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

(defconst omnigent-mock-url
  (or (getenv "OMNIGENT_MOCK_URL")
      (error "OMNIGENT_MOCK_URL is not set"))
  "Base URL of the upstream mock LLM server backing the integration fixture.")

(defun omnigent-mock-required-tools ()
  "Return the advertised tool that guards scripted queues from background calls.
Title generation and other background requests advertise no tools, so a
queue guarded by an agent tool only answers real agent turns."
  (if (equal omnigent-integration-harness "codex-native")
      ["exec_command"] ["Read"]))

(defun omnigent-mock-request (method path &optional data)
  "Send METHOD to the mock LLM server at PATH with DATA and return the reply."
  (let ((omnigent-server-url omnigent-mock-url))
    (omnigent-mock-test-request method path data)))

(defun omnigent-mock-set-reply (text)
  "Make the mock answer every model request of this harness with TEXT.
The reply is a queue fallback, so it also serves background requests such as
title generation and survives mock resets."
  (dolist (key (list "default" omnigent-integration-model))
    (let ((reply (omnigent-mock-request "POST" "/mock/set_fallback"
                                        `(("key" . ,key) ("text" . ,text)
                                          ("stream" . t)))))
      (should (= (car reply) 200)))))

(defun omnigent-mock-configure (marker responses)
  "Script the mock with RESPONSES for the turn whose prompt contains MARKER.
RESPONSES is a vector of queued response alists in consumption order; each
supports `text', `thinking', `tool_calls', `delay', `block' and `usage' as
documented by the upstream mock LLM server."
  (let ((reply (omnigent-mock-request "POST" "/mock/configure"
                                      `(("match" . ,marker)
                                        ("required_tools" . ,(omnigent-mock-required-tools))
                                        ("responses" . ,responses)))))
    (should (= (car reply) 200))
    (should (= (alist-get 'count (cdr reply)) (length responses)))))

(defun omnigent-mock-gate-release ()
  "Release the oldest request blocked on a mock gate."
  (let ((reply (omnigent-mock-request "POST" "/gate/release")))
    (should (= (car reply) 200))))

(defun omnigent-mock-reset ()
  "Clear the mock's scripted queues and captured requests."
  (let ((reply (omnigent-mock-request "POST" "/mock/reset")))
    (should (= (car reply) 200))))

(defconst omnigent-mock-fixture-directory
  (expand-file-name "fixtures" (file-name-directory load-file-name))
  "Directory of JSON mock fixtures mirrored from the upstream test suite.")

(defun omnigent-mock-fixture-data (name)
  "Return the parsed contents of mock fixture NAME."
  (let ((path (expand-file-name (concat name ".json") omnigent-mock-fixture-directory)))
    (with-temp-buffer
      (insert-file-contents path)
      (json-parse-string (buffer-string)
                         :object-type 'alist :array-type 'array
                         :null-object nil :false-object :json-false))))

(defun omnigent-mock-fixture-responses (data)
  "Return the response vector of fixture DATA for the harness under test.
Fixtures shared by both harnesses keep a `responses' array; harness-specific
fixtures keep a `responses_by_harness' mapping keyed by harness name."
  (or (alist-get 'responses data)
      (alist-get (intern omnigent-integration-harness)
                 (alist-get 'responses_by_harness data))))

(defun omnigent-mock-fixture-response (name &optional index)
  "Return mock fixture NAME's response alist at INDEX, defaulting to the first."
  (let* ((data (omnigent-mock-fixture-data name))
         (responses (omnigent-mock-fixture-responses data)))
    (should responses)
    (elt responses (or index 0))))

(defun omnigent-mock-fixture-reply (name)
  "Return the first response text of mock fixture NAME."
  (alist-get 'text (omnigent-mock-fixture-response name)))

(defun omnigent-mock-configure-fixture (name marker)
  "Script the mock from fixture NAME for the turn whose prompt contains MARKER.
Return the fixture's prompt with MARKER appended."
  (let* ((data (omnigent-mock-fixture-data name))
         (responses (omnigent-mock-fixture-responses data))
         (prompt (alist-get 'prompt data)))
    (should responses)
    (should prompt)
    (omnigent-mock-configure marker responses)
    (concat prompt "\n" marker)))

(defun omnigent-mock-model-requests (marker)
  "Return captured tool-enabled model requests whose prompt contains MARKER."
  (let ((response (omnigent-mock-request "GET" "/mock/requests")))
    (should (= (car response) 200))
    (cl-remove-if-not
     (lambda (body)
       (and (> (length (alist-get 'tools body)) 0)
            (string-match-p (regexp-quote marker) (json-encode body))))
     (append (alist-get 'requests (cdr response)) nil))))

(provide 'test-utils)
;;; test-utils.el ends here
