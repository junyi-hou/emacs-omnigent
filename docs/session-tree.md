# Session Management Design

**Status:** Session-list state, buffer registration, creation, and lower-level actions
are implemented in `omnigent-sessions.el`. Conversation integration and frontend
presentation remain incomplete. This document owns session-list data, actions, and
update-frame handling. It calls the APIs in [transport.md](transport.md) for all server
input and output. Transport parses and forwards frames; this component interprets them
and updates list state. [frontend.md](frontend.md) owns presentation.

## Public APIs

The v1 client needs these server APIs. One-shot requests follow the [API
callback design](api-callbacks.md) for result delivery, response validation, and
callback lifetimes. This document specifies session payloads and state changes;
the WebSocket subscription has its own transport contract.

| Operation | Server API | Client helper |
|---|---|---|
| List sessions | `GET /v1/sessions?limit=1000&include_archived=true&sort_by=updated_at&order=desc` | `omnigent-transport-list-sessions` |
| List agents | `GET /v1/agents` | `omnigent-transport-request` |
| List execution hosts | `GET /v1/hosts` | `omnigent-transport-request` |
| Browse host directories | `GET /v1/hosts/{host_id}/filesystem` or `/filesystem/{path}` | `omnigent-transport-request` |
| Create session | `POST /v1/sessions` with `agent_id`, `host_id`, `workspace`, and optional `title` | `omnigent-transport-request` |
| Interrupt | `POST /v1/sessions/{id}/events`, type `interrupt` | `omnigent-transport-post-session-event` |
| Stop | Same endpoint, type `stop_session` | `omnigent-transport-post-session-event` |
| Delete | `DELETE /v1/sessions/{id}` | New helper |
| List updates | `WS /v1/sessions/updates` | `omnigent-transport-start-session-updates`, `omnigent-transport-set-session-updates-watch`, `omnigent-transport-stop-session-updates` |

Stop belongs to session management and takes a session ID. It does not require an open
conversation buffer. Stop is owner-only; it terminates the live process without deleting
history. Stop is non-sticky: a later message normally relaunches the session on its
online host.

Delete permanently removes the conversation; request confirmation before deleting it. Do
not use deletion as a close operation.

### Execution host and workspace

V1 creates sessions on the connected server, whether local or remote and regardless
of who started it. Starting a local server is an optional convenience, not a creation
requirement. The server must be reachable and its requests must be authorized; see
[transport authentication](transport.md#authentication) for the current limitation.

The server coordinates sessions. An execution host runs the agent and its tools.
The server can run on machine A while the selected host runs on machine B. The
workspace is a directory on B, not necessarily a directory on A or the Emacs machine.
The host service must already be online and have the agent dependencies installed.
Connecting to a server does not install or start a host.

At creation time, query `GET /v1/hosts`. This response lists hosts but does not declare
a default execution host. Select the sole online host automatically; if several are
online, prompt with their names and IDs. If none are online, report the problem.
Do not assume that a host runs on the server machine or the Emacs machine.

Always prompt for the workspace with a `find-file`-style `completing-read` table.
Use the workspace of the session at point as the default when its host matches.
Otherwise use no default. Query the selected
host's filesystem through the server; do not inspect the Emacs filesystem. Empty input selects that default when available. Otherwise it cannot create a session. Completion initially lists the
host's home directory. Relative input resolves under that home; absolute and
host-relative tilde paths retain their meaning on the selected host.

Offer directories only, support navigation by path, and fetch all listing pages.
Cache listings only during the prompt. Validate the chosen directory with a fresh
filesystem request before creation, including paths the user types directly.
Send the host ID and native workspace path in the create request. Reject TRAMP
syntax rather than send it to the agent. Abort if the server changes during selection.
The selection helpers live in `omnigent-sessions.el`. Fetch hosts, directory
listings, and agents asynchronously. Show an echo-area message while each request
runs, except during directory completion. A response callback presents the next prompt
or processes a
failure. Directory completion uses cached results and refreshes when an
asynchronous listing arrives.  Do not wait for network output inside a command
or completion table.

Create prompts for an agent and optional title. An empty title lets the server derive
one. The `omnigent-sessions-open-hook` receives the new session; the conversation
component opens its buffer. Refresh the list after a write completes. Presentation of
failures belongs to [frontend.md](frontend.md).

## List and updates

Fetch active and archived sessions on initial load and manual refresh. The server
defaults to 20 entries; request 1,000, sorted by most recently updated first. The server
must sort before applying the limit. Pagination beyond that is post-v1. Do not silently
represent a truncated result as complete.

Check that list responses contain an array and the string fields needed to
process each row. Check the session ID before opening a created session. Missing
or malformed fields are client processing failures, not empty results. Preserve
the previous list and truncation state when a response is malformed. An explicit
empty array is valid.

Subscribe to session updates. A watch message replaces the complete watch set, which
contains only IDs with live conversation buffers. Creating or closing a conversation
buffer adds or removes its ID. The server limits the watch set to 500 IDs, so refuse to
open a new conversation buffer at the limit and report why.  Reusing an open buffer is
still allowed. Manual refresh reconciles all loaded rows; rows without open conversation
buffers do not receive live updates. The transport reconnects and resends the watch set.

The server sends a snapshot after each watch, changed and removed frames, and
heartbeats. Merge the fetched root list with watched sessions that have open
conversation buffers. Keep each open session visible even when it falls outside
the fetched list. Sort merged rows by their last known `updated_at`. Apply watched
updates to its row. A removed frame removes its
row. Treat a `removed` frame as session deletion, even though the server can also
send it when access is lost. If its conversation buffer is open, freeze it as-is,
including any draft,
and make it read-only; do not report the deletion. Close its workspace panel. Do not infer that a session was deleted merely because a list refresh omitted
it. After a conversation buffer closes, retain its row until the next successful
list refresh; remove it then if it is absent from the fetched list. Reconcile on
reconnect and manual refresh. Child sessions remain outside v1.

The server owns session state. Refresh the list once after Emacs becomes idle for
10 seconds, in addition to live updates and manual refresh. Do not repeat the
refresh during the same idle period. Keep the idle timer active while connected,
even when the session side window is hidden; stop it on disconnect. The frontend
owns the list's display and ordering. The conversation frontend owns user-facing actions. Child-session
display and management are post-v1; do not fetch child lists or open child conversations
in v1.

## Checks

Use fixture list responses and update frames to check root updates, unknown IDs,
removals, reconnect, buffer open and close, and refusal to open a 501st buffer.
Check that the request selects the 1,000 most recently updated sessions and that
a truncated list is not presented as complete. Check that commands return
between requests and that completion does not duplicate pending directory
requests. Real-server tests mock user choices, browse nested directories, and
reject a missing typed path before creation. Existing transport tests cover the
WebSocket.

## Deferred

Forking, child sessions, archiving and unarchiving, cursor pagination beyond 1,000,
search, custom ordering, automatic remote-host setup, TRAMP-to-host inference,
managed sandbox creation, advanced creation options, and `delete_worktree` are
post-v1. Selecting an existing online remote host is supported. V1 still lists
archived sessions.

## References

- [Frontend design](frontend.md)
- [Transport design](transport.md)
- Omnigent 0.19.1: `server/routes/sessions/routes_core.py` and
  `server/routes/sessions/routes_events.py`.
