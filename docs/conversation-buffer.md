# Conversation Buffer Design

**Status:** Proposed. Not implemented. This document covers one conversation buffer:
session lifecycle, transcript state, reconciliation, and
sending. [frontend.md](frontend.md) owns presentation, [transport.md](transport.md) owns
server connections, and [session-tree.md](session-tree.md) owns session management.

## Scope and requirements

Send the prompt to the server as the user enters it. The server decides what to do:
start a turn, or queue the message behind the running one. The client builds no queue
machinery of its own.

## What the server offers

Facts come from the server API document and the installed server.

- A session snapshot (`GET /v1/sessions/{id}`) returns committed `items` in order. Item
  types: `message` (user or assistant), `function_call`, `function_call_output`, and
  `reasoning`. Each item has a stable server `id`. A `function_call` and its
  `function_call_output` share a `call_id`.
- The SSE stream (`GET /v1/sessions/{id}/stream`) is a live tail with no
  replay. Relevant events:
  - `response.output_item.added` / `response.output_item.done` with the full item
    payload.
  - `response.output_text.delta` and `response.reasoning_text.delta` /
    `response.reasoning_summary_text.delta` for streamed text.
  - `response.error` and `response.failed` for errors during a response.
  - `session.status` can report a failed startup with an error, without a
    `response.failed` event.
  - `session.interrupted` after a user interrupt.
  - `response.elicitation_request` when the agent needs a user response.
  - `response.elicitation_resolved` when a request is answered or ends.
- A session snapshot includes outstanding requests in `pending_elicitations`.
- `POST /v1/sessions/{id}/events` with `{"type":"message",...}` returns 202
  `{"queued":true}`. While the session is `running`, the server queues the message
  behind the current turn and consumes it at the next iteration checkpoint. No separate
  steer event exists. The client does not model any of this; it sends and renders the
  result.

## Buffer and mode

Open-or-reuse scans live conversation buffers for the buffer-local session ID, not
the buffer name. A major mode `omnigent-conversation-mode`, derived from `text-mode`,
owns each buffer. The session tree passes
the selected session ID when it creates the buffer. Bind the ID dynamically while
activating the mode; the mode copies it into a buffer-local variable after the
major-mode reset and starts the session stream. Activating the mode without a session ID
signals an error. Reusing an existing buffer does not restart its stream.  The
transcript is read-only text. An editable prompt region sits at the end. Two markers,
`prompt-start` and `prompt-end`, delimit it. All output is inserted before
`prompt-start`.

Buffer-local state:

- `session-id` and the stream handle from `omnigent-transport-start-session-stream`.
- A hash table keyed by item id. Each entry holds markers for the rendered block and the
  fold state.  This table is the dedupe index: an item that is already present is never
  rendered twice, from the snapshot or the stream.
- Pending elicitations, keyed by elicitation id, stored separately from transcript
  items. Session management supplies status from the session-updates WebSocket for
  queued-message display.

The conversation buffer holds the client-side transcript state while it is open. The
server remains authoritative for persisted session state. Mode activation calls
`omnigent-transport-start-session-stream` with the buffer-local session ID. The
transport starts the SSE stream and requests `GET /v1/sessions/{id}` on each stream
connection or reconnection attempt. The snapshot contains committed `items` and
`pending_elicitations`. The conversation layer owns reconciliation and deduplication;
transport forwards parsed data and the snapshot callback. Follow the web frontend's
approach to reconciling snapshot items and stream events: use item IDs to avoid
duplicate transcript entries, and reconcile pending inputs with their server IDs. Buffer
stream events while the snapshot is in flight, then apply them in arrival order after
installing the snapshot. Reconcile full items by ID and update existing blocks rather
than rendering duplicates. A final full item replaces its partial
representation. Reconcile elicitation requests and resolutions by elicitation ID.

Follow the official web frontend's snapshot and stream reconciliation behavior, rather
than adding separate handling for edge cases it does not cover. If the stream or snapshot
fails, report the error; do not silently present an empty transcript as complete.

A snapshot refresh preserves fold state and point by item ID, and preserves composer
text and elicitation drafts. Reopening a killed buffer restores only server state, not
unsent drafts or local fold state.

### Multiple buffers and stream lifecycle

A user may keep several sessions live at once on one server. Each session has its own
endpoints, so each conversation buffer owns its own SSE stream: N open buffers means N
curl processes, each writing to exactly one buffer. Each session stream has its own
handle. Conversation buffers do not share transcript or request state. Transport keeps a
global server connection record for cleanup. No stream sharing or cap in v1; add a cap
only if resource use becomes a measured problem. Closing a buffer stops its stream on
`kill-buffer-hook`. Creating a conversation buffer adds its session ID to the
session-management WebSocket watch set. Closing it removes the ID. The watch set
contains only sessions with live conversation buffers. Refuse to open a new buffer when
500 are already open; reusing an existing buffer is allowed. See
[session-tree.md](session-tree.md) for watch-set ownership.

