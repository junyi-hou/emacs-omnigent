# Agent Instructions

## Design

- Follow the applicable design decisions in `docs/` and `docs/adr/` when implementing
- changes.  If a change conflicts with a design decision, ask before changing the
- implementation or the decision.

## Style

- Do not use `cl-loop`.
- Run `make format` after editing Emacs Lisp files.
- Define all user options in `omnigent-options.el`.

## Interactive functions

- Define all interactive functions in `omnigent.el`.

## Docstrings

- Add a docstring to every function, including private functions and test functions.
- Add a docstring to every public variable.

## Tests

- Put unit tests in `test/unit/` in files named `*-test.el`. Use unit tests for
  behavior you can check without starting the Omnigent server or the local mock.
- Put each live integration test in its own `*-test.el` file in
  `test/integration/fixtures/`. Define exactly one `ert-deftest` per file.
- Call `omnigent-integration-with-run` once per integration test. The macro
  starts an isolated environment for the test and cleans up its resources.
  Keep shared setup and cleanup in `test/integration/omnigent-integration-fixture.el`.
- Run `make test-deps` to install the unit test dependencies in `.tools/test-elpa`.
  Then run `make unit-test` to check unit test changes.
- Run `make integration-deps` to install the integration test dependencies.
  Then run `make integration-test` to check integration test changes.
  See the [integration testing guide](docs/integration-testing.md) for setup details.

## Markdown

- Run `fill-region` on changed Markdown text with `emacsclient` when it is available.
