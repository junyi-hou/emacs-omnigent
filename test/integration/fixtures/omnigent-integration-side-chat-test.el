;;; omnigent-integration-side-chat-test.el --- Check the side chat journey -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(ert-deftest omnigent-integration-side-chat ()
  "Ask through /btw and the Lisp API on the local mock model."
  (omnigent-integration-with-run
   run
   (let ((omnigent-server-url
          (omnigent-integration-run-server-url run))
         (omnigent-auth-method 'none)
         (omnigent-open-session-list-on-connect nil)
         (prompt "Side chat source prompt")
         (source-reply "The source response is ready.")
         (btw-question "Side chat interactive question")
         (btw-reply "The interactive side chat answered.")
         (api-question "Side chat programmatic question")
         (api-reply "The programmatic side chat answered."))
     (dolist (exchange
              (list
               (cons prompt source-reply)
               (cons btw-question btw-reply)
               (cons api-question api-reply)))
       (omnigent-integration--post-json
        (concat
         (omnigent-integration-run-mock-url run) "/mock/configure")
        `((match . ,(car exchange))
          (required_tools . ["exec_command"])
          (responses . [((text . ,(cdr exchange)) (stream . t))]))))
     (save-window-excursion
       (unwind-protect
           (progn
             (omnigent-connect omnigent-server-url)
             (let* ((id
                     (omnigent-integration--mock-session
                      run "Side chat journey"))
                    (source
                     (progn
                       (omnigent-conversation-open id)
                       (omnigent-sessions-buffer id)))
                    side
                    result)
               (with-current-buffer source
                 (omnigent-integration--wait
                  #'omnigent-conversation-ready-p)
                 (goto-char (point-max))
                 (insert prompt)
                 (call-interactively (key-binding (kbd "C-c C-c")))
                 (omnigent-integration--wait
                  (lambda ()
                    (omnigent-integration--message-position
                     source-reply)))
                 (goto-char (point-max))
                 (insert "/btw " btw-question)
                 (call-interactively (key-binding (kbd "C-c C-c"))))
               (setq side
                     (omnigent-integration--wait
                      (lambda ()
                        (let ((buffer
                               (window-buffer (selected-window))))
                          (when (buffer-local-value
                                 'omnigent--conversation-side-chat-p
                                 buffer)
                            buffer)))))
               (with-current-buffer side
                 (should-not
                  (equal omnigent-conversation-session-id id))
                 (omnigent-integration--wait
                  (lambda ()
                    (omnigent-integration--message-position
                     btw-reply)))
                 (should
                  (omnigent-integration--message-position
                   btw-question)))
               (let ((buffers (buffer-list)))
                 (omnigent-side-chat-ask
                  id api-question
                  (lambda (status body)
                    (setq result (cons status body))))
                 (omnigent-integration--wait (lambda () result))
                 (should (omnigent-transport-success-p (car result)))
                 (should (equal (cdr result) api-reply))
                 (dolist (buffer (buffer-list))
                   (when (buffer-local-value
                          'omnigent--conversation-side-chat-p buffer)
                     (should (memq buffer buffers)))))
               (with-current-buffer source
                 (should (string-suffix-p "> " (buffer-string)))
                 (dolist (text
                          (list
                           btw-question
                           btw-reply
                           api-question
                           api-reply))
                   (should-not
                    (omnigent-integration--message-position text))))))
         (omnigent-disconnect))))))

;;; omnigent-integration-side-chat-test.el ends here
