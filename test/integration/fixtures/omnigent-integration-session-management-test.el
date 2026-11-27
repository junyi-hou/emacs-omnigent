;;; omnigent-integration-session-management-test.el --- Manage sessions and projects -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(defun omnigent-integration--project-heading (name)
  "Return the position of the session list heading named NAME."
  (with-current-buffer "*omnigent-sessions*"
    (save-excursion
      (goto-char (point-min))
      (while (and (not (eobp))
                  (not
                   (and (get-text-property
                         (point) 'omnigent-ui-project)
                        (string-suffix-p
                         name
                         (buffer-substring-no-properties
                          (point) (line-end-position))))))
        (forward-line 1))
      (unless (eobp)
        (point)))))

(defun omnigent-integration--session-fields (id fields)
  "Wait for session ID to have FIELDS on the server and return it."
  (omnigent-integration--wait
   (lambda ()
     (let ((session
            (omnigent-integration--get-json
             (omnigent-transport--session-path id))))
       (and (seq-every-p
             (lambda (field)
               (equal (alist-get (car field) session) (cdr field)))
             fields)
            session)))))

(defun omnigent-integration--management-key (key)
  "Invoke the command bound to KEY in the current buffer."
  (let ((command (key-binding (kbd key))))
    (should (and (commandp command) (not (eq command 'undefined))))
    (call-interactively command)))

(defun omnigent-integration--management-get-status (path)
  "Return the HTTP status for a GET of PATH."
  (let (result)
    (omnigent-transport-request
     "GET" path
     (lambda (status _body) (setq result status)))
    (omnigent-integration--wait (lambda () result))))

(ert-deftest omnigent-integration-session-management ()
  "Create, organize, archive, restore, and delete sessions and projects."
  (omnigent-integration-with-run
   run
   (let ((omnigent-server-url
          (omnigent-integration-run-server-url run))
         (omnigent-auth-method 'none)
         (omnigent-open-session-list-on-connect t)
         (omnigent-fetch-archived-sessions nil)
         (omnigent-transport-session-limit 20)
         (omnigent--create-draft nil)
         (project "Inbox")
         (renamed-project "In progress")
         (title "Draft")
         (renamed-title "Review")
         (generated-title "Reviewed")
         (prompt "Session management title context")
         (reply "The review is ready."))
     (dolist
         (exchange
          (list
           (cons prompt reply)
           (cons
            "Write a short session title based on the recent conversation"
            generated-title)))
       (omnigent-integration--post-json
        (concat
         (omnigent-integration-run-mock-url run) "/mock/configure")
        `((match . ,(car exchange))
          (required_tools . ["exec_command"])
          (responses . [((text . ,(cdr exchange)) (stream . t))]))))
     (save-window-excursion
       (unwind-protect
           (progn
             (omnigent-connect omnigent-server-url)
             (with-current-buffer (omnigent-integration--wait
                                   (lambda ()
                                     (and (get-buffer-window
                                           "*omnigent-sessions*")
                                          (get-buffer
                                           "*omnigent-sessions*"))))
               (cl-letf (((symbol-function 'read-string)
                          (lambda (&rest _) project)))
                 (omnigent-integration--management-key "C"))
               (goto-char
                (omnigent-integration--wait
                 (lambda ()
                   (omnigent-integration--project-heading project))))
               (let* ((project-id
                       (get-text-property
                        (point) 'omnigent-ui-project))
                      (id
                       (omnigent-integration--mock-session run title))
                      (session
                       (omnigent-integration--session-fields
                        id `((project_id . ,project-id))))
                      (workspace (alist-get 'workspace session))
                      (path (omnigent-transport--session-path id)))
                 (omnigent-integration--wait
                  (lambda () (omnigent-integration--session-row id)))
                 (goto-char
                  (omnigent-integration--project-heading project))
                 (cl-letf (((symbol-function 'read-string)
                            (lambda (&rest _) renamed-project)))
                   (call-interactively #'omnigent-ui-rename-at-point))
                 (omnigent-integration--wait
                  (lambda ()
                    (omnigent-integration--project-heading
                     renamed-project)))
                 (let (selected)
                   (cl-letf (((symbol-function 'completing-read)
                              (lambda (_ choices &rest _)
                                (should
                                 (assoc renamed-project choices))
                                (setq selected renamed-project))))
                     (omnigent-integration--management-key "/")
                     (omnigent-integration--wait
                      (lambda ()
                        (and selected
                             (equal
                              (point)
                              (omnigent-integration--project-heading
                               renamed-project)))))))
                 (omnigent-integration--management-key "TAB")
                 (should-not (omnigent-integration--session-row id))
                 (omnigent-integration--management-key "TAB")
                 (should (omnigent-integration--session-row id))
                 (let ((current-prefix-arg 1000))
                   (omnigent-integration--management-key "-"))
                 (omnigent-integration--wait
                  (lambda ()
                    (not (omnigent-integration--session-row id))))
                 (omnigent-integration--management-key "+")
                 (ert-info
                  ((format "Selecting session %s in %s"
                           id
                           (buffer-name)))
                  (goto-char
                   (omnigent-integration--wait
                    (lambda
                      ()
                      (omnigent-integration--session-row id)))))
                 (let ((current-prefix-arg 20))
                   (omnigent-integration--management-key "+"))
                 (cl-letf (((symbol-function 'read-string)
                            (lambda (&rest _) renamed-title)))
                   (call-interactively #'omnigent-ui-rename-at-point))
                 (omnigent-integration--session-fields
                  id `((title . ,renamed-title)))
                 (omnigent-integration--management-key "g")
                 (omnigent-integration--wait
                  (lambda ()
                    (and
                     (equal
                      (point) (omnigent-integration--session-row id))
                     (looking-at-p
                      (concat " *" (regexp-quote renamed-title))))))
                 (cl-letf (((symbol-function 'completing-read)
                            (lambda (_ choices &rest _)
                              (should (assoc "[Unassigned]" choices))
                              "[Unassigned]")))
                   (omnigent-integration--management-key "m")
                   (omnigent-integration--session-fields
                    id
                    `((project_id . :null) (workspace . ,workspace))))
                 (omnigent-integration--management-key "u")
                 (omnigent-integration--session-fields
                  id `((project_id . ,project-id)))
                 (omnigent-integration--management-key "C-r")
                 (omnigent-integration--session-fields
                  id '((project_id . :null)))
                 (ert-info
                  ((format "Selecting session %s in %s"
                           id
                           (buffer-name)))
                  (goto-char
                   (omnigent-integration--wait
                    (lambda
                      ()
                      (omnigent-integration--session-row id)))))
                 (cl-letf (((symbol-function 'completing-read)
                            (lambda (_ choices &rest _)
                              (should (assoc renamed-project choices))
                              renamed-project)))
                   (omnigent-integration--management-key "m")
                   (omnigent-integration--session-fields
                    id `((project_id . ,project-id))))
                 (ert-info
                  ((format "Selecting session %s in %s"
                           id
                           (buffer-name)))
                  (goto-char
                   (omnigent-integration--wait
                    (lambda
                      ()
                      (omnigent-integration--session-row id)))))
                 (omnigent-integration--management-key "a")
                 (omnigent-integration--session-fields
                  id '((archived . t)))
                 (omnigent-integration--wait
                  (lambda ()
                    (not (omnigent-integration--session-row id))))
                 (omnigent-integration--management-key "A")
                 (omnigent-integration--wait
                  (lambda ()
                    (memq
                     'omnigent-ui-session-archived
                     (ensure-list
                      (omnigent-integration--session-row-face id)))))
                 (omnigent-integration--management-key "u")
                 (omnigent-integration--session-fields
                  id '((archived . :false)))
                 (omnigent-integration--management-key "C-r")
                 (omnigent-integration--session-fields
                  id '((archived . t)))
                 (goto-char (omnigent-integration--session-row id))
                 (omnigent-integration--management-key "a")
                 (omnigent-integration--session-fields
                  id '((archived . :false)))
                 (let ((conversation
                        (omnigent-integration--open-session-row id)))
                   (with-current-buffer conversation
                     (goto-char (point-max))
                     (insert prompt)
                     (omnigent-integration--management-key "C-c C-c")
                     (omnigent-integration--wait
                      (lambda ()
                        (omnigent-integration--message-position
                         reply)))
                     (omnigent-integration--management-key "C-c C-t"))
                   (omnigent-integration--session-fields
                    id `((title . ,generated-title)))
                   (with-current-buffer conversation
                     (omnigent-integration--management-key "C-c C-a"))
                   (omnigent-integration--session-fields
                    id '((archived . t)))
                   (omnigent-integration--wait
                    (lambda () (not (buffer-live-p conversation)))))
                 (select-window
                  (get-buffer-window "*omnigent-sessions*"))
                 (omnigent-integration--management-key "g")
                 (ert-info
                  ((format "Selecting session %s in %s"
                           id
                           (buffer-name)))
                  (goto-char
                   (omnigent-integration--wait
                    (lambda
                      ()
                      (omnigent-integration--session-row id)))))
                 (omnigent-integration--management-key "a")
                 (omnigent-integration--session-fields
                  id '((archived . :false)))
                 (goto-char
                  (omnigent-integration--project-heading
                   renamed-project))
                 (cl-letf (((symbol-function 'y-or-n-p)
                            (lambda (&rest _) t)))
                   (omnigent-integration--management-key "d"))
                 (omnigent-integration--wait
                  (lambda ()
                    (not
                     (omnigent-integration--project-heading
                      renamed-project))))
                 (omnigent-integration--session-fields
                  id '((archived . t) (project_id . :null)))
                 (ert-info
                  ((format "Selecting session %s in %s"
                           id
                           (buffer-name)))
                  (goto-char
                   (omnigent-integration--wait
                    (lambda
                      ()
                      (omnigent-integration--session-row id)))))
                 (cl-letf (((symbol-function 'y-or-n-p)
                            (lambda (&rest _) t)))
                   (omnigent-integration--management-key "d"))
                 (omnigent-integration--wait
                  (lambda ()
                    (not (omnigent-integration--session-row id))))
                 (should
                  (= 404
                     (omnigent-integration--management-get-status
                      path)))
                 (should
                  (= 404
                     (omnigent-integration--management-get-status
                      (concat "/v1/projects/" project-id))))
                 ;; Create from a file and delete from its conversation.
                 (let* ((file
                         (expand-file-name "management.txt"
                                           workspace))
                        (omnigent-session-default-host
                         (alist-get 'host_id session))
                        (omnigent-session-default-agent
                         (alist-get 'agent_id session))
                        (omnigent-session-default-model "mock-model")
                        (omnigent-session-default-title
                         "Session from file")
                        created)
                   (with-temp-file file
                     (insert "Session workspace\n"))
                   (with-temp-buffer
                     (setq
                      buffer-file-name file
                      default-directory (file-name-directory file))
                     (let ((omnigent-sessions-open-hook
                            (list
                             (lambda
                               (row)
                               (setq created (alist-get 'id row))))))
                       (call-interactively
                        #'omnigent-sessions-create-from-file)
                       (omnigent-integration--wait
                        (lambda () created))))
                   (omnigent-integration--session-fields
                    created
                    `((workspace . ,workspace) (project_id . :null)))
                   (with-current-buffer
                       (omnigent-integration--open-session-row
                        created)
                     (cl-letf (((symbol-function 'y-or-n-p)
                                (lambda (&rest _) t)))
                       (omnigent-integration--management-key
                        "C-c C-d")))
                   (omnigent-integration--wait
                    (lambda ()
                      (not
                       (omnigent-integration--session-row created))))
                   (should
                    (= 404
                       (omnigent-integration--management-get-status
                        (omnigent-transport--session-path
                         created))))))))
         (omnigent-disconnect))))))

;;; omnigent-integration-session-management-test.el ends here
