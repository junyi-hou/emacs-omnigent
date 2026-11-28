;;; omnigent-integration-messaging-test.el --- Check the messaging journey -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(defun omnigent-integration--check-message-history (texts)
  "Check that each of TEXTS appears once, in order, in read-only history."
  (let ((previous (point-min)))
    (dolist (text texts)
      (let ((position (omnigent-integration--message-position text)))
        (should position)
        (should (<= previous position))
        (should
         (= (how-many (regexp-quote text) (point-min) (point-max)) 1))
        (should (get-text-property position 'read-only))
        (setq previous (+ position (length text)))))))

(defun omnigent-integration--check-live-messaging (id history)
  "Send and receive HISTORY in the current conversation for ID."
  (pcase-let ((`(,prompt
                 ,first-reply ,follow-up ,queued-prompt ,final-reply)
               history))
    (goto-char (point-max))
    (should (equal (buffer-substring (- (point) 2) (point)) "> "))
    (should-error
     (delete-region (- (point) 2) (- (point) 1))
     :type 'text-read-only)
    (insert "Messaging fixture first prompt")
    (call-interactively (key-binding (kbd "RET")))
    (insert "  Keep this indentation")
    (call-interactively (key-binding (kbd "C-c C-c")))
    (ert-info
     ("Wait for the first partial reply")
     (omnigent-integration--wait
      (lambda ()
        (omnigent-integration--message-position
         "**Streaming reply**"))))
    (should-not (omnigent-integration--message-position first-reply))
    (should
     (omnigent-integration--message-position
      "codex-native-ui:\n**Streaming reply**"))
    (font-lock-ensure)
    (should-not
     (get-text-property
      (+
       2
       (omnigent-integration--message-position "**Streaming reply**"))
      'font-lock-face))
    (should
     (omnigent-integration--message-position
      (concat "You:\n" prompt)))
    (should (string-suffix-p "> " (buffer-string)))
    (ert-info
     ("Wait for the running session row and conversation spinner")
     (omnigent-integration--wait
      (lambda ()
        (and (eq
              (omnigent-integration--session-row-face id)
              'omnigent-session-running)
             (member
              (overlay-get
               omnigent-conversation--busy-overlay 'before-string)
              '("|" "/" "-" "\\"))))))
    (goto-char (point-max))
    (insert follow-up)
    (backward-char 2)
    (omnigent-integration--wait
     (lambda ()
       (omnigent-integration--message-position
        "**Streaming reply** gives Emacs time")))
    (should (string-suffix-p (concat "> " follow-up) (buffer-string)))
    (should (= (- (point-max) (point)) 2))
    (let* ((window (selected-window))
           (reading (omnigent-integration--message-position prompt)))
      (goto-char reading)
      (set-window-start window reading)
      (omnigent-integration--wait
       (lambda ()
         (omnigent-integration--message-position
          "show an update while")))
      (should (= (point) reading))
      (should (= (window-start window) reading)))
    (ert-info
     ("Wait for the first completed reply and spinner to clear")
     (omnigent-integration--wait
      (lambda ()
        (and (omnigent-integration--message-position first-reply)
             (eq
              (omnigent-integration--session-row-face id)
              'omnigent-session-idle)
             (equal
              (overlay-get
               omnigent-conversation--busy-overlay 'before-string)
              " ")))))
    (font-lock-ensure)
    (let ((bold-word
           (+ 2
              (omnigent-integration--message-position
               "**Streaming reply**"))))
      (should
       (memq
        'markdown-bold-face
        (append
         (ensure-list (get-text-property bold-word 'face))
         (ensure-list
          (get-text-property bold-word 'font-lock-face))))))
    (goto-char (point-max))
    (call-interactively (key-binding (kbd "C-c C-c")))
    (ert-info
     ("Wait for the follow-up to start streaming")
     (omnigent-integration--wait
      (lambda ()
        (omnigent-integration--message-position
         "Queue phase starts"))))
    (goto-char (point-max))
    (insert queued-prompt)
    (call-interactively (key-binding (kbd "C-c C-c")))
    (ert-info
     ("Observe the message in the queue")
     (let ((queued
            (omnigent-integration--wait
             (lambda ()
               (omnigent-integration--message-position
                (concat "[queued] > " queued-prompt))))))
       (should (get-text-property queued 'read-only))
       (should
        (< (omnigent-integration--message-position
            "Queue phase starts")
           queued))
       (should
        (string-suffix-p
         (concat
          "[queued] > " queued-prompt "\n\n> ")
         (buffer-string)))))
    (ert-info
     ("Reconnect during the final reply")
     (omnigent-integration--wait
      (lambda ()
        (omnigent-integration--message-position
         "Final reply starts")))
     (should-not (omnigent-integration--message-position final-reply))
     (goto-char (point-max))
     (insert "Unsent recovery draft")
     (call-interactively (key-binding (kbd "C-c C-r")))
     (should buffer-read-only)
     (should-error
      (call-interactively (key-binding (kbd "C-c C-c")))
      :type 'user-error)
     (omnigent-integration--wait (lambda () (not buffer-read-only)))
     (should
      (string-suffix-p "> Unsent recovery draft" (buffer-string))))
    (ert-info
     ("Wait for both replies and the idle session row")
     (omnigent-integration--wait
      (lambda ()
        (and (omnigent-integration--message-position final-reply)
             (eq
              (omnigent-integration--session-row-face id)
              'omnigent-session-idle)))))
    (should-not (omnigent-integration--message-position "[queued] >"))
    (omnigent-integration--check-message-history history)
    (should
     (= (how-many "before the last part of this reply arrives"
                  (point-min)
                  (point-max))
        1))))


(ert-deftest omnigent-integration-messaging ()
  "Send messages, watch replies stream, and reopen the same session."
  (unless (executable-find "codex")
    (error "The messaging integration test requires codex on PATH"))
  (omnigent-integration-with-run
   run
   (let*
       ((omnigent-server-url
         (omnigent-integration-run-server-url run))
        (omnigent-auth-method 'none)
        (omnigent-open-session-list-on-connect t)
        (prompt
         "Messaging fixture first prompt\n  Keep this indentation")
        (follow-up "Messaging fixture follow-up")
        (queued-prompt "Messaging fixture queued prompt")
        (queue-reply
         "Queue phase starts and leaves time for another message to arrive while this model response is still streaming.")
        (first-reply
         "**Streaming reply** gives Emacs time to show an update while the user edits a draft and then reads the final reply.")
        (final-reply
         "Final reply starts and gives Emacs time to reconnect before the last part of this reply arrives.")
        (mock (omnigent-integration-run-mock-url run)))
     (omnigent-integration--post-json
      (concat mock "/mock/configure")
      `((match . "Messaging fixture")
        (required_tools . ["exec_command"])
        (responses
         .
         [((text . ,first-reply)
           (stream . t)
           (chunk_delay . 0.35))
          ((text . ,queue-reply) (stream . t) (chunk_delay . 0.35))
          ((text . ,final-reply)
           (stream . t)
           (chunk_delay . 0.35))])))
     (save-window-excursion
       (unwind-protect
           (progn
             (omnigent-connect omnigent-server-url)
             (let* ((id
                     (omnigent-integration--mock-session
                      run "Messaging journey"))
                    (buffer
                     (omnigent-integration--open-session-row id))
                    (history
                     (list
                      prompt
                      first-reply
                      follow-up
                      queued-prompt
                      final-reply)))
               (with-current-buffer buffer
                 (condition-case err
                     (omnigent-integration--check-live-messaging
                      id history)
                   (error
                    (message "Conversation transcript:\n%s"
                             (buffer-string))
                    (signal (car err) (cdr err))))
                 (kill-buffer buffer))
               (with-current-buffer
                   (omnigent-integration--open-session-row id)
                 (omnigent-integration--check-message-history history)
                 (should (string-suffix-p "> " (buffer-string))))))
         (omnigent-disconnect))))))

;;; omnigent-integration-messaging-test.el ends here
