;;; omnigent.el --- Omnigent for Emacs -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1") (websocket "1.16"))

;;; Commentary:
;; Start or connect to an Omnigent server.

;;; Code:

(require 'subr-x)
(require 'omnigent-transport)
(require 'omnigent-sessions)
(require 'omnigent-ui)

(add-hook 'omnigent-sessions-open-hook #'omnigent-ui-created)

(defgroup omnigent nil
  "Interact with Omnigent servers."
  :group 'applications)

(defcustom omnigent-executable
  (let ((local (expand-file-name
                ".venv/bin/omnigent"
                (file-name-directory (or load-file-name buffer-file-name)))))
    (if (file-executable-p local) local "omnigent"))
  "Omnigent CLI executable used to start the local server.
Use the project's local executable when available, or search `exec-path'."
  :type 'file
  :group 'omnigent)

(defvar omnigent-start-process nil
  "CLI process that is starting the local Omnigent server.")

;;;###autoload
(defun omnigent-connect (url)
  "Select the Omnigent server at URL.
URL must start with http:// or https://.  Close conversation buffers and
reset session and transport state before selecting the server."
  (interactive (list (read-string "Omnigent server URL: " omnigent-server-url)))
  (unless (string-match-p "\\`https?://" url)
    (user-error "Server URL must start with http:// or https://"))
  (mapc (lambda (entry)
          (when (buffer-live-p (cdr entry)) (kill-buffer (cdr entry))))
        (copy-sequence omnigent-sessions--buffers))
  (omnigent-sessions-reset)
  (omnigent-transport-reset)
  (omnigent-ui-reset)
  (setq omnigent-server-url (string-remove-suffix "/" url))
  (omnigent-ui-start)
  (message "Using Omnigent server %s" omnigent-server-url))

;;;###autoload
(defun omnigent-disconnect ()
  "Disconnect from the server and close its conversation and workspace buffers.
Unsent drafts are lost, but agents continue to run on their execution hosts."
  (interactive)
  (mapc (lambda (entry)
          (when (buffer-live-p (cdr entry)) (kill-buffer (cdr entry))))
        (copy-sequence omnigent-sessions--buffers))
  (omnigent-sessions-reset)
  (omnigent-transport-reset)
  (omnigent-ui-reset)
  (message "Disconnected from Omnigent"))

(defun omnigent--server-url-from-output (buffer)
  "Return the first HTTP URL in BUFFER, or nil if none exists."
  (with-current-buffer buffer
    (goto-char (point-min))
    (when (re-search-forward "https?://[^[:space:]]+" nil t)
      (match-string-no-properties 0))))

(defun omnigent--start-server-sentinel (process _event)
  "Select the local server URL when startup PROCESS exits successfully.
Report a startup failure otherwise.  Ignore _EVENT."
  (when (memq (process-status process) '(exit signal))
    (when (eq process omnigent-start-process)
      (setq omnigent-start-process nil))
    (let* ((buffer (process-buffer process))
           (url (and (= (process-exit-status process) 0)
                     (buffer-live-p buffer)
                     (omnigent--server-url-from-output buffer))))
      (if url
          (progn
            (kill-buffer buffer)
            (omnigent-connect url))
        (message "Omnigent startup failed; see %s"
                 (if (buffer-live-p buffer) (buffer-name buffer) "process output"))))))

;;;###autoload
(defun omnigent-start-server ()
  "Start or reuse the local Omnigent server and local execution host.
Select the server URL.  Session creation discovers hosts through the server.
The CLI runs asynchronously; saved remote-server defaults are not used."
  (interactive)
  (if (process-live-p omnigent-start-process)
      (message "Omnigent server startup is already in progress")
    (let ((executable (executable-find omnigent-executable))
          (buffer (get-buffer-create "*Omnigent Server Startup*"))
          (default-directory temporary-file-directory))
      (unless executable
        (user-error "Cannot find Omnigent CLI: %s" omnigent-executable))
      (with-current-buffer buffer
        (erase-buffer))
      (setq omnigent-start-process
            (make-process
             :name "omnigent-server-start"
             :buffer buffer
             :stderr buffer
             :command (list executable "host" "--server" "" "--background"
                            "--no-open" "--non-interactive")
             :connection-type 'pipe
             :noquery t
             :sentinel #'omnigent--start-server-sentinel))
      (message "Starting or reusing the local Omnigent server..."))))

(defun omnigent-sessions-refresh ()
  "Request the root session list asynchronously.
Run `omnigent-sessions-change-hook' on success, or the error hook on failure."
  (interactive)
  (let ((number (cl-incf omnigent-sessions--refresh-number))
        (revision omnigent-sessions--revision))
    (omnigent-transport-list-sessions
     (apply-partially #'omnigent-sessions--refreshed number revision))))

;;;###autoload
(defun omnigent-sessions-create ()
  "Create a session with asynchronously fetched host, workspace, and agent choices.
Prompt for a workspace and optional title without a default workspace.
Report failures through `omnigent-sessions-error-hook'."
  (interactive)
  (omnigent-sessions--read-workspace
   (apply-partially #'omnigent-sessions--workspace-selected omnigent-transport--generation)))

(define-derived-mode omnigent-conversation-mode text-mode "Omnigent"
  "Major mode for a conversation transcript and composer.
Use `omnigent-conversation-open' to create a conversation buffer."
  (unless omnigent-conversation--session-id
    (error "A session ID is required"))
  (setq omnigent-conversation-session-id omnigent-conversation--session-id
        omnigent-conversation--items (make-hash-table :test 'equal)
        omnigent-conversation--elicitations (make-hash-table :test 'equal)
        omnigent-conversation--elicitation-drafts (make-hash-table :test 'equal)
        omnigent-conversation--elicitation-submitting (make-hash-table :test 'equal)
        omnigent-conversation--loading t
        omnigent-conversation--prompt-start (copy-marker (point-min))
        omnigent-conversation--prompt-end (copy-marker (point-max) t))
  (add-hook 'kill-buffer-hook #'omnigent-conversation--close nil t)
  (let ((buffer (current-buffer)))
    (setq omnigent-conversation--stream
          (omnigent-transport-start-session-stream
           omnigent-conversation-session-id
           (lambda (name data) (when (buffer-live-p buffer)
                                 (with-current-buffer buffer (omnigent-conversation--event name data))))
           (lambda (status body) (when (buffer-live-p buffer)
                                   (with-current-buffer buffer (omnigent-conversation--snapshot status body))))
           (lambda (err) (message "Omnigent stream: %s" err))
           (lambda () (when (buffer-live-p buffer)
                        (with-current-buffer buffer
                          (setq omnigent-conversation--loading t
                                omnigent-conversation--pending-events nil))))))))

;;;###autoload
(defun omnigent-conversation-open (id &optional title)
  "Open the conversation for session ID, with optional TITLE."
  (interactive "sSession ID: ")
  (let ((buffer (omnigent-sessions-buffer id)))
    (unless buffer
      (setq buffer (generate-new-buffer (format "*omnigent: %s [%s]*"
                                                (if (or (null title) (string-empty-p title)) "Untitled" title) (substring id 0 (min 9 (length id))))))
      (condition-case err
          (progn
            (with-current-buffer buffer
              (let ((omnigent-conversation--session-id id))
                (omnigent-conversation-mode)))
            (omnigent-sessions-register-buffer id buffer))
        (error (kill-buffer buffer) (signal (car err) (cdr err)))))
    (pop-to-buffer buffer)))

(defun omnigent-conversation-send ()
  "Send the composer text to the current session."
  (interactive)
  (when buffer-read-only (user-error "This session is read-only"))
  (when omnigent-conversation--sending (user-error "A message is being sent"))
  (let ((text (buffer-substring-no-properties omnigent-conversation--prompt-start (point-max)))
        (buffer (current-buffer)))
    (when (string-blank-p text) (user-error "The message is empty"))
    (setq omnigent-conversation--sending t)
    (condition-case err
        (omnigent-transport-post-session-event
         omnigent-conversation-session-id
         `(("type" . "message") ("data" . (("role" . "user")
                    ("content" . [(("type" . "input_text") ("text" . ,text))]))))
         (apply-partially #'omnigent-conversation--sent buffer text))
      (error (setq omnigent-conversation--sending nil) (signal (car err) (cdr err))))))

(defun omnigent-conversation-interrupt ()
  "Interrupt the current session asynchronously."
  (interactive)
  (when buffer-read-only (user-error "This session is read-only"))
  (omnigent-transport-post-session-event
   omnigent-conversation-session-id '(("type" . "interrupt"))
   #'omnigent-conversation--interrupted))

(defun omnigent-ui-sessions-open ()
  "Open the session at point."
  (interactive)
  (let* ((id (omnigent-ui--session-id-at-point))
         (session (cl-find id omnigent-sessions :key (lambda (row) (alist-get 'id row))
                           :test #'equal)))
    (unless session (user-error "No session at point"))
    (omnigent-ui-open id (alist-get 'title session))))

(define-derived-mode omnigent-ui-sessions-mode special-mode "Omnigent Sessions"
  "Major mode for the Omnigent session list."
  (setq-local truncate-lines t))

;;;###autoload
(defun omnigent-ui-sessions ()
  "Show or hide the Omnigent session list in a left side window."
  (interactive)
  (let ((buffer (get-buffer-create "*omnigent-sessions*")))
    (with-current-buffer buffer (omnigent-ui-sessions-mode))
    (omnigent-ui-sessions-render)
    (if-let* ((window (get-buffer-window buffer)))
        (delete-window window)
      (display-buffer-in-side-window buffer '((side . left) (slot . -1))))))

(defun omnigent-ui-refresh ()
  "Refresh the full root session list."
  (interactive)
  (let ((omnigent-transport-session-limit 1000)) (omnigent-sessions-refresh)))

(defun omnigent-ui-stop ()
  "Stop the selected session without deleting its history."
  (interactive)
  (pcase-let ((`(,id . ,title) (omnigent-ui--action-target)))
    (omnigent-sessions-action id "stop_session"
                              (apply-partially #'omnigent-ui--action-result "Stop" title))))

(defun omnigent-ui-delete ()
  "Delete the selected session after confirmation."
  (interactive)
  (pcase-let ((`(,id . ,title) (omnigent-ui--action-target)))
    (when (yes-or-no-p (format "Permanently delete session %s? " title))
      (omnigent-sessions-delete id (apply-partially #'omnigent-ui--action-result "Delete" title)))))

(define-derived-mode omnigent-ui-workspace-mode special-mode "Omnigent Workspace"
  "Show changed workspace-relative paths for one session."
  (setq-local truncate-lines t))

(defun omnigent-ui-workspace ()
  "Show or hide the selected session's workspace panel."
  (interactive)
  (unless omnigent-ui--selected-session (user-error "Select a session first"))
  (if omnigent-ui--workspace-visible
      (progn (omnigent-ui--workspace-hide) (setq omnigent-ui--workspace-closed t))
    (setq omnigent-ui--workspace-closed nil omnigent-ui--workspace-visible t)
    (omnigent-ui--workspace-display)
    (omnigent-ui-workspace-refresh)))

(defun omnigent-ui-workspace-refresh (&optional id)
  "Refresh workspace ID, or the current panel, coalescing concurrent requests."
  (interactive)
  (setq id (or id omnigent-ui--workspace-id omnigent-ui--selected-session))
  (when id
    (if (gethash id omnigent-ui--workspace-pending)
        (puthash id t omnigent-ui--workspace-again)
      (let ((token (make-symbol "workspace-fetch")))
        (puthash id token omnigent-ui--workspace-pending)
        (condition-case nil
            (omnigent-workspace-list id (apply-partially #'omnigent-ui--workspace-result
                                                       id omnigent-transport--generation token))
          (error (remhash id omnigent-ui--workspace-pending)))))))

(defun omnigent-ui-workspace-diff ()
  "Fetch a fresh file or combined diff for the selected workspace row."
  (interactive)
  (let ((id omnigent-ui--workspace-id)
        (path (get-text-property (line-beginning-position) 'omnigent-ui-path)))
    (unless (and id path) (user-error "No changed file at point"))
    (let ((callback (apply-partially #'omnigent-ui--diff-result id path)))
      (condition-case nil
          (if (eq path :all) (omnigent-workspace-diff id callback)
            (omnigent-workspace-file-diff id path callback))
        (error nil)))))

(provide 'omnigent)
;;; omnigent.el ends here
