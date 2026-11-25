;;; omnigent-integration-workspace-file-test.el --- Display a changed file -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(ert-deftest omnigent-integration-workspace-file-display ()
  "List, diff, and visit a new file in the session workspace."
  (omnigent-integration-with-run
   run
   (let* ((omnigent-server-url
           (omnigent-integration-run-server-url run))
          (omnigent-auth-method 'none)
          (omnigent-open-session-list-on-connect t)
          (workspace
           (expand-file-name "workspace"
                             (omnigent-integration-run-root run)))
          (path "notes/workspace note.txt")
          (row (concat "^A " (regexp-quote path) "$"))
          (file (expand-file-name path workspace))
          (contents "Workspace fixture contents\n"))
     (make-directory (file-name-directory file) t)
     (let ((default-directory workspace)
           (process-environment
            (omnigent-integration-run-environment run)))
       (should
        (equal 0 (call-process "git" nil nil nil "init" "-q"))))
     (with-temp-file file
       (insert contents))
     (save-window-excursion
       (unwind-protect
           (progn
             (omnigent-connect omnigent-server-url)
             (omnigent-integration--open-session-row
              (omnigent-integration--mock-session
               run "Workspace file display" nil workspace))
             (let ((panel
                    (omnigent-integration--wait
                     (lambda ()
                       (seq-find
                        (lambda (window)
                          (with-current-buffer (window-buffer window)
                            (and (derived-mode-p
                                  'omnigent-ui-workspace-mode)
                                 (save-excursion
                                   (goto-char (point-min))
                                   (re-search-forward row nil t)))))
                        (window-list))))))
               (with-selected-window panel
                 (goto-char (point-min))
                 (re-search-forward row)
                 (beginning-of-line)
                 (call-interactively (key-binding (kbd "RET"))))
               (omnigent-integration--wait
                (lambda ()
                  (with-current-buffer (window-buffer
                                        (selected-window))
                    (and (derived-mode-p 'diff-mode)
                         (string-search
                          (concat "+" contents) (buffer-string))))))
               (with-selected-window panel
                 (goto-char (point-min))
                 (re-search-forward row)
                 (beginning-of-line)
                 (call-interactively (key-binding (kbd "f")))
                 (should (file-equal-p buffer-file-name file))
                 (should (equal (buffer-string) contents)))))
         (when-let* ((buffer (get-file-buffer file)))
           (kill-buffer buffer))
         (omnigent-disconnect))))))

;;; omnigent-integration-workspace-file-test.el ends here
