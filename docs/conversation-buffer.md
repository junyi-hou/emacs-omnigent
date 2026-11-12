# Conversation Buffer Design

**Status:** Implemented in `omnigent-conversation.el` and `omnigent.el`. This document
covers one conversation buffer: session lifecycle, transcript state, reconciliation, and
sending. [frontend.md](frontend.md) owns presentation, [transport.md](transport.md) owns
server connections, and [session-tree.md](session-tree.md) owns session management.

## Scope and requirements

Send the prompt to the server as the user enters it. The server decides what to do:
start a turn, or queue the message behind the running one. Show pending messages in the
conversation buffer. Submitted messages are read-only.

## What the server offers

Facts come from the server API document and the installed server.

- A session snapshot (`GET /v1/sessions/{id}`) returns committed `items` in order. Item
  types: `message` (user or assistant), `function_call`, `function_call_output`, and
  `reasoning`. Each item has a stable server `id`. A `function_call` and its
  `function_call_output` share a `call_id`.
- The SSE stream (`GET /v1/sessions/{id}/stream`) is a live tail with no replay.
  Relevant events:
  - `response.output_item.added` / `response.output_item.done` with the full item
    payload.
  - `response.output_text.delta` and `response.reasoning_text.delta` /
    `response.reasoning_summary_text.delta` for streamed text.
  - `response.error` and `response.failed` for errors during a response.
  - `session.status` can report a failed startup with an error, without a
    `response.failed` event.
  - `session.interrupted` after a user interrupt.
  - `session.input.consumed` with the committed item and, when available, the cleared
    pending-input ID.
  - `response.elicitation_request` when the agent needs a user response.
  - `response.elicitation_resolved` when a request is answered or ends.
- A session snapshot includes outstanding requests in `pending_elicitations`.
- `POST /v1/sessions/{id}/events` with `{"type":"message",...}` returns 202
  `{"queued":true}`. While the session is `running`, the server queues the message
  behind the current turn and consumes it at the next iteration checkpoint. No separate
  steer event exists. The client displays server-reported input state; it does not
  schedule or manage the queue.

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
  fold state. This table is the dedupe index: an item that is already present is never
  rendered twice, from the snapshot or the stream.
- Pending elicitations, keyed by elicitation id, stored separately from transcript
  items.
- Pending messages, kept in server queue order and separate from committed transcript
  items. Track server identifiers for reconciliation.

The conversation buffer holds the client-side transcript state while it is open. The
server remains authoritative for persisted session state. Mode activation calls
`omnigent-transport-start-session-stream` with the buffer-local session ID. The
transport starts the SSE stream and requests `GET /v1/sessions/{id}` on each stream
connection or reconnection attempt. The snapshot contains committed `items` and
`pending_elicitations`. The conversation layer owns reconciliation and deduplication;
transport forwards parsed data and the snapshot callback. Follow the web frontend's
approach to reconciling snapshot items and stream events: use item IDs to avoid
duplicate transcript entries, and reconcile pending inputs with their server IDs. Buffer
stream events while the snapshot is in flight. After installing the snapshot, discard
buffered text and reasoning deltas whose overlap with committed text is unknown. Apply
other buffered events in arrival order. Reconcile full items by ID and update existing
blocks rather than rendering duplicates. Added items and later deltas cannot change
committed snapshot or final items. A final full item replaces its partial
representation. Partial text can remain incomplete until that full item arrives.
Reconcile elicitation requests and resolutions by elicitation ID.

Use the official web frontend as a reference for snapshot and stream reconciliation. Do
not copy a FIFO fallback that can remove an unrelated pending message when replaying an
event already represented in the snapshot. If the stream or snapshot fails, report the
error; do not silently present an empty transcript as complete. Follow
[reconnection.md](reconnection.md) for read-only recovery state and snapshot-failure
invalidation. A failed snapshot stops recovery until the user closes and reopens the
conversation; it does not trigger an automatic read retry.

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
removed, while disconnected or recovering, or after a snapshot failure invalidates the
buffer. Read-only recovery state also disables send, interrupt, and elicitation actions.
Session status alone does not block typing. Send and interrupt requests follow
the [API callback design](api-callbacks.md). Transport delivers outcomes; conversation
callbacks own draft updates and outcome handling. Keep the draft until a successful
POST. On failure or uncertain timeout, preserve it and report the outcome. Do not resend
a potentially accepted message automatically.

