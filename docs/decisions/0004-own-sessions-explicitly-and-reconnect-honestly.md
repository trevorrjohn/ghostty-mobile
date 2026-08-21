# ADR 0004: Own Sessions Explicitly and Reconnect Honestly

- Status: Accepted
- Date: 2026-08-21

## Context

Mobile UI surfaces are routinely recreated, backgrounded, or suspended while SSH connections and terminal state have different lifetimes. Saved host IDs are also insufficient session identities because users may open multiple connections to one host.

An SSH reconnect cannot restore the remote shell process unless an independent remote tool such as tmux or screen preserved it.

## Decision

Each live session has a runtime ID and one explicit owner for its transport, Ghostty terminal, prompts, effects, retry state, and cleanup.

- Runtime session identity is distinct from saved host identity.
- UI attachment does not define transport ownership.
- Android uses a foreground service and isolated session records.
- iOS will use a platform-appropriate session registry without claiming Android background guarantees.
- Reconnect creates a new remote shell and says so.
- Automatic retry is bounded by typed failure, network state, retry budget, and credential reuse policy.
- Process death and OS suspension are represented honestly.
- Read-only local archives never imply transport or remote-process restoration.

## Consequences

- Multi-session state, credentials, prompts, and effects remain isolated.
- Platform lifecycle implementations differ while product semantics remain shared.
- iOS requires architectural work to move from screen-owned single sessions to a registry.
- Remote process continuity remains the responsibility of remote tools.
