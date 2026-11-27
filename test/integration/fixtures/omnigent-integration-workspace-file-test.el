;;; omnigent-integration-workspace-file-test.el --- Display a changed file -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(ert-deftest omnigent-integration-workspace-file-display ()
  "Open the workspace on demand and visit or diff a new file."
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
          (row (concat "^  A  " (regexp-quote path) "$"))
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
             (let ((id
                    (omnigent-integration--mock-session
                     run "Workspace file display" nil workspace)))
               (omnigent-ui-open id "Workspace file display")
               (let ((buffer-name
                      (format "*omnigent-workspace: %s*" id)))
                 (omnigent-integration--wait
                  (lambda ()
                    (when-let* ((sidebar
                                 (get-buffer "*omnigent-sessions*")))
                      (with-current-buffer sidebar
                        (save-excursion
                          (goto-char (point-min))
                          (search-forward "[workspace]" nil t))))))
                 (should-not (get-buffer buffer-name))
                 (call-interactively (key-binding (kbd "M-RET")))
                 (let ((buffer (current-buffer)))
                   (should
                    (derived-mode-p 'omnigent-ui-workspace-mode))
                   (should (equal (buffer-name buffer) buffer-name))
                   (goto-char (point-min))
                   (re-search-forward row)
                   (beginning-of-line)
                   (call-interactively (key-binding (kbd "d")))
                   (omnigent-integration--wait
                    (lambda ()
                      (with-current-buffer (window-buffer
                                            (selected-window))
                        (and (derived-mode-p 'diff-mode)
                             (string-search
                              (concat "+" contents)
                              (buffer-string))))))
                   (pop-to-buffer buffer)
                   (call-interactively (key-binding (kbd "RET")))
                   (should (file-equal-p buffer-file-name file))
                   (should (equal (buffer-string) contents))))))
         (when-let* ((buffer (get-file-buffer file)))
           (kill-buffer buffer))
         (omnigent-disconnect))))))

;;; omnigent-integration-workspace-file-test.el ends here
