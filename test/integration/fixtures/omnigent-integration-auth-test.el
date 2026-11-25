;;; omnigent-integration-auth-test.el --- Check bearer authentication -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(defun omnigent-integration--auth-request (method path &optional data)
  "Send METHOD to PATH with DATA and wait for the status and body."
  (let (response)
    (omnigent-transport-request
     method path
     (lambda (status body) (setq response (cons status body))) data)
    (omnigent-integration--wait (lambda () response))))

(defun omnigent-integration--check-auth-stream ()
  "Check that the authenticated session stream receives a live frame."
  (let* ((agents
          (omnigent-integration--auth-request "GET" "/v1/agents"))
         (agent
          (seq-find
           (lambda (entry)
             (equal (alist-get 'name entry) "codex-native-ui"))
           (alist-get 'data (cdr agents)))))
    (should (= 200 (car agents)))
    (should agent)
    (let* ((response
            (omnigent-integration--auth-request
             "POST" "/v1/sessions"
             `((agent_id . ,(alist-get 'id agent)))))
           (id (alist-get 'id (cdr response))))
      (should (= 201 (car response)))
      (should (stringp id))
      (let ((stream
             (omnigent-transport-start-session-stream
              id #'ignore #'ignore)))
        (unwind-protect
            (omnigent-integration--wait
             (lambda () (omnigent-stream-ready stream)))
          (omnigent-transport-stop-session-stream stream))))))

(ert-deftest omnigent-integration-auth ()
  "Connect to an accounts server with a valid bearer token."
  (let
      ((omnigent-integration--server-environment
        '("OMNIGENT_AUTH_PROVIDER=accounts"
          "OMNIGENT_LOCAL_SINGLE_USER=0"
          "OMNIGENT_ACCOUNTS_INIT_ADMIN_USERNAME=integration-admin"
          "OMNIGENT_ACCOUNTS_INIT_ADMIN_PASSWORD=integration-test-password")))
    (omnigent-integration-with-run
     run
     (let ((omnigent-server-url
            (omnigent-integration-run-server-url run))
           (omnigent-auth-method 'none)
           (omnigent-extra-headers nil)
           (omnigent-open-session-list-on-connect t))
       ;; Emacs URL prompts for credentials on HTTP 401.
       (dolist (headers
                '(nil ("-H" "Authorization: Bearer invalid-token")))
         (with-temp-buffer
           (should
            (zerop
             (apply #'call-process
                    "curl"
                    nil
                    t
                    nil
                    "--silent"
                    "--show-error"
                    "--max-time"
                    "5"
                    "--output"
                    "/dev/null"
                    "--write-out"
                    "%{http_code}"
                    (concat omnigent-server-url "/v1/sessions")
                    headers)))
           (should (equal (buffer-string) "401"))))
       (let* ((login
               (omnigent-integration--auth-request
                "POST" "/auth/login"
                '((username . "integration-admin")
                  (password . "integration-test-password"))))
              (token (alist-get 'token (cdr login)))
              (omnigent-auth-method 'token)
              (omnigent-auth-token-function (lambda () token)))
         (should (= 200 (car login)))
         (should (stringp token))
         (should
          (= 200
             (car
              (omnigent-integration--auth-request
               "GET" "/v1/sessions"))))
         (save-window-excursion
           (unwind-protect
               (progn
                 (omnigent-connect omnigent-server-url)
                 (omnigent-integration--wait
                  (lambda ()
                    (omnigent-session-updates-connected
                     omnigent-sessions-updates)))
                 (omnigent-integration--check-auth-stream))
             (omnigent-disconnect))))))))

;;; omnigent-integration-auth-test.el ends here
