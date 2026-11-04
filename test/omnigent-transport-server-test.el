;;; omnigent-transport-server-test.el --- Omnigent server integration test -*- lexical-binding: t; -*-

(require 'ert)
(require 'omnigent)
(require 'websocket)

(setq omnigent-server-url
      (or (getenv "OMNIGENT_TEST_SERVER_URL")
          (error "OMNIGENT_TEST_SERVER_URL is not set")))

(ert-deftest omnigent-transport-requests-session-list-from-server ()
  "Check that the REST client reads the session list from a live server."
  (let (done result)
    (omnigent-list-sessions
     (lambda (status body)
       (setq result (cons status body)
             done t)))
    (with-timeout (10 (ert-fail "Omnigent server request timed out"))
      (while (not done)
        (accept-process-output nil 0.1)))
    (should (equal (car result) 200))
    (should (equal (cdr (assq 'object (cdr result))) "list"))
    (should (vectorp (cdr (assq 'data (cdr result)))))))

(ert-deftest omnigent-transport-session-updates-uses-live-websocket ()
  "Receive session snapshots and changes over a live WebSocket connection."
  (let ((omnigent-current-session-id nil)
        (omnigent-current-session nil)
        frames stream-error updates patch-result)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt _choices &rest args) (nth 4 args))))
            (omnigent-connect omnigent-server-url)
            (with-timeout (20 (ert-fail "Timed out creating a session"))
              (while (not omnigent-current-session-id)
                (accept-process-output nil 0.1))))
          (setq updates
                (omnigent-start-session-updates
                 (lambda (frame) (push frame frames))
                 (lambda (error) (setq stream-error error))))
          (omnigent-set-session-updates-watch
           updates (list omnigent-current-session-id))
          (with-timeout (15 (ert-fail "Timed out waiting for WebSocket snapshot"))
            (while (not (cl-some (lambda (frame)
                                   (equal (cdr (assq 'type frame)) "snapshot"))
                                 frames))
              (accept-process-output nil 0.1)))
          (let* ((snapshot (cl-find-if
                            (lambda (frame)
                              (equal (cdr (assq 'type frame)) "snapshot"))
                            frames))
                 (items (cdr (assq 'items snapshot))))
            (should (cl-some (lambda (item)
                               (equal (cdr (assq 'id item))
                                      omnigent-current-session-id))
                             (append items nil))))
          (omnigent-request
           "PATCH"
           (omnigent-transport--session-path omnigent-current-session-id)
           (lambda (status body) (setq patch-result (cons status body)))
           '(("title" . "websocket-updated")))
          (with-timeout (10 (ert-fail "Timed out updating session title"))
            (while (not patch-result) (accept-process-output nil 0.1)))
          (should (equal (car patch-result) 200))
          (with-timeout (15 (ert-fail "Timed out waiting for WebSocket change"))
            (while (not (cl-some
                         (lambda (frame)
                           (and (equal (cdr (assq 'type frame)) "changed")
                                (cl-some
                                 (lambda (item)
                                   (and (equal (cdr (assq 'id item))
                                               omnigent-current-session-id)
                                        (equal (cdr (assq 'title item))
                                               "websocket-updated")))
                                 (append (cdr (assq 'items frame)) nil))))
                         frames))
              (accept-process-output nil 0.1)))
          (should-not stream-error))
      (when updates (omnigent-stop-session-updates updates)))))

(ert-deftest omnigent-connect-creates-default-session-and-receives-event ()
  "Select New session, then receive a transient SSE event from the server."
  (let ((omnigent-current-session-id nil)
        snapshot acknowledgement received stream-error stream)
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (_prompt _choices &rest args) (nth 4 args))))
            (omnigent-connect omnigent-server-url)
            (with-timeout (20 (ert-fail "Timed out creating a new session"))
              (while (not omnigent-current-session-id)
                (accept-process-output nil 0.1))))
          (setq stream
                (omnigent-start-session-stream
                 omnigent-current-session-id
                 (lambda (name data)
                   (when (equal name "response.output_text.delta")
                     (setq received data)))
                 (lambda (status body)
                   (setq snapshot (cons status body)))
                 (lambda (error)
                   (setq stream-error error))))
          (with-timeout (20 (ert-fail "Timed out waiting for a server SSE event"))
            (while (not snapshot)
              (accept-process-output nil 0.1))
            (should (equal (car snapshot) 200))
            (omnigent-post-session-event
             omnigent-current-session-id
             '(("type" . "external_output_text_delta")
               ("data" . (("delta" . "transport-test"))))
             (lambda (status body)
               (setq acknowledgement (cons status body))))
            (while (not (and acknowledgement received))
              (accept-process-output nil 0.1)))
          (should (equal (car acknowledgement) 202))
          (should (equal (cdr (assq 'delta received)) "transport-test"))
          (should-not stream-error))
      (when stream
        (omnigent-stop-session-stream stream)))))

(provide 'omnigent-transport-server-test)
;;; omnigent-transport-server-test.el ends here
