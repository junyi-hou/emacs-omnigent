# Client Reconnection and State Recovery

**Status:** Implemented with unit and native integration coverage. Emacs-side fault
injection tests use a real server and mock model with both native harnesses. Physical
laptop suspend and deployed remote networking remain unverified. This document covers
client outages, not execution-host outages or recovery of an agent process that stops.

[transport.md](transport.md) owns connections and requests.
[session-tree.md](session-tree.md) owns the session list and watch set.
[conversation-buffer.md](conversation-buffer.md) owns transcript reconciliation and drafts.

REST reads and writes follow the [API callback design](api-callbacks.md) for
result delivery and invalidation. Composite snapshot reads have a bounded deadline.
Temporary snapshot failures retry automatically with capped backoff. SSE and WebSocket callbacks have separate
subscription contracts.

## Goal and deployment

A user can disconnect Emacs or suspend the laptop while a remote task continues.
After reconnection, the client loads current server state and resumes live updates.
It does not restart the agent or resend earlier requests.

The server and execution host must remain available independently of the laptop.
They can share an always-on remote machine. A client-only outage does not stop the
agent, although an unanswered elicitation can pause its work.

No SSH connection is required if Emacs can reach an authorized HTTP(S) endpoint.
Use a private network or authenticated HTTPS, not an unauthenticated public port.
Remote-server authentication remains a separate prerequisite; it is not implemented
in this client. See [transport authentication](transport.md#authentication).

## Existing behavior and gaps

| Area | Implemented | Remaining work |
|---|---|---|
| SSE | Reconnect after exit, inactivity, or a long scheduling gap, with capped backoff. | Verify physical laptop suspend and deployed proxies. |
| Session snapshot | Serialize bounded composite reads; invalidate on read failure, timeout, or malformed data. | Verify commits during real-server snapshot pagination. |
| Conversation state | Preserve drafts and history as read-only during recovery; reconcile full items by ID. | Verify physical laptop suspend and deployed remote networking. |
| Session updates | Detect inactivity, reconnect, restore the watch set, and refresh the list on open. | Verify deployed proxies. |
| Initial connection | Reset state, select the server URL, start session updates, and load the list. | None for this flow. |

`curl -N` disables buffering. It does not reconnect or replay events. During laptop
sleep, curl can remain suspended with a socket that no longer works after resume.
A process that still exists is not proof of a live connection.

## Recovery source

The server remains authoritative. Recover committed transcript items, current status,
and outstanding elicitations through REST. Do not build a client-side offline event log.

The SSE interface has no general durable event cursor for replaying every missed event.
Some server versions emit current state on subscription. That is not a guarantee that
all missed text deltas can be replayed. Completed items replace provisional streamed text.

Use the existing metadata and item requests:

- `GET /v1/sessions/{id}?include_items=false` for metadata and pending elicitations.
- `GET /v1/sessions/{id}/items` for paginated committed history.
- `GET /v1/sessions` for the session list; a WebSocket watch snapshot is not the full list.

Respect `omnigent-transport-history-limit`, currently 5,000 items by default. Recovery
loads that bounded window, not unlimited history. Older items remain on the server;
interactive loading of older history remains deferred.

## Reconnection flow

1. Detect a closed or stale connection. Retain the last known state and drafts. Make the
   conversation read-only, including send, interrupt, and elicitation actions, while
   disconnected or recovering.
2. Retry connection establishment with the existing capped backoff. Keep only one
   active process and reconnect timer per stream handle.
3. Start the session SSE request, then fetch session metadata and bounded committed
   history without waiting for the SSE response. Buffer events during the snapshot read.
   Allow only one active snapshot operation per handle, including refreshes after an
   interrupt. Coalesce another refresh request until that operation completes.
4. Keep the existing display while the snapshot loads. After all reads succeed and pass
   validation, replace server-derived history, pending inputs, and pending elicitations
   with snapshot state. Preserve the composer, valid elicitation drafts, point, and fold
   state. Reconcile live events by item and elicitation ID; do not blindly append deltas
   that may overlap the snapshot. Restore editing and actions only when the same stream
   attempt remains live and server permissions allow them.
5. If any snapshot read or validation fails, invalidate the conversation as described
   below. Retry connection errors, timeouts, HTTP 408 and 429, and temporary server
   errors (500, 502, 503, and 504). Preserve drafts during each retry.
6. Report stream failures. Restore the WebSocket watch set and refresh the session list
   when its connection opens.

Each conversation recovers independently. A working WebSocket does not prove that
its SSE streams work, or that their snapshots loaded successfully. Follow the frontend
policy: do not add stale-state visual indicators in v1. Opening a conversation does not
make its disconnected or invalid state editable.

### Subscription readiness and overlap

Spawning curl does not establish an SSE subscription. HTTP response headers alone
are not sufficient unless the server contract guarantees registration before them.

Follow the official web frontend's request ordering: start SSE first, but do not wait
for its response before requesting the snapshot. A proxy can delay SSE headers while no
events arrive. Starting the request does not prove that the server registered the
subscription before the snapshot. An item committed after the history read but before
subscription registration can be missed. We accept this potential gap because the
official frontend uses the same request ordering. This design does not guarantee
gap-free recovery. Closing that gap requires a verified server guarantee or a server
contract change.

The web frontend processes live events during its snapshot request and merges the
snapshot by item ID. This client buffers events during snapshot loading. During
reconciliation, discard buffered text and reasoning deltas because their overlap with
snapshot text is unknown. Apply full items and lifecycle, input, and elicitation events
in arrival order. An added item cannot replace an already committed item. New live
deltas update provisional items only; snapshot and final items remain authoritative.
Partial streamed text can remain incomplete until a final full item arrives.

The interface also has no shared snapshot/event sequence number. Stable item IDs
support full-item deduplication, but do not by themselves deduplicate text deltas.
Test snapshot/stream overlap explicitly. Do not promise exact token replay; committed
server items are the recovery source when partial text cannot be reconstructed.

### Composite snapshot consistency

The current API does not provide an atomic snapshot of metadata, pending inputs,
elicitations, and the bounded history window. Even `GET /v1/sessions/{id}` with items
included reads metadata and items separately and returns only the latest 100 items. It
cannot replace the paginated recovery reads without reducing the history window. Keep
the existing bounded pagination; do not add a server snapshot protocol in this work.

Installing the result only after all reads pass validation prevents partial client
updates. It does not make the server reads atomic. Check pending-input consumption,
elicitation resolution, status changes, and active-response changes between metadata and
history reads and during pagination. Reconcile buffered events against the result. These
checks do not remove the subscription gap described above.

### Liveness and retry rules

- Omnigent 0.21.0 sends SSE heartbeats every 15 seconds and WebSocket heartbeats after
  30 idle seconds. Check connections every five seconds. Reconnect after 90 seconds
  without traffic, or a scheduling gap longer than 15 seconds. Any stream traffic
  updates the activity time; normal idle heartbeats keep connections alive.
- Allow 30 seconds for the first SSE frame or WebSocket open, and 30 seconds for the
  complete composite snapshot. The transport timeout options control these deadlines.
  Buffer at most 10,000 events or approximately 8 MiB during snapshot loading; the
  conversation recovery options control these limits.
- After laptop resume or a long scheduling gap, restart stale connections through
  their existing handles. Do not call the destructive server-selection reset.
- Give connection establishment and snapshot reads bounded timeouts. Cancel or ignore
  superseded work using connection generations and stream attempt numbers. A snapshot
  timeout invalidates the conversation; late results must not change it.
- Bound temporary event buffering. Overflow invalidates the conversation, just like a
  snapshot failure. Do not discard events and continue as if recovery succeeded.
- Report authentication and authorization failures separately. Do not treat them as
  ordinary network outages or bypass authentication. Authentication recovery needs
  the separate authentication design.
- An unavailable session follows the session-management removal policy: stop its stream
  retries, freeze its conversation and drafts as read-only, and close its workspace
  panel. Do not report deletion or infer it from list omission or a REST 404, which can
  also represent lost access.
- Closing a conversation or selecting another server cancels its recovery work.
  Late callbacks must not revive a stopped stream or update another server's state.

### Failed snapshot and manual recovery

Any failed snapshot read, malformed required data, or snapshot timeout invalidates that
conversation buffer. Stop its stream, reconnect timer, and pending recovery work.
Discard buffered events and reject late callbacks. Preserve the last displayed state,
composer text, and elicitation drafts as read-only. Do not apply further live updates or
enable mutating actions in that buffer.

Report the error with its available status and diagnostics. Ask the user to close and
reopen the conversation to try again. Reopening an existing invalid buffer must not
silently restart recovery. Closing it loses local drafts under the existing buffer
lifecycle policy, so the error must tell the user to copy any drafts first.

Temporary snapshot failures retry automatically with capped backoff. Existing SSE and WebSocket connection retries
remain in scope, but must not revive an invalidated conversation.

## Drafts and mutating requests

Transient reconnection keeps the existing conversation buffer. Preserve composer
text and drafts for elicitations that remain pending. Refresh the elicitation set
so requests resolved while offline do not remain actionable.

Do not automatically retry messages, interrupts, session creation, or elicitation
answers after an uncertain response. The server may already have accepted them.
Refresh state, preserve unconfirmed drafts, and report the uncertain result. Reconnect
must not become an implicit resend operation.

After Emacs exits, reopening a session loads server state. Restoring unsent drafts,
fold state, or the previous set of open buffers across Emacs restarts is out of scope.

## Ownership and scope

Reuse the existing transport handles, attempt counters, session hooks, and conversation
state. No separate recovery service or generic retry framework is required. Transport
detects connection loss and reconnects streams. It serializes snapshot operations and
forwards their results without automatically retrying failed reads. Conversation
handling retries temporary snapshot failures and leaves other failures frozen until
manual recovery. Session management refreshes
its list and watch set. Conversation handling reconciles snapshots and preserves drafts.
The frontend reports recovery failures without adding stale-state visual indicators.

This work does not manage SSH tunnels, restart servers or hosts, recover lost server
data, or guarantee that an agent continues through a server outage.

## Acceptance checks

- Disconnect only the client while a real remote-style server and mock agent continue.
  Let the task finish, reconnect, and compare committed item IDs, order, content,
  and current session status with REST. Each item must appear once.
- Commit items during the subscription/snapshot handoff. Check for missing items,
  duplicate items, and duplicated text under snapshot/stream overlap. Include a case
  that demonstrates the accepted gap before subscription registration; do not treat
  this design as a guarantee against that gap.
- Change pending inputs, elicitations, status, and the active response between metadata
  and history reads and during pagination. Check reconciliation of buffered events,
  including committed A with pending B and duplicate consumption of A.
- Fail or time out a snapshot read while SSE remains healthy, and return malformed
  required data. Check that each failure stops recovery, preserves the display and
  drafts as read-only, reports an error, and allows manual recovery with `C-c C-r`.
  Deliver late callbacks and check that they cannot revive the invalid buffer.
- Request another refresh during a snapshot read. Check that only one snapshot operation
  is active and that successful completion permits a coalesced refresh.
- Overflow the temporary event buffer. Check invalidation without automatic retry.
- Simulate a silent broken socket and laptop resume. Check bounded detection and
  recovery without duplicate curl processes or reconnect timers.
- Add, change, and remove sessions while the WebSocket is offline. Check that REST
  refresh and watch restoration recover the current list within its configured limit.
- Resolve elicitations while offline. Check their refreshed state and preservation
  of unrelated composer text and still-valid drafts in multiple open buffers.
- Close a buffer or change servers during recovery. Deliver late callbacks and check
  that they cannot restart stopped streams or change current state.
- Accept a message on the server but lose its acknowledgement. Reconnect and check
  that the client does not submit the message again.
- Accumulate more items than the history limit. Check that recovery loads the bounded
  window without claiming older server history was deleted.

The conversation command `omnigent-conversation-reconnect` (`C-c C-r`) restarts
the session stream and loads a fresh snapshot without replacing the composer draft.
Successful recovery restores editing when the stream is connected and permissions allow it.
