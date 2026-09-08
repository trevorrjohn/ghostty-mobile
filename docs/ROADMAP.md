# Seance Shell Product Roadmap

## Purpose

Seance Shell is a native SSH client for Android and iOS powered by Ghostty's terminal engine. This is the single product roadmap for both apps. It records the shared direction, current platform parity, delivery order, and explicit reasons for deferring or excluding work.

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
| 3. iOS core parity | Establish a full-app TestFlight baseline, then implement the validated Android connection, terminal, session, and privacy behavior using iOS-native architecture. | The full app must prove signing, distribution, installation, and core behavior before optional lightweight experiences add release surface. |
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
| SSH key naming and import during host setup, with sole-key auto-selection | `Implemented` | `Implemented` | Both host editors can add and name an identity without leaving setup and automatically select the only available key when SSH-key authentication is chosen. |
| Imported Ed25519 and RSA keys, including encrypted keys | `Implemented` | `Implemented` | Shared baseline; additional key formats require transport support, not only import recognition. |
| Keyboard-interactive, OTP, and MFA challenges | `Implemented` | `Planned` | iOS has not reached transport-level challenge handling yet. |
| Tailscale SSH authentication | `Partial` | `Planned` | Android supports explicit credential-free SSH `none` authentication on port 22, strict host-key verification, and bounded user-opened check-mode links while the Tailscale VPN remains platform-owned. Live Tailscale policy, rotation, interruption, and SFTP check-mode validation remain. |
| Key inspection, rename, deletion, and public-key export | `Implemented` | `Implemented` | Both platforms use stable UUID host references, collision-safe rename, affected-host deletion warnings, active-session deletion guards, and copy/share export when OpenSSH public metadata is derivable. |
| Unknown and changed host-key verification | `Implemented` | `Implemented` | Both block the handshake for explicit approval and display the full SHA-256 fingerprint; iOS also displays the algorithm and previous fingerprint for changed keys. |
| Trusted-host inspection and removal | `Implemented` | `Implemented` | Android uses versioned alias-preserving migration, normalized DNS/IP destinations, conflict-safe replacement, compare-and-set approval, malformed-record removal, and normalized terminal/SFTP activity guards. iOS enumerates authoritative per-destination Keychain pins; shared normalization fixtures remain parity work. |
| Cancellation, retry, keepalive, and typed failures | `Partial` | `Partial` | Android owns and cancels each setup worker, uses interruptible DNS waiting, waits for teardown before retry, cancels prompts, and has per-host bounded retry, keepalive, abrupt-EOF recovery, failure classification, a generation-owned default-network callback, and credential-safe notification reconnect for reusable keys; physical Wi-Fi, cellular, and VPN transition validation remains. iOS has typed failures, parent-channel loss detection, close-first teardown, per-host bounded retry/backoff, an app-owned network-path monitor that pauses attempts while the route is unavailable, and credential-safe automatic retry for passphrase-free imported keys. Passwords and protected keys require manual reauthentication, reconnects identify the new shell, and explicit or background disconnect cancels retry ownership. True keepalive and prompt in-progress connect cancellation require additional Citadel support; physical Wi-Fi, cellular, and VPN transition validation remains. |
| ProxyJump and bastion routing | `Planned` | `Planned` | Accepted after trust management; each hop must have independent host verification and credentials. |
| Per-host startup command, environment, and initial directory | `Planned` | `Planned` | Deferred until connection setup has typed, auditable configuration. |

### Terminal Interaction

