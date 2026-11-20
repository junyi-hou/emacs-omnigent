;;; omnigent-sessions-test.el --- Session state checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'omnigent)

(ert-deftest omnigent-sessions-fork-and-launch ()
  "Send fork options and launch a worktree on the source host."
  (let (requests
        opened)
    (cl-letf (((symbol-function 'omnigent-transport--request)
               (lambda (_session-id
                        method path callback &optional data)
                 (push (list method path data) requests)
                 (funcall callback
                          201
                          '((id . "fork") (title . "Fork")))))
              ((symbol-function 'omnigent-sessions-refresh) #'ignore)
              ((symbol-function 'omnigent-ui-created)
               (lambda (session) (setq opened session))))
      (with-temp-buffer
        (setq
         major-mode 'omnigent-conversation-mode
         omnigent-conversation-session-id "source"
         omnigent-conversation-host-id "host"
         omnigent-conversation-header-data '((workspace . "/repo")))
        (cl-letf (((symbol-function 'omnigent--fork-menu) #'ignore)
                  ((symbol-function 'read-string)
                   (lambda (&rest _) "feature")))
          (omnigent-conversation-fork t)
          (should-not requests)
          (omnigent--fork-branch)
          (setf (alist-get 'up_to_response_id omnigent--fork-draft)
                "resp")
          (omnigent--fork-submit)))
      (setq requests (nreverse requests))
      (should (equal (cadar requests) "/v1/sessions/source/fork"))
      (should
       (equal
        (nth 2 (car requests)) '(("up_to_response_id" . "resp"))))
      (should (equal (cadr (cadr requests)) "/v1/hosts/host/runners"))
      (should
       (equal
        (nth 2 (cadr requests))
        '(("session_id" . "fork")
          ("workspace" . "/repo")
          ("git" ("branch_name" . "feature")))))
      (should (equal (alist-get 'id opened) "fork")))))

(ert-deftest omnigent-sessions-managed-fork-opens-during-provisioning
    ()
  "A managed fork opens by ID and lets the server launch its runner."
  (let (opened
        options)
    (cl-letf (((symbol-function 'omnigent--create-read-profile)
               (lambda (_draft callback &rest _options)
                 (funcall callback)))
              ((symbol-function 'omnigent-sessions-fork)
               (lambda (id data callback)
                 (should (equal id "source"))
                 (setq options data)
                 (funcall callback 201 '((id . "fork")))))
              ((symbol-function 'omnigent-sessions-launch-fork)
               (lambda (&rest _)
                 (ert-fail "Managed fork launched a host runner")))
              ((symbol-function 'omnigent-sessions-refresh) #'ignore)
              ((symbol-function 'omnigent-ui-created)
               (lambda (session) (setq opened session))))
      (with-temp-buffer
        (setq
         major-mode 'omnigent-conversation-mode
         omnigent-conversation-session-id "source"
         omnigent-conversation--managed t)
        (omnigent-conversation-fork nil))
      (should (equal options '(("host_type" . "managed"))))
      (should (equal (alist-get 'id opened) "fork"))
      (should
       (equal
        (alist-get
         'stage (alist-get 'sandbox_status opened))
        "provisioning")))))

(ert-deftest omnigent-sessions-fork-launch-failure ()
  "Report the created fork ID when runner launch fails."
  (let (reported)
    (cl-letf (((symbol-function 'omnigent-sessions-refresh) #'ignore)
              ((symbol-function 'omnigent-sessions--error)
               (lambda (action _status &optional _body)
                 (setq reported action)))
              ((symbol-function 'omnigent-ui-created)
               (lambda (_session) (ert-fail "Opened failed fork"))))
      (omnigent--fork-launched '((id . "fork")) 400 "failed")
      (should (string-match-p "fork" reported)))))

(ert-deftest omnigent-sessions-side-chat-shares-runner ()
  "Create a side chat and bind it to the runner from the source snapshot."
  (let (requests
        result)
    (cl-letf (((symbol-function 'omnigent-transport--request)
               (lambda (_id method path callback &optional data)
                 (push (list method path data) requests)
                 (pcase method
                   ("GET"
                    (funcall callback 200 '((runner_id . "runner"))))
                   ("POST" (funcall callback 201 '((id . "side"))))
                   ("PATCH" (funcall callback 200 nil))))))
      (omnigent-sessions-side-chat
       "source"
       (lambda (status body) (setq result (cons status body)))))
    (should
     (equal
      (nreverse requests)
      '(("GET" "/v1/sessions/source?include_items=false" nil)
        ("POST"
         "/v1/sessions/source/fork"
         (("side_chat" . t) ("title" . "Side chat")))
        ("PATCH" "/v1/sessions/side" (("runner_id" . "runner"))))))
    (should (equal result '(200 (id . "side"))))))

(ert-deftest omnigent-conversation-side-chat-captures-display-action
    ()
  "Return a hidden buffer even after the caller's let binding ends."
  (let (finish
        result)
    (with-temp-buffer
      (let ((side (current-buffer)))
        (cl-letf (((symbol-function 'omnigent-sessions-side-chat)
                   (lambda (_id callback) (setq finish callback)))
                  ((symbol-function 'omnigent--conversation-buffer)
                   (lambda (_id _title side-chat)
                     (should side-chat)
                     side))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (&rest _)
                     (ert-fail "Displayed hidden side chat"))))
          (with-temp-buffer
            (setq major-mode 'omnigent-conversation-mode)
            (let ((omnigent-side-chat-display-action nil))
              (omnigent-conversation-side-chat
               (lambda (status body)
                 (setq result (cons status body))))))
          (funcall finish 201 '((id . "side")))
          (should (equal result (cons 201 side))))))))

(ert-deftest omnigent-conversation-side-chat-skips-skill-completion ()
  "Fetch the skill catalog on connect only for a regular conversation."
  (dolist (side-chat '(nil t))
    (let ((omnigent--conversation-opening-side-chat side-chat)
          (omnigent-conversation--session-id "session")
          requested)
      (cl-letf (((symbol-function
                  'omnigent-transport-start-session-stream)
                 (lambda (_id
                          _event
                          _snapshot
                          _error
                          _connect
                          state
                          skip-history)
                   (should (eq skip-history side-chat))
                   (funcall state 'connected)
                   nil))
                ((symbol-function 'omnigent-transport--request)
                 (lambda (_id _method path _callback &optional _data)
                   (setq requested path))))
        (with-temp-buffer
          (omnigent-conversation-mode)
          (should
           (equal
            requested
            (unless side-chat
              "/v1/skills?session_id=session"))))))))

(ert-deftest omnigent-sessions-frames-and-watch-limit ()
  (let ((omnigent-sessions '(((id . "one") (title . "old"))))
        (omnigent-sessions--buffers nil)
        (omnigent-sessions-updates nil)
        (omnigent-sessions-change-hook nil)
        (omnigent-sessions-frame-hook nil)
        (refreshes 0))
    (cl-letf (((symbol-function 'omnigent-sessions-refresh)
               (lambda () (cl-incf refreshes))))
      (omnigent-sessions--frame
       '((type . "changed")
         (items . [((id . "one") (title . "new"))])))
      (should
       (equal (alist-get 'title (car omnigent-sessions)) "new"))
      (omnigent-sessions--frame
       '((type . "changed") (items . [((id . "child"))])))
      (should (= refreshes 1))
      (omnigent-sessions--frame '((type . "removed") (ids . ["one"])))
      (should-not omnigent-sessions)
      (let ((buffers
             (cl-loop
              for
              n
              below
              501
              collect
              (generate-new-buffer (format " *session-%d*" n)))))
        (unwind-protect
            (progn
              (cl-loop
               for buffer in buffers for n from 0 below 500 do
               (omnigent-sessions-register-buffer
                (number-to-string n) buffer))
              (should-error
               (omnigent-sessions-register-buffer
                "501" (car (last buffers)))
               :type 'user-error)
              (kill-buffer (car buffers))
              (should (= (length omnigent-sessions--buffers) 499)))
          (mapc
           (lambda (buffer)
             (when (buffer-live-p buffer)
               (kill-buffer buffer)))
           buffers))))))

(ert-deftest omnigent-sessions-refresh-and-create ()
  "Apply root-session data and create a session from the selected target."
  (let ((omnigent-sessions nil)
        (omnigent-sessions-truncated nil)
        (omnigent-sessions--refresh-number 0)
        (omnigent-sessions--revision 0)
        (omnigent-sessions-change-hook nil)
        (omnigent-sessions-open-hook nil)
        created
        post-data)
    (cl-letf (((symbol-function 'omnigent-sessions--read-workspace)
               (lambda (callback)
                 (funcall callback '("host-b" . "/srv/project"))))
              ((symbol-function 'omnigent-transport-list-sessions)
               (lambda (callback &optional project _limit)
                 (funcall callback
                          200
                          (if project
                              '((has_more . :json-false))
                            '((data
                               .
                               [((id . "root"))
                                ((id . "child")
                                 (parent_session_id . "root"))])
                              (has_more . t))))))
              ((symbol-function 'omnigent-transport--request)
               (lambda (_session-id
                        method _path callback &optional data)
                 (if (equal method "GET")
                     (funcall callback
                              200
                              '((data
                                 .
                                 [((id . "agent")
                                   (name . "Agent"))])))
                   (setq post-data data)
                   (funcall callback 201 '((id . "new"))))))
              ((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (should (equal choices '(("Agent" . "agent"))))
                 "Agent"))
              ((symbol-function 'read-string) (lambda (&rest _) "")))
      (setq omnigent-sessions-open-hook
            (list (lambda (session) (setq created session))))
      (omnigent-sessions-refresh)
      (should omnigent-sessions-truncated)
      (should (= (length omnigent-sessions) 1))
      (omnigent-sessions-create)
      (should (equal (cdr (assoc "agent_id" post-data)) "agent"))
      (should (equal (cdr (assoc "host_id" post-data)) "host-b"))
      (should
       (equal (cdr (assoc "workspace" post-data)) "/srv/project"))
      (should (equal (alist-get 'id created) "new")))))

(ert-deftest omnigent-sessions-create-from-project-heading ()
  "Send the project at point with a new session in both creation paths."
  (let ((omnigent-session-default-host-type "external")
        (omnigent-session-default-host "host")
        (omnigent-session-default-workspace "/repo")
        (omnigent-session-default-agent "Agent")
        payload
        menu)
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (_method path callback &optional data)
                 (cond
                  ((equal path "/v1/agents")
                   (funcall callback
                            200
                            '((data . [])
                              (has_more . t)
                              (last_id . "cursor"))))
                  ((equal path "/v1/agents?after=cursor")
                   (funcall callback
                            200
                            '((data
                               .
                               [((id . "agent") (name . "Agent"))]))))
                  (t
                   (setq payload data)))))
              ((symbol-function 'omnigent--create-menu)
               (lambda () (setq menu omnigent--create-draft))))
      (with-temp-buffer
        (setq major-mode 'omnigent-ui-sessions-mode)
        (insert
         (propertize "Project" 'omnigent-ui-project "project-1"))
        (goto-char (point-min))
        (omnigent-sessions-create)
        (should
         (equal (cdr (assoc "project_id" payload)) "project-1"))
        (should (equal (cdr (assoc "agent_id" payload)) "agent"))
        (should-not (assoc "agent_reference" payload))
        (omnigent-sessions-create '(4))
        (should
         (equal (alist-get 'project_id (cdr menu)) "project-1"))
        (put-text-property
         (point-min) (point-max) 'omnigent-ui-project 'unassigned)
        (setq payload nil)
        (omnigent-sessions-create)
        (should-not (assoc "project_id" payload))))))

(ert-deftest omnigent-sessions-create-from-file-uses-buffer-workspace
    ()
  "Send the project root or buffer directory without a server project."
  (let ((omnigent-session-default-host-type "managed")
        (omnigent-session-default-host nil)
        (omnigent-session-default-workspace "/configured")
        (omnigent-session-default-worktree-branch "new-branch")
        root)
    (cl-letf (((symbol-function 'project-current)
               (lambda (&rest _) (and root (cons 'transient root))))
              ((symbol-function 'omnigent-sessions--read-workspace)
               (lambda (callback _session _host workspace)
                 (funcall callback (cons "host" workspace))))
              ((symbol-function 'omnigent-workspace-host-mapping)
               (lambda (_host) 'local))
              ((symbol-function 'omnigent--create-resolve)
               (lambda (draft &rest _)
                 (let ((fields (cdr draft)))
                   (should
                    (equal (alist-get 'host_type fields) "external"))
                   (should (equal (alist-get 'host_id fields) "host"))
                   (should
                    (equal
                     (alist-get 'workspace fields)
                     (or root default-directory)))
                   (should-not (assq 'project_id fields))
                   (should-not (alist-get 'git fields))))))
      (with-temp-buffer
        (setq default-directory "/repo/subdir/")
        (should-error
         (omnigent-sessions-create-from-file)
         :type 'user-error)
        (setq
         buffer-file-name "/repo/subdir/file"
         root "/repo/")
        (omnigent-sessions-create-from-file)
        (setq root nil)
        (omnigent-sessions-create-from-file)))))

(ert-deftest omnigent-sessions-create-prefix-uses-same-defaults ()
  "Use the same draft for quick creation and the menu."
  (let ((omnigent-session-default-agent "configured")
        quick
        menu)
    (cl-letf (((symbol-function 'omnigent--create-resolve)
               (lambda (draft &optional session menu)
                 (should-not session)
                 (should menu)
                 (setq quick draft)))
              ((symbol-function 'omnigent--create-menu)
               (lambda () (setq menu omnigent--create-draft))))
      (with-temp-buffer
        (setq
         major-mode 'omnigent-conversation-mode
         omnigent-conversation-host-id "host-a"
         omnigent-conversation-header-data '((workspace . "/repo")))
        (omnigent-sessions-create)
        (omnigent-sessions-create '(4))
        (should (equal quick menu))
        (should (equal (alist-get 'host_id (cdr menu)) "host-a"))
        (should (equal (alist-get 'workspace (cdr menu)) "/repo"))
        (should
         (equal
          (alist-get 'agent_reference (cdr menu)) "configured"))))))

(ert-deftest omnigent-sessions-create-managed-uses-configured-defaults
    ()
  "Create a managed session without prompting for a connected host."
  (let ((omnigent-session-default-host-type "managed")
        (omnigent-session-default-agent "agent")
        (omnigent-session-default-model "model")
        request)
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (method path callback &optional payload)
                 (cond
                  ((equal path "/v1/agents")
                   (funcall callback
                            200
                            '((data
                               .
                               [((id . "agent") (name . "Agent"))]))))
                  ((equal path "/v1/info")
                   (funcall callback
                            200
                            '((sandbox_provider . "provider"))))
                  ((equal
                    path "/v1/sandbox-profiles?provider=provider")
                   (funcall callback 200 '((managed_providers . []))))
                  (t
                   (setq request (list method path payload)))))))
      (omnigent-sessions-create)
      (should (equal (car request) "POST"))
      (should (equal (cadr request) "/v1/sessions"))
      (should
       (equal (cdr (assoc "host_type" (caddr request))) "managed"))
      (should
       (equal (cdr (assoc "model_override" (caddr request))) "model"))
      (should-not (assoc "sandbox_provider" (caddr request)))
      (should-not (assoc "host_id" (caddr request))))))

(ert-deftest omnigent-sessions-create-picks-required-sandbox-profile
    ()
  "Use completion for a required profile and send its exact revision."
  (let ((omnigent-session-default-host-type "managed")
        (omnigent-session-default-agent "Agent")
        payload)
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (_method path callback &optional data)
                 (cond
                  ((equal path "/v1/agents")
                   (funcall callback
                            200
                            '((data
                               .
                               [((id . "agent") (name . "Agent"))]))))
                  ((equal path "/v1/info")
                   (funcall callback
                            200
                            '((sandbox_provider . "provider"))))
                  ((equal
                    path "/v1/sandbox-profiles?provider=provider")
                   (funcall callback
                            200
                            '((managed_providers . ["provider"])
                              (profiles
                               .
                               [((name . "Profile")
                                 (id . "profile")
                                 (revision . "revision"))]))))
                  ((equal path "/v1/sessions")
                   (setq payload data))
                  (t
                   (ert-fail path)))))
              ((symbol-function 'completing-read)
               (lambda (prompt choices &rest _)
                 (should (equal prompt "Sandbox profile: "))
                 (caar choices))))
      (omnigent-sessions-create)
      (should
       (equal (cdr (assoc "sandbox_profile_id" payload)) "profile"))
      (should
       (equal
        (cdr (assoc "sandbox_profile_revision" payload)) "revision"))
      (should-not (assoc "sandbox_provider" payload)))))

(ert-deftest omnigent-sessions-create-canceled-location-restores-menu
    ()
  "Cancel host or workspace selection without changing the menu draft."
  (dolist (hosts
           '([((host_id . "one") (status . "online"))]
             [((host_id . "one") (status . "online"))
              ((host_id . "two") (status . "online"))]))
    (let* ((draft
            (list omnigent-transport--generation '(title . "Draft")))
           (omnigent--create-draft draft)
           restored)
      (cl-letf (((symbol-function 'omnigent-transport-request)
                 (lambda (method path callback &optional _data)
                   (should (equal method "GET"))
                   (should (equal path "/v1/hosts"))
                   (funcall callback 200 (list (cons 'hosts hosts)))))
                ((symbol-function
                  'omnigent-sessions--workspace-directories)
                 (lambda (_host _path callback &rest _args)
                   (funcall callback 200 nil)))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) (signal 'quit nil)))
                ((symbol-function 'omnigent--create-menu)
                 (lambda () (setq restored omnigent--create-draft))))
        (omnigent--create-submit)
        (should (eq restored draft))
        (should (equal (cdr draft) '((title . "Draft"))))))))

(ert-deftest omnigent-sessions-refreshes-after-reconnect ()
  (let (opened
        (count 0)
        (omnigent-sessions-updates nil))
    (cl-letf (((symbol-function
                'omnigent-transport-start-session-updates)
               (lambda (_frame _error open)
                 (setq opened open)
                 'handle))
              ((symbol-function 'omnigent-sessions-refresh)
               (lambda () (cl-incf count))))
      (omnigent-sessions-start)
      (funcall opened)
      (funcall opened)
      (should (= count 3)))))

(ert-deftest omnigent-sessions-refresh-ignores-out-of-order-responses
    ()
  "An older list response cannot replace the latest list or report errors."
  (let ((omnigent-sessions nil)
        (omnigent-sessions-truncated nil)
        (omnigent-sessions--refresh-number 0)
        (omnigent-sessions--revision 0)
        (changes 0)
        errors
        callbacks
        (omnigent-sessions-change-hook nil)
        (omnigent-sessions-error-hook nil))
    (setq
     omnigent-sessions-change-hook
     (list (lambda () (cl-incf changes)))
     omnigent-sessions-error-hook (list (lambda (error) (push error errors))))
    (cl-letf (((symbol-function 'omnigent-transport-list-sessions)
               (lambda (callback) (push callback callbacks))))
      (omnigent-sessions-refresh)
      (omnigent-sessions-refresh)
      (funcall (car callbacks) 200 '((data . [((id . "new"))])))
      (funcall (cadr callbacks)
               200
               '((data . [((id . "old"))]) (has_more . t)))
      (funcall (cadr callbacks) 500 nil)
      (should (equal omnigent-sessions '(((id . "new")))))
      (should-not omnigent-sessions-truncated)
      (should (= changes 1))
      (should-not errors))))

(ert-deftest omnigent-sessions-refresh-retries-after-update ()
  "A frame during a pending list request invalidates that list response."
  (let ((omnigent-sessions '(((id . "one") (title . "initial"))))
        (omnigent-sessions-truncated nil)
        (omnigent-sessions--refresh-number 0)
        (omnigent-sessions--revision 0)
        (omnigent-sessions-change-hook nil)
        (omnigent-sessions-frame-hook nil)
        callbacks)
    (cl-letf (((symbol-function 'omnigent-transport-list-sessions)
               (lambda (callback) (push callback callbacks))))
      (omnigent-sessions-refresh)
      (omnigent-sessions--frame
       '((type . "changed")
         (items . [((id . "one") (title . "updated"))])))
      (funcall (car callbacks)
               200
               '((data . [((id . "one") (title . "stale"))])))
      (should (= (length callbacks) 2))
      (should
       (equal (alist-get 'title (car omnigent-sessions)) "updated"))
      (funcall (car callbacks)
               200
               '((data . [((id . "one") (title . "fresh"))])))
      (should
       (equal (alist-get 'title (car omnigent-sessions)) "fresh")))))

(ert-deftest omnigent-sessions-create-reports-agent-list-failure ()
  "Do not prompt or create a session if agent lookup fails."
  (dolist
      (case
       '((nil 500 nil "List agents: 500")
         (nil 200 ((data . [])) "Create session: No agents available")
         ("Agent"
          200
          ((data . []))
          "Create session: client error (No agent matches the configured default \"Agent\".)")
         ("Agent" 200
          ((data
            .
            [((id . "a") (name . "Agent"))
             ((id . "b") (name . "Agent"))]))
          "Create session: client error (Multiple agents named \"Agent\". Set the default to an agent ID.)")))
    (pcase-let ((`(,reference ,status ,body ,expected-error) case))
      (let ((omnigent-session-default-agent reference)
            errors
            requests
            menu
            (omnigent-sessions-error-hook nil))
        (setq omnigent-sessions-error-hook
              (list (lambda (error) (push error errors))))
        (cl-letf (((symbol-function
                    'omnigent-sessions--read-workspace)
                   (lambda (callback)
                     (funcall callback '("host-b" . "/srv/project"))))
                  ((symbol-function 'omnigent-transport--request)
                   (lambda (_session-id
                            method path callback &optional _data)
                     (push (list method path) requests)
                     (funcall callback status body)))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _)
                     (ert-fail "Unexpected agent prompt")))
                  ((symbol-function 'omnigent--create-menu)
                   (lambda () (setq menu t)))
                  ((symbol-function 'read-string)
                   (lambda (&rest _)
                     (ert-fail "Unexpected title prompt")))
                  ((symbol-function 'omnigent-sessions-refresh)
                   (lambda () (ert-fail "Unexpected refresh"))))
          (omnigent-sessions-create)
          (should (equal requests '(("GET" "/v1/agents"))))
          (should (equal errors (list expected-error)))
          (should (eq menu (and reference t))))))))

(ert-deftest
    omnigent-sessions-create-includes-title-and-handles-result
    ()
  "Send the selected agent and title; refresh on success and failure."
  (dolist (status '(201 500))
    (let ((omnigent-session-default-title "My session")
          (omnigent-sessions-open-hook nil)
          (omnigent-sessions-error-hook nil)
          (refreshes 0)
          errors
          opened
          callback
          payload
          requests
          (session '((id . "new") (title . "My session"))))
      (setq
       omnigent-sessions-open-hook
       (list (lambda (value) (push value opened)))
       omnigent-sessions-error-hook (list (lambda (error) (push error errors))))
      (cl-letf (((symbol-function 'omnigent-sessions--read-workspace)
                 (lambda (callback)
                   (funcall callback '("host-b" . "/srv/project"))))
                ((symbol-function 'omnigent--create-menu) #'ignore)
                ((symbol-function 'omnigent-transport--request)
                 (lambda (_session-id method path cb &optional data)
                   (push (list method path) requests)
                   (if (equal method "GET")
                       (funcall cb
                                200
                                '((data
                                   .
                                   [((id . "agent-a")
                                     (name . "Agent"))
                                    ((id . "agent-b")
                                     (name . "Agent"))])))
                     (setq
                      callback cb
                      payload data))))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) "Agent [agent-b]"))
                ((symbol-function 'read-string)
                 (lambda (&rest _) "My session"))
                ((symbol-function 'omnigent-sessions-refresh)
                 (lambda () (cl-incf refreshes))))
        (omnigent-sessions-create)
        (should
         (equal
          (reverse requests)
          '(("GET" "/v1/agents") ("POST" "/v1/sessions"))))
        (should (equal (cdr (assoc "title" payload)) "My session"))
        (should (equal (cdr (assoc "agent_id" payload)) "agent-b"))
        (should (equal (cdr (assoc "host_id" payload)) "host-b"))
        (should
         (equal (cdr (assoc "workspace" payload)) "/srv/project"))
        (should (= refreshes 0))
        (should-not opened)
        (should-not errors)
        (funcall callback
                 status
                 (if (= status 201)
                     session
                   '((detail . "Create denied"))))
        (should (= refreshes 1))
        (if (= status 201)
            (progn
              (should (equal opened (list session)))
              (should-not errors))
          (should-not opened)
          (should
           (equal
            errors '("Create session: 500 (Create denied)"))))))))

(ert-deftest
    omnigent-sessions-create-selects-host-and-workspace-separately
    ()
  "Change the host without opening a workspace prompt, then use that host."
  (let ((omnigent--create-draft
         (list
          omnigent-transport--generation
          (cons 'host_id "old")
          (cons 'workspace "/old")
          (list 'git (cons 'branch_name "feature"))))
        (menu-count 0))
    (cl-letf (((symbol-function 'omnigent--create-menu)
               (lambda () (cl-incf menu-count)))
              ((symbol-function 'omnigent-transport-request)
               (lambda (method path callback)
                 (should
                  (equal (list method path) '("GET" "/v1/hosts")))
                 (funcall callback
                          200
                          '((hosts
                             .
                             [((host_id . "new")
                               (status . "online"))]))))))
      (omnigent--create-host)
      (should
       (equal
        (alist-get 'host_id (cdr omnigent--create-draft)) "new"))
      (should-not (alist-get 'workspace (cdr omnigent--create-draft)))
      (should-not (alist-get 'git (cdr omnigent--create-draft)))
      (should (= menu-count 1))
      (cl-letf (((symbol-function 'omnigent-sessions--read-workspace)
                 (lambda (callback _session host workspace)
                   (should (equal host "new"))
                   (should-not workspace)
                   (funcall callback '("new" . "/new")))))
        (omnigent--create-workspace))
      (should
       (equal
        (alist-get 'workspace (cdr omnigent--create-draft)) "/new"))
      (should (= menu-count 2)))))

(ert-deftest omnigent-sessions-create-aborts-after-server-change ()
  "Do not send a selected host and workspace to a different server."
  (let ((omnigent-transport--generation 0)
        posted)
    (cl-letf (((symbol-function 'omnigent-sessions--read-workspace)
               (lambda (callback)
                 (funcall callback '("host-b" . "/srv/project"))))
              ((symbol-function 'omnigent-transport--request)
               (lambda (_session-id
                        method _path callback &optional _data)
                 (if (equal method "GET")
                     (funcall callback
                              200
                              '((data
                                 .
                                 [((id . "agent")
                                   (name . "Agent"))])))
                   (setq posted t))))
              ((symbol-function 'completing-read)
               (lambda (&rest _)
                 (cl-incf omnigent-transport--generation)
                 "Agent")))
      (should-error (omnigent-sessions-create) :type 'user-error)
      (should-not posted))))

(ert-deftest
    omnigent-sessions-toggle-archive-and-delete-forward-results
    ()
  "Refresh before forwarding successful or failed archive and delete results."
  (dolist (operation '(archive delete))
    (dolist (status '(200 202 204 500 (:error (connection-failed))))
      (let ((refreshes 0)
            request
            callback
            received
            (body '((result . "server result"))))
        (cl-letf (((symbol-function 'omnigent-transport--request)
                   (lambda (_session-id method path cb &optional data)
                     (if (equal method "GET")
                         (funcall cb 200 '((archived . :json-false)))
                       (setq
                        request (list method path data)
                        callback cb))))
                  ((symbol-function 'omnigent-sessions-refresh)
                   (lambda () (cl-incf refreshes))))
          (let ((on-result
                 (lambda (result-status result-body)
                   (should (= refreshes 1))
                   (setq received (list result-status result-body)))))
            (if (eq operation 'archive)
                (omnigent-sessions-toggle-archive "session" on-result)
              (omnigent-sessions-delete "session" on-result)))
          (should
           (equal
            request
            (if (eq operation 'archive)
                '("PATCH" "/v1/sessions/session" (("archived" . t)))
              '("DELETE" "/v1/sessions/session" nil))))
          (should (= refreshes 0))
          (should-not received)
          (funcall callback status body)
          (should (= refreshes 1))
          (should (equal (car received) status))
          (should (eq (cadr received) body)))))))

(ert-deftest omnigent-sessions-delete-closes-conversation-on-success
    ()
  "Close the session's conversation buffer after a successful delete."
  (let ((omnigent-sessions--buffers nil)
        (callback nil)
        (buffer (generate-new-buffer " *delete-session*")))
    (unwind-protect
        (progn
          (omnigent-sessions-register-buffer "session" buffer)
          (save-window-excursion
            (let ((window (split-window-right)))
              (set-window-buffer window buffer)
              (cl-letf (((symbol-function
                          'omnigent-transport-delete-session)
                         (lambda (_id cb) (setq callback cb)))
                        ((symbol-function 'omnigent-sessions-refresh)
                         #'ignore))
                (omnigent-sessions-delete "session" #'ignore)
                (should (buffer-live-p buffer))
                (funcall callback 204 nil)
                (should-not (buffer-live-p buffer))
                (should-not (window-live-p window))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest omnigent-sessions-archive-closes-conversation-on-success
    ()
  "Close the conversation buffer when a session is archived."
  (let ((omnigent-sessions--buffers nil)
        (archive-callback nil)
        (buffer (generate-new-buffer " *archive-session*")))
    (unwind-protect
        (progn
          (omnigent-sessions-register-buffer "session" buffer)
          (save-window-excursion
            (let ((window (split-window-right)))
              (set-window-buffer window buffer)
              (cl-letf (((symbol-function
                          'omnigent-transport-get-session)
                         (lambda (_id callback)
                           (funcall callback
                                    200
                                    '((archived . :json-false)))))
                        ((symbol-function
                          'omnigent-transport-set-session-archived)
                         (lambda (_id _archived callback)
                           (setq archive-callback callback)))
                        ((symbol-function 'omnigent-sessions-refresh)
                         #'ignore))
                (omnigent-sessions-toggle-archive "session" #'ignore)
                (should (buffer-live-p buffer))
                (funcall archive-callback 204 nil)
                (should-not (buffer-live-p buffer))
                (should-not (window-live-p window))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest omnigent-sessions-toggle-archive-uses-server-state ()
  "Toggle both archive states and reject failed or malformed session reads."
  (dolist (state '(t :json-false))
    (let (payload
          result)
      (cl-letf (((symbol-function 'omnigent-transport--request)
                 (lambda (_session-id
                          method _path callback &optional data)
                   (if (equal method "GET")
                       (funcall callback 200 `((archived . ,state)))
                     (setq payload (json-encode data))
                     (funcall callback 200 data))))
                ((symbol-function 'omnigent-sessions-refresh)
                 #'ignore))
        (omnigent-sessions-toggle-archive
         "session" (lambda (status _body) (setq result status)))
        (should (= result 200))
        (should
         (equal
          payload
          (if (eq state t)
              "{\"archived\":false}"
            "{\"archived\":true}"))))))
  (dolist (response
           '((403 . ((detail . "Denied")))
             (200 . ((id . "session")))))
    (let (result)
      (cl-letf (((symbol-function 'omnigent-transport-get-session)
                 (lambda (_id callback)
                   (funcall callback (car response) (cdr response))))
                ((symbol-function
                  'omnigent-transport-set-session-archived)
                 (lambda (&rest _)
                   (ert-fail "Unexpected archive update"))))
        (omnigent-sessions-toggle-archive
         "session"
         (lambda (status body) (setq result (list status body))))
        (should
         (equal
          result
          (if (= (car response) 403)
              (list 403 (cdr response))
            '(nil "Invalid session archive state"))))))))

(ert-deftest omnigent-sessions-workspace-completes-host-directories ()
  "Complete directories through the server, including pagination and nested paths."
  (let ((omnigent-server-url "https://server-a.example")
        requests
        result)
    (cl-letf
        (((symbol-function 'omnigent-transport--request)
          (lambda (_session-id method path callback &optional _data)
            (should (equal method "GET"))
            (push path requests)
            (funcall
             callback
             200
             (cond
              ((equal path "/v1/hosts")
               '((hosts
                  .
                  [((host_id . "host-b")
                    (name . "Devbox")
                    (status . "online"))])))
              ((equal path "/v1/hosts/host-b/filesystem?limit=1000")
               '((data
                  .
                  [((name . "projects")
                    (path . "/home/remote/projects")
                    (type . "directory"))
                   ((name . "readme")
                    (path . "/home/remote/readme")
                    (type . "file"))])
                 (has_more . t)))
              ((string-match-p
                "&after=%2Fhome%2Fremote%2Freadme\\'" path)
               '((data
                  .
                  [((name . "z #")
                    (path . "/home/remote/z #")
                    (type . "directory"))])))
              ((equal
                path
                "/v1/hosts/host-b/filesystem/~/projects/?limit=1000")
               '((data
                  .
                  [((name . "src")
                    (path
                     . "/home/remote/projects/src")
                    (type . "directory"))])))
              ((equal path "/v1/hosts/host-b/filesystem/?limit=1000")
               '((data
                  .
                  [((name . "srv")
                    (path . "/srv")
                    (type . "directory"))])))
              ((equal
                path
                "/v1/hosts/host-b/filesystem/srv/project%20%231?limit=1000")
               '((data . []) (has_more . :json-false)))
              (t
               (ert-fail
                (format "Unexpected filesystem query: %s" path)))))))
         ((symbol-function 'file-directory-p)
          (lambda (&rest _)
            (ert-fail "Must not inspect Emacs's filesystem")))
         ((symbol-function 'completing-read)
          (lambda (prompt table &rest options)
            (should
             (string-match-p
              "Workspace on Devbox \\[host-b\\]" prompt))
            (should-not (nth 2 options)) ; No initial directory.
            (should-not (nth 4 options)) ; No default selection.
            (should
             (eq
              (completion-metadata-get
               (completion-metadata "" table nil) 'category)
              'omnigent-workspace))
            (should (= (length requests) 3)) ; Initial home listing is already cached.
            (should
             (equal
              (all-completions "" table) '("~/" "projects/" "z #/")))
            (let ((count (length requests)))
              (should
               (equal (try-completion "pro" table) "projects/"))
              (should (= (length requests) count)))
            (should
             (equal (all-completions "projects/" table) '("" "src/")))
            (should (equal (all-completions "/" table) '("" "srv/")))
            "/srv/project #1")))
      (omnigent-sessions--read-workspace
       (lambda (target) (setq result target)))
      (should (equal result '("host-b" . "/srv/project #1")))
      (should (= (length requests) 6)))))

(ert-deftest
    omnigent-sessions-workspace-prompts-when-host-is-ambiguous
    ()
  "Use host IDs to distinguish equal names and exclude offline hosts."
  (let (prompts
        requests
        result)
    (cl-letf (((symbol-function 'omnigent-transport--request)
               (lambda (_session-id
                        _method path callback &optional _data)
                 (push path requests)
                 (funcall callback
                          200
                          (if (equal path "/v1/hosts")
                              '((hosts
                                 .
                                 [((host_id . "one")
                                   (name . "Box")
                                   (status . "online"))
                                  ((host_id . "two")
                                   (name . "Box")
                                   (status . "online"))
                                  ((host_id . "off")
                                   (name . "Box")
                                   (status . "offline"))]))
                            '((data . []))))))
              ((symbol-function 'completing-read)
               (lambda (prompt choices &rest _)
                 (push prompt prompts)
                 (if (equal prompt "Execution host: ")
                     (progn
                       (should
                        (equal
                         choices
                         '(("Box [one]" . "one")
                           ("Box [two]" . "two"))))
                       "Box [two]")
                   "repo"))))
      (omnigent-sessions--read-workspace
       (lambda (target) (setq result target)))
      (should (equal result (cons "two" (expand-file-name "~/repo"))))
      (should (= (length prompts) 2))
      (should
       (equal
        (car requests)
        (concat
         "/v1/hosts/two/filesystem"
         (expand-file-name "~/repo")
         "?limit=1000"))))))

(ert-deftest omnigent-sessions-workspace-requires-an-online-host ()
  "Report failed discovery or no online hosts without prompting."
  (dolist (response
           '((500 . ((detail . "Discovery failed")))
             (200 . ((hosts . [])))
             (200 .
                  ((hosts
                    . [((host_id . "off") (status . "offline"))])))))
    (let (errors
          (omnigent-sessions-error-hook nil))
      (setq omnigent-sessions-error-hook
            (list (lambda (error) (push error errors))))
      (cl-letf (((symbol-function 'omnigent-transport--request)
                 (lambda (_session-id
                          _method path callback &optional _data)
                   (should (equal path "/v1/hosts"))
                   (funcall callback (car response) (cdr response))))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) (ert-fail "Unexpected prompt"))))
        (omnigent-sessions--read-workspace
         (lambda (_) (ert-fail "Unexpected selection")))
        (should (= (length errors) 1))))))

(ert-deftest omnigent-sessions-workspace-validates-input-on-the-host
    ()
  "Reject empty/TRAMP input and validate typed directories through the server."
  (dolist (input '("" "/ssh:devbox:/repo/" "bad\0path"))
    (should-error
     (omnigent-sessions--native-workspace input)
     :type 'user-error))
  (dolist (path
           '("/srv/repo"
             "~/repo"
             "C:/Users/agent/repo"
             "\\\\server\\share\\repo"))
    (should (equal (omnigent-sessions--native-workspace path) path)))
  (dolist (status '(403 404 409 504 (:error (connection-failed))))
    (let (errors
          (omnigent-sessions-error-hook nil))
      (setq omnigent-sessions-error-hook
            (list (lambda (error) (push error errors))))
      (cl-letf (((symbol-function 'omnigent-transport--request)
                 (lambda (_session-id
                          _method path callback &optional _data)
                   (cond
                    ((equal path "/v1/hosts")
                     (funcall callback
                              200
                              '((hosts
                                 .
                                 [((host_id . "host")
                                   (status . "online"))]))))
                    ((equal
                      path "/v1/hosts/host/filesystem?limit=1000")
                     (funcall callback 200 '((data . []))))
                    (t
                     (funcall callback
                              status
                              '((detail
                                 . "Directory unavailable")))))))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) "/remote/path")))
        (omnigent-sessions--read-workspace
         (lambda (_) (ert-fail "Unexpected selection")))
        (should (= (length errors) 1))))))

(ert-deftest omnigent-sessions-create-waits-for-async-choices ()
  "Return between requests and prompt only after each required response arrives."
  (let ((omnigent-sessions-open-hook nil)
        requests
        callback
        opened
        (prompts 0)
        (refreshes 0))
    (setq omnigent-sessions-open-hook
          (list (lambda (session) (setq opened session))))
    (cl-letf (((symbol-function 'omnigent-transport--request)
               (lambda (_session-id method path cb &optional data)
                 (push (list method path data) requests)
                 (setq callback cb)))
              ((symbol-function 'accept-process-output)
               (lambda (&rest _)
                 (ert-fail
                  "A command must not wait for network output")))
              ((symbol-function 'completing-read)
               (lambda (prompt _choices &rest _)
                 (cl-incf prompts)
                 (if (string-prefix-p "Workspace on " prompt)
                     "repo"
                   "Agent")))
              ((symbol-function 'read-string)
               (lambda (&rest _) "Async selection"))
              ((symbol-function 'omnigent-sessions-refresh)
               (lambda () (cl-incf refreshes))))
      (omnigent-sessions-create)
      (should (equal (cadar requests) "/v1/hosts"))
      (should (= prompts 0))
      (funcall callback
               200
               '((hosts
                  . [((host_id . "host") (status . "online"))])))
      (should
       (equal
        (cadar requests) "/v1/hosts/host/filesystem?limit=1000"))
      (should (= prompts 0))
      (funcall callback 200 '((data . [])))
      (should (= prompts 1))
      (should
       (equal
        (cadar requests)
        (concat
         "/v1/hosts/host/filesystem"
         (expand-file-name "~/repo")
         "?limit=1000")))
      (funcall callback 200 '((data . [])))
      (should (equal (cadar requests) "/v1/agents"))
      (should (= prompts 1))
      (funcall callback
               200
               '((data . [((id . "agent") (name . "Agent"))])))
      (should (= prompts 2))
      (should (equal (caar requests) "POST"))
      (should
       (equal
        (cdr (assoc "workspace" (caddar requests)))
        (expand-file-name "~/repo")))
      (should-not opened)
      (should (= refreshes 0))
      (funcall callback 201 '((id . "new")))
      (should (equal opened '((id . "new"))))
      (should (= refreshes 1)))))

(ert-deftest omnigent-sessions-workspace-completion-does-not-wait ()
  "Cache asynchronous directory results without duplicate requests or late UI updates."
  (let ((requests 0)
        (updates 0)
        directory-callback
        late-callback)
    (cl-letf (((symbol-function
                'omnigent-sessions--workspace-directories)
               (lambda (_host _path callback &rest _)
                 (cl-incf requests)
                 (setq directory-callback callback)))
              ((symbol-function 'omnigent-transport--request)
               #'ignore)
              ((symbol-function 'accept-process-output)
               (lambda (&rest _)
                 (ert-fail
                  "Completion must not wait for network output")))
              ((symbol-function 'active-minibuffer-window)
               (lambda () (selected-window)))
              ((symbol-function 'minibuffer-contents-no-properties)
               (lambda () "repo/"))
              ((symbol-function 'featurep)
               (let ((original (symbol-function 'featurep)))
                 (lambda (feature &optional subfeature)
                   (if (eq feature 'vertico)
                       t
                     (funcall original feature subfeature)))))
              ((symbol-function 'vertico--exhibit)
               (lambda (&rest _)
                 (should (eq (symbol-value 'vertico--input) t))
                 (cl-incf updates)))
              ((symbol-function 'redisplay) #'ignore)
              ((symbol-function 'completing-read)
               (lambda (_prompt table &rest _)
                 (all-completions "other/partial" table)
                 (should (= requests 0))
                 (should
                  (equal
                   (completion-boundaries
                    "repo/" table nil "")
                   '(5 . 0)))
                 (should
                  (equal
                   (completion-boundaries
                    "repo/partial" table nil "")
                   '(5 . 0)))
                 (should (= requests 0))
                 (should
                  (equal (all-completions "repo/" table) '("")))
                 (should
                  (equal (all-completions "repo/" table) '("")))
                 (should (= requests 1))
                 (with-current-buffer (window-buffer
                                       (selected-window))
                   (set
                    (make-local-variable 'vertico--input)
                    '("repo/" . 5)))
                 (funcall directory-callback
                          200
                          '(((name . "src") (type . "directory"))))
                 (should (= updates 1))
                 (with-current-buffer (window-buffer
                                       (selected-window))
                   (kill-local-variable 'vertico--input))
                 (should
                  (equal
                   (all-completions "repo/" table) '("" "src/")))
                 (all-completions "other/" table)
                 (setq late-callback directory-callback)
                 "repo")))
      (omnigent-sessions--select-workspace
       omnigent-transport--generation
       "host"
       "Host"
       #'ignore
       nil
       200
       nil)
      (cl-letf (((symbol-function 'active-minibuffer-window)
                 (lambda ()
                   (ert-fail
                    "A closed prompt must ignore late results"))))
        (funcall late-callback 200 '(((name . "late"))))))))

(ert-deftest omnigent-sessions-workspace-filesystem-url-encoding ()
  "Keep home distinct from root and encode path segments and cursors."
  (dolist
      (case
       '(("" "/v1/hosts/host%20id/filesystem?limit=1000")
         ("/" "/v1/hosts/host%20id/filesystem/?limit=1000")
         ("~/a #?"
          "/v1/hosts/host%20id/filesystem/~/a%20%23%3F?limit=1000")
         ("C:\\Users\\agent"
          "/v1/hosts/host%20id/filesystem/C%3A/Users/agent?limit=1000")))
    (should
     (equal
      (omnigent-sessions--filesystem-path
       "host id" (car case))
      (cadr case))))
  (should
   (string-suffix-p
    "&after=%2Fa%20%23"
    (omnigent-sessions--filesystem-path "host" "/" "/a #"))))

(ert-deftest
    omnigent-sessions-workspace-aborts-on-server-change-and-bad-pagination
    ()
  "Do not continue discovery on another server or loop on an invalid cursor."
  (let ((omnigent-transport--generation 0)
        selected)
    (cl-letf (((symbol-function 'omnigent-transport--request)
               (lambda (_session-id &rest _)
                 (cl-incf omnigent-transport--generation))))
      (omnigent-sessions--read-workspace
       (lambda (_) (setq selected t)))
      (should-not selected)))
  (let ((omnigent-transport--generation 0))
    (cl-letf (((symbol-function 'omnigent-transport--request)
               (lambda (_session-id
                        _method path callback &optional _data)
                 (funcall callback
                          200
                          (if (equal path "/v1/hosts")
                              '((hosts
                                 .
                                 [((host_id . "host")
                                   (status . "online"))]))
                            '((data . []))))))
              ((symbol-function 'completing-read)
               (lambda (&rest _)
                 (cl-incf omnigent-transport--generation)
                 "/repo")))
      (should-error
       (omnigent-sessions--read-workspace #'ignore)
       :type 'user-error)))
  (let (result)
    (cl-letf (((symbol-function 'omnigent-transport--request)
               (lambda (_session-id
                        _method _path callback &optional _data)
                 (funcall callback
                          200
                          '((data . []) (has_more . t))))))
      (omnigent-sessions--workspace-directories
       "host"
       "/"
       (lambda (status body) (setq result (list status body))))
      (should
       (equal result '(nil "Invalid filesystem pagination"))))))

(ert-deftest
    omnigent-sessions-mutation-results-survive-refresh-failure
    ()
  "Deliver the original mutation result even when the follow-up refresh signals."
  (dolist (operation
           '(omnigent-sessions-toggle-archive
             omnigent-sessions-delete))
    (let (callback
          received)
      (cl-letf (((symbol-function
                  'omnigent-transport-set-session-archived)
                 (lambda (_id _archived cb) (setq callback cb)))
                ((symbol-function 'omnigent-transport-get-session)
                 (lambda (_id cb)
                   (funcall cb 200 '((archived . :json-false)))))
                ((symbol-function 'omnigent-transport-delete-session)
                 (lambda (_id cb) (setq callback cb)))
                ((symbol-function 'omnigent-sessions-refresh)
                 (lambda () (error "Refresh failed"))))
        (let ((on-result
               (lambda (status body)
                 (setq received (list status body)))))
          (funcall operation "id" on-result))
        (should
         (equal
          (should-error
           (funcall callback 202 '((queued . t))))
          '(error "Refresh failed")))
        (should (equal received '(202 ((queued . t))))))))
  (let ((omnigent-sessions-open-hook nil)
        opened)
    (setq omnigent-sessions-open-hook
          (list (lambda (session) (setq opened session))))
    (cl-letf (((symbol-function 'omnigent-sessions-refresh)
               (lambda () (error "Refresh failed"))))
      (should
       (equal
        (should-error
         (omnigent-sessions--created 201 '((id . "new"))))
        '(error "Refresh failed")))
      (should (equal opened '((id . "new")))))))

(ert-deftest omnigent-sessions-errors-retain-server-details ()
  "Retain server details when list, agent, and creation handlers report errors."
  (let ((omnigent-sessions--refresh-number 0)
        (omnigent-sessions--revision 0)
        (omnigent-sessions-error-hook nil)
        errors)
    (setq omnigent-sessions-error-hook
          (list (lambda (error) (push error errors))))
    (cl-letf (((symbol-function 'omnigent-sessions-refresh) #'ignore)
              ((symbol-function 'omnigent-transport-request)
               (lambda (_method _path callback)
                 (funcall callback
                          403
                          '((detail . "Access denied"))))))
      (omnigent-sessions--refreshed
       0 0 403 '((detail . "Access denied")))
      (omnigent-sessions--read-agent
       omnigent-transport--generation #'ignore)
      (omnigent-sessions--created 403 '((detail . "Access denied"))))
    (should
     (equal
      (nreverse errors)
      '("List sessions: 403 (Access denied)"
        "List agents: 403 (Access denied)"
        "Create session: 403 (Access denied)")))))

(ert-deftest omnigent-sessions-refresh-rejects-malformed-responses ()
  "Keep prior sessions and truncation state when a successful response is malformed."
  (dolist (body
           '(nil
             "not JSON"
             []
             ((unexpected . t))
             ((data . nil))
             ((data . "invalid"))
             ((data . [nil]))
             ((data . [((id . 7))]))))
    (let ((omnigent-sessions '(((id . "keep"))))
          (omnigent-sessions-truncated t)
          (omnigent-sessions--refresh-number 0)
          (omnigent-sessions--revision 0)
          (omnigent-sessions-change-hook nil)
          (omnigent-sessions-error-hook nil)
          errors
          callback
          (changes 0))
      (setq
       omnigent-sessions-change-hook
       (list (lambda () (cl-incf changes)))
       omnigent-sessions-error-hook (list (lambda (error) (push error errors))))
      (cl-letf (((symbol-function 'omnigent-transport-list-sessions)
                 (lambda (cb) (setq callback cb))))
        (omnigent-sessions-refresh)
        (funcall callback 200 body)
        (should (equal omnigent-sessions '(((id . "keep")))))
        (should omnigent-sessions-truncated)
        (should (= changes 0))
        (should (= (length errors) 1))
        ;; An explicit empty array is a valid empty list, not a malformed response.
        (funcall callback 200 '((data . []) (has_more . :json-false)))
        (should-not omnigent-sessions)
        (should-not omnigent-sessions-truncated)
        (should (= changes 1))))))

(ert-deftest omnigent-sessions-selection-rejects-malformed-responses
    ()
  "Reject missing arrays and required row fields before prompting or continuing."
  (dolist (body
           '(nil
             "not JSON"
             []
             ((data . nil))
             ((data . [nil]))
             ((data . [((id . 7))]))
             ((hosts . [((host_id . "host"))]))))
    (let ((omnigent-sessions-error-hook nil)
          (omnigent-sessions-open-hook nil)
          errors
          result)
      (setq omnigent-sessions-error-hook
            (list (lambda (error) (push error errors))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (ert-fail
                    "Malformed data must not reach a prompt")))
                ((symbol-function 'omnigent-sessions-refresh)
                 #'ignore)
                ((symbol-function 'omnigent-transport--request)
                 (lambda (_session-id
                          _method _path cb &optional _data)
                   (funcall cb 200 body))))
        (omnigent-sessions--select-host
         omnigent-transport--generation #'ignore nil 200 body)
        (omnigent-sessions--read-agent
         omnigent-transport--generation #'ignore)
        (omnigent-sessions--workspace-directories
         "host"
         "/repo"
         (lambda (status data) (setq result (list status data))))
        (omnigent-sessions--created 201 body)
        (should (= (length errors) 3))
        (should-not (car result))
        (should (stringp (cadr result)))))))

(ert-deftest omnigent-sessions-workspace-check-requires-a-listing ()
  "Do not accept a typed workspace when its successful check lacks a listing."
  (let ((omnigent-sessions-error-hook nil)
        errors
        selected)
    (setq omnigent-sessions-error-hook
          (list (lambda (error) (push error errors))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "/repo"))
              ((symbol-function 'omnigent-transport--request)
               (lambda (_session-id _method _path cb &optional _data)
                 (funcall cb 200 nil))))
      (omnigent-sessions--select-workspace
       omnigent-transport--generation
       "host"
       "Host"
       (lambda (_) (setq selected t))
       nil
       200
       nil)
      (should-not selected)
      (should (= (length errors) 1)))))


(ert-deftest
    omnigent-sessions-list-keeps-watched-roots-until-unwatched
    ()
  "Merge watched server rows outside the fetched list and drop them after close."
  (let ((omnigent-sessions '(((id . "watched") (title . "Keep"))))
        (omnigent-sessions--refresh-number 1)
        (omnigent-sessions--revision 0)
        (omnigent-sessions-change-hook nil)
        (omnigent-sessions--buffers nil))
    (with-temp-buffer
      (setq omnigent-sessions--buffers
            (list (cons "watched" (current-buffer))))
      (omnigent-sessions--refreshed
       1 0 200 '((data . [((id . "fetched"))])))
      (should
       (equal
        (mapcar
         (lambda (row) (alist-get 'id row)) omnigent-sessions)
        '("watched" "fetched")))
      (setq omnigent-sessions--buffers nil)
      (omnigent-sessions--refreshed
       1 0 200 '((data . [((id . "fetched"))])))
      (should (equal omnigent-sessions '(((id . "fetched"))))))))

(ert-deftest omnigent-sessions-watch-frame-adds-missing-root-row ()
  "Use watched snapshot rows even if the bounded REST list omitted them."
  (let ((omnigent-sessions nil)
        (omnigent-sessions-frame-hook nil)
        (omnigent-sessions-change-hook nil)
        (omnigent-sessions--buffers nil))
    (with-temp-buffer
      (setq omnigent-sessions--buffers
            (list (cons "watched" (current-buffer))))
      (cl-letf (((symbol-function 'omnigent-sessions-refresh)
                 #'ignore))
        (omnigent-sessions--frame
         '((type . "snapshot")
           (items . [((id . "watched") (title . "Keep"))])))
        (should
         (equal
          omnigent-sessions
          '(((id . "watched") (title . "Keep")))))))))

(provide 'omnigent-sessions-test)
;;; omnigent-sessions-test.el ends here

(ert-deftest omnigent-sessions-workspace-uses-matching-host-default ()
  "Offer the session workspace only on its execution host."
  (dolist (host '("host-a" "host-b"))
    (let (default)
      (cl-letf (((symbol-function
                  'omnigent-sessions--workspace-directories)
                 (lambda (_host _path callback &rest _)
                   (funcall callback 200 nil)))
                ((symbol-function 'completing-read)
                 (lambda (_prompt
                          _table
                          _predicate
                          _require
                          _initial
                          _history
                          value
                          &rest
                          _)
                   (setq default value)
                   "/chosen"))
                ((symbol-function 'omnigent-transport-request)
                 #'ignore))
        (omnigent-sessions--select-host
         omnigent-transport--generation
         #'ignore
         '((host_id . "host-a") (workspace . "/original"))
         200
         `((hosts . [((host_id . ,host) (status . "online"))])))
        (should
         (equal default (and (equal host "host-a") "/original")))))))
