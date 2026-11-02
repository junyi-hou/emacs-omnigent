#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
server_bin=${OMNIGENT_BIN:-.venv/bin/omnigent}
emacs_bin=${EMACS:-emacs}
if [ ! -x "$server_bin" ]; then
  echo "Omnigent executable not found: $server_bin" >&2
  exit 1
fi

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
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
printf '{}\n' > "$tmp/config.yaml"
"$server_bin" server --host 127.0.0.1 --port "$port" \
  --database-uri "sqlite:///$tmp/chat.db" \
  --artifact-location "$tmp/artifacts" \
  --config "$tmp/config.yaml" --no-open >"$tmp/server.log" 2>&1 &
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
OMNIGENT_TEST_SERVER_URL=$url "$emacs_bin" -Q --batch -L . -L test \
  -l test/omnigent-transport-server-test.el -f ert-run-tests-batch-and-exit
