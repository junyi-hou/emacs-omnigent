# Conversation Buffer Design

**Status:** Proposed. Not implemented. This document covers one
conversation buffer: the transcript, folding, the composer, and the send
queue. See [frontend.md](frontend.md) for views and window behavior,
[transport.md](transport.md) for the transport layer, and
[session-tree.md](session-tree.md) for the session tree.

## Scope and requirements

1. Fold tool calls and reasoning (chain of thought) the way agent-shell
   does, with the smallest implementation that works.
2. Send the prompt to the server as the user enters it. The server
   decides what to do: start a turn, or queue the message behind the
   running one. The client builds no queue machinery of its own.
3. Keep the implementation minimal. Cut every agent-shell feature that
   the requirements above do not need.

## What the server offers

Facts come from the server API document and the installed server.

- A session snapshot (`GET /v1/sessions/{id}`) returns committed
  `items` in order. Item types: `message` (user or assistant),
  `function_call`, `function_call_output`, and `reasoning`. Each item
  has a stable server `id`. A `function_call` and its
  `function_call_output` share a `call_id`.
- The SSE stream (`GET /v1/sessions/{id}/stream`) is a live tail with no
  replay. Relevant events:
  - `session.status` with `status` `running`, `waiting`, `idle`, or
    `failed`.
  - `response.output_item.added` / `response.output_item.done` with the
    full item payload.
  - `response.output_text.delta` and
    `response.reasoning_text.delta` / `response.reasoning_summary_text.delta`
    for streamed text.
  - `session.interrupted` after a user interrupt.
- `POST /v1/sessions/{id}/events` with `{"type":"message",...}` returns
  202 `{"queued":true}`. While the session is `running`, the server
  queues the message behind the current turn and consumes it at the
  next iteration checkpoint. No separate steer event exists. The
  client does not model any of this; it sends and renders the result.

## Buffer and mode

One buffer per session, named `*omnigent: TITLE [conv_XXXX]*`: the
session title (or `Untitled`) plus the first characters of the session
id, so the name is always unique and readable. Open-or-reuse never
matches on the buffer name; it scans live conversation buffers for the
buffer-local session id. The name is display only. A major
mode `omnigent-conversation-mode`, derived from `text-mode`, owns it.
The transcript is read-only text. An editable prompt region sits at the
end. Two markers, `prompt-start` and `prompt-end`, delimit it. All
output is inserted before `prompt-start`.

Buffer-local state:

- `session-id` and the stream handle from `omnigent-start-session-stream`.
- A hash table keyed by item id. Each entry holds markers for the
  rendered block and the fold state.
  This table is the dedupe index: an item that is already present is
  never rendered twice, from the snapshot or the stream.

The buffer is a view. The snapshot plus the stream is the source of
truth, per the reconnect contract in [transport.md](transport.md). The
buffer opens the stream, gets the snapshot, renders the snapshot items,
and drops any stream item whose id is already in the hash table. A
snapshot refresh re-renders the buffer from the committed items.

A re-render preserves fold state and point. Keep the hash-table entries
whose item id still exists in the snapshot; drop the rest; apply the
stored `collapsed` instead of the defaults. Restore point by item id,
the same pattern the session tree uses: record the item id at point
before the re-render, then move point to that block's marker after it.
If the item is gone, point lands at the prompt. An SSE reconnect runs
the same path, so a dropped connection must not flatten folds the user
opened.

### Multiple buffers and stream lifecycle

A user may keep several sessions live at once on one server. Each
session has its own endpoints, so each conversation buffer owns its own
SSE stream: N open buffers means N curl processes, each writing to
exactly one buffer. The transport is already per-session with no shared
state. No cross-buffer coordination, no stream sharing, and no cap in
v1; add one only if resource use becomes a measured problem. Closing a
buffer stops its stream on `kill-buffer-hook`.

The conversation buffer is self-contained: every operation (send,
interrupt, refresh, render) reads the buffer-local session id. Do not
track a global "current session" in this design. The only consumer of
such a global would be a future "message the active session from any
buffer" command; if that ships, set one variable on buffer focus and
read it there. CONTEXT.md keeps the term for UI language only.

### Opening a conversation buffer

