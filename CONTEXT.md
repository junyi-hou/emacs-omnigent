# Omnigent Emacs Frontend

An Emacs frontend for Omnigent: connect to a server, chat with coding
agents, and monitor sessions and their children.

## Language

### Sessions

**Session**:
An Omnigent conversation bound to an agent.
_Avoid_: conversation (in UI text), chat

**Root session**:
A top-level session the user created directly. Every fork is a root.
_Avoid_: top-level session, parent session

**Child session**:
A sub-agent session spawned by a parent session. Children can nest deeper
than one level.
_Avoid_: sub-agent, subtask

**Fork**:
A new root session copied from an existing session's history. A fork never
becomes a child of its source.
_Avoid_: branch, clone

**Elicitation**:
A question the agent asks the user mid-task, such as an approval.
_Avoid_: approval (that is one kind), permission request

**Attention**:
The state of a session with an elicitation the user has not answered.
_Avoid_: needs-attention, waiting

### Buffers

**Conversation buffer**:
The buffer that shows one session's transcript and takes input for that
session. One buffer per session.
_Avoid_: chat buffer, session buffer

**Load a session**:
Open the session's conversation buffer: a snapshot GET plus the SSE
stream. Omnigent has no resume operation; loading and sending a message
are the same path.
_Avoid_: resume a session

**Fold block**:
A transcript block with a visible header line and a collapsible body
(a tool call or reasoning). Collapsed by default.
_Avoid_: fragment, foldable region

**Active session**:
The session of the conversation buffer point is in; when point is
elsewhere, the most recently used conversation buffer's session.
_Avoid_: current session, selected session

### Connection

**Connection**:
The single Omnigent server the frontend is attached to. Connecting resets
all session state.
_Avoid_: server profile, instance
