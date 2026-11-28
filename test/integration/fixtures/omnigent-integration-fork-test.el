;;; omnigent-integration-fork-test.el --- Fork a live conversation -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(ert-deftest omnigent-integration-fork-from-response ()
  "Fork through the first response and open the truncated conversation."
  (omnigent-integration-with-run
   run
   (let* ((omnigent-server-url
           (omnigent-integration-run-server-url run))
          (omnigent-auth-method 'none)
          (omnigent-open-session-list-on-connect t)
          (first-prompt "Fork fixture keep this turn")
          (first-reply "This reply belongs in the fork.")
          (second-prompt "Fork fixture leave this turn behind")
          (second-reply "This reply stays in the source."))
     (omnigent-integration--post-json
      (concat
       (omnigent-integration-run-mock-url run) "/mock/configure")
      `((match . "Fork fixture")
        (required_tools . ["exec_command"])
        (responses
         . [((text . ,first-reply)) ((text . ,second-reply))])))
     (save-window-excursion
       (unwind-protect
           (progn
             (omnigent-connect omnigent-server-url)
             (let* ((source
                     (omnigent-integration--mock-session
                      run "Fork journey"))
                    (source-buffer
                     (omnigent-integration--open-session-row source)))
               (with-current-buffer source-buffer
                 (dolist (turn
                          (list
                           (cons first-prompt first-reply)
                           (cons second-prompt second-reply)))
                   (goto-char (point-max))
                   (insert (car turn))
                   (funcall #'omnigent-conversation-send)
                   (omnigent-integration--wait
                    (lambda ()
                      (and (omnigent-integration--message-position
                            (cdr turn))
                           (eq
                            (omnigent-integration--session-row-face
                             source)
                            'omnigent-session-idle)))))
                 (let* ((items
                         (alist-get
                          'data
                          (omnigent-integration--get-json
                           (format
                            "/v1/sessions/%s/items?type=message"
                            source))))
                        (first-answer
                         (seq-find
                          (lambda (item)
                            (and (equal
                                  (alist-get 'role item) "assistant")
                                 (string-search
                                  first-reply (json-encode item))))
                          items))
                        (response-id
                         (alist-get 'response_id first-answer)))
                   (should (stringp response-id))
                   ;; Call the fork commands without opening the menu in batch Emacs.
                   (cl-letf (((symbol-function 'omnigent--fork-menu)
                              #'ignore)
                             ((symbol-function 'completing-read)
                              (lambda (prompt choices &rest _)
                                (should
                                 (equal
                                  prompt "Fork through response: "))
                                (should (member response-id choices))
                                response-id)))
                     (funcall #'omnigent-conversation-fork t)
                     (funcall #'omnigent--fork-response)
                     (funcall #'omnigent--fork-submit))))
               (let ((fork
                      (omnigent-integration--wait
                       (lambda ()
                         (with-current-buffer (window-buffer
                                               (selected-window))
                           (and
                            (derived-mode-p
                             'omnigent-conversation-mode)
                            (not
                             (equal
                              omnigent-conversation-session-id
                              source))
                            (not buffer-read-only)
                            (omnigent-integration--message-position
                             first-reply)
                            omnigent-conversation-session-id)))
                       40)))
                 (should
                  (omnigent-integration--wait
                   (lambda ()
                     (omnigent-integration--session-row fork))))
                 (should (omnigent-integration--session-row source))
                 (with-current-buffer (omnigent-sessions-buffer fork)
                   (let ((prompt
                          (omnigent-integration--message-position
                           first-prompt))
                         (reply
                          (omnigent-integration--message-position
                           first-reply)))
                     (should (< prompt reply))
                     (should
                      (= 1
                         (how-many (regexp-quote first-reply)
                                   (point-min)
                                   (point-max)))))
                   (should-not
                    (omnigent-integration--message-position
                     second-prompt))
                   (should-not
                    (omnigent-integration--message-position
                     second-reply)))
                 (with-current-buffer source-buffer
                   (should
                    (omnigent-integration--message-position
                     second-reply))))))
         (omnigent-disconnect))))))

;;; omnigent-integration-fork-test.el ends here
