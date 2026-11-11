# Native harness contracts

These contracts describe the installed Omnigent 0.21.0 server. The integration
fixture supports `claude-native` and `codex-native`. It does not emulate ACP or
use `claude-sdk`.

## Workspace APIs

Both harnesses use the same session resource API. There is no Claude-specific or
Codex-specific changes endpoint. Under `/v1/sessions/{id}`, use:

| Method | Path | Result |
| --- | --- | --- |
| GET | `/resources/environments` | Available environment resources |
| GET | `/resources/environments/{environment}` | Environment metadata |
| GET | `/resources/environments/{environment}/filesystem` | Root listing with `base` and `data` |
| GET | `/resources/environments/{environment}/changes` | Git paths and change statuses |
| GET | `/resources/environments/{environment}/diff/{path}` | Before and after file contents |
| PUT | `/resources/environments/{environment}/filesystem/{path}` | Write a file; invalidate changed-file state |

Environment IDs are opaque. `default` means the agent's primary OS environment;
it is not an alias for any running terminal. Terminal resources can refer to a
separate environment through their `environment` field. Do not construct that ID
from the harness name.

The server rejects filesystem operations if the agent has no `os_env`. Selecting
a terminal environment does not bypass this check. Both fixture agents declare
`os_env`, so the existing `default` paths work without a client routing change.
Their test-only OS environment uses `sandbox.type: none`. An explicit confined
sandbox also applies to the native CLI and must grant access to its
configuration and bridge files. Native tool approval remains enabled and is
tested separately from OS confinement. Each ordinary test session gets a
separate temporary workspace.

## Permission cards

Both native harnesses resolve permission cards through:

```text
POST /v1/sessions/{id}/elicitations/{elicitation_id}/resolve
```

```json
{"action":"accept"}
```

The action is `accept`, `decline`, or `cancel`. Optional `content` carries form
answers or offered approval options. The resolve request returns HTTP 202; that
acknowledgement does not prove tool execution. Check the file or tool output.

| Harness or fixture | Permission request | Client response | Native conversion |
| --- | --- | --- | --- |
| `claude-native` | `requestedSchema: null`, policy `claude_native_permission` | Binary action; no enum answer | Accept becomes `allow`; decline/cancel become `deny` |
| `codex-native` | `requestedSchema: null`, command/file/permission approval phase | Same binary action | V2 accept/decline/cancel, or legacy approved/denied/abort |
| Previous mock-acp fixture | Form with `properties.answer.enum` | Selected form answer | ACP adapter owns its option conversion |
| Other harnesses | Not covered by this fixture | Follow the actual request schema | No new adapter is added here |

A null permission schema does not imply that every elicitation is binary. User
questions can still require form answers. Extra permissions must match options
that the server offers. Examples include Claude's `remember` or
`allow_all_edits`, and Codex's `execpolicy_amendment`.

Codex 0.160.1 accepts `on-request` and `never` for `--ask-for-approval`, not
`untrusted`. Tests request `on-request` with `workspace-write`; the permission
scenario explicitly requests `sandbox_permissions: require_escalated`. A normal
write within the workspace would not reliably produce an approval card.
Omnigent's default automatic reviewer is not suitable for this permission test.

Runtime controls differ. Claude uses `PATCH /v1/sessions/{id}` with
`permission_mode`. Codex uses `approval_mode`, not `permission_mode`. The four
`omnigent-mock-claude-change-*` tests remain Claude-specific.

## Native transcript and streaming

Input delivery and model execution have separate lifecycles. A native
`response.completed` with empty output can acknowledge input delivery while the
model still runs. The native model turn identifies itself through
`session.status` with a `response_id`. The client must not discard its later
ID-less reasoning or text deltas, or clear that turn when a different response
completes.

Committed items are authoritative. Native transcript forwarding can finish after
an input-delivery completion or a transient idle status. Before reopening a
completed exchange, tests wait for both committed user and assistant items. Tool
tests wait for the actual call and output, correlate their observed `call_id`,
and check real file contents. They do not expect ACP display titles or fixed
IDs.

The mock long-running turn has one reasoning block and one text block. Each
block has three delayed deltas. Anthropic uses `content_block_delta`; Responses
uses `response.reasoning_summary_text.delta` and `response.output_text.delta`.
Chat Completions uses repeated choice deltas. Done events carry the complete
content. Three complete blocks are not a substitute for three deltas within one
block.

The queue test checks two restored exchanges after the first long-running turn.
The old mock produced three complete assistant blocks for the first turn, so its
exact-two-item wait failed even though the queued message was answered.

## Version checks and remaining compatibility limits

The runner installs Claude Code **2.1.181** and Codex **0.160.1**. Launch
wrappers check the actual executable version on every invocation and disable
Claude's updater. Native runner diagnostics also report the CLI version. The
runner still performs dependency preparation unconditionally.

Claude 2.1.181 has two observed limits with this installed Omnigent version:

- Its native `MessageDisplay` hook records the full long-running text once, with
  `final: true`. The same CLI in print mode receives three separate API text
  deltas. The mock protocol is therefore streaming, but this TUI path does not
  expose those partial text chunks. The live-conversation assertion remains
  strict.
- A runtime permission change returns HTTP 503 because Omnigent cannot read the
  default permission-mode footer. The terminal shows the effort indicator but no
  permission label. The permission-control test remains strict. This needs a
  compatible CLI/server pair or an upstream footer-parser fix.

Codex's native SSE trace does contain separate delayed text deltas. The Emacs
client previously dropped them because it only recognized response-start events.
The client now recognizes the native status lifecycle, with a unit regression
for both input-completion orderings.

Source references in the installed Python package: `runner/resource_routes.py`,
`runner/resource_registry.py`, `server/routes/sessions/routes_elicitations.py`,
`server/routes/sessions/routes_hooks.py`, `server/routes/_codex_elicitation.py`,
`harnesses/claude_native/bridge.py`, and both native `forwarder.py` modules.
