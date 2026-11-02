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

(provide 'omnigent-transport-test)
;;; omnigent-transport-test.el ends here
