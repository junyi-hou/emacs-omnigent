# One-Shot API Callback Design

**Status:** Accepted. This document defines the client contract for one-shot
HTTP requests and composite data operations. It does not define SSE or WebSocket
subscription callbacks. [transport.md](transport.md) owns protocol
implementation; feature modules own response processing and state; frontends own
presentation.

## Request flow and ownership

Use this flow for one-shot operations:

```text
Collect local input
  -> dispatch an asynchronous request
  -> receive (STATUS BODY) in a callback
  -> process data, update state, report failure, or present the next prompt
```

- Transport owns request encoding, response decoding, response-buffer cleanup, and
  invalidation after a server change. It does not update feature state or display
  request errors.
- Endpoint helpers construct requests and forward results. Composite operations
  can make several requests and produce one derived result.
- Processing callbacks interpret endpoint data and apply state changes. Keep this
  processing separate from request dispatch. A named handler or a local callback
  is sufficient; no generic dispatcher is required.
- Commands collect user input and choose how to present results. When a prompt
  requires remote choices, fetch them asynchronously before presenting the prompt.
  Show an echo-area message during the fetch. Completion tables must not wait for
  network output; they can use cached results and refresh when a listing arrives.
- Local UI continuations can receive selected values instead of `(STATUS BODY)`.
  A selection continuation is not a request-result callback.

## Result contract

Request-result callbacks receive exactly two arguments: `(STATUS BODY)`.

| STATUS | Meaning | BODY |
|---|---|---|
| HTTP integer | An HTTP response is available. | The decoded response, or the operation's documented success value. |
| Transport status plist | No HTTP status is available; transport forwards the `url-retrieve` status plist. | Response content, if any. |
| `nil` | Client-side response processing failed. | An error description string. |

Use `omnigent-transport-success-p` for HTTP success detection. Only integer
codes from 200 through 299 are successful. Acceptance of a request does not
prove that an agent turn, interruption, or other background server action has
finished.

Raw requests return parsed JSON when possible, raw response text otherwise, and
nil for an empty body. JSON objects become alists with symbol keys; arrays
become vectors. JSON null becomes nil, and JSON false becomes `:json-false`.

Each composite operation documents its derived success value. Workspace diff,
for example, delivers a string instead of the underlying file-content responses.
On an HTTP or transport failure, forward the original status and body unchanged.
Do not invent an HTTP code for a local failure or turn a failed request into an
empty success.

The callback is the result interface. Function return values are not documented
result or cancellation handles. Callers must not depend on incidental retrieval
buffers or the return value of a composite operation.

## Validation and error presentation

The server owns domain decisions and remote filesystem validation. Processing
code checks the response fields needed for safe use before changing state or
presenting choices. Check required arrays and identifiers, not a second copy of
the complete server schema. Keep these checks in the feature module, not in the
shared transport request function.

A missing array is not an empty array. A malformed list response must preserve
existing state, including its truncation indicator. Report a client processing
failure instead. An explicit empty array is a valid empty result.

Keep the status and body until the command or frontend presents the outcome. Use
`omnigent-transport-error-message` for common error text. It includes the status
and prefers server `detail` or `error` fields, with the response body as
fallback. It formats text only. Callers choose an error hook, an echo-area
message, or another presentation method.

## Exceptions and notifications

Input validation and synchronous request setup can signal errors instead of
invoking a result callback. If an owner sets pending state before dispatch, it
must clear that state when setup fails. Preserve unsent drafts and the original
setup error.

Catch expected processing failures around the processing code only. Do not
convert an exception from a consumer callback into an operation failure or call
the consumer again with that exception. Consumer exceptions remain client
errors.

Complete required state changes before notifying observers. Notification errors
must not prevent pending-state cleanup or completion callback delivery.
Elicitation submission reports change-hook errors as client warnings so dispatch
and result handling can continue. It does not suppress external callback errors.

A mutation callback can schedule a list refresh. The mutation result does not
wait for that refresh to finish. A refresh failure must not hide the original
mutation result. Observers use the list's change hook to learn when refreshed
state is available.

## Lifetime and callback context

Deliver at most one result per operation. This is not a guarantee that every
call eventually invokes its callback. Setup can fail synchronously, and lifetime
checks can discard a result.

- Transport discards callbacks from an earlier server generation.
- State owners reject obsolete results, such as an older list refresh.
- Buffer-owned handlers check that their target buffer is live. They can discard
  results after that buffer dies, including any external callback they own.
- Prompt-owned completion handlers discard results after the prompt closes.
- Recheck server identity after user prompts, because prompts allow other events
  to run before the workflow continues.

These checks have different owners and purposes. Do not replace them with a
shared token solely for uniformity. Discarding a result does not cancel or undo
a server mutation.

Callbacks must not depend on the current buffer. Raw transport callbacks run in
a temporary response buffer. Buffer-owned handlers capture their target and
restore its context explicitly. Transport removes its response buffer even if a
callback changes buffers or signals an error.

## Retries and deadlines

One-shot requests do not automatically retry mutations. A lost response or
uncertain timeout does not prove that the server rejected a write. Preserve
unconfirmed drafts and report the uncertain outcome instead of resending.

There is no common application-level request deadline today. If deadlines are
added, implement them in transport rather than introducing synchronous wait
loops or separate timeout policies in each feature. Persistent connection
recovery is outside this contract; see [reconnection.md](reconnection.md).

## Checks and feature contracts

Regression checks must cover malformed responses without state loss, retained
server diagnostics, notification failures, callback exceptions, stale results,
and asynchronous selection with mocked user input. Check HTTP success range
endpoints and non-integer failure statuses through the shared predicate.

Feature documents specify payloads, state changes, and owner lifetimes without
redefining this common contract:

- [Session management](session-tree.md)
- [Conversation buffers](conversation-buffer.md)
- [Elicitations](elicitation.md)
- [Workspace changes](workspace-changes.md)
