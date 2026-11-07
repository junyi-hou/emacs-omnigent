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

(defun omnigent-sessions--success-p (status)
  "Return non-nil when STATUS is a successful HTTP status code."
  (and (integerp status) (<= 200 status) (< status 300)))

(defun omnigent-sessions--error (action status)
  "Report the failure of ACTION with STATUS to the error hook."
  (run-hook-with-args 'omnigent-sessions-error-hook
                      (format "%s: %s" action status)))

(defun omnigent-sessions-refresh ()
  "Request the root session list asynchronously.
Run `omnigent-sessions-change-hook' on success, or the error hook on failure."
  (interactive)
  (let ((number (cl-incf omnigent-sessions--refresh-number))
        (revision omnigent-sessions--revision))
    (omnigent-transport-list-sessions
     (lambda (status body)
       (when (= number omnigent-sessions--refresh-number)
         (if (and (omnigent-sessions--success-p status)
                  (/= revision omnigent-sessions--revision))
             (omnigent-sessions-refresh)
           (if (omnigent-sessions--success-p status)
             (progn
               (setq omnigent-sessions
                     (cl-remove-if (lambda (row) (alist-get 'parent_session_id row))
                                   (append (alist-get 'data body) nil))
                     omnigent-sessions-truncated (eq (alist-get 'has_more body) t))
               (run-hooks 'omnigent-sessions-change-hook))
           (omnigent-sessions--error "List sessions" status))))))))

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

(defun omnigent-sessions--workspace-get (path)
  "Read PATH from the connected server while allowing process output and quit."
  (let ((generation omnigent-transport--generation) result)
    (omnigent-transport-request
     "GET" path (lambda (status body) (setq result (cons status body))))
    (with-timeout (30 (user-error "Timed out reading %s" path))
      (while (and (not result) (= generation omnigent-transport--generation))
        (accept-process-output nil 0.05)))
    (unless (= generation omnigent-transport--generation)
      (user-error "Server changed during workspace selection"))
    (unless (omnigent-sessions--success-p (car result))
      (user-error "Read %s: %s%s" path (car result)
                  (let ((detail (and (listp (cdr result)) (alist-get 'detail (cdr result)))))
                    (if detail (format " (%s)" detail) ""))))
    (cdr result)))

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

(defun omnigent-sessions--workspace-directories (host-id path)
  "List directories at PATH on HOST-ID, following every page."
  (let ((more t) directories after)
    ;; ponytail: fetch full listings; use incremental completion if large directories are slow.
    (while more
      (let* ((body (omnigent-sessions--workspace-get
                    (omnigent-sessions--filesystem-path host-id path after)))
             (entries (append (alist-get 'data body) nil))
             (cursor (alist-get 'path (car (last entries)))))
        (dolist (entry entries)
          (when (equal (alist-get 'type entry) "directory")
            (push entry directories)))
        (setq more (eq (alist-get 'has_more body) t))
        (when (and more (or (null cursor) (equal cursor after)))
          (user-error "Invalid filesystem pagination for %s" path))
        (setq after cursor)))
    (nreverse directories)))

(defun omnigent-sessions--native-workspace (input)
  "Interpret INPUT on the execution host, never relative to Emacs's directory."
  (when (or (string-empty-p input) (file-remote-p input) (string-match-p "\0" input))
    (user-error "Choose a directory path on the execution host, not a TRAMP path"))
  (if (or (string-prefix-p "/" input) (string-prefix-p "~" input)
          (string-prefix-p "\\\\" input)
          (string-match-p "\\`[[:alpha:]]:[/\\\\]" input))
      input
    (concat "~/" input)))

