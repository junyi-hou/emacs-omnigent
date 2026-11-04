# Session Tree Design

**Status:** Accepted. The session-updates WebSocket transport is implemented.
The session tree is not implemented. This document rounds up the tree design:
the buffer and major mode, the lineage display, the keymap, and the faces. See
[frontend.md](frontend.md) for the overall UI plan and
[transport.md](transport.md) for the transport layer.

Facts below come from the installed server (omnigent 0.19.1, FastAPI routes
in `omnigent/server/routes/sessions/`).

## API layer

The transport already has `omnigent-request`, `omnigent-get-session`,
`omnigent-list-sessions`, `omnigent-list-child-sessions`, and
`omnigent-post-session-event`. The tree needs these additions.

### Read: list and lineage

`GET /v1/sessions` paginates with a cursor. The default `limit` is 20, so the
tree must pass an explicit limit. Start with one call at `limit=1000` and add
a cursor loop (`after` parameter) only when a user exceeds that. Request
`include_archived=true` in the same call and split active vs. archived rows
client-side.

`GET /v1/sessions/{id}/child_sessions` returns child summaries. It is the
only lineage source. `SessionListItem` has no `parent_session_id`, so the
client cannot build the tree from a single list call. Fetch children only
when a node is expanded, and keep expansion state keyed by session id so a
refresh does not collapse the view. The same endpoint works on a child id,
because sub-agents can nest deeper than one level.

Forks are always top-level sessions. A fork promotes a sub-agent to a
standalone session. It never appears under its source.

### Write: session operations

| Operation | Route | Notes |
|-----------|-------|-------|
| Fork | `POST /v1/sessions/{source_id}/fork` | All body fields optional. Empty body forks with the source agent. `agent_id` switches harness. `up_to_response_id` truncates history. |
| Interrupt | `POST /v1/sessions/{id}/events` with `{"type":"interrupt","data":{}}` | Cancels the active task. Not owner-only. |
| Stop | Same route with `{"type":"stop_session","data":{}}` | Owner-only. Kills the live process. Non-sticky: no persistent marker, and the next message relaunches the session. |
| Retry | Same route with `{"type":"retry_session","data":{}}` | Relaunches or reconnects the runner and retries a failed startup input. |
| Archive | `PATCH /v1/sessions/{id}` with `{"archived":true}` | Owner-only. Hides the session from the default list. |
| Unarchive | Same route with `{"archived":false}` | Owner-only. |
| Delete | `DELETE /v1/sessions/{id}` | Deletes the conversation permanently. Ask for confirmation before calling it. |

There is no resume endpoint. Loading a session is opening it: a snapshot
GET plus the SSE stream, and the conversation buffer is that open state
(see [conversation-buffer.md](conversation-buffer.md)). Do not name a
helper "resume" and do not add a `stop_session`-like helper for it. A
stopped session relaunches on the next message, so loading and "send a
message" are the same path.

`delete_worktree: true` also removes the session worktree directory when
archiving. Skip it in v1; add it only when a user asks.

Add one transport helper per row in the table. Each wraps
`omnigent-request` and calls back with status and body, like the existing
helpers.

## Buffer and major mode

One buffer: `*omnigent-sessions*`. A major mode
`omnigent-session-tree-mode`, derived from `special-mode`, owns it. The mode
gives read-only text, `q` to close the window, and `g` to refresh, plus the
custom keymap below.

Render the tree with plain `insert` calls and text properties. Do not use
widget.el, tabulated-list, or an external tree library. Each line carries
these text properties:

- `omnigent-session-id`: the session id under point.
- `omnigent-session-kind`: `root`, `child`, or `new`.
- `omnigent-session-expanded`: `t` on an expanded root.

Line format, one line per session:

- Root: `[-] Title (Agent) STATUS` plus an attention marker when needed.
- Child: same format, indented by two spaces per depth level.
- `New session` first, then active roots, then an `Archived` heading and
  archived roots.

Root status comes from the list item's `status` field:
`idle`, `running`, `waiting`, or `failed`. Child status comes from `busy`,
`current_task_status`, and `last_task_error`. Attention means
`pending_elicitations_count > 0`; show it as a `!` marker on the line. Both
list items and child summaries carry this field.

