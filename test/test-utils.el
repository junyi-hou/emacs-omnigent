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

(defun omnigent-integration-create-session (&optional with-host workspace)
  "Create a mock agent session and return its ID.
When WITH-HOST is non-nil, bind it to an online host in WORKSPACE or HOME."
  (let* ((agents (omnigent-mock-test-request "GET" "/v1/agents?limit=1000"))
         (agent (cl-find-if (lambda (item) (equal (alist-get 'name item) "mock-acp"))
                            (append (alist-get 'data (cdr agents)) nil)))
         (data `(("agent_id" . ,(alist-get 'id agent)))))
    (should agent)
    (when with-host
      (let* ((hosts (omnigent-mock-test-request "GET" "/v1/hosts"))
             (host (cl-find-if (lambda (item) (equal (alist-get 'status item) "online"))
                               (append (alist-get 'hosts (cdr hosts)) nil))))
        (should host)
        (setq data (append data `(("host_id" . ,(alist-get 'host_id host))
                                  ("workspace" . ,(or workspace (getenv "HOME"))))))))
    (let ((created (omnigent-mock-test-request "POST" "/v1/sessions" data)))
      (should (= (car created) 201))
      (should (alist-get 'id (cdr created)))
      (alist-get 'id (cdr created)))))

(provide 'test-utils)
;;; test-utils.el ends here
