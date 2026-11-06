# Session Management Design

**Status:** Proposed. Session selection exists; the session list and its
management actions are not implemented. This document owns session-list data,
actions, and update-frame handling. It calls the APIs in
[transport.md](transport.md) for all server input and output. Transport parses
and forwards frames; this component interprets them and updates list state.
[frontend.md](frontend.md) owns presentation.

## Public APIs

The v1 client needs these server APIs. Transport helpers are asynchronous and
return a status and response body to their callback.

| Operation | Server API | Client helper |
|---|---|---|
| List sessions | `GET /v1/sessions?limit=1000&include_archived=true&sort_by=updated_at&order=desc` | `omnigent-transport-list-sessions` (extend existing helper) |
| List agents | `GET /v1/agents` | `omnigent-transport-request` |
| Create session | `POST /v1/sessions` with `agent_id` and optional `title` | `omnigent-transport-request` |
| Interrupt | `POST /v1/sessions/{id}/events`, type `interrupt` | `omnigent-transport-post-session-event` |
| Stop | Same endpoint, type `stop_session` | `omnigent-transport-post-session-event` |
| Delete | `DELETE /v1/sessions/{id}` | New helper |
| List updates | `WS /v1/sessions/updates` | `omnigent-transport-start-session-updates`, `omnigent-transport-set-session-updates-watch`, `omnigent-transport-stop-session-updates` |

Stop belongs to session management and takes a session ID. It does not
require an open conversation buffer. Stop is owner-only; it terminates the
live process without deleting history. Stop is non-sticky: a later message
normally relaunches the session on its online host.

Delete permanently removes the conversation; request confirmation before deleting it. Do not use deletion as
a close operation.

Create prompts for an agent and optional title. An empty title lets the server
derive one. Open the new session's conversation buffer on success. Refresh the
list after a write completes. Presentation of failures belongs to
[frontend.md](frontend.md).

## List and updates

Fetch active and archived sessions on initial load and manual refresh. The
server defaults to 20 entries; request 1,000, sorted by most recently updated
first. The server must sort before applying the limit. Pagination beyond that is
post-v1. Do not silently represent a truncated result as complete.

Subscribe to session updates. A watch message replaces the complete watch set,
which contains only IDs with live conversation buffers. Creating or closing a
conversation buffer adds or removes its ID. The server limits the watch set to
500 IDs, so refuse to open a new conversation buffer at the limit and report why.
Reusing an open buffer is still allowed. Manual refresh reconciles all loaded rows;
rows without open conversation buffers do not receive live updates. The transport
reconnects and resends the watch set.

The server sends a snapshot after each watch, changed and removed frames, and
heartbeats. Apply frames to the watched session and its list row. For an unknown
ID, refresh the root list rather than assuming it is a root: the server can also
report child sessions. A removed frame removes its row. Reconcile on reconnect
and manual refresh.

The server owns session state. Do not poll for updates. The frontend owns the
list's display, ordering, and actions. Child-session display and management are
post-v1; do not fetch child lists or open child conversations in v1.

## Checks

Use fixture list responses and update frames to check root updates, unknown IDs,
removals, reconnect, buffer open and close, and refusal to open a 501st buffer.
Check that the request selects the 1,000 most recently updated sessions and that
a truncated list is not presented as complete. Existing transport tests cover the WebSocket.

## Deferred

Forking, child sessions, archiving and unarchiving, cursor pagination beyond
1,000, search, custom ordering, advanced creation options, and
`delete_worktree` are post-v1. V1 still lists archived sessions.

## References

- [Frontend design](frontend.md)
- [Transport design](transport.md)
- Omnigent 0.19.1: `server/routes/sessions/routes_core.py` and
  `server/routes/sessions/routes_events.py`.