(defun omnigent-sessions--read-workspace ()
  "Return (HOST-ID . WORKSPACE) selected through the connected server.
Use the sole online host, or prompt when several hosts are online.  Always
prompt for a directory, with completion against that host's filesystem.
The empty input has no default.  Relative input refers to the host's home."
  (let* ((generation omnigent-transport--generation)
         (body (omnigent-sessions--workspace-get "/v1/hosts"))
         (hosts (cl-remove-if-not
                 (lambda (host) (equal (alist-get 'status host) "online"))
                 (append (alist-get 'hosts body) nil)))
         (choices (mapcar (lambda (host)
                            (cons (format "%s [%s]" (or (alist-get 'name host) "Host")
                                          (alist-get 'host_id host))
                                  (alist-get 'host_id host))) hosts)))
    (unless choices
      (user-error "No online execution hosts; connect a host to this server first"))
    (let* ((choice (if (cdr choices)
                       (completing-read "Execution host: " choices nil t)
                     (caar choices)))
           (host-id (cdr (assoc choice choices)))
           (cache (make-hash-table :test #'equal))
           (table
            (lambda (input predicate action)
              (unless (= generation omnigent-transport--generation)
                (user-error "Server changed during workspace selection"))
              (if (eq action 'metadata)
                  '(metadata (category . omnigent-workspace))
                (let* ((parent (or (file-name-directory input) ""))
                       (entries (gethash parent cache 'missing)))
                  (when (eq entries 'missing)
                    (setq entries (omnigent-sessions--workspace-directories
                                   host-id (if (string-empty-p parent) ""
                                             (omnigent-sessions--native-workspace parent))))
                    (puthash parent entries cache))
                  (complete-with-action
                   action (cons (if (string-empty-p parent) "~/" parent)
                                (mapcar (lambda (entry)
                                          (concat parent (alist-get 'name entry) "/")) entries))
                   input predicate)))))
           (workspace (omnigent-sessions--native-workspace
                       (completing-read (format "Workspace on %s: " choice)
                                        table nil nil nil t))))
      (unless (= generation omnigent-transport--generation)
        (user-error "Server changed during workspace selection"))
      ;; A fresh listing validates typed paths, including empty directories.
      (omnigent-sessions--workspace-get (omnigent-sessions--filesystem-path host-id workspace))
      (cons host-id workspace))))

;;;###autoload
(defun omnigent-sessions-create ()
  "Create a session on the connected server, regardless of who started it.
Select an online execution host and a workspace through the server, then
prompt for an agent and optional title.  No workspace default or prefix
argument is used."
  (interactive)
  (let* ((generation omnigent-transport--generation)
         (target (omnigent-sessions--read-workspace))
         (host-id (car target))
         (workspace (cdr target)))
    (omnigent-transport-request
     "GET" "/v1/agents"
     (lambda (status body)
       (if (not (omnigent-sessions--success-p status))
           (omnigent-sessions--error "List agents" status)
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
                            ("host_id" . ,host-id)
                            ("workspace" . ,workspace))))
               (unless (string-empty-p title)
                 (push (cons "title" title) data))
               (unless (= generation omnigent-transport--generation)
                 (user-error "Server changed during session creation"))
               (omnigent-transport-request
                "POST" "/v1/sessions"
                (lambda (create-status session)
                  (omnigent-sessions-refresh)
                  (if (omnigent-sessions--success-p create-status)
                      (if omnigent-sessions-open-hook
                          (run-hook-with-args 'omnigent-sessions-open-hook session)
                        (message "Session created; conversation view is not available yet"))
                    (omnigent-sessions--error "Create session" create-status)))
                data)))))))))

(defun omnigent-sessions-action (id type callback)
  "Send event TYPE for session ID and invoke CALLBACK with the result.
CALLBACK receives the HTTP status and response body.  Refresh the session list
after the request completes."
  (omnigent-transport-post-session-event
   id `(("type" . ,type))
   (lambda (status body)
     (omnigent-sessions-refresh)
     (funcall callback status body))))

(defun omnigent-sessions-delete (id callback)
  "Delete session ID and invoke CALLBACK with the result.
CALLBACK receives the HTTP status and response body.  Refresh the session list
after the request completes.  The caller must obtain confirmation first."
  (omnigent-transport-delete-session
   id (lambda (status body)
        (omnigent-sessions-refresh)
        (funcall callback status body))))

(provide 'omnigent-sessions)
;;; omnigent-sessions.el ends here
