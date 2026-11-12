# Emacs Transport Design

**Status:** REST, SSE, session-updates WebSocket transport, connection setup, and
connection reset are implemented. Native integration tests cover local client-outage
faults; physical laptop suspend and deployed remote networking remain unverified. The
transport implementation is [omnigent-transport.el](../omnigent-transport.el). The
existing interactive entry points are in [omnigent.el](../omnigent.el).
[reconnection.md](reconnection.md) defines the client-outage recovery flow,
including stale-connection detection, the subscription gap, and manual recovery after
snapshot failure. Automatic snapshot retries are deferred.

Transport owns the input and output protocols and their implementation: server
connections, requests, response parsing, SSE, and WebSocket frames. It exposes client
APIs for the other components to call. It forwards parsed data and request outcomes
without managing session-list state, reconciling conversation items, or rendering
UI. Those components process the data they receive.

[session-tree.md](session-tree.md) owns session management and list state;
[conversation-buffer.md](conversation-buffer.md) owns conversation state;
[elicitation.md](elicitation.md) owns request state and response validation;
[workspace-changes.md](workspace-changes.md) owns workspace data processing;
[frontend.md](frontend.md) owns presentation.

## Connection entry points

- `omnigent-start-server` runs
  `omnigent host --server "" --background --no-open --non-interactive` to start or
  reuse the local server and execution host. The empty server argument forces local
  mode, even when the CLI has a saved remote-server default.
- `omnigent-connect` selects an existing local or remote server URL without starting
  any local process. Session creation works on the connected server regardless of
  who started it. It discovers execution hosts and workspaces through REST, not the
  local CLI. Host and workspace selection belongs to [session-tree.md](session-tree.md).

## What the server offers

- REST endpoints under `/v1/sessions` for create, get, post-event, fork, delete, and
  file resources. One-shot request and response.
- `GET /v1/hosts` lists execution hosts owned by the caller, with online/offline status.
  It does not identify a default host. `GET /v1/hosts/{id}/filesystem` lists that host's
  home directory; `/filesystem/{path}` lists a native directory path. Listings include
  entry names, paths, types, and `has_more`; request further pages with `after`.
  These requests work before a session or runner exists.
- A session stream at `GET /v1/sessions/{id}/stream`. It is Server-Sent Events (SSE) and
  a live tail only: no replay, no sequence numbers, no `starting_after` parameter. The
  API document shows the stream ending with `data: [DONE]`; see the `[DONE]` ambiguity
  in the session-stream section.
- A live-only stream without replay or sequence numbers. The conversation layer owns
  snapshot and stream reconciliation.

## Decisions

### REST: `url-retrieve`

Use the built-in `url-retrieve` for one-shot requests. `omnigent-transport-request`
handles JSON encoding and response parsing. The endpoint helpers cover session
snapshots, top-level lists, child lists, and posted events.

Follow the [one-shot API callback design](api-callbacks.md) for result
arguments, success detection, validation, error presentation, notification
ordering, and callback lifetimes. That document owns the common request-result
contract; this document owns its transport implementation.

### Session stream: a `curl` subprocess

Run `curl -N <url>` as an Emacs subprocess. Attach a process filter to the curl
process. The filter splits the process buffer on blank lines (SSE frame boundary) and
parses `event:` and `data:` lines. Keep partial frames in the buffer between filter
calls.

curl is an external dependency, not a guaranteed platform tool. At connect time, check
`executable-find`. If curl is missing, refuse to open a session stream and report an
error that names curl as the requirement. REST through `url-retrieve` keeps working
without it.

curl handles chunked transfer, TLS, and proxies. Emacs code parses only complete
frames. Set `omnigent-server-url` to the canonical server URL because curl does not
follow redirects.

The API document is ambiguous about `data: [DONE]`. One passage says the stream stays
open until the client disconnects or the conversation closes. Another says the stream
terminates with `[DONE]`, and the example stream shows `[DONE]` after a turn reaches
`idle`. Treat a `[DONE]` frame and a curl process exit as connection close. Resubscribe
after a one-second minimum delay, since subscribing is safe at any point in the session
lifecycle. The snapshot callback runs after each connection starts. The conversation
layer reconciles snapshot items and stream events; transport does not deduplicate
them. Apply the minimum delay to every close; use capped exponential backoff for failed
connects. Keep the contradiction as an upstream contract risk until the server document
resolves it.

### Session updates: the session-updates WebSocket

Provide a subscription to `WS /v1/sessions/updates`. The session-management component
decides when to subscribe and processes the frames. The connection uses the GNU ELPA
`websocket` package, which this project declares as a dependency.  `url-retrieve` cannot
speak WebSocket, and the protocol needs bidirectional watch-set updates.

`omnigent-transport-start-session-updates` takes a frame callback and an optional error
callback. The frame callback receives one parsed JSON frame. The error callback receives
an error string. The function returns a handle.
`omnigent-transport-set-session-updates-watch` replaces the full watch set. It accepts
up to 500 session ID strings. The transport sends the current set when the connection
opens and re-sends it after reconnect. It stores watch-set changes made while the
connection is opening. `omnigent-transport-stop-session-updates` closes the connection
and stops reconnects.

