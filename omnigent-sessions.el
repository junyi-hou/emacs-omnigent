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

;;;###autoload
(defun omnigent-sessions-create ()
  "Prompt for an agent and title, then create a session."
  (interactive)
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
                  (data `(("agent_id" . ,(cdr (assoc choice choices))))))
             (unless (string-empty-p title)
               (push (cons "title" title) data))
             (omnigent-transport-request
              "POST" "/v1/sessions"
              (lambda (create-status session)
                (omnigent-sessions-refresh)
                (if (omnigent-sessions--success-p create-status)
                    (if omnigent-sessions-open-hook
                        (run-hook-with-args 'omnigent-sessions-open-hook session)
                      (message "Session created; conversation view is not available yet"))
                  (omnigent-sessions--error "Create session" create-status)))
              data))))))))

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
