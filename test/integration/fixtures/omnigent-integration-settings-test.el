;;; omnigent-integration-settings-test.el --- Change conversation settings -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(defun omnigent-integration--wait-for-setting (id field value header)
  "Wait for session ID to report FIELD as VALUE and display HEADER."
  (let ((path (omnigent-transport--session-path id)))
    (omnigent-integration--wait
     (lambda ()
       (and (string-search header header-line-format)
            (equal
             (alist-get field (omnigent-integration--get-json path))
             value))))))

(defun omnigent-integration--send-slash (command)
  "Submit slash COMMAND from the conversation composer."
  (goto-char (point-max))
  (insert command)
  (call-interactively (key-binding (kbd "C-c C-c"))))

(defun omnigent-integration--check-other-slash-commands (id)
  "Check the remaining built-in slash commands from session ID."
  (dolist (command '("/context" "/mcp" "/permissions" "/help"))
    (omnigent-integration--send-slash command)
    (should (string-suffix-p (concat "> " command) (buffer-string)))
    (delete-region (- (point-max) (length command)) (point-max)))
  (let ((omnigent-side-chat-display-action
         '(display-buffer-in-side-window (side . right))))
    (dolist (command '("/side" "/btw"))
      (save-window-excursion
        (omnigent-integration--send-slash command)
        (omnigent-integration--wait
         (lambda ()
           (and (string-suffix-p "> " (buffer-string))
                (seq-some
                 (lambda (window)
                   (with-current-buffer (window-buffer window)
                     (and (derived-mode-p 'omnigent-conversation-mode)
                          (not
                           (equal
                            id omnigent-conversation-session-id))
                          (eq
                           (window-parameter window 'window-side)
                           'right))))
                 (window-list))))))))
  (let* ((source
          (omnigent-integration--get-json
           (omnigent-transport--session-path id)))
         (omnigent-session-default-agent (alist-get 'agent_id source))
         created
         (omnigent-sessions-open-hook
          (list (lambda (session) (setq created session)))))
    (omnigent-integration--send-slash "/new")
    (omnigent-integration--wait (lambda () created))
    (should-not (equal id (alist-get 'id created)))
    (should
     (equal
      (alist-get 'workspace source) (alist-get 'workspace created)))
    (should (string-suffix-p "> " (buffer-string))))
  (omnigent-integration--send-slash "/compact")
  (omnigent-integration--wait
   (lambda () (string-suffix-p "> " (buffer-string))))
  (let ((window (get-buffer-window (current-buffer))))
    (omnigent-integration--send-slash "/clear")
    (let ((replacement
           (omnigent-integration--wait
            (lambda ()
              (with-current-buffer (window-buffer window)
                (and (derived-mode-p 'omnigent-conversation-mode)
                     (not (equal id omnigent-conversation-session-id))
                     (omnigent-conversation-ready-p)
                     (current-buffer)))))))
      (with-current-buffer replacement
        (should (string-suffix-p "> " (buffer-string)))
        (should-not
         (omnigent-integration--message-position
          "The session is ready."))))))

(ert-deftest omnigent-integration-change-conversation-settings ()
  "Change model and effort with Emacs commands and exercise built-in slash commands."
  (omnigent-integration-with-run
   run
   (let ((omnigent-server-url
          (omnigent-integration-run-server-url run))
         (omnigent-auth-method 'none)
         (omnigent-open-session-list-on-connect t))
     (omnigent-integration--post-json
      (concat
       (omnigent-integration-run-mock-url run) "/mock/configure")
      '((match . "Load the model catalog")
        (required_tools . ["exec_command"])
        (responses
         . [((text . "The session is ready.") (stream . t))])))
     (save-window-excursion
       (unwind-protect
           (progn
             (omnigent-connect omnigent-server-url)
             (let* ((id
                     (omnigent-integration--mock-session
                      run "Conversation settings"))
                    (buffer
                     (omnigent-integration--open-session-row id))
                    model
                    alternate-model)
               (with-current-buffer buffer
                 (omnigent-integration--wait
                  (lambda ()
                    (and header-line-format (not buffer-read-only))))
                 ;; Codex reports its model catalog after the runner starts.
                 (goto-char (point-max))
                 (insert "Load the model catalog")
                 (call-interactively (key-binding (kbd "C-c C-c")))
                 (omnigent-integration--wait
                  (lambda ()
                    (and (equal omnigent-conversation--status "idle")
                         (omnigent-integration--message-position
                          "The session is ready."))))
                 (cl-letf (((symbol-function 'completing-read)
                            (lambda (prompt choices &rest _)
                              (let ((choice
                                     (pcase prompt
                                       ("Model: "
                                        (setq alternate-model
                                              (cadr choices))
                                        (setq model (car choices)))
                                       ("Effort: " "high"))))
                                (should (member choice choices))
                                choice))))
                   (call-interactively
                    #'omnigent-conversation-set-model)
                   (omnigent-integration--wait-for-setting
                    id
                    'model_override
                    (omnigent-integration--wait (lambda () model))
                    (format " | %s | " model))
                   (call-interactively
                    #'omnigent-conversation-set-effort)
                   (omnigent-integration--wait-for-setting
                    id
                    'reasoning_effort
                    "high"
                    (format " | %s | high | " model)))
                 (omnigent-integration--send-slash "/effort low")
                 (omnigent-integration--wait-for-setting
                  id
                  'reasoning_effort
                  "low"
                  (format " | %s | low | " model))
                 (should alternate-model)
                 (omnigent-integration--send-slash
                  (concat "/model " alternate-model))
                 (omnigent-integration--wait-for-setting
                  id
                  'model_override
                  alternate-model
                  (format " | %s | " alternate-model))
                 (should (string-suffix-p "> " (buffer-string)))
                 (omnigent-integration--check-other-slash-commands
                  id))))
         (omnigent-disconnect))))))

;;; omnigent-integration-settings-test.el ends here
