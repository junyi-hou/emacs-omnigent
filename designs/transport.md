# Emacs Transport Design

**Status:** Proposed. No implementation exists yet.

This document covers how the Emacs client talks to the Omnigent server. It is separate from the frontend design (`designs/frontend.md`), which covers views and window behavior.

## What the server offers

- REST endpoints under `/v1/sessions` for create, get, post-event, fork, delete, and file resources. One-shot request and response.
- A session stream at `GET /v1/sessions/{id}/stream`. It is Server-Sent Events (SSE) and a live tail only: no replay, no sequence numbers, no `starting_after` parameter. The API document shows the stream ending with `data: [DONE]`; see the `[DONE]` ambiguity in the session-stream section.
- A reconnect contract with no replay machinery: open the stream first, then GET the session snapshot, then dedupe items by item id between the two.

## Decisions

### REST: `url-retrieve`

Use the built-in `url-retrieve` for one-shot requests. Parse responses with built-in `json-parse-buffer`. No external dependency.

### Session stream: a `curl` subprocess

Run `curl -N <url>` as an Emacs subprocess. Attach a process filter to the curl process. The filter splits the process buffer on blank lines (SSE frame boundary) and parses `event:` and `data:` lines. Keep partial frames in the buffer between filter calls.

curl is an external dependency, not a guaranteed platform tool. At connect time, check `executable-find`. If curl is missing, refuse to open a session stream and report an error that names curl as the requirement. REST through `url-retrieve` keeps working without it.

Rationale: curl handles chunked encoding, TLS, proxies, and redirects natively. Emacs code parses only complete frames.

The API document is ambiguous about `data: [DONE]`. One passage says the stream stays open until the client disconnects or the conversation closes. Another says the stream terminates with `[DONE]`, and the example stream shows `[DONE]` after a turn reaches `idle`. Do not resolve the ambiguity by guessing. Treat a `[DONE]` frame and a curl process exit as the same event: the connection is closed. Then resubscribe after a short minimum delay (for example, one second), since the API states that subscribing is safe at any point in the session lifecycle. Follow the reconnect contract on every resubscribe: GET the snapshot, dedupe by item id. Apply the minimum delay to every close, including clean `[DONE]` resubscribes, so an idle session that returns `[DONE]` immediately on every connection cannot drive a reconnect loop. Use longer backoff for failed connects. This is correct under either interpretation. Keep this ambiguity listed as an upstream contract risk until the server document fixes the contradiction.

### Session-list updates: poll REST

Poll REST endpoints at a fixed interval: `GET /v1/sessions/{id}/child_sessions` refreshes the child-session tree of one parent, and `GET /v1/sessions` handles top-level session discovery. Both return the liveness signals, `runner_online` and `host_online`, that the tree needs. Use `url-retrieve` for these requests; the long-lived curl process is only for the SSE session stream.

## Authentication

A local single-user server needs no credentials. A shared server checks a bearer token: a login token from `POST /auth/login` or a machine token from `POST /oauth/token`, sent as `Authorization: Bearer <token>`.

Keep the token in one user option, for example `omnigent-token`, or read it from a file path in a user option. For REST requests, `url-retrieve` sets the header directly. For the curl subprocess, do not put the token in the curl command line: process listings can expose command-line arguments. Instead, write one header file per curl process in `temporary-file-directory`, set its mode to `0600` before writing the token into it, and pass it with `-H @<header-file>` or a curl config file (`-K`). Delete the file in the curl process sentinel when the process exits. Do not log the header value.

## Event dispatch

The SSE filter parses a frame into an event name and a JSON payload. Dispatch on the `type` field of the payload, as the server does. One entry function receives every event and routes it. Buffer-level rendering stays out of the transport layer.

## Non-goals

- Do not stream SSE through `url-retrieve`.
- Do not build a general HTTP client wrapper. `url-retrieve` calls stay inline until a second caller needs the same shape.
- Do not implement client-side replay. The server has none; the snapshot and item-id dedupe are the contract.

## Open decisions

1. Poll interval for the session list, and whether it polls only while the child-session tree is visible.
2. Token storage: plain user option, auth-source, or a file path.
3. Whether the SSE parser needs an `Accept: text/event-stream` header workaround for any Emacs-side proxy in front of the server.

## References

- [Omnigent server API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md) — stream endpoint, stream events, reconnect contract
- [curl manual](https://curl.se/docs/manpage.html)
