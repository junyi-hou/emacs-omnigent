;;; omnigent-integration-conversation-directory-test.el --- Check workspace access from a conversation -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(ert-deftest omnigent-integration-conversation-directory ()
  "Read an updated workspace file relative to the conversation directory."
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
          (file (expand-file-name path workspace))
          (updated "Updated workspace contents\n"))
     (make-directory (file-name-directory file) t)
     (with-temp-file file
       (insert "Original workspace contents\n"))
     (save-window-excursion
       (unwind-protect
           (progn
             (omnigent-connect omnigent-server-url)
             (let ((id
                    (omnigent-integration--mock-session
                     run "Conversation directory" nil workspace)))
               (with-current-buffer
                   (omnigent-integration--open-session-row id)
                 (should (file-equal-p default-directory workspace))
                 (should (file-equal-p path file))
                 (with-temp-file file
                   (insert updated))
                 (with-temp-buffer
                   (insert-file-contents path)
                   (should (equal (buffer-string) updated))))))
         (omnigent-disconnect))))))

;;; omnigent-integration-conversation-directory-test.el ends here
