;;; omnigent-integration-polly-test.el --- Follow a child session -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'omnigent)
(require 'omnigent-integration-fixture)

(defun omnigent-integration--write-polly (root meta-message)
  "Write a Polly bundle with one worker and a skill using META-MESSAGE under ROOT."
  (let*
      ((bundle (expand-file-name "polly" root))
       (worker (expand-file-name "agents/codex" bundle))
       (skill (expand-file-name "skills/fixture-context" bundle))
       (executor
        (concat
         "spec_version: 1\nexecutor:\n  type: omnigent\n"
         "  auth: {type: provider, name: test-mock}\n"
         "  config: {%s}\n"
         "llm: {model: mock-model}\n"
         "os_env: {type: caller_process, cwd: ., sandbox: {type: none}}\n")))
    (make-directory worker t)
    (make-directory skill t)
    (with-temp-file (expand-file-name "SKILL.md" skill)
      (insert
       "---\nname: fixture-context\ndescription: Supply test context.\n---\n"
       meta-message
       "\n"))
    (with-temp-file (expand-file-name "config.yaml" bundle)
      (insert
       (format executor "harness: openai-agents")
       "name: polly-ui-fixture\nprompt: Delegate work to Codex.\n"
       "tools: {agents: [codex]}\n"))
    (with-temp-file (expand-file-name "config.yaml" worker)
      (insert
       (format executor "harness: codex-native, yolo: true")
       "name: codex\nprompt: Report the result.\n"))
    bundle))

(defun omnigent-integration--polly-release (mock gate)
  "Wait for the named GATE on MOCK and release it."
  (let ((omnigent-server-url mock)
        (url-request-method "POST"))
    (omnigent-integration--wait
     (lambda ()
       (eq
        t
        (alist-get
         'released
         (omnigent-integration--get-json
          (concat "/gate/release?gate=" gate))))))))

(defun omnigent-integration--check-polly-transcript
    (parent-reply meta-reply meta-message worker-reply)
  "Check visible replies and hidden work messages in Polly's transcript."
  (should (omnigent-integration--message-position parent-reply))
  (should (omnigent-integration--message-position meta-reply))
  (should
   (omnigent-integration--message-position "You:\n/fixture-context"))
  (should-not (omnigent-integration--message-position meta-message))
  ;; The inbox can retain the worker reply and notice inside a collapsed tool block.
  (dolist (text (list worker-reply "[System: sub-agent"))
    (save-excursion
      (goto-char (point-min))
      (while (search-forward text nil t)
        (should (invisible-p (match-beginning 0)))))))

(ert-deftest omnigent-integration-polly ()
  "Follow a real child from dispatch through its completed conversation."
  (let*
      ((meta-message
        "Polly fixture internal context, hidden from the transcript")
       (omnigent-integration--server-agent
        (lambda (root)
          (omnigent-integration--write-polly root meta-message))))
    (omnigent-integration-with-run
     run
     (let* ((omnigent-server-url
             (omnigent-integration-run-server-url run))
            (omnigent-auth-method 'none)
            (omnigent-open-session-list-on-connect t)
            (mock (omnigent-integration-run-mock-url run))
            (prompt "Polly fixture delegate one task")
            (child-prompt "Polly fixture worker task")
            (worker-reply "The worker found the answer.")
            (parent-reply "Polly collected the answer.")
            (meta-reply "Polly received the context."))
       (omnigent-integration--post-json
        (concat mock "/mock/configure")
        `((key . "mock-model")
          (match . ,prompt) (required_tools . ["sys_session_send"])
          (responses
           .
           [((block . t)
             (gate . "dispatch")
             (tool_calls
              .
              [((call_id . "polly-dispatch")
                (name . "sys_session_send")
                (arguments
                 .
                 ,(json-encode
                   `((agent . "codex")
                     (title . "fixture-worker")
                     (args . ,child-prompt)))))]))
            ((text . "Polly dispatched the worker.")
             (block . t)
             (gate . "polly-wait"))])))
       (omnigent-integration--post-json
        (concat mock "/mock/configure")
        `((match . ,child-prompt)
          (required_tools . ["exec_command"])
          (responses
           .
           [((text . ,worker-reply) (block . t) (gate . "worker"))])))
       (omnigent-integration--post-json
        (concat mock "/mock/configure")
        `((match . "Call sys_read_inbox to collect.")
          (required_tools . ["sys_read_inbox"])
          (responses
           .
           [((tool_calls
              .
              [((call_id . "polly-inbox")
                (name . "sys_read_inbox")
                (arguments . "{}"))]))
            ((text . ,parent-reply))])))
       (omnigent-integration--post-json
        (concat mock "/mock/configure")
        `((match . ,meta-message)
          (required_tools . ["sys_session_send"])
          (responses . [((text . ,meta-reply))])))
       (save-window-excursion
         (unwind-protect
             (condition-case err
                 (progn
                   (omnigent-connect omnigent-server-url)
                   (let* ((parent
                           (omnigent-integration--mock-session
                            run "Polly journey" "polly-ui-fixture"))
                          (parent-buffer
                           (omnigent-integration--open-session-row
                            parent))
                          (children-path
                           (format "/v1/sessions/%s/child_sessions"
                                   parent))
                          child)
                     (with-current-buffer parent-buffer
                       (goto-char (point-max))
                       (insert prompt)
                       (funcall #'omnigent-conversation-send)
                       (ert-info
                        ("Polly shows a busy row and spinner")
                        (omnigent-integration--wait
                         (lambda ()
                           (and
                            (eq
                             (omnigent-integration--session-row-face
                              parent)
                             'omnigent-session-running)
                            (member
                             (overlay-get
                              omnigent-conversation--busy-overlay
                              'before-string)
                             '("|" "/" "-" "\\")))))))
                     (omnigent-integration--polly-release
                      mock "dispatch")
                     (ert-info
                      ("The running child appears without a refresh")
                      (setq
                       child
                       (omnigent-integration--wait
                        (lambda ()
                          (let* ((rows
                                  (alist-get
                                   'data
                                   (omnigent-integration--get-json
                                    children-path)))
                                 (id (alist-get 'id (car rows))))
                            (when
                                (and
                                 id
                                 (eq
                                  (omnigent-integration--session-row-face
                                   id)
                                  'omnigent-session-running))
                              id))))))
                     (save-selected-window
                       (select-window
                        (get-buffer-window "*omnigent-sessions*"))
                       (goto-char
                        (omnigent-integration--session-row parent))
                       (should (looking-at "  ▾ Polly"))
                       (should
                        (= (omnigent-integration--session-row child)
                           (line-beginning-position 2)))
                       (should
                        (save-excursion
                          (forward-line 1)
                          (looking-at "      codex:fixt")))
                       (funcall #'omnigent-session-toggle-tree)
                       (should
                        (eq
                         (point)
                         (omnigent-integration--session-row parent)))
                       (should-not
                        (omnigent-integration--session-row child))
                       (funcall #'omnigent-session-toggle-tree)
                       (should
                        (eq
                         (point)
                         (omnigent-integration--session-row parent)))
                       (should
                        (omnigent-integration--session-row child)))
                     (with-current-buffer parent-buffer
                       (ert-info
                        ("Polly's spinner advances while the child is running")
                        (let ((frame
                               (overlay-get
                                omnigent-conversation--busy-overlay
                                'before-string))
                              (frames '("|" "/" "-" "\\")))
                          (should (member frame frames))
                          (omnigent-integration--wait
                           (lambda ()
                             (let
                                 ((next
                                   (overlay-get
                                    omnigent-conversation--busy-overlay
                                    'before-string)))
                               (should (member next frames))
                               (should
                                (eq
                                 (omnigent-integration--session-row-face
                                  parent)
                                 'omnigent-session-running))
                               (should
                                (eq
                                 (omnigent-integration--session-row-face
                                  child)
                                 'omnigent-session-running))
                               (not (equal next frame))))))))
                     (let ((child-buffer
                            (omnigent-integration--open-session-row
                             child)))
                       (should
                        (get-buffer-window "*omnigent-sessions*"))
                       (should-not (eq parent-buffer child-buffer))
                       (omnigent-integration--polly-release
                        mock "worker")
                       (with-current-buffer child-buffer
                         (omnigent-integration--wait
                          (lambda ()
                            (and
                             (omnigent-integration--message-position
                              worker-reply)
                             (eq
                              (omnigent-integration--session-row-face
                               child)
                              'omnigent-session-idle))))
                         (should-not
                          (omnigent-integration--message-position
                           parent-reply))))
                     (omnigent-integration--polly-release
                      mock "polly-wait")
                     (with-current-buffer
                         (omnigent-integration--open-session-row
                          parent)
                       (ert-info
                        ("Polly shows its own reply and returns to idle")
                        (omnigent-integration--wait
                         (lambda ()
                           (and
                            (omnigent-integration--message-position
                             parent-reply)
                            (eq
                             (omnigent-integration--session-row-face
                              parent)
                             'omnigent-session-idle)
                            (equal
                             (overlay-get
                              omnigent-conversation--busy-overlay
                              'before-string)
                             " ")))))
                       (omnigent-integration--post-json
                        (format "%s/v1/sessions/%s/events"
                                omnigent-server-url parent)
                        '((type . "slash_command")
                          (data
                           .
                           ((kind . "skill")
                            (name . "fixture-context")))))
                       (ert-info
                        ("Hidden context reaches Polly and the server history")
                        (omnigent-integration--wait
                         (lambda ()
                           (omnigent-integration--message-position
                            meta-reply)))
                        (let ((items
                               (alist-get
                                'data
                                (omnigent-integration--get-json
                                 (format "/v1/sessions/%s/items"
                                         parent)))))
                          (should
                           (string-search
                            "[System: sub-agent codex/fixture-worker finished (completed)"
                            (json-encode items)))
                          (should
                           (seq-some
                            (lambda (item)
                              (and (eq
                                    (alist-get 'is_meta item) t)
                                   (string-search
                                    meta-message (json-encode item))))
                            items))))
                       (omnigent-integration--check-polly-transcript
                        parent-reply
                        meta-reply
                        meta-message
                        worker-reply))
                     (kill-buffer parent-buffer)
                     (with-current-buffer
                         (omnigent-integration--open-session-row
                          parent)
                       (omnigent-integration--check-polly-transcript
                        parent-reply
                        meta-reply
                        meta-message
                        worker-reply))))
               (error
                (message "Session list:\n%s"
                         (with-current-buffer "*omnigent-sessions*"
                           (buffer-string)))
                (message "Current buffer:\n%s" (buffer-string))
                (dolist (log (omnigent-integration-run-logs run))
                  (message "%s:\n%s"
                           (buffer-name log)
                           (omnigent-integration--log-text log)))
                (signal (car err) (cdr err))))
           (omnigent-disconnect)))))))

;;; omnigent-integration-polly-test.el ends here
