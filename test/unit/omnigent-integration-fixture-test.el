;;; omnigent-integration-fixture-test.el --- Unit tests for integration test fixtures -*- lexical-binding: t; -*-

;;; Commentary:

;; Check that integration test fixtures isolate each run and clean up its resources.

;;; Code:

(require 'ert)
(require 'omnigent-integration-fixture)

(ert-deftest omnigent-integration-environment-is-isolated ()
  "Build a process environment without caller secrets or proxy settings."
  (let* ((root (make-temp-file "omnigent-integration-env-test-" t))
         (process-environment
          (append
           '("OPENAI_API_KEY=user-secret"
             "ANTHROPIC_BASE_URL=https://outside.invalid"
             "HTTPS_PROXY=http://proxy.invalid")
           process-environment))
         (environment
          (omnigent-integration--isolated-environment
           root "/official/repo" "http://127.0.0.1:12345")))
    (unwind-protect
        (let ((process-environment environment))
          (should
           (equal (getenv "HOME") (expand-file-name "home" root)))
          (should (equal (getenv "OPENAI_API_KEY") "mock-key"))
          (should
           (equal
            (getenv "OPENAI_BASE_URL") "http://127.0.0.1:12345/v1"))
          (should
           (equal
            (getenv "ANTHROPIC_BASE_URL") "http://127.0.0.1:12345"))
          (should-not (getenv "HTTPS_PROXY"))
          (should-not
           (equal (getenv "OPENAI_API_KEY") "user-secret")))
      (delete-directory root t))))

(ert-deftest omnigent-integration-stop-cleans-run-resources ()
  "Stop fixture processes and delete its directory and log buffers."
  (let* ((root (make-temp-file "omnigent-integration-stop-test-" t))
         (log
          (generate-new-buffer
           " *omnigent-integration-stop-test-log*"))
         (process
          (start-process "omnigent-integration-stop-test" nil "sleep"
                         "30"))
         (run
          (omnigent-integration--make-run
           :root root
           :processes (list process)
           :logs (list log))))
    (omnigent-integration-stop run)
    (should-not (process-live-p process))
    (should-not (file-exists-p root))
    (should-not (buffer-live-p log))))

(ert-deftest omnigent-integration-harness-uses-agent-and-owned-process
    ()
  "Pass the agent path to the CLI and retain the harness output for teardown."
  (let* ((root
          (make-temp-file "omnigent-integration-harness-test-" t))
         (executable (expand-file-name "fake-omnigent" root))
         (arguments-file (expand-file-name "arguments" root))
         (environment
          (omnigent-integration--isolated-environment
           root "/official/repo" "http://127.0.0.1:12345"))
         (run
          (omnigent-integration--make-run
           :root root
           :server-url "http://127.0.0.1:23456"
           :mock-url "http://127.0.0.1:12345"
           :environment environment
           :processes nil
           :logs nil))
         buffer)
    (with-temp-file executable
      (insert
       "#!/bin/sh\nprintf '%s\\n' \"$@\" > "
       (shell-quote-argument arguments-file)
       "\n"))
    (set-file-modes executable #o755)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (_name) executable)))
            (setq buffer
                  (omnigent-integration-run-harness
                   run "codex" "/tmp/agent.yaml" "hello")))
          (should
           (equal
            (with-temp-buffer
              (insert-file-contents arguments-file)
              (split-string (buffer-string) "\n" t))
            '("run"
              "/tmp/agent.yaml"
              "--server"
              "http://127.0.0.1:23456"
              "--harness"
              "codex"
              "--model"
              "mock-model"
              "-p"
              "hello")))
          (should
           (equal
            (buffer-local-value
             'omnigent-integration-exit-status buffer)
            0))
          (should
           (= (length (omnigent-integration-run-processes run)) 1)))
      (omnigent-integration-stop run))))

(ert-deftest omnigent-integration-stop-cleans-child-after-parent-exits
    ()
  "Stop an owned child after its process group leader exits first."
  (let* ((root
          (make-temp-file "omnigent-integration-process-group-test-"
                          t))
         (pid-file (expand-file-name "child.pid" root))
         (process
          (omnigent-integration--start-owned-process
           "omnigent-integration-parent-test"
           (list
            "sh" "-c"
            (format "sleep 30 & echo $! > %s; exit 0"
                    (shell-quote-argument pid-file)))
           nil))
         (group-id (process-id process))
         child-pid)
    (unwind-protect
        (progn
          (while (process-live-p process)
            (accept-process-output process 0.05))
          (should (file-exists-p pid-file))
          (setq child-pid
                (string-to-number
                 (with-temp-buffer
                   (insert-file-contents pid-file)
                   (string-trim (buffer-string)))))
          (should (process-attributes child-pid))
          (omnigent-integration--stop-process process group-id)
          ;; The child can still be visible briefly after the signal.
          (let ((deadline (+ (float-time) 2)))
            (while (and (process-attributes child-pid)
                        (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (should-not (process-attributes child-pid)))
      (omnigent-integration--stop-process process group-id)
      (delete-directory root t))))

(ert-deftest omnigent-integration-start-cleans-partial-initialization
    ()
  "Remove fixture resources when starting the mock process fails."
  (let* ((repo (make-temp-file "omnigent-integration-repo-test-" t))
         (mock-dir (expand-file-name "tests/server/integration" repo))
         (root nil)
         (original-make-temp-file (symbol-function 'make-temp-file))
         (process-environment
          (cons (concat "OMNIGENT_REPO=" repo) process-environment)))
    (make-directory mock-dir t)
    (with-temp-file (expand-file-name "mock_llm_server.py" mock-dir)
      (insert "# fixture stub\n"))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (_name) "/bin/true"))
                    ((symbol-function 'make-temp-file)
                     (lambda (prefix &optional directory)
                       (setq root
                             (funcall original-make-temp-file
                                      prefix
                                      directory))))
                    ((symbol-function 'file-executable-p)
                     (lambda (_path) t))
                    ((symbol-function
                      'omnigent-integration--free-port)
                     (lambda (_python) 43127))
                    ((symbol-function 'make-process)
                     (lambda (&rest _arguments)
                       (error "mock process startup failed"))))
            (should-error (omnigent-integration-start) :type 'error))
          (should root)
          (should-not (file-exists-p root))
          (should-not
           (cl-some
            (lambda (buffer)
              (string-match-p
               "omnigent-integration-mock-log" (buffer-name buffer)))
            (buffer-list))))
      (when (file-directory-p repo)
        (delete-directory repo t)))))

(provide 'omnigent-integration-fixture-test)

;;; omnigent-integration-fixture-test.el ends here
