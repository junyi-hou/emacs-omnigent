;;; omnigent-transport-lifecycle-test.el --- Connection lifecycle tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'omnigent-transport)

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
