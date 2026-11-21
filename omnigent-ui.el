;;; omnigent-ui.el --- Omnigent frontend views -*- lexical-binding: t; -*-

;;; Commentary:
;; Session and workspace side windows, transcript folds, and inline forms.

;;; Code:

(require 'cl-lib)
(require 'comint)
(require 'omnigent-conversation)
(require 'omnigent-workspace)
(require 'omnigent-options)
(require 'wid-edit)
(require 'diff-mode)
(require 'markdown-mode)

(defgroup omnigent-ui nil
  "Presentation for Omnigent sessions."
  :group 'applications)

(defvar omnigent-ui--selected-session nil)
(defvar-local omnigent-ui--widgets nil)

(defface omnigent-ui-session-running '((t :inherit warning))
  "Face for running sessions."
  :group 'omnigent-ui)
(defface omnigent-ui-session-waiting
  '((t :inherit font-lock-warning-face))
  "Face for waiting sessions."
  :group 'omnigent-ui)
(defface omnigent-ui-session-failed '((t :inherit error))
  "Face for failed sessions."
  :group 'omnigent-ui)
(defface omnigent-ui-session-idle '((t :inherit default))
  "Face for idle sessions."
  :group 'omnigent-ui)
(defface omnigent-ui-session-archived '((t :inherit shadow))
  "Face for archived sessions."
  :group 'omnigent-ui)
(defface omnigent-ui-session-attention '((t :inherit warning))
  "Face for the pending elicitation marker."
  :group 'omnigent-ui)
(defface omnigent-ui-project
  '((t :inherit font-lock-keyword-face :weight normal))
  "Face for project headings."
  :group 'omnigent-ui)

(defun omnigent-ui--session-face (session)
  "Return the face for SESSION."
  (cond
   ((eq (alist-get 'archived session) t)
    'omnigent-ui-session-archived)
   ((or (equal (alist-get 'status session) "running")
        (and (not (alist-get 'status session))
             (eq (alist-get 'busy session) t)))
    'omnigent-ui-session-running)
   ((equal (alist-get 'status session) "waiting")
    'omnigent-ui-session-waiting)
   ((or (equal (alist-get 'status session) "failed")
        (and (not (alist-get 'status session))
             (equal
              (alist-get 'current_task_status session) "failed")))
    'omnigent-ui-session-failed)
   (t
    'omnigent-ui-session-idle)))

(defun omnigent-ui--session-id-at-point ()
  "Return the session ID at point."
  (get-text-property
   (line-beginning-position) 'omnigent-ui-session-id))

(defun omnigent-ui--session-age (updated-at)
  "Return a short age label for UPDATED-AT."
  (when updated-at
    (condition-case nil
        (let* ((time
                (if (numberp updated-at)
                    (seconds-to-time updated-at)
                  (date-to-time updated-at)))
               (seconds
                (max 0
                     (floor
                      (float-time
                       (time-subtract (current-time) time))))))
          (cond
           ((< seconds 3600)
            (format "%dm" (max 1 (/ seconds 60))))
           ((< seconds 86400)
            (format "%dhr" (/ seconds 3600)))
           ((< seconds 604800)
            (format "%dd" (/ seconds 86400)))
           (t
            (if (>= seconds (* 4 604800))
                "4w+"
              (format "%dw" (/ seconds 604800))))))
      (error
       "n/a"))))

(defvar-local omnigent-ui--folded-projects nil)

(defvar-local omnigent-ui--folded-sessions nil
  "Session IDs whose child rows are folded.")

(defun omnigent-ui--session-pending-p (session)
  "Return non-nil if SESSION has a current pending elicitation."
  (let ((count (alist-get 'pending_elicitations_count session)))
    (and (numberp count)
         (> count 0)
         (or (not (alist-get 'parent_session_id session))
             (member
              (alist-get 'id session)
              omnigent-sessions--watched-ids)))))

(defun omnigent-ui--descendant-pending-p (session)
  "Return non-nil if a descendant of SESSION has a pending elicitation."
  (seq-some
   (lambda (child)
     (or (omnigent-ui--session-pending-p child)
         (omnigent-ui--descendant-pending-p child)))
   (omnigent-sessions-children (alist-get 'id session))))

(defun omnigent-ui--project-at-point ()
  "Return the project key on the heading at point."
  (get-text-property (line-beginning-position) 'omnigent-ui-project))

(defun omnigent-ui-sessions-render ()
  "Render the session list and preserve point by session ID."
  (when-let* ((buffer (get-buffer "*omnigent-sessions*")))
    (with-current-buffer buffer
      (let ((id (omnigent-ui--session-id-at-point))
            (project
             (or (omnigent-ui--project-at-point)
                 (get-text-property
                  (line-beginning-position)
                  'omnigent-ui-session-project)))
            (inhibit-read-only t)
            (sessions
             (sort (copy-sequence (omnigent-sessions-visible))
                   (lambda (a b)
                     (let ((left-archived
                            (eq (alist-get 'archived a) t))
                           (right-archived
                            (eq (alist-get 'archived b) t))
                           (left (alist-get 'updated_at a))
                           (right (alist-get 'updated_at b)))
                       (if (not (eq left-archived right-archived))
                           (not left-archived)
                         (if (and (numberp left) (numberp right))
                             (> left right)
                           (string>
                            (format "%s" (or left ""))
                            (format "%s" (or right ""))))))))))
        (erase-buffer)
        (let ((line-width
               (if-let* ((window (get-buffer-window buffer t)))
                 (window-body-width window)
                 (frame-width))))
          (let ((groups (make-hash-table :test 'equal))
                (keys
                 (mapcar
                  (lambda (row) (alist-get 'id row))
                  omnigent-sessions-projects)))
            (dolist (session sessions)
              (let ((key (omnigent-sessions-project-key session)))
                (push session (gethash key groups))
                (unless (or (eq key 'unassigned) (member key keys))
                  (setq keys (append keys (list key))))))
            (dolist (key
                     (append
                      (cl-remove-if-not
                       (lambda (key)
                         (or (gethash key groups)
                             (gethash
                              key omnigent-sessions--project-lists)))
                       keys)
                      (when (or (gethash 'unassigned groups)
                                (gethash
                                 'unassigned
                                 omnigent-sessions--project-lists))
                        '(unassigned))))
              (let ((folded (member key omnigent-ui--folded-projects))
                    last-session
                    (name
                     (if (eq key 'unassigned)
                         "Unassigned"
                       (or (alist-get
                            'name
                            (cl-find
                             key
                             omnigent-sessions-projects
                             :key
                             (lambda (row) (alist-get 'id row))
                             :test #'equal))
                           key))))
                (insert
                 (propertize
                  (concat
                   (if folded
                       "▸ "
                     "▾ ")
                   (if (and folded
                            (seq-some
                             #'omnigent-ui--descendant-pending-p
                             (gethash key groups)))
                       (propertize
                        "! "
                        'face 'omnigent-ui-session-attention)
                     "")
                   (replace-regexp-in-string "[\n\r]" " " name) "\n")
                  'omnigent-ui-project
                  key
                  'face
                  'omnigent-ui-project))
                (unless folded
                  (dolist (session (nreverse (gethash key groups)))
                    (setq last-session session)
                    (omnigent-ui--insert-session-row
                     session line-width 1 key))
                  (when (if-let*
                            ((entry
                              (gethash
                               key omnigent-sessions--project-lists)))
                          (nth 2 entry)
                          (eq
                           (gethash
                            key omnigent-sessions--project-more)
                           t))
                    (insert
                     (propertize
                      "  ...\n"
                      'face
                      (when (eq (alist-get 'archived last-session) t)
                        'omnigent-ui-session-archived)))))))))
        (goto-char (point-min))
        (when (or id project)
          (while (and (not (eobp))
                      (not
                       (if id
                           (equal
                            id (omnigent-ui--session-id-at-point))
                         (equal
                          project (omnigent-ui--project-at-point)))))
            (forward-line 1))
          (when (eobp)
            (goto-char (point-min))
            (when project
              (while (and (not (eobp))
                          (not
                           (equal
                            project (omnigent-ui--project-at-point))))
                (forward-line 1))
              (when (eobp)
                (goto-char (point-min))))))))))

(defun omnigent-ui--insert-session-row
    (session line-width depth project)
  "Insert SESSION and its unfolded children within LINE-WIDTH at DEPTH in PROJECT."
  (let* ((start (point))
         (id (alist-get 'id session))
         (children (omnigent-sessions-children id))
         (folded (member id omnigent-ui--folded-sessions))
         (indent (* 2 depth))
         (pending
          (or (omnigent-ui--session-pending-p session)
              (and folded
                   (omnigent-ui--descendant-pending-p session))))
         (prefix-width
          (+ indent
             (if children
                 2
               0)
             (if pending
                 2
               0)))
         (title (alist-get 'title session))
         (updated-at
          (omnigent-ui--session-age (alist-get 'updated_at session)))
         (title
          (if (and (stringp title) (not (string-empty-p title)))
              (replace-regexp-in-string "[\n\r]" " " title)
            "Untitled")))
    (insert (make-string indent ?\s))
    (when children
      (insert
       (if folded
           "▸ "
         "▾ ")))
    (when pending
      (insert "! "))
    (insert
     (truncate-string-to-width
      title
      (max 1
           (- line-width prefix-width
              (if updated-at
                  (+ 1 (string-width updated-at))
                0)))
      nil nil "…"))
    (when updated-at
      (insert
       (propertize " "
                   'display
                   `(space
                     :align-to (- right ,(string-width updated-at)))))
      (insert updated-at))
    (insert "\n")
    (add-text-properties
     start (point)
     (list
      'omnigent-ui-session-id
      (alist-get 'id session)
      'omnigent-ui-session-project
      project
      'face
      (omnigent-ui--session-face session)))
    (when (equal
           (alist-get 'id session) omnigent-ui--selected-session)
      (add-face-text-property
       (+ start prefix-width) (1- (point)) 'bold))
    (when pending
      (put-text-property
       (+ start prefix-width -2)
       (+ start prefix-width -1)
       'face
       'omnigent-ui-session-attention))
    (unless folded
      (dolist (child children)
        (omnigent-ui--insert-session-row
         child line-width (1+ depth) project)))))


;;; Connection and selection

(defvar omnigent-ui--idle-timer nil)
(defvar omnigent-ui--workspace-cache (make-hash-table :test 'equal))
(defvar omnigent-ui--workspace-pending (make-hash-table :test 'equal))
(defvar omnigent-ui--workspace-again (make-hash-table :test 'equal))
(defvar omnigent-ui--workspace-visible nil)
(defvar omnigent-ui--workspace-closed nil)
(defvar omnigent-ui--changing-windows nil)
(defvar-local omnigent-ui--workspace-id nil)


(defun omnigent-ui-start ()
  "Load server data and open the session list after connection."
  (unless omnigent-sessions-updates
    (omnigent-sessions-start
     (lambda ()
       (when (and omnigent-open-session-list-on-connect
                  (not (get-buffer-window "*omnigent-sessions*")))
         (omnigent-ui-sessions)))))
  (unless omnigent-ui--idle-timer
    (setq omnigent-ui--idle-timer
          (run-with-idle-timer 10 t #'omnigent-sessions-refresh))))

(defun omnigent-ui-reset ()
  "Stop frontend timers and discard server-specific workspace views."
  (when-let* ((buffer (get-buffer "*omnigent-sessions*")))
    (with-current-buffer buffer
      (setq
       omnigent-ui--folded-projects nil
       omnigent-ui--folded-sessions nil)))
  (when (timerp omnigent-ui--idle-timer)
    (cancel-timer omnigent-ui--idle-timer))
  (setq
   omnigent-ui--idle-timer nil
   omnigent-ui--selected-session nil
   omnigent-ui--workspace-visible nil
   omnigent-ui--workspace-closed nil)
  (clrhash omnigent-ui--workspace-cache)
  (clrhash omnigent-ui--workspace-pending)
  (clrhash omnigent-ui--workspace-again)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (or omnigent-ui--workspace-id
                (derived-mode-p 'omnigent-ui-workspace-mode))
        (kill-buffer buffer))))
  (omnigent-ui-sessions-render))

(defun omnigent-ui-open (id &optional title)
  "Open ID with TITLE in a non-side window and select its composer."
  (let ((window (or (get-mru-window nil nil t) (selected-window))))
    (when (window-parameter window 'window-side)
      (setq window (window-main-window)))
    (with-selected-window window
      (omnigent-conversation-open id title))
    (select-window (get-buffer-window (omnigent-sessions-buffer id)))
    (omnigent-ui--selection)))

(defun omnigent-ui-created (session)
  "Open the newly created SESSION."
  (let ((omnigent-conversation--initial-sandbox-status
         (alist-get 'sandbox_status session)))
    (omnigent-ui-open (alist-get 'id session)
                      (alist-get 'title session))))

(defun omnigent-ui--selection (&rest _ignored)
  "Track the most recently selected conversation, ignoring other buffers."
  (when (and (not omnigent-ui--changing-windows)
             (buffer-live-p (window-buffer (selected-window))))
    (with-current-buffer (window-buffer (selected-window))
      (when (and (derived-mode-p 'omnigent-conversation-mode)
                 (not
                  (equal
                   omnigent-conversation-session-id
                   omnigent-ui--selected-session)))
        (setq
         omnigent-ui--selected-session
         omnigent-conversation-session-id
         omnigent-ui--workspace-closed nil)
        (omnigent-ui-sessions-render)
        (omnigent-ui--workspace-display)
        (omnigent-ui-workspace-refresh)))))

(defun omnigent-ui--action-target ()
  "Return the current session ID and display title."
  (let* ((id
          (or (and (derived-mode-p 'omnigent-conversation-mode)
                   omnigent-conversation-session-id)
              (omnigent-ui--session-id-at-point)))
         (row (omnigent-sessions-row id)))
    (unless id
      (user-error "No session at point"))
    (when (or (and (derived-mode-p 'omnigent-conversation-mode)
                   buffer-read-only)
              (equal (alist-get 'permission_level row) 1)
              (when-let* ((buffer (omnigent-sessions-buffer id)))
                (with-current-buffer buffer
                  buffer-read-only)))
      (user-error "This session is read-only"))
    (cons id (or (alist-get 'title row) "Untitled"))))

(defun omnigent-ui--action-result (action title status body)
  "Report failed ACTION on TITLE with STATUS and BODY diagnostics."
  (unless (omnigent-transport-success-p status)
    (message "%s"
             (omnigent-transport-error-message
              (format "%s session %s" action title) status body))))


(defun omnigent-ui--frame (frame)
  "Freeze removed sessions and close their workspace panel for FRAME."
  (when (equal (alist-get 'type frame) "removed")
    (dolist (id (append (alist-get 'ids frame) nil))
      (when-let* ((buffer (omnigent-sessions-buffer id)))
        (with-current-buffer buffer
          (omnigent-conversation--freeze)
          (dolist (widget omnigent-ui--widgets)
            (widget-apply widget :deactivate))))
      (remhash id omnigent-ui--workspace-cache)
      (remhash id omnigent-ui--workspace-pending)
      (remhash id omnigent-ui--workspace-again)
      (when (equal id omnigent-ui--selected-session)
        (omnigent-ui--workspace-hide)))))

;;; Workspace side windows

(defun omnigent-ui--workspace-buffer (id)
  "Return the separate workspace buffer for session ID."
  (let ((buffer
         (get-buffer-create (format "*omnigent-workspace: %s*" id))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'omnigent-ui-workspace-mode)
        (omnigent-ui-workspace-mode)
        (setq omnigent-ui--workspace-id id)))
    buffer))

(defun omnigent-ui--workspace-hide ()
  "Hide the workspace side window without recording a user close."
  (let ((omnigent-ui--changing-windows t))
    (dolist (window (window-list))
      (when (with-current-buffer (window-buffer window)
              (derived-mode-p 'omnigent-ui-workspace-mode))
        (delete-window window))))
  (setq omnigent-ui--workspace-visible nil))

(defun omnigent-ui--workspace-display ()
  "Display the selected session's cache if the panel is enabled."
  (let* ((id omnigent-ui--selected-session)
         (data (gethash id omnigent-ui--workspace-cache)))
    (if (or (not id) (and data (null (alist-get 'changes data))))
        (omnigent-ui--workspace-hide)
      (when (or omnigent-ui--workspace-visible
                (and data (not omnigent-ui--workspace-closed)))
        (let* ((buffer (omnigent-ui--workspace-buffer id))
               (visible-window
                (get-buffer-window buffer (selected-frame))))
          (unless visible-window
            (let ((omnigent-ui--changing-windows t))
              (omnigent-ui--workspace-hide)
              (display-buffer-in-side-window
               buffer
               (append
                '((side . left) (slot . 1))
                (when omnigent-side-window-width
                  `((window-width . ,omnigent-side-window-width)))
                (when omnigent-workspace-window-height
                  `((window-height
                     . ,omnigent-workspace-window-height)))))))
          (setq omnigent-ui--workspace-visible t))))))

(defun omnigent-ui--windows-changed (&rest _ignored)
  "Record a manual workspace close and follow conversation selection."
  (unless omnigent-ui--changing-windows
    (when (and omnigent-ui--workspace-visible
               (not
                (cl-some
                 (lambda (window)
                   (with-current-buffer (window-buffer window)
                     (derived-mode-p 'omnigent-ui-workspace-mode)))
                 (window-list))))
      (setq
       omnigent-ui--workspace-visible nil
       omnigent-ui--workspace-closed t))
    (omnigent-ui--selection)))


(defun omnigent-ui--workspace-result (id generation token status data)
  "Cache workspace DATA for ID on successful STATUS from GENERATION and TOKEN."
  (when (and (= generation omnigent-transport--generation)
             (eq token (gethash id omnigent-ui--workspace-pending)))
    (remhash id omnigent-ui--workspace-pending)
    (when (omnigent-transport-success-p status)
      (puthash id data omnigent-ui--workspace-cache)
      (omnigent-ui--workspace-render id data)
      (when (equal id omnigent-ui--selected-session)
        (omnigent-ui--workspace-display)))
    (when (gethash id omnigent-ui--workspace-again)
      (remhash id omnigent-ui--workspace-again)
      (omnigent-ui-workspace-refresh id))))

(defun omnigent-ui--workspace-render (id data)
  "Render ID's changed paths from DATA and preserve point by path."
  (with-current-buffer (omnigent-ui--workspace-buffer id)
    (let ((path
           (get-text-property
            (line-beginning-position) 'omnigent-ui-path))
          (line (line-number-at-pos))
          (inhibit-read-only t))
      (erase-buffer)
      (insert (propertize "[unified diff]\n" 'omnigent-ui-path :all))
      (dolist (change
               (sort (copy-sequence (alist-get 'changes data))
                     (lambda (a b)
                       (string<
                        (alist-get 'path a) (alist-get 'path b)))))
        (insert
         (propertize (format "%s %s\n"
                             (pcase (alist-get 'status change)
                               ("created" "A")
                               ("deleted" "D")
                               (_ "M"))
                             (alist-get 'path change))
                     'omnigent-ui-path (alist-get 'path change))))
      (goto-char (point-min))
      (while (and path
                  (not (eobp))
                  (not
                   (equal
                    path
                    (get-text-property (point) 'omnigent-ui-path))))
        (forward-line 1))
      (when (or (not path) (eobp))
        (goto-char (point-min))
        (forward-line (max 0 (1- line)))
        (when (and (eobp) (> (point) (point-min)))
          (forward-line -1))))))


(defun omnigent-ui--workspace-filename (id path)
  "Return the filename for PATH in workspace ID."
  (let* ((buffer (omnigent-sessions-buffer id))
         (host-id
          (or (and (buffer-live-p buffer)
                   (buffer-local-value
                    'omnigent-conversation-host-id buffer))
              (alist-get
               'host_id
               (cl-find
                id
                (omnigent-sessions-visible)
                :key
                (lambda (row) (alist-get 'id row))
                :test #'equal))))
         (root
          (alist-get
           'root (gethash id omnigent-ui--workspace-cache))))
    (omnigent-workspace-local-filename
     root path (omnigent-workspace-host-mapping host-id))))

(defun omnigent-ui--diff-result (id path status diff)
  "Display successful DIFF for ID and PATH, leaving old buffers on failure."
  (when (omnigent-transport-success-p status)
    (if (string-empty-p diff)
        (message "No diff available for %s"
                 (if (eq path :all)
                     "this workspace"
                   path))
      (let ((buffer
             (get-buffer-create
              (format "*omnigent-diff: %s:%s*" id path))))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert diff)
            (funcall omnigent-workspace-diff-mode)
            (let ((map (copy-keymap omnigent-ui-workspace-mode-map)))
              (set-keymap-parent map (current-local-map))
              (use-local-map map))
            (when (gethash id omnigent-ui--workspace-cache)
              (setq default-directory
                    (file-name-as-directory
                     (omnigent-ui--workspace-filename id ""))))
            (setq
             omnigent-ui--workspace-id id
             buffer-read-only t)
            (goto-char (point-min))))
        (pop-to-buffer buffer)))))

;;; Conversation presentation

(defface omnigent-ui-user
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for user message labels."
  :group 'omnigent-ui)
(defface omnigent-ui-agent '((t :inherit highlight :weight bold))
  "Face for agent message labels."
  :group 'omnigent-ui)
(defface omnigent-ui-prompt '((t :inherit comint-highlight-prompt))
  "Face for conversation prompts and message labels."
  :group 'omnigent-ui)
(defface omnigent-ui-attachment
  '((t :inherit link :underline nil :weight bold))
  "Face for the attachment block in the composer."
  :group 'omnigent-ui)
(defface omnigent-ui-fold-marker
  '((t :inherit font-lock-builtin-face :underline nil))
  "Face for fold buttons without underlining."
  :group 'omnigent-ui)

(define-button-type 'omnigent-ui-fold
  'face
  'omnigent-ui-fold-marker
  'mouse-face
  'omnigent-ui-fold-marker)

(defface omnigent-ui-reasoning '((t :inherit shadow))
  "Face for reasoning blocks."
  :group 'omnigent-ui)
(defface omnigent-ui-error '((t :inherit error))
  "Face for errors and interruption markers."
  :group 'omnigent-ui)
(defface omnigent-ui-elicitation
  '((t :inherit font-lock-warning-face :weight bold))
  "Face for temporary request headings."
  :group 'omnigent-ui)

;; ponytail: display limits only; fetch omitted content on demand in a later version.
(defconst omnigent-ui--tool-line-limit 32768)
(defconst omnigent-ui--tool-lines-limit 1000)
(defvar-local omnigent-ui--request-start nil)
(defvar-local omnigent-ui--composer-label nil)
(defvar-local omnigent-ui--pending-start nil
  "Marker separating request forms from submitted input blocks.")
(defvar-local omnigent-ui--folds nil)
(defvar-local omnigent-ui--field-errors nil)
(defvar-local omnigent-ui--rendering nil)

(defun omnigent-ui--bounded-output (text)
  "Bound long lines and line counts in tool output TEXT deterministically."
  (let ((lines
         (mapcar
          (lambda (line)
            (if (> (length line) omnigent-ui--tool-line-limit)
                (concat
                 (substring line 0 200)
                 (format " ... [%d characters omitted] ... "
                         (- (length line) 400))
                 (substring line -200))
              line))
          (split-string text "\n"))))
    (when (> (length lines) omnigent-ui--tool-lines-limit)
      (setq lines
            (append
             (cl-subseq lines 0 400)
             (list
              (format "[%d lines omitted]" (- (length lines) 800)))
             (last lines 400))))
    (mapconcat #'identity lines "\n")))

(defun omnigent-ui--string (value)
  "Return readable plain text for server VALUE."
  (if (stringp value)
      value
    (if value
        (format "%s" value)
      "")))

(defun omnigent-ui--location (position)
  "Record POSITION by transcript item ID or by a marker outside transcript."
  (if (>= position omnigent-ui--request-start)
      (copy-marker position t)
    (let* ((id (get-text-property position 'omnigent-ui-item-id))
           (start
            (or (previous-single-property-change
                 (min (point-max) (1+ position)) 'omnigent-ui-item-id)
                (point-min))))
      (list id (- position start)))))

(defun omnigent-ui--restore-location (location)
  "Return the position represented by LOCATION after a render."
  (if (markerp location)
      (prog1 (marker-position location)
        (set-marker location nil))
    (let ((position (point-min))
          (id (car location)))
      (while (and (< position omnigent-ui--request-start)
                  (not
                   (equal
                    id
                    (get-text-property
                     position 'omnigent-ui-item-id))))
        (setq position
              (or (next-single-property-change
                   position 'omnigent-ui-item-id)
                  omnigent-ui--request-start)))
      (if (>= position omnigent-ui--request-start)
          omnigent-ui--request-start
        (min (+ position (or (cadr location) 0))
             (1- (or (next-single-property-change
                      position 'omnigent-ui-item-id)
                     omnigent-ui--request-start)))))))

(defun omnigent-ui--fold-button (button)
  "Toggle the fold identified by BUTTON without changing any other fold."
  (let ((id (button-get button 'omnigent-ui-fold-id)))
    (puthash
     id (not (gethash id omnigent-ui--folds)) omnigent-ui--folds)
    (omnigent-ui--transcript)))

(defun omnigent-ui-fold-at-point (open)
  "Set the fold for the current transcript block to OPEN.
Signal an error if point is not in a foldable block."
  (let* ((item-id (get-text-property (point) 'omnigent-ui-item-id))
         (start
          (and item-id
               (or (previous-single-property-change
                    (min (point-max)
                         (1+ (point)))
                    'omnigent-ui-item-id)
                   (point-min))))
         (end
          (and start
               (or (next-single-property-change
                    start 'omnigent-ui-item-id)
                   (point-max))))
         button)
    (when start
      (let ((position start))
        (while (and (< position end) (not button))
          (when (and (button-at position)
                     (equal
                      item-id
                      (button-get
                       (button-at position) 'omnigent-ui-fold-id)))
            (setq button (button-at position)))
          (setq position (1+ position)))))
    (unless button
      (user-error "Point is not in a foldable transcript block"))
    (unless (eq (and (gethash item-id omnigent-ui--folds) t) open)
      (button-activate button))))

(defun omnigent-ui--fold (id heading body &optional face)
  "Insert a fold for ID with HEADING, BODY, and optional FACE."
  (let ((open (gethash id omnigent-ui--folds)))
    (insert-text-button (if open
                            "▼"
                          "▶")
                        'type
                        'omnigent-ui-fold
                        'face
                        'omnigent-ui-fold-marker
                        'font-lock-face
                        'omnigent-ui-fold-marker
                        'mouse-face
                        'omnigent-ui-fold-marker
                        'omnigent-ui-fold-id
                        id
                        'action
                        #'omnigent-ui--fold-button
                        'follow-link
                        t)
    (insert " " heading)
    (let ((start (point)))
      (insert "\n" body)
      (put-text-property
       start (point) 'invisible
       (unless open
         'omnigent-ui-fold))
      (when face
        (put-text-property start (point) 'face face)))
    (insert "\n\n")))

(defun omnigent-ui--tool-render (id item outputs command)
  "Render tool ITEM and OUTPUTS for ID with optional COMMAND heading."
  (let* ((output (gethash (alist-get 'call_id item) outputs))
         (args (omnigent-ui--string (alist-get 'arguments item)))
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
    (omnigent-ui--fold
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
      (omnigent-ui--bounded-output
       (omnigent-ui--string
        (or (alist-get 'output output)
            (alist-get 'content output)
            "")))))))

(defun omnigent-ui--tool-arguments (item)
  "Parse the JSON arguments of tool ITEM."
  (condition-case nil
      (json-parse-string (omnigent-ui--string
                          (alist-get 'arguments item))
                         :object-type 'alist)
    (error
     nil)))

(defun omnigent-ui--tool-shell-p (item)
  "Return non-nil when ITEM is a shell call."
  (member (alist-get 'name item) '("shell" "bash")))

(defun omnigent-ui--tool-patch-p (item)
  "Return non-nil when ITEM is a file patch or read call."
  (member
   (alist-get 'name item) '("apply_patch" "edit" "write" "read")))

(defun omnigent-ui--tool-turn-diff-p (item)
  "Return non-nil when ITEM is a turn diff."
  (equal (alist-get 'name item) "turn_diff"))

(defun omnigent-ui--tool-any-p (_item)
  "Match any tool ITEM."
  t)

(defun omnigent-ui--unwrap-shell-command (command)
  "Return COMMAND without its /bin/sh and -lc wrapper."
  (if (string-match
       "\\`/bin/[^/]+sh -lc \\(['\"]\\)\\(\\(?:.\\|\n\\)*\\)\\1\\'"
       command)
      (match-string 2 command)
    command))

(defun omnigent-ui--tool-shell (id item outputs)
  "Render shell ITEM and OUTPUTS for ID."
  (let ((command
         (alist-get 'command (omnigent-ui--tool-arguments item))))
    (when (stringp command)
      (setq command (omnigent-ui--unwrap-shell-command command)))
    (omnigent-ui--tool-render id item outputs command)))

(defun omnigent-ui--tool-patch (id item outputs)
  "Render patch or read ITEM and OUTPUTS for ID."
  (let* ((arguments (omnigent-ui--tool-arguments item))
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
    (omnigent-ui--tool-render
     id item outputs
     (when paths
       (concat verb " " (mapconcat #'identity paths ", "))))))

(defun omnigent-ui--tool-turn-diff (_id _item _outputs)
  "Hide the turn diff for _ID, _ITEM, and _OUTPUTS."
  nil)

(defun omnigent-ui--tool-default (id item outputs)
  "Render tool ITEM and OUTPUTS for ID with the default heading."
  (omnigent-ui--tool-render id item outputs nil))

(defconst omnigent-ui--tool-handlers
  '((omnigent-ui--tool-turn-diff-p . omnigent-ui--tool-turn-diff)
    (omnigent-ui--tool-shell-p . omnigent-ui--tool-shell)
    (omnigent-ui--tool-patch-p . omnigent-ui--tool-patch)
    (omnigent-ui--tool-any-p . omnigent-ui--tool-default))
  "Predicates and renderers for tool calls, in dispatch order.")

(defun omnigent-ui--tool-dispatch (id item outputs)
  "Render tool ITEM with ID and OUTPUTS using the first matching handler."
  (let ((handler
         (cl-find-if
          (lambda (entry)
            (funcall (car entry) item))
          omnigent-ui--tool-handlers)))
    (funcall (cdr handler) id item outputs)))

(defun omnigent-ui--item (id item outputs)
  "Render transcript ITEM with ID and tool OUTPUTS indexed by call ID."
  (let ((type (alist-get 'type item))
        (text (omnigent-conversation--text item)))
    (when-let* ((previous (alist-get 'omnigent-previous-id item))
                ((gethash previous omnigent-ui--folds)))
      (puthash id t omnigent-ui--folds)
      (remhash previous omnigent-ui--folds))
    (pcase type
      ((or "function_call_output" "resource_event") nil)
      ((guard (eq (alist-get 'is_meta item) t)) nil)
      ("reasoning"
       (omnigent-ui--fold id "Thinking" text 'omnigent-ui-reasoning))
      ("function_call" (omnigent-ui--tool-dispatch id item outputs))
      ("error" (insert
        (propertize "Error:\n" 'face 'omnigent-ui-error) text "\n\n"))
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
                      'omnigent-ui-prompt
                      'font-lock-face
                      'omnigent-ui-prompt)
          (if (omnigent-ui--message-complete-p id item)
              (propertize text 'omnigent-ui-markdown id)
            text)
          "\n\n"))))))

(defun omnigent-ui--message-complete-p (id item)
  "Return non-nil when message ID and ITEM are ready for Markdown display."
  (or (equal (alist-get 'role item) "user")
      (alist-get 'omnigent-committed item)
      (not omnigent-conversation--response-id)
      (not (equal id omnigent-conversation--section-id))))

(defun omnigent-ui--markdown-apply (begin end hide)
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
      (font-lock-ensure)
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
                     'omnigent-ui-attachment)))
              (put-text-property pos next 'face face)
              (put-text-property pos next 'font-lock-face face)))
          (setq pos next))))
    (put-text-property begin end 'omnigent-ui-markdown-done t)))

(defun omnigent-ui--markdown-fontify (start end &optional _loudly)
  "Apply Markdown to completed messages visible between START and END."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t))
    (with-silent-modifications
      (save-excursion
        (goto-char start)
        (while (< (point) end)
          (let* ((id
                  (get-text-property (point) 'omnigent-ui-markdown))
                 (next
                  (next-single-property-change
                   (point) 'omnigent-ui-markdown
                   nil (point-max))))
            (when (and id
                       (not
                        (get-text-property
                         (point) 'omnigent-ui-markdown-done)))
              (let ((begin
                     (or (previous-single-property-change
                          (1+ (point)) 'omnigent-ui-markdown)
                         (point-min))))
                (omnigent-ui--markdown-apply begin next t)))
            (goto-char next)))
        (when (and (> end omnigent-conversation--prompt-start)
                   (not
                    (get-text-property
                     omnigent-conversation--prompt-start
                     'omnigent-ui-markdown-done)))
          (omnigent-ui--markdown-apply
           omnigent-conversation--prompt-start (point-max) nil))))))

(defun omnigent-ui--markdown-composer-changed (start _end _old-length)
  "Invalidate composer Markdown after an edit at START."
  (when (and omnigent-conversation--prompt-start
             (>= start omnigent-conversation--prompt-start)
             (not omnigent-ui--rendering))
    (let ((inhibit-read-only t))
      (with-silent-modifications
        (remove-text-properties
         omnigent-conversation--prompt-start
         (point-max)
         '(omnigent-ui-markdown-done nil))))
    (font-lock-flush
     omnigent-conversation--prompt-start (point-max))))

(defvar-local omnigent-ui--blocks nil
  "Rendered item signatures and boundary markers, indexed by item ID.")

(defun omnigent-ui--block-remove (block)
  "Delete rendered BLOCK and release its boundary markers."
  (delete-region (nth 1 block) (nth 2 block))
  (set-marker (nth 1 block) nil)
  (set-marker (nth 2 block) nil))

(defun omnigent-ui--block-signature (id item outputs)
  "Return the rendering inputs for ID, ITEM and tool OUTPUTS."
  (list
   item
   (gethash (alist-get 'call_id item) outputs)
   (gethash id omnigent-ui--folds)
   omnigent-conversation-agent-name
   (omnigent-ui--message-complete-p id item)))

(defvar-local omnigent-ui--history-positioned nil
  "Non-nil after the first nonempty transcript receives its window position.")

(defun omnigent-ui--transcript-render ()
  "Refresh only transcript text, preserving composer, forms, folds and reading."
  (when (and omnigent-ui--request-start (not omnigent-ui--rendering))
    (let* ((omnigent-ui--rendering t)
           (location (omnigent-ui--location (point)))
           (windows
            (mapcar
             (lambda (window)
               (list
                window
                (omnigent-ui--location (window-start window))
                (omnigent-ui--location (window-point window))))
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
           (omnigent-ui--block-remove block)
           (remhash id omnigent-ui--blocks)))
       omnigent-ui--blocks)
      (goto-char (point-min))
      (dolist (id omnigent-conversation--order)
        (let* ((item (gethash id omnigent-conversation--items))
               (block (gethash id omnigent-ui--blocks))
               (signature
                (omnigent-ui--block-signature id item outputs)))
          (if (and block
                   (= (point) (nth 1 block))
                   (equal signature (car block)))
              (goto-char (nth 2 block))
            (when block
              (omnigent-ui--block-remove block))
            (let ((start (point)))
              (omnigent-ui--item id item outputs)
              (add-text-properties
               start (point)
               (list
                'omnigent-ui-item-id
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
                 (omnigent-ui--block-signature id item outputs))
                (copy-marker start (< start (point)))
                (copy-marker (point)))
               omnigent-ui--blocks)))))
      (move-overlay
       omnigent-ui--busy-overlay
       omnigent-ui--composer-label
       omnigent-ui--composer-label)
      (goto-char (omnigent-ui--restore-location location))
      (dolist (entry windows)
        (pcase-let ((`(,window ,start ,position) entry))
          (let ((new-start (omnigent-ui--restore-location start))
                (new-point (omnigent-ui--restore-location position)))
            (set-window-point window new-point)
            (set-window-start window new-start t))))
      (when (and omnigent-conversation--order
                 (not omnigent-ui--history-positioned))
        (setq omnigent-ui--history-positioned t)
        (dolist (window
                 (get-buffer-window-list (current-buffer) nil t))
          (with-selected-window window
            (recenter -3)))))))

(defun omnigent-ui--transcript-flush (buffer)
  "Render the pending transcript update in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq omnigent-ui--transcript-timer nil)
      (omnigent-ui--transcript-render))))

(defun omnigent-ui--transcript ()
  "Batch transcript updates while a response streams, then render them."
  (if (and omnigent-conversation--response-id
           (not omnigent-conversation--invalid))
      (unless (timerp omnigent-ui--transcript-timer)
        (setq omnigent-ui--transcript-timer
              (run-at-time 0.05 nil #'omnigent-ui--transcript-flush
                           (current-buffer))))
    (when (timerp omnigent-ui--transcript-timer)
      (cancel-timer omnigent-ui--transcript-timer)
      (setq omnigent-ui--transcript-timer nil))
    (omnigent-ui--transcript-render)))

(defun omnigent-ui--pending-inputs ()
  "Render submitted input between request forms and the editable composer."
  (when (and omnigent-ui--pending-start (not omnigent-ui--rendering))
    (let ((omnigent-ui--rendering t)
          (inhibit-read-only t)
          (inhibit-modification-hooks t)
          (buffer-undo-list t)
          (position (copy-marker (point) t))
          (request-start (marker-position omnigent-ui--request-start))
          (start (marker-position omnigent-ui--pending-start)))
      (delete-region start omnigent-ui--composer-label)
      (goto-char start)
      (dolist (input omnigent-conversation--pending-inputs)
        (let ((begin (point))
              (text (omnigent-conversation--text input)))
          (insert
           (propertize (format "[%s] > " (alist-get 'state input))
                       'face 'omnigent-ui-user)
           (propertize text 'omnigent-ui-markdown t) "\n")
          (when (eq (alist-get 'state input) 'unconfirmed)
            (insert
             (propertize
              "Warning: the server may have accepted this message. Do not resend automatically.\n"
              'face 'omnigent-ui-error)))
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
      (set-marker omnigent-ui--pending-start start)
      (set-marker omnigent-ui--request-start request-start)
      (goto-char position)
      (move-overlay
       omnigent-ui--busy-overlay
       omnigent-ui--composer-label
       omnigent-ui--composer-label)
      (set-marker position nil))))

(defun omnigent-ui--composer-indent (&rest _ignored)
  "Align composer continuation lines using display properties only."
  (when (and omnigent-conversation--prompt-start
             (not omnigent-ui--rendering))
    (let ((omnigent-ui--rendering t)
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

(defun omnigent-ui--evil-change (change beg end &rest args)
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
  (advice-add 'evil-change :around #'omnigent-ui--evil-change))

(defun omnigent-ui--conversation-event (name data)
  "Refresh workspace changes on invalidation or terminal session status DATA."
  (let ((finished
         (and (equal name "session.status")
              (member (alist-get 'status data) '("idle" "failed")))))
    (when (and finished
               (equal
                omnigent-conversation-session-id
                omnigent-ui--selected-session))
      (setq omnigent-ui--workspace-closed nil))
    (when (or finished
              (equal name "session.changed_files.invalidated"))
      (omnigent-ui-workspace-refresh
       omnigent-conversation-session-id))))

(defun omnigent-ui--token-count (count)
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

(defun omnigent-ui--conversation-header ()
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
                                  (format "%s / %s (%.0f%%%%)"
                                          (omnigent-ui--token-count
                                           used)
                                          (omnigent-ui--token-count
                                           window)
                                          (* 100.0
                                             (/ (float used)
                                                window))))
                                 ((numberp used)
                                  (format "%s / unknown"
                                          (omnigent-ui--token-count
                                           used)))
                                 ((and (numberp window) (> window 0))
                                  (format "unknown / %s"
                                          (omnigent-ui--token-count
                                           window)))
                                 (t
                                  "unknown"))))
                      'face 'diff-header 'line-spacing 3))
    (force-mode-line-update)))

(defvar-local omnigent-ui--busy-overlay nil)
(defvar-local omnigent-ui--sandbox-overlay nil
  "Overlay for the sandbox status block before the composer.")
(defvar-local omnigent-ui--busy-timer nil)
(defvar-local omnigent-ui--busy-frame 0)
(defvar-local omnigent-ui--transcript-timer nil)

(defun omnigent-ui--sandbox-animating-p ()
  "Return non-nil when the sandbox status needs an animated spinner."
  (and omnigent-conversation--sandbox-status
       (not omnigent-conversation--invalid)
       (not
        (member
         (alist-get
          'stage omnigent-conversation--sandbox-status)
         '("failed" "action_required")))))

(defun omnigent-ui--sandbox-render (frame)
  "Render the sandbox status block with spinner FRAME."
  (when (overlayp omnigent-ui--sandbox-overlay)
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
       omnigent-ui--sandbox-overlay
       omnigent-ui--request-start
       omnigent-ui--request-start)
      (overlay-put
       omnigent-ui--sandbox-overlay 'before-string
       (when text
         (propertize (format "   %s%s\n\n"
                             (if (omnigent-ui--sandbox-animating-p)
                                 (concat frame " ")
                               "")
                             text)
                     'face
                     (if (equal stage "failed")
                         'omnigent-ui-error
                       'shadow)))))))

(defun omnigent-ui--busy-tick (buffer)
  "Advance busy indicators in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((responding
              (and omnigent-conversation--response-id
                   (not omnigent-conversation--invalid)))
             (frame
              (aref
               ["|" "/" "-" "\\"] (mod omnigent-ui--busy-frame 4))))
        (when (or responding (omnigent-ui--sandbox-animating-p))
          (cl-incf omnigent-ui--busy-frame))
        (when (overlayp omnigent-ui--busy-overlay)
          (overlay-put
           omnigent-ui--busy-overlay 'before-string
           (if responding
               frame
             " ")))
        (omnigent-ui--sandbox-render frame)))))

(defun omnigent-ui--busy-update ()
  "Update the transcript and prompt busy indicators."
  (cond
   ((and (not omnigent-conversation--invalid)
         (or omnigent-conversation--response-id
             (omnigent-ui--sandbox-animating-p)))
    (if omnigent-ui--busy-timer
        (progn
          (unless omnigent-conversation--response-id
            (overlay-put
             omnigent-ui--busy-overlay 'before-string " "))
          (omnigent-ui--sandbox-render
           (aref
            ["|" "/" "-" "\\"] (mod (1- omnigent-ui--busy-frame) 4))))
      (omnigent-ui--busy-tick (current-buffer))
      (setq omnigent-ui--busy-timer
            (run-at-time 0.15 0.15 #'omnigent-ui--busy-tick
                         (current-buffer)))))
   (t
    (when omnigent-ui--busy-timer
      (cancel-timer omnigent-ui--busy-timer)
      (setq omnigent-ui--busy-timer nil))
    (omnigent-ui--busy-tick (current-buffer)))))

(defun omnigent-ui--busy-stop ()
  "Stop the prompt animation when the conversation closes."
  (when omnigent-ui--busy-timer
    (cancel-timer omnigent-ui--busy-timer)
    (setq omnigent-ui--busy-timer nil))
  (when (timerp omnigent-ui--transcript-timer)
    (cancel-timer omnigent-ui--transcript-timer)
    (setq omnigent-ui--transcript-timer nil)))

(defun omnigent-ui-conversation-setup ()
  "Initialize transcript, request and composer boundaries for this session."
  (setq
   omnigent-ui--blocks (make-hash-table :test 'equal)
   omnigent-ui--folds (make-hash-table :test 'equal)
   omnigent-ui--field-errors (make-hash-table :test 'equal))
  (add-to-invisibility-spec 'omnigent-ui-fold)
  (add-to-invisibility-spec 'markdown-markup)
  (setq-local font-lock-defaults '(nil t))
  (font-lock-mode 1)
  (setq-local font-lock-fontify-region-function
              #'omnigent-ui--markdown-fontify)
  (add-hook
   'after-change-functions #'omnigent-ui--markdown-composer-changed
   nil t)
  (let ((inhibit-read-only t))
    (goto-char (point-min))
    (setq
     omnigent-ui--request-start (copy-marker (point) t)
     omnigent-ui--pending-start (copy-marker (point) t)
     omnigent-ui--composer-label (copy-marker (point) t))
    (insert
     (propertize "> "
                 'face
                 'omnigent-ui-prompt
                 'font-lock-face
                 'omnigent-ui-prompt
                 'read-only
                 t
                 'field
                 'prompt
                 'rear-nonsticky
                 t))
    (set-marker omnigent-ui--request-start (point-min))
    (set-marker omnigent-ui--pending-start (point-min))
    (set-marker omnigent-ui--composer-label (point-min))
    (set-marker omnigent-conversation--prompt-start (point))
    (set-marker-insertion-type
     omnigent-conversation--prompt-start nil))
  (setq omnigent-ui--busy-overlay
        (make-overlay
         omnigent-ui--composer-label omnigent-ui--composer-label))
  (setq omnigent-ui--sandbox-overlay
        (make-overlay
         omnigent-ui--request-start omnigent-ui--request-start))
  (omnigent-ui--busy-update)
  (add-hook 'kill-buffer-hook #'omnigent-ui--busy-stop nil t)
  (add-hook
   'omnigent-conversation-change-hook #'omnigent-ui--busy-update
   t t)
  (omnigent-ui--conversation-header)
  (add-hook 'omnigent-conversation-change-hook
            #'omnigent-ui--conversation-header
            nil
            t)
  (add-hook
   'omnigent-conversation-change-hook #'omnigent-ui--transcript
   nil t)
  (add-hook
   'omnigent-conversation-change-hook #'omnigent-ui--pending-inputs
   nil t)
  (add-hook 'omnigent-conversation-elicitation-change-hook
            #'omnigent-ui--requests
            nil
            t)
  (add-hook
   'omnigent-conversation-event-hook #'omnigent-ui--conversation-event
   nil t)
  (add-hook 'after-change-functions #'omnigent-ui--composer-indent
            nil
            t)
  (omnigent-ui--transcript)
  (omnigent-ui--requests)
  (omnigent-ui--pending-inputs)
  (goto-char (point-max)))

;;; Inline request widgets

(defun omnigent-ui--field-notify (widget &rest _ignored)
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

(defun omnigent-ui--secret (widget &rest _ignored)
  "Read WIDGET's secret into request state without inserting it in this buffer."
  (let* ((id (widget-get widget :request-id))
         (key (widget-get widget :field-name))
         (draft (omnigent-conversation-elicitation-draft id))
         (value (read-passwd (format "%s: " key))))
    (puthash key value draft)
    (omnigent-conversation-elicitation-set-draft id draft)))

(defun omnigent-ui--field
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
               :notify #'omnigent-ui--secret
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
                   :notify #'omnigent-ui--field-notify
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
                      (gethash id omnigent-ui--field-errors))
                     "; ")))
    (push widget omnigent-ui--widgets)
    (unless (string-empty-p errors)
      (insert
       (propertize (concat "  " errors) 'face 'omnigent-ui-error)))
    (insert "\n")))

(defun omnigent-ui--schema-fields (id params)
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
        (omnigent-ui--field
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

(defun omnigent-ui--question-fields (id)
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
        (omnigent-ui--field
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

(defun omnigent-ui--submit-widget (widget &rest _ignored)
  "Validate and submit the response selected by WIDGET."
  (let* ((id (widget-get widget :request-id))
         (action (widget-get widget :response-action))
         (errors
          (and (eq action 'accept)
               (omnigent-conversation-elicitation-validate id))))
    (puthash id errors omnigent-ui--field-errors)
    (if errors
        (progn
          (omnigent-ui--requests)
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
                        (reverse omnigent-ui--widgets))))
            (goto-char (widget-get field :from))))
      (omnigent-conversation-elicitation-submit
       id
       action
       (apply-partially #'omnigent-ui--action-result "Answer" id)))))

(defun omnigent-ui--request (request)
  "Insert one temporary REQUEST and its response widgets."
  (let* ((id (alist-get 'elicitation_id request))
         (params (alist-get 'params request))
         (url (alist-get 'url params))
         (external (and url (not (string-prefix-p "/approve/" url))))
         (approval
          (or (and url (not external))
              (alist-get 'policy_name params)))
         (pending (omnigent-conversation-elicitation-submitting-p id))
         (start (point)))
    (insert
     (propertize (if approval
                     "Approval required\n"
                   "Question\n")
                 'face 'omnigent-ui-elicitation))
    (dolist (key '(message policy_name phase content_preview))
      (when-let* ((value (alist-get key params)))
        (insert (omnigent-ui--string value) "\n")))
    (if external
        (push (widget-create 'url-link :value url url)
              omnigent-ui--widgets)
      (if (omnigent-conversation-elicitation-questions id)
          (omnigent-ui--question-fields id)
        (omnigent-ui--schema-fields id params))
      (dolist (error (gethash id omnigent-ui--field-errors))
        (unless (car error)
          (insert
           (propertize (concat (cdr error) "\n")
                       'face
                       'omnigent-ui-error))))
      (dolist (action '(accept decline))
        (let ((widget
               (widget-create
                'push-button
                :request-id id
                :response-action action
                :notify #'omnigent-ui--submit-widget
                (if (eq action 'accept)
                    (if approval
                        "Approve"
                      "Submit")
                  "Decline"))))
          (push widget omnigent-ui--widgets)
          (when pending
            (widget-apply widget :deactivate)))
        (insert " "))
      (when pending
        (insert "Submitting...")))
    (insert "\n\n")
    (add-text-properties
     start (point) (list 'omnigent-ui-request-id id))))

(defun omnigent-ui--widget-before-change (start end)
  "Apply widget edit protection to request fields between START and END only."
  (when (< start omnigent-conversation--prompt-start)
    (condition-case err
        (widget-before-change start end)
      (text-read-only
       (remove-hook 'post-command-hook #'widget-add-change t)
       (add-hook 'post-command-hook #'omnigent-ui--restore-edit-hooks
                 nil
                 t)
       (signal (car err) (cdr err))))))

(defun omnigent-ui--restore-edit-hooks ()
  "Restore request-only widget hooks after a rejected edit or form setup."
  (remove-hook 'post-command-hook #'omnigent-ui--restore-edit-hooks t)
  (remove-hook 'before-change-functions #'widget-before-change t)
  (remove-hook 'after-change-functions #'widget-after-change t)
  (add-hook
   'before-change-functions #'omnigent-ui--widget-before-change
   nil t)
  (add-hook 'after-change-functions #'omnigent-ui--widget-after-change
            nil
            t))

(defun omnigent-ui--widget-after-change (start end old-length)
  "Notify request widgets of changes from START to END with OLD-LENGTH."
  (when (< start omnigent-ui--pending-start)
    (widget-after-change start end old-length)))

(defun omnigent-ui--requests ()
  "Refresh only temporary request blocks, keeping composer and transcript intact."
  (when (and omnigent-ui--request-start (not omnigent-ui--rendering))
    (let* ((omnigent-ui--rendering t)
           (inhibit-read-only t)
           (buffer-undo-list t)
           (position (copy-marker (point) t))
           (field
            (cl-find-if
             (lambda (widget)
               (and (widget-get widget :field-name)
                    (<= (widget-get widget :from) (point))
                    (>= (widget-get widget :to) (point))))
             omnigent-ui--widgets))
           (field-location
            (and field
                 (list
                  (widget-get field :request-id)
                  (widget-get field :field-name)
                  (- (point) (widget-get field :from)))))
           (start (marker-position omnigent-ui--request-start)))
      (dolist (widget omnigent-ui--widgets)
        (widget-delete widget))
      (setq omnigent-ui--widgets nil)
      (delete-region start omnigent-ui--pending-start)
      (goto-char start)
      (dolist (request (omnigent-conversation-elicitations))
        (omnigent-ui--request request))
      (set-marker omnigent-ui--request-start start)
      (widget-setup)
      (when buffer-read-only
        (dolist (widget omnigent-ui--widgets)
          (widget-apply widget :deactivate)))
      (omnigent-ui--restore-edit-hooks)
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
                      omnigent-ui--widgets)))
          (goto-char
           (min (widget-get replacement :to)
                (+ (widget-get replacement :from)
                   (nth 2 field-location))))))
      (set-marker position nil))))

(add-hook
 'omnigent-conversation-mode-hook #'omnigent-ui-conversation-setup)
(add-hook
 'omnigent-sessions-change-hook #'omnigent-ui-sessions-render)
(add-hook 'omnigent-sessions-frame-hook #'omnigent-ui--frame)
(add-hook 'window-selection-change-functions #'omnigent-ui--selection)
(add-hook
 'window-buffer-change-functions #'omnigent-ui--windows-changed)
(add-hook
 'window-configuration-change-hook #'omnigent-ui--windows-changed)

(provide 'omnigent-ui)
;;; omnigent-ui.el ends here
