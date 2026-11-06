;;; omnigent.el --- Omnigent for Emacs -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1") (websocket "1.16"))

;;; Commentary:
;; Start or connect to an Omnigent server.

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

;;;###autoload
(defun omnigent-connect (url)
  "Connect to URL."
  (interactive (list (read-string "Omnigent server URL: " omnigent-server-url)))
  (unless (string-match-p "\\`https?://" url)
    (user-error "Server URL must start with http:// or https://"))
  (omnigent-transport-reset)
  (setq omnigent-server-url (string-remove-suffix "/" url))
  (message "Using Omnigent server %s" omnigent-server-url))

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