Omnigent has no resume command. Loading a session is opening it: a
snapshot GET plus the SSE stream, and the conversation buffer is that
open state. Selecting a session from any path (the `completing-read`
flow in `omnigent-connect`, new-session creation, the future session
tree) ends by opening or reusing that session's conversation buffer.
`omnigent-resume-session` and the selection globals
(`omnigent-current-session-id`, `omnigent-current-session`) are
removed: their only job was remembering which session a message would
go to, and the conversation buffer now carries that per buffer. Sending
a message to a stopped or idle session is the same path; the server
relaunches the runner on the next message.

Connecting to a different server resets all session state (per
CONTEXT.md): close every open conversation buffer, which stops their
streams, before selecting a session on the new server.

## Transcript rendering

| Item | Rendering |
|------|-----------|
| User message | `You:` label, plain text, no fold. |
| Assistant message | Agent name label, plain text, no fold. Streamed deltas append to the open block. |
| Reasoning | Foldable block. Header `Thinking`. Body is the reasoning text. |
| Function call | Foldable block. Header is the tool name, a one-line argument summary, and a status. Body is the full arguments and output. |
| Function call output | Merged into the matching function-call block by `call_id`. Never rendered as its own block. |

Merging call and output by `call_id` replaces agent-shell's group
machinery. One fold unit is one block; there are no groups and no
nesting in v1.

Block layout: a blank line between blocks. A fold block is one header
line (`▶` or `▼` plus the label) followed by the body. Bodies render
flush left in the proof of concept; visual indentation via
`line-prefix` and `wrap-prefix` can come later without touching the
fold mechanics. Wrap insertions in `(let ((inhibit-read-only t)
(buffer-undo-list t)) ...)`.

Tool output bodies are bounded in both dimensions:

- **Line width**: a line longer than 32,768 characters keeps 200
  characters at each end, with an omitted-character count in the
  middle (`... [32600 characters omitted] ...`). Same rule and constants
  as agent-shell; long single lines are what makes Emacs redisplay and
  vertical motion crawl, not total volume.
- **Total lines**: output longer than 1,000 lines keeps the first 400
  and the last 400 lines, with one `... [N lines omitted] ...` marker
  replacing the middle.

Both caps are display-only and deterministic; a refresh re-renders the
  same truncation. No fetch-on-expand: nothing but pathological
  middles is hidden. `ponytail:` comment on the constants names
  fetch-on-expand as the upgrade path if the middle of a giant output
  ever matters.

Unknown stream events are ignored. Ignore is better than error: the
server adds event types faster than any client tracks them.

## Folding

### The agent-shell mechanism, for reference

agent-shell keeps a fragment engine in `agent-shell-ui.el`. Each
fragment has a model (namespace, block id, left and right labels, body,
optional group), a state map stored in a text property on the block,
and a header line with a `▶`/`▼` indicator. Collapse sets the
`invisible` text property over the body range; it does not use overlays.
A keymap property on the header binds TAB, RET, and mouse-1 to the
toggle. Fold state is cached per qualified id, so streaming updates
(`:append`) preserve it, and appended text in a collapsed body gets the
`invisible` property as it arrives. Groups are header-only fragments
whose children reference them by id. Isearch integration (a filter
predicate plus an end-of-search re-collapse hook) lets searches open and
restore folds.

### The minimal subset for omnigent

Keep four ideas from that engine; drop the rest.

1. **One block, one fold unit.** A block is a header line plus a body.
   No groups, no nesting, no namespaces. The call-output merge replaces
   groups. Qualified id is just the item id (the `call_id` block key).
2. **Collapse with the `invisible` text property.** No overlays. Toggle
   rewrites the `▶`/`▼` indicator in place; both glyphs are two columns
   wide, so nothing shifts.
3. **Fold state in a buffer-local hash table keyed by item id.** The
   entry records `collapsed`. Appending streamed text
   to a collapsed body re-applies `invisible` over the whole body range
   after each append. This is the one subtlety agent-shell solved that
   we must keep: folds must survive streaming.
4. **A keymap property on the header.** TAB, RET, and mouse-1 toggle
   the block under point.

Fold defaults (proof of concept):

- Every fold block is collapsed by default: reasoning and tool calls
  alike. Nothing auto-expands or auto-collapses. The user is the only
  thing that changes a fold, so there is no `user-folded` flag and no
  fold lifecycle code.
