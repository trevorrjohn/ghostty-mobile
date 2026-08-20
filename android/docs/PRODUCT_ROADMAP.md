# Ghostty Connect Product Roadmap

## Purpose

This document is the overall delivery plan for Ghostty Connect. It connects the original MVP scope, terminal architecture, current implementation, and post-MVP product backlog.

- [PRODUCT_SCOPE.md](PRODUCT_SCOPE.md) defines the original product boundary and MVP promise.
- [RENDERING_PLAN.md](RENDERING_PLAN.md) describes the native terminal architecture in depth.
- This roadmap defines what we build next, in what order, and how each phase is accepted.

## Product vision

Ghostty Connect is a focused Android SSH client for developers and operators who want a fast, trustworthy terminal designed for touch, hardware keyboards, and intermittent mobile networks.

The product should feel like a native Android tool rather than a desktop terminal compressed onto a phone. Terminal correctness is foundational, but product quality is measured by whether users can connect, recover, switch tasks, manage trust, and move data without surprises.

## Product principles

1. Security decisions are explicit. Unknown host keys, changed host keys, remote clipboard writes, and secret storage never happen silently.
2. Terminal behavior is honest. A reconnected SSH transport starts a new shell and is never presented as a resumed remote process.
3. Mobile interruptions are normal. Network changes, backgrounding, rotation, and process death have deliberate behavior.
4. Sessions are independent. Output, prompts, credentials, effects, notifications, and failures cannot leak between sessions.
5. Secrets are short-lived. Passwords, passphrases, OTP responses, and challenge answers are not persisted and are wiped from mutable memory promptly.
6. Compatibility work is bounded. Protocol parsers enforce input, memory, image, and processing limits.
7. Accessibility and external keyboards are primary input modes, not afterthoughts.
8. The smallest correct implementation wins over speculative abstraction.

## Current baseline

### Terminal foundation - implemented

- Pinned `libghostty-vt` for arm64 and x86_64.
- JNI-owned terminal state with bounded native resources.
- Dirty-row snapshots and per-row `RenderNode` caching.
- Android text shaping, fallback fonts, combining graphemes, and color emoji.
- ANSI, 256-color, true-color, styled underline, overline, cursor, and selection rendering.
- Scrollback, search, prompt navigation, semantic output copy, hyperlinks, and accessibility actions.
- IME, hardware keyboard, configurable modifier bar, mouse, stylus, focus reporting, paste safety, and bracketed paste.
- Kitty graphics and bounded iTerm2 inline-image translation, including tmux passthrough.
- Encrypted read-only terminal archives with version-pinned Ghostty state and graphics sidecars.

### Host and authentication foundation - implemented

- Encrypted saved hosts and reusable imported SSH keys.
- Password, private-key, encrypted-key, and keyboard-interactive authentication.
- OTP and public-key-plus-OTP challenge flows.
- Better imported-key names, passphrase detection, and secret-memory clearing.
- Explicit unknown and changed host-key verification.
- Per-host consent policies for remote clipboard and notification requests.

### Session reliability foundation - implemented

- Multiple independent live sessions in one foreground service.
- Active-session switching, duplication, and per-session disconnect.
- Session-specific notification open and disconnect actions.
- Ordered writes, resize delivery, PTY responses, stderr handling, and SSH signals.
- Bounded automatic reconnect for unencrypted-key sessions.
- Network-aware retry with a five-attempt, two-minute budget.
- Retry and reauthentication flow for password and encrypted-key sessions.
- Explicit messaging that reconnect creates a new shell and that tmux or screen is required for remote process continuity.

## Delivery status

Status values used below:

- `Complete`: implemented and covered by the current build verification.
- `Next`: the next product slice to implement.
- `Planned`: accepted scope, not started.
- `Optional`: useful but not required for the first public release.
- `Blocked`: requires upstream Ghostty APIs or a separate subsystem.

## Phase 1: Trust and identity management

Status: `Next`

### Outcomes

- Users can inspect, rename, and delete imported SSH identities.
- Users can copy or export a public key without exposing the private key.
- Users can see key type, fingerprint, encryption status, and affected hosts.
- Users can review and remove trusted host fingerprints.
- Deleting a key cannot silently break saved hosts.
- Concurrent trust updates cannot overwrite each other.

