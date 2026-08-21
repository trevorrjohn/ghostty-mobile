# Ghostty Mobile Product Roadmap

## Purpose

Ghostty Mobile is a native SSH client for Android and iOS powered by Ghostty's terminal engine. This is the single product roadmap for both apps. It records the shared direction, current platform parity, delivery order, and explicit reasons for deferring or excluding work.

The apps may ship features at different times, but platform differences should be intentional and visible here. A missing feature is not rejected unless its status is `Excluded`.

Shared product boundaries are defined in [PRODUCT_SCOPE.md](PRODUCT_SCOPE.md), architecture in [ARCHITECTURE.md](ARCHITECTURE.md), and durable decisions in the [ADR log](decisions/README.md).

## Product Principles

1. Security decisions are explicit. Host trust, remote clipboard writes, remote notifications, and secret storage never happen silently.
2. Terminal behavior is honest. A reconnected SSH transport starts a new shell and is never presented as a resumed remote process.
3. Mobile interruptions are normal. Network changes, backgrounding, rotation, and process death have deliberate behavior on each platform.
4. Sessions are isolated. Output, prompts, credentials, effects, notifications, and failures cannot leak between sessions.
5. Secrets are short-lived. Passwords, passphrases, OTP responses, and challenge answers are not persisted.
6. Compatibility work is bounded. Protocol parsers enforce input, memory, image, and processing limits.
7. Accessibility, touch, and external keyboards are primary interaction modes.
8. Shared product behavior matters more than identical platform architecture.
9. Product priorities come from deliberate dogfooding and privacy-preserving feedback, not speculative feature breadth.

## Status Model

| Status | Meaning |
| --- | --- |
| `Implemented` | Available in the current working tree with meaningful automated coverage. |
| `Partial` | A useful slice exists, but important behavior, integration, or verification is missing. |
| `Planned` | Accepted product scope that has not been reached on that platform. |
| `Blocked` | Accepted scope that depends on an upstream API or unresolved technical prerequisite. |
| `Excluded` | Intentionally outside the product direction for the reason recorded here. |

## Delivery Order

| Phase | Outcome | Why this comes next |
| --- | --- | --- |
| 0. Android feedback loop | Capture encrypted in-app dogfooding notes, review them in context, and explicitly export a sanitized report. | Product priorities need evidence from daily use before more scope is added. |
| 1. Android core quality | Complete identity management, trust, cancellation, retry, secure-store safety, input, shell integration, and error recovery on Android. | Android is the reference implementation for discovering and validating the product workflow. |
| 2. Android lifecycle and release baseline | Validate multiple sessions, interruptions, accessibility, device layouts, live SSH, and UI automation. | The reference behavior must be dependable before it is copied. |
| 3. iOS core parity | Implement the validated Android connection, terminal, session, and privacy behavior using iOS-native architecture. | iOS should inherit product decisions, not repeat product discovery from scratch. |
| 4. Remote integrations | Enforce remote clipboard and notification policy, complete title/CWD/link handling, and render bounded inline graphics. | These features must preserve consent and parser limits before being enabled broadly. |
| 5. Files and tunnels | SFTP plus local, remote, and dynamic forwarding with ownership, progress, and safe cancellation. | Valuable post-core workflows that add substantial transport and security surface. |
| 6. Organization and portability | Search, favorites, groups, workspaces, archive controls, and encrypted configuration import/export. | Organization becomes important after connection and session behavior are dependable. |
| 7. Security, accessibility, and release | Biometrics, app protection, audits, accessibility completion, diagnostics, localization, CI, signing, and store delivery. | Public release requires evidence that the complete product is safe and operable. |

## Product Discovery Loop

Android is the product reference implementation until its core SSH and terminal workflow is dependable. During daily use:

1. Record `Bug`, `Friction`, or `Idea` notes without leaving the current workflow.
2. Review notes by product area and resolve repeated connection, trust, input, terminal, and lifecycle problems first.
3. Export reviewed notes as plaintext only when intentionally sharing them for triage.
4. Never automatically collect terminal contents, host details, credentials, clipboard data, or screenshots.
5. Update the roadmap and shared contracts when dogfooding changes accepted product behavior.
6. Port validated behavior to iOS after critical Android workflow issues are resolved.

The first implementation stores a bounded feedback log in Android's encrypted local storage. Safe context is limited to app/build version, Android API, device model, product area, and optional session state and authentication class. The user can review or delete every note before export.

## Capability Matrix

The matrix reflects the current working tree, not only the last commit.

### Hosts, Authentication, and Trust

