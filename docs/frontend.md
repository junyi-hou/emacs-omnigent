# Emacs Frontend Presentation

**Status:** Proposed. Session selection, conversation, and side views are not
implemented. This document owns presentation and window arrangement.
[session-tree.md](session-tree.md) owns session management,
[conversation-buffer.md](conversation-buffer.md) owns conversation behavior,
and [elicitation.md](elicitation.md) owns request and response handling.

## Arrangement

Use a chat-centered interface. Show one session per conversation buffer in the
main window. Offer a session list and a workspace view as optional left side
windows. When both are open, stack the session list above the workspace view.
Users can show or hide each view. Do not merge transcripts.

## Session list

Use `*omnigent-sessions*`, with a mode derived from `special-mode`. Show New
session first, then root sessions and an Archived section. Show each session's
title, agent, status, and an attention marker for pending elicitations. Preserve
point by session ID on refresh. Child sessions are deferred.

Use faces for busy, idle, failed, archived, and attention entries.
Show failed actions with the action, session title, and available status and
diagnostics. Follow the [API callback
design](api-callbacks.md#validation-and-error-presentation) for one-shot
request-error presentation. Indicate sessions outside the watch limit. The list
is a view of server data, not its source. A Transient menu for advanced creation
options is deferred.

Session creation uses the connected server, whether Emacs started it or not.
Select its sole online execution host automatically; prompt when several are online.
Always prompt for a workspace with directory completion through that host's filesystem
interface. Start with empty input and no default or prefix argument. The prompt names
its execution host. Do not use the Emacs project root as a remote workspace.
See [session-tree.md](session-tree.md#execution-host-and-workspace).

## Conversation

Use one buffer per session, named `*omnigent: TITLE [conv_XXXX]*`: the session
title (or `Untitled`) and the first characters of the session ID. The name is
for display only; identify buffers by their buffer-local session ID.

Use a mode derived from `text-mode`. Show a read-only transcript and an editable
composer. Distinguish user, agent, tool, reasoning, and error text with faces.
Show tool calls and reasoning in foldable blocks. Show streamed output before
the composer. Keep the target session clear in each buffer. Detailed rendering
and buffer behavior are in [conversation-buffer.md](conversation-buffer.md).

### Transcript and folds

| Item | Presentation |
|------|--------------|
| User message | `You:` label, plain text, no fold. |
| Assistant message | Agent name label, plain text, no fold; append streamed text. |
| Reasoning | Foldable `Thinking` block with reasoning text. |
| Function call | Foldable block with tool name, argument summary, and status in the header; full arguments and output in the body. |
| Function call output | Merge into its function-call block. |

Separate blocks with a blank line. A fold has a `▶` or `▼` header followed
by its body. Bodies are flush left in v1. Reasoning and tool folds start
collapsed; only the user changes their fold state. Use the `invisible` text
property for folded bodies and reapply it when streamed text is appended. Use the
smallest folding implementation that works, following agent-shell's approach.
Show running, done, or failed in the tool header. No groups, nested folds, or
isearch fold integration in v1.

Bound tool output for display: lines longer than 32,768 characters retain 200
characters at each end and show the omitted count. Outputs longer than 1,000
lines retain the first and last 400 lines and show the omitted count. Apply
both limits deterministically on refresh. Fetching omitted content is deferred;
mark the constants with a `ponytail:` comment naming that upgrade path.

Faces: `omnigent-user` and `omnigent-agent` for message labels,
`omnigent-tool` for tool headers, `omnigent-reasoning` for reasoning, and
`omnigent-error` for failed status and interrupt markers. Use plain text, not
Markdown rendering, in v1. Do not add a plan panel or usage display in v1.

## Elicitations

Show each pending request in a separate inline block between the transcript and
the composer. Show its message and available policy, phase, and content preview.
Show Yes/No actions for approvals. Treat an internal `/approve/...` URL as an
approval page; show an external URL as a browser link without in-buffer response
actions.

Show editable form fields, including boolean and selectable options. Show an
editable field for an `isOther` option. Mask secret input: keep its clear value
in request state, not buffer text, undo history, or the transcript. Indicate all
invalid fields and their errors, and move point to the first invalid field.
Disable response actions during submission. Request and draft state, validation,
and server interactions belong to [elicitation.md](elicitation.md).

The conversation implementation must keep separate boundaries for transcript,
request blocks, and composer. Stream insertion and transcript refresh must not
overwrite request drafts or composer text.

## Workspace view

Show workspace files and diffs in an optional side window. The detailed UI,
including selection, opening files, diff display, and unavailable states, is
**open for discussion**. Data collection and API semantics belong to
[workspace-changes.md](workspace-changes.md).

## Nongoals

No full dashboard, policy editor, Git staging or commit actions in v1.
Agent and policy definitions remain in configuration files.
