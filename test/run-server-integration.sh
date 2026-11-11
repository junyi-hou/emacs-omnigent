#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
export PATH="$PWD/.tools/bin:$PATH"
if ! command -v pixi >/dev/null 2>&1; then
  mkdir -p .tools/bin
  curl -fsSL https://pixi.sh/install.sh -o .tools/install-pixi.sh
  PIXI_NO_PATH_UPDATE=1 PIXI_BIN_DIR="$PWD/.tools/bin" bash .tools/install-pixi.sh
  rm .tools/install-pixi.sh
fi
pixi install --environment test
export PATH="$PWD/.pixi/envs/test/bin:$PATH"
npm install --global --prefix "$PWD/.pixi/envs/test" \
  @openai/codex@0.160.1 @anthropic-ai/claude-code@2.1.181
claude_bin=$(command -v claude)
codex_bin=$(command -v codex)
[ "$("$claude_bin" --version)" = "2.1.181 (Claude Code)" ]
[ "$("$codex_bin" --version)" = "codex-cli 0.160.1" ]
server_bin=${OMNIGENT_BIN:-"$PWD/.pixi/envs/test/bin/omnigent"}
emacs_bin=${EMACS:-emacs}
python_bin=${PYTHON:-"$PWD/.pixi/envs/test/bin/python"}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/omnigent-transport.XXXXXX")
port=$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)
server_pid=
host_pid=
model_pid=
cleanup() {
  if [ -n "$host_pid" ]; then
    kill "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
  fi
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [ -n "$model_pid" ]; then
    kill "$model_pid" 2>/dev/null || true
    wait "$model_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$tmp/config" "$tmp/bin"
"$python_bin" - "$tmp/bin" "$claude_bin" "$codex_bin" <<'PY'
import pathlib
import shlex
import sys

root = pathlib.Path(sys.argv[1])
for name, executable, version in (("claude", sys.argv[2], "2.1.181 (Claude Code)"),
                                  ("codex", sys.argv[3], "codex-cli 0.160.1")):
    path = root / name
    path.write_text("#!/bin/sh\nset -eu\n"
                    "export DISABLE_AUTOUPDATER=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1\n"
                    "actual=$(" + shlex.quote(executable) + " --version)\n"
                    "[ \"$actual\" = " + shlex.quote(version) + " ] || { echo \"Unexpected CLI version: $actual\" >&2; exit 1; }\n"
                    "printf 'Mock native CLI: %s\\n' \"$actual\" >&2\n"
                    "exec " + shlex.quote(executable) + " \"$@\"\n")
    path.chmod(0o755)
PY
export PATH="$tmp/bin:$PATH"
"$python_bin" test/mock-model/server.py --port 0 >"$tmp/model.log" 2>&1 &
model_pid=$!
i=0
while [ "$i" -lt 100 ] && [ ! -s "$tmp/model.log" ]; do
  if ! kill -0 "$model_pid" 2>/dev/null; then
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
export ANTHROPIC_BASE_URL=$(awk '/Mock model listening on/ {print $NF; exit}' "$tmp/model.log")
if [ -z "$ANTHROPIC_BASE_URL" ] || ! curl --silent --fail "$ANTHROPIC_BASE_URL/health" >/dev/null; then
  echo "Mock model server did not start:" >&2
  tail -n 80 "$tmp/model.log" >&2
  exit 1
fi
export ANTHROPIC_API_KEY=mock-key
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export DISABLE_AUTOUPDATER=1
export OTEL_SDK_DISABLED=true
unset CLAUDECODE ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY
export OMNIGENT_CONFIG_HOME="$tmp/config"
export OMNIGENT_DATA_DIR="$tmp/data"
export HOME="$tmp/home"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export CODEX_HOME="$HOME/.codex"
mkdir -p "$HOME/src" "$CODEX_HOME" "$OMNIGENT_DATA_DIR"
printf 'File read successfully.\n' >"$HOME/src/config.json"
printf 'def hello_world():\n    print("Hello, world!")\n' >"$HOME/src/main.py"
export OMNIGENT_TEST_BIN="$server_bin"
export OMNIGENT_TEST_TMP="$tmp"
"$python_bin" - "$tmp/config/config.yaml" "$ANTHROPIC_BASE_URL" <<'PY'
import json
import sys

with open(sys.argv[1], "w") as stream:
    json.dump({"providers": {"mock": {"kind": "local", "default": "anthropic",
              "anthropic": {"base_url": sys.argv[2], "api_key": "mock-key",
                            "models": {"sonnet": "claude-sonnet-4-6",
                                       "opus": "claude-opus-4-6"}},
              "openai": {"base_url": sys.argv[2] + "/v1", "api_key": "mock-key",
                         "wire_api": "responses", "models": {"default": "gpt-5.4"}}}}}, stream)
PY
"$server_bin" server --host 127.0.0.1 --port "$port" \
  --database-uri "sqlite:///$tmp/chat.db" \
  --artifact-location "$tmp/artifacts" \
  --config "$tmp/config/config.yaml" --agent "$PWD/test/mock-model/agent" \
  --agent "$PWD/test/mock-model/codex-agent" \
  --no-open >"$tmp/server.log" 2>&1 &
server_pid=$!
url="http://127.0.0.1:$port"
ready=false
i=0
while [ "$i" -lt 100 ]; do
  if curl --silent --fail --output /dev/null "$url/v1/sessions" 2>/dev/null; then
    ready=true
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    break
  fi
  i=$((i + 1))
  sleep 0.2
done
if [ "$ready" != true ]; then
  echo "Omnigent server did not start:" >&2
  tail -n 80 "$tmp/server.log" >&2
  exit 1
fi
"$server_bin" host --server "$url" --no-open --non-interactive >"$tmp/host.log" 2>&1 &
host_pid=$!
i=0
while [ "$i" -lt 100 ]; do
  if curl --silent --fail "$url/v1/hosts" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not any(h.get("status") == "online" for h in d.get("hosts", [])))' 2>/dev/null; then
    break
  fi
  if ! kill -0 "$host_pid" 2>/dev/null; then
    break
  fi
  i=$((i + 1))
  sleep 0.2
