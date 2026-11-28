;;; omnigent-conversation.el --- Session conversation buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Maintain and display conversations.  Send messages to session agents.

;;; Code:

(require 'cl-lib)
(require 'comint)
(require 'wid-edit)
(require 'markdown-mode)
(require 'subr-x)
(require 'omnigent-options)
(require 'omnigent-sessions)

(defvar omnigent-conversation--session-id nil
  "Major mode initialization clears buffer-local variables.
Bind this temporarily so the mode can set `omnigent-conversation-session-id'.")
(defvar-local omnigent-conversation-session-id nil
  "Session ID associated with the current conversation buffer.")
(defvar-local omnigent-conversation-host-id nil
  "Host ID from the latest successful session snapshot.")
(defvar-local omnigent-conversation-agent-name nil
  "Agent display name from the latest successful session snapshot.")
(defvar-local omnigent-conversation-header-data nil
  "Session settings and context usage from snapshots and stream events.")
(defvar omnigent-conversation--initial-sandbox-status nil
  "Sandbox launch status supplied while opening a newly created session.")
(defvar-local omnigent-conversation--sandbox-status nil
  "Current sandbox launch status, or nil after launch succeeds.")
(defvar-local omnigent-conversation--managed nil
  "Non-nil once this buffer identifies a managed sandbox session.")
(defvar-local omnigent-conversation--permission-read-only nil)
(defvar-local omnigent-conversation--elicitations nil)
(defvar-local omnigent-conversation--elicitation-drafts nil)
(defvar-local omnigent-conversation--elicitation-submitting nil)
(defvar-local omnigent-conversation--stream nil)
(defvar-local omnigent-conversation--items nil)
(defvar-local omnigent--conversation-side-chat-p nil
  "Non-nil when this conversation buffer is a side chat.")

(defvar-local omnigent-conversation--order nil)
(defvar-local omnigent-conversation--order-tail nil)
(defvar-local omnigent-conversation--pending-events nil)
(defvar-local omnigent-conversation--loading nil)
(defvar-local omnigent-conversation--invalid nil)
(defvar-local omnigent-conversation--retry-timer nil
  "Timer for retrying a failed session snapshot.")
(defvar-local omnigent-conversation--retry-count 0
  "Number of consecutive snapshot failures awaiting recovery.")
(defvar-local omnigent-conversation--connected t)
(defvar-local omnigent-conversation--pending-event-count 0)
(defvar-local omnigent-conversation--pending-event-bytes 0)
(defvar-local omnigent-conversation--prompt-start nil)
(defvar-local omnigent-conversation--prompt-end nil)
(defvar-local omnigent-conversation--sending nil)
(defvar-local omnigent-conversation--pending-inputs nil
  "Submitted inputs in queue order, separate from committed transcript items.")
(defvar-local omnigent-conversation--response-id nil)
(defvar-local omnigent-conversation--status nil
  "Status from the session snapshot or event stream.")
(defvar-local omnigent-conversation--section-id nil)
(defvar-local omnigent-conversation-change-hook nil
  "Hook run after conversation state changes in this buffer.")
(defvar-local omnigent-conversation-event-hook nil
  "Hook called with stream event name and data after processing.")
(defvar-local omnigent-conversation--elicitation-order nil)
(defun omnigent-conversation--setting-choices (setting session)
  "Return completion choices for SETTING from SESSION's model catalog."
  (let ((models (alist-get 'model_options session)))
    (unless (and (vectorp models)
                 (cl-every
                  (lambda (model)
                    (and (stringp (alist-get 'id model))
                         (or (null (alist-get 'model model))
                             (stringp (alist-get 'model model)))))
                  models))
      (error "Invalid session model catalog"))
    (if (eq setting 'model)
        (mapcar
         (lambda (model)
           (or (alist-get 'model model) (alist-get 'id model)))
         models)
      (let* ((current
              (or (alist-get 'model_override session)
                  (alist-get 'llm_model session)))
             (model
              (cl-find-if
               (lambda (row)
                 (and (stringp current)
                      (member
                       current
                       (list
                        (alist-get 'id row) (alist-get 'model row)))))
               models))
             (efforts (alist-get 'supportedReasoningEfforts model)))
        (unless (and model
                     (vectorp efforts)
                     (cl-every
                      (lambda (effort)
                        (stringp (alist-get 'reasoningEffort effort)))
                      efforts))
          (error
           "Effort choices are unavailable for the current model"))
        (mapcar
         (lambda (effort) (alist-get 'reasoningEffort effort))
         efforts)))))

(defun omnigent-conversation--text (item)
  "Return the text in ITEM, combining content parts when necessary."
  (let ((content (alist-get 'content item)))
    (cond
     ((stringp content)
      content)
     ((vectorp content)
      (mapconcat (lambda (part) (or (alist-get 'text part) ""))
                 (append content nil)
                 ""))
     (t
      (or (alist-get 'text item) "")))))

(defun omnigent-conversation--put-item (item)
  "Store ITEM by ID and keep insertion order within the history limit."
  ;; Snapshot items wrap their message fields in `data'.  Stream items may
  ;; already have those fields at the top level.
  (let ((id (alist-get 'id item))
        (data (alist-get 'data item)))
    (when (listp data)
      (setq item (append item data)))
    (when (and (equal (alist-get 'type item) "slash_command")
               (equal (alist-get 'kind item) "skill"))
      (setf
       (alist-get 'role item) "user"
       (alist-get 'content item)
       (concat
        "/" (or (alist-get 'name item) "")
        (if (string-empty-p (or (alist-get 'arguments item) ""))
            ""
          (concat " " (alist-get 'arguments item))))))
    (when id
      (unless (gethash id omnigent-conversation--items)
        (when (>= (hash-table-count omnigent-conversation--items)
                  (max 1 omnigent-transport-history-limit))
          (remhash
           (pop omnigent-conversation--order)
           omnigent-conversation--items)
          (unless omnigent-conversation--order
            (setq omnigent-conversation--order-tail nil)))
        (let ((cell (list id)))
          (if omnigent-conversation--order-tail
              (setcdr omnigent-conversation--order-tail cell)
            (setq omnigent-conversation--order cell))
          (setq omnigent-conversation--order-tail cell)))
      (puthash id item omnigent-conversation--items))))

(defun omnigent-conversation--delta (kind data)
  "Append DATA to an identified item or the active response's KIND section."
  (let* ((item-id (alist-get 'item_id data))
         (message-id (alist-get 'message_id data))
         (explicit-id (or item-id message-id))
         (id (or explicit-id omnigent-conversation--section-id))
         (item (and id (gethash id omnigent-conversation--items))))
    (when (and omnigent-conversation--response-id
               (or (not explicit-id) (and message-id (not item))))
      (unless (and item (equal (alist-get 'type item) kind))
        (setq
         id (or message-id (make-symbol "live-section"))
         item
         `((id . ,id)
           (type . ,kind)
           (content . ,(string))
           (response_id . ,omnigent-conversation--response-id)
           (omnigent-provisional . t)))
        (when (and message-id
                   (numberp (alist-get 'index data))
                   (> (alist-get 'index data) 0))
          (push '(omnigent-missing-prefix . t) item))
        (when (equal kind "message")
          (push '(role . "assistant") item))
        (omnigent-conversation--put-item item)
        (setq omnigent-conversation--section-id id)))
    (when (and item (not (alist-get 'omnigent-committed item)))
      (setf (alist-get 'content item)
            (concat
             (omnigent-conversation--text item)
             (or (alist-get 'delta data) ""))))))

(defun omnigent-conversation--stream-item
    (item &optional added message-id)
  "Reconcile stream ITEM in place; ADDED starts an identified section.
MESSAGE-ID identifies the native preview that ITEM finalizes."
  (let*
      ((item (omnigent-transport--output-item item))
       (id (alist-get 'id item))
       (kind (alist-get 'type item))
       (response-id
        (or (alist-get 'response_id item)
            omnigent-conversation--response-id))
       (active
        (gethash
         omnigent-conversation--section-id
         omnigent-conversation--items))
       (provisional
        (and
         id
         (not (gethash id omnigent-conversation--items))
         (not (equal (alist-get 'role item) "user"))
         (if message-id
             (when (alist-get
                    'omnigent-provisional
                    (gethash message-id omnigent-conversation--items))
               message-id)
           (or
            (cl-find-if
             (lambda (old-id)
               (let ((old
                      (gethash old-id omnigent-conversation--items)))
                 (and (alist-get 'omnigent-provisional old)
                      (equal (alist-get 'response_id old) response-id)
                      (equal (alist-get 'type old) kind)
                      (equal
                       (omnigent-conversation--text old)
                       (omnigent-conversation--text item)))))
             omnigent-conversation--order)
            (and
             (alist-get 'omnigent-provisional active)
             (equal (alist-get 'type active) kind)
             (or
              (equal (alist-get 'response_id active) response-id)
              ;; A native snapshot can report a different response ID
              ;; and leave the resumed stream with only a suffix.
              (and (not added)
                   (alist-get 'omnigent-missing-prefix active)
                   (let ((suffix
                          (omnigent-conversation--text active)))
                     (and
                      (not (string-empty-p suffix))
                      (string-suffix-p
                       suffix (omnigent-conversation--text item))))))
             omnigent-conversation--section-id))))))
    (unless (and added
                 (alist-get
                  'omnigent-committed
                  (gethash id omnigent-conversation--items)))
      (unless added
        (setf (alist-get 'omnigent-committed item) t))
      (when provisional
        (setf (alist-get 'omnigent-previous-id item) provisional)
        (setcar (member provisional omnigent-conversation--order) id)
        (remhash provisional omnigent-conversation--items)
        (puthash id item omnigent-conversation--items))
      (when (or (equal id omnigent-conversation--section-id)
                (equal provisional omnigent-conversation--section-id)
                (not (member kind '("message" "reasoning"))))
        (setq omnigent-conversation--section-id nil))
      (omnigent-conversation--put-item item)
      (when (and added
                 (member kind '("message" "reasoning"))
                 (not (equal (alist-get 'role item) "user")))
        (setq omnigent-conversation--section-id id)))))

(defun omnigent-conversation--consume-input (data)
  "Commit the input in event DATA and settle only its matching pending entry."
  (let*
      ((payload (alist-get 'data data))
       (id (alist-get 'item_id payload))
       (kind (alist-get 'type payload))
       (content (alist-get 'data payload))
       (pending-id (alist-get 'cleared_pending_id payload))
       (known (and id (gethash id omnigent-conversation--items)))
       (text (string-trim (omnigent-conversation--text content)))
       (eligible
        (and
         (equal kind "message")
         (equal (alist-get 'role content) "user")
         (not (eq (alist-get 'is_meta content) t))
         (not
          (string-match-p
           "\\`\\(?:\\[System: \\|\\[Request interrupted by user\\|<task-notification>\\|<teammate-message\\|<agent-message\\)"
           text))))
       (entry
        (and
         eligible
         (if pending-id
             (cl-find
              pending-id
              omnigent-conversation--pending-inputs
              :key
              (lambda (input) (alist-get 'pending_id input))
              :test #'equal)
           ;; ponytail: FIFO assumes ordered user inputs; require pending IDs
           ;; if multiple producers interleave inputs without identifiers.
           (and (not known)
                (cl-find-if
                 (lambda (input)
                   (memq
                    (alist-get 'state input)
                    '(submitting queued accepted)))
                 omnigent-conversation--pending-inputs))))))
    (when (and (stringp id) (stringp kind))
      (when (and eligible pending-id omnigent-conversation--sending)
        (push pending-id
              (alist-get
               'consumed-pending-ids omnigent-conversation--sending)))
      (when entry
        (setf (alist-get 'state entry) 'consumed)
        (setq omnigent-conversation--pending-inputs
              (delq entry omnigent-conversation--pending-inputs)))
      (omnigent-conversation--stream-item
       `((id . ,id) (type . ,kind) (data . ,content))))))

(defconst omnigent-conversation--event-handlers
  `((("response.elicitation_request")
     .
     ,(lambda (data)
        (setq omnigent-conversation--section-id nil)
        (omnigent-conversation--elicitation-put data)
        (run-hooks 'omnigent-conversation-elicitation-change-hook)))
    (("response.elicitation_resolved")
     .
     ,(lambda (data)
        (when-let* ((id (alist-get 'elicitation_id data)))
          (omnigent-conversation--elicitation-remove id))
        (run-hooks 'omnigent-conversation-elicitation-change-hook)))
    (("session.input.consumed")
     .
     ,#'omnigent-conversation--consume-input)
    (("response.output_item.added")
     .
     ,(lambda (data)
        (omnigent-conversation--stream-item (alist-get 'item data)
                                            t)))
    (("response.output_item.done")
     .
     ,(lambda (data)
        (omnigent-conversation--stream-item (alist-get 'item data)
                                            nil
                                            (alist-get
                                             'message_id data))))
    (("response.reasoning.started")
     .
     ,(lambda (_data) (setq omnigent-conversation--section-id nil)))
    (("response.created" "response.in_progress" "session.status")
     .
     ,(lambda (data)
        (when-let* ((id
                     (omnigent-transport--starting-response-id data)))
          (when (or (not omnigent-conversation--response-id)
                    (equal id omnigent-conversation--response-id)
                    (equal (alist-get 'status data) "running"))
            (unless (equal id omnigent-conversation--response-id)
              (setq omnigent-conversation--section-id nil))
            (setq omnigent-conversation--response-id id)))
        (when (and (member
                    (alist-get 'status data) '("idle" "failed"))
                   (equal
                    (alist-get 'response_id data)
                    omnigent-conversation--response-id))
          (setq
           omnigent-conversation--response-id nil
           omnigent-conversation--section-id nil))))
    (("response.output_text.delta")
     .
     ,(lambda (data) (omnigent-conversation--delta "message" data)))
    (("response.reasoning_text.delta"
      "response.reasoning_summary_text.delta")
     .
     ,(lambda (data) (omnigent-conversation--delta "reasoning" data)))
    (("response.completed"
      "response.incomplete"
      "response.cancelled"
      "session.interrupted")
     .
     ,(lambda (data)
        ;; Input delivery can complete independently of the native model turn.
        (let ((id (alist-get 'id (alist-get 'response data))))
          (when (and id (equal id omnigent-conversation--response-id))
            (setq
             omnigent-conversation--response-id nil
             omnigent-conversation--section-id nil)))))
    (("response.error" "response.failed")
     .
     ,(lambda (data)
        (setq
         omnigent-conversation--response-id nil
         omnigent-conversation--section-id nil)
        (omnigent-conversation--put-item
         `((id
            .
            ,(format "error-%s" (float-time)))
           (type . "error")
           (text
            . ,(format "%s" (or (alist-get 'error data) data))))))))
  "Event names and their conversation state handlers.")

(defun omnigent-conversation--event (name data)
  "Apply stream event NAME with DATA, or queue it while loading."
  (unless omnigent-conversation--invalid
    (if omnigent-conversation--loading
        (progn
          (cl-incf omnigent-conversation--pending-event-count)
          (cl-incf omnigent-conversation--pending-event-bytes
                   (+ (string-bytes name)
                      (string-bytes (prin1-to-string data))))
          (if (or (> omnigent-conversation--pending-event-count
                     omnigent-conversation-recovery-event-limit)
                  (> omnigent-conversation--pending-event-bytes
                     omnigent-conversation-recovery-byte-limit))
              (omnigent-conversation--invalidate
               nil "Snapshot event buffer overflow")
            (push
             (cons name data) omnigent-conversation--pending-events)))
      (pcase (cl-find-if
              (lambda (entry) (member name (car entry)))
              omnigent-conversation--event-handlers)
        (`(,_ . ,handler) (funcall handler data)))
      (pcase name
        ("session.status" (setq omnigent-conversation--status
               (alist-get 'status data)))
        ("session.sandbox_status"
         (when (stringp (alist-get 'stage data))
           (setq
            omnigent-conversation--managed t
            omnigent-conversation--sandbox-status
            (unless (equal (alist-get 'stage data) "ready")
              data))
           (omnigent-conversation--read-only)
           (when (and (equal (alist-get 'stage data) "ready")
                      omnigent-conversation--stream)
             (omnigent-transport-refresh-session-stream
              omnigent-conversation--stream))))
        ("session.model" (setf (alist-get
                'llm_model omnigent-conversation-header-data)
               (alist-get 'model data)))
        ("session.reasoning_effort" (setf (alist-get
                'reasoning_effort omnigent-conversation-header-data)
               (alist-get 'reasoning_effort data)))
        ((or "session.permission_mode" "session.codex_approval_mode")
         (setf (alist-get
                'access_mode omnigent-conversation-header-data)
               (alist-get
                (if (equal name "session.permission_mode")
                    'permission_mode
                  'approval_mode)
                data)))
        ("session.usage" (dolist (field
                  '((context_tokens . last_total_tokens)
                    (context_window . context_window)))
           (when (numberp (alist-get (car field) data))
             (setf (alist-get
                    (cdr field) omnigent-conversation-header-data)
                   (alist-get (car field) data)))))
        ("response.completed"
         (let* ((usage (alist-get 'usage (alist-get 'response data)))
                (tokens
                 (or (alist-get 'context_tokens usage)
                     (alist-get 'total_tokens usage)))
                (model (alist-get 'model usage)))
           (when (numberp tokens)
             (setf (alist-get
                    'last_total_tokens
                    omnigent-conversation-header-data)
                   tokens))
           (when (and (stringp model) (not (string-empty-p model)))
             (setf (alist-get
                    'llm_model omnigent-conversation-header-data)
                   model)))))
      (when (and (equal name "session.status")
                 (equal (alist-get 'status data) "failed")
                 (alist-get 'error data))
        (omnigent-conversation--put-item
         `((id . ,(format "error-%s" (float-time)))
           (type . "error")
           (text . ,(format "%s" (alist-get 'error data))))))
      (when (equal name "session.interrupted")
        (omnigent-conversation--put-item
         `((id . ,(format "interrupt-%s" (float-time)))
           (type . "error")
           (text . "Interrupted")))
        (when omnigent-conversation--stream
          (omnigent-transport-refresh-session-stream
           omnigent-conversation--stream)))
      (run-hook-with-args 'omnigent-conversation-event-hook name data)
      (run-hooks 'omnigent-conversation-change-hook))))

(defun omnigent-conversation--write-blocked-p ()
  "Return non-nil when session state prevents writes."
  (not
   (omnigent-transport--session-write-ready-p
    omnigent-conversation--connected
    (not omnigent-conversation--loading)
    (or omnigent-conversation--invalid
        omnigent-conversation--permission-read-only)
    (member
     (alist-get 'stage omnigent-conversation--sandbox-status)
     '("failed" "action_required")))))

(defun omnigent-conversation-ready-p ()
  "Return non-nil when the current conversation can submit composer text."
  (and (derived-mode-p 'omnigent-conversation-mode)
       (not (omnigent-conversation--write-blocked-p))
       (not omnigent-conversation--sending)))

(defun omnigent-conversation--read-only ()
  "Apply recovery and server permission restrictions without losing drafts."
  (let ((previous buffer-read-only))
    (setq buffer-read-only (omnigent-conversation--write-blocked-p))
    (unless (eq previous buffer-read-only)
      (omnigent-conversation--notify-submission-change))))

(defun omnigent-conversation--connection-state (state)
  "Apply stream connection STATE to this conversation."
  (unless omnigent-conversation--invalid
    (let ((was-read-only buffer-read-only))
      (setq omnigent-conversation--connected (eq state 'connected))
      (omnigent-conversation--read-only)
      (unless (eq was-read-only buffer-read-only)
        (omnigent-conversation--notify-input-change)))))

(defun omnigent-conversation--begin-snapshot ()
  "Make this conversation read-only and buffer events during its next snapshot."
  (unless omnigent-conversation--invalid
    (setq
     omnigent-conversation--loading t
     omnigent-conversation--pending-events nil
     omnigent-conversation--pending-event-count 0
     omnigent-conversation--pending-event-bytes 0)
    (omnigent-conversation--read-only)))

(defun omnigent-conversation--freeze ()
  "Stop recovery and preserve this conversation and its drafts as read-only."
  (setq
   omnigent-conversation--invalid t
   omnigent-conversation--loading nil
   omnigent-conversation--connected nil
   omnigent-conversation--pending-events nil
   omnigent-conversation--pending-event-count 0
   omnigent-conversation--pending-event-bytes 0)
  (omnigent-conversation--close)
  (omnigent-conversation--read-only))

(defun omnigent-conversation--invalidate (status body)
  "Freeze this buffer after snapshot failure STATUS and BODY and report recovery."
  (unless omnigent-conversation--invalid
    (omnigent-conversation--freeze)
    (when (equal status 404)
      (omnigent-sessions--frame
       `((type . "removed")
         (ids . ,(vector omnigent-conversation-session-id)))))
    (if (and omnigent-conversation-auto-recovery
             (not
              (member
               body
               '("Invalid session snapshot"
                 "Snapshot event buffer overflow")))
             (or (null status)
                 (consp status)
                 (memq status '(408 429 500 502 503 504))))
        (let ((buffer (current-buffer)))
          (cl-incf omnigent-conversation--retry-count)
          (setq omnigent-conversation--retry-timer
                (run-at-time
                 (omnigent-transport--reconnect-delay
                  omnigent-conversation--retry-count)
                 nil
                 (lambda ()
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (omnigent-conversation-reconnect)))))))
      (message
       "%s. %s"
       (omnigent-transport-error-message
        "Omnigent snapshot failed" status body)
       (substitute-command-keys
        "Use \\[omnigent-conversation-reconnect] to reconnect this session")))))

(defun omnigent-conversation--snapshot-valid-p (body)
  "Check required snapshot arrays and fields before replacing state with BODY."
  (condition-case nil
      (and (listp body)
           (cl-every
            (lambda (key) (vectorp (alist-get key body)))
            '(items pending_inputs pending_elicitations))
           (cl-every
            (lambda (item)
              (and (listp item)
                   (stringp (alist-get 'id item))
                   (not (string-empty-p (alist-get 'id item)))
                   (listp (alist-get 'data item))))
            (alist-get 'items body))
           (cl-every
            (lambda (input)
              (and (listp input)
                   (stringp (alist-get 'pending_id input))
                   (not
                    (string-empty-p (alist-get 'pending_id input)))
                   (or (stringp (alist-get 'content input))
                       (vectorp (alist-get 'content input)))))
            (alist-get 'pending_inputs body))
           (cl-every
            (lambda (request)
              (and (listp request)
                   (stringp (alist-get 'elicitation_id request))
                   (not
                    (string-empty-p
                     (alist-get 'elicitation_id request)))
                   (listp (alist-get 'params request))
                   (listp
                    (alist-get
                     'requestedSchema (alist-get 'params request)))
                   (cl-every
                    (lambda (property)
                      (and (consp property)
                           (symbolp (car property))
                           (listp (cdr property))))
                    (alist-get
                     'properties
                     (alist-get
                      'requestedSchema
                      (alist-get 'params request))))))
            (alist-get 'pending_elicitations body)))
    (error
     nil)))

(defun omnigent-conversation--snapshot (status body)
  "Validate and apply snapshot BODY once, or invalidate on failed STATUS."
  (unless omnigent-conversation--invalid
    (when (and (omnigent-transport-success-p status)
               (not (omnigent-conversation--snapshot-valid-p body)))
      (setq
       status nil
       body "Invalid session snapshot"))
    (if (not (omnigent-transport-success-p status))
        (omnigent-conversation--invalidate status body)
      (setq omnigent-conversation--retry-count 0)
      (let ((events (nreverse omnigent-conversation--pending-events)))
        (setq
         omnigent-conversation--pending-events nil
         omnigent-conversation--pending-event-count 0
         omnigent-conversation--pending-event-bytes 0)
        (setq omnigent-conversation--permission-read-only
              (equal (alist-get 'permission_level body) 1))
        (let* ((status (alist-get 'sandbox_status body))
               (stage (alist-get 'stage status)))
          (when (or stage
                    (alist-get 'sandbox_profile body)
                    (assq
                     'omnigent.sandbox.repo (alist-get 'labels body))
                    (assq
                     'omnigent.sandbox.repo.0
                     (alist-get 'labels body))
                    (assq
                     'omnigent.sandbox.requested_host_id
                     (alist-get 'labels body)))
            (setq omnigent-conversation--managed t))
          (setq omnigent-conversation--sandbox-status
                (cond
                 ((equal stage "ready")
                  nil)
                 (stage
                  status)
                 ((and omnigent-conversation--sandbox-status
                       (equal (alist-get 'status body) "failed"))
                  (if (equal
                       (alist-get
                        'stage omnigent-conversation--sandbox-status)
                       "failed")
                      omnigent-conversation--sandbox-status
                    '((stage . "failed"))))
                 ((alist-get 'host_id body)
                  nil)
                 (t
                  omnigent-conversation--sandbox-status))))
        (setq
         omnigent-conversation-host-id (alist-get 'host_id body)
         omnigent-conversation-agent-name (alist-get 'agent_name body)
         omnigent-conversation-header-data
         `((workspace . ,(alist-get 'workspace body))
           (project_id . ,(alist-get 'project_id body))
           (harness . ,(alist-get 'harness body))
           (llm_model . ,(alist-get 'llm_model body))
           (reasoning_effort . ,(alist-get 'reasoning_effort body))
           (permission_level . ,(alist-get 'permission_level body))
           (access_mode
            .
            ,(or (alist-get
                  'omnigent.claude_native.permission_mode
                  (alist-get 'labels body))
                 (alist-get
                  'omnigent.codex_native.approval_mode
                  (alist-get 'labels body))))
           (last_total_tokens . ,(alist-get 'last_total_tokens body))
           (context_window . ,(alist-get 'context_window body))))
        (unless omnigent--conversation-side-chat-p
          (clrhash omnigent-conversation--items)
          (setq
           omnigent-conversation--order nil
           omnigent-conversation--order-tail nil))
        (clrhash omnigent-conversation--elicitations)
        (setq omnigent-conversation--elicitation-order nil)
        (dolist (request
                 (append (alist-get 'pending_elicitations body) nil))
          (omnigent-conversation--elicitation-put request))
        (maphash
         (lambda (id _draft)
           (unless (gethash id omnigent-conversation--elicitations)
             (remhash id omnigent-conversation--elicitation-drafts)))
         omnigent-conversation--elicitation-drafts)
        (setq omnigent-conversation--pending-inputs
              (mapcar
               (lambda (input)
                 (copy-tree (cons '(state . queued) input) t))
               (append (alist-get 'pending_inputs body) nil)))
        (setq
         omnigent-conversation--response-id
         (alist-get 'active_response_id body)
         omnigent-conversation--status (alist-get 'status body)
         omnigent-conversation--section-id nil
         omnigent-conversation--loading nil)
        (dolist (item (append (alist-get 'items body) nil))
          (setq item (copy-tree item t))
          (setf (alist-get 'omnigent-committed item) t)
          (omnigent-conversation--put-item item))
        (dolist (event events)
          ;; Without shared sequence numbers, partial deltas can overlap committed text.
          ;; Final full items recover authoritative content; keep other event types.
          (unless (member
                   (car event)
                   '("response.output_text.delta"
                     "response.reasoning_text.delta"
                     "response.reasoning_summary_text.delta"))
            (omnigent-conversation--event (car event) (cdr event))))
        (omnigent-conversation--read-only)
        (run-hooks 'omnigent-conversation-elicitation-change-hook)
        (run-hooks 'omnigent-conversation-change-hook)))))

(defun omnigent-conversation--close ()
  "Stop the current buffer's session stream."
  (when (timerp omnigent-conversation--retry-timer)
    (cancel-timer omnigent-conversation--retry-timer))
  (setq omnigent-conversation--retry-timer nil)
  (when omnigent-conversation--stream
    (omnigent-transport-stop-session-stream
     omnigent-conversation--stream)))

(defun omnigent-conversation--notify-input-change ()
  "Notify conversation observers without interrupting input submission."
  (save-current-buffer
    (condition-case err
        (run-hooks 'omnigent-conversation-change-hook)
      (error
       (display-warning
        'omnigent
        (format "Conversation change hook failed: %s"
                (error-message-string err)))))))

(defun omnigent-conversation--sent (buffer entry status body)
  "Apply send STATUS and BODY to ENTRY in BUFFER without recreating old input."
  (when (and (buffer-live-p buffer)
             (not
              (buffer-local-value
               'omnigent-conversation--invalid buffer)))
    (with-current-buffer buffer
      (setq omnigent-conversation--sending nil)
      (let* ((data (and (listp body) body))
             (accepted
              (and (omnigent-transport-success-p status)
                   (not (eq (alist-get 'denied data) t))))
             (text
              (or (alist-get 'draft entry)
                  (omnigent-conversation--text entry))))
        (if accepted
            (progn
              (let ((draft
                     (buffer-substring-no-properties
                      omnigent-conversation--prompt-start
                      (point-max)))
                    (inhibit-read-only t))
                (when (string-prefix-p text draft)
                  (delete-region
                   omnigent-conversation--prompt-start
                   (+ omnigent-conversation--prompt-start
                      (length text)))))
              (when (memq entry omnigent-conversation--pending-inputs)
                (let ((id (alist-get 'item_id data))
                      (pending-id (alist-get 'pending_id data)))
                  (cond
                   ((stringp id)
                    (setq omnigent-conversation--pending-inputs
                          (delq
                           entry
                           omnigent-conversation--pending-inputs))
                    (unless (gethash id omnigent-conversation--items)
                      (omnigent-conversation--put-item
                       `((id . ,id)
                         (type . "message")
                         (role . "user")
                         (content . ,(alist-get 'content entry))))))
                   ((and pending-id
                         (member
                          pending-id
                          (alist-get 'consumed-pending-ids entry)))
                    (setf (alist-get 'state entry) 'consumed)
                    (setq omnigent-conversation--pending-inputs
                          (delq
                           entry
                           omnigent-conversation--pending-inputs)))
                   (t
                    (setf
                     (alist-get 'pending_id entry) pending-id
                     (alist-get 'state entry)
                     (if (or (stringp pending-id)
                             (eq (alist-get 'queued data) t))
                         'queued
                       'accepted)))))))
          (if (or (eq (alist-get 'denied data) t)
                  (and (integerp status) (<= 400 status 499)))
              (setq omnigent-conversation--pending-inputs
                    (delq
                     entry omnigent-conversation--pending-inputs))
            (when (memq entry omnigent-conversation--pending-inputs)
              (setf (alist-get 'state entry) 'unconfirmed)))
          (message "%s"
                   (omnigent-transport-error-message
                    "Omnigent send failed" status body)))
        (omnigent-conversation--notify-input-change)))))


(defun omnigent-conversation--interrupted (status body)
  "Report a failed interrupt STATUS; successful acceptance needs no UI change."
  (unless (omnigent-transport-success-p status)
    (message "%s"
             (omnigent-transport-error-message
              "Omnigent interrupt failed" status body))))


;;; Elicitations

(defvar-local omnigent-conversation-elicitation-change-hook nil
  "Functions called without arguments when elicitation state changes.")

(defun omnigent-conversation-elicitations ()
  "Return pending request events for the current conversation.
Each event contains `elicitation_id' and `params'.  Frontends must not
modify the returned objects."
  (delq
   nil
   (mapcar
    (lambda (id)
      (gethash id omnigent-conversation--elicitations))
    omnigent-conversation--elicitation-order)))

(defun omnigent-conversation-elicitation-draft (id)
  "Return ID's draft as a hash table with string keys.
JSON false is `:json-false'; JSON null is `:null'.  Missing keys are
unanswered.  The frontend must use the setter to change this table."
  (copy-hash-table
   (or (gethash id omnigent-conversation--elicitation-drafts)
       (make-hash-table :test 'equal))))

(defun omnigent-conversation-elicitation-set-draft (id content)
  "Set ID's draft to CONTENT, a hash table with string property names."
  (unless (gethash id omnigent-conversation--elicitations)
    (error "Unknown elicitation: %s" id))
  (unless (hash-table-p content)
    (error "Draft must be a hash table"))
  (puthash
   id
   (copy-hash-table content)
   omnigent-conversation--elicitation-drafts)
  (run-hooks 'omnigent-conversation-elicitation-change-hook))

(defun omnigent-conversation-elicitation-questions (id)
  "Return structured questions for elicitation ID."
  (append
   (alist-get
    'questions
    (alist-get
     'ask_user_question
     (alist-get
      'params (gethash id omnigent-conversation--elicitations))))
   nil))

(defun omnigent-conversation-elicitation-validate (id)
  "Return (FIELD . ERROR) pairs for ID's schema or structured questions."
  (let ((questions (omnigent-conversation-elicitation-questions id)))
    (if (not questions)
        (omnigent-conversation--validate-schema id)
      (let ((draft (omnigent-conversation-elicitation-draft id))
            errors
            (index 0))
        (dolist (question questions)
          (let* ((key
                  (format "%s" (or (alist-get 'id question) index)))
                 (value (gethash key draft))
                 (options
                  (mapcar
                   (lambda (option) (alist-get 'label option))
                   (append (alist-get 'options question) nil)))
                 (values
                  (if (eq (alist-get 'multiSelect question) t)
                      (and (vectorp value) (append value nil))
                    (list value))))
            (unless (and values
                         (cl-every
                          (lambda (answer)
                            (and (stringp answer)
                                 (not (string-empty-p answer))
                                 (or (member answer options)
                                     (not
                                      (eq
                                       (alist-get 'isOther question)
                                       :json-false)))))
                          values))
              (push (cons key "Choose an option or enter an answer")
                    errors)))
          (cl-incf index))
        (nreverse errors)))))

(defun omnigent-conversation-elicitation-submitting-p (id)
  "Return non-nil when a response for ID is in flight."
  (gethash id omnigent-conversation--elicitation-submitting))

(defun omnigent-conversation--elicitation-put (request)
  "Store a local elicitation REQUEST and initialize its draft."
  (when-let* ((id (alist-get 'elicitation_id request))
              ((let ((target
                      (alist-get
                       'target_session_id
                       (alist-get 'params request))))
                 (or (not target)
                     (equal
                      target omnigent-conversation-session-id)))))
    (unless (gethash id omnigent-conversation--elicitations)
      (setq omnigent-conversation--elicitation-order
            (append
             omnigent-conversation--elicitation-order (list id))))
    (puthash id request omnigent-conversation--elicitations)
    (unless (gethash id omnigent-conversation--elicitation-drafts)
      (let ((draft (make-hash-table :test 'equal)))
        (dolist (property
                 (alist-get
                  'properties
                  (alist-get
                   'requestedSchema (alist-get 'params request))))
          (when (assq 'default (cdr property))
            (puthash
             (symbol-name (car property))
             (let ((value (alist-get 'default (cdr property))))
               (if (null value)
                   :null value))
             draft)))
        (let ((index 0))
          (dolist (question
                   (omnigent-conversation-elicitation-questions id))
            (when-let* ((input (alist-get 'textInput question))
                        ((assq 'default input)))
              (puthash
               (format "%s"
                       (or (alist-get 'id question) index))
               (alist-get 'default input) draft))
            (cl-incf index)))
        (puthash
         id draft omnigent-conversation--elicitation-drafts)))))

(defun omnigent-conversation--elicitation-remove (id)
  "Remove elicitation ID and its draft."
  (setq omnigent-conversation--elicitation-order
        (delete id omnigent-conversation--elicitation-order))
  (remhash id omnigent-conversation--elicitations)
  (remhash id omnigent-conversation--elicitation-drafts))

(defun omnigent-conversation--validate-schema (id)
  "Return validation errors for ID's draft as (FIELD . MESSAGE) pairs.
A nil FIELD identifies an unsupported or invalid schema.  Supported field
types are string, integer, number, boolean and null.  Supported constraints
are required, enum, minimum, maximum, minLength and maxLength."
  (let* ((request
          (or (gethash id omnigent-conversation--elicitations)
              (error "Unknown elicitation: %s" id)))
         (schema
          (alist-get 'requestedSchema (alist-get 'params request)))
         (properties (alist-get 'properties schema))
         (required (append (alist-get 'required schema) nil))
         (draft (omnigent-conversation-elicitation-draft id))
         (missing (make-symbol "missing"))
         errors)
    (cl-labels
     ((problem (field text) (push (cons field text) errors))
      (unsupported
       (object allowed field)
       (dolist (entry object)
         (unless (memq (car entry) allowed)
           (problem
            field
            (format "Unsupported schema keyword: %s" (car entry)))))))
     (unless (or (null schema) (listp schema))
       (problem nil "Invalid schema"))
     (when (listp schema)
       (unsupported
        schema '(type properties required title description) nil)
       (when (and (alist-get 'type schema)
                  (not (equal (alist-get 'type schema) "object")))
         (problem nil "Schema must describe an object"))
       (dolist (name required)
         (when (eq (gethash name draft missing) missing)
           (problem name "Required")))
       (maphash
        (lambda (name _value)
          (unless (cl-find
                   name
                   properties
                   :key (lambda (p) (symbol-name (car p)))
                   :test #'equal)
            (problem name "Unknown field")))
        draft)
       (dolist (property properties)
         (let* ((name (symbol-name (car property)))
                (spec (cdr property))
                (type (alist-get 'type spec))
                (types
                 (if (vectorp type)
                     (append type nil)
                   (list type)))
                (value (gethash name draft missing))
                (enum (alist-get 'enum spec)))
           (unsupported
            spec
            '(type
              title
              description
              default
              enum
              enumNames
              minimum
              maximum
              minLength
              maxLength
              format
              secret)
            name)
           (when (and (alist-get 'format spec)
                      (not
                       (equal (alist-get 'format spec) "password")))
             (problem name "Unsupported string format"))
           (dolist (key '(minimum maximum minLength maxLength))
             (when (and (assq key spec)
                        (not
                         (if (memq key '(minLength maxLength))
                             (and (integerp (alist-get key spec))
                                  (>= (alist-get key spec) 0))
                           (numberp (alist-get key spec)))))
               (problem name (format "Invalid %s constraint" key))))
           (when (and (assq 'enum spec) (not (vectorp enum)))
             (problem name "Invalid enum constraint"))
           (unless (and type
                        (cl-every
                         (lambda (x)
                           (member
                            x
                            '("string"
                              "integer"
                              "number"
                              "boolean"
                              "null")))
                         types))
             (problem name "Unsupported field type"))
           (unless (eq value missing)
             (unless (cl-some
                      (lambda (kind)
                        (pcase kind
                          ("null" (eq value :null))
                          ("string" (stringp value))
                          ("integer" (integerp value))
                          ("number" (numberp value))
                          ("boolean" (memq value '(t :json-false)))))
                      types)
               (problem name "Invalid type"))
             (when (and enum
                        (not
                         (cl-some
                          (lambda (choice)
                            (equal
                             value
                             (if (null choice)
                                 :null choice)))
                          (append enum nil))))
               (problem name "Not an allowed value"))
             (when (numberp value)
               (when (and (numberp (alist-get 'minimum spec))
                          (< value (alist-get 'minimum spec)))
                 (problem name "Below minimum"))
               (when (and (numberp (alist-get 'maximum spec))
                          (> value (alist-get 'maximum spec)))
                 (problem name "Above maximum")))
             (when (stringp value)
               (when (and (integerp (alist-get 'minLength spec))
                          (< (length value)
                             (alist-get 'minLength spec)))
                 (problem name "Too short"))
               (when (and (integerp (alist-get 'maxLength spec))
                          (> (length value)
                             (alist-get 'maxLength spec)))
                 (problem name "Too long"))))))))
    (nreverse errors)))

(defun omnigent-conversation-elicitation-submit (id action callback)
  "Submit ID with ACTION and call CALLBACK with STATUS and BODY.
ACTION is `accept', `decline', or `cancel'.  Accept validates the draft;
validation errors signal `user-error'.  External URL requests cannot be
submitted here.  The change hook reports state changes to the frontend."
  (when buffer-read-only
    (user-error "This session is read-only"))
  (let* ((request
          (or (gethash id omnigent-conversation--elicitations)
              (user-error "Unknown elicitation: %s" id)))
         (params (alist-get 'params request))
         (url (alist-get 'url params))
         (buffer (current-buffer))
         (payload `(("action" . ,(symbol-name action)))))
    (unless (memq action '(accept decline cancel))
      (error "Invalid action"))
    (when (and url (not (string-prefix-p "/approve/" url)))
      (user-error
       "External URL requests must be answered in the browser"))
    (when (gethash id omnigent-conversation--elicitation-submitting)
      (user-error "A response is being submitted"))
    (when (eq action 'accept)
      (let ((errors (omnigent-conversation-elicitation-validate id)))
        (when errors
          (user-error "Invalid elicitation draft: %S" errors)))
      (when (or (alist-get 'requestedSchema params)
                (alist-get 'ask_user_question params))
        (let ((content (omnigent-conversation-elicitation-draft id)))
          (maphash
           (lambda (key value)
             (when (eq value :null)
               (puthash key nil content)))
           content)
          (push (cons "content" content) payload))))
    (puthash id t omnigent-conversation--elicitation-submitting)
    (condition-case err
        (progn
          (omnigent-conversation--notify-submission-change)
          (omnigent-transport--request
           omnigent-conversation-session-id "POST"
           (omnigent-transport--session-path
            omnigent-conversation-session-id
            (concat
             "/elicitations/" (url-hexify-string id) "/resolve"))
           (apply-partially
            #'omnigent-conversation--elicitation-submitted
            buffer id callback)
           payload))
      ((error quit)
       (when (gethash
              id omnigent-conversation--elicitation-submitting)
         (remhash id omnigent-conversation--elicitation-submitting)
         (omnigent-conversation--notify-submission-change))
       (signal (car err) (cdr err))))))


(defun omnigent-conversation--notify-submission-change ()
  "Notify elicitation observers without letting hook errors interrupt submission.
Report hook errors as client warnings, not request failures."
  (save-current-buffer
    (condition-case err
        (run-hooks 'omnigent-conversation-elicitation-change-hook)
      (error
       (display-warning
        'omnigent
        (format "Elicitation change hook failed: %s"
                (error-message-string err)))))))

(defun omnigent-conversation--elicitation-submitted
    (buffer id callback status body)
  "Apply submission STATUS and BODY for ID in BUFFER, then call CALLBACK."
  (when (and (buffer-live-p buffer)
             (not
              (buffer-local-value
               'omnigent-conversation--invalid buffer)))
    (with-current-buffer buffer
      (remhash id omnigent-conversation--elicitation-submitting)
      (when (omnigent-transport-success-p status)
        (omnigent-conversation--elicitation-remove id))
      (omnigent-conversation--notify-submission-change)
      (when callback
        (funcall callback status body)))))

;;; Conversation presentation

(defvar-local omnigent-conversation--widgets nil)

(defface omnigent-conversation-user
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for user message labels."
  :group 'omnigent)
(defface omnigent-conversation-agent
  '((t :inherit highlight :weight bold))
  "Face for agent message labels."
  :group 'omnigent)
(defface omnigent-conversation-prompt
  '((t :inherit comint-highlight-prompt))
  "Face for conversation prompts and message labels."
  :group 'omnigent)
(defface omnigent-conversation-attachment
  '((t :inherit link :underline nil :weight bold))
  "Face for the attachment block in the composer."
  :group 'omnigent)
(defface omnigent-conversation-fold-marker
  '((t :inherit font-lock-builtin-face :underline nil))
  "Face for fold buttons without underlining."
  :group 'omnigent)

(define-button-type 'omnigent-conversation-fold
  'face
  'omnigent-conversation-fold-marker
  'mouse-face
  'omnigent-conversation-fold-marker)

(defface omnigent-conversation-reasoning '((t :inherit shadow))
  "Face for reasoning blocks."
  :group 'omnigent)
(defface omnigent-conversation-error '((t :inherit error))
  "Face for errors and interruption markers."
  :group 'omnigent)
(defface omnigent-conversation-elicitation
  '((t :inherit font-lock-warning-face :weight bold))
  "Face for temporary request headings."
  :group 'omnigent)

;; ponytail: display limits only; fetch omitted content on demand in a later version.
(defconst omnigent-conversation--tool-line-limit 32768)
(defconst omnigent-conversation--tool-lines-limit 1000)
(defvar-local omnigent-conversation--request-start nil)
(defvar-local omnigent-conversation--composer-label nil)
(defvar-local omnigent-conversation--pending-start nil
  "Marker separating request forms from submitted input blocks.")
(defvar-local omnigent-conversation--folds nil)
(defvar-local omnigent-conversation--field-errors nil)
(defvar-local omnigent-conversation--rendering nil)

(defun omnigent-conversation--bounded-output (text)
  "Bound long lines and line counts in tool output TEXT deterministically."
  (let ((lines
         (mapcar
          (lambda (line)
            (if (> (length line)
                   omnigent-conversation--tool-line-limit)
                (concat
                 (substring line 0 200)
                 (format " ... [%d characters omitted] ... "
                         (- (length line) 400))
                 (substring line -200))
              line))
          (split-string text "\n"))))
    (when (> (length lines) omnigent-conversation--tool-lines-limit)
      (setq lines
            (append
             (cl-subseq lines 0 400)
             (list
              (format "[%d lines omitted]" (- (length lines) 800)))
             (last lines 400))))
    (mapconcat #'identity lines "\n")))

(defun omnigent-conversation--string (value)
  "Return readable plain text for server VALUE."
  (if (stringp value)
      value
    (if value
        (format "%s" value)
      "")))

(defun omnigent-conversation--location (position)
  "Record POSITION by transcript item ID or by a marker outside transcript."
  (if (>= position omnigent-conversation--request-start)
      (copy-marker position t)
    (let* ((id
            (get-text-property
             position 'omnigent-conversation-item-id))
           (start
            (or (previous-single-property-change
                 (min (point-max)
                      (1+ position))
                 'omnigent-conversation-item-id)
                (point-min))))
      (list id (- position start)))))

(defun omnigent-conversation--restore-location (location)
  "Return the position represented by LOCATION after a render."
  (if (markerp location)
      (prog1 (marker-position location)
        (set-marker location nil))
    (let ((position (point-min))
          (id (car location)))
      (while (and (< position omnigent-conversation--request-start)
                  (not
                   (equal
                    id
                    (get-text-property
                     position 'omnigent-conversation-item-id))))
        (setq position
              (or (next-single-property-change
                   position 'omnigent-conversation-item-id)
                  omnigent-conversation--request-start)))
      (if (>= position omnigent-conversation--request-start)
          omnigent-conversation--request-start
        (min (+ position (or (cadr location) 0))
             (1- (or (next-single-property-change
                      position 'omnigent-conversation-item-id)
                     omnigent-conversation--request-start)))))))

(defun omnigent-conversation--fold-button (button)
  "Toggle the fold identified by BUTTON without changing any other fold."
  (let ((id (button-get button 'omnigent-conversation-fold-id)))
    (puthash
     id
     (not (gethash id omnigent-conversation--folds))
     omnigent-conversation--folds)
    (omnigent-conversation--transcript)))

(defun omnigent-conversation-fold-at-point (open)
  "Set the fold for the current transcript block to OPEN.
Signal an error if point is not in a foldable block."
  (let* ((item-id
          (get-text-property (point) 'omnigent-conversation-item-id))
         (start
          (and item-id
               (or (previous-single-property-change
                    (min (point-max)
                         (1+ (point)))
                    'omnigent-conversation-item-id)
                   (point-min))))
         (end
          (and start
               (or (next-single-property-change
                    start 'omnigent-conversation-item-id)
                   (point-max))))
         button)
    (when start
      (let ((position start))
        (while (and (< position end) (not button))
          (when (and (button-at position)
                     (equal
                      item-id
                      (button-get
                       (button-at position)
                       'omnigent-conversation-fold-id)))
            (setq button (button-at position)))
          (setq position (1+ position)))))
    (unless button
      (user-error "Point is not in a foldable transcript block"))
    (unless (eq
             (and (gethash item-id omnigent-conversation--folds) t)
             open)
      (button-activate button))))

(defun omnigent-conversation--fold (id heading body &optional face)
  "Insert a fold for ID with HEADING, BODY, and optional FACE."
  (let ((open (gethash id omnigent-conversation--folds)))
    (insert-text-button (if open
                            "▼"
                          "▶")
                        'type
                        'omnigent-conversation-fold
                        'face
                        'omnigent-conversation-fold-marker
                        'font-lock-face
                        'omnigent-conversation-fold-marker
                        'mouse-face
                        'omnigent-conversation-fold-marker
                        'omnigent-conversation-fold-id
                        id
                        'action
                        #'omnigent-conversation--fold-button
                        'follow-link
                        t)
    (insert " " heading)
    (let ((start (point)))
      (insert "\n" body)
      (put-text-property
       start (point) 'invisible
       (unless open
         'omnigent-conversation-fold))
      (when face
        (put-text-property start (point) 'face face)))
    (insert "\n\n")))

(defun omnigent-conversation--tool-render (id item outputs command)
  "Render tool ITEM and OUTPUTS for ID with optional COMMAND heading."
  (let* ((output (gethash (alist-get 'call_id item) outputs))
         (args
          (omnigent-conversation--string (alist-get 'arguments item)))
         (status
          (cond
           ((or (eq (alist-get 'is_error output) t)
                (alist-get 'error output)
                (equal (alist-get 'status item) "failed"))
            "failed")
           (output
            "done")
           (t
            "running")))
         (name (or (alist-get 'name item) "Tool")))
    (omnigent-conversation--fold
     id
     (concat
      (pcase status
        ("running" "\uf252 ")
        ("failed" "\uf2d3 ")
        (_ "\uf14a "))
      (truncate-string-to-width
       (replace-regexp-in-string
        "\n" " " (or command (concat name " " args)))
       80 nil nil "…"))
     (concat
      "Arguments:\n" args "\n\nOutput:\n"
      (omnigent-conversation--bounded-output
       (omnigent-conversation--string
        (or (alist-get 'output output)
            (alist-get 'content output)
            "")))))))

(defun omnigent-conversation--tool-arguments (item)
  "Parse the JSON arguments of tool ITEM."
  (condition-case nil
      (json-parse-string (omnigent-conversation--string
                          (alist-get 'arguments item))
                         :object-type 'alist)
    (error
     nil)))

(defun omnigent-conversation--tool-shell-p (item)
  "Return non-nil when ITEM is a shell call."
  (member (alist-get 'name item) '("shell" "bash")))

(defun omnigent-conversation--tool-patch-p (item)
  "Return non-nil when ITEM is a file patch or read call."
  (member
   (alist-get 'name item) '("apply_patch" "edit" "write" "read")))

(defun omnigent-conversation--tool-turn-diff-p (item)
  "Return non-nil when ITEM is a turn diff."
  (equal (alist-get 'name item) "turn_diff"))

(defun omnigent-conversation--tool-any-p (_item)
  "Match any tool ITEM."
  t)

(defun omnigent-conversation--unwrap-shell-command (command)
  "Return COMMAND without its /bin/sh and -lc wrapper."
  (if (string-match
       "\\`/bin/[^/]+sh -lc \\(['\"]\\)\\(\\(?:.\\|\n\\)*\\)\\1\\'"
       command)
      (match-string 2 command)
    command))

(defun omnigent-conversation--tool-shell (id item outputs)
  "Render shell ITEM and OUTPUTS for ID."
  (let ((command
         (alist-get
          'command (omnigent-conversation--tool-arguments item))))
    (when (stringp command)
      (setq command
            (omnigent-conversation--unwrap-shell-command command)))
    (omnigent-conversation--tool-render id item outputs command)))

(defun omnigent-conversation--tool-patch (id item outputs)
  "Render patch or read ITEM and OUTPUTS for ID."
  (let* ((arguments (omnigent-conversation--tool-arguments item))
         (paths
          (or (delq
               nil
               (mapcar
                (lambda (change) (alist-get 'path change))
                (append (alist-get 'changes arguments) nil)))
              (and (stringp (alist-get 'path arguments))
                   (list (alist-get 'path arguments)))))
         (verb
          (if (equal (alist-get 'name item) "read")
              "read"
            "edit")))
    (omnigent-conversation--tool-render
     id item outputs
     (when paths
       (concat verb " " (mapconcat #'identity paths ", "))))))

(defun omnigent-conversation--tool-turn-diff (_id _item _outputs)
  "Hide the turn diff for _ID, _ITEM, and _OUTPUTS."
  nil)

(defun omnigent-conversation--tool-default (id item outputs)
  "Render tool ITEM and OUTPUTS for ID with the default heading."
  (omnigent-conversation--tool-render id item outputs nil))

(defconst omnigent-conversation--tool-handlers
  '((omnigent-conversation--tool-turn-diff-p
     . omnigent-conversation--tool-turn-diff)
    (omnigent-conversation--tool-shell-p
     . omnigent-conversation--tool-shell)
    (omnigent-conversation--tool-patch-p
     . omnigent-conversation--tool-patch)
    (omnigent-conversation--tool-any-p
     . omnigent-conversation--tool-default))
  "Predicates and renderers for tool calls, in dispatch order.")

(defun omnigent-conversation--tool-dispatch (id item outputs)
  "Render tool ITEM with ID and OUTPUTS using the first matching handler."
  (let ((handler
         (cl-find-if
          (lambda (entry)
            (funcall (car entry) item))
          omnigent-conversation--tool-handlers)))
    (funcall (cdr handler) id item outputs)))

(defun omnigent-conversation--item (id item outputs)
  "Render transcript ITEM with ID and tool OUTPUTS indexed by call ID."
  (let ((type (alist-get 'type item))
        (text (omnigent-conversation--text item)))
    (when-let* ((previous (alist-get 'omnigent-previous-id item))
                ((gethash previous omnigent-conversation--folds)))
      (puthash id t omnigent-conversation--folds)
      (remhash previous omnigent-conversation--folds))
    (pcase type
      ((or "function_call_output" "resource_event") nil)
      ((guard (eq (alist-get 'is_meta item) t)) nil)
      ((guard
        (and (equal type "message")
             (equal (alist-get 'role item) "user")
             (string-prefix-p
              "[System: sub-agent" (string-trim text))))
       nil)
      ("reasoning" (omnigent-conversation--fold id "Thinking" text
                                    'omnigent-conversation-reasoning))
      ("function_call"
       (omnigent-conversation--tool-dispatch id item outputs))
      ("error" (insert
        (propertize "Error:\n"
                    'face
                    'omnigent-conversation-error)
        (or (alist-get 'message item) text) "\n\n"))
      (_
       (let ((user (equal (alist-get 'role item) "user")))
         (insert
          (propertize (if user
                          "You:\n"
                        (concat
                         (or (alist-get 'agent_name item)
                             omnigent-conversation-agent-name
                             (alist-get
                              'agent_name
                              (cl-find
                               omnigent-conversation-session-id
                               (omnigent-sessions-visible)
                               :key
                               (lambda (row) (alist-get 'id row))
                               :test #'equal))
                             "Agent")
                         ":\n"))
                      'face
                      'omnigent-conversation-prompt
                      'font-lock-face
                      'omnigent-conversation-prompt)
          (if (omnigent-conversation--message-complete-p id item)
              (propertize text 'omnigent-conversation-markdown id)
            text)
          "\n\n"))))))

(defun omnigent-conversation--message-complete-p (id item)
  "Return non-nil when message ID and ITEM are ready for Markdown display."
  (or (equal (alist-get 'role item) "user")
      (alist-get 'omnigent-committed item)
      (not omnigent-conversation--response-id)
      (not (equal id omnigent-conversation--section-id))))

(defvar omnigent-conversation--markdown-link-map
  (let ((map (make-sparse-keymap)))
    (define-key map [follow-link] 'mouse-face)
    (define-key map [mouse-2] #'omnigent-conversation-follow-link)
    (define-key map (kbd "RET") #'omnigent-conversation-follow-link)
    map)
  "Keymap for Markdown links in rendered conversation text.")

(defun omnigent-conversation--markdown-apply (begin end hide)
  "Apply Markdown properties between BEGIN and END; HIDE conceals markup."
  (let ((text (buffer-substring-no-properties begin end)))
    (with-temp-buffer
      (insert text)
      (let ((markdown-mode-hook nil))
        (markdown-mode))
      (setq-local markdown-hide-markup hide)
      (setq-local markdown-fontify-code-blocks-natively t)
      ;; Chat prose is not an implicit MultiMarkdown metadata header.
      (font-lock-remove-keywords
       nil
       (cl-remove-if-not
        (lambda (rule)
          (eq (car-safe rule) 'markdown-match-declarative-metadata))
        markdown-mode-font-lock-keywords))
      (let ((markdown-mode-mouse-map
             (if hide
                 omnigent-conversation--markdown-link-map
               markdown-mode-mouse-map)))
        (font-lock-ensure))
      (unless hide
        (remove-text-properties
         (point-min) (point-max) '(invisible nil)))
      (setq text (buffer-string)))
    (let ((offset 0))
      (while (< offset (length text))
        (let ((next (next-property-change offset text (length text))))
          (dolist (property
                   '(face
                     font-lock-face
                     invisible
                     display
                     composition
                     help-echo
                     mouse-face))
            (put-text-property
             (+ begin offset)
             (+ begin next)
             property
             (get-text-property offset property text)))
          (when (eq
                 (get-text-property offset 'keymap text)
                 omnigent-conversation--markdown-link-map)
            (put-text-property
             (+ begin offset)
             (+ begin next)
             'keymap
             omnigent-conversation--markdown-link-map))
          (setq offset next))))
    (let ((pos begin))
      (while (< pos end)
        (let ((next
               (min (next-single-property-change
                     pos 'omnigent-attachment-path
                     nil end)
                    (next-single-property-change
                     pos 'omnigent-attachment-block
                     nil end))))
          (when (get-text-property pos 'omnigent-attachment-block)
            (let ((face
                   (if (get-text-property
                        pos 'omnigent-attachment-path)
                       'link
                     'omnigent-conversation-attachment)))
              (put-text-property pos next 'face face)
              (put-text-property pos next 'font-lock-face face)))
          (setq pos next))))
    (put-text-property
     begin end 'omnigent-conversation-markdown-done t)))

(defun omnigent-conversation--markdown-fontify
    (start end &optional _loudly)
  "Apply Markdown to completed messages visible between START and END."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t))
    (with-silent-modifications
      (save-excursion
        (goto-char start)
        (while (< (point) end)
          (let* ((id
                  (get-text-property
                   (point) 'omnigent-conversation-markdown))
                 (next
                  (next-single-property-change
                   (point) 'omnigent-conversation-markdown
                   nil (point-max))))
            (when (and id
                       (not
                        (get-text-property
                         (point)
                         'omnigent-conversation-markdown-done)))
              (let ((begin
                     (or (previous-single-property-change
                          (1+
                           (point))
                          'omnigent-conversation-markdown)
                         (point-min))))
                (omnigent-conversation--markdown-apply begin next t)))
            (goto-char next)))
        (when (and (> end omnigent-conversation--prompt-start)
                   (not
                    (get-text-property
                     omnigent-conversation--prompt-start
                     'omnigent-conversation-markdown-done)))
          (omnigent-conversation--markdown-apply
           omnigent-conversation--prompt-start (point-max) nil))))))

(defun omnigent-conversation--markdown-composer-changed
    (start _end _old-length)
  "Invalidate composer Markdown after an edit at START."
  (when (and omnigent-conversation--prompt-start
             (>= start omnigent-conversation--prompt-start)
             (not omnigent-conversation--rendering))
    (let ((inhibit-read-only t))
      (with-silent-modifications
        (remove-text-properties
         omnigent-conversation--prompt-start
         (point-max)
         '(omnigent-conversation-markdown-done nil))))
    (font-lock-flush
     omnigent-conversation--prompt-start (point-max))))

(defvar-local omnigent-conversation--blocks nil
  "Rendered item signatures and boundary markers, indexed by item ID.")

(defun omnigent-conversation--block-remove (block)
  "Delete rendered BLOCK and release its boundary markers."
  (delete-region (nth 1 block) (nth 2 block))
  (set-marker (nth 1 block) nil)
  (set-marker (nth 2 block) nil))

(defun omnigent-conversation--block-signature (id item outputs)
  "Return the rendering inputs for ID, ITEM and tool OUTPUTS."
  (list
   item
   (gethash (alist-get 'call_id item) outputs)
   (gethash id omnigent-conversation--folds)
   omnigent-conversation-agent-name
   (omnigent-conversation--message-complete-p id item)))

(defvar-local omnigent-conversation--history-positioned nil
  "Non-nil after the first nonempty transcript receives its window position.")

(defun omnigent-conversation--transcript-render ()
  "Refresh only transcript text, preserving composer, forms, folds and reading."
  (when (and omnigent-conversation--request-start
             (not omnigent-conversation--rendering))
    (let* ((omnigent-conversation--rendering t)
           (location (omnigent-conversation--location (point)))
           (windows
            (mapcar
             (lambda (window)
               (list
                window
                (omnigent-conversation--location
                 (window-start window))
                (omnigent-conversation--location
                 (window-point window))))
             (get-buffer-window-list (current-buffer) nil t)))
           (inhibit-read-only t)
           (buffer-undo-list t)
           (outputs (make-hash-table :test 'equal)))
      (dolist (id omnigent-conversation--order)
        (let ((item (gethash id omnigent-conversation--items)))
          (when (equal (alist-get 'type item) "function_call_output")
            (puthash (alist-get 'call_id item) item outputs))))
      (maphash
       (lambda (id block)
         (unless (gethash id omnigent-conversation--items)
           (omnigent-conversation--block-remove block)
           (remhash id omnigent-conversation--blocks)))
       omnigent-conversation--blocks)
      (goto-char (point-min))
      (dolist (id omnigent-conversation--order)
        (let* ((item (gethash id omnigent-conversation--items))
               (block (gethash id omnigent-conversation--blocks))
               (signature
                (omnigent-conversation--block-signature
                 id item outputs)))
          (if (and block
                   (= (point) (nth 1 block))
                   (equal signature (car block)))
              (goto-char (nth 2 block))
            (when block
              (omnigent-conversation--block-remove block))
            (let ((start (point)))
              (omnigent-conversation--item id item outputs)
              (add-text-properties
               start (point)
               (list
                'omnigent-conversation-item-id
                id
                'read-only
                t
                'rear-nonsticky
                t
                'line-prefix
                "   "
                'wrap-prefix
                "   "))
              (when (and (< start (point)) (button-at start))
                (put-text-property
                 start (1+ start) 'line-prefix "  "))
              (puthash
               id
               (list
                (copy-tree
                 (omnigent-conversation--block-signature
                  id item outputs))
                (copy-marker start (< start (point)))
                (copy-marker (point)))
               omnigent-conversation--blocks)))))
      (move-overlay
       omnigent-conversation--busy-overlay
       omnigent-conversation--composer-label
       omnigent-conversation--composer-label)
      (goto-char (omnigent-conversation--restore-location location))
      (dolist (entry windows)
        (pcase-let ((`(,window ,start ,position) entry))
          (let ((new-start
                 (omnigent-conversation--restore-location start))
                (new-point
                 (omnigent-conversation--restore-location position)))
            (set-window-point window new-point)
            (set-window-start window new-start t))))
      (when (and omnigent-conversation--order
                 (not omnigent-conversation--history-positioned))
        (setq omnigent-conversation--history-positioned t)
        (dolist (window
                 (get-buffer-window-list (current-buffer) nil t))
          (with-selected-window window
            (recenter -3)))))))

(defun omnigent-conversation--transcript-flush (buffer)
  "Render the pending transcript update in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq omnigent-conversation--transcript-timer nil)
      (omnigent-conversation--transcript-render))))

(defun omnigent-conversation--transcript ()
  "Batch transcript updates while a response streams, then render them."
  (if (and omnigent-conversation--response-id
           (not omnigent-conversation--invalid))
      (unless (timerp omnigent-conversation--transcript-timer)
        (setq omnigent-conversation--transcript-timer
              (run-at-time
               0.05 nil #'omnigent-conversation--transcript-flush
               (current-buffer))))
    (when (timerp omnigent-conversation--transcript-timer)
      (cancel-timer omnigent-conversation--transcript-timer)
      (setq omnigent-conversation--transcript-timer nil))
    (omnigent-conversation--transcript-render)))

(defun omnigent-conversation--render-pending-inputs ()
  "Render submitted input between request forms and the editable composer."
  (when (and omnigent-conversation--pending-start
             (not omnigent-conversation--rendering))
    (let ((omnigent-conversation--rendering t)
          (inhibit-read-only t)
          (inhibit-modification-hooks t)
          (buffer-undo-list t)
          (position (copy-marker (point) t))
          (request-start
           (marker-position omnigent-conversation--request-start))
          (start
           (marker-position omnigent-conversation--pending-start)))
      (delete-region start omnigent-conversation--composer-label)
      (goto-char start)
      (dolist (input omnigent-conversation--pending-inputs)
        (let ((begin (point))
              (text (omnigent-conversation--text input)))
          (insert
           (propertize (format "[%s] > " (alist-get 'state input))
                       'face 'omnigent-conversation-user)
           (propertize text 'omnigent-conversation-markdown t) "\n")
          (when (eq (alist-get 'state input) 'unconfirmed)
            (insert
             (propertize
              "Warning: the server may have accepted this message. Do not resend automatically.\n"
              'face 'omnigent-conversation-error)))
          (insert "\n")
          (add-text-properties
           begin (point)
           '(read-only
             t
             rear-nonsticky
             t
             line-prefix
             "   "
             wrap-prefix
             "   "))))
      (set-marker omnigent-conversation--pending-start start)
      (set-marker omnigent-conversation--request-start request-start)
      (goto-char position)
      (move-overlay
       omnigent-conversation--busy-overlay
       omnigent-conversation--composer-label
       omnigent-conversation--composer-label)
      (set-marker position nil))))

(defun omnigent-conversation--composer-indent (&rest _ignored)
  "Align composer continuation lines using display properties only."
  (when (and omnigent-conversation--prompt-start
             (not omnigent-conversation--rendering))
    (let ((omnigent-conversation--rendering t)
          (inhibit-modification-hooks t)
          (inhibit-read-only t)
          (buffer-undo-list t))
      (with-silent-modifications
        (add-text-properties
         omnigent-conversation--prompt-start
         (point-max)
         '(line-prefix "   " wrap-prefix "   "))
        (save-excursion
          (goto-char omnigent-conversation--prompt-start)
          (put-text-property
           (point)
           (min (line-end-position) (point-max))
           'line-prefix
           nil))))))

(defun omnigent-conversation--evil-change (change beg end &rest args)
  "Run Evil CHANGE from BEG to END with ARGS inside the composer bounds."
  (if (and (derived-mode-p 'omnigent-conversation-mode)
           omnigent-conversation--prompt-start
           (<= omnigent-conversation--prompt-start beg))
      (save-restriction
        (narrow-to-region
         omnigent-conversation--prompt-start (point-max))
        (apply change beg end args))
    (apply change beg end args)))

(with-eval-after-load 'evil-commands
  (advice-add
   'evil-change
   :around #'omnigent-conversation--evil-change))

(defun omnigent-conversation--render-event (name data)
  "Refresh linked PRs when NAME reports terminal session status in DATA."
  (when (and (equal name "session.status")
             (member (alist-get 'status data) '("idle" "failed")))
    (omnigent-session--refresh-pull-requests
     omnigent-conversation-session-id)))

(defun omnigent-conversation--token-count (count)
  "Format token COUNT with at most one decimal, rounded up."
  (let ((scale
         (cond
          ((>= count 1000000)
           1000000)
          ((>= count 1000)
           1000))))
    (if (not scale)
        (number-to-string count)
      (let* ((tenths (ceiling (/ (* 10.0 count) scale)))
             (number
              (if (zerop (% tenths 10))
                  (number-to-string (/ tenths 10))
                (format "%.1f" (/ tenths 10.0)))))
        (concat
         number
         (if (= scale 1000000)
             "m"
           "k"))))))

(defun omnigent-conversation--header-line ()
  "Update the header from the current session settings and context usage."
  (let* ((data omnigent-conversation-header-data)
         (workspace (alist-get 'workspace data))
         (folder
          (and (stringp workspace)
               (not (string-empty-p workspace))
               (file-name-nondirectory
                (directory-file-name workspace)))))
    (setq header-line-format
          (propertize (format " %s%s | %s | %s | %s | %s"
                              (if (and folder
                                       (not (string-empty-p folder)))
                                  folder
                                (if (equal workspace "/")
                                    "/"
                                  "unknown"))
                              (pcase (alist-get
                                      'permission_level data)
                                (1 " [R]")
                                (2 " [E]")
                                ((or 3 4) " [M]")
                                (_ ""))
                              (or (alist-get 'llm_model data)
                                  "unknown")
                              (or (alist-get 'reasoning_effort data)
                                  "unknown")
                              (or (alist-get 'access_mode data)
                                  "unknown")
                              (let ((used
                                     (alist-get
                                      'last_total_tokens data))
                                    (window
                                     (alist-get
                                      'context_window data)))
                                (cond
                                 ((and (numberp used)
                                       (numberp window)
                                       (> window 0))
                                  (format
                                   "%s / %s (%.0f%%%%)"
                                   (omnigent-conversation--token-count
                                    used)
                                   (omnigent-conversation--token-count
                                    window)
                                   (* 100.0 (/ (float used) window))))
                                 ((numberp used)
                                  (format
                                   "%s / unknown"
                                   (omnigent-conversation--token-count
                                    used)))
                                 ((and (numberp window) (> window 0))
                                  (format
                                   "unknown / %s"
                                   (omnigent-conversation--token-count
                                    window)))
                                 (t
                                  "unknown"))))
                      'face 'diff-header 'line-spacing 3))
    (force-mode-line-update)))

(defvar-local omnigent-conversation--busy-overlay nil)
(defvar-local omnigent-conversation--sandbox-overlay nil
  "Overlay for the sandbox status block before the composer.")
(defvar-local omnigent-conversation--busy-timer nil)
(defvar-local omnigent-conversation--busy-frame 0)
(defvar-local omnigent-conversation--transcript-timer nil)

(defun omnigent-conversation--sandbox-animating-p ()
  "Return non-nil when the sandbox status needs an animated spinner."
  (and omnigent-conversation--sandbox-status
       (not omnigent-conversation--invalid)
       (not
        (member
         (alist-get
          'stage omnigent-conversation--sandbox-status)
         '("failed" "action_required")))))

(defun omnigent-conversation--sandbox-render (frame)
  "Render the sandbox status block with spinner FRAME."
  (when (overlayp omnigent-conversation--sandbox-overlay)
    (let* ((status omnigent-conversation--sandbox-status)
           (stage (alist-get 'stage status))
           (text
            (pcase stage
              ("failed" (format "Sandbox provisioning failed%s"
                       (if-let* ((err (alist-get 'error status)))
                         (format " (%s)" err)
                         "")))
              ("ready" nil)
              ("action_required" (or (alist-get 'details status)
                   "Sandbox provisioning needs your attention"))
              ("cloning" "Cloning repositories…")
              ("starting" "Connecting host…")
              ("connecting" "Starting agent…")
              ((pred stringp) "Provisioning sandbox…"))))
      (move-overlay
       omnigent-conversation--sandbox-overlay
       omnigent-conversation--request-start
       omnigent-conversation--request-start)
      (overlay-put
       omnigent-conversation--sandbox-overlay 'before-string
       (when text
         (propertize (format
                      "   %s%s\n\n"
                      (if (omnigent-conversation--sandbox-animating-p)
                          (concat frame " ")
                        "")
                      text)
                     'face
                     (if (equal stage "failed")
                         'omnigent-conversation-error
                       'shadow)))))))

(defun omnigent-conversation--busy-p ()
  "Return non-nil while the conversation has a response or is running."
  (and (not omnigent-conversation--invalid)
       (or omnigent-conversation--response-id
           (member
            omnigent-conversation--status '("running" "waiting")))))

(defun omnigent-conversation--busy-tick (buffer)
  "Advance busy indicators in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((responding (omnigent-conversation--busy-p))
             (frame
              (aref
               ["|" "/" "-" "\\"]
               (mod omnigent-conversation--busy-frame 4))))
        (when (or responding
                  (omnigent-conversation--sandbox-animating-p))
          (cl-incf omnigent-conversation--busy-frame))
        (when (overlayp omnigent-conversation--busy-overlay)
          (overlay-put
           omnigent-conversation--busy-overlay 'before-string
           (if responding
               frame
             " ")))
        (omnigent-conversation--sandbox-render frame)))))

(defun omnigent-conversation--busy-update ()
  "Update the transcript and prompt busy indicators."
  (cond
   ((and (not omnigent-conversation--invalid)
         (or (omnigent-conversation--busy-p)
             (omnigent-conversation--sandbox-animating-p)))
    (if omnigent-conversation--busy-timer
        (progn
          (unless (omnigent-conversation--busy-p)
            (overlay-put
             omnigent-conversation--busy-overlay 'before-string " "))
          (omnigent-conversation--sandbox-render
           (aref
            ["|" "/" "-" "\\"]
            (mod (1- omnigent-conversation--busy-frame) 4))))
      (omnigent-conversation--busy-tick (current-buffer))
      (setq omnigent-conversation--busy-timer
            (run-at-time 0.15 0.15 #'omnigent-conversation--busy-tick
                         (current-buffer)))))
   (t
    (when omnigent-conversation--busy-timer
      (cancel-timer omnigent-conversation--busy-timer)
      (setq omnigent-conversation--busy-timer nil))
    (omnigent-conversation--busy-tick (current-buffer)))))

(defun omnigent-conversation--busy-stop ()
  "Stop the prompt animation when the conversation closes."
  (when omnigent-conversation--busy-timer
    (cancel-timer omnigent-conversation--busy-timer)
    (setq omnigent-conversation--busy-timer nil))
  (when (timerp omnigent-conversation--transcript-timer)
    (cancel-timer omnigent-conversation--transcript-timer)
    (setq omnigent-conversation--transcript-timer nil)))

(defun omnigent-conversation-setup ()
  "Initialize transcript, request and composer boundaries for this session."
  (setq
   omnigent-conversation--blocks (make-hash-table :test 'equal)
   omnigent-conversation--folds (make-hash-table :test 'equal)
   omnigent-conversation--field-errors (make-hash-table :test 'equal))
  (add-to-invisibility-spec 'omnigent-conversation-fold)
  (add-to-invisibility-spec 'markdown-markup)
  (setq-local font-lock-defaults '(nil t))
  (font-lock-mode 1)
  (setq-local font-lock-fontify-region-function
              #'omnigent-conversation--markdown-fontify)
  (add-hook 'after-change-functions
            #'omnigent-conversation--markdown-composer-changed
            nil
            t)
  (let ((inhibit-read-only t))
    (goto-char (point-min))
    (setq
     omnigent-conversation--request-start (copy-marker (point) t)
     omnigent-conversation--pending-start (copy-marker (point) t)
     omnigent-conversation--composer-label (copy-marker (point) t))
    (insert
     (propertize "> "
                 'face
                 'omnigent-conversation-prompt
                 'font-lock-face
                 'omnigent-conversation-prompt
                 'read-only
                 t
                 'field
                 'prompt
                 'rear-nonsticky
                 t))
    (set-marker omnigent-conversation--request-start (point-min))
    (set-marker omnigent-conversation--pending-start (point-min))
    (set-marker omnigent-conversation--composer-label (point-min))
    (set-marker omnigent-conversation--prompt-start (point))
    (set-marker-insertion-type
     omnigent-conversation--prompt-start nil))
  (setq omnigent-conversation--busy-overlay
        (make-overlay
         omnigent-conversation--composer-label
         omnigent-conversation--composer-label))
  (setq omnigent-conversation--sandbox-overlay
        (make-overlay
         omnigent-conversation--request-start
         omnigent-conversation--request-start))
  (omnigent-conversation--busy-update)
  (add-hook 'kill-buffer-hook #'omnigent-conversation--busy-stop
            nil
            t)
  (add-hook 'omnigent-conversation-change-hook
            #'omnigent-conversation--busy-update
            t
            t)
  (omnigent-conversation--header-line)
  (add-hook 'omnigent-conversation-change-hook
            #'omnigent-conversation--header-line
            nil
            t)
  (add-hook 'omnigent-conversation-change-hook
            #'omnigent-conversation--transcript
            nil
            t)
  (add-hook 'omnigent-conversation-change-hook
            #'omnigent-conversation--render-pending-inputs
            nil
            t)
  (add-hook 'omnigent-conversation-elicitation-change-hook
            #'omnigent-conversation--requests
            nil
            t)
  (add-hook 'omnigent-conversation-event-hook
            #'omnigent-conversation--render-event
            nil
            t)
  (add-hook
   'after-change-functions #'omnigent-conversation--composer-indent
   nil t)
  (omnigent-conversation--transcript)
  (omnigent-conversation--requests)
  (omnigent-conversation--render-pending-inputs)
  (goto-char (point-max)))

;;; Inline request widgets

(defun omnigent-conversation--field-notify (widget &rest _ignored)
  "Store WIDGET's edited value in request state, not in transcript state."
  (let* ((id (widget-get widget :request-id))
         (key (widget-get widget :field-name))
         (type (widget-get widget :field-type))
         (value (widget-value widget))
         (draft (omnigent-conversation-elicitation-draft id)))
    (when (and
           (member type '("integer" "number"))
           (stringp value)
           (string-match-p
            (if (equal type "integer")
                "\\`[-+]?[0-9]+\\'"
              "\\`[-+]?[0-9]*\\.?[0-9]+\\(?:[eE][-+]?[0-9]+\\)?\\'")
            value))
      (setq value (string-to-number value)))
    (when (equal type "multi")
      (setq value (vconcat value)))
    (if (or (eq value :unanswered)
            (and (equal value "")
                 (not (widget-get widget :required))))
        (remhash key draft)
      (puthash key value draft))
    ;; Editing must not rebuild the form that owns the current widget.
    (let ((omnigent-conversation-elicitation-change-hook nil))
      (omnigent-conversation-elicitation-set-draft id draft))))

(defun omnigent-conversation--secret (widget &rest _ignored)
  "Read WIDGET's secret into request state without inserting it in this buffer."
  (let* ((id (widget-get widget :request-id))
         (key (widget-get widget :field-name))
         (draft (omnigent-conversation-elicitation-draft id))
         (value (read-passwd (format "%s: " key))))
    (puthash key value draft)
    (omnigent-conversation-elicitation-set-draft id draft)))

(defun omnigent-conversation--field
    (id key label type value choices required secret)
  "Insert ID's KEY field with LABEL, TYPE and VALUE.
CHOICES is a widget choice list; REQUIRED and SECRET control input handling."
  (insert label ": ")
  (let* ((widget
          (if secret
              (widget-create
               'push-button
               :request-id id
               :field-name key
               :notify #'omnigent-conversation--secret
               (if (eq value :unanswered)
                   "Set secret"
                 "Change secret (set)"))
            (apply #'widget-create
                   (if choices
                       (if (equal type "multi")
                           'checklist
                         'menu-choice)
                     'editable-field)
                   :request-id id
                   :field-name key
                   :field-type type
                   :required required
                   :notify #'omnigent-conversation--field-notify
                   :value
                   (cond
                    ((equal type "multi")
                     (append value nil))
                    (choices
                     value)
                    ((eq value :unanswered)
                     "")
                    (t
                     (format "%s" value)))
                   (if choices
                       choices
                     '(:size 32)))))
         (errors
          (mapconcat #'cdr
                     (cl-remove-if-not
                      (lambda (entry) (equal key (car entry)))
                      (gethash
                       id omnigent-conversation--field-errors))
                     "; ")))
    (push widget omnigent-conversation--widgets)
    (unless (string-empty-p errors)
      (insert
       (propertize (concat "  " errors)
                   'face
                   'omnigent-conversation-error)))
    (insert "\n")))

(defun omnigent-conversation--schema-fields (id params)
  "Insert widgets for ID's requested schema in PARAMS."
  (let* ((schema (alist-get 'requestedSchema params))
         (required (append (alist-get 'required schema) nil))
         (draft (omnigent-conversation-elicitation-draft id)))
    (dolist (property (alist-get 'properties schema))
      (let* ((key (symbol-name (car property)))
             (spec (cdr property))
             (type (alist-get 'type spec))
             (types
              (if (vectorp type)
                  (append type nil)
                (list type)))
             (kind (car (remove "null" types)))
             (enum (alist-get 'enum spec))
             (choices
              (cond
               (enum
                (mapcar
                 (lambda (option)
                   `(const
                     :tag ,(format "%s" (or option "null"))
                     ,(if (null option)
                          :null option)))
                 (append enum nil)))
               ((equal kind "boolean")
                '((const :tag "Yes" t)
                  (const :tag "No" :json-false))))))
        (when (and (member "null" types) (not enum))
          (setq choices
                (append
                 choices '((const :tag "null" :null))
                 (unless choices
                   `((editable-field :tag "Value" ""))))))
        (when choices
          (push '(const :tag "Unanswered" :unanswered) choices))
        (omnigent-conversation--field
         id
         key
         (or (alist-get 'title spec) key)
         kind
         (gethash key draft :unanswered)
         choices
         (member key required)
         (or (eq (alist-get 'secret spec) t)
             (equal (alist-get 'format spec) "password")))
        (when (alist-get 'description spec)
          (insert (alist-get 'description spec) "\n"))))))

(defun omnigent-conversation--question-fields (id)
  "Insert structured question widgets for elicitation ID."
  (let ((draft (omnigent-conversation-elicitation-draft id))
        (index 0))
    (dolist (question
             (omnigent-conversation-elicitation-questions id))
      (let* ((key (format "%s" (or (alist-get 'id question) index)))
             (multi (eq (alist-get 'multiSelect question) t))
             (options
              (mapcar
               (lambda (option)
                 `(const
                   :tag
                   ,(alist-get 'label option)
                   ,(alist-get 'label option)))
               (append (alist-get 'options question) nil))))
        (unless (eq (alist-get 'isOther question) :json-false)
          (setq options
                (append options '((editable-field :tag "Other" "")))))
        (unless multi
          (push '(const :tag "Unanswered" :unanswered) options))
        (omnigent-conversation--field
         id key (or (alist-get 'question question) key)
         (if multi
             "multi"
           "string")
         (gethash key draft
                  (if multi
                      []
                    :unanswered))
         options t (eq (alist-get 'isSecret question) t)))
      (cl-incf index))))

(defun omnigent-conversation--submit-widget (widget &rest _ignored)
  "Validate and submit the response selected by WIDGET."
  (let* ((id (widget-get widget :request-id))
         (action (widget-get widget :response-action))
         (errors
          (and (eq action 'accept)
               (omnigent-conversation-elicitation-validate id))))
    (puthash id errors omnigent-conversation--field-errors)
    (if errors
        (progn
          (omnigent-conversation--requests)
          (when-let* ((field
                       (cl-find-if
                        (lambda (candidate)
                          (and (equal
                                id
                                (widget-get candidate :request-id))
                               (assoc
                                (widget-get
                                 candidate
                                 :field-name)
                                errors)))
                        (reverse omnigent-conversation--widgets))))
            (goto-char (widget-get field :from))))
      (omnigent-conversation-elicitation-submit
       id
       action
       (apply-partially #'omnigent--action-result "Answer" id)))))

(defun omnigent-conversation--request (request)
  "Insert one temporary REQUEST and its response widgets."
  (let* ((id (alist-get 'elicitation_id request))
         (params (alist-get 'params request))
         (url (alist-get 'url params))
         (external (and url (not (string-prefix-p "/approve/" url))))
         (questions (omnigent-conversation-elicitation-questions id))
         (approval
          (and (not external)
               (not questions)
               (not (alist-get 'requestedSchema params))
               (or url (alist-get 'policy_name params))))
         (command (and approval (alist-get 'command params)))
         (cwd (and approval (alist-get 'cwd params)))
         (reason
          (or (and approval (alist-get 'reason params))
              (unless command
                (alist-get 'message params))))
         (pending (omnigent-conversation-elicitation-submitting-p id))
         (start (point)))
    (insert
     (if approval
         "# Approval required\n\n"
       "# Question\n\n"))
    (when (and (stringp reason) (not (string-empty-p reason)))
      (insert
       "> " (replace-regexp-in-string "\n" "\n> " reason) "\n\n"))
    (when (and (stringp command) (not (string-empty-p command)))
      (let ((fence
             (make-string
              (1+ (apply #'max
                         2
                         (mapcar
                          #'length (split-string command "[^`]+" t))))
              ?`)))
        (insert fence "\n" command "\n" fence "\n\n")))
    (when (and (stringp cwd) (not (string-empty-p cwd)))
      (insert "> cwd: `" cwd "`\n\n"))
    (omnigent-conversation--markdown-apply start (point) t)
    (if external
        (push (widget-create 'url-link :value url url)
              omnigent-conversation--widgets)
      (let ((fields-start (point)))
        (if questions
            (omnigent-conversation--question-fields id)
          (omnigent-conversation--schema-fields id params))
        (dolist (error
                 (gethash id omnigent-conversation--field-errors))
          (unless (car error)
            (insert
             (propertize (concat (cdr error) "\n")
                         'face
                         'omnigent-conversation-error))))
        (when (> (point) fields-start)
          (insert "\n")))
      (dolist (action '(accept decline))
        (let ((widget
               (widget-create
                'push-button
                :request-id id
                :response-action action
                :notify #'omnigent-conversation--submit-widget
                (if (eq action 'accept)
                    (if approval
                        "Approve"
                      "Submit")
                  "Decline"))))
          (push widget omnigent-conversation--widgets)
          (when pending
            (widget-apply widget :deactivate)))
        (insert " "))
      (when pending
        (insert "Submitting...")))
    (insert "\n\n")
    (add-text-properties
     start (point)
     (list
      'omnigent-conversation-request-id
      id
      'line-prefix
      "   "
      'wrap-prefix
      "   "
      'rear-nonsticky
      t))))

(defun omnigent-conversation--widget-before-change (start end)
  "Apply widget edit protection to request fields between START and END only."
  (when (< start omnigent-conversation--prompt-start)
    (condition-case err
        (widget-before-change start end)
      (text-read-only
       (remove-hook 'post-command-hook #'widget-add-change t)
       (add-hook
        'post-command-hook #'omnigent-conversation--restore-edit-hooks
        nil t)
       (signal (car err) (cdr err))))))

(defun omnigent-conversation--restore-edit-hooks ()
  "Restore request-only widget hooks after a rejected edit or form setup."
  (remove-hook
   'post-command-hook #'omnigent-conversation--restore-edit-hooks
   t)
  (remove-hook 'before-change-functions #'widget-before-change t)
  (remove-hook 'after-change-functions #'widget-after-change t)
  (add-hook 'before-change-functions
            #'omnigent-conversation--widget-before-change
            nil
            t)
  (add-hook 'after-change-functions
            #'omnigent-conversation--widget-after-change
            nil
            t))

(defun omnigent-conversation--widget-after-change
    (start end old-length)
  "Notify request widgets of changes from START to END with OLD-LENGTH."
  (when (< start omnigent-conversation--pending-start)
    (widget-after-change start end old-length)))

(defun omnigent-conversation--requests ()
  "Refresh only temporary request blocks, keeping composer and transcript intact."
  (when (and omnigent-conversation--request-start
             (not omnigent-conversation--rendering))
    (let* ((omnigent-conversation--rendering t)
           (inhibit-read-only t)
           (buffer-undo-list t)
           (position (copy-marker (point) t))
           (field
            (cl-find-if
             (lambda (widget)
               (and (widget-get widget :field-name)
                    (<= (widget-get widget :from) (point))
                    (>= (widget-get widget :to) (point))))
             omnigent-conversation--widgets))
           (field-location
            (and field
                 (list
                  (widget-get field :request-id)
                  (widget-get field :field-name)
                  (- (point) (widget-get field :from)))))
           (start
            (marker-position omnigent-conversation--request-start)))
      (dolist (widget omnigent-conversation--widgets)
        (widget-delete widget))
      (setq omnigent-conversation--widgets nil)
      (delete-region start omnigent-conversation--pending-start)
      (goto-char start)
      (dolist (request (omnigent-conversation-elicitations))
        (omnigent-conversation--request request))
      (set-marker omnigent-conversation--request-start start)
      (widget-setup)
      (when buffer-read-only
        (dolist (widget omnigent-conversation--widgets)
          (widget-apply widget :deactivate)))
      (omnigent-conversation--restore-edit-hooks)
      (goto-char position)
      (when field-location
        (when-let* ((replacement
                     (cl-find-if
                      (lambda (widget)
                        (and (equal
                              (car field-location)
                              (widget-get widget :request-id))
                             (equal
                              (cadr field-location)
                              (widget-get widget :field-name))))
                      omnigent-conversation--widgets)))
          (goto-char
           (min (widget-get replacement :to)
                (+ (widget-get replacement :from)
                   (nth 2 field-location))))))
      (set-marker position nil))))

(add-hook
 'omnigent-conversation-mode-hook #'omnigent-conversation-setup)

(provide 'omnigent-conversation)
;;; omnigent-conversation.el ends here
