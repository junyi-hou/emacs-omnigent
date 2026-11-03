# Emacs Transport Design

**Status:** Transport and server/session-selection entry points are implemented. Conversation buffers and side views remain proposed.

This document covers how the Emacs client talks to the Omnigent server. It is separate from the frontend design (`designs/frontend.md`), which covers views and window behavior.

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

### Session-list updates: poll REST

Use `omnigent-list-child-sessions` to refresh one parent's child tree and `omnigent-list-sessions` for top-level session discovery. The caller schedules these REST requests at a fixed interval and can stop polling when the view closes. The long-lived curl process is only for the SSE session stream.

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

Run `make test` for the unit and integration tests. The integration test starts an isolated Omnigent server with a temporary database and artifact directory, then checks REST and SSE without starting an agent turn.

## Open decisions

1. Poll interval for the session list, and whether it polls only while the child-session tree is visible.
2. Token storage: plain user option, auth-source, or a file path.
3. Whether the SSE parser needs an `Accept: text/event-stream` header workaround for any Emacs-side proxy in front of the server.

## References

- [Omnigent server API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md) — stream endpoint, stream events, reconnect contract
- [curl manual](https://curl.se/docs/manpage.html)
