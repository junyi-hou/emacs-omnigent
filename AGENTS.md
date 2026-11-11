# Agent Instructions

## Design

- Follow the applicable design decisions in `docs/` and `docs/adr/` when implementing
- changes.  If a change conflicts with a design decision, ask before changing the
- implementation or the decision.

## Style

- Do not use `cl-loop`.

## Interactive functions

- Define all interactive functions in `omnigent.el`.

## Docstrings

- Add a docstring to every function, including private functions and test functions.
- Add a docstring to every public variable.

## Markdown

- Run `fill-region` on changed Markdown text with `emacsclient` when it is available.
