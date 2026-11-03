# Omnigent for Emacs

This project will bring [Omnigent](https://github.com/omnigent-ai/omnigent) to Emacs.

This README records upstream features and current Emacs scope. The transport and server/session-selection entry points exist; the chat UI remains unimplemented.

## Omnigent features

### Agent support

- Runs supported coding agents, including Claude Code, Codex, Cursor, OpenCode, Hermes, and Pi.
- Supports custom agents defined in YAML.
- Runs multiple agents in one session, including reviewer and sub-agent workflows.
- Lets users select different model providers and credential types.

### Sessions

- Stores conversations as persistent sessions.
- Lets users resume or fork a session.
- Lets users continue a conversation with a different agent by cloning or forking it.
- Streams agent output and tool activity while the agent works.
- Keeps session data in sync across supported interfaces.

### User interfaces

- Provides a keyboard-first terminal interface.
- Provides a web interface and a macOS desktop app.
- Supports access from mobile browsers.
- Shows session files and diffs in the web interface.
- Supports inline comments in the web interface.

### Collaboration

- Lets users share sessions with other people.
- Lets collaborators watch a session and send messages.
- Lets users fork a shared conversation.
- Supports multi-user accounts and invite-based access.

### Sandboxes and policies

- Runs agents in local operating-system sandboxes or remote cloud sandboxes.
- Supports several sandbox providers, including Modal, Daytona, E2B, and Kubernetes.
- Applies policies at the server, agent, or session level.
- Can restrict tools, require approval for actions, and set spend limits.

### Programmatic access

- Provides a command-line interface.
- Provides a Python client and SDK.
- Provides a REST API for sessions and other server resources.
- Streams session events over server-sent events (SSE).

## Emacs design

### Session selection

The current completion prompt is temporary. After the user starts or connects to a server, the future UI should open a session-tree side panel. It should show top-level sessions as roots and child sessions under their parent. It should offer `New session` and let the user resume an existing session.

### Child sessions

The parent agent is the main orchestrator. It can create child sessions for delegated work and pass each child the context it needs. Child sessions have separate histories and statuses.

The first Emacs version will show child sessions and let users inspect or message them. It will not add a manual child-creation action. The parent agent can create children through Omnigent's delegation tools. A manual action can be added when users need it and Omnigent documents a clear client API.

## Sources

- [Omnigent repository and README](https://github.com/omnigent-ai/omnigent)
- [Programmatic usage](https://omnigent.ai/docs/programmatic)
- [Terminal interface](https://omnigent.ai/docs/interact/terminal)
- [Server API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md)
