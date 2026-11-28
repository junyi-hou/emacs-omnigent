;;; omnigent-integration-stream-drop-test.el --- Check automatic stream recovery -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(defun omnigent-integration--committed-transcript (id)
  "Read server items for ID and return their visible labels and text."
  (let ((page
         (omnigent-integration--get-json
          (format "/v1/sessions/%s/items?order=asc" id))))
    (should (eq (alist-get 'has_more page) :false))
    (delq
     nil
     (mapcar
      (lambda (item)
        (unless (eq (alist-get 'is_meta item) t)
          (pcase (alist-get 'type item)
            ("resource_event" nil)
            ("error"
             (should (stringp (alist-get 'message item)))
             (cons "Error" (alist-get 'message item)))
            ("message" (cons
              (if (equal (alist-get 'role item) "user")
                  "You"
                "codex-native-ui")
              (let ((content (alist-get 'content item)))
                (if (stringp content)
                    content
                  (mapconcat
                   (lambda (part) (alist-get 'text part)) content
                   "")))))
            (type
             (ert-fail (list "Unexpected server item" type item))))))
      (alist-get 'data page)))))

(ert-deftest omnigent-integration-stream-drop ()
  "Recover committed history exactly after losing the live reply stream."
  (omnigent-integration-with-run
   run
   (let*
       ((omnigent-server-url
         (omnigent-integration-run-server-url run))
        (omnigent-auth-method 'none)
        (omnigent-open-session-list-on-connect t)
        ;; Give the server time to commit while the client is offline.
        (omnigent-transport--reconnect-min-delay 10)
        (first-prompt "Stream drop fixture warmup")
        (first-reply "Ready for the numbered reply.")
        (second-prompt "Stream drop fixture send the numbered reply")
        (second-reply
         (mapconcat (lambda (index)
                      (format "section%02d" index))
                    (number-sequence 1 24)
                    " "))
        (draft "Unsent recovery draft"))
     (omnigent-integration--post-json
      (concat
       (omnigent-integration-run-mock-url run) "/mock/configure")
      `((match . "Stream drop fixture")
        (required_tools . ["exec_command"])
        (responses
         .
         [((text . ,first-reply))
          ((text . ,second-reply)
           (stream . t)
           (chunk_delay . 0.22))])))
     (save-window-excursion
       (unwind-protect
           (progn
             (omnigent-connect omnigent-server-url)
             (let ((id
                    (omnigent-integration--mock-session
                     run "Stream drop journey")))
               (with-current-buffer
                   (omnigent-integration--open-session-row id)
                 (goto-char (point-max))
                 (insert first-prompt)
                 (call-interactively (key-binding (kbd "C-c C-c")))
                 (omnigent-integration--wait
                  (lambda ()
                    (and (omnigent-integration--message-position
                          first-reply)
                         (eq
                          (omnigent-integration--session-row-face id)
                          'omnigent-session-idle))))
                 (goto-char (point-max))
                 (insert second-prompt)
                 (call-interactively (key-binding (kbd "C-c C-c")))
                 (omnigent-integration--wait
                  (lambda ()
                    (omnigent-integration--message-position
                     "section04")))
                 (should-not
                  (omnigent-integration--message-position
                   "section24"))
                 (goto-char (point-max))
                 (insert draft)
                 (backward-char 5)
                 (let* ((stream omnigent-conversation--stream)
                        (process (omnigent-stream-process stream))
                        (attempt (omnigent-stream-attempt stream))
                        committed)
                   (ert-info
                    ("Drop only the live SSE subprocess")
                    (should (process-live-p process))
                    (delete-process process)
                    (omnigent-integration--wait
                     (lambda () buffer-read-only)))
                   (ert-info
                    ("Read the committed transcript before Emacs reconnects")
                    (omnigent-integration--wait
                     (lambda ()
                       (should
                        (= (omnigent-stream-attempt stream) attempt))
                       (setq
                        committed
                        (omnigent-integration--committed-transcript
                         id))
                       (equal (cdar (last committed)) second-reply)))
                    (should-not (omnigent-stream-process stream))
                    (should-not
                     (omnigent-integration--message-position
                      "section24"))
                    (should
                     (equal
                      (seq-remove
                       (lambda (entry)
                         (equal (car entry) "Error"))
                       committed)
                      `(("You" . ,first-prompt)
                        ("codex-native-ui" . ,first-reply)
                        ("You" . ,second-prompt)
                        ("codex-native-ui" . ,second-reply)))))
                   (ert-info
                    ("Compare the entire recovered transcript with the server")
                    (omnigent-integration--wait
                     (lambda ()
                       (and
                        (> (omnigent-stream-attempt stream) attempt)
                        (process-live-p
                         (omnigent-stream-process stream))
                        (not buffer-read-only)
                        (omnigent-integration--message-position
                         "section24")
                        (eq
                         (omnigent-integration--session-row-face id)
                         'omnigent-session-idle)))
                     (+ omnigent-transport--reconnect-min-delay
                        omnigent-transport-connect-timeout))
                    (should
                     (equal
                      (buffer-substring-no-properties
                       (point-min)
                       omnigent-conversation--request-start)
                      (mapconcat (lambda (entry)
                                   (concat
                                    (car entry)
                                    ":\n"
                                    (cdr entry)
                                    "\n\n"))
                                 committed
                                 "")))
                    (should
                     (string-suffix-p
                      (concat "> " draft) (buffer-string)))
                    (should (= (- (point-max) (point)) 5)))))))
         (omnigent-disconnect))))))

;;; omnigent-integration-stream-drop-test.el ends here
