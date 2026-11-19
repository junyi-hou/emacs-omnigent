;;; omnigent-sessions.el --- Session list state -*- lexical-binding: t; -*-

;;; Commentary:
;; Session list state and server actions.  Presentation and conversation
;; buffers are separate components.

;;; Code:

(require 'cl-lib)
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

(defun omnigent-sessions-project-key (session)
  "Return SESSION's project ID or the symbol unassigned."
  (or (alist-get 'project_id session) 'unassigned))

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
                    (equal key (omnigent-sessions-project-key row)))
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
      (omnigent-sessions-refresh-projects)
      (run-hooks 'omnigent-sessions-change-hook)
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
               (old
                (cl-find
                 id
                 omnigent-sessions
                 :key (lambda (row) (alist-get 'id row))
                 :test #'equal)))
          (if old
              (setq omnigent-sessions
                    (mapcar
                     (lambda (row)
                       (if (eq row old)
                           item
                         row))
                     omnigent-sessions))
            (when (and (omnigent-sessions-buffer id)
                       (not (alist-get 'parent_session_id item)))
              (push item omnigent-sessions))
            (setq unknown t)))))
     ((equal type "removed")
      (let ((ids (append (alist-get 'ids frame) nil)))
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
  (when omnigent-sessions-updates
    (omnigent-transport-set-session-updates-watch
     omnigent-sessions-updates
     (mapcar #'car omnigent-sessions--buffers))))

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
  (setq omnigent-sessions--buffers
        (cl-remove
         (current-buffer)
         omnigent-sessions--buffers
         :key #'cdr))
  (omnigent-sessions--watch))

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
             (omnigent-sessions-show-project body))))))))

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

(defun omnigent-sessions-move (id project-id)
  "Move session ID to PROJECT-ID.  An empty string unassigns it."
  (omnigent-transport--request
   id "PATCH" (omnigent-transport--session-path id)
   (lambda (status body)
     (if (omnigent-transport-success-p status)
         (omnigent-sessions-refresh)
       (omnigent-sessions--error "Move session" status body)))
   `(("project_id" . ,project-id))))

(defun omnigent-sessions-reset ()
  "Forget state from the current server."
  (cl-incf omnigent-sessions--refresh-number)
  (clrhash omnigent-sessions--pending-projects)
  (setq
   omnigent-sessions-projects nil
   omnigent-sessions--project-catalog nil)
  (clrhash omnigent-sessions--project-lists)
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

(defun omnigent-sessions--select-host
    (generation
     callback
     session
     status
     body
     &optional
     fixed-host
     fixed-workspace)
  "Present hosts from BODY after STATUS and call CALLBACK on GENERATION.
Use SESSION for context and retain FIXED-HOST and FIXED-WORKSPACE."
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
           "Select workspace" "No online execution hosts")
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
            (if fixed-workspace
                (funcall callback (cons host-id fixed-workspace))
              (message "Reading workspaces on %s..." choice)
              (omnigent-sessions--workspace-directories
               host-id ""
               (apply-partially
                #'omnigent-sessions--select-workspace
                generation host-id choice callback
                (and (equal host-id (alist-get 'host_id session))
                     (alist-get 'workspace session))))))))))))

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
    (generation callback &optional inherit)
  "Read an agent on GENERATION and pass its ID to CALLBACK.
When INHERIT is a label, offer it and pass the symbol inherit if selected."
  (omnigent-transport-request
   "GET" "/v1/agents"
   (apply-partially #'omnigent-sessions--select-agent
                    generation callback inherit)))

(defun omnigent-sessions--select-agent
    (generation callback inherit status body)
  "Read an agent from BODY after STATUS on GENERATION, with optional INHERIT choice."
  (unless (= generation omnigent-transport--generation)
    (user-error "Server changed during session creation"))
  (cond
   ((not (omnigent-transport-success-p status))
    (omnigent-sessions--error "List agents" status body))
   ((not (omnigent-sessions--rows-p body 'data 'id 'name))
    (omnigent-sessions--error "List agents" nil
                              "Invalid agent list response"))
   ((and (not inherit) (zerop (length (alist-get 'data body))))
    (omnigent-sessions--error "Create session" "No agents available"))
   (t
    (let ((choices
           (mapcar
            (lambda (agent)
              (let ((id (alist-get 'id agent)))
                (cons
                 (format "%s [%s]" (alist-get 'name agent) id) id)))
            (alist-get 'data body))))
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
                  nil)))))))

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
  "Refresh sessions and open SESSION after successful creation STATUS."
  (unwind-protect
      (omnigent-sessions-refresh)
    (cond
     ((not (omnigent-transport-success-p status))
      (omnigent-sessions--error "Create session" status session))
     ((not (and (listp session) (stringp (alist-get 'id session))))
      (omnigent-sessions--error "Create session" nil
                                "Invalid created session response"))
     (omnigent-sessions-open-hook
      (run-hook-with-args 'omnigent-sessions-open-hook session))
     (t
      (message
       "Session created; conversation view is not available yet")))))

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

(defun omnigent-sessions-toggle-archive (id callback)
  "Toggle ID's current server archive state and invoke CALLBACK with the result.
CALLBACK receives the HTTP status and response body.  Refresh the session list
after the update completes."
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
       (omnigent-transport-set-session-archived
        id (not (eq (alist-get 'archived body) t))
        (lambda (update-status update-body)
          (when (and (omnigent-transport-success-p update-status)
                     (not (eq (alist-get 'archived body) t)))
            (omnigent-sessions--close-conversation id))
          (unwind-protect
              (omnigent-sessions-refresh)
            (funcall callback update-status update-body)))))))))

(defun omnigent-sessions-delete (id callback)
  "Delete session ID and invoke CALLBACK with the result.
CALLBACK receives the HTTP status and response body.  Refresh the session list
after the request completes.  The caller must obtain confirmation first."
  (omnigent-transport-delete-session
   id
   (lambda (status body)
     (when (omnigent-transport-success-p status)
       (omnigent-sessions--close-conversation id))
     (unwind-protect
         (omnigent-sessions-refresh)
       (funcall callback status body)))))

(provide 'omnigent-sessions)
;;; omnigent-sessions.el ends here
