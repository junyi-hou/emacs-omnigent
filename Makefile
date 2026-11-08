EMACS ?= emacs

.PHONY: test
test:
	$(EMACS) -Q --batch -L . -L test -l test/omnigent-transport-test.el -l test/omnigent-transport-lifecycle-test.el -l test/omnigent-test.el -l test/omnigent-sessions-test.el -l test/omnigent-conversation-test.el -l test/omnigent-workspace-test.el -f ert-run-tests-batch-and-exit
	EMACS="$(EMACS)" test/run-server-integration.sh
