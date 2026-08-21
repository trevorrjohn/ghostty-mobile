# Cross-Platform Contracts

These contracts define shared behavior, not a shared programming language API. Kotlin and Swift names may differ, but deviations in semantics require an architecture decision record.

## Host Profile

A host profile has a stable ID, display name, hostname, port, username, authentication choice, optional identity reference, and ask/allow/block policy for remote clipboard and notification requests.

- Host trust is keyed by normalized hostname and port, not display name.
- Duplicating a profile creates a new ID and unique display name.
- Organization metadata never changes trust or identity matching.
- Profiles never contain passwords, passphrases, OTPs, or challenge answers.

## Ephemeral Credential

An ephemeral credential is supplied to one connection attempt and may contain a password, private-key material, or key passphrase.

- It is never persisted or included in logs, diagnostics, notifications, or saved UI state.
- Mutable secret storage is cleared after transfer or use where the platform permits.
- A credential is not silently reused for another host or ProxyJump hop.

## Host Trust Decision

A trust request contains destination, algorithm, fingerprint, and whether the key is unknown or changed.

- Unknown keys require explicit approval before public release.
- Changed keys block until the user explicitly replaces trust.
- Accepting trust records the exact destination and key fingerprint.
- Removing trust causes the next connection to request approval again.

## SSH Transport

Conceptually, a transport supports:

```text
connect(host, ephemeral credential)
ordered output byte stream
write(bytes)
resize(columns, rows, pixel width, pixel height)
disconnect()
```

- It requests an interactive `xterm-256color` PTY.
- It preserves output and write order.
- It reports typed connection and closure states.
- It exposes host-trust and keyboard-interactive challenges as side channels.
- It does not parse terminal state, render UI, or make consent decisions.
- Disconnect and cancellation are idempotent.

## Terminal Engine

Conceptually, a terminal adapter supports:

```text
create(columns, rows, options)
feed(bytes)
resize(columns, rows, pixel dimensions)
encode(input event or paste)
snapshot(viewport)
drain effects
close()
```

- It exclusively owns Ghostty handles.
- Calls after closure fail safely.
- It validates ranges, dimensions, enum values, and upstream failures.
- It returns platform-owned immutable values rather than native pointers.
- Input encoding reflects current terminal modes.
- It never writes terminal content to logs.

Scrollback, selection, search, graphics, and archive operations extend this contract as platforms implement them; capability status is tracked in the roadmap.

## Terminal Snapshot

A render snapshot contains generation, dimensions, viewport position, default colors, immutable styled cells, dirty-region information when available, cursor state, and bounded graphics placements when supported.

- Renderers may retain snapshots but never mutable native memory.
- Cell text is grapheme-aware and preserves display width.
- Application colors do not overwrite explicit remote indexed or RGB colors.
- A snapshot is render state, not a transport or remote-process snapshot.

## Terminal Input Event

Input is normalized into text, named key, modifiers, action, and optional pointer coordinates before terminal encoding.

- Text is sent only after IME commit.
- Paste uses bracketed-paste and safety policy where applicable.
- Key encoding is terminal-mode-aware.
- The client never locally echoes committed input.
- Password-input detection suppresses accessibility or preview exposure where supported.

## Terminal Effect

Effects are untrusted remote requests or metadata separate from cell rendering. Examples include bell, progress, title, working directory, clipboard write, notification, hyperlink, graphics, and bytes that Ghostty requests be returned to the PTY.

- Clipboard and notification effects pass through host-scoped ask/allow/block policy.
- URLs use an explicit safe-scheme allowlist.
- Payloads have documented size and processing bounds.
- Background delivery never bypasses consent.
- Malformed or unsupported effects fail safely without becoming visible escape text.

## Session Coordinator

A live session has a runtime ID distinct from its saved host ID and owns one transport, one terminal, one connection attempt state, pending prompts, effects, and cleanup.

- Concurrent sessions for one saved host remain independent.
- Prompt answers are delivered once to the correct session and attempt.
- Reconnect creates a new remote shell and communicates that fact.
- Automatic retry is limited by typed failure, retry budget, network state, and reusable credential policy.
- UI attachment does not determine transport ownership.
- Local read-only archives never imply live-session restoration.

## Secure Store

A secure store reads, writes, and deletes versioned product records using platform-backed protection.

- Writes are atomic from the reader's perspective.
- Concurrent read-modify-write operations must not silently lose updates.
- Corruption and migration failures produce actionable errors rather than empty replacement data.
- Backups and exports exclude secrets unless an explicitly reviewed encrypted format says otherwise.
- Transient credentials are not valid secure-store records.

## Shared Behavioral Fixtures

Algorithms duplicated in Kotlin and Swift should use shared fixture inputs and expected outputs where practical. Priority fixtures include host-name duplication, terminal byte streams, key inspection, tmux passthrough, iTerm payload bounds, host trust transitions, retry policy, resize, and shell-integration markers.
