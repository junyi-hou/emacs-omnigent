;;; omnigent-test.el --- Tests for Omnigent entry points -*- lexical-binding: t; -*-

(require 'ert)
(require 'omnigent)

(ert-deftest omnigent-connect-defaults-to-new-session ()
  "Offer New session as the default choice after connecting."
  (let ((omnigent-server-url "http://old.example")
        default-choice new-session-selected)
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (_method path callback)
                 (should (equal path "/v1/sessions?limit=1000&include_archived=true&sort_by=updated_at&order=desc"))
                 (funcall callback 200
                          '((data . [((id . "conv-1") (title . "Work")
                                      (agent_name . "Pi") (status . "idle"))])))))
              ((symbol-function 'completing-read)
               (lambda (_prompt _choices &rest args)
                 (setq default-choice (nth 4 args))
                 default-choice))
              ((symbol-function 'omnigent--new-session)
               (lambda () (setq new-session-selected t))))
      (omnigent-connect "http://example.test/"))
    (should (equal omnigent-server-url "http://example.test"))
    (should (equal default-choice "New session"))
    (should new-session-selected)))

(ert-deftest omnigent-selects-existing-session ()
  "Resume the selected existing session."
  (let (resumed-session)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _args) (caadr choices)))
              ((symbol-function 'omnigent-resume-session)
               (lambda (session-id) (setq resumed-session session-id))))
      (omnigent--select-session
       "http://example.test" 200
       '((data . [((id . "conv-1") (title . "Work")
                   (agent_name . "Pi") (status . "idle"))])))
    (should (equal resumed-session "conv-1")))))

(ert-deftest omnigent-new-session-creates-and-selects-an-agent-session ()
  "Create a session for the selected agent and select its snapshot."
  (let (omnigent-current-session-id omnigent-current-session)
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (method path callback &optional data)
                 (cond
                  ((equal method "GET")
                   (should (equal path "/v1/agents?limit=1000"))
                   (funcall callback 200
                            '((data . [((id . "agent-1") (name . "Pi")
                                        (harness . "pi"))]))))
                  ((equal method "POST")
                   (should (equal path "/v1/sessions"))
                   (should (equal (cdr (assoc "agent_id" data)) "agent-1"))
                   (funcall callback 201
                            '((id . "conv-new") (status . "idle")))))))
              ((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _args) (caar choices)))
              ((symbol-function 'message) #'ignore))
      (omnigent--new-session))
    (should (equal omnigent-current-session-id "conv-new"))
    (should (equal (cdr (assq 'status omnigent-current-session)) "idle"))))

(ert-deftest omnigent-resume-loads-session-snapshot ()
  "Set the selected session from the server snapshot."
  (let (omnigent-current-session-id omnigent-current-session)
    (cl-letf (((symbol-function 'omnigent-transport-get-session)
               (lambda (session-id callback)
                 (funcall callback 200
                          `((id . ,session-id) (status . "idle")))))
              ((symbol-function 'message) #'ignore))
      (omnigent-resume-session "conv-known"))
    (should (equal omnigent-current-session-id "conv-known"))
    (should (equal (cdr (assq 'status omnigent-current-session)) "idle"))))

(ert-deftest omnigent-start-parses-server-url-from-cli-output ()
  "Extract the URL printed by the Omnigent server command."
  (with-temp-buffer
    (insert "Started background server at http://127.0.0.1:6767\n  log: server.log\n")
    (should (equal (omnigent--server-url-from-output (current-buffer))
                   "http://127.0.0.1:6767"))))

(provide 'omnigent-test)
;;; omnigent-test.el ends here
