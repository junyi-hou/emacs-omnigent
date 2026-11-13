;;; omnigent-transport-test.el --- Tests for Omnigent transport -*- lexical-binding: t; -*-

(require 'ert)
(require 'omnigent-transport)

(ert-deftest omnigent-transport-generate-session-title-patches-session
    ()
  "Request generated title metadata through the session PATCH endpoint."
  (let (request)
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (&rest args) (setq request args))))
      (omnigent-transport-generate-session-title
       "session" "Focus on recent turns." #'ignore))
    (should
     (equal
      request
      (list
       "PATCH" "/v1/sessions/session" #'ignore
       '(("generate_title" . t)
         ("session_title_instructions"
          .
          "Focus on recent turns.")))))))

(ert-deftest omnigent-transport-success-codes ()
  "Accept only integer HTTP success codes, including both range endpoints."
  (dolist (status '(200 202 204 299))
    (should (omnigent-transport-success-p status)))
  (dolist (status
           '(199
             300
             500
             200.0
             "200"
             nil
             t
             (:error (connection-failed))))
    (should-not (omnigent-transport-success-p status))))

(ert-deftest omnigent-transport-error-message-preserves-diagnostics ()
  "Format HTTP, transport, and local failures without discarding response details."
  (dolist (case
           '((403
              ((detail . "Access denied"))
              "Read: 403 (Access denied)")
             (422
              ((detail . [((msg . "Required"))]))
              "Read: 422 ([((msg . Required))])")
             (502
              "Upstream unavailable"
              "Read: 502 (Upstream unavailable)")
             (500
              ((error . "Runner failed"))
              "Read: 500 (Runner failed)")
             (500
              ((reason . "Failure"))
              "Read: 500 (((reason . Failure)))")
             (204 nil "Read: 204")
             (nil
              "Invalid response"
              "Read: client error (Invalid response)")
             ((:error (connection-failed))
              nil
              "Read: (:error (connection-failed))")))
    (should
     (equal
      (omnigent-transport-error-message
       "Read" (nth 0 case) (nth 1 case))
      (nth 2 case)))))

(ert-deftest omnigent-transport-splits-sse-frames-across-chunks ()
  "Keep partial frames until a blank-line delimiter arrives."
  (let*
      ((first
        (omnigent-transport--split-sse-frames
         ""
         "event: session.status\r\ndata: {\"type\":\"session.status\"}\r"))
       (second
        (omnigent-transport--split-sse-frames
         (cdr first) "\n\r\nevent: ping\ndata: 1\n\n")))
    (should (equal (car first) nil))
    (should
     (equal
      (car second)
      '("event: session.status\ndata: {\"type\":\"session.status\"}"
        "event: ping\ndata: 1")))
    (should (equal (cdr second) ""))))

