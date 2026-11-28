# Agent Instructions

## Design

Follow the applicable design decisions in `docs/` and `docs/adr/` when implementing
changes. If a change conflicts with a design decision, ask before changing the
implementation or the decision.

## Style

- Do not use `cl-loop`.
- Run `make format` after editing Emacs Lisp files.
- Define all user options in `omnigent-options.el`.

## Interactive functions

- Define all interactive functions in `omnigent.el`.

## Docstrings

- Add a docstring to every function, including private functions and test functions.
- Add a docstring to every public variable.

## Coding workflow

Follow this workflow through merge and branch cleanup.

1. Add or update unit tests to specify the expected behavior.
2. Implement the feature or fix.
3. Run `make unit-test` locally. Fix failures and rerun it until all unit tests
   pass.
4. Update integration tests when the change affects behavior they cover or
   requires new integration coverage. Run the integration tests as described
   below. If you change code or unit tests again, rerun `make unit-test`.
5. Stage the changes for this task. Use the `commit-message` skill to draft the
   commit message when the skill is available. Otherwise, follow this
   repository's Conventional Commits format, such as
   `fix(sessions): align session titles`. Then create the commit.
6. Push the task branch and open a pull request. Monitor CI through completion.
   Fix failures caused by the change and verify the new revision. Use
   `gh pr merge --rebase` after all CI tests pass on the latest revision and all
   required checks pass.
7. Confirm that the pull request merged. Delete the local and remote task
   branches if they still exist. Preserve any uncommitted work.

## External actions

For coding tasks in this repository, the workflow authorizes the Git and GitHub
actions it lists. This authorization takes precedence over general restrictions
on those actions. Ask before taking any other external action.

If the sandbox blocks an authorized step, request sandbox approval for that step.
This includes write access to Git metadata and network access to GitHub. If
approval is denied or unavailable, complete the steps that can still run and
report the exact step that remains blocked.

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
