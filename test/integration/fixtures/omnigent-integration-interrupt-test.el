;;; omnigent-integration-interrupt-test.el --- Check interrupt and continue -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(ert-deftest omnigent-integration-interrupt-and-continue ()
  "Interrupt a live Codex reply and continue in the same Codex conversation."
  (omnigent-integration-with-run
   run
   (let* ((omnigent-server-url
           (omnigent-integration-run-server-url run))
          (omnigent-auth-method 'none)
          (omnigent-open-session-list-on-connect t)
          (mock (omnigent-integration-run-mock-url run))
          (first-prompt "Interrupt fixture warmup")
          (long-prompt "Interrupt fixture long turn")
          (follow-up "Interrupt fixture continue")
          (first-reply "Ready to write the report.")
          (final-reply "Continuing the report now.")
          (end-marker "section60")
          (interruption "<turn_aborted>"))
     (omnigent-integration--post-json
      (concat mock "/mock/configure")
      `((match . "Interrupt fixture")
        (required_tools . ["exec_command"])
        (responses
         .
         [((text . ,first-reply))
          ((text
            .
            ,(mapconcat (lambda (index) (format "section%02d" index))
                        (number-sequence 1 60)
                        " "))
           (stream . t) (chunk_delay . 0.4))
          ((text . ,final-reply))])))
     (save-window-excursion
       (unwind-protect
           (progn
             (omnigent-connect omnigent-server-url)
             (let ((id
                    (omnigent-integration--mock-session
                     run "Interrupt and continue")))
               (with-current-buffer
                   (omnigent-integration--open-session-row id)
                 (goto-char (point-max))
                 (insert first-prompt)
                 (funcall #'omnigent-conversation-send)
                 (omnigent-integration--wait
                  (lambda ()
                    (and (omnigent-integration--message-position
                          first-reply)
                         (eq
                          (omnigent-integration--session-row-face id)
                          'omnigent-session-idle))))
                 (goto-char (point-max))
                 (insert long-prompt)
                 (funcall #'omnigent-conversation-send)
                 (ert-info
                  ("Interrupt after Codex starts streaming")
                  (omnigent-integration--wait
                   (lambda ()
                     (and (omnigent-integration--message-position
                           "section04")
                          (eq
                           (omnigent-integration--session-row-face id)
                           'omnigent-session-running)
                          (member
                           (overlay-get
                            omnigent-conversation--busy-overlay
                            'before-string)
                           '("|" "/" "-" "\\")))))
                  (should-not
                   (omnigent-integration--message-position
                    end-marker))
                  (funcall #'omnigent-conversation-interrupt)
                  (omnigent-integration--wait
                   (lambda ()
                     (and (not buffer-read-only)
                          (eq
                           (omnigent-integration--session-row-face id)
                           'omnigent-session-idle)
                          (equal
                           (overlay-get
                            omnigent-conversation--busy-overlay
                            'before-string)
                           " ")))))
                 (goto-char (point-max))
                 (insert follow-up)
                 (funcall #'omnigent-conversation-send)
                 (let ((reply
                        (omnigent-integration--wait
                         (lambda ()
                           (omnigent-integration--message-position
                            final-reply)))))
                   (should
                    (< (omnigent-integration--message-position
                        first-reply)
                       (omnigent-integration--message-position
                        follow-up)
                       reply)))
                 (should-not
                  (omnigent-integration--message-position
                   end-marker))))
             (ert-info
              ("Check the follow-up continues the Codex conversation")
              (let* ((omnigent-server-url mock)
                     (requests
                      (alist-get
                       'requests
                       (omnigent-integration--get-json
                        "/mock/requests")))
                     (continued nil))
                (dolist (request requests)
                  (let ((body (json-encode request)))
                    (when-let* ((prompt-position
                                 (string-search follow-up body)))
                      (should-not
                       (string-search "Conversation so far:" body))
                      (when-let* ((marker-position
                                   (string-search interruption body)))
                        (should-not
                         (string-search interruption body
                                        (+ marker-position
                                           (length interruption))))
                        (when (< marker-position prompt-position)
                          (setq continued t))))))
                (should continued))))
         (omnigent-disconnect))))))

;;; omnigent-integration-interrupt-test.el ends here
