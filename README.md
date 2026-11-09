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

## Using the frontend

Load `omnigent.el` with this directory on `load-path`. Install the declared GNU
ELPA `websocket` dependency. The client also uses `curl` for session streams and
`diff` for workspace patches.

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

Run `make test-unit` for offline unit checks. `make test` also runs the
network-dependent integration runner described in
[test/README.md](test/README.md).

The client can open at most 500 conversation buffers at once, because the server
limits the WebSocket watch set to 500 sessions. This should be more than enough
for normal use. Close a conversation buffer to open another session.

The v1 workspace diff treats missing file contents as empty. If Omnigent fails
to read a Git baseline, the diff can show existing lines as additions or omit a
deleted file. Omnigent does not distinguish that failure from a new file.

## TODO (post-v1)

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
- [ ] Track queued messages client-side: show messages sent while the
      session is busy (the server queues them; v1 renders them only
      after a snapshot refresh). See
      [docs/conversation-buffer.md](docs/conversation-buffer.md).
- [ ] Fetch sessions incrementally: load 20 first, then let the user fetch more.
- [ ] Fetch older conversation items on demand.
- [ ] Infer execution hosts and native workspace paths from TRAMP buffers.
      Existing online hosts and their directories are already selectable through
      the server. Design automatic remote-host setup and connectivity separately.
- [ ] Advanced session-creation options in a Transient menu: sandbox,
      model override, reasoning effort, launch args, and
      fork options (harness switch, fork-from-response).
- [ ] Child-session display and management.
- [ ] Fork sessions, including fork options.
- [ ] `delete_worktree` option on archive (removes the session worktree).

## Sources

- [Omnigent repository and README](https://github.com/omnigent-ai/omnigent)
- [Server API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md)
- [Programmatic usage](https://omnigent.ai/docs/programmatic)
