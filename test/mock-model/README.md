# Mock model server

This server exposes the mock-acp scenarios through model HTTP APIs. It uses only
Python's standard library. It listens on loopback and accepts any API key. Do
not use it as a public service.

```sh
python3 test/mock-model/server.py --port 8080
python3 -m unittest discover -s test/mock-model
```

Use `--port 0` to select a free port. The server prints its address at startup.
`GET /health` reports readiness. `GET /v1/models` lists two mock names and two
Claude model IDs. `GET /requests` returns received request paths and JSON bodies
in arrival order. The server records no authentication headers. These records
remain in memory until the server stops.

## APIs

The following endpoints support JSON and SSE responses:

- Anthropic: `POST /v1/messages`, including `?beta=true`.
- OpenAI Chat Completions: `POST /v1/chat/completions`.
- OpenAI Responses: `POST /v1/responses` or `POST /responses`.

Set `stream` to `true` for SSE. Anthropic token counting is available at `POST
/v1/messages/count_tokens`. Usage values are deterministic: 512 input tokens and
32 output tokens. These are test values, not token counts from the prompt.
Responses requests support full input history or `previous_response_id`.
Response history remains in memory until the server stops.

## Claude Code

Use a temporary working directory and configuration directory for integration
runs. Set the API base URL without `/v1`:

```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:8080 \
ANTHROPIC_API_KEY=mock-key \
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
claude --bare -p --model claude-sonnet-4-6 'test agent_message'
```

`--bare` prevents user hooks, plugins, and project configuration from affecting
the test. Keep normal permission checks enabled when testing permission prompts.

## Codex

Set the provider base URL with `/v1`. Codex uses Responses, not Chat
Completions:

```sh
codex exec --skip-git-repo-check --ephemeral \
  -c 'model_provider="mock"' \
  -c 'model_providers.mock.name="Mock"' \
  -c 'model_providers.mock.base_url="http://127.0.0.1:8080/v1"' \
  -c 'model_providers.mock.wire_api="responses"' \
  -m mock-model 'test agent_message'
```

Use a temporary `CODEX_HOME` directory to exclude user configuration. The
directory must exist before Codex starts.

## Scenarios

Send `test <name>` as the user prompt. Scenario matching uses the latest user
message, not system instructions or tool output. It tolerates harness notes
before the scenario line. Unknown prompts return `Done.`.

| Names | Model response |
| --- | --- |
| `agent_message` | The fixture's Paris response |
| `thought` | Thinking blocks or reasoning summaries |
| `plan` | A plan tool call, followed by a completed plan tool call |
| `tool_call`, `tool_call_read`, `tool_call_locations`, `fs_read` | A file-read tool call |
| `tool_call_edit`, `tool_call_diff`, `tool_call_diff_no_old`, `fs_write` | A file-write tool call |
| `tool_call_terminal` | A shell command that prints the fixture's terminal transcript |
| `request_permission` | A Write call for `mock-permission.txt`, or a shell fallback, subject to the client's permission policy |
| `long_running` | One thought block and one text block, each with three deltas and 1.5-second stream delays |
| `model` | The model ID in the request |
| `reasoning` | The requested reasoning effort, or `low` |
| `permission` | `ask`, a fixed mock value, not the client's actual policy |
| `error`, `init_error` | HTTP 500 |
| `auth_error` | HTTP 401 |
| `all` | All update scenarios, followed by permission, read, and write calls |

Tool scenarios require advertised tools. The server selects Claude's `Read`,
`Write`, `TodoWrite`, or `Bash`, or Codex's `update_plan`, `exec_command`,
`shell_command`, or `shell`. Chat Completions accepts nested function
definitions. Other tool sets return HTTP 400 when a scenario needs a tool.

The client executes tools, not the HTTP server. Prepare `src/config.json` and
`src/main.py` in a temporary workspace for successful read scenarios. Fixture
paths under `/home/user/project` become workspace-relative paths. Write
scenarios can change `src/config.json`, `config.json`, and
`mock-permission.txt`. The terminal scenario prints a transcript instead of
running `npm install`. Tool results, including permission denials and execution
errors, advance the scenario without repeating the call.

A closed stream affects only that request. Concurrent conversations use separate
request histories. Long-running delays apply only to streamed responses.

## ACP limits

All 43 JSON fixtures are copied unchanged from
[mock-acp](https://github.com/junyi-hou/mock-acp), revision
`549bab49a1e24e3a1d114adcf9fc73366def1c28`, the revision in the integration
runner. The `golden` directory contains the upstream ACP fixtures. The
`addition` directory contains mock-acp's extra fixtures. No ACP package or
checkout is needed at runtime.

Model APIs cannot emit ACP session configuration, user-message updates,
available commands, current modes, or session metadata. The `config_option`,
`user_message`, `available_commands`, `current_mode`, and `session_info`
scenarios return their fixture payload as JSON text. The `usage` scenario also
returns its ACP payload as text, alongside native API usage fields. These text
responses do not change the client's configuration or session metadata.

ACP tool progress, tool IDs, diff events, terminal references, and permission
choices are not model outputs. Claude or Codex generates those events from
native tool execution. The model server cannot force an allow/reject dialog or
reproduce ACP option IDs. The image and audio fixtures contain placeholder data,
not valid media. They remain vendored reference fixtures, not generated model
responses. ACP initialization and authentication handshakes have no model-API
equivalent; the error scenarios only simulate HTTP failures.

Tests that assert ACP-specific names, IDs, progress text, or configuration must
change during migration. The integration runner uses `claude-native` with
`agent/config.yaml`, or `codex-native` with `codex-agent/config.yaml`. See [the
native contracts](native-contracts.md) for workspace and permission APIs,
streaming semantics, and remaining version limits. Native control tests are
described in [`../README.md`](../README.md).

## Real-client check

Run the optional smoke check with the installed CLI paths:

```sh
python3 test/mock-model/smoke_cli.py \
  --claude .pixi/envs/test/bin/claude \
  --codex .pixi/envs/test/bin/codex
```

It starts a temporary server and workspace. It checks text, tools, thought, and
plan scenarios through both clients. It also checks the three text deltas in a
Claude print-mode long-running turn. It isolates client configuration and points
model requests at loopback. The check uses the clients' normal permission rules.
It does not install software or call a hosted model. This check passes with
Claude Code 2.1.181 and Codex 0.160.1.
