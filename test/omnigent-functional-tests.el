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

(provide 'omnigent-functional-tests)
;;; omnigent-functional-tests.el ends here
