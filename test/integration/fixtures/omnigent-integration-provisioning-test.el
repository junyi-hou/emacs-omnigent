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
  (when (overlayp omnigent-ui--sandbox-overlay)
    (overlay-get omnigent-ui--sandbox-overlay 'before-string)))

(ert-deftest omnigent-integration-managed-provisioning ()
  "Watch a managed session start and become editable with a local launcher."
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
                   (should buffer-read-only)
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
                    (and buffer-read-only
                         (string-match-p
                          "Provisioning sandbox"
                          (or (omnigent-integration--sandbox-display)
                              "")))))
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
                 (goto-char (point-max))
                 (insert "Managed session draft")
                 (should
                  (string-suffix-p
                   "> Managed session draft" (buffer-string)))))
           (when (buffer-live-p buffer)
             (kill-buffer buffer))
           (ignore-errors
             (omnigent-integration--post-json
              (concat omnigent-server-url "/__test/host/stop") '()))
           (omnigent-disconnect)))))))

;;; omnigent-integration-provisioning-test.el ends here
