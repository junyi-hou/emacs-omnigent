;;; omnigent-sessions.el --- Session list state -*- lexical-binding: t; -*-

;;; Commentary:
;; Session list state and server actions.  Presentation and conversation
;; buffers are separate components.

;;; Code:

(require 'cl-lib)
(require 'omnigent-transport)

(defvar omnigent-sessions nil
  "List of root session alists from the server.")
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
                      (omnigent-transport-error-message action status body)))

(defun omnigent-sessions--rows-p (body key &rest fields)
  "Return non-nil if BODY has an array at KEY with string FIELDS in each row."
  (and (listp body)
       (vectorp (alist-get key body))
       (cl-every (lambda (row)
                   (and (listp row)
                        (cl-every (lambda (field) (stringp (alist-get field row))) fields)))
                 (alist-get key body))))

(defun omnigent-sessions-refresh ()
  "Request the root session list asynchronously.
Run `omnigent-sessions-change-hook' on success, or the error hook on failure."
  (interactive)
  (let ((number (cl-incf omnigent-sessions--refresh-number))
        (revision omnigent-sessions--revision))
    (omnigent-transport-list-sessions
     (apply-partially #'omnigent-sessions--refreshed number revision))))

(defun omnigent-sessions--refreshed (number revision status body)
  "Apply list BODY for refresh NUMBER and REVISION when STATUS succeeds."
  (when (= number omnigent-sessions--refresh-number)
    (cond
     ((not (omnigent-transport-success-p status))
      (omnigent-sessions--error "List sessions" status body))
     ((/= revision omnigent-sessions--revision)
      (omnigent-sessions-refresh))
     ((not (omnigent-sessions--rows-p body 'data 'id))
      (omnigent-sessions--error "List sessions" nil "Invalid session list response"))
     (t
      (let ((rows (append (alist-get 'data body) nil)))
        (dolist (entry omnigent-sessions--buffers)
          (when (and (buffer-live-p (cdr entry))
                     (not (cl-find (car entry) rows :key (lambda (row) (alist-get 'id row))
                                   :test #'equal)))
            (when-let* ((old (cl-find (car entry) omnigent-sessions
                                     :key (lambda (row) (alist-get 'id row)) :test #'equal)))
              (push old rows))))
        (setq omnigent-sessions
              (cl-remove-if (lambda (row) (alist-get 'parent_session_id row)) rows)))
      (setq omnigent-sessions-truncated (eq (alist-get 'has_more body) t))
      (run-hooks 'omnigent-sessions-change-hook)))))

(defun omnigent-sessions--frame (frame)
  "Apply session update FRAME and notify the session hooks.
Refresh the list if FRAME contains a session that is not in the list."
  (let ((type (alist-get 'type frame)) unknown)
    (cond
     ((member type '("snapshot" "changed"))
      (dolist (item (append (alist-get 'items frame) nil))
        (let* ((id (alist-get 'id item))
               (old (cl-find id omnigent-sessions :key (lambda (row) (alist-get 'id row))
                             :test #'equal)))
          (if old
              (setq omnigent-sessions (mapcar (lambda (row) (if (eq row old) item row))
                                               omnigent-sessions))
            (when (and (omnigent-sessions-buffer id)
                       (not (alist-get 'parent_session_id item)))
              (push item omnigent-sessions))
            (setq unknown t)))))
     ((equal type "removed")
      (let ((ids (append (alist-get 'ids frame) nil)))
        (setq omnigent-sessions
              (cl-remove-if (lambda (row) (member (alist-get 'id row) ids))
                            omnigent-sessions)))))
    (when (member type '("snapshot" "changed" "removed"))
      (cl-incf omnigent-sessions--revision))
    (run-hook-with-args 'omnigent-sessions-frame-hook frame)
    (unless (equal type "heartbeat")
      (run-hooks 'omnigent-sessions-change-hook))
    (when unknown (omnigent-sessions-refresh))))

(defun omnigent-sessions--watch ()
  "Remove dead buffers and update the watched session IDs."
  (setq omnigent-sessions--buffers
        (cl-remove-if-not (lambda (entry) (buffer-live-p (cdr entry)))
                          omnigent-sessions--buffers))
  (when omnigent-sessions-updates
    (omnigent-transport-set-session-updates-watch
     omnigent-sessions-updates (mapcar #'car omnigent-sessions--buffers))))

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
      (setq omnigent-sessions--buffers (delq existing omnigent-sessions--buffers)
            existing nil))
    (when (and existing (not (eq buffer (cdr existing))))
      (user-error "Session already has a conversation buffer"))
    (unless existing
      (omnigent-sessions--watch)
      (when (>= (length omnigent-sessions--buffers) 500)
        (user-error "Cannot open another session: the watch limit is 500"))
      (push (cons id buffer) omnigent-sessions--buffers)
      (with-current-buffer buffer
        (add-hook 'kill-buffer-hook #'omnigent-sessions--buffer-killed nil t))
      (omnigent-sessions--watch))))

(defun omnigent-sessions--buffer-killed ()
  "Remove the current buffer's registration and update the watch set."
  (setq omnigent-sessions--buffers
        (cl-remove (current-buffer) omnigent-sessions--buffers :key #'cdr))
  (omnigent-sessions--watch))

(defun omnigent-sessions-reset ()
  "Forget state from the current server."
  (cl-incf omnigent-sessions--refresh-number)
  (when omnigent-sessions-updates
    (omnigent-transport-stop-session-updates omnigent-sessions-updates))
  (setq omnigent-sessions nil omnigent-sessions-truncated nil
        omnigent-sessions-updates nil omnigent-sessions--buffers nil))

(defun omnigent-sessions-start ()
  "Start the session update connection and load the list."
  (setq omnigent-sessions-updates
        (omnigent-transport-start-session-updates
         #'omnigent-sessions--frame
         (lambda (error) (omnigent-sessions--error "Session updates" error))
         #'omnigent-sessions-refresh))
  (omnigent-sessions-refresh))

(defun omnigent-sessions--filesystem-path (host-id path &optional after)
  "Build the filesystem request for HOST-ID, PATH, and pagination cursor AFTER."
  (let* ((base (concat "/v1/hosts/" (url-hexify-string host-id) "/filesystem"))
         (windows (or (string-match-p "\\`[[:alpha:]]:[/\\\\]" path)
                      (string-prefix-p "\\\\" path)))
         (native (if windows (subst-char-in-string ?\\ ?/ path)
                   (string-remove-prefix "/" path))))
    (concat base
            (unless (string-empty-p path)
              (concat "/" (mapconcat #'url-hexify-string (split-string native "/") "/")))
            "?limit=1000"
            (when after (concat "&after=" (url-hexify-string after))))))

(defun omnigent-sessions--workspace-directories (host-id path callback &optional after directories)
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
                 (funcall callback nil "Invalid filesystem pagination")
               (omnigent-sessions--workspace-directories host-id path callback cursor directories))
           (funcall callback status (nreverse directories)))))))))

