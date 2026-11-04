# Emacs Transport Design

**Status:** REST, SSE, and session-updates WebSocket transport are implemented, as are the server and session-selection entry points. Conversation buffers and side views remain proposed.

This document covers how the Emacs client talks to the Omnigent server. It is separate from the frontend design (`docs/frontend.md`), which covers views and window behavior.

## Entry points

- `M-x omnigent-start-server` runs `omnigent server --background --no-open`, then connects to the local server. The CLI reuses an existing local server when possible.
- `M-x omnigent-connect` prompts for a server URL, lists accessible sessions, and prompts for one to select. `New session` is the default choice; it prompts for an agent and creates a session. Selecting an existing session loads its snapshot. Set `omnigent-token` before connecting to a shared server.

## What the server offers

- REST endpoints under `/v1/sessions` for create, get, post-event, fork, delete, and file resources. One-shot request and response.
- A session stream at `GET /v1/sessions/{id}/stream`. It is Server-Sent Events (SSE) and a live tail only: no replay, no sequence numbers, no `starting_after` parameter. The API document shows the stream ending with `data: [DONE]`; see the `[DONE]` ambiguity in the session-stream section.
- A reconnect contract with no replay machinery: open the stream first, then GET the session snapshot, then dedupe items by item id between the two.

## Decisions

### REST: `url-retrieve`

Use the built-in `url-retrieve` for one-shot requests. `omnigent-request` handles JSON encoding, auth headers, and response parsing. The endpoint helpers cover session snapshots, top-level lists, child lists, and posted events.

### Session stream: a `curl` subprocess

Run `curl -N <url>` as an Emacs subprocess. Attach a process filter to the curl process. The filter splits the process buffer on blank lines (SSE frame boundary) and parses `event:` and `data:` lines. Keep partial frames in the buffer between filter calls.

curl is an external dependency, not a guaranteed platform tool. At connect time, check `executable-find`. If curl is missing, refuse to open a session stream and report an error that names curl as the requirement. REST through `url-retrieve` keeps working without it.

curl handles chunked transfer, TLS, and proxies. Emacs code parses only complete frames. Set `omnigent-server-url` to the canonical server URL because curl does not follow redirects.

The API document is ambiguous about `data: [DONE]`. One passage says the stream stays open until the client disconnects or the conversation closes. Another says the stream terminates with `[DONE]`, and the example stream shows `[DONE]` after a turn reaches `idle`. Treat a `[DONE]` frame and a curl process exit as connection close. Resubscribe after a one-second minimum delay, since subscribing is safe at any point in the session lifecycle. The snapshot callback runs after each connection starts. The caller deduplicates snapshot items and stream events by item id. Apply the minimum delay to every close; use capped exponential backoff for failed connects. Keep the contradiction as an upstream contract risk until the server document resolves it.

### Session-list updates: the session-updates websocket

Subscribe to `WS /v1/sessions/updates` for session-list changes; do not
poll. The connection uses the GNU ELPA `websocket` package, which this
project declares as a dependency.
`url-retrieve` cannot speak WebSocket, and the protocol needs bidirectional
watch-set updates.

`omnigent-start-session-updates` takes a frame callback and an optional
error callback. The frame callback receives one parsed JSON frame. The
error callback receives an error string. The function returns a handle.
`omnigent-set-session-updates-watch` replaces the full watch set. It accepts
up to 500 session ID strings. The transport sends the current set when the
connection opens and re-sends it after reconnect. It stores watch-set changes
made while the connection is opening. `omnigent-stop-session-updates` closes
the connection and stops reconnects.

The connection uses the `ws` or `wss` scheme that matches the server URL.
The bearer token goes in the handshake header. The connection runs
in-process, so the curl header-file scheme does not apply. A missing
`websocket` package produces an error that names the package. REST and SSE
transport code does not load WebSocket functions until a connection starts.

REST list calls remain for the initial load, for manual refresh, and for
child lists: `omnigent-list-child-sessions` refreshes one parent's child
tree when a watched child changes. See
[session-tree.md](session-tree.md) for the frame handling.

## Authentication

A local single-user server needs no credentials. A shared server checks a bearer token: a login token from `POST /auth/login` or a machine token from `POST /oauth/token`, sent as `Authorization: Bearer <token>`.

Keep the token in one user option, for example `omnigent-token`, or read it from a file path in a user option. For REST requests, `url-retrieve` sets the header directly. For the curl subprocess, do not put the token in the curl command line: process listings can expose command-line arguments. Instead, write one header file per curl process in `temporary-file-directory`, set its mode to `0600` before writing the token into it, and pass it with `-H @<header-file>`. Delete the file in the curl process sentinel when the process exits. Do not log the header value.

## Event dispatch

`omnigent-start-session-stream` calls the event callback with the SSE event name and parsed JSON payload. Dispatch on the payload's `type` field. Keep buffer rendering outside the transport layer.

## Non-goals

- Do not stream SSE through `url-retrieve`.
- Do not add endpoint-specific policy to the shared request helper.
- Do not implement client-side replay. The server has none; the snapshot and item-id dedupe are the contract.

## Checks

Run `make test` for the unit and integration tests. The transport unit tests use a mocked WebSocket connection to check URL, auth, watch messages, frame parsing, and reconnect behavior. The integration test starts an isolated Omnigent server with a temporary database and artifact directory. It checks REST and SSE without starting an agent turn, and it checks the WebSocket handshake, snapshot, and changed frame with the GNU ELPA client.

## Open decisions

1. Token storage: plain user option, auth-source, or a file path.
2. Whether the SSE parser needs an `Accept: text/event-stream` header workaround for any Emacs-side proxy in front of the server.

## References

- [Omnigent server API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md) — stream endpoint, stream events, reconnect contract
- [curl manual](https://curl.se/docs/manpage.html)