Refresh re-renders the whole buffer and restores point and expansion state.
Point restores by session id, not by line number: after a refresh, point
sits on the same session's row wherever that row moved. Keep the tree as a
view; the server data is the source of truth.

Every transport helper calls back asynchronously with `status` and
`body`. The helpers stay reusable: no buffer knowledge inside the
transport layer. The tree layer closes over its buffer object and starts
each callback with `(when (buffer-live-p buf) ...)`, no-op when the
buffer is gone. The tree closes its session-updates connection on
`kill-buffer-hook`, so no live connection outlives the buffer.

## Refresh: the session-updates websocket

The tree will subscribe to `WS /v1/sessions/updates` and do no polling.
The transport provides `omnigent-start-session-updates`,
`omnigent-set-session-updates-watch`, and
`omnigent-stop-session-updates`, built on the required `websocket` package
from GNU ELPA. The frame callback receives each parsed JSON frame. The
optional error callback receives an error string. The transport reconnects
with the same backoff constants and re-sends the latest watch set after
reconnect.

Protocol: the client sends `{"type":"watch","session_ids":[...]}`;
each watch replaces the whole set (server cap: 500 ids). The server
answers each watch with a `snapshot` frame, then sends `changed` /
`removed` deltas on a 4-second rescan and a `heartbeat` after 30 idle
seconds. A session created anywhere reaches the client as a `changed`
frame even when not watched.

Frame handling: the watch-set is every displayed id, roots plus children
of expanded nodes. A `changed` frame carries a full `SessionListItem`,
which is exactly what a root row renders from, so roots update in place
with no REST call. Child rows render from child-summary fields, which
frames do not carry: a changed child marks its parent dirty and triggers
one debounced `GET .../child_sessions` re-fetch. A `removed` frame drops
the row. A `changed` for an unknown id is a new session; insert it.

Manual `g` re-lists through REST and re-renders; it stays as the force
re-sync key. REST also does the initial load on first open.

Dependency: `websocket` from GNU ELPA. It is not bundled with Emacs. The
transport reports an error that names the package if it is missing. REST
and SSE calls do not load WebSocket functions until a connection starts.

## Connection lifecycle

The frontend is connected to one server at a time. `omnigent-connect`
(and `omnigent-start-server`, which ends in a connect) resets everything
first: stop every SSE stream, stop the session-updates websocket, kill
the tree buffer, kill conversation buffers. Then it connects and opens
the tree. The reset runs even when the URL is
unchanged: a restarted server or stale expansion state is cheaper to
rebuild than to reconcile.

`omnigent-session-tree` is the standalone entry: it creates the tree
buffer or pops to it, and re-initializes the websocket when the buffer
was killed.

## Active session

The active session is the session of the conversation buffer point is
in, per CONTEXT.md. There is no global variable holding it: no
`omnigent-current-session-id`, no most-recently-used fallback. Every
conversation buffer is self-contained and reads its own buffer-local
session id. If a future command needs "the active session" from
outside a conversation buffer, it can set one variable on buffer focus
then; do not build the tracking first.

A conversation buffer belongs to exactly one session; there is one buffer
per session and no shared transcript. Each open conversation buffer keeps
its own SSE stream.

## Keymap

Commands read `(get-text-property (point) 'omnigent-session-id)`. When point
is not on a session line, the command signals an error that names the key.

| Key | Action |
|-----|--------|
| `RET` | Open the session: pop to its conversation buffer, or create the buffer when none exists. |
| `TAB` | Expand or collapse the node under point. |
| `n` | New session: pick an agent, read a title, create. |
| `f` | Fork the session under point. |
| `i` | Interrupt the session under point. |
| `s` | Stop the session under point. |
| `R` | Retry the session under point (relaunch the runner). |
| `a` | Archive the session under point. |
| `u` | Unarchive the session under point. |
| `d` | Delete the session under point, after `yes-or-no-p`. |
| `g` | Refresh the tree. |
| `q` | Bury the tree buffer. |

`stop_session` and `delete` change state in ways a user cannot undo, so show
the affected session title in the confirmation prompt. Archive and stop need
no extra confirmation beyond the keypress: the tree shows the target, and
both are reversible (unarchive; message to relaunch).

