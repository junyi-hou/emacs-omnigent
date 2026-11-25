# Integration testing

`make integration-test` starts a real Omnigent server and the official
local mock LLM server. The integration tests cover service health and
cleanup, session list setup, session creation, and the messaging
journey. The messaging test checks the composer, queued messages,
streamed replies, recovered history, and the running and idle states
in the session list. The test runs Codex with the local mock model.

`make unit-test` checks that the integration test fixtures isolate each run and
clean up its resources. These checks can run without either server.

## Dependencies and setup

Install Node.js 24 with npm before you run the setup commands.

```sh
make integration-deps
make integration-test
```

`make integration-deps` clones the default branch of the official Omnigent
repository into `.tools/omnigent-upstream` if that checkout is missing. Set
`OMNIGENT_REPO` for both commands to use an existing checkout at a different
path.

`make integration-deps` runs `make test-deps` to install Emacs packages in
`.tools/test-elpa`. It uses npm to install Codex and Claude Code in
`.tools/agents`. The test target adds both executables to `PATH`.
If `uv` is missing, the target uses `curl` to download its
installer and installs `uv` in `.tools/uv/bin`. The target uses the upstream
lock file to install the server in `.tools/omnigent-server` and the mock
dependencies in `.tools/omnigent-mock`. It stores managed Python and the
download cache under `.tools/uv`. Repeat the setup command to reuse these files.
