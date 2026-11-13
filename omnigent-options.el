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

(defcustom omnigent-conversation-mode-map
  (let ((map (make-sparse-keymap)))
    (require 'text-mode)
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'omnigent-conversation-send)
    (define-key map (kbd "C-c C-k") #'omnigent-conversation-interrupt)
    (define-key map (kbd "TAB") #'widget-forward)
    (define-key map (kbd "<backtab>") #'widget-backward)
    (define-key map (kbd "C-c C-s") #'omnigent-ui-stop)
    map)
  "Keymap for `omnigent-conversation-mode'."
  :type 'keymap
  :group 'omnigent)

(defcustom omnigent-ui-sessions-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'omnigent-ui-sessions-open)
    (define-key map (kbd "g") #'omnigent-ui-refresh)
    (define-key map (kbd "c") #'omnigent-sessions-create)
    (define-key map (kbd "s") #'omnigent-ui-stop)
    (define-key map (kbd "d") #'omnigent-ui-delete)
    (define-key map (kbd "C-c C-n") #'omnigent-sessions-create)
    map)
  "Keymap for `omnigent-ui-sessions-mode'."
  :type 'keymap
  :group 'omnigent)

(defcustom omnigent-ui-workspace-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'omnigent-ui-workspace-diff)
    (define-key map (kbd "g") #'omnigent-ui-workspace-refresh)
    map)
  "Keymap for the workspace side view."
  :type 'keymap
  :group 'omnigent)

(defcustom omnigent-executable "omnigent"
  "Omnigent CLI executable used to start the local server."
  :type 'file
  :group 'omnigent)

(defcustom omnigent-open-session-list-on-connect t
  "When non-nil, open the session list after connecting to a server."
  :type 'boolean
  :group 'omnigent)

(defcustom omnigent-workspace-diff-mode #'diff-mode
  "Function called in the workspace diff buffer after inserting the diff.
The function takes no arguments."
  :type 'function
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