Until `omnigent-conversation-mode` exists, `RET` is a mock: it loads the
session through the existing select-and-load path and sets the active
session. The pop-or-create behavior replaces the mock when conversation
mode lands; nothing else in the keymap depends on it.

### Creating sessions

v1 uses plain prompts, no Transient menu. `n` (the command also works
outside the tree): one `completing-read` over `GET /v1/agents`, then one
`read-string` for the title; an empty title lets the server derive one.
Then `POST /v1/sessions` with `agent_id` and, when given, `title`. After
the create returns, the new session's conversation buffer opens and
behaves like `RET` on its row; the row itself arrives through the push
channel.

`f` in v1 sends an empty body: the fork keeps the source agent, copies
full history, and gets a derived title. No prompts. The fork does not
auto-open. It arrives as a new root through the push channel.

Write-action failures surface as a `message` naming the action, the
session title, and the HTTP status, for example "Could not archive X:
HTTP 403".

Deferred creation options, in one later Transient menu: workspace, host,
sandbox, model override, reasoning effort, launch args, fork's harness
switch and `up_to_response_id` ("fork from this response", which needs
the conversation buffer).

After any write action, refresh the tree once the callback returns.
## Faces

Map each server status to one face. Group statuses the user acts on the
same way:

- `omnigent-session-tree-running`: `running`, `waiting`, and live-work
  states. The agent is busy. Default: bold.
- `omnigent-session-tree-idle`: `idle`. Default: inherit `default`.
- `omnigent-session-tree-failed`: `failed`, and children with
  `last_task_error`. Default: inherit `error`.
- `omnigent-session-tree-archived`: archived rows. Default: inherit
  `shadow`.
- `omnigent-session-tree-attention`: the `!` marker for pending
  elicitations. Default: inherit `warning`.
- `omnigent-session-tree-new`: the `New session` entry. Default: inherit
  `link`.

Waiting does not get its own face: the `!` marker already shows
waiting-on-user, and waiting-on-agent reads as busy. Define faces with
`defface` and a `t` fallback so they work on any theme.

## Order of work

1. Transport helpers: list with limit, the write helpers (fork, interrupt,
   stop, retry, archive, unarchive, delete), and the session-updates
   websocket.
2. Tree buffer, mode, render, expansion, and the websocket subscription.
3. Keymap and actions.
4. Faces and the archived section.

The side-window placement (left panel) is a separate, later change. The
buffer works in any window first.

## Nongoals

- No search box in the tree. The server supports `search_query`; add it when
  a user has too many sessions to scan.
- No pinning, labels editing, or drag-and-drop reorder.
- No per-session SSE stream for the tree. The session-updates websocket is
  the only push channel for tree state.
- No `delete_worktree` option in v1.
- No manual child-session creation until the upstream client API documents
  it.
- No multi-server support: one connection at a time, reset on every
  connect.

## Open decisions

1. Whether the cursor loop for >1000 sessions belongs in v1 or waits for a
   real user with that many sessions.
2. Row ordering in the tree. Deferred: the server default (`created_at`
   descending) applies for now. Revisit `updated_at` descending so recently
   active sessions stay on top.

## Checks

The planned tree unit tests will run in batch Emacs with no server. They
will feed fixture frames and fixture list and child JSON to the frame
handler and renderer. They will check the tree structure, faces, text
properties, point restore by session ID, and dirty-parent refetch scheduling.

`test/omnigent-transport-test.el` tests the WebSocket transport with a
mocked connection. It checks URL construction, auth headers, watch messages,
frame parsing, missing-package errors, and reconnect behavior.
`test/omnigent-transport-server-test.el` also connects to the test server with
the GNU ELPA client. It checks the handshake, a watch snapshot, and a changed
frame. The integration script installs `websocket` into a temporary package
directory. Set `OMNIGENT_WEBSOCKET_LOAD_PATH` to an existing source directory
to run the integration test without a package download.

Keymap commands are thin wrappers over tested functions and get no tests
of their own.

## References

- [Transport design](transport.md)
- [Frontend design](frontend.md)
- Server routes in the installed package:
  `omnigent/server/routes/sessions/routes_core.py` (list, patch, fork),
  `routes_events.py` (events, delete), `routes_items.py`
  (child_sessions), and `omnigent/server/schemas.py`
  (SessionListItem, UpdateSessionRequest, SessionEventInput).
