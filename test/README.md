# Integration tests

The integration runner starts a temporary Omnigent server, execution
host, and the upstream mock LLM server. It registers the
`claude-native-ui` and `codex-native-ui` agents and launches the
installed native CLI. Claude is the default. Set
`OMNIGENT_TEST_HARNESS=codex-native` to run the shared tests through
Codex. It does not use mock-acp or an ACP harness.

The runner reads the Omnigent version pinned in `pixi.lock`, fetches
the matching `v<version>` tag of the upstream
[omnigent](https://github.com/omnigent-ai/omnigent) repository into
`test/upstream/omnigent`, and starts its
`tests/server/integration/mock_llm_server.py`. The mock and the
installed server therefore come from the same release. The checkout is
cached and refreshed when the pinned version changes.

The runner creates a temporary home, Claude configuration, provider
configuration, database, workspace, and artifact store. Model requests
use the mock's local Anthropic Messages or OpenAI Responses endpoint
with a fake key. The runner stops the processes and removes the
temporary directory on exit.

The runner installs Pixi if necessary and runs `pixi install
--environment test`. It installs Claude Code 2.1.181 and Codex 0.160.1
with npm. Launch wrappers check the actual version on every invocation
and disable Claude auto-updates. It uses
`.pixi/envs/test/bin/omnigent` and `.pixi/envs/test/bin/python`. Set
`OMNIGENT_BIN` or `PYTHON` to use another executable.

Run unit tests and both native integration suites separately:

```sh
make test-deps
make unit-test
make integration-test HARNESS=claude-native
make integration-test HARNESS=codex-native
```

`make test-deps` installs Evil, WebSocket, `f`, `s`, and their dependencies in
`.tools/test-elpa`, separate from user packages. Run it once before either
suite. Both runners load this shared directory. The integration runner no longer
installs Emacs packages. Unit tests then run offline and require Evil so the
composer regression test cannot silently skip. CI runs setup before the unit
suite. The package itself does not require Evil.

`make test` runs unit tests and the selected integration suite
together. `HARNESS` defaults to `claude-native`. The Makefile passes
it to the integration runner through `OMNIGENT_TEST_HARNESS`. Unit
tests do not depend on the selected harness.

The runner needs network access for dependency installation, the upstream
checkout, Emacs, Python 3, Node.js, tmux, curl, and the Emacs `websocket`
package from `make test-deps`. Set `OMNIGENT_WEBSOCKET_LOAD_PATH` to an
installed WebSocket package directory to override the shared directory for
integration tests.

To select integration tests, set `OMNIGENT_TEST_SELECTOR` to an ERT
selector. For example, run the native model, effort, and permission
checks with:

```sh
OMNIGENT_TEST_SELECTOR='"omnigent-mock-claude-change-"' \
  test/run-server-integration.sh
```

## Client recovery faults

The recovery tests in `omnigent-functional-tests.el` run five journeys through both
native harnesses:

- Finish a running task while the client is offline, then recover the same buffer.
- Fail a history read while SSE works, then require manual close and reopen.
- Suppress traffic on open SSE and WebSocket sockets, then check watchdog recovery.
- Consume queued input, resolve an elicitation, and change the session list offline.
- Deliver a delayed snapshot after buffer close or selection of another server URL.

Faults are injected in Emacs; no network proxy is required. Outage tests close client
connections and defer their retry timers until the server-side changes finish. The
snapshot-failure test returns a failed GET result. The late-result test holds a real GET
callback until its buffer closes or the server URL changes. The silent-socket test
replaces the old processes' filters with `ignore` and ages only their activity
timestamps. Replacement connections retain normal heartbeat margins.

The server, execution host, and mock model continue independently. Tests use event and
callback barriers, not fixed sleeps. The server-selection case uses a different URL for
the same isolated backend and opens a different session. These checks cover client
recovery from injected faults, not failures in the network or a deployed proxy.

Run only these tests with either harness:

```sh
OMNIGENT_TEST_SELECTOR='"^omnigent-reconnection-"' \
  make integration-test HARNESS=claude-native
OMNIGENT_TEST_SELECTOR='"^omnigent-reconnection-"' \
  make integration-test HARNESS=codex-native
```

These tests do not guarantee gap-free snapshot/stream handoff or test physical laptop
suspend. See [the recovery design](../docs/reconnection.md) for those limits.

## Mock fixtures

Model behavior is scripted per turn. Tests own their fixtures: each
Elisp test loads a JSON file from [fixtures](fixtures), which carries
the queue script (the same response dict the mirrored upstream test
passes to `configure_mock_llm`), the prompt prefix, and the upstream
test it mirrors. See [fixtures/README.md](fixtures/README.md) for the
fixture format and the coverage map against the upstream suite. Plain
reply turns use a mock fallback instead of a queue, so background
requests such as title generation cannot drain a turn's script.

Add API integration tests to `omnigent-api-tests.el`. Add recovery fault tests and other
end-to-end behavior tests to `omnigent-functional-tests.el`. Some older test names still
contain `mock-acp`; they now run through the selected native harness. Codex runs exclude
the four Claude-specific control tests by default.

Run the shared suite through Codex with:

```sh
OMNIGENT_TEST_HARNESS=codex-native test/run-server-integration.sh
```

## Native controls

Model-change tests invoke the Emacs interactive model command. They
check the `model` field in Claude's next HTTP request, both before and
after an initial turn. The effort test uses the session PATCH API to
select `low` and `high` and checks `output_config.effort` in the next
HTTP request. These checks use unique prompt markers to select the
request from `GET /mock/requests` on the mock server. They exclude
title generation and model probes, and do not infer control changes
from logs or model-generated text.

The permission test changes a live session through the session PATCH
API. In `default` mode, a Write call must produce an elicitation and
must not create a file. The test declines the elicitation and checks
that the file remains absent. It then selects `acceptEdits` in the
same session. The next Write call must create the file without an
elicitation. The test uses a separate temporary workspace.
