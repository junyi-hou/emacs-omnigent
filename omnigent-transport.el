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

(defconst omnigent-transport--reconnect-min-delay 1.0)
(defconst omnigent-transport--reconnect-max-delay 15.0)

(cl-defstruct (omnigent-stream (:constructor omnigent-transport--make-stream))
  session-id event-callback snapshot-callback error-callback process timer
  stopped failures attempt)

(cl-defstruct (omnigent-session-updates
               (:constructor omnigent-transport--make-session-updates))
  frame-callback error-callback websocket timer session-ids stopped failures
  attempt connected failed)

(defun omnigent-transport--url (path)
  (concat (string-remove-suffix "/" omnigent-server-url) path))

(defun omnigent-transport--session-path (session-id &optional suffix)
  (concat "/v1/sessions/" (url-hexify-string session-id) (or suffix "")))

(defun omnigent-transport--response-body ()
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
  (unwind-protect
      (let ((http-status (and (boundp 'url-http-response-status)
                               url-http-response-status)))
        (when (= generation omnigent-transport--generation)
          (funcall callback (or http-status status)
                   (omnigent-transport--response-body))))
    (when (buffer-live-p (current-buffer))
      (kill-buffer (current-buffer)))))

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
   "GET" "/v1/sessions?limit=1000&include_archived=true&sort_by=updated_at&order=desc"
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
  (when (omnigent-stream-error-callback stream)
    (funcall (omnigent-stream-error-callback stream) error)))

(defun omnigent-transport--stream-filter (process chunk)
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
  (list (executable-find "curl") "--silent" "--show-error"
        "--no-buffer" "--fail"
        (omnigent-transport--url
         (concat (omnigent-transport--session-path session-id) "/stream"))))

(defun omnigent-transport--stream-snapshot (stream attempt status body)
  (when (and (not (omnigent-stream-stopped stream))
             (= attempt (omnigent-stream-attempt stream)))
    (funcall (omnigent-stream-snapshot-callback stream) status body)))

(defun omnigent-transport--reconnect-delay (failures)
  (if (zerop failures)
      omnigent-transport--reconnect-min-delay
    (min omnigent-transport--reconnect-max-delay
         (* omnigent-transport--reconnect-min-delay (expt 2 (1- failures))))))

(defun omnigent-transport--stream-sentinel (process _event)
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
        (process-put process 'omnigent-stream stream)
        (process-put process 'omnigent-stderr stderr)
        (setf (omnigent-stream-process stream) process)
        (omnigent-transport-get-session
         (omnigent-stream-session-id stream)
         (lambda (status body)
           (omnigent-transport--stream-snapshot stream attempt status body)))))))

(defun omnigent-transport-start-session-stream (session-id on-event on-snapshot &optional on-error)
  "Start the SSE stream for SESSION-ID.

ON-EVENT receives (EVENT-NAME DATA).  ON-SNAPSHOT receives (STATUS BODY)
after each stream connection starts.  ON-ERROR, when non-nil, receives an
error string.  Return a stream handle for `omnigent-transport-stop-session-stream'."
  (unless (executable-find "curl")
    (user-error "Omnigent session streams require curl"))
  (let ((stream (omnigent-transport--make-stream
                 :session-id session-id :event-callback on-event
                 :snapshot-callback on-snapshot :error-callback on-error
                 :stopped nil :failures 0 :attempt 0)))
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
  (unless (string-match-p "\\`https?://" omnigent-server-url)
    (user-error "Omnigent WebSocket URL must start with http:// or https://"))
  (concat (if (string-prefix-p "https://" omnigent-server-url) "wss" "ws")
          (substring (string-remove-suffix "/" omnigent-server-url)
                     (if (string-prefix-p "https://" omnigent-server-url) 5 4))
          "/v1/sessions/updates"))

(defun omnigent-transport--updates-current-p (updates attempt)
  (and (not (omnigent-session-updates-stopped updates))
       (= attempt (omnigent-session-updates-attempt updates))))

(defun omnigent-transport--updates-notify-error (updates error)
  (when (omnigent-session-updates-error-callback updates)
    (condition-case nil
        (funcall (omnigent-session-updates-error-callback updates) error)
      (error nil))))

(defun omnigent-transport--updates-send-watch (updates websocket attempt)
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
  (unless (or (omnigent-session-updates-stopped updates)
              (timerp (omnigent-session-updates-timer updates)))
    (setf (omnigent-session-updates-timer updates)
          (run-at-time delay nil
                       #'omnigent-transport--updates-connect updates))))

(defun omnigent-transport--updates-opened (updates websocket attempt)
  (when (omnigent-transport--updates-current-p updates attempt)
    (setf (omnigent-session-updates-websocket updates) websocket
          (omnigent-session-updates-connected updates) t
          (omnigent-session-updates-failed updates) nil
          (omnigent-session-updates-failures updates) 0)
    (omnigent-transport--updates-send-watch updates websocket attempt)))

(defun omnigent-transport--updates-message (updates websocket attempt frame)
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
  (when (omnigent-transport--updates-current-p updates attempt)
    (setf (omnigent-session-updates-failed updates) t)
    (omnigent-transport--updates-notify-error
     updates (format "WebSocket %s: %s" type (error-message-string err)))))

(defun omnigent-transport--updates-closed (updates attempt _websocket)
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

(defun omnigent-transport-start-session-updates (on-frame &optional on-error)
  "Connect to the session-updates WebSocket.

ON-FRAME receives each parsed JSON frame.  ON-ERROR, when non-nil, receives
an error string.  Return a handle for `omnigent-transport-stop-session-updates'."
  (unless (require 'websocket nil t)
    (user-error "Session updates require the websocket package from GNU ELPA"))
  (omnigent-transport--updates-url)
  (let ((updates (omnigent-transport--make-session-updates
                  :frame-callback on-frame :error-callback on-error
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