Conversation-buffer actions read the buffer-local session ID. There is no global session
selection state. Opening a buffer does not start or restart the agent. Killing it stops
its stream, but does not stop the agent or delete history. The user can close the buffer
without confirmation; unsent composer text and elicitation drafts are lost. Reopening
fetches committed history and currently pending requests from the server. Pending
requests may resolve while closed or be lost on a server restart.

Selecting or creating a session opens or reuses its conversation buffer. A message to a
stopped session normally relaunches its runner on the online host; there is no separate
resume REST call. Stop belongs to session management in
[session-tree.md](session-tree.md). A conversation buffer can call those operations with
its session ID. Server connection reset is owned by [transport.md](transport.md). On
server reset, close the conversation buffers; their unsent drafts are lost.

## Public APIs

- `GET /v1/sessions/{id}`: committed history, status, and pending requests.
- `GET /v1/sessions/{id}/stream`: live SSE events, no replay.
- `POST /v1/sessions/{id}/events`: message and interrupt events.
- `omnigent-transport-get-session`, `omnigent-transport-start-session-stream`,
  `omnigent-transport-stop-session-stream`, and `omnigent-transport-post-session-event`
  provide the existing transport interface. Opening or reusing a conversation buffer
  needs a new public client operation; its name is not yet decided.

## Transcript state

Merge function calls and outputs by `call_id`. Keep one fold unit per call, with no
nesting. The display and output size limits are defined in [frontend.md](frontend.md).

Unknown stream events are ignored. Ignore is better than error: the server adds event
types faster than any client tracks them.

## Fold state

Keep fold state in a buffer-local hash table keyed by item ID. Preserve it across
snapshot refreshes. Fold presentation belongs to [frontend.md](frontend.md).

## Composer and sending

The composer is enabled unless the conversation is read-only, such as after a session is
removed. Session status alone does not block typing. Send and interrupt requests follow
the [API callback design](api-callbacks.md). Transport delivers outcomes; conversation
callbacks own draft updates and outcome handling. Keep the draft until a successful
POST. On failure or uncertain timeout, preserve it and report the outcome. Do not resend
a potentially accepted message automatically.

- **Send** posts `{"type":"message",...}` through
  `omnigent-transport-post-session-event` without checking session status. The server
  accepts or rejects the request and owns the queue. Report a rejection and keep the
  draft. Forking is deferred.
- **Rendering rule**: use the last known status from the session-updates WebSocket, not
  `session.status` from the conversation stream. Render the sent message only when that
  status is `idle`. When it is `running`, `waiting`, `failed`, or unknown, do not render
  it; a later snapshot refresh renders committed messages. Status can change between the
  update and the POST, so this is a display heuristic, not proof that the server queued
  the message.
- **Known gap**: while the session is busy, a sent message is invisible in the
  transcript until a refresh or reconnect. The live stream never re-delivers user
  messages, so nothing renders it on its own, even after the turn finishes. Accept this
  in v1. The README TODO tracks the follow-up: client-side tracking of queued messages
  so the user sees what was sent while the session is busy.
- **Duplicate guard**: the live stream never re-delivers user messages on regular
  sessions, so an optimistic render cannot double-render. Native-terminal transcript
  mirrors can broadcast the user's own item; if that item matches the newest optimistic
  block's text, replace the block instead of appending. One line at render time.
- **Interrupt** posts `{"type":"interrupt","data":{}}`. After `session.interrupted`, the
  buffer marks the turn as interrupted. What the server does with unconsumed messages is
  the server's business; a snapshot refresh shows the truth.

## Harness and session errors

Show a live error as its own transcript item, including errors reported by
`response.error`, `response.failed`, and failed `session.status` events. Treat error
items like other transcript items. On snapshot or reconnect, construct history from
snapshot items only. Do not synthesize history from `last_task_error`, or retain an
error that is absent from the snapshot. Live errors that are not persisted in the
snapshot can disappear on refresh or reconnect. Use the error face for error items.

## Elicitations

See [elicitation.md](elicitation.md) for request state and resolution.
[frontend.md](frontend.md) owns inline forms.

## Non-goals

- No editing or resending past messages.
- No client-side replay or diffing of the transcript; a refresh re-renders from the
  snapshot.
- No queue UI: no queued-bubble faces, no `session.input.consumed` tracking, no
  `pending_inputs` rehydration. The client sends; the server decides.

## References

- [Omnigent server
  API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md)
  - session events, stream events, interrupt semantics
- [Transport design](transport.md)
- [Frontend design](frontend.md)
- [Session tree design](session-tree.md)

## Checks

Check mode activation with and without a session ID, reuse without restarting the
stream, reopening from a snapshot, send failure draft preservation, and event/snapshot
overlap. Check that closing a buffer stops its stream without stopping the session.
