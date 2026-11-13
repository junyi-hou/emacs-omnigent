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

(ert-deftest omnigent-workspace-diff-and-failures ()
  "Check diff generation, URL encoding, and request failures."
  (let (requests
        result
        failure)
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (_method path callback &optional _data)
                 (push path requests)
                 (cond
                  ((string-suffix-p "/changes" path)
                   (funcall callback
                            200
                            '((data
                               .
                               [((path . "a b/x#y"))
                                ((path . "new"))]))))
                  ((string-suffix-p "/new" path)
                   (funcall callback
                            200
                            '((before . nil) (after . "new\n"))))
                  (failure
                   (funcall callback 503 '((error . "unavailable"))))
                  (t
                   (funcall callback
                            200
                            '((before . "old\n")
                              (after . "changed\n"))))))))
      (omnigent-workspace-diff
       "id/1" (lambda (status body) (setq result (cons status body))))
      (should (= (car result) 200))
      (should
       (string-match-p (regexp-quote "-old\n+changed") (cdr result)))
      (should (string-match-p (regexp-quote "+new") (cdr result)))
      (should
       (cl-some
        (lambda (path)
          (string-match-p "id%2F1.*a%20b/x%23y" path))
        requests))
      (setq
       failure t
       result nil)
      (omnigent-workspace-diff
       "id" (lambda (status body) (setq result (cons status body))))
      (should (= (car result) 503)))))

(ert-deftest
    omnigent-workspace-consumer-errors-are-not-request-failures
    ()
  "Propagate consumer errors without delivering a second operation result."
  (dolist (operation
           '(omnigent-workspace-diff omnigent-workspace-list))
    (dolist (paths '([] [((path . "file") (status . "modified"))]))
      (let ((calls 0))
        (cl-letf (((symbol-function 'omnigent-transport-request)
                   (lambda (_method path callback &optional _data)
                     (funcall callback
                              200
                              (cond
                               ((string-suffix-p "/filesystem" path)
                                '((base . "/workspace")))
                               ((string-suffix-p "/changes" path)
                                `((data . ,paths)))
                               (t
                                '((before . "old")
                                  (after . "new"))))))))
          (should
           (equal
            (should-error
             (funcall operation
                      "id"
                      (lambda (&rest _)
                        (cl-incf calls)
                        (error "Consumer failed"))))
            '(error "Consumer failed")))
          (should (= calls 1)))))))

(ert-deftest omnigent-workspace-list-rejects-malformed-root ()
  "Report malformed successful root responses through the result callback."
  (dolist (body '(nil "not JSON" [] ((base . 7))))
    (let (result)
      (cl-letf (((symbol-function 'omnigent-transport-request)
                 (lambda (_method _path callback &optional _data)
                   (funcall callback 200 body))))
        (omnigent-workspace-list
         "id" (lambda (status data) (setq result (list status data))))
        (should
         (equal
          result '(nil "Invalid environment root response")))))))

(ert-deftest omnigent-workspace-list-and-access ()
  "Check workspace listing and direct access restrictions."
  (let (result)
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (_method path callback &optional _data)
                 (funcall callback
                          200
                          (if (string-suffix-p "/filesystem" path)
                              '((base . "/workspace"))
                            '((data
                               .
                               [((path . "src/file")
                                 (status . "modified"))])))))))
      (omnigent-workspace-list
       "id" (lambda (status body) (setq result (cons status body))))
      (should (equal (alist-get 'root (cdr result)) "/workspace"))
      (should (equal (alist-get 'paths (cdr result)) '("src/file")))
      (should
       (equal
        (alist-get 'changes (cdr result))
        '(((path . "src/file") (status . "modified"))))))
    (should
     (equal
      (omnigent-workspace-local-filename
       "/workspace" "src/file" 'local)
      "/workspace/src/file"))
    (should-error
     (omnigent-workspace-local-filename "/workspace" "src/file"))
    (should-error
     (omnigent-workspace-local-filename
      "/workspace" "../secret" 'local))))

(ert-deftest omnigent-workspace-file-diff-results ()
  "Check single-file diffs, encoding, failures, and callback errors."
  (let (request
        result
        response)
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (_method path callback &optional _data)
                 (setq request path)
                 (funcall callback (car response) (cdr response)))))
      (setq response '(200 (before . "old\n") (after . "new\n")))
      (omnigent-workspace-file-diff
       "id/1"
       "a b/x#y"
       (lambda (status body) (setq result (cons status body))))
      (should (string-match-p "id%2F1.*a%20b/x%23y" request))
      (should
       (string-match-p (regexp-quote "-old\n+new") (cdr result)))
      (setq response '(503 (error . "unavailable")))
      (omnigent-workspace-file-diff
       "id" "file"
       (lambda (status body) (setq result (cons status body))))
      (should (equal result response))
      (setq response '(200 (before . 3) (after . "new")))
      (omnigent-workspace-file-diff
       "id" "file"
       (lambda (status body) (setq result (cons status body))))
      (should-not (car result))
      (setq response '(200 (before . nil) (after . "new")))
      (should-error
       (omnigent-workspace-file-diff
        "id" "file" (lambda (&rest _) (error "Consumer failed")))))))

(ert-deftest omnigent-workspace-list-rejects-missing-status ()
  "Reject a change list without the status needed by the workspace view."
  (let (result)
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (_method path callback &optional _data)
                 (funcall callback
                          200
                          (if (string-suffix-p "/filesystem" path)
                              '((base . "/workspace"))
                            '((data . [((path . "file"))])))))))
      (omnigent-workspace-list
       "id" (lambda (status body) (setq result (cons status body))))
      (should
       (equal
        result '(nil . "Invalid workspace changes response"))))))

(ert-deftest omnigent-workspace-list-retries-host-only-root ()
  "Retry transient host listings, bound retries, and stop after disconnect."
  (dolist (scenario '(ready unavailable disconnected))
    (let ((omnigent-transport--generation 0)
          (attempts 0)
          scheduled
          result)
      (cl-letf (((symbol-function 'omnigent-transport-request)
                 (lambda (_method path callback &optional _data)
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
        (omnigent-workspace-list
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
            (equal (alist-get 'root (cdr result)) "/workspace")))
          ('unavailable
           (should (= attempts 11))
           (should
            (equal
             result '(nil . "Invalid environment root response"))))
          ('disconnected
           (should (= attempts 1))
           (should-not result)))))))

(provide 'omnigent-workspace-test)
;;; omnigent-workspace-test.el ends here
