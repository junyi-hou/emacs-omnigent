;;; omnigent-integration-provisioning-test.el --- Check managed provisioning -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(defun omnigent-integration--managed-server-command
    (omnigent root port)
  "Start the upstream local managed launcher beside OMNIGENT in ROOT on PORT."
  (let ((url (format "http://127.0.0.1:%d" port)))
    (list
     (expand-file-name "python" (file-name-directory omnigent))
     "-m"
     "tests.e2e_ui.start_session._managed_replica_server"
     "a"
     "--root"
     root
     "--port"
     (number-to-string port)
     "--replica-a"
     url
     "--replica-b"
     url)))

(defun omnigent-integration--sandbox-display ()
  "Return the displayed sandbox status in the current conversation."
  (when (overlayp omnigent-conversation--sandbox-overlay)
    (overlay-get
     omnigent-conversation--sandbox-overlay 'before-string)))

(ert-deftest omnigent-integration-managed-provisioning ()
  "Queue a message in a managed session before the local launcher is ready."
  (let ((omnigent-integration--server-command
         #'omnigent-integration--managed-server-command)
        (omnigent-integration--server-environment
         '("OMNIGENT_LOCAL_SINGLE_USER=1"
           "OMNIGENT_SKIP_ONBOARD=1"
           "OMNIGENT_FEATURES=-automations_v2")))
    (omnigent-integration-with-run
     run
     (let ((omnigent-server-url
            (omnigent-integration-run-server-url run))
           (omnigent-auth-method 'none)
           (omnigent-open-session-list-on-connect nil)
           (omnigent-session-default-host-type "managed")
           (omnigent-session-default-sandbox-provider "modal")
           (omnigent-session-default-agent "codex-native-ui")
           (omnigent--create-draft nil)
           (prompt "Managed session queued prompt")
           (draft "Managed session draft")
           id
           buffer)
       (save-window-excursion
         (unwind-protect
             (progn
               (omnigent-connect omnigent-server-url)
               (call-interactively #'omnigent-sessions-create)
               (setq buffer
                     (omnigent-integration--wait
                      (lambda ()
                        (let ((selected
                               (window-buffer (selected-window))))
                          (with-current-buffer selected
                            (and (derived-mode-p
                                  'omnigent-conversation-mode)
                                 selected))))))
               (setq id
                     (buffer-local-value
                      'omnigent-conversation-session-id buffer))
               (with-current-buffer buffer
                 (let
                     ((first
                       (omnigent-integration--wait
                        (lambda ()
                          (let
                              ((display
                                (omnigent-integration--sandbox-display)))
                            (and display
                                 (string-match-p
                                  "Provisioning sandbox" display)
                                 display))))))
                   (omnigent-integration--wait
                    (lambda ()
                      (let ((display
                             (omnigent-integration--sandbox-display)))
                        (and display (not (equal display first))))))))
               (kill-buffer buffer)
               (omnigent-conversation-open id)
               (setq buffer (omnigent-sessions-buffer id))
               (with-current-buffer buffer
                 (omnigent-integration--wait
                  (lambda ()
                    (and (omnigent-conversation-ready-p)
                         (string-match-p
                          "Provisioning sandbox"
                          (or (omnigent-integration--sandbox-display)
                              "")))))
                 (goto-char (point-max))
                 (insert prompt)
                 (call-interactively (key-binding (kbd "C-c C-c")))
                 (omnigent-integration--wait
                  (lambda ()
                    (and (omnigent-conversation-ready-p)
                         (omnigent-integration--message-position
                          (concat "[queued] > " prompt)))))
                 (let ((session
                        (omnigent-integration--get-json
                         (omnigent-transport--session-path id))))
                   (should
                    (equal
                     (alist-get
                      'stage (alist-get 'sandbox_status session))
                     "provisioning"))
                   (should
                    (equal
                     (mapcar
                      (lambda (item)
                        (alist-get
                         'text (car (alist-get 'content item))))
                      (alist-get 'pending_inputs session))
                     (list prompt))))
                 (goto-char (point-max))
                 (insert draft)
                 (omnigent-integration--post-json
                  (concat
                   omnigent-server-url "/__test/provision/release")
                  '())
                 (omnigent-integration--wait
                  (lambda ()
                    (and
                     (not buffer-read-only)
                     (not (omnigent-integration--sandbox-display))))
                  30)
                 (should
                  (string-suffix-p
                   (concat "> " draft) (buffer-string)))))
           (when (buffer-live-p buffer)
             (kill-buffer buffer))
           (ignore-errors
             (omnigent-integration--post-json
              (concat omnigent-server-url "/__test/host/stop") '()))
           (omnigent-disconnect)))))))

;;; omnigent-integration-provisioning-test.el ends here
