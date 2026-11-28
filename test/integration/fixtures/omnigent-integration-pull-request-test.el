;;; omnigent-integration-pull-request-test.el --- Link and unlink session pull requests -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(defun omnigent-integration--pr-url (number)
  "Return the fixture URL for pull request NUMBER."
  (format "https://github.com/example/repo/pull/%s" number))

(defun omnigent-integration--stub-gh (run)
  "Serve pull request 42 from a local gh executable for RUN's host."
  (let* ((root (omnigent-integration-run-root run))
         (cli (expand-file-name "gh" root))
         (process-environment
          (omnigent-integration-run-environment run)))
    (with-temp-file cli
      (insert
       "#!/bin/sh\n"
       "case \"$1 $2 $3 $4 $5\" in\n"
       "  'pr view 42 -R github.com/example/repo')\n"
       "    echo '{\"number\":42,\"url\":\"https://github.com/example/repo/pull/42\",\"title\":\"Fixture PR\",\"state\":\"OPEN\"}';;\n"
       "  'pr diff 42 -R github.com/example/repo')\n"
       "    printf '%s\\n' 'diff --git a/demo.txt b/demo.txt' '--- a/demo.txt' \\\n"
       "      '+++ b/demo.txt' '@@ -1 +1 @@' '-before' '+after';;\n"
       "  *) exit 1;;\n"
       "esac\n"))
    (set-file-modes cli #o700)
    (setenv "PATH" (concat root path-separator (getenv "PATH")))
    (setf (omnigent-integration-run-environment run)
          process-environment)))

(defun omnigent-integration--report-pull-requests (id &rest numbers)
  "Report inferred pull request NUMBERS on session ID."
  (let ((now (float-time)))
    (omnigent-integration--post-json
     (concat
      omnigent-server-url
      (omnigent-transport--session-path id "/events"))
     `((type . "external_pull_requests")
       (data
        (prs
         .
         ,(vconcat
           (mapcar
            (lambda (number)
              `((url . ,(omnigent-integration--pr-url number))
                (host . "github.com")
                (repository . "example/repo")
                (number . ,number)
                (relationship . "inferred")
                (first_seen_at . ,now)
                (last_seen_at . ,now)))
            numbers))))))))

