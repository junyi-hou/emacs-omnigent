;;; omnigent-transport.el --- Omnigent HTTP and SSE transport -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;; Small REST and session-stream client for Omnigent.
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

(defcustom omnigent-token nil
  "Bearer token for a shared Omnigent server, or nil for a local server."
  :type '(choice (const :tag "No token" nil) string)
  :group 'omnigent-transport)

(defconst omnigent-transport--reconnect-min-delay 1.0)
(defconst omnigent-transport--reconnect-max-delay 15.0)

(cl-defstruct (omnigent-stream (:constructor omnigent-transport--make-stream))
  session-id event-callback snapshot-callback error-callback process timer
  stopped failures attempt)

(defun omnigent-transport--url (path)
  (concat (string-remove-suffix "/" omnigent-server-url) path))

(defun omnigent-transport--auth-header ()
  (when (and omnigent-token (not (string-empty-p omnigent-token)))
    (when (string-match-p "[\r\n]" omnigent-token)
      (user-error "Omnigent token must not contain a newline"))
    (cons "Authorization" (concat "Bearer " omnigent-token))))

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

(defun omnigent-transport--url-callback (status callback)
  (unwind-protect
      (let ((http-status (and (boundp 'url-http-response-status)
                               url-http-response-status)))
        (funcall callback (or http-status status)
                 (omnigent-transport--response-body)))
    (when (buffer-live-p (current-buffer))
      (kill-buffer (current-buffer)))))

(defun omnigent-request (method path callback &optional data)
  "Send METHOD to PATH and call CALLBACK with status and response body.

PATH is relative to `omnigent-server-url' and must start with `/'.  DATA,
when non-nil, is JSON-encoded.  CALLBACK receives (STATUS BODY)."
  (unless (string-prefix-p "/" path)
    (error "Omnigent API path must start with /: %s" path))
  (let ((url-request-method method)
        (url-request-extra-headers
         (delq nil
               (append (when data '(("Content-Type" . "application/json")))
                       (list (omnigent-transport--auth-header)))))
        (url-request-data (when data
                            (encode-coding-string (json-encode data)
                                                  'utf-8))))
    (url-retrieve (omnigent-transport--url path)
                  #'omnigent-transport--url-callback (list callback) t t)))

(defun omnigent-get-session (session-id callback)
  "Get SESSION-ID and call CALLBACK with status and response body."
  (omnigent-request "GET" (omnigent-transport--session-path session-id) callback))

(defun omnigent-list-sessions (callback)
  "List sessions and call CALLBACK with status and response body."
  (omnigent-request "GET" "/v1/sessions" callback))

(defun omnigent-list-child-sessions (parent-id callback)
  "List children of PARENT-ID and call CALLBACK with status and response body."
  (omnigent-request "GET"
                    (omnigent-transport--session-path parent-id "/child_sessions")
                    callback))

(defun omnigent-post-session-event (session-id event callback)
  "Post EVENT to SESSION-ID and call CALLBACK with status and response body."
  (omnigent-request "POST"
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
      (unless (process-get process 'omnigent-done)
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

(defun omnigent-transport--curl-header-file ()
  (let ((header (omnigent-transport--auth-header)))
    (when header
      (let ((file (make-temp-file "omnigent-headers-")))
        (let ((written nil))
          (unwind-protect
              (progn
                (set-file-modes file #o600)
                (with-temp-buffer
                  (insert (car header) ": " (cdr header) "\n")
                  (let ((coding-system-for-write 'utf-8-unix))
                    (write-region (point-min) (point-max) file nil 'silent)))
                (setq written t)
                file)
            (unless written
              (ignore-errors (delete-file file)))))))))

(defun omnigent-transport--stream-command (session-id header-file)
  (append (list (executable-find "curl") "--silent" "--show-error"
                "--no-buffer" "--fail")
          (when header-file (list "--header" (concat "@" header-file)))
          (list (omnigent-transport--url
                 (concat (omnigent-transport--session-path session-id)
                         "/stream")))))

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
           (header-file (process-get process 'omnigent-header-file))
           (stderr (process-get process 'omnigent-stderr))
           (done (process-get process 'omnigent-done)))
      (when header-file (ignore-errors (delete-file header-file)))
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
    (let* ((header-file (omnigent-transport--curl-header-file))
           (stderr (generate-new-buffer " *omnigent-curl-stderr*"))
           (attempt (1+ (omnigent-stream-attempt stream)))
           process)
      (setf (omnigent-stream-attempt stream) attempt)
      (condition-case err
          (setq process
                (make-process :name (format "omnigent-%s" (omnigent-stream-session-id stream))
                              :buffer nil
                              :stderr stderr
                              :command (omnigent-transport--stream-command
                                        (omnigent-stream-session-id stream) header-file)
                              :connection-type 'pipe
                              :coding 'utf-8-unix
                              :noquery t
                              :filter #'omnigent-transport--stream-filter
                              :sentinel #'omnigent-transport--stream-sentinel))
        (error
         (when header-file (ignore-errors (delete-file header-file)))
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
        (process-put process 'omnigent-header-file header-file)
        (process-put process 'omnigent-stderr stderr)
        (setf (omnigent-stream-process stream) process)
        (omnigent-get-session
         (omnigent-stream-session-id stream)
         (lambda (status body)
           (omnigent-transport--stream-snapshot stream attempt status body)))))))

(defun omnigent-start-session-stream (session-id on-event on-snapshot &optional on-error)
  "Start the SSE stream for SESSION-ID.

ON-EVENT receives (EVENT-NAME DATA).  ON-SNAPSHOT receives (STATUS BODY)
after each stream connection starts.  ON-ERROR, when non-nil, receives an
error string.  Return a stream handle for `omnigent-stop-session-stream'."
  (unless (executable-find "curl")
    (user-error "Omnigent session streams require curl"))
  (omnigent-transport--auth-header)
  (let ((stream (omnigent-transport--make-stream
                 :session-id session-id :event-callback on-event
                 :snapshot-callback on-snapshot :error-callback on-error
                 :stopped nil :failures 0 :attempt 0)))
    (omnigent-transport--stream-connect stream)
    stream))

(defun omnigent-stop-session-stream (stream)
  "Stop STREAM and prevent automatic reconnection."
  (setf (omnigent-stream-stopped stream) t)
  (when (timerp (omnigent-stream-timer stream))
    (cancel-timer (omnigent-stream-timer stream)))
  (when (process-live-p (omnigent-stream-process stream))
    (delete-process (omnigent-stream-process stream))))

(provide 'omnigent-transport)
;;; omnigent-transport.el ends here