- **Send** posts `{"type":"message",...}` through
  `omnigent-transport-post-session-event` without checking session status. The server
  accepts or rejects the request and owns the queue. Report a rejection and keep the
  draft. Forking is deferred.
- **Accepted messages** remain visible after the server confirms acceptance. Trust the
  server response and its identifiers: render a committed item as history, or show a
  pending input with a `[queued]` label. A `queued: true` response can also include an
  already-persisted `item_id`, so the flag alone does not distinguish these states. A
  successful HTTP response can report denial; do not treat that as acceptance. Do not
  infer message state from session status.
- **Pending messages** are separate from committed history and retain server queue
  order. [frontend.md](frontend.md) owns their presentation.
- **Consumption**: dispatch `session.input.consumed` from the existing session SSE
  stream. Store the server-provided pending ID with each pending item. Match the event's
  `cleared_pending_id` to that ID when possible. An explicit but unmatched pending ID
  must not trigger FIFO removal. If the committed item is already in the snapshot or
  transcript, remove only an exactly matched pending entry. For a new committed item
  without a pending ID, use the web frontend's FIFO fallback for eligible user messages;
  do not remove a pending message for a system marker or an unsent draft. Render the
  event's committed item in read-only history, deduplicated by `item_id`, and remove the
  `[queued]` label. Do not poll or POST to check consumption. Keep submission order in
  the buffer-local pending state; no separate temporary ID is required. The POST
  callback retains a stable item reference and must not recreate an item already
  consumed before the response arrived. Do not infer consumption from an interrupt or a
  status change. If the send outcome is unknown, show an explicit unconfirmed label
  rather than claiming acceptance.
- **Refresh and recovery**: the server is the single source of truth. On a successful
  snapshot refresh, rebuild committed history and pending messages from server state,
  then reconcile buffered live events. Render snapshot pending inputs with `[queued]`
  labels in server order. Do not merge unmatched local submission records back into the
  recovered queue. A previously queued message can appear as committed history or be
  absent from the recovered state. Full recovery of earlier client state is not
  required. Preserve composer text across refreshes in an open buffer. If a snapshot
  fails, retain the visible state and drafts as read-only, stop recovery, and report the
  error. Ask the user to copy drafts before closing and reopening the conversation to
  try again. Do not automatically retry the snapshot or apply further live events to the
  invalid buffer. Reopening a buffer restores only server state, not local drafts.
- **Uncertain sends**: keep the composer draft and show a persistent warning that the
  server may have accepted it. Do not automatically resend it. A failed or uncertain
  send must not appear as confirmed queued input.
- **Interrupt** posts `{"type":"interrupt","data":{}}`. After `session.interrupted`, the
  buffer marks the turn as interrupted and refreshes pending input state. An interrupt
  does not itself confirm that pending inputs were cancelled or consumed. The refreshed
  snapshot determines which messages remain visible. No dedicated copy or correction
  command is required.

The installed Omnigent 0.21.0 server publishes consumption events on the session SSE
stream and includes pending inputs in snapshots. The stream has no history replay, so
refresh the snapshot after reconnect and after interrupt; buffer live events during the
snapshot as described above. Check the exact identifiers and interrupt behavior for each
supported harness before implementation.

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

- No full client-state recovery after reconnecting or reopening a conversation. Recover
  the server's current committed history and pending inputs, not earlier local labels,
  unmatched submission records, or removed pending text. Preserve drafts only while the
  existing buffer remains open.
- No editing or resending past messages.
- No client-side replay or diffing of the transcript; a refresh re-renders from the
  snapshot.
- No full queue manager: do not add reordering or cancellation unless separately
  designed.

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
Check queued ordering, output insertion above the queue, SSE consumption by ID and FIFO
fallback, system markers, consumption before the POST response, snapshot and stream
overlap, identical messages, interrupt refresh, uncertain sends, and draft preservation.
Replay consumption of A after installing a snapshot with committed A and pending B; B
must remain pending. Check that recovery renders snapshot pending inputs and drops
unmatched local submission records.
