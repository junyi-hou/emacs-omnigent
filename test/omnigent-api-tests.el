;;; omnigent-api-tests.el --- Omnigent API integration tests -*- lexical-binding: t; -*-

(require 'test-utils)
(require 'omnigent-workspace)

(defun omnigent-api-workspace-result (operation id)
  "Call workspace OPERATION for ID and return its asynchronous response."
  (let (result)
    (funcall operation id (lambda (status body) (setq result (cons status body))))
    (with-timeout (30 (ert-fail "Workspace request timed out"))
      (while (not result) (accept-process-output nil 0.1)))
    result))

(defun omnigent-api-workspace-git (root &rest args)
  "Run Git ARGS in ROOT, retrying while the runner holds the index lock."
  (with-timeout (10 (ert-fail "Git index lock did not clear"))
    (let (done)
      (while (not done)
        (with-temp-buffer
          (let ((status (apply #'call-process "git" nil (list t t) nil "-C" root args)))
            (cond ((= status 0) (setq done t))
                  ((string-match-p "index.lock.*File exists" (buffer-string))
                   (sleep-for 0.05))
                  (t (ert-fail (buffer-string))))))))))

(ert-deftest omnigent-api-workspace-git-changes ()
  "Read clean, modified, added, deleted, and committed workspace changes."
  (let* ((root (file-truename (make-temp-file "omnigent-git-" t)))
         (default-directory (file-name-as-directory root))
         (process-environment (copy-sequence process-environment))
         id)
    (unwind-protect
        (progn
          (setenv "GIT_AUTHOR_NAME" "Omnigent Test")
          (setenv "GIT_AUTHOR_EMAIL" "test@example.invalid")
          (setenv "GIT_COMMITTER_NAME" "Omnigent Test")
          (setenv "GIT_COMMITTER_EMAIL" "test@example.invalid")
          (should (= 0 (call-process "git" nil nil nil "-C" root "init" "-q")))
          (make-directory "nested")
          (write-region "old line\n" nil (expand-file-name "nested/modified #1.txt" root) nil 'silent)
          (write-region "deleted line\n" nil (expand-file-name "deleted.txt" root) nil 'silent)
          (write-region "before staged\n" nil (expand-file-name "staged.txt" root) nil 'silent)
          (should (= 0 (call-process "git" nil nil nil "-C" root "add" ".")))
          (should (= 0 (call-process "git" nil nil nil "-C" root "commit" "-qm" "baseline")))
          (let* ((agents (cdr (omnigent-mock-test-request "GET" "/v1/agents?limit=1000")))
                 (agent (cl-find "mock-acp" (append (alist-get 'data agents) nil)
                                 :key (lambda (entry) (alist-get 'name entry)) :test #'equal))
                 (hosts (cdr (omnigent-mock-test-request "GET" "/v1/hosts")))
                 (host (cl-find "online" (append (alist-get 'hosts hosts) nil)
                                :key (lambda (entry) (alist-get 'status entry)) :test #'equal))
                 (created (omnigent-mock-test-request
                           "POST" "/v1/sessions"
                           `(("agent_id" . ,(alist-get 'id agent))
                             ("host_id" . ,(alist-get 'host_id host))
                             ("workspace" . ,root)))))
            (should agent)
            (should host)
            (should (= 201 (car created)))
            (setq id (alist-get 'id (cdr created))))
          (let ((clean (omnigent-api-workspace-result #'omnigent-workspace-diff id)))
            (should (= 200 (car clean)))
            (should (equal "" (cdr clean))))
          (write-region "new line\n" nil (expand-file-name "nested/modified #1.txt" root) nil 'silent)
          (delete-file (expand-file-name "deleted.txt" root))
          (write-region "added without newline" nil (expand-file-name "nested/new #2.txt" root) nil 'silent)
          (write-region "after staged\n" nil (expand-file-name "staged.txt" root) nil 'silent)
          (omnigent-api-workspace-git root "add" "staged.txt")
          (let* ((listing (omnigent-api-workspace-result #'omnigent-workspace-list id))
                 (paths (alist-get 'paths (cdr listing)))
                 (diff (omnigent-api-workspace-result #'omnigent-workspace-diff id))
                 (patch (cdr diff)))
            (should (= 200 (car listing)))
            (should (equal (file-truename (alist-get 'root (cdr listing))) root))
            (should (equal (sort (copy-sequence paths) #'string<)
                           '("deleted.txt" "nested/modified #1.txt" "nested/new #2.txt" "staged.txt")))
            (should (= 200 (car diff)))
            (dolist (text '("--- a/deleted.txt" "-deleted line"
                            "--- a/nested/modified #1.txt" "-old line" "+new line"
                            "--- a/nested/new #2.txt" "+added without newline"
                            "\\ No newline at end of file"
                            "--- a/staged.txt" "-before staged" "+after staged"))
              (should (string-match-p (regexp-quote text) patch))))
          (omnigent-api-workspace-git root "add" "-A")
          (omnigent-api-workspace-git root "commit" "-qm" "changes")
          (let ((clean (omnigent-api-workspace-result #'omnigent-workspace-diff id)))
            (should (= 200 (car clean)))
            (should (equal "" (cdr clean)))))
      (unwind-protect
          (when id (omnigent-mock-test-request "DELETE" (omnigent-transport--session-path id)))
        (delete-directory root t)))))

(ert-deftest omnigent-api-workspace-missing-session ()
  "Report a server error instead of an empty diff for a missing session."
  (let ((result (omnigent-api-workspace-result #'omnigent-workspace-diff
                                               "missing-workspace-session")))
    (should (integerp (car result)))
    (should (<= 400 (car result)))))

(ert-deftest omnigent-api-session-list ()
  "List a session created on the temporary server."
  (let* ((id (omnigent-integration-create-session))
         (response (omnigent-mock-test-request "GET" "/v1/sessions?limit=1000&include_archived=true&sort_by=updated_at&order=desc")))
    (should (= (car response) 200))
    (should (equal (alist-get 'object (cdr response)) "list"))
    (should (cl-find id (append (alist-get 'data (cdr response)) nil)
                     :key (lambda (row) (alist-get 'id row)) :test #'equal))))

(ert-deftest omnigent-api-session-get-and-delete ()
  "Get and delete a session."
  (let* ((id (omnigent-integration-create-session))
         (path (omnigent-transport--session-path id))
         (response (omnigent-mock-test-request "GET" path)))
    (should (= (car response) 200))
    (should (equal (alist-get 'id (cdr response)) id))
    (should (memq (car (omnigent-mock-test-request "DELETE" path)) '(200 204)))
    (should (= (car (omnigent-mock-test-request "GET" path)) 404))))

(ert-deftest omnigent-api-session-updates-watch ()
  "Watch a session and receive its snapshot."
  (let ((id (omnigent-integration-create-session)) frames failure updates)
    (unwind-protect
        (progn
          (setq updates (omnigent-transport-start-session-updates
                         (lambda (frame) (push frame frames))
                         (lambda (error) (setq failure error))))
          (omnigent-transport-set-session-updates-watch updates (list id))
          (with-timeout (15 (ert-fail (format "Timed out waiting for snapshot: %S" failure)))
            (while (not (cl-some
                         (lambda (frame)
                           (and (equal (alist-get 'type frame) "snapshot")
                                (cl-find id (append (alist-get 'items frame) nil)
                                         :key (lambda (row) (alist-get 'id row))
                                         :test #'equal))) frames))
              (accept-process-output nil 0.1)))
          (should-not failure))
      (when updates (omnigent-transport-stop-session-updates updates)))))

(ert-deftest omnigent-api-session-message-event ()
  "Post a message event and check the server response."
  (let* ((id (omnigent-integration-create-session t))
         (response
          (omnigent-mock-test-request
           "POST" (omnigent-transport--session-path id "/events")
           '(("type" . "message")
             ("data" . (("role" . "user")
                        ("content" . [(("type" . "input_text")
                                       ("text" . "test agent_message"))])))))))
    (should (= (car response) 202))
    (should (eq (alist-get 'queued (cdr response)) t))
    (with-timeout (30 (ert-fail "Timed out waiting for committed message"))
      (let (item)
        (while (not item)
          (let* ((snapshot (omnigent-mock-test-request
                            "GET" (omnigent-transport--session-path id)))
                 (items (append (alist-get 'items (cdr snapshot)) nil)))
            (should (= (car snapshot) 200))
            (setq item (cl-find-if
                        (lambda (entry)
                          (and (equal (alist-get 'type entry) "message")
                               (equal (alist-get 'role (alist-get 'data entry)) "user")))
                        items)))
          (unless item (sleep-for 0.2)))
        (with-temp-buffer
          (setq omnigent-conversation--items (make-hash-table :test 'equal))
          (omnigent-conversation--put-item item)
          (let ((parsed (gethash (alist-get 'id item) omnigent-conversation--items)))
            (should (equal (alist-get 'role parsed) "user"))
            (should (equal (omnigent-conversation--text parsed) "test agent_message"))))))))

(provide 'omnigent-api-tests)
;;; omnigent-api-tests.el ends here
