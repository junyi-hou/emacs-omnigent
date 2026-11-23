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

- Run `make test-deps` to install test dependencies in `.tools/test-elpa`.
- Run `make unit-test` to run the unit tests. This target does not install dependencies.
- After the first dependency setup, run `make unit-test` for later test runs.

## Markdown

- Run `fill-region` on changed Markdown text with `emacsclient` when it is available.
