# Emacs Frontend Presentation

**Status:** Implemented in `omnigent-ui.el`. Session selection, conversation
presentation, inline requests, and optional side views follow this v1 design. This
document owns presentation and window arrangement. [session-tree.md](session-tree.md)
owns session management, [conversation-buffer.md](conversation-buffer.md) owns
conversation behavior, and [elicitation.md](elicitation.md) owns request and response
handling.

## Arrangement

Use a chat-centered interface. Show one session per conversation buffer in the main
window. Offer a session list and a workspace view as optional left side windows. When
both are open, stack the session list above the workspace view. By default, open the
session list after the first successful server connection. The user can disable this
behavior with `omnigent-open-session-list-on-connect`. Users can show or hide each
view. Do not reopen the session list on a connection retry. Do not merge transcripts.
Follow Emacs key binding conventions across all views.

## Session list

Use `*omnigent-sessions*`, with a mode derived from `special-mode`. Group root
sessions by server project. Show sessions without a project under Unassigned.
Within each group, show active sessions before archived sessions. Sort each
set by most recent update first. Create sessions with a keyboard command. Show
each session's title and an attention marker for pending
elicitations. Indicate status with a face. Preserve point by session ID on
refresh. Child sessions are deferred.

Show each session on one line. Use faces, not glyphs, for session states. Show
`!` in a separate column when an elicitation is pending; otherwise leave it
blank.  Truncate long titles rather than wrap lines, and keep the attention
marker visible in narrow windows. Do not show a legend in the buffer. Use `g`
for manual refresh.  Refresh once after Emacs has been idle for 10 seconds,
even if the side window is hidden; stop the idle timer on disconnect. If
refresh fails, report the failure and keep the existing rows, which may be
stale. If the server reports a truncated list, show a non-selectable warning
line. `RET` opens the selected session's conversation buffer in the main
window and keeps the session side window visible. Move point to the
conversation buffer. Press `TAB` on a project heading to fold or unfold its
sessions. Press `TAB` on a session to fold its project and move point to the
heading. Preserve the fold state across refreshes. Press `m` on a session to
select a destination with completion. Select `[Unassigned]` to remove the
project assignment. Moving a session changes its server project
membership. Its workspace stays the same. Follow Treemacs or Neotree
conventions for other bindings where applicable. Use `a` to toggle archive and
`d` to delete the session at point. Archiving preserves history. Ask for
confirmation before permanent deletion with `y-or-n-p`. The conversation
commands use `C-c C-a` to toggle archive and `C-c C-d` for Delete.

On connection, fetch the configured global session limit. The default is 20
sessions total. Load project details for the sessions in that list. Press
`/` to find a project, show its heading, and fetch its sessions. Search and
move load the full project catalog on first use and cache it for the
connection. Press `+` or `-` on a project heading
or session row to change only that group's limit. The commands start from the
number of sessions shown in that group. A numeric prefix changes the limit by
that amount. A limit of zero hides the group's session rows. Project fetches
use the current archive setting.

