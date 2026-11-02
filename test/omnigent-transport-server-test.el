;;; omnigent-transport-server-test.el --- Omnigent server integration test -*- lexical-binding: t; -*-

(require 'ert)
(require 'omnigent-transport)

(setq omnigent-server-url
      (or (getenv "OMNIGENT_TEST_SERVER_URL")
          (error "OMNIGENT_TEST_SERVER_URL is not set")))

(ert-deftest omnigent-transport-requests-session-list-from-server ()
  "Check that the REST client reads the session list from a live server."
  (let (done result)
    (omnigent-list-sessions
     (lambda (status body)
       (setq result (cons status body)
             done t)))
    (with-timeout (10 (ert-fail "Omnigent server request timed out"))
      (while (not done)
        (accept-process-output nil 0.1)))
    (should (equal (car result) 200))
    (should (equal (cdr (assq 'object (cdr result))) "list"))
    (should (vectorp (cdr (assq 'data (cdr result)))))))

(ert-deftest omnigent-transport-receives-server-sse-event ()
  "Receive a transient SSE event from a local Omnigent session."
  (let (agent-response session-response snapshot acknowledgement received stream-error
        stream)
    (omnigent-request "GET" "/v1/agents"
                      (lambda (status body)
                        (setq agent-response (cons status body))))
    (unwind-protect
        (with-timeout (20 (ert-fail "Timed out waiting for a server SSE event"))
          (while (not agent-response)
            (accept-process-output nil 0.1))
          (should (equal (car agent-response) 200))
          (let* ((agents (cdr (assq 'data (cdr agent-response))))
                 (agent-id (cdr (assq 'id (aref agents 0)))))
            (omnigent-request "POST" "/v1/sessions"
                              (lambda (status body)
                                (setq session-response (cons status body)))
                              `(("agent_id" . ,agent-id)))
            (while (not session-response)
              (accept-process-output nil 0.1))
            (should (equal (car session-response) 201))
            (let ((session-id (cdr (assq 'id (cdr session-response)))))
              (setq stream
                    (omnigent-start-session-stream
                     session-id
                     (lambda (name data)
                       (when (equal name "response.output_text.delta")
                         (setq received data)))
                     (lambda (status body)
                       (setq snapshot (cons status body)))
                     (lambda (error)
                       (setq stream-error error))))
              (while (not snapshot)
                (accept-process-output nil 0.1))
              (should (equal (car snapshot) 200))
              (omnigent-post-session-event
               session-id
               '(("type" . "external_output_text_delta")
                 ("data" . (("delta" . "transport-test"))))
               (lambda (status body)
                 (setq acknowledgement (cons status body))))
              (while (not (and acknowledgement received))
                (accept-process-output nil 0.1))
              (should (equal (car acknowledgement) 202))
              (should (equal (cdr (assq 'delta received)) "transport-test"))
              (should-not stream-error))))
      (when stream
        (omnigent-stop-session-stream stream)))))

(provide 'omnigent-transport-server-test)
;;; omnigent-transport-server-test.el ends here
