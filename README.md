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
- Create sessions on the connected server with `omnigent-sessions-create`, regardless
  of who started it. Use the sole online execution host, or select one if several
  are online. Always pick a workspace through host filesystem completion. No Emacs
  project-path default or prefix argument is used.

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

Run unit tests and both native integration suites separately:

```sh
make test-deps
make unit-test
make integration-test HARNESS=claude-native
make integration-test HARNESS=codex-native
```

`make test-deps` installs Evil, WebSocket, `f`, `s`, and their dependencies in
`.tools/test-elpa`. Evil is not a runtime dependency. After setup, unit tests
run offline. Integration tests need network access for dependency installation.
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

- [ ] Use a Markdown parser to render conversation messages.

- [ ] Complete client reconnection after network loss or laptop sleep: detect stale
      SSE/WebSocket connections, restore subscriptions, reload server state, and
      retry failed snapshots without resending messages. See
      [the reconnection design](docs/reconnection.md).
- [ ] Design server-to-harness retry for a failed runner startup and its saved input.
- [ ] Design client-to-server retry for requests with no confirmed response, including
      messages and elicitation responses the server may already have accepted.
- [ ] Support workspace diffs for non-Git workspaces.
- [ ] Integrate Magit for staging and committing workspace changes.
- [ ] Design safe workspace file visiting for local and remote execution hosts,
      including how to identify the host and avoid opening a file on the wrong host.
- [ ] Design centralized authentication for remote servers, including token expiration.
- [ ] Support connections to multiple Omnigent servers.
- [x] Show pending messages while the session is busy, track server consumption, and
      restore server pending inputs from snapshots. See
      [docs/conversation-buffer.md](docs/conversation-buffer.md).
- [ ] Test cancellation during a model switch. Pending-state refresh is implemented.
      Check session items and pending inputs after cancellation and refresh. The
      upstream live test is
      `tests/e2e_ui/chat/test_cancel_message_model_switch_live.py`; a controlled delay
      can test the workflow without testing the real model-switch race. Interrupt is
      session-wide, not selective cancellation.
- [ ] Fetch sessions incrementally: load 20 first, then let the user fetch more.
- [ ] Fetch older conversation items on demand.
- [ ] Infer execution hosts and native workspace paths from TRAMP buffers.
      Existing online hosts and their directories are already selectable through
      the server. Design automatic remote-host setup and connectivity separately.
- [ ] Advanced session-creation options in a Transient menu: sandbox,
      model override, reasoning effort, launch args, and
      fork options (harness switch, fork-from-response).
- [ ] Child-session display and management.
- [ ] Support side chat and its MCP tool allowlist.
- [ ] Fork sessions, including fork options.
- [ ] `delete_worktree` option on archive (removes the session worktree).

## Sources

- [Omnigent repository and README](https://github.com/omnigent-ai/omnigent)
- [Server API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md)
- [Programmatic usage](https://omnigent.ai/docs/programmatic)
