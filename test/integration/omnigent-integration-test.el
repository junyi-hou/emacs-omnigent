;;; omnigent-integration-test.el --- Live smoke tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Smoke tests for the real Omnigent server and the official local mock.

;;; Code:

(require 'ert)
(require 'omnigent-smoke)

(ert-deftest omnigent-integration-starts-and-stops-services ()
  "Start both services, check the mock model, and remove the run resources."
  (let (root
        processes)
    (omnigent-smoke-with-run
     run
     (setq
      root (omnigent-smoke-run-root run)
      processes (omnigent-smoke-run-processes run))
     (let ((response
            (url-retrieve-synchronously
             (concat (omnigent-smoke-run-mock-url run) "/v1/models")
             t
             t
             5)))
       (should response)
       (unwind-protect
           (with-current-buffer response
             (should (= url-http-response-status 200))
             (goto-char url-http-end-of-headers)
             (let* ((body
                     (json-parse-buffer
                      :object-type 'alist
                      :array-type 'list))
                    (models (alist-get 'data body)))
               (should
                (equal
                 (mapcar
                  (lambda (model) (alist-get 'id model)) models)
                 (list omnigent-smoke--model)))))
         (kill-buffer response))))
    (should-not (file-exists-p root))
    (dolist (process processes)
      (should-not (process-live-p process)))))

;;; omnigent-integration-test.el ends here