| Capability | Android | iOS | Direction or reason |
| --- | --- | --- | --- |
| Saved host add, edit, delete, and duplicate | `Implemented` | `Implemented` | Shared baseline with collision-safe duplicate names and independent host IDs. |
| Password authentication | `Implemented` | `Implemented` | Passwords remain memory-only and are never saved. |
| Imported Ed25519 and RSA keys, including encrypted keys | `Implemented` | `Implemented` | Shared baseline; additional key formats require transport support, not only import recognition. |
| Keyboard-interactive, OTP, and MFA challenges | `Implemented` | `Planned` | iOS has not reached transport-level challenge handling yet. |
| Key inspection, rename, deletion, and public-key export | `Partial` | `Partial` | Import exists; complete lifecycle management and affected-host warnings are Phase 1. |
| Unknown and changed host-key verification | `Implemented` | `Partial` | iOS pins first use but still needs fingerprint display and explicit first-use approval. |
| Trusted-host inspection and removal | `Partial` | `Partial` | Android lists full saved fingerprints, serializes trust updates, and guards removal while sessions are active. Destination normalization and host-key algorithm display remain; iOS still needs a complete management surface. |
| Cancellation, retry, keepalive, and typed failures | `Partial` | `Planned` | Android has retry, reauthentication, keepalive, and failure classification but still needs complete cancellation and user-configurable policy. iOS has not reached this phase. |
| ProxyJump and bastion routing | `Planned` | `Planned` | Accepted after trust management; each hop must have independent host verification and credentials. |
| Per-host startup command, environment, and initial directory | `Planned` | `Planned` | Deferred until connection setup has typed, auditable configuration. |

### Terminal Interaction

| Capability | Android | iOS | Direction or reason |
| --- | --- | --- | --- |
| Ghostty VT parsing and styled native rendering | `Implemented` | `Implemented` | Shared foundation with platform-native renderers. |
| Unicode, colors, cursor state, and PTY resize | `Implemented` | `Implemented` | Continue device, rotation, and split-view validation. |
| Software and hardware keyboard input | `Partial` | `Partial` | Android needs IME and shortcut hardening; iOS needs broader mode-aware key and modifier handling. |
| Configurable modifier and extra-key controls | `Implemented` | `Planned` | iOS has only fixed controls and has not reached customization. |
| Scrollback navigation | `Implemented` | `Planned` | Ghostty retains iOS scrollback, but the app does not expose it yet. |
| Selection and copy | `Implemented` | `Planned` | iOS needs a touch, pointer, and hardware-keyboard selection model. |
| Paste and paste-safety confirmation | `Implemented` | `Planned` | iOS has not reached clipboard and bracketed-paste integration. |
| Search within terminal history | `Implemented` | `Planned` | Planned with iOS scrollback exposure. Android still needs full Unicode case handling. |
| Prompt navigation and semantic output copy | `Partial` | `Planned` | Depends on reliable OSC 133 shell markers. Android has the terminal support; iOS has not started it. |
| Guided Bash and zsh shell integration | `Partial` | `Planned` | Android detects OSC 133 markers and provides guided setup; it still needs broader validation and durable UX. iOS has not reached this slice. |
| Mouse, trackpad, stylus, and remote mouse reporting | `Implemented` | `Planned` | iOS pointer support is accepted for iPad and external-device workflows but is lower priority than core touch selection. |
| Built-in themes and font scaling | `Implemented` | `Implemented` | Custom fonts, themes, and per-host overrides remain planned. |
| Cursor blinking and synchronized-output scheduling | `Partial` | `Planned` | Android has more complete rendering cadence; iOS snapshots blink state but does not schedule it. |
| Terminal accessibility navigation | `Partial` | `Partial` | Both expose a basic terminal surface; neither has complete screen-reader workflows and validation. |

### Remote Integrations and Graphics

| Capability | Android | iOS | Direction or reason |
| --- | --- | --- | --- |
| Per-host OSC 52 clipboard policy | `Implemented` | `Partial` | iOS stores the policy but does not yet intercept or enforce requests. |
| Per-host remote-notification policy | `Implemented` | `Partial` | iOS stores the policy but does not yet parse or deliver notifications. |
| Bell, progress, hyperlinks, title, and working directory | `Implemented` | `Planned` | iOS has not connected Ghostty effects to product UI yet. |
| iTerm2 inline images and tmux passthrough | `Partial` | `Partial` | Android renders a bounded bitmap subset. iOS parses bounded payloads but does not render them live. Downloads and rich media are deferred. |
| Kitty graphics | `Partial` | `Planned` | Android renders a bounded subset; complete placeholder and restoration behavior needs additional Ghostty APIs. |
| Sixel graphics | `Blocked` | `Blocked` | Ghostty exposes neither Sixel parsing nor the required DCS callback. A separate bounded decoder is not a core-release priority. |
| Native graphics restoration | `Blocked` | `Blocked` | Ghostty snapshots omit image registries and public import APIs. Read-only sidecars cannot restore interactive graphics semantics. |
| Safe remote file handoff | `Planned` | `Planned` | Requires bounded storage, explicit user destinations, and platform-native sharing behavior. |

