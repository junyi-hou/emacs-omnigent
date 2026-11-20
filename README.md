# Omnigent for Emacs

[Omnigent](https://github.com/omnigent-ai/omnigent) is a platform for running
coding agents: multiple supported agents, persistent sessions, sandboxes, and
policies. This project brings Omnigent to Emacs as an interactive frontend.

The goal of this project is to create a chat-centered omnignt interface in
emacs: connect to an Omnigent server, pick a session, chat with the agent,
and follow child sessions and workspace changes from inside Emacs. See
[docs/frontend.md](docs/frontend.md) for the UI plan and
[docs/transport.md](docs/transport.md) for the transport layer.

## Project status

Alpha. The v1 session, conversation, elicitation, and workspace views are
implemented.

What works:

- HTTP REST requests, plus reconnecting SSE session streams and session-updates
  WebSocket connections (`omnigent-transport.el`).
- Start or reuse a local server and local execution host from the Omnigent CLI
  (`omnigent-start-server`).
- Select an existing local or remote server with `omnigent-connect`, without
  starting a local process. Remote-server authentication is not implemented yet.
- Run `omnigent-sessions-create` or enter `/new` for quick creation. Use
  `C-u` with the command to review and edit the session in a Transient menu.
  Both paths use the defaults in the `omnigent-session-creation` Customize
  group. Quick creation prompts only for missing required settings.

- Conversation state, snapshot parsing, and message and interrupt requests
  (`omnigent-conversation.el`).

- Optional session and workspace side windows, streamed plain-text transcripts,
  collapsed tool and reasoning blocks, and inline elicitation forms
  (`omnigent-ui.el`).

## Installation

Choose one of these configurations for your Emacs initialization file.

With Elpaca:

```elisp
(use-package omnigent
  :ensure (:host github :repo "junyi-hou/omnigent-emacs"))
```

With straight.el:

```elisp
(use-package omnigent
  :straight (:host github :repo "junyi-hou/omnigent-emacs"))
```

With `use-package-vc` (Emacs 30 or later):

```elisp
(use-package omnigent
  :vc (:url "https://github.com/junyi-hou/omnigent-emacs"))
```

Install `curl` for session streams and `diff` for workspace patches.

## Using the frontend

1. Connect to an existing server with `M-x omnigent-connect`. Alternatively, use
   `M-x omnigent-start-server` for a local server and host.
2. Run `M-x omnigent-ui-sessions` to show or hide the session list. Use `RET` to open a
   session, `c` to create one, `g` to refresh, `s` to stop, or `d` to delete after
   confirmation.
3. Type after `> ` in a conversation. `RET` inserts a newline. `C-c C-c` sends
   the composer; `C-c C-k` interrupts the session. Activate tool and reasoning
   headings to expand or collapse their bodies.
4. Use `TAB` and `S-TAB` to navigate elicitation fields and actions. Secret
   fields use a masked minibuffer prompt, not clear text in the transcript.
5. Run `M-x omnigent-ui-workspace` to show or hide workspace changes. Use `RET` for a
   fresh file or combined diff, or `g` to refresh the file list. The panel opens
   automatically for changed files until you close it yourself.
6. Run `M-x omnigent-disconnect` to stop client connections and close
   conversation and workspace buffers. This discards unsent drafts but does not
   stop agents.

Session lists refresh after ten seconds of idle time, including when hidden.
Workspace refresh failures retain the previous view without a notification.
Transcript text uses plain text, not Markdown rendering.

### Side chat

Run `M-x omnigent-conversation-side-chat` or submit `/side` to open a
private fork with the current conversation's history. Use `/side QUESTION`
to send a question in the side chat. The source session must have a
connected runner. Customize `omnigent-side-chat-display-action` to change
where Emacs opens the chat. `/btw` and `/btw QUESTION` work the same way.

#### Ask for a one-shot answer from Lisp

Call this example from the source conversation with lexical binding enabled.
It opens a hidden side chat and sends one question. The open callback
receives the HTTP status and the new buffer on success.

```elisp
(defun my-side-chat-send (question observe)
  "Send QUESTION in a hidden side chat and pass its events to OBSERVE."
  (let ((omnigent-side-chat-display-action nil))
    (omnigent-conversation-side-chat
     (lambda (status body)
       (if (omnigent-transport-success-p status)
           (with-current-buffer body
             (add-hook 'omnigent-conversation-event-hook observe nil t)
             (letrec ((send-when-ready
                       (lambda ()
                         (unless buffer-read-only
                           (remove-hook 'omnigent-conversation-change-hook
                                        send-when-ready t)
                           (goto-char (point-max))
                           (insert question)
                           (omnigent-conversation-send)))))
               (add-hook 'omnigent-conversation-change-hook
                         send-when-ready t t)
               (funcall send-when-ready)))
         (message "%s" (omnigent-transport-error-message
                        "Open side chat" status body)))))))
```

`send-when-ready` checks the composer immediately and after each
conversation change. Once the composer is writable, the function removes
itself before sending. `letrec` lets the function refer to itself for that
removal.  The send command treats a leading slash as a possible slash
command.

Your `observe` function receives `(EVENT-NAME DATA)` in the side chat
buffer.  Collect the assistant messages for the new turn from
`response.output_item.done` events. Use the answer when that turn finishes.
An empty `response.completed` can acknowledge native input delivery before
the agent answers. Handle failures and set a timeout for the exchange.  Kill
the buffer when you finish or give up. The server retains the side chat and
its history. See [Side chat](docs/conversation-buffer.md#side-chat) for turn
tracking and the bufferless API.

Run unit tests and both native integration suites separately:

```sh
make test-deps
make unit-test
make integration-test HARNESS=claude-native
make integration-test HARNESS=codex-native
```

`make test-deps` installs Evil, WebSocket, `markdown-mode`, `f`, `s`, and their
dependencies in `.tools/test-elpa`. Evil is not a runtime dependency. After
setup, unit tests run offline. Integration tests need network access for
dependency installation.

`make test HARNESS=claude-native` runs unit tests and the selected integration
suite together; the default harness is `claude-native`. See
[test/README.md](test/README.md) for details.

The client can open at most 500 conversation buffers at once, because the server
limits the WebSocket watch set to 500 sessions. This should be more than enough
for normal use.

The v1 workspace diff treats missing file contents as empty. If Omnigent fails
to read a Git baseline, the diff can show existing lines as additions or omit a
deleted file. Omnigent does not distinguish that failure from a new file.

## TODO

- [ ] Design client-to-server retry for requests with no confirmed response, including
      messages and elicitation responses the server may already have accepted.
- [ ] Support workspace diffs for non-Git workspaces.
- [ ] Fetch older conversation items on demand.

## Sources

- [Omnigent repository and README](https://github.com/omnigent-ai/omnigent)
- [Server API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md)
- [Programmatic usage](https://omnigent.ai/docs/programmatic)
