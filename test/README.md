# Integration tests

The integration runner starts a temporary Omnigent server, execution host, and
[local mock model server](mock-model/README.md). It registers the
`claude-native-ui` and `codex-native-ui` agents and launches the installed
native CLI. Claude is the default. Set `OMNIGENT_TEST_HARNESS=codex-native` to
run the shared tests through Codex. It does not use mock-acp or an ACP harness.

The runner creates a temporary home, Claude configuration, provider
configuration, database, workspace, and artifact store. Model requests use the
local Anthropic Messages or OpenAI Responses endpoint with a fake key. The
runner stops the processes and removes the temporary directory on exit.

The runner installs Pixi if necessary and runs `pixi install --environment
test`. It installs Claude Code 2.1.181 and Codex 0.160.1 with npm. Launch
wrappers check the actual version on every invocation and disable Claude
auto-updates. It uses `.pixi/envs/test/bin/omnigent` and
`.pixi/envs/test/bin/python`. Set `OMNIGENT_BIN` or `PYTHON` to use another
executable.

Run unit tests and both native integration suites separately:

```sh
make unit-test
make integration-test HARNESS=claude-native
make integration-test HARNESS=codex-native
```

`make test` runs unit tests and the selected integration suite together.
`HARNESS` defaults to `claude-native`. The Makefile passes it to the integration
runner through `OMNIGENT_TEST_HARNESS`. Unit tests do not depend on the selected
harness.

The runner needs network access for dependency installation, Emacs, Python 3,
Node.js, tmux, curl, and the Emacs `websocket` package. Set
`OMNIGENT_WEBSOCKET_LOAD_PATH` to an installed package directory to avoid the
runner's package download.

To select integration tests, set `OMNIGENT_TEST_SELECTOR` to an ERT selector.
For example, run the native model, effort, and permission checks with:

```sh
OMNIGENT_TEST_SELECTOR='"omnigent-mock-claude-change-"' \
  test/run-server-integration.sh
```

Add API integration tests to `omnigent-api-tests.el`. Add end-to-end behavior
tests to `omnigent-functional-tests.el`. Some older test names still contain
`mock-acp`; they now run through the selected native harness. Codex runs exclude
the four Claude-specific control tests by default. See [the native
contracts](mock-model/native-contracts.md) for workspace routing, permission
schemas, transcript timing, and known Claude compatibility failures. The Claude
full suite is not yet a passing baseline.

Run the shared suite through Codex with:

```sh
OMNIGENT_TEST_HARNESS=codex-native test/run-server-integration.sh
```

## Checked baseline

With Omnigent 0.21.0 and the pinned CLI versions:

| Checks | Result |
| --- | --- |
| Emacs unit tests | 104/104 passed |
| Mock server tests | 9/9 passed |
| Real-client smoke checks | 9/9 passed |
| Codex shared integration tests | 25/25 passed |
| Claude integration tests | 27/29 passed |

The two Claude failures are partial TUI text streaming and runtime permission
mode changes. Their assertions remain enabled. See the native contract document
for the observed version limits.

## Native controls

Model-change tests invoke the Emacs interactive model command. They check the
`model` field in Claude's next HTTP request, both before and after an initial
turn. The effort test uses the session PATCH API to select `low` and `high` and
checks `output_config.effort` in the next HTTP request. These checks use unique
prompt markers to select the request from `GET /requests` on the mock server.
They exclude title generation and model probes, and do not infer control changes
from logs or model-generated text.

The permission test changes a live session through the session PATCH API. In
`default` mode, a Write call must produce an elicitation and must not create a
file. The test declines the elicitation and checks that the file remains absent.
It then selects `acceptEdits` in the same session. The next Write call must
create the file without an elicitation. The test uses a separate temporary
workspace.
