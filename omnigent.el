;;; omnigent.el --- Omnigent for Emacs -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1") (websocket "1.16") (markdown-mode "2.6") (transient "0.4.0"))

;;; Commentary:
;; Start or connect to an Omnigent server.

;;; Code:

(require 'subr-x)
(require 'cl-lib)
(require 'project)
(require 'transient)
(require 'omnigent-options)
(require 'omnigent-transport)
(require 'omnigent-sessions)
(require 'omnigent-workspace)
(require 'omnigent-ui)

(add-hook 'omnigent-sessions-open-hook #'omnigent-ui-created)

;;;###autoload
(defun omnigent-conversation-open-block ()
  "Open the fold for the transcript block at point."
  (interactive)
  (omnigent-ui-fold-at-point t))

;;;###autoload
(defun omnigent-conversation-close-block ()
  "Close the fold for the transcript block at point."
  (interactive)
  (omnigent-ui-fold-at-point nil))

(defun omnigent--conversation-title (title)
  "Rename the current conversation buffer to TITLE."
  (when (and omnigent-conversation-session-id
             (or (null title) (stringp title)))
    (rename-buffer (format "*omnigent: %s [%s]*"
                           (if (or (null title)
                                   (string-empty-p title))
                               "Untitled"
                             title)
                           (substring
                            omnigent-conversation-session-id
                            0
                            (min 9
                                 (length
                                  omnigent-conversation-session-id))))
                   t)))

(defun omnigent--conversation-title-event (name data)
  "Apply title from conversation SSE event NAME and DATA."
  (when (equal name "session.title")
    (omnigent--conversation-title (alist-get 'title data))))

(defun omnigent--conversation-superseded-event (name data)
  "Open the new conversation from SSE event NAME and DATA."
  (when (and (equal name "session.superseded")
             (equal
              (alist-get 'conversation_id data)
              omnigent-conversation-session-id)
             (stringp (alist-get 'target_conversation_id data)))
    (let ((window (get-buffer-window (current-buffer) t)))
      (when (window-live-p window)
        (with-selected-window window
          (let ((display-buffer-overriding-action
                 '(display-buffer-same-window)))
            (omnigent-conversation-open
             (alist-get 'target_conversation_id data))))))))

(defun omnigent--conversation-title-watch ()
  "Watch title events in the current conversation buffer."
  (add-hook 'omnigent-conversation-event-hook
            #'omnigent--conversation-title-event
            nil
            t))

(defun omnigent--conversation-superseded-watch ()
  "Watch session supersession in the current conversation buffer."
  (add-hook 'omnigent-conversation-event-hook
            #'omnigent--conversation-superseded-event
            nil
            t))

(defun omnigent--sessions-title-frame (frame)
  "Apply session titles from update FRAME to open conversation buffers."
  (when (member (alist-get 'type frame) '("snapshot" "changed"))
    (dolist (session (append (alist-get 'items frame) nil))
      (when-let* ((buffer
                   (omnigent-sessions-buffer
                    (alist-get 'id session))))
        (with-current-buffer buffer
          (omnigent--conversation-title
           (alist-get 'title session)))))))

(add-hook
 'omnigent-conversation-mode-hook
 #'omnigent--conversation-title-watch)
(add-hook
 'omnigent-conversation-mode-hook
 #'omnigent--conversation-superseded-watch)
(add-hook
 'omnigent-sessions-frame-hook #'omnigent--sessions-title-frame)

(defvar omnigent-start-process nil
  "CLI process that is starting the local Omnigent server.")

;;;###autoload
(defun omnigent-connect (url)
  "Select the Omnigent server at URL.
URL must start with http:// or https://.  Close conversation buffers and
reset session and transport state before selecting the server."
  (interactive (list
                (read-string "Omnigent server URL: "
                             omnigent-server-url)))
  (unless (string-match-p "\\`https?://" url)
    (user-error "Server URL must start with http:// or https://"))
  (mapc
   (lambda (entry)
     (when (buffer-live-p (cdr entry))
       (kill-buffer (cdr entry))))
   (copy-sequence omnigent-sessions--buffers))
  (omnigent-sessions-reset)
  (omnigent-transport-reset)
  (omnigent-ui-reset)
  (setq omnigent-server-url (string-remove-suffix "/" url))
  (omnigent-ui-start)
  (message "Using Omnigent server %s" omnigent-server-url))

;;;###autoload
(defun omnigent-disconnect ()
  "Disconnect and close Omnigent side windows and server-specific buffers.
Unsent drafts are lost, but agents continue to run on their execution hosts."
  (interactive)
  (mapc
   (lambda (entry)
     (when (buffer-live-p (cdr entry))
       (kill-buffer (cdr entry))))
   (copy-sequence omnigent-sessions--buffers))
  (omnigent-sessions-reset)
  (omnigent-transport-reset)
  (let ((omnigent-ui--changing-windows t))
    (dolist (frame (frame-list))
      (dolist (window (window-list frame))
        (when (and (window-parameter window 'window-side)
                   (with-current-buffer (window-buffer window)
                     (derived-mode-p
                      'omnigent-ui-sessions-mode
                      'omnigent-ui-workspace-mode)))
          (delete-window window)))))
  (omnigent-ui-reset)
  (message "Disconnected from Omnigent"))

(defun omnigent--server-url-from-output (buffer)
  "Return the first HTTP URL in BUFFER, or nil if none exists."
  (with-current-buffer buffer
    (goto-char (point-min))
    (when (re-search-forward "https?://[^[:space:]]+" nil t)
      (match-string-no-properties 0))))

(defun omnigent--start-server-sentinel (process _event)
  "Select the local server URL when startup PROCESS exits successfully.
Report a startup failure otherwise.  Ignore _EVENT."
  (when (memq (process-status process) '(exit signal))
    (when (eq process omnigent-start-process)
      (setq omnigent-start-process nil))
    (let* ((buffer (process-buffer process))
           (url
            (and (= (process-exit-status process) 0)
                 (buffer-live-p buffer)
                 (omnigent--server-url-from-output buffer))))
      (if url
          (progn
            (kill-buffer buffer)
            (omnigent-connect url))
        (message "Omnigent startup failed; see %s"
                 (if (buffer-live-p buffer)
                     (buffer-name buffer)
                   "process output"))))))

;;;###autoload
(defun omnigent-start-server ()
  "Start or reuse the local Omnigent server and local execution host.
Select the server URL.  Session creation discovers hosts through the server.
The CLI runs asynchronously; saved remote-server defaults are not used."
  (interactive)
  (if (process-live-p omnigent-start-process)
      (message "Omnigent server startup is already in progress")
    (let ((executable (executable-find omnigent-executable))
          (buffer (get-buffer-create "*Omnigent Server Startup*"))
          (default-directory temporary-file-directory))
      (unless executable
        (user-error "Cannot find Omnigent CLI: %s"
                    omnigent-executable))
      (with-current-buffer buffer
        (erase-buffer))
      (setq omnigent-start-process
            (make-process
             :name "omnigent-server-start"
             :buffer buffer
             :stderr buffer
             :command
             (list
              executable
              "host"
              "--server"
              ""
              "--background"
              "--no-open"
              "--non-interactive")
             :connection-type 'pipe
             :noquery t
             :sentinel #'omnigent--start-server-sentinel))
      (message "Starting or reusing the local Omnigent server..."))))

(defun omnigent-sessions-refresh ()
  "Request the root session list asynchronously.
Run `omnigent-sessions-change-hook' on success, or the error hook on failure."
  (interactive)
  (let ((number (cl-incf omnigent-sessions--refresh-number))
        (revision omnigent-sessions--revision))
    (omnigent-transport-list-sessions
     (apply-partially #'omnigent-sessions--refreshed
                      number revision))))

(defvar omnigent--create-draft nil
  "Current creation draft as a cons of server generation and fields.")

(defun omnigent--create-managed-p ()
  "Return non-nil when the draft requests a managed sandbox."
  (equal
   (alist-get 'host_type (cdr omnigent--create-draft)) "managed"))

(defun omnigent--create-default-fields ()
  "Return a fresh draft from the session creation user options."
  `((host_type . ,omnigent-session-default-host-type)
    (host_id . ,omnigent-session-default-host)
    (workspace . ,omnigent-session-default-workspace)
    (agent_reference . ,omnigent-session-default-agent)
    (model_override . ,omnigent-session-default-model)
    (reasoning_effort . ,omnigent-session-default-reasoning-effort)
    (title . ,omnigent-session-default-title)
    (terminal_launch_args
     .
     ,(and omnigent-session-default-launch-arguments
           (vconcat omnigent-session-default-launch-arguments)))
    (sandbox_provider . ,omnigent-session-default-sandbox-provider)
    (sandbox_profile_id . ,omnigent-session-default-sandbox-profile)
    (sandbox_profile_revision
     .
     ,(and omnigent-session-default-sandbox-profile
           omnigent-session-default-sandbox-profile-revision))
    (workspaces
     .
     ,(and omnigent-session-default-sandbox-repositories
           (vconcat omnigent-session-default-sandbox-repositories)))
    (git
     .
     ,(when omnigent-session-default-worktree-branch
        `((branch_name . ,omnigent-session-default-worktree-branch)
          ,@
          (when omnigent-session-default-worktree-base-branch
            `((base_branch
               .
               ,omnigent-session-default-worktree-base-branch))))))))

;;;###autoload
(defun omnigent-sessions-create (&optional edit)
  "Create a session using configured and server defaults.
With a prefix argument EDIT, open the session creation menu."
  (interactive "P")
  (let* ((id (omnigent-ui--session-id-at-point))
         (session
          (and id
               (cl-find
                id
                (omnigent-sessions-visible)
                :key (lambda (row) (alist-get 'id row))
                :test #'equal)))
         (host
          (or (alist-get 'host_id session)
              (and (derived-mode-p 'omnigent-conversation-mode)
                   omnigent-conversation-host-id)))
         (workspace
          (or (alist-get 'workspace session)
              (and (derived-mode-p 'omnigent-conversation-mode)
                   (alist-get
                    'workspace omnigent-conversation-header-data))))
         (project
          (and (derived-mode-p 'omnigent-ui-sessions-mode)
               (omnigent-ui--project-at-point)))
         (fields (omnigent--create-default-fields))
         (configured-host (alist-get 'host_id fields)))
    (when (stringp project)
      (setf (alist-get 'project_id fields) project))
    (unless (equal (alist-get 'host_type fields) "managed")
      (unless configured-host
        (setf (alist-get 'host_id fields) host))
      (when (and (not (alist-get 'workspace fields))
                 (or (not configured-host)
                     (equal configured-host host)))
        (setf (alist-get 'workspace fields) workspace)))
    (setq omnigent--create-draft
          (cons omnigent-transport--generation fields))
    (if edit
        (omnigent--create-menu)
      (omnigent--create-submit))))

;;;###autoload
(defun omnigent-sessions-create-from-file ()
  "Create an unassigned session from the current file buffer.
Use the Emacs project root or, outside a project, `default-directory'
as the workspace on a local execution host."
  (interactive)
  (unless buffer-file-name
    (user-error "Current buffer does not visit a file"))
  (let* ((project (project-current nil))
         (workspace
          (omnigent-sessions--native-workspace
           (if project
               (project-root project)
             default-directory)))
         (fields (omnigent--create-default-fields))
         (draft (cons omnigent-transport--generation fields)))
    (setf
     (alist-get 'host_type fields) "external"
     (alist-get 'workspace fields) workspace
     (alist-get 'git fields) nil)
    (setq omnigent--create-draft draft)
    (omnigent--create-pick-location
     draft
     (lambda (target)
       (when target
         (unless
             (eq
              (omnigent-workspace-host-mapping (car target)) 'local)
           (user-error
            "Select a local execution host for the file buffer"))
         (omnigent--create-submit)))
     nil
     t)))

(defun omnigent--create-pick-location
    (draft callback &optional session keep)
  "Update DRAFT location using SESSION context, then call CALLBACK.
When KEEP is non-nil, retain any location settings already in DRAFT."
  (let* ((fields (cdr draft))
         (host (alist-get 'host_id fields))
         (workspace (and keep (alist-get 'workspace fields)))
         (selected
          (lambda (target)
            (when (and (eq draft omnigent--create-draft)
                       (= (car draft) omnigent-transport--generation))
              (when target
                (unless (or keep
                            (and (equal
                                  (car target)
                                  (alist-get 'host_id fields))
                                 (equal
                                  (cdr target)
                                  (alist-get 'workspace fields))))
                  (setf (alist-get 'git (cdr draft)) nil))
                (setf
                 (alist-get 'host_id (cdr draft)) (car target)
                 (alist-get 'workspace (cdr draft)) (cdr target)))
              (funcall callback target)))))
    (cond
     ((or host workspace)
      (omnigent-sessions--read-workspace
       selected session host workspace))
     (session
      (omnigent-sessions--read-workspace selected session))
     (t
      (omnigent-sessions--read-workspace selected)))))

(defun omnigent--create-resolve (draft &optional session menu)
  "Resolve DRAFT using SESSION context and submit.
When MENU is non-nil, restore the draft after a failed request."
  (unless (= (car draft) omnigent-transport--generation)
    (user-error "Server changed during session creation"))
  (let ((fields (cdr draft)))
    (cond
     ((and (not (omnigent--create-managed-p))
           (not
            (and (alist-get 'host_id fields)
                 (alist-get 'workspace fields))))
      (omnigent--create-pick-location draft
                                      (lambda (target)
                                        (cond
                                         (target
                                          (omnigent--create-resolve
                                           draft
                                           nil menu))
                                         (menu
                                          (omnigent--create-menu))))
                                      session t))
     ((not (alist-get 'agent_id fields))
      (omnigent-sessions--read-agent
       (car draft)
       (lambda (agent)
         (when (eq draft omnigent--create-draft)
           (cond
            (agent
             (setf
              (alist-get 'agent_id (cdr draft)) agent
              (alist-get 'agent_reference (cdr draft)) nil)
             (omnigent--create-resolve draft nil menu))
            (menu
             (omnigent--create-menu)))))
       nil (alist-get 'agent_reference fields)))
     ((and (omnigent--create-managed-p)
           (not (alist-get 'sandbox_profile_id fields)))
      (omnigent--create-read-profile draft
                                     (lambda ()
                                       (omnigent--create-send
                                        draft menu))
                                     nil
                                     (when menu
                                       #'omnigent--create-menu)))
     (t
      (omnigent--create-send draft menu)))))

(defun omnigent--create-send (draft menu)
  "Send DRAFT and restore MENU after a failed request when non-nil."
  (omnigent-sessions--submit-create
   (car draft) (cdr draft)
   (when menu
     (lambda (status body)
       (omnigent-sessions--created status body)
       (when (and (not (omnigent-transport-success-p status))
                  (eq draft omnigent--create-draft)
                  (= (car draft) omnigent-transport--generation))
         (omnigent--create-menu))))))

(defun omnigent--create-submit ()
  "Submit the active creation draft."
  (interactive)
  (omnigent--create-resolve omnigent--create-draft nil t))

(defun omnigent--create-host ()
  "Choose a connected execution host for this draft."
  (interactive)
  (let ((draft omnigent--create-draft))
    (omnigent-sessions--read-host
     (lambda (host)
       (when (and (eq draft omnigent--create-draft)
                  (= (car draft) omnigent-transport--generation))
         (when (and host
                    (not
                     (equal host (alist-get 'host_id (cdr draft)))))
           (setf
            (alist-get 'host_id (cdr draft)) host
            (alist-get 'workspace (cdr draft)) nil
            (alist-get 'git (cdr draft)) nil))
         (omnigent--create-menu))))))

(defun omnigent--create-workspace ()
  "Choose a workspace on the draft's execution host."
  (interactive)
  (omnigent--create-pick-location
   omnigent--create-draft (lambda (_) (omnigent--create-menu))
   (cdr omnigent--create-draft)))

(defun omnigent--create-agent ()
  "Choose a registered agent for this draft."
  (interactive)
  (let ((draft omnigent--create-draft))
    (omnigent-sessions--read-agent
     (car draft)
     (lambda (agent)
       (when (eq draft omnigent--create-draft)
         (when (and agent
                    (not
                     (equal agent (alist-get 'agent_id (cdr draft)))))
           (dolist (field
                    '(model_override
                      reasoning_effort terminal_launch_args))
             (setf (alist-get field (cdr draft)) nil))
           (setf
            (alist-get 'agent_id (cdr draft)) agent
            (alist-get 'agent_reference (cdr draft)) nil))
         (omnigent--create-menu))))))

(defun omnigent--create-edit-field
    (field label &optional choices parse)
  "Edit FIELD using LABEL, optional CHOICES and optional PARSE function."
  (let ((current (alist-get field (cdr omnigent--create-draft))))
    (condition-case nil
        (let* ((prompt (concat label " (empty for server default): "))
               (input
                (if choices
                    (completing-read prompt choices
                                     nil
                                     t
                                     nil
                                     nil
                                     "Server default")
                  (read-string prompt
                               (if (and parse
                                        (sequencep current)
                                        (not (stringp current)))
                                   (mapconcat
                                    #'shell-quote-argument current
                                    " ")
                                 current))))
               (value
                (unless (member input '("" "Server default"))
                  (if parse
                      (funcall parse input)
                    input))))
          (unless (equal current value)
            (setf (alist-get field (cdr omnigent--create-draft))
                  value)
            (when (eq field 'model_override)
              (setf (alist-get
                     'reasoning_effort (cdr omnigent--create-draft))
                    nil))
            (when (memq field '(sandbox_provider sandbox_profile_id))
              (setf (alist-get
                     'sandbox_profile_revision
                     (cdr omnigent--create-draft))
                    nil)
              (when (eq field 'sandbox_provider)
                (setf (alist-get
                       'sandbox_profile_id
                       (cdr omnigent--create-draft))
                      nil)))))
      (quit
       nil))
    (omnigent--create-menu)))

(defun omnigent--create-label (field label)
  "Show LABEL and the draft value of FIELD."
  (format "%s (%s)"
          label
          (or (alist-get field (cdr omnigent--create-draft))
              (and (eq field 'agent_id)
                   (alist-get
                    'agent_reference (cdr omnigent--create-draft)))
              "Server default")))

(defun omnigent--create-host-type ()
  "Set the execution host type for this session."
  (interactive)
  (omnigent--create-edit-field 'host_type "Execution host type"
                               '("Server default"
                                 "external"
                                 "managed")))

(defvar omnigent--fork-draft nil
  "Active fork settings, including the sandbox draft for a managed fork.")

(defun omnigent--create-discover (draft path callback)
  "Fetch PATH for DRAFT and call CALLBACK with status and data."
  (omnigent-transport-request
   "GET" path
   (lambda (status body)
     (when (and (or (eq draft omnigent--create-draft)
                    (eq
                     draft (alist-get 'sandbox omnigent--fork-draft)))
                (= (car draft) omnigent-transport--generation))
       (funcall callback status body)))))

(defun omnigent--create-provider ()
  "Choose a sandbox provider from the connected server."
  (interactive)
  (omnigent--create-discover
   omnigent--create-draft "/v1/info"
   (lambda (status body)
     (if (omnigent-transport-success-p status)
         (omnigent--create-edit-field
          'sandbox_provider "Sandbox provider"
          (cons
           "Server default"
           (append (alist-get 'sandbox_providers body) nil)))
       (omnigent-sessions--error "List sandbox providers" status body)
       (omnigent--create-menu)))))

(defun omnigent--create-read-profile
    (draft callback &optional edit cancel)
  "Resolve the sandbox profile for DRAFT, then call CALLBACK on success.
With EDIT, prompt even if the provider does not require a profile.
Call CANCEL on cancellation during required profile selection."
  (let ((provider (alist-get 'sandbox_provider (cdr draft))))
    (if provider
        (omnigent--create-profiles
         draft provider callback edit cancel)
      (omnigent--create-discover
       draft "/v1/info"
       (lambda (status body)
         (cond
          ((and (omnigent-transport-success-p status)
                (alist-get 'sandbox_provider body))
           (omnigent--create-profiles
            draft
            (alist-get 'sandbox_provider body) callback edit cancel))
          ((not edit)
           (funcall callback))
          (t
           (omnigent-sessions--error
            "Discover default sandbox provider" status body)
           (funcall callback))))))))

(defun omnigent--create-profiles (draft provider callback edit cancel)
  "Resolve a PROVIDER profile for DRAFT and call CALLBACK.
When EDIT is non-nil, allow clearing the selection.
Call CANCEL when required selection does not complete."
  (omnigent--create-discover
   draft
   (concat
    "/v1/sandbox-profiles?provider=" (url-hexify-string provider))
   (lambda (status body)
     (cond
      ((and (not edit)
            (or (equal status 404)
                (and (omnigent-transport-success-p status)
                     (not
                      (seq-contains-p
                       (alist-get
                        'managed_providers body)
                       provider)))))
       (funcall callback))
      ((not (omnigent-transport-success-p status))
       (omnigent-sessions--error "List sandbox profiles" status body)
       (when edit
         (funcall callback)))
      (t
       (let* ((choices
               (mapcar
                (lambda (profile)
                  (cons
                   (format "%s [%s]"
                           (alist-get 'name profile)
                           (alist-get 'id profile))
                   profile))
                (alist-get 'profiles body)))
              (selection
               (cond
                ((or edit choices)
                 (condition-case nil
                     (completing-read "Sandbox profile: "
                                      (if edit
                                          (cons
                                           (list
                                            "Server default")
                                           choices)
                                        choices)
                                      nil t)
                   (quit
                    nil)))
                (t
                 (omnigent-sessions--error
                  "Create session" "No sandbox profiles available")
                 nil)))
              (profile (cdr (assoc selection choices))))
         (when selection
           (setf
            (alist-get 'sandbox_profile_id (cdr draft))
            (alist-get 'id profile)
            (alist-get 'sandbox_profile_revision (cdr draft)) (alist-get 'revision profile)))
         (if (or edit profile)
             (funcall callback)
           (when cancel
             (funcall cancel)))))))))

(defun omnigent--create-profile ()
  "Choose an authorized sandbox profile."
  (interactive)
  (omnigent--create-read-profile
   omnigent--create-draft #'omnigent--create-menu
   t))

(defun omnigent--create-repository ()
  "Set the git repositories for this session."
  (interactive)
  (omnigent--create-edit-field 'workspaces "Git repositories"
                               nil
                               (lambda (input)
                                 (vconcat
                                  (split-string-shell-command
                                   input)))))

(defun omnigent--create-model ()
  "Set the model id for this session."
  (interactive)
  (omnigent--create-edit-field 'model_override "Model ID"))

(defun omnigent--create-effort ()
  "Set the reasoning effort for this session."
  (interactive)
  (omnigent--create-edit-field 'reasoning_effort "Reasoning effort"
                               '("Server default"
                                 "none"
                                 "minimal"
                                 "low"
                                 "medium"
                                 "high"
                                 "xhigh"
                                 "max"
                                 "ultra")))

(defun omnigent--create-title ()
  "Set the title for this session."
  (interactive)
  (omnigent--create-edit-field 'title "Title"))

(defun omnigent--create-args ()
  "Set the native launch arguments for this session."
  (interactive)
  (omnigent--create-edit-field
   'terminal_launch_args "Native launch arguments"
   nil (lambda (input) (vconcat (split-string-shell-command input)))))

(defun omnigent--create-worktree ()
  "Choose a new worktree branch and optional base branch."
  (interactive)
  (let* ((settings (alist-get 'git (cdr omnigent--create-draft)))
         (branch (alist-get 'branch_name settings)))
    (condition-case nil
        (let ((name
               (read-string "New branch (empty for no worktree): "
                            branch)))
          (setf (alist-get 'git (cdr omnigent--create-draft))
                (unless (string-empty-p name)
                  (let ((base
                         (read-string
                          "Base branch (empty for current HEAD): "
                          (alist-get 'base_branch settings))))
                    (if (string-empty-p base)
                        (list (cons 'branch_name name))
                      (list
                       (cons 'branch_name name)
                       (cons 'base_branch base)))))))
      (quit
       nil))
    (omnigent--create-menu)))

(transient-define-prefix
 omnigent--create-menu
 ()
 "Review and edit the session creation draft."
 ["Location" ("t" omnigent--create-host-type
   :description
   (lambda ()
     (omnigent--create-label 'host_type "Execution host type")))
  ("h" omnigent--create-host
   :description
   (lambda ()
     (format "Host ID (%s)"
             (or (alist-get 'host_id (cdr omnigent--create-draft))
                 "Choose host")))
   :if-not omnigent--create-managed-p)
  ("w"
   omnigent--create-workspace
   :description
   (lambda ()
     (format "Workspace (%s)"
             (or (alist-get 'workspace (cdr omnigent--create-draft))
                 "Choose workspace")))
   :inapt-if
   (lambda () (not (alist-get 'host_id (cdr omnigent--create-draft))))
   :if-not omnigent--create-managed-p)
  ("g" omnigent--create-worktree
   :if-not omnigent--create-managed-p
   :description
   (lambda ()
     (format "Worktree (%s)"
             (or (alist-get
                  'branch_name
                  (alist-get 'git (cdr omnigent--create-draft)))
                 "In place"))))]
 ["Managed sandbox"
  :if omnigent--create-managed-p
  ("s" omnigent--create-provider
   :description
   (lambda ()
     (omnigent--create-label 'sandbox_provider "Sandbox provider")))
  ("i" omnigent--create-profile
   :description
   (lambda ()
     (omnigent--create-label
      'sandbox_profile_id "Sandbox profile ID")))
  ("r" omnigent--create-repository
   :description
   (lambda ()
     (omnigent--create-label 'workspaces "Git repositories")))]
 ["Session" ("a" omnigent--create-agent
   :description
   (lambda () (omnigent--create-label 'agent_id "Agent")))
  ("m"
   omnigent--create-model
   :description
   (lambda () (omnigent--create-label 'model_override "Model ID")))
  ("e" omnigent--create-effort
   :description
   (lambda ()
     (omnigent--create-label 'reasoning_effort "Reasoning effort")))
  ("T"
   omnigent--create-title
   :description
   (lambda () (omnigent--create-label 'title "Title")))
  ("l" omnigent--create-args
   :description
   (lambda ()
     (omnigent--create-label
      'terminal_launch_args "Native launch arguments")))]
 ["Actions" ("RET" "Create session" omnigent--create-submit)])

(defun omnigent--fork-launched (session status body)
  "Open fork SESSION after launch STATUS, or report failure BODY."
  (unwind-protect
      (omnigent-sessions-refresh)
    (if (omnigent-transport-success-p status)
        (omnigent-ui-created session)
      (omnigent-sessions--error
       (format "Fork %s created; runner launch failed"
               (alist-get 'id session))
       status body))))

(defun omnigent--fork-created (host workspace branch status session)
  "Launch SESSION on HOST in WORKSPACE with optional BRANCH after STATUS."
  (cond
   ((not (omnigent-transport-success-p status))
    (omnigent-sessions--error "Fork session" status session))
   ((not
     (and (listp session)
          (stringp (alist-get 'id session))
          (not (string-empty-p (alist-get 'id session)))))
    (omnigent-sessions--error
     "Fork session" nil "Invalid fork response"))
   (t
    (message "Launching fork %s..." (alist-get 'id session))
    (omnigent-sessions-launch-fork
     (alist-get 'id session)
     host
     workspace
     branch
     (apply-partially #'omnigent--fork-launched session)))))

(defun omnigent--fork-managed-p ()
  "Return non-nil when the active fork requests a managed sandbox."
  (equal (alist-get 'host_type omnigent--fork-draft) "managed"))

(defun omnigent--fork-send (draft &optional menu)
  "Resolve and create the fork described by DRAFT.
When MENU is non-nil, return to it if profile selection is canceled."
  (unless (= (alist-get 'generation draft)
             omnigent-transport--generation)
    (user-error "Server changed during fork setup"))
  (let ((sandbox (alist-get 'sandbox draft)))
    (if (and (equal (alist-get 'host_type draft) "managed")
             (not (alist-get 'sandbox_profile_id (cdr sandbox))))
        (omnigent--create-read-profile sandbox
                                       (lambda ()
                                         (omnigent--fork-request
                                          draft))
                                       nil
                                       (when menu
                                         #'omnigent--fork-menu))
      (omnigent--fork-request draft))))

(defun omnigent--fork-request (draft)
  "Create the fork in DRAFT and attach an external runner when required."
  (let* ((generation (alist-get 'generation draft))
         (host (alist-get 'host_id draft))
         (workspace (alist-get 'workspace draft))
         (branch (alist-get 'branch draft))
         (managed (equal (alist-get 'host_type draft) "managed"))
         (fields
          (if managed
              (append (cdr (alist-get 'sandbox draft)) draft)
            draft))
         options)
    (unless (= generation omnigent-transport--generation)
      (user-error "Server changed during fork setup"))
    (unless (or managed
                (and (stringp host)
                     (not (string-empty-p host))
                     (stringp workspace)
                     (not (string-empty-p workspace))))
      (user-error "Choose an execution host and workspace"))
    (dolist (field
             (append
              '(agent_id
                up_to_response_id model_override reasoning_effort)
              (when managed
                '(host_type
                  sandbox_provider
                  sandbox_profile_id
                  sandbox_profile_revision))))
      (when-let* ((value (alist-get field fields)))
        (push (cons (symbol-name field) value) options)))
    (message "Forking session...")
    (omnigent-sessions-fork
     (alist-get 'source draft) options
     (lambda (status session)
       (when (= generation omnigent-transport--generation)
         (if (and managed
                  (omnigent-transport-success-p status)
                  (listp session)
                  (stringp (alist-get 'id session))
                  (not (string-empty-p (alist-get 'id session))))
             (omnigent--fork-launched
              (omnigent-sessions--seed-sandbox-status session)
              status
              nil)
           (omnigent--fork-created
            host workspace branch status session)))))))

;;;###autoload
(defun omnigent-conversation-fork (edit)
  "Fork the current session using its execution host type.
With prefix argument EDIT, open the fork menu."
  (interactive "P")
  (unless (derived-mode-p 'omnigent-conversation-mode)
    (user-error "No Omnigent conversation in this buffer"))
  (let (responses)
    (when (and edit (hash-table-p omnigent-conversation--items))
      (maphash
       (lambda (_ item)
         (when-let* ((id (alist-get 'response_id item)))
           (when (stringp id)
             (push id responses))))
       omnigent-conversation--items))
    (let ((draft
           `((source . ,omnigent-conversation-session-id)
             (generation . ,omnigent-transport--generation)
             (host_type
              .
              ,(when omnigent-conversation--managed
                 "managed"))
             (sandbox . ,(list omnigent-transport--generation))
             (host_id . ,omnigent-conversation-host-id)
             (workspace
              .
              ,(alist-get
                'workspace omnigent-conversation-header-data))
             (responses . ,(delete-dups responses)))))
      (setq omnigent--fork-draft draft)
      (if edit
          (omnigent--fork-menu)
        (omnigent--fork-submit)))))

(defun omnigent--fork-submit ()
  "Submit the connected-host fork draft."
  (interactive)
  (omnigent--fork-send omnigent--fork-draft t))

(defun omnigent--fork-location ()
  "Choose a connected host and workspace for the fork."
  (interactive)
  (let ((draft omnigent--fork-draft))
    (unless (= (alist-get 'generation draft)
               omnigent-transport--generation)
      (user-error "Server changed during fork setup"))
    (omnigent-sessions--read-workspace
     (lambda (target)
       (when (and (eq draft omnigent--fork-draft)
                  (= (alist-get 'generation draft)
                     omnigent-transport--generation))
         (when target
           (unless (and (equal
                         (car target) (alist-get 'host_id draft))
                        (equal
                         (cdr target) (alist-get 'workspace draft)))
             (setf (alist-get 'branch omnigent--fork-draft) nil))
           (setf
            (alist-get 'host_id omnigent--fork-draft) (car target)
            (alist-get 'workspace omnigent--fork-draft) (cdr target)))
         (omnigent--fork-menu)))
     draft)))

(defun omnigent--fork-agent ()
  "Choose a registered agent for the fork."
  (interactive)
  (let ((draft omnigent--fork-draft))
    (unless (= (alist-get 'generation draft)
               omnigent-transport--generation)
      (user-error "Server changed during fork setup"))
    (omnigent-sessions--read-agent
     (alist-get 'generation draft)
     (lambda (agent)
       (when (and (eq draft omnigent--fork-draft)
                  (= (alist-get 'generation draft)
                     omnigent-transport--generation))
         (when agent
           (when (eq agent 'inherit)
             (setq agent nil))
           (unless (equal agent (alist-get 'agent_id draft))
             (setf
              (alist-get 'model_override omnigent--fork-draft) nil
              (alist-get 'reasoning_effort omnigent--fork-draft) nil))
           (setf (alist-get 'agent_id omnigent--fork-draft) agent))
         (omnigent--fork-menu)))
     "Source agent")))

(defun omnigent--fork-read-field
    (field prompt &optional choices default)
  "Set fork FIELD using PROMPT, optional CHOICES and DEFAULT."
  (condition-case nil
      (let ((value
             (if choices
                 (completing-read prompt choices
                                  nil
                                  t
                                  nil
                                  nil
                                  default)
               (read-string prompt
                            (alist-get field omnigent--fork-draft)))))
        (setf (alist-get field omnigent--fork-draft)
              (unless (or (string-empty-p value)
                          (equal value default))
                value)))
    (quit
     nil))
  (omnigent--fork-menu))

(defun omnigent--fork-branch ()
  "Set the new worktree branch for the fork."
  (interactive)
  (omnigent--fork-read-field
   'branch "New branch (empty for no worktree): "))

(defun omnigent--fork-response ()
  "Choose the last response to include in the fork."
  (interactive)
  (omnigent--fork-read-field
   'up_to_response_id
   "Fork through response: "
   (cons "Full history" (alist-get 'responses omnigent--fork-draft))
   "Full history"))

(defun omnigent--fork-model ()
  "Set a model ID, inherit the source model, or reset to the agent default."
  (interactive)
  (omnigent--fork-read-field
   'model_override "Model ID (empty to inherit, default to reset): "))

(defun omnigent--fork-effort ()
  "Set reasoning effort, inherit the source effort, or reset it."
  (interactive)
  (omnigent--fork-read-field 'reasoning_effort "Reasoning effort: "
                             '("Inherit"
                               "default"
                               "none"
                               "minimal"
                               "low"
                               "medium"
                               "high"
                               "xhigh"
                               "max"
                               "ultra")
                             "Inherit"))

(defun omnigent--fork-host-type ()
  "Choose a connected execution host or a new managed sandbox."
  (interactive)
  (omnigent--fork-read-field 'host_type "Execution host type: "
                             '("external" "managed")
                             "external"))

(defun omnigent--fork-provider ()
  "Choose a provider for the new fork sandbox."
  (interactive)
  (let* ((draft (alist-get 'sandbox omnigent--fork-draft))
         (fields (cdr draft)))
    (omnigent--create-discover
     draft "/v1/info"
     (lambda (status body)
       (if (omnigent-transport-success-p status)
           (condition-case nil
               (let* ((selection
                       (completing-read
                        "Sandbox provider: "
                        (cons
                         "Server default"
                         (append
                          (alist-get 'sandbox_providers body) nil))
                        nil t nil nil "Server default"))
                      (provider
                       (unless (equal selection "Server default")
                         selection)))
                 (unless (equal
                          provider
                          (alist-get 'sandbox_provider fields))
                   (setf
                    (alist-get 'sandbox_provider (cdr draft)) provider
                    (alist-get 'sandbox_profile_id (cdr draft)) nil
                    (alist-get 'sandbox_profile_revision (cdr draft)) nil)))
             (quit
              nil))
         (omnigent-sessions--error
          "List sandbox providers" status body))
       (omnigent--fork-menu)))))

(defun omnigent--fork-profile ()
  "Choose an authorized profile for the new fork sandbox."
  (interactive)
  (omnigent--create-read-profile (alist-get
                                  'sandbox omnigent--fork-draft)
                                 #'omnigent--fork-menu
                                 t))

(defun omnigent--fork-label (field label default)
  "Show fork FIELD under LABEL, with DEFAULT when unset."
  (format "%s (%s)"
          label
          (or (alist-get field omnigent--fork-draft) default)))

(transient-define-prefix
 omnigent--fork-menu () "Review the location and settings for a fork."
 ["Location" ("h" omnigent--fork-host-type
   :description
   (lambda ()
     (omnigent--fork-label
      'host_type "Execution host type" "external")))
  ("w" omnigent--fork-location
   :if-not omnigent--fork-managed-p
   :description
   (lambda ()
     (format "Host and workspace (%s %s)"
             (or (alist-get 'host_id omnigent--fork-draft)
                 "Choose host")
             (or (alist-get 'workspace omnigent--fork-draft) ""))))
  ("g"
   omnigent--fork-branch
   :if-not omnigent--fork-managed-p
   :description
   (lambda () (omnigent--fork-label 'branch "Worktree" "In place")))]
 ["Managed sandbox"
  :if
  omnigent--fork-managed-p
  ("s" "Sandbox provider" omnigent--fork-provider)
  ("i" "Sandbox profile" omnigent--fork-profile)]
 ["Session" ("a" omnigent--fork-agent
   :description
   (lambda ()
     (omnigent--fork-label 'agent_id "Agent" "Source agent")))
  ("r" omnigent--fork-response
   :description
   (lambda ()
     (omnigent--fork-label
      'up_to_response_id "History" "Full history")))
  ("m" omnigent--fork-model
   :description
   (lambda ()
     (omnigent--fork-label 'model_override "Model" "Inherit")))
  ("e" omnigent--fork-effort
   :description
   (lambda ()
     (omnigent--fork-label
      'reasoning_effort "Reasoning effort" "Inherit")))]
 ["Actions" ("RET" "Fork session" omnigent--fork-submit)])

;;;###autoload
(defun omnigent-conversation-archive ()
  "Toggle the current session's archived state.
Close this conversation buffer after the session becomes archived."
  (interactive)
  (unless (derived-mode-p 'omnigent-conversation-mode)
    (user-error "No Omnigent conversation in this buffer"))
  (let ((buffer (current-buffer)))
    (omnigent-sessions-toggle-archive
     omnigent-conversation-session-id
     (lambda (status body)
       (when (and (buffer-live-p buffer)
                  (omnigent-transport-success-p status)
                  (eq (alist-get 'archived body) t))
         (kill-buffer buffer))))))

(defvar omnigent--conversation-opening-side-chat nil
  "Non-nil while initializing a side chat buffer.")

(define-derived-mode
 omnigent-conversation-mode text-mode "Omnigent"
 "Major mode for a conversation transcript and composer.
Use `omnigent-conversation-open' to create a conversation buffer."
 (unless omnigent-conversation--session-id
   (error "A session ID is required"))
 (setq
  omnigent-conversation-session-id omnigent-conversation--session-id
  omnigent--conversation-side-chat-p omnigent--conversation-opening-side-chat
  omnigent-conversation--sandbox-status omnigent-conversation--initial-sandbox-status
  omnigent-conversation--managed (and omnigent-conversation--initial-sandbox-status t)
  omnigent-conversation--items (make-hash-table :test 'equal)
  omnigent-conversation--elicitations (make-hash-table :test 'equal)
  omnigent-conversation--elicitation-drafts (make-hash-table :test 'equal)
  omnigent-conversation--elicitation-submitting (make-hash-table :test 'equal)
  omnigent-conversation--loading t
  omnigent-conversation--connected nil
  buffer-read-only t
  omnigent-conversation--prompt-start (copy-marker (point-min))
  omnigent-conversation--prompt-end (copy-marker (point-max) t))
 (add-hook 'kill-buffer-hook #'omnigent-conversation--close nil t)
 (add-hook
  'completion-at-point-functions #'omnigent--conversation-command-capf
  nil t)
 (setq-local omnigent--file-completion-cache
             (make-hash-table :test 'equal))
 (add-hook 'completion-at-point-functions #'omnigent--file-capf nil t)
 (when (eq omnigent-completion-frontend 'corfu)
   (require 'omnigent-corfu)
   (omnigent-corfu-setup))
 (omnigent--conversation-connect))

(defvar-local omnigent--file-completion-cache nil)

(defun omnigent--file-completion-result
    (buffer directory after entries status body)
  "Store ENTRIES and results from STATUS and BODY for BUFFER and DIRECTORY.
AFTER is the cursor used for the current page."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (and (omnigent-transport-success-p status)
               (vectorp (alist-get 'data body)))
          (let ((entries
                 (append entries (append (alist-get 'data body) nil)))
                (cursor (alist-get 'last_id body)))
            (if (eq (alist-get 'has_more body) t)
                (if (and (stringp cursor) (not (equal cursor after)))
                    (omnigent--file-completion-request directory
                                                       cursor
                                                       entries)
                  (remhash directory omnigent--file-completion-cache)
                  (message "Invalid workspace directory pagination"))
              (puthash
               directory entries omnigent--file-completion-cache)
              (when (eq omnigent-completion-frontend 'corfu)
                (omnigent-corfu-refresh directory))))
        (remhash directory omnigent--file-completion-cache)
        (message "Could not load workspace directory: %s"
                 (omnigent-transport-error-message
                  "List files" status body))))))

(defun omnigent--file-completion-request
    (directory &optional after entries)
  "Request direct children of DIRECTORY after AFTER, accumulating ENTRIES."
  (puthash directory 'loading omnigent--file-completion-cache)
  (condition-case err
      (omnigent-transport--request
       omnigent-conversation-session-id "GET"
       (concat
        (omnigent-workspace--path
         omnigent-conversation-session-id "filesystem")
        (unless (string-empty-p directory)
          (concat
           "/"
           (mapconcat
            #'url-hexify-string (split-string directory "/" t)
            "/")))
        "?limit=1000&order=asc"
        (when after
          (concat "&after=" (url-hexify-string after))))
       (apply-partially #'omnigent--file-completion-result
                        (current-buffer)
                        directory
                        after
                        entries))
    (error
     (remhash directory omnigent--file-completion-cache)
     (message "Could not load workspace directory: %s"
              (error-message-string err)))))

(defun omnigent--file-completion-context ()
  "Return the bounds and directory of the file mention at point."
  (when (and omnigent-conversation--prompt-start
             (>= (point) omnigent-conversation--prompt-start))
    (save-excursion
      (let ((end (point)))
        (skip-chars-backward "^ \t\n@"
                             omnigent-conversation--prompt-start)
        (when (and (eq (char-before) ?@)
                   (or (= (1- (point))
                          omnigent-conversation--prompt-start)
                       (memq
                        (char-before (1- (point))) '(?\s ?\t ?\n))))
          (let* ((start (1- (point)))
                 (query (buffer-substring-no-properties (point) end))
                 (directory (or (file-name-directory query) "")))
            (list start end (directory-file-name directory))))))))

(defun omnigent--file-candidates (string predicate action)
  "Complete STRING with PREDICATE and ACTION using the directory cache."
  (when-let* ((context (omnigent--file-completion-context)))
    (let* ((directory (nth 2 context))
           (directory
            (if (equal directory ".")
                ""
              directory))
           (entries
            (gethash directory omnigent--file-completion-cache
                     'missing)))
      (when (eq entries 'missing)
        (omnigent--file-completion-request directory))
      (complete-with-action
       action
       (mapcar
        (lambda (entry)
          (concat
           "@"
           (unless (string-empty-p directory)
             (concat directory "/"))
           (alist-get 'name entry)
           (when (equal (alist-get 'type entry) "directory")
             "/")))
        (if (listp entries)
            entries
          nil))
       string predicate))))

(defun omnigent--file-capf ()
  "Complete workspace files after an at sign in the composer."
  (when-let* ((context (omnigent--file-completion-context)))
    (list
     (car context)
     (cadr context)
     #'omnigent--file-candidates
     :exit-function #'omnigent--file-completion-exit
     :company-prefix-length t)))

(defun omnigent--attachment-bounds ()
  "Return the bounds of the attachment block in the composer."
  (let ((start
         (text-property-any
          omnigent-conversation--prompt-start
          (point-max)
          'omnigent-attachment-block
          t)))
    (when start
      (cons
       start
       (or (next-single-property-change
            start 'omnigent-attachment-block
            nil (point-max))
           (point-max))))))

(defun omnigent--attachment-paths ()
  "Return the file paths in the composer attachment block."
  (when-let* ((bounds (omnigent--attachment-bounds)))
    (let ((pos (car bounds))
          paths)
      (while (< pos (cdr bounds))
        (let* ((path
                (get-text-property pos 'omnigent-attachment-path))
               (end
                (next-single-property-change
                 pos 'omnigent-attachment-path
                 nil (cdr bounds))))
          (when path
            (push (buffer-substring-no-properties pos end) paths))
          (setq pos end)))
      (nreverse paths))))

(defun omnigent--attachment-open-result (buffer path status body)
  "Open PATH for BUFFER using workspace root STATUS and BODY."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((root (alist-get 'base body)))
        (if (and (omnigent-transport-success-p status) (stringp root))
            (find-file
             (omnigent-workspace-local-filename
              root path
              (omnigent-workspace-host-mapping
               omnigent-conversation-host-id)))
          (message "%s"
                   (omnigent-transport-error-message
                    "Open attached file" status body)))))))

(defun omnigent--attachment-open (button)
  "Open the file named by BUTTON in the session workspace."
  (let ((path (button-label button)))
    (when (string-match "\\`\\(.*\\):[0-9]+-[0-9]+\\'" path)
      (setq path (match-string 1 path)))
    (omnigent-workspace--root
     omnigent-conversation-session-id
     (apply-partially #'omnigent--attachment-open-result
                      (current-buffer) path))))

(defun omnigent--attachment-set (paths)
  "Replace the composer attachment block with PATHS."
  (let ((bounds (omnigent--attachment-bounds)))
    (save-excursion
      (when bounds
        (delete-region (car bounds) (cdr bounds)))
      (when paths
        (goto-char (point-max))
        (let ((start (point)))
          (insert "\n\n[Attached (files): ")
          (let ((first t))
            (dolist (path paths)
              (unless first
                (insert ", "))
              (setq first nil)
              (insert-text-button path
                                  'action
                                  #'omnigent--attachment-open
                                  'follow-link
                                  t
                                  'omnigent-attachment-path
                                  t
                                  'rear-nonsticky
                                  t)))
          (insert "]")
          (add-text-properties
           start
           (point)
           '(omnigent-attachment-block t rear-nonsticky t))
          (put-text-property
           start (point) 'font-lock-face 'omnigent-ui-attachment)
          (put-text-property
           start (point) 'face 'omnigent-ui-attachment)
          (let ((pos start))
            (while (< pos (point))
              (let ((next
                     (next-single-property-change
                      pos 'omnigent-attachment-path
                      nil (point))))
                (when (get-text-property
                       pos 'omnigent-attachment-path)
                  (put-text-property pos next 'face 'link)
                  (put-text-property pos next 'font-lock-face 'link))
                (setq pos next)))))))))

(defun omnigent--file-completion-exit (candidate status)
  "Attach file CANDIDATE after completion STATUS."
  (when (and (memq status '(finished exact))
             (string-prefix-p "@" candidate)
             (not (string-suffix-p "/" candidate)))
    (let ((start (- (point) (length candidate)))
          (path (substring-no-properties candidate 1)))
      (when (and (>= start omnigent-conversation--prompt-start)
                 (equal
                  (buffer-substring-no-properties start (point))
                  candidate))
        (delete-region start (point))
        (let ((position (copy-marker (point))))
          (omnigent--attachment-set
           (delete-dups
            (append (omnigent--attachment-paths) (list path))))
          (goto-char position)
          (set-marker position nil))))))

(defun omnigent-conversation-delete-backward (arg)
  "Delete the previous attachment or ARG characters."
  (interactive "p")
  (let ((path
         (and (= arg 1)
              (> (point) (point-min))
              (get-text-property
               (1- (point)) 'omnigent-attachment-path))))
    (if (and path
             (not
              (get-text-property (point) 'omnigent-attachment-path)))
        (let* ((end (point))
               (start
                (or (previous-single-property-change
                     end 'omnigent-attachment-path
                     nil omnigent-conversation--prompt-start)
                    omnigent-conversation--prompt-start))
               (name (buffer-substring-no-properties start end))
               (paths (omnigent--attachment-paths)))
          (omnigent--attachment-set (delete name paths)))
      (backward-delete-char-untabify arg))))

(define-key
 omnigent-conversation-mode-map
 (kbd "DEL")
 #'omnigent-conversation-delete-backward)

(defvar omnigent--conversation-submitted-draft nil)

(defvar-local omnigent--conversation-command-catalog-requested nil)
(defvar-local omnigent--conversation-command-skills nil)

(defun omnigent--conversation-command-catalog-result
    (buffer status body)
  "Cache skill names from STATUS and BODY in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (and (omnigent-transport-success-p status)
               (vectorp (alist-get 'skills body))
               (vectorp (alist-get 'warnings body))
               (cl-every
                (lambda (skill)
                  (stringp (alist-get 'name skill)))
                (alist-get 'skills body)))
          (progn
            (setq omnigent--conversation-command-skills
                  (mapcar
                   (lambda (skill) (alist-get 'name skill))
                   (append (alist-get 'skills body) nil)))
            (when (> (length (alist-get 'warnings body)) 0)
              (message "Skill discovery incomplete: %s"
                       (mapconcat #'identity
                                  (append
                                   (alist-get 'warnings body) nil)
                                  "; "))))
        (message "Could not load skills for completion")))))

(defun omnigent--conversation-command-capf ()
  "Complete slash commands at the start of the composer."
  (let ((start (marker-position omnigent-conversation--prompt-start)))
    (when (and start
               (>= (point) (1+ start)) (eq (char-after start) ?/)
               (string-match-p
                "\\`/[^[:space:]/]*\\'"
                (buffer-substring-no-properties start (point))))
      (list
       start (point)
       (mapcar
        (lambda (name) (concat "/" name))
        (append
         '("model"
           "effort"
           "new"
           "clear"
           "compact"
           "btw"
           "side")
         omnigent--conversation-command-skills))
       :exclusive 'no))))

(define-key
 omnigent-conversation-mode-map
 (kbd "C-c @ C-c")
 #'omnigent-conversation-close-block)
(define-key
 omnigent-conversation-mode-map
 (kbd "C-c @ C-e")
 #'omnigent-conversation-open-block)

(defun omnigent--conversation-connect ()
  "Start the current conversation stream without replacing its draft."
  (let ((buffer (current-buffer))
        opening-snapshot)
    (setq
     omnigent-conversation--stream
     (omnigent-transport-start-session-stream
      omnigent-conversation-session-id
      (lambda (name data)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (and (equal name "session.created")
                       (stringp (alist-get 'child_session_id data)))
              (omnigent-sessions-refresh-children
               omnigent-conversation-session-id))
            (omnigent-conversation--event name data))))
      (lambda (status body)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (omnigent-conversation--snapshot status body))))
      (lambda (err) (message "Omnigent stream: %s" err))
      (lambda ()
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (omnigent-conversation--begin-snapshot)
            (when opening-snapshot
              (setq opening-snapshot nil)
              (omnigent-sessions-refresh-children
               omnigent-conversation-session-id)))))
      (lambda (state)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when (eq state 'connecting)
              (setq opening-snapshot t))
            (omnigent-conversation--connection-state state)
            (when (and
                   (eq state 'connected)
                   (not omnigent--conversation-side-chat-p)
                   (not
                    omnigent--conversation-command-catalog-requested))
              (setq
               omnigent--conversation-command-catalog-requested t)
              (condition-case err
                  (omnigent-transport--request
                   omnigent-conversation-session-id "GET"
                   (concat
                    "/v1/skills?session_id="
                    (url-hexify-string
                     omnigent-conversation-session-id))
                   (apply-partially
                    #'omnigent--conversation-command-catalog-result
                    buffer))
                (error
                 (message "Could not load skills for completion: %s"
                          (error-message-string err))))))))
      omnigent--conversation-side-chat-p))
    ;; A synchronous snapshot setup failure can arrive before the handle is assigned.
    (when omnigent-conversation--invalid
      (omnigent-transport-stop-session-stream
       omnigent-conversation--stream))))

(defun omnigent-conversation--default-directory (id)
  "Return the local workspace directory for session ID.
Use the current project root when the session workspace is unavailable."
  (let* ((session (omnigent-sessions-row id))
         (workspace (alist-get 'workspace session))
         (host-id (alist-get 'host_id session)))
    (if (and (stringp workspace)
             (not (string-empty-p workspace))
             (stringp host-id)
             (not (string-empty-p host-id)))
        (file-name-as-directory
         (omnigent-workspace-local-filename
          workspace "" (omnigent-workspace-host-mapping host-id)))
      (let ((project (project-current nil)))
        (if project
            (project-root project)
          default-directory)))))

(defvar-local omnigent-conversation--directory-pending nil
  "Non-nil when the session workspace is not yet available.")

(defun omnigent-conversation--update-directories ()
  "Set pending conversation directories when session metadata arrives."
  (dolist (entry omnigent-sessions--buffers)
    (when (buffer-live-p (cdr entry))
      (with-current-buffer (cdr entry)
        (when omnigent-conversation--directory-pending
          (let* ((session
                  (cl-find
                   (car entry)
                   (omnigent-sessions-visible)
                   :key (lambda (row) (alist-get 'id row))
                   :test #'equal))
                 (workspace (alist-get 'workspace session))
                 (host (alist-get 'host_id session)))
            (when (and (stringp workspace)
                       (not (string-empty-p workspace))
                       (stringp host)
                       (not (string-empty-p host)))
              (setq
               default-directory
               (omnigent-conversation--default-directory (car entry))
               omnigent-conversation--directory-pending nil))))))))

(add-hook
 'omnigent-sessions-change-hook
 #'omnigent-conversation--update-directories)

(defun omnigent--conversation-buffer (id title &optional side-chat)
  "Return the conversation buffer for session ID, creating it with TITLE.
When SIDE-CHAT is non-nil, skip skill completion discovery."
  (let* ((directory (omnigent-conversation--default-directory id))
         (buffer (omnigent-sessions-buffer id))
         (session (omnigent-sessions-row id))
         (workspace (alist-get 'workspace session))
         (host (alist-get 'host_id session)))
    (unless buffer
      (setq buffer
            (generate-new-buffer
             (format "*omnigent: %s [%s]*"
                     (if (or (null title) (string-empty-p title))
                         "Untitled"
                       title)
                     (substring id 0 (min 9 (length id))))))
      (condition-case err
          (progn
            (with-current-buffer buffer
              (setq default-directory directory)
              (let ((omnigent-conversation--session-id id)
                    (omnigent--conversation-opening-side-chat
                     side-chat))
                (omnigent-conversation-mode)))
            (omnigent-sessions-register-buffer id buffer)
            (omnigent-sessions-refresh-children id))
        (error
         (kill-buffer buffer)
         (signal (car err) (cdr err)))))
    (with-current-buffer buffer
      (setq
       default-directory (file-name-as-directory directory)
       omnigent-conversation--directory-pending
       (not
        (and (stringp workspace)
             (not (string-empty-p workspace))
             (stringp host)
             (not (string-empty-p host))))))
    buffer))

;;;###autoload
(defun omnigent-conversation-open (id &optional title)
  "Open the conversation for session ID, with optional TITLE."
  (interactive "sSession ID: ")
  (pop-to-buffer (omnigent--conversation-buffer id title)))

;;;###autoload
(defun omnigent-attach-file-to-session ()
  "Attach the visited file or active region to a matching session composer."
  (interactive)
  (let* ((file (expand-file-name buffer-file-name))
         (region-start
          (when (use-region-p)
            (region-beginning)))
         (region-end
          (when region-start
            (region-end)))
         (range
          (when region-start
            (format ":%d-%d"
                    (line-number-at-pos region-start t)
                    (line-number-at-pos
                     (max region-start (1- region-end)) t))))
         matches)
    (dolist (session (omnigent-sessions-visible))
      (let* ((id (alist-get 'id session))
             (root
              (or (alist-get
                   'root
                   (gethash id omnigent-ui--workspace-cache))
                  (alist-get 'workspace session)))
             (host (alist-get 'host_id session)))
        (when (and (stringp root) (stringp host) (stringp id))
          (let ((mapped
                 (condition-case nil
                     (omnigent-workspace-local-filename
                      root "" (omnigent-workspace-host-mapping host))
                   (error
                    nil))))
            (when (and mapped
                       (string-prefix-p
                        (file-name-as-directory mapped) file))
              (push (cons
                     session
                     (concat
                      (substring file
                                 (length
                                  (file-name-as-directory mapped)))
                      range))
                    matches))))))
    (unless matches
      (user-error "No session workspace contains this file"))
    (setq matches
          (sort matches
                (lambda (a b)
                  (let ((left (alist-get 'updated_at (car a)))
                        (right (alist-get 'updated_at (car b))))
                    (if (and (numberp left) (numberp right))
                        (> left right)
                      (string>
                       (format "%s" (or left ""))
                       (format "%s" (or right ""))))))))
    (let* ((choices
            (mapcar
             (lambda (match)
               (let* ((session (car match))
                      (id (alist-get 'id session)))
                 (cons
                  (format "%s (%s) [%s]"
                          (or (alist-get 'title session) "Untitled")
                          (let ((age
                                 (omnigent-ui--session-age
                                  (alist-get 'updated_at session))))
                            (if (and age (not (equal age "n/a")))
                                (concat age " ago")
                              "unknown"))
                          id)
                  match)))
             matches))
           (table
            (lambda (string predicate action)
              (if (eq action 'metadata)
                  '(metadata
                    (display-sort-function . identity)
                    (cycle-sort-function . identity))
                (complete-with-action
                 action choices string predicate))))
           (selected
            (cdr
             (assoc
              (completing-read "Attach to session: " table
                               nil t)
              choices)))
           (session (car selected))
           (buffer
            (omnigent--conversation-buffer
             (alist-get 'id session) (alist-get 'title session)))
           (window
            (or (get-buffer-window buffer t)
                (display-buffer buffer
                                '(display-buffer-pop-up-window)))))
      (unless (window-live-p window)
        (user-error "Could not display the session"))
      (with-current-buffer buffer
        (when (or omnigent-conversation--invalid
                  omnigent-conversation--permission-read-only)
          (user-error "This session is unavailable or read-only"))
        (let ((inhibit-read-only t))
          (omnigent--attachment-set
           (delete-dups
            (append
             (omnigent--attachment-paths) (list (cdr selected))))))
        (goto-char
         (or (car (omnigent--attachment-bounds)) (point-max))))
      (select-window window)
      (set-window-point
       window
       (with-current-buffer buffer
         (point))))))

;;;###autoload
(defun omnigent-conversation-side-chat (&optional callback)
  "Open a private side chat with the current conversation's history.
Use `omnigent-side-chat-display-action' as set when called.
Optional CALLBACK receives (STATUS BODY) asynchronously.  On HTTP success,
BODY is the conversation buffer.  It may still be loading its transcript.
On failure, BODY holds the diagnostics.  Without CALLBACK, report errors
in the echo area."
  (interactive)
  (unless (derived-mode-p 'omnigent-conversation-mode)
    (user-error "No Omnigent conversation in this buffer"))
  (when buffer-read-only
    (user-error "This session is read-only"))
  (message "Opening side chat...")
  (let ((action omnigent-side-chat-display-action)
        (result
         (or callback
             (lambda (status body)
               (unless (omnigent-transport-success-p status)
                 (message "%s"
                          (omnigent-transport-error-message
                           "Open side chat" status body)))))))
    (omnigent-sessions-side-chat
     omnigent-conversation-session-id
     (lambda (status session)
       (if (not (omnigent-transport-success-p status))
           (funcall result status session)
         (let* ((id (alist-get 'id session))
                (buffer
                 (condition-case err
                     (omnigent--conversation-buffer id
                                                    (alist-get
                                                     'title session)
                                                    t)
                   (error
                    (setq status nil)
                    (format "Side chat %s: %s"
                            id
                            (error-message-string err))))))
           (when (and action (bufferp buffer))
             (pop-to-buffer buffer action))
           (funcall result status buffer)))))))

(defun omnigent-conversation-reconnect ()
  "Reconnect the current session and preserve its composer draft."
  (interactive)
  (unless omnigent-conversation-session-id
    (user-error "No session in this buffer"))
  (omnigent-conversation--close)
  (setq
   omnigent-conversation--invalid nil
   omnigent-conversation--connected nil)
  (omnigent-conversation--begin-snapshot)
  (omnigent--conversation-connect))

(defun omnigent--composer-clear (text)
  "Clear TEXT from the composer if it has not changed."
  (when (equal
         text
         (buffer-substring-no-properties
          omnigent-conversation--prompt-start (point-max)))
    (delete-region omnigent-conversation--prompt-start (point-max))))

(defun omnigent--conversation-submit (text event)
  "Submit TEXT using session EVENT and the normal pending message flow."
  (let ((entry
         (copy-tree
          `((state . submitting)
            (content . ,text)
            (draft . ,omnigent--conversation-submitted-draft)
            (pending_id . nil)
            (consumed-pending-ids . nil))))
        (buffer (current-buffer)))
    (setq
     omnigent-conversation--sending entry
     omnigent-conversation--pending-inputs (append omnigent-conversation--pending-inputs (list entry)))
    (omnigent-conversation--notify-input-change)
    (condition-case err
        (omnigent-transport-post-session-event
         omnigent-conversation-session-id
         event
         (apply-partially #'omnigent-conversation--sent buffer entry))
      ((error quit)
       (setq
        omnigent-conversation--sending nil
        omnigent-conversation--pending-inputs (delq entry omnigent-conversation--pending-inputs))
       (omnigent-conversation--notify-input-change)
       (signal (car err) (cdr err))))))

(defun omnigent--conversation-message (text)
  "Submit TEXT as a user message."
  (omnigent--conversation-submit
   text (omnigent-transport--user-message-event text)))

(defun omnigent--conversation-skills-result
    (buffer text name args status body)
  "Dispatch TEXT with NAME and ARGS using skill catalog STATUS and BODY in BUFFER."
  (when (and (buffer-live-p buffer)
             (not
              (buffer-local-value
               'omnigent-conversation--invalid buffer)))
    (with-current-buffer buffer
      (setq omnigent-conversation--sending nil)
      (cond
       ((not (omnigent-transport-success-p status))
        (message "%s"
                 (omnigent-transport-error-message
                  "Read skills" status body)))
       ((not
         (and (vectorp (alist-get 'skills body))
              (vectorp (alist-get 'warnings body))
              (cl-every
               (lambda (skill)
                 (stringp (alist-get 'name skill)))
               (alist-get 'skills body))))
        (message "Invalid skill catalog"))
       ((> (length (alist-get 'warnings body)) 0)
        (message "Skill discovery incomplete: %s"
                 (mapconcat
                  #'identity (append (alist-get 'warnings body) nil)
                  "; ")))
       ((cl-find
         name
         (alist-get 'skills body)
         :key (lambda (skill) (alist-get 'name skill))
         :test #'equal)
        (omnigent--conversation-submit
         text
         `(("type" . "slash_command")
           ("data" .
            (("kind" . "skill")
             ("name" . ,name)
             ("arguments" . ,args))))))
       (t
        (omnigent--conversation-message text))))))

(defun omnigent--conversation-control-result
    (buffer text action status body)
  "Handle ACTION for TEXT in BUFFER with response STATUS and BODY."
  (when (and (buffer-live-p buffer)
             (not
              (buffer-local-value
               'omnigent-conversation--invalid buffer)))
    (with-current-buffer buffer
      (setq omnigent-conversation--sending nil)
      (if (and (omnigent-transport-success-p status)
               (not (eq (alist-get 'denied body) t)))
          (omnigent--composer-clear text)
        (message "%s"
                 (omnigent-transport-error-message
                  action status body))))))

(defun omnigent--conversation-control (type text)
  "Send control event TYPE for composer TEXT."
  (setq omnigent-conversation--sending t)
  (condition-case err
      (omnigent-transport-post-session-event
       omnigent-conversation-session-id `(("type" . ,type))
       (apply-partially #'omnigent--conversation-control-result
                        (current-buffer) text type))
    ((error quit)
     (setq omnigent-conversation--sending nil)
     (signal (car err) (cdr err)))))

(defun omnigent-conversation-clear ()
  "Clear the current session and follow the new session."
  (interactive)
  (when buffer-read-only
    (user-error "This session is read-only"))
  (when omnigent-conversation--sending
    (user-error "A message is being sent"))
  (omnigent--conversation-control
   "clear"
   (buffer-substring-no-properties
    omnigent-conversation--prompt-start (point-max))))

(defun omnigent--conversation-reset-setting (setting)
  "Reset session SETTING to its default value."
  (funcall (if (eq setting 'model)
               #'omnigent-transport-set-session-model
             #'omnigent-transport-set-session-effort)
           omnigent-conversation-session-id nil
           (lambda (status body)
             (if (omnigent-transport-success-p status)
                 (message "%s reset requested" setting)
               (message "%s"
                        (omnigent-transport-error-message
                         "Reset setting" status body))))))

(defun omnigent--conversation-command-name (text)
  "Return the slash command name at the start of TEXT, if present."
  (when (string-match
         (rx string-start "/" (group (+ (not (any " \t\n"))))) text)
    (match-string 1 text)))

(defun omnigent--conversation-command-arguments (text)
  "Return the arguments of slash command TEXT."
  (omnigent--conversation-command-name text)
  (string-trim (substring text (match-end 0))))

(defun omnigent--conversation-validate-command
    (text &optional no-arguments)
  "Validate command TEXT, rejecting arguments when NO-ARGUMENTS is non-nil."
  (when (string-match-p "\n" text)
    (user-error "Slash command must be on one line"))
  (when (and no-arguments
             (not
              (string-empty-p
               (omnigent--conversation-command-arguments text))))
    (user-error "/%s does not accept arguments"
                (omnigent--conversation-command-name text))))

(defun omnigent--conversation-model-command (text)
  "Apply the model command in TEXT."
  (omnigent--conversation-validate-command text)
  (let ((args (omnigent--conversation-command-arguments text)))
    (omnigent--composer-clear text)
    (if (member (downcase args) '("default" "off" "reset"))
        (omnigent--conversation-reset-setting 'model)
      (omnigent-conversation-set-model
       (unless (string-empty-p args)
         args)))))

(defun omnigent--conversation-effort-command (text)
  "Apply the effort command in TEXT."
  (omnigent--conversation-validate-command text)
  (let ((args (omnigent--conversation-command-arguments text)))
    (omnigent--composer-clear text)
    (if (equal (downcase args) "default")
        (omnigent--conversation-reset-setting 'effort)
      (omnigent-conversation-set-effort
       (unless (string-empty-p args)
         args)))))

(defun omnigent--conversation-new-command (text)
  "Start session creation for command TEXT."
  (omnigent--conversation-validate-command text t)
  (omnigent--composer-clear text)
  (call-interactively #'omnigent-sessions-create))

(defun omnigent--conversation-clear-command (text)
  "Clear the session for command TEXT."
  (omnigent--conversation-validate-command text t)
  (omnigent-conversation-clear))

(defun omnigent--conversation-compact-command (text)
  "Compact the session for command TEXT."
  (omnigent--conversation-validate-command text t)
  (omnigent--conversation-control "compact" text))

(defun omnigent--side-chat-send-question (question)
  "Put QUESTION in the side chat composer and send it when writable."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (insert question))
  (letrec ((send
            (lambda ()
              (when (omnigent-conversation-ready-p)
                (remove-hook 'omnigent-conversation-change-hook send
                             t)
                (condition-case err
                    (omnigent--conversation-message question)
                  (error
                   (message "%s" (error-message-string err))))))))
    (add-hook 'omnigent-conversation-change-hook send t t)
    (funcall send)))

(defun omnigent--conversation-side-command (text)
  "Open a side chat for command TEXT and submit its optional question."
  (omnigent--conversation-validate-command text)
  (let ((source (current-buffer))
        (question (omnigent--conversation-command-arguments text)))
    (setq omnigent-conversation--sending t)
    (condition-case err
        (omnigent-conversation-side-chat
         (lambda (status body)
           (when (and (buffer-live-p source)
                      (not
                       (buffer-local-value
                        'omnigent-conversation--invalid source)))
             (with-current-buffer source
               (setq omnigent-conversation--sending nil)
               (when (omnigent-transport-success-p status)
                 (let ((inhibit-read-only t))
                   (omnigent--composer-clear text)))))
           (if (omnigent-transport-success-p status)
               (unless (string-empty-p question)
                 (with-current-buffer body
                   (omnigent--side-chat-send-question question)))
             (message "%s"
                      (omnigent-transport-error-message
                       "Open side chat" status body)))))
      ((error quit)
       (setq omnigent-conversation--sending nil)
       (signal (car err) (cdr err))))))

(defun omnigent--conversation-unsupported-command (text)
  "Report that the command in TEXT is not supported."
  (omnigent--conversation-validate-command text)
  (message "/%s is not supported"
           (omnigent--conversation-command-name text)))

(defun omnigent--conversation-skill-command (text)
  "Fetch the skill catalog before dispatching slash command TEXT."
  (let ((name (omnigent--conversation-command-name text))
        (args (omnigent--conversation-command-arguments text)))
    (setq omnigent-conversation--sending t)
    (condition-case err
        (omnigent-transport--request
         omnigent-conversation-session-id "GET"
         (concat
          "/v1/skills?session_id="
          (url-hexify-string omnigent-conversation-session-id))
         (apply-partially #'omnigent--conversation-skills-result
                          (current-buffer) text name args))
      ((error quit)
       (setq omnigent-conversation--sending nil)
       (signal (car err) (cdr err))))))

(defconst omnigent--conversation-message-handlers
  `(("model" . ,#'omnigent--conversation-model-command)
    ("effort" . ,#'omnigent--conversation-effort-command)
    ("new" . ,#'omnigent--conversation-new-command)
    ("clear" . ,#'omnigent--conversation-clear-command)
    ("compact" . ,#'omnigent--conversation-compact-command)
    ("context" . ,#'omnigent--conversation-unsupported-command)
    ("mcp" . ,#'omnigent--conversation-unsupported-command)
    ("permissions" . ,#'omnigent--conversation-unsupported-command)
    ("btw" . ,#'omnigent--conversation-side-command)
    ("side" . ,#'omnigent--conversation-side-command)
    ("help" . ,#'omnigent--conversation-unsupported-command)
    (slash . ,#'omnigent--conversation-skill-command)
    (t . ,#'omnigent--conversation-message))
  "Command names and handlers for conversation input, in dispatch order.")

(defun omnigent--conversation-dispatch (text)
  "Dispatch composer TEXT to the first matching input handler."
  (let* ((name (omnigent--conversation-command-name text))
         (handler
          (cl-find-if
           (lambda (entry)
             (let ((predicate (car entry)))
               (cond
                ((stringp predicate)
                 (equal predicate name))
                ((eq predicate 'slash)
                 name)
                (t
                 (eq predicate t)))))
           omnigent--conversation-message-handlers)))
    (funcall (cdr handler) text)))

(defun omnigent-conversation-send ()
  "Send the composer text to the current session."
  (interactive)
  (when buffer-read-only
    (user-error "This session is read-only"))
  (when omnigent-conversation--sending
    (user-error "A message is being sent"))
  (let* ((text
          (buffer-substring-no-properties
           omnigent-conversation--prompt-start (point-max)))
         (paths (omnigent--attachment-paths))
         (bounds (omnigent--attachment-bounds))
         (omnigent--conversation-submitted-draft (and paths text)))
    (when (string-blank-p text)
      (user-error "The message is empty"))
    (if paths
        (let* ((harness
                (alist-get
                 'harness omnigent-conversation-header-data))
               (label
                (if (and (stringp harness)
                         (string-match-p "codex" harness))
                    "Attached file"
                  "Attached"))
               (message-text
                (concat
                 (mapconcat (lambda (path)
                              (format "[%s: %s]" label path))
                            paths
                            "\n")
                 "\n\n"
                 (buffer-substring-no-properties
                  omnigent-conversation--prompt-start (car bounds)))))
          (omnigent--conversation-message message-text))
      (omnigent--conversation-dispatch text))))

(defun omnigent--conversation-select-setting (setting)
  "Fetch choices for SETTING and prompt in the current conversation."
  (let ((buffer (current-buffer))
        (generation omnigent-transport--generation))
    (message "Reading %s choices..." setting)
    (omnigent-transport-get-session
     omnigent-conversation-session-id
     (lambda (status body)
       (when (and (buffer-live-p buffer)
                  (= generation omnigent-transport--generation))
         (if (not (omnigent-transport-success-p status))
             (message "%s"
                      (omnigent-transport-error-message
                       "Read session settings" status body))
           (let ((choices
                  (condition-case err
                      (omnigent-conversation--setting-choices
                       setting body)
                    (error
                     (message "%s" (error-message-string err))
                     'invalid))))
             (cond
              ((eq choices 'invalid)
               nil)
              ((not choices)
               (message
                "No %s choices are available; refresh the session and try again"
                setting))
              (t
               (with-current-buffer buffer
                 (let ((choice
                        (condition-case nil
                            (completing-read (if (eq setting 'model)
                                                 "Model: "
                                               "Effort: ")
                                             choices
                                             nil t)
                          (quit
                           nil))))
                   (when choice
                     (unless (= generation
                                omnigent-transport--generation)
                       (user-error "Server changed during selection"))
                     (if (eq setting 'model)
                         (omnigent-conversation-set-model choice)
                       (omnigent-conversation-set-effort
                        choice))))))))))))))

(defun omnigent-conversation-set-model (&optional model)
  "Change the current session's MODEL asynchronously.
When MODEL is nil, fetch the session catalog and prompt with completion."
  (interactive)
  (unless (derived-mode-p 'omnigent-conversation-mode)
    (user-error "This is not an Omnigent conversation"))
  (when buffer-read-only
    (user-error "This session is read-only"))
  (when (and model (string-blank-p model))
    (user-error "The model is empty"))
  (if (null model)
      (omnigent--conversation-select-setting 'model)
    (omnigent-transport-set-session-model
     omnigent-conversation-session-id model
     (lambda (status body)
       (if (omnigent-transport-success-p status)
           (message "Model change requested: %s" model)
         (message "%s"
                  (omnigent-transport-error-message
                   "Change model" status body)))))))

(defvar-local omnigent--effort-request-generation 0
  "Generation of the latest effort change request.")

(defun omnigent-conversation-set-effort (&optional effort)
  "Change the current session's reasoning EFFORT asynchronously.
When EFFORT is nil, prompt with the current model's supported levels."
  (interactive)
  (unless (derived-mode-p 'omnigent-conversation-mode)
    (user-error "This is not an Omnigent conversation"))
  (when buffer-read-only
    (user-error "This session is read-only"))
  (when (and effort (string-blank-p effort))
    (user-error "The effort is empty"))
  (if (null effort)
      (omnigent--conversation-select-setting 'effort)
    (let ((buffer (current-buffer))
          (generation (cl-incf omnigent--effort-request-generation))
          (server-generation omnigent-transport--generation)
          (session-id omnigent-conversation-session-id))
      (omnigent-transport-set-session-effort
       session-id effort
       (lambda (status body)
         (if (not (omnigent-transport-success-p status))
             (message "%s"
                      (omnigent-transport-error-message
                       "Change effort" status body))
           (when (and (buffer-live-p buffer)
                      (= server-generation
                         omnigent-transport--generation))
             (with-current-buffer buffer
               (when (= generation
                        omnigent--effort-request-generation)
                 (let ((previous
                        (alist-get
                         'reasoning_effort
                         omnigent-conversation-header-data)))
                   (omnigent-transport-get-session
                    session-id
                    (lambda (fetch-status session)
                      (when (and (buffer-live-p buffer)
                                 (= server-generation
                                    omnigent-transport--generation))
                        (with-current-buffer buffer
                          (when
                              (and
                               (= generation
                                  omnigent--effort-request-generation)
                               (equal
                                previous
                                (alist-get
                                 'reasoning_effort
                                 omnigent-conversation-header-data)))
                            (if (omnigent-transport-success-p
                                 fetch-status)
                                (progn
                                  (setf
                                   (alist-get
                                    'reasoning_effort
                                    omnigent-conversation-header-data)
                                   (alist-get
                                    'reasoning_effort session))
                                  (run-hooks
                                   'omnigent-conversation-change-hook))
                              (message
                               "%s"
                               (omnigent-transport-error-message
                                "Read session settings"
                                fetch-status
                                session))))))))))))))))))

(defun omnigent-conversation-interrupt ()
  "Interrupt the current session asynchronously."
  (interactive)
  (when buffer-read-only
    (user-error "This session is read-only"))
  (omnigent-transport-post-session-event
   omnigent-conversation-session-id
   '(("type" . "interrupt"))
   #'omnigent-conversation--interrupted))

(defun omnigent-ui-sessions-open ()
  "Open the session at point."
  (interactive)
  (let* ((id (omnigent-ui--session-id-at-point))
         (session (and id (omnigent-sessions-row id))))
    (unless session
      (user-error "No session at point"))
    (omnigent-ui-open id (alist-get 'title session))))

(defun omnigent-ui--project-heading ()
  "Return the position of the project heading for the current line."
  (save-excursion
    (beginning-of-line)
    (when (omnigent-ui--session-id-at-point)
      (while (and (not (bobp)) (not (omnigent-ui--project-at-point)))
        (forward-line -1)))
    (when (omnigent-ui--project-at-point)
      (point))))

(defun omnigent-ui-toggle-tree ()
  "Fold or unfold the project or session branch at point."
  (interactive)
  (let ((project (omnigent-ui--project-at-point))
        (id (omnigent-ui--session-id-at-point)))
    (cond
     (project
      (setq omnigent-ui--folded-projects
            (if (member project omnigent-ui--folded-projects)
                (delete project omnigent-ui--folded-projects)
              (cons project omnigent-ui--folded-projects)))
      (omnigent-ui-sessions-render))
     ((and id (omnigent-sessions-children id))
      (setq omnigent-ui--folded-sessions
            (if (member id omnigent-ui--folded-sessions)
                (delete id omnigent-ui--folded-sessions)
              (cons id omnigent-ui--folded-sessions)))
      (omnigent-ui-sessions-render)))))

(defalias 'omnigent-ui-toggle-project #'omnigent-ui-toggle-tree)

(defun omnigent-ui--read-project (prompt projects &optional unassign)
  "Read a project from PROJECTS with PROMPT.
When UNASSIGN is non-nil, offer to remove the project assignment."
  (let* ((generation omnigent-transport--generation)
         (choices
          (mapcar
           (lambda (row) (cons (alist-get 'name row) row)) projects))
         (choices
          (if unassign
              (cons '("[Unassigned]" . unassigned) choices)
            choices))
         (choice (completing-read prompt choices nil t)))
    (when (= generation omnigent-transport--generation)
      (cdr (assoc choice choices)))))

(defun omnigent-ui-find-project ()
  "Find a server project and load its sessions in the session list."
  (interactive)
  (unless (derived-mode-p 'omnigent-ui-sessions-mode)
    (user-error "Open the Omnigent session list first"))
  (let ((buffer (current-buffer)))
    (omnigent-sessions-read-projects
     (lambda (projects)
       (when (buffer-live-p buffer)
         (when-let* ((project
                      (omnigent-ui--read-project
                       "Find project: " projects))
                     (id (alist-get 'id project)))
           (with-current-buffer buffer
             (setq omnigent-ui--folded-projects
                   (delete id omnigent-ui--folded-projects))
             (omnigent-sessions-show-project project)
             (omnigent-sessions-fetch-project
              id
              (or
               (car (gethash id omnigent-sessions--project-lists))
               (max 1 (min 1000 omnigent-transport-session-limit))))
             (omnigent-ui-sessions-render)
             (goto-char (point-min))
             (while (and (not (eobp))
                         (not
                          (equal id (omnigent-ui--project-at-point))))
               (forward-line 1)))))))))

(defun omnigent-ui-move-session ()
  "Move the session at point to a server project."
  (interactive)
  (let ((id (omnigent-ui--session-id-at-point)))
    (unless id
      (user-error "No session at point"))
    (omnigent-sessions-read-projects
     (lambda (projects)
       (when-let* ((destination
                    (omnigent-ui--read-project
                     "Move session to: " projects
                     t)))
         (omnigent-sessions-move
          id
          (if (eq destination 'unassigned)
              ""
            (alist-get 'id destination))))))))

(define-derived-mode
 omnigent-ui-sessions-mode
 special-mode
 "Omnigent Sessions"
 "Major mode for the Omnigent session list."
 (setq-local truncate-lines t))

;;;###autoload
(defun omnigent-ui-sessions ()
  "Show or hide the Omnigent session list in a left side window."
  (interactive)
  (let ((buffer (get-buffer-create "*omnigent-sessions*")))
    (with-current-buffer buffer
      (unless (derived-mode-p 'omnigent-ui-sessions-mode)
        (omnigent-ui-sessions-mode)))
    (omnigent-ui-sessions-render)
    (if-let* ((window (get-buffer-window buffer)))
      (delete-window window)
      (display-buffer-in-side-window
       buffer
       (append
        '((side . left) (slot . -1))
        (when omnigent-side-window-width
          `((window-width . ,omnigent-side-window-width))))))))

(defun omnigent-ui-refresh ()
  "Refresh the root list and the child lists of open conversations."
  (interactive)
  (omnigent-sessions-refresh)
  (dolist (entry omnigent-sessions--buffers)
    (omnigent-sessions-refresh-children (car entry))))

(defun omnigent-ui--adjust-project-limit (amount)
  "Change the fetch limit for the project at point by AMOUNT."
  (let* ((heading (omnigent-ui--project-heading))
         (key
          (and heading
               (get-text-property heading 'omnigent-ui-project))))
    (unless key
      (user-error "No project at point"))
    (unless (or (eq key 'unassigned)
                (cl-find
                 key
                 omnigent-sessions-projects
                 :key (lambda (row) (alist-get 'id row))
                 :test #'equal))
      (user-error "Project is unavailable"))
    (let* ((current
            (or (car
                 (gethash key omnigent-sessions--project-lists))
                (cl-count
                 key
                 (omnigent-sessions-visible)
                 :key #'omnigent-sessions-project-key
                 :test #'equal)))
           (limit (max 0 (min 1000 (+ current amount)))))
      (unless (= current limit)
        (omnigent-sessions-fetch-project key limit))
      (message "Project session limit: %d" limit))))

(defun omnigent-ui-increase-session-limit (amount)
  "Increase the current project's fetch limit by AMOUNT."
  (interactive "p")
  (omnigent-ui--adjust-project-limit amount))

(defun omnigent-ui-decrease-session-limit (amount)
  "Decrease the current project's fetch limit by AMOUNT."
  (interactive "p")
  (omnigent-ui--adjust-project-limit (- amount)))

(defun omnigent-ui-toggle-archived-sessions ()
  "Toggle archived sessions in the list and refresh the session list."
  (interactive)
  (setq omnigent-fetch-archived-sessions
        (not omnigent-fetch-archived-sessions))
  (omnigent-ui-refresh)
  (message "Archived sessions %s"
           (if omnigent-fetch-archived-sessions
               "enabled"
             "disabled")))

(defun omnigent-ui-create-project ()
  "Prompt for a name and create a server project."
  (interactive)
  (let ((generation omnigent-transport--generation)
        (name (string-trim (read-string "New project name: "))))
    (when (string-empty-p name)
      (user-error "Project name is empty"))
    (unless (= generation omnigent-transport--generation)
      (user-error "Server changed during project creation"))
    (omnigent-sessions-create-project name)))

(defun omnigent-ui-rename-project ()
  "Rename the project heading at point in the session buffer."
  (interactive)
  (unless (derived-mode-p 'omnigent-ui-sessions-mode)
    (user-error "Use this command in the session buffer"))
  (let* ((id (omnigent-ui--project-at-point))
         (project
          (cl-find
           id
           omnigent-sessions-projects
           :key (lambda (row) (alist-get 'id row))
           :test #'equal))
         (generation omnigent-transport--generation))
    (unless (and (stringp id) project)
      (user-error "No server project at point"))
    (let* ((name (alist-get 'name project))
           (new-name
            (string-trim (read-string "Project name: " name))))
      (when (string-empty-p new-name)
        (user-error "Project name is empty"))
      (unless (= generation omnigent-transport--generation)
        (user-error "Server changed during project rename"))
      (unless (equal name new-name)
        (omnigent-transport-request
         "PATCH" (concat "/v1/projects/" (url-hexify-string id))
         (lambda (status body)
           (if (omnigent-transport-success-p status)
               (progn
                 (setf (alist-get 'name project) new-name)
                 (setq omnigent-sessions--project-catalog nil)
                 (run-hooks 'omnigent-sessions-change-hook))
             (omnigent-sessions--error "Rename project" status body)))
         `(("name" . ,new-name)))))))

(defun omnigent-ui-rename-at-point ()
  "Rename the project or session at point in the session buffer."
  (interactive)
  (unless (derived-mode-p 'omnigent-ui-sessions-mode)
    (user-error "Use this command in the session buffer"))
  (call-interactively
   (if (omnigent-ui--project-at-point)
       #'omnigent-ui-rename-project
     #'omnigent-ui-rename-session)))

(defun omnigent-ui-delete-project ()
  "Delete the project heading at point after confirmation."
  (interactive)
  (let ((id (omnigent-ui--project-at-point))
        (generation omnigent-transport--generation))
    (unless (stringp id)
      (user-error "No server project at point"))
    (let ((name
           (alist-get
            'name
            (cl-find
             id
             omnigent-sessions-projects
             :key (lambda (row) (alist-get 'id row))
             :test #'equal))))
      (when
          (y-or-n-p
           (format
            "Archive and unassign all sessions, then delete project %s? "
            (or name id)))
        (unless (= generation omnigent-transport--generation)
          (user-error "Server changed during project deletion"))
        (omnigent-sessions-delete-project id)))))

(defun omnigent-ui-delete-at-point ()
  "Delete the project or session at point."
  (interactive)
  (call-interactively
   (if (omnigent-ui--project-at-point)
       #'omnigent-ui-delete-project
     #'omnigent-ui-delete)))

(defun omnigent-ui-archive-at-point ()
  "Toggle archive on the session at point."
  (interactive)
  (when (omnigent-ui--project-at-point)
    (user-error "The server does not support archiving projects"))
  (omnigent-ui-archive))

(defun omnigent-ui-archive ()
  "Toggle the selected session's archived state without deleting its history."
  (interactive)
  (pcase-let* ((`(,id . ,title) (omnigent-ui--action-target))
               (buffer (current-buffer))
               (session (omnigent-sessions-row id))
               (next-id
                (when (and (derived-mode-p 'omnigent-ui-sessions-mode)
                           (not (eq (alist-get 'archived session) t)))
                  (save-excursion
                    (forward-line 1)
                    (or (omnigent-ui--session-id-at-point)
                        (progn
                          (forward-line -2)
                          (omnigent-ui--session-id-at-point)))))))
    (omnigent-sessions-toggle-archive
     id
     (lambda (status body)
       (when (and next-id
                  (omnigent-transport-success-p status)
                  (buffer-live-p buffer))
         (with-current-buffer buffer
           (when (equal id (omnigent-ui--session-id-at-point))
             (goto-char (point-min))
             (while (and (not (eobp))
                         (not
                          (equal
                           next-id
                           (omnigent-ui--session-id-at-point))))
               (forward-line 1))
             (when (eobp)
               (goto-char (point-min))))))
       (omnigent-ui--action-result
        "Toggle archive" title status body)))))

(defun omnigent-ui-rename-session ()
  "Change the title of the current session or the session at point."
  (interactive)
  (pcase-let* ((`(,id . ,title) (omnigent-ui--action-target))
               (new-title (read-string "Session title: " title)))
    (unless (equal title new-title)
      (omnigent-transport--request
       id "PATCH" (omnigent-transport--session-path id)
       (lambda (status body)
         (if (omnigent-transport-success-p status)
             (omnigent-sessions-refresh)
           (omnigent-ui--action-result "Rename" title status body)))
       `(("title" . ,new-title))))))

(defun omnigent-ui-generate-session-title ()
  "Generate a title for the current session or the session at point.
Use a private side chat on the source runner to read the conversation."
  (interactive)
  (pcase-let ((`(,id . ,title) (omnigent-ui--action-target)))
    (message "Generating title...")
    (omnigent-side-chat-ask
     id
     "Write a short session title based on the recent conversation before this request. Return only the title on one line, without quotes or markup. Do not use tools."
     (apply-partially #'omnigent--apply-generated-session-title
                      id title))))

(defun omnigent--apply-generated-session-title (id title status body)
  "Apply BODY to session ID, currently TITLE, if STATUS indicates success."
  (let ((new-title
         (and (omnigent-transport-success-p status)
              (string-trim body))))
    (cond
     ((not new-title)
      (omnigent-ui--action-result
       "Generate title for" title status body))
     ((or (string-empty-p new-title)
          (string-match-p "[[:cntrl:]]" new-title))
      (omnigent-ui--action-result
       "Generate title for"
       title
       nil
       "The side chat did not return a single-line title"))
     (t
      (omnigent-transport--request
       id "PATCH" (omnigent-transport--session-path id)
       (lambda (patch-status patch-body)
         (if (omnigent-transport-success-p patch-status)
             (progn
               (when (equal (current-message) "Generating title...")
                 (message nil))
               (omnigent-sessions-refresh))
           (omnigent-ui--action-result
            "Rename" title patch-status patch-body)))
       `(("title" . ,new-title)))))))

(defun omnigent-side-chat-ask (id question callback &optional on-send)
  "Ask QUESTION in a private fork of ID without opening a buffer.
Call CALLBACK with (STATUS BODY).  On success BODY is the final assistant
message text.  On failure BODY contains diagnostics.  Call ON-SEND, if
non-nil, immediately before posting the question."
  (omnigent-sessions-side-chat
   id
   (lambda (status body)
     (if (omnigent-transport-success-p status)
         (omnigent--side-chat-ask
          (alist-get 'id body) question callback on-send)
       (funcall callback status body)))))

(defun omnigent--side-chat-ask (child question callback on-send)
  "Post QUESTION to private fork CHILD and report its answer to CALLBACK.
Call ON-SEND, if non-nil, when the fork is ready to submit the question."
  (let (stream
        timer
        connected
        snapshot
        sandbox-stage
        sent
        response-id
        answer
        finished)
    (cl-labels
     ((finish
       (status body) "Close the stream and report the result once."
       (unless finished
         (setq finished t)
         (when timer
           (cancel-timer timer))
         (when stream
           (omnigent-transport-stop-session-stream stream))
         (funcall callback status body)))
      (send
       () "Send the question once the fork can accept a message."
       (when (and (not sent)
                  (not finished)
                  (omnigent-transport--session-write-ready-p
                   connected snapshot nil
                   (and sandbox-stage
                        (not (equal sandbox-stage "ready")))))
         (setq sent t)
         (condition-case err
             (progn
               (when on-send
                 (funcall on-send))
               (omnigent-transport-post-session-event
                child
                (omnigent-transport--user-message-event question)
                (lambda (status body)
                  (unless (omnigent-transport-success-p status)
                    (finish status body)))))
           (error
            (finish nil (error-message-string err))))))
      (event
       (name data)
       "Track sandbox readiness and collect the matching assistant answer."
       (when (and (equal name "session.sandbox_status")
                  (stringp (alist-get 'stage data)))
         (setq sandbox-stage (alist-get 'stage data))
         (send))
       (when (and sent (not finished))
         (let* ((status (alist-get 'status data))
                (response (alist-get 'response data))
                (event-id
                 (or (alist-get 'response_id data)
                     (alist-get 'id response)))
                (item
                 (omnigent-transport--output-item
                  (alist-get 'item data))))
           (cond
            ((or (and (equal name "session.status")
                      (equal status "running"))
                 (and (not response-id)
                      (member
                       name
                       '("response.created" "response.in_progress"))))
             (let ((id
                    (omnigent-transport--starting-response-id data)))
               (when (and id (not (equal id response-id)))
                 (setq
                  response-id id
                  answer nil))))
            ((and (equal name "response.output_item.done")
                  response-id
                  (equal
                   response-id
                   (or (alist-get 'response_id item)
                       event-id
                       response-id))
                  (equal (alist-get 'type item) "message")
                  (equal (alist-get 'role item) "assistant"))
             (setq answer (omnigent-conversation--text item)))
            ((and response-id (equal event-id response-id))
             (cond
              ((or (and (equal name "session.status")
                        (equal status "idle"))
                   (and (equal name "response.completed")
                        (not
                         (seq-empty-p (alist-get 'output response)))))
               (if (and answer (not (string-blank-p answer)))
                   (finish 200 answer)
                 (finish
                  nil "The side chat did not return an answer")))
              ((or (and (equal name "session.status")
                        (equal status "failed"))
                   (member
                    name
                    '("response.failed"
                      "response.incomplete"
                      "response.cancelled")))
               (finish
                nil
                (or (alist-get 'error data)
                    "The side chat turn failed"))))))))))
     (condition-case err
         (progn
           (setq stream
                 (omnigent-transport-start-session-stream
                  child #'event
                  (lambda (status body)
                    (cond
                     ((not (omnigent-transport-success-p status))
                      (finish status body))
                     ((equal (alist-get 'permission_level body) 1)
                      (finish nil "The side chat is read-only"))
                     (t
                      (let ((stage
                             (alist-get
                              'stage
                              (alist-get 'sandbox_status body))))
                        (setq
                         snapshot t
                         sandbox-stage (or sandbox-stage stage))
                        (send)))))
                  (lambda (error) (finish nil error)) nil
                  (lambda (state)
                    (pcase state
                      ('connected
                       (setq connected t)
                       (send))
                      ('disconnected
                       (finish nil "The side chat disconnected"))))
                  t))
           (if finished
               (omnigent-transport-stop-session-stream stream)
             (setq timer
                   (run-at-time 120 nil #'finish
                                nil
                                "The side chat timed out"))))
       (error
        (finish nil (error-message-string err)))))))

(defun omnigent-ui-delete ()
  "Delete the selected session and its descendants after confirmation."
  (interactive)
  (pcase-let ((`(,id . ,title) (omnigent-ui--action-target)))
    (when
        (y-or-n-p
         (format
          "Permanently delete session %s and all its child sessions? "
          title))
      (omnigent-sessions-delete
       id
       (apply-partially #'omnigent-ui--action-result
                        "Delete" title)))))

(define-derived-mode
 omnigent-ui-workspace-mode
 special-mode
 "Omnigent Workspace"
 "Show changed workspace-relative paths for one session."
 (setq-local truncate-lines t))

(defun omnigent-ui-workspace ()
  "Show or hide the selected session's workspace panel."
  (interactive)
  (unless omnigent-ui--selected-session
    (user-error "Select a session first"))
  (if omnigent-ui--workspace-visible
      (progn
        (omnigent-ui--workspace-hide)
        (setq omnigent-ui--workspace-closed t))
    (setq
     omnigent-ui--workspace-closed nil
     omnigent-ui--workspace-visible t)
    (omnigent-ui--workspace-display)
    (omnigent-ui-workspace-refresh)))

(defun omnigent-ui-workspace-refresh (&optional id)
  "Refresh workspace ID, or the current panel, coalescing concurrent requests."
  (interactive)
  (setq id
        (or id
            omnigent-ui--workspace-id
            omnigent-ui--selected-session))
  (when id
    (if (gethash id omnigent-ui--workspace-pending)
        (puthash id t omnigent-ui--workspace-again)
      (let ((token (make-symbol "workspace-fetch")))
        (puthash id token omnigent-ui--workspace-pending)
        (condition-case nil
            (omnigent-workspace-list
             id
             (apply-partially
              #'omnigent-ui--workspace-result
              id omnigent-transport--generation token))
          (error
           (remhash id omnigent-ui--workspace-pending)))))))

(defun omnigent-ui-workspace-diff ()
  "Fetch a fresh file or combined diff for the selected workspace row."
  (interactive)
  (let ((id omnigent-ui--workspace-id)
        (path
         (get-text-property
          (line-beginning-position) 'omnigent-ui-path)))
    (unless (and id path)
      (user-error "No changed file at point"))
    (let ((callback
           (apply-partially #'omnigent-ui--diff-result id path)))
      (condition-case nil
          (if (eq path :all)
              (omnigent-workspace-diff id callback)
            (omnigent-workspace-file-diff id path callback))
        (error
         nil)))))

(defun omnigent-ui-workspace-visit-file ()
  "Visit the changed file at point in its workspace."
  (interactive)
  (let ((id omnigent-ui--workspace-id)
        (path
         (get-text-property
          (line-beginning-position) 'omnigent-ui-path)))
    (unless (and id (stringp path))
      (user-error "No changed file at point"))
    (find-file (omnigent-ui--workspace-filename id path))))

(defun omnigent-ui-workspace-magit-status ()
  "Open Magit status for the workspace of the current diff buffer."
  (interactive)
  (unless omnigent-ui--workspace-id
    (user-error "No workspace for this buffer"))
  (unless (require 'magit nil t)
    (user-error "Magit is not installed"))
  (magit-status
   (file-name-as-directory
    (omnigent-ui--workspace-filename omnigent-ui--workspace-id ""))))

(provide 'omnigent)
;;; omnigent.el ends here