(defun omnigent-sessions--native-workspace (input)
  "Interpret INPUT on the execution host, never relative to Emacs's directory."
  (when (or (string-empty-p input) (file-remote-p input) (string-match-p "\0" input))
    (user-error "Choose a directory path on the execution host, not a TRAMP path"))
  (if (or (string-prefix-p "/" input) (string-prefix-p "~" input)
          (string-prefix-p "\\\\" input)
          (string-match-p "\\`[[:alpha:]]:[/\\\\]" input))
      input
    (concat "~/" input)))

(defun omnigent-sessions--read-workspace (callback)
  "Select a host and workspace asynchronously, then call CALLBACK with their cons.
Use the sole online host, or prompt when several hosts are online.
Report discovery failures through `omnigent-sessions-error-hook'."
  (message "Reading execution hosts...")
  (omnigent-transport-request
   "GET" "/v1/hosts"
   (apply-partially #'omnigent-sessions--select-host
                    omnigent-transport--generation callback)))

(defun omnigent-sessions--select-host (generation callback status body)
  "Present hosts from BODY for GENERATION and continue through CALLBACK."
  (cond
   ((not (omnigent-transport-success-p status))
    (omnigent-sessions--error "List hosts" status body))
   ((not (omnigent-sessions--rows-p body 'hosts 'host_id 'status))
    (omnigent-sessions--error "List hosts" nil "Invalid execution host response"))
   (t
    (let* ((hosts (cl-remove-if-not
                   (lambda (host) (equal (alist-get 'status host) "online"))
                   (append (alist-get 'hosts body) nil)))
           (choices (mapcar (lambda (host)
                              (cons (format "%s [%s]" (or (alist-get 'name host) "Host")
                                            (alist-get 'host_id host))
                                    (alist-get 'host_id host))) hosts)))
      (if (null choices)
          (omnigent-sessions--error "Select workspace" "No online execution hosts")
        (let* ((choice (if (cdr choices)
                           (completing-read "Execution host: " choices nil t)
                         (caar choices)))
               (host-id (cdr (assoc choice choices))))
          (unless (= generation omnigent-transport--generation)
            (user-error "Server changed during workspace selection"))
          (message "Reading workspaces on %s..." choice)
          (omnigent-sessions--workspace-directories
           host-id ""
           (apply-partially #'omnigent-sessions--select-workspace
                            generation host-id choice callback))))))))

(defun omnigent-sessions--select-workspace (generation host-id choice callback status directories)
  "Prompt with DIRECTORIES for HOST-ID and CHOICE after successful STATUS.
Continue through CALLBACK after validating the path on GENERATION's server."
  (if (not (omnigent-transport-success-p status))
      (omnigent-sessions--error "List workspaces" status directories)
    (let ((cache (make-hash-table :test #'equal)) (active t) workspace)
      (puthash "" directories cache)
      (unwind-protect
          (setq workspace
                (omnigent-sessions--native-workspace
                 (completing-read
                  (format "Workspace on %s: " choice)
                  (lambda (input predicate action)
                    (unless (= generation omnigent-transport--generation)
                      (user-error "Server changed during workspace selection"))
                    (if (eq action 'metadata)
                        '(metadata (category . omnigent-workspace))
                      (let ((parent (or (file-name-directory input) ""))
                            (minibuffer (when-let* ((window (active-minibuffer-window)))
                                          (window-buffer window))))
                        (when (eq (gethash parent cache 'missing) 'missing)
                          (puthash parent 'pending cache)
                          (message "Reading directories...")
                          (omnigent-sessions--workspace-directories
                           host-id (if (string-empty-p parent) ""
                                     (omnigent-sessions--native-workspace parent))
                           (lambda (directory-status entries)
                             (when active
                               (if (not (omnigent-transport-success-p directory-status))
                                   (progn
                                     (remhash parent cache)
                                     (omnigent-sessions--error "List directories"
                                                               directory-status entries))
                                 (puthash parent entries cache)
                                 (when-let* ((window (active-minibuffer-window))
                                             ((eq (window-buffer window) minibuffer)))
                                   (with-selected-window window
                                     (when (equal parent (or (file-name-directory
                                                              (minibuffer-contents-no-properties)) ""))
                                       (minibuffer-complete)))))))))
                        (let ((entries (gethash parent cache)))
                          (complete-with-action
                           action (cons (if (string-empty-p parent) "~/" parent)
                                        (unless (eq entries 'pending)
                                          (mapcar (lambda (entry)
                                                    (concat parent (alist-get 'name entry) "/")) entries)))
                           input predicate)))))
                  nil nil nil t)))
        (setq active nil))
      (unless (= generation omnigent-transport--generation)
        (user-error "Server changed during workspace selection"))
      (message "Checking workspace %s..." workspace)
      ;; A fresh listing validates typed paths, including empty directories.
      (omnigent-transport-request
       "GET" (omnigent-sessions--filesystem-path host-id workspace)
       (lambda (check-status body)
         (cond
          ((not (omnigent-transport-success-p check-status))
           (omnigent-sessions--error "Check workspace" check-status body))
          ((not (omnigent-sessions--rows-p body 'data 'name 'path 'type))
           (omnigent-sessions--error "Check workspace" nil "Invalid filesystem listing response"))
          (t (funcall callback (cons host-id workspace)))))))))

;;;###autoload
(defun omnigent-sessions-create ()
  "Create a session with asynchronously fetched host, workspace, and agent choices.
Prompt for a workspace and optional title without a default workspace.
Report failures through `omnigent-sessions-error-hook'."
  (interactive)
  (omnigent-sessions--read-workspace
   (apply-partially #'omnigent-sessions--workspace-selected omnigent-transport--generation)))

(defun omnigent-sessions--workspace-selected (generation target)
  "Fetch agents for GENERATION after the user selects workspace TARGET."
  (message "Reading agents...")
  (omnigent-transport-request
   "GET" "/v1/agents"
   (apply-partially #'omnigent-sessions--select-agent generation target)))

(defun omnigent-sessions--select-agent (generation target status body)
  "Present agents from BODY and create a session on GENERATION at TARGET."
  (cond
   ((not (omnigent-transport-success-p status))
    (omnigent-sessions--error "List agents" status body))
   ((not (omnigent-sessions--rows-p body 'data 'id 'name))
    (omnigent-sessions--error "List agents" nil "Invalid agent list response"))
   (t
    (let* ((agents (append (alist-get 'data body) nil))
           (choices (mapcar (lambda (agent)
                              (cons (format "%s [%s]" (alist-get 'name agent)
                                            (alist-get 'id agent))
                                    (alist-get 'id agent))) agents)))
      (if (null choices)
          (omnigent-sessions--error "Create session" "No agents available")
        (let* ((choice (completing-read "Agent: " choices nil t))
               (title (read-string "Title (optional): "))
               (data `(("agent_id" . ,(cdr (assoc choice choices)))
                       ("host_id" . ,(car target))
                       ("workspace" . ,(cdr target)))))
          (unless (string-empty-p title)
            (push (cons "title" title) data))
          (unless (= generation omnigent-transport--generation)
            (user-error "Server changed during session creation"))
          (message "Creating session...")
          (omnigent-transport-request "POST" "/v1/sessions" #'omnigent-sessions--created data)))))))

(defun omnigent-sessions--created (status session)
  "Refresh sessions and open SESSION after successful creation STATUS."
  (unwind-protect (omnigent-sessions-refresh)
    (cond
     ((not (omnigent-transport-success-p status))
      (omnigent-sessions--error "Create session" status session))
     ((not (and (listp session) (stringp (alist-get 'id session))))
      (omnigent-sessions--error "Create session" nil "Invalid created session response"))
     (omnigent-sessions-open-hook
      (run-hook-with-args 'omnigent-sessions-open-hook session))
     (t (message "Session created; conversation view is not available yet")))))

(defun omnigent-sessions-action (id type callback)
  "Send event TYPE for session ID and invoke CALLBACK with the result.
CALLBACK receives the HTTP status and response body.  Refresh the session list
after the request completes."
  (omnigent-transport-post-session-event
   id `(("type" . ,type))
   (lambda (status body)
     (unwind-protect (omnigent-sessions-refresh)
       (funcall callback status body)))))

(defun omnigent-sessions-delete (id callback)
  "Delete session ID and invoke CALLBACK with the result.
CALLBACK receives the HTTP status and response body.  Refresh the session list
after the request completes.  The caller must obtain confirmation first."
  (omnigent-transport-delete-session
   id (lambda (status body)
        (unwind-protect (omnigent-sessions-refresh)
          (funcall callback status body)))))

(provide 'omnigent-sessions)
;;; omnigent-sessions.el ends here
