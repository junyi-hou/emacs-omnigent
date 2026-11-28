;;; omnigent-buffers-test.el --- Frontend tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'omnigent)

(ert-deftest omnigent-session-age-uses-short-time-units ()
  "Show session ages from less than a minute to four weeks or more."
  (let* ((updated-at (encode-time 0 0 0 1 1 2025 t))
         (now (time-add updated-at (seconds-to-time (* 14 86400))))
         (timestamp
          (lambda (time)
            (format-time-string "%Y-%m-%dT%H:%M:%SZ" time t))))
    (cl-letf (((symbol-function 'current-time) (lambda () now)))
      (should
       (equal
        (omnigent--session-age (funcall timestamp updated-at)) "2w"))
      (should
       (equal
        (omnigent--session-age
         (funcall timestamp
                  (time-subtract now (seconds-to-time (* 3 86400)))))
        "3d"))
      (should
       (equal
        (omnigent--session-age
         (funcall timestamp
                  (time-subtract now (seconds-to-time (* 2 3600)))))
        "2hr"))
      (should
       (equal
        (omnigent--session-age
         (funcall timestamp (time-subtract now (seconds-to-time 59))))
        "<1m"))
      (should
       (equal
        (omnigent--session-age
         (funcall timestamp (time-subtract now (seconds-to-time 60))))
        "1m"))
      (should
       (equal
        (omnigent--session-age
         (funcall timestamp
                  (time-subtract now (seconds-to-time (* 4 604800)))))
        "4w+"))
      (should (equal (omnigent--session-age "invalid") "n/a")))))

(ert-deftest omnigent-session-render-truncates-title-to-window-width
    ()
  "Keep a long session title on one line before its age label."
  (let ((omnigent-sessions
         '(((id . "a")
            (title . "A very long session title")
            (updated_at . "now"))))
        (omnigent-sessions-truncated nil))
    (unwind-protect
        (with-current-buffer (get-buffer-create "*omnigent-sessions*")
          (omnigent-session-mode)
          (cl-letf (((symbol-function 'frame-width)
                     (lambda (&rest _) 16))
                    ((symbol-function 'omnigent--session-age)
                     (lambda (_) "2d")))
            (omnigent-session-render))
          (should
           (equal
            (buffer-string) "▾ Unassigned\n    A very l… 2d\n")))
      (when-let* ((buffer (get-buffer "*omnigent-sessions*")))
        (kill-buffer buffer)))))

(ert-deftest omnigent-session-render-shows-only-project-ellipsis ()
  "Show one marker when only the project fetch identifies more rows."
  (let ((omnigent-sessions '(((id . "a") (title . "First"))))
        (omnigent-sessions-projects nil)
        (omnigent-sessions-truncated t)
        (omnigent-sessions--project-lists
         (make-hash-table :test 'equal)))
    (unwind-protect
        (with-current-buffer (get-buffer-create "*omnigent-sessions*")
          (omnigent-session-mode)
          (omnigent-session-render)
          (should-not (string-match-p "[.][.][.]" (buffer-string)))
          (puthash
           'unassigned
           (list 1 omnigent-sessions t)
           omnigent-sessions--project-lists)
          (omnigent-session-render)
          (should (string-suffix-p "\n  ...\n" (buffer-string)))
          (should
           (= (how-many "^ *[.][.][.]$" (point-min) (point-max)) 1))
          (should-not (get-text-property (- (point-max) 4) 'face)))
      (kill-buffer "*omnigent-sessions*"))))

(ert-deftest omnigent-session-render-checks-unassigned-pagination ()
  "Show the Unassigned marker after its initial pagination check."
  (let ((omnigent-sessions nil)
        (omnigent-sessions-projects nil)
        (omnigent-sessions-truncated nil)
        (omnigent-sessions--project-lists
         (make-hash-table :test 'equal))
        (omnigent-sessions--project-more
         (make-hash-table :test 'equal))
        (omnigent-sessions--buffers nil)
        (omnigent-sessions-change-hook '(omnigent-session-render))
        callback)
    (unwind-protect
        (with-current-buffer (get-buffer-create "*omnigent-sessions*")
          (omnigent-session-mode)
          (cl-letf (((symbol-function
                      'omnigent-transport-list-sessions)
                     (lambda (fn project limit)
                       (should (equal project ""))
                       (should (= limit 1))
                       (setq callback fn))))
            (omnigent-sessions--refreshed
             omnigent-sessions--refresh-number
             omnigent-sessions--revision
             200
             '((data . [((id . "a") (title . "First"))])
               (has_more . t)))
            (should callback)
            (should-not (string-suffix-p "\n  ...\n" (buffer-string)))
            (funcall callback 200 '((has_more . t)))
            (should (string-suffix-p "\n  ...\n" (buffer-string)))))
      (kill-buffer "*omnigent-sessions*"))))

(ert-deftest omnigent-session-render-preserves-selection ()
  "Render statuses and attention while preserving the selected session."
  (let ((omnigent-sessions
         '(((id . "a")
            (title . "First")
            (status . "running")
            (updated_at . "2025-01-01")
            (pending_elicitations_count . 1))
           ((id . "b")
            (title . "Second")
            (status . "idle")
            (updated_at . "2025-01-02"))
           ((id . "archived")
            (title . "Archived")
            (archived . t)
            (updated_at . "2025-01-03"))))
        (omnigent-fetch-archived-sessions t)
        (omnigent-sessions--project-lists
         (make-hash-table :test 'equal)))
    (puthash
     'unassigned
     (list 3 omnigent-sessions t)
     omnigent-sessions--project-lists)
    (unwind-protect
        (with-current-buffer (get-buffer-create "*omnigent-sessions*")
          (omnigent-session-mode)
          (omnigent-session-render)
          (goto-char (point-min))
          (search-forward "! First")
          (beginning-of-line)
          (should (looking-at "    ! First"))
          (should
           (eq
            (get-text-property (+ (point) 4) 'face)
            'omnigent-session-attention))
          (should
           (eq
            (get-text-property (+ (point) 6) 'face)
            'omnigent-session-running))
          (omnigent-session-render)
          (should (equal (omnigent-session--session-id-at-point) "a"))
          (should
           (equal
            (mapcar
             (lambda (session)
               (get-text-property
                (save-excursion
                  (goto-char (point-min))
                  (search-forward (alist-get 'title session))
                  (line-beginning-position))
                'omnigent-session-id))
             omnigent-sessions)
            '("a" "b" "archived")))
          (should
           (save-excursion
             (goto-char (point-min))
             (search-forward "w")
             (eq
              (get-text-property (match-beginning 0) 'display) nil)))
          (should
           (save-excursion
             (goto-char (point-max))
             (forward-line -1)
             (and (looking-at "  [.][.][.]$")
                  (eq
                   (get-text-property (+ (point) 2) 'face)
                   'omnigent-session-archived)))))
      (when-let* ((buffer (get-buffer "*omnigent-sessions*")))
        (kill-buffer buffer)))))


(defmacro omnigent-conversation-test--buffer (&rest body)
  "Run BODY in an isolated conversation with no network or process activity."
  (declare (indent 0) (debug t))
  `(let ((omnigent-session--selected-session nil))
     (cl-letf (((symbol-function
                 'omnigent-transport-start-session-stream)
                (lambda (&rest _) nil)))
       (with-temp-buffer
         (let ((omnigent-conversation--session-id "conv_test"))
           (omnigent-conversation-mode))
         (setq
          omnigent-conversation--loading nil
          omnigent-conversation--connected t
          buffer-read-only nil)
         ,@body))))

(ert-deftest omnigent-conversation-btw-opens-side-chat ()
  "Open a side chat for /btw and send its question when supplied."
  (dolist (question '(nil "What changed?"))
    (with-temp-buffer
      (let ((side (current-buffer))
            opened
            sent)
        (omnigent-conversation-test--buffer
          (cl-letf (((symbol-function
                      'omnigent-conversation-side-chat)
                     (lambda (callback)
                       (setq opened t)
                       (funcall callback 200 side)))
                    ((symbol-function
                      'omnigent--side-chat-send-question)
                     (lambda (text)
                       (should (eq (current-buffer) side))
                       (setq sent text))))
            (insert
             (if question
                 (concat "/btw " question)
               "/btw"))
            (omnigent-conversation-send)
            (should opened)
            (should (equal sent question))))))))

(ert-deftest
    omnigent-conversation-side-chat-question-waits-for-connection
    ()
  "Keep the question in the composer until the side chat can send it."
  (omnigent-conversation-test--buffer
    (let (requests)
      (cl-letf (((symbol-function
                  'omnigent-transport-post-session-event)
                 (lambda (id event callback)
                   (push (cons id event) requests)
                   (funcall callback 400 '((detail . "Rejected"))))))
        (omnigent-conversation--connection-state 'connecting)
        (omnigent--side-chat-send-question "/literal question")
        (should-not requests)
        (omnigent-conversation--connection-state 'connected)
        (run-hooks 'omnigent-conversation-change-hook)
        (should (= (length requests) 1))
        (should
         (equal
          (alist-get "type" (cdar requests)
                     nil
                     nil
                     #'equal)
          "message"))
        (should
         (equal
          (buffer-substring-no-properties
           omnigent-conversation--prompt-start (point-max))
          "/literal question"))))))

(ert-deftest omnigent-conversation-header-tracks-session-data ()
  "Show snapshot settings and update them from partial stream events."
  (omnigent-conversation-test--buffer
    (should (string-prefix-p " unknown | unknown" header-line-format))
    (should
     (eq (get-text-property 0 'face header-line-format) 'diff-header))
    (should
     (equal
      (mapcar
       #'omnigent-conversation--token-count
       '(10 1000 1001 1200 1000000 1050001))
      '("10" "1k" "1.1k" "1.2k" "1m" "1.1m")))
    (omnigent-conversation--snapshot
     200
     '((title . "Test session")
       (workspace . "/srv/project/")
       (harness . "codex-native")
       (llm_model . "model-a")
       (reasoning_effort . "high")
       (labels
        . ((omnigent.codex_native.approval_mode . "read-only")))
       (last_total_tokens . 100)
       (context_window . 1000)
       (items . [])
       (pending_inputs . [])
       (pending_elicitations . [])))
    (should
     (equal
      header-line-format
      " project | model-a | high | read-only | 100 / 1k (10%%)"))
    (omnigent-conversation--event
     "session.model" '((model . "model-b")))
    (omnigent-conversation--event
     "session.reasoning_effort" '((reasoning_effort . "low")))
    (omnigent-conversation--event
     "session.codex_approval_mode" '((approval_mode . "full-access")))
    (omnigent-conversation--event
     "session.usage" '((context_tokens . 250)))
    (should
     (equal
      header-line-format
      " project | model-b | low | full-access | 250 / 1k (25%%)"))
    (omnigent-conversation--event
     "response.completed"
     '((response
        .
        ((model . "agent-name")
         (usage
          .
          ((model . "model-c")
           (context_tokens . 300)
           (total_tokens . 900)))))))
    (should
     (string-match-p "model-c.*300 / 1k (30%%)" header-line-format))
    (omnigent-conversation--snapshot
     200
     '((last_total_tokens . 42)
       (items . [])
       (pending_inputs . [])
       (pending_elicitations . [])))
    (should (string-match-p "42 / unknown" header-line-format))
    (omnigent-conversation--snapshot
     200
     '((context_window . 4096)
       (items . [])
       (pending_inputs . [])
       (pending_elicitations . [])))
    (should (string-match-p "unknown / 4.1k" header-line-format))
    (omnigent-conversation--event
     "response.completed"
     '((response . ((usage . ((total_tokens . 512)))))))
    (should (string-match-p "512 / 4.1k (12%%)" header-line-format))))

(ert-deftest omnigent-conversation-message-label-faces ()
  "Use the prompt face for user and agent labels."
  (omnigent-conversation-test--buffer
    (let ((outputs (make-hash-table :test 'equal)))
      (let ((user-start (point-max)))
        (omnigent-conversation--item
         "user"
         '((type . "message")
           (role . "user")
           (content . "Hi"))
         outputs)
        (let ((user-face (get-text-property user-start 'face)))
          (let ((inhibit-read-only t))
            (erase-buffer))
          (let ((agent-start (point)))
            (omnigent-conversation--item
             "agent"
             '((type . "message")
               (role . "assistant")
               (agent_name . "codex-native-ui")
               (content . "Hello"))
             outputs)
            (should (eq user-face 'omnigent-conversation-prompt))
            (should
             (eq
              (get-text-property agent-start 'face)
              'omnigent-conversation-prompt))))))))

(ert-deftest omnigent-conversation-prompt-busy-indicator ()
  "Animate the prompt while a response is active and stop when it ends."
  (omnigent-conversation-test--buffer
    (unwind-protect
        (progn
          (should
           (equal
            (overlay-get
             omnigent-conversation--busy-overlay 'before-string)
            " "))
          (omnigent-conversation--event
           "response.created" '((response . ((id . "response")))))
          (should (timerp omnigent-conversation--busy-timer))
          (omnigent-conversation--event
           "response.output_text.delta" '((delta . "streaming")))
          (omnigent-conversation--transcript-render)
          (should
           (= (overlay-start omnigent-conversation--busy-overlay)
              (marker-position
               omnigent-conversation--composer-label)))
          (should
           (equal
            (overlay-get
             omnigent-conversation--busy-overlay 'before-string)
            "|"))
          (omnigent-conversation--busy-tick (current-buffer))
          (should
           (equal
            (overlay-get
             omnigent-conversation--busy-overlay 'before-string)
            "/"))
          (omnigent-conversation--event
           "response.completed" '((response . ((id . "response")))))
          (should-not omnigent-conversation--busy-timer)
          (should
           (equal
            (overlay-get
             omnigent-conversation--busy-overlay 'before-string)
            " ")))
      (omnigent-conversation--busy-stop))))

(ert-deftest
    omnigent-conversation-busy-indicator-survives-steering-delivery
    ()
  "Keep animating when a steering message finishes delivery during a turn."
  (omnigent-conversation-test--buffer
    (unwind-protect
        (progn
          (omnigent-conversation--event
           "session.status"
           '((status . "running") (response_id . "native")))
          (omnigent-conversation--event
           "response.created" '((response . ((id . "delivery")))))
          (omnigent-conversation--event
           "response.completed" '((response . ((id . "delivery")))))
          (should (timerp omnigent-conversation--busy-timer))
          (should-not
           (equal
            (overlay-get
             omnigent-conversation--busy-overlay 'before-string)
            " "))
          (omnigent-conversation--event
           "session.status"
           '((status . "idle") (response_id . "native")))
          (should-not omnigent-conversation--busy-timer))
      (omnigent-conversation--busy-stop))))

(ert-deftest
    omnigent-conversation-busy-indicator-survives-follow-up-completion
    ()
  "Keep animating after a follow-up while the session is still running."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--event
     "session.status" '((status . "running")))
    (should (timerp omnigent-conversation--busy-timer))
    (omnigent-conversation--event
     "response.created" '((response . ((id . "follow-up")))))
    (should (timerp omnigent-conversation--busy-timer))
    (omnigent-conversation--event
     "response.completed" '((response . ((id . "follow-up")))))
    (should (timerp omnigent-conversation--busy-timer))
    (omnigent-conversation--busy-tick (current-buffer))
    (should-not
     (equal
      (overlay-get
       omnigent-conversation--busy-overlay 'before-string)
      " "))
    (omnigent-conversation--event
     "session.status" '((status . "idle")))
    (should-not omnigent-conversation--busy-timer)))

(ert-deftest
    omnigent-conversation-busy-indicator-recovers-session-status
    ()
  "Restore the prompt animation from the session snapshot."
  (omnigent-conversation-test--buffer
    (let ((snapshot
           '((items . [])
             (pending_inputs . [])
             (pending_elicitations . []))))
      (omnigent-conversation--snapshot
       200 (cons '(status . "running") snapshot))
      (should (timerp omnigent-conversation--busy-timer))
      (omnigent-conversation--snapshot
       200 (cons '(status . "idle") snapshot))
      (should-not omnigent-conversation--busy-timer))))

(ert-deftest
    omnigent-conversation-busy-indicator-ignores-late-session-list-update
    ()
  "Keep the prompt idle when the session list reports running after a turn."
  (omnigent-conversation-test--buffer
    (let ((omnigent-sessions
           '(((id . "conv_test") (status . "idle"))))
          (omnigent-sessions--buffers
           (list (cons "conv_test" (current-buffer))))
          (omnigent-sessions--revision 0))
      (omnigent-conversation--event
       "session.status"
       '((status . "running") (response_id . "turn")))
      (should (timerp omnigent-conversation--busy-timer))
      (omnigent-conversation--event
       "session.status" '((status . "idle") (response_id . "turn")))
      (should-not omnigent-conversation--busy-timer)
      (omnigent-sessions--frame
       '((type . "changed")
         (items . [((id . "conv_test") (status . "running"))])))
      (should-not omnigent-conversation--busy-timer))))

(ert-deftest
    omnigent-conversation-sandbox-progress-recovers-and-clears
    ()
  "Render snapshot and live sandbox progress without writing transcript items."
  (omnigent-conversation-test--buffer
    (let ((snapshot
           '((items . [])
             (pending_inputs . [])
             (pending_elicitations . []))))
      (insert "draft")
      (omnigent-conversation--snapshot
       200 (cons '(sandbox_status (stage . "cloning")) snapshot))
      (should-not buffer-read-only)
      (should (timerp omnigent-conversation--busy-timer))
      (should
       (string-match-p
        "Cloning repositories"
        (overlay-get
         omnigent-conversation--sandbox-overlay 'before-string)))
      (omnigent-conversation--event
       "session.sandbox_status" '((stage . "action_required")))
      (should buffer-read-only)
      (should-not omnigent-conversation--busy-timer)
      (omnigent-conversation--event
       "session.sandbox_status"
       '((stage . "failed") (error . "Provider unavailable")))
      (should buffer-read-only)
      (should-not omnigent-conversation--busy-timer)
      (should
       (string-match-p
        "Provider unavailable"
        (overlay-get
         omnigent-conversation--sandbox-overlay 'before-string)))
      (omnigent-conversation--event
       "session.sandbox_status" '((stage . "ready")))
      (should-not buffer-read-only)
      (should-not
       (overlay-get
        omnigent-conversation--sandbox-overlay 'before-string))
      (should-not omnigent-conversation--order)
      (should
       (equal
        (buffer-substring-no-properties
         omnigent-conversation--prompt-start (point-max))
        "draft")))))

(ert-deftest omnigent-session-undo-and-redo-move-and-archive ()
  "Undo and redo a move and a mixed archive branch in order."
  (with-temp-buffer
    (omnigent-session-mode)
    (let ((inhibit-read-only t))
      (insert (propertize "Parent\n" 'omnigent-session-id "parent")))
    (goto-char (point-min))
    (let ((omnigent-sessions '(((id . "parent") (title . "Parent"))))
          (states
           (copy-tree
            '(("parent" . :json-false)
              ("active" . :json-false)
              ("archived" . t))))
          project
          fail-archive-write)
      (cl-letf (((symbol-function 'omnigent-sessions-read-projects)
                 (lambda (done)
                   (funcall done
                            '(((id . "project")
                               (name . "Project"))))))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) "Project"))
                ((symbol-function 'omnigent-transport-get-session)
                 (lambda (id done)
                   (funcall done
                            200
                            `((id . ,id)
                              (project_id . ,project)
                              (archived
                               . ,(cdr (assoc id states)))))))
                ((symbol-function
                  'omnigent-transport-list-child-sessions)
                 (lambda (id done &optional _after)
                   (funcall done
                            200
                            (if (equal id "parent")
                                '((data
                                   .
                                   [((id . "active"))
                                    ((id . "archived"))]))
                              '((data . []))))))
                ((symbol-function 'omnigent-transport--request)
                 (lambda (_id method _path done body)
                   (should (equal method "PATCH"))
                   (setq project (cdr (assoc "project_id" body)))
                   (funcall done 200 nil)))
                ((symbol-function
                  'omnigent-transport-set-session-archived)
                 (lambda (id archived done)
                   (if fail-archive-write
                       (funcall done 500 "Write failed")
                     (setcdr
                      (assoc id states)
                      (if archived
                          t
                        :json-false))
                     (funcall done 200 nil))))
                ((symbol-function 'omnigent-sessions-refresh)
                 #'ignore))
        (omnigent-session-move-session)
        (should (equal project "project"))
        (omnigent-session-archive-at-point)
        (should
         (seq-every-p (lambda (entry) (eq (cdr entry) t)) states))
        (setq fail-archive-write t)
        (call-interactively (key-binding (kbd "u")))
        (should (= (length omnigent-session--undo-history) 2))
        (setq fail-archive-write nil)
        (omnigent-session-undo-action)
        (should
         (equal
          states
          '(("parent" . :json-false)
            ("active" . :json-false)
            ("archived" . t))))
        (should (equal project "project"))
        (omnigent-session-undo-action)
        (should (equal project ""))
        (should-error
         (omnigent-session-undo-action)
         :type 'user-error)
        (call-interactively (key-binding (kbd "C-r")))
        (should (equal project "project"))
        (setq fail-archive-write t)
        (omnigent-session-redo-action)
        (should (= (length omnigent-session--redo-history) 1))
        (setq fail-archive-write nil)
        (omnigent-session-redo-action)
        (should
         (seq-every-p (lambda (entry) (eq (cdr entry) t)) states))
        (should-error
         (omnigent-session-redo-action)
         :type 'user-error)
        (omnigent-session-undo-action)
        (should (eq (cdr (assoc "active" states)) :json-false))
        (omnigent-session-archive-at-point)
        (should-error
         (omnigent-session-redo-action)
         :type 'user-error)
        (omnigent-session-undo-action)
        (let ((omnigent-transport--generation
               (1+ omnigent-transport--generation)))
          (should-error
           (omnigent-session-redo-action)
           :type 'user-error)
          (should-error
           (omnigent-session-undo-action)
           :type 'user-error))))))

(ert-deftest omnigent-session-archive-and-delete-commands ()
  "Archive the selected session and require confirmation for permanent deletion."
  (dolist (conversation '(nil t))
    (with-temp-buffer
      (if conversation
          (setq
           major-mode 'omnigent-conversation-mode
           omnigent-conversation-session-id "target")
        (setq major-mode 'omnigent-session-mode)
        (insert (propertize "Target\n" 'omnigent-session-id "target"))
        (goto-char (point-min)))
      (let ((omnigent-sessions
             '(((id . "target") (title . "Target"))))
            (omnigent-sessions--buffers nil)
            archived
            deleted
            confirmation)
        (cl-letf (((symbol-function 'omnigent-sessions-toggle-archive)
                   (lambda (id callback &optional record)
                     (setq archived id)
                     (funcall callback
                              200
                              (if record
                                  '(("target" . :json-false))
                                '((archived . t))))))
                  ((symbol-function 'omnigent-sessions-delete)
                   (lambda (id callback)
                     (setq deleted id)
                     (funcall callback 204 nil)))
                  ((symbol-function 'y-or-n-p)
                   (lambda (prompt)
                     (should
                      (string-match-p
                       "Permanently delete session Target" prompt))
                     confirmation)))
          (omnigent-archive)
          (should (equal archived "target"))
          (omnigent-delete)
          (should-not deleted)
          (setq confirmation t)
          (omnigent-delete)
          (should (equal deleted "target")))))))

(ert-deftest omnigent-conversation-user-permission ()
  "Freeze read-only sessions and restore editing when permission increases."
  (omnigent-conversation-test--buffer
    (insert "unsent draft")
    (omnigent-conversation--snapshot
     200
     '((permission_level . 1)
       (items . [])
       (pending_inputs . [])
       (pending_elicitations . [])))
    (should buffer-read-only)
    (should (string-prefix-p " unknown [R] |" header-line-format))
    (should-error (insert "more") :type 'buffer-read-only)
    (should-error (omnigent-conversation-send) :type 'user-error)
    (should-error (omnigent-conversation-interrupt) :type 'user-error)
    (should-error (omnigent-archive) :type 'user-error)
    (should-error (omnigent-delete) :type 'user-error)
    (omnigent-conversation--snapshot
     200
     '((permission_level . 2)
       (items . [])
       (pending_inputs . [])
       (pending_elicitations . [])))
    (should-not buffer-read-only)
    (should (string-prefix-p " unknown [E] |" header-line-format))
    (should
     (equal
      (buffer-substring-no-properties
       omnigent-conversation--prompt-start (point-max))
      "unsent draft"))
    (omnigent-conversation--snapshot
     200
     '((permission_level . 4)
       (items . [])
       (pending_inputs . [])
       (pending_elicitations . [])))
    (should (string-prefix-p " unknown [M] |" header-line-format))))

(ert-deftest
    omnigent-conversation-transcript-stream-preserves-composer-and-fold
    ()
  "Render streamed blocks without replacing input or opening collapsed folds."
  (omnigent-conversation-test--buffer
    (insert "draft\ncontinued")
    (let ((position (point)))
      (omnigent-conversation--event
       "response.output_item.added"
       '((item
          .
          ((id . "r") (type . "reasoning") (content . "think")))))
      (should
       (equal
        (buffer-substring-no-properties
         omnigent-conversation--prompt-start (point-max))
        "draft\ncontinued"))
      (should (= (- (point-max) (point)) 0))
      (should (> (point) position))
      (goto-char (point-min))
      (should (search-forward "▶ Thinking" nil t))
      (forward-line 1)
      (should (invisible-p (point)))
      (omnigent-conversation--event
       "response.reasoning_text.delta"
       '((item_id . "r") (delta . " more")))
      (goto-char (point-min))
      (forward-line 1)
      (should (invisible-p (point)))
      (omnigent-conversation--fold-button (button-at (point-min)))
      (goto-char (point-min))
      (forward-line 1)
      (should-not (invisible-p (point)))
      (omnigent-conversation--snapshot
       200
       '((items
          . [((id . "r") (type . "reasoning") (content . "final"))])
         (pending_inputs . []) (pending_elicitations . [])))
      (goto-char (point-min))
      (forward-line 1)
      (should-not (invisible-p (point)))
      (should-error (delete-char 1) :type 'text-read-only))))

(ert-deftest omnigent-conversation-fold-commands-use-block-at-point ()
  "Open and close the fold that contains point."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--event
     "response.output_item.added"
     '((item
        .
        ((id . "r") (type . "reasoning") (content . "think")))))
    (goto-char (point-min))
    (forward-line 1)
    (should (invisible-p (point)))
    (omnigent-conversation-open-block)
    (goto-char (point-min))
    (forward-line 1)
    (should-not (invisible-p (point)))
    (omnigent-conversation-close-block)
    (goto-char (point-min))
    (forward-line 1)
    (should (invisible-p (point)))))

(ert-deftest omnigent-conversation-fold-commands-work-at-indicator ()
  "Open and close a fold when point is on its indicator."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--event
     "response.output_item.added"
     '((item
        .
        ((id . "r") (type . "reasoning") (content . "think")))))
    (goto-char (point-min))
    (should (eq (char-after) ?▶))
    (omnigent-conversation-open-block)
    (goto-char (point-min))
    (should (eq (char-after) ?▼))
    (omnigent-conversation-close-block)
    (goto-char (point-min))
    (should (eq (char-after) ?▶))))

(ert-deftest omnigent-conversation-fold-face-survives-fontification ()
  "Keep the fold marker face when fontification removes its explicit face."
  (with-temp-buffer
    (let ((omnigent-conversation--folds
           (make-hash-table :test 'equal)))
      (omnigent-conversation--fold "fold" "Heading" "Body"))
    (remove-text-properties (point-min) (point-max) '(face nil))
    (should
     (eq
      (get-char-property (point-min) 'face)
      'omnigent-conversation-fold-marker))
    (should-not
     (face-attribute 'omnigent-conversation-fold-marker :underline
                     nil t))))

(ert-deftest omnigent-conversation-fold-spacing-and-no-ellipsis ()
  "Keep visible blank lines between items with either fold state."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--snapshot
     200
     '((items
        .
        [((id . "first")
          (type . "reasoning")
          (content . "first thought"))
         ((id . "second")
          (type . "reasoning")
          (content . "second thought"))
         ((id . "message") (role . "user") (content . "hello"))
         ((id . "error") (type . "error") (text . "failed"))])
       (pending_inputs . []) (pending_elicitations . [])))
    (dolist (open '(nil t))
      (puthash "first" open omnigent-conversation--folds)
      (puthash "second" open omnigent-conversation--folds)
      (omnigent-conversation--transcript)
      (let ((position (point-min))
            visible)
        (while (< position omnigent-conversation--request-start)
          (if (invisible-p position)
              (should (eq (invisible-p position) t))
            (push (char-after position) visible))
          (setq position (1+ position)))
        (should
         (equal
          (apply #'string (nreverse visible))
          (concat
           (if open
               "▼ Thinking\nfirst thought\n\n▼ Thinking\nsecond thought\n\n"
             "▶ Thinking\n\n▶ Thinking\n\n")
           "You:\nhello\n\nError:\nfailed\n\n")))))))

(ert-deftest omnigent-conversation-tool-output-merges-and-bounds ()
  "Merge tool outputs into one fold and apply both deterministic size limits."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--event
     "response.output_item.done"
     '((item
        .
        ((id . "call")
         (type . "function_call")
         (call_id . "c")
         (name . "shell")
         (arguments . "pwd")))))
    (omnigent-conversation--event
     "response.output_item.done"
     '((item
        .
        ((id . "output")
         (type . "function_call_output")
         (call_id . "c")
         (output . "workspace")))))
    (should (= (how-many "▶ \uf14a shell" (point-min) (point-max)) 1))
    (should (string-match-p "\uf14a shell pwd" (buffer-string)))
    (should (string-match-p "Output:\nworkspace" (buffer-string)))
    (let* ((line (make-string 33000 ?x))
           (text
            (mapconcat #'identity (cons line (make-list 1100 "short"))
                       "\n"))
           (bounded (omnigent-conversation--bounded-output text)))
      (should (string-match-p "32600 characters omitted" bounded))
      (should (string-match-p "301 lines omitted" bounded))
      (should (= (length (split-string bounded "\n")) 801)))))

(ert-deftest omnigent-conversation-tool-headings-cover-pi-harness ()
  "Render concise headings for Pi tool names bash, read, and edit."
  (omnigent-conversation-test--buffer
    (dolist (tool
             '(("bash" . "{\"command\":\"ls -la\"}")
               ("read" . "{\"path\":\"src/a.el\"}")
               ("edit" . "{\"path\":\"src/a.el\"}")))
      (omnigent-conversation--event
       "response.output_item.done"
       `((item
          .
          ((id . ,(concat "call-" (car tool)))
           (type . "function_call")
           (call_id . ,(concat "c-" (car tool)))
           (name . ,(car tool))
           (arguments . ,(cdr tool))))))
      (omnigent-conversation--event
       "response.output_item.done"
       `((item
          .
          ((id
            .
            ,(concat "out-" (car tool)))
           (type . "function_call_output")
           (call_id
            . ,(concat "c-" (car tool)))
           (output . "done"))))))
    (let ((text (buffer-string)))
      (should (string-match-p "ls -la" text))
      (should (string-match-p "edit src/a.el" text))
      (should (string-match-p "read src/a.el" text))
      (should (= 3 (how-many "▶ " (point-min) (point-max)))))))

(ert-deftest
    omnigent-conversation-shell-heading-unwraps-quoted-login-shell
    ()
  "Strip /bin/zsh, -lc, and shell quotes from the tool heading."
  (should
   (equal
    (omnigent-conversation--unwrap-shell-command
     "/bin/zsh -lc \"rg -n pattern\\; echo done\"")
    "rg -n pattern\\; echo done"))
  (should
   (equal
    (omnigent-conversation--unwrap-shell-command
     "/bin/zsh -lc \"echo one\" \"echo two\"")
    "echo one\" \"echo two"))
  (should
   (equal
    (omnigent-conversation--unwrap-shell-command
     "/bin/zsh -lc \"unbalanced quote")
    "/bin/zsh -lc \"unbalanced quote"))
  (should
   (equal
    (omnigent-conversation--unwrap-shell-command
     "/bin/zsh -lc \"echo \\\"\"'foo\"")
    "echo \\\"\"'foo")))

(ert-deftest
    omnigent-conversation-inline-forms-survive-output-and-failure
    ()
  "Keep field edits and composer text while streaming and a resolve is pending."
  (omnigent-conversation-test--buffer
    (insert "composer")
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "question")
       (params
        .
        ((message . "Your name?")
         (requestedSchema
          .
          ((type . "object")
           (required . ["name"])
           (properties . ((name . ((type . "string")))))))))))
    (should
     (string-match-p "# Question\n\n> Your name?" (buffer-string)))
    (let* ((field
            (cl-find
             "name"
             omnigent-conversation--widgets
             :key
             (lambda (widget) (widget-get widget :field-name))
             :test #'equal))
           callback)
      (widget-value-set field "Alice")
      (omnigent-conversation--field-notify field)
      (omnigent-conversation--event
       "response.output_item.done"
       '((item
          .
          ((id . "a") (type . "message") (content . "answer")))))
      (should
       (equal
        (gethash
         "name" (omnigent-conversation-elicitation-draft "question"))
        "Alice"))
      (should (equal (widget-value field) "Alice"))
      (cl-letf (((symbol-function 'omnigent-transport--request)
                 (lambda (_session-id _method _path cb _data)
                   (setq callback cb))))
        (omnigent-conversation-elicitation-submit
         "question" 'accept nil)
        (should
         (string-match-p "Submitting\\.\\.\\." (buffer-string)))
        (funcall callback 500 '((detail . "No")))
        (should
         (gethash "question" omnigent-conversation--elicitations))
        (should (string-match-p "Alice" (buffer-string))))
      (goto-char (point-max))
      (insert " suffix")
      (should
       (equal
        (buffer-substring-no-properties
         omnigent-conversation--prompt-start (point-max))
        "composer suffix"))
      (omnigent-conversation--event
       "response.elicitation_resolved"
       '((elicitation_id . "question")))
      (should-not (string-match-p "Your name?" (buffer-string)))
      (should
       (equal
        (buffer-substring-no-properties
         omnigent-conversation--prompt-start (point-max))
        "composer suffix")))))

(ert-deftest omnigent-conversation-secret-stays-out-of-text-and-undo
    ()
  "Read a secret into the draft without retaining clear text in buffer or undo."
  (omnigent-conversation-test--buffer
    (buffer-enable-undo)
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "secret")
       (params
        .
        ((requestedSchema
          .
          ((type . "object")
           (properties
            .
            ((token
              .
              ((type . "string") (format . "password")))))))))))
    (let ((field
           (cl-find
            "token"
            omnigent-conversation--widgets
            :key
            (lambda (widget) (widget-get widget :field-name))
            :test #'equal)))
      (cl-letf (((symbol-function 'read-passwd)
                 (lambda (&rest _) "sensitive-value")))
        (omnigent-conversation--secret field)))
    (should
     (equal
      (gethash
       "token" (omnigent-conversation-elicitation-draft "secret"))
      "sensitive-value"))
    (should-not (string-match-p "sensitive-value" (buffer-string)))
    (should-not
     (string-match-p
      "sensitive-value" (format "%S" buffer-undo-list)))))

(ert-deftest
    omnigent-conversation-requests-arrive-in-order-without-moving-point
    ()
  "Keep pending requests oldest first and retain the point inside the composer."
  (omnigent-conversation-test--buffer
    (insert "draft")
    (dolist (id '("first" "second"))
      (omnigent-conversation--event
       "response.elicitation_request"
       `((elicitation_id . ,id) (params . ((message . ,id))))))
    (should (= (point) (point-max)))
    (should
     (equal
      (mapcar
       (lambda (request)
         (alist-get 'elicitation_id request))
       (omnigent-conversation-elicitations))
      '("first" "second")))
    (should
     (string-match-p
      "first\n\n.*\n\n# Question\n\n> second" (buffer-string)))))

(ert-deftest omnigent-conversation-schema-validation-shows-all-errors
    ()
  "Display every invalid field and select the first invalid field."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "q")
       (params
        .
        ((requestedSchema
          .
          ((type . "object")
           (required . ["first" "second"])
           (properties
            .
            ((first . ((type . "string")))
             (second . ((type . "string")))))))))))
    (let ((submit
           (cl-find
            'accept
            omnigent-conversation--widgets
            :key
            (lambda (widget) (widget-get widget :response-action)))))
      (omnigent-conversation--submit-widget submit)
      (should (= (how-many "Required" (point-min) (point-max)) 2))
      (should
       (= (point)
          (widget-get
           (cl-find
            "first"
            omnigent-conversation--widgets
            :key
            (lambda (widget) (widget-get widget :field-name))
            :test #'equal)
           :from))))))

(ert-deftest omnigent-conversation-questions-other-and-multiple-values
    ()
  "Use question IDs and transmit editable Other answers and multiple choices."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "q")
       (params
        .
        ((policy_name . "codex_native_request_user_input")
         (message . "Codex needs input")
         (ask_user_question
          .
          ((questions
            .
            [((id . "choice")
              (question . "Pick")
              (isOther . t)
              (options . [((label . "One"))]))
             ((id . "many")
              (question . "Several")
              (multiSelect . t)
              (isOther . :json-false)
              (options . [((label . "A")) ((label . "B"))]))])))))))
    (should
     (string-match-p
      "# Question\n\n> Codex needs input" (buffer-string)))
    (should (string-match-p "Submit" (buffer-string)))
    (dolist (entry '(("choice" . "Custom") ("many" . ("A" "B"))))
      (let ((field
             (cl-find
              (car entry)
              omnigent-conversation--widgets
              :key
              (lambda (widget) (widget-get widget :field-name))
              :test #'equal)))
        (widget-value-set field (cdr entry))
        (omnigent-conversation--field-notify field)))
    (should-not (omnigent-conversation-elicitation-validate "q"))
    (let (payload)
      (cl-letf (((symbol-function 'omnigent-transport--request)
                 (lambda (_session-id _method _path _callback data)
                   (setq payload data))))
        (omnigent-conversation-elicitation-submit "q" 'accept nil))
      (let ((content (alist-get "content" payload nil nil #'equal)))
        (should (equal (gethash "choice" content) "Custom"))
        (should (equal (gethash "many" content) ["A" "B"]))))))

(ert-deftest
    omnigent-conversation-external-url-has-no-response-actions
    ()
  "Render external URLs as links and internal approval URLs as actions."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "external")
       (params . ((url . "https://example.test/")))))
    (should-not
     (cl-some
      (lambda (widget)
        (widget-get widget :response-action))
      omnigent-conversation--widgets))
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "approval")
       (params . ((url . "/approve/id")))))
    (goto-char omnigent-conversation--request-start)
    (should
     (search-forward "# Approval required\n\n[Approve] [Decline]"
                     omnigent-conversation--pending-start t))))

(ert-deftest
    omnigent-conversation-approval-card-renders-structured-command-details
    ()
  "Render command details as Markdown and keep the response buttons active."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "command")
       (params
        .
        ((policy_name . "internal-policy")
         (phase . "internal-phase")
         (content_preview . "raw-preview")
         (message . "Run a command")
         (reason . "First line\nSecond line")
         (command . "printf '%s' value")
         (cwd . "/work tree")))))
    (goto-char omnigent-conversation--request-start)
    (should
     (looking-at-p
      (regexp-quote
       (concat
        "# Approval required\n\n> First line\n> Second line\n\n"
        "```\nprintf '%s' value\n```\n\n> cwd: `/work tree`\n\n[Approve] [Decline]"))))
    (should
     (get-text-property (point) 'omnigent-conversation-markdown-done))
    (should (equal (get-text-property (point) 'line-prefix) "   "))
    (should (equal (get-text-property (point) 'wrap-prefix) "   "))
    (should-not
     (re-search-forward
      "internal-policy\\|internal-phase\\|raw-preview"
      omnigent-conversation--pending-start t))
    (should
     (equal
      (mapcar
       (lambda (widget)
         (widget-get widget :response-action))
       omnigent-conversation--widgets)
      '(decline accept)))))

(ert-deftest
    omnigent-conversation-composer-continuation-indentation-is-display-only
    ()
  "Indent both explicit and visual continuations without changing sent text."
  (omnigent-conversation-test--buffer
    (should
     (= (+ (string-width
            (overlay-get
             omnigent-conversation--busy-overlay 'before-string))
           (- omnigent-conversation--prompt-start
              omnigent-conversation--composer-label))
        3))
    (insert "first\nsecond")
    (should
     (equal
      (buffer-substring-no-properties
       omnigent-conversation--prompt-start (point-max))
      "first\nsecond"))
    (should-not
     (get-text-property
      omnigent-conversation--prompt-start 'line-prefix))
    (should
     (equal
      (get-text-property
       (+ omnigent-conversation--prompt-start 6) 'line-prefix)
      "   "))
    (should
     (equal
      (get-text-property
       omnigent-conversation--prompt-start 'wrap-prefix)
      "   "))))

(ert-deftest omnigent-diff-reuses-buffer-and-keeps-it-on-failure ()
  "Reuse successful diff buffers and leave existing contents on failed fetch."
  (save-window-excursion
    (let (buffer)
      (unwind-protect
          (progn
            (omnigent--diff-result
             "diff-test" "file" 200 "first diff\n")
            (setq buffer (current-buffer))
            (should (derived-mode-p 'diff-mode))
            (omnigent--diff-result "diff-test" "file" 500 "bad")
            (should (equal (buffer-string) "first diff\n"))
            (omnigent--diff-result
             "diff-test" "file" 200 "new diff\n")
            (should (eq buffer (current-buffer)))
            (should (equal (buffer-string) "new diff\n")))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest omnigent-workspace-diff-keymaps ()
  "Run the patch handler in the session diff buffer from both keymaps."
  (let ((omnigent-sessions
         '(((id . "diff-test")
            (title . "Diff test")
            (workspace . "/workspace")
            (host_id . "runner"))))
        (omnigent-host-address-function (lambda (_) "127.0.0.1"))
        calls)
    (let ((omnigent-workspace-diff-function
           (lambda (patch)
             (push (list
                    patch default-directory (buffer-name))
                   calls))))
      (cl-letf (((symbol-function 'omnigent-workspace--fetch-diff)
                 (lambda (id callback)
                   (should (equal id "diff-test"))
                   (funcall callback 200 "workspace patch"))))
        (omnigent-conversation-test--buffer
          (setq omnigent-conversation-session-id "diff-test")
          (call-interactively (key-binding (kbd "C-c C-g"))))
        (unwind-protect
            (with-current-buffer (get-buffer-create
                                  "*omnigent-sessions*")
              (omnigent-session-mode)
              (omnigent-session-render)
              (goto-char (point-min))
              (should (search-forward "Diff test" nil t))
              (call-interactively (key-binding (kbd "C-c C-g"))))
          (kill-buffer "*omnigent-sessions*")
          (when-let* ((buffer
                       (get-buffer
                        "*omnigent-diff: diff-test:workspace*")))
            (kill-buffer buffer)))))
    (should
     (equal
      calls
      '(("workspace patch"
         "/workspace/"
         "*omnigent-diff: diff-test:workspace*")
        ("workspace patch"
         "/workspace/"
         "*omnigent-diff: diff-test:workspace*"))))))

(ert-deftest omnigent-workspace-diff-fetches-and-displays-server-patch
    ()
  "Display the patch from the changed path and file contents returned by the server."
  (let (paths
        displayed)
    (omnigent-conversation-test--buffer
      (cl-letf (((symbol-function 'omnigent-transport--request)
                 (lambda (_id method path callback &optional _)
                   (should (equal method "GET"))
                   (push path paths)
                   (if (string-suffix-p "/changes" path)
                       (funcall callback
                                200
                                '((data
                                   . [((path . "src/some file"))])))
                     (funcall callback
                              200
                              '((before . "old\n")
                                (after . "new\n"))))))
                ((symbol-function 'pop-to-buffer)
                 (lambda (buffer &rest _) (setq displayed buffer))))
        (call-interactively (key-binding (kbd "C-c C-g")))
        (should
         (equal
          (nreverse paths)
          '("/v1/sessions/conv_test/resources/environments/default/changes"
            "/v1/sessions/conv_test/resources/environments/default/diff/src/some%20file")))
        (should (buffer-live-p displayed))
        (unwind-protect
            (with-current-buffer displayed
              (should (equal omnigent--workspace-id "conv_test"))
              (should (string-search "-old\n+new\n" (buffer-string))))
          (kill-buffer displayed))))))

(ert-deftest omnigent-workspace-diff-directory ()
  "Use the mapped workspace root for the diff buffer."
  (save-window-excursion
    (let ((omnigent-sessions
           '(((id . "mapping")
              (host_id . "runner")
              (workspace . "/workspace"))))
          (omnigent-host-address-function
           (lambda (_id) "runner.example"))
          buffer)
      (unwind-protect
          (progn
            (omnigent--diff-result "mapping" "src/file" 200 "diff\n")
            (setq buffer (current-buffer))
            (should
             (equal
              default-directory "/ssh:runner.example:/workspace/")))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest omnigent-session-list-opens-on-first-connection ()
  "Open the session list only after the first successful connection."
  (save-window-excursion
    (let ((omnigent-sessions-updates nil)
          (omnigent--idle-timer nil)
          (omnigent-open-session-list-on-connect t)
          opened)
      (unwind-protect
          (cl-letf (((symbol-function
                      'omnigent-transport-start-session-updates)
                     (lambda (_frame _error callback)
                       (setq opened callback)
                       'updates))
                    ((symbol-function 'omnigent-sessions-refresh)
                     #'ignore)
                    ((symbol-function
                      'omnigent-sessions-refresh-projects)
                     #'ignore)
                    ((symbol-function 'run-with-idle-timer) #'ignore))
            (omnigent--start)
            (should-not (get-buffer-window "*omnigent-sessions*"))
            (funcall opened)
            (should (get-buffer-window "*omnigent-sessions*"))
            (omnigent-session-list)
            (should-not (get-buffer-window "*omnigent-sessions*"))
            (funcall opened)
            (should-not (get-buffer-window "*omnigent-sessions*")))
        (when-let* ((buffer (get-buffer "*omnigent-sessions*")))
          (kill-buffer buffer))))))

(ert-deftest omnigent-session-list-stays-closed-when-disabled ()
  "Keep the session list closed when automatic opening is disabled."
  (save-window-excursion
    (let ((omnigent-sessions-updates nil)
          (omnigent--idle-timer nil)
          (omnigent-open-session-list-on-connect nil)
          opened)
      (cl-letf (((symbol-function
                  'omnigent-transport-start-session-updates)
                 (lambda (_frame _error callback)
                   (setq opened callback)
                   'updates))
                ((symbol-function 'omnigent-sessions-refresh)
                 #'ignore)
                ((symbol-function 'omnigent-sessions-refresh-projects)
                 #'ignore)
                ((symbol-function 'run-with-idle-timer) #'ignore))
        (omnigent--start)
        (funcall opened)
        (should-not (get-buffer-window "*omnigent-sessions*"))))))

(ert-deftest omnigent-idle-timer-stops-on-reset ()
  "Start one ten-second idle timer even with hidden views and cancel on reset."
  (let ((omnigent--idle-timer nil)
        (omnigent-sessions-updates 'updates)
        (calls 0)
        canceled)
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (seconds repeat function)
                 (should (= seconds 10))
                 (should repeat)
                 (should (eq function #'omnigent-sessions-refresh))
                 (cl-incf calls)
                 'timer))
              ((symbol-function 'timerp)
               (lambda (timer) (eq timer 'timer)))
              ((symbol-function 'cancel-timer)
               (lambda (timer) (setq canceled timer))))
      (omnigent--start)
      (omnigent--start)
      (should (= calls 1))
      (omnigent--reset)
      (should (eq canceled 'timer))
      (should-not omnigent--idle-timer))))

(ert-deftest omnigent-session-selected-title-keeps-state-face ()
  "Add bold to the selected title without losing its archived state face."
  (let ((omnigent-sessions
         '(((id . "selected")
            (title . "Title")
            (archived . t)
            (status . "running"))))
        (omnigent-session--selected-session "selected")
        (omnigent-sessions-truncated nil))
    (unwind-protect
        (with-current-buffer (get-buffer-create "*omnigent-sessions*")
          (omnigent-session-mode)
          (omnigent-session-render)
          (should
           (equal
            (get-text-property
             (1- (search-forward "Title")) 'face)
            '(bold omnigent-session-archived))))
      (kill-buffer "*omnigent-sessions*"))))

(ert-deftest omnigent-session-side-window-size ()
  "Pass the configured width to the session side window."
  (let ((omnigent-side-window-width 32)
        action)
    (unwind-protect
        (cl-letf (((symbol-function 'display-buffer-in-side-window)
                   (lambda (_buffer settings)
                     (setq action settings))))
          (omnigent-session-list)
          (should (equal (alist-get 'window-width action) 32)))
      (when-let* ((buffer (get-buffer "*omnigent-sessions*")))
        (kill-buffer buffer)))))

(ert-deftest omnigent-open-keeps-session-side-window ()
  "Open the selected conversation in the main window, leaving sessions visible."
  (save-window-excursion
    (let ((omnigent-sessions
           '(((id . "side-test") (title . "Side test"))))
          (omnigent-sessions--buffers nil)
          (omnigent-session--selected-session nil)
          buffer)
      (cl-letf (((symbol-function
                  'omnigent-transport-start-session-stream)
                 (lambda (&rest _) nil)))
        (unwind-protect
            (progn
              (omnigent-session-list)
              (select-window
               (get-buffer-window "*omnigent-sessions*"))
              (forward-line 1)
              (omnigent-session-open-at-point)
              (setq buffer (current-buffer))
              (should (derived-mode-p 'omnigent-conversation-mode))
              (should-not
               (window-parameter (selected-window) 'window-side))
              (should (get-buffer-window "*omnigent-sessions*")))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))
          (when (get-buffer "*omnigent-sessions*")
            (kill-buffer "*omnigent-sessions*")))))))

(ert-deftest omnigent-conversation-incoming-request-keeps-field-point
    ()
  "Preserve edited field text and its cursor offset when another request arrives."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "first")
       (params
        .
        ((requestedSchema
          .
          ((type . "object")
           (properties . ((name . ((type . "string")))))))))))
    (let ((field
           (cl-find
            "name"
            omnigent-conversation--widgets
            :key
            (lambda (widget) (widget-get widget :field-name))
            :test #'equal)))
      (widget-value-set field "Alice")
      (omnigent-conversation--field-notify field)
      (goto-char (+ (widget-get field :from) 2)))
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "second") (params . ((message . "Next")))))
    (let ((field
           (cl-find
            "name"
            omnigent-conversation--widgets
            :key
            (lambda (widget) (widget-get widget :field-name))
            :test #'equal)))
      (should (= (point) (+ (widget-get field :from) 2)))
      (should (equal (widget-value field) "Alice")))))

(ert-deftest
    omnigent-conversation-stream-final-keeps-expanded-provisional-fold
    ()
  "Retain a user-expanded fold when the final server item adopts its stable ID."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--event
     "response.in_progress" '((response . ((id . "turn")))))
    (omnigent-conversation--event
     "response.reasoning_text.delta" '((delta . "think")))
    (omnigent-conversation--transcript-flush (current-buffer))
    (omnigent-conversation--fold-button (button-at (point-min)))
    (omnigent-conversation--event
     "response.output_item.done"
     '((item
        .
        ((id . "final")
         (type . "reasoning")
         (content . "thinking")
         (response_id . "turn")))))
    (omnigent-conversation--transcript-flush (current-buffer))
    (should (gethash "final" omnigent-conversation--folds))
    (goto-char (point-min))
    (forward-line 1)
    (should-not (invisible-p (point)))))

(ert-deftest omnigent-session-resources-follow-their-session-fold ()
  "Add resources to the owning branch and preserve its fold through updates."
  (let ((omnigent-sessions '(((id . "parent") (title . "Polly"))))
        (omnigent-sessions--children (make-hash-table :test 'equal))
        (omnigent-session--pull-requests
         (make-hash-table :test 'equal))
        (omnigent-session--pull-requests-pending
         (make-hash-table :test 'equal))
        (url "https://github.com/example/project/pull/42")
        request
        opened)
    (puthash
     "parent"
     '(((id . "child") (title . "Implement fix")))
     omnigent-sessions--children)
    (unwind-protect
        (with-current-buffer (get-buffer-create "*omnigent-sessions*")
          (omnigent-session-mode)
          (omnigent-session-render)
          (should (re-search-forward "^      Implement fix" nil t))
          (should-not (omnigent-session--session-branch-p "child"))
          (cl-letf (((symbol-function 'omnigent-transport--request)
                     (lambda (id method path callback &optional _)
                       (should
                        (equal
                         (list id method path)
                         '("child"
                           "GET"
                           "/v1/sessions/child/pull-requests")))
                       (setq request callback))))
            (omnigent-session--refresh-pull-requests "child")
            (funcall request
                     200
                     `((data
                        .
                        [((url . ,url)
                          (number . 42)
                          (state . "OPEN")
                          (title . "Parser fix"))]))))
          (should (looking-at "    ▾ Implement fix"))
          (forward-line 1)
          (should
           (looking-at-p
            (concat (regexp-quote "        PR #42 [open]") "$")))
          (cl-letf (((symbol-function 'browse-url)
                     (lambda (target &rest _) (setq opened target))))
            (button-activate (button-at (+ (point) 8)))
            (should (equal opened url))
            (setq opened nil)
            (call-interactively (key-binding (kbd "RET")))
            (should (equal opened url)))
          (cl-letf
              (((symbol-function 'omnigent-transport--request)
                (lambda (_id _method _path callback &optional _)
                  (funcall
                   callback
                   200
                   `((data
                      .
                      [((url . ,url)
                        (number . 42)
                        (state . "MERGED")
                        (title . "Parser fix"))
                       ((url
                         .
                         "https://github.com/example/project/pull/43")
                        (number . 43)
                        (state . "OPEN")
                        (title . "Second fix"))]))))))
            (omnigent-session--refresh-pull-requests "child"))
          (should
           (looking-at-p
            (concat (regexp-quote "        PR #42 [merged]") "$")))
          (save-excursion
            (forward-line 1)
            (should
             (looking-at-p
              (concat (regexp-quote "        PR #43 [open]") "$"))))
          (forward-line -1)
          (omnigent-session-toggle-tree)
          (omnigent-session-render)
          (should (looking-at "    ▸ Implement fix"))
          (should-not (search-forward "#42" nil t))
          (omnigent-session-toggle-tree)
          (should (search-forward "PR #42 [merged]" nil t)))
      (when-let* ((buffer (get-buffer "*omnigent-sessions*")))
        (kill-buffer buffer)))))

(ert-deftest omnigent-session-pr-status-faces ()
  "Keep the PR number linked and underline each status in its own face."
  (let ((omnigent-session--pull-requests
         (make-hash-table :test 'equal))
        (url "https://github.com/example/project/pull/42"))
    (dolist (entry
             '(("OPEN" . success)
               ("MERGED" . omnigent-session-archived)
               ("CLOSED" . error)))
      (puthash
       "items"
       `(((url . ,url) (number . 42) (state . ,(car entry))))
       omnigent-session--pull-requests)
      (with-temp-buffer
        (omnigent-session--insert-session-row
         '((id . "items") (title . "Fix parser")) 80 0 nil)
        (goto-char (point-min))
        (search-forward "PR #42 ")
        (should (eq (get-text-property (- (point) 2) 'face) 'link))
        (should
         (equal
          (get-text-property (point) 'face)
          `(:inherit ,(cdr entry) :underline t)))
        (should (button-at (point)))))))

(ert-deftest omnigent-session-pr-diff ()
  "Use the owning session on a PR row and fetch the PR patch with d."
  (let ((omnigent-session--pull-requests
         (make-hash-table :test 'equal))
        (omnigent-sessions '(((id . "items") (title . "Fix parser"))))
        (url "https://github.com/example/project/pull/42")
        displayed)
    (puthash
     "items"
     `(((url . ,url) (number . 42)))
     omnigent-session--pull-requests)
    (unwind-protect
        (with-current-buffer (get-buffer-create "*omnigent-sessions*")
          (omnigent-session-mode)
          (omnigent-session-render)
          (should (search-forward "#42" nil t))
          (should
           (equal (omnigent-workspace--session-at-point) "items"))
          (should
           (equal
            (omnigent--action-target) '("items" . "Fix parser")))
          (cl-letf
              (((symbol-function 'omnigent-transport--request)
                (lambda (id method path callback &optional _)
                  (should (equal (list id method) '("items" "GET")))
                  (should
                   (equal
                    path
                    (concat
                     "/v1/sessions/items/resources/github/diff?pr_url="
                     (url-hexify-string url))))
                  (funcall callback 200 '((patch . "PR patch")))))
               ((symbol-function 'omnigent--diff-result)
                (lambda (id target status patch)
                  (setq displayed (list id target status patch)))))
            (call-interactively (key-binding (kbd "d")))
            (should
             (equal displayed (list "items" url 200 "PR patch")))))
      (kill-buffer "*omnigent-sessions*"))))

(ert-deftest omnigent-removal-freezes-draft-and-rejects-late-prs ()
  "Freeze a removed session and discard its pending PR response."
  (omnigent-conversation-test--buffer
    (insert "keep draft")
    (let ((omnigent-sessions--buffers
           (list (cons "conv_test" (current-buffer))))
          (omnigent-session--pull-requests
           (make-hash-table :test 'equal))
          (omnigent-session--pull-requests-pending
           (make-hash-table :test 'equal))
          callback)
      (cl-letf (((symbol-function 'omnigent-transport--request)
                 (lambda (_id _method _path cb &optional _)
                   (setq callback cb))))
        (omnigent-session--refresh-pull-requests "conv_test"))
      (omnigent--frame '((type . "removed") (ids . ["conv_test"])))
      (should buffer-read-only)
      (should-error (omnigent-conversation-send) :type 'user-error)
      (should (string-suffix-p "keep draft" (buffer-string)))
      (funcall callback
               200
               '((data . [((url . "https://example.com/pr"))])))
      (should-not
       (gethash "conv_test" omnigent-session--pull-requests)))))

(ert-deftest
    omnigent-conversation-send-uses-server-state-not-session-status
    ()
  "Display queued input for every session status and commit it exactly once."
  (dolist (status '("idle" "running" "waiting" "failed" nil))
    (omnigent-conversation-test--buffer
      (let ((omnigent-sessions
             `(((id . "conv_test") (status . ,status)))))
        (insert "sent message")
        (cl-letf (((symbol-function
                    'omnigent-transport-post-session-event)
                   (lambda (_id _event callback)
                     (funcall callback
                              202
                              '((queued . t)
                                (pending_id . "pending"))))))
          (omnigent-conversation-send))
        (should-not omnigent-conversation--order)
        (should
         (string-match-p
          "\\[queued\\] > sent message" (buffer-string)))
        (omnigent-conversation-test--consume
         "committed" "sent message"
         "pending")
        (omnigent-conversation-test--consume
         "committed" "sent message"
         "pending")
        (should-not omnigent-conversation--pending-inputs)
        (should (equal omnigent-conversation--order '("committed")))
        (should (= (how-many "You:" (point-min) (point-max)) 1))))))

(ert-deftest omnigent-conversation-snapshot-hides-resource-events ()
  "Do not render resource events as empty agent messages after refresh."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--snapshot
     200
     '((items
        .
        [((id . "resource")
          (type . "resource_event")
          (event_type . "session.resource.created"))
         ((id . "user")
          (type . "message")
          (role . "user")
          (content . "Hello"))])
       (pending_inputs . []) (pending_elicitations . [])))
    (omnigent-conversation--transcript-render)
    (should
     (equal
      (buffer-substring-no-properties
       (point-min) omnigent-conversation--request-start)
      "You:\nHello\n\n"))))

(ert-deftest omnigent-conversation-transcript-renders-error-messages
    ()
  "Show committed diagnostic messages and live error text in the transcript."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--snapshot
     200
     '((items
        .
        [((id . "diagnostic")
          (type . "error")
          (message . "Model unavailable."))])
       (pending_inputs . []) (pending_elicitations . [])))
    (omnigent-conversation--event
     "response.error" '((error . "Live stream error.")))
    (omnigent-conversation--transcript-render)
    (should
     (equal
      (buffer-substring-no-properties
       (point-min) omnigent-conversation--request-start)
      "Error:\nModel unavailable.\n\nError:\nLive stream error.\n\n"))))

(ert-deftest
    omnigent-conversation-scrolled-transcript-keeps-reading-position
    ()
  "Preserve point by item ID when transcript output is refreshed above the composer."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--snapshot
     200
     '((items
        .
        [((id . "first")
          (type . "message")
          (content . "first text"))
         ((id . "second")
          (type . "message")
          (content . "second text"))])
       (pending_inputs . []) (pending_elicitations . [])))
    (goto-char (point-min))
    (search-forward "second te")
    (let ((offset
           (- (point)
              (previous-single-property-change
               (point) 'omnigent-conversation-item-id))))
      (omnigent-conversation--snapshot
       200
       '((items
          .
          [((id . "first")
            (type . "message")
            (content . "a longer first text"))
           ((id . "second")
            (type . "message")
            (content . "second text"))])
         (pending_inputs . []) (pending_elicitations . [])))
      (should
       (equal
        (get-text-property
         (point) 'omnigent-conversation-item-id)
        "second"))
      (should
       (= offset
          (- (point)
             (previous-single-property-change
              (point) 'omnigent-conversation-item-id)))))))

(ert-deftest omnigent-conversation-initial-history-shows-context ()
  "Show recent history above the composer when a session first loads."
  (save-window-excursion
    (omnigent-conversation-test--buffer
      (switch-to-buffer (current-buffer))
      (omnigent-conversation--snapshot
       200
       `((items
          .
          [((id . "history")
            (content
             .
             ,(mapconcat #'number-to-string (number-sequence 1 100)
                         "\n")))])
         (pending_inputs . []) (pending_elicitations . [])))
      (should
       (< (window-start) omnigent-conversation--composer-label))
      (should omnigent-conversation--history-positioned))))

(ert-deftest omnigent-conversation-history-reserves-prompt-columns ()
  "Align history text and fold indicators with the composer."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--snapshot
     200
     '((items
        .
        [((id . "message") (content . "text"))
         ((id . "reason")
          (type . "reasoning")
          (content . "thought"))])
       (pending_inputs . []) (pending_elicitations . [])))
    (goto-char (point-min))
    (should (equal (get-text-property (point) 'line-prefix) "   "))
    (search-forward "▶")
    (should
     (equal (get-text-property (1- (point)) 'line-prefix) "  "))
    (forward-line 1)
    (should (equal (get-text-property (point) 'line-prefix) "   "))
    (should (equal (get-text-property (point) 'wrap-prefix) "   "))))

(ert-deftest
    omnigent-conversation-transcript-shortened-item-keeps-point
    ()
  "Keep point inside its transcript item when that item becomes shorter."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--snapshot
     200
     '((items
        .
        [((id . "first") (content . "a long first item"))
         ((id . "second") (content . "second item"))])
       (pending_inputs . []) (pending_elicitations . [])))
    (goto-char (point-min))
    (search-forward "long first item")
    (omnigent-conversation--snapshot
     200
     '((items
        .
        [((id . "first") (content . "x"))
         ((id . "second") (content . "second item"))])
       (pending_inputs . []) (pending_elicitations . [])))
    (should
     (equal
      (get-text-property
       (point) 'omnigent-conversation-item-id)
      "first"))))

(ert-deftest
    omnigent-conversation-transcript-does-not-recenter-reading-point
    ()
  "Preserve the view for transcript and composer point without forced recentering."
  (save-window-excursion
    (omnigent-conversation-test--buffer
      (set-window-buffer (selected-window) (current-buffer))
      (omnigent-conversation--snapshot
       200
       '((items . [((id . "first") (content . "text"))])
         (pending_inputs . [])
         (pending_elicitations . [])))
      (dolist (position
               (list (point-min) omnigent-conversation--prompt-start))
        (goto-char position)
        (let ((recentered nil)
              (start (window-start)))
          (cl-letf (((symbol-function 'window-end)
                     (lambda (&rest _) (point-max)))
                    ((symbol-function 'recenter)
                     (lambda (&rest _) (setq recentered t))))
            (omnigent-conversation--transcript))
          (should-not recentered)
          (should (= (point) position))
          (should (= (window-start) start)))))))

(ert-deftest omnigent-conversation-composer-line-start-stays-in-input
    ()
  "Keep line-start motion and deletion inside the editable composer."
  (omnigent-conversation-test--buffer
    (insert "first\nsecond")
    (goto-char (+ omnigent-conversation--prompt-start 2))
    (beginning-of-line)
    (should (= (point) omnigent-conversation--prompt-start))
    (kill-line)
    (should
     (equal
      (buffer-substring-no-properties
       omnigent-conversation--prompt-start (point-max))
      "\nsecond"))
    (should
     (equal
      (buffer-substring-no-properties
       omnigent-conversation--composer-label
       omnigent-conversation--prompt-start)
      "> "))))

(ert-deftest omnigent-conversation-composer-evil-line-edits ()
  "Keep the prompt protected while Evil changes or deletes composer lines."
  (require 'evil)
  (dolist (case
           '(("first\nsecond" "dd" "second")
             ("first" "dd" "")
             ("" "dd" "")
             ("first\nsecond" "2dd" "")
             ("first\nsecond" "ccnew <escape>" "new\nsecond")
             ("first" "ccnew <escape>" "new\n")
             ("" "ccnew <escape>" "new\n")
             ("first\nsecond\nthird" "2ccnew <escape>" "new\nthird")
             ("first\nsecond" "Vd" "second")
             ("first\nsecond" "Vcnew <escape>" "new\nsecond")
             ("first\nsecond" "D" "\nsecond")
             ("first\nsecond" "Cnew <escape>" "new\nsecond")))
    (ert-info
     ((format "Input and keys: %S" case))
     (omnigent-conversation-test--buffer
       (save-window-excursion
         (switch-to-buffer (current-buffer))
         (omnigent-conversation--snapshot
          200
          '((items . [((id . "history") (content . "protected"))])
            (pending_inputs . [])
            (pending_elicitations . [])))
         (insert (car case))
         (goto-char omnigent-conversation--prompt-start)
         (evil-local-mode 1)
         (unwind-protect
             (progn
               (evil-normal-state)
               (execute-kbd-macro (kbd (cadr case)))
               (should
                (equal
                 (buffer-substring-no-properties
                  omnigent-conversation--prompt-start (point-max))
                 (nth 2 case)))
               (should
                (equal
                 (buffer-substring-no-properties
                  omnigent-conversation--composer-label
                  omnigent-conversation--prompt-start)
                 "> "))
               (goto-char (point-min))
               (should-error (delete-char 1) :type 'text-read-only))
           (evil-local-mode -1)))))))

(ert-deftest
    omnigent-conversation-rejected-edit-does-not-lock-composer
    ()
  "A rejected transcript edit must not install widget-only editing on the composer."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--event
     "response.output_item.done"
     '((item . ((id . "a") (content . "protected")))))
    (goto-char (point-min))
    (should-error (insert "forbidden") :type 'text-read-only)
    (run-hooks 'post-command-hook)
    (goto-char (point-max))
    (insert "still editable")
    (should (string-suffix-p "still editable" (buffer-string)))))

(ert-deftest omnigent-conversation-real-field-edit-updates-draft ()
  "Normal field typing must update request state without explicit notification."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "q")
       (params
        .
        ((requestedSchema
          .
          ((type . "object")
           (properties . ((name . ((type . "string")))))))))))
    (let ((field
           (cl-find
            "name"
            omnigent-conversation--widgets
            :key
            (lambda (widget) (widget-get widget :field-name))
            :test #'equal)))
      (goto-char (widget-field-start field))
      (insert "typed")
      (should
       (equal
        (gethash
         "name" (omnigent-conversation-elicitation-draft "q"))
        "typed")))))

(defun omnigent-conversation-test--consume
    (id text &optional pending-id meta)
  "Deliver consumption of ID with TEXT, optional PENDING-ID and META flag."
  (omnigent-conversation--event
   "session.input.consumed"
   `((data
      .
      ((item_id . ,id)
       (type . "message") (cleared_pending_id . ,pending-id)
       (data
        . ((role . "user") (content . ,text) (is_meta . ,meta))))))))

(ert-deftest omnigent-conversation-hides-sub-agent-notices ()
  "Hide sub-agent notices from live events and snapshots."
  (omnigent-conversation-test--buffer
    (let
        ((notice
          "[System: sub-agent pi/inspect-upstream-mock-deps finished (completed) — 1 result waiting in inbox. Call sys_read_inbox to collect.]"))
      (omnigent-conversation-test--consume "live" notice)
      (should-not (string-match-p "You:\n" (buffer-string)))
      (should-not
       (string-match-p (regexp-quote notice) (buffer-string)))
      (omnigent-conversation--snapshot
       200
       '((items
          .
          [((id . "saved")
            (type . "message")
            (data
             .
             ((role . "user")
              (content . "[System: sub-agent finished]"))))
           ((id . "user")
            (type . "message")
            (role . "user")
            (content . "[System: example]"))])
         (pending_inputs . []) (pending_elicitations . [])))
      (omnigent-conversation--transcript-render)
      (should
       (equal
        (buffer-substring-no-properties
         (point-min) omnigent-conversation--request-start)
        "You:\n[System: example]\n\n")))))

(ert-deftest omnigent-conversation-pending-order-forms-and-draft ()
  "Keep output, forms, queued input and composer separate."
  (omnigent-conversation-test--buffer
    (let ((next 0))
      (cl-letf (((symbol-function
                  'omnigent-transport-post-session-event)
                 (lambda (_id _event callback)
                   (funcall callback
                            202
                            `((queued . t)
                              (pending_id
                               .
                               ,(number-to-string
                                 (cl-incf next))))))))
        (dolist (text '("first" "second"))
          (goto-char (point-max))
          (insert text)
          (omnigent-conversation-send))))
    (insert "draft")
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "q") (params . ((message . "Approval")))))
    (omnigent-conversation--event
     "response.output_item.done"
     '((item . ((id . "answer") (content . "output")))))
    (should
     (string-match-p
      "output\n\n# Question\n\n> Approval" (buffer-string)))
    (should
     (string-match-p
      "\\[queued\\] > first\n\n\\[queued\\] > second\n\n> draft"
      (buffer-string)))
    (should (= (point) (point-max)))
    (goto-char omnigent-conversation--pending-start)
    (should-error (insert "edit") :type 'text-read-only)
    (run-hooks 'post-command-hook)
    (should
     (equal
      (buffer-substring-no-properties
       omnigent-conversation--prompt-start (point-max))
      "draft"))
    (omnigent-conversation--event
     "response.elicitation_resolved" '((elicitation_id . "q")))
    (should
     (string-match-p
      "output\n\n\\[queued\\] > first" (buffer-string)))
    (omnigent-conversation-test--consume "first" "first" "1")
    (should (= (length omnigent-conversation--pending-inputs) 1))))

(ert-deftest
    omnigent-conversation-new-transcript-items-stay-above-queued-inputs
    ()
  "Keep new transcript items above queued input."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--event
     "response.created" '((response . ((id . "active")))))
    (cl-letf (((symbol-function
                'omnigent-transport-post-session-event)
               (lambda (_id _event callback)
                 (funcall callback
                          202
                          '((queued . t) (pending_id . "p"))))))
      (insert "queued")
      (omnigent-conversation-send))
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "q") (params . ((message . "Question")))))
    (omnigent-conversation--event
     "response.output_text.delta" '((delta . "current message")))
    (omnigent-conversation--transcript-flush (current-buffer))
    (should
     (= (overlay-start omnigent-conversation--busy-overlay)
        (marker-position omnigent-conversation--composer-label)))
    (should
     (overlay-get omnigent-conversation--busy-overlay 'before-string))
    (should
     (< (string-match "Agent:\ncurrent message" (buffer-string))
        (string-match "\\[queued\\] > queued" (buffer-string))))))

(ert-deftest omnigent-conversation-consumption-before-post-response ()
  "Do not recreate consumed input when its POST acknowledgement arrives late."
  (dolist (pending-id '(nil "pending"))
    (omnigent-conversation-test--buffer
      (let (callback)
        (insert "same")
        (cl-letf (((symbol-function
                    'omnigent-transport-post-session-event)
                   (lambda (_id _event cb) (setq callback cb))))
          (omnigent-conversation-send))
        (omnigent-conversation-test--consume "committed" "same"
                                             pending-id)
        (insert " suffix")
        (with-temp-buffer
          (funcall callback
                   202
                   `((queued . t) (pending_id . ,pending-id))))
        (should-not omnigent-conversation--pending-inputs)
        (should (equal omnigent-conversation--order '("committed")))
        (should
         (equal
          (buffer-substring-no-properties
           omnigent-conversation--prompt-start (point-max))
          " suffix"))
        (should (= (how-many "You:" (point-min) (point-max)) 1))))))

(ert-deftest
    omnigent-conversation-snapshot-is-authoritative-for-pending-input
    ()
  "Replace local input records, then ignore already-recovered FIFO consumption."
  (omnigent-conversation-test--buffer
    (insert "draft")
    (setq omnigent-conversation--pending-inputs
          '(((state . queued) (content . "local"))))
    (dolist (cleared-id '("pending-a" nil))
      (setq omnigent-conversation--loading t)
      (omnigent-conversation-test--consume "a" "same" cleared-id)
      (omnigent-conversation--snapshot
       200
       '((items
          .
          [((id . "a")
            (type . "message")
            (data . ((role . "user") (content . "same"))))])
         (pending_inputs
          .
          [((pending_id . "pending-b")
            (content . [((type . "input_text") (text . "same"))]))])
         (pending_elicitations . [])))
      (should (= (length omnigent-conversation--pending-inputs) 1))
      (should
       (equal
        (alist-get
         'pending_id (car omnigent-conversation--pending-inputs))
        "pending-b"))
      (should
       (= (how-many "\\[queued\\] > same" (point-min) (point-max))
          1)))
    (omnigent-conversation-test--consume "unrelated" "other"
                                         "unknown-id")
    (should (= (length omnigent-conversation--pending-inputs) 1))
    (omnigent-conversation--snapshot
     200
     '((items . [])
       (pending_inputs . [])
       (pending_elicitations . [])))
    (should-not omnigent-conversation--pending-inputs)
    (omnigent-conversation--snapshot 500 nil)
    (should omnigent-conversation--invalid)
    (should buffer-read-only)
    (should
     (equal
      (buffer-substring-no-properties
       omnigent-conversation--prompt-start (point-max))
      "draft"))))

(ert-deftest
    omnigent-conversation-fifo-skips-markers-and-keeps-identical-inputs
    ()
  "Only new user consumption can remove one eligible FIFO input."
  (omnigent-conversation-test--buffer
    (setq omnigent-conversation--pending-inputs
          (list
           (list '(state . queued) '(content . "same"))
           (list '(state . queued) '(content . "same"))))
    (omnigent-conversation-test--consume "meta" "injected context"
                                         nil
                                         t)
    (omnigent-conversation-test--consume
     "marker" "[System: task completed]")
    (should (= (length omnigent-conversation--pending-inputs) 2))
    (omnigent-conversation-test--consume "a" "same")
    (should (= (length omnigent-conversation--pending-inputs) 1))
    (omnigent-conversation-test--consume "a" "same")
    (should (= (length omnigent-conversation--pending-inputs) 1))
    (omnigent-conversation-test--consume "b" "same")
    (should-not omnigent-conversation--pending-inputs)
    (should
     (equal
      omnigent-conversation--order '("meta" "marker" "a" "b")))))

(ert-deftest
    omnigent-conversation-send-outcomes-and-late-response-after-snapshot
    ()
  "Trust response IDs, retain uncertain drafts and do not restore superseded input."
  (dolist (response
           '((202 (queued . t) (item_id . "saved"))
             (202 (queued . t) (pending_id . "pending"))
             (202 (denied . t) (reason . "Denied"))
             (403 (detail . "Denied"))
             (nil)
             (500)))
    (omnigent-conversation-test--buffer
      (insert "message")
      (let ((requests 0))
        (cl-letf (((symbol-function
                    'omnigent-transport-post-session-event)
                   (lambda (_id _event callback)
                     (cl-incf requests)
                     (funcall callback
                              (car response)
                              (cdr response)))))
          (call-interactively (key-binding (kbd "C-c C-c")))
          (should (= requests 1))))
      (cond
       ((alist-get 'item_id (cdr response))
        (should (equal omnigent-conversation--order '("saved")))
        (should-not omnigent-conversation--pending-inputs))
       ((alist-get 'pending_id (cdr response))
        (should
         (string-match-p "\\[queued\\] > message" (buffer-string))))
       ((memq (car response) '(nil 500))
        (should
         (string-match-p
          "\\[unconfirmed\\] > message" (buffer-string)))
        (should
         (string-match-p "server may have accepted" (buffer-string))))
       (t
        (should-not
         (string-match-p "\\[queued\\] > message" (buffer-string)))
        (should-not
         (string-match-p
          "\\[unconfirmed\\] > message" (buffer-string)))))
      (should
       (equal
        (buffer-substring-no-properties
         omnigent-conversation--prompt-start (point-max))
        (if (and (equal (car response) 202)
                 (not (eq (alist-get 'denied (cdr response)) t)))
            ""
          "message")))))
  (omnigent-conversation-test--buffer
    (let (callback)
      (insert "message")
      (cl-letf (((symbol-function
                  'omnigent-transport-post-session-event)
                 (lambda (_id _event cb) (setq callback cb))))
        (omnigent-conversation-send))
      (omnigent-conversation--snapshot
       200
       '((pending_inputs . [])
         (items . [])
         (pending_elicitations . [])))
      (funcall callback 202 '((queued . t) (pending_id . "old")))
      (should-not omnigent-conversation--pending-inputs))))

(ert-deftest omnigent-conversation-interrupt-refresh-buffers-events ()
  "Refresh after interruption without losing later buffered consumption events."
  (omnigent-conversation-test--buffer
    (let ((buffer (current-buffer))
          (reads 0))
      (setq omnigent-conversation--stream
            (omnigent-transport--make-stream
             :attempt 1
             :connect-callback
             (lambda ()
               (with-current-buffer buffer
                 (setq
                  omnigent-conversation--loading t
                  omnigent-conversation--pending-events nil)))))
      (cl-letf (((symbol-function
                  'omnigent-transport--stream-load-snapshot)
                 (lambda (stream attempt)
                   (should (eq stream omnigent-conversation--stream))
                   (should (= attempt 1))
                   (cl-incf reads)
                   (funcall
                    (omnigent-stream-connect-callback stream)))))
        ;; An interrupt queued during initial recovery starts another snapshot.
        (setq omnigent-conversation--loading t)
        (omnigent-conversation--event "session.interrupted" nil)
        (omnigent-conversation-test--consume "b" "queued" "pending-b")
        (omnigent-conversation--snapshot
         200
         '((pending_inputs
            . [((pending_id . "pending-b") (content . "queued"))])
           (items . []) (pending_elicitations . [])))
        (should (= reads 1))
        (should omnigent-conversation--loading)
        (should (= (length omnigent-conversation--pending-events) 1))
        (omnigent-conversation--snapshot
         200
         '((pending_inputs
            . [((pending_id . "pending-b") (content . "queued"))])
           (items . []) (pending_elicitations . [])))
        (should-not omnigent-conversation--loading)
        (should-not omnigent-conversation--pending-inputs)
        (should (equal omnigent-conversation--order '("b"))))
      (setf (omnigent-stream-stopped omnigent-conversation--stream)
            t))))

(ert-deftest omnigent-conversation-send-hook-errors-and-raw-failure ()
  "Dispatch despite observer errors and retain a draft on a raw transport failure."
  (omnigent-conversation-test--buffer
    (insert "draft")
    (let ((omnigent-conversation-change-hook
           (list (lambda () (error "Frontend failed"))))
          callback
          warnings)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type text &rest _) (push text warnings)))
                ((symbol-function
                  'omnigent-transport-post-session-event)
                 (lambda (_id _event cb) (setq callback cb))))
        (omnigent-conversation-send)
        (should callback)
        (funcall callback nil "Response lost")
        (should-not omnigent-conversation--sending)
        (should
         (eq
          (alist-get
           'state (car omnigent-conversation--pending-inputs))
          'unconfirmed))
        (should (string-suffix-p "draft" (buffer-string)))
        (should (= (length warnings) 2))))))

(ert-deftest
    omnigent-conversation-invalid-pending-snapshot-keeps-visible-state
    ()
  "Reject malformed queue arrays or identifiers without deleting visible input."
  (dolist (pending
           '(nil
             "invalid"
             [((content . "missing id"))]
             [((pending_id . "id"))]))
    (omnigent-conversation-test--buffer
      (insert "draft")
      (omnigent-conversation--snapshot
       200
       '((pending_inputs
          . [((pending_id . "keep") (content . "queued"))])
         (items . []) (pending_elicitations . [])))
      (omnigent-conversation--snapshot
       200
       `((pending_inputs . ,pending)
         (items . [])
         (pending_elicitations . [])))
      (should
       (equal
        (alist-get
         'pending_id (car omnigent-conversation--pending-inputs))
        "keep"))
      (should
       (string-match-p "\\[queued\\] > queued" (buffer-string)))
      (should (string-suffix-p "draft" (buffer-string))))))

(ert-deftest
    omnigent-conversation-select-model-and-effort-from-session-catalog
    ()
  "Fetch choices asynchronously and patch the selected model or its effort."
  (dolist (setting '(model effort))
    (omnigent-conversation-test--buffer
      (let (loaded
            prompted
            request)
        (cl-letf (((symbol-function 'omnigent-transport-get-session)
                   (lambda (_id callback) (setq loaded callback)))
                  ((symbol-function 'completing-read)
                   (lambda (_prompt
                            choices _predicate required &rest _)
                     (should required)
                     (should
                      (equal
                       choices
                       (if (eq setting 'model)
                           '("first" "second")
                         '("low" "high"))))
                     (setq prompted t)
                     (if (eq setting 'model)
                         "second"
                       "high")))
                  ((symbol-function 'omnigent-transport--request)
                   (lambda (_session-id method path _callback body)
                     (setq request (list method path body)))))
          (call-interactively
           (if (eq setting 'model)
               #'omnigent-conversation-set-model
             #'omnigent-conversation-set-effort))
          (should loaded)
          (should-not prompted)
          (should-not request)
          (funcall loaded
                   200
                   '((llm_model . "first")
                     (model_options
                      .
                      [((id . "first")
                        (supportedReasoningEfforts
                         .
                         [((reasoningEffort . "low"))
                          ((reasoningEffort . "high"))]))
                       ((id . "second")
                        (supportedReasoningEfforts
                         . [((reasoningEffort . "ultra"))]))])))
          (should prompted)
          (should
           (equal
            request
            (list
             "PATCH" "/v1/sessions/conv_test"
             (if (eq setting 'model)
                 '(("model_override" . "second"))
               '(("reasoning_effort" . "high")))))))))))

(provide 'omnigent-buffers-test)
;;; omnigent-buffers-test.el ends here

(ert-deftest
    omnigent-conversation-transcript-updates-only-changed-blocks
    ()
  "Preserve old text properties while appending and replacing individual items."
  (omnigent-conversation-test--buffer
    (dotimes (index 2000)
      (omnigent-conversation--put-item
       `((id . ,(format "item-%d" index))
         (type . "message")
         (content . "unchanged"))))
    (omnigent-conversation--transcript-render)
    (let ((inhibit-read-only t))
      (put-text-property 1 2 'omnigent-test-retained t))
    (let ((calls 0)
          (render (symbol-function 'omnigent-conversation--item)))
      (cl-letf (((symbol-function 'omnigent-conversation--item)
                 (lambda (&rest arguments)
                   "Count item renders with ARGUMENTS."
                   (cl-incf calls)
                   (apply render arguments))))
        (omnigent-conversation--put-item
         '((id . "new") (type . "message") (content . "new text")))
        (omnigent-conversation--transcript-render)
        (should (= calls 1))
        (setf (alist-get
               'content (gethash "new" omnigent-conversation--items))
              "updated text")
        (omnigent-conversation--transcript-render)
        (should (= calls 2))
        (omnigent-conversation--transcript-render)
        (should (= calls 2))
        (should (get-text-property 1 'omnigent-test-retained))
        (goto-char (point-min))
        (should (search-forward "updated text" nil t))))))

(ert-deftest
    omnigent-conversation-transcript-reconciles-reordered-and-removed-items
    ()
  "Reconcile snapshot removals and reordering without duplicate text."
  (omnigent-conversation-test--buffer
    (dolist (id '("a" "b" "c"))
      (omnigent-conversation--put-item
       `((id . ,id) (type . "message") (content . ,id))))
    (omnigent-conversation--transcript-render)
    (remhash "b" omnigent-conversation--items)
    (setq omnigent-conversation--order '("c" "a"))
    (omnigent-conversation--transcript-render)
    (should
     (equal
      (buffer-substring-no-properties
       (point-min) omnigent-conversation--request-start)
      "Agent:\nc\n\nAgent:\na\n\n"))
    (should (= (hash-table-count omnigent-conversation--blocks) 2))
    (omnigent-conversation--transcript-render)
    (should
     (equal
      (buffer-substring-no-properties
       (point-min) omnigent-conversation--request-start)
      "Agent:\nc\n\nAgent:\na\n\n"))))

(ert-deftest omnigent-conversation-markdown-opens-transcript-links ()
  "Open a rendered agent link with RET or a mouse click."
  (omnigent-conversation-test--buffer
    (omnigent-conversation--put-item
     '((id . "link")
       (type . "message")
       (content . "[Example](https://example.com)")))
    (omnigent-conversation--transcript-render)
    (goto-char (point-min))
    (search-forward "Example")
    (backward-char)
    (omnigent-conversation--markdown-fontify (point-min) (point-max))
    (let ((link-position (point))
          (link-map (get-text-property (point) 'keymap))
          opened)
      (should (eq (lookup-key link-map [follow-link]) 'mouse-face))
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (push url opened))))
        (let ((last-command-event ?\r))
          (call-interactively (key-binding (kbd "RET"))))
        (save-window-excursion
          (set-window-buffer (selected-window) (current-buffer))
          (goto-char (point-min))
          (let ((last-command-event
                 (list
                  'mouse-2
                  (list (selected-window) link-position '(0 . 0) 0))))
            (call-interactively (lookup-key link-map [mouse-2])))))
      (should
       (equal
        opened '("https://example.com" "https://example.com"))))))

(ert-deftest
    omnigent-conversation-markdown-waits-for-message-completion
    ()
  "Keep active text plain and render completed text only when requested."
  (omnigent-conversation-test--buffer
    (setq
     omnigent-conversation--response-id "response"
     omnigent-conversation--section-id "active")
    (omnigent-conversation--put-item
     '((id . "active") (type . "message") (content . "**bold**")))
    (omnigent-conversation--transcript-render)
    (goto-char (point-min))
    (search-forward "**bold**")
    (should-not
     (get-text-property
      (- (point) 5) 'omnigent-conversation-markdown))
    (setq omnigent-conversation--section-id "next")
    (omnigent-conversation--transcript-render)
    (goto-char (point-min))
    (search-forward "**bold**")
    (let ((begin (- (point) 8)))
      (should
       (get-text-property begin 'omnigent-conversation-markdown))
      (should-not
       (get-text-property begin 'omnigent-conversation-markdown-done))
      (omnigent-conversation--markdown-fontify begin (+ begin 2))
      (should
       (get-text-property begin 'omnigent-conversation-markdown-done))
      (should (get-text-property begin 'invisible))
      (should
       (equal
        (buffer-substring-no-properties
         begin (+ begin 8))
        "**bold**"))
      (let ((calls 0))
        (cl-letf (((symbol-function
                    'omnigent-conversation--markdown-apply)
                   (lambda (&rest _arguments)
                     "Count unnecessary repeat renders."
                     (cl-incf calls))))
          (font-lock-fontify-region begin (+ begin 2))
          (should (= calls 0))
          (should (get-text-property (+ begin 2) 'face))))
      (setf (alist-get
             'content
             (gethash "active" omnigent-conversation--items))
            "**corrected**")
      (omnigent-conversation--transcript-render)
      (should-not
       (get-text-property begin 'omnigent-conversation-markdown-done))
      (omnigent-conversation--markdown-fontify begin (+ begin 2))
      (should
       (get-text-property
        begin 'omnigent-conversation-markdown-done)))))

(ert-deftest omnigent-conversation-markdown-composer-preserves-edits
    ()
  "Highlight composer text and invalidate properties after an edit."
  (omnigent-conversation-test--buffer
    (insert "**draft**")
    (let ((begin
           (marker-position omnigent-conversation--prompt-start)))
      (omnigent-conversation--markdown-fontify begin (point-max))
      (should (get-text-property (+ begin 2) 'face))
      (should-not (get-text-property begin 'invisible))
      (should
       (get-text-property begin 'omnigent-conversation-markdown-done))
      (goto-char (point-max))
      (insert " more")
      (should-not
       (get-text-property begin 'omnigent-conversation-markdown-done))
      (omnigent-conversation--markdown-fontify begin (point-max))
      (should
       (equal
        (buffer-substring-no-properties
         begin (point-max))
        "**draft** more")))))

(ert-deftest
    omnigent-conversation-markdown-colon-prose-is-not-metadata
    ()
  "Keep first-paragraph colon prose free of implicit document metadata faces."
  (dolist (hide '(nil t))
    (with-temp-buffer
      (insert "for kind: subscription\n\n**bold** and `code`\n")
      (omnigent-conversation--markdown-apply
       (point-min) (point-max) hide)
      (should-not (get-text-property (point-min) 'face))
      (goto-char (point-min))
      (search-forward "subscription")
      (should-not (get-text-property (1- (point)) 'face))
      (search-forward "bold")
      (should (get-text-property (1- (point)) 'face))
      (search-forward "code")
      (should (get-text-property (1- (point)) 'face)))))

(ert-deftest
    omnigent-session-child-branches-default-open-and-preserve-folds
    ()
  "Display nested branches and move child attention to a folded ancestor."
  (let ((omnigent-sessions '(((id . "parent") (title . "Parent"))))
        (omnigent-sessions--children (make-hash-table :test 'equal))
        (omnigent-sessions--watched-ids '("grandchild"))
        (buffer (get-buffer-create "*omnigent-sessions*")))
    (unwind-protect
        (with-current-buffer buffer
          (omnigent-session-mode)
          (omnigent-session-render)
          (forward-line 1)
          (omnigent-session-toggle-tree)
          (should
           (equal (omnigent-session--session-id-at-point) "parent"))
          (puthash
           "parent"
           '(((id . "child")
              (title . "Child")
              (parent_session_id . "parent")))
           omnigent-sessions--children)
          (puthash
           "child"
           '(((id . "grandchild")
              (title . "Grandchild")
              (parent_session_id . "child")
              (pending_elicitations_count . 1)))
           omnigent-sessions--children)
          (omnigent-session-render)
          (should
           (string-match-p "^        ! Grandchild" (buffer-string)))
          (omnigent-session-toggle-tree)
          (should
           (equal (omnigent-session--session-id-at-point) "parent"))
          (should (string-match-p "▸ ! Parent" (buffer-string)))
          (should-not (string-match-p "Grandchild" (buffer-string)))
          (setq omnigent-sessions--watched-ids nil)
          (omnigent-session-render)
          (should (string-match-p "▸ Parent" (buffer-string)))
          (omnigent-session-toggle-tree)
          (should
           (string-match-p "^        Grandchild" (buffer-string))))
      (kill-buffer buffer))))
