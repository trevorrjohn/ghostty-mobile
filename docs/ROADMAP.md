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
| 1. Trust and connection reliability | Complete identity management, explicit host trust, typed failures, cancellation, retry, keepalives, and atomic secure stores. | A trustworthy connection is more important than adding protocol breadth. |
| 2. Terminal workflow parity | Bring iOS scrollback, selection, paste safety, search, prompt navigation, and shell integration to the Android baseline; harden Android's partial input and shell-integration work. | Both apps need a complete daily terminal workflow before broader product features. |
| 3. Sessions and mobile lifecycle | Multiple isolated sessions, visible reconnect behavior, background/foreground handling, and platform-appropriate restoration. | Mobile network and lifecycle interruptions are routine, not edge cases. |
| 4. Remote integrations | Enforce remote clipboard and notification policy, complete title/CWD/link handling, and render bounded inline graphics. | These features must preserve consent and parser limits before being enabled broadly. |
| 5. Files and tunnels | SFTP plus local, remote, and dynamic forwarding with ownership, progress, and safe cancellation. | Valuable post-core workflows that add substantial transport and security surface. |
| 6. Organization and portability | Search, favorites, groups, workspaces, archive controls, and encrypted configuration import/export. | Organization becomes important after connection and session behavior are dependable. |
| 7. Security, accessibility, and release | Biometrics, app protection, audits, accessibility completion, diagnostics, localization, CI, signing, and store delivery. | Public release requires evidence that the complete product is safe and operable. |

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
| Trusted-host inspection and removal | `Partial` | `Partial` | Storage exists, but both apps need a complete management surface. |
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

### Quality and Release

| Capability | Android | iOS | Direction or reason |
| --- | --- | --- | --- |
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

1. Finish SSH key and trusted-host management on both platforms.
2. Add explicit first-use host-key approval and connection reliability to iOS.
3. Make secure-store updates atomic under concurrent sessions and management screens.
4. Complete iOS scrollback, selection, copy/paste safety, and search.
5. Complete and validate Bash/zsh OSC 133 shell integration on Android, then implement the same product flow on iOS.
6. Build iOS multi-session ownership and platform-appropriate lifecycle behavior.
7. Enforce iOS remote clipboard and notification policy and connect terminal effects.
8. Add disposable SSH-server, lifecycle, accessibility, and release automation before broadening into SFTP and forwarding.

This order prioritizes trust, daily terminal usability, and interruption recovery over additional protocol breadth.
