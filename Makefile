EMACS ?= emacs
HARNESS ?= claude-native
ELISP_AUTOFMT ?= $(HOME)/.emacs.d/elpaca/sources/emacs-elisp-autofmt/elisp-autofmt-cmd.py

.PHONY: test test-deps unit-test integration-test format
test: unit-test integration-test

test-deps:
	$(EMACS) -Q --batch \
	  --eval '(require (quote package))' \
	  --eval '(setq package-user-dir (expand-file-name ".tools/test-elpa") package-archives (quote (("gnu" . "https://elpa.gnu.org/packages/") ("nongnu" . "https://elpa.nongnu.org/nongnu/") ("melpa" . "https://melpa.org/packages/"))) package-pinned-packages (quote ((evil . "nongnu") (websocket . "gnu"))))' \
	  --eval '(package-initialize)' \
	  --eval '(unless (seq-every-p (function package-installed-p) (quote (evil websocket f s))) (package-refresh-contents) (dolist (pkg (quote (evil websocket f s))) (unless (package-installed-p pkg) (package-install pkg))))'

format:
	$(ELISP_AUTOFMT) $(wildcard *.el .*.el test/*.el)

integration-test:
	EMACS="$(EMACS)" OMNIGENT_TEST_HARNESS="$(HARNESS)" test/run-server-integration.sh

unit-test:
	$(EMACS) -Q --batch \
	  --eval '(require (quote package))' \
	  --eval '(setq package-user-dir (expand-file-name ".tools/test-elpa"))' \
	  --eval '(package-initialize)' \
	  -L . -L test -l test/omnigent-transport-test.el -l test/omnigent-test.el -l test/omnigent-sessions-test.el -l test/omnigent-conversation-test.el -l test/omnigent-workspace-test.el -l test/omnigent-ui-test.el -f ert-run-tests-batch-and-exit
