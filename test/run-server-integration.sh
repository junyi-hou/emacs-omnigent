#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
server_bin=${OMNIGENT_BIN:-"$PWD/.pixi/envs/default/bin/omnigent"}
emacs_bin=${EMACS:-emacs}
python_bin=${PYTHON:-"$PWD/.pixi/envs/default/bin/python"}

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
cleanup() {
  if [ -n "$host_pid" ]; then
    kill "$host_pid" 2>/dev/null || true
    wait "$host_pid" 2>/dev/null || true
  fi
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$tmp/bin" "$tmp/config"
git clone --quiet https://github.com/junyi-hou/mock-acp.git "$tmp/mock-acp"
git -C "$tmp/mock-acp" checkout --quiet a835bac254932c7f91905c087a893e9053e8a4c4
printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' \
  "$python_bin" "$tmp/mock-acp/src/main.py" > "$tmp/bin/mock-acp"
chmod +x "$tmp/bin/mock-acp"
export OMNIGENT_CONFIG_HOME="$tmp/config"
export OMNIGENT_DATA_DIR="$tmp/data"
export HOME="$tmp/home"
mkdir -p "$HOME" "$OMNIGENT_DATA_DIR"
export PATH="$tmp/bin:$PATH"
python3 - "$tmp/bin/mock-acp" "$tmp/config/config.yaml" <<'PY'
import json
import sys

# JSON is valid YAML, and quotes paths without relying on shell escaping.
with open(sys.argv[2], "w") as f:
    json.dump({"acp": {"agents": [{"name": "mock-acp", "command": sys.argv[1],
                                  "inject_system_prompt": False,
                                  "omnigent_mcp": False}]}}, f)
PY
"$server_bin" server --host 127.0.0.1 --port "$port" \
  --database-uri "sqlite:///$tmp/chat.db" \
  --artifact-location "$tmp/artifacts" \
  --config "$tmp/config/config.yaml" --no-open >"$tmp/server.log" 2>&1 &
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
run_integration_tests() {
  if [ -n "$websocket_load_path" ]; then
    OMNIGENT_TEST_SERVER_URL="$url" "$emacs_bin" -Q --batch \
      -L "$websocket_load_path" -L . -L test \
      -l test/omnigent-api-tests.el -l test/omnigent-functional-tests.el -f ert-run-tests-batch-and-exit
  else
    OMNIGENT_TEST_PACKAGE_DIR="$package_dir" OMNIGENT_TEST_SERVER_URL="$url" \
      "$emacs_bin" -Q --batch \
      --eval '(require (quote package))' \
      --eval '(setq package-user-dir (getenv "OMNIGENT_TEST_PACKAGE_DIR"))' \
      --eval '(package-initialize)' \
      -L . -L test -l test/omnigent-api-tests.el -l test/omnigent-functional-tests.el \
      -f ert-run-tests-batch-and-exit
  fi
}
if ! run_integration_tests; then
  tail -n 120 "$tmp/server.log" >&2
  tail -n 120 "$tmp/host.log" >&2
  exit 1
fi