### Acceptance criteria

- Key deletion lists affected hosts and requires confirmation.
- A key referenced by an active session cannot be removed without an explicit warning.
- Known-host entries show host, port, fingerprint, and last trust decision.
- Removing a known-host entry causes the next connection to prompt again.
- Private-key bytes never appear in logs, intents, clipboard, or ordinary preferences.

## Phase 2: Advanced connection routing

Status: `Planned`

### Outcomes

- ProxyJump and bastion-host connections.
- Per-host connect timeout, keepalive, reconnect, and startup settings.
- Optional startup command, environment variables, and initial working directory.
- Clear typed failure states instead of behavior based on display strings.

### Acceptance criteria

- Direct and one-hop ProxyJump connections use the same host-key verification policy.
- Every hop has an independently verified host key.
- Credentials for one hop are never reused for another unless configured explicitly.
- Reconnect policy is visible and configurable per host.
- Startup commands cannot be confused with locally typed terminal input.

## Phase 3: Android credential protection

Status: `Planned`

### Outcomes

- Android Credential Manager integration for user-approved password retrieval.
- Optional biometric gate before decrypting imported identities.
- Configurable application lock after inactivity.
- Optional screenshot and recent-app preview protection for all sessions.
- Clipboard expiry for copied secrets.

### Acceptance criteria

- Credential storage remains opt-in.
- Biometric cancellation never falls through to an unlocked identity.
- Locking the app does not falsely claim that an SSH transport was disconnected.
- Secret clipboard entries can be cleared after a configurable timeout.
- Process death does not leave plaintext credentials recoverable from saved state.

## Phase 4: Mobile and large-screen workflows

Status: `Planned`

### Outcomes

- Purpose-built portrait, landscape, tablet, foldable, and ChromeOS layouts.
- Faster session switching on large screens.
- Complete external-keyboard shortcut reference and customization.
- Configurable gesture sensitivity and mouse-routing behavior.
- Share-to-terminal and deep-link connection intents with safe confirmation.

### Acceptance criteria

- Terminal resize remains correct during rotation, split screen, folding, and keyboard attachment.
- No active-session action is unreachable on a narrow phone layout.
- Hardware-only operation is possible without invoking the software keyboard.
- TalkBack can identify sessions, connection state, prompts, terminal text, and primary actions.

## Phase 5: Files and tunnels

Status: `Planned post-MVP`

### Outcomes

- SFTP browser using Android's document picker and storage access framework.
- Upload, download, progress, cancellation, and conflict handling.
- Tablet and ChromeOS drag and drop.
- Local, remote, and dynamic port forwarding.
- Visible tunnel ownership and shutdown controls per session.

### Acceptance criteria

- File operations never require broad storage permission.
- Transfers continue or fail visibly when the Activity is recreated.
- Paths are treated as remote data and cannot escape a user-selected local destination.
- Port forwards show local and remote endpoints and stop when their owning session ends.

## Phase 6: Host and workspace organization

Status: `Planned`

### Outcomes

- Host search, favorites, tags, and folders.
- Named workspaces containing hosts and active sessions.
- Recent-session ordering and session restoration entry points.
- Reconnect from an archived session into a clearly new live shell.
- Configurable archive retention and explicit archive deletion.

### Acceptance criteria

- Organization metadata does not alter SSH identity or host-key matching.
- Archive deletion removes encrypted files immediately.
- Same-host concurrent sessions have deterministic archive behavior.
- Reconnect-from-archive never implies remote process restoration.

## Phase 7: Customization and portability

Status: `Planned`

### Outcomes

- Custom fonts and user-created terminal themes.
- Per-host theme, font, keyboard-bar, gesture, and scrollback settings.
- Encrypted configuration export and import.
- Optional encrypted synchronization after a separate threat-model review.

### Acceptance criteria

- Imported fonts are validated and bounded before use.
- A broken font or theme cannot prevent access to host settings.
- Export excludes transient credentials and terminal contents unless selected explicitly.
- Import previews conflicts before replacing hosts, keys, or trust records.

## Phase 8: Release readiness

Status: `Planned`

### Outcomes

- First-run onboarding and guided connection test.
- Diagnostics export with automatic secret and terminal-content redaction.
- Localization-ready strings and layouts.
- Privacy-respecting crash-reporting policy.
- Release signing, Play packaging, backup policy, and upgrade testing.

