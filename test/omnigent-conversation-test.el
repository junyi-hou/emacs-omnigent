;;; omnigent-conversation-test.el --- Conversation checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'omnigent-conversation)

(ert-deftest omnigent-conversation-snapshot-stream-and-draft ()
  (let (event snapshot stopped callback (omnigent-sessions--buffers nil))
    (cl-letf (((symbol-function 'omnigent-transport-start-session-stream)
               (lambda (_id on-event on-snapshot &optional _error on-connect)
                 (setq event on-event snapshot on-snapshot)
                 (funcall on-connect) 'stream))
              ((symbol-function 'omnigent-transport-stop-session-stream)
               (lambda (stream) (setq stopped stream)))
              ((symbol-function 'omnigent-transport-post-session-event)
               (lambda (_id _data cb) (setq callback cb))))
      (save-window-excursion
        (omnigent-conversation-open "session-1")
        (let ((buffer (current-buffer)))
          (unwind-protect
              (progn
                (insert "draft")
                (funcall event "response.output_item.done"
                         '((item . ((id . "a") (type . "message")
                                    (data . ((role . "assistant") (content . "hello")))))))
                (funcall snapshot 200
                         '((items . [((id . "a") (type . "message")
                                      (data . ((role . "assistant")
                                               (content . [((type . "output_text") (text . "hello"))]))))])))
                (should (equal (buffer-string) "draft"))
                (should (equal omnigent-conversation--order '("a")))
                (let ((item (gethash "a" omnigent-conversation--items)))
                  (should (equal (alist-get 'role item) "assistant"))
                  (should (equal (omnigent-conversation--text item) "hello")))
                (omnigent-conversation-send)
                (funcall callback 500 nil)
                (should (string-suffix-p "draft" (buffer-string)))
                (omnigent-conversation-send)
                (funcall callback 202 nil)
                (should-not (string-suffix-p "draft" (buffer-string))))
            (kill-buffer buffer)))
        (should (eq stopped 'stream))
        (should-not omnigent-sessions--buffers)))))

(provide 'omnigent-conversation-test)
