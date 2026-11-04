# Use websocket.el for the session-updates stream

The session tree needs push updates for session-list state (status
changes, new and removed sessions). The server exposes
`WS /v1/sessions/updates` for exactly this, and we subscribe to it with
the GNU ELPA `websocket` package instead of polling REST. The SSE session
stream deliberately stays on a curl subprocess: SSE is plain HTTP line
streaming that curl handles well, while WebSocket is a bidirectional
binary protocol (handshake, frame masking, ping/pong) that neither
`url-retrieve` nor this machine's curl supports. Do not unify the two
channels.

## Considered options

- REST polling at a fixed interval: rejected. Rows for sessions driven
  outside Emacs go stale, and the server built the websocket to replace
  the web app's 4-second poll.
- curl subprocess with WS: unavailable (macOS curl has no WebSocket
  support) and unusable (watch-set updates need mid-connection sends).
- Hand-rolled WS client over `open-network-stream`: rejected. The
  protocol is subtle (masking, fragmentation, 64-bit lengths) and a
  mature package already exists.
