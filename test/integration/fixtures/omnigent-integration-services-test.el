;;; omnigent-integration-services-test.el --- Check the integration test services -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent-integration-fixture)

(ert-deftest omnigent-integration-starts-and-stops-services ()
  "Start both services, check the mock model, and remove the run resources."
  (let (root
        processes)
    (omnigent-integration-with-run
     run
     (setq
      root (omnigent-integration-run-root run)
      processes (omnigent-integration-run-processes run))
     (let ((response
            (url-retrieve-synchronously
             (concat
              (omnigent-integration-run-mock-url run) "/v1/models")
             t t 5)))
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
                 (list omnigent-integration--model)))))
         (kill-buffer response))))
    (should-not (file-exists-p root))
    (dolist (process processes)
      (should-not (process-live-p process)))))

;;; omnigent-integration-services-test.el ends here
