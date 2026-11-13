# Workspace Changes Data Design

**Status:** Diff and listing operations are implemented in
[omnigent-workspace.el](../omnigent-workspace.el). Change-list caching and refresh
coordination remain proposed. This document describes workspace data processing,
not presentation or transport.
Use the APIs in [transport.md](transport.md) for server requests and responses.

## Decision

Provide a stateless operation that takes a session ID and returns a unified diff of the
workspace changes reported by Omnigent. Each call queries the server again. Do not
maintain a client-side change history or a global diff.

V1 supports Git workspaces only. This is a workspace diff, not a record of changes
attributable to the session. Omnigent reports uncommitted changes relative to `HEAD`,
including changes made by other processes or sessions. Committing a change removes it
from that result. Non-Git workspace support is a post-v1 TODO.

## Collecting the diff

1. Request `GET /v1/sessions/{id}/resources/environments/default/changes`.
2. For each returned path, request `GET
   /v1/sessions/{id}/resources/environments/default/diff/{path}`. Encode the session ID
   and path correctly for their URL positions.
3. Generate a unified diff from the returned `before` and `after` contents. Combine the
   per-file diffs into one result.

The server returns before and after contents, not a unified workspace patch. An empty
change list produces an empty diff. The operation must report a failure or explicitly
identify a partial result if any file request fails. It must not silently omit a file.

The list and file requests do not form an atomic snapshot. Files can change between
requests, including without a request failing. The result is therefore a best-effort
view, not a consistent snapshot.

Treat null `before` and `after` contents as empty when generating the diff. The server
can return null `before` for a new file or when `git show` fails; it does not distinguish
these cases. If `git show` fails for a modified file, the diff shows its entire current
content as added. If it fails for a deleted file, the diff can omit that file. A null
`after` indicates a deleted file. The server decodes contents as text with
replacement for invalid bytes, so this interface cannot promise a lossless binary diff.

In the inspected Omnigent 0.19.1 implementation, the change list is limited to 10,000
entries, but its response reports `has_more: false`. The client cannot reliably detect
truncation from that response. Server errors, including an unavailable runner, must
remain distinct from an empty change list.

## Workspace root and file paths

Provide a separate operation to obtain the environment root and workspace-relative
paths. The root listing endpoint is:

```text
GET /v1/sessions/{id}/resources/environments/default/filesystem
```

Its directory response includes an absolute `base` path. Use that path as the root for
paths from the environment changes API. The session snapshot from `GET
/v1/sessions/{id}` also has a `workspace` field, but it may be null. Do not assume that
it always matches the environment root.

A root path is meaningful on the runner's filesystem. The user configures
`omnigent-host-address-function` to map each `host_id` to its address. The default
returns the host in `omnigent-server-url`. A return value of `localhost` also means
the server host. The client uses local filenames for a local address and SSH TRAMP
filenames for a remote address.
The user must provide the correct mapping when a runner is on another host.

## Client API

Load `omnigent-workspace` to use these asynchronous operations:

- `omnigent-workspace-diff` returns a combined unified diff string.
- `omnigent-workspace-file-diff` takes a session ID and a workspace-relative path, and
  returns that file's unified diff string. Equal before and after contents produce an
  empty string. The server can return 404 when a path is no longer changed. The
  operation forwards request failures and reports invalid responses as client errors.
- `omnigent-workspace-list` returns an alist with `root`, `paths`, and `changes`. Each
  entry in `changes` has a `path` and the server's `status` string. The `paths` list
  remains available for existing callers. During runner startup, a host-only filesystem
  listing can omit the root. Retry that response every half second for up to five
  seconds. Stop retries on disconnect. Other invalid root responses fail immediately.
- `omnigent-workspace-local-filename` requires an explicit `local` marker or trusted
  TRAMP prefix before it constructs an Emacs filename.

The asynchronous operations follow the [API callback design](api-callbacks.md)
for status values, error forwarding, and callback lifetimes. Their success
payloads are specified above. Diff generation requires the `diff` executable.

## Change-list cache and refresh

Keep a separate change-list cache for each session. Fetch the selected session's list on
selection and on `session.changed_files.invalidated` events. The frontend can also
request a manual refresh. Coalesce overlapping refreshes for the same session: allow at
most one fetch at a time, and schedule one follow-up fetch if an invalidation or manual
refresh arrives while it runs. A failed fetch leaves the cached list unchanged. Results
for one session must not overwrite another session's cache. Clear cached state on server
disconnect. This coordination is proposed, not yet implemented.

## Scope

Rendering, buffer selection, and file-opening commands belong in
[frontend.md](frontend.md); the workspace UI remains open for discussion. Git staging,
commits, persistent snapshots, and session-exclusive change attribution are out of
scope.

## References

- [Frontend design](frontend.md)
- Omnigent 0.19.1 installed source: `runner/resource_routes.py`,
  `runtime/filesystem_registry.py`, and `server/schemas.py`.
