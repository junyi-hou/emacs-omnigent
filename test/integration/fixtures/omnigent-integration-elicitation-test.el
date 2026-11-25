;;; omnigent-integration-elicitation-test.el --- Answer live requests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)
(require 'wid-edit)

(defun omnigent-integration--answer-request
    (session-id request-id title action &optional answer)
  "Answer REQUEST-ID for SESSION-ID from its displayed widgets.
TITLE is the prompt text.  Send ACTION and, for a question, ANSWER."
  (let*
      ((path (format "/v1/sessions/%s" session-id))
       (request-path (concat path "/elicitations/" request-id))
       (params
        (append
         `((mode . "form") (message . ,title))
         (if answer
             '((requestedSchema
                .
                ((type . "object")
                 (required . ["branch"])
                 (properties
                  .
                  ((branch
                    .
                    ((type . "string")
                     (title . "Release branch"))))))))
           '((policy_name . "integration_approval")))))
       (draft-offset (- (point-max) (point)))
       result
       ;; This hook holds the request open and returns the actual verdict.
       (response
        (let ((url-request-method "POST")
              (url-request-extra-headers
               '(("Content-Type" . "application/json")))
              (url-request-data
               (json-encode
                `((elicitation_id . ,request-id)
                  (params . ,params)))))
          (url-retrieve
           (concat
            omnigent-server-url
            path
            "/hooks/antigravity-elicitation-request")
           (lambda (status)
             (unwind-protect
                 (setq result
                       (if (or (plist-get status :error)
                               (not
                                (eq url-http-response-status 200)))
                           (list status url-http-response-status)
                         (goto-char url-http-end-of-headers)
                         (json-parse-buffer :object-type 'alist)))
               (kill-buffer (current-buffer))))
           nil t t))))
    (unwind-protect
        (progn
          (omnigent-integration--wait
           (lambda ()
             (omnigent-integration--message-position
              (concat
               (if answer
                   "# Question"
                 "# Approval required")
               "\n\n> " title))))
          (should (= (- (point-max) (point)) draft-offset))
          (should
           (string-suffix-p "> Unsent release draft" (buffer-string)))
          (should
           (equal
            "pending"
            (alist-get
             'status (omnigent-integration--get-json request-path))))
          (when answer
            (let ((field
                   (seq-find
                    (lambda (widget)
                      (equal
                       (widget-get widget :field-name) "branch"))
                    omnigent-ui--widgets)))
              (should field)
              (should
               (omnigent-integration--message-position
                "Release branch"))
              (save-excursion
                (goto-char (widget-field-start field))
                (insert answer))))
          (let ((button
                 (seq-find
                  (lambda (widget)
                    (eq (widget-get widget :response-action) action))
                  omnigent-ui--widgets)))
            (should button)
            (should
             (equal
              (widget-value button)
              (cond
               (answer
                "Submit")
               ((eq action 'accept)
                "Approve")
               (t
                "Decline"))))
            (widget-apply button :action))
          (omnigent-integration--wait (lambda () result))
          (should
           (equal (alist-get 'action result) (symbol-name action)))
          (when answer
            (should
             (equal
              (alist-get 'content result) `((branch . ,answer)))))
          (omnigent-integration--wait
           (lambda ()
             (not (omnigent-integration--message-position title))))
          (should
           (equal
            "resolved"
            (alist-get
             'status (omnigent-integration--get-json request-path))))
          (should (= (- (point-max) (point)) draft-offset))
          (should
           (string-suffix-p
            "> Unsent release draft" (buffer-string))))
      (when (buffer-live-p response)
        (kill-buffer response)))))

(ert-deftest omnigent-integration-elicitation ()
  "Approve, decline, and answer a question through the live conversation UI."
  (omnigent-integration-with-run
   run
   (let ((omnigent-server-url
          (omnigent-integration-run-server-url run))
         (omnigent-auth-method 'none)
         (omnigent-open-session-list-on-connect t))
     (save-window-excursion
       (unwind-protect
           (progn
             (omnigent-connect omnigent-server-url)
             (let ((id
                    (omnigent-integration--mock-session
                     run "Elicitation journey")))
               (with-current-buffer
                   (omnigent-integration--open-session-row id)
                 (goto-char (point-max))
                 (insert "Unsent release draft")
                 (backward-char 5)
                 (ert-info
                  ("Accept a yes/no request")
                  (omnigent-integration--answer-request
                   id
                   "elicit_integration_accept"
                   "Prepare the release?"
                   'accept))
                 (ert-info
                  ("Decline a yes/no request")
                  (omnigent-integration--answer-request
                   id
                   "elicit_integration_decline"
                   "Publish the draft?"
                   'decline))
                 (ert-info
                  ("Submit a typed answer")
                  (omnigent-integration--answer-request
                   id
                   "elicit_integration_question"
                   "Which branch should I use?"
                   'accept
                   "release/2.4")))))
         (omnigent-disconnect))))))

;;; omnigent-integration-elicitation-test.el ends here
