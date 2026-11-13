;;; omnigent-ui-test.el --- Frontend tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'omnigent)

(ert-deftest omnigent-ui-session-render-preserves-selection ()
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
            (updated_at . "2025-01-02"))))
        (omnigent-sessions-truncated t))
    (unwind-protect
        (with-current-buffer (get-buffer-create "*omnigent-sessions*")
          (omnigent-ui-sessions-mode)
          (omnigent-ui-sessions-render)
          (goto-char (point-min))
          (search-forward "! First")
          (beginning-of-line)
          (should (looking-at "! First"))
          (should
           (eq
            (get-text-property (point) 'face)
            'omnigent-ui-session-attention))
          (should
           (eq
            (get-text-property (+ (point) 2) 'face)
            'omnigent-ui-session-running))
          (omnigent-ui-sessions-render)
          (should (equal (omnigent-ui--session-id-at-point) "a"))
          (should
           (save-excursion
             (goto-char (point-min))
             (looking-at "Session list is truncated"))))
      (when-let* ((buffer (get-buffer "*omnigent-sessions*")))
        (kill-buffer buffer)))))


(defmacro omnigent-ui-test--conversation (&rest body)
  "Run BODY in an isolated conversation with no network or process activity."
  (declare (indent 0) (debug t))
  `(let ((omnigent-ui--selected-session nil)
         (omnigent-ui--workspace-cache (make-hash-table :test 'equal))
         (omnigent-ui--workspace-pending
          (make-hash-table :test 'equal))
         (omnigent-ui--workspace-again
          (make-hash-table :test 'equal)))
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

(ert-deftest omnigent-ui-conversation-header-tracks-session-data ()
  "Show snapshot settings and update them from partial stream events."
  (omnigent-ui-test--conversation
    (should (string-prefix-p "unknown | unknown" header-line-format))
    (should
     (eq (get-text-property 0 'face header-line-format) 'diff-header))
    (should
     (equal
      (mapcar
       #'omnigent-ui--token-count
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
      "project | model-a | high | read-only | 100 / 1k (10%%)"))
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
      "project | model-b | low | full-access | 250 / 1k (25%%)"))
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

(ert-deftest omnigent-ui-message-label-faces ()
  "Highlight agent labels and distinguish them from user labels."
  (omnigent-ui-test--conversation
    (let ((outputs (make-hash-table :test 'equal)))
      (let ((user-start (point-max)))
        (omnigent-ui--item
         "user"
         '((type . "message")
           (role . "user")
           (content . "Hi"))
         outputs)
        (let ((user-face (get-text-property user-start 'face)))
          (let ((inhibit-read-only t))
            (erase-buffer))
          (let ((agent-start (point)))
            (omnigent-ui--item
             "agent"
             '((type . "message")
               (role . "assistant")
               (agent_name . "codex-native-ui")
               (content . "Hello"))
             outputs)
            (should (eq user-face 'omnigent-ui-user))
            (should
             (eq
              (get-text-property agent-start 'face)
              'omnigent-ui-agent))
            (should-not (eq user-face 'omnigent-ui-agent))))))))

(ert-deftest omnigent-ui-prompt-busy-indicator ()
  "Animate the prompt while a response is active and stop when it ends."
  (omnigent-ui-test--conversation
    (unwind-protect
        (progn
          (should
           (equal
            (overlay-get
             omnigent-ui--busy-overlay 'before-string)
            " "))
          (omnigent-conversation--event
           "response.created" '((response . ((id . "response")))))
          (should (timerp omnigent-ui--busy-timer))
          (should
           (equal
            (overlay-get
             omnigent-ui--busy-overlay 'before-string)
            "|"))
          (omnigent-ui--busy-tick (current-buffer))
          (should
           (equal
            (overlay-get
             omnigent-ui--busy-overlay 'before-string)
            "/"))
          (omnigent-conversation--event
           "response.completed" '((response . ((id . "response")))))
          (should-not omnigent-ui--busy-timer)
          (should
           (equal
            (overlay-get
             omnigent-ui--busy-overlay 'before-string)
            " ")))
      (omnigent-ui--busy-stop))))

(ert-deftest omnigent-ui-session-archive-and-delete-commands ()
  "Archive the selected session and require confirmation for permanent deletion."
  (dolist (conversation '(nil t))
    (with-temp-buffer
      (if conversation
          (setq
           major-mode 'omnigent-conversation-mode
           omnigent-conversation-session-id "target")
        (setq major-mode 'omnigent-ui-sessions-mode)
        (insert
         (propertize "Target\n" 'omnigent-ui-session-id "target"))
        (goto-char (point-min)))
      (let ((omnigent-sessions
             '(((id . "target") (title . "Target"))))
            (omnigent-sessions--buffers nil)
            archived
            deleted
            confirmation)
        (cl-letf (((symbol-function 'omnigent-sessions-toggle-archive)
                   (lambda (id callback)
                     (setq archived id)
                     (funcall callback 200 '((archived . t)))))
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
          (omnigent-ui-archive)
          (should (equal archived "target"))
          (omnigent-ui-delete)
          (should-not deleted)
          (setq confirmation t)
          (omnigent-ui-delete)
          (should (equal deleted "target")))))))

(ert-deftest omnigent-ui-conversation-user-permission ()
  "Freeze read-only sessions and restore editing when permission increases."
  (omnigent-ui-test--conversation
    (insert "unsent draft")
    (omnigent-conversation--snapshot
     200
     '((permission_level . 1)
       (items . [])
       (pending_inputs . [])
       (pending_elicitations . [])))
    (should buffer-read-only)
    (should (string-prefix-p "unknown [R] |" header-line-format))
    (should-error (insert "more") :type 'buffer-read-only)
    (should-error (omnigent-conversation-send) :type 'user-error)
    (should-error (omnigent-conversation-interrupt) :type 'user-error)
    (should-error (omnigent-ui-archive) :type 'user-error)
    (should-error (omnigent-ui-delete) :type 'user-error)
    (omnigent-conversation--snapshot
     200
     '((permission_level . 2)
       (items . [])
       (pending_inputs . [])
       (pending_elicitations . [])))
    (should-not buffer-read-only)
    (should (string-prefix-p "unknown [E] |" header-line-format))
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
    (should (string-prefix-p "unknown [M] |" header-line-format))))

(ert-deftest omnigent-ui-transcript-stream-preserves-composer-and-fold
    ()
  "Render streamed blocks without replacing input or opening collapsed folds."
  (omnigent-ui-test--conversation
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
      (omnigent-ui--fold-button (button-at (point-min)))
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

(ert-deftest omnigent-ui-fold-spacing-and-no-ellipsis ()
  "Keep visible blank lines between items with either fold state."
  (omnigent-ui-test--conversation
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
      (puthash "first" open omnigent-ui--folds)
      (puthash "second" open omnigent-ui--folds)
      (omnigent-ui--transcript)
      (let ((position (point-min))
            visible)
        (while (< position omnigent-ui--request-start)
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

(ert-deftest omnigent-ui-tool-output-merges-and-bounds ()
  "Merge tool outputs into one fold and apply both deterministic size limits."
  (omnigent-ui-test--conversation
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
    (should (= (how-many "▶ shell" (point-min) (point-max)) 1))
    (should (string-match-p "shell pwd — done" (buffer-string)))
    (should (string-match-p "Output:\nworkspace" (buffer-string)))
    (let* ((line (make-string 33000 ?x))
           (text
            (mapconcat #'identity (cons line (make-list 1100 "short"))
                       "\n"))
           (bounded (omnigent-ui--bounded-output text)))
      (should (string-match-p "32600 characters omitted" bounded))
      (should (string-match-p "301 lines omitted" bounded))
      (should (= (length (split-string bounded "\n")) 801)))))

(ert-deftest omnigent-ui-inline-forms-survive-output-and-failure ()
  "Keep field edits and composer text while streaming and a resolve is pending."
  (omnigent-ui-test--conversation
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
    (should (string-match-p "Question\nYour name?" (buffer-string)))
    (let* ((field
            (cl-find
             "name"
             omnigent-ui--widgets
             :key
             (lambda (widget) (widget-get widget :field-name))
             :test #'equal))
           callback)
      (widget-value-set field "Alice")
      (omnigent-ui--field-notify field)
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
      (cl-letf (((symbol-function 'omnigent-transport-request)
                 (lambda (_method _path cb _data)
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

(ert-deftest omnigent-ui-secret-stays-out-of-text-and-undo ()
  "Read a secret into the draft without retaining clear text in buffer or undo."
  (omnigent-ui-test--conversation
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
            omnigent-ui--widgets
            :key
            (lambda (widget) (widget-get widget :field-name))
            :test #'equal)))
      (cl-letf (((symbol-function 'read-passwd)
                 (lambda (&rest _) "sensitive-value")))
        (omnigent-ui--secret field)))
    (should
     (equal
      (gethash
       "token" (omnigent-conversation-elicitation-draft "secret"))
      "sensitive-value"))
    (should-not (string-match-p "sensitive-value" (buffer-string)))
    (should-not
     (string-match-p
      "sensitive-value" (format "%S" buffer-undo-list)))))

(ert-deftest omnigent-ui-requests-arrive-in-order-without-moving-point
    ()
  "Keep pending requests oldest first and retain the point inside the composer."
  (omnigent-ui-test--conversation
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
      "first\n.*\n\nQuestion\nsecond" (buffer-string)))))

(ert-deftest omnigent-ui-schema-validation-shows-all-errors ()
  "Display every invalid field and select the first invalid field."
  (omnigent-ui-test--conversation
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
            omnigent-ui--widgets
            :key
            (lambda (widget) (widget-get widget :response-action)))))
      (omnigent-ui--submit-widget submit)
      (should (= (how-many "Required" (point-min) (point-max)) 2))
      (should
       (= (point)
          (widget-get
           (cl-find
            "first"
            omnigent-ui--widgets
            :key
            (lambda (widget) (widget-get widget :field-name))
            :test #'equal)
           :from))))))

(ert-deftest omnigent-ui-questions-other-and-multiple-values ()
  "Use question IDs and transmit editable Other answers and multiple choices."
  (omnigent-ui-test--conversation
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "q")
       (params
        .
        ((ask_user_question
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
    (dolist (entry '(("choice" . "Custom") ("many" . ("A" "B"))))
      (let ((field
             (cl-find
              (car entry)
              omnigent-ui--widgets
              :key
              (lambda (widget) (widget-get widget :field-name))
              :test #'equal)))
        (widget-value-set field (cdr entry))
        (omnigent-ui--field-notify field)))
    (should-not (omnigent-conversation-elicitation-validate "q"))
    (let (payload)
      (cl-letf (((symbol-function 'omnigent-transport-request)
                 (lambda (_method _path _callback data)
                   (setq payload data))))
        (omnigent-conversation-elicitation-submit "q" 'accept nil))
      (let ((content (alist-get "content" payload nil nil #'equal)))
        (should (equal (gethash "choice" content) "Custom"))
        (should (equal (gethash "many" content) ["A" "B"]))))))

(ert-deftest omnigent-ui-external-url-has-no-response-actions ()
  "Render external URLs as links and internal approval URLs as actions."
  (omnigent-ui-test--conversation
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "external")
       (params . ((url . "https://example.test/")))))
    (should-not
     (cl-some
      (lambda (widget)
        (widget-get widget :response-action))
      omnigent-ui--widgets))
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "approval")
       (params . ((url . "/approve/id")))))
    (should (string-match-p "Approval required" (buffer-string)))
    (should (string-match-p "Approve" (buffer-string)))))

(ert-deftest
    omnigent-ui-composer-continuation-indentation-is-display-only
    ()
  "Indent both explicit and visual continuations without changing sent text."
  (omnigent-ui-test--conversation
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
      "  "))
    (should
     (equal
      (get-text-property
       omnigent-conversation--prompt-start 'wrap-prefix)
      "  "))))

(ert-deftest
    omnigent-ui-workspace-refresh-coalesces-and-isolates-sessions
    ()
  "Coalesce repeated refreshes and never replace another session's panel."
  (let ((omnigent-ui--workspace-cache (make-hash-table :test 'equal))
        (omnigent-ui--workspace-pending
         (make-hash-table :test 'equal))
        (omnigent-ui--workspace-again (make-hash-table :test 'equal))
        (omnigent-ui--selected-session "b")
        calls
        displays)
    (cl-letf (((symbol-function 'omnigent-workspace-list)
               (lambda (id callback) (push (cons id callback) calls)))
              ((symbol-function 'omnigent-ui--workspace-render)
               #'ignore)
              ((symbol-function 'omnigent-ui--workspace-display)
               (lambda () (push t displays))))
      (omnigent-ui-workspace-refresh "a")
      (omnigent-ui-workspace-refresh "a")
      (omnigent-ui-workspace-refresh "a")
      (should (= (length calls) 1))
      (funcall (cdar calls)
               200
               '((changes . (((path . "a") (status . "modified"))))))
      (should (= (length calls) 2))
      (should-not displays)
      (funcall (cdar calls) 500 nil)
      (should (gethash "a" omnigent-ui--workspace-cache))
      (should-not (gethash "a" omnigent-ui--workspace-pending))
      (omnigent-ui-workspace-refresh "b")
      (funcall (cdar calls) 200 '((changes . nil)))
      (should (= (length displays) 1)))))

(ert-deftest omnigent-ui-workspace-rows-sort-and-preserve-path ()
  "Sort flat paths alphabetically, mark statuses and preserve path selection."
  (let ((id "row-test")
        buffer)
    (unwind-protect
        (progn
          (omnigent-ui--workspace-render
           id
           '((changes
              .
              (((path . "z") (status . "created"))
               ((path . "a") (status . "deleted"))
               ((path . "m") (status . "modified"))))))
          (setq buffer (omnigent-ui--workspace-buffer id))
          (with-current-buffer buffer
            (should
             (equal
              (buffer-string) "[unified diff]\nD a\nM m\nA z\n"))
            (goto-char (point-min))
            (forward-line 2)
            (omnigent-ui--workspace-render
             id
             '((changes
                .
                (((path . "m") (status . "created"))
                 ((path . "b") (status . "modified"))))))
            (should
             (equal
              (get-text-property (point) 'omnigent-ui-path) "m"))
            (omnigent-ui--workspace-render
             id '((changes . (((path . "b") (status . "modified"))))))
            (should
             (equal
              (get-text-property (point) 'omnigent-ui-path) "b"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest omnigent-ui-diff-reuses-buffer-and-keeps-it-on-failure ()
  "Reuse successful diff buffers and leave existing contents on failed fetch."
  (save-window-excursion
    (let (buffer)
      (unwind-protect
          (progn
            (omnigent-ui--diff-result
             "diff-test" "file" 200 "first diff\n")
            (setq buffer (current-buffer))
            (should (derived-mode-p 'diff-mode))
            (omnigent-ui--diff-result "diff-test" "file" 500 "bad")
            (should (equal (buffer-string) "first diff\n"))
            (omnigent-ui--diff-result
             "diff-test" "file" 200 "new diff\n")
            (should (eq buffer (current-buffer)))
            (should (equal (buffer-string) "new diff\n")))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest omnigent-ui-session-list-opens-on-first-connection ()
  "Open the session list only after the first successful connection."
  (save-window-excursion
    (let ((omnigent-sessions-updates nil)
          (omnigent-ui--idle-timer nil)
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
                    ((symbol-function 'run-with-idle-timer) #'ignore))
            (omnigent-ui-start)
            (should-not (get-buffer-window "*omnigent-sessions*"))
            (funcall opened)
            (should (get-buffer-window "*omnigent-sessions*"))
            (omnigent-ui-sessions)
            (should-not (get-buffer-window "*omnigent-sessions*"))
            (funcall opened)
            (should-not (get-buffer-window "*omnigent-sessions*")))
        (when-let* ((buffer (get-buffer "*omnigent-sessions*")))
          (kill-buffer buffer))))))

(ert-deftest omnigent-ui-session-list-stays-closed-when-disabled ()
  "Keep the session list closed when automatic opening is disabled."
  (save-window-excursion
    (let ((omnigent-sessions-updates nil)
          (omnigent-ui--idle-timer nil)
          (omnigent-open-session-list-on-connect nil)
          opened)
      (cl-letf (((symbol-function
                  'omnigent-transport-start-session-updates)
                 (lambda (_frame _error callback)
                   (setq opened callback)
                   'updates))
                ((symbol-function 'omnigent-sessions-refresh)
                 #'ignore)
                ((symbol-function 'run-with-idle-timer) #'ignore))
        (omnigent-ui-start)
        (funcall opened)
        (should-not (get-buffer-window "*omnigent-sessions*"))))))

(ert-deftest omnigent-ui-idle-timer-stops-on-reset ()
  "Start one ten-second idle timer even with hidden views and cancel on reset."
  (let ((omnigent-ui--idle-timer nil)
        (omnigent-sessions-updates 'updates)
        (omnigent-ui--workspace-cache (make-hash-table :test 'equal))
        (omnigent-ui--workspace-pending
         (make-hash-table :test 'equal))
        (omnigent-ui--workspace-again (make-hash-table :test 'equal))
        (calls 0)
        canceled)
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (seconds repeat function)
                 (should (= seconds 10))
                 (should repeat)
                 (should (eq function #'omnigent-ui-refresh))
                 (cl-incf calls)
                 'timer))
              ((symbol-function 'timerp)
               (lambda (timer) (eq timer 'timer)))
              ((symbol-function 'cancel-timer)
               (lambda (timer) (setq canceled timer))))
      (omnigent-ui-start)
      (omnigent-ui-start)
      (should (= calls 1))
      (omnigent-ui-reset)
      (should (eq canceled 'timer))
      (should-not omnigent-ui--idle-timer))))

(ert-deftest omnigent-ui-selected-title-keeps-state-face ()
  "Add bold to the selected title without losing its archived state face."
  (let ((omnigent-sessions
         '(((id . "selected")
            (title . "Title")
            (archived . t)
            (status . "running"))))
        (omnigent-ui--selected-session "selected")
        (omnigent-sessions-truncated nil))
    (unwind-protect
        (with-current-buffer (get-buffer-create "*omnigent-sessions*")
          (omnigent-ui-sessions-mode)
          (omnigent-ui-sessions-render)
          (should
           (equal
            (get-text-property (+ (point-min) 2) 'face)
            '(bold omnigent-ui-session-archived))))
      (kill-buffer "*omnigent-sessions*"))))

(ert-deftest omnigent-ui-open-keeps-session-side-window ()
  "Open the selected conversation in the main window, leaving sessions visible."
  (save-window-excursion
    (let ((omnigent-sessions
           '(((id . "side-test") (title . "Side test"))))
          (omnigent-sessions--buffers nil)
          (omnigent-ui--selected-session nil)
          (omnigent-ui--workspace-visible nil)
          buffer)
      (cl-letf (((symbol-function
                  'omnigent-transport-start-session-stream)
                 (lambda (&rest _) nil))
                ((symbol-function 'omnigent-ui-workspace-refresh)
                 #'ignore))
        (unwind-protect
            (progn
              (omnigent-ui-sessions)
              (select-window
               (get-buffer-window "*omnigent-sessions*"))
              (omnigent-ui-sessions-open)
              (setq buffer (current-buffer))
              (should (derived-mode-p 'omnigent-conversation-mode))
              (should-not
               (window-parameter (selected-window) 'window-side))
              (should (get-buffer-window "*omnigent-sessions*")))
          (when (buffer-live-p buffer)
            (kill-buffer buffer))
          (when (get-buffer "*omnigent-sessions*")
            (kill-buffer "*omnigent-sessions*")))))))

(ert-deftest omnigent-ui-incoming-request-keeps-field-point ()
  "Preserve edited field text and its cursor offset when another request arrives."
  (omnigent-ui-test--conversation
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
            omnigent-ui--widgets
            :key
            (lambda (widget) (widget-get widget :field-name))
            :test #'equal)))
      (widget-value-set field "Alice")
      (omnigent-ui--field-notify field)
      (goto-char (+ (widget-get field :from) 2)))
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "second") (params . ((message . "Next")))))
    (let ((field
           (cl-find
            "name"
            omnigent-ui--widgets
            :key
            (lambda (widget) (widget-get widget :field-name))
            :test #'equal)))
      (should (= (point) (+ (widget-get field :from) 2)))
      (should (equal (widget-value field) "Alice")))))

(ert-deftest omnigent-ui-stream-final-keeps-expanded-provisional-fold
    ()
  "Retain a user-expanded fold when the final server item adopts its stable ID."
  (omnigent-ui-test--conversation
    (omnigent-conversation--event
     "response.in_progress" '((response . ((id . "turn")))))
    (omnigent-conversation--event
     "response.reasoning_text.delta" '((delta . "think")))
    (omnigent-ui--transcript-flush (current-buffer))
    (omnigent-ui--fold-button (button-at (point-min)))
    (omnigent-conversation--event
     "response.output_item.done"
     '((item
        .
        ((id . "final")
         (type . "reasoning")
         (content . "thinking")
         (response_id . "turn")))))
    (omnigent-ui--transcript-flush (current-buffer))
    (should (gethash "final" omnigent-ui--folds))
    (goto-char (point-min))
    (forward-line 1)
    (should-not (invisible-p (point)))))

(ert-deftest omnigent-ui-workspace-reopens-on-conversation-selection
    ()
  "Reopen a closed workspace when selecting another conversation with changes."
  (omnigent-ui-test--conversation
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((omnigent-ui--selected-session "other")
            (omnigent-ui--workspace-visible nil)
            (omnigent-ui--workspace-closed t)
            (omnigent-ui--changing-windows nil)
            (data
             '((changes
                . (((path . "changed") (status . "modified")))))))
        (unwind-protect
            (cl-letf (((symbol-function 'omnigent-workspace-list)
                       (lambda (_id callback)
                         (funcall callback 200 data))))
              (omnigent-ui--selection)
              (should
               (get-buffer-window
                (omnigent-ui--workspace-buffer "conv_test")))
              (should-not
               (window-parameter (selected-window) 'window-side))
              (omnigent-ui--workspace-hide)
              (setq omnigent-ui--workspace-closed t)
              (omnigent-ui--selection)
              (should-not omnigent-ui--workspace-visible))
          (omnigent-ui--workspace-hide)
          (when-let* ((buffer
                       (get-buffer
                        "*omnigent-workspace: conv_test*")))
            (kill-buffer buffer)))))))

(ert-deftest omnigent-ui-workspace-reopens-after-turn ()
  "Reopen on terminal status only when the selected session has changed files."
  (omnigent-ui-test--conversation
    (save-window-excursion
      (switch-to-buffer (current-buffer))
      (let ((omnigent-ui--selected-session "conv_test")
            (omnigent-ui--workspace-visible nil)
            (omnigent-ui--workspace-closed t)
            (omnigent-ui--changing-windows nil)
            (data
             '((changes
                . (((path . "changed") (status . "modified")))))))
        (unwind-protect
            (cl-letf (((symbol-function 'omnigent-workspace-list)
                       (lambda (_id callback)
                         (funcall callback 200 data))))
              (omnigent-ui--conversation-event
               "session.changed_files.invalidated" nil)
              (should-not omnigent-ui--workspace-visible)
              (omnigent-ui--conversation-event
               "response.completed" nil)
              (should-not omnigent-ui--workspace-visible)
              (omnigent-ui--conversation-event
               "session.status" '((status . "idle")))
              (should
               (get-buffer-window
                (omnigent-ui--workspace-buffer "conv_test")))
              (should-not
               (window-parameter (selected-window) 'window-side))
              (omnigent-ui--workspace-hide)
              (setq
               omnigent-ui--workspace-closed t
               data '((changes . nil)))
              (omnigent-ui--conversation-event
               "session.status" '((status . "idle")))
              (should-not omnigent-ui--workspace-visible)
              (setq
               omnigent-ui--workspace-closed t
               omnigent-ui--selected-session "other")
              (omnigent-ui--conversation-event
               "session.status" '((status . "idle")))
              (should omnigent-ui--workspace-closed)
              (should-not omnigent-ui--workspace-visible))
          (omnigent-ui--workspace-hide)
          (when-let* ((buffer
                       (get-buffer
                        "*omnigent-workspace: conv_test*")))
            (kill-buffer buffer)))))))

(ert-deftest omnigent-ui-workspace-window-lifecycle ()
  "Stack side views, switch caches, close empty results and honor manual closure."
  (save-window-excursion
    (let ((omnigent-ui--selected-session "window-a")
          (omnigent-ui--workspace-visible nil)
          (omnigent-ui--workspace-closed nil)
          (omnigent-ui--workspace-cache
           (make-hash-table :test 'equal))
          (omnigent-ui--workspace-pending
           (make-hash-table :test 'equal))
          (omnigent-ui--workspace-again
           (make-hash-table :test 'equal))
          (omnigent-sessions nil))
      (unwind-protect
          (progn
            (omnigent-ui-sessions)
            (let ((data
                   '((changes
                      . (((path . "a") (status . "created")))))))
              (puthash "window-a" data omnigent-ui--workspace-cache)
              (omnigent-ui--workspace-render "window-a" data))
            (omnigent-ui--workspace-display)
            (let ((sessions (get-buffer-window "*omnigent-sessions*"))
                  (workspace
                   (get-buffer-window
                    (omnigent-ui--workspace-buffer "window-a"))))
              (should sessions)
              (should workspace)
              (should
               (< (nth 1 (window-edges sessions))
                  (nth 1 (window-edges workspace)))))
            (setq omnigent-ui--selected-session "window-b")
            (omnigent-ui--workspace-display)
            (with-current-buffer (window-buffer
                                  (get-buffer-window
                                   (omnigent-ui--workspace-buffer
                                    "window-b")))
              (should (string-empty-p (buffer-string))))
            (let ((window
                   (get-buffer-window
                    (omnigent-ui--workspace-buffer "window-b"))))
              (delete-window window)
              (omnigent-ui--windows-changed))
            (should omnigent-ui--workspace-closed)
            (puthash
             "window-b"
             '((changes . (((path . "b") (status . "modified"))))) omnigent-ui--workspace-cache)
            (omnigent-ui--workspace-display)
            (should-not omnigent-ui--workspace-visible)
            (setq omnigent-ui--workspace-closed nil)
            (omnigent-ui--workspace-display)
            (should omnigent-ui--workspace-visible)
            (puthash
             "window-b"
             '((changes . nil))
             omnigent-ui--workspace-cache)
            (omnigent-ui--workspace-display)
            (should-not omnigent-ui--workspace-visible)
            (should (get-buffer-window "*omnigent-sessions*")))
        (dolist (name
                 '("*omnigent-sessions*"
                   "*omnigent-workspace: window-a*"
                   "*omnigent-workspace: window-b*"))
          (when (get-buffer name)
            (kill-buffer name)))))))

(ert-deftest
    omnigent-ui-removal-freezes-draft-and-rejects-late-workspace
    ()
  "Freeze a removed session and discard a pending workspace result for it."
  (omnigent-ui-test--conversation
    (insert "keep draft")
    (let ((omnigent-sessions--buffers
           (list (cons "conv_test" (current-buffer))))
          callback)
      (cl-letf (((symbol-function 'omnigent-workspace-list)
                 (lambda (_id cb) (setq callback cb))))
        (omnigent-ui-workspace-refresh "conv_test"))
      (omnigent-ui--frame '((type . "removed") (ids . ["conv_test"])))
      (should buffer-read-only)
      (should-error (omnigent-conversation-send) :type 'user-error)
      (should (string-suffix-p "keep draft" (buffer-string)))
      (funcall callback
               200
               '((changes
                  . (((path . "late") (status . "created"))))))
      (should-not
       (gethash "conv_test" omnigent-ui--workspace-cache)))))

(ert-deftest omnigent-ui-send-uses-server-state-not-session-status ()
  "Display queued input for every session status and commit it exactly once."
  (dolist (status '("idle" "running" "waiting" "failed" nil))
    (omnigent-ui-test--conversation
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
        (omnigent-ui-test--consume "committed" "sent message"
                                   "pending")
        (omnigent-ui-test--consume "committed" "sent message"
                                   "pending")
        (should-not omnigent-conversation--pending-inputs)
        (should (equal omnigent-conversation--order '("committed")))
        (should (= (how-many "You:" (point-min) (point-max)) 1))))))

(ert-deftest omnigent-ui-scrolled-transcript-keeps-reading-position ()
  "Preserve point by item ID when transcript output is refreshed above the composer."
  (omnigent-ui-test--conversation
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
               (point) 'omnigent-ui-item-id))))
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
        (get-text-property (point) 'omnigent-ui-item-id) "second"))
      (should
       (= offset
          (- (point)
             (previous-single-property-change
              (point) 'omnigent-ui-item-id)))))))

(ert-deftest omnigent-ui-history-reserves-prompt-columns ()
  "Align history text and fold indicators with the composer."
  (omnigent-ui-test--conversation
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
    (should (equal (get-text-property (point) 'line-prefix) "  "))
    (search-forward "▶")
    (should (equal (get-text-property (1- (point)) 'line-prefix) " "))
    (forward-line 1)
    (should (equal (get-text-property (point) 'line-prefix) "  "))
    (should (equal (get-text-property (point) 'wrap-prefix) "  "))))

(ert-deftest omnigent-ui-transcript-shortened-item-keeps-point ()
  "Keep point inside its transcript item when that item becomes shorter."
  (omnigent-ui-test--conversation
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
      (get-text-property (point) 'omnigent-ui-item-id) "first"))))

(ert-deftest omnigent-ui-transcript-does-not-recenter-reading-point ()
  "Preserve the view for transcript and composer point without forced recentering."
  (save-window-excursion
    (omnigent-ui-test--conversation
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
            (omnigent-ui--transcript))
          (should-not recentered)
          (should (= (point) position))
          (should (= (window-start) start)))))))

(ert-deftest omnigent-ui-composer-line-start-stays-in-input ()
  "Keep line-start motion and deletion inside the editable composer."
  (omnigent-ui-test--conversation
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
       omnigent-ui--composer-label
       omnigent-conversation--prompt-start)
      "> "))))

(ert-deftest omnigent-ui-composer-evil-line-edits ()
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
     (omnigent-ui-test--conversation
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
                  omnigent-ui--composer-label
                  omnigent-conversation--prompt-start)
                 "> "))
               (goto-char (point-min))
               (should-error (delete-char 1) :type 'text-read-only))
           (evil-local-mode -1)))))))

(ert-deftest omnigent-ui-rejected-edit-does-not-lock-composer ()
  "A rejected transcript edit must not install widget-only editing on the composer."
  (omnigent-ui-test--conversation
    (omnigent-conversation--event
     "response.output_item.done"
     '((item . ((id . "a") (content . "protected")))))
    (goto-char (point-min))
    (should-error (insert "forbidden") :type 'text-read-only)
    (run-hooks 'post-command-hook)
    (goto-char (point-max))
    (insert "still editable")
    (should (string-suffix-p "still editable" (buffer-string)))))

(ert-deftest omnigent-ui-real-field-edit-updates-draft ()
  "Normal field typing must update request state without explicit notification."
  (omnigent-ui-test--conversation
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
            omnigent-ui--widgets
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

(defun omnigent-ui-test--consume (id text &optional pending-id meta)
  "Deliver consumption of ID with TEXT, optional PENDING-ID and META flag."
  (omnigent-conversation--event
   "session.input.consumed"
   `((data
      .
      ((item_id . ,id)
       (type . "message") (cleared_pending_id . ,pending-id)
       (data
        . ((role . "user") (content . ,text) (is_meta . ,meta))))))))

(ert-deftest omnigent-ui-pending-order-forms-and-draft ()
  "Keep output, forms, queued input and composer separate."
  (omnigent-ui-test--conversation
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
     (string-match-p "output\n\nQuestion\nApproval" (buffer-string)))
    (should
     (string-match-p
      "\\[queued\\] > first\n\n\\[queued\\] > second\n\n> draft"
      (buffer-string)))
    (should (= (point) (point-max)))
    (goto-char omnigent-ui--pending-start)
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
    (omnigent-ui-test--consume "first" "first" "1")
    (should (= (length omnigent-conversation--pending-inputs) 1))))

(ert-deftest omnigent-ui-new-transcript-items-stay-above-queued-inputs
    ()
  "Keep new transcript items above queued input."
  (omnigent-ui-test--conversation
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
    (omnigent-ui--transcript-flush (current-buffer))
    (should
     (= (overlay-start omnigent-ui--busy-overlay)
        (marker-position omnigent-ui--composer-label)))
    (should (overlay-get omnigent-ui--busy-overlay 'before-string))
    (should
     (< (string-match "Agent:\ncurrent message" (buffer-string))
        (string-match "\\[queued\\] > queued" (buffer-string))))))

(ert-deftest omnigent-ui-consumption-before-post-response ()
  "Do not recreate consumed input when its POST acknowledgement arrives late."
  (dolist (pending-id '(nil "pending"))
    (omnigent-ui-test--conversation
      (let (callback)
        (insert "same")
        (cl-letf (((symbol-function
                    'omnigent-transport-post-session-event)
                   (lambda (_id _event cb) (setq callback cb))))
          (omnigent-conversation-send))
        (omnigent-ui-test--consume "committed" "same" pending-id)
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

(ert-deftest omnigent-ui-snapshot-is-authoritative-for-pending-input
    ()
  "Replace local input records, then ignore already-recovered FIFO consumption."
  (omnigent-ui-test--conversation
    (insert "draft")
    (setq omnigent-conversation--pending-inputs
          '(((state . queued) (content . "local"))))
    (dolist (cleared-id '("pending-a" nil))
      (setq omnigent-conversation--loading t)
      (omnigent-ui-test--consume "a" "same" cleared-id)
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
    (omnigent-ui-test--consume "unrelated" "other" "unknown-id")
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

(ert-deftest omnigent-ui-fifo-skips-markers-and-keeps-identical-inputs
    ()
  "Only new user consumption can remove one eligible FIFO input."
  (omnigent-ui-test--conversation
    (setq omnigent-conversation--pending-inputs
          (list
           (list '(state . queued) '(content . "same"))
           (list '(state . queued) '(content . "same"))))
    (omnigent-ui-test--consume "meta" "injected context" nil t)
    (omnigent-ui-test--consume "marker" "[System: task completed]")
    (should (= (length omnigent-conversation--pending-inputs) 2))
    (omnigent-ui-test--consume "a" "same")
    (should (= (length omnigent-conversation--pending-inputs) 1))
    (omnigent-ui-test--consume "a" "same")
    (should (= (length omnigent-conversation--pending-inputs) 1))
    (omnigent-ui-test--consume "b" "same")
    (should-not omnigent-conversation--pending-inputs)
    (should
     (equal
      omnigent-conversation--order '("meta" "marker" "a" "b")))))

(ert-deftest
    omnigent-ui-send-outcomes-and-late-response-after-snapshot
    ()
  "Trust response IDs, retain uncertain drafts and do not restore superseded input."
  (dolist (response
           '((202 (queued . t) (item_id . "saved"))
             (202 (queued . t) (pending_id . "pending"))
             (202 (denied . t) (reason . "Denied"))
             (403 (detail . "Denied"))
             (nil)
             (500)))
    (omnigent-ui-test--conversation
      (insert "message")
      (cl-letf (((symbol-function
                  'omnigent-transport-post-session-event)
                 (lambda (_id _event callback)
                   (funcall callback (car response) (cdr response)))))
        (omnigent-conversation-send))
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
        (should-not omnigent-conversation--pending-inputs)))
      (should
       (equal
        (buffer-substring-no-properties
         omnigent-conversation--prompt-start (point-max))
        (if (and (equal (car response) 202)
                 (not (eq (alist-get 'denied (cdr response)) t)))
            ""
          "message")))))
  (omnigent-ui-test--conversation
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

(ert-deftest omnigent-ui-interrupt-refresh-buffers-events ()
  "Refresh after interruption without losing later buffered consumption events."
  (omnigent-ui-test--conversation
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
        (omnigent-ui-test--consume "b" "queued" "pending-b")
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

(ert-deftest omnigent-ui-send-hook-errors-and-raw-failure ()
  "Dispatch despite observer errors and retain a draft on a raw transport failure."
  (omnigent-ui-test--conversation
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

(ert-deftest omnigent-ui-invalid-pending-snapshot-keeps-visible-state
    ()
  "Reject malformed queue arrays or identifiers without deleting visible input."
  (dolist (pending
           '(nil
             "invalid"
             [((content . "missing id"))]
             [((pending_id . "id"))]))
    (omnigent-ui-test--conversation
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

(provide 'omnigent-ui-test)
;;; omnigent-ui-test.el ends here
