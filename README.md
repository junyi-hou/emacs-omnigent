# Omnigent for Emacs

This project will bring [Omnigent](https://github.com/omnigent-ai/omnigent) to Emacs.

This README records upstream features, not project status. An initial Emacs transport module exists; frontend integration remains unimplemented.

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

## Sources

- [Omnigent repository and README](https://github.com/omnigent-ai/omnigent)
- [Programmatic usage](https://omnigent.ai/docs/programmatic)
- [Terminal interface](https://omnigent.ai/docs/interact/terminal)
- [Server API](https://github.com/omnigent-ai/omnigent/blob/main/omnigent/server/API.md)
