# Security and Trust

## Security Boundary

The remote host, terminal byte stream, remote file paths, links, graphics, clipboard requests, and notifications are untrusted. The mobile operating system and platform secure storage provide local protection, but unlocked-device compromise is outside the application's complete control.

## Secrets

- Passwords, passphrases, OTPs, and keyboard-interactive answers are memory-only.
- Private keys are persisted only through platform-backed secure storage.
- Secrets and terminal contents are excluded from logs, analytics, crash reports, notifications, and ordinary preferences.
- Diagnostics require automatic redaction and must omit terminal content by default.
- Clipboard use is explicit; secret clipboard expiry remains planned.

## Host Trust

- Trust identity is scoped to normalized hostname and port.
- Unknown host keys require fingerprint display and explicit approval before public release.
- Changed keys block by default and require an explicit replacement decision.
- Trust removal causes the next connection to prompt again.
- ProxyJump hops must be verified independently.

iOS and Android block the SSH handshake for explicit first-use and changed-key approval with a full SHA-256 fingerprint. Android canonicalizes DNS, IDN, IPv4, and IPv6 destinations across terminal and SFTP trust, preserves conflicting legacy aliases until explicit replacement, and prevents stale approvals from overwriting newer trust. Equivalent iOS normalization remains parity work.

## Local Persistence

Android uses AES-GCM files protected by a non-exportable Android Keystore key and disables application backup. iOS uses Keychain records restricted to the unlocked device and excluded from migration to another device.

Android serializes encrypted-file reads, atomic replacement, and deletion by canonical app-private path within its single application process. Aggregate host, identity, trust, favorite, and feedback mutations use process-wide locks so separately constructed store instances cannot lose unrelated updates. Multi-file identity changes publish blobs before index additions and remove index entries before blobs; interruption can retain encrypted orphan blobs for recovery but cannot publish a missing new blob. iOS still needs explicit concurrent-update verification, and any future multi-process or synchronization design requires a separate locking and conflict model.

## Remote Effects

- Clipboard and notification requests use host-scoped ask/allow/block policy.
- Remote effects cannot display permission UI from an unsafe background context.
- Hyperlinks are restricted to reviewed schemes.
- Image and passthrough parsers enforce fixed header, encoded, decoded, and buffering limits.
- Unsupported protocols fail safely and do not justify an unbounded compatibility parser.

## Session and Lifecycle Privacy

- Sessions do not share prompts, credentials, output, effects, or retry state.
- Password input suppresses screen previews and accessibility text where the platform can detect it.
- Reconnect starts a new shell and never claims remote process continuity.
- Android terminal archives are encrypted, bounded, read-only local aids; they are not recordings or live restoration.

## Dogfooding Feedback

- Feedback contains only manually entered notes plus allowlisted app and device context.
- Terminal contents, host details, credentials, clipboard data, and screenshots are not collected automatically.
- Local feedback is encrypted and bounded like other product records.
- Users review entries before an explicit plaintext share action.
- Shared plaintext is no longer protected by Ghostty Connect and may contain secrets the user typed despite the warning.
- Automatic upload, telemetry, attachments, or broader diagnostics require a new security review.

## Review Requirements

The following work requires an explicit threat-model or security ADR update before implementation:

- Configuration synchronization.
- Shared or team credentials.
- Crash reporting and exported diagnostics.
- New remote file-transfer protocols.
- Agent forwarding or any feature that delegates credentials.
- Broader URL schemes or executable integrations.

Security decisions are indexed in [decisions](decisions/README.md), and incomplete controls are tracked in the [roadmap](ROADMAP.md).
