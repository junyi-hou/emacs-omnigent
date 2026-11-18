# Markdown Rendering Design

**Status:** Implemented in `omnigent-ui.el`. This document defines when message
text is ready for Markdown and how the frontend applies Markdown properties.
[frontend.md](frontend.md) owns layout and folds.
[conversation-buffer.md](conversation-buffer.md) owns transcript state and event
reconciliation.

## Scope

Apply Markdown highlighting and display properties to agent messages, user
messages, submitted pending messages, and the composer. Use `markdown-mode` to
interpret Markdown, including native syntax highlighting for fenced code.  Tool
output, reasoning folds, error messages, labels, and request widgets keep their
existing presentation.

Keep the source text unchanged. Message display can conceal Markdown delimiters.
The composer keeps delimiters visible so the user can edit the source. Sending
uses the exact composer text, without display properties.

## Ready for Markdown

A block is ready when the frontend can apply Markdown without processing each
incoming text delta. Ready does not mean immutable.

| Text | Ready condition |
|---|---|
| User message | The message is accepted or loaded from a snapshot. |
| Submitted pending message | The submitted text is available in full. |
| Agent message | A final full item arrives, the next block starts, or the response ends. |
| Snapshot message | The full message is available from the snapshot. |
| Composer | The user edits the draft. |

An active agent message remains plain text while its text streams. Starting a
new block ends the previous active text section for Markdown purposes. The final
message in a response becomes ready when its final item arrives or the response
ends. Snapshot messages are ready even if the session is still running.

Readiness permits processing. It does not require immediate processing of text
outside the window.

## Visible text and deferred processing

A message can be expanded but outside the window. Expanded messages are not
necessarily visible on screen. The composer can also be outside the window when
the user reads earlier history.

Use Emacs fontification to defer Markdown processing until ready text enters the
area that Emacs requests for display. Fontification can include nearby text.
When any part of a ready message needs processing, interpret the whole message.
This preserves Markdown constructs that span lines, such as fenced code blocks.

Apply the resulting faces and display properties directly to the existing text.
Mark the block as processed. Leave those properties in place on later updates
that do not change the block. Do not keep a separate cache of Markdown strings
or parsed messages.

After a composer edit, invalidate its Markdown properties and request
fontification. Interpret the whole composer when fontification runs. Do not
apply message delimiter hiding to the composer.

## Transcript updates and later corrections

Preserve unchanged transcript blocks in the buffer. Append new blocks. Replace
only blocks whose rendering inputs change. Tool output can change the associated
tool-call block. Snapshots can also remove or reorder blocks.

Track item IDs, rendering inputs, and boundary markers to identify affected
blocks. This tracking supports transcript reconciliation; it is not a Markdown
cache. Preserve composer text, request drafts, folds, point, and reading
position.

A later final item or snapshot can correct an existing message. Readiness does
not prevent that correction. Replace the affected block and discard its old
Markdown properties. If the replacement is ready, apply Markdown again when it
enters the display area. Other blocks retain their properties.

## Performance boundaries

A snapshot can contain thousands of blocks. Insert their source text and mark
ready messages without parsing Markdown for the entire history. Defer Markdown
work for messages outside the display area.

During streaming, update the active block without parsing its Markdown on every
delta. Existing transcript batching can still combine stream updates. Completed
messages require no repeat Markdown processing unless their rendering inputs
change.

Transcript reconciliation still scans item state. This design avoids rebuilding
all transcript text and parsing all Markdown on each update. It does not provide
constant-time reconciliation or incremental Markdown parsing within a block.

## Checks

Check that active text remains plain until ready. Check readiness after a final
item, a new section, response completion, and snapshot loading. Check that
messages outside the display area remain unprocessed until requested.

Check that unchanged blocks retain their properties. Check that later
corrections invalidate only affected blocks. Check composer highlighting after
edits, visible delimiters, exact source text, and read-only transcript
protection.  Use large histories to check that one active update does not render
all items.
