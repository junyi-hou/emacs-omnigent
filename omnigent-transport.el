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
(require 'omnigent-options)

(defvar omnigent-transport--generation 0
  "Generation of the current server connection.")
(defvar omnigent-transport--streams nil
  "Session streams associated with the current server.")
(defvar omnigent-transport--updates nil
  "Session update connections associated with the current server.")

(defun omnigent-transport-reset ()
  "Stop connections and invalidate requests for the current server."
  (cl-incf omnigent-transport--generation)
  (mapc
   #'omnigent-transport-stop-session-stream
   omnigent-transport--streams)
  (mapc
   #'omnigent-transport-stop-session-updates
   omnigent-transport--updates)
  (setq
   omnigent-transport--streams nil
   omnigent-transport--updates nil))

(defconst omnigent-transport--watchdog-interval 5
  "Seconds between connection liveness checks.")
(defconst omnigent-transport--reconnect-min-delay 1.0)
(defconst omnigent-transport--reconnect-max-delay 15.0)

(cl-defstruct
 (omnigent-stream (:constructor omnigent-transport--make-stream))
 session-id
 event-callback
 snapshot-callback
 error-callback
 connect-callback
 process
 timer
 stopped
 failures
 attempt
 state-callback
 ready
 last-activity
 last-check
 watchdog
 snapshot-active
 snapshot-timer
 snapshot-again)

(cl-defstruct
 (omnigent-session-updates
  (:constructor omnigent-transport--make-session-updates))
 frame-callback
 error-callback
 open-callback
 websocket
 timer
 session-ids
 stopped
 failures
 attempt
 connected
 failed
 last-activity
 last-check
 watchdog)

(defun omnigent-transport--url (path)
  "Return the server URL with PATH appended."
  (concat (string-remove-suffix "/" omnigent-server-url) path))

(defun omnigent-transport--session-path (session-id &optional suffix)
  "Return the API path for SESSION-ID with optional SUFFIX appended."
  (concat
   "/v1/sessions/" (url-hexify-string session-id) (or suffix "")))

(defun omnigent-transport--response-body ()
  "Return the current HTTP response body as parsed JSON or a raw string.
Return nil for an empty body."
  (let ((start
         (if (and (boundp 'url-http-end-of-headers)
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
            (json-parse-string raw
                               :object-type 'alist
                               :array-type 'array
                               :null-object nil
                               :false-object
                               :json-false)
          (json-parse-error
           raw))))))

(defun omnigent-transport--url-callback (status callback generation)
  "Call CALLBACK with STATUS and the response for current GENERATION.
Use the HTTP status when available, and always kill the response buffer."
  (let ((response-buffer (current-buffer)))
    (unwind-protect
        (let ((http-status
               (and (boundp 'url-http-response-status)
                    url-http-response-status)))
          (when (= generation omnigent-transport--generation)
            (funcall callback
                     (or http-status status)
                     (omnigent-transport--response-body))))
      (when (buffer-live-p response-buffer)
        (kill-buffer response-buffer)))))

(defun omnigent-transport-request
    (method path callback &optional data)
  "Send METHOD to PATH and call CALLBACK with status and response body.

PATH is relative to `omnigent-server-url' and must start with `/'.  DATA,
when non-nil, is JSON-encoded.  CALLBACK receives (STATUS BODY)."
  (unless (string-prefix-p "/" path)
    (error "Omnigent API path must start with /: %s" path))
  (let ((url-request-method method)
        (url-request-extra-headers
         (when data
           '(("Content-Type" . "application/json"))))
        (url-request-data
         (when data
           (encode-coding-string (json-encode data) 'utf-8))))
    (url-retrieve
     (omnigent-transport--url path)
     #'omnigent-transport--url-callback
     (list callback omnigent-transport--generation)
     t
     t)))

(defun omnigent-transport-success-p (status)
  "Return non-nil when STATUS is an HTTP success code from 200 through 299."
  (and (integerp status) (<= 200 status 299)))

(defun omnigent-transport-error-message (action status body)
  "Describe ACTION's failure STATUS with diagnostics from BODY.
Prefer server `detail' or `error' fields; otherwise retain the response body.
A nil STATUS identifies a client-side processing failure.  This function
only formats text; the caller decides how to present it."
  (let ((detail
         (or (and (listp body)
                  (or (alist-get 'detail body)
                      (alist-get 'error body)))
             body)))
    (format "%s: %s%s"
            action (or status "client error")
            (if (or (null detail) (equal detail ""))
                ""
              (format " (%s)" detail)))))

(defun omnigent-transport-get-session (session-id callback)
  "Get SESSION-ID and call CALLBACK with status and response body."
  (omnigent-transport-request
   "GET"
   (omnigent-transport--session-path session-id) callback))

(defun omnigent-transport-set-session-model
    (session-id model callback)
  "Set SESSION-ID's MODEL and call CALLBACK with status and response body."
  (omnigent-transport-request
   "PATCH" (omnigent-transport--session-path session-id) callback
   `(("model_override" . ,model))))

(defun omnigent-transport-set-session-effort
    (session-id effort callback)
  "Set SESSION-ID's reasoning EFFORT and call CALLBACK with status and body."
  (omnigent-transport-request
   "PATCH" (omnigent-transport--session-path session-id) callback
   `(("reasoning_effort" . ,effort))))

(defun omnigent-transport-list-sessions (callback)
  "List sessions and call CALLBACK with status and response body."
  (omnigent-transport-request
   "GET"
   (format
    "/v1/sessions?limit=%d&include_archived=true&sort_by=updated_at&order=desc"
    (max 1 (min 1000 omnigent-transport-session-limit)))
   callback))

(defun omnigent-transport-set-session-archived
    (session-id archived callback)
  "Set SESSION-ID's ARCHIVED state and call CALLBACK with status and body."
  (omnigent-transport-request
   "PATCH"
   (omnigent-transport--session-path session-id)
   callback
   `(("archived" .
      ,(if archived
           t
         :json-false)))))

(defun omnigent-transport-generate-session-title
    (session-id instructions callback)
  "Request a generated title for SESSION-ID with INSTRUCTIONS.
Call CALLBACK with the result."
  (omnigent-transport-request
   "PATCH" (omnigent-transport--session-path session-id) callback
   `(("generate_title" . t)
     ("session_title_instructions" . ,instructions))))

(defun omnigent-transport-delete-session (session-id callback)
  "Delete SESSION-ID and call CALLBACK with status and response body."
  (omnigent-transport-request
   "DELETE" (omnigent-transport--session-path session-id) callback))

(defun omnigent-transport-list-child-sessions (parent-id callback)
  "List children of PARENT-ID and call CALLBACK with status and response body."
  (omnigent-transport-request
   "GET"
   (omnigent-transport--session-path parent-id
                                     "/child_sessions")
   callback))

(defun omnigent-transport-post-session-event
    (session-id event callback)
  "Post EVENT to SESSION-ID and call CALLBACK with status and response body."
  (omnigent-transport-request "POST"
                              (omnigent-transport--session-path
                               session-id
                               "/events")
                              callback
                              event))

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
  (let ((event "message")
        data)
    (dolist (line (split-string frame "\n" t))
      (unless (string-prefix-p ":" line)
        (let* ((colon (string-match ":" line))
               (field
                (if colon
                    (substring line 0 colon)
                  line))
               (value
                (if colon
                    (substring line
                               (if (and (< (1+ colon) (length line))
                                        (eq
                                         (aref line (1+ colon)) ?\s))
                                   (+ colon 2)
                                 (1+ colon)))
                  "")))
          (cond
           ((equal field "event")
            (setq event value))
           ((equal field "data")
            (push value data))))))
    (when data
      (cons event (mapconcat #'identity (nreverse data) "\n")))))

(defun omnigent-transport--notify-error (stream error)
  "Send ERROR to STREAM's error callback without interrupting recovery."
  (when (omnigent-stream-error-callback stream)
    (condition-case err
        (funcall (omnigent-stream-error-callback stream) error)
      (error
       (display-warning
        'omnigent
        (format "Stream error callback failed: %s"
                (error-message-string err)))))))

(defun omnigent-transport--stream-filter (process chunk)
  "Parse SSE frames from PROCESS output CHUNK and deliver their events."
  (let* ((stream (process-get process 'omnigent-stream))
         (split
          (omnigent-transport--split-sse-frames
           (or (process-get process 'omnigent-pending) "") chunk)))
    (when (and (eq process (omnigent-stream-process stream))
               (not (omnigent-stream-stopped stream)))
      (setf (omnigent-stream-last-activity stream) (float-time)))
    (process-put process 'omnigent-pending (cdr split))
    (dolist (frame (car split))
      (unless (or (omnigent-stream-stopped stream)
                  (not (eq process (omnigent-stream-process stream)))
                  (process-get process 'omnigent-done))
        (unless (omnigent-stream-ready stream)
          (setf (omnigent-stream-ready stream) t)
          (omnigent-transport--stream-state stream 'connected))
        (let ((parsed (omnigent-transport--parse-sse-frame frame)))
          (when parsed
            (let ((data (cdr parsed)))
              (if (equal data "[DONE]")
                  (progn
                    (process-put process 'omnigent-done t)
                    (delete-process process))
                (let ((payload
                       (condition-case err
                           (json-parse-string
                            data
                            :object-type 'alist
                            :array-type 'array
                            :null-object nil
                            :false-object
                            :json-false)
                         (error
                          (omnigent-transport--notify-error
                           stream
                           (format "Invalid SSE JSON: %s"
                                   (error-message-string err)))
                          :invalid))))
                  (unless (eq payload :invalid)
                    (funcall (omnigent-stream-event-callback stream)
                             (car parsed)
                             payload)))))))))))

(defun omnigent-transport--stream-command (session-id)
  "Return the curl command that streams events for SESSION-ID."
  (list
   (executable-find "curl")
   "--silent"
   "--show-error"
   "--no-buffer"
   "--fail"
   (omnigent-transport--url
    (concat
     (omnigent-transport--session-path session-id) "/stream"))))

(defun omnigent-transport--snapshot-current-p
    (stream attempt operation)
  "Return non-nil for STREAM's active ATTEMPT and snapshot OPERATION."
  (and (not (omnigent-stream-stopped stream))
       (= attempt (omnigent-stream-attempt stream))
       (eq operation (omnigent-stream-snapshot-active stream))))

(defun omnigent-transport--cancel-snapshot (stream)
  "Invalidate STREAM's composite read and cancel its deadline."
  (when (timerp (omnigent-stream-snapshot-timer stream))
    (cancel-timer (omnigent-stream-snapshot-timer stream)))
  (setf
   (omnigent-stream-snapshot-active stream) nil
   (omnigent-stream-snapshot-timer stream) nil
   (omnigent-stream-snapshot-again stream) nil))

(defun omnigent-transport--stream-snapshot
    (stream attempt status body &optional operation)
  "Deliver snapshot STATUS and BODY for STREAM's ATTEMPT and OPERATION once."
  (when (and (not (omnigent-stream-stopped stream))
             (= attempt (omnigent-stream-attempt stream))
             (or (null operation)
                 (eq
                  operation
                  (omnigent-stream-snapshot-active stream))))
    (let ((again (omnigent-stream-snapshot-again stream)))
      ;; Keep the operation active through the consumer: replay may request refresh.
      (when (timerp (omnigent-stream-snapshot-timer stream))
        (cancel-timer (omnigent-stream-snapshot-timer stream)))
      (unwind-protect
          (funcall (omnigent-stream-snapshot-callback stream)
                   status
                   body)
        (setq again
              (or again (omnigent-stream-snapshot-again stream)))
        (omnigent-transport--cancel-snapshot stream))
      (when (and again
                 (omnigent-transport-success-p status)
                 (not (omnigent-stream-stopped stream)))
        (omnigent-transport-refresh-session-stream stream)))))

(defun omnigent-transport--snapshot-timeout (stream attempt operation)
  "Fail STREAM's current snapshot OPERATION on ATTEMPT after its deadline."
  (when (omnigent-transport--snapshot-current-p
         stream attempt operation)
    (omnigent-transport--stream-snapshot
     stream attempt nil "Session snapshot timed out"
     operation)))

(defun omnigent-transport--stream-load-items
    (stream attempt operation body remaining before items)
  "Load bounded history for STREAM's ATTEMPT and OPERATION into BODY.
REMAINING limits items; BEFORE is the cursor and ITEMS is chronological."
  (let* ((path
          (omnigent-transport--session-path
           (omnigent-stream-session-id stream)))
         (query
          (format "/items?limit=%d&order=desc" (min 1000 remaining))))
    (when before
      (setq query
            (concat query "&after=" (url-hexify-string before))))
    (omnigent-transport-request
     "GET" (concat path query)
     (lambda (status page)
       (when (omnigent-transport--snapshot-current-p
              stream attempt operation)
         (cond
          ((not (omnigent-transport-success-p status))
           (omnigent-transport--stream-snapshot
            stream attempt status page
            operation))
          ((not
            (and (listp page)
                 (vectorp (alist-get 'data page))
                 (memq (alist-get 'has_more page) '(t :json-false))
                 (<= (length (alist-get 'data page))
                     (min 1000 remaining))
                 (or (not (eq (alist-get 'has_more page) t))
                     (and (> (length (alist-get 'data page)) 0)
                          (stringp (alist-get 'last_id page))
                          (not
                           (string-empty-p (alist-get 'last_id page)))
                          (not
                           (equal
                            before (alist-get 'last_id page)))))))
           (omnigent-transport--stream-snapshot
            stream attempt nil "Invalid session history page"
            operation))
          (t
           (let* ((data (append (alist-get 'data page) nil))
                  (remaining (- remaining (length data)))
                  (items (nconc (nreverse data) items))
                  (cursor (alist-get 'last_id page)))
             (if (and (> remaining 0)
                      (eq (alist-get 'has_more page) t))
                 (condition-case err
                     (omnigent-transport--stream-load-items
                      stream
                      attempt
                      operation
                      body
                      remaining
                      cursor
                      items)
                   (error
                    (if (omnigent-transport--snapshot-current-p
                         stream attempt operation)
                        (omnigent-transport--stream-snapshot
                         stream attempt nil (error-message-string err)
                         operation)
                      (signal (car err) (cdr err)))))
               (setf (alist-get 'items body) (vconcat items))
               (omnigent-transport--stream-snapshot
                stream attempt status body
                operation))))))))))

(defun omnigent-transport--stream-load-snapshot (stream attempt)
  "Start one composite snapshot for STREAM and ATTEMPT, coalescing refreshes."
  (if (omnigent-stream-snapshot-active stream)
      (setf (omnigent-stream-snapshot-again stream) t)
    (let ((operation (make-symbol "snapshot"))
          (path
           (omnigent-transport--session-path
            (omnigent-stream-session-id stream))))
      (setf
       (omnigent-stream-snapshot-active stream) operation
       (omnigent-stream-snapshot-timer stream)
       (run-at-time omnigent-transport-snapshot-timeout
                    nil
                    #'omnigent-transport--snapshot-timeout
                    stream
                    attempt
                    operation))
      (when (omnigent-stream-connect-callback stream)
        (funcall (omnigent-stream-connect-callback stream)))
      (condition-case err
          (omnigent-transport-request
           "GET" (concat path "?include_items=false")
           (lambda (status body)
             (when (omnigent-transport--snapshot-current-p
                    stream attempt operation)
               (cond
                ((not (omnigent-transport-success-p status))
                 (omnigent-transport--stream-snapshot
                  stream attempt status body
                  operation))
                ((not (listp body))
                 (omnigent-transport--stream-snapshot
                  stream attempt nil "Invalid session metadata"
                  operation))
                (t
                 (condition-case setup-error
                     (omnigent-transport--stream-load-items
                      stream
                      attempt
                      operation
                      body
                      (max 1 omnigent-transport-history-limit)
                      nil
                      nil)
                   (error
                    (if (omnigent-transport--snapshot-current-p
                         stream attempt operation)
                        (omnigent-transport--stream-snapshot
                         stream
                         attempt
                         nil
                         (error-message-string setup-error)
                         operation)
                      (signal (car setup-error)
                              (cdr setup-error))))))))))
        (error
         (if (omnigent-transport--snapshot-current-p
              stream attempt operation)
             (omnigent-transport--stream-snapshot
              stream attempt nil (error-message-string err)
              operation)
           (signal (car err) (cdr err))))))))

(defun omnigent-transport--reconnect-delay (failures)
  "Return the capped reconnect delay in seconds for FAILURES."
  (if (zerop failures)
      omnigent-transport--reconnect-min-delay
    (min omnigent-transport--reconnect-max-delay
         (* omnigent-transport--reconnect-min-delay
            (expt 2 (1- failures))))))

(defun omnigent-transport--stream-state (stream state)
  "Notify STREAM's owner of connection STATE."
  (when (omnigent-stream-state-callback stream)
    (funcall (omnigent-stream-state-callback stream) state)))

(defun omnigent-transport--stream-watchdog (stream attempt)
  "Reconnect STREAM's ATTEMPT after silence or a long scheduling gap."
  (when (and (not (omnigent-stream-stopped stream))
             (= attempt (omnigent-stream-attempt stream)))
    (let* ((now (float-time))
           (gap (- now (omnigent-stream-last-check stream)))
           (idle (- now (omnigent-stream-last-activity stream))))
      (setf (omnigent-stream-last-check stream) now)
      (when (or (> gap (* 3 omnigent-transport--watchdog-interval))
                (> idle
                   (if (omnigent-stream-ready stream)
                       omnigent-transport-inactivity-timeout
                     omnigent-transport-connect-timeout)))
        (omnigent-transport--notify-error
         stream "Session stream disconnected or inactive")
        (when (process-live-p (omnigent-stream-process stream))
          (delete-process (omnigent-stream-process stream)))))))

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
           stream
           (with-current-buffer stderr
             (string-trim (buffer-string)))))
        (kill-buffer stderr))
      (when (and stream (eq process (omnigent-stream-process stream)))
        (when (timerp (omnigent-stream-watchdog stream))
          (cancel-timer (omnigent-stream-watchdog stream)))
        (omnigent-transport--cancel-snapshot stream)
        (setf
         (omnigent-stream-process stream) nil
         (omnigent-stream-ready stream) nil
         (omnigent-stream-watchdog stream) nil)
        (omnigent-transport--stream-state stream 'disconnected)
        (unless (omnigent-stream-stopped stream)
          (let ((failures
                 (if (or done (zerop (process-exit-status process)))
                     0
                   (1+ (omnigent-stream-failures stream)))))
            (setf
             (omnigent-stream-failures stream) failures
             (omnigent-stream-timer stream)
             (run-at-time (omnigent-transport--reconnect-delay
                           failures)
                          nil #'omnigent-transport--stream-connect
                          stream))))))))

(defun omnigent-transport--stream-connect (stream)
  "Start STREAM's curl process and load a snapshot, or schedule a retry."
  (unless (or (omnigent-stream-stopped stream)
              (process-live-p (omnigent-stream-process stream)))
    (when (timerp (omnigent-stream-timer stream))
      (cancel-timer (omnigent-stream-timer stream)))
    (setf (omnigent-stream-timer stream) nil)
    (when (timerp (omnigent-stream-watchdog stream))
      (cancel-timer (omnigent-stream-watchdog stream)))
    (omnigent-transport--cancel-snapshot stream)
    (omnigent-transport--stream-state stream 'connecting)
    (let* ((stderr (generate-new-buffer " *omnigent-curl-stderr*"))
           (attempt (1+ (omnigent-stream-attempt stream)))
           process)
      (setf (omnigent-stream-attempt stream) attempt)
      (condition-case err
          (setq process
                (make-process
                 :name
                 (format "omnigent-%s"
                         (omnigent-stream-session-id stream))
                 :buffer nil
                 :stderr stderr
                 :command
                 (omnigent-transport--stream-command
                  (omnigent-stream-session-id stream))
                 :connection-type 'pipe
                 :coding 'utf-8-unix
                 :noquery t
                 :filter #'omnigent-transport--stream-filter
                 :sentinel #'omnigent-transport--stream-sentinel))
        (error
         (when (buffer-live-p stderr)
           (kill-buffer stderr))
         (omnigent-transport--notify-error
          stream (error-message-string err))
         (setf (omnigent-stream-failures stream)
               (1+ (omnigent-stream-failures stream))
               (omnigent-stream-timer stream)
               (run-at-time (omnigent-transport--reconnect-delay
                             (omnigent-stream-failures stream))
                            nil #'omnigent-transport--stream-connect
                            stream))))
      (when process
        (process-put process 'omnigent-stream stream)
        (process-put process 'omnigent-stderr stderr)
        (setf
         (omnigent-stream-process stream) process
         (omnigent-stream-ready stream) nil
         (omnigent-stream-last-check stream) (float-time)
         (omnigent-stream-last-activity stream) (float-time)
         (omnigent-stream-watchdog stream)
         (run-at-time omnigent-transport--watchdog-interval
                      omnigent-transport--watchdog-interval
                      #'omnigent-transport--stream-watchdog
                      stream
                      attempt))
        (omnigent-transport--stream-load-snapshot stream attempt)))))

(defun omnigent-transport-start-session-stream
    (session-id
     on-event on-snapshot &optional on-error on-connect on-state)
  "Start the SSE stream for SESSION-ID.

ON-EVENT receives (EVENT-NAME DATA).  ON-SNAPSHOT receives (STATUS BODY)
after each stream connection starts.  ON-ERROR, when non-nil, receives an
error string.  ON-CONNECT runs before each snapshot request.
ON-STATE receives `connecting', `connected', or `disconnected'.  Connected
means live traffic arrived, not that the snapshot/event handoff is gap-free.
Return a stream handle for `omnigent-transport-stop-session-stream'."
  (unless (executable-find "curl")
    (user-error "Omnigent session streams require curl"))
  (let ((stream
         (omnigent-transport--make-stream
          :session-id session-id
          :event-callback on-event
          :snapshot-callback on-snapshot
          :error-callback on-error
          :connect-callback on-connect
          :state-callback on-state
          :stopped nil
          :failures 0
          :attempt 0)))
    (push stream omnigent-transport--streams)
    (omnigent-transport--stream-connect stream)
    stream))

(defun omnigent-transport-refresh-session-stream (stream)
  "Reload STREAM's snapshot without restarting its live SSE subscription.
Coalesce requests while a snapshot is active.  Reconnection invalidates
this read through the stream attempt number."
  (unless (omnigent-stream-stopped stream)
    (omnigent-transport--stream-load-snapshot
     stream (omnigent-stream-attempt stream))))

(defun omnigent-transport-stop-session-stream (stream)
  "Stop STREAM and prevent automatic reconnection."
  (setf (omnigent-stream-stopped stream) t)
  (omnigent-transport--cancel-snapshot stream)
  (when (timerp (omnigent-stream-watchdog stream))
    (cancel-timer (omnigent-stream-watchdog stream)))
  (setf (omnigent-stream-watchdog stream) nil)
  (setq omnigent-transport--streams
        (delq stream omnigent-transport--streams))
  (when (timerp (omnigent-stream-timer stream))
    (cancel-timer (omnigent-stream-timer stream)))
  (when (process-live-p (omnigent-stream-process stream))
    (delete-process (omnigent-stream-process stream))))

(defun omnigent-transport--updates-url ()
  "Return the WebSocket URL for session updates on the current server."
  (unless (string-match-p "\\`https?://" omnigent-server-url)
    (user-error
     "Omnigent WebSocket URL must start with http:// or https://"))
  (concat
   (if (string-prefix-p "https://" omnigent-server-url)
       "wss"
     "ws")
   (substring (string-remove-suffix "/" omnigent-server-url)
              (if (string-prefix-p "https://" omnigent-server-url)
                  5
                4))
   "/v1/sessions/updates"))

(defun omnigent-transport--updates-current-p (updates attempt)
  "Return non-nil if ATTEMPT is current and UPDATES has not stopped."
  (and (not (omnigent-session-updates-stopped updates))
       (= attempt (omnigent-session-updates-attempt updates))))

(defun omnigent-transport--updates-notify-error (updates error)
  "Send ERROR to UPDATES' error callback, ignoring callback errors."
  (when (omnigent-session-updates-error-callback updates)
    (condition-case nil
        (funcall (omnigent-session-updates-error-callback updates)
                 error)
      (error
       nil))))

(defun omnigent-transport--updates-send-watch
    (updates websocket attempt)
  "Send UPDATES' watch set on WEBSOCKET for the current ATTEMPT."
  (when (and (omnigent-transport--updates-current-p updates attempt)
             (websocket-openp websocket))
    (condition-case err
        (websocket-send-text
         websocket
         (json-encode
          `(("type" . "watch")
            ("session_ids" .
             ,(vconcat
               (omnigent-session-updates-session-ids updates))))))
      (error
       (setf (omnigent-session-updates-failed updates) t)
       (omnigent-transport--updates-notify-error
        updates (error-message-string err))
       (ignore-errors
         (websocket-close websocket))))))

(defun omnigent-transport--updates-schedule-reconnect (updates delay)
  "Schedule UPDATES to reconnect after DELAY seconds if not already scheduled."
  (unless (or (omnigent-session-updates-stopped updates)
              (timerp (omnigent-session-updates-timer updates)))
    (setf (omnigent-session-updates-timer updates)
          (run-at-time delay nil #'omnigent-transport--updates-connect
                       updates))))

(defun omnigent-transport--updates-watchdog (updates attempt)
  "Reconnect UPDATES' ATTEMPT after inactivity or a long scheduling gap."
  (when (omnigent-transport--updates-current-p updates attempt)
    (let* ((now (float-time))
           (gap (- now (omnigent-session-updates-last-check updates)))
           (idle
            (- now (omnigent-session-updates-last-activity updates))))
      (setf (omnigent-session-updates-last-check updates) now)
      (when (or (> gap (* 3 omnigent-transport--watchdog-interval))
                (> idle
                   (if (omnigent-session-updates-connected updates)
                       omnigent-transport-inactivity-timeout
                     omnigent-transport-connect-timeout)))
        (omnigent-transport--updates-notify-error
         updates "Session updates disconnected or inactive")
        (let ((websocket
               (omnigent-session-updates-websocket updates)))
          (omnigent-transport--updates-closed
           updates attempt websocket)
          (when websocket
            (ignore-errors
              (websocket-close websocket))))))))

(defun omnigent-transport--updates-opened (updates websocket attempt)
  "Record an open WEBSOCKET for UPDATES and ATTEMPT, then send the watch set."
  (when (omnigent-transport--updates-current-p updates attempt)
    (setf
     (omnigent-session-updates-websocket updates) websocket
     (omnigent-session-updates-connected updates) t
     (omnigent-session-updates-failed updates) nil
     (omnigent-session-updates-failures updates) 0
     (omnigent-session-updates-last-activity updates) (float-time))
    (omnigent-transport--updates-send-watch updates websocket attempt)
    (when (omnigent-session-updates-open-callback updates)
      (funcall (omnigent-session-updates-open-callback updates)))))

(defun omnigent-transport--updates-message
    (updates websocket attempt frame)
  "Parse FRAME from WEBSOCKET and deliver it for UPDATES' current ATTEMPT."
  (when (omnigent-transport--updates-current-p updates attempt)
    (setf (omnigent-session-updates-last-activity updates)
          (float-time))
    (let ((data
           (condition-case err
               (json-parse-string (websocket-frame-text frame)
                                  :object-type 'alist
                                  :array-type 'array
                                  :null-object nil
                                  :false-object
                                  :json-false)
             (error
              (omnigent-transport--updates-notify-error
               updates
               (format "Invalid WebSocket JSON: %s"
                       (error-message-string err)))
              :invalid))))
      (unless (eq data :invalid)
        (funcall (omnigent-session-updates-frame-callback updates)
                 data)))))

(defun omnigent-transport--updates-error
    (updates attempt _websocket type err)
  "Report WebSocket error TYPE and ERR for UPDATES' current ATTEMPT.
Ignore _WEBSOCKET."
  (when (omnigent-transport--updates-current-p updates attempt)
    (setf (omnigent-session-updates-failed updates) t)
    (omnigent-transport--updates-notify-error
     updates
     (format "WebSocket %s: %s" type (error-message-string err)))))

(defun omnigent-transport--updates-closed (updates attempt _websocket)
  "Schedule reconnection after UPDATES' current ATTEMPT closes.
Ignore _WEBSOCKET."
  (when (omnigent-transport--updates-current-p updates attempt)
    (when (timerp (omnigent-session-updates-watchdog updates))
      (cancel-timer (omnigent-session-updates-watchdog updates)))
    (setf
     (omnigent-session-updates-watchdog updates) nil
     (omnigent-session-updates-websocket updates) nil)
    (cl-incf (omnigent-session-updates-attempt updates))
    (let ((failed
           (or (omnigent-session-updates-failed updates)
               (not (omnigent-session-updates-connected updates)))))
      (setf
       (omnigent-session-updates-failures updates)
       (if failed
           (1+ (omnigent-session-updates-failures updates))
         0)
       (omnigent-session-updates-connected updates) nil
       (omnigent-session-updates-failed updates) nil)
      (omnigent-transport--updates-schedule-reconnect
       updates
       (omnigent-transport--reconnect-delay
        (omnigent-session-updates-failures updates))))))

(defun omnigent-transport--updates-connect (updates)
  "Open the WebSocket for UPDATES, or schedule a retry on failure."
  (unless (or (omnigent-session-updates-stopped updates)
              (omnigent-session-updates-websocket updates))
    (when (timerp (omnigent-session-updates-timer updates))
      (cancel-timer (omnigent-session-updates-timer updates)))
    (setf (omnigent-session-updates-timer updates) nil)
    (let* ((attempt (1+ (omnigent-session-updates-attempt updates)))
           websocket)
      (setf
       (omnigent-session-updates-attempt updates) attempt
       (omnigent-session-updates-connected updates) nil
       (omnigent-session-updates-failed updates) nil
       (omnigent-session-updates-last-check updates) (float-time)
       (omnigent-session-updates-last-activity updates) (float-time)
       (omnigent-session-updates-watchdog updates)
       (run-at-time omnigent-transport--watchdog-interval
                    omnigent-transport--watchdog-interval
                    #'omnigent-transport--updates-watchdog
                    updates
                    attempt))
      (condition-case err
          (setq websocket
                (websocket-open
                 (omnigent-transport--updates-url)
                 :nowait t
                 :on-open
                 (lambda (ws)
                   (omnigent-transport--updates-opened
                    updates ws attempt))
                 :on-message
                 (lambda (ws frame)
                   (omnigent-transport--updates-message
                    updates ws attempt frame))
                 :on-close
                 (lambda (ws)
                   (omnigent-transport--updates-closed
                    updates attempt ws))
                 :on-error
                 (lambda (ws type error)
                   (omnigent-transport--updates-error
                    updates attempt ws type error))))
        (error
         (setf (omnigent-session-updates-failed updates) t)
         (omnigent-transport--updates-notify-error
          updates (error-message-string err))
         (omnigent-transport--updates-closed updates attempt nil)))
      (when (and websocket
                 (omnigent-transport--updates-current-p
                  updates attempt))
        (setf (omnigent-session-updates-websocket updates)
              websocket)))))

(defun omnigent-transport-start-session-updates
    (on-frame &optional on-error on-open)
  "Connect to the session-updates WebSocket.

ON-FRAME receives each parsed JSON frame.  ON-ERROR, when non-nil, receives
an error string.  ON-OPEN, when non-nil, runs after each connection opens.
Return a handle for `omnigent-transport-stop-session-updates'."
  (unless (require 'websocket nil t)
    (user-error
     "Session updates require the websocket package from GNU ELPA"))
  (omnigent-transport--updates-url)
  (let ((updates
         (omnigent-transport--make-session-updates
          :frame-callback on-frame
          :error-callback on-error
          :open-callback on-open
          :session-ids nil
          :stopped nil
          :failures 0
          :attempt 0)))
    (push updates omnigent-transport--updates)
    (omnigent-transport--updates-connect updates)
    updates))

(defun omnigent-transport-set-session-updates-watch
    (updates session-ids)
  "Set UPDATES' watched SESSION-IDS and send the full set to the server.
SESSION-IDS must be a list of at most 500 strings."
  (unless (and (listp session-ids)
               (<= (length session-ids) 500)
               (cl-every #'stringp session-ids))
    (user-error
     "Session watch must be a list of at most 500 session IDs"))
  (setf (omnigent-session-updates-session-ids updates)
        (copy-sequence session-ids))
  (when (omnigent-session-updates-websocket updates)
    (omnigent-transport--updates-send-watch
     updates
     (omnigent-session-updates-websocket updates)
     (omnigent-session-updates-attempt updates))))

(defun omnigent-transport-stop-session-updates (updates)
  "Stop UPDATES and prevent automatic reconnection."
  (setf (omnigent-session-updates-stopped updates) t)
  (when (timerp (omnigent-session-updates-watchdog updates))
    (cancel-timer (omnigent-session-updates-watchdog updates)))
  (setf (omnigent-session-updates-watchdog updates) nil)
  (setq omnigent-transport--updates
        (delq updates omnigent-transport--updates))
  (when (timerp (omnigent-session-updates-timer updates))
    (cancel-timer (omnigent-session-updates-timer updates)))
  (let ((websocket (omnigent-session-updates-websocket updates)))
    (setf (omnigent-session-updates-websocket updates) nil)
    (when websocket
      (ignore-errors
        (websocket-close websocket)))))

(provide 'omnigent-transport)
;;; omnigent-transport.el ends here
