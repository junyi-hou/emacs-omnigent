;;; omnigent-conversation.el --- Session conversation buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Maintain session transcript state and send messages to its agent.
;; Transcript presentation belongs to the frontend.

;;; Code:

(require 'cl-lib)
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
(defvar-local omnigent-conversation--permission-read-only nil)
(defvar-local omnigent-conversation--elicitations nil)
(defvar-local omnigent-conversation--elicitation-drafts nil)
(defvar-local omnigent-conversation--elicitation-submitting nil)
(defvar-local omnigent-conversation--stream nil)
(defvar-local omnigent-conversation--items nil)
(defvar-local omnigent-conversation--order nil)
(defvar-local omnigent-conversation--order-tail nil)
(defvar-local omnigent-conversation--pending-events nil)
(defvar-local omnigent-conversation--loading nil)
(defvar-local omnigent-conversation--invalid nil)
(defvar-local omnigent-conversation--connected t)
(defvar-local omnigent-conversation--pending-event-count 0)
(defvar-local omnigent-conversation--pending-event-bytes 0)
(defvar-local omnigent-conversation--prompt-start nil)
(defvar-local omnigent-conversation--prompt-end nil)
(defvar-local omnigent-conversation--sending nil)
(defvar-local omnigent-conversation--pending-inputs nil
  "Submitted inputs in queue order, separate from committed transcript items.")
(defvar-local omnigent-conversation--response-id nil)
(defvar-local omnigent-conversation--section-id nil)
(defvar-local omnigent-conversation-change-hook nil
  "Hook run after transcript state changes in this buffer.")
(defvar-local omnigent-conversation-event-hook nil
  "Hook called with stream event name and data after processing.")
(defvar-local omnigent-conversation--elicitation-order nil)
(defvar-local omnigent-conversation--title-prompt-count 0)
(defvar-local omnigent-conversation--title-generation-pending nil)

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

(defun omnigent-conversation--title-generation-result
    (buffer session-id count status body)
  "Handle title generation for BUFFER and SESSION-ID after COUNT prompts."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq omnigent-conversation--title-generation-pending nil)
      (if (omnigent-transport-success-p status)
          (progn
            (setq omnigent-conversation--title-prompt-count
                  (max 0
                       (- omnigent-conversation--title-prompt-count
                          count)))
            (omnigent-sessions-refresh))
        (message "%s"
                 (omnigent-transport-error-message
                  "Generate session title" status body))))))

