;;; test-utils.el --- Integration test helpers -*- lexical-binding: t; -*-

(require 'ert)
(require 'omnigent)
(require 'websocket)

(setq omnigent-server-url
      (or (getenv "OMNIGENT_TEST_SERVER_URL")
          (error "OMNIGENT_TEST_SERVER_URL is not set")))

(defconst omnigent-integration-harness
  (or (getenv "OMNIGENT_TEST_HARNESS") "claude-native")
  "Native harness under test, either claude-native or codex-native.")

(defconst omnigent-integration-agent-name
  (concat omnigent-integration-harness "-ui")
  "Name of the agent served by the integration fixture.")

(defconst omnigent-integration-model
  (if (equal omnigent-integration-harness "codex-native") "gpt-5.4" "claude-sonnet-4-6")
  "Configured model identifier of the integration agent.")

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
  "Create a mock native session and return its ID.
When WITH-HOST is non-nil, bind it to an online host.
Use WORKSPACE or a new isolated directory inside the temporary HOME."
  (let* ((agents (omnigent-mock-test-request "GET" "/v1/agents?limit=1000"))
         (agent (cl-find-if (lambda (item) (equal (alist-get 'name item) omnigent-integration-agent-name))
                            (append (alist-get 'data (cdr agents)) nil)))
         (data `(("agent_id" . ,(alist-get 'id agent)))))
    (when (equal omnigent-integration-harness "codex-native")
      (push '("terminal_launch_args" . ["--ask-for-approval" "on-request" "--sandbox" "workspace-write"]) data))
    (should agent)
    (when with-host
      (let* ((hosts (omnigent-mock-test-request "GET" "/v1/hosts"))
             (host (cl-find-if (lambda (item) (equal (alist-get 'status item) "online"))
                               (append (alist-get 'hosts (cdr hosts)) nil))))
        (should host)
        (setq data (append data `(("host_id" . ,(alist-get 'host_id host))
                                  ("workspace" . ,(or workspace
                                                      (make-temp-file
                                                       (expand-file-name "session-" (getenv "HOME")) t))))))))
    (let ((created (omnigent-mock-test-request "POST" "/v1/sessions" data)))
      (should (= (car created) 201))
      (should (alist-get 'id (cdr created)))
      (alist-get 'id (cdr created)))))

(defun omnigent-mock-model-requests (marker)
  "Return native streaming tool-enabled model requests that contain MARKER.
Exclude title generation and model probes, which are not agent turns."
  (let* ((omnigent-server-url (or (getenv "ANTHROPIC_BASE_URL")
                                (error "ANTHROPIC_BASE_URL is not set")))
         (response (omnigent-mock-test-request "GET" "/requests")))
    (should (= (car response) 200))
    (cl-remove-if-not
     (lambda (body)
       (and (eq (alist-get 'stream body) t)
            (> (length (alist-get 'tools body)) 0)
            (string-match-p (regexp-quote marker) (json-encode body))))
     (mapcar (lambda (request) (alist-get 'body request))
             (append (cdr response) nil)))))

(provide 'test-utils)
;;; test-utils.el ends here
