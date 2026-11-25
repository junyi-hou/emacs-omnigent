;;; omnigent-integration-configuration-test.el --- Check Omnigent client configuration -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(defun omnigent-integration--check-session-list-option (run)
  "Check when the session list opens on the server for RUN."
  (let ((omnigent-server-url omnigent-server-url)
        (omnigent-auth-method 'none)
        (omnigent-open-session-list-on-connect nil))
    (save-window-excursion
      (unwind-protect
          (dolist (auto-open '(nil t))
            (setq omnigent-open-session-list-on-connect auto-open)
            (omnigent-connect
             (omnigent-integration-run-server-url run))
            (let ((deadline (+ (float-time) 10)))
              (while (and (< (float-time) deadline)
                          (not
                           (omnigent-session-updates-connected
                            omnigent-sessions-updates)))
                (accept-process-output nil 0.05)))
            (should
             (omnigent-session-updates-connected
              omnigent-sessions-updates))
            (if auto-open
                (should
                 (window-live-p
                  (get-buffer-window "*omnigent-sessions*")))
              (should-not (get-buffer-window "*omnigent-sessions*"))
              (call-interactively #'omnigent-ui-sessions)
              (should
               (window-live-p
                (get-buffer-window "*omnigent-sessions*"))))
            (omnigent-disconnect))
        (when omnigent-sessions-updates
          (omnigent-disconnect))))))

(defun omnigent-integration--get-json (path)
  "Read a JSON object from PATH on the test server."
  (let ((response
         (url-retrieve-synchronously
          (concat omnigent-server-url path) t t 5)))
    (should response)
    (unwind-protect
        (with-current-buffer response
          (should (= url-http-response-status 200))
          (goto-char url-http-end-of-headers)
          (json-parse-buffer :object-type 'alist :array-type 'list))
      (kill-buffer response))))

(defun omnigent-integration--wait (predicate)
  "Wait for PREDICATE to return a value."
  (let ((deadline (+ (float-time) 20))
        value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should value)
    value))

(defun omnigent-integration--check-agent-options (run)
  "Check that the server for RUN stores defaults and selected overrides."
  (let* ((omnigent-server-url
          (omnigent-integration-run-server-url run))
         (omnigent-auth-method 'none)
         (omnigent-session-default-workspace
          (omnigent-integration-run-root run))
         (omnigent-session-default-model "mock-model")
         (omnigent-session-default-reasoning-effort "low")
         (omnigent--create-draft nil)
         (host-log
          (generate-new-buffer " *omnigent-integration-host*"))
         (agents
          (alist-get
           'data (omnigent-integration--get-json "/v1/agents")))
         (default-agent
          (seq-find
           (lambda (agent)
             (equal (alist-get 'name agent) "codex-native-ui"))
           agents))
         (selected-agent
          (seq-find
           (lambda (agent)
             (equal (alist-get 'name agent) "claude-native-ui"))
           agents))
         (omnigent-session-default-agent
          (alist-get 'id default-agent))
         (selected-name (alist-get 'name selected-agent))
         (omnigent-session-agent-overrides
          `((,selected-name
             .
             ((model_override . "mock-model-alt")
              (reasoning_effort . "high")))))
         created
         (omnigent-sessions-open-hook
          (list
           (lambda (session)
             (setq created (alist-get 'id session))))))
    (push host-log (omnigent-integration-run-logs run))
    (should default-agent)
    (should selected-agent)
    (let ((process-environment
           (omnigent-integration-run-environment run))
          (default-directory omnigent-session-default-workspace))
      (omnigent-integration--register-process
       run
       (omnigent-integration--start-owned-process
        "omnigent-integration-host"
        (list
         (executable-find "omnigent")
         "host"
         "--server"
         omnigent-server-url
         "--no-open"
         "--non-interactive")
        host-log)))
    (let ((omnigent-session-default-host
           (alist-get
            'host_id
            (omnigent-integration--wait
             (lambda ()
               (seq-find
                (lambda
                  (host)
                  (equal (alist-get 'status host) "online"))
                (alist-get
                 'hosts
                 (omnigent-integration--get-json "/v1/hosts"))))))))
      (unwind-protect
          (with-temp-buffer
            (dolist (select-agent '(nil t))
              (setq created nil)
              (if select-agent
                  (cl-letf (((symbol-function 'omnigent--create-menu)
                             #'ignore)
                            ((symbol-function 'completing-read)
                             (lambda (_prompt choices &rest _)
                               (should (assoc selected-name choices))
                               selected-name)))
                    (omnigent-sessions-create '(4))
                    (omnigent--create-agent)
                    (omnigent-integration--wait
                     (lambda ()
                       (alist-get
                        'agent_id (cdr omnigent--create-draft))))
                    (omnigent--create-submit))
                (omnigent-sessions-create))
              (let ((session
                     (omnigent-integration--get-json
                      (omnigent-transport--session-path
                       (omnigent-integration--wait
                        (lambda () created))))))
                (should
                 (equal
                  (alist-get 'host_id session)
                  omnigent-session-default-host))
                (should
                 (file-equal-p
                  (alist-get 'workspace session)
                  omnigent-session-default-workspace))
                (should
                 (equal
                  (alist-get 'agent_id session)
                  (alist-get
                   'id
                   (if select-agent
                       selected-agent
                     default-agent))))
                (should
                 (equal
                  (alist-get 'model_override session)
                  (if select-agent
                      "mock-model-alt"
                    "mock-model")))
                (should
                 (equal
                  (alist-get 'reasoning_effort session)
                  (if select-agent
                      "high"
                    "low"))))))
        (omnigent-disconnect)))))

(ert-deftest omnigent-integration-configuration ()
  "Check session list and session creation options on one server."
  (omnigent-integration-with-run
   run
   (omnigent-integration--check-session-list-option run)
   (omnigent-integration--check-agent-options run)))

;;; omnigent-integration-configuration-test.el ends here
