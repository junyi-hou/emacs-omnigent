;;; omnigent-sessions-test.el --- Session state checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'omnigent)

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
               (lambda (callback)
                 (funcall callback
                          200
                          '((data
                             .
                             [((id . "root"))
                              ((id . "child")
                               (parent_session_id . "root"))])
                            (has_more . t)))))
              ((symbol-function 'omnigent-transport-request)
               (lambda (method _path callback &optional data)
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
               (lambda (&rest _) "Agent [agent]"))
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
  "Do not prompt for an agent or create a session if agents cannot be listed."
  (dolist (case
           '((500 nil "List agents: 500")
             (200
              ((data . []))
              "Create session: No agents available")))
    (pcase-let ((`(,status ,body ,expected-error) case))
      (let (errors
            requests
            (omnigent-sessions-error-hook nil))
        (setq omnigent-sessions-error-hook
              (list (lambda (error) (push error errors))))
        (cl-letf (((symbol-function
                    'omnigent-sessions--read-workspace)
                   (lambda (callback)
                     (funcall callback '("host-b" . "/srv/project"))))
                  ((symbol-function 'omnigent-transport-request)
                   (lambda (method path callback &optional _data)
                     (push (list method path) requests)
                     (funcall callback status body)))
                  ((symbol-function 'completing-read)
                   (lambda (&rest _)
                     (ert-fail "Unexpected agent prompt")))
                  ((symbol-function 'read-string)
                   (lambda (&rest _)
                     (ert-fail "Unexpected title prompt")))
                  ((symbol-function 'omnigent-sessions-refresh)
                   (lambda () (ert-fail "Unexpected refresh"))))
          (omnigent-sessions-create)
          (should (equal requests '(("GET" "/v1/agents"))))
          (should (equal errors (list expected-error))))))))

(ert-deftest
    omnigent-sessions-create-includes-title-and-handles-result
    ()
  "Send the selected agent and title; refresh on success and failure."
  (dolist (status '(201 500))
    (let ((omnigent-sessions-open-hook nil)
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
                ((symbol-function 'omnigent-transport-request)
                 (lambda (method path cb &optional data)
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

(ert-deftest omnigent-sessions-create-aborts-after-server-change ()
  "Do not send a selected host and workspace to a different server."
  (let ((omnigent-transport--generation 0)
        posted)
    (cl-letf (((symbol-function 'omnigent-sessions--read-workspace)
               (lambda (callback)
                 (funcall callback '("host-b" . "/srv/project"))))
              ((symbol-function 'omnigent-transport-request)
               (lambda (method _path callback &optional _data)
                 (if (equal method "GET")
                     (funcall callback
                              200
                              '((data
                                 .
                                 [((id . "agent")
                                   (name . "Agent"))])))
                   (setq posted t))))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "Agent [agent]"))
              ((symbol-function 'read-string)
               (lambda (&rest _)
                 (cl-incf omnigent-transport--generation)
                 "")))
      (should-error (omnigent-sessions-create) :type 'user-error)
      (should-not posted))))

(ert-deftest omnigent-sessions-actions-and-delete-forward-results ()
  "Refresh before forwarding successful or failed action and delete results."
  (dolist (operation '(action delete))
    (dolist (status '(202 204 500 (:error (connection-failed))))
      (let ((refreshes 0)
            request
            callback
            received
            (body '((result . "server result"))))
        (cl-letf (((symbol-function
                    'omnigent-transport-post-session-event)
                   (lambda (id event cb)
                     (setq
                      request (list id event)
                      callback cb)))
                  ((symbol-function
                    'omnigent-transport-delete-session)
                   (lambda (id cb)
                     (setq
                      request (list id)
                      callback cb)))
                  ((symbol-function 'omnigent-sessions-refresh)
                   (lambda () (cl-incf refreshes))))
          (let ((on-result
                 (lambda (result-status result-body)
                   (should (= refreshes 1))
                   (setq received (list result-status result-body)))))
            (if (eq operation 'action)
                (omnigent-sessions-action
                 "session" "interrupt" on-result)
              (omnigent-sessions-delete "session" on-result)))
          (should
           (equal
            request
            (if (eq operation 'action)
                '("session" (("type" . "interrupt")))
              '("session"))))
          (should (= refreshes 0))
          (should-not received)
          (funcall callback status body)
          (should (= refreshes 1))
          (should (equal (car received) status))
          (should (eq (cadr received) body)))))))

(ert-deftest omnigent-sessions-workspace-completes-host-directories ()
  "Complete directories through the server, including pagination and nested paths."
  (let ((omnigent-server-url "https://server-a.example")
        requests
        result)
    (cl-letf
        (((symbol-function 'omnigent-transport-request)
          (lambda (method path callback &optional _data)
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
             (equal
              (all-completions "projects/" table)
              '("projects/" "projects/src/")))
            (should
             (equal (all-completions "/" table) '("/" "/srv/")))
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
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (_method path callback &optional _data)
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
      (should (equal result '("two" . "~/repo")))
      (should (= (length prompts) 2))
      (should
       (equal
        (car requests)
        "/v1/hosts/two/filesystem/~/repo?limit=1000")))))

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
      (cl-letf (((symbol-function 'omnigent-transport-request)
                 (lambda (_method path callback &optional _data)
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
      (cl-letf (((symbol-function 'omnigent-transport-request)
                 (lambda (_method path callback &optional _data)
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
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (method path cb &optional data)
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
                   "Agent [agent]")))
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
        "/v1/hosts/host/filesystem/~/repo?limit=1000"))
      (funcall callback 200 '((data . [])))
      (should (equal (cadar requests) "/v1/agents"))
      (should (= prompts 1))
      (funcall callback
               200
               '((data . [((id . "agent") (name . "Agent"))])))
      (should (= prompts 2))
      (should (equal (caar requests) "POST"))
      (should
       (equal (cdr (assoc "workspace" (caddar requests))) "~/repo"))
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
              ((symbol-function 'omnigent-transport-request) #'ignore)
              ((symbol-function 'accept-process-output)
               (lambda (&rest _)
                 (ert-fail
                  "Completion must not wait for network output")))
              ((symbol-function 'active-minibuffer-window)
               (lambda () (selected-window)))
              ((symbol-function 'minibuffer-contents-no-properties)
               (lambda () "repo/"))
              ((symbol-function 'minibuffer-complete)
               (lambda () (cl-incf updates)))
              ((symbol-function 'completing-read)
               (lambda (_prompt table &rest _)
                 (should
                  (equal (all-completions "repo/" table) '("repo/")))
                 (should
                  (equal (all-completions "repo/" table) '("repo/")))
                 (should (= requests 1))
                 (funcall directory-callback
                          200
                          '(((name . "src") (type . "directory"))))
                 (should (= updates 1))
                 (should
                  (equal
                   (all-completions "repo/" table)
                   '("repo/" "repo/src/")))
                 (all-completions "other/" table)
                 (setq late-callback directory-callback)
                 "repo")))
      (omnigent-sessions--select-workspace
       omnigent-transport--generation "host" "Host" #'ignore 200 nil)
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
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (&rest _)
                 (cl-incf omnigent-transport--generation))))
      (omnigent-sessions--read-workspace
       (lambda (_) (setq selected t)))
      (should-not selected)))
  (let ((omnigent-transport--generation 0))
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (_method path callback &optional _data)
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
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (_method _path callback &optional _data)
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
           '(omnigent-sessions-action omnigent-sessions-delete))
    (let (callback
          received)
      (cl-letf (((symbol-function
                  'omnigent-transport-post-session-event)
                 (lambda (_id _event cb) (setq callback cb)))
                ((symbol-function 'omnigent-transport-delete-session)
                 (lambda (_id cb) (setq callback cb)))
                ((symbol-function 'omnigent-sessions-refresh)
                 (lambda () (error "Refresh failed"))))
        (let ((on-result
               (lambda (status body)
                 (setq received (list status body)))))
          (if (eq operation 'omnigent-sessions-action)
              (funcall operation "id" "interrupt" on-result)
            (funcall operation "id" on-result)))
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
    (cl-letf (((symbol-function 'omnigent-sessions-refresh) #'ignore))
      (omnigent-sessions--refreshed
       0 0 403 '((detail . "Access denied")))
      (omnigent-sessions--select-agent
       0 '("host" . "/repo") 403 '((detail . "Access denied")))
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
                ((symbol-function 'omnigent-transport-request)
                 (lambda (_method _path cb &optional _data)
                   (funcall cb 200 body))))
        (omnigent-sessions--select-host
         omnigent-transport--generation #'ignore 200 body)
        (omnigent-sessions--select-agent
         omnigent-transport--generation '("host" . "/repo") 200 body)
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
              ((symbol-function 'omnigent-transport-request)
               (lambda (_method _path cb &optional _data)
                 (funcall cb 200 nil))))
      (omnigent-sessions--select-workspace
       omnigent-transport--generation
       "host"
       "Host"
       (lambda (_) (setq selected t))
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
