EMACS ?= emacs
HARNESS ?= claude-native
ELISP_AUTOFMT ?= elisp-autofmt-cmd.py

.PHONY: test unit-test integration-test format
test: unit-test integration-test

format:
	$(ELISP_AUTOFMT) $(wildcard *.el .*.el test/*.el)

integration-test:
	EMACS="$(EMACS)" OMNIGENT_TEST_HARNESS="$(HARNESS)" test/run-server-integration.sh

unit-test:
	$(EMACS) -Q --batch -L . -L test -l test/omnigent-transport-test.el -l test/omnigent-test.el -l test/omnigent-sessions-test.el -l test/omnigent-conversation-test.el -l test/omnigent-workspace-test.el -l test/omnigent-ui-test.el -f ert-run-tests-batch-and-exit