| Capability | Android | iOS | Direction or reason |
| --- | --- | --- | --- |
| Ghostty VT parsing and styled native rendering | `Implemented` | `Implemented` | Shared foundation with platform-native renderers. |
| Unicode, colors, cursor state, and PTY resize | `Implemented` | `Implemented` | Continue device, rotation, and split-view validation. |
| Software and hardware keyboard input | `Partial` | `Partial` | Android has bounded cursor-aware IME staging, Unicode-safe deletion, stale-connection cancellation, privacy flags, one-shot modifier safety, distinct numpad and lock-key encoding, and dedicated copy/paste-key handling; broader device/IME, AltGr, shortcut, and live tmux validation remain. iOS normalizes external Ctrl/Alt/Shift/Caps Lock with navigation, F-keys, and the standard ASCII punctuation keys while preserving Command for app and system shortcuts; physical keyboard layouts and broader device validation remain. |
| Configurable modifier and extra-key controls | `Implemented` | `Implemented` | Android includes configurable mode-aware volume actions and a persistent four-direction hold menu with keys, custom chords, selection, paste, search, session switching, and explicit cancellation. iOS has persisted ordering, bounded custom actions with standard ASCII punctuation, one-shot and locked Ctrl/Alt/Shift/Meta/Caps/Num, last-used controls, navigation/editing keys, and F1-F12. iOS reserves external Command combinations for app and system shortcuts while Option maps to terminal Alt. |
| User-defined multi-step key sequences | `Implemented` | `Implemented` | Both platforms encode custom actions as up to eight ordered key events, enabling workflows such as tmux `Ctrl+B`, then `n` without pasting text or adding tmux-specific UI. |
| Scrollback navigation | `Implemented` | `Partial` | iOS retains 10,000 lines, supports row-based touch and accessibility scrolling, exposes viewport state, and provides a Live return; inertia and pointer-wheel handling remain. |
| Selection and copy | `Implemented` | `Partial` | Android has an explicit local-selection mode that pauses remote mouse reporting for tmux and other TUIs, plus contextual double-tap actions, draggable endpoints, edge autoscroll, and copy. iOS supports contextual actions, long-press word selection followed by multi-row drag extension, bounded edge autoscroll, post-lift draggable endpoint handles, and plain-text copy; broader pointer selection remains. |
| Paste and paste-safety confirmation | `Implemented` | `Implemented` | Both route explicit paste through Ghostty's mode-aware encoder and confirm LF or bracketed-paste termination; iOS also confirms CR-only command submission. |
| Search within terminal history | `Implemented` | `Implemented` | Both select one match and support cyclic previous/next navigation across soft-wrapped scrollback. iOS bounds queries to 1,024 UTF-8 bytes and uses Unicode-aware case matching; Android still needs full Unicode case handling. |
| Prompt navigation and semantic output copy | `Partial` | `Planned` | Depends on reliable OSC 133 shell markers. Android has the terminal support; iOS has not started it. |
| Guided Bash and zsh shell integration | `Partial` | `Planned` | Android detects OSC 133 markers and provides guided setup; it still needs broader validation and durable UX. iOS has not reached this slice. |
| Mouse, trackpad, stylus, and remote mouse reporting | `Implemented` | `Planned` | Android exposes an explicit local-selection override when remote applications capture pointer input, preserves correct right/middle button identity, and releases remote buttons on focus and lifecycle transitions. iOS pointer support is accepted for iPad and external-device workflows but is lower priority than core touch selection. |
| Built-in themes and font scaling | `Implemented` | `Implemented` | Custom fonts, themes, and per-host overrides remain planned. |
| Cursor blinking and synchronized-output scheduling | `Partial` | `Planned` | Android has more complete rendering cadence; iOS snapshots blink state but does not schedule it. |
| Terminal accessibility navigation | `Partial` | `Partial` | Both expose a basic terminal surface; neither has complete screen-reader workflows and validation. |

### Remote Integrations and Graphics

| Capability | Android | iOS | Direction or reason |
| --- | --- | --- | --- |
| Per-host OSC 52 clipboard policy | `Implemented` | `Implemented` | Both enforce persisted ask/allow/block policy. iOS accepts only bounded plain UTF-8 writes to the standard clipboard, bounds callback buffering, permits one pending approval, and rejects stale approvals after connection teardown. |
| Per-host remote-notification policy | `Implemented` | `Partial` | iOS stores the policy but does not yet parse or deliver notifications. |
| Bell, progress, hyperlinks, title, and working directory | `Implemented` | `Partial` | iOS supports explicit copy/open actions for bounded `http` and `https` OSC 8 hyperlinks; bell, progress, title, working directory, and broader effect policy remain. |
| iTerm2 inline images and tmux passthrough | `Partial` | `Partial` | Android renders a bounded bitmap subset. iOS parses bounded payloads but does not render them live. Downloads and rich media are deferred. |
| Kitty graphics | `Partial` | `Planned` | Android renders a bounded subset; complete placeholder and restoration behavior needs additional Ghostty APIs. |
| Sixel graphics | `Blocked` | `Blocked` | Ghostty exposes neither Sixel parsing nor the required DCS callback. A separate bounded decoder is not a core-release priority. |
| Native graphics restoration | `Blocked` | `Blocked` | Ghostty snapshots omit image registries and public import APIs. Read-only sidecars cannot restore interactive graphics semantics. |
| Safe remote file handoff | `Planned` | `Planned` | Requires bounded storage, explicit user destinations, and platform-native sharing behavior. |

