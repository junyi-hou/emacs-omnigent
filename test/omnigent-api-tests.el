;;; omnigent-api-tests.el --- Omnigent API integration tests -*- lexical-binding: t; -*-

(require 'test-utils)

(ert-deftest omnigent-api-session-list ()
  "List a session created on the temporary server."
  (let* ((id (omnigent-integration-create-session))
         (response (omnigent-mock-test-request "GET" "/v1/sessions?limit=1000&include_archived=true&sort_by=updated_at&order=desc")))
    (should (= (car response) 200))
    (should (equal (alist-get 'object (cdr response)) "list"))
    (should (cl-find id (append (alist-get 'data (cdr response)) nil)
                     :key (lambda (row) (alist-get 'id row)) :test #'equal))))

(ert-deftest omnigent-api-session-get-and-delete ()
  "Get and delete a session."
  (let* ((id (omnigent-integration-create-session))
         (path (omnigent-transport--session-path id))
         (response (omnigent-mock-test-request "GET" path)))
    (should (= (car response) 200))
    (should (equal (alist-get 'id (cdr response)) id))
    (should (memq (car (omnigent-mock-test-request "DELETE" path)) '(200 204)))
    (should (= (car (omnigent-mock-test-request "GET" path)) 404))))

(ert-deftest omnigent-api-session-updates-watch ()
  "Watch a session and receive its snapshot."
  (let ((id (omnigent-integration-create-session)) frames failure updates)
    (unwind-protect
        (progn
          (setq updates (omnigent-transport-start-session-updates
                         (lambda (frame) (push frame frames))
                         (lambda (error) (setq failure error))))
          (omnigent-transport-set-session-updates-watch updates (list id))
          (with-timeout (15 (ert-fail (format "Timed out waiting for snapshot: %S" failure)))
            (while (not (cl-some
                         (lambda (frame)
                           (and (equal (alist-get 'type frame) "snapshot")
                                (cl-find id (append (alist-get 'items frame) nil)
                                         :key (lambda (row) (alist-get 'id row))
                                         :test #'equal))) frames))
              (accept-process-output nil 0.1)))
          (should-not failure))
      (when updates (omnigent-transport-stop-session-updates updates)))))

(ert-deftest omnigent-api-session-message-event ()
  "Post a message event and check the server response."
  (let* ((id (omnigent-integration-create-session t))
         (response
          (omnigent-mock-test-request
           "POST" (omnigent-transport--session-path id "/events")
           '(("type" . "message")
             ("data" . (("role" . "user")
                        ("content" . [(("type" . "input_text")
                                       ("text" . "test agent_message"))])))))))
    (should (= (car response) 202))
    (should (eq (alist-get 'queued (cdr response)) t))
    (with-timeout (30 (ert-fail "Timed out waiting for committed message"))
      (let (item)
        (while (not item)
          (let* ((snapshot (omnigent-mock-test-request
                            "GET" (omnigent-transport--session-path id)))
                 (items (append (alist-get 'items (cdr snapshot)) nil)))
            (should (= (car snapshot) 200))
            (setq item (cl-find-if
                        (lambda (entry)
                          (and (equal (alist-get 'type entry) "message")
                               (equal (alist-get 'role (alist-get 'data entry)) "user")))
                        items)))
          (unless item (sleep-for 0.2)))
        (with-temp-buffer
          (setq omnigent-conversation--items (make-hash-table :test 'equal))
          (omnigent-conversation--put-item item)
          (let ((parsed (gethash (alist-get 'id item) omnigent-conversation--items)))
            (should (equal (alist-get 'role parsed) "user"))
            (should (equal (omnigent-conversation--text parsed) "test agent_message"))))))))

(provide 'omnigent-api-tests)
;;; omnigent-api-tests.el ends here
