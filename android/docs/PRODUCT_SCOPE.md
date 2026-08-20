# Ghostty Connect — Product Scope

## Product statement

Ghostty Connect is a focused Android SSH client powered by Ghostty's terminal engine. It lets a user save a machine, connect securely, and work in a responsive terminal designed for touch and hardware keyboards.

## Target

- Latest stable Android: Android 16 / API 36
- `compileSdk` and `targetSdk`: 36
- Initial `minSdk`: 29, subject to validation during Ghostty integration
- Primary users: developers and system operators who already understand SSH

## MVP user journey

1. Add a host with a label, hostname, port, and username.
2. Start a connection.
3. Review and approve an unknown SSH host-key fingerprint; reject changed keys by default.
4. Authenticate with a password or imported SSH key.
5. Use an interactive Ghostty-rendered shell.
6. Disconnect explicitly or reconnect after a network or lifecycle interruption.

## In scope

### Hosts and authentication

- Add, edit, and delete saved hosts
- Password and SSH-key authentication
- Android Keystore-backed protection for stored secrets
- Strict known-host verification and clear fingerprint-change warnings

### Terminal

- Ghostty terminal emulation and rendering
- Touch scrolling, selection, copy, and paste
- Software extra-key row for Escape, Control, Alt, Tab, and arrow keys
- Hardware keyboard support
- Font-size adjustment and a small set of themes
- Correct resize, Unicode, and color behavior

The implementation architecture, staged delivery, and acceptance tests for this area are specified in [RENDERING_PLAN.md](RENDERING_PLAN.md). That plan deepens this scope without adding product features.

### Connection behavior

- One interactive SSH shell per terminal tab
- Clear connecting, verifying, connected, disconnected, and failed states
- Manual reconnect and safe automatic retry after brief network interruption
- Keep an active shell running while the app is backgrounded using a policy-compliant foreground service
- Show an ongoing connection notification with reopen and disconnect actions
- Send periodic SSH keepalives while connected
- Honest Android lifecycle behavior; no promise of indefinite background execution

## Out of scope

- tmux-specific discovery, commands, or UI
- SFTP or file browsing
- Port forwarding
- Mosh
- SSH agent forwarding
- Local shell or Linux environment
- Cloud sync and shared/team credentials
- Terminal recording, plugins, or scripting
- Desktop and iOS clients

## Security requirements

- Never silently accept an unknown or changed host key
- Never log passwords, private keys, passphrases, or terminal contents
- Keep credentials out of ordinary preferences and backups
- Allow optional biometric confirmation before unlocking saved identities
- Offer an option to hide terminal content in recent-app previews

## Delivery milestones

1. **Terminal spike:** render Ghostty on Android and validate input, resize, Unicode, and supported ABIs.
2. **SSH vertical slice:** connect to a test host, verify its key, authenticate, and open a shell.
3. **Usable MVP:** saved hosts, protected identities, terminal controls, tabs, and reconnect states.
4. **Release readiness:** lifecycle testing, accessibility, security review, crash reporting policy, and Play packaging.

## MVP acceptance criteria

- A user can save a host and connect without re-entering non-secret host details.
- Unknown and changed host keys require an explicit decision.
- Password and key authentication work without exposing secrets in logs or backups.
- Interactive terminal input and output remain correct across rotation and resize.
- Disconnects are visible, recoverable, and never presented as an active session.
- The app builds against API 36 and passes its automated checks.
