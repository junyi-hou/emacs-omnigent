# Integration tests

The integration runner starts a temporary Omnigent server and host. It clones a
pinned revision of [mock-acp](https://github.com/junyi-hou/mock-acp) into the
temporary directory and configures Omnigent's generic ACP harness to launch it. It also creates a temporary home,
configuration, database, workspace, and artifact store. The runner stops the host
and server and removes the temporary directory on exit.

Run `pixi install` to install the ACP dependency in this project's Python
environment. The runner uses `.pixi/envs/default/bin/omnigent` and
`.pixi/envs/default/bin/python`. Set `OMNIGENT_BIN` or `PYTHON` to use another
executable.

Run the tests with:

```sh
make test
```

The runner needs Git, network access, Emacs, Python 3, curl, and the Emacs `websocket` package. Set
`OMNIGENT_WEBSOCKET_LOAD_PATH` to an installed package directory to avoid the
runner's package download.

Add API integration tests to `omnigent-api-tests.el`. Add end-to-end behavior
tests to `omnigent-functional-tests.el`. The agent-turn test shows how to select
the mock agent, create a session on the temporary host, send a scenario prompt,
and check SSE and WebSocket updates. The mock accepts prompts such as
`test agent_message` and `test tool_call`; see its README for the full list.
