;;; omnigent-test.el --- Tests for Omnigent entry points -*- lexical-binding: t; -*-

(require 'ert)
(require 'omnigent)

(ert-deftest omnigent-connect-sets-server-url ()
  "Reset transport and set the server URL without selecting a session."
  (let ((omnigent-server-url "http://old.example") reset)
    (cl-letf (((symbol-function 'omnigent-transport-reset)
               (lambda () (setq reset t)))
              ((symbol-function 'omnigent-transport-request)
               (lambda (&rest _) (ert-fail "Unexpected request")))
              ((symbol-function 'make-process)
               (lambda (&rest _) (ert-fail "Connecting must not launch a process"))))
      (omnigent-connect "http://example.test/"))
    (should reset)
    (should (equal omnigent-server-url "http://example.test"))))

(ert-deftest omnigent-list-sessions-requests-most-recent ()
  "Request the most recently updated sessions, including archived ones."
  (let ((omnigent-transport-session-limit 42))
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (method path callback)
                 (should (equal method "GET"))
                 (should (equal path "/v1/sessions?limit=42&include_archived=true&sort_by=updated_at&order=desc"))
                 (should (eq callback #'ignore)))))
      (omnigent-transport-list-sessions #'ignore))))

(ert-deftest omnigent-start-parses-server-url-from-cli-output ()
  "Extract the URL printed by the Omnigent server command."
  (with-temp-buffer
    (insert "Started background server at http://127.0.0.1:6767\n  log: server.log\n")
    (should (equal (omnigent--server-url-from-output (current-buffer))
                   "http://127.0.0.1:6767"))))

(ert-deftest omnigent-start-establishes-local-server-and-host ()
  "Start local mode explicitly without using saved remote-server defaults."
  (let ((omnigent-executable "/bin/omnigent")
        (omnigent-start-process nil)
        (omnigent-server-url "http://old.example")
        commands process-options
        (buffer (get-buffer-create "*Omnigent Server Startup*")))
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (name) name))
                  ((symbol-function 'make-process)
                   (lambda (&rest options)
                     (push (plist-get options :command) commands)
                     (setq process-options options)
                     'startup))
                  ((symbol-function 'process-live-p) (lambda (_) nil))
                  ((symbol-function 'process-status) (lambda (_) 'exit))
                  ((symbol-function 'process-exit-status) (lambda (_) 0))
                  ((symbol-function 'process-buffer) (lambda (_) buffer))
                  ((symbol-function 'process-command) (lambda (_) (car commands)))
                  ((symbol-function 'omnigent-transport-reset) #'ignore))
          (omnigent-start-server)
          (should (equal (car commands)
                         '("/bin/omnigent" "host" "--server" "" "--background"
                           "--no-open" "--non-interactive")))
          (with-current-buffer buffer (insert "server http://127.0.0.1:6767\n"))
          (funcall (plist-get process-options :sentinel) 'startup "finished")
          (should (= (length commands) 1))
          (should (equal omnigent-server-url "http://127.0.0.1:6767"))
          (should-not omnigent-start-process)
          (should-not (buffer-live-p buffer)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(provide 'omnigent-test)
;;; omnigent-test.el ends here
