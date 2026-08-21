# Ghostty Mobile Product Scope

## Product Statement

Ghostty Mobile is a focused native SSH client for Android and iOS powered by Ghostty's terminal engine. It lets developers and operators save remote hosts, connect securely, and work in a responsive terminal designed for touch, external keyboards, and mobile network interruptions.

## Shared User Journey

1. Add a host with a name, hostname, port, username, and authentication method.
2. Start a connection and review the remote host-key fingerprint when trust is unknown or changed.
3. Authenticate with a transient password or an imported SSH identity.
4. Use an interactive Ghostty-rendered remote shell.
5. Navigate terminal history and safely use input, clipboard, and remote integrations.
6. Disconnect explicitly or recover honestly after a network or lifecycle interruption.

## In Scope

### Hosts and Authentication

- Add, edit, duplicate, delete, search, and organize saved hosts.
- Password, imported-key, and keyboard-interactive authentication.
- Strict host-key verification and trusted-host management.
- Platform-secure storage for profiles, imported keys, trust, and settings.

### Terminal

- Ghostty terminal parsing through a pinned `libghostty-vt` revision.
- Platform-native rendering, keyboard input, touch interaction, and accessibility.
- Correct resize, Unicode, colors, cursor behavior, scrollback, selection, copy, paste, and search.
- Bounded and consent-gated remote effects such as clipboard requests, notifications, links, and inline graphics.
- Optional shell integration for semantic prompt and command boundaries.

### Sessions and Connections

- One SSH PTY and one Ghostty terminal model per live session.
- Multiple isolated sessions with visible ownership and disconnect controls.
- Clear connecting, verifying, authenticating, connected, retrying, disconnected, and failed states.
- Platform-appropriate lifecycle behavior and honest reconnect semantics.
- Keepalives, configurable retry, ProxyJump, SFTP, and port forwarding as later product phases.

### Security and Quality

- Transient handling of passwords, passphrases, OTPs, and challenge answers.
- Explicit consent for host trust and remote side effects.
- Accessibility, localization, diagnostics redaction, automated tests, signing, and store release workflows.

## Explicitly Excluded

- Local shell or bundled Linux environment.
- Mosh.
- SSH agent forwarding.
- Shared or team credential vaults.
- Terminal recording.
- Plugin or general scripting platform.
- tmux-specific management UI; tmux and screen remain normal remote programs.

The reasons for these decisions and any future reconsideration are recorded in the [roadmap](ROADMAP.md) and [decision log](decisions/README.md).

## Product Acceptance

- Unknown and changed host keys require an explicit decision before public release.
- Credentials and private terminal content never appear in logs, ordinary preferences, backups, or diagnostics.
- Interactive input and output remain correct through resize and supported lifecycle transitions.
- Disconnect and reconnect states are visible and never imply that a remote process survived.
- Remote effects and file paths are treated as untrusted input.
- Supported platform builds pass their automated checks and release security review.
