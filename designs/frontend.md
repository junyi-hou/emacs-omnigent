# Emacs Frontend Design

**Status:** Proposed. Session start and selection exist; conversation buffers and side views are not implemented.

## Decision

Use a chat-centered interface. Keep the active Omnigent session in the main conversation buffer. Add optional views for child sessions and workspace changes. Use Transient for session actions.

The UI does not need to copy the Omnigent web app. Users can manage agent and policy definitions in config files from Emacs.

## Views

### Session Tree

After the user starts or connects to a server, open a session tree in a left side window. Keep it available while the user works. Show top-level sessions as roots and nest child sessions under their parent. Put `New session` first. Selecting a top-level session loads it. The current `completing-read` prompt is temporary.

Use the tree to select and monitor sessions. Show each child’s agent, status, and whether it needs attention.

#### Child nodes

Open a selected child in its own conversation buffer.

Selecting a child makes it the active conversation. Use the same composer to send messages directly to that child. The main session is the default when the user opens the session view. Show the active session clearly so users know where a message will go. Keep the parent and child transcripts separate. Do not merge child output into the parent transcript.

Use Omnigent’s child-session data and events as the source of truth. Do not infer child sessions from text or tool calls alone. A harness can have internal subtasks that Omnigent does not expose as child sessions. A child may share its parent’s runner; the client must target the selected child session ID.

For v1, support direct messages and interrupt. Send interrupt through `POST /v1/sessions/{id}/events` with `{"type":"interrupt","data":{}}`. Omit `stop_session` for now, although the API supports it: it is owner-only and terminates the live process. Add it only if users need a distinct terminate action. Do not add a close action: `sys_session_close` is an agent tool, not a client REST route. Do not use session deletion as close; it deletes the conversation.

### Conversation

The main conversation belongs to one Omnigent session. For an orchestrator session, this is the parent session.

Build `omnigent-conversation-mode` as a major mode derived from `text-mode`. Render the transcript as read-only text and keep an editable prompt region at the end. Use markers to insert streamed output before the prompt. Keep Omnigent session items and event IDs as session state; treat the buffer as a view, not the source of truth. Use text properties to mark messages and tool activity. See gptel as a chat-buffer design reference, not a dependency.

### Workspace Changes

Show workspace files and diffs in an optional side window. Use Omnigent’s workspace environment API for this view:

- `GET /v1/sessions/{id}/resources/environments/default/changes` lists files created, modified, or deleted during the session.
- `GET /v1/sessions/{id}/resources/environments/default/diff/{path}` returns the file’s `before` and `after` contents, not a unified patch. `before` can be null for a new file or an unknown baseline. `after` can be null for a deleted file.
- `GET /v1/sessions/{id}/resources/environments/default/filesystem[/{path}]` lists workspace files and directories.

Render the file diff in Emacs. Refresh the change list when the session stream reports `session.changed_files.invalidated`, and also when the session transitions from `running` or `waiting` to `idle`: the web client treats that end-of-turn refresh as a backstop because the invalidation event is throttled and runner-emitted. Handle HTTP 503 with error code `runner_unavailable` separately from 404: 503 means the runner is offline and a message can wake it, 404 means the session has no runner filesystem. These workspace endpoints are separate from `/resources/files`, which stores uploaded attachments.

The current web UI uses these endpoints, but the checked-in server API reference does not document them. Confirm their contract before relying on them. Some sessions have no runner filesystem and may return 404.

### Session Actions and Configuration

Use Transient for short-lived actions, such as selecting, sharing, forking, or archiving a session. The menu is temporary. The action can change persistent server state.

Keep agent and policy definitions in config files. Use Emacs to edit those files. Do not build a second policy editor in Transient. Add a transient action for a policy only when Omnigent exposes a clear session-level operation for it.

## Window Behavior

Keep the conversation as the main view. Place the session tree and workspace view on the left. Let users show or hide each view.

When both views are open, stack them vertically on the left. Put the session tree above the workspace view. Use the session tree as a live status surface. Use Transient for actions. A temporary menu is not a replacement for visible run state.

## Nongoals

- Do not build a full Omnigent dashboard before a workflow requires it.
- Do not show every child stream in the parent conversation.
- Do not add Git staging or commit actions to the initial workspace view.
- Do not add ETAF for a simple transcript. Reconsider it only if the UI needs richer layout or interaction than native Emacs buffers provide.

## Open Decisions

1. Confirm the workspace endpoint contract with Omnigent, since the web UI uses these routes but the checked-in server API reference does not document them.


## References

- [Omnigent programmatic usage](https://omnigent.ai/docs/programmatic)
- [Omnigent server API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md)
- [Web UI changed-files implementation](https://github.com/omnigent-ai/omnigent/blob/main/web/src/hooks/useWorkspaceChangedFiles.ts)
- [Web UI file-diff implementation](https://github.com/omnigent-ai/omnigent/blob/main/web/src/hooks/useFileDiff.ts)
- [Transport design](transport.md)
- [gptel](https://github.com/karthink/gptel)
