# Workspace paths

Omnigent uses the session workspace directory to locate files in Emacs.
The client can also look up the environment root to open files linked from
conversation text.

The root listing endpoint is:

```text
GET /v1/sessions/{id}/resources/environments/default/filesystem
```

Its directory response includes an absolute `base` path. The session snapshot
from `GET /v1/sessions/{id}` also has a `workspace` field. That field can be
null or contain a path that differs from the environment root.

A root path is meaningful on the runner's filesystem. The user configures
`omnigent-host-address-function` to map each `host_id` to its address. The default
returns the host in `omnigent-server-url`. A return value of `localhost` also means
the server host. The client uses local filenames for a local address and SSH TRAMP
filenames for a remote address.
The user must provide the correct mapping when a runner is on another host.

During runner startup, a host-only filesystem listing can omit the root.
The client retries that response every half second for up to five seconds.
Disconnecting stops retries.

## Workspace patches

The client requests the changed paths from `GET /v1/sessions/{id}/resources/environments/default/changes`.
It fetches each path's before and after contents from the corresponding
`diff/{path}` endpoint. It uses the local `diff` executable to combine them
into a unified patch relative to Git HEAD. An individual request can fail if
the workspace changes during the fetch.
