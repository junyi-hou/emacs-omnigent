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

(ert-deftest omnigent-conversation-send-preserves-edits-while-pending ()
  "Only clear the submitted prefix; reject concurrent and empty sends."
  (dolist (case '(("draft appended" 202 " appended")
                  ("replacement" 202 "replacement")
                  ("draft appended" 500 "draft appended")))
    (pcase-let ((`(,edited ,status ,remaining) case))
      (with-temp-buffer
        (setq omnigent-conversation-session-id "session"
              omnigent-conversation--prompt-start (copy-marker (point-min)))
        (insert "draft")
        (let (callback payload (requests 0))
          (cl-letf (((symbol-function 'omnigent-transport-post-session-event)
                     (lambda (id data cb)
                       (should (equal id "session"))
                       (cl-incf requests)
                       (setq callback cb payload data))))
            (omnigent-conversation-send)
            (should omnigent-conversation--sending)
            (should (equal payload
                           '(("type" . "message")
                             ("data" . (("role" . "user")
                                        ("content" . [(("type" . "input_text")
                                                       ("text" . "draft"))]))))))
            (should-error (omnigent-conversation-send) :type 'user-error)
            (should (= requests 1))
            (erase-buffer)
            (insert edited)
            (funcall callback status nil)
            (should-not omnigent-conversation--sending)
            (should (equal (buffer-string) remaining))
            (erase-buffer)
            (insert " \n\t")
            (should-error (omnigent-conversation-send) :type 'user-error)
            (should-not omnigent-conversation--sending)
            (should (= requests 1))))))))

(ert-deftest omnigent-conversation-send-recovers-from-synchronous-error ()
  "Keep the draft and permit retry if submission throws before a callback."
  (with-temp-buffer
    (setq omnigent-conversation-session-id "session"
          omnigent-conversation--prompt-start (copy-marker (point-min)))
    (insert "draft")
    (cl-letf (((symbol-function 'omnigent-transport-post-session-event)
               (lambda (&rest _) (error "Submission failed"))))
      (should-error (omnigent-conversation-send))
      (should-not omnigent-conversation--sending)
      (should (equal (buffer-string) "draft")))
    (cl-letf (((symbol-function 'omnigent-transport-post-session-event)
               (lambda (_id _data callback) (funcall callback 202 nil))))
      (omnigent-conversation-send)
      (should-not omnigent-conversation--sending)
      (should (equal (buffer-string) "")))))

(ert-deftest omnigent-conversation-failed-snapshot-replays-events-and-recovers ()
  "Retain existing items on failure and replay queued events in order."
  (with-temp-buffer
    (setq omnigent-conversation--items (make-hash-table :test 'equal)
          omnigent-conversation--loading t)
    (omnigent-conversation--put-item '((id . "existing") (content . "keep")))
    (omnigent-conversation--event
     "response.output_item.added" '((item . ((id . "new") (content . "")))))
    (omnigent-conversation--event
     "response.output_text.delta" '((item_id . "new") (delta . "first")))
    (omnigent-conversation--event
     "response.output_text.delta" '((item_id . "new") (delta . " second")))
    (should (= (length omnigent-conversation--pending-events) 3))
    (should-not (gethash "new" omnigent-conversation--items))
    (omnigent-conversation--snapshot 500 nil)
    (should-not omnigent-conversation--loading)
    (should-not omnigent-conversation--pending-events)
    (should (equal omnigent-conversation--order '("existing" "new")))
    (should (equal (omnigent-conversation--text
                    (gethash "existing" omnigent-conversation--items)) "keep"))
    (should (equal (omnigent-conversation--text
                    (gethash "new" omnigent-conversation--items)) "first second"))
    ;; The next connection loads a fresh snapshot before applying new deltas.
    (setq omnigent-conversation--loading t)
    (omnigent-conversation--event
     "response.output_text.delta" '((item_id . "new") (delta . " recovered")))
    (omnigent-conversation--snapshot
     200 '((items . [((id . "new") (content . "snapshot"))])))
    (should-not omnigent-conversation--loading)
    (should-not omnigent-conversation--pending-events)
    (should-not (gethash "existing" omnigent-conversation--items))
    (should (equal omnigent-conversation--order '("new")))
    (should (equal (omnigent-conversation--text
                    (gethash "new" omnigent-conversation--items))
                   "snapshot recovered"))
    (omnigent-conversation--event
     "response.output_text.delta" '((item_id . "new") (delta . " live")))
    (should (equal (omnigent-conversation--text
                    (gethash "new" omnigent-conversation--items))
                   "snapshot recovered live"))))

(ert-deftest omnigent-conversation-accumulates-text-and-reasoning-deltas ()
  "Append each supported delta without changing item order or other items."
  (dolist (event '("response.output_text.delta" "response.reasoning_text.delta"
                   "response.reasoning_summary_text.delta"))
    (with-temp-buffer
      (setq omnigent-conversation--items (make-hash-table :test 'equal))
      (omnigent-conversation--put-item
       (copy-tree '((id . "first") (content . [((type . "text") (text . "start"))])) t))
      (omnigent-conversation--put-item '((id . "second") (content . "untouched")))
      (omnigent-conversation--event event '((item_id . "first") (delta . " one")))
      (omnigent-conversation--event event '((item_id . "first") (delta . " two")))
      (omnigent-conversation--event event '((item_id . "first")))
      (should (equal (omnigent-conversation--text
                      (gethash "first" omnigent-conversation--items)) "start one two"))
      (should (equal (omnigent-conversation--text
                      (gethash "second" omnigent-conversation--items)) "untouched"))
      (should (equal omnigent-conversation--order '("first" "second"))))))

(ert-deftest omnigent-conversation-ignores-deltas-without-known-items ()
  "Unknown or missing item IDs must not create transcript entries."
  (with-temp-buffer
    (setq omnigent-conversation--items (make-hash-table :test 'equal))
    (dolist (event '("response.output_text.delta" "response.reasoning_text.delta"
                     "response.reasoning_summary_text.delta"))
      (omnigent-conversation--event event '((item_id . "unknown") (delta . "text")))
      (omnigent-conversation--event event '((delta . "text"))))
    (should (= (hash-table-count omnigent-conversation--items) 0))
    (should-not omnigent-conversation--order)))

(ert-deftest omnigent-conversation-full-items-replace-without-reordering ()
  "Added and done events replace existing items without duplicating IDs."
  (with-temp-buffer
    (setq omnigent-conversation--items (make-hash-table :test 'equal))
    (omnigent-conversation--event
     "response.output_item.added" '((item . ((id . "first") (content . "partial")))))
    (omnigent-conversation--event
     "response.output_item.added" '((item . ((id . "second") (content . "other")))))
    (dolist (event '("response.output_item.added" "response.output_item.done"))
      (omnigent-conversation--event
       event '((item . ((id . "first") (type . "message")
                        (data . ((role . "assistant") (content . "complete")))))))
      (should (equal omnigent-conversation--order '("first" "second")))
      (should (= (hash-table-count omnigent-conversation--items) 2))
      (let ((item (gethash "first" omnigent-conversation--items)))
        (should (equal (alist-get 'role item) "assistant"))
        (should (equal (omnigent-conversation--text item) "complete"))))))

(ert-deftest omnigent-conversation-records-response-errors ()
  "Record both error events, with nested errors or the full event payload."
  (dolist (event '("response.error" "response.failed"))
    (dolist (data '(((error . "Runner failed")) ((message . "Failure details"))))
      (with-temp-buffer
        (setq omnigent-conversation--items (make-hash-table :test 'equal))
        (omnigent-conversation--put-item '((id . "message") (content . "keep")))
        (omnigent-conversation--event event data)
        (should (= (hash-table-count omnigent-conversation--items) 2))
        (should (equal (car omnigent-conversation--order) "message"))
        (let* ((id (cadr omnigent-conversation--order))
               (item (gethash id omnigent-conversation--items)))
          (should (string-prefix-p "error-" id))
          (should (equal (alist-get 'type item) "error"))
          (should (equal (omnigent-conversation--text item)
                         (format "%s" (or (alist-get 'error data) data)))))
        (should (equal (omnigent-conversation--text
                        (gethash "message" omnigent-conversation--items)) "keep"))))))

(ert-deftest omnigent-conversation-interrupt-sends-valid-json ()
  "The interrupt must omit optional data or encode it as an object, not null."
  (with-temp-buffer
    (setq omnigent-conversation-session-id "session")
    (let (sent)
      (cl-letf (((symbol-function 'omnigent-transport-post-session-event)
                 (lambda (id event callback)
                   (should (equal id "session"))
                   (setq sent t)
                   (let ((payload (json-parse-string (json-encode event) :object-type 'hash-table)))
                     (should (equal (gethash "type" payload) "interrupt"))
                     (should (or (eq (gethash "data" payload :absent) :absent)
                                 (hash-table-p (gethash "data" payload)))))
                   (funcall callback 202 nil))))
        (omnigent-conversation-interrupt)
        (should sent)))))

(provide 'omnigent-conversation-test)
