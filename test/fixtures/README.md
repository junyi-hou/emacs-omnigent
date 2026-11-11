# Mock fixtures

Each JSON file scripts one model-behavior scenario for the mock LLM
server from the upstream test suite. The Elisp tests load these files,
post them to the mock's `/mock/configure` endpoint with a unique
routing marker, and keep only assertions and UI driving in Elisp.

## Format

```json
{
  "upstream": "tests/e2e_ui/<file>.py",
  "prompt": "test <scenario>",
  "responses": [{"text": "..."}],
  "responses_by_harness": {"claude-native": [...], "codex-native": [...]},
  "expect": {"file_content": "..."}
}
```

- `upstream`: the upstream test this fixture mirrors, at the tag
  pinned in `pixi.lock`. On a version bump, re-diff this file against
  that test.
- `prompt`: the user prompt prefix; the loader appends a per-turn
  marker.
- `responses` or `responses_by_harness`: the queue script in
  consumption order, the same shape the upstream test passes to
  `configure_mock_llm`. Supported keys: `text`, `thinking`,
  `tool_calls`, `delay`, `block`, `error`, `usage`,
  `refusal_category`, `chunk_delay`, `truncate_after`.
- `expect`: optional expected side effects for assertions, such as the
  file content a scripted Write tool call must produce.

Plain reply turns do not need a queue: `omnigent-mock-set-reply`
installs a fallback response that background requests (title
generation, probes) also consume, so they cannot drain a scripted
queue.

## Coverage map

Mirrored and covered by the Emacs suite, at Omnigent 0.21.0:

| Fixture               | Upstream test                                                 | Emacs tests                                                                                            |
|-----------------------|---------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| agent-message.json    | tests/e2e_ui/messages/test_message_render_parity.py           | agent-turn, reopen-completed, multiple-hosts, create-to-chat, send-while-busy, model and effort checks |
| usage-turn.json       | tests/e2e_ui/chat/test_context_meter_freeze_on_failed_turn.py | conversation-header                                                                                    |
| tool-read.json        | tests/e2e_ui/messages/test_native_claude_render_parity.py     | tool-call                                                                                              |
| permission-write.json | tests/e2e_ui/approvals/test_native_claude_question.py         | change-permission, decline-and-cancel-permission, elicitations-survive, two-conversations              |
| long-running.json     | tests/e2e_ui/chat/test_queued_message_lifecycle.py            | interrupt-running-turn, ui-interrupt, close-running, send-while-busy, two-conversations                |
| thinking-turn.json    | tests/e2e_ui/messages/test_native_claude_reasoning_in_chat.py | live-conversation-response                                                                             |

Upstream scenarios not yet mirrored, as the roadmap for the Emacs
client:

| Upstream test                                      | What it covers                                   | Status                                          |
|----------------------------------------------------|--------------------------------------------------|-------------------------------------------------|
| test_escape_interrupts_working_session.py          | Escape interrupts a working turn from a draft    | not covered; the UI interrupt keybinding exists |
| test_draft_survives_incoming_messages.py           | Composer draft survives incoming messages and queue flush | queue-flush draft covered by send-while-busy; arriving permission prompt not covered |
| test_stream_disconnect_stage_matrix.py             | Stream error recovery across disconnect stages   | not covered                                     |
| test_cancel_message_model_switch_live.py           | Canceling a queued message after a model switch  | not covered                                     |
| test_claude_native_refused_delivery_persistence.py | Safeguard refusal rendering and persistence      | not covered; needs refusal_category support     |
| test_claude_native_hook_retry_stop.py              | Hook block and retry states in chat              | not covered                                     |
| test_native_claude_compact_restart_resume.py       | Session compaction and resume                    | not covered                                     |
| test_fork_carries_attachments.py                   | Forked sessions with attachments                 | not covered                                     |
| test_side_chat_mcp_allowlist.py                    | Side chat and MCP tool advertisement             | not covered; terminal client has no side chat   |

Out of scope by design: browser-surface journeys (xterm attach, view
toggles, modals, mobile layouts) that a terminal client does not
render, and upstream stub-harness journeys that do not use the mock
LLM at all.
