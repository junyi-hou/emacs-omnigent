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

Alpha. The foundation works, the UI does not exist yet.

What works:

- HTTP REST requests, plus reconnecting SSE session streams and session-updates
  WebSocket connections (`omnigent-transport.el`).
- Start a local server from the Omnigent CLI, or connect to a remote one
  (`omnigent-connect`, `omnigent-start`).
- List, select, and create sessions through a `completing-read` prompt.

What does not exist yet: conversation buffers, session tree, streaming chat
output, and the composer. Session selection is currently the end of the line.

## TODO

- [ ] Design centralized authentication for remote servers, including token expiration.
- [ ] Conversation buffer (`omnigent-conversation-mode`): read-only transcript,
      editable prompt region, streamed output inserted via markers.
- [ ] Composer: send user messages to the active session, render agent replies
      and tool activity.
- [ ] Session tree side panel: top-level sessions as roots, child sessions
      nested, `New session` entry; replaces the current `completing-read` prompt.
      See [docs/session-tree.md](docs/session-tree.md) for the full design.
- [ ] Child sessions: show agent and status per child, open a child in its own
      conversation buffer, message or interrupt a selected child.
- [ ] Workspace changes view: list changed files, show before/after contents
      (Omnigent environments API).
- [ ] Track queued messages client-side: show messages sent while the
      session is busy (the server queues them; v1 renders them only
      after a snapshot refresh). See
      [docs/conversation-buffer.md](docs/conversation-buffer.md).
- [ ] Interrupt action via `POST /v1/sessions/{id}/events`.

Later, if needed:

- [ ] Row ordering in the session tree (`updated_at` vs. `created_at`).
- [ ] Advanced session-creation options in a Transient menu: workspace,
      host, sandbox, model override, reasoning effort, launch args, and
      fork options (harness switch, fork-from-response).
- [ ] Manual child-session creation (requires a documented client API upstream).
- [ ] `delete_worktree` option on archive (removes the session worktree).

## Sources

- [Omnigent repository and README](https://github.com/omnigent-ai/omnigent)
- [Server API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md)
- [Programmatic usage](https://omnigent.ai/docs/programmatic)
