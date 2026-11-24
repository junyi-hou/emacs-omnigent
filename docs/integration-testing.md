# Integration testing

`make integration-test` starts a real Omnigent server and the official local
mock LLM server. The smoke test checks service health, checks that the mock serves the
configured model, and checks cleanup. It does not run a harness request. `make
unit-test` covers fixture mechanics without starting either server.

## Dependencies and setup

```sh
make integration-deps
make integration-test
```

`make integration-deps` clones the default branch of the official Omnigent
repository into `.tools/omnigent-upstream` if that checkout is missing. Set
`OMNIGENT_REPO` for both commands to use an existing checkout at a different
path.

`make integration-deps` runs `make test-deps` to install Emacs packages in
`.tools/test-elpa`. If `uv` is missing, the target uses `curl` to download its
installer and installs `uv` in `.tools/uv/bin`. The target uses the upstream
lock file to install the server in `.tools/omnigent-server` and the mock
dependencies in `.tools/omnigent-mock`. It stores managed Python and the
download cache under `.tools/uv`. Repeat the setup command to reuse these files.
