;;; omnigent.el --- Omnigent for Emacs -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1") (websocket "1.16"))

;;; Commentary:
;; Start or connect to an Omnigent server, then select a session.

;;; Code:

(require 'subr-x)
(require 'omnigent-transport)

(defgroup omnigent nil
  "Interact with Omnigent servers."
  :group 'applications)

(defcustom omnigent-executable
  (let ((local (expand-file-name
                ".venv/bin/omnigent"
                (file-name-directory (or load-file-name buffer-file-name)))))
    (if (file-executable-p local) local "omnigent"))
  "Omnigent CLI executable."
  :type 'file
  :group 'omnigent)

(defvar omnigent-start-process nil
  "CLI process that is starting the local Omnigent server.")

(defvar omnigent-current-session-id nil
  "ID of the session selected in this Emacs session.")

(defvar omnigent-current-session nil
  "Snapshot of the selected Omnigent session.")

(defconst omnigent--new-session-choice "New session")

(defun omnigent--response-data (status body)
  (when (and (eql status 200) (listp body))
    (let ((data (cdr (assq 'data body))))
      (and (vectorp data) data))))

(defun omnigent--session-label (session)
  (format "%s [%s] <%s> %s"
          (or (cdr (assq 'title session)) "Untitled")
          (or (cdr (assq 'agent_name session)) "agent")
          (or (cdr (assq 'status session)) "unknown")
          (cdr (assq 'id session))))

(defun omnigent--select-session (url status body)
  (let ((sessions (omnigent--response-data status body)))
    (if (not sessions)
        (message "Could not list sessions from %s: %s"
                 url (if (integerp status) (format "HTTP %d" status)
                       (format "%S" status)))
      (let* ((choices (cons (cons omnigent--new-session-choice :new)
                            (mapcar (lambda (session)
                                      (cons (omnigent--session-label session) session))
                                    (append sessions nil))))
             (choice (completing-read "Session: " choices nil t nil nil
                                      omnigent--new-session-choice))
             (session (cdr (assoc choice choices))))
        (if (eq session :new)
            (omnigent--new-session)
          (omnigent-resume-session (cdr (assq 'id session))))))))

;;;###autoload
(defun omnigent-connect (url)
  "Connect to URL, list its sessions, and prompt for a session to select."
  (interactive (list (read-string "Omnigent server URL: " omnigent-server-url)))
  (unless (string-match-p "\\`https?://" url)
    (user-error "Server URL must start with http:// or https://"))
  (omnigent-transport-reset)
  (setq omnigent-server-url (string-remove-suffix "/" url)
        omnigent-current-session-id nil
        omnigent-current-session nil)
  (message "Connecting to %s..." omnigent-server-url)
  (omnigent-transport-request "GET" "/v1/sessions?limit=1000&include_archived=true&sort_by=updated_at&order=desc"
                    (apply-partially #'omnigent--select-session
                                     omnigent-server-url)))

(defun omnigent--resume-result (session-id status session)
  (if (and (memq status '(200 201)) (listp session))
      (progn
        (setq omnigent-current-session-id session-id
              omnigent-current-session session)
        (message "%s session %s (%s)"
                 (if (eql status 201) "Created" "Selected")
                 (or (cdr (assq 'title session)) session-id)
                 (or (cdr (assq 'status session)) "unknown")))
    (message "Could not load session %s: %s"
             session-id (if (integerp status) (format "HTTP %d" status)
                          (format "%S" status)))))

(defun omnigent--agent-label (agent)
  (format "%s [%s] <%s>"
          (cdr (assq 'name agent))
          (or (cdr (assq 'harness agent)) "unknown")
          (cdr (assq 'id agent))))

(defun omnigent--create-session-result (status session)
  (let ((session-id (and (listp session) (cdr (assq 'id session)))))
    (if (and (eql status 201) session-id)
        (omnigent--resume-result session-id status session)
      (message "Could not create Omnigent session: %s"
               (if (integerp status) (format "HTTP %d" status)
                 (format "%S" status))))))

(defun omnigent--select-agent (status body)
  (let ((agents (omnigent--response-data status body)))
    (if (not agents)
        (message "Could not list agents: %s"
                 (if (integerp status) (format "HTTP %d" status)
                   (format "%S" status)))
      (if (= (length agents) 0)
          (message "No agents are available on this server.")
        (let* ((choices (mapcar (lambda (agent)
                                  (cons (omnigent--agent-label agent) agent))
                                (append agents nil)))
               (choice (completing-read "Agent for new session: " choices nil t nil nil
                                        (caar choices)))
               (agent (cdr (assoc choice choices))))
          (omnigent-transport-request
           "POST" "/v1/sessions" #'omnigent--create-session-result
           `(("agent_id" . ,(cdr (assq 'id agent))))))))))

(defun omnigent--new-session ()
  (omnigent-transport-request "GET" "/v1/agents?limit=1000"
                    #'omnigent--select-agent))

;;;###autoload
(defun omnigent-resume-session (session-id)
  "Load SESSION-ID as the current session."
  (interactive (list (read-string "Resume Omnigent session ID: ")))
  (when (string-empty-p session-id)
    (user-error "Session ID must not be empty"))
  (setq omnigent-current-session-id nil
        omnigent-current-session nil)
  (omnigent-transport-get-session
   session-id (apply-partially #'omnigent--resume-result session-id)))

(defun omnigent--server-url-from-output (buffer)
  (with-current-buffer buffer
    (goto-char (point-min))
    (when (re-search-forward "https?://[^[:space:]]+" nil t)
      (match-string-no-properties 0))))

(defun omnigent--start-server-sentinel (process _event)
  (when (memq (process-status process) '(exit signal))
    (when (eq process omnigent-start-process)
      (setq omnigent-start-process nil))
    (let* ((buffer (process-buffer process))
           (url (and (= (process-exit-status process) 0)
                     (buffer-live-p buffer)
                     (omnigent--server-url-from-output buffer))))
      (if url
          (progn
            (when (buffer-live-p buffer)
              (kill-buffer buffer))
            (omnigent-connect url))
        (message "Omnigent server failed to start; see %s"
                 (if (buffer-live-p buffer) (buffer-name buffer) "process output"))))))

;;;###autoload
(defun omnigent-start-server ()
  "Start or reuse the local Omnigent server, then select a session."
  (interactive)
  (if (process-live-p omnigent-start-process)
      (message "Omnigent server startup is already in progress")
    (let ((executable (executable-find omnigent-executable))
          (buffer (get-buffer-create "*Omnigent Server Startup*")))
      (unless executable
        (user-error "Cannot find Omnigent CLI: %s" omnigent-executable))
      (with-current-buffer buffer
        (erase-buffer))
      (setq omnigent-start-process
            (make-process
             :name "omnigent-server-start"
             :buffer buffer
             :stderr buffer
             :command (list executable "server" "--background" "--no-open")
             :connection-type 'pipe
             :noquery t
             :sentinel #'omnigent--start-server-sentinel))
      (message "Starting or reusing the local Omnigent server..."))))

(provide 'omnigent)
;;; omnigent.el ends here
