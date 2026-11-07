;;; omnigent-conversation.el --- Session conversation buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Maintain session transcript state and send messages to its agent.
;; Transcript presentation belongs to the frontend.

;;; Code:

(require 'cl-lib)
(require 'omnigent-sessions)

(defvar omnigent-conversation--session-id nil
  "Major mode initialization clears buffer-local variables.
Bind this temporarily so the mode can set `omnigent-conversation-session-id'.")
(defvar-local omnigent-conversation-session-id nil
  "Session ID associated with the current conversation buffer.")
(defvar-local omnigent-conversation--stream nil)
(defvar-local omnigent-conversation--items nil)
(defvar-local omnigent-conversation--order nil)
(defvar-local omnigent-conversation--order-tail nil)
(defvar-local omnigent-conversation--pending-events nil)
(defvar-local omnigent-conversation--loading nil)
(defvar-local omnigent-conversation--prompt-start nil)
(defvar-local omnigent-conversation--sending nil)


(defun omnigent-conversation--text (item)
  "Return the text in ITEM, combining content parts when necessary."
  (let ((content (alist-get 'content item)))
    (cond ((stringp content) content)
          ((vectorp content)
           (mapconcat (lambda (part) (or (alist-get 'text part) ""))
                      (append content nil) ""))
          (t (or (alist-get 'text item) "")))))

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
          (remhash (pop omnigent-conversation--order) omnigent-conversation--items)
          (unless omnigent-conversation--order
            (setq omnigent-conversation--order-tail nil)))
        (let ((cell (list id)))
          (if omnigent-conversation--order-tail
              (setcdr omnigent-conversation--order-tail cell)
            (setq omnigent-conversation--order cell))
          (setq omnigent-conversation--order-tail cell)))
      (puthash id item omnigent-conversation--items))))

(defun omnigent-conversation--event (name data)
  "Apply stream event NAME with DATA, or queue it while loading."
  (if omnigent-conversation--loading
      (push (cons name data) omnigent-conversation--pending-events)
    (cond
     ((equal name "response.elicitation_request")
      (omnigent-conversation--elicitation-put data)
      (run-hooks 'omnigent-conversation-elicitation-change-hook))
     ((equal name "response.elicitation_resolved")
      (when-let* ((id (alist-get 'elicitation_id data)))
        (omnigent-conversation--elicitation-remove id))
      (run-hooks 'omnigent-conversation-elicitation-change-hook))
     ((member name '("response.output_item.added" "response.output_item.done"))
      (omnigent-conversation--put-item (alist-get 'item data)))
     ((member name '("response.output_text.delta" "response.reasoning_text.delta"
                     "response.reasoning_summary_text.delta"))
      (let* ((id (alist-get 'item_id data))
             (item (and id (gethash id omnigent-conversation--items))))
        (when item
          (setf (alist-get 'content item)
                (concat (omnigent-conversation--text item) (or (alist-get 'delta data) ""))))))
     ((member name '("response.error" "response.failed"))
      (omnigent-conversation--put-item
       `((id . ,(format "error-%s" (float-time))) (type . "error")
         (text . ,(format "%s" (or (alist-get 'error data) data)))))))))

(defun omnigent-conversation--snapshot (status body)
  "Apply snapshot BODY when STATUS indicates success.
Replay queued stream events and notify the elicitation change hook."
  (if (not (omnigent-sessions--success-p status))
      (progn (setq omnigent-conversation--loading nil)
             (message "Omnigent snapshot failed: %s" status)
             (dolist (event (nreverse omnigent-conversation--pending-events))
               (omnigent-conversation--event (car event) (cdr event))))
    (clrhash omnigent-conversation--items)
    (clrhash omnigent-conversation--elicitations)
    (dolist (request (append (alist-get 'pending_elicitations body) nil))
      (omnigent-conversation--elicitation-put request))
    (maphash (lambda (id _draft)
               (unless (gethash id omnigent-conversation--elicitations)
                 (remhash id omnigent-conversation--elicitation-drafts)))
             omnigent-conversation--elicitation-drafts)
    (setq omnigent-conversation--order nil omnigent-conversation--order-tail nil
          omnigent-conversation--loading nil)
    (dolist (item (append (alist-get 'items body) nil))
      (omnigent-conversation--put-item item))
    (dolist (event (nreverse omnigent-conversation--pending-events))
      (omnigent-conversation--event (car event) (cdr event))))
  (setq omnigent-conversation--pending-events nil)
  (run-hooks 'omnigent-conversation-elicitation-change-hook))

(defun omnigent-conversation--close ()
  "Stop the current buffer's session stream."
  (when omnigent-conversation--stream
    (omnigent-transport-stop-session-stream omnigent-conversation--stream)))

(defvar omnigent-conversation-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'omnigent-conversation-send)
    (define-key map (kbd "C-c C-k") #'omnigent-conversation-interrupt)
    map)
  "Keymap for `omnigent-conversation-mode'.")

(define-derived-mode omnigent-conversation-mode text-mode "Omnigent"
  "Major mode for a conversation transcript and composer.
Use `omnigent-conversation-open' to create a conversation buffer."
  (unless omnigent-conversation--session-id
    (error "A session ID is required"))
  (setq omnigent-conversation-session-id omnigent-conversation--session-id
        omnigent-conversation--items (make-hash-table :test 'equal)
        omnigent-conversation--elicitations (make-hash-table :test 'equal)
        omnigent-conversation--elicitation-drafts (make-hash-table :test 'equal)
        omnigent-conversation--elicitation-submitting (make-hash-table :test 'equal)
        omnigent-conversation--loading t
        omnigent-conversation--prompt-start (copy-marker (point-min)))
  (add-hook 'kill-buffer-hook #'omnigent-conversation--close nil t)
  (let ((buffer (current-buffer)))
    (setq omnigent-conversation--stream
          (omnigent-transport-start-session-stream
           omnigent-conversation-session-id
           (lambda (name data) (when (buffer-live-p buffer)
                                 (with-current-buffer buffer (omnigent-conversation--event name data))))
           (lambda (status body) (when (buffer-live-p buffer)
                                   (with-current-buffer buffer (omnigent-conversation--snapshot status body))))
           (lambda (err) (message "Omnigent stream: %s" err))
           (lambda () (when (buffer-live-p buffer)
                        (with-current-buffer buffer
                          (setq omnigent-conversation--loading t
                                omnigent-conversation--pending-events nil))))))))

;;;###autoload
(defun omnigent-conversation-open (id &optional title)
  "Open the conversation for session ID, with optional TITLE."
  (interactive "sSession ID: ")
  (let ((buffer (omnigent-sessions-buffer id)))
    (unless buffer
      (setq buffer (generate-new-buffer (format "*omnigent: %s [%s]*"
                                                (or title "Untitled") (substring id 0 (min 9 (length id))))))
      (condition-case err
          (progn
            (with-current-buffer buffer
              (let ((omnigent-conversation--session-id id))
                (omnigent-conversation-mode)))
            (omnigent-sessions-register-buffer id buffer))
        (error (kill-buffer buffer) (signal (car err) (cdr err)))))
    (pop-to-buffer buffer)))

(defun omnigent-conversation-send ()
  "Send the composer text to the current session."
  (interactive)
  (when omnigent-conversation--sending (user-error "A message is being sent"))
  (let ((text (buffer-substring-no-properties omnigent-conversation--prompt-start (point-max)))
        (buffer (current-buffer)))
    (when (string-blank-p text) (user-error "The message is empty"))
    (setq omnigent-conversation--sending t)
    (condition-case err
        (omnigent-transport-post-session-event
         omnigent-conversation-session-id
         `(("type" . "message") ("data" . (("role" . "user")
                    ("content" . [(("type" . "input_text") ("text" . ,text))]))))
         (lambda (status _body)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (setq omnigent-conversation--sending nil)
               (if (omnigent-sessions--success-p status)
                   (let ((draft (buffer-substring-no-properties omnigent-conversation--prompt-start (point-max))))
                     (when (string-prefix-p text draft)
                       (delete-region omnigent-conversation--prompt-start
                                      (+ omnigent-conversation--prompt-start (length text)))))
                 (message "Omnigent send failed: %s" status))))))
      (error (setq omnigent-conversation--sending nil) (signal (car err) (cdr err))))))

(defun omnigent-conversation-interrupt ()
  "Interrupt the current session."
  (interactive)
  (omnigent-transport-post-session-event
   omnigent-conversation-session-id '(("type" . "interrupt"))
   (lambda (status _body)
     (unless (omnigent-sessions--success-p status)
       (message "Omnigent interrupt failed: %s" status)))))


;;; Elicitations

(defvar-local omnigent-conversation--elicitations nil)
(defvar-local omnigent-conversation--elicitation-drafts nil)
(defvar-local omnigent-conversation--elicitation-submitting nil)
(defvar-local omnigent-conversation-elicitation-change-hook nil
  "Functions called without arguments when elicitation state changes.")

(defun omnigent-conversation-elicitations ()
  "Return pending request events for the current conversation.
Each event contains `elicitation_id' and `params'.  Frontends must not
modify the returned objects."
  (let (requests)
    (maphash (lambda (_id request) (push request requests))
             omnigent-conversation--elicitations)
    requests))

(defun omnigent-conversation-elicitation-draft (id)
  "Return ID's draft as a hash table with string keys.
JSON false is `:json-false'; JSON null is `:null'.  Missing keys are
unanswered.  The frontend must use the setter to change this table."
  (copy-hash-table (or (gethash id omnigent-conversation--elicitation-drafts)
                       (make-hash-table :test 'equal))))

(defun omnigent-conversation-elicitation-set-draft (id content)
  "Set ID's draft to CONTENT, a hash table with string property names."
  (unless (gethash id omnigent-conversation--elicitations)
    (error "Unknown elicitation: %s" id))
  (unless (hash-table-p content) (error "Draft must be a hash table"))
  (puthash id (copy-hash-table content) omnigent-conversation--elicitation-drafts)
  (run-hooks 'omnigent-conversation-elicitation-change-hook))

(defun omnigent-conversation-elicitation-submitting-p (id)
  "Return non-nil when a response for ID is in flight."
  (gethash id omnigent-conversation--elicitation-submitting))

(defun omnigent-conversation--elicitation-put (request)
  "Store elicitation REQUEST and initialize its draft from schema defaults."
  (when-let* ((id (alist-get 'elicitation_id request)))
    (puthash id request omnigent-conversation--elicitations)
    (unless (gethash id omnigent-conversation--elicitation-drafts)
      (let ((draft (make-hash-table :test 'equal)))
        (dolist (property (alist-get 'properties
                                     (alist-get 'requestedSchema (alist-get 'params request))))
          (when (assq 'default (cdr property))
            (puthash (symbol-name (car property))
                     (let ((value (alist-get 'default (cdr property))))
                       (if (null value) :null value)) draft)))
        (puthash id draft omnigent-conversation--elicitation-drafts)))))

(defun omnigent-conversation--elicitation-remove (id)
  "Remove elicitation ID and its draft."
  (remhash id omnigent-conversation--elicitations)
  (remhash id omnigent-conversation--elicitation-drafts))

(defun omnigent-conversation-elicitation-validate (id)
  "Return validation errors for ID's draft as (FIELD . MESSAGE) pairs.
A nil FIELD identifies an unsupported or invalid schema.  Supported field
types are string, integer, number, boolean and null.  Supported constraints
are required, enum, minimum, maximum, minLength and maxLength."
  (let* ((request (or (gethash id omnigent-conversation--elicitations)
                      (error "Unknown elicitation: %s" id)))
         (schema (alist-get 'requestedSchema (alist-get 'params request)))
         (properties (alist-get 'properties schema))
         (required (append (alist-get 'required schema) nil))
         (draft (omnigent-conversation-elicitation-draft id))
         (missing (make-symbol "missing")) errors)
    (cl-labels ((problem (field text) (push (cons field text) errors))
                (unsupported (object allowed field)
                  (dolist (entry object)
                    (unless (memq (car entry) allowed)
                      (problem field (format "Unsupported schema keyword: %s" (car entry)))))))
      (unless (or (null schema) (listp schema))
        (problem nil "Invalid schema"))
      (when (listp schema)
        (unsupported schema '(type properties required title description) nil)
        (when (and (alist-get 'type schema) (not (equal (alist-get 'type schema) "object")))
          (problem nil "Schema must describe an object"))
        (dolist (name required)
          (when (eq (gethash name draft missing) missing)
            (problem name "Required")))
        (maphash (lambda (name _value)
                   (unless (cl-find name properties :key (lambda (p) (symbol-name (car p))) :test #'equal)
                     (problem name "Unknown field"))) draft)
        (dolist (property properties)
          (let* ((name (symbol-name (car property)))
                 (spec (cdr property))
                 (type (alist-get 'type spec))
                 (types (if (vectorp type) (append type nil) (list type)))
                 (value (gethash name draft missing))
                 (enum (alist-get 'enum spec)))
            (unsupported spec '(type title description default enum enumNames minimum maximum
                                     minLength maxLength) name)
            (dolist (key '(minimum maximum minLength maxLength))
              (when (and (assq key spec)
                         (not (if (memq key '(minLength maxLength))
                                  (and (integerp (alist-get key spec))
                                       (>= (alist-get key spec) 0))
                                (numberp (alist-get key spec)))))
                (problem name (format "Invalid %s constraint" key))))
            (when (and (assq 'enum spec) (not (vectorp enum)))
              (problem name "Invalid enum constraint"))
            (unless (and type (cl-every (lambda (x) (member x '("string" "integer" "number" "boolean" "null"))) types))
              (problem name "Unsupported field type"))
            (unless (eq value missing)
              (unless (cl-some (lambda (kind)
                                 (pcase kind
                                   ("null" (eq value :null))
                                   ("string" (stringp value))
                                   ("integer" (integerp value))
                                   ("number" (numberp value))
                                   ("boolean" (memq value '(t :json-false))))) types)
                (problem name "Invalid type"))
              (when (and enum
                         (not (cl-some (lambda (choice)
                                         (equal value (if (null choice) :null choice)))
                                       (append enum nil))))
                (problem name "Not an allowed value"))
              (when (numberp value)
                (when (and (numberp (alist-get 'minimum spec)) (< value (alist-get 'minimum spec)))
                  (problem name "Below minimum"))
                (when (and (numberp (alist-get 'maximum spec)) (> value (alist-get 'maximum spec)))
                  (problem name "Above maximum")))
              (when (stringp value)
                (when (and (integerp (alist-get 'minLength spec)) (< (length value) (alist-get 'minLength spec)))
                  (problem name "Too short"))
                (when (and (integerp (alist-get 'maxLength spec)) (> (length value) (alist-get 'maxLength spec)))
                  (problem name "Too long"))))))))
    (nreverse errors)))

(defun omnigent-conversation-elicitation-submit (id action callback)
  "Submit ID with ACTION and call CALLBACK with STATUS and BODY.
ACTION is `accept', `decline', or `cancel'.  Accept validates the draft;
validation errors signal `user-error'.  External URL requests cannot be
submitted here.  The change hook reports state changes to the frontend."
  (let* ((request (or (gethash id omnigent-conversation--elicitations)
                      (user-error "Unknown elicitation: %s" id)))
         (params (alist-get 'params request))
         (url (alist-get 'url params))
         (buffer (current-buffer))
         (payload `(("action" . ,(symbol-name action)))))
    (unless (memq action '(accept decline cancel)) (error "Invalid action"))
    (when (and url (not (string-prefix-p "/approve/" url)))
      (user-error "External URL requests must be answered in the browser"))
    (when (gethash id omnigent-conversation--elicitation-submitting)
      (user-error "A response is being submitted"))
    (when (eq action 'accept)
      (let ((errors (omnigent-conversation-elicitation-validate id)))
        (when errors (user-error "Invalid elicitation draft: %S" errors)))
      (when (alist-get 'requestedSchema params)
        (let ((content (omnigent-conversation-elicitation-draft id)))
          (maphash (lambda (key value) (when (eq value :null) (puthash key nil content))) content)
          (push (cons "content" content) payload))))
    (puthash id t omnigent-conversation--elicitation-submitting)
    (run-hooks 'omnigent-conversation-elicitation-change-hook)
    (condition-case err
        (omnigent-transport-request
         "POST" (omnigent-transport--session-path
                  omnigent-conversation-session-id
                  (concat "/elicitations/" (url-hexify-string id) "/resolve"))
         (lambda (status body)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (remhash id omnigent-conversation--elicitation-submitting)
               (when (omnigent-sessions--success-p status)
                 (omnigent-conversation--elicitation-remove id))
               (run-hooks 'omnigent-conversation-elicitation-change-hook)
               (when callback (funcall callback status body))))) payload)
      (error (remhash id omnigent-conversation--elicitation-submitting)
             (run-hooks 'omnigent-conversation-elicitation-change-hook)
             (signal (car err) (cdr err))))))



(provide 'omnigent-conversation)
;;; omnigent-conversation.el ends here
