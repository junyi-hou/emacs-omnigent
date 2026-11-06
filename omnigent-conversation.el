;;; omnigent-conversation.el --- Session conversation buffers -*- lexical-binding: t; -*-

;;; Commentary:
;; Maintain session transcript state and send messages to its agent.
;; Transcript presentation belongs to the frontend.

;;; Code:

(require 'cl-lib)
(require 'omnigent-sessions)

(defvar omnigent-conversation--opening-id nil)
(defvar-local omnigent-conversation-session-id nil)
(defvar-local omnigent-conversation--stream nil)
(defvar-local omnigent-conversation--items nil)
(defvar-local omnigent-conversation--order nil)
(defvar-local omnigent-conversation--pending-events nil)
(defvar-local omnigent-conversation--loading nil)
(defvar-local omnigent-conversation--prompt-start nil)
(defvar-local omnigent-conversation--sending nil)

(defun omnigent-conversation--text (item)
  (let ((content (alist-get 'content item)))
    (cond ((stringp content) content)
          ((vectorp content)
           (mapconcat (lambda (part) (or (alist-get 'text part) ""))
                      (append content nil) ""))
          (t (or (alist-get 'text item) "")))))

(defun omnigent-conversation--put-item (item)
  ;; Snapshot items wrap their message fields in `data'.  Stream items may
  ;; already have those fields at the top level.
  (let ((id (alist-get 'id item))
        (data (alist-get 'data item)))
    (when (listp data)
      (setq item (append item data)))
    (when id
      (unless (gethash id omnigent-conversation--items)
        (setq omnigent-conversation--order (append omnigent-conversation--order (list id))))
      (puthash id item omnigent-conversation--items))))

(defun omnigent-conversation--event (name data)
  (if omnigent-conversation--loading
      (push (cons name data) omnigent-conversation--pending-events)
    (cond
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
  (if (not (omnigent-sessions--success-p status))
      (progn (setq omnigent-conversation--loading nil)
             (message "Omnigent snapshot failed: %s" status)
             (dolist (event (nreverse omnigent-conversation--pending-events))
               (omnigent-conversation--event (car event) (cdr event))))
    (clrhash omnigent-conversation--items)
    (setq omnigent-conversation--order nil omnigent-conversation--loading nil)
    (dolist (item (append (alist-get 'items body) nil))
      (omnigent-conversation--put-item item))
    (dolist (event (nreverse omnigent-conversation--pending-events))
      (omnigent-conversation--event (car event) (cdr event))))
  (setq omnigent-conversation--pending-events nil))

(defun omnigent-conversation--close ()
  (when omnigent-conversation--stream
    (omnigent-transport-stop-session-stream omnigent-conversation--stream)))

(defvar omnigent-conversation-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'omnigent-conversation-send)
    (define-key map (kbd "C-c C-k") #'omnigent-conversation-interrupt)
    map))

(define-derived-mode omnigent-conversation-mode text-mode "Omnigent"
  "Conversation transcript and composer."
  (unless omnigent-conversation--opening-id
    (error "A session ID is required"))
  (setq omnigent-conversation-session-id omnigent-conversation--opening-id
        omnigent-conversation--items (make-hash-table :test 'equal)
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
              (let ((omnigent-conversation--opening-id id))
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
   omnigent-conversation-session-id '(("type" . "interrupt") ("data" . ()))
   (lambda (status _body)
     (unless (omnigent-sessions--success-p status)
       (message "Omnigent interrupt failed: %s" status)))))

(provide 'omnigent-conversation)
;;; omnigent-conversation.el ends here
