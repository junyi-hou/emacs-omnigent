# The server owns the message queue; the client renders only committed items

The conversation buffer sends every prompt immediately through
`POST /v1/sessions/{id}/events`, regardless of session status. The
client renders the sent message only when the session is idle. While a
session is running or waiting, the server queues the message behind the
current turn and the buffer shows nothing: no queued bubble, no echo,
no acknowledgment tracking. A refresh (manual or reconnect) re-renders
from the snapshot's committed items, which is where a queued message
reappears after the turn consumes it.

The client builds no queue machinery. In particular it does not track
`session.input.consumed` events, does not maintain a FIFO of optimistic
bubbles, and does not rehydrate the snapshot's `pending_inputs`. The
send path is one POST plus a status check.

## Considered options

- Optimistic queued bubbles with `session.input.consumed` tracking (the
  first-party web client's design): rejected. It costs a FIFO, a
  consumed-event handler, and FIFO matching against server item ids,
  all to visualize a queue the server already owns.
- Rehydrating `pending_inputs` from the snapshot as plain user blocks:
  rejected. It closes the invisibility gap on native-terminal sessions,
  but it is queue state on the client side of a line we drew at zero.
- Rendering the sent message unconditionally: rejected. It double-renders
  with the committed item and needs a text-matching dedupe to repair.

## Consequences

- While a session is busy, a sent message is invisible in the transcript
  until a refresh. The user's only reminder it exists is the prompt
  history. Accepted deliberately; the README TODO tracks the follow-up
  (client-side tracking of queued messages) if this gap proves costly.
- Sending to a `failed` session is blocked client-side, since a failed
  session accepts no events and an optimistic render would show a
  message that never arrived.
- Native-terminal transcript mirrors can re-deliver the user's own
  item; a one-line guard replaces the matching optimistic block instead
  of appending a duplicate.
- Removing this later, once queue tracking exists, is a visible behavior
  change; that is the cost of the simplicity bought now.
