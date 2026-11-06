# The server owns the message queue

The server queues messages sent during a running turn. The client does not
maintain a second queue. See [conversation-buffer.md](../conversation-buffer.md)
for the send and rendering behavior.

## Rationale

Tracking optimistic queued bubbles and consumed events duplicates server state
and requires matching queued messages to committed items. Rehydrating pending
inputs also adds client-side queue state. The simpler v1 design accepts that a
busy-session message is not visible until a later snapshot refresh.
