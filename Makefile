EMACS ?= emacs

.PHONY: test
test:
	$(EMACS) -Q --batch -L . -L test -l test/omnigent-transport-test.el -f ert-run-tests-batch-and-exit
	EMACS="$(EMACS)" test/run-server-integration.sh
