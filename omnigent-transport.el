;;; omnigent-transport.el --- Omnigent HTTP, SSE, and WebSocket transport -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Package-Requires: ((emacs "27.1") (websocket "1.16"))

;;; Commentary:
;; Small REST, session-stream, and session-updates client for Omnigent.
;;
;; REST callbacks receive (STATUS BODY).  STATUS is the HTTP status code, or
;; url-retrieve's status plist when no HTTP response arrived.  BODY is parsed
;; JSON when possible, otherwise the raw response string.
;;
;; Stream event callbacks receive (EVENT-NAME DATA).  Snapshot callbacks use
;; the REST callback signature and run after each stream connection starts.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url)
(require 'url-util)

(defgroup omnigent-transport nil
  "Transport settings for Omnigent."
  :group 'applications)

(defcustom omnigent-server-url "http://127.0.0.1:6767"
  "Base URL of the Omnigent server."
  :type 'string
  :group 'omnigent-transport)

(defcustom omnigent-transport-session-limit 100
  "Maximum number of sessions to fetch, between 1 and 1000."
  :type 'integer
  :group 'omnigent-transport)

(defvar omnigent-transport--generation 0
  "Generation of the current server connection.")
(defvar omnigent-transport--streams nil
  "Session streams associated with the current server.")
(defvar omnigent-transport--updates nil
  "Session update connections associated with the current server.")

(defun omnigent-transport-reset ()
  "Stop connections and invalidate requests for the current server."
  (cl-incf omnigent-transport--generation)
  (mapc #'omnigent-transport-stop-session-stream omnigent-transport--streams)
  (mapc #'omnigent-transport-stop-session-updates omnigent-transport--updates)
  (setq omnigent-transport--streams nil
        omnigent-transport--updates nil))

(defcustom omnigent-transport-history-limit 5000
  "Maximum number of conversation items to keep."
  :type '(integer :tag "Items")
  :group 'omnigent-transport)
(defconst omnigent-transport--reconnect-min-delay 1.0)
(defconst omnigent-transport--reconnect-max-delay 15.0)

(cl-defstruct (omnigent-stream (:constructor omnigent-transport--make-stream))
  session-id event-callback snapshot-callback error-callback connect-callback process timer
  stopped failures attempt)

(cl-defstruct (omnigent-session-updates
               (:constructor omnigent-transport--make-session-updates))
  frame-callback error-callback open-callback websocket timer session-ids stopped failures
  attempt connected failed)

(defun omnigent-transport--url (path)
  "Return the server URL with PATH appended."
  (concat (string-remove-suffix "/" omnigent-server-url) path))

(defun omnigent-transport--session-path (session-id &optional suffix)
  "Return the API path for SESSION-ID with optional SUFFIX appended."
  (concat "/v1/sessions/" (url-hexify-string session-id) (or suffix "")))

(defun omnigent-transport--response-body ()
  "Return the current HTTP response body as parsed JSON or a raw string.
Return nil for an empty body."
  (let ((start (if (and (boundp 'url-http-end-of-headers)
                        (markerp url-http-end-of-headers))
                   (marker-position url-http-end-of-headers)
                 (save-excursion
                   (goto-char (point-min))
                   (if (re-search-forward "\r\n\r\n\\|\n\n" nil t)
                       (point)
                     (point-max))))))
    (goto-char start)
    (let ((raw (buffer-substring-no-properties (point) (point-max))))
      (if (string-empty-p raw)
          nil
        (condition-case nil
            (json-parse-string raw :object-type 'alist :array-type 'array
                               :null-object nil :false-object :json-false)
          (json-parse-error raw))))))

(defun omnigent-transport--url-callback (status callback generation)
  "Call CALLBACK with STATUS and the response for current GENERATION.
Use the HTTP status when available, and always kill the response buffer."
  (let ((response-buffer (current-buffer)))
    (unwind-protect
        (let ((http-status (and (boundp 'url-http-response-status)
                                 url-http-response-status)))
          (when (= generation omnigent-transport--generation)
            (funcall callback (or http-status status)
                     (omnigent-transport--response-body))))
      (when (buffer-live-p response-buffer)
        (kill-buffer response-buffer)))))

(defun omnigent-transport-request (method path callback &optional data)
  "Send METHOD to PATH and call CALLBACK with status and response body.

PATH is relative to `omnigent-server-url' and must start with `/'.  DATA,
when non-nil, is JSON-encoded.  CALLBACK receives (STATUS BODY)."
  (unless (string-prefix-p "/" path)
    (error "Omnigent API path must start with /: %s" path))
  (let ((url-request-method method)
        (url-request-extra-headers
         (when data '(("Content-Type" . "application/json"))))
        (url-request-data (when data
                            (encode-coding-string (json-encode data)
                                                  'utf-8))))
    (url-retrieve (omnigent-transport--url path)
                  #'omnigent-transport--url-callback
                  (list callback omnigent-transport--generation) t t)))

(defun omnigent-transport-get-session (session-id callback)
  "Get SESSION-ID and call CALLBACK with status and response body."
  (omnigent-transport-request "GET" (omnigent-transport--session-path session-id) callback))

(defun omnigent-transport-list-sessions (callback)
  "List sessions and call CALLBACK with status and response body."
  (omnigent-transport-request
   "GET" (format "/v1/sessions?limit=%d&include_archived=true&sort_by=updated_at&order=desc"
                 (max 1 (min 1000 omnigent-transport-session-limit)))
   callback))

(defun omnigent-transport-delete-session (session-id callback)
  "Delete SESSION-ID and call CALLBACK with status and response body."
  (omnigent-transport-request "DELETE"
                              (omnigent-transport--session-path session-id)
                              callback))

(defun omnigent-transport-list-child-sessions (parent-id callback)
  "List children of PARENT-ID and call CALLBACK with status and response body."
  (omnigent-transport-request "GET"
                    (omnigent-transport--session-path parent-id "/child_sessions")
                    callback))

(defun omnigent-transport-post-session-event (session-id event callback)
  "Post EVENT to SESSION-ID and call CALLBACK with status and response body."
  (omnigent-transport-request "POST"
                    (omnigent-transport--session-path session-id "/events")
                    callback event))

(defun omnigent-transport--split-sse-frames (pending chunk)
  "Return complete SSE frames and remainder from PENDING plus CHUNK."
  (let* ((input (concat pending chunk))
         (trailing-cr (string-suffix-p "\r" input))
         frames)
    (when trailing-cr
      (setq input (substring input 0 -1)))
    (setq input (replace-regexp-in-string "\r\n\\|\r" "\n" input))
    (when trailing-cr
      (setq input (concat input "\r")))
    (while (string-match "\n\n" input)
      (push (substring input 0 (match-beginning 0)) frames)
      (setq input (substring input (match-end 0))))
    (cons (nreverse frames) input)))

(defun omnigent-transport--parse-sse-frame (frame)
  "Parse FRAME and return (EVENT-NAME . DATA), or nil when it has no data."
  (let ((event "message") data)
    (dolist (line (split-string frame "\n" t))
      (unless (string-prefix-p ":" line)
        (let* ((colon (string-match ":" line))
               (field (if colon (substring line 0 colon) line))
               (value (if colon
                          (substring line (if (eq (aref line (1+ colon)) ?\s)
                                              (+ colon 2)
                                            (1+ colon)))
                        "")))
          (cond
           ((equal field "event") (setq event value))
           ((equal field "data") (push value data))))))
    (when data
      (cons event (mapconcat #'identity (nreverse data) "\n")))))

(defun omnigent-transport--notify-error (stream error)
  "Send ERROR to STREAM's error callback if it exists."
  (when (omnigent-stream-error-callback stream)
    (funcall (omnigent-stream-error-callback stream) error)))

(defun omnigent-transport--stream-filter (process chunk)
  "Parse SSE frames from PROCESS output CHUNK and deliver their events."
  (let* ((stream (process-get process 'omnigent-stream))
         (split (omnigent-transport--split-sse-frames
                 (or (process-get process 'omnigent-pending) "") chunk)))
    (process-put process 'omnigent-pending (cdr split))
    (dolist (frame (car split))
      (unless (or (omnigent-stream-stopped stream)
                  (process-get process 'omnigent-done))
        (let ((parsed (omnigent-transport--parse-sse-frame frame)))
          (when parsed
            (let ((data (cdr parsed)))
              (if (equal data "[DONE]")
                  (progn
                    (process-put process 'omnigent-done t)
                    (delete-process process))
                (condition-case err
                    (funcall (omnigent-stream-event-callback stream)
                             (car parsed)
                             (json-parse-string data :object-type 'alist
                                                :array-type 'array
                                                :null-object nil
                                                :false-object :json-false))
                  (error
                   (omnigent-transport--notify-error
                    stream (format "Invalid SSE JSON: %s"
                                   (error-message-string err)))))))))))))

(defun omnigent-transport--stream-command (session-id)
  "Return the curl command that streams events for SESSION-ID."
  (list (executable-find "curl") "--silent" "--show-error"
        "--no-buffer" "--fail"
        (omnigent-transport--url
         (concat (omnigent-transport--session-path session-id) "/stream"))))

(defun omnigent-transport--stream-snapshot (stream attempt status body)
  "Deliver snapshot STATUS and BODY for STREAM's current ATTEMPT."
  (when (and (not (omnigent-stream-stopped stream))
             (= attempt (omnigent-stream-attempt stream)))
    (funcall (omnigent-stream-snapshot-callback stream) status body)))

(defun omnigent-transport--stream-load-items (stream attempt body remaining before items)
  "Load item pages for STREAM and ATTEMPT into snapshot BODY.
REMAINING limits the number of items.  BEFORE is the pagination cursor;
ITEMS contains items already fetched in chronological order."
  (let* ((path (omnigent-transport--session-path (omnigent-stream-session-id stream)))
         (query (format "/items?limit=%d&order=desc" (min 1000 remaining))))
    (when before (setq query (concat query "&after=" (url-hexify-string before))))
    (omnigent-transport-request
     "GET" (concat path query)
     (lambda (status page)
       (when (and (not (omnigent-stream-stopped stream))
                  (= attempt (omnigent-stream-attempt stream)))
         (if (not (and (integerp status) (<= 200 status 299)))
             (omnigent-transport--stream-snapshot stream attempt status page)
           (let* ((data (append (alist-get 'data page) nil))
                  (remaining (- remaining (length data)))
                  (items (nconc (nreverse data) items))
                  (cursor (alist-get 'last_id page)))
             (if (and (> remaining 0) (eq (alist-get 'has_more page) t) cursor data)
                 (omnigent-transport--stream-load-items stream attempt body remaining cursor items)
               (setf (alist-get 'items body) (vconcat items))
               (omnigent-transport--stream-snapshot stream attempt status body)))))))))

(defun omnigent-transport--stream-load-snapshot (stream attempt)
  "Fetch session metadata and bounded item history for STREAM and ATTEMPT."
  (let ((path (omnigent-transport--session-path (omnigent-stream-session-id stream))))
    (omnigent-transport-request
     "GET" (concat path "?include_items=false")
     (lambda (status body)
       (when (and (not (omnigent-stream-stopped stream))
                  (= attempt (omnigent-stream-attempt stream)))
         (if (not (and (integerp status) (<= 200 status 299)))
             (omnigent-transport--stream-snapshot stream attempt status body)
           (omnigent-transport--stream-load-items
            stream attempt body (max 1 omnigent-transport-history-limit) nil nil)))))))

(defun omnigent-transport--reconnect-delay (failures)
  "Return the capped reconnect delay in seconds for FAILURES."
  (if (zerop failures)
      omnigent-transport--reconnect-min-delay
    (min omnigent-transport--reconnect-max-delay
         (* omnigent-transport--reconnect-min-delay (expt 2 (1- failures))))))

(defun omnigent-transport--stream-sentinel (process _event)
  "Handle PROCESS exit, report errors, and schedule reconnection.
Ignore _EVENT."
  (when (memq (process-status process) '(exit signal))
    (let* ((stream (process-get process 'omnigent-stream))
           (stderr (process-get process 'omnigent-stderr))
           (done (process-get process 'omnigent-done)))
      (when (buffer-live-p stderr)
        (unless (or done
                    (and stream (omnigent-stream-stopped stream))
                    (zerop (process-exit-status process)))
          (omnigent-transport--notify-error
           stream (with-current-buffer stderr (string-trim (buffer-string)))))
        (kill-buffer stderr))
      (when stream
        (setf (omnigent-stream-process stream) nil)
        (unless (omnigent-stream-stopped stream)
          (let ((failures (if (or done (zerop (process-exit-status process)))
                              0
                            (1+ (omnigent-stream-failures stream)))))
            (setf (omnigent-stream-failures stream) failures
                  (omnigent-stream-timer stream)
                  (run-at-time (omnigent-transport--reconnect-delay failures)
                               nil #'omnigent-transport--stream-connect stream))))))))

(defun omnigent-transport--stream-connect (stream)
  "Start STREAM's curl process and load a snapshot, or schedule a retry."
  (unless (omnigent-stream-stopped stream)
    (let* ((stderr (generate-new-buffer " *omnigent-curl-stderr*"))
           (attempt (1+ (omnigent-stream-attempt stream)))
           process)
      (setf (omnigent-stream-attempt stream) attempt)
      (condition-case err
          (setq process
                (make-process :name (format "omnigent-%s" (omnigent-stream-session-id stream))
                              :buffer nil
                              :stderr stderr
                              :command (omnigent-transport--stream-command
                                        (omnigent-stream-session-id stream))
                              :connection-type 'pipe
                              :coding 'utf-8-unix
                              :noquery t
                              :filter #'omnigent-transport--stream-filter
                              :sentinel #'omnigent-transport--stream-sentinel))
        (error
            (when (buffer-live-p stderr) (kill-buffer stderr))
         (omnigent-transport--notify-error stream (error-message-string err))
         (setf (omnigent-stream-failures stream)
               (1+ (omnigent-stream-failures stream))
               (omnigent-stream-timer stream)
               (run-at-time
                (omnigent-transport--reconnect-delay (omnigent-stream-failures stream))
                nil #'omnigent-transport--stream-connect stream))))
      (when process
        (when (omnigent-stream-connect-callback stream)
          (funcall (omnigent-stream-connect-callback stream)))
        (process-put process 'omnigent-stream stream)
        (process-put process 'omnigent-stderr stderr)
        (setf (omnigent-stream-process stream) process)
        (omnigent-transport--stream-load-snapshot stream attempt)))))

(defun omnigent-transport-start-session-stream (session-id on-event on-snapshot &optional on-error on-connect)
  "Start the SSE stream for SESSION-ID.

ON-EVENT receives (EVENT-NAME DATA).  ON-SNAPSHOT receives (STATUS BODY)
after each stream connection starts.  ON-ERROR, when non-nil, receives an
error string.  ON-CONNECT runs before each snapshot request.
Return a stream handle for `omnigent-transport-stop-session-stream'."
  (unless (executable-find "curl")
    (user-error "Omnigent session streams require curl"))
  (let ((stream (omnigent-transport--make-stream
                 :session-id session-id :event-callback on-event
                 :snapshot-callback on-snapshot :error-callback on-error
                 :connect-callback on-connect :stopped nil :failures 0 :attempt 0)))
    (push stream omnigent-transport--streams)
    (omnigent-transport--stream-connect stream)
    stream))

(defun omnigent-transport-stop-session-stream (stream)
  "Stop STREAM and prevent automatic reconnection."
  (setf (omnigent-stream-stopped stream) t)
  (setq omnigent-transport--streams (delq stream omnigent-transport--streams))
  (when (timerp (omnigent-stream-timer stream))
    (cancel-timer (omnigent-stream-timer stream)))
  (when (process-live-p (omnigent-stream-process stream))
    (delete-process (omnigent-stream-process stream))))

(defun omnigent-transport--updates-url ()
  "Return the WebSocket URL for session updates on the current server."
  (unless (string-match-p "\\`https?://" omnigent-server-url)
    (user-error "Omnigent WebSocket URL must start with http:// or https://"))
  (concat (if (string-prefix-p "https://" omnigent-server-url) "wss" "ws")
          (substring (string-remove-suffix "/" omnigent-server-url)
                     (if (string-prefix-p "https://" omnigent-server-url) 5 4))
          "/v1/sessions/updates"))

(defun omnigent-transport--updates-current-p (updates attempt)
  "Return non-nil if ATTEMPT is current and UPDATES has not stopped."
  (and (not (omnigent-session-updates-stopped updates))
       (= attempt (omnigent-session-updates-attempt updates))))

(defun omnigent-transport--updates-notify-error (updates error)
  "Send ERROR to UPDATES' error callback, ignoring callback errors."
  (when (omnigent-session-updates-error-callback updates)
    (condition-case nil
        (funcall (omnigent-session-updates-error-callback updates) error)
      (error nil))))

(defun omnigent-transport--updates-send-watch (updates websocket attempt)
  "Send UPDATES' watch set on WEBSOCKET for the current ATTEMPT."
  (when (and (omnigent-transport--updates-current-p updates attempt)
             (websocket-openp websocket))
    (condition-case err
        (websocket-send-text
         websocket
         (json-encode `(("type" . "watch")
                        ("session_ids" . ,(vconcat
                                            (omnigent-session-updates-session-ids
                                             updates))))))
      (error
       (setf (omnigent-session-updates-failed updates) t)
       (omnigent-transport--updates-notify-error
        updates (error-message-string err))
       (ignore-errors (websocket-close websocket))))))

(defun omnigent-transport--updates-schedule-reconnect (updates delay)
  "Schedule UPDATES to reconnect after DELAY seconds if not already scheduled."
  (unless (or (omnigent-session-updates-stopped updates)
              (timerp (omnigent-session-updates-timer updates)))
    (setf (omnigent-session-updates-timer updates)
          (run-at-time delay nil
                       #'omnigent-transport--updates-connect updates))))

(defun omnigent-transport--updates-opened (updates websocket attempt)
  "Record an open WEBSOCKET for UPDATES and ATTEMPT, then send the watch set."
  (when (omnigent-transport--updates-current-p updates attempt)
    (setf (omnigent-session-updates-websocket updates) websocket
          (omnigent-session-updates-connected updates) t
          (omnigent-session-updates-failed updates) nil
          (omnigent-session-updates-failures updates) 0)
    (omnigent-transport--updates-send-watch updates websocket attempt)
    (when (omnigent-session-updates-open-callback updates)
      (funcall (omnigent-session-updates-open-callback updates)))))

(defun omnigent-transport--updates-message (updates websocket attempt frame)
  "Parse FRAME from WEBSOCKET and deliver it for UPDATES' current ATTEMPT."
  (when (omnigent-transport--updates-current-p updates attempt)
    (let ((data
           (condition-case err
               (json-parse-string (websocket-frame-text frame)
                                  :object-type 'alist :array-type 'array
                                  :null-object nil :false-object :json-false)
             (error
              (omnigent-transport--updates-notify-error
               updates (format "Invalid WebSocket JSON: %s"
                               (error-message-string err)))
              :invalid))))
      (unless (eq data :invalid)
        (funcall (omnigent-session-updates-frame-callback updates) data)))))

(defun omnigent-transport--updates-error (updates attempt _websocket type err)
  "Report WebSocket error TYPE and ERR for UPDATES' current ATTEMPT.
Ignore _WEBSOCKET."
  (when (omnigent-transport--updates-current-p updates attempt)
    (setf (omnigent-session-updates-failed updates) t)
    (omnigent-transport--updates-notify-error
     updates (format "WebSocket %s: %s" type (error-message-string err)))))

(defun omnigent-transport--updates-closed (updates attempt _websocket)
  "Schedule reconnection after UPDATES' current ATTEMPT closes.
Ignore _WEBSOCKET."
  (when (omnigent-transport--updates-current-p updates attempt)
    (setf (omnigent-session-updates-websocket updates) nil)
    (let ((failed (or (omnigent-session-updates-failed updates)
                      (not (omnigent-session-updates-connected updates)))))
      (setf (omnigent-session-updates-failures updates)
            (if failed (1+ (omnigent-session-updates-failures updates)) 0)
            (omnigent-session-updates-connected updates) nil
            (omnigent-session-updates-failed updates) nil)
      (omnigent-transport--updates-schedule-reconnect
       updates (omnigent-transport--reconnect-delay
                (omnigent-session-updates-failures updates))))))

(defun omnigent-transport--updates-connect (updates)
  "Open the WebSocket for UPDATES, or schedule a retry on failure."
  (unless (omnigent-session-updates-stopped updates)
    (setf (omnigent-session-updates-timer updates) nil)
    (let* ((attempt (1+ (omnigent-session-updates-attempt updates)))
           websocket)
      (setf (omnigent-session-updates-attempt updates) attempt
            (omnigent-session-updates-connected updates) nil
            (omnigent-session-updates-failed updates) nil)
      (condition-case err
          (setq websocket
                (websocket-open
                 (omnigent-transport--updates-url)
                 :nowait t
                 :on-open (lambda (ws)
                            (omnigent-transport--updates-opened
                             updates ws attempt))
                 :on-message (lambda (ws frame)
                               (omnigent-transport--updates-message
                                updates ws attempt frame))
                 :on-close (lambda (ws)
                             (omnigent-transport--updates-closed
                              updates attempt ws))
                 :on-error (lambda (ws type error)
                             (omnigent-transport--updates-error
                              updates attempt ws type error))))
        (error
         (setf (omnigent-session-updates-failures updates)
               (1+ (omnigent-session-updates-failures updates)))
         (omnigent-transport--updates-notify-error
          updates (error-message-string err))
         (omnigent-transport--updates-schedule-reconnect
          updates (omnigent-transport--reconnect-delay
                   (omnigent-session-updates-failures updates)))))
      (when websocket
        (setf (omnigent-session-updates-websocket updates) websocket)))))

(defun omnigent-transport-start-session-updates (on-frame &optional on-error on-open)
  "Connect to the session-updates WebSocket.

ON-FRAME receives each parsed JSON frame.  ON-ERROR, when non-nil, receives
an error string.  ON-OPEN, when non-nil, runs after each connection opens.
Return a handle for `omnigent-transport-stop-session-updates'."
  (unless (require 'websocket nil t)
    (user-error "Session updates require the websocket package from GNU ELPA"))
  (omnigent-transport--updates-url)
  (let ((updates (omnigent-transport--make-session-updates
                  :frame-callback on-frame :error-callback on-error :open-callback on-open
                  :session-ids nil :stopped nil :failures 0 :attempt 0)))
    (push updates omnigent-transport--updates)
    (omnigent-transport--updates-connect updates)
    updates))

(defun omnigent-transport-set-session-updates-watch (updates session-ids)
  "Set UPDATES' watched SESSION-IDS and send the full set to the server.
SESSION-IDS must be a list of at most 500 strings."
  (unless (and (listp session-ids) (<= (length session-ids) 500)
               (cl-every #'stringp session-ids))
    (user-error "Session watch must be a list of at most 500 session IDs"))
  (setf (omnigent-session-updates-session-ids updates) (copy-sequence session-ids))
  (when (omnigent-session-updates-websocket updates)
    (omnigent-transport--updates-send-watch
     updates (omnigent-session-updates-websocket updates)
     (omnigent-session-updates-attempt updates))))

(defun omnigent-transport-stop-session-updates (updates)
  "Stop UPDATES and prevent automatic reconnection."
  (setf (omnigent-session-updates-stopped updates) t)
  (setq omnigent-transport--updates (delq updates omnigent-transport--updates))
  (when (timerp (omnigent-session-updates-timer updates))
    (cancel-timer (omnigent-session-updates-timer updates)))
  (let ((websocket (omnigent-session-updates-websocket updates)))
    (setf (omnigent-session-updates-websocket updates) nil)
    (when websocket
      (ignore-errors (websocket-close websocket)))))

(provide 'omnigent-transport)
;;; omnigent-transport.el ends here