(ert-deftest omnigent-transport-parses-sse-data-lines ()
  "Ignore comments and join multiple data lines with newlines."
  (should
   (equal
    (omnigent-transport--parse-sse-frame
     ": heartbeat\nevent: response.output_text.delta\ndata: {\"text\":\ndata: \"hi\"}")
    '("response.output_text.delta" . "{\"text\":\n\"hi\"}"))))

(ert-deftest
    omnigent-transport-websocket-url-uses-secure-scheme-when-needed
    ()
  "Map the configured HTTP URL to the session-updates WebSocket URL."
  (let ((omnigent-server-url "https://example.test/base/"))
    (should
     (equal
      (omnigent-transport--updates-url)
      "wss://example.test/base/v1/sessions/updates")))
  (let ((omnigent-server-url "http://localhost:6767"))
    (should
     (equal
      (omnigent-transport--updates-url)
      "ws://localhost:6767/v1/sessions/updates")))
  (let ((omnigent-server-url "file:///tmp/server"))
    (should-error
     (omnigent-transport--updates-url)
     :type 'user-error)))

(ert-deftest
    omnigent-transport-session-updates-sends-watch-and-parses-frames
    ()
  "Send watch sets and pass parsed server frames to the callback."
  (let ((real-require (symbol-function 'require))
        (omnigent-server-url "https://example.test")
        open-args
        sent
        frames
        errors
        closed)
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'websocket)
                     t
                   (funcall real-require feature filename noerror))))
              ((symbol-function 'websocket-open)
               (lambda (url &rest args)
                 (setq open-args (cons url args))
                 'fake-websocket))
              ((symbol-function 'websocket-openp)
               (lambda (_websocket) t))
              ((symbol-function 'websocket-send-text)
               (lambda (_websocket text) (push text sent)))
              ((symbol-function 'websocket-frame-text) #'identity)
              ((symbol-function 'websocket-close)
               (lambda (_websocket) (setq closed t))))
      (let ((updates
             (omnigent-transport-start-session-updates
              (lambda (frame) (push frame frames))
              (lambda (error) (push error errors)))))
        (should
         (equal
          (car open-args) "wss://example.test/v1/sessions/updates"))
        (should-not (plist-get (cdr open-args) :custom-header-alist))
        (funcall (plist-get (cdr open-args) :on-open) 'fake-websocket)
        (should
         (equal
          (json-parse-string (car sent)
                             :object-type 'alist
                             :array-type 'array)
          '((type . "watch") (session_ids . []))))
        (omnigent-transport-set-session-updates-watch
         updates '("s1" "s2"))
        (should-error
         (omnigent-transport-set-session-updates-watch
          updates (make-list 501 "s"))
         :type 'user-error)
        (should
         (equal
          (cdr
           (assq
            'session_ids
            (json-parse-string
             (car sent)
             :object-type 'alist
             :array-type 'array)))
          ["s1" "s2"]))
        (funcall (plist-get (cdr open-args) :on-message)
                 'fake-websocket
                 "{\"type\":\"changed\",\"id\":\"s1\"}")
        (should
         (equal (car frames) '((type . "changed") (id . "s1"))))
        (funcall (plist-get (cdr open-args) :on-message)
                 'fake-websocket
                 "not json")
        (should
         (string-match-p "Invalid WebSocket JSON" (car errors)))
        (omnigent-transport-stop-session-updates updates)
        (should closed)
        (should (omnigent-session-updates-stopped updates))))))

(ert-deftest
    omnigent-transport-session-updates-reconnects-with-latest-watch
    ()
  "Reconnect after close and send the latest complete watch set."
  (let ((real-require (symbol-function 'require))
        (real-run-at-time (symbol-function 'run-at-time))
        (open-callbacks nil)
        (sent nil)
        scheduled)
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'websocket)
                     t
                   (funcall real-require feature filename noerror))))
              ((symbol-function 'websocket-open)
               (lambda (_url &rest args)
                 (push args open-callbacks)
                 (intern
                  (format "fake-websocket-%d"
                          (length open-callbacks)))))
              ((symbol-function 'websocket-openp)
               (lambda (_websocket) t))
              ((symbol-function 'websocket-send-text)
               (lambda (_websocket text) (push text sent)))
              ((symbol-function 'websocket-close) #'ignore)
              ((symbol-function 'run-at-time)
               (lambda (delay _repeat function &rest args)
                 (setq scheduled (list delay function args))
                 (funcall real-run-at-time 3600 nil #'ignore)))
              ((symbol-function 'cancel-timer) #'ignore))
      (let ((updates
             (omnigent-transport-start-session-updates #'ignore)))
        (omnigent-transport-set-session-updates-watch
         updates '("old"))
        (funcall (plist-get (car open-callbacks) :on-close)
                 'fake-websocket-1)
        (should
         (= (car scheduled) omnigent-transport--reconnect-min-delay))
        (omnigent-transport-set-session-updates-watch
         updates '("new"))
        (funcall (cadr scheduled) (car (caddr scheduled)))
        (should (= (length open-callbacks) 2))
        (funcall (plist-get (car open-callbacks) :on-open)
                 'fake-websocket-2)
        (should
         (equal
          (cdr
           (assq
            'session_ids
            (json-parse-string
             (car sent)
             :object-type 'alist
             :array-type 'array)))
          ["new"]))
        (omnigent-transport-stop-session-updates updates)))))

(ert-deftest
    omnigent-transport-session-updates-requires-websocket-package
    ()
  "Report the optional GNU ELPA dependency when it is missing."
  (let ((real-require (symbol-function 'require)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'websocket)
                     nil
                   (funcall real-require feature filename noerror)))))
      (should-error
       (omnigent-transport-start-session-updates #'ignore)
       :type 'user-error))))

;;; Connection lifecycle and recovery

(ert-deftest omnigent-transport-stream-reconnect-backoff ()
  "Increase retry delays after failures, without exceeding the cap."
  (should
   (equal
    (mapcar
     #'omnigent-transport--reconnect-delay '(0 1 2 3 4 5 10))
    '(1.0 1.0 2.0 4.0 8.0 15.0 15.0))))

(ert-deftest omnigent-transport-stream-exit-schedules-reconnect ()
  "Retry failed, clean, and DONE exits; do not retry a stopped stream."
  (dolist (case
           '((1 nil nil 3 4.0)
             (0 nil nil 0 1.0)
             (1 t nil 0 1.0)
             (1 nil t 2 nil)))
    (pcase-let* ((`(,exit-code ,done ,stopped ,failures ,delay) case)
                 (errors nil)
                 (stream
                  (omnigent-transport--make-stream
                   :stopped stopped
                   :failures 2
                   :process 'process
                   :error-callback
                   (lambda (error) (push error errors))))
                 (stderr
                  (generate-new-buffer " *omnigent-test-stderr*"))
                 (scheduled nil))
      (unwind-protect
          (cl-letf (((symbol-function 'process-status)
                     (lambda (_) 'exit))
                    ((symbol-function 'process-exit-status)
                     (lambda (_) exit-code))
                    ((symbol-function 'process-get)
                     (lambda (_ key)
                       (pcase key
                         ('omnigent-stream stream)
                         ('omnigent-stderr stderr)
                         ('omnigent-done done))))
                    ((symbol-function 'run-at-time)
                     (lambda (&rest args)
                       (setq scheduled args)
                       'retry)))
            (with-current-buffer stderr
              (insert "curl failed\n"))
            (omnigent-transport--stream-sentinel 'process "exited")
            (should-not (buffer-live-p stderr))
            (should-not (omnigent-stream-process stream))
            (should (= (omnigent-stream-failures stream) failures))
            (if delay
                (should
                 (equal
                  scheduled
                  (list
                   delay
                   nil
                   #'omnigent-transport--stream-connect
                   stream)))
              (should-not scheduled))
            (should
             (equal
              errors
              (when (and (/= exit-code 0) (not done) (not stopped))
                '("curl failed")))))
        (when (buffer-live-p stderr)
          (kill-buffer stderr))))))

(ert-deftest omnigent-transport-stream-connect-fetches-each-snapshot
    ()
  "Fetch a snapshot after each connection, ignoring old or stopped attempts."
  (let* ((connected 0)
         snapshots
         callbacks
         properties
         (stream
          (omnigent-transport--make-stream
           :session-id "session"
           :failures 0
           :attempt 0
           :connect-callback (lambda () (cl-incf connected))
           :snapshot-callback
           (lambda (status body)
             (push (cons status body) snapshots)))))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (push (plist-get args :stderr) properties)
                 'process))
              ((symbol-function 'process-put) #'ignore)
              ((symbol-function
                'omnigent-transport--stream-load-snapshot)
               (lambda (target attempt)
                 (funcall (omnigent-stream-connect-callback target))
                 (push (lambda (status body)
                         (omnigent-transport--stream-snapshot
                          target attempt status body))
                       callbacks))))
      (unwind-protect
          (progn
            (omnigent-transport--stream-connect stream)
            (omnigent-transport--stream-connect stream)
            (should (= connected 2))
            (should (= (omnigent-stream-attempt stream) 2))
            (funcall (cadr callbacks) 200 'old)
            (should-not snapshots)
            (funcall (car callbacks) 200 'current)
            (should (equal snapshots '((200 . current))))
            (setf (omnigent-stream-stopped stream) t)
            (funcall (car callbacks) 200 'late)
            (omnigent-transport--stream-connect stream)
            (should (= connected 2))
            (should (equal snapshots '((200 . current)))))
        (omnigent-transport-stop-session-stream stream)
        (mapc #'kill-buffer properties)))))

(ert-deftest omnigent-transport-stream-loads-bounded-history ()
  "Load the configured history window in chronological order across pages."
  (let* ((omnigent-transport-history-limit 1001)
         requests
         result
         (stream
          (omnigent-transport--make-stream
           :session-id "session"
           :attempt 1
           :snapshot-callback
           (lambda (status body) (setq result (cons status body))))))
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (_method path callback &optional _data)
                 (push (cons path callback) requests))))
      (omnigent-transport--stream-load-snapshot stream 1)
      (should
       (equal
        (caar requests) "/v1/sessions/session?include_items=false"))
      (funcall (cdar requests) 200 '((pending_elicitations . [])))
      (should
       (equal
        (caar requests)
        "/v1/sessions/session/items?limit=1000&order=desc"))
      (funcall (cdar requests)
               200
               `((data
                  .
                  ,(vconcat
                    (mapcar
                     (lambda (n) `((id . ,n)))
                     (number-sequence 1001 2 -1))))
                 (has_more . t) (last_id . "cursor /")))
      (should
       (equal
        (caar requests)
        "/v1/sessions/session/items?limit=1&order=desc&after=cursor%20%2F"))
      (funcall (cdar requests)
               200
               '((data . [((id . 1))]) (has_more . :json-false)))
      (let ((items (alist-get 'items (cdr result))))
        (should (= (length items) 1001))
        (should (= (alist-get 'id (aref items 0)) 1))
        (should (= (alist-get 'id (aref items 1000)) 1001))))))

(ert-deftest omnigent-transport-stream-start-failure-and-stop ()
  "Retry process creation failures, then cancel the retry when stopped."
  (let* ((omnigent-transport--streams nil)
         (stderr nil)
         errors
         scheduled
         cancelled
         (timer (run-at-time 3600 nil #'ignore))
         (stream
          (omnigent-transport--make-stream
           :session-id "session"
           :attempt 0
           :failures 0
           :error-callback
           (lambda (error) (push error errors)))))
    (unwind-protect
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest args)
                     (setq stderr (plist-get args :stderr))
                     (error "Cannot start curl")))
                  ((symbol-function 'run-at-time)
                   (lambda (&rest args)
                     (setq scheduled args)
                     timer))
                  ((symbol-function 'cancel-timer)
                   (lambda (value) (setq cancelled value))))
          (push stream omnigent-transport--streams)
          (omnigent-transport--stream-connect stream)
          (should-not (buffer-live-p stderr))
          (should (equal errors '("Cannot start curl")))
          (should (= (omnigent-stream-failures stream) 1))
          (should
           (equal
            scheduled
            (list
             1.0 nil #'omnigent-transport--stream-connect stream)))
          (omnigent-transport-stop-session-stream stream)
          (should (eq cancelled timer))
          (should (omnigent-stream-stopped stream))
          (should-not omnigent-transport--streams)
          (setq scheduled nil)
          (omnigent-transport--stream-connect stream)
          (should-not scheduled))
      (cancel-timer timer))))

(ert-deftest omnigent-transport-stream-done-stops-frame-delivery ()
  "DONE closes the process and ignores later events in the same chunk."
  (let* (events
         deleted
         (stream
          (omnigent-transport--make-stream
           :process 'process
           :event-callback
           (lambda (&rest event) (push event events))))
         (properties (list 'omnigent-stream stream)))
    (cl-letf (((symbol-function 'process-get)
               (lambda (_ key) (plist-get properties key)))
              ((symbol-function 'process-put)
               (lambda (_ key value)
                 (setq properties (plist-put properties key value))))
              ((symbol-function 'delete-process)
               (lambda (_) (setq deleted t))))
      (omnigent-transport--stream-filter
       'process
       "data: {\"n\":1}\n\ndata: [DONE]\n\ndata: {\"n\":2}\n\n")
      (should deleted)
      (should (plist-get properties 'omnigent-done))
      (should (equal events '(("message" ((n . 1)))))))))

(ert-deftest omnigent-transport-updates-ignore-stale-callbacks ()
  "Old attempts and stopped handles cannot deliver callbacks or reconnect."
  (let* ((frames 0)
         (errors 0)
         (opens 0)
         (scheduled 0)
         (sent 0)
         (updates
          (omnigent-transport--make-session-updates
           :attempt 2
           :failures 0
           :websocket 'current
           :frame-callback
           (lambda (_) (cl-incf frames))
           :error-callback
           (lambda (_) (cl-incf errors))
           :open-callback
           (lambda () (cl-incf opens)))))
    (cl-letf (((symbol-function 'websocket-frame-text) #'identity)
              ((symbol-function 'websocket-openp) (lambda (_) t))
              ((symbol-function 'websocket-send-text)
               (lambda (&rest _) (cl-incf sent)))
              ((symbol-function 'run-at-time)
               (lambda (&rest _) (cl-incf scheduled))))
      (dolist (attempt '(1 2))
        (when (= attempt 2)
          (setf (omnigent-session-updates-stopped updates) t))
        (omnigent-transport--updates-opened updates 'old attempt)
        (omnigent-transport--updates-message
         updates 'old attempt "{}")
        (omnigent-transport--updates-error
         updates attempt 'old 'error '(error "late"))
        (omnigent-transport--updates-closed updates attempt 'old))
      (should
       (eq (omnigent-session-updates-websocket updates) 'current))
      (should (= (omnigent-session-updates-failures updates) 0))
      (should
       (equal
        (list frames errors opens scheduled sent) '(0 0 0 0 0))))))

(ert-deftest
    omnigent-transport-callback-cleans-up-original-response-buffer
    ()
  "Keep a buffer selected by the callback and kill only the HTTP response."
  (let ((response (generate-new-buffer " *omnigent-response*"))
        (conversation
         (generate-new-buffer " *omnigent-conversation*")))
    (unwind-protect
        (save-current-buffer
          (set-buffer response)
          (insert "{}")
          (omnigent-transport--url-callback
           nil
           (lambda (&rest _) (set-buffer conversation))
           omnigent-transport--generation)
          (should-not (buffer-live-p response))
          (should (buffer-live-p conversation)))
      (when (buffer-live-p response)
        (kill-buffer response))
      (when (buffer-live-p conversation)
        (kill-buffer conversation)))))

(ert-deftest omnigent-transport-reset-invalidates-old-work ()
  "Stop registered connections and ignore callbacks from the old server."
  (let* ((omnigent-transport--generation 0)
         (stream (omnigent-transport--make-stream :stopped nil))
         (updates
          (omnigent-transport--make-session-updates :stopped nil))
         (omnigent-transport--streams (list stream))
         (omnigent-transport--updates (list updates))
         called)
    (omnigent-transport-reset)
    (should (omnigent-stream-stopped stream))
    (should (omnigent-session-updates-stopped updates))
    (should-not omnigent-transport--streams)
    (should-not omnigent-transport--updates)
    (with-temp-buffer
      (omnigent-transport--url-callback
       nil
       (lambda (&rest _) (setq called t)) 0))
    (should-not called)))

(ert-deftest
    omnigent-transport-sse-consumer-errors-are-not-json-errors
    ()
  "Propagate consumer errors without misreporting malformed server JSON."
  (let* (errors
         (stream
          (omnigent-transport--make-stream
           :process 'process
           :event-callback
           (lambda (&rest _) (error "Consumer failed"))
           :error-callback
           (lambda (error) (push error errors))))
         (properties (list 'omnigent-stream stream)))
    (cl-letf (((symbol-function 'process-get)
               (lambda (_ key) (plist-get properties key)))
              ((symbol-function 'process-put)
               (lambda (_ key value)
                 (setq properties (plist-put properties key value)))))
      (should
       (equal
        (should-error
         (omnigent-transport--stream-filter 'process "data: {}\n\n"))
        '(error "Consumer failed")))
      (should-not errors))))

(ert-deftest
    omnigent-transport-stream-watchdog-recovers-silence-and-resume
    ()
  "Keep idle sessions live, but reconnect silent sockets and long scheduling gaps."
  (dolist (case
           '((t 95 20 nil)
             (t 95 9 t)
             (t 80 100 t)
             (nil 95 69 t)
             (nil 95 90 nil)))
    (pcase-let* ((`(,ready ,checked ,activity ,expired) case)
                 (retries 0)
                 (closed 0)
                 (states nil)
                 (stream
                  (omnigent-transport--make-stream
                   :process 'process
                   :attempt 1
                   :failures 0
                   :ready ready
                   :last-check checked
                   :last-activity activity
                   :state-callback
                   (lambda (state) (push state states)))))
      (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 100))
                ((symbol-function 'process-live-p)
                 (lambda (process)
                   (and (eq process 'process) (zerop closed))))
                ((symbol-function 'process-status)
                 (lambda (_) 'signal))
                ((symbol-function 'process-exit-status)
                 (lambda (_) 1))
                ((symbol-function 'process-get)
                 (lambda (_ key)
                   (when (eq key 'omnigent-stream)
                     stream)))
                ((symbol-function 'delete-process)
                 (lambda (process)
                   (cl-incf closed)
                   (omnigent-transport--stream-sentinel
                    process "inactive")))
                ((symbol-function 'run-at-time)
                 (lambda (_delay _repeat function &rest _)
                   (when (eq
                          function
                          #'omnigent-transport--stream-connect)
                     (cl-incf retries))
                   'retry)))
        (omnigent-transport--stream-watchdog stream 1)
        (should
         (= closed
            (if expired
                1
              0)))
        (should
         (= retries
            (if expired
                1
              0)))
        (should
         (equal
          states
          (when expired
            '(disconnected))))
        (when expired
          (omnigent-transport--stream-sentinel
           'process "duplicate exit")
          (should (= retries 1)))
        (setf (omnigent-stream-attempt stream) 2)
        (omnigent-transport--stream-watchdog stream 1)
        (omnigent-transport-stop-session-stream stream)
        (omnigent-transport--stream-watchdog stream 2)
        (should
         (= retries
            (if expired
                1
              0)))))))

(ert-deftest
    omnigent-transport-stream-watchdog-survives-error-observers
    ()
  "A failing error observer cannot prevent stale stream termination and retry."
  (let* ((closed nil)
         (stream
          (omnigent-transport--make-stream
           :process 'process
           :attempt 1
           :ready t
           :last-check 95
           :last-activity 0
           :error-callback
           (lambda (_) (error "Observer failed")))))
    (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 100))
              ((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'delete-process)
               (lambda (_) (setq closed t)))
              ((symbol-function 'display-warning) #'ignore))
      (omnigent-transport--stream-watchdog stream 1)
      (should closed))))

(ert-deftest omnigent-transport-updates-watchdog-recovers-once ()
  "Reconnect inactive WebSockets once and reject callbacks from the closed attempt."
  (dolist (case
           '((t 95 20 nil)
             (t 95 9 t)
             (t 80 100 t)
             (nil 95 69 t)
             (nil 95 90 nil)))
    (pcase-let* ((`(,connected ,checked ,activity ,expired) case)
                 (retries 0)
                 (closed 0)
                 (frames 0)
                 (updates
                  (omnigent-transport--make-session-updates
                   :websocket 'socket
                   :attempt 1
                   :failures 0
                   :connected connected
                   :last-check checked
                   :last-activity activity
                   :frame-callback
                   (lambda (_) (cl-incf frames)))))
      (cl-letf (((symbol-function 'float-time) (lambda (&rest _) 100))
                ((symbol-function 'run-at-time)
                 (lambda (&rest _)
                   (cl-incf retries)
                   'retry))
                ((symbol-function 'websocket-close)
                 (lambda (socket)
                   (cl-incf closed)
                   (omnigent-transport--updates-closed
                    updates 1 socket)))
                ((symbol-function 'websocket-frame-text) #'identity))
        (omnigent-transport--updates-watchdog updates 1)
        (should
         (= closed
            (if expired
                1
              0)))
        (should
         (= retries
            (if expired
                1
              0)))
        (when expired
          (omnigent-transport--updates-message updates 'socket 1 "{}")
          (omnigent-transport--updates-watchdog updates 1)
          (should (= frames 0))
          (should (= retries 1)))
        (omnigent-transport-stop-session-updates updates)
        (omnigent-transport--updates-watchdog
         updates (omnigent-session-updates-attempt updates))
        (should
         (= retries
            (if expired
                1
              0)))))))

(ert-deftest
    omnigent-transport-snapshot-coalesces-and-rejects-late-results
    ()
  "Serialize composite reads and discard an old operation's duplicate result."
  (let* (requests
         results
         (stream
          (omnigent-transport--make-stream
           :session-id "session"
           :attempt 1
           :snapshot-callback
           (lambda (status body) (push (cons status body) results)))))
    (unwind-protect
        (cl-letf (((symbol-function 'omnigent-transport-request)
                   (lambda (_method path callback &optional _data)
                     (push (cons path callback) requests))))
          (omnigent-transport-refresh-session-stream stream)
          (let ((first (cdar requests)))
            (omnigent-transport-refresh-session-stream stream)
            (omnigent-transport-refresh-session-stream stream)
            (should (= (length requests) 1))
            (funcall first
                     200
                     '((pending_inputs . [])
                       (pending_elicitations . [])))
            (funcall (cdar requests)
                     200
                     '((data . []) (has_more . :json-false)))
            (should (= (length results) 1))
            (should (= (length requests) 3))
            (funcall first 500 "late")
            (should (= (length results) 1))))
      (omnigent-transport-stop-session-stream stream))))

(ert-deftest omnigent-transport-snapshot-pagination-setup-failure ()
  "Report a later page's setup failure immediately instead of waiting for timeout."
  (let* (callback
         results
         (stream
          (omnigent-transport--make-stream
           :session-id "session"
           :attempt 1
           :snapshot-callback
           (lambda (status body) (push (cons status body) results)))))
    (unwind-protect
        (cl-letf (((symbol-function 'omnigent-transport-request)
                   (lambda (_method path cb &optional _data)
                     (if (string-match-p "after=" path)
                         (error "Page setup failed")
                       (setq callback cb)))))
          (omnigent-transport-refresh-session-stream stream)
          (funcall callback
                   200
                   '((pending_inputs . [])
                     (pending_elicitations . [])))
          (funcall callback
                   200
                   '((data . [((id . "a"))])
                     (has_more . t)
                     (last_id . "a")))
          (should (equal results '((nil . "Page setup failed"))))
          (should-not (omnigent-stream-snapshot-active stream))
          (should-not (omnigent-stream-snapshot-timer stream)))
      (omnigent-transport-stop-session-stream stream))))

(ert-deftest omnigent-transport-snapshot-timeout-delivers-once ()
  "A composite timeout cannot deliver again or schedule an automatic read retry."
  (let* (callback
         results
         (stream
          (omnigent-transport--make-stream
           :session-id "session"
           :attempt 1
           :snapshot-callback
           (lambda (status body) (push (cons status body) results)))))
    (unwind-protect
        (cl-letf (((symbol-function 'omnigent-transport-request)
                   (lambda (_method _path cb &optional _data)
                     (setq callback cb))))
          (omnigent-transport-refresh-session-stream stream)
          (omnigent-transport--snapshot-timeout
           stream 1 (omnigent-stream-snapshot-active stream))
          (should (= (length results) 1))
          (should-not (caar results))
          (should (string-match-p "timed out" (cdar results)))
          (funcall callback
                   200
                   '((pending_inputs . [])
                     (pending_elicitations . [])))
          (should (= (length results) 1))
          (should-not (omnigent-stream-snapshot-active stream))
          (should-not (omnigent-stream-timer stream)))
      (omnigent-transport-stop-session-stream stream))))

(ert-deftest omnigent-transport-snapshot-rejects-malformed-pages ()
  "Reject missing item arrays and broken cursors rather than load empty history."
  (dolist (page
           '(((has_more . :json-false))
             ((data . "bad"))
             ((data . [((id . "a"))]) (has_more . t))
             ((data . []) (has_more . t) (last_id . "a"))))
    (let* (callback
           result
           (stream
            (omnigent-transport--make-stream
             :session-id "session"
             :attempt 1
             :snapshot-callback
             (lambda (status body)
               (setq result (cons status body))))))
      (unwind-protect
          (cl-letf (((symbol-function 'omnigent-transport-request)
                     (lambda (_method _path cb &optional _data)
                       (setq callback cb))))
            (omnigent-transport-refresh-session-stream stream)
            (funcall callback
                     200
                     '((pending_inputs . [])
                       (pending_elicitations . [])))
            (funcall callback 200 page)
            (should result)
            (should-not (car result)))
        (omnigent-transport-stop-session-stream stream)))))

(provide 'omnigent-transport-test)
;;; omnigent-transport-test.el ends here
