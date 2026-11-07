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

(ert-deftest omnigent-conversation-elicitations-reconcile-snapshot ()
  (with-temp-buffer
    (setq omnigent-conversation--items (make-hash-table :test 'equal)
          omnigent-conversation--elicitations (make-hash-table :test 'equal)
          omnigent-conversation--elicitation-drafts (make-hash-table :test 'equal)
          omnigent-conversation--elicitation-submitting (make-hash-table :test 'equal)
          omnigent-conversation--loading t)
    (omnigent-conversation--event "response.elicitation_resolved"
                                  '((elicitation_id . "old")))
    (omnigent-conversation--event "response.elicitation_request"
                                  '((elicitation_id . "new")))
    (omnigent-conversation--snapshot
     200 '((pending_elicitations . [((elicitation_id . "old"))])))
    (should-not (gethash "old" omnigent-conversation--elicitations))
    (should (gethash "new" omnigent-conversation--elicitations))))

(ert-deftest omnigent-conversation-elicitation-drafts-and-change-hook ()
  (with-temp-buffer
    (setq omnigent-conversation--items (make-hash-table :test 'equal)
          omnigent-conversation--elicitations (make-hash-table :test 'equal)
          omnigent-conversation--elicitation-drafts (make-hash-table :test 'equal))
    (let ((changes 0))
      (add-hook 'omnigent-conversation-elicitation-change-hook
                (lambda () (cl-incf changes)) nil t)
      (omnigent-conversation--event "response.elicitation_request" '((elicitation_id . "keep")))
      (should (= changes 1))
      (let ((draft (omnigent-conversation-elicitation-draft "keep")))
        (puthash "answer" "draft" draft)
        (omnigent-conversation-elicitation-set-draft "keep" draft))
      (should (= changes 2))
      (omnigent-conversation--event "response.elicitation_request" '((elicitation_id . "stale")))
      (setq omnigent-conversation--loading t)
      (omnigent-conversation--snapshot
       200 '((pending_elicitations . [((elicitation_id . "keep"))])))
      (should (= changes 4))
      (should (equal (gethash "answer" (omnigent-conversation-elicitation-draft "keep")) "draft"))
      (should-not (gethash "stale" omnigent-conversation--elicitation-drafts))
      (omnigent-conversation--event "response.elicitation_resolved" '((elicitation_id . "keep")))
      (should (= changes 5))
      (should-not (gethash "keep" omnigent-conversation--elicitation-drafts)))))

(ert-deftest omnigent-conversation-elicitation-submit-after-failure ()
  (with-temp-buffer
    (setq omnigent-conversation-session-id "session"
          omnigent-conversation--elicitations (make-hash-table :test 'equal)
          omnigent-conversation--elicitation-drafts (make-hash-table :test 'equal)
          omnigent-conversation--elicitation-submitting (make-hash-table :test 'equal))
    (omnigent-conversation--elicitation-put
     '((elicitation_id . "id") (params . ((requestedSchema .
       ((type . "object") (required . ["name"])
        (properties . ((name . ((type . "string") (minLength . 2)))))))))))
    (should (omnigent-conversation-elicitation-validate "id"))
    (let ((draft (omnigent-conversation-elicitation-draft "id")) cb payload (changes 0))
      (add-hook 'omnigent-conversation-elicitation-change-hook
                (lambda () (cl-incf changes)) nil t)
      (puthash "name" "ok" draft)
      (omnigent-conversation-elicitation-set-draft "id" draft)
      (cl-letf (((symbol-function 'omnigent-transport-request)
                 (lambda (_method _path callback data) (setq cb callback payload data))))
        (omnigent-conversation-elicitation-submit "id" 'accept nil)
        (should (= changes 2))
        (should (omnigent-conversation-elicitation-submitting-p "id"))
        (should (equal (gethash "name" (alist-get "content" payload nil nil #'equal)) "ok"))
        (funcall cb 500 nil)
        (should (= changes 3))
        (should (gethash "id" omnigent-conversation--elicitations))
        (should (equal (gethash "name" (omnigent-conversation-elicitation-draft "id")) "ok"))
        (omnigent-conversation-elicitation-submit "id" 'accept nil)
        (funcall cb 202 nil)
        (should (= changes 5))
        (should-not (gethash "id" omnigent-conversation--elicitations))
        (should-not (gethash "id" omnigent-conversation--elicitation-drafts))
        ;; A resolution event after the response must also be harmless.
        (omnigent-conversation--event "response.elicitation_resolved" '((elicitation_id . "id")))))))

(ert-deftest omnigent-conversation-elicitation-submit-guards ()
  (with-temp-buffer
    (setq omnigent-conversation-session-id "session"
          omnigent-conversation--elicitations (make-hash-table :test 'equal)
          omnigent-conversation--elicitation-drafts (make-hash-table :test 'equal)
          omnigent-conversation--elicitation-submitting (make-hash-table :test 'equal))
    (omnigent-conversation--elicitation-put
     '((elicitation_id . "id") (params . ((requestedSchema .
       ((type . "object") (required . ["name"])
        (properties . ((name . ((type . "string")))))))))))
    (let (callback (requests 0))
      (cl-letf (((symbol-function 'omnigent-transport-request)
                 (lambda (_method _path cb _data) (cl-incf requests) (setq callback cb))))
        (should-error (omnigent-conversation-elicitation-submit "id" 'accept nil) :type 'user-error)
        (should (= requests 0))
        ;; Decline does not require a valid draft.
        (omnigent-conversation-elicitation-submit "id" 'decline nil)
        (should-error (omnigent-conversation-elicitation-submit "id" 'cancel nil) :type 'user-error)
        (should (= requests 1))
        ;; Resolution may arrive before the HTTP response.
        (omnigent-conversation--event "response.elicitation_resolved" '((elicitation_id . "id")))
        (funcall callback 202 nil)
        (should-not (omnigent-conversation-elicitation-submitting-p "id"))
        (should-not (gethash "id" omnigent-conversation--elicitations))))
    (omnigent-conversation--elicitation-put '((elicitation_id . "id")))
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (&rest _) (error "Transport failed"))))
      (should-error (omnigent-conversation-elicitation-submit "id" 'cancel nil))
      (should-not (omnigent-conversation-elicitation-submitting-p "id"))
      (should (gethash "id" omnigent-conversation--elicitations)))
    (omnigent-conversation--elicitation-put
     '((elicitation_id . "external") (params . ((url . "https://example.test/")))))
    (should-error (omnigent-conversation-elicitation-submit "external" 'decline nil) :type 'user-error)))

(ert-deftest omnigent-conversation-elicitation-submit-wire-format ()
  (with-temp-buffer
    (setq omnigent-conversation-session-id "session /"
          omnigent-conversation--elicitations (make-hash-table :test 'equal)
          omnigent-conversation--elicitation-drafts (make-hash-table :test 'equal)
          omnigent-conversation--elicitation-submitting (make-hash-table :test 'equal))
    (omnigent-conversation--elicitation-put
     '((elicitation_id . "id / malformed") (params . ((requestedSchema .
       ((type . "object") (properties . ((answer . ((type . ["boolean" "null"])))))))))))
    (let ((draft (omnigent-conversation-elicitation-draft "id / malformed")))
      (puthash "answer" :json-false draft)
      (omnigent-conversation-elicitation-set-draft "id / malformed" draft))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (url _callback _args &rest _)
                 (should (string-suffix-p "/v1/sessions/session%20%2F/elicitations/id%20%2F%20malformed/resolve" url))
                 (should (equal url-request-method "POST"))
                 (let* ((body (json-parse-string url-request-data :object-type 'hash-table
                                                 :null-object :null :false-object :json-false))
                        (content (gethash "content" body)))
                   (should (equal (gethash "action" body) "accept"))
                   (should (eq (gethash "answer" content) :json-false))))))
      (omnigent-conversation-elicitation-submit "id / malformed" 'accept nil))))

(ert-deftest omnigent-conversation-elicitation-validation-and-json-values ()
  "Validate defaults, false, null, constraints, and unsupported keywords."
  (with-temp-buffer
    (setq omnigent-conversation-session-id "session"
          omnigent-conversation--elicitations (make-hash-table :test 'equal)
          omnigent-conversation--elicitation-drafts (make-hash-table :test 'equal)
          omnigent-conversation--elicitation-submitting (make-hash-table :test 'equal))
    (omnigent-conversation--elicitation-put
     '((elicitation_id . "id")
       (params . ((requestedSchema .
        ((type . "object") (required . ["enabled" "choice"])
         (properties . ((enabled . ((type . "boolean") (default . :json-false)))
                        (choice . ((type . ["string" "null"]) (enum . ["yes" nil])))
                        (count . ((type . "integer") (minimum . 1) (maximum . 3)))
                        (name . ((type . "string") (minLength . 2) (maxLength . 4)))))))))))
    (let ((draft (omnigent-conversation-elicitation-draft "id")) payload)
      (should (eq (gethash "enabled" draft) :json-false))
      (should (assoc "choice" (omnigent-conversation-elicitation-validate "id")))
      (puthash "choice" :null draft)
      (puthash "count" 4 draft)
      (puthash "name" "x" draft)
      (omnigent-conversation-elicitation-set-draft "id" draft)
      (should (assoc "count" (omnigent-conversation-elicitation-validate "id")))
      (should (assoc "name" (omnigent-conversation-elicitation-validate "id")))
      (puthash "count" 2 draft)
      (puthash "name" "ok" draft)
      (omnigent-conversation-elicitation-set-draft "id" draft)
      (should-not (omnigent-conversation-elicitation-validate "id"))
      (cl-letf (((symbol-function 'omnigent-transport-request)
                 (lambda (_method _path _callback data) (setq payload data))))
        (omnigent-conversation-elicitation-submit "id" 'accept nil))
      (let* ((encoded (json-encode payload))
             (content (gethash "content" (json-parse-string encoded :object-type 'hash-table
                                                             :null-object :null :false-object :json-false))))
        (should (eq (gethash "enabled" content) :json-false))
        (should (eq (gethash "choice" content) :null)))
      (omnigent-conversation--elicitation-put
       '((elicitation_id . "other") (params . ((requestedSchema .
          ((type . "object") (properties . ((name . ((type . "string") (pattern . "x")))))))))))
      (should (assoc "name" (omnigent-conversation-elicitation-validate "other")))
      (should-error (omnigent-conversation-elicitation-submit "other" 'accept nil)
                    :type 'user-error))))

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
          omnigent-conversation--elicitations (make-hash-table :test 'equal)
          omnigent-conversation--elicitation-drafts (make-hash-table :test 'equal)
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
    (omnigent-conversation--put-item '((id . "after-reload")))
    (should (equal omnigent-conversation--order '("new" "after-reload")))
    (should (equal (omnigent-conversation--text
                    (gethash "new" omnigent-conversation--items))
                   "snapshot recovered"))
    (omnigent-conversation--event
     "response.output_text.delta" '((item_id . "new") (delta . " live")))
    (should (equal (omnigent-conversation--text
                    (gethash "new" omnigent-conversation--items))
                   "snapshot recovered live"))))

(ert-deftest omnigent-conversation-history-limit ()
  (with-temp-buffer
    (let ((omnigent-transport-history-limit 2))
      (setq omnigent-conversation--items (make-hash-table :test 'equal))
      (omnigent-conversation--put-item '((id . "first")))
      (omnigent-conversation--put-item '((id . "second")))
      (omnigent-conversation--put-item '((id . "second") (content . "updated")))
      (should (equal omnigent-conversation--order '("first" "second")))
      (omnigent-conversation--put-item '((id . "third")))
      (should (equal omnigent-conversation--order '("second" "third")))
      (should-not (gethash "first" omnigent-conversation--items))
      (should (= (hash-table-count omnigent-conversation--items) 2)))))

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