(defun omnigent-integration--pull-request-numbers (id)
  "Return the linked pull request numbers for session ID."
  (mapcar
   (lambda (pr) (alist-get 'number pr))
   (alist-get
    'data
    (omnigent-integration--get-json
     (omnigent-transport--session-path id "/pull-requests")))))

(defun omnigent-integration--pull-request-row (id number)
  "Return the sidebar position of pull request NUMBER on session ID."
  (let ((resource (cons id (omnigent-integration--pr-url number))))
    (save-excursion
      (goto-char (point-min))
      (when-let* ((match
                   (text-property-search-forward
                    'omnigent-session-resource resource t)))
        (prop-match-beginning match)))))

(ert-deftest omnigent-integration-pull-request-linking ()
  "Show, open, and unlink PRs and keep links separate across sessions."
  (omnigent-integration-with-run
   run
   (let ((omnigent-server-url
          (omnigent-integration-run-server-url run))
         (omnigent-auth-method 'none)
         (omnigent-open-session-list-on-connect t)
         (omnigent-session-default-host-type "external")
         (omnigent-session-default-host nil)
         (omnigent-session-default-workspace nil)
         (omnigent-session-default-worktree-branch nil)
         (omnigent--create-draft nil)
         created)
     (save-window-excursion
       (unwind-protect
           (progn
             (omnigent-integration--stub-gh run)
             (omnigent-connect omnigent-server-url)
             (let* ((source
                     (omnigent-integration--mock-session
                      run "Source PR"))
                    (session
                     (omnigent-integration--get-json
                      (omnigent-transport--session-path source)))
                    (omnigent-session-default-agent
                     (alist-get 'agent_id session))
                    (omnigent-session-default-model "mock-model")
                    (omnigent-session-default-title "Same workspace")
                    (omnigent-sessions-open-hook
                     (list
                      (lambda (row)
                        (setq created (alist-get 'id row))))))
               (omnigent-integration--report-pull-requests source 42)
               (should
                (equal
                 (omnigent-integration--pull-request-numbers source)
                 '(42)))
               (with-current-buffer "*omnigent-sessions*"
                 (goto-char
                  (omnigent-integration--wait
                   (lambda ()
                     (omnigent-integration--pull-request-row
                      source 42))
                   65))
                 (let (opened-url)
                   (cl-letf (((symbol-function 'browse-url)
                              (lambda (url &rest _)
                                (setq opened-url url))))
                     (omnigent-session-open-at-point))
                   (should
                    (equal
                     opened-url (omnigent-integration--pr-url 42))))
                 (goto-char
                  (omnigent-integration--session-row source))
                 (omnigent-sessions-create))
               (omnigent-integration--wait (lambda () created))
               (should
                (equal
                 (alist-get 'workspace session)
                 (alist-get
                  'workspace
                  (omnigent-integration--get-json
                   (omnigent-transport--session-path created)))))
               (omnigent-integration--report-pull-requests created
                                                           42
                                                           43)
               (omnigent-integration--wait
                (lambda ()
                  (equal
                   (omnigent-integration--pull-request-numbers
                    created)
                   '(43))))
               (omnigent-integration--report-pull-requests created 42)
               (should
                (equal
                 (omnigent-integration--pull-request-numbers created)
                 '(43)))
               (with-current-buffer "*omnigent-sessions*"
                 (omnigent-integration--wait
                  (lambda ()
                    (omnigent-session--refresh-resources t)
                    (omnigent-integration--pull-request-row
                     created 43)))
                 (should-not
                  (omnigent-integration--pull-request-row created 42))
                 (let (status)
                   (omnigent-transport-request
                    "DELETE"
                    (omnigent-transport--session-path
                     created
                     (concat
                      "/pull-requests?url="
                      (url-hexify-string
                       (omnigent-integration--pr-url 43))))
                    (lambda (code _body) (setq status code)))
                   (should
                    (omnigent-transport-success-p
                     (omnigent-integration--wait
                      (lambda () status)))))
                 (omnigent-integration--wait
                  (lambda ()
                    (omnigent-session--refresh-resources t)
                    (not
                     (omnigent-integration--pull-request-row
                      created 43))))
                 (should
                  (omnigent-integration--pull-request-row source 42)))
               (omnigent-integration--report-pull-requests created 43)
               (should-not
                (omnigent-integration--pull-request-numbers created))
               (omnigent-integration--post-json
                (concat
                 omnigent-server-url
                 (omnigent-transport--session-path
                  created "/resources/github/prs"))
                `((action . "attach")
                  (url . ,(omnigent-integration--pr-url 42))))
               (should
                (equal
                 (omnigent-integration--pull-request-numbers created)
                 '(42)))
               (with-current-buffer "*omnigent-sessions*"
                 (goto-char
                  (omnigent-integration--wait
                   (lambda ()
                     (omnigent-session--refresh-resources t)
                     (omnigent-integration--pull-request-row
                      created 42))))
                 (omnigent-session-pull-request-diff))
               (let ((diff
                      (omnigent-integration--wait
                       (lambda ()
                         (get-buffer
                          (format
                           "*omnigent-diff: %s:%s*"
                           created
                           (omnigent-integration--pr-url 42)))))))
                 (unwind-protect
                     (with-current-buffer diff
                       (should (search-forward "+after" nil t)))
                   (kill-buffer diff)))
               (should
                (equal
                 (omnigent-integration--pull-request-numbers source)
                 '(42)))))
         (omnigent-disconnect))))))

;;; omnigent-integration-pull-request-test.el ends here