### Sessions and Lifecycle

| Capability | Android | iOS | Direction or reason |
| --- | --- | --- | --- |
| Multiple isolated live sessions | `Implemented` | `Planned` | iOS currently owns one session per terminal screen and disconnects when leaving it. |
| Session switching and per-session actions | `Implemented` | `Planned` | iOS needs a session registry before tabs or switching UI. |
| Background and foreground lifecycle behavior | `Implemented` | `Planned` | Android uses a foreground service. iOS requires an honest platform-specific suspension and reconnect policy. |
| Network-aware reconnect and reauthentication | `Implemented` | `Planned` | Reconnect always creates a new shell; neither app should imply remote process continuity. |
| Encrypted read-only terminal archives | `Partial` | `Planned` | Android stores one bounded archive per host but needs retention and same-host concurrency rules. |
| Host and session search, favorites, groups, and workspaces | `Planned` | `Planned` | Deferred until multi-session behavior is dependable on both platforms. |

### Security and Privacy

| Capability | Android | iOS | Direction or reason |
| --- | --- | --- | --- |
| Platform-backed encrypted local storage | `Implemented` | `Implemented` | Android uses Keystore-backed AES-GCM; iOS uses device-only Keychain items. |
| Short-lived credential handling | `Partial` | `Partial` | Both avoid persistence, but a full secret-lifetime, logging, clipboard, and crash-path audit remains. |
| Biometric identity unlock and app lock | `Planned` | `Planned` | Must be opt-in, cancellation-safe, and must not misrepresent transport state. |
| Screenshot and recent-app content protection | `Partial` | `Planned` | Android protects detected password input; both need a clear user-controlled policy. |
| Atomic concurrent secure-store updates | `Partial` | `Partial` | Required before concurrent management and synchronization can be considered safe. |
| Encrypted configuration import and export | `Planned` | `Planned` | Export must exclude transient credentials and preview conflicts before replacement. |
| Optional personal encrypted synchronization | `Planned` | `Planned` | Deferred until a separate threat model and conflict model exist. Shared team credentials remain excluded. |

### Files, Tunnels, and Mobile Workflows

| Capability | Android | iOS | Direction or reason |
| --- | --- | --- | --- |
| SFTP browsing, upload, and download | `Planned` | `Planned` | Post-core work; must use platform document APIs without broad storage access. |
| Local, remote, and dynamic port forwarding | `Planned` | `Planned` | Post-core work; tunnels need visible ownership and shutdown controls. |
| Tablet, landscape, split-screen, and external-keyboard workflows | `Partial` | `Partial` | Basic layouts work; neither platform has completed its device and interaction matrix. |
| Safe share and deep-link connection entry points | `Planned` | `Planned` | External input requires explicit confirmation and must not carry credentials. |
| Custom fonts, themes, gestures, and per-host terminal settings | `Planned` | `Planned` | Deferred until core terminal and session behavior reaches parity. |

### SFTP Product Slice

SFTP is part of Ghostty Mobile's SSH product, but it is not part of Ghostty's terminal engine. It reuses saved hosts, authentication, host-key trust, ProxyJump policy, and connection diagnostics while remaining a separate file-transfer subsystem. SFTP data never passes through a PTY, terminal parser, render snapshot, or shell-integration path.

Status: `Planned` for Android first, followed by iOS using the validated product behavior and shared contracts.

#### User Outcomes

- Browse remote directories with clear loading, empty, permission-denied, and disconnected states.
- Inspect file name, type, size, modification time, permissions, and symlink status.
- Download a remote file to an explicit platform document destination.
- Upload a user-selected local document to the current remote directory.
- Create directories, rename entries, and delete files or empty directories with confirmation.
- See transfer progress, byte counts, cancellation, completion, and actionable failure details.
- Start a terminal session for the same host without confusing terminal and file-transfer ownership.

#### Product and Security Boundaries

- Use the SFTP subsystem over SSH; do not implement file transfer by sending shell commands or parsing terminal output.
- Apply the same host-key and authentication policy as terminal connections. ProxyJump hops are verified independently.
- Use platform document APIs and user-selected destinations; never request broad filesystem permission.
- Treat remote names, paths, metadata, and symlink targets as untrusted data.
- Stream transfers with bounded memory rather than loading complete files into RAM.
- Never silently overwrite a local or remote file. Ask whether to replace, rename, or cancel.
- Cancellation closes the transfer operation without disconnecting an unrelated terminal session.
- Background behavior must match platform guarantees and must not imply that a transfer survived process death.
- Transfer paths, file contents, and credentials are excluded from logs, diagnostics, notifications, and feedback context.