### Sessions and Lifecycle

| Capability | Android | iOS | Direction or reason |
| --- | --- | --- | --- |
| Multiple isolated live sessions | `Implemented` | `Implemented` | Both use independent runtime IDs and session coordinators, including for concurrent sessions sharing one saved host. Android uses a foreground service; iOS uses an app-owned in-memory registry. |
| Session switching and per-session actions | `Implemented` | `Implemented` | Both distinguish same-host sessions and expose switching plus explicit per-session disconnect controls. Android restores selection across activity recreation; iOS retains sessions while navigating among app screens. |
| Background and foreground lifecycle behavior | `Implemented` | `Partial` | Android uses a foreground service. iOS disconnects all transports on background entry, retains in-memory records for manual reconnect, and does not imply remote process continuity; physical-device interruption validation remains. |
| Network-aware reconnect and reauthentication | `Implemented` | `Partial` | Both pause automatic retry while the default route is unavailable, bound attempts per host, and identify the replacement shell. iOS automatically retries only passphrase-free imported keys; passwords and protected keys require manual reauthentication. Physical Wi-Fi, cellular, and VPN transition validation remains. |
| Encrypted read-only terminal archives | `Partial` | `Planned` | Android stores one device-bound snapshot per host and can explicitly export a selected live session as bounded passphrase-encrypted portable text. An in-app viewer, retention controls, and same-host local-snapshot concurrency rules remain. |
| Host and session search, favorites, groups, and workspaces | `Planned` | `Planned` | Deferred until multi-session behavior is dependable on both platforms. |

### Security and Privacy

| Capability | Android | iOS | Direction or reason |
| --- | --- | --- | --- |
| Platform-backed encrypted local storage | `Implemented` | `Implemented` | Android uses Keystore-backed AES-GCM; iOS uses device-only Keychain items. |
| Short-lived credential handling | `Partial` | `Partial` | Both avoid persistence, but a full secret-lifetime, logging, clipboard, and crash-path audit remains. |
| Biometric identity unlock and app lock | `Partial` | `Planned` | Android has opt-in per-identity strong-biometric encryption, per-attempt unlock for terminal and SFTP, in-memory SSHJ key loading, no unattended reconnect for protected keys, and bounded encrypted diagnostics with explicit redacted export; real-device failure diagnosis, lifecycle/invalidation coverage, and app lock remain. |
| Screenshot and recent-app content protection | `Partial` | `Planned` | Android protects detected password input; both need a clear user-controlled policy. |
| Atomic concurrent secure-store updates | `Implemented` | `Partial` | Android serializes per-file atomic commits and protects aggregate host, identity, trust, favorite, and feedback updates across store instances, with concurrent instrumentation coverage. Multi-file identity changes use recovery-safe ordering rather than claiming a cross-file transaction. iOS still needs explicit concurrent-update verification. |
| Encrypted configuration import and export | `Planned` | `Planned` | Export must exclude transient credentials and preview conflicts before replacement. |
| Optional personal encrypted synchronization | `Planned` | `Planned` | Deferred until a separate threat model and conflict model exist. Shared team credentials remain excluded. |

### Files, Tunnels, and Mobile Workflows

| Capability | Android | iOS | Direction or reason |
| --- | --- | --- | --- |
| SFTP browsing, upload, and download | `Partial` | `Partial` | Android has an independent SFTP browser with shared trust/authentication, canonical path entry, fuzzy current-folder search, sorting, encrypted per-host favorites and bounded recent folders, bounded Open and document-URI transfers, conservative symlink handling, opt-in deletion, conflict prompts, progress, cancellation, rotation reattachment, and a disposable OpenSSH tier. iOS now has an independent Citadel SFTP connection, strict shared trust/authentication, canonical browsing, combined path/search, sorting, hidden files, Keychain-backed locations, bounded chunked transfer and previews, metadata/actions, opt-in deletion, and separate host/terminal entry points. iOS still needs a bounded incremental listing API, conflict completion, and live OpenSSH/document-provider/interruption/accessibility validation; Android still needs key authentication, host-key rotation, server-side interruption, connected lifecycle, document-provider, and TalkBack validation. |
| Local, remote, and dynamic port forwarding | `Planned` | `Planned` | Post-core work; tunnels need visible ownership and shutdown controls. |
| Tablet, landscape, split-screen, and external-keyboard workflows | `Partial` | `Partial` | Basic layouts work; neither platform has completed its device and interaction matrix. |
| Safe share and deep-link connection entry points | `Planned` | `Planned` | External input requires explicit confirmation and must not carry credentials. |
| Custom fonts, themes, gestures, and per-host terminal settings | `Planned` | `Planned` | Deferred until core terminal and session behavior reaches parity. |

