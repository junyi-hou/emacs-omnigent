;;; omnigent-ui-test.el --- Frontend tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'omnigent-ui)

(ert-deftest omnigent-ui-session-render-preserves-selection ()
  "Render statuses and attention while preserving the selected session."
  (let ((omnigent-sessions '(((id . "a") (title . "First") (status . "running")
                               (updated_at . "2025-01-01") (pending_elicitations_count . 1))
                              ((id . "b") (title . "Second") (status . "idle")
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
          (should (eq (get-text-property (point) 'face) 'omnigent-ui-session-attention))
          (omnigent-ui-sessions-render)
          (should (equal (omnigent-ui--session-id-at-point) "a"))
          (should (save-excursion (goto-char (point-min)) (looking-at "Session list is truncated"))))
      (when-let* ((buffer (get-buffer "*omnigent-sessions*"))) (kill-buffer buffer)))))


(defmacro omnigent-ui-test--conversation (&rest body)
  "Run BODY in an isolated conversation with no network or process activity."
  (declare (indent 0) (debug t))
  `(let ((omnigent-ui--selected-session nil)
         (omnigent-ui--workspace-cache (make-hash-table :test 'equal))
         (omnigent-ui--workspace-pending (make-hash-table :test 'equal))
         (omnigent-ui--workspace-again (make-hash-table :test 'equal)))
     (cl-letf (((symbol-function 'omnigent-transport-start-session-stream) (lambda (&rest _) nil)))
       (with-temp-buffer
         (let ((omnigent-conversation--session-id "conv_test")) (omnigent-conversation-mode))
         (setq omnigent-conversation--loading nil)
         ,@body))))

(ert-deftest omnigent-ui-transcript-stream-preserves-composer-and-fold ()
  "Render streamed blocks without replacing input or opening collapsed folds."
  (omnigent-ui-test--conversation
    (insert "draft\ncontinued")
    (let ((position (point)))
      (omnigent-conversation--event
       "response.output_item.added" '((item . ((id . "r") (type . "reasoning") (content . "think")))))
      (should (equal (buffer-substring-no-properties omnigent-conversation--prompt-start (point-max))
                     "draft\ncontinued"))
      (should (= (- (point-max) (point)) 0))
      (should (> (point) position))
      (goto-char (point-min))
      (should (search-forward "▶ Thinking" nil t))
      (forward-line 1)
      (should (invisible-p (point)))
      (omnigent-conversation--event "response.reasoning_text.delta"
                                   '((item_id . "r") (delta . " more")))
      (goto-char (point-min)) (forward-line 1)
      (should (invisible-p (point)))
      (omnigent-ui--fold-button (button-at (point-min)))
      (goto-char (point-min)) (forward-line 1)
      (should-not (invisible-p (point)))
      (omnigent-conversation--snapshot
       200 '((items . [((id . "r") (type . "reasoning") (content . "final"))])))
      (goto-char (point-min)) (forward-line 1)
      (should-not (invisible-p (point)))
      (should-error (delete-char 1) :type 'text-read-only))))

(ert-deftest omnigent-ui-tool-output-merges-and-bounds ()
  "Merge tool outputs into one fold and apply both deterministic size limits."
  (omnigent-ui-test--conversation
    (omnigent-conversation--event
     "response.output_item.done"
     '((item . ((id . "call") (type . "function_call") (call_id . "c")
                (name . "shell") (arguments . "pwd")))))
    (omnigent-conversation--event
     "response.output_item.done"
     '((item . ((id . "output") (type . "function_call_output") (call_id . "c")
                (output . "workspace")))))
    (should (= (how-many "▶ shell" (point-min) (point-max)) 1))
    (should (string-match-p "shell pwd — done" (buffer-string)))
    (should (string-match-p "Output:\nworkspace" (buffer-string)))
    (let* ((line (make-string 33000 ?x))
           (text (mapconcat #'identity (cons line (make-list 1100 "short")) "\n"))
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
       (params . ((message . "Your name?")
                  (requestedSchema . ((type . "object") (required . ["name"])
                                      (properties . ((name . ((type . "string")))))))))))
    (should (string-match-p "Question\nYour name?" (buffer-string)))
    (let* ((field (cl-find "name" omnigent-ui--widgets
                           :key (lambda (widget) (widget-get widget :field-name)) :test #'equal))
           callback)
      (widget-value-set field "Alice")
      (omnigent-ui--field-notify field)
      (omnigent-conversation--event
       "response.output_item.done" '((item . ((id . "a") (type . "message") (content . "answer")))))
      (should (equal (gethash "name" (omnigent-conversation-elicitation-draft "question")) "Alice"))
      (should (equal (widget-value field) "Alice"))
      (cl-letf (((symbol-function 'omnigent-transport-request)
                 (lambda (_method _path cb _data) (setq callback cb))))
        (omnigent-conversation-elicitation-submit "question" 'accept nil)
        (should (string-match-p "Submitting\\.\\.\\." (buffer-string)))
        (funcall callback 500 '((detail . "No")))
        (should (gethash "question" omnigent-conversation--elicitations))
        (should (string-match-p "Alice" (buffer-string))))
      (goto-char (point-max)) (insert " suffix")
      (should (equal (buffer-substring-no-properties omnigent-conversation--prompt-start (point-max))
                     "composer suffix"))
      (omnigent-conversation--event "response.elicitation_resolved" '((elicitation_id . "question")))
      (should-not (string-match-p "Your name?" (buffer-string)))
      (should (equal (buffer-substring-no-properties omnigent-conversation--prompt-start (point-max))
                     "composer suffix")))))

(ert-deftest omnigent-ui-secret-stays-out-of-text-and-undo ()
  "Read a secret into the draft without retaining clear text in buffer or undo."
  (omnigent-ui-test--conversation
    (buffer-enable-undo)
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "secret")
       (params . ((requestedSchema . ((type . "object")
                   (properties . ((token . ((type . "string") (format . "password")))))))))))
    (let ((field (cl-find "token" omnigent-ui--widgets
                          :key (lambda (widget) (widget-get widget :field-name)) :test #'equal)))
      (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) "sensitive-value")))
        (omnigent-ui--secret field)))
    (should (equal (gethash "token" (omnigent-conversation-elicitation-draft "secret")) "sensitive-value"))
    (should-not (string-match-p "sensitive-value" (buffer-string)))
    (should-not (string-match-p "sensitive-value" (format "%S" buffer-undo-list)))))

(ert-deftest omnigent-ui-requests-arrive-in-order-without-moving-point ()
  "Keep pending requests oldest first and retain the point inside the composer."
  (omnigent-ui-test--conversation
    (insert "draft")
    (dolist (id '("first" "second"))
      (omnigent-conversation--event
       "response.elicitation_request" `((elicitation_id . ,id) (params . ((message . ,id))))))
    (should (= (point) (point-max)))
    (should (equal (mapcar (lambda (request) (alist-get 'elicitation_id request))
                           (omnigent-conversation-elicitations)) '("first" "second")))
    (should (string-match-p "first\n.*\n\nQuestion\nsecond" (buffer-string)))))

(ert-deftest omnigent-ui-schema-validation-shows-all-errors ()
  "Display every invalid field and select the first invalid field."
  (omnigent-ui-test--conversation
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "q") (params . ((requestedSchema .
       ((type . "object") (required . ["first" "second"])
        (properties . ((first . ((type . "string"))) (second . ((type . "string")))))))))))
    (let ((submit (cl-find 'accept omnigent-ui--widgets
                           :key (lambda (widget) (widget-get widget :response-action)))))
      (omnigent-ui--submit-widget submit)
      (should (= (how-many "Required" (point-min) (point-max)) 2))
      (should (= (point) (widget-get (cl-find "first" omnigent-ui--widgets
                                           :key (lambda (widget) (widget-get widget :field-name))
                                           :test #'equal) :from))))))

(ert-deftest omnigent-ui-questions-other-and-multiple-values ()
  "Use question IDs and transmit editable Other answers and multiple choices."
  (omnigent-ui-test--conversation
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "q") (params . ((ask_user_question .
        ((questions . [((id . "choice") (question . "Pick") (isOther . t)
                         (options . [((label . "One"))]))
                        ((id . "many") (question . "Several") (multiSelect . t)
                         (isOther . :json-false) (options . [((label . "A")) ((label . "B"))]))])))))))
    (dolist (entry '(("choice" . "Custom") ("many" . ("A" "B"))))
      (let ((field (cl-find (car entry) omnigent-ui--widgets
                            :key (lambda (widget) (widget-get widget :field-name)) :test #'equal)))
        (widget-value-set field (cdr entry))
        (omnigent-ui--field-notify field)))
    (should-not (omnigent-conversation-elicitation-validate "q"))
    (let (payload)
      (cl-letf (((symbol-function 'omnigent-transport-request)
                 (lambda (_method _path _callback data) (setq payload data))))
        (omnigent-conversation-elicitation-submit "q" 'accept nil))
      (let ((content (alist-get "content" payload nil nil #'equal)))
        (should (equal (gethash "choice" content) "Custom"))
        (should (equal (gethash "many" content) ["A" "B"]))))))

(ert-deftest omnigent-ui-external-url-has-no-response-actions ()
  "Render external URLs as links and internal approval URLs as actions."
  (omnigent-ui-test--conversation
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "external") (params . ((url . "https://example.test/")))))
    (should-not (cl-some (lambda (widget) (widget-get widget :response-action))
                         omnigent-ui--widgets))
    (omnigent-conversation--event
     "response.elicitation_request" '((elicitation_id . "approval") (params . ((url . "/approve/id")))))
    (should (string-match-p "Approval required" (buffer-string)))
    (should (string-match-p "Approve" (buffer-string)))))

(ert-deftest omnigent-ui-composer-continuation-indentation-is-display-only ()
  "Indent both explicit and visual continuations without changing sent text."
  (omnigent-ui-test--conversation
    (insert "first\nsecond")
    (should (equal (buffer-substring-no-properties omnigent-conversation--prompt-start (point-max))
                   "first\nsecond"))
    (should-not (get-text-property omnigent-conversation--prompt-start 'line-prefix))
    (should (equal (get-text-property (+ omnigent-conversation--prompt-start 6) 'line-prefix) "  "))
    (should (equal (get-text-property omnigent-conversation--prompt-start 'wrap-prefix) "  "))))

(ert-deftest omnigent-ui-workspace-refresh-coalesces-and-isolates-sessions ()
  "Coalesce repeated refreshes and never replace another session's panel."
  (let ((omnigent-ui--workspace-cache (make-hash-table :test 'equal))
        (omnigent-ui--workspace-pending (make-hash-table :test 'equal))
        (omnigent-ui--workspace-again (make-hash-table :test 'equal))
        (omnigent-ui--selected-session "b")
        calls displays)
    (cl-letf (((symbol-function 'omnigent-workspace-list)
               (lambda (id callback) (push (cons id callback) calls)))
              ((symbol-function 'omnigent-ui--workspace-render) #'ignore)
              ((symbol-function 'omnigent-ui--workspace-display) (lambda () (push t displays))))
      (omnigent-ui-workspace-refresh "a")
      (omnigent-ui-workspace-refresh "a")
      (omnigent-ui-workspace-refresh "a")
      (should (= (length calls) 1))
      (funcall (cdar calls) 200 '((changes . (((path . "a") (status . "modified"))))))
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
  (let ((id "row-test") buffer)
    (unwind-protect
        (progn
          (omnigent-ui--workspace-render
           id '((changes . (((path . "z") (status . "created"))
                            ((path . "a") (status . "deleted"))
                            ((path . "m") (status . "modified"))))))
          (setq buffer (omnigent-ui--workspace-buffer id))
          (with-current-buffer buffer
            (should (equal (buffer-string) "[unified diff]\nD a\nM m\nA z\n"))
            (goto-char (point-min)) (forward-line 2)
            (omnigent-ui--workspace-render
             id '((changes . (((path . "m") (status . "created")) ((path . "b") (status . "modified"))))))
            (should (equal (get-text-property (point) 'omnigent-ui-path) "m"))
            (omnigent-ui--workspace-render id '((changes . (((path . "b") (status . "modified"))))))
            (should (equal (get-text-property (point) 'omnigent-ui-path) "b"))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest omnigent-ui-diff-reuses-buffer-and-keeps-it-on-failure ()
  "Reuse successful diff buffers and leave existing contents on failed fetch."
  (save-window-excursion
    (let (buffer)
      (unwind-protect
          (progn
            (omnigent-ui--diff-result "diff-test" "file" 200 "first diff\n")
            (setq buffer (current-buffer))
            (should (derived-mode-p 'diff-mode))
            (omnigent-ui--diff-result "diff-test" "file" 500 "bad")
            (should (equal (buffer-string) "first diff\n"))
            (omnigent-ui--diff-result "diff-test" "file" 200 "new diff\n")
            (should (eq buffer (current-buffer)))
            (should (equal (buffer-string) "new diff\n")))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest omnigent-ui-idle-timer-stops-on-reset ()
  "Start one ten-second idle timer even with hidden views and cancel on reset."
  (let ((omnigent-ui--idle-timer nil)
        (omnigent-sessions-updates 'updates)
        (omnigent-ui--workspace-cache (make-hash-table :test 'equal))
        (omnigent-ui--workspace-pending (make-hash-table :test 'equal))
        (omnigent-ui--workspace-again (make-hash-table :test 'equal))
        (calls 0) canceled)
    (cl-letf (((symbol-function 'run-with-idle-timer)
               (lambda (seconds repeat function)
                 (should (= seconds 10)) (should repeat)
                 (should (eq function #'omnigent-ui-refresh))
                 (cl-incf calls) 'timer))
              ((symbol-function 'timerp) (lambda (timer) (eq timer 'timer)))
              ((symbol-function 'cancel-timer) (lambda (timer) (setq canceled timer))))
      (omnigent-ui-start)
      (omnigent-ui-start)
      (should (= calls 1))
      (omnigent-ui-reset)
      (should (eq canceled 'timer))
      (should-not omnigent-ui--idle-timer))))

(ert-deftest omnigent-ui-selected-title-keeps-state-face ()
  "Add bold to the selected title without losing its archived state face."
  (let ((omnigent-sessions '(((id . "selected") (title . "Title") (archived . t) (status . "running"))))
        (omnigent-ui--selected-session "selected")
        (omnigent-sessions-truncated nil))
    (unwind-protect
        (with-current-buffer (get-buffer-create "*omnigent-sessions*")
          (omnigent-ui-sessions-mode)
          (omnigent-ui-sessions-render)
          (should (equal (get-text-property (+ (point-min) 2) 'face)
                         '(bold omnigent-ui-session-archived))))
      (kill-buffer "*omnigent-sessions*"))))

(ert-deftest omnigent-ui-open-keeps-session-side-window ()
  "Open the selected conversation in the main window, leaving sessions visible."
  (save-window-excursion
    (let ((omnigent-sessions '(((id . "side-test") (title . "Side test"))))
          (omnigent-sessions--buffers nil)
          (omnigent-ui--selected-session nil)
          (omnigent-ui--workspace-visible nil)
          buffer)
      (cl-letf (((symbol-function 'omnigent-transport-start-session-stream) (lambda (&rest _) nil))
                ((symbol-function 'omnigent-ui-workspace-refresh) #'ignore))
        (unwind-protect
            (progn
              (omnigent-ui-sessions)
              (select-window (get-buffer-window "*omnigent-sessions*"))
              (omnigent-ui-sessions-open)
              (setq buffer (current-buffer))
              (should (derived-mode-p 'omnigent-conversation-mode))
              (should-not (window-parameter (selected-window) 'window-side))
              (should (get-buffer-window "*omnigent-sessions*")))
          (when (buffer-live-p buffer) (kill-buffer buffer))
          (when (get-buffer "*omnigent-sessions*") (kill-buffer "*omnigent-sessions*")))))))

(ert-deftest omnigent-ui-incoming-request-keeps-field-point ()
  "Preserve edited field text and its cursor offset when another request arrives."
  (omnigent-ui-test--conversation
    (omnigent-conversation--event
     "response.elicitation_request"
     '((elicitation_id . "first") (params . ((requestedSchema .
         ((type . "object") (properties . ((name . ((type . "string")))))))))))
    (let ((field (cl-find "name" omnigent-ui--widgets
                          :key (lambda (widget) (widget-get widget :field-name)) :test #'equal)))
      (widget-value-set field "Alice")
      (omnigent-ui--field-notify field)
      (goto-char (+ (widget-get field :from) 2)))
    (omnigent-conversation--event
     "response.elicitation_request" '((elicitation_id . "second") (params . ((message . "Next")))))
    (let ((field (cl-find "name" omnigent-ui--widgets
                          :key (lambda (widget) (widget-get widget :field-name)) :test #'equal)))
      (should (= (point) (+ (widget-get field :from) 2)))
      (should (equal (widget-value field) "Alice")))))

(ert-deftest omnigent-ui-stream-final-keeps-expanded-provisional-fold ()
  "Retain a user-expanded fold when the final server item adopts its stable ID."
  (omnigent-ui-test--conversation
    (omnigent-conversation--event "response.in_progress" '((response . ((id . "turn")))))
    (omnigent-conversation--event "response.reasoning_text.delta" '((delta . "think")))
    (omnigent-ui--fold-button (button-at (point-min)))
    (omnigent-conversation--event
     "response.output_item.done"
     '((item . ((id . "final") (type . "reasoning") (content . "thinking") (response_id . "turn")))))
    (should (gethash "final" omnigent-ui--folds))
    (goto-char (point-min)) (forward-line 1)
    (should-not (invisible-p (point)))))

(ert-deftest omnigent-ui-workspace-window-lifecycle ()
  "Stack side views, switch caches, close empty results and honor manual closure."
  (save-window-excursion
    (let ((omnigent-ui--selected-session "window-a")
          (omnigent-ui--workspace-visible nil)
          (omnigent-ui--workspace-closed nil)
          (omnigent-ui--workspace-cache (make-hash-table :test 'equal))
          (omnigent-ui--workspace-pending (make-hash-table :test 'equal))
          (omnigent-ui--workspace-again (make-hash-table :test 'equal))
          (omnigent-sessions nil))
      (unwind-protect
          (progn
            (omnigent-ui-sessions)
            (let ((data '((changes . (((path . "a") (status . "created")))))))
              (puthash "window-a" data omnigent-ui--workspace-cache)
              (omnigent-ui--workspace-render "window-a" data))
            (omnigent-ui--workspace-display)
            (let ((sessions (get-buffer-window "*omnigent-sessions*"))
                  (workspace (get-buffer-window (omnigent-ui--workspace-buffer "window-a"))))
              (should sessions) (should workspace)
              (should (< (nth 1 (window-edges sessions)) (nth 1 (window-edges workspace)))))
            (setq omnigent-ui--selected-session "window-b")
            (omnigent-ui--workspace-display)
            (with-current-buffer (window-buffer (get-buffer-window (omnigent-ui--workspace-buffer "window-b")))
              (should (string-empty-p (buffer-string))))
            (let ((window (get-buffer-window (omnigent-ui--workspace-buffer "window-b"))))
              (delete-window window)
              (omnigent-ui--windows-changed))
            (should omnigent-ui--workspace-closed)
            (puthash "window-b" '((changes . (((path . "b") (status . "modified")))))
                     omnigent-ui--workspace-cache)
            (omnigent-ui--workspace-display)
            (should-not omnigent-ui--workspace-visible)
            (setq omnigent-ui--workspace-closed nil)
            (omnigent-ui--workspace-display)
            (should omnigent-ui--workspace-visible)
            (puthash "window-b" '((changes . nil)) omnigent-ui--workspace-cache)
            (omnigent-ui--workspace-display)
            (should-not omnigent-ui--workspace-visible)
            (should (get-buffer-window "*omnigent-sessions*")))
        (dolist (name '("*omnigent-sessions*" "*omnigent-workspace: window-a*"
                        "*omnigent-workspace: window-b*"))
          (when (get-buffer name) (kill-buffer name)))))))

(ert-deftest omnigent-ui-removal-freezes-draft-and-rejects-late-workspace ()
  "Freeze a removed session and discard a pending workspace result for it."
  (omnigent-ui-test--conversation
    (insert "keep draft")
    (let ((omnigent-sessions--buffers (list (cons "conv_test" (current-buffer)))) callback)
      (cl-letf (((symbol-function 'omnigent-workspace-list)
                 (lambda (_id cb) (setq callback cb))))
        (omnigent-ui-workspace-refresh "conv_test"))
      (omnigent-ui--frame '((type . "removed") (ids . ["conv_test"])))
      (should buffer-read-only)
      (should-error (omnigent-conversation-send) :type 'user-error)
      (should (string-suffix-p "keep draft" (buffer-string)))
      (funcall callback 200 '((changes . (((path . "late") (status . "created"))))))
      (should-not (gethash "conv_test" omnigent-ui--workspace-cache)))))

(ert-deftest omnigent-ui-send-idle-renders-once-and-busy-does-not ()
  "Render successful idle sends and deduplicate mirrored user items."
  (dolist (status '("idle" "running" "waiting" "failed" nil))
    (omnigent-ui-test--conversation
      (let ((omnigent-sessions `(((id . "conv_test") (status . ,status)))))
        (insert "sent message")
        (cl-letf (((symbol-function 'omnigent-transport-post-session-event)
                   (lambda (_id _event callback) (funcall callback 202 nil))))
          (omnigent-conversation-send))
        (if (equal status "idle")
            (progn
              (should (= (hash-table-count omnigent-conversation--items) 1))
              (omnigent-conversation--event
               "response.output_item.done"
               '((item . ((id . "mirror") (type . "message") (role . "user") (content . "sent message")))))
              (should (equal omnigent-conversation--order '("mirror")))
              (should (= (how-many "You:" (point-min) (point-max)) 1)))
          (should (= (hash-table-count omnigent-conversation--items) 0)))))))

(ert-deftest omnigent-ui-scrolled-transcript-keeps-reading-position ()
  "Preserve point by item ID when transcript output is refreshed above the composer."
  (omnigent-ui-test--conversation
    (omnigent-conversation--snapshot
     200 '((items . [((id . "first") (type . "message") (content . "first text"))
                      ((id . "second") (type . "message") (content . "second text"))])))
    (goto-char (point-min)) (search-forward "second te")
    (let ((offset (- (point) (previous-single-property-change (point) 'omnigent-ui-item-id))))
      (omnigent-conversation--snapshot
       200 '((items . [((id . "first") (type . "message") (content . "a longer first text"))
                        ((id . "second") (type . "message") (content . "second text"))])))
      (should (equal (get-text-property (point) 'omnigent-ui-item-id) "second"))
      (should (= offset (- (point) (previous-single-property-change (point) 'omnigent-ui-item-id)))))))

(ert-deftest omnigent-ui-rejected-edit-does-not-lock-composer ()
  "A rejected transcript edit must not install widget-only editing on the composer."
  (omnigent-ui-test--conversation
    (omnigent-conversation--event
     "response.output_item.done" '((item . ((id . "a") (content . "protected")))))
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
     '((elicitation_id . "q") (params . ((requestedSchema .
          ((type . "object") (properties . ((name . ((type . "string")))))))))))
    (let ((field (cl-find "name" omnigent-ui--widgets
                          :key (lambda (widget) (widget-get widget :field-name)) :test #'equal)))
      (goto-char (widget-field-start field))
      (insert "typed")
      (should (equal (gethash "name" (omnigent-conversation-elicitation-draft "q")) "typed")))))

(provide 'omnigent-ui-test)
;;; omnigent-ui-test.el ends here