#### First Slice Exclusions

- Recursive directory upload or download.
- Automatic synchronization or watched folders.
- In-app remote text editing.
- `chmod`, `chown`, ACL, and extended-attribute management.
- Cross-host copying.
- Guaranteed transfer continuation after process death.

These are deferred rather than rejected and should be reconsidered only after ordinary browse, upload, download, conflict, and cancellation workflows are dependable.

#### Acceptance Criteria

- Unknown or changed host keys cannot be bypassed by entering the file browser.
- Passwords and key passphrases remain transient and are not retained by transfer jobs.
- Large-file upload and download use bounded memory and report progress without blocking terminal interaction.
- Canceling one transfer does not corrupt its destination or terminate unrelated sessions.
- Local destinations remain within the document selected by the user.
- Remote path traversal and symlink behavior cannot escape the operation the user approved.
- Network interruption produces a visible partial/failed state and a safe retry path.
- Android behavior is covered by disposable SSH-server integration tests before iOS implementation begins.

### Quality and Release

| Capability | Android | iOS | Direction or reason |
| --- | --- | --- | --- |
| In-app dogfooding feedback log and reviewed export | `Implemented` | `Planned` | Android stores bounded encrypted manual notes with allowlisted context and explicit plaintext sharing. Port the validated workflow to iOS later. |
| Unit and native terminal tests | `Partial` | `Implemented` | Both have useful coverage; Android still needs its full device suite run consistently. |
| Disposable live SSH-server integration tests | `Planned` | `Planned` | Needed for authentication, host-key rotation, interruption, routing, files, and tunnels. |
| UI and lifecycle automation | `Planned` | `Planned` | Required before public release because session ownership and interruption behavior are product-critical. |
| Accessibility validation | `Partial` | `Partial` | Complete TalkBack and VoiceOver journeys are not yet covered. |
| Localization and support documentation | `Planned` | `Planned` | Most strings remain hard-coded and support workflows are not established. |
| CI, signing, diagnostics, and store release | `Planned` | `Planned` | Neither app has a complete public-release pipeline or redacted diagnostics workflow. |

## Explicit Exclusions

| Capability | Android | iOS | Decision |
| --- | --- | --- | --- |
| Local shell or bundled Linux environment | `Excluded` | `Excluded` | The product is a focused remote SSH client, not a local execution environment. |
| Mosh | `Excluded` | `Excluded` | It requires a separate transport and server component outside the current SSH-focused architecture. |
| SSH agent forwarding | `Excluded` | `Excluded` | The credential exposure and lifecycle surface is not justified for the focused mobile workflow. |
| Shared or team credential vaults | `Excluded` | `Excluded` | Multi-user secret distribution requires a different trust, audit, and service model. |
| Terminal recording | `Excluded` | `Excluded` | Recording creates unnecessary secret and terminal-content retention risk. Read-only crash/lifecycle archives are not recordings. |
| Plugin or general scripting platform | `Excluded` | `Excluded` | It would expand the security and compatibility surface beyond the focused client. Shell integration remains narrowly scoped. |
| tmux-specific management UI | `Excluded` | `Excluded` | tmux and screen already work as remote programs; protocol passthrough is supported without product-specific discovery or control. |

## Acceptance Rules

- A capability becomes `Implemented` only when its user-facing path and narrowest useful automated tests are present.
- Platform-specific architecture is expected, but security and product semantics should match.
- Unknown and changed host keys always require an explicit decision before public release.
- Reconnect and archive flows must never imply that a remote process survived.
- Remote effects and file paths are untrusted input and must remain consent-gated and bounded.
- Every feature change must update this matrix when its status or rationale changes.

## Near-Term Execution

1. Use the Android feedback log during daily host, terminal, and interruption workflows and triage by severity and repetition.
2. Finish Android SSH key and trusted-host management, then make aggregate secure-store updates concurrency-safe.
3. Complete Android cancellation, configurable retry, input hardening, and Bash/zsh shell-integration validation.
4. Exercise Android multi-session ownership through backgrounding, rotation, network changes, VPN changes, and process death.
5. Add disposable SSH-server, lifecycle, accessibility, and UI automation for the validated Android behavior.
6. Update shared contracts and fixtures with product decisions discovered through Android dogfooding.
7. Implement iOS first-use host approval, connection reliability, terminal workflow parity, and platform-appropriate session ownership.
8. Connect iOS remote-effect policy only after its core daily workflow reaches parity.

This order uses Android to validate trust, daily terminal usability, and interruption recovery before duplicating behavior or adding protocol breadth.
