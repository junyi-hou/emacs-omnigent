EMACS ?= emacs
HARNESS ?= claude-native

.PHONY: test unit-test integration-test
test: unit-test integration-test

integration-test:
	EMACS="$(EMACS)" OMNIGENT_TEST_HARNESS="$(HARNESS)" test/run-server-integration.sh

unit-test:
	$(EMACS) -Q --batch -L . -L test -l test/omnigent-transport-test.el -l test/omnigent-transport-lifecycle-test.el -l test/omnigent-test.el -l test/omnigent-sessions-test.el -l test/omnigent-conversation-test.el -l test/omnigent-workspace-test.el -l test/omnigent-ui-test.el -f ert-run-tests-batch-and-exit
