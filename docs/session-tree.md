# Session Management Design

**Status:** Session-list state, buffer registration, creation, and lower-level actions
are implemented in `omnigent-sessions.el`. Conversation integration and frontend
presentation remain incomplete. This document owns session-list data, actions, and
update-frame handling. It calls the APIs in [transport.md](transport.md) for all server
input and output. Transport parses and forwards frames; this component interprets them
and updates list state. [frontend.md](frontend.md) owns presentation.

## Public APIs

The v1 client needs these server APIs. One-shot requests follow the [API
callback design](api-callbacks.md) for result delivery, response validation, and
callback lifetimes. This document specifies session payloads and state changes;
the WebSocket subscription has its own transport contract.

| Operation | Server API | Client helper |
|---|---|---|
| List sessions | `GET /v1/sessions?limit=1000&include_archived={true|false}&sort_by=updated_at&order=desc` | `omnigent-transport-list-sessions` |
| List projects | `GET /v1/projects` | `omnigent-sessions-refresh-projects` |
| Move session | `PATCH /v1/sessions/{id}` with `project_id` | `omnigent-sessions-move` |
| List agents | `GET /v1/agents` | `omnigent-transport-request` |
| List execution hosts | `GET /v1/hosts` | `omnigent-transport-request` |
| Browse host directories | `GET /v1/hosts/{host_id}/filesystem` or `/filesystem/{path}` | `omnigent-transport-request` |
| Create session | `POST /v1/sessions` with an agent and draft settings | `omnigent-transport-request` |
| Interrupt | `POST /v1/sessions/{id}/events`, type `interrupt` | `omnigent-transport-post-session-event` |
| Toggle archive | `GET /v1/sessions/{id}`, then `PATCH` with the opposite `archived` boolean | `omnigent-sessions-toggle-archive` |
| Delete | `DELETE /v1/sessions/{id}` | `omnigent-transport-delete-session` |
| List updates | `WS /v1/sessions/updates` | `omnigent-transport-start-session-updates`, `omnigent-transport-set-session-updates-watch`, `omnigent-transport-stop-session-updates` |

Use the session row's `project_id` to identify its project. Send an empty
`project_id` string to remove the assignment. Refresh sessions after a move
succeeds.

Toggle Archive reads the current server state and archives or unarchives the
session. Both operations preserve history. Include archived sessions when
`omnigent-fetch-archived-sessions` is non-nil. The server controls agent cleanup.
Archive does not request worktree deletion. Session management does not expose a Stop command;
use Interrupt to cancel the current turn.

Delete permanently removes the conversation; request confirmation with
`y-or-n-p` before deleting it. Do not use deletion as a close operation.

### Session creation

