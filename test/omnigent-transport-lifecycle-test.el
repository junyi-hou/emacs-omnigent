;;; omnigent-transport-lifecycle-test.el --- Connection lifecycle tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'omnigent-transport)

(ert-deftest omnigent-transport-stream-reconnect-backoff ()
  "Increase retry delays after failures, without exceeding the cap."
  (should (equal (mapcar #'omnigent-transport--reconnect-delay '(0 1 2 3 4 5 10))
                 '(1.0 1.0 2.0 4.0 8.0 15.0 15.0))))

(ert-deftest omnigent-transport-stream-exit-schedules-reconnect ()
  "Retry failed, clean, and DONE exits; do not retry a stopped stream."
  (dolist (case '((1 nil nil 3 4.0) (0 nil nil 0 1.0)
                  (1 t nil 0 1.0) (1 nil t 2 nil)))
    (pcase-let* ((`(,exit-code ,done ,stopped ,failures ,delay) case)
                 (errors nil)
                 (stream (omnigent-transport--make-stream
                          :stopped stopped :failures 2 :process 'process
                          :error-callback (lambda (error) (push error errors))))
                 (stderr (generate-new-buffer " *omnigent-test-stderr*"))
                 (scheduled nil))
      (unwind-protect
          (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
                    ((symbol-function 'process-exit-status) (lambda (_) exit-code))
                    ((symbol-function 'process-get)
                     (lambda (_ key)
                       (pcase key ('omnigent-stream stream)
                              ('omnigent-stderr stderr) ('omnigent-done done))))
                    ((symbol-function 'run-at-time)
                     (lambda (&rest args) (setq scheduled args) 'retry)))
            (with-current-buffer stderr (insert "curl failed\n"))
            (omnigent-transport--stream-sentinel 'process "exited")
            (should-not (buffer-live-p stderr))
            (should-not (omnigent-stream-process stream))
            (should (= (omnigent-stream-failures stream) failures))
            (if delay
                (should (equal scheduled
                               (list delay nil #'omnigent-transport--stream-connect stream)))
              (should-not scheduled))
            (should (equal errors
                           (when (and (/= exit-code 0) (not done) (not stopped))
                             '("curl failed")))))
        (when (buffer-live-p stderr) (kill-buffer stderr))))))

(ert-deftest omnigent-transport-stream-connect-fetches-each-snapshot ()
  "Fetch a snapshot after each connection, ignoring old or stopped attempts."
  (let* ((connected 0) snapshots callbacks properties
         (stream (omnigent-transport--make-stream
                  :session-id "session" :failures 0 :attempt 0
                  :connect-callback (lambda () (cl-incf connected))
                  :snapshot-callback (lambda (status body) (push (cons status body) snapshots)))))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (push (plist-get args :stderr) properties)
                 'process))
              ((symbol-function 'process-put) #'ignore)
              ((symbol-function 'omnigent-transport--stream-load-snapshot)
               (lambda (target attempt)
                 (push (lambda (status body)
                         (omnigent-transport--stream-snapshot target attempt status body))
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
        (mapc #'kill-buffer properties)))))

(ert-deftest omnigent-transport-stream-loads-bounded-history ()
  (let* ((omnigent-transport-history-limit 1001) requests result
         (stream (omnigent-transport--make-stream
                  :session-id "session" :attempt 1
                  :snapshot-callback (lambda (status body) (setq result (cons status body))))))
    (cl-letf (((symbol-function 'omnigent-transport-request)
               (lambda (_method path callback &optional _data)
                 (push (cons path callback) requests))))
      (omnigent-transport--stream-load-snapshot stream 1)
      (should (equal (caar requests) "/v1/sessions/session?include_items=false"))
      (funcall (cdar requests) 200 '((pending_elicitations . [])))
      (should (equal (caar requests) "/v1/sessions/session/items?limit=1000&order=desc"))
      (funcall (cdar requests) 200
               `((data . ,(vconcat (mapcar (lambda (n) `((id . ,n))) (number-sequence 1001 2 -1))))
                 (has_more . t) (last_id . "cursor /")))
      (should (equal (caar requests) "/v1/sessions/session/items?limit=1&order=desc&after=cursor%20%2F"))
      (funcall (cdar requests) 200 '((data . [((id . 1))]) (has_more . :json-false)))
      (let ((items (alist-get 'items (cdr result))))
        (should (= (length items) 1001))
        (should (= (alist-get 'id (aref items 0)) 1))
        (should (= (alist-get 'id (aref items 1000)) 1001))))))

(ert-deftest omnigent-transport-stream-start-failure-and-stop ()
  "Retry process creation failures, then cancel the retry when stopped."
  (let* ((omnigent-transport--streams nil)
         (stderr nil) errors scheduled cancelled
         (timer (run-at-time 3600 nil #'ignore))
         (stream (omnigent-transport--make-stream
                  :session-id "session" :attempt 0 :failures 0
                  :error-callback (lambda (error) (push error errors)))))
    (unwind-protect
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest args)
                     (setq stderr (plist-get args :stderr))
                     (error "Cannot start curl")))
                  ((symbol-function 'run-at-time)
                   (lambda (&rest args) (setq scheduled args) timer))
                  ((symbol-function 'cancel-timer)
                   (lambda (value) (setq cancelled value))))
          (push stream omnigent-transport--streams)
          (omnigent-transport--stream-connect stream)
          (should-not (buffer-live-p stderr))
          (should (equal errors '("Cannot start curl")))
          (should (= (omnigent-stream-failures stream) 1))
          (should (equal scheduled (list 1.0 nil #'omnigent-transport--stream-connect stream)))
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
  (let* (events deleted
         (stream (omnigent-transport--make-stream
                  :event-callback (lambda (&rest event) (push event events))))
         (properties (list 'omnigent-stream stream)))
    (cl-letf (((symbol-function 'process-get)
               (lambda (_ key) (plist-get properties key)))
              ((symbol-function 'process-put)
               (lambda (_ key value) (setq properties (plist-put properties key value))))
              ((symbol-function 'delete-process) (lambda (_) (setq deleted t))))
      (omnigent-transport--stream-filter
       'process "data: {\"n\":1}\n\ndata: [DONE]\n\ndata: {\"n\":2}\n\n")
      (should deleted)
      (should (plist-get properties 'omnigent-done))
      (should (equal events '(("message" ((n . 1)))))))))

(ert-deftest omnigent-transport-updates-ignore-stale-callbacks ()
  "Old attempts and stopped handles cannot deliver callbacks or reconnect."
  (let* ((frames 0) (errors 0) (opens 0) (scheduled 0) (sent 0)
         (updates (omnigent-transport--make-session-updates
                   :attempt 2 :failures 0 :websocket 'current
                   :frame-callback (lambda (_) (cl-incf frames))
                   :error-callback (lambda (_) (cl-incf errors))
                   :open-callback (lambda () (cl-incf opens)))))
    (cl-letf (((symbol-function 'websocket-frame-text) #'identity)
              ((symbol-function 'websocket-openp) (lambda (_) t))
              ((symbol-function 'websocket-send-text) (lambda (&rest _) (cl-incf sent)))
              ((symbol-function 'run-at-time) (lambda (&rest _) (cl-incf scheduled))))
      (dolist (attempt '(1 2))
        (when (= attempt 2) (setf (omnigent-session-updates-stopped updates) t))
        (omnigent-transport--updates-opened updates 'old attempt)
        (omnigent-transport--updates-message updates 'old attempt "{}")
        (omnigent-transport--updates-error updates attempt 'old 'error '(error "late"))
        (omnigent-transport--updates-closed updates attempt 'old))
      (should (eq (omnigent-session-updates-websocket updates) 'current))
      (should (= (omnigent-session-updates-failures updates) 0))
      (should (equal (list frames errors opens scheduled sent) '(0 0 0 0 0))))))

(ert-deftest omnigent-transport-callback-cleans-up-original-response-buffer ()
  "Keep a buffer selected by the callback and kill only the HTTP response."
  (let ((response (generate-new-buffer " *omnigent-response*"))
        (conversation (generate-new-buffer " *omnigent-conversation*")))
    (unwind-protect
        (save-current-buffer
          (set-buffer response)
          (insert "{}")
          (omnigent-transport--url-callback
           nil (lambda (&rest _) (set-buffer conversation))
           omnigent-transport--generation)
          (should-not (buffer-live-p response))
          (should (buffer-live-p conversation)))
      (when (buffer-live-p response) (kill-buffer response))
      (when (buffer-live-p conversation) (kill-buffer conversation)))))

(ert-deftest omnigent-transport-reset-invalidates-old-work ()
  "Stop registered connections and ignore callbacks from the old server."
  (let* ((omnigent-transport--generation 0)
         (stream (omnigent-transport--make-stream :stopped nil))
         (updates (omnigent-transport--make-session-updates :stopped nil))
         (omnigent-transport--streams (list stream))
         (omnigent-transport--updates (list updates))
         called)
    (omnigent-transport-reset)
    (should (omnigent-stream-stopped stream))
    (should (omnigent-session-updates-stopped updates))
    (should-not omnigent-transport--streams)
    (should-not omnigent-transport--updates)
    (with-temp-buffer
      (omnigent-transport--url-callback nil (lambda (&rest _) (setq called t)) 0))
    (should-not called)))
