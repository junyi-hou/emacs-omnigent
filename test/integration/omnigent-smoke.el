;;; omnigent-smoke.el --- Isolated real-server smoke test fixtures -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Helpers for ERT CUJ tests.  Each invocation owns its processes and files.

;;; Code:

(require 'cl-lib)
(require 'url)
(require 'url-http)
(require 'json)

(cl-defstruct
 (omnigent-smoke-run (:constructor omnigent-smoke--make-run))
 "Resources owned by one isolated CUJ invocation."
 root
 server-url
 mock-url
 environment
 processes
 process-groups
 logs)

(defconst omnigent-smoke--mock-relative-path
  "tests/server/integration/mock_llm_server.py"
  "Relative path to the official Omnigent local mock LLM fixture.")

(defconst omnigent-smoke--model "mock-model"
  "Model name served by the official Omnigent integration fixture.")

(defconst omnigent-smoke--harness-timeout 120
  "Maximum time in seconds to wait for a harness invocation.")

(defvar-local omnigent-smoke-exit-status nil
  "Exit status from an Omnigent smoke harness process.")

(defun omnigent-smoke--isolated-environment
    (root repo &optional mock-url)
  "Build a clean process environment rooted at ROOT and using MOCK-URL.

REPO supplies the official fixture imports.  Only executable lookup, locale,
and explicitly configured test values are inherited from the parent."
  (let ((path (or (getenv "PATH") ""))
        (lang (getenv "LANG"))
        (lc-all (getenv "LC_ALL")))
    (let ((process-environment nil))
      (setenv "PATH" path)
      (when lang
        (setenv "LANG" lang))
      (when lc-all
        (setenv "LC_ALL" lc-all))
      (setenv "HOME" (expand-file-name "home" root))
      (setenv "OMNIGENT_CONFIG_HOME" (expand-file-name "config" root))
      (setenv "XDG_CONFIG_HOME" (expand-file-name "config" root))
      (setenv "XDG_DATA_HOME" (expand-file-name "data" root))
      (setenv "XDG_CACHE_HOME" (expand-file-name "cache" root))
      (setenv "XDG_STATE_HOME" (expand-file-name "state" root))
      (setenv "XDG_RUNTIME_DIR" (expand-file-name "runtime" root))
      (setenv "TMPDIR" (expand-file-name "tmp" root))
      (setenv "TMP" (expand-file-name "tmp" root))
      (setenv "TEMP" (expand-file-name "tmp" root))
      (setenv "PYTHONPATH" repo)
      (setenv "PYTHONDONTWRITEBYTECODE" "1")
      (when mock-url
        (setenv "OPENAI_API_KEY" "mock-key")
        (setenv "OPENAI_BASE_URL" (concat mock-url "/v1"))
        (setenv "ANTHROPIC_API_KEY" "mock-key")
        (setenv "ANTHROPIC_BASE_URL" mock-url))
      (setenv "NO_COLOR" "1")
      (copy-sequence process-environment))))

(defun omnigent-smoke--log-text (log)
  "Return the contents of LOG, which can be a buffer or file name."
  (if (bufferp log)
      (with-current-buffer log
        (buffer-substring-no-properties
         (max (point-min) (- (point-max) 4000)) (point-max)))
    (if (file-readable-p log)
        (with-temp-buffer
          (insert-file-contents log)
          (buffer-substring-no-properties
           (max (point-min) (- (point-max) 4000)) (point-max)))
      "no log")))

(defun omnigent-smoke--free-port (python)
  "Return an available loopback port selected with PYTHON."
  (with-temp-buffer
    (unless
        (=
         0
         (call-process
          python
          nil
          t
          nil
          "-c"
          "import socket; s=socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1]); s.close()"))
      (error "Could not select a loopback port"))
    (string-to-number (string-trim (buffer-string)))))

(defun omnigent-smoke--with-port-lock (function)
  "Call FUNCTION while holding a cross-process fixture port lock."
  (let ((lock-directory
         (expand-file-name "omnigent-smoke-port-lock"
                           temporary-file-directory))
        (deadline (+ (float-time) 30))
        locked)
    (unwind-protect
        (progn
          (while (not locked)
            (condition-case nil
                (progn
                  (make-directory lock-directory)
                  (setq locked t))
              (file-already-exists
               (when (>= (float-time) deadline)
                 (error "Timed out waiting for fixture port lock"))
               (sleep-for 0.05))))
          (funcall function))
      (when locked
        (delete-directory lock-directory t)))))

(defun omnigent-smoke--wait-for-health
    (url process log &optional endpoint)
  "Wait until PROCESS serves ENDPOINT at URL, or signal with LOG contents."
  (let ((deadline (+ (float-time) 20))
        (ready nil))
    (while (and (not ready)
                (< (float-time) deadline)
                (process-live-p process))
      (condition-case nil
          (let ((response
                 (url-retrieve-synchronously
                  (concat url (or endpoint "/health")) t t 1)))
            (when response
              (with-current-buffer response
                (setq ready
                      (and (boundp 'url-http-response-status)
                           (= url-http-response-status 200)))
                (kill-buffer response))))
        (error
         nil))
      (unless ready
        (sleep-for 0.1)))
    (unless ready
      (error "Service did not become healthy: %s"
             (omnigent-smoke--log-text log)))))

(defun omnigent-smoke--post-json (url data)
  "POST DATA as JSON to URL and require a successful response."
  (let* ((url-request-method "POST")
         (url-request-extra-headers
          '(("Content-Type" . "application/json")))
         (url-request-data (json-encode data))
         (buffer (url-retrieve-synchronously url t t 5)))
    (unless buffer
      (error "No response from %s" url))
    (with-current-buffer buffer
      (unwind-protect
          (unless (and (boundp 'url-http-response-status)
                       (<= 200 url-http-response-status)
                       (< url-http-response-status 300))
            (error "POST %s failed: %s" url url-http-response-status))
        (kill-buffer buffer)))))

(defun omnigent-smoke--start-owned-process (name command buffer)
  "Start COMMAND in its own Emacs process group and return the process.

NAME names the Emacs process.  BUFFER receives standard output and error.
The process group keeps ownership of children if COMMAND exits first."
  (make-process
   :name name
   :command command
   :buffer buffer
   :stderr buffer
   :noquery t
   :connection-type 'pipe))

(defun omnigent-smoke--group-members (group-id)
  "Return live operating system process IDs in GROUP-ID."
  (let (members)
    (dolist (pid (list-system-processes))
      (let* ((attributes
              (ignore-errors
                (process-attributes pid)))
             (process-group (cdr (assq 'pgrp attributes))))
        (when (and attributes
                   (numberp process-group)
                   (= process-group group-id))
          (push pid members))))
    members))

(defun omnigent-smoke--stop-process-group (group-id)
  "Terminate all processes in GROUP-ID, even when its leader has exited."
  (ignore-errors
    (signal-process (- group-id) 'SIGTERM))
  (let ((deadline (+ (float-time) 2))
        (members (omnigent-smoke--group-members group-id)))
    (while (and members (< (float-time) deadline))
      (sleep-for 0.05)
      (setq members (omnigent-smoke--group-members group-id)))
    (when members
      (ignore-errors
        (signal-process (- group-id) 'SIGKILL))
      (let ((kill-deadline (+ (float-time) 1)))
        (while (and (omnigent-smoke--group-members group-id)
                    (< (float-time) kill-deadline))
          (sleep-for 0.05))))))

(defun omnigent-smoke--stop-process (process &optional group-id)
  "Stop PROCESS and its owned GROUP-ID, even if PROCESS has exited."
  (when group-id
    (omnigent-smoke--stop-process-group group-id))
  (when (and (processp process) (process-live-p process))
    (delete-process process)))

(defun omnigent-smoke--register-process (run process)
  "Register PROCESS and its process group with RUN, then return PROCESS."
  (let* ((pid (process-id process))
         (attributes (process-attributes pid))
         (group-id (or (cdr (assq 'pgrp attributes)) pid)))
    (unless (= group-id pid)
      (delete-process process)
      (error "Emacs did not isolate process %s in its own group" pid))
    (push process (omnigent-smoke-run-processes run))
    (push group-id (omnigent-smoke-run-process-groups run)))
  process)

(defun omnigent-smoke-start ()
  "Start isolated official mock and real Omnigent server resources.

The caller must pass the returned run to `omnigent-smoke-stop', usually in
an `unwind-protect' cleanup clause."
  (let* ((repo (getenv "OMNIGENT_REPO"))
         (repo (and repo (expand-file-name repo)))
         (mock-script
          (and repo
               (expand-file-name omnigent-smoke--mock-relative-path
                                 repo)))
         (omnigent (executable-find "omnigent"))
         (python
          (expand-file-name ".tools/omnigent-mock/bin/python"
                            (locate-dominating-file
                             default-directory "Makefile"))))
    (unless repo
      (error "Set OMNIGENT_REPO to an official Omnigent checkout"))
    (unless (file-exists-p mock-script)
      (error "Official Omnigent mock server not found: %s"
             mock-script))
    (unless omnigent
      (error "The omnigent executable is required for smoke tests"))
    (unless (file-executable-p python)
      (error
       "Run make integration-deps to install mock Python dependencies"))
    (let* ((root (make-temp-file "omnigent-smoke-" t))
           (home (expand-file-name "home" root))
           (config (expand-file-name "config" root))
           (data (expand-file-name "data" root))
           mock-url
           mock-log
           (environment nil)
           (completed nil)
           server-process
           server-port
           run)
      (unwind-protect
          (condition-case error-data
              (progn
                (setq run
                      (omnigent-smoke--make-run
                       :root root
                       :processes nil
                       :process-groups nil
                       :logs nil))
                (setq mock-log
                      (generate-new-buffer
                       " *omnigent-smoke-mock-log*"))
                (push mock-log (omnigent-smoke-run-logs run))
                (setf (omnigent-smoke-run-mock-url run) nil)
                (dolist (directory
                         (list
                          home
                          config
                          data
                          (expand-file-name "cache" root)
                          (expand-file-name "state" root)
                          (expand-file-name "runtime" root)
                          (expand-file-name "tmp" root)))
                  (make-directory directory t))
                (setq environment
                      (omnigent-smoke--isolated-environment
                       root repo))
                (omnigent-smoke--with-port-lock
                 (lambda ()
                   (let* ((mock-port
                           (omnigent-smoke--free-port python))
                          (process-environment environment)
                          (default-directory repo))
                     (setq mock-url
                           (format "http://127.0.0.1:%d" mock-port))
                     (omnigent-smoke--register-process
                      run
                      (omnigent-smoke--start-owned-process
                       "omnigent-smoke-mock"
                       (list
                        python
                        mock-script
                        (number-to-string mock-port))
                       mock-log)))
                   (setf (omnigent-smoke-run-mock-url run) mock-url)
                   (omnigent-smoke--wait-for-health
                    mock-url
                    (car (omnigent-smoke-run-processes run))
                    mock-log
                    "/v1/models")))
                (omnigent-smoke--post-json
                 (concat mock-url "/mock/served_models")
                 '((models . ["mock-model"])))
                (omnigent-smoke--post-json
                 (concat mock-url "/mock/configure")
                 '((key . "mock-model")
                   (responses
                    . [((text . "OMNIGENT_SMOKE_RESPONSE"))])))
                (setq environment
                      (omnigent-smoke--isolated-environment root repo
                                                            mock-url))
                (setf (omnigent-smoke-run-environment run)
                      environment)
                (let* ((server-log
                        (generate-new-buffer
                         " *omnigent-smoke-server-log*")))
                  (push server-log (omnigent-smoke-run-logs run))
                  (omnigent-smoke--with-port-lock
                   (lambda ()
                     (setq server-port
                           (omnigent-smoke--free-port python))
                     (let ((process-environment environment)
                           (default-directory root))
                       (setq server-process
                             (omnigent-smoke--register-process
                              run
                              (omnigent-smoke--start-owned-process
                               "omnigent-smoke-server"
                               (list
                                omnigent
                                "server"
                                "--host"
                                "127.0.0.1"
                                "--port"
                                (number-to-string server-port)
                                "--database-uri"
                                (concat
                                 "sqlite:///"
                                 (expand-file-name "server.db" root))
                                "--artifact-location"
                                (expand-file-name "artifacts" root)
                                "--no-open")
                               server-log))))
                     (let ((server-url
                            (format "http://127.0.0.1:%d"
                                    server-port)))
                       (setf (omnigent-smoke-run-server-url run)
                             server-url)
                       (omnigent-smoke--wait-for-health
                        server-url server-process server-log))))
                  (setq completed t)
                  run))
            (error
             (signal (car error-data) (cdr error-data))))
        (unless completed
          (if run
              (omnigent-smoke-stop run)
            (when (buffer-live-p mock-log)
              (kill-buffer mock-log))
            (when (file-directory-p root)
              (delete-directory root t))))))))

(defun omnigent-smoke-stop (run)
  "Stop all processes and remove temporary resources owned by RUN."
  (dolist (group-id (omnigent-smoke-run-process-groups run))
    (omnigent-smoke--stop-process-group group-id))
  (dolist (process (omnigent-smoke-run-processes run))
    (omnigent-smoke--stop-process process))
  (dolist (log (omnigent-smoke-run-logs run))
    (when (buffer-live-p log)
      (kill-buffer log)))
  (when (file-directory-p (omnigent-smoke-run-root run))
    (delete-directory (omnigent-smoke-run-root run) t)))

(defun omnigent-smoke-run-harness (run harness agent prompt)
  "Run HARNESS for AGENT with PROMPT against RUN's real Omnigent server.

AGENT is an agent YAML file or directory accepted by `omnigent run'.
Return the output buffer.  Its exit status is in
`omnigent-smoke-exit-status'.  RUN owns the buffer and process for teardown."
  (let ((omnigent (executable-find "omnigent")))
    (unless omnigent
      (error "The omnigent executable is required for smoke tests"))
    (let ((buffer (generate-new-buffer " *omnigent-smoke-harness*")))
      (push buffer (omnigent-smoke-run-logs run))
      (let ((process-environment
             (copy-sequence (omnigent-smoke-run-environment run)))
            (default-directory (omnigent-smoke-run-root run))
            (completed nil)
            process)
        (unwind-protect
            (progn
              (setq process
                    (omnigent-smoke--register-process
                     run
                     (omnigent-smoke--start-owned-process
                      "omnigent-smoke-harness"
                      (list
                       omnigent
                       "run"
                       agent
                       "--server"
                       (omnigent-smoke-run-server-url run)
                       "--harness"
                       harness
                       "--model"
                       omnigent-smoke--model
                       "-p"
                       prompt)
                      buffer)))
              (let ((deadline
                     (+ (float-time)
                        omnigent-smoke--harness-timeout)))
                (while (and (process-live-p process)
                            (< (float-time) deadline))
                  (accept-process-output process 0.1)))
              (when (process-live-p process)
                (error "Harness timed out after %s seconds"
                       omnigent-smoke--harness-timeout))
              (with-current-buffer buffer
                (setq-local omnigent-smoke-exit-status
                            (process-exit-status process)))
              (setq completed t)
              buffer)
          (unless completed
            (when process
              (omnigent-smoke--stop-process process
                                            (process-id process)))
            (when (buffer-live-p buffer)
              (kill-buffer buffer))))))))

(defmacro omnigent-smoke-with-run (variable &rest body)
  "Bind VARIABLE to an isolated run while evaluating BODY, then clean up."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,variable (omnigent-smoke-start)))
     (unwind-protect
         (progn
           ,@body)
       (omnigent-smoke-stop ,variable))))

(provide 'omnigent-smoke)

;;; omnigent-smoke.el ends here
