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

(provide 'omnigent-functional-tests)
;;; omnigent-functional-tests.el ends here