### iOS App Clip Product Slice

Status: `Blocked`. The product direction is accepted, but implementation depends on proving that the SSH transport can operate within App Clip networking constraints. The current Citadel/SwiftNIO transport must be validated on a physical device and through archive validation; if it depends on unavailable low-level networking, the slice requires a Network.framework-compatible transport path.

The App Clip starts only after the full iOS app has been archived, uploaded, installed, and smoke-tested through TestFlight. It is not a prerequisite for the first TestFlight build.

#### First Slice

- Start one temporary SSH session using a user-entered hostname or IP address, port, username, and password.
- Require explicit approval of unknown or changed host-key fingerprints before authentication.
- Render the remote PTY through the same bounded Ghostty terminal adapter used by the full app.
- Keep credentials, host trust, terminal contents, and connection state in memory only.
- Disconnect explicitly when the user exits or when App Clip lifecycle limits prevent continued foreground operation.
- Offer installation of the full app for saved hosts, imported keys, SFTP, settings, and longer-lived session ownership.

#### Boundaries

- Invocation URLs, App Clip Codes, QR codes, and analytics never contain passwords or other credentials.
- The first slice does not save or transfer hosts, credentials, trust decisions, terminal history, or clipboard contents to the full app.
- Imported identities, keyboard-interactive authentication, SFTP, tunnels, multiple sessions, background operation, automatic reconnect, archives, and remote integrations remain full-app capabilities.
- A failed or interrupted App Clip session starts a new shell after reauthentication; it is never presented as resumed.
- The App Clip ships only if its binary size, privacy manifest, associated-domain configuration, transport behavior, and App Store validation satisfy current platform requirements.

#### Acceptance Criteria

- A physical-device spike proves connection, host-key verification, password authentication, PTY traffic, resize, input, and disconnect using an App Clip build.
- No credential or host detail is accepted from invocation metadata without explicit in-app review, and credentials are never accepted from invocation metadata.
- Backgrounding or expiration produces a visible disconnect and releases transport and terminal resources.
- Installing or opening the full app does not silently persist App Clip secrets or imply continuation of the remote process.
- The full iOS app has a successful TestFlight baseline before App Clip implementation begins.

### SFTP Product Slice

SFTP is part of Seance Shell's SSH product, but it is not part of Ghostty's terminal engine. It reuses saved hosts, authentication, host-key trust, ProxyJump policy, and connection diagnostics while remaining a separate file-transfer subsystem. SFTP data never passes through a PTY, terminal parser, render snapshot, or shell-integration path.

Status: `Partial` on both platforms. Android remains the reference implementation; iOS uses the same product behavior with platform-native lifecycle and document APIs.

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
| Disposable live SSH-server integration tests | `Partial` | `Planned` | Android has an opt-in pinned OpenSSH container and device runner covering password authentication, unknown-host trust and reuse, PTY traffic, abrupt transport loss, SFTP streaming, and canceled-upload cleanup. Key authentication, host-key rotation, server-side transfer interruption, reconnect, routing, service lifecycle, files, and tunnels remain. |
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
2. Complete Android Bash/zsh shell-integration validation and continue device-specific IME, AltGr, shortcut, and live tmux input coverage.
3. Continue Android multi-session validation through network and VPN changes and process death; selected-session rotation restoration, same-host identifiers, monotonic durations, prompt ownership, and pending-connect rotation handoff are implemented.
4. Add disposable SSH-server, lifecycle, accessibility, and UI automation for the validated Android behavior.
5. Update shared contracts and fixtures with product decisions discovered through Android dogfooding.
6. Complete the iOS signing, privacy, packaging, and core connection checks required for a full-app distribution baseline.
7. Archive, upload, install, and smoke-test the full iOS app through TestFlight before beginning App Clip implementation.
8. Continue iOS physical-device lifecycle validation, pointer selection, connection reliability, and remote-effect parity without blocking the initial internal TestFlight build.
9. After the TestFlight baseline, run a physical-device App Clip transport spike and proceed only if networking, binary size, privacy, and lifecycle constraints are satisfied.

This order uses Android to validate trust, daily terminal usability, and interruption recovery before duplicating behavior or adding protocol breadth.
