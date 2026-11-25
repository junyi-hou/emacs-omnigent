EMACS ?= emacs
OMNIGENT_REPO ?= $(CURDIR)/.tools/omnigent-upstream
ELISP_AUTOFMT ?= $(HOME)/.emacs.d/elpaca/sources/emacs-elisp-autofmt/elisp-autofmt-cmd.py

.PHONY: test test-deps integration-deps unit-test integration-test format
test: unit-test

test-deps:
	$(EMACS) -Q --batch \
	  --eval '(require (quote package))' \
	  --eval '(setq package-user-dir (expand-file-name ".tools/test-elpa") package-archives (quote (("gnu" . "https://elpa.gnu.org/packages/") ("nongnu" . "https://elpa.nongnu.org/nongnu/") ("melpa" . "https://melpa.org/packages/"))) package-pinned-packages (quote ((evil . "nongnu") (websocket . "gnu"))))' \
	  --eval '(package-initialize)' \
	  --eval '(unless (seq-every-p (function package-installed-p) (quote (evil websocket f s markdown-mode))) (package-refresh-contents) (dolist (pkg (quote (evil websocket f s markdown-mode))) (unless (package-installed-p pkg) (package-install pkg))))'

integration-deps: export UV_CACHE_DIR := $(CURDIR)/.tools/uv/cache
integration-deps: export UV_PYTHON_INSTALL_DIR := $(CURDIR)/.tools/uv/python
integration-deps: export UV_PYTHON_BIN_DIR := $(CURDIR)/.tools/uv/bin
integration-deps: test-deps
	@mkdir -p .tools/uv
	@if [ "$(OMNIGENT_REPO)" = "$(CURDIR)/.tools/omnigent-upstream" ] && [ ! -d "$(OMNIGENT_REPO)" ]; then \
	  git clone --depth 1 https://github.com/omnigent-ai/omnigent.git "$(OMNIGENT_REPO)"; \
	fi
	@test -f "$(OMNIGENT_REPO)/.python-version" || (echo "Set OMNIGENT_REPO to an official Omnigent checkout" >&2; exit 1)
	@set -e; export PATH="$(UV_PYTHON_BIN_DIR):$$PATH"; \
	if ! command -v uv >/dev/null; then \
	  curl -fsSL https://astral.sh/uv/install.sh -o .tools/uv/install.sh; \
	  UV_UNMANAGED_INSTALL="$(UV_PYTHON_BIN_DIR)" sh .tools/uv/install.sh; \
	  rm .tools/uv/install.sh; \
	fi; \
	uv venv --allow-existing --managed-python --python "$$(cat "$(OMNIGENT_REPO)/.python-version")" .tools/omnigent-mock; \
	uv export --locked --python "$(CURDIR)/.tools/omnigent-mock/bin/python" --no-emit-local --no-hashes --project "$(OMNIGENT_REPO)" --output-file .tools/uv/mock-constraints.txt >/dev/null; \
	uv pip install --python .tools/omnigent-mock/bin/python --constraints .tools/uv/mock-constraints.txt fastapi uvicorn; \
	OMNIGENT_SKIP_WEB_UI=true UV_PROJECT_ENVIRONMENT="$(CURDIR)/.tools/omnigent-server" \
	  uv sync --locked --managed-python --project "$(OMNIGENT_REPO)"

integration-test:
	OMNIGENT_REPO="$(OMNIGENT_REPO)" PATH="$(CURDIR)/.tools/omnigent-server/bin:$$PATH" \
	  $(EMACS) -Q --batch \
	  --eval '(require (quote package))' \
	  --eval '(setq package-user-dir (expand-file-name ".tools/test-elpa"))' \
	  --eval '(package-initialize)' \
	  -L . -L test/integration $(addprefix -l ,$(wildcard test/integration/fixtures/*-test.el)) -f ert-run-tests-batch-and-exit

format:
	$(ELISP_AUTOFMT) $(wildcard *.el .*.el test/unit/*.el test/integration/*.el test/integration/fixtures/*.el)

unit-test:
	$(EMACS) -Q --batch \
	  --eval '(require (quote package))' \
	  --eval '(setq package-user-dir (expand-file-name ".tools/test-elpa"))' \
	  --eval '(package-initialize)' \
	  -L . -L test/unit -L test/integration $(addprefix -l ,$(wildcard test/unit/*-test.el)) -f ert-run-tests-batch-and-exit