- The header carries the status (`running`, `done`, `failed`), so a
  collapsed transcript reads as a log of what the agent did.
- Upgrade path: an expand-while-streaming, auto-collapse-on-done
  lifecycle can be layered on later, keyed by the same item ids, if a
  workflow needs to watch live tool output.

Dropped from agent-shell, deliberately: group headers, nested folds,
viewport rendering, block navigation (`agent-shell-ui-forward-block`),
echo hints on the header (`cursor-sensor-functions`), and isearch fold
integration. Isearch already skips invisible text, which is the default
Emacs behavior and an acceptable v1 limitation; agent-shell's filter
predicate is the recipe if users hit it.

## Composer and sending

The composer is always enabled; the session status never blocks typing.

- **RET in the prompt** posts `{"type":"message",...}` through
  `omnigent-post-session-event`, regardless of session status. When the
  session is `idle`, the server starts a turn. When the session is
  `running` or `waiting`, the server queues the message behind the
  current turn. Both paths are the same client code; the server owns
  the queue and the client does not model it.
- **`failed` blocks the send** with a `user-error`: a failed session
  cannot accept new events, so rendering an optimistic block would show
  a message that never arrived. Recovery is the fork route (see
  [session-tree.md](session-tree.md)). Status `idle` or unknown allows
  the send; `running` and `waiting` send into the server queue.
- **Rendering rule**: render the sent message only when the buffer's
  last known session status is `idle`. When the session is `running` or
  `waiting`, do not render it. The message is queued server-side; a
  later snapshot refresh renders it as a committed item.
- **Known gap**: while the session is busy, a sent message is invisible
  in the transcript until a refresh (`g` or reconnect). The live stream
  never re-delivers user messages, so nothing renders it on its own,
  even after the turn finishes. Accept this in v1. The README TODO
  tracks the follow-up: client-side tracking of queued messages so the
  user sees what was sent while the session is busy.
- **Duplicate guard**: the live stream never re-delivers user messages
  on regular sessions, so an optimistic render cannot double-render.
  Native-terminal transcript mirrors can broadcast the user's own
  item; if that item matches the newest optimistic block's text,
  replace the block instead of appending. One line at render time.
- **`C-c C-c`** posts `{"type":"interrupt","data":{}}`. After
  `session.interrupted`, the buffer marks the turn as interrupted. What
  the server does with unconsumed messages is the server's business; a
  snapshot refresh shows the truth.
- **`C-c C-c`** posts `{"type":"interrupt","data":{}}`. After
  `session.interrupted`, the buffer marks the turn as interrupted. What
  the server does with unconsumed messages is the server's business; a
  snapshot refresh shows the truth.

## Faces

- `omnigent-user`, `omnigent-agent`: message labels.
- `omnigent-tool`: tool block headers.
- `omnigent-reasoning`: reasoning headers and bodies, dim.
- `omnigent-error`: failed status and interrupt markers.

## Keymap

| Key | Action |
|-----|--------|
| C-c RET (prompt) | Send message. Plain RET types a newline. |
| RET, TAB, mouse-1 (fold header) | Toggle fold. |
| C-c C-c | Interrupt. |
| C-c g | Refresh from snapshot (re-render buffer, preserving folds and point). |

## Non-goals

- No markdown rendering of message bodies in v1. Plain text only. Add
  when a workflow needs it.
- No elicitation cards in this document. They use the resolve route and
  need their own design.
- No editing or resending past messages.
- No todos or plan panel, no usage display.
- No client-side replay or diffing of the transcript; a refresh
  re-renders from the snapshot.
- No queue UI: no queued-bubble faces, no `session.input.consumed`
  tracking, no `pending_inputs` rehydration. The client sends; the
  server decides.

## References

- [Omnigent server API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md)
  — session events, stream events, interrupt semantics
- agent-shell folding implementation:
  `/Users/dad/Projects/agent-shell/agent-shell-ui.el` (fragment model,
  `invisible`-property collapse, fold-state cache, keymap header) and
  `agent-shell.el` (per-line tool-output truncation)
- [Transport design](transport.md)
- [ADR 0002: the server owns the message queue](adr/0002-server-owns-the-message-queue.md)
- [Frontend design](frontend.md)
- [Session tree design](session-tree.md)
