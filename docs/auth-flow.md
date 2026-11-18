# Authentication Design

## Status

Accepted. This document describes the first authentication release.

## Context

The client sends requests through three transports: REST requests, session
SSE streams, and session-update WebSockets. Before this change, no transport
sent credentials. Remote servers can require authentication.

## Decision

Use two user options:

- `omnigent-auth-method`: set this option to `token` or `none`. The default
  is `none`.
- `omnigent-auth-token-function`: set this option to a function that returns
  one bearer-token string.

When the method is `token`, the client calls the token function before each
request. If the function returns a non-empty token, the client sends this
header:

```text
Authorization: Bearer <token>
```

The client sends the header on REST, SSE, and WebSocket connections. The
first version does not cache tokens. The token function runs each time a
transport needs credentials. This keeps the design simple and lets a user
refresh tokens in the callback.

When an HTTP response has status 401, the client prints one message. The
message tells the user that authentication failed and asks the user to check
the token.

## Consequences

- The token function runs often. It must return promptly.
- Token state stays inside the user's function; the package stores no
  credential.
- A missing function, an empty return value, or an invalid token produces a
  clear user message.
- WebSocket and SSE authentication failures are not reliably detected yet;
  curl `--fail` reports them as generic process errors. Define handling for
  these transport failures.
- The current no-cache design may call the token function too often. Define
  token time-to-live and cache behavior when a concrete requirement appears.
- Support more authentication methods only when a second real method exists.
- Future work can add more methods without changing the public options.