(defun omnigent-conversation--title-update-event (name data)
  "Count user prompts from event NAME and DATA, then update the title."
  (when (equal name "session.input.consumed")
    (let* ((payload (alist-get 'data data))
           (content (alist-get 'data payload))
           (text (string-trim (omnigent-conversation--text content))))
      (when
          (and
           (equal (alist-get 'type payload) "message")
           (equal (alist-get 'role content) "user")
           (not (eq (alist-get 'is_meta content) t))
           (not
            (string-match-p
             "\\`\\(?:\\[System: \\|\\[Request interrupted by user\\|<task-notification>\\|<teammate-message\\|<agent-message\\)"
             text)))
        (cl-incf omnigent-conversation--title-prompt-count)))
    (when (and (> omnigent-title-update-turn-interval 0)
               (>= omnigent-conversation--title-prompt-count
                   omnigent-title-update-turn-interval)
               (not omnigent-conversation--title-generation-pending))
      (let ((buffer (current-buffer))
            (session-id omnigent-conversation-session-id)
            (count omnigent-title-update-turn-interval))
        (setq omnigent-conversation--title-generation-pending t)
        (omnigent-transport-generate-session-title
         session-id
         (format
          "Focus the title on the most recent %d turns of this conversation."
          count)
         (lambda (status body)
           (omnigent-conversation--title-generation-result
            buffer session-id count status body)))))))

(defun omnigent-conversation--title-update-watch ()
  "Watch consumed prompts and update the session title when due."
  (add-hook 'omnigent-conversation-event-hook
            #'omnigent-conversation--title-update-event
            nil
            t))

(add-hook
 'omnigent-conversation-mode-hook
 #'omnigent-conversation--title-update-watch)


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
  (let* ((explicit-id (alist-get 'item_id data))
         (id (or explicit-id omnigent-conversation--section-id))
         (item (and id (gethash id omnigent-conversation--items))))
    (when (and (not explicit-id) omnigent-conversation--response-id)
      (unless (and item (equal (alist-get 'type item) kind))
        (setq
         id (make-symbol "live-section")
         item
         `((id . ,id)
           (type . ,kind)
           (content . ,(string))
           (response_id . ,omnigent-conversation--response-id)
           (omnigent-provisional . t)))
        (when (equal kind "message")
          (push '(role . "assistant") item))
        (omnigent-conversation--put-item item)
        (setq omnigent-conversation--section-id id)))
    (when (and item (not (alist-get 'omnigent-committed item)))
      (setf (alist-get 'content item)
            (concat
             (omnigent-conversation--text item)
             (or (alist-get 'delta data) ""))))))

(defun omnigent-conversation--stream-item (item &optional added)
  "Reconcile stream ITEM in place; ADDED starts an identified section."
  (let* ((item (append item (alist-get 'data item)))
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
          (and id
               (not (gethash id omnigent-conversation--items))
               (not (equal (alist-get 'role item) "user"))
               (or (cl-find-if
                    (lambda (old-id)
                      (let ((old
                             (gethash
                              old-id omnigent-conversation--items)))
                        (and (alist-get 'omnigent-provisional old)
                             (equal
                              (alist-get 'response_id old)
                              response-id)
                             (equal (alist-get 'type old) kind)
                             (equal
                              (omnigent-conversation--text old)
                              (omnigent-conversation--text item)))))
                    omnigent-conversation--order)
                   (and (alist-get 'omnigent-provisional active)
                        (equal
                         (alist-get 'response_id active) response-id)
                        (equal (alist-get 'type active) kind)
                        omnigent-conversation--section-id)))))
    (unless (and added
                 (alist-get
                  'omnigent-committed
                  (gethash id omnigent-conversation--items)))
      (unless added
        (setf (alist-get 'omnigent-committed item) t))
      (when provisional
        (setf (alist-get 'omnigent-previous-id item) provisional)
        (setcar (memq provisional omnigent-conversation--order) id)
        (remhash provisional omnigent-conversation--items)
        (puthash id item omnigent-conversation--items))
      (when (or (equal id omnigent-conversation--section-id)
                (eq provisional omnigent-conversation--section-id)
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
        (omnigent-conversation--stream-item (alist-get 'item data))))
    (("response.reasoning.started")
     .
     ,(lambda (_data) (setq omnigent-conversation--section-id nil)))
    (("response.created" "response.in_progress" "session.status")
     .
     ,(lambda (data)
        ;; Native turns report their response ID through session.status.
        (when-let* ((id
                     (or (alist-get 'id (alist-get 'response data))
                         (and (equal
                               (alist-get 'status data) "running")
                              (alist-get 'response_id data)))))
          (unless (equal id omnigent-conversation--response-id)
            (setq omnigent-conversation--section-id nil))
          (setq omnigent-conversation--response-id id))
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
          (when (or (not id)
                    (equal id omnigent-conversation--response-id))
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

(defun omnigent-conversation--read-only ()
  "Apply recovery and server permission restrictions without losing drafts."
  (let ((previous buffer-read-only))
    (setq buffer-read-only
          (or omnigent-conversation--invalid
              omnigent-conversation--loading
              (not omnigent-conversation--connected)
              omnigent-conversation--permission-read-only))
    (unless (eq previous buffer-read-only)
      (omnigent-conversation--notify-submission-change))))

(defun omnigent-conversation--connection-state (state)
  "Apply stream connection STATE to this conversation."
  (unless omnigent-conversation--invalid
    (setq omnigent-conversation--connected (eq state 'connected))
    (omnigent-conversation--read-only)))

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
    (message
     "%s. Copy any drafts, then close and reopen this session to try again"
     (omnigent-transport-error-message
      "Omnigent snapshot failed" status body))))

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
      (let ((events (nreverse omnigent-conversation--pending-events)))
        (setq
         omnigent-conversation--pending-events nil
         omnigent-conversation--pending-event-count 0
         omnigent-conversation--pending-event-bytes 0)
        (setq omnigent-conversation--permission-read-only
              (equal (alist-get 'permission_level body) 1))
        (setq
         omnigent-conversation-host-id (alist-get 'host_id body)
         omnigent-conversation-agent-name (alist-get 'agent_name body)
         omnigent-conversation-header-data
         `((workspace . ,(alist-get 'workspace body))
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
        (clrhash omnigent-conversation--items)
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
         omnigent-conversation--order nil
         omnigent-conversation--order-tail nil
         omnigent-conversation--response-id (alist-get 'active_response_id body)
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
             (text (omnigent-conversation--text entry)))
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
  "Store elicitation REQUEST and initialize its draft from schema defaults."
  (when-let* ((id (alist-get 'elicitation_id request)))
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
          (omnigent-transport-request
           "POST"
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

(provide 'omnigent-conversation)
;;; omnigent-conversation.el ends here