Use the session state face on the whole line, with a separate attention face on
`!`. Provide faces for running, waiting, idle, failed, and archived sessions. Use
the archived face for archived sessions regardless of their reported status. Make
the current session's title bold without replacing its state face.
Show failed actions with the action, session title, and available status and
diagnostics. Follow the [API callback
design](api-callbacks.md#validation-and-error-presentation) for one-shot
request-error presentation. Do not mark sessions that lack live updates. Do not add
stale-state visual indicators in v1. Disconnected or recovering conversations are
read-only. A failed snapshot leaves its conversation invalid and read-only; report the
error and ask the user to copy drafts before closing and reopening it to try again. See
[reconnection.md](reconnection.md) for the recovery lifecycle. Keep open sessions
visible by merging the fetched list with watched sessions.

### Session creation

Run `omnigent-sessions-create` for quick creation. With a prefix argument,
open a Transient that displays the draft values. Use `RET` to submit.
The Transient edits only this draft and does not save user options.
Cancel a picker with `C-g` to return to the menu with the same draft.
Cancel at the menu to leave the creation flow. In quick creation,
canceling a required picker ends the command.

Use `h` to set the execution host type. For an external host, show host,
workspace, and worktree controls. For a managed sandbox, show provider,
profile, and Git repository controls. Both host types show agent, model
ID, reasoning effort, title, and native launch arguments.

Fetch host, workspace, agent, provider, and profile choices asynchronously
and use `completing-read`. Use a fixed completion list for reasoning
effort. Read the model ID, title, and native launch arguments as text.
When a create request reports failure, return to the draft if it still
belongs to the active server. Do not resubmit automatically. See
[session-tree.md](session-tree.md#session-creation) for defaults and
request behavior.

### Managed sandbox provisioning

Open a managed session or fork when the server returns its ID. Show an
animated status block before the composer while the agent starts. Keep
the status outside the saved transcript and preserve any composer text.
The composer is read-only while provisioning.

Use the snapshot's `sandbox_status` on open and after reconnect. Update
the block from `session.sandbox_status` events. On `ready`, remove the
block and refresh session metadata. Show server instructions if the
provider needs user action. On failure, stop the spinner and show the
error in the session buffer.

## Conversation

Use one buffer per session, named `*omnigent: TITLE [conv_XXXX]*`: the session
title (or `Untitled`) and the first characters of the session ID. The name is
for display only; identify buffers by their buffer-local session ID.

Use a mode derived from `text-mode`. Show a read-only transcript and an editable
composer headed by `>`. Start input on the same line after `> `.  Give the
protected prompt a text field boundary so Evil line edits operate on input.
Limit Evil change operations in the composer to the input bounds so line changes
preserve adjacent input lines.  Align explicit continuation lines and visually
wrapped lines with the first input character. This indentation is display-only
and is not sent as part of the message. `RET` inserts a newline; `C-c C-c` sends
the message. Distinguish user, agent, tool, reasoning, and error text with
faces. Show tool calls and reasoning in foldable blocks. Show streamed output
before the pending-message area and composer. Show pending messages in queue
order immediately above the composer, with `[queued] >` labels. Place new
pending messages below older ones. Insert incoming agent output above all
pending messages. Keep the target session clear in each buffer. Detailed
rendering and buffer behavior are in
[conversation-buffer.md](conversation-buffer.md).

### Queued messages

Submitted messages are read-only. Show a confirmed pending message with a `[queued] >`
label. When the server confirms consumption, move the message into normal read-only
history and remove the label. Trust server-reported acceptance and message state. If the
send outcome is unknown, show an unconfirmed state instead. After snapshot recovery,
render the server's current history and pending messages; earlier local labels need not
survive. Use standard Emacs commands to select and copy text; no dedicated copy command
is needed.

### Transcript and folds

| Item | Presentation |
|------|--------------|
| User message | `You:` label, Markdown when ready, no fold. |
| Assistant message | Agent name label, plain text while streaming, Markdown when ready, no fold. |
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

Faces: `omnigent-ui-prompt` for the composer prompt and message labels,
`omnigent-ui-reasoning` for reasoning, and `omnigent-ui-error` for error
headings and interrupt markers. Apply Markdown to ready messages and highlight
composer text according to [markdown-rendering.md](markdown-rendering.md).  Do
not add a plan panel in v1.

Show the workspace folder name, role, model, reasoning effort, access mode, and context
window usage in the conversation header. Do not show the harness or session name in the
header. The buffer name shows the session name. Show unknown values when the server does
not report them. Update the header from session snapshots and stream events.

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

The conversation implementation must keep separate boundaries for transcript,
request blocks, pending messages, and composer. Place request blocks above
pending messages. Stream insertion and transcript refresh must not overwrite
request drafts or composer text. Incoming output must not move point from the
composer or interrupt typing. Follow incoming output with normal Emacs scrolling
when needed to keep point visible. Restore the window's reading position after
transcript updates without forced recentering.

### Transcript updates

Keep unchanged transcript blocks in the buffer, including their display
properties. Append new blocks and replace only blocks whose rendering inputs
change. Track boundary markers and rendering inputs by item ID. Reconcile
snapshot removals and ordering against the server state. This strategy applies
to both stream updates and snapshots. The first snapshot in an empty buffer
inserts all blocks; later snapshots preserve unchanged blocks. A stream update
can replace the current block without rebuilding the full transcript. Stream
updates remain batched at 50 ms intervals while a response is active.

Updates can target any existing item, including an earlier message. Compare
rendering inputs by item ID rather than assuming that only the last item can
change. Replace the affected block at its existing position. Function-call
rendering inputs include the output matched by call ID, so late tool output
updates its earlier call block. Fold changes also affect only their block.

The conversation layer decides whether to accept an event. Committed items
reject added-item events and text deltas. A later final full item or snapshot
can still replace their content. Rendering does not bypass these rules or infer
event order from the displayed block position.

When a ready message changes, discard its previous Markdown properties with the
replaced text. Apply Markdown again when the replacement enters the display
area. Preserve unchanged blocks, composer text, request drafts, folds, point,
and reading position. See [markdown-rendering.md](markdown-rendering.md) for
readiness and deferred processing.

Reconciliation still scans transcript items to compare rendering inputs. It
avoids deleting, inserting, and parsing all message text on each update; it does
not make each update constant-time.

## Workspace view

Show workspace changes for the selected conversation in a left side window below
the session list. Let Emacs choose the initial height split and allow normal
window resizing. Open the workspace panel automatically on server connection
when the current session has changed files. Users can close it and open it again
with a command. After the user closes it, keep it closed on ordinary
updates. Reopen it when the user selects a different conversation with changed
files, or when the selected session's turn ends with changed files. Fetch
changes on terminal `session.status` events (`idle` or `failed`); input-delivery
`response.completed` events can precede the native turn's end.  List changed
files as flat, workspace-relative paths. Prefix each path with `A`, `D`, or `M`
for the server's created, deleted, or modified status. Sort files alphabetically
by workspace-relative path, regardless of status. Add a selectable `[unified
diff]` row above the files; `RET` on that row displays the combined diff. `RET`
on a file displays its diff using Emacs window selection rules and the user's
`display-buffer` configuration; do not force the main window. Fetch fresh data
each time a diff is opened. Show the diff in a separate buffer. Use
`omnigent-workspace-diff-mode` to select its mode function; the default is
`diff-mode`. If the requested file has no diff, report that no diff is
available. If a diff request fails, do not report the failure; leave any
existing diff buffer unchanged. Reuse the existing buffer for the same session
and file, replacing its contents only after a successful fetch.  Likewise, reuse
one combined-diff buffer per session. Set the diff buffer's default directory to the
mapped workspace root. Use `f` on a file row to visit the file through the same mapping.
Keep a separate workspace buffer per session. After the new conversation opens
successfully, or the user selects an
existing conversation through Emacs buffer commands, replace the panel contents
with the selected session's cached list, or clear it if there is no cached
list. Keep the last selected session's workspace panel when another,
non-conversation buffer is displayed.  When multiple conversations are visible,
use the most recently selected conversation window. Fetch the change list when a
session is selected and when its stream reports
`session.changed_files.invalidated`. A late response updates only its own
session's buffer, not the selected session's panel. Use `g` for manual
refresh. Preserve point by file path on refresh; if the file is gone, move point
to the nearest remaining row. A failed fetch is a no-op: keep the panel's
previous contents and visibility, which may be stale. Do not report the failure
in v1. A successful empty list closes the panel, and the session list expands to
use the available side-window height. The remaining UI details are open for
discussion. Data collection and API semantics belong to
[workspace-changes.md](workspace-changes.md).

## Nongoals

No full dashboard, policy editor, Git staging or commit actions in v1.
Agent and policy definitions remain in configuration files.
