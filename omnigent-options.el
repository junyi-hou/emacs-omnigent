;;; omnigent-options.el --- Omnigent user options -*- lexical-binding: t; -*-

;;; Commentary:
;; User options shared by Omnigent modules.

;;; Code:

(defgroup omnigent nil
  "Interact with Omnigent servers."
  :group 'applications)

(defgroup omnigent-transport nil
  "Transport settings for Omnigent."
  :group 'applications)

(defcustom omnigent-executable "omnigent"
  "Omnigent CLI executable used to start the local server."
  :type 'file
  :group 'omnigent)

(defcustom omnigent-open-session-list-on-connect t
  "When non-nil, open the session list after connecting to a server."
  :type 'boolean
  :group 'omnigent)

(defcustom omnigent-server-url "http://127.0.0.1:6767"
  "Base URL of the Omnigent server."
  :type 'string
  :group 'omnigent-transport)

(defcustom omnigent-transport-session-limit 1000
  "Maximum number of sessions to fetch, between 1 and 1000."
  :type 'integer
  :group 'omnigent-transport)

(defcustom omnigent-transport-history-limit 5000
  "Maximum number of committed conversation items to load and keep.
This limit does not control live events buffered during recovery; see
`omnigent-conversation-recovery-event-limit'."
  :type '(integer :tag "Items")
  :group 'omnigent-transport)

(defcustom omnigent-transport-snapshot-timeout 30
  "Maximum seconds for a complete composite session snapshot."
  :type 'number
  :group 'omnigent-transport)

(defcustom omnigent-transport-connect-timeout 30
  "Maximum seconds to receive a stream frame or open a WebSocket."
  :type 'number
  :group 'omnigent-transport)

(defcustom omnigent-transport-inactivity-timeout 90
  "Seconds without stream traffic before reconnecting.
Omnigent 0.21.0 sends SSE heartbeats every 15 seconds and WebSocket
heartbeats after 30 idle seconds.  Allow additional time for proxies."
  :type 'number
  :group 'omnigent-transport)

(defcustom omnigent-conversation-recovery-event-limit 10000
  "Maximum live events buffered while a recovery snapshot loads.
One conversation item can produce many events, including text deltas.
This limit is separate from `omnigent-transport-history-limit', which
counts committed items.  Overflow invalidates the conversation."
  :type 'integer
  :group 'omnigent-transport)

(defcustom omnigent-conversation-recovery-byte-limit (* 8 1024 1024)
  "Maximum approximate serialized bytes buffered during a snapshot read."
  :type 'integer
  :group 'omnigent-transport)

(provide 'omnigent-options)
;;; omnigent-options.el ends here
