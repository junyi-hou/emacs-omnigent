# Omnigent for Emacs

[Omnigent](https://github.com/omnigent-ai/omnigent) is a platform for running coding
agents: multiple supported agents, persistent sessions, sandboxes, and policies. This
project brings Omnigent to Emacs as an interactive frontend.

The goal of this project is to create a chat-centered omnignt interface in emacs:
connect to an Omnigent server, pick a session, chat with the agent, and follow child
sessions and workspace changes from inside Emacs. See
[docs/frontend.md](docs/frontend.md) for the UI plan and
[docs/transport.md](docs/transport.md) for the transport layer.

## Project status

Alpha. The v1 session, conversation, elicitation, and workspace views are implemented.

What works:

- HTTP REST requests, plus reconnecting SSE session streams and session-updates
  WebSocket connections (`omnigent-transport.el`).
- Start or reuse a local server and local execution host from the Omnigent CLI
  (`omnigent-start-server`).
- Select an existing local or remote server with `omnigent-connect`, without starting a
  local process. Remote-server authentication is not implemented yet.
- Run `omnigent-sessions-create` or enter `/new` for quick creation. Use `C-u` with the
  command to review and edit the session in a Transient menu.  Both paths use the
  defaults in the `omnigent-session-creation` Customize group. Quick creation prompts
  only for missing required settings.

- Conversation state, snapshot parsing, and message and interrupt requests
  (`omnigent-conversation.el`).

- Optional session and workspace side windows, streamed plain-text transcripts,
  collapsed tool and reasoning blocks, and inline elicitation forms (`omnigent-ui.el`).

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

1. Connect to an existing server with `M-x omnigent-connect`. Alternatively, use `M-x
   omnigent-start-server` for a local server and host.
2. Run `M-x omnigent-ui-sessions` to show or hide the session list. Use `RET` to open a
   session, `c` to create one, `g` to refresh, `s` to stop, or `d` to delete after
   confirmation.
3. Type after `> ` in a conversation. `RET` inserts a newline. `C-c C-c` sends the
   composer; `C-c C-k` interrupts the session. Activate tool and reasoning headings to
   expand or collapse their bodies.
4. Use `TAB` and `S-TAB` to navigate elicitation fields and actions. Secret fields use a
   masked minibuffer prompt, not clear text in the transcript.
5. Run `M-x omnigent-ui-workspace` to show or hide workspace changes. Use `RET` for a
   fresh file or combined diff, or `g` to refresh the file list. The panel opens
   automatically for changed files until you close it yourself.
6. Run `M-x omnigent-disconnect` to stop client connections and close conversation and
   workspace buffers. This discards unsent drafts but does not stop agents.

Session lists refresh after ten seconds of idle time, including when hidden.  Workspace
refresh failures retain the previous view without a notification.  Transcript text uses
plain text, not Markdown rendering.

### Side chat

Run `M-x omnigent-conversation-side-chat` or submit `/side` to open a private fork with
the current conversation's history. Use `/side QUESTION` to send a question in the side
chat. The source session must have a connected runner. Customize
`omnigent-side-chat-display-action` to change where Emacs opens the chat. `/btw` and
`/btw QUESTION` work the same way.

#### Generate a session title

Press `C-c C-t` in a conversation to generate a title from recent messages. You can also
run `M-x omnigent-ui-generate-session-title` with point on a session in the list. The
command uses the bufferless side-chat API and applies the title to the source
session. See the [side-chat API](docs/conversation-buffer.md#side-chat) for stream and
turn tracking details.

#### Ask for a one-shot answer from Lisp

Call `omnigent-side-chat-ask` with the source session ID, a question, and a
callback. This example prints the answer in the echo area.

```elisp
(omnigent-side-chat-ask
 omnigent-conversation-session-id
 "What did we decide in the last exchange?"
 (lambda (status body)
   (message "%s"
            (if (omnigent-transport-success-p status)
                body
              (omnigent-transport-error-message
               "Ask side chat" status body)))))
```

Run this example in the source conversation, or pass its session ID explicitly. The
function waits for the private fork, sends the question, and calls back with the final
assistant message or an error. It closes the stream when the exchange ends. The server
retains the private fork and its history. See [Side
chat](docs/conversation-buffer.md#side-chat) for connection and turn handling.

## Tests

Run unit tests with these commands.

```sh
make test-deps
make unit-test
```

`make test-deps` installs the Emacs test packages in `.tools/test-elpa`.  For the live
smoke test, run `make integration-deps` and then `make integration-test`. See the
[integration testing guide](docs/integration-testing.md) for the required tools and
checkout.

The client can open at most 500 conversation buffers at once, because the server limits
the WebSocket watch set to 500 sessions. This should be more than enough for normal use.

The v1 workspace diff treats missing file contents as empty. If Omnigent fails to read a
Git baseline, the diff can show existing lines as additions or omit a deleted
file. Omnigent does not distinguish that failure from a new file.

## TODO

- [ ] Design client-to-server retry for requests with no confirmed response, including
      messages and elicitation responses the server may already have accepted.
- [ ] Support workspace diffs for non-Git workspaces.
- [ ] Fetch older conversation items on demand.

## Sources

- [Omnigent repository and README](https://github.com/omnigent-ai/omnigent)
- [Server API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md)
- [Programmatic usage](https://omnigent.ai/docs/programmatic)