### Acceptance criteria

- A new user can add a host, verify it, authenticate, and reach a shell without external documentation.
- Failure screens identify the phase and provide a safe next action.
- Diagnostics never include passwords, passphrases, private keys, OTPs, terminal contents, or clipboard data.
- Accessibility, lifecycle, network interruption, and upgrade suites pass on the supported API range.

## Technical compatibility backlog

These items improve terminal compatibility but do not block the product phases above.

### Virtual Kitty Unicode placeholders

Status: `Blocked`

Ghostty exposes virtual placement definitions but not resolved visible placeholder instances. The preferred solution is a public Ghostty iterator that returns image ID, placement ID, source rectangle, destination rectangle, z-index, and viewport visibility. Porting Ghostty's private diacritic and placement algorithm into Android would create a fragile maintenance fork.

### Native graphics restoration

Status: `Blocked`

Ghostty snapshot v1 omits image and placement registries, and the public API cannot import them. The current sidecar correctly restores read-only rendering but cannot recreate interactive native graphics semantics. The long-term solution is Ghostty graphics snapshot serialization or image and placement import APIs.

### Sixel

Status: `Optional`

Ghostty does not expose Sixel parsing or DCS callbacks. Support requires a separate bounded decoder before Ghostty, followed by translation into Kitty placements. This should be implemented only after product workflows above unless a concrete user workflow requires it.

### iTerm2 completeness

Status: `Optional`

Inline bitmap display is implemented. Downloads, PDF/video display, and animated GIF playback are not required for the initial release.

## Architecture direction

```text
MainActivity
    | selected session and product UI
    v
SshSessionService
    | ordered map of independent session records
    +-- Session A: SSH transport + parsers + Ghostty terminal + effects
    +-- Session B: SSH transport + parsers + Ghostty terminal + effects
    +-- Session C: retry or reauthentication state
    |
    v
Session-specific notifications and encrypted archives
```

Each session has a generated runtime ID separate from its saved host ID. Credentials and runtime session IDs are not persisted. The service is `START_NOT_STICKY`; process death ends live SSH transports. Archived terminal state is a local read-only aid, not a promise of SSH or remote-process continuation.

## Data and security plan

- Saved hosts, trusted fingerprints, key names, private keys, settings, and archives remain encrypted with Android Keystore-backed keys.
- Passwords, key passphrases, OTPs, and keyboard-interactive responses remain memory-only.
- Mutable credential arrays are cleared after transfer or use.
- Unknown and changed host keys always require an explicit decision.
- Remote clipboard and notification requests remain host-scoped and consent-gated.
- Shared encrypted stores must use process-wide serialization and atomic replacement before concurrent management screens ship.
- Export, synchronization, and crash reporting require explicit threat-model reviews before implementation.

## Verification strategy

Every product phase must add tests at the narrowest useful layer.

### Unit tests

- Parsers, retry policy, failure classification, key inspection, challenge ownership, and data migration.
- No Android device or network dependency.

### Device integration tests

- Ghostty native behavior, snapshots, graphics, text shaping, focus, selection, and accessibility.
- Activity recreation, notification intents, and multi-session routing.

### SSH integration tests

- Disposable test servers for password, key, encrypted key, keyboard-interactive, OTP, ProxyJump, SFTP, and forwarding.
- Network loss, delayed packets, server EOF, host-key rotation, and authentication failure.

### Release checks

```sh
./gradlew testDebugUnitTest lintDebug assembleDebug
./gradlew connectedDebugAndroidTest
```

Release builds must also verify both native ABIs, 16 KB page compatibility, reproducible Ghostty artifacts, upgrade migrations, and absence of secrets in logs and exported diagnostics.

## Near-term execution order

1. Build SSH key and known-host management.
2. Make encrypted store updates atomic and safe under concurrent sessions.
3. Add ProxyJump and typed per-host connection settings.
4. Add Credential Manager and biometric identity unlock.
5. Complete tablet, external-keyboard, and accessibility workflows.
6. Add SFTP and port forwarding.
7. Add workspaces, archive controls, and customization.
8. Complete onboarding, diagnostics, localization, and release packaging.

This order prioritizes daily reliability, trust, and recoverability over additional terminal protocol breadth.
