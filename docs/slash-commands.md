# Slash Commands Design

**Status:** Proposed. This document defines command dispatch in the conversation
composer. [conversation-buffer.md](conversation-buffer.md) owns message submission.
[api-callbacks.md](api-callbacks.md) owns asynchronous request behavior.

## Dispatch

When the user submits the composer with `C-c C-c`, check for an Omnigent command.
Omnigent owns the command names in the inventory below. An Omnigent command takes
precedence when a harness defines the same name.

Recognize a command only at the start of the composer. The name ends at the first
space, tab, newline, or end of input. Match the name exactly and case sensitively.
For an owned command, spaces and tabs after the name separate it from its argument.
Trim spaces and tabs around the argument. Treat an empty argument as absent. An
owned command with a newline is invalid: report the error and keep the draft.
Do not send an invalid owned command to the harness.

After checking owned commands, match the session skill catalog. Send a matched
skill as a structured `slash_command` event. Send all remaining nonempty input
unchanged through the existing message POST. The harness decides how to interpret
that input. Use the existing pending and transcript reconciliation flow for both
messages and skill commands.

## Omnigent commands

The following names belong to Omnigent. Unsupported commands call one shared
no-op handler. It reports that the command is not supported and preserves the
draft. It does not send the text to the harness. Side-chat support, MCP controls,
and permission controls are deferred.

| Command | Emacs behavior |
|---|---|
| `/model [name]` | Reuse the existing model command. Select a model without an argument; set the supplied model directly. |
| `/effort [level]` | Reuse the existing effort command. Select a level without an argument; set the supplied level directly. |
| `/compact` | Dispatch from the composer through an internal POST. Reject arguments. No separate interactive function is required. |
| `/clear` | Call a new interactive clear command. Follow the server to the new session, create its conversation buffer, and select it in the current window. |
| `/context` | No-op. The header line presents context information. |
| `/mcp` | No-op. MCP controls are deferred. |
| `/permissions` | No-op. A permission setting command is planned; harness-specific handling is deferred. |
| `/new` | Call `omnigent-sessions-create` interactively and clear the composer. |
| `/btw [question]` | No-op. Side questions are deferred. |
| `/side [question]` | No-op. Side-chat design is deferred. |
| `/help` | No-op. Slash completion via `completion-at-point-functions` is planned. |

The clear command starts a session with no title or prior context on the same host
and workspace. The server handles session creation. The client opens and selects
its conversation buffer in the current window. The installed server's native clear
path reports the replacement through `session.superseded`; the client must follow
that event and use the replacement session ID. Check other harness paths before
assuming they use the same event. Reject arguments to `/clear` and `/new`.

The installed server's `compact` control event forwards only the event type to the
runner. The official frontend instead sends `/compact` as a message for some
native harnesses. Confirm the correct event or message path per harness before
implementation.

The official frontend matches skills from session data and posts a structured
`slash_command` event with `kind: skill`, `name`, and `arguments`. The server asks
the runner to resolve the skill on its host. It records a visible slash-command
item and a hidden message with the skill instructions. It sends the hidden message
to the runner. A resolution error is reported; the server does not fall back to a
plain message in this path. Render the visible skill command as a normal user
message, including its name and arguments. Reconcile its server item ID using the
existing submission and transcript flow. Do not render the hidden message.

Skill discovery is harness-aware. It can include the agent bundle, workspace,
host, and harness-specific skill or plugin directories. The catalog is not one
central list shared by all harnesses. The official frontend has additional prefix
and collision rules; this design uses the agreed Omnigent command precedence.
Use the catalog refresh behavior below.

Reuse `omnigent-conversation-set-model` and `omnigent-conversation-set-effort`.
Pass the complete trimmed argument as the value. Do not prompt again when a value
is present. Let the server validate the value. Both commands use the existing
session setting endpoints and obey the conversation's read-only state. Reset values
need a separate path: a missing argument currently opens a selector, while a reset
requires a JSON null setting.

These functions report request outcomes through messages. Preserve their existing
interactive behavior. A successful HTTP response means the server accepted the
request; it does not prove that a later background change completed.

## Skill catalog discovery

Fetch `GET /v1/skills?session_id=SESSION_ID` for the current conversation. The
server uses the session's host, workspace, agent bundle, and skill filters. The
request requires session edit access. The host must be online and ready.

The response contains a `skills` array and a `warnings` array. Each skill has a
`name`, `description`, and optional `display_name`. Match the invocation against
skill names. Use descriptions and display names for presentation when useful. The
server and runner load skill contents; the client does not read `SKILL.md`.

A nonempty `warnings` array means discovery is incomplete. Report the warnings;
do not present the catalog as complete. A failed request also does not establish
an empty catalog. If the client cannot determine whether a slash command names a
skill, preserve the draft and report the discovery problem instead of sending it
as plain text. This prevents a missed skill from bypassing the structured route.

Fetch the catalog asynchronously when a slash command needs skill matching.
Refresh it before later skill dispatches. When future completion support fetches a
very recent catalog while the user types, reuse that cached result for dispatch.
Preserve the distinction between a complete empty catalog and an unavailable or
incomplete catalog when caching results.

## Draft and request behavior

For `/new`, clear the submitted command and call `omnigent-sessions-create`
interactively. For `/model` and `/effort`, use the same composer behavior: clear
the submitted command when invoking the existing command. Preserve later edits.

For other commands, keep the submitted command in the composer during selection
and request processing.
On cancellation, validation failure, setup error, or request failure, report the
outcome and preserve any remaining draft. A transport failure can leave the outcome unknown;
do not retry a mutation automatically. If the server accepts the request, clear
the submitted command only if the composer still contains exactly that text.
Preserve edits made while the request was in flight. Results for a closed buffer or
an earlier server connection follow the lifetime rules in
[api-callbacks.md](api-callbacks.md).

Do not block the UI while fetching choices or sending a request. Prevent a second
submission of the same local command while its selection or request is pending.
Report the pending state when the user attempts another submission. Normal message
submission remains governed by the existing sending state.

## Source and open decisions

The inventory comes from the installed Omnigent web frontend bundle
`NewChatDialog-Cw9Z1J88.js` and its dispatch in `index-CzcMPENv.js`, plus
`server/routes/sessions/routes_events.py` and `_sessions/helpers.py` in the installed
Omnigent package. The frontend uses capability checks and does not offer every
command for every session. Its `/compact` and `/clear` behavior depends on the
harness; the server also defines `compact` and `clear` session events.

Confirm the compact dispatch and clear replacement event for each harness before
implementation. Side chats, MCP presentation, and permission controls need their
own design. The draft and request rules above apply to setting mutations; other
commands need outcome and cancellation rules appropriate to their action.

## Checks for implementation

Check exact command matching, argument trimming, invalid multiline owned commands,
and unchanged forwarding of unknown commands. Check both setting commands with and
without arguments, including cancellation and server errors. Check that an accepted
request clears only the original draft, and that edits during a request survive.
Check read-only and pending states, server changes, and closed buffers. Check that
interactive setting commands still work independently of slash dispatch.
