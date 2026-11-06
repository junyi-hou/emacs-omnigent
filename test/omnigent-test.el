;;; omnigent-test.el --- Tests for Omnigent entry points -*- lexical-binding: t; -*-

(require 'ert)
(require 'omnigent)

(ert-deftest omnigent-connect-sets-server-url ()
  "Reset transport and set the server URL without selecting a session."
  (let ((omnigent-server-url "http://old.example") reset)
    (cl-letf (((symbol-function 'omnigent-transport-reset)
               (lambda () (setq reset t)))
              ((symbol-function 'omnigent-transport-request)
               (lambda (&rest _) (ert-fail "Unexpected request"))))
      (omnigent-connect "http://example.test/"))
    (should reset)
    (should (equal omnigent-server-url "http://example.test"))))

(ert-deftest omnigent-list-sessions-requests-most-recent ()
  "Request the most recently updated sessions, including archived ones."
  (cl-letf (((symbol-function 'omnigent-transport-request)
             (lambda (method path callback)
               (should (equal method "GET"))
               (should (equal path "/v1/sessions?limit=1000&include_archived=true&sort_by=updated_at&order=desc"))
               (should (eq callback #'ignore)))))
    (omnigent-transport-list-sessions #'ignore)))

(ert-deftest omnigent-start-parses-server-url-from-cli-output ()
  "Extract the URL printed by the Omnigent server command."
  (with-temp-buffer
    (insert "Started background server at http://127.0.0.1:6767\n  log: server.log\n")
    (should (equal (omnigent--server-url-from-output (current-buffer))
                   "http://127.0.0.1:6767"))))

(provide 'omnigent-test)
;;; omnigent-test.el ends here