done
if [ "$i" -eq 100 ] || ! kill -0 "$host_pid" 2>/dev/null; then
  echo "Omnigent host did not start:" >&2
  tail -n 80 "$tmp/host.log" >&2
  exit 1
fi
package_dir="$tmp/elpa"
websocket_load_path=${OMNIGENT_WEBSOCKET_LOAD_PATH:-}
if [ -z "$websocket_load_path" ]; then
  OMNIGENT_TEST_PACKAGE_DIR="$package_dir" "$emacs_bin" -Q --batch \
    --eval '(require (quote package))' \
    --eval '(setq package-user-dir (getenv "OMNIGENT_TEST_PACKAGE_DIR") package-archives (quote (("gnu" . "https://elpa.gnu.org/packages/") ("melpa" . "https://melpa.org/packages/"))))' \
    --eval '(package-refresh-contents)' \
    --eval '(setq package-pinned-packages (quote ((websocket . "gnu"))) byte-compile-warnings nil bytecomp--inhibit-lexical-cookie-warning t)' \
    --eval '(progn (package-install (quote f)) (package-install (quote s)) (package-install (quote websocket)))'
fi
# Runtime permission_mode controls are Claude-specific, not Codex controls.
if [ "${OMNIGENT_TEST_HARNESS:-claude-native}" = codex-native ] && [ -z "${OMNIGENT_TEST_SELECTOR:-}" ]; then
  export OMNIGENT_TEST_SELECTOR='(not "^omnigent-mock-claude-")'
fi
run_integration_tests() {
  if [ -n "$websocket_load_path" ]; then
    OMNIGENT_TEST_SERVER_URL="$url" "$emacs_bin" -Q --batch \
      -L "$websocket_load_path" -L . -L test \
      -l test/omnigent-api-tests.el -l test/omnigent-functional-tests.el \
      --eval '(ert-run-tests-batch-and-exit (read (or (getenv "OMNIGENT_TEST_SELECTOR") "t")))'
  else
    OMNIGENT_TEST_PACKAGE_DIR="$package_dir" OMNIGENT_TEST_SERVER_URL="$url" \
      "$emacs_bin" -Q --batch \
      --eval '(require (quote package))' \
      --eval '(setq package-user-dir (getenv "OMNIGENT_TEST_PACKAGE_DIR"))' \
      --eval '(package-initialize)' \
      -L . -L test -l test/omnigent-api-tests.el -l test/omnigent-functional-tests.el \
      --eval '(ert-run-tests-batch-and-exit (read (or (getenv "OMNIGENT_TEST_SELECTOR") "t")))'
  fi
}
if ! run_integration_tests; then
  tail -n 120 "$tmp/server.log" >&2
  tail -n 120 "$tmp/host.log" >&2
  tail -n 120 "$tmp/model.log" >&2
  exit 1
fi
