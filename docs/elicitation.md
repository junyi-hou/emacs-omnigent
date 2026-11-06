# Elicitation Handling Design

**Status:** Proposed. Not implemented. This document owns request state,
validation, and response handling. Use [transport.md](transport.md) APIs for
server input and output. [frontend.md](frontend.md) owns presentation. An
elicitation is a temporary server request, not a conversation item.

## Public APIs

- `GET /v1/sessions/{id}` returns `pending_elicitations` alongside committed
  items. Re-fetch it on open and reconnect.
- The session SSE stream sends `response.elicitation_request` and
  `response.elicitation_resolved` events.
- `POST /v1/sessions/{id}/elicitations/{elicitation_id}/resolve` accepts an
  `action` of `accept`, `decline`, or `cancel`, and optional form `content`.
  Add a transport helper for this route.

## State and response

Keep requests and unsent drafts in their conversation buffer, keyed by
elicitation ID. Add or update requests on request events and remove them on
resolved events. Reconcile the snapshot with events as described in
[conversation-buffer.md](conversation-buffer.md). A request resolved by
another client disappears on its resolved event or the next snapshot.

Build form content with schema property names or question IDs as keys. Initialize
drafts from schema defaults, but require an explicit submission. Omit unanswered
optional fields. Send `null` only when the schema permits it and the user chooses
it. Validate against `requestedSchema`; reject constraints the client cannot
validate. Preserve drafts across re-rendering.

Disable submission while a resolve request is pending. A successful response
confirms resolution: remove the request and clear its draft. On failure, retain
the request and draft. A resolved event may arrive before the response; removal
by ID must be harmless when repeated.

Closing a buffer needs no confirmation. A still-pending server request can be
loaded again when the buffer opens. Unsubmitted draft answers are lost. Pending
requests are held in server memory and can be lost on server restart; a request
can also resolve while the buffer is closed. Do not promise recovery in those
cases. Child-session request handling is deferred with child sessions.

## Checks

Check request and resolve events around snapshot loading, duplicate resolution,
failed submission, and reopening a buffer with a pending request. Check that
unsent drafts are not sent or restored on reopening.
