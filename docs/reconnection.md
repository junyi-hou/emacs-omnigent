# Client Reconnection and State Recovery

**Status:** Proposed. Basic reconnect and snapshot loading exist. The complete flow
below is not implemented. This document covers client outages, not execution-host
outages or recovery of an agent process that stops.

[transport.md](transport.md) owns connections and requests.
[session-tree.md](session-tree.md) owns the session list and watch set.
[conversation-buffer.md](conversation-buffer.md) owns transcript reconciliation and drafts.

REST reads and writes follow the [API callback design](api-callbacks.md) for
result delivery and invalidation. The recovery-specific read retries and
deadlines below remain proposed. SSE and WebSocket callbacks have separate
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
| SSE | Restart curl after exit, with capped reconnect backoff. | Detect silent broken connections and laptop resume. |
| Session snapshot | Fetch metadata and bounded history on each stream attempt. | Confirm subscription readiness before snapshot loading; retry failed snapshots independently. |
| Conversation state | Buffer events during loading and reconcile full items by ID. | Verify overlap and recovery across a complete client outage. |
| Session updates | Reconnect the WebSocket, restore its watch set, and refresh the list through its open callback. | Detect silent broken connections. |
| Initial connection | Reset state and select the server URL. | Call session-list and WebSocket startup from the connection entry point. |

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

1. Detect a closed or stale connection. Mark its data as stale and retain the last known state.
2. Retry connection establishment with the existing capped backoff. Keep only one
   active process and reconnect timer per stream handle.
3. Establish the session SSE subscription. Buffer events for this recovery attempt.
4. Confirm that the server has registered the subscription before loading the snapshot.
5. Fetch session metadata and bounded committed history. Retry transient read failures
   even if the SSE process remains connected.
6. Install the snapshot. Reconcile buffered full items by server ID and elicitations
   by elicitation ID. Apply the established provisional-text reconciliation rules;
   do not blindly append deltas that may overlap the snapshot.
7. Mark the conversation synchronized only after snapshot success and subscription
   readiness on the same live attempt. Then continue normal event handling.
8. Restore the WebSocket watch set and refresh the session list when its connection opens.

Each conversation recovers independently. A working WebSocket does not prove that
its SSE streams work, or that their snapshots loaded successfully. The frontend
must distinguish stale data, recovery in progress, and synchronized data.

### Subscription readiness and overlap

Spawning curl does not establish an SSE subscription. HTTP response headers alone
are not sufficient unless the server contract guarantees registration before them.

At implementation time, verify whether an existing initial event or heartbeat
provides a subscription-ready signal. If it does not, a server contract change is
required to close the startup gap. Do not invent an event name or claim gap-free
recovery without that guarantee.

The interface also has no shared snapshot/event sequence number. Stable item IDs
support full-item deduplication, but do not by themselves deduplicate text deltas.
Test snapshot/stream overlap explicitly. Do not promise exact token replay; committed
server items are the recovery source when partial text cannot be reconstructed.

### Liveness and retry rules

- Detect SSE and WebSocket inactivity using their verified heartbeat contracts.
  Normal idle sessions must not trigger false failures. Choose timeout margins after
  checking the server intervals and proxy behavior.
- After laptop resume or a long scheduling gap, restart stale connections through
  their existing handles. Do not call the destructive server-selection reset.
- Give connection establishment and snapshot reads bounded timeouts. Cancel or ignore
  superseded work using connection generations and stream attempt numbers.
- A snapshot failure leaves the conversation stale. Retry the read without requiring
  another stream failure. Bound temporary event buffering; if it overflows, restart
  recovery rather than silently discard events and claim synchronization.
- Report authentication and authorization failures separately. Do not treat them as
  ordinary network outages or bypass authentication. Authentication recovery needs
  the separate authentication design.
- A confirmed missing session stops its stream retries and reports the condition.
- Closing a conversation or selecting another server cancels its recovery work.
  Late callbacks must not revive a stopped stream or update another server's state.

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
state. No separate recovery service or generic retry framework is required.
Transport detects connection loss and retries reads. Session management refreshes its
list and watch set. Conversation handling reconciles snapshots and preserves drafts.
The frontend reports stale state and recovery failures.

This work does not manage SSH tunnels, restart servers or hosts, recover lost server
data, or guarantee that an agent continues through a server outage.

## Acceptance checks

- Disconnect only the client while a real remote-style server and mock agent continue.
  Let the task finish, reconnect, and compare committed item IDs, order, content,
  and current session status with REST. Each item must appear once.
- Commit items during the subscription/snapshot handoff. Check for missing items,
  duplicate items, and duplicated text under snapshot/stream overlap.
- Fail snapshot reads while SSE remains healthy. Check automatic read retry and
  stale-state reporting until synchronization succeeds.
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
