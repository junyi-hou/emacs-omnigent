;;; omnigent-sessions.el --- Session list and server actions -*- lexical-binding: t; -*-

;;; Commentary:
;; Maintain and display the session list.  Manage server actions.

;;; Code:

(require 'cl-lib)
(require 'button)
(require 'seq)
(require 'omnigent-transport)
(require 'omnigent-workspace)

(defvar vertico--input)
(declare-function vertico--exhibit "vertico")

(defvar omnigent-sessions nil
  "List of root session alists from the server.")
(defvar omnigent-sessions-projects nil
  "List of project alists from the current server.")
(defvar omnigent-sessions--project-lists
  (make-hash-table :test 'equal)
  "Map project keys to a list of limit, fetched rows, and whether more exist.")
(defvar omnigent-sessions--project-more (make-hash-table :test 'equal)
  "Map project keys to pagination check states.")

(defvar omnigent-sessions--missing-projects
  (make-hash-table :test 'equal))

(defun omnigent-sessions-project-key (session)
  "Return SESSION's project ID or the symbol unassigned."
  (let ((id (alist-get 'project_id session)))
    (if (and id
             (not (gethash id omnigent-sessions--missing-projects)))
        id
      'unassigned)))

(defun omnigent-sessions-visible ()
  "Return global session rows with project fetches applied."
  (if (= 0 (hash-table-count omnigent-sessions--project-lists))
      omnigent-sessions
    (let (rows)
      (maphash
       (lambda (_key entry)
         (when (cadr entry)
           (setq rows (append (cadr entry) rows))))
       omnigent-sessions--project-lists)
      (setq rows
            (append
             rows
             (cl-remove-if
              (lambda (row)
                (let ((entry
                       (gethash
                        (omnigent-sessions-project-key row)
                        omnigent-sessions--project-lists)))
                  (and entry (or (zerop (car entry)) (cadr entry)))))
              omnigent-sessions)))
      (cl-delete-duplicates
       (if omnigent-fetch-archived-sessions
           rows
         (cl-remove-if
          (lambda (row) (eq (alist-get 'archived row) t)) rows))
       :key (lambda (row) (alist-get 'id row))
       :test #'equal
       :from-end t))))

(defun omnigent-sessions-fetch-project (key limit)
  "Fetch up to LIMIT sessions for project KEY and replace its displayed rows."
  (let* ((name
          (if (eq key 'unassigned)
              ""
            (alist-get
             'name
             (cl-find
              key
              omnigent-sessions-projects
              :key (lambda (row) (alist-get 'id row))
              :test #'equal))))
         (old (gethash key omnigent-sessions--project-lists))
         (entry
          (list
           limit
           (and (> limit 0) (cadr old))
           (and (> limit 0) (nth 2 old))))
         (archived omnigent-fetch-archived-sessions))
    (when name
      (puthash key entry omnigent-sessions--project-lists)
      (if (zerop limit)
          (run-hooks 'omnigent-sessions-change-hook)
        (omnigent-transport-list-sessions
         (lambda (status body)
           (when (and (eq
                       entry
                       (gethash key omnigent-sessions--project-lists))
                      (eq archived omnigent-fetch-archived-sessions))
             (cond
              ((not (omnigent-transport-success-p status))
               (omnigent-sessions--error
                "List project sessions" status
                body))
              ((not (omnigent-sessions--rows-p body 'data 'id))
               (omnigent-sessions--error
                "List project sessions" nil
                "Invalid session list response"))
              (t
               (setf
                (cadr entry)
                (or
                 (cl-remove-if-not
                  (lambda (row)
                    (and
                     (not (alist-get 'parent_session_id row))
                     (equal key (omnigent-sessions-project-key row))))
                  (append (alist-get 'data body) nil))
                 ;; Distinguish an empty result from a pending request.
                 [])
                (nth 2 entry) (eq (alist-get 'has_more body) t))
               (run-hooks 'omnigent-sessions-change-hook)))))
         name limit)))))

(defvar omnigent-sessions--project-catalog nil)
(defvar omnigent-sessions--pending-projects
  (make-hash-table :test 'equal))

(defvar omnigent-sessions-truncated nil
  "Non-nil when the server reports more sessions than were fetched.")
(defvar omnigent-sessions-updates nil
  "Transport handle for session updates, or nil when not started.")
(defvar omnigent-sessions-change-hook nil
  "Hook run without arguments after session list changes.")
(defvar omnigent-sessions-frame-hook nil
  "Hook called with each parsed session update frame.")
(defvar omnigent-sessions-error-hook '(message)
  "Hook called with an error description string.")
(defvar omnigent-sessions-open-hook nil
  "Hook called with a newly created session alist so a frontend can open it.")
(defvar omnigent-sessions--refresh-number 0)
(defvar omnigent-sessions--buffers nil)
(defvar omnigent-sessions--revision 0)

(defvar omnigent-sessions--children (make-hash-table :test 'equal)
  "Map parent IDs to cached child rows.")
(defvar omnigent-sessions--child-requests
  (make-hash-table :test 'equal)
  "Map parent IDs to pending refresh state.")
(defvar omnigent-sessions--watched-ids nil
  "IDs submitted to the session-updates watch.")

(defun omnigent-sessions-children (id)
  "Return known children of session ID."
  (gethash id omnigent-sessions--children))

(defun omnigent-sessions-row (id)
  "Return the root or child session row for ID."
  (or (cl-find
       id
       (omnigent-sessions-visible)
       :key (lambda (row) (alist-get 'id row))
       :test #'equal)
      (catch 'row
        (maphash
         (lambda (_ rows)
           (when-let* ((row
                        (cl-find
                         id rows
                         :key
                         (lambda (row) (alist-get 'id row))
                         :test #'equal)))
             (throw 'row row)))
         omnigent-sessions--children))))

(defun omnigent-sessions--merge-child (row fields)
  "Return ROW with the supplied FIELDS updated."
  (append
   fields
   (cl-remove-if (lambda (field) (assq (car field) fields)) row)))

(defun omnigent-sessions--child-change (parent id fields)
  "Update child ID of PARENT with FIELDS, or remove it if FIELDS is nil."
  (when-let* ((request
               (gethash parent omnigent-sessions--child-requests)))
    (let ((old (assoc id (cdr request))))
      (setcdr
       request
       (cons
        (cons
         id
         (and fields
              (omnigent-sessions--merge-child (cdr old) fields)))
        (delq old (cdr request))))))
  (when-let* ((rows (omnigent-sessions-children parent)))
    (puthash
     parent
     (delq
      nil
      (mapcar
       (lambda (row)
         (if (equal id (alist-get 'id row))
             (and fields (omnigent-sessions--merge-child row fields))
           row))
       rows))
     omnigent-sessions--children)))

(defun omnigent-sessions--child-page (id buffer request rows cursors)
  "Fetch a page for ID and BUFFER, tracking ROWS and CURSORS for REQUEST."
  (condition-case err
      (omnigent-transport-list-child-sessions
       id
       (lambda (status body)
         (when (and (eq
                     request
                     (gethash id omnigent-sessions--child-requests))
                    (eq buffer (omnigent-sessions-buffer id)))
           (let* ((valid
                   (and (omnigent-transport-success-p status)
                        (omnigent-sessions--rows-p body 'data 'id)))
                  (more (and valid (eq (alist-get 'has_more body) t)))
                  (cursor (and more (alist-get 'last_id body))))
             (when valid
               (setq rows
                     (nconc
                      rows (append (alist-get 'data body) nil))))
             (if (and more
                      (stringp cursor)
                      (not (string-empty-p cursor))
                      (not (member cursor cursors)))
                 (omnigent-sessions--child-page
                  id buffer request rows (cons cursor cursors))
               (remhash id omnigent-sessions--child-requests)
               (cond
                ((not (omnigent-transport-success-p status))
                 (omnigent-sessions--error
                  "List child sessions" status
                  body))
                ((or (not valid) more)
                 (omnigent-sessions--error
                  "List child sessions" nil
                  "Invalid child session list"))
                (t
                 (puthash
                  id
                  (delq
                   nil
                   (mapcar
                    (lambda (row)
                      (if-let* ((patch
                                 (assoc
                                  (alist-get 'id row) (cdr request))))
                        (and (cdr patch)
                             (omnigent-sessions--merge-child
                              row (cdr patch)))
                        row))
                    rows))
                  omnigent-sessions--children)
                 (omnigent-sessions--watch)
                 (run-hooks 'omnigent-sessions-change-hook)))
               (when (car request)
                 (omnigent-sessions-refresh-children id))))))
       (car cursors))
    (error
     (when (eq request (gethash id omnigent-sessions--child-requests))
       (remhash id omnigent-sessions--child-requests)
       (omnigent-sessions--error "List child sessions" nil
                                 (error-message-string err))))))

(defun omnigent-sessions-refresh-children (id)
  "Refresh ID's child list while its conversation buffer is open."
  (when-let* ((buffer (omnigent-sessions-buffer id)))
    (if-let* ((request
               (gethash id omnigent-sessions--child-requests)))
      (setcar request t)
      (let ((request (list nil)))
        (puthash id request omnigent-sessions--child-requests)
        (omnigent-sessions--child-page id buffer request nil nil)))))

(defun omnigent-sessions--check-project-more (key name)
  "Check whether project KEY, queried as NAME, has more sessions."
  (when (and omnigent-sessions-truncated
             (not (gethash key omnigent-sessions--project-lists))
             (not (gethash key omnigent-sessions--project-more)))
    (let ((limit
           (cl-count
            key
            omnigent-sessions
            :key #'omnigent-sessions-project-key
            :test #'equal))
          (number omnigent-sessions--refresh-number)
          (checks omnigent-sessions--project-more)
          (archived omnigent-fetch-archived-sessions))
      (when (> limit 0)
        (puthash key 'pending omnigent-sessions--project-more)
        (omnigent-transport-list-sessions
         (lambda (status body)
           (when (and (= number omnigent-sessions--refresh-number)
                      (eq checks omnigent-sessions--project-more)
                      (eq archived omnigent-fetch-archived-sessions))
             (if (and (omnigent-transport-success-p status)
                      (eq (alist-get 'has_more body) t))
                 (progn
                   (puthash key t omnigent-sessions--project-more)
                   (unless (gethash
                            key omnigent-sessions--project-lists)
                     (run-hooks 'omnigent-sessions-change-hook)))
               (puthash
                key 'complete omnigent-sessions--project-more))))
         name limit)))))

(defun omnigent-sessions--error (action status &optional body)
  "Report ACTION's failure STATUS and any server detail in BODY to the error hook."
  (run-hook-with-args 'omnigent-sessions-error-hook
                      (omnigent-transport-error-message
                       action status body)))

(defun omnigent-sessions--rows-p (body key &rest fields)
  "Return non-nil if BODY has an array at KEY with string FIELDS in each row."
  (and (listp body)
       (vectorp (alist-get key body))
       (cl-every
        (lambda (row)
          (and (listp row)
               (cl-every
                (lambda (field)
                  (stringp (alist-get field row)))
                fields)))
        (alist-get key body))))


(defun omnigent-sessions--refreshed (number revision status body)
  "Apply list BODY for refresh NUMBER and REVISION when STATUS succeeds."
  (when (= number omnigent-sessions--refresh-number)
    (cond
     ((not (omnigent-transport-success-p status))
      (omnigent-sessions--error "List sessions" status body))
     ((/= revision omnigent-sessions--revision)
      (omnigent-sessions-refresh))
     ((not (omnigent-sessions--rows-p body 'data 'id))
      (omnigent-sessions--error "List sessions" nil
                                "Invalid session list response"))
     (t
      (let ((rows (append (alist-get 'data body) nil)))
        (dolist (entry omnigent-sessions--buffers)
          (when (and (buffer-live-p (cdr entry))
                     (not
                      (cl-find
                       (car entry)
                       rows
                       :key (lambda (row) (alist-get 'id row))
                       :test #'equal)))
            (when-let* ((old
                         (cl-find
                          (car entry)
                          omnigent-sessions
                          :key
                          (lambda (row) (alist-get 'id row))
                          :test #'equal)))
              (push old rows))))
        (setq omnigent-sessions
              (cl-remove-if
               (lambda (row)
                 (alist-get 'parent_session_id row))
               rows)))
      (setq omnigent-sessions-truncated
            (eq (alist-get 'has_more body) t))
      (setq omnigent-sessions--project-more
            (make-hash-table :test 'equal))
      (omnigent-sessions-refresh-projects)
      (run-hooks 'omnigent-sessions-change-hook)
      (omnigent-sessions--check-project-more 'unassigned "")
      (dolist (project omnigent-sessions-projects)
        (omnigent-sessions--check-project-more
         (alist-get 'id project) (alist-get 'name project)))
      (maphash
       (lambda (key entry)
         (when (> (car entry) 0)
           (omnigent-sessions-fetch-project key (car entry))))
       omnigent-sessions--project-lists)))))

(defun omnigent-sessions--frame (frame)
  "Apply session update FRAME and notify the session hooks.
Refresh the list if FRAME contains a session that is not in the list."
  (let ((type (alist-get 'type frame))
        unknown)
    (cond
     ((member type '("snapshot" "changed"))
      (dolist (item (append (alist-get 'items frame) nil))
        (let* ((id (alist-get 'id item))
               (parent (alist-get 'parent_session_id item))
               (old
                (cl-find
                 id
                 omnigent-sessions
                 :key (lambda (row) (alist-get 'id row))
                 :test #'equal)))
          (unless (alist-get
                   'omnigent.side_chat (alist-get 'labels item))
            (cond
             (parent
              (when (or (omnigent-sessions-buffer parent)
                        (omnigent-sessions-buffer id))
                (omnigent-sessions--child-change parent id item)))
             (old
              (setq omnigent-sessions
                    (mapcar
                     (lambda (row)
                       (if (eq row old)
                           item
                         row))
                     omnigent-sessions)))
             (t
              (when (omnigent-sessions-buffer id)
                (push item omnigent-sessions))
              (setq unknown t)))))))
     ((equal type "removed")
      (let ((ids (append (alist-get 'ids frame) nil)))
        (dolist (id ids)
          (remhash id omnigent-sessions--child-requests)
          (remhash id omnigent-sessions--children))
        (maphash
         (lambda (parent rows)
           (dolist (row rows)
             (let ((id (alist-get 'id row)))
               (when (member id ids)
                 (omnigent-sessions--child-change parent id nil)))))
         omnigent-sessions--children)
        (omnigent-sessions--watch)
        (setq omnigent-sessions
              (cl-remove-if
               (lambda (row)
                 (member (alist-get 'id row) ids))
               omnigent-sessions)))))
    (when (member type '("snapshot" "changed" "removed"))
      (cl-incf omnigent-sessions--revision))
    (run-hook-with-args 'omnigent-sessions-frame-hook frame)
    (unless (equal type "heartbeat")
      (run-hooks 'omnigent-sessions-change-hook))
    (when unknown
      (omnigent-sessions-refresh))))

(defun omnigent-sessions--watch ()
  "Remove dead buffers and update the watched session IDs."
  (setq omnigent-sessions--buffers
        (cl-remove-if-not
         (lambda (entry) (buffer-live-p (cdr entry)))
         omnigent-sessions--buffers))
  (let* ((open (mapcar #'car omnigent-sessions--buffers))
         (children
          (delete-dups
           (apply #'append
                  (mapcar
                   (lambda (id)
                     (mapcar
                      (lambda (row) (alist-get 'id row))
                      (omnigent-sessions-children id)))
                   open))))
         (ids
          (append
           open
           (cl-remove-if (lambda (id) (member id open)) children)))
         (watch (seq-take ids 500)))
    (when (and omnigent-sessions-updates
               (not (equal watch omnigent-sessions--watched-ids)))
      (setq omnigent-sessions--watched-ids watch)
      (omnigent-transport-set-session-updates-watch
       omnigent-sessions-updates watch))
    (when (> (length ids) 500)
      (message
       "Some child sessions lack live updates: session watch limit is 500"))))

(defun omnigent-sessions-buffer (id)
  "Return the live conversation buffer for ID, or nil."
  (let ((buffer (cdr (assoc id omnigent-sessions--buffers))))
    (and (buffer-live-p buffer) buffer)))

(defun omnigent-sessions-register-buffer (id buffer)
  "Register conversation BUFFER for session ID.
Signal a user error if ID already has a different live buffer or the
500-session watch limit is reached.  Remove the registration when BUFFER dies."
  (let ((existing (assoc id omnigent-sessions--buffers)))
    (when (and existing (not (buffer-live-p (cdr existing))))
      (setq
       omnigent-sessions--buffers
       (delq existing omnigent-sessions--buffers)
       existing nil))
    (when (and existing (not (eq buffer (cdr existing))))
      (user-error "Session already has a conversation buffer"))
    (unless existing
      (omnigent-sessions--watch)
      (when (>= (length omnigent-sessions--buffers) 500)
        (user-error
         "Cannot open another session: the watch limit is 500"))
      (push (cons id buffer) omnigent-sessions--buffers)
      (with-current-buffer buffer
        (add-hook 'kill-buffer-hook #'omnigent-sessions--buffer-killed
                  nil
                  t))
      (omnigent-sessions--watch))))

(defun omnigent-sessions--buffer-killed ()
  "Remove the current buffer's registration and update the watch set."
  (when-let* ((entry
               (rassq (current-buffer) omnigent-sessions--buffers)))
    (remhash (car entry) omnigent-sessions--child-requests)
    (setq omnigent-sessions--buffers
          (delq entry omnigent-sessions--buffers))
    (omnigent-sessions--watch)
    (run-hooks 'omnigent-sessions-change-hook)))

(defun omnigent-sessions--close-conversation (id)
  "Close the registered conversation buffer for session ID."
  (when-let* ((buffer (omnigent-sessions-buffer id)))
    (if-let* ((window (get-buffer-window buffer t)))
      (with-selected-window window
        (kill-buffer-and-window))
      (kill-buffer buffer))))

(defun omnigent-sessions-show-project (project)
  "Add PROJECT to the displayed project list and notify the frontend."
  (let ((id (alist-get 'id project)))
    (unless (cl-find
             id
             omnigent-sessions-projects
             :key (lambda (row) (alist-get 'id row))
             :test #'equal)
      (setq omnigent-sessions-projects
            (append omnigent-sessions-projects (list project)))
      (run-hooks 'omnigent-sessions-change-hook))))

(defun omnigent-sessions-create-project (name)
  "Create a server project named NAME and reveal it in the session list."
  (omnigent-transport-request
   "POST" "/v1/projects"
   (lambda (status body)
     (cond
      ((not (omnigent-transport-success-p status))
       (omnigent-sessions--error "Create project" status body))
      ((not
        (and (listp body)
             (stringp (alist-get 'id body))
             (stringp (alist-get 'name body))))
       (omnigent-sessions--error "Create project" nil
                                 "Invalid project response"))
      (t
       (setq omnigent-sessions--project-catalog nil)
       (omnigent-sessions-show-project body)
       (omnigent-sessions-fetch-project
        (alist-get 'id body)
        (max 1 (min 1000 omnigent-transport-session-limit)))
       (run-hooks 'omnigent-sessions-change-hook))))
   `(("name" . ,name))))

(defun omnigent-sessions-delete-project (id)
  "Archive and unassign all sessions in project ID before deleting the project."
  (omnigent-transport-request
   "GET" (concat "/v1/projects/" (url-hexify-string id))
   (lambda (status body)
     (cond
      ((not (omnigent-transport-success-p status))
       (omnigent-sessions--error "Read project" status body))
      ((not (and (listp body) (stringp (alist-get 'name body))))
       (omnigent-sessions--error "Read project" nil
                                 "Invalid project response"))
      (t
       (omnigent-sessions--project-members
        id (alist-get 'name body) nil nil))))))

(defun omnigent-sessions--project-members (id name after members)
  "Collect members of project ID named NAME after cursor AFTER into MEMBERS."
  (omnigent-transport-request
   "GET"
   (concat
    "/v1/sessions?limit=1000&include_archived=true&sort_by=created_at&order=asc&project="
    (url-hexify-string name)
    (when after
      (concat "&after=" (url-hexify-string after))))
   (lambda (status body)
     (cond
      ((not (omnigent-transport-success-p status))
       (omnigent-sessions--error "List project members" status body))
      ((not
        (and (omnigent-sessions--rows-p body 'data 'id)
             (memq (alist-get 'has_more body) '(t :json-false))))
       (omnigent-sessions--error "List project members" nil
                                 "Invalid session list response"))
      (t
       (dolist (row (append (alist-get 'data body) nil))
         (when (equal id (alist-get 'project_id row))
           (push (alist-get 'id row) members)))
       (if (eq (alist-get 'has_more body) t)
           (let ((next (alist-get 'last_id body)))
             (if (and (stringp next)
                      (not (string-empty-p next))
                      (not (equal next after)))
                 (omnigent-sessions--project-members
                  id name next members)
               (omnigent-sessions--error
                "List project members" nil
                "Invalid session list cursor")))
         (omnigent-sessions--archive-project-members
          id (delete-dups members))))))))

(defun omnigent-sessions--archive-project-members (id members)
  "Archive and unassign MEMBERS in sequence, then delete project ID."
  (if-let* ((session (car members)))
    (omnigent-transport--request
     session "PATCH" (omnigent-transport--session-path session)
     (lambda (status body)
       (if (omnigent-transport-success-p status)
           (progn
             (omnigent-sessions--close-conversation session)
             (omnigent-sessions--archive-project-members
              id (cdr members)))
         (omnigent-sessions--error
          (format "Archive and unassign session %s (project kept)"
                  session)
          status
          body)
         (omnigent-sessions-refresh)))
     '(("archived" . t) ("project_id" . "")))
    (omnigent-sessions--delete-empty-project id)))

(defun omnigent-sessions--delete-empty-project (id)
  "Delete server project ID and refresh the session list."
  (omnigent-transport-request
   "DELETE" (concat "/v1/projects/" (url-hexify-string id))
   (lambda (status body)
     (if (omnigent-transport-success-p status)
         (progn
           (setq
            omnigent-sessions--project-catalog nil
            omnigent-sessions-projects
            (cl-remove
             id
             omnigent-sessions-projects
             :key (lambda (row) (alist-get 'id row))
             :test #'equal))
           (puthash id t omnigent-sessions--missing-projects)
           (remhash id omnigent-sessions--project-lists)
           (run-hooks 'omnigent-sessions-change-hook)
           (omnigent-sessions-refresh))
       (omnigent-sessions--error "Delete project" status body)
       (omnigent-sessions-refresh)))))

(defun omnigent-sessions-refresh-projects ()
  "Fetch details for projects represented in the global session list."
  (dolist (session omnigent-sessions)
    (let ((id (alist-get 'project_id session)))
      (when (and (stringp id)
                 (not
                  (gethash id omnigent-sessions--pending-projects))
                 (not
                  (cl-find
                   id
                   omnigent-sessions-projects
                   :key (lambda (row) (alist-get 'id row))
                   :test #'equal)))
        (puthash id t omnigent-sessions--pending-projects)
        (omnigent-transport-request
         "GET" (concat "/v1/projects/" (url-hexify-string id))
         (lambda (status body)
           (remhash id omnigent-sessions--pending-projects)
           (when (and (omnigent-transport-success-p status)
                      (listp body)
                      (equal id (alist-get 'id body))
                      (stringp (alist-get 'name body)))
             (omnigent-sessions-show-project body)
             (omnigent-sessions--check-project-more
              id (alist-get 'name body)))))))))

(defun omnigent-sessions-read-projects (callback)
  "Pass the cached or newly fetched project catalog to CALLBACK."
  (if omnigent-sessions--project-catalog
      (funcall callback
               (append omnigent-sessions--project-catalog nil))
    (omnigent-transport-request
     "GET" "/v1/projects"
     (lambda (status body)
       (cond
        ((not (omnigent-transport-success-p status))
         (omnigent-sessions--error "List projects" status body))
        ((not (omnigent-sessions--rows-p body 'data 'id 'name))
         (omnigent-sessions--error "List projects" nil
                                   "Invalid project list"))
        (t
         (setq omnigent-sessions--project-catalog
               (alist-get 'data body))
         (funcall callback
                  (append
                   omnigent-sessions--project-catalog nil))))))))

(defun omnigent-sessions-move (id project-id &optional callback)
  "Move ID to PROJECT-ID.  An empty string unassigns it.
Pass the status and response body to CALLBACK when supplied."
  (omnigent-transport--request
   id "PATCH" (omnigent-transport--session-path id)
   (lambda (status body)
     (unwind-protect
         (when (omnigent-transport-success-p status)
           (omnigent-sessions-refresh))
       (if callback
           (funcall callback status body)
         (unless (omnigent-transport-success-p status)
           (omnigent-sessions--error "Move session" status body)))))
   `(("project_id" . ,project-id))))

(defun omnigent-sessions-reset ()
  "Forget state from the current server."
  (cl-incf omnigent-sessions--refresh-number)
  (clrhash omnigent-sessions--children)
  (clrhash omnigent-sessions--child-requests)
  (setq omnigent-sessions--watched-ids nil)
  (clrhash omnigent-sessions--pending-projects)
  (clrhash omnigent-sessions--missing-projects)
  (setq
   omnigent-sessions-projects nil
   omnigent-sessions--project-catalog nil)
  (clrhash omnigent-sessions--project-lists)
  (clrhash omnigent-sessions--project-more)
  (when omnigent-sessions-updates
    (omnigent-transport-stop-session-updates
     omnigent-sessions-updates))
  (setq
   omnigent-sessions nil
   omnigent-sessions-truncated nil
   omnigent-sessions-updates nil
   omnigent-sessions--buffers nil))

(defun omnigent-sessions-start (&optional on-first-open)
  "Start session updates and invoke ON-FIRST-OPEN after the first connection."
  (setq omnigent-sessions-updates
        (omnigent-transport-start-session-updates
         #'omnigent-sessions--frame
         (lambda (error)
           (omnigent-sessions--error "Session updates" error))
         (lambda ()
           (when on-first-open
             (let ((callback on-first-open))
               (setq on-first-open nil)
               (funcall callback)))
           (omnigent-sessions-refresh))))
  (omnigent-sessions--watch)
  (omnigent-sessions-refresh))

(defun omnigent-sessions--filesystem-path
    (host-id path &optional after)
  "Build the filesystem request for HOST-ID, PATH, and pagination cursor AFTER."
  (let* ((base
          (concat
           "/v1/hosts/" (url-hexify-string host-id) "/filesystem"))
         (windows
          (or (string-match-p "\\`[[:alpha:]]:[/\\\\]" path)
              (string-prefix-p "\\\\" path)))
         (native
          (if windows
              (subst-char-in-string ?\\ ?/ path)
            (string-remove-prefix "/" path))))
    (concat
     base
     (unless (string-empty-p path)
       (concat
        "/"
        (mapconcat #'url-hexify-string (split-string native "/")
                   "/")))
     "?limit=1000"
     (when after
       (concat "&after=" (url-hexify-string after))))))

(defun omnigent-sessions--workspace-directories
    (host-id path callback &optional after directories)
  "Fetch directories at PATH on HOST-ID asynchronously for CALLBACK.
CALLBACK receives (STATUS DIRECTORIES), or (STATUS BODY) on failure.
AFTER and DIRECTORIES carry the cursor and entries across listing pages."
  ;; ponytail: fetch full listings; use incremental completion if large directories are slow.
  (omnigent-transport-request
   "GET" (omnigent-sessions--filesystem-path host-id path after)
   (lambda (status body)
     (cond
      ((not (omnigent-transport-success-p status))
       (funcall callback status body))
      ((not (omnigent-sessions--rows-p body 'data 'name 'path 'type))
       (funcall callback nil "Invalid filesystem listing response"))
      (t
       (let* ((entries (append (alist-get 'data body) nil))
              (cursor (alist-get 'path (car (last entries)))))
         (dolist (entry entries)
           (when (equal (alist-get 'type entry) "directory")
             (push entry directories)))
         (if (eq (alist-get 'has_more body) t)
             (if (or (null cursor) (equal cursor after))
                 (funcall callback
                          nil
                          "Invalid filesystem pagination")
               (omnigent-sessions--workspace-directories
                host-id path callback
                cursor directories))
           (funcall callback status (nreverse directories)))))))))

(defun omnigent-sessions--native-workspace (input &optional host-id)
  "Interpret INPUT on the execution host, never relative to Emacs's directory.
When HOST-ID is non-nil, expand the path through its configured mapping."
  (when (or (string-empty-p input)
            (file-remote-p input)
            (string-match-p "\0" input))
    (user-error
     "Choose a directory path on the execution host, not a TRAMP path"))
  (if (and host-id
           (not (string-prefix-p "\\\\" input))
           (not (string-match-p "\\`[[:alpha:]]:[/\\\\]" input)))
      (if (string-prefix-p "/" input)
          (expand-file-name input "/")
        (let* ((mapping (omnigent-workspace-host-mapping host-id))
               (prefix
                (if (eq mapping 'local)
                    ""
                  mapping)))
          (file-local-name
           (expand-file-name (concat prefix input)
                             (expand-file-name
                              (concat prefix "~/"))))))
    (if (or (string-prefix-p "/" input)
            (string-prefix-p "~" input)
            (string-prefix-p "\\\\" input)
            (string-match-p "\\`[[:alpha:]]:[/\\\\]" input))
        input
      (concat "~/" input))))

(defun omnigent-sessions--read-workspace
    (callback &optional session fixed-host fixed-workspace)
  "Select a host and workspace asynchronously, then call CALLBACK with their cons.
Call CALLBACK with nil if the user cancels selection.
Use the sole online host, or prompt when several hosts are online.
Use SESSION as a workspace default when its host matches.
Use FIXED-HOST or FIXED-WORKSPACE when already configured.
Report discovery failures through `omnigent-sessions-error-hook'."
  (message "Reading execution hosts...")
  (let ((generation omnigent-transport--generation))
    (omnigent-transport-request
     "GET" "/v1/hosts"
     (lambda (status body)
       (omnigent-sessions--select-host
        generation callback session status body
        fixed-host fixed-workspace)))))

(defun omnigent-sessions--read-host (callback)
  "Call CALLBACK with the selected online host ID, or nil on cancellation."
  (message "Reading execution hosts...")
  (let ((generation omnigent-transport--generation))
    (omnigent-transport-request
     "GET" "/v1/hosts"
     (lambda (status body)
       (omnigent-sessions--select-host
        generation callback nil status body
        nil nil t)))))

(defun omnigent-sessions--select-host
    (generation
     callback
     session
     status
     body
     &optional
     fixed-host
     fixed-workspace
     host-only)
  "Present hosts from BODY after STATUS and call CALLBACK on GENERATION.
Use SESSION for context and retain FIXED-HOST and FIXED-WORKSPACE.
When HOST-ONLY is non-nil, call CALLBACK with the host ID alone."
  (cond
   ((not (omnigent-transport-success-p status))
    (omnigent-sessions--error "List hosts" status body))
   ((not (omnigent-sessions--rows-p body 'hosts 'host_id 'status))
    (omnigent-sessions--error "List hosts" nil
                              "Invalid execution host response"))
   (t
    (let* ((hosts
            (cl-remove-if-not
             (lambda (host)
               (and (equal
                     (alist-get 'status host) "online")
                    (or (not fixed-host)
                        (equal
                         fixed-host (alist-get 'host_id host)))))
             (append (alist-get 'hosts body) nil)))
           (choices
            (mapcar
             (lambda (host)
               (cons
                (format "%s [%s]"
                        (or (alist-get 'name host) "Host")
                        (alist-get 'host_id host))
                (alist-get 'host_id host)))
             hosts)))
      (if (null choices)
          (omnigent-sessions--error
           (if host-only
               "Select host"
             "Select workspace")
           "No online execution hosts")
        (let* ((choice
                (if (cdr choices)
                    (condition-case nil
                        (completing-read "Execution host: " choices
                                         nil
                                         t)
                      (quit
                       nil))
                  (caar choices)))
               (host-id (cdr (assoc choice choices))))
          (if (not choice)
              (funcall callback nil)
            (unless (= generation omnigent-transport--generation)
              (user-error
               "Server changed during workspace selection"))
            (cond
             (host-only
              (funcall callback host-id))
             (fixed-workspace
              (funcall callback (cons host-id fixed-workspace)))
             (t
              (message "Reading workspaces on %s..." choice)
              (omnigent-sessions--workspace-directories
               host-id ""
               (apply-partially
                #'omnigent-sessions--select-workspace
                generation host-id choice callback
                (and (equal host-id (alist-get 'host_id session))
                     (alist-get 'workspace session)))))))))))))

(defun omnigent-sessions--select-workspace
    (generation host-id choice callback default status directories)
  "Prompt with DIRECTORIES for HOST-ID and CHOICE after successful STATUS.
Use DEFAULT as the workspace default.
Continue through CALLBACK after validating the path on GENERATION's server."
  (if (not (omnigent-transport-success-p status))
      (omnigent-sessions--error "List workspaces" status directories)
    (let ((cache (make-hash-table :test #'equal))
          (active t)
          workspace)
      (puthash "" directories cache)
      (unwind-protect
          (setq
           workspace
           (condition-case nil
               (omnigent-sessions--native-workspace
                (minibuffer-with-setup-hook
                    (lambda ()
                      (let ((refresh
                             (lambda (&rest _)
                               (all-completions
                                (minibuffer-contents-no-properties)
                                minibuffer-completion-table
                                minibuffer-completion-predicate))))
                        (add-hook 'after-change-functions refresh
                                  nil t)
                        (funcall refresh)))
                  (completing-read
                   (format "Workspace on %s: " choice)
                   (lambda (input predicate action)
                     (unless
                         (= generation omnigent-transport--generation)
                       (user-error
                        "Server changed during workspace selection"))
                     (cond
                      ((eq action 'metadata)
                       '(metadata (category . omnigent-workspace)))
                      ((eq
                        (car-safe action) 'boundaries)
                       `(boundaries
                         .
                         (,(length
                            (or (file-name-directory input) ""))
                          . 0)))
                      (t
                       (let
                           ((parent
                             (or (file-name-directory input) ""))
                            (minibuffer
                             (when-let*
                                 ((window (active-minibuffer-window)))
                               (window-buffer window))))
                         (when (and (string-suffix-p "/" input)
                                    (eq
                                     (gethash parent cache 'missing)
                                     'missing))
                           (puthash parent 'pending cache)
                           (omnigent-sessions--workspace-directories
                            host-id
                            (if (string-empty-p parent)
                                ""
                              (omnigent-sessions--native-workspace
                               parent))
                            (lambda (directory-status entries)
                              (when active
                                (if (not
                                     (omnigent-transport-success-p
                                      directory-status))
                                    (progn
                                      (remhash parent cache)
                                      (omnigent-sessions--error
                                       "List directories"
                                       directory-status
                                       entries))
                                  (puthash parent entries cache)
                                  (when-let*
                                      ((window
                                        (active-minibuffer-window))
                                       ((eq
                                         (window-buffer
                                          window)
                                         minibuffer)))
                                    (with-selected-window window
                                      (when
                                          (equal
                                           parent
                                           (or
                                            (file-name-directory
                                             (minibuffer-contents-no-properties))
                                            ""))
                                        (if (and (featurep 'vertico)
                                                 (bound-and-true-p
                                                  vertico--input))
                                            (progn
                                              (setq vertico--input t)
                                              (vertico--exhibit))
                                          (run-hooks
                                           'post-command-hook))
                                        (redisplay)))))))))
                         (let ((entries (gethash parent cache)))
                           (complete-with-action
                            action
                            (cons
                             (if (string-empty-p parent)
                                 "~/"
                               "")
                             (unless (eq entries 'pending)
                               (mapcar
                                (lambda (entry)
                                  (concat
                                   (alist-get 'name entry) "/"))
                                entries)))
                            (if (string-empty-p parent)
                                input
                              (file-name-nondirectory input))
                            predicate))))))
                   nil
                   nil
                   nil
                   nil
                   default
                   t))
                host-id)
             (quit
              nil)))
        (setq active nil))
      (if (not workspace)
          (funcall callback nil)
        (unless (= generation omnigent-transport--generation)
          (user-error "Server changed during workspace selection"))
        (message "Checking workspace %s..." workspace)
        ;; A fresh listing validates typed paths, including empty directories.
        (omnigent-transport-request
         "GET" (omnigent-sessions--filesystem-path host-id workspace)
         (lambda (check-status body)
           (cond
            ((not (omnigent-transport-success-p check-status))
             (omnigent-sessions--error "Check workspace" check-status
                                       body))
            ((not
              (omnigent-sessions--rows-p body 'data
                                         'name
                                         'path
                                         'type))
             (omnigent-sessions--error
              "Check workspace" nil
              "Invalid filesystem listing response"))
            (t
             (funcall callback (cons host-id workspace))))))))))

(defun omnigent-sessions--read-agent
    (generation
     callback &optional inherit reference return-row after agents)
  "Pass the selected agent ID on GENERATION to CALLBACK.
When INHERIT is a label, offer it and return the symbol inherit if selected.
Resolve REFERENCE as an ID or name when it is non-nil.
When RETURN-ROW is non-nil, pass the selected agent row for a choice.
AFTER and AGENTS track the cursor and rows across pages."
  (omnigent-transport-request
   "GET"
   (if after
       (concat "/v1/agents?after=" (url-hexify-string after))
     "/v1/agents")
   (lambda (status body)
     (unless (= generation omnigent-transport--generation)
       (user-error "Server changed during agent selection"))
     (cond
      ((not (omnigent-transport-success-p status))
       (omnigent-sessions--error "List agents" status body))
      ((not (omnigent-sessions--rows-p body 'data 'id 'name))
       (omnigent-sessions--error "List agents" nil
                                 "Invalid agent list response"))
      (t
       (let ((rows (append agents (alist-get 'data body) nil)))
         (if (eq (alist-get 'has_more body) t)
             (let ((next (alist-get 'last_id body)))
               (if (and (stringp next)
                        (not (string-empty-p next))
                        (not (equal after next)))
                   (omnigent-sessions--read-agent generation callback
                                                  inherit
                                                  reference
                                                  return-row
                                                  next
                                                  rows)
                 (omnigent-sessions--error
                  "List agents" nil
                  "Invalid agent list cursor")))
           (omnigent-sessions--select-agent
            callback inherit reference rows
            return-row))))))))

(defun omnigent-sessions--select-agent
    (callback inherit reference agents &optional return-row)
  "Pass the ID selected from AGENTS to CALLBACK.
Offer INHERIT when non-nil, or resolve a configured REFERENCE.
When RETURN-ROW is non-nil, pass the selected agent row for a choice."
  (let ((names (make-hash-table :test #'equal)))
    (dolist (agent agents)
      (let ((name (alist-get 'name agent)))
        (push agent (gethash name names))))
    (cond
     (reference
      (let* ((matches (gethash reference names))
             (id
              (or (and (seq-find
                        (lambda (agent)
                          (equal (alist-get 'id agent) reference))
                        agents)
                       reference)
                  (and (= (length matches) 1)
                       (alist-get 'id (car matches))))))
        (unless id
          (omnigent-sessions--error
           "Create session" nil
           (if matches
               (format
                "Multiple agents named %S. Set the default to an agent ID."
                reference)
             (format "No agent matches the configured default %S."
                     reference))))
        (funcall callback id)))
     ((and (not inherit) (not agents))
      (omnigent-sessions--error
       "Create session" "No agents available"))
     (t
      (let ((choices
             (mapcar
              (lambda (agent)
                (let ((name (alist-get 'name agent))
                      (id (alist-get 'id agent)))
                  (cons
                   (if (or (equal name inherit)
                           (cdr (gethash name names)))
                       (format "%s [%s]" name id)
                     name)
                   (if return-row
                       agent
                     id))))
              agents)))
        (when inherit
          (push (cons inherit 'inherit) choices))
        (funcall callback
                 (condition-case nil
                     (cdr
                      (assoc
                       (completing-read "Agent: " choices
                                        nil
                                        t
                                        nil
                                        nil
                                        inherit)
                       choices))
                   (quit
                    nil))))))))

(defun omnigent-sessions--submit-create
    (generation fields &optional callback)
  "Create a session with FIELDS on GENERATION and notify CALLBACK."
  (unless (= generation omnigent-transport--generation)
    (user-error "Server changed during session creation"))
  (let ((managed (equal (alist-get 'host_type fields) "managed"))
        payload)
    (dolist (field fields)
      (when (and (cdr field)
                 (not
                  (memq
                   (car field)
                   (if managed
                       '(host_id workspace git)
                     '(sandbox_provider
                       sandbox_profile_id
                       sandbox_profile_revision
                       workspaces
                       initial_input)))))
        (push (cons (symbol-name (car field)) (cdr field)) payload)))
    (omnigent-transport-request
     "POST" "/v1/sessions"
     (lambda (status body)
       (funcall (or callback #'omnigent-sessions--created)
                status
                (if (and managed
                         (omnigent-transport-success-p status))
                    (omnigent-sessions--seed-sandbox-status body)
                  body)))
     payload)))

(defun omnigent-sessions--seed-sandbox-status (session)
  "Return a managed SESSION with initial provisioning status."
  (if (and (listp session)
           (stringp (alist-get 'id session))
           (not (alist-get 'sandbox_status session))
           (not (eq (alist-get 'runner_online session) t)))
      (cons '(sandbox_status (stage . "provisioning")) session)
    session))

(defun omnigent-sessions--created (status session)
  "Grow the fetch limit, refresh, and open SESSION after creation STATUS."
  (let ((success (omnigent-transport-success-p status))
        (valid
         (and (listp session) (stringp (alist-get 'id session)))))
    (when (and success
               valid
               (< omnigent-transport-session-limit 1000))
      (setq omnigent-transport-session-limit
            (1+ (max 1 omnigent-transport-session-limit))))
    (unwind-protect
        (omnigent-sessions-refresh)
      (cond
       ((not success)
        (omnigent-sessions--error "Create session" status session))
       ((not valid)
        (omnigent-sessions--error "Create session" nil
                                  "Invalid created session response"))
       (omnigent-sessions-open-hook
        (run-hook-with-args 'omnigent-sessions-open-hook session))
       (t
        (message
         "Session created; conversation view is not available yet"))))))

(defun omnigent-sessions-fork (id options callback)
  "Fork session ID with OPTIONS and call CALLBACK with status and body.
OPTIONS is an alist of server fork options, or nil for the defaults."
  (omnigent-transport--request
   id "POST"
   (concat (omnigent-transport--session-path id) "/fork") callback
   (or options (make-hash-table :test 'equal))))

(defun omnigent-sessions-launch-fork
    (id host workspace branch callback)
  "Launch fork ID on HOST in WORKSPACE and call CALLBACK with status and body.
When BRANCH is non-nil, create a worktree with that new branch."
  (omnigent-transport--request
   id
   "POST"
   (format "/v1/hosts/%s/runners" (url-hexify-string host))
   callback
   (append
    `(("session_id" . ,id) ("workspace" . ,workspace))
    (when branch
      `(("git" . (("branch_name" . ,branch))))))))

(defun omnigent-sessions-side-chat (id callback)
  "Fork a private side chat from ID and attach it to the source runner.
Call CALLBACK with (STATUS BODY).  On success, BODY is the forked session.
The source session must have a connected runner."
  (omnigent-transport--request
   id "GET"
   (concat
    (omnigent-transport--session-path id) "?include_items=false")
   (lambda (status source)
     (let ((runner
            (and (listp source) (alist-get 'runner_id source))))
       (cond
        ((not (omnigent-transport-success-p status))
         (funcall callback status source))
        ((or (eq (alist-get 'runner_online source) :json-false)
             (not
              (and (stringp runner) (not (string-empty-p runner)))))
         (funcall callback nil "Reconnect the source session first"))
        (t
         (omnigent-sessions-fork
          id '(("side_chat" . t) ("title" . "Side chat"))
          (lambda (fork-status session)
            (let ((child
                   (and (listp session) (alist-get 'id session))))
              (cond
               ((not (omnigent-transport-success-p fork-status))
                (funcall callback fork-status session))
               ((not
                 (and (stringp child) (not (string-empty-p child))))
                (funcall callback nil "Invalid side chat response"))
               (t
                (omnigent-transport--request
                 child
                 "PATCH"
                 (omnigent-transport--session-path child)
                 (lambda (bind-status body)
                   (funcall callback
                            bind-status
                            (if (omnigent-transport-success-p
                                 bind-status)
                                session
                              body)))
                 `(("runner_id" . ,runner))))))))))))))

(defun omnigent-sessions--mutate-ordered (order mutate callback)
  "Call MUTATE on each ID in ORDER, then refresh and call CALLBACK.
Stop at the first failure and pass its status and body to CALLBACK."
  (let ((session (pop order)))
    (funcall mutate
             session
             (lambda (status body)
               (if (and order (omnigent-transport-success-p status))
                   (omnigent-sessions--mutate-ordered
                    order mutate callback)
                 (unwind-protect
                     (omnigent-sessions-refresh)
                   (funcall callback status body)))))))

(defun omnigent-sessions--mutate-subtree
    (id mutate close callback &optional prepare)
  "Discover ID's subtree, then call MUTATE on each ID, descendants first.
When CLOSE is non-nil, close each successfully updated conversation.
Pass the first failure or the selected session's result to CALLBACK.
When PREPARE is supplied, pass it the ordered IDs and write continuation."
  (let ((pending (list id))
        (seen (make-hash-table :test 'equal))
        order)
    (puthash id t seen)
    (cl-labels
     ((write-next
       ()
       (omnigent-sessions--mutate-ordered
        order
        (lambda (session done)
          (funcall mutate
                   session
                   (lambda (status body)
                     (when (and close
                                (omnigent-transport-success-p status))
                       (omnigent-sessions--close-conversation
                        session))
                     (funcall done status body))))
        callback))
      (read-next
       ()
       (if pending
           (let ((session (pop pending)))
             (push session order)
             (read-page session nil))
         (if prepare
             (funcall prepare order #'write-next)
           (write-next))))
      (read-page
       (session cursors)
       (omnigent-transport-list-child-sessions
        session
        (lambda (status body)
          (cond
           ((not (omnigent-transport-success-p status))
            (funcall callback status body))
           ((not (omnigent-sessions--rows-p body 'data 'id))
            (funcall callback nil "Invalid child session list"))
           (t
            (seq-doseq (row (alist-get 'data body))
              (let ((child (alist-get 'id row)))
                (unless (gethash child seen)
                  (puthash child t seen)
                  (push child pending))))
            (if (eq (alist-get 'has_more body) t)
                (let ((cursor (alist-get 'last_id body)))
                  (if (and (stringp cursor)
                           (not (string-empty-p cursor))
                           (not (member cursor cursors)))
                      (read-page session (cons cursor cursors))
                    (funcall callback
                             nil
                             "Invalid child session pagination")))
              (read-next)))))
        (car cursors))))
     (read-next))))

(defun omnigent-sessions-toggle-archive (id callback &optional record)
  "Toggle ID's server archive state and apply it to all descendants.
CALLBACK receives the HTTP status and response body.  When RECORD is
non-nil, the success body contains the prior states of changed sessions
as an alist of session IDs and archive booleans in descendant-first order."
  (omnigent-transport-get-session
   id
   (lambda (status body)
     (cond
      ((not (omnigent-transport-success-p status))
       (funcall callback status body))
      ((not
        (and (listp body)
             (memq (alist-get 'archived body) '(t :json-false))))
       (funcall callback nil "Invalid session archive state"))
      (t
       (let ((archived (not (eq (alist-get 'archived body) t)))
             (root-state (alist-get 'archived body))
             previous)
         (cl-labels
          ((record-next
            (order write)
            (let ((session (car order)))
              (if (equal session id)
                  (progn
                    (push (cons id root-state) previous)
                    (funcall write))
                (omnigent-transport-get-session
                 session
                 (lambda (status body)
                   (cond
                    ((not (omnigent-transport-success-p status))
                     (funcall callback status body))
                    ((and (listp body)
                          (memq
                           (alist-get 'archived body)
                           '(t :json-false)))
                     (unless (eq
                              archived
                              (eq (alist-get 'archived body) t))
                       (push (cons session (alist-get 'archived body))
                             previous))
                     (record-next (cdr order) write))
                    (t
                     (funcall callback
                              nil
                              "Invalid child archive state")))))))))
          (omnigent-sessions--mutate-subtree
           id
           (lambda (session done)
             (omnigent-transport-set-session-archived
              session archived done))
           archived
           (lambda (status body)
             (funcall
              callback
              status
              (if (and record (omnigent-transport-success-p status))
                  (nreverse previous)
                body)))
           (when record
             #'record-next)))))))))

(defun omnigent-sessions-restore-archive (states callback)
  "Restore each session's prior archive state in STATES.
Pass the HTTP status and response body to CALLBACK."
  (omnigent-sessions--mutate-ordered
   states
   (lambda (entry done)
     (let ((id (car entry))
           (archived (eq (cdr entry) t)))
       (omnigent-transport-set-session-archived
        id archived
        (lambda (status body)
          (when (and archived (omnigent-transport-success-p status))
            (omnigent-sessions--close-conversation id))
          (funcall done status body)))))
   callback))

(defun omnigent-sessions-delete (id callback)
  "Delete session ID and all its descendants.
CALLBACK receives the HTTP status and response body.
The caller must obtain confirmation first."
  (omnigent-sessions--mutate-subtree
   id #'omnigent-transport-delete-session t callback))

;;; Session list presentation

(defvar omnigent-session--selected-session nil
  "ID of the most recently selected conversation for the session list.")

(defface omnigent-session-running '((t :inherit warning))
  "Face for running sessions."
  :group 'omnigent)
(defface omnigent-session-waiting
  '((t :inherit font-lock-warning-face))
  "Face for waiting sessions."
  :group 'omnigent)
(defface omnigent-session-failed '((t :inherit error))
  "Face for failed sessions."
  :group 'omnigent)
(defface omnigent-session-idle '((t :inherit default))
  "Face for idle sessions."
  :group 'omnigent)
(defface omnigent-session-archived '((t :inherit shadow))
  "Face for archived sessions."
  :group 'omnigent)
(defface omnigent-session-attention '((t :inherit warning))
  "Face for the pending elicitation marker."
  :group 'omnigent)
(defface omnigent-session-project
  '((t :inherit font-lock-keyword-face :weight normal))
  "Face for project headings."
  :group 'omnigent)

(defun omnigent-session--session-face (session)
  "Return the face for SESSION."
  (cond
   ((eq (alist-get 'archived session) t)
    'omnigent-session-archived)
   ((or (equal (alist-get 'status session) "running")
        (and (not (alist-get 'status session))
             (eq (alist-get 'busy session) t)))
    'omnigent-session-running)
   ((equal (alist-get 'status session) "waiting")
    'omnigent-session-waiting)
   ((or (equal (alist-get 'status session) "failed")
        (and (not (alist-get 'status session))
             (equal
              (alist-get 'current_task_status session) "failed")))
    'omnigent-session-failed)
   (t
    'omnigent-session-idle)))

(defun omnigent-session--session-id-at-point ()
  "Return the session ID for the session or linked PR at point."
  (let ((start (line-beginning-position)))
    (or (get-text-property start 'omnigent-session-id)
        (car (get-text-property start 'omnigent-session-resource)))))

(defvar-local omnigent-session--folded-projects nil)

(defvar-local omnigent-session--folded-sessions nil
  "Session IDs whose child rows are folded.")

(defun omnigent-session--session-pending-p (session)
  "Return non-nil if SESSION has a current pending elicitation."
  (let ((count (alist-get 'pending_elicitations_count session)))
    (and (numberp count)
         (> count 0)
         (or (not (alist-get 'parent_session_id session))
             (member
              (alist-get 'id session)
              omnigent-sessions--watched-ids)))))

(defun omnigent-session--descendant-pending-p (session)
  "Return non-nil if a descendant of SESSION has a pending elicitation."
  (seq-some
   (lambda (child)
     (or (omnigent-session--session-pending-p child)
         (omnigent-session--descendant-pending-p child)))
   (omnigent-sessions-children (alist-get 'id session))))

(defun omnigent-session--project-at-point ()
  "Return the project key on the heading at point."
  (get-text-property
   (line-beginning-position) 'omnigent-session-project))

(defun omnigent-session-render ()
  "Render the session list and preserve point on the current row."
  (when-let* ((buffer (get-buffer "*omnigent-sessions*")))
    (with-current-buffer buffer
      (let* ((resource
              (get-text-property
               (line-beginning-position) 'omnigent-session-resource))
             (id (omnigent-session--session-id-at-point))
             (project
              (or (omnigent-session--project-at-point)
                  (get-text-property
                   (line-beginning-position)
                   'omnigent-session-project-id)))
             (inhibit-read-only t)
             (sessions
              (sort (copy-sequence (omnigent-sessions-visible))
                    (lambda (a b)
                      (let ((left-archived
                             (eq (alist-get 'archived a) t))
                            (right-archived
                             (eq (alist-get 'archived b) t))
                            (left (alist-get 'updated_at a))
                            (right (alist-get 'updated_at b)))
                        (if (not (eq left-archived right-archived))
                            (not left-archived)
                          (if (and (numberp left) (numberp right))
                              (> left right)
                            (string>
                             (format "%s" (or left ""))
                             (format "%s" (or right ""))))))))))
        (erase-buffer)
        (let ((line-width
               (if-let* ((window (get-buffer-window buffer t)))
                 (window-body-width window)
                 (frame-width))))
          (let ((groups (make-hash-table :test 'equal))
                (keys
                 (mapcar
                  (lambda (row) (alist-get 'id row))
                  omnigent-sessions-projects)))
            (dolist (session sessions)
              (let ((key (omnigent-sessions-project-key session)))
                (push session (gethash key groups))
                (unless (or (eq key 'unassigned) (member key keys))
                  (setq keys (append keys (list key))))))
            (dolist (key
                     (append
                      (cl-remove-if-not
                       (lambda (key)
                         (or (gethash key groups)
                             (gethash
                              key omnigent-sessions--project-lists)))
                       keys)
                      (when (or (gethash 'unassigned groups)
                                (gethash
                                 'unassigned
                                 omnigent-sessions--project-lists))
                        '(unassigned))))
              (let ((folded
                     (member key omnigent-session--folded-projects))
                    last-session
                    (name
                     (if (eq key 'unassigned)
                         "Unassigned"
                       (or (alist-get
                            'name
                            (cl-find
                             key
                             omnigent-sessions-projects
                             :key
                             (lambda (row) (alist-get 'id row))
                             :test #'equal))
                           key))))
                (insert
                 (propertize
                  (concat
                   (if folded
                       "▸ "
                     "▾ ")
                   (if (and folded
                            (seq-some
                             #'omnigent-session--descendant-pending-p
                             (gethash key groups)))
                       (propertize "! "
                                   'face 'omnigent-session-attention)
                     "")
                   (replace-regexp-in-string "[\n\r]" " " name) "\n")
                  'omnigent-session-project
                  key
                  'face
                  'omnigent-session-project))
                (unless folded
                  (dolist (session (nreverse (gethash key groups)))
                    (setq last-session session)
                    (omnigent-session--insert-session-row
                     session line-width 1 key))
                  (when (if-let*
                            ((entry
                              (gethash
                               key omnigent-sessions--project-lists)))
                          (nth 2 entry)
                          (eq
                           (gethash
                            key omnigent-sessions--project-more)
                           t))
                    (insert
                     (propertize "  ...\n"
                                 'face
                                 (when (eq
                                        (alist-get
                                         'archived last-session)
                                        t)
                                   'omnigent-session-archived)))))))))
        (goto-char (point-min))
        (when resource
          (while (and (not (eobp))
                      (not
                       (equal
                        resource
                        (get-text-property
                         (point) 'omnigent-session-resource))))
            (forward-line 1))
          (when (eobp)
            (setq resource nil)
            (goto-char (point-min))))
        (when (and (not resource) (or id project))
          (while (and (not (eobp))
                      (not
                       (if id
                           (equal
                            id
                            (omnigent-session--session-id-at-point))
                         (equal
                          project
                          (omnigent-session--project-at-point)))))
            (forward-line 1))
          (when (eobp)
            (goto-char (point-min))
            (when project
              (while (and (not (eobp))
                          (not
                           (equal
                            project
                            (omnigent-session--project-at-point))))
                (forward-line 1))
              (when (eobp)
                (goto-char (point-min))))))))))

(defvar omnigent-session--pull-requests (make-hash-table :test 'equal)
  "Linked pull requests by session ID.")

(defun omnigent-session--session-branch-p (id)
  "Return non-nil when ID has child sessions or linked PRs."
  (or (omnigent-sessions-children id)
      (gethash id omnigent-session--pull-requests)))

(defun omnigent-session--open-resource-button (button)
  "Open the session resource represented by BUTTON."
  (save-excursion
    (goto-char (button-start button))
    (omnigent-session-open-at-point)))

(defun omnigent-session--insert-resource-row
    (id target label indent width project)
  "Insert LABEL for ID and TARGET at INDENT within WIDTH under PROJECT."
  (let ((start (point)))
    (insert (make-string indent ?\s))
    (insert-text-button (truncate-string-to-width
                         (replace-regexp-in-string "[\n\r]" " " label)
                         (max 1 (- width indent)) nil nil "…")
                        'action
                        #'omnigent-session--open-resource-button
                        'follow-link
                        t
                        'face
                        'link)
    (insert "\n")
    (add-text-properties
     start (point)
     (list
      'omnigent-session-resource
      (cons id target)
      'omnigent-session-project-id
      project))))

(defun omnigent-session--insert-session-row
    (session line-width depth project)
  "Insert SESSION and its unfolded rows within LINE-WIDTH at DEPTH in PROJECT."
  (let* ((start (point))
         (id (alist-get 'id session))
         (children (omnigent-sessions-children id))
         (branch (omnigent-session--session-branch-p id))
         (folded (member id omnigent-session--folded-sessions))
         (indent (* 2 depth))
         (pending
          (or (omnigent-session--session-pending-p session)
              (and folded
                   (omnigent-session--descendant-pending-p session))))
         (prefix-width
          (+ indent
             (if branch
                 2
               0)
             (if pending
                 2
               0)))
         (title (alist-get 'title session))
         (updated-at
          (omnigent--session-age (alist-get 'updated_at session)))
         (title
          (if (and (stringp title) (not (string-empty-p title)))
              (replace-regexp-in-string "[\n\r]" " " title)
            "Untitled")))
    (insert (make-string indent ?\s))
    (when branch
      (insert
       (if folded
           "▸ "
         "▾ ")))
    (when pending
      (insert "! "))
    (insert
     (truncate-string-to-width
      title
      (max 1
           (- line-width prefix-width
              (if updated-at
                  (+ 1 (string-width updated-at))
                0)))
      nil nil "…"))
    (when updated-at
      (insert
       (propertize " "
                   'display
                   `(space
                     :align-to (- right ,(string-width updated-at)))))
      (insert updated-at))
    (insert "\n")
    (add-text-properties
     start (point)
     (list
      'omnigent-session-id
      (alist-get 'id session)
      'omnigent-session-project-id
      project
      'face
      (omnigent-session--session-face session)))
    (when (equal
           (alist-get 'id session) omnigent-session--selected-session)
      (add-face-text-property
       (+ start prefix-width) (1- (point)) 'bold))
    (when pending
      (put-text-property
       (+ start prefix-width -2)
       (+ start prefix-width -1)
       'face
       'omnigent-session-attention))
    (unless folded
      (dolist (pr (gethash id omnigent-session--pull-requests))
        (let ((state (alist-get 'state pr)))
          (omnigent-session--insert-resource-row
           id (alist-get 'url pr)
           (concat
            (format "PR #%s" (alist-get 'number pr))
            (when state
              (format " [%s]" (downcase state))))
           (+ indent 2) line-width project)))
      (dolist (child children)
        (omnigent-session--insert-session-row
         child line-width (1+ depth) project)))))


;;; Connection and selection

(defvar omnigent-session--pull-requests-pending
  (make-hash-table :test 'equal))
(defvar omnigent-session--resource-checked
  (make-hash-table :test 'equal))

(defun omnigent-session--pull-request-page
    (id token entries &optional after)
  "Fetch ID's PR page after AFTER, accumulating ENTRIES for TOKEN."
  (omnigent-transport--request
   id "GET"
   (omnigent-transport--session-path
    id
    (concat
     "/pull-requests"
     (when after
       (concat "?after=" (url-hexify-string after)))))
   (lambda (status body)
     (when (eq
            token
            (gethash id omnigent-session--pull-requests-pending))
       (let ((data (alist-get 'data body))
             (cursor (alist-get 'last_id body)))
         (if (and (omnigent-transport-success-p status)
                  (vectorp data)
                  (eq (alist-get 'has_more body) t)
                  (stringp cursor)
                  (not (equal cursor after)))
             (omnigent-session--pull-request-page id token
                                                  (append
                                                   entries data nil)
                                                  cursor)
           (remhash id omnigent-session--pull-requests-pending)
           (when (and (omnigent-transport-success-p status)
                      (vectorp data)
                      (not (eq (alist-get 'has_more body) t)))
             (let ((prs
                    (cl-remove-if-not
                     (lambda (pr)
                       (let ((url (alist-get 'url pr)))
                         (and (stringp url)
                              (string-match-p "\\`https?://" url))))
                     (mapcar
                      (lambda (pr)
                        (mapcar
                         (lambda (key) (assq key pr))
                         '(url number state)))
                      (append entries data nil)))))
               (unless (equal
                        prs
                        (gethash id omnigent-session--pull-requests))
                 (puthash id prs omnigent-session--pull-requests)
                 (omnigent-session-render))))))))))

(defun omnigent-session--refresh-pull-requests (id)
  "Refresh ID's linked PRs unless a request is already in flight."
  (unless (gethash id omnigent-session--pull-requests-pending)
    (let ((token (make-symbol "pull-requests")))
      (puthash id token omnigent-session--pull-requests-pending)
      (condition-case nil
          (omnigent-session--pull-request-page id token nil)
        (error
         (remhash id omnigent-session--pull-requests-pending))))))

(defun omnigent-session--refresh-resources (&optional force)
  "Refresh resources for sessions in the open sidebar, immediately if FORCE."
  (when (get-buffer-window "*omnigent-sessions*" t)
    (let ((now (float-time)))
      (cl-labels
       ((visit
         (row)
         (let* ((id (alist-get 'id row))
                (checked
                 (gethash id omnigent-session--resource-checked 0)))
           (when (or force (>= (- now checked) 30))
             (puthash id now omnigent-session--resource-checked)
             (omnigent-session--refresh-pull-requests id))
           (mapc #'visit (omnigent-sessions-children id)))))
       (mapc #'visit (omnigent-sessions-visible))))))

(add-hook 'omnigent-sessions-change-hook #'omnigent-session-render)
(add-hook
 'omnigent-sessions-change-hook #'omnigent-session--refresh-resources)

(provide 'omnigent-sessions)
;;; omnigent-sessions.el ends here
