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
                                      (equal (cdr (assq 'name item)) "mock-acp"))
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
            (while (not (and (assoc "response.completed" events)
                             (cl-some (lambda (event)
                                        (and (equal (car event) "session.status")
                                             (equal (alist-get 'status (cdr event)) "idle")))
                                      events)))
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
  "Receive a tool call over SSE and check its committed result."
  (let ((id (omnigent-integration-create-session t))
        snapshot events stream failure)
    (unwind-protect
        (progn
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
            (while (not (assoc "response.completed" events))
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
                (should (equal (alist-get 'name stored-call) "Reading configuration file"))
                (should (equal (alist-get 'call_id stored-call) "call_001"))
                (should (equal (alist-get 'call_id stored-output)
                               (alist-get 'call_id stored-call)))
                (should (string-match-p "File read successfully"
                                        (format "%s" (alist-get 'output stored-output))))))))
      (when stream (omnigent-transport-stop-session-stream stream)))))

(ert-deftest omnigent-mock-acp-interrupt-running-turn ()
  "Interrupt after the mock starts streaming, not after a fixed sleep."
  (let ((id (omnigent-integration-create-session t))
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
                  '(("type" . "message")
                    ("data" . (("role" . "user")
                               ("content" . [(("type" . "input_text")
                                              ("text" . "test long_running"))])))))))
            (should (= (car response) 202)))
          (with-timeout (30 (ert-fail (format "Mock did not start reasoning: %S" events)))
            (while (not (assoc "response.reasoning_text.delta" events))
              (accept-process-output nil 0.1)))
          (should-not (assoc "response.completed" events))
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
          (should-not (assoc "response.completed" events))
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
                              (equal (omnigent-conversation--text data) "test long_running"))))
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
              (let* ((request (car (omnigent-conversation-elicitations)))
                     (schema (alist-get 'requestedSchema (alist-get 'params request)))
                     (answer (alist-get 'answer (alist-get 'properties schema)))
                     (draft (omnigent-conversation-elicitation-draft request-id)))
                (puthash "answer" (aref (alist-get 'enum answer) 0) draft)
                (omnigent-conversation-elicitation-set-draft request-id draft))
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
    (omnigent-conversation-send))
  (omnigent-functional-wait "Message acknowledgement timed out"
    (not (buffer-local-value 'omnigent-conversation--sending buffer)))
  (with-current-buffer buffer
    (should (equal (buffer-substring-no-properties
                    omnigent-conversation--prompt-start (point-max)) ""))))

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
                 (agent (cl-find "mock-acp" (append (alist-get 'data agents) nil)
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
  "Browse nested host directories through the real filesystem endpoint."
  (let* ((root (make-temp-file "omnigent-workspace-" t))
         (workspace (concat root "/project #1")))
    (unwind-protect
        (progn
          (make-directory workspace)
          (make-directory (concat workspace "/src"))
          (write-region "Not a directory" nil (concat root "/notes.txt") nil 'silent)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (prompt table &rest _)
                       (should (string-prefix-p "Workspace on " prompt))
                       (should (equal (all-completions (concat root "/") table)
                                      (list (concat root "/") (concat workspace "/"))))
                       (should (equal (try-completion (concat workspace "/s") table)
                                      (concat workspace "/src/")))
                       workspace)))
            (let* ((target (omnigent-sessions--read-workspace))
                   (hosts (cdr (omnigent-mock-test-request "GET" "/v1/hosts"))))
              (should (equal (car target) (alist-get 'host_id (aref (alist-get 'hosts hosts) 0))))
              (should (equal (cdr target) workspace)))))
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
                           (car (cl-find-if (lambda (choice) (string-prefix-p "mock-acp [" (car choice)))
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
            (omnigent-functional-wait "Created session did not answer"
              (cl-find-if (lambda (item)
                            (and (equal (alist-get 'role item) "assistant")
                                 (equal (omnigent-conversation--text item)
                                        "The capital of France is Paris.")))
                          (omnigent-functional-items buffer)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

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
            (with-current-buffer buffer
              (let ((request-id (alist-get 'elicitation_id (car (omnigent-conversation-elicitations)))))
                (omnigent-conversation-elicitation-submit
                 request-id action (lambda (status body) (setq reply (cons status body))))))
            (omnigent-functional-wait "Permission response was not acknowledged" reply)
            (should (= (car reply) 202))
            (omnigent-functional-wait "Permission turn did not become idle"
              (omnigent-functional-status-p id "idle"))
            (with-current-buffer buffer
              (should-not (omnigent-conversation-elicitations))
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
  (let ((id (omnigent-integration-create-session t)) buffer stream)
    (unwind-protect
        (save-window-excursion
          (setq buffer (omnigent-functional-open id)
                stream (buffer-local-value 'omnigent-conversation--stream buffer))
          (omnigent-functional-send buffer "test long_running")
          (omnigent-functional-wait "Turn did not start before closing"
            (omnigent-functional-status-p id "running"))
          (with-current-buffer buffer (insert "discard this draft"))
          (kill-buffer buffer)
          (should (omnigent-stream-stopped stream))
          (should-not (process-live-p (omnigent-stream-process stream)))
          (should-not (assoc id omnigent-sessions--buffers))
          (omnigent-functional-wait "Agent did not finish while buffer was closed"
            (omnigent-functional-status-p id "idle"))
          (setq buffer (omnigent-functional-open id))
          (let ((items (omnigent-functional-items buffer)))
            (should (= 1 (cl-count "user" items :key (lambda (item) (alist-get 'role item)) :test #'equal)))
            (should (= 1 (cl-count "assistant" items :key (lambda (item) (alist-get 'role item)) :test #'equal)))
            (should (cl-find-if (lambda (item)
                                 (equal (omnigent-conversation--text item)
                                        (apply #'concat (make-list 3 "The capital of France is Paris.")))) items)))
          (with-current-buffer buffer (should (equal (buffer-string) ""))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'omnigent-functional-tests)
;;; omnigent-functional-tests.el ends here
