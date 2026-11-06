;;; test-utils.el --- Integration test helpers -*- lexical-binding: t; -*-

(require 'ert)
(require 'omnigent)
(require 'websocket)

(setq omnigent-server-url
      (or (getenv "OMNIGENT_TEST_SERVER_URL")
          (error "OMNIGENT_TEST_SERVER_URL is not set")))

(defun omnigent-mock-test-request (method path &optional data)
  "Send METHOD to PATH with DATA and return the response."
  (let (result)
    (omnigent-transport-request method path
                                (lambda (status body) (setq result (cons status body)))
                                data)
    (with-timeout (30 (ert-fail (format "Request timed out: %s %s" method path)))
      (while (not result) (accept-process-output nil 0.1)))
    result))

(defun omnigent-integration-create-session ()
  "Create a session for the mock agent and return its ID."
  (let* ((agents (omnigent-mock-test-request "GET" "/v1/agents?limit=1000"))
         (agent (cl-find-if (lambda (item) (equal (alist-get 'name item) "mock-acp"))
                            (append (alist-get 'data (cdr agents)) nil))))
    (should agent)
    (let ((created (omnigent-mock-test-request
                    "POST" "/v1/sessions" `(("agent_id" . ,(alist-get 'id agent))))))
      (should (= (car created) 201))
      (should (alist-get 'id (cdr created)))
      (alist-get 'id (cdr created)))))

(provide 'test-utils)
;;; test-utils.el ends here
