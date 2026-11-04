;;; omnigent-transport-test.el --- Tests for Omnigent transport -*- lexical-binding: t; -*-

(require 'ert)
(require 'omnigent-transport)

(ert-deftest omnigent-transport-splits-sse-frames-across-chunks ()
  "Keep partial frames until a blank-line delimiter arrives."
  (let* ((first (omnigent-transport--split-sse-frames
                 "" "event: session.status\r\ndata: {\"type\":\"session.status\"}\r"))
         (second (omnigent-transport--split-sse-frames
                  (cdr first) "\n\r\nevent: ping\ndata: 1\n\n")))
    (should (equal (car first) nil))
    (should (equal (car second)
                   '("event: session.status\ndata: {\"type\":\"session.status\"}"
                     "event: ping\ndata: 1")))
    (should (equal (cdr second) ""))))

(ert-deftest omnigent-transport-parses-sse-data-lines ()
  "Ignore comments and join multiple data lines with newlines."
  (should (equal (omnigent-transport--parse-sse-frame
                  ": heartbeat\nevent: response.output_text.delta\ndata: {\"text\":\ndata: \"hi\"}" )
                 '("response.output_text.delta" . "{\"text\":\n\"hi\"}"))))

(ert-deftest omnigent-transport-websocket-url-uses-secure-scheme-when-needed ()
  "Map the configured HTTP URL to the session-updates WebSocket URL."
  (let ((omnigent-server-url "https://example.test/base/"))
    (should (equal (omnigent-transport--updates-url)
                   "wss://example.test/base/v1/sessions/updates")))
  (let ((omnigent-server-url "http://localhost:6767"))
    (should (equal (omnigent-transport--updates-url)
                   "ws://localhost:6767/v1/sessions/updates")))
  (let ((omnigent-server-url "file:///tmp/server"))
    (should-error (omnigent-transport--updates-url) :type 'user-error)))

(ert-deftest omnigent-transport-session-updates-sends-watch-and-parses-frames ()
  "Send watch sets and pass parsed server frames to the callback."
  (let ((real-require (symbol-function 'require))
        (omnigent-server-url "https://example.test")
        (omnigent-token "secret")
        open-args sent frames errors closed)
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'websocket) t
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
      (let ((updates (omnigent-start-session-updates
                      (lambda (frame) (push frame frames))
                      (lambda (error) (push error errors)))))
        (should (equal (car open-args) "wss://example.test/v1/sessions/updates"))
        (should (equal (plist-get (cdr open-args) :custom-header-alist)
                       '(("Authorization" . "Bearer secret"))))
        (funcall (plist-get (cdr open-args) :on-open) 'fake-websocket)
        (should (equal (json-parse-string (car sent) :object-type 'alist
                                          :array-type 'array)
                       '((type . "watch") (session_ids . []))))
        (omnigent-set-session-updates-watch updates '("s1" "s2"))
        (should-error (omnigent-set-session-updates-watch
                       updates (make-list 501 "s"))
                      :type 'user-error)
        (should (equal (cdr (assq 'session_ids
                                  (json-parse-string (car sent)
                                                     :object-type 'alist
                                                     :array-type 'array)))
                       ["s1" "s2"]))
        (funcall (plist-get (cdr open-args) :on-message)
                 'fake-websocket "{\"type\":\"changed\",\"id\":\"s1\"}")
        (should (equal (car frames) '((type . "changed") (id . "s1"))))
        (funcall (plist-get (cdr open-args) :on-message)
                 'fake-websocket "not json")
        (should (string-match-p "Invalid WebSocket JSON" (car errors)))
        (omnigent-stop-session-updates updates)
        (should closed)
        (should (omnigent-session-updates-stopped updates))))))

(ert-deftest omnigent-transport-session-updates-reconnects-with-latest-watch ()
  "Reconnect after close and send the latest complete watch set."
  (let ((real-require (symbol-function 'require))
        (real-run-at-time (symbol-function 'run-at-time))
        (open-callbacks nil) (sent nil) scheduled)
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'websocket) t
                   (funcall real-require feature filename noerror))))
              ((symbol-function 'websocket-open)
               (lambda (_url &rest args)
                 (push args open-callbacks)
                 (intern (format "fake-websocket-%d" (length open-callbacks)))))
              ((symbol-function 'websocket-openp) (lambda (_websocket) t))
              ((symbol-function 'websocket-send-text)
               (lambda (_websocket text) (push text sent)))
              ((symbol-function 'websocket-close) #'ignore)
              ((symbol-function 'run-at-time)
               (lambda (delay _repeat function &rest args)
                 (setq scheduled (list delay function args))
                 (funcall real-run-at-time 3600 nil #'ignore)))
              ((symbol-function 'cancel-timer) #'ignore))
      (let ((updates (omnigent-start-session-updates #'ignore)))
        (omnigent-set-session-updates-watch updates '("old"))
        (funcall (plist-get (car open-callbacks) :on-close)
                 'fake-websocket-1)
        (should (= (car scheduled) omnigent-transport--reconnect-min-delay))
        (omnigent-set-session-updates-watch updates '("new"))
        (funcall (cadr scheduled) (car (caddr scheduled)))
        (should (= (length open-callbacks) 2))
        (funcall (plist-get (car open-callbacks) :on-open) 'fake-websocket-2)
        (should (equal (cdr (assq 'session_ids
                                  (json-parse-string (car sent)
                                                     :object-type 'alist
                                                     :array-type 'array)))
                       ["new"]))
        (omnigent-stop-session-updates updates)))))

(ert-deftest omnigent-transport-session-updates-requires-websocket-package ()
  "Report the optional GNU ELPA dependency when it is missing."
  (let ((real-require (symbol-function 'require)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'websocket) nil
                   (funcall real-require feature filename noerror))))
              ((symbol-function 'omnigent-transport--auth-header) #'ignore))
      (should-error (omnigent-start-session-updates #'ignore)
                    :type 'user-error))))

(provide 'omnigent-transport-test)
;;; omnigent-transport-test.el ends here
