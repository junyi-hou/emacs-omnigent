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

Alpha. The conversation frontend is not implemented yet.

What works:

- HTTP REST requests, plus reconnecting SSE session streams and session-updates
  WebSocket connections (`omnigent-transport.el`).
- Start a local server from the Omnigent CLI, or connect to a remote one
  (`omnigent-connect`, `omnigent-start`).

- Conversation state, snapshot parsing, and message and interrupt requests
  (`omnigent-conversation.el`).

The conversation frontend, including transcript display, is not implemented.
The session tree and session selection are also not implemented.

The planned client can open at most 500 conversation buffers at once, because the
server limits the WebSocket watch set to 500 sessions. This should be more than enough
for normal use. Close a conversation buffer to open another session.

The planned v1 workspace diff treats missing file contents as empty. If Omnigent
fails to read a Git baseline, the diff can show existing lines as additions or
omit a deleted file. Omnigent does not distinguish that failure from a new file.

## TODO (post-v1)

- [ ] Design server-to-harness retry for a failed runner startup and its saved input.
- [ ] Design client-to-server retry for requests with no confirmed response, including
      messages the server may already have accepted.

- [ ] Support workspace diffs for non-Git workspaces.
- [ ] Design centralized authentication for remote servers, including token expiration.
- [ ] Support connections to multiple Omnigent servers.
- [ ] Track queued messages client-side: show messages sent while the
      session is busy (the server queues them; v1 renders them only
      after a snapshot refresh). See
      [docs/conversation-buffer.md](docs/conversation-buffer.md).
- [ ] Fetch sessions incrementally: load 20 first, then let the user fetch more.
- [ ] Row ordering in the session tree (`updated_at` vs. `created_at`).
- [ ] Advanced session-creation options in a Transient menu: workspace,
      host, sandbox, model override, reasoning effort, launch args, and
      fork options (harness switch, fork-from-response).
- [ ] Child-session display and management.
- [ ] Fork sessions, including fork options.
- [ ] `delete_worktree` option on archive (removes the session worktree).

## Sources

- [Omnigent repository and README](https://github.com/omnigent-ai/omnigent)
- [Server API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md)
- [Programmatic usage](https://omnigent.ai/docs/programmatic)
