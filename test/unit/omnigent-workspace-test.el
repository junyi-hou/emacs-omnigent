;;; omnigent-workspace-test.el --- Workspace data tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'omnigent-workspace)

(ert-deftest omnigent-workspace-host-address-mapping ()
  "Map host IDs to local or SSH workspace access."
  (let ((omnigent-server-url "http://localhost:6767")
        (omnigent-host-address-function (lambda (_id) "localhost")))
    (should (eq (omnigent-workspace-host-mapping "host") 'local))
    (let ((omnigent-server-url "http://server.example:6767"))
      (should
       (equal
        (omnigent-workspace-host-mapping "host")
        "/ssh:server.example:")))
    (let ((omnigent-host-address-function
           (lambda (id) (concat id ".example"))))
      (should
       (equal
        (omnigent-workspace-host-mapping "runner")
        "/ssh:runner.example:")))
    (should-error (omnigent-workspace-host-mapping nil))))

(ert-deftest omnigent-workspace-default-host-address ()
  "Use the server host for local and remote default mappings."
  (let ((omnigent-host-address-function
         (default-value 'omnigent-host-address-function)))
    (let ((omnigent-server-url "http://localhost:6767"))
      (should (eq (omnigent-workspace-host-mapping "host") 'local)))
    (let ((omnigent-server-url "http://server.example:6767"))
      (should
       (equal
        (omnigent-workspace-host-mapping "host")
        "/ssh:server.example:")))))

(ert-deftest omnigent-workspace-local-filename-access ()
  "Require a trusted mapping and a relative path for direct access."
  (should
   (equal
    (omnigent-workspace-local-filename
     "/workspace" "src/file" 'local)
    "/workspace/src/file"))
  (should-error
   (omnigent-workspace-local-filename "/workspace" "src/file"))
  (should-error
   (omnigent-workspace-local-filename
    "/workspace" "../secret" 'local)))

(ert-deftest omnigent-workspace-root-retries-host-only-listing ()
  "Retry transient host listings, bound retries, and stop after disconnect."
  (dolist (scenario '(ready unavailable disconnected))
    (let ((omnigent-transport--generation 0)
          (attempts 0)
          scheduled
          result)
      (cl-letf (((symbol-function 'omnigent-transport--request)
                 (lambda (_session-id
                          _method path callback &optional _data)
                   (if (string-suffix-p "/filesystem" path)
                       (progn
                         (cl-incf attempts)
                         (funcall callback
                                  200
                                  (if (and (eq scenario 'ready)
                                           (> attempts 1))
                                      '((base . "/workspace"))
                                    '((object . "list")
                                      (data . [])))))
                     (funcall callback 200 '((data . []))))))
                ((symbol-function 'run-at-time)
                 (lambda (_time _repeat function &rest _args)
                   (setq scheduled function))))
        (omnigent-workspace--root
         "id" (lambda (status body) (setq result (cons status body))))
        (should scheduled)
        (should-not result)
        (when (eq scenario 'disconnected)
          (cl-incf omnigent-transport--generation))
        (while scheduled
          (let ((next scheduled))
            (setq scheduled nil)
            (funcall next)))
        (pcase scenario
          ('ready
           (should (= attempts 2))
           (should (= (car result) 200))
           (should
            (equal (alist-get 'base (cdr result)) "/workspace")))
          ('unavailable
           (should (= attempts 11))
           (should
            (equal result '(200 (object . "list") (data . [])))))
          ('disconnected
           (should (= attempts 1))
           (should-not result)))))))

(provide 'omnigent-workspace-test)
;;; omnigent-workspace-test.el ends here
