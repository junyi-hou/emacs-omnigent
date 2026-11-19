;;; omnigent-options.el --- Omnigent user options -*- lexical-binding: t; -*-

;;; Commentary:
;; User options shared by Omnigent modules.

;;; Code:

(require 'url-parse)

(defgroup omnigent nil
  "Interact with Omnigent servers."
  :group 'applications)

(defgroup omnigent-transport nil
  "Transport settings for Omnigent."
  :group 'applications)

(defgroup omnigent-session-creation nil
  "Defaults shared by quick session creation and the creation menu."
  :group 'omnigent)

(defcustom omnigent-session-default-host-type nil
  "Execution host type for new sessions.  Nil uses the server default."
  :type
  '(choice
    (const :tag "Use default" nil)
    (const "external")
    (const "managed"))
  :group 'omnigent-session-creation)

(defcustom omnigent-session-default-host nil
  "Execution host ID for new external sessions.
Nil allows the current session or the host picker to supply the host."
  :type '(choice (const :tag "Use default" nil) string)
  :group 'omnigent-session-creation)

(defcustom omnigent-session-default-workspace nil
  "Absolute workspace path on the execution host for new external sessions.
Nil allows the current session or the workspace picker to supply the path."
  :type '(choice (const :tag "Use default" nil) string)
  :group 'omnigent-session-creation)

(defcustom omnigent-session-default-agent nil
  "Registered agent ID for new sessions.  Nil prompts for an agent."
  :type '(choice (const :tag "Use default" nil) string)
  :group 'omnigent-session-creation)

(defcustom omnigent-session-default-model nil
  "Model ID for new sessions.  Nil uses the agent default."
  :type '(choice (const :tag "Use default" nil) string)
  :group 'omnigent-session-creation)

(defcustom omnigent-session-default-reasoning-effort nil
  "Reasoning effort for new sessions.  Nil uses the agent default."
  :type
  '(choice
    (const :tag "Use default" nil)
    (const "none")
    (const "minimal")
    (const "low")
    (const "medium")
    (const "high")
    (const "xhigh")
    (const "max")
    (const "ultra"))
  :group 'omnigent-session-creation)

(defcustom omnigent-session-default-title nil
  "Title for new sessions.  Nil lets the server derive a title."
  :type '(choice (const :tag "Use default" nil) string)
  :group 'omnigent-session-creation)

(defcustom omnigent-session-default-launch-arguments nil
  "Native launch arguments for new sessions, as a list of strings.
Nil uses the harness defaults."
  :type '(repeat string)
  :group 'omnigent-session-creation)

(defcustom omnigent-session-default-sandbox-provider nil
  "Provider for new managed sandboxes.  Nil uses the server default."
  :type '(choice (const :tag "Use default" nil) string)
  :group 'omnigent-session-creation)

(defcustom omnigent-session-default-sandbox-profile nil
  "Profile ID for new managed sandboxes.  Nil prompts when required."
  :type '(choice (const :tag "Use default" nil) string)
  :group 'omnigent-session-creation)

(defcustom omnigent-session-default-sandbox-profile-revision nil
  "Expected revision of the default sandbox profile.
This applies only when a default profile ID is set."
  :type '(choice (const :tag "Use default" nil) string)
  :group 'omnigent-session-creation)

(defcustom omnigent-session-default-sandbox-repositories nil
  "Git repository URLs for new managed sandboxes, as a list of strings.
A URL can include a #branch fragment.  Nil uses an empty workspace."
  :type '(repeat string)
  :group 'omnigent-session-creation)

(defcustom omnigent-session-default-worktree-branch nil
  "New worktree branch for external sessions.  Nil uses the workspace in place."
  :type '(choice (const :tag "Use default" nil) string)
  :group 'omnigent-session-creation)

(defcustom omnigent-session-default-worktree-base-branch nil
  "Base ref for the default worktree branch.  Nil uses the repository HEAD."
  :type '(choice (const :tag "Use default" nil) string)
  :group 'omnigent-session-creation)

(defcustom omnigent-conversation-mode-map
  (let ((map (make-sparse-keymap)))
    (require 'text-mode)
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'omnigent-conversation-send)
    (define-key map (kbd "C-c C-k") #'omnigent-conversation-interrupt)
    (define-key map (kbd "C-c C-r") #'omnigent-conversation-reconnect)
    (define-key map (kbd "C-c C-f") #'omnigent-conversation-fork)
    (define-key map (kbd "C-c C-m") #'omnigent-conversation-set-model)
    (define-key
     map (kbd "C-c C-e") #'omnigent-conversation-set-effort)
    (define-key map (kbd "TAB") #'widget-forward)
    (define-key map (kbd "<backtab>") #'widget-backward)
    (define-key map (kbd "C-c C-a") #'omnigent-conversation-archive)
    (define-key map (kbd "C-c C-d") #'omnigent-ui-delete)
    map)
  "Keymap for `omnigent-conversation-mode'."
  :type 'keymap
  :group 'omnigent)

(defcustom omnigent-ui-sessions-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'omnigent-ui-sessions-open)
    (define-key map (kbd "TAB") #'omnigent-ui-toggle-project)
    (define-key map (kbd "<tab>") #'omnigent-ui-toggle-project)
    (define-key map (kbd "m") #'omnigent-ui-move-session)
    (define-key map (kbd "g") #'omnigent-ui-refresh)
    (define-key map (kbd "+") #'omnigent-ui-increase-session-limit)
    (define-key map (kbd "-") #'omnigent-ui-decrease-session-limit)
    (define-key map (kbd "A") #'omnigent-ui-toggle-archived-sessions)
    (define-key map (kbd "c") #'omnigent-sessions-create)
    (define-key map (kbd "a") #'omnigent-ui-archive)
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
    (define-key map (kbd "f") #'omnigent-ui-workspace-visit-file)
    (define-key map (kbd "g") #'omnigent-ui-workspace-refresh)
    (define-key
     map (kbd "C-c C-g") #'omnigent-ui-workspace-magit-status)
    map)
  "Keymap for the workspace side view."
  :type 'keymap
  :group 'omnigent)

(defcustom omnigent-executable "omnigent"
  "Omnigent CLI executable used to start the local server."
  :type 'file
  :group 'omnigent)

(defcustom omnigent-host-address-function
  (lambda (_host-id)
    (url-host (url-generic-parse-url omnigent-server-url)))
  "Function that returns the address for an Omnigent host ID.
The function takes one host ID string and returns an address string.
The address `localhost' means the host in `omnigent-server-url'.
The default returns the host in `omnigent-server-url'.
Configure this function when a runner is on a different host."
  :type 'function
  :group 'omnigent)

(defcustom omnigent-open-session-list-on-connect t
  "When non-nil, open the session list after connecting to a server."
  :type 'boolean
  :group 'omnigent)

(defcustom omnigent-fetch-archived-sessions nil
  "When non-nil, include archived sessions in the session list."
  :type 'boolean
  :group 'omnigent)

(defcustom omnigent-side-window-width 0.25
  "Initial width of the session and workspace side windows.
An integer specifies columns; a float specifies a fraction of frame width.
When nil, let Emacs choose the width."
  :type '(choice (const :tag "Emacs default" nil) integer float)
  :group 'omnigent)

(defcustom omnigent-workspace-window-height 15
  "Initial height of the workspace side window.
An integer specifies lines; a float specifies a fraction of frame height.
When nil, let Emacs choose the height."
  :type '(choice (const :tag "Emacs default" nil) integer float)
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

(defcustom omnigent-auth-method 'none
  "Authentication method used with the Omnigent server.
`token' sends a bearer token from `omnigent-auth-token-function'.
`none' sends no authentication credentials."
  :type
  '(choice
    (const :tag "No authentication" none)
    (const :tag "Bearer token" token))
  :group 'omnigent-transport)

(defcustom omnigent-auth-token-function nil
  "Function that returns the bearer token for server requests.
The function takes no arguments.  Set `omnigent-auth-method' to `token'
to use the returned token.  The function is called for every request."
  :type '(choice (const :tag "None" nil) (function :tag "Token function"))
  :group 'omnigent-transport)

(defcustom omnigent-extra-headers nil
  "Additional headers sent with REST, SSE, and WebSocket requests.
Each entry is (HEADER-NAME . VALUE).  VALUE is a string or a function.
The function receives the session ID, or nil for a request without one.
A nil return value omits the header.  Authentication headers take precedence."
  :type
  '(alist
    :key-type string
    :value-type
    (choice
     (function :tag
               "Header value function called with the session ID")
     (string :tag "constant header value")))
  :group 'omnigent-transport)

(defcustom omnigent-transport-session-limit 20
  "Number of sessions to fetch initially, between 1 and 1000."
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

(defcustom omnigent-conversation-auto-recovery t
  "When non-nil, retry temporary session snapshot failures automatically.
When nil, use `omnigent-conversation-reconnect' to recover manually.
This option does not disable normal stream reconnection."
  :type 'boolean
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