The connection uses the `ws` or `wss` scheme that matches the server URL.  A missing
`websocket` package produces an error that names the package. REST and SSE transport
code does not load WebSocket functions until a connection starts.

See [session-tree.md](session-tree.md) for the caller's list refresh and frame handling.

## Server connection and request lifecycle

A server connection is the client's association with one server URL, not a single
socket. The session-updates WebSocket is scoped to the server and user, not to one
session. The client also makes REST requests and can open a separate SSE stream for each
conversation buffer.

The WebSocket does not provide the initial session list. Its snapshot contains only the
IDs in the watch set supplied by the client; an empty watch set gives an empty
snapshot. Session management opens the WebSocket, fetches the initial list with REST,
and watches only session IDs with live conversation buffers. The 500-ID server limit
also limits open conversation buffers to 500. The WebSocket supplies updates, not a
complete inventory. Reconcile with REST on reconnect, as described in
[session-tree.md](session-tree.md).

V1 supports one server at a time. Keep global connection state with the server URL, the
session-updates handle, open session-stream handles, and a connection generation to
invalidate outstanding callbacks. This is transport state, not a globally selected
session. Before connecting, including to the same URL, stop the old WebSocket, session
streams and reconnect timers; invalidate callbacks; and reset server-specific client
state. Then establish the new association and load its list. Conversation buffer cleanup
belongs to [conversation-buffer.md](conversation-buffer.md). If list loading or the
WebSocket fails, report the failure; do not claim watched sessions are up to date.

The server protocol does not require a single global server. Separate URLs and
connection state could support multiple servers; that support is deferred.

Requests and stream handles belong to the connection on which they started.  Cancel
outstanding work where possible; discard late callbacks from the old connection so they
cannot affect the new connection. Report HTTP failures, transport failures, and
uncertain timeouts distinctly. A timeout does not prove that a mutating request failed;
do not automatically resend it. The caller owns its draft and decides how to present the
outcome.

## Public APIs

The following transport functions are implemented in `omnigent-transport.el`:

- `omnigent-transport-reset` stops registered streams and invalidates outstanding REST
  callbacks before a server change.
- `omnigent-transport-request`, `omnigent-transport-get-session`,
  `omnigent-transport-list-sessions`, and `omnigent-transport-post-session-event` issue
  asynchronous REST requests.
- `omnigent-transport-start-session-stream` and `omnigent-transport-stop-session-stream`
  manage a session SSE handle. The existing start function also requests a snapshot
  after each connection attempt and invokes the supplied snapshot callback.
- `omnigent-transport-refresh-session-stream` requests another snapshot without
  restarting SSE. It invokes the connection callback before loading, so the conversation
  buffers live events during the refresh. It enforces one active snapshot operation per
  handle and coalesces refresh requests received during a read. It does not
  automatically retry a failed snapshot. A composite deadline and operation identity
  prevent late responses from changing recovered state.
- Session stream startup accepts an optional state callback with `connecting`,
  `connected`, or `disconnected`. Connected means a complete stream frame arrived, not
  that the snapshot/event handoff is gap-free. Inactivity and scheduling-gap watchdogs
  reconnect SSE and WebSocket handles without resetting the server association.
- `omnigent-transport-start-session-updates`,
  `omnigent-transport-set-session-updates-watch`, and
  `omnigent-transport-stop-session-updates` manage the session-updates WebSocket.

`omnigent-connect` and `omnigent-start-server` are existing interactive entry points in
`omnigent.el`, not transport functions. `omnigent-connect` resets the old transport,
then starts the frontend and session management. Session management opens the
session-updates WebSocket and loads the session list.

## Authentication

Authentication is not implemented. The client cannot connect directly to a server that
requires authentication. A centralized authentication mechanism needs a design before
implementation.

## Event dispatch

`omnigent-transport-start-session-stream` calls the event callback with the SSE event
name and parsed JSON payload. The caller dispatches on the payload's `type` field. The
WebSocket callback likewise receives parsed frames; its caller interprets frame types
and updates session-list state.

## Non-goals

- Do not stream SSE through `url-retrieve`.
- Do not add endpoint-specific policy to the shared request helper.
- Do not implement client-side replay. The server has none; the conversation layer
  handles the incomplete snapshot/stream handoff.

## Checks

Run `make test` for the unit and integration tests. The transport unit tests use a
mocked WebSocket connection to check URL, watch messages, frame parsing, and reconnect
behavior. The integration test starts an isolated Omnigent server with a temporary
database and artifact directory. It checks REST and SSE without starting an agent turn,
and it checks the WebSocket handshake, snapshot, and changed frame with the GNU ELPA
client.

## Open decisions

1. Token storage: plain user option, auth-source, or a file path.
2. Whether the SSE parser needs an `Accept: text/event-stream` header workaround for any
   Emacs-side proxy in front of the server.

## References

- [Omnigent server
  API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md) —
  stream endpoint, stream events, reconnect contract
- [curl manual](https://curl.se/docs/manpage.html)
