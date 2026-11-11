;;; omnigent-functional-tests.el --- Mock ACP functional tests -*- lexical-binding: t; -*-

(require 'test-utils)

(ert-deftest omnigent-mock-acp-agent-turn ()
  "Send a message through Omnigent to the mock ACP agent."
  (let ((omnigent-current-session-id nil)
        (omnigent-current-session nil)
        snapshot acknowledgement received stream-error stream events
        updates frames updates-error)
    (unwind-protect
        (progn
          (let* ((agents (omnigent-mock-test-request "GET" "/v1/agents?limit=1000"))
                 (hosts (omnigent-mock-test-request "GET" "/v1/hosts"))
                 (agent (cl-find-if (lambda (item)
                                      (equal (cdr (assq 'name item)) omnigent-integration-agent-name))
                                    (append (cdr (assq 'data (cdr agents))) nil)))
                 (host (aref (cdr (assq 'hosts (cdr hosts))) 0))
                 (created (omnigent-mock-test-request
                           "POST" "/v1/sessions"
                           `(("agent_id" . ,(cdr (assq 'id agent)))
                             ("host_id" . ,(cdr (assq 'host_id host)))
                             ("workspace" . ,(getenv "HOME"))))))
            (should agent)
            (should (equal (car created) 201))
            (setq omnigent-current-session-id (cdr (assq 'id (cdr created)))))
          (setq updates
                (omnigent-transport-start-session-updates
                 (lambda (frame) (push frame frames))
                 (lambda (error) (setq updates-error error))))
          (omnigent-transport-set-session-updates-watch
           updates (list omnigent-current-session-id))
          (with-timeout (15 (ert-fail "Timed out waiting for WebSocket snapshot"))
            (while (not (cl-some
                         (lambda (frame)
                           (and (equal (cdr (assq 'type frame)) "snapshot")
                                (cl-some (lambda (item)
                                           (equal (cdr (assq 'id item))
                                                  omnigent-current-session-id))
                                         (append (cdr (assq 'items frame)) nil))))
                         frames))
              (accept-process-output nil 0.1)))
          (setq stream
                (omnigent-transport-start-session-stream
                 omnigent-current-session-id
                 (lambda (name data)
                   (push (cons name data) events)
                   (when (equal name "response.output_text.delta")
                     (push (cdr (assq 'delta data)) received)))
                 (lambda (status body) (setq snapshot (cons status body)))
                 (lambda (error) (setq stream-error error))))
          (with-timeout (30 (ert-fail (format "Mock ACP turn timed out: ack=%S error=%S events=%S" acknowledgement stream-error events)))
            (while (not snapshot) (accept-process-output nil 0.1))
            (should (equal (car snapshot) 200))
            (setq frames nil)
            (omnigent-transport-post-session-event
             omnigent-current-session-id
             '(("type" . "message")
               ("data" . (("role" . "user")
                          ("content" . [(("type" . "input_text")
                                         ("text" . "test agent_message"))]))))
             (lambda (status body) (setq acknowledgement (cons status body))))
            (while (not acknowledgement) (accept-process-output nil 0.1))
            (should (equal (car acknowledgement) 202))
            (while (not (and (string-match-p "The capital of France is Paris\\."
                                              (mapconcat #'identity (reverse received) ""))
                             (cl-some
                              (lambda (frame)
                                (and (equal (cdr (assq 'type frame)) "changed")
                                     (cl-some (lambda (item)
                                                (equal (cdr (assq 'id item))
                                                       omnigent-current-session-id))
                                              (append (cdr (assq 'items frame)) nil))))
                              frames)))
              (accept-process-output nil 0.1)))
          (should-not stream-error)
          (should-not updates-error))
      (when stream (omnigent-transport-stop-session-stream stream))
      (when updates (omnigent-transport-stop-session-updates updates)))))

(ert-deftest omnigent-mock-acp-conversation-header ()
  "Show available session data before and after a mock ACP usage update."
  (let ((id (omnigent-integration-create-session t)) buffer observer snapshot events)
    (unwind-protect
        (save-window-excursion
          (omnigent-conversation-open id)
          (setq buffer (current-buffer))
          (setq observer (omnigent-transport-start-session-stream
                          id (lambda (name data) (push (cons name data) events))
                          (lambda (status _body) (setq snapshot status))))
          (with-timeout (15 (ert-fail "Conversation snapshot timed out"))
            (while (or (not snapshot)
                       (with-current-buffer buffer omnigent-conversation--loading))
              (accept-process-output nil 0.1)))
          (should (= snapshot 200))
          (with-current-buffer buffer
            (should (string-prefix-p
                     (format "Harness: %s | Model: %s | "
                             omnigent-integration-harness omnigent-integration-model)
                     header-line-format))
            (insert "test usage")
            (omnigent-conversation-send))
          (with-timeout (30 (ert-fail "Mock usage turn timed out"))
            (while (not (and (assoc "response.output_text.delta" events)
                             (omnigent-functional-status-p id "idle")))
              (accept-process-output nil 0.1)))
          (omnigent-functional-wait "Mock usage did not reach the header"
            (with-current-buffer buffer
              (numberp (alist-get 'last_total_tokens omnigent-conversation-header-data))))
          (with-current-buffer buffer
            (should (string-prefix-p
                     (format "Harness: %s | Model: %s | "
                             omnigent-integration-harness omnigent-integration-model)
                     header-line-format))
            (should (= (alist-get 'last_total_tokens omnigent-conversation-header-data)
                       512))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when observer (omnigent-transport-stop-session-stream observer)))))

(ert-deftest omnigent-session-list-refresh ()
  "Load a session created on the temporary server."
  (let ((id (omnigent-integration-create-session))
        (omnigent-sessions nil)
        (omnigent-sessions--refresh-number 0)
        (omnigent-sessions--revision 0)
        loaded)
    (let ((omnigent-sessions-change-hook (list (lambda () (setq loaded t)))))
      (omnigent-sessions-refresh)
      (with-timeout (15 (ert-fail "Timed out loading session list"))
        (while (not loaded) (accept-process-output nil 0.1)))
      (should (cl-find id omnigent-sessions
                       :key (lambda (row) (alist-get 'id row)) :test #'equal)))))

(ert-deftest omnigent-mock-acp-reopen-completed-conversation ()
  "Restore a completed exchange from the snapshot after reopening."
  (let ((id (omnigent-integration-create-session t)) buffer observer events failure snapshot)
    (unwind-protect
        (save-window-excursion
          (omnigent-conversation-open id)
          (setq buffer (current-buffer))
          (setq observer (omnigent-transport-start-session-stream
                          id (lambda (name data) (push (cons name data) events))
                          (lambda (status _body) (setq snapshot status))
                          (lambda (err) (setq failure err))))
          (with-timeout (15 (ert-fail "Conversation snapshot timed out"))
            (while (or (not snapshot)
                       (with-current-buffer buffer omnigent-conversation--loading))
              (accept-process-output nil 0.1)))
          (should (= snapshot 200))
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert "test agent_message")
            (omnigent-conversation-send))
          (with-timeout (30 (ert-fail (format "Turn did not finish: %S" events)))
            (while (not (and (omnigent-functional-exchange-stored-p
                             id "test agent_message" "The capital of France is Paris.")
                            (omnigent-functional-status-p id "idle")))
              (accept-process-output nil 0.1)))
          (should-not failure)
          (kill-buffer buffer)
          (omnigent-conversation-open id)
          (setq buffer (current-buffer))
          (with-timeout (15 (ert-fail "Reopened conversation snapshot timed out"))
            (while (with-current-buffer buffer omnigent-conversation--loading)
              (accept-process-output nil 0.1)))
          (with-current-buffer buffer
            (let ((items (mapcar (lambda (item-id)
                                   (gethash item-id omnigent-conversation--items))
                                 omnigent-conversation--order)))
              (should (cl-some (lambda (item)
                                 (and (equal (alist-get 'role item) "user")
                                      (equal (omnigent-conversation--text item) "test agent_message")))
                               items))
              (should (cl-some (lambda (item)
                                 (and (equal (alist-get 'role item) "assistant")
                                      (string-match-p "The capital of France is Paris\\."
                                                      (omnigent-conversation--text item))))
                               items)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when observer (omnigent-transport-stop-session-stream observer)))))

(ert-deftest omnigent-mock-acp-tool-call ()
  "Receive a native tool call over SSE and check its committed file result."
  (let* ((workspace (make-temp-file "omnigent-tool-" t))
         (id (omnigent-integration-create-session t workspace))
         snapshot events stream failure)
    (unwind-protect
        (progn
          (make-directory (expand-file-name "src" workspace))
          (write-region "File read successfully\n" nil
                        (expand-file-name "src/config.json" workspace) nil 'silent)
          (setq stream
                (omnigent-transport-start-session-stream
                 id (lambda (name data) (push (cons name data) events))
                 (lambda (status body) (setq snapshot (cons status body)))
                 (lambda (error) (setq failure error))))
          (with-timeout (15 (ert-fail (format "Tool stream did not load: %S" failure)))
            (while (not snapshot) (accept-process-output nil 0.1)))
          (should (= (car snapshot) 200))
          (let ((response
                 (omnigent-mock-test-request
                  "POST" (omnigent-transport--session-path id "/events")
                  '(("type" . "message")
                    ("data" . (("role" . "user")
                               ("content" . [(("type" . "input_text")
                                              ("text" . "test tool_call"))])))))))
            (should (= (car response) 202)))
          (with-timeout (30 (ert-fail (format "Tool turn timed out: %S; events: %S" failure events)))
            (while (not (cl-some
                         (lambda (event)
                           (and (equal (car event) "response.output_item.done")
                                (equal (alist-get 'type (alist-get 'item (cdr event)))
                                       "function_call_output"))) events))
              (accept-process-output nil 0.1)))
          (should-not failure)
          (let* ((done-items
                  (mapcar (lambda (event) (alist-get 'item (cdr event)))
                          (cl-remove-if-not
                           (lambda (event) (equal (car event) "response.output_item.done")) events)))
                 (call (cl-find "function_call" done-items
                                :key (lambda (item) (alist-get 'type item)) :test #'equal))
                 (output (cl-find "function_call_output" done-items
                                  :key (lambda (item) (alist-get 'type item)) :test #'equal))
                 (response (omnigent-mock-test-request "GET" (omnigent-transport--session-path id)))
                 (items (append (alist-get 'items (cdr response)) nil)))
            (should call)
            (should output)
            (should (= (car response) 200))
            ;; Parse committed items through the same state code used by a conversation.
            (with-temp-buffer
              (setq omnigent-conversation--items (make-hash-table :test 'equal))
              (dolist (item items) (omnigent-conversation--put-item item))
              ;; Stream IDs and database IDs differ; call_id correlates the tool pair.
              (let* ((stored (mapcar (lambda (item-id)
                                      (gethash item-id omnigent-conversation--items))
                                    omnigent-conversation--order))
                     (stored-call (cl-find "function_call" stored
                                           :key (lambda (item) (alist-get 'type item)) :test #'equal))
                     (stored-output (cl-find "function_call_output" stored
                                             :key (lambda (item) (alist-get 'type item)) :test #'equal)))
                (should stored-call)
                (should stored-output)
                (should (equal (alist-get 'name call) (alist-get 'name stored-call)))
                (should (equal (alist-get 'call_id call) (alist-get 'call_id stored-call)))
                (should (equal (alist-get 'call_id output) (alist-get 'call_id stored-output)))
                (should (equal (alist-get 'output output) (alist-get 'output stored-output)))
                (should (equal (alist-get 'type stored-call) "function_call"))
                (should (equal (alist-get 'type stored-output) "function_call_output"))
                (should (member (alist-get 'name stored-call)
                                (if (equal omnigent-integration-harness "claude-native")
                                    '("Read") '("exec_command" "shell_command" "shell"))))
                (should (string-prefix-p "call_" (alist-get 'call_id stored-call)))
                (should (equal (alist-get 'call_id stored-output)
                               (alist-get 'call_id stored-call)))
                (should (string-match-p "File read successfully"
                                        (format "%s" (alist-get 'output stored-output))))))))
      (when stream (omnigent-transport-stop-session-stream stream))
      (delete-directory workspace t))))

(ert-deftest omnigent-mock-acp-interrupt-running-turn ()
  "Interrupt after the mock starts streaming, not after a fixed sleep."
  (let* ((id (omnigent-integration-create-session t))
         (marker (make-temp-name "interrupt-check-"))
         (prompt (concat "test long_running\n" marker))
         snapshot events stream failure)
    (unwind-protect
        (progn
          (setq stream
                (omnigent-transport-start-session-stream
                 id (lambda (name data) (push (cons name data) events))
                 (lambda (status body) (setq snapshot (cons status body)))
                 (lambda (error) (setq failure error))))
          (with-timeout (15 (ert-fail (format "Interrupt stream did not load: %S" failure)))
            (while (not snapshot) (accept-process-output nil 0.1)))
          (should (= (car snapshot) 200))
          (let ((response
                 (omnigent-mock-test-request
                  "POST" (omnigent-transport--session-path id "/events")
                  `(("type" . "message")
                    ("data" . (("role" . "user")
                               ("content" . [(("type" . "input_text")
                                              ("text" . ,prompt))])))))))
            (should (= (car response) 202)))
          ;; Native Claude does not forward reasoning deltas before completion.
          ;; The unique HTTP request proves the model turn, not just input delivery, began.
          (omnigent-functional-wait "Mock did not receive the interrupt turn"
            (omnigent-mock-model-requests marker))
          (should (omnigent-functional-status-p id "running"))
          (setq events nil)
          (with-temp-buffer
            (setq omnigent-conversation-session-id id)
            (omnigent-conversation-interrupt))
          (with-timeout (15 (ert-fail (format "Interrupt did not finish the turn: %S" events)))
            (while (not (and (assoc "session.interrupted" events)
                             (cl-some (lambda (event)
                                        (and (equal (car event) "session.status")
                                             (equal (alist-get 'status (cdr event)) "idle")))
                                      events)))
              (accept-process-output nil 0.1)))
          (should-not failure)
          ;; Native input-delivery acknowledgements can complete with empty output.
          (should-not (cl-some
                       (lambda (event)
                         (and (equal (car event) "response.completed")
                              (> (length (alist-get 'output (alist-get 'response (cdr event)))) 0)))
                       events))
          (should-not (assoc "response.output_text.delta" events))
          (should (integerp (alist-get 'requested_at
                                       (alist-get 'data (cdr (assoc "session.interrupted" events))))))
          (let ((response (omnigent-mock-test-request "GET" (omnigent-transport--session-path id))))
            (should (= (car response) 200))
            (should (equal (alist-get 'status (cdr response)) "idle"))
            (should (cl-find-if
                     (lambda (item)
                       (let ((data (alist-get 'data item)))
                         (and (equal (alist-get 'type item) "message")
                              (equal (alist-get 'role data) "user")
                              (equal (omnigent-conversation--text data) prompt))))
                     (append (alist-get 'items (cdr response)) nil)))))
      (when stream (omnigent-transport-stop-session-stream stream)))))

(ert-deftest omnigent-mock-acp-elicitations-survive-reopen-and-resolve ()
  "Restore a pending request without its draft and resolve it through the API."
  (let ((id (omnigent-integration-create-session t)) buffer observer events reply)
    (unwind-protect
        (save-window-excursion
          (omnigent-conversation-open id)
          (setq buffer (current-buffer))
          (setq observer (omnigent-transport-start-session-stream
                          id (lambda (name data) (push (cons name data) events))
                          (lambda (_status _body)) (lambda (_error))))
          (with-timeout (15 (ert-fail "Conversation snapshot timed out"))
            (while (with-current-buffer buffer omnigent-conversation--loading)
              (accept-process-output nil 0.1)))
          (let ((response (omnigent-mock-test-request
                           "POST" (omnigent-transport--session-path id "/events")
                           '(("type" . "message")
                             ("data" . (("role" . "user")
                                        ("content" . [(("type" . "input_text")
                                                       ("text" . "test request_permission"))])))))))
            (should (= (car response) 202)))
          (with-timeout (30 (ert-fail (format "No elicitation: %S" events)))
            (while (not (with-current-buffer buffer (omnigent-conversation-elicitations)))
              (accept-process-output nil 0.1)))
          (let* ((request (with-current-buffer buffer (car (omnigent-conversation-elicitations))))
                 (request-id (alist-get 'elicitation_id request))
                 (draft (make-hash-table :test 'equal)))
            (puthash "unsent" "draft" draft)
            (with-current-buffer buffer
              (omnigent-conversation-elicitation-set-draft request-id draft))
            (kill-buffer buffer)
            (omnigent-conversation-open id)
            (setq buffer (current-buffer))
            (with-timeout (15 (ert-fail "Reopened conversation did not restore request"))
              (while (or (with-current-buffer buffer omnigent-conversation--loading)
                         (not (with-current-buffer buffer (omnigent-conversation-elicitations))))
                (accept-process-output nil 0.1)))
            (with-current-buffer buffer
              (should (equal request-id (alist-get 'elicitation_id (car (omnigent-conversation-elicitations)))))
              (should-not (gethash "unsent" (omnigent-conversation-elicitation-draft request-id)))
              ;; Native Claude and Codex permission cards use a binary verdict.
              (should-not (alist-get 'requestedSchema
                                     (alist-get 'params (car (omnigent-conversation-elicitations)))))
              (omnigent-conversation-elicitation-submit
               request-id 'accept (lambda (status body) (setq reply (cons status body)))))
            (with-timeout (30 (ert-fail (format "Elicitation did not finish: reply=%S events=%S" reply events)))
              (while (not (and reply (assoc "response.completed" events)))
                (accept-process-output nil 0.1)))
            (should (= (car reply) 202))
            (should-not (with-current-buffer buffer (omnigent-conversation-elicitations)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when observer (omnigent-transport-stop-session-stream observer)))))

(defmacro omnigent-functional-wait (description &rest body)
  "Wait up to 30 seconds for BODY, reporting DESCRIPTION on timeout."
  (declare (indent 1))
  `(with-timeout (30 (ert-fail ,description))
     (while (not (progn ,@body)) (accept-process-output nil 0.1))))

(defun omnigent-functional-items (buffer)
  "Return BUFFER's conversation items in transcript order."
  (with-current-buffer buffer
    (mapcar (lambda (id) (gethash id omnigent-conversation--items))
            omnigent-conversation--order)))

(defun omnigent-functional-open (id)
  "Open ID and wait for its initial snapshot."
  (omnigent-conversation-open id)
  (let ((buffer (current-buffer)))
    (omnigent-functional-wait "Conversation did not load"
      (not (buffer-local-value 'omnigent-conversation--loading buffer)))
    buffer))

(defun omnigent-functional-send (buffer text)
  "Send TEXT through BUFFER's composer and wait for acknowledgement."
  (with-current-buffer buffer
    (goto-char (point-max))
    (insert text)
    (call-interactively (key-binding (kbd "C-c C-c"))))
  (omnigent-functional-wait "Message acknowledgement timed out"
    (not (buffer-local-value 'omnigent-conversation--sending buffer)))
  (with-current-buffer buffer
    (should (equal (buffer-substring-no-properties
                    omnigent-conversation--prompt-start (point-max)) ""))))

(defun omnigent-functional-exchange-stored-p (id prompt answer)
  "Return non-nil when ID has committed both PROMPT and ANSWER.
Native input delivery completes before the transcript forwarder commits output."
  (let* ((reply (omnigent-mock-test-request
                 "GET" (omnigent-transport--session-path id "/items?limit=1000&order=asc")))
         (items (append (alist-get 'data (cdr reply)) nil)))
    (should (= (car reply) 200))
    (cl-every (lambda (expected)
                (cl-some (lambda (item)
                           (and (equal (alist-get 'role item) (car expected))
                                (equal (omnigent-conversation--text item) (cdr expected)))) items))
              `(("user" . ,prompt) ("assistant" . ,answer)))))

(defun omnigent-functional-status-p (id status)
  "Return non-nil when ID's server state equals STATUS."
  (let ((response (omnigent-mock-test-request "GET" (omnigent-transport--session-path id))))
    (should (= (car response) 200))
    (equal (alist-get 'status (cdr response)) status)))

(ert-deftest omnigent-mock-acp-multiple-hosts ()
  "Run a mock agent session on each of two distinct hosts."
  (let* ((process-environment (copy-sequence process-environment))
         (tmp (getenv "OMNIGENT_TEST_TMP"))
         (log (generate-new-buffer " *omnigent-second-host*"))
         host-process buffers)
    (unwind-protect
        (progn
          (setenv "OMNIGENT_HOST_ID" "12345678-1234-4234-8234-123456789abc")
          (setenv "OMNIGENT_HOST_NAME" "integration-second-host")
          (setenv "OMNIGENT_DATA_DIR" (concat tmp "/second-host-data"))
          (setq host-process
                (make-process :name "omnigent-second-host" :buffer log
                              :command (list (getenv "OMNIGENT_TEST_BIN") "host"
                                             "--server" omnigent-server-url
                                             "--no-open" "--non-interactive")
                              :noquery t))
          (omnigent-functional-wait "Second host did not come online"
            (progn
              (unless (process-live-p host-process)
                (ert-fail (with-current-buffer log (buffer-string))))
              (let* ((response (omnigent-mock-test-request "GET" "/v1/hosts"))
                     (hosts (append (alist-get 'hosts (cdr response)) nil)))
                (>= (cl-count "online" hosts :key (lambda (host) (alist-get 'status host))
                              :test #'equal)
                    2))))
          (let* ((hosts (cl-remove-if-not
                         (lambda (host) (equal (alist-get 'status host) "online"))
                         (append (alist-get 'hosts
                                            (cdr (omnigent-mock-test-request "GET" "/v1/hosts"))) nil)))
                 (agents (cdr (omnigent-mock-test-request "GET" "/v1/agents?limit=1000")))
                 (agent (cl-find omnigent-integration-agent-name (append (alist-get 'data agents) nil)
                                 :key (lambda (item) (alist-get 'name item)) :test #'equal)))
            (should agent)
            (should (= (length hosts) 2))
            (should-not (equal (alist-get 'host_id (car hosts))
                               (alist-get 'host_id (cadr hosts))))
            (dolist (host hosts)
              (let* ((host-id (alist-get 'host_id host))
                     (created (omnigent-mock-test-request
                               "POST" "/v1/sessions"
                               `(("agent_id" . ,(alist-get 'id agent))
                                 ("host_id" . ,host-id)
                                 ("workspace" . ,(getenv "HOME")))))
                     (id (alist-get 'id (cdr created)))
                     buffer)
                (should (= (car created) 201))
                (should (equal host-id (alist-get 'host_id
                                                  (cdr (omnigent-mock-test-request
                                                        "GET" (omnigent-transport--session-path id))))))
                (save-window-excursion
                  (setq buffer (omnigent-functional-open id))
                  (push buffer buffers)
                  (omnigent-functional-send buffer "test agent_message")
                  (omnigent-functional-wait "Host agent did not answer"
                    (cl-find-if (lambda (item)
                                  (and (equal (alist-get 'role item) "assistant")
                                       (equal (omnigent-conversation--text item)
                                              "The capital of France is Paris.")))
                                (omnigent-functional-items buffer))))))))
      (dolist (buffer buffers) (when (buffer-live-p buffer) (kill-buffer buffer)))
      (when (and host-process (process-live-p host-process))
        (delete-process host-process))
      (kill-buffer log))))

(ert-deftest omnigent-host-workspace-completion ()
  "Select a path with mocked input and asynchronous real host filesystem requests."
  (let* ((root (make-temp-file "omnigent-workspace-" t))
         (workspace (concat root "/project #1"))
         target)
    (unwind-protect
        (progn
          (make-directory workspace)
          (make-directory (concat workspace "/src"))
          (write-region "Not a directory" nil (concat root "/notes.txt") nil 'silent)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (prompt table &rest _)
                       (should (string-prefix-p "Workspace on " prompt))
                       (omnigent-functional-wait "Parent directory completion did not load"
                         (equal (all-completions (concat root "/") table)
                                (list (concat root "/") (concat workspace "/"))))
                       (omnigent-functional-wait "Nested directory completion did not load"
                         (equal (try-completion (concat workspace "/s") table)
                                (concat workspace "/src/")))
                       workspace)))
            (omnigent-sessions--read-workspace (lambda (value) (setq target value)))
            (should-not target)
            (omnigent-functional-wait "Workspace selection did not finish" target)
            (let ((hosts (cdr (omnigent-mock-test-request "GET" "/v1/hosts"))))
              (should (equal (car target) (alist-get 'host_id (aref (alist-get 'hosts hosts) 0))))
              (should (equal (cdr target) workspace)))))
      (delete-directory root t))))

(ert-deftest omnigent-host-workspace-selection-rejects-missing-path ()
  "Let the real server reject a typed path before continuing session creation."
  (let* ((root (make-temp-file "omnigent-selection-" t))
         (missing (concat root "/does-not-exist"))
         (omnigent-sessions-error-hook nil)
         errors selected)
    (unwind-protect
        (progn
          (setq omnigent-sessions-error-hook (list (lambda (error) (push error errors))))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (prompt _table &rest _)
                       (should (string-prefix-p "Workspace on " prompt))
                       missing)))
            (omnigent-sessions--read-workspace (lambda (_) (setq selected t)))
            (should-not errors)
            (omnigent-functional-wait "Missing workspace did not report a server failure" errors)
            (should-not selected)
            (should (= (length errors) 1))
            (should (string-prefix-p "Check workspace: 404" (car errors)))))
      (delete-directory root t))))

(ert-deftest omnigent-mock-acp-create-to-chat ()
  "Create through the client prompts, open through its hook, and chat."
  (let* ((hosts (cdr (omnigent-mock-test-request "GET" "/v1/hosts")))
         (host-id (alist-get 'host_id (aref (alist-get 'hosts hosts) 0)))
         (workspace (file-truename (getenv "HOME")))
         (omnigent-executable "/not-installed-on-this-client")
         buffer)
    (unwind-protect
        (save-window-excursion
          ;; The fixture starts the server elsewhere; connecting needs no CLI.
          (omnigent-connect omnigent-server-url)
          (let ((omnigent-sessions-open-hook
                 (append omnigent-sessions-open-hook
                         (list (lambda (session)
                                 (setq buffer (omnigent-sessions-buffer (alist-get 'id session))))))))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (prompt choices &rest _args)
                         (if (string-prefix-p "Workspace on " prompt)
                             workspace
                           (car (cl-find-if (lambda (choice) (string-prefix-p (concat omnigent-integration-agent-name " [") (car choice)))
                                            choices)))))
                      ((symbol-function 'read-string)
                       (lambda (&rest _args) "Functional create-to-chat")))
              (omnigent-sessions-create)
              (omnigent-functional-wait "Created session did not open" buffer)))
          ;; REST response cleanup must not kill the newly opened conversation.
          (should (buffer-live-p buffer))
          (let* ((id (buffer-local-value 'omnigent-conversation-session-id buffer))
                 (session (cdr (omnigent-mock-test-request
                                "GET" (omnigent-transport--session-path id)))))
            (should (equal (alist-get 'host_id session) host-id))
            (should (equal (alist-get 'workspace session) workspace))
            (omnigent-functional-wait "Created conversation did not load"
              (not (buffer-local-value 'omnigent-conversation--loading buffer)))
            (omnigent-functional-wait "Created session missing from list"
              (cl-find id omnigent-sessions :key (lambda (row) (alist-get 'id row)) :test #'equal))
            (should (equal (alist-get 'title (cl-find id omnigent-sessions
                              :key (lambda (row) (alist-get 'id row)) :test #'equal))
                           "Functional create-to-chat"))
            (omnigent-functional-send buffer "test agent_message")
            (omnigent-functional-wait "Created session did not render the exchange"
              (with-current-buffer buffer
                (and (string-match-p "You:\ntest agent_message" (buffer-string))
                     (string-match-p "The capital of France is Paris\\." (buffer-string)))))
            (omnigent-functional-wait "Created session did not finish"
              (and (omnigent-functional-exchange-stored-p
                    id "test agent_message" "The capital of France is Paris.")
                   (omnigent-functional-status-p id "idle")))
            (kill-buffer buffer)
            (setq buffer (omnigent-functional-open id))
            (with-current-buffer buffer
              (should (string-match-p "You:\ntest agent_message" (buffer-string)))
              (should (string-match-p "The capital of France is Paris\\." (buffer-string))))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun omnigent-functional-model-turn (buffer scenario)
  "Send SCENARIO through BUFFER and return its recorded model request."
  (let ((marker (make-temp-name "model-check-"))
        (assistant-count (cl-count "assistant" (omnigent-functional-items buffer)
                                   :key (lambda (item) (alist-get 'role item)) :test #'equal))
        requests)
    (omnigent-functional-send buffer (concat "test " scenario "\n" marker))
    (omnigent-functional-wait "Native client did not send the model request"
      (setq requests (omnigent-mock-model-requests marker)))
    (omnigent-functional-wait "Native turn did not finish"
      (and (> (cl-count "assistant" (omnigent-functional-items buffer)
                        :key (lambda (item) (alist-get 'role item)) :test #'equal)
              assistant-count)
           (omnigent-functional-status-p
            (buffer-local-value 'omnigent-conversation-session-id buffer) "idle")))
    (car (last requests))))

(defun omnigent-functional-change-model (buffer model)
  "Change BUFFER's MODEL through the interactive command and check its reply."
  (let (result)
    (cl-letf* ((original (symbol-function 'omnigent-transport-set-session-model))
               ((symbol-function 'omnigent-transport-set-session-model)
                (lambda (session value callback)
                  (funcall original session value
                           (lambda (status body)
                             (setq result (cons status body))
                             (funcall callback status body)))))
               ((symbol-function 'read-string) (lambda (&rest _) model)))
      (with-current-buffer buffer (call-interactively #'omnigent-conversation-set-model))
      (omnigent-functional-wait "Model change timed out" result))
    (should (omnigent-transport-success-p (car result)))))

(ert-deftest omnigent-mock-claude-change-model ()
  "Change the model before the first turn and check Claude's HTTP request."
  (let ((id (omnigent-integration-create-session t)) buffer)
    (unwind-protect
        (save-window-excursion
          (setq buffer (omnigent-functional-open id))
          (omnigent-functional-change-model buffer "claude-opus-4-6")
          (should (equal (alist-get 'model (omnigent-functional-model-turn buffer "model"))
                         "claude-opus-4-6")))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest omnigent-mock-claude-change-model-after-chat ()
  "Change a live Claude session's model and check the next HTTP request."
  (let ((id (omnigent-integration-create-session t)) buffer)
    (unwind-protect
        (save-window-excursion
          (setq buffer (omnigent-functional-open id))
          (should (equal (alist-get 'model (omnigent-functional-model-turn buffer "model"))
                         "claude-sonnet-4-6"))
          (omnigent-functional-change-model buffer "claude-opus-4-6")
          (should (equal (alist-get 'model (omnigent-functional-model-turn buffer "model"))
                         "claude-opus-4-6")))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest omnigent-mock-claude-change-effort ()
  "Change Claude's effort and check the low and high API request values."
  (let ((id (omnigent-integration-create-session t)) buffer)
    (unwind-protect
        (save-window-excursion
          (setq buffer (omnigent-functional-open id))
          (omnigent-functional-model-turn buffer "agent_message")
          (dolist (effort '("low" "high"))
            (let ((reply (omnigent-mock-test-request
                          "PATCH" (omnigent-transport--session-path id)
                          `(("reasoning_effort" . ,effort)))))
              (should (omnigent-transport-success-p (car reply))))
            (let ((request (omnigent-functional-model-turn buffer "reasoning")))
              (should (equal (alist-get 'effort (alist-get 'output_config request)) effort)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest omnigent-mock-claude-change-permission ()
  "Check that default asks for a write and acceptEdits permits the next write."
  (let* ((workspace (make-temp-file "omnigent-permission-" t))
         (path (expand-file-name "mock-permission.txt" workspace))
         (id (omnigent-integration-create-session t workspace)) buffer)
    (unwind-protect
        (save-window-excursion
          (setq buffer (omnigent-functional-open id))
          (omnigent-functional-model-turn buffer "agent_message")
          (let ((reply (omnigent-mock-test-request
                        "PATCH" (omnigent-transport--session-path id)
                        '(("permission_mode" . "default")))))
            (ert-info ((format "Default permission response: %S" reply))
              (should (omnigent-transport-success-p (car reply)))))
          (omnigent-functional-send buffer "test request_permission")
          (omnigent-functional-wait "Default mode did not ask for permission"
            (with-current-buffer buffer (omnigent-conversation-elicitations)))
          (should-not (file-exists-p path))
          (let* ((request (with-current-buffer buffer (car (omnigent-conversation-elicitations))))
                 (reply (omnigent-mock-test-request
                         "POST" (omnigent-transport--session-path
                                 id (concat "/elicitations/" (alist-get 'elicitation_id request) "/resolve"))
                         '(("action" . "decline")))))
            (should (= (car reply) 202)))
          (omnigent-functional-wait "Declined write did not finish"
            (omnigent-functional-status-p id "idle"))
          (should-not (file-exists-p path))
          (let ((reply (omnigent-mock-test-request
                        "PATCH" (omnigent-transport--session-path id)
                        '(("permission_mode" . "acceptEdits")))))
            (ert-info ((format "acceptEdits response: %S" reply))
              (should (omnigent-transport-success-p (car reply)))))
          (omnigent-functional-send buffer "test request_permission")
          (omnigent-functional-wait "acceptEdits did not execute the write"
            (should-not (with-current-buffer buffer (omnigent-conversation-elicitations)))
            (and (file-exists-p path) (omnigent-functional-status-p id "idle")))
          (with-temp-buffer
            (insert-file-contents path)
            (should (equal (buffer-string) "Mock permission granted.\n"))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (omnigent-mock-test-request "DELETE" (omnigent-transport--session-path id))
      (delete-directory workspace t))))

(ert-deftest omnigent-mock-acp-decline-and-cancel-permission ()
  "Decline and cancel real pending permission requests without form answers."
  (dolist (action '(decline cancel))
    (let ((id (omnigent-integration-create-session t)) buffer reply)
      (unwind-protect
          (save-window-excursion
            (setq buffer (omnigent-functional-open id))
            (omnigent-functional-send buffer "test request_permission")
            (omnigent-functional-wait "Permission request did not arrive"
              (with-current-buffer buffer (omnigent-conversation-elicitations)))
            (if (eq action 'decline)
                (with-current-buffer buffer
                  (should (string-match-p "Decline" (buffer-string)))
                  (let ((button (cl-find 'decline omnigent-ui--widgets
                                         :key (lambda (widget) (widget-get widget :response-action)))))
                    (should button)
                    (widget-apply-action button)))
              (with-current-buffer buffer
                (let ((request-id (alist-get 'elicitation_id (car (omnigent-conversation-elicitations)))))
                  (omnigent-conversation-elicitation-submit
                   request-id action (lambda (status body) (setq reply (cons status body))))))
              (omnigent-functional-wait "Permission response was not acknowledged" reply)
              (should (= (car reply) 202)))
            (omnigent-functional-wait "Permission turn did not become idle"
              (omnigent-functional-status-p id "idle"))
            (with-current-buffer buffer
              (should-not (omnigent-conversation-elicitations))
              (should-not (string-match-p "Decline" (buffer-string)))
              (should (= (hash-table-count omnigent-conversation--elicitation-submitting) 0)))
            (kill-buffer buffer)
            (setq buffer (omnigent-functional-open id))
            (should-not (with-current-buffer buffer (omnigent-conversation-elicitations))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest omnigent-mock-acp-live-conversation-response ()
  "Apply partial streamed text to an open buffer without changing its draft."
  (let ((id (omnigent-integration-create-session t)) buffer)
    (unwind-protect
        (save-window-excursion
          (setq buffer (omnigent-functional-open id))
          (omnigent-functional-send buffer "test long_running")
          (with-current-buffer buffer (insert "unsent next prompt"))
          (omnigent-functional-wait "Assistant text did not reach conversation state"
            (cl-find-if (lambda (item)
                          (and (equal (alist-get 'role item) "assistant")
                               (not (string-empty-p (omnigent-conversation--text item)))))
                        (omnigent-functional-items buffer)))
          ;; The first visible text must be one chunk, not just the final full item.
          (let ((assistant (cl-find "assistant" (omnigent-functional-items buffer)
                                    :key (lambda (item) (alist-get 'role item)) :test #'equal)))
            (should (equal (omnigent-conversation--text assistant) "The capital of France is Paris.")))
          (should (omnigent-functional-status-p id "running"))
          (omnigent-functional-wait "Streamed response did not finish"
            (and (cl-find-if
                  (lambda (item)
                    (and (equal (alist-get 'role item) "assistant")
                         (equal (omnigent-conversation--text item)
                                (apply #'concat (make-list 3 "The capital of France is Paris.")))))
                  (omnigent-functional-items buffer))
                 (omnigent-functional-status-p id "idle")))
          (let ((items (omnigent-functional-items buffer)))
            (should (= 1 (cl-count "assistant" items
                                  :key (lambda (item) (alist-get 'role item)) :test #'equal)))
            (let ((thoughts (cl-remove-if-not
                             (lambda (item) (equal (alist-get 'type item) "reasoning")) items)))
              (should (= (length thoughts) 1))
              (should (equal (omnigent-conversation--text (car thoughts))
                             (apply #'concat (make-list 3 "Thinking about best approach..."))))))
          (with-current-buffer buffer
            (should (equal (buffer-substring-no-properties omnigent-conversation--prompt-start (point-max))
                           "unsent next prompt"))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest omnigent-mock-acp-ui-interrupt ()
  "Interrupt a real running model turn through the UI and keep its composer usable."
  (let* ((id (omnigent-integration-create-session t))
         (marker (make-temp-name "ui-interrupt-check-"))
         buffer)
    (unwind-protect
        (save-window-excursion
          (setq buffer (omnigent-functional-open id))
          (omnigent-functional-send buffer (concat "test long_running\n" marker))
          (omnigent-functional-wait "Model turn did not start"
            (and (omnigent-mock-model-requests marker)
                 (omnigent-functional-status-p id "running")))
          (with-current-buffer buffer
            (call-interactively (key-binding (kbd "C-c C-k"))))
          (omnigent-functional-wait "Interrupted session did not become idle"
            (and (omnigent-functional-status-p id "idle")
                 (with-current-buffer buffer
                   (string-match-p "Interrupted" (buffer-string)))))
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert "next draft")
            (should (string-suffix-p "next draft" (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest omnigent-mock-acp-send-while-busy ()
  "Queue a second composer message during a turn and restore both exchanges."
  (let ((id (omnigent-integration-create-session t)) buffer)
    (unwind-protect
        (save-window-excursion
          (setq buffer (omnigent-functional-open id))
          (omnigent-functional-send buffer "test long_running")
          (omnigent-functional-wait "First turn did not start"
            (omnigent-functional-status-p id "running"))
          (omnigent-functional-send buffer "test agent_message")
          (omnigent-functional-wait "Queued turn did not answer"
            (= 2 (cl-count "assistant" (omnigent-functional-items buffer)
                           :key (lambda (item) (alist-get 'role item)) :test #'equal)))
          (omnigent-functional-wait "Queued turns did not finish"
            (omnigent-functional-status-p id "idle"))
          (kill-buffer buffer)
          (setq buffer (omnigent-functional-open id))
          (let ((items (omnigent-functional-items buffer)))
            (should (equal (mapcar #'omnigent-conversation--text
                                  (cl-remove-if-not (lambda (item) (equal (alist-get 'role item) "user")) items))
                           '("test long_running" "test agent_message")))
            (should (= 2 (cl-count "assistant" items :key (lambda (item) (alist-get 'role item)) :test #'equal)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest omnigent-mock-acp-two-conversations ()
  "Keep two sessions isolated, reuse buffers, and interrupt only one session."
  (let ((id-a (omnigent-integration-create-session t))
        (id-b (omnigent-integration-create-session t)) a b)
    (unwind-protect
        (save-window-excursion
          (setq a (omnigent-functional-open id-a)
                b (omnigent-functional-open id-b))
          (let (loaded)
            (let ((omnigent-sessions-change-hook (cons (lambda () (setq loaded t))
                                                       omnigent-sessions-change-hook)))
              (omnigent-sessions-refresh)
              (omnigent-functional-wait "Session list did not load" loaded))
            (unless (get-buffer-window "*omnigent-sessions*") (omnigent-ui-sessions))
            (dolist (entry `((,id-a . ,a) (,id-b . ,b)))
              (select-window (get-buffer-window "*omnigent-sessions*"))
              (goto-char (point-min))
              (while (and (not (eobp))
                          (not (equal (get-text-property (point) 'omnigent-ui-session-id)
                                      (car entry))))
                (forward-line 1))
              (should-not (eobp))
              (call-interactively (key-binding (kbd "RET")))
              (should (eq (current-buffer) (cdr entry)))
              (should (equal omnigent-ui--selected-session (car entry)))))
          (let ((stream (buffer-local-value 'omnigent-conversation--stream a)))
            (should (eq a (omnigent-functional-open id-a)))
            (should (eq stream (buffer-local-value 'omnigent-conversation--stream a))))
          (omnigent-functional-send a "test long_running")
          (omnigent-functional-wait "Session A did not start"
            (omnigent-functional-status-p id-a "running"))
          (omnigent-functional-send b "test request_permission")
          (omnigent-functional-wait "Session B did not request permission"
            (with-current-buffer b (omnigent-conversation-elicitations)))
          (with-current-buffer b (insert "draft for B"))
          (with-current-buffer a
            (should (equal omnigent-conversation-session-id id-a))
            (should-not (omnigent-conversation-elicitations))
            (insert "draft for A")
            (omnigent-conversation-interrupt))
          (omnigent-functional-wait "Session A did not stop"
            (omnigent-functional-status-p id-a "idle"))
          (with-current-buffer b
            (should (equal omnigent-conversation-session-id id-b))
            (should (omnigent-conversation-elicitations))
            (omnigent-conversation-elicitation-submit
             (alist-get 'elicitation_id (car (omnigent-conversation-elicitations))) 'decline nil))
          (omnigent-functional-wait "Session B did not finish"
            (omnigent-functional-status-p id-b "idle"))
          (should-not (cl-find "assistant" (omnigent-functional-items a)
                               :key (lambda (item) (alist-get 'role item)) :test #'equal))
          (dolist (entry `((,a . "draft for A") (,b . "draft for B")))
            (with-current-buffer (car entry)
              (should (equal (buffer-substring-no-properties omnigent-conversation--prompt-start (point-max))
                             (cdr entry))))))
      (when (buffer-live-p a) (kill-buffer a))
      (when (buffer-live-p b) (kill-buffer b)))))

(ert-deftest omnigent-mock-acp-close-running-conversation ()
  "Closing stops the client stream, but the agent finishes and history survives."
  (let* ((id (omnigent-integration-create-session t))
         (marker (make-temp-name "close-check-"))
         (prompt (concat "test long_running\n" marker))
         buffer stream)
    (unwind-protect
        (save-window-excursion
          (setq buffer (omnigent-functional-open id)
                stream (buffer-local-value 'omnigent-conversation--stream buffer))
          (omnigent-functional-send buffer prompt)
          (omnigent-functional-wait "Turn did not start before closing"
            (and (omnigent-mock-model-requests marker)
                 (omnigent-functional-status-p id "running")))
          (with-current-buffer buffer (insert "discard this draft"))
          (kill-buffer buffer)
          (should (omnigent-stream-stopped stream))
          (should-not (process-live-p (omnigent-stream-process stream)))
          (should-not (assoc id omnigent-sessions--buffers))
          (omnigent-functional-wait "Agent did not finish while buffer was closed"
            (and (omnigent-functional-exchange-stored-p
                  id prompt
                  (apply #'concat (make-list 3 "The capital of France is Paris.")))
                 (omnigent-functional-status-p id "idle")))
          (setq buffer (omnigent-functional-open id))
          (let ((items (omnigent-functional-items buffer)))
            (should (= 1 (cl-count "user" items :key (lambda (item) (alist-get 'role item)) :test #'equal)))
            (should (= 1 (cl-count "assistant" items :key (lambda (item) (alist-get 'role item)) :test #'equal)))
            (should (cl-find-if (lambda (item)
                                 (equal (omnigent-conversation--text item)
                                        (apply #'concat (make-list 3 "The capital of France is Paris.")))) items)))
          (with-current-buffer buffer
            (should (equal (buffer-substring-no-properties
                            omnigent-conversation--prompt-start (point-max)) ""))
            (should-not (string-match-p "discard this draft" (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun omnigent-functional-workspace (root)
  "Initialize ROOT with two tracked files for workspace frontend tests."
  (make-directory root t)
  (write-region "before modification\n" nil (expand-file-name "modified #1.txt" root) nil 'silent)
  (write-region "before deletion\n" nil (expand-file-name "deleted.txt" root) nil 'silent)
  (dolist (args '(("init" "-q") ("add" ".")
                  ("-c" "user.name=Omnigent Test" "-c" "user.email=test@example.invalid"
                   "commit" "-qm" "baseline")))
    (should (= 0 (apply #'call-process "git" nil nil nil "-C" root args)))))

(ert-deftest omnigent-ui-workspace-live-diffs ()
  "Select changed files and fetch fresh file and combined diffs through the UI."
  (let ((root (file-truename (make-temp-file "omnigent-panel-" t)))
        (omnigent-ui--selected-session nil)
        (omnigent-ui--workspace-cache (make-hash-table :test 'equal))
        (omnigent-ui--workspace-pending (make-hash-table :test 'equal))
        (omnigent-ui--workspace-again (make-hash-table :test 'equal))
        (omnigent-ui--workspace-visible nil)
        (omnigent-ui--workspace-closed nil)
        id conversation panel file-buffer combined-buffer)
    (unwind-protect
        (save-window-excursion
          (omnigent-functional-workspace root)
          (setq id (omnigent-integration-create-session t root))
          (write-region "first modification\n" nil (expand-file-name "modified #1.txt" root) nil 'silent)
          (write-region "new file\n" nil (expand-file-name "added.txt" root) nil 'silent)
          (delete-file (expand-file-name "deleted.txt" root))
          (omnigent-ui-open id)
          (setq conversation (current-buffer))
          (omnigent-functional-wait "Workspace selection did not populate the panel"
            (and (gethash id omnigent-ui--workspace-cache)
                 (get-buffer-window (omnigent-ui--workspace-buffer id))))
          (setq panel (omnigent-ui--workspace-buffer id))
          (with-current-buffer panel
            (should (equal (buffer-string)
                           "[unified diff]\nA added.txt\nD deleted.txt\nM modified #1.txt\n"))
            (goto-char (point-min))
            (forward-line 3)
            (call-interactively (key-binding (kbd "RET"))))
          (omnigent-functional-wait "File diff did not open"
            (setq file-buffer (get-buffer (format "*omnigent-diff: %s:modified #1.txt*" id))))
          (with-current-buffer file-buffer
            (should (derived-mode-p 'diff-mode))
            (should (string-match-p "\\+first modification" (buffer-string))))
          (write-region "second modification\n" nil (expand-file-name "modified #1.txt" root) nil 'silent)
          (with-selected-window (get-buffer-window panel)
            (goto-char (point-min))
            (forward-line 3)
            (omnigent-ui-workspace-diff))
          (omnigent-functional-wait "Reopening the diff did not fetch fresh content"
            (with-current-buffer file-buffer
              (string-match-p "\\+second modification" (buffer-string))))
          (should (eq file-buffer (get-buffer (format "*omnigent-diff: %s:modified #1.txt*" id))))
          (with-current-buffer file-buffer
            (should-not (string-match-p "first modification" (buffer-string))))
          (with-current-buffer panel
            (goto-char (point-min))
            (omnigent-ui-workspace-diff))
          (omnigent-functional-wait "Combined diff did not open"
            (setq combined-buffer (get-buffer (format "*omnigent-diff: %s::all*" id))))
          (with-current-buffer combined-buffer
            (should (derived-mode-p 'diff-mode))
            (dolist (text '("+new file" "-before deletion" "+second modification"))
              (should (string-match-p (regexp-quote text) (buffer-string))))))
      (dolist (buffer (list conversation panel file-buffer combined-buffer))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (when id (omnigent-mock-test-request "DELETE" (omnigent-transport--session-path id)))
      (delete-directory root t))))

(ert-deftest omnigent-ui-workspace-live-invalidation ()
  "A server invalidation refreshes its session without replacing another panel."
  (let ((root (file-truename (make-temp-file "omnigent-invalidation-" t)))
        (other-root (file-truename (make-temp-file "omnigent-other-workspace-" t)))
        (omnigent-ui--selected-session nil)
        (omnigent-ui--workspace-cache (make-hash-table :test 'equal))
        (omnigent-ui--workspace-pending (make-hash-table :test 'equal))
        (omnigent-ui--workspace-again (make-hash-table :test 'equal))
        (omnigent-ui--workspace-visible nil)
        (omnigent-ui--workspace-closed nil)
        a b buffer-a buffer-b panel-a panel-b events)
    (unwind-protect
        (save-window-excursion
          (omnigent-functional-workspace root)
          (omnigent-functional-workspace other-root)
          (write-region "other workspace change\n" nil
                        (expand-file-name "modified #1.txt" other-root) nil 'silent)
          (setq a (omnigent-integration-create-session t root)
                b (omnigent-integration-create-session t other-root))
          (write-region "selected session change\n" nil (expand-file-name "modified #1.txt" root) nil 'silent)
          (omnigent-ui-open a)
          (setq buffer-a (current-buffer))
          (omnigent-functional-wait "First session workspace did not load"
            (and (not (buffer-local-value 'omnigent-conversation--loading buffer-a))
                 (gethash a omnigent-ui--workspace-cache)))
          (with-current-buffer buffer-a
            (add-hook 'omnigent-conversation-event-hook
                      (lambda (name data) (push (cons name data) events)) nil t))
          ;; Read-only browsing can use the host before the native runner starts.
          ;; A mutation needs its live environment, so finish a real native turn first.
          (omnigent-functional-model-turn buffer-a "agent_message")
          (setq panel-a (omnigent-ui--workspace-buffer a))
          (omnigent-ui-open b)
          (setq buffer-b (current-buffer))
          (omnigent-functional-wait "Second session workspace did not display"
            (and (gethash b omnigent-ui--workspace-cache)
                 (get-buffer-window (omnigent-ui--workspace-buffer b))))
          (setq panel-b (omnigent-ui--workspace-buffer b))
          (let ((previous-b (gethash b omnigent-ui--workspace-cache))
                (panel-text-b (with-current-buffer panel-b (buffer-string)))
                (response (omnigent-mock-test-request
                           "PUT" (omnigent-workspace--path a "filesystem/agent%20%231.txt")
                           '(("content" . "written through the server\n")))))
            (ert-info ((format "Workspace write response: %S" response))
              (should (omnigent-transport-success-p (car response))))
            (omnigent-functional-wait "Server invalidation was not received"
              (assoc "session.changed_files.invalidated" events))
            (should (equal a (alist-get 'session_id
                                       (cdr (assoc "session.changed_files.invalidated" events)))))
            (omnigent-functional-wait "Invalidated session cache did not refresh"
              (member "agent #1.txt" (alist-get 'paths (gethash a omnigent-ui--workspace-cache))))
            (should (equal omnigent-ui--selected-session b))
            (should (get-buffer-window panel-b))
            (should-not (get-buffer-window panel-a))
            (should (equal previous-b (gethash b omnigent-ui--workspace-cache)))
            (with-current-buffer panel-b (should (equal panel-text-b (buffer-string))))
            (with-current-buffer panel-a
              (should (string-match-p "A agent #1.txt" (buffer-string))))
            (omnigent-ui-open a)
            (should (get-buffer-window panel-a))
            (with-current-buffer panel-a
              (should (string-match-p "A agent #1.txt" (buffer-string))))))
      (dolist (buffer (list buffer-a buffer-b panel-a panel-b))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (dolist (id (delq nil (list a b)))
        (omnigent-mock-test-request "DELETE" (omnigent-transport--session-path id)))
      (delete-directory root t)
      (delete-directory other-root t))))

(provide 'omnigent-functional-tests)
;;; omnigent-functional-tests.el ends here
