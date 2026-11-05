# Elicitation Design

**Status:** Proposed. Not implemented. This document covers requests shown
in a [conversation buffer](conversation-buffer.md).

An elicitation is a temporary request, not a conversation item. The
server snapshot and stream are the source of truth. The server keeps
pending requests in memory, so a server restart can lose them.

### State and notifications

- Load `pending_elicitations` from the session snapshot on open and
  reconnect.
- Add or update a request on `response.elicitation_request`. Remove it
  on `response.elicitation_resolved`.
- Keep each request in the conversation buffer that receives it. Do not
  use a global active request or global pending-request registry.
- Render every pending request in that buffer as a separate inline block,
  stacked in arrival order.
- Key requests within the buffer by elicitation ID. Keep the target
  session ID with the request. Use `params.target_session_id` when the
  server mirrors a child request into a parent stream. Otherwise, use
  the session that sent the event.
- A mirrored child request can appear in both parent and child buffers
  when both streams are open. This duplicate display is acceptable. Each
  buffer resolves its local block using the target session ID. The
  resolved event removes each local copy.
- Use the session tree's attention marker to notify the user about
  pending requests in other sessions.

### Inline request block

Show every pending request as its own inline block between the
transcript and the composer. Stack the blocks in arrival order. Keep them
outside the transcript item hash and the read-only transcript region.

Show the request message and available context, including its policy,
phase, and content preview. If `target_session_id` names a child session,
show the child's title or agent name. If neither is known, show its ID.

Show inline Yes/No actions for policy and permission approvals. Bind
`y` to accept and `n` to decline when point is on the request block.
Treat an internal `/approve/...` URL as an approval page, not as an
external URL request. For an external URL request, show only a browser
link. Do not show in-buffer response actions for it. Remove its block
when the server reports that the request is resolved.

### Form input

Keep each request's answers in its owning conversation buffer. Render
editable fields inside the request block. Do not use a shared minibuffer
or a global active-request variable.

Initialize fields from schema defaults when present. Treat each default
as an editable draft. The user must still submit the response.

Render boolean fields as one checkbox row. Press `SPC` to toggle it.

Render enum and question options as selectable rows. Press `SPC` on an
option to select it. For a multi-select field, `SPC` toggles that option
without changing the other selections. If the request has an `isOther`
option, selecting it shows an editable text field.

For an `isSecret` field, use a custom masked editor inside the request
block. Keep the clear value in buffer-local request state, not in buffer
text, undo history, or the transcript. Do not use the shared minibuffer
or send the user to a browser for this field. The value still exists in
Emacs memory while the request is pending.

Build the response content with the schema property names or question
IDs as keys. Preserve draft answers when the block is re-rendered. Omit
unanswered optional fields. Send `null` only when the schema allows it
and the user selects it.

Before submission, validate the response against `requestedSchema`. If
validation fails, signal `user-error`, highlight all invalid fields, and
show each error beside its field. Move point to the first invalid field.
Do not send the resolve request. Reject a constraint that the client
cannot validate.

### Resolve a request

The server accepts `accept`, `decline`, and `cancel` actions. An accepted
form request can also include form content.

Send the verdict to the resolve route:
`POST /v1/sessions/{target}/elicitations/{elicitation_id}/resolve`
with `{"action": ...}` and optional form `content`. The elicitation ID
rides in the URL. Use `params.target_session_id` as `{target}` when
present (a child request mirrored into a parent stream); otherwise use
the buffer's session ID. The API also accepts a `type: "approval"`
event on `POST /v1/sessions/{id}/events`, and both paths converge on
the same server-side resolver, but the resolve URL is the documented
human-approval path that policy ASK gates rely on; use it.

Disable the response actions while the request is being sent. The
resolve route completes resolution before it returns, so a successful
response confirms that the elicitation is done. Remove the block and
clear its draft values after that response. Keep the block and its draft
values if the response fails.

An accepted elicitation lets its caller continue with the answer. A
declined or canceled elicitation can deny or stop the pending operation.
In all cases, the resolved event or a refreshed snapshot reconciles
requests resolved by another client or by the harness. Apply removal by
elicitation ID so duplicate updates are harmless.

A pending request remains on the server when its buffer closes. Unsent local
draft answers are lost.

Before killing any conversation buffer, ask `yes-or-no-p`. Ask even when
the buffer has no pending request or draft answers. If the user says no,
keep the buffer and its stream open.

