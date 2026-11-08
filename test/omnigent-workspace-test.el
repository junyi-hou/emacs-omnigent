;;; omnigent-workspace-test.el --- Workspace data tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'omnigent-workspace)

(ert-deftest omnigent-workspace-diff-and-failures ()
  "Check diff generation, URL encoding, and request failures."
  (let (requests result failure)
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (_method path callback &optional _data)
                 (push path requests)
                 (cond
                  ((string-suffix-p "/changes" path)
                   (funcall callback 200 '((data . [((path . "a b/x#y")) ((path . "new"))]))))
                  ((string-suffix-p "/new" path)
                   (funcall callback 200 '((before . nil) (after . "new\n"))))
                  (failure (funcall callback 503 '((error . "unavailable"))))
                  (t (funcall callback 200 '((before . "old\n") (after . "changed\n"))))))))
      (omnigent-workspace-diff "id/1" (lambda (status body) (setq result (cons status body))))
      (should (= (car result) 200))
      (should (string-match-p (regexp-quote "-old\n+changed") (cdr result)))
      (should (string-match-p (regexp-quote "+new") (cdr result)))
      (should (cl-some (lambda (path) (string-match-p "id%2F1.*a%20b/x%23y" path)) requests))
      (setq failure t result nil)
      (omnigent-workspace-diff "id" (lambda (status body) (setq result (cons status body))))
      (should (= (car result) 503)))))

(ert-deftest omnigent-workspace-consumer-errors-are-not-request-failures ()
  "Propagate consumer errors without delivering a second operation result."
  (dolist (operation '(omnigent-workspace-diff omnigent-workspace-list))
    (dolist (paths '([] [((path . "file"))]))
      (let ((calls 0))
        (cl-letf (((symbol-function 'omnigent-transport-request)
                   (lambda (_method path callback &optional _data)
                     (funcall callback 200
                              (cond
                               ((string-suffix-p "/filesystem" path) '((base . "/workspace")))
                               ((string-suffix-p "/changes" path) `((data . ,paths)))
                               (t '((before . "old") (after . "new"))))))))
          (should (equal (should-error
                          (funcall operation "id"
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
        (omnigent-workspace-list "id" (lambda (status data) (setq result (list status data))))
        (should (equal result '(nil "Invalid environment root response")))))))

(ert-deftest omnigent-workspace-list-and-access ()
  "Check workspace listing and direct access restrictions."
  (let (result)
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (_method path callback &optional _data)
                 (funcall callback 200
                          (if (string-suffix-p "/filesystem" path)
                              '((base . "/workspace"))
                            '((data . [((path . "src/file"))])))))))
      (omnigent-workspace-list "id" (lambda (status body) (setq result (cons status body))))
      (should (equal (alist-get 'root (cdr result)) "/workspace"))
      (should (equal (alist-get 'paths (cdr result)) '("src/file"))))
    (should (equal (omnigent-workspace-local-filename "/workspace" "src/file" 'local)
                   "/workspace/src/file"))
    (should-error (omnigent-workspace-local-filename "/workspace" "src/file"))
    (should-error (omnigent-workspace-local-filename "/workspace" "../secret" 'local))))

(provide 'omnigent-workspace-test)
;;; omnigent-workspace-test.el ends here
