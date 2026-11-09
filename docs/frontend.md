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
Users can show or hide each view. Do not merge transcripts. Follow Emacs key
binding conventions across all views.

## Session list

Use `*omnigent-sessions*`, with a mode derived from `special-mode`. List all root
sessions together without sections, most recently updated first. Create sessions with a
keyboard command, not a list entry. Show each session's title and an attention marker
for pending elicitations. Indicate status with a face. Preserve point by session ID on
refresh. Child sessions are deferred.

Show each session on one line. Use faces, not glyphs, for session states. Show
`!` in a separate column when an elicitation is pending; otherwise leave it blank.
Truncate long titles rather than wrap lines, and keep the attention marker visible
in narrow windows. Do not show a legend in the buffer. Use `g` for manual refresh.
Refresh once after Emacs has been idle for 10 seconds, even if the side window is
hidden; stop the idle timer on disconnect. If refresh fails, report the failure
and keep the existing rows, which may be stale. If the server reports a truncated
list, show a non-selectable warning line. `RET` opens the selected
session's conversation buffer in the main window and keeps the session side window
visible. Move point to the conversation buffer. Follow Treemacs or Neotree conventions for other
bindings where applicable.

Use the session state face on the whole line, with a separate attention face on
`!`. Provide faces for running, waiting, idle, failed, and archived sessions. Use
the archived face for archived sessions regardless of their reported status. Make
the current session's title bold without replacing its state face.
Show failed actions with the action, session title, and available status and
diagnostics. Follow the [API callback
design](api-callbacks.md#validation-and-error-presentation) for one-shot
request-error presentation. Do not mark sessions that lack live updates. Keep open sessions visible by merging
the fetched list with watched sessions. The list
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
composer headed by `>`. Start input on the same line after `> `. Align explicit
continuation lines and visually wrapped lines with the first input character. This
indentation is display-only and is not sent as part of the message. `RET` inserts a
newline; `C-c C-c` sends the message. Distinguish user, agent, tool, reasoning, and
error text with faces. Show tool calls and reasoning in foldable blocks. Show streamed
output before the composer. Keep the target session clear in each buffer. Detailed
rendering and buffer behavior are in [conversation-buffer.md](conversation-buffer.md).

### Transcript and folds

| Item | Presentation |
|------|--------------|
| User message | `You:` label, plain text, no fold. |
| Assistant message | Agent name label, plain text, no fold; append streamed text. |
| Reasoning | Foldable `Thinking` block with reasoning text. |
| Function call | Foldable block with tool name, argument summary, and status in the header; full arguments and output in the body. |
| Function call output | Merge into its function-call block. |
| Error | Show an `Error:` heading and the full message in its own block, without a fold. |

Separate blocks with a blank line. Use distinct headings and faces for error and
elicitation blocks, without literal borders. A fold has a `▶` or `▼` header followed by
its body. Bodies are flush left in v1. Reasoning and tool folds start collapsed; only
the user changes their fold state. Use the `invisible` text property for folded bodies
and reapply it when streamed text is appended. Use the smallest folding implementation
that works, following agent-shell's approach. Show running, done, or failed in the tool
header. No groups, nested folds, or isearch fold integration in v1.

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

Give each request an action-specific heading, such as `Approval required` or `Question`.
Show each pending request only in a separate inline block between the transcript and the
composer, in arrival order with the oldest first. Remove the whole block when resolution
is confirmed; retain it if submission fails. Elicitations are temporary requests, not
transcript items. Do not move point when a new request arrives. Show its message and
available policy, phase, and content preview. Show `Approve` and `Decline` actions for
approvals. Treat an internal `/approve/...` URL as an approval page; show an external
URL as a browser link without in-buffer response actions.

Use normal Emacs widget navigation, including `TAB` between fields and actions.
Show editable form fields, including boolean and selectable options. Show an
editable field for an `isOther` option. Mask secret input: keep its clear value
in request state, not buffer text, undo history, or the transcript. Indicate all
invalid fields and their errors, and move point to the first invalid field.
During submission, keep the request visible, disable its response actions, and show
`Submitting...`. Remove it only after server confirmation or a resolved event. Request and draft state, validation,
and server interactions belong to [elicitation.md](elicitation.md).

The conversation implementation must keep separate boundaries for transcript, request
blocks, and composer. Stream insertion and transcript refresh must not overwrite request
drafts or composer text. Incoming output must not move point from the composer or
interrupt typing. Follow incoming output only when the window is already at the bottom;
otherwise preserve the user's reading position.

## Workspace view

Show workspace changes for the selected conversation in a left side window below the
session list. Let Emacs choose the initial height split and allow normal window
resizing. Open the workspace panel automatically on server connection when the current
session has changed files. Users can close it and open it again with a command. After
the user closes it, do not reopen it automatically on later updates. List changed files
as flat, workspace-relative paths. Prefix each path with `A`, `D`, or `M` for the
server's created, deleted, or modified status. Sort files alphabetically by
workspace-relative path, regardless of status. Add a selectable `[unified diff]` row
above the files; `RET` on that row displays the combined diff. `RET` on a file displays
its diff using Emacs window selection rules and the user's `display-buffer`
configuration; do not force the main window. Fetch fresh data each time a diff is
opened. Show the diff in a separate buffer using built-in `diff-mode`. If the requested
file has no diff, report that no diff is available. If a diff request fails, do not
report the failure; leave any existing diff buffer unchanged. Reuse the existing buffer
for the same session and file, replacing its contents only after a successful fetch.
Likewise, reuse one combined-diff buffer per session. Keep a separate workspace buffer
per session. After the new conversation opens successfully, or the user selects an
existing conversation through Emacs buffer commands, replace the panel contents with the
selected session's cached list, or clear it if there is no cached list. Keep the last
selected session's workspace panel when another, non-conversation buffer is displayed.
When multiple conversations are visible, use the most recently selected conversation
window. Fetch the change list when a session is selected and when its stream reports
`session.changed_files.invalidated`. A late response updates only its own session's
buffer, not the selected session's panel. Use `g` for manual refresh. Preserve point by
file path on refresh; if the file is gone, move point to the nearest remaining row. A
failed fetch is a no-op: keep the panel's previous contents and visibility, which may be
stale. Do not report the failure in v1. A successful empty list closes the panel, and
the session list expands to use the available side-window height. The remaining UI
details are open for discussion. Data collection and API semantics belong to
[workspace-changes.md](workspace-changes.md).

## Nongoals

No full dashboard, policy editor, Git staging or commit actions in v1.
Agent and policy definitions remain in configuration files.