Create sessions on the connected server. See
[transport authentication](transport.md#authentication) for the current
authorization requirements.

Both creation paths start with the individual user options in the
`omnigent-session-creation` Customize group. A Transient edit overrides
the corresponding option for one request. Clearing an
optional field leaves it out of the request so the server can apply its
default. Quick creation has no draft edits and prompts only for required
values that it cannot resolve. The server requires an agent ID for
ordinary creation. Fetch the agent list to resolve a configured agent
name or ID, or use completion if the draft has neither. Show agent names
in completion and add IDs when names are shared. An omitted title lets
the server derive one.

#### Execution host and workspace

When the draft omits `host_type`, the server uses `"external"`.
External sessions need an online execution host and a
workspace on that host. Use the session at point or the current
conversation to fill missing location fields. Use the context workspace
only when its host matches the chosen host.

If the draft needs a host, fetch `GET /v1/hosts`. Select the sole online
host automatically. When several are online, prompt with their names and
IDs. Report an error when none are online. When the host is known and
the draft still needs a workspace, browse that host's filesystem through
the server. The Emacs project root does not supply a remote path.

Offer directories only. Fetch all listing pages and cache them during
the prompt. Validate the chosen directory with a fresh request, including
when the user types the path. Resolve relative input under the host's
home directory. Accept absolute and host-relative tilde paths. Reject
TRAMP paths. Send the host ID and native workspace path. An optional
`git` object requests a new worktree with a branch name and optional base
branch.

#### Managed sandbox

Set `host_type` to `"managed"` to request a managed sandbox. Omit
`sandbox_provider` to let the server choose. Use `GET /v1/info` to discover
providers and the server's default provider. If the draft has no profile,
check `GET /v1/sandbox-profiles` and prompt when the provider requires a
profile. Send the selected profile ID and revision.

Managed requests omit the connected host and worktree settings. Optional
Git repository URLs go in `workspaces`. A URL can include a
`#branch` fragment. The server provisions the sandbox after creating
the session. Open the conversation as soon as the server returns its ID.
Apply the same provisioning status rules to creation and forks. See
[frontend.md](frontend.md#managed-sandbox-provisioning).

For example, configure quick creation with a registered agent and the
server's default sandbox provider.

```elisp
(setq omnigent-session-default-host-type "managed"
      omnigent-session-default-agent "codex-native-ui")
```

#### Requests and results

Fetch picker data asynchronously. Use cached directory results during
completion and refresh them when another listing arrives. Abort
submission if the server changes during selection.

Pass a successful create response to `omnigent-sessions-open-hook` and
refresh the session list after the write completes. See
[frontend.md](frontend.md#session-creation) for menu and error behavior.

## List and updates

Fetch active sessions on initial load and manual refresh. Include archived sessions
when `omnigent-fetch-archived-sessions` is non-nil. The server
defaults to 20 entries; request 1,000, sorted by most recently updated first. The server
must sort before applying the limit. Pagination beyond that is post-v1. Do not silently
represent a truncated result as complete.

Check that list responses contain an array and the string fields needed to
process each row. Check the session ID before opening a created session. Missing
or malformed fields are client processing failures, not empty results. Preserve
the previous list and truncation state when a response is malformed. An explicit
empty array is valid.

Subscribe to session updates. A watch message replaces the complete watch set, which
contains only IDs with live conversation buffers. Creating or closing a conversation
buffer adds or removes its ID. The server limits the watch set to 500 IDs, so refuse to
open a new conversation buffer at the limit and report why.  Reusing an open buffer is
still allowed. Manual refresh reconciles all loaded rows; rows without open conversation
buffers do not receive live updates. The transport reconnects and resends the watch set.

The server sends a snapshot after each watch, changed and removed frames, and
heartbeats. Merge the fetched root list with watched sessions that have open
conversation buffers. Keep each open session visible even when it falls outside
the fetched list. Sort merged rows by their last known `updated_at`. Apply watched
updates to its row. A removed frame removes its
row. Treat a `removed` frame as session deletion, even though the server can also
send it when access is lost. If its conversation buffer is open, freeze it as-is,
including any draft,
and make it read-only; do not report the deletion. Close its workspace panel. Do not infer that a session was deleted merely because a list refresh omitted
it. After a conversation buffer closes, retain its row until the next successful
list refresh; remove it then if it is absent from the fetched list. Reconcile on
reconnect and manual refresh. Child sessions remain outside v1.

The server owns session state. Refresh the list once after Emacs becomes idle for
10 seconds, in addition to live updates and manual refresh. Do not repeat the
refresh during the same idle period. Keep the idle timer active while connected,
even when the session side window is hidden; stop it on disconnect. The frontend
owns the list's display and ordering. The conversation frontend owns user-facing actions. Child-session
display and management are post-v1; do not fetch child lists or open child conversations
in v1.

## Checks

Use fixture list responses and update frames to check root updates, unknown IDs,
removals, reconnect, buffer open and close, and refusal to open a 501st buffer.
Check that the request selects the 1,000 most recently updated sessions and that
a truncated list is not presented as complete. Check that commands return
between requests and that completion does not duplicate pending directory
requests. Real-server tests mock user choices, browse nested directories, and
reject a missing typed path before creation. Existing transport tests cover the
WebSocket.

## Deferred

Child sessions, cursor pagination beyond 1,000,
search, custom ordering, automatic remote-host setup, TRAMP-to-host inference,
managed sandbox creation, advanced creation options, and `delete_worktree` are
post-v1. Selecting an existing online remote host is supported. V1 still lists
archived sessions.

## Forking

`C-c C-f` forks a conversation with its existing agent and history. The
client launches a new runner on the source host in the source workspace
and opens the fork after launch succeeds.

### Fork menu

For a connected host, keep the quick fork on the source host and workspace. Use
`C-u C-c C-f` to open a Fork Transient with those values filled in.
Use the same async host and workspace picker as session creation.
Allow the user to choose a new worktree branch. Use the source agent
and full history by default. The response picker lists response IDs
from the loaded conversation. For model and reasoning effort, distinguish inheritance
from a reset to the selected agent's defaults.

Resolve the host and workspace before creating the fork. Send the history
and agent options in the fork request. After the server creates the fork,
launch its runner on the selected host. If launch fails, report the fork ID
so the user can find the session that already exists. Keep the fork request
separate from runner launch.

For a managed fork, choose the managed host type in the menu. When the
source is known to use a managed sandbox, the quick fork uses a new
sandbox. The server inherits the source repositories. The client can
select a provider and profile through the same discovery requests as
creation. The fork request leaves host and workspace binding to the
server.

## References

- [Frontend design](frontend.md)
- [Transport design](transport.md)
- Omnigent 0.19.1: `server/routes/sessions/routes_core.py` and
  `server/routes/sessions/routes_events.py`.
