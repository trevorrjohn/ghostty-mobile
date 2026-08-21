# Shared Architecture

## Goal

Android and iOS share one logical architecture and set of behavioral contracts. They use platform-native UI, concurrency, storage, and lifecycle mechanisms rather than sharing application source code or forcing identical class structures.

## System Model

```text
Native application shell and presentation
                |
                v
Profiles, settings, identities, and permission policy
                |
                v
Session coordinator and lifecycle owner
       +--------+---------+
       |                  |
       v                  v
SSH transport       Terminal engine adapter
       |                  |
       +---- PTY bytes ---+
                          |
                          v
                Immutable render snapshot
                          |
                          v
                 Native terminal surface

Input flows in reverse:
keyboard/touch -> terminal-aware encoder -> SSH transport

Side channels:
host trust and authentication <-> session coordinator
terminal effects -> permission policy -> platform integration
secure stores <- profiles, keys, trust, settings, optional archives
```

## Layers

### Application Shell

The application shell owns navigation, dependency composition, user prompts, and presentation state. It may observe sessions but does not own raw SSH streams or Ghostty handles.

Android currently composes the app in `MainActivity`. iOS uses `GhosttyConnectApp`, `AppModel`, and SwiftUI views. This is an intentional platform difference.

### Product State

Product models describe hosts, authentication choice, selected identity, remote permission policy, terminal settings, and user-visible session summaries. Shared behavior is defined in [CONTRACTS.md](CONTRACTS.md); storage representation is platform-specific.

### Session Coordinator

A session coordinator owns exactly one logical relationship among a host, SSH transport attempt, Ghostty terminal, prompts, effects, resize state, and cleanup. Sessions are identified independently from saved hosts so concurrent connections to one host remain isolated.

Android currently stores multiple session records in `SshSessionService`. iOS currently has one screen-owned `TerminalSessionModel`; a platform-appropriate multi-session registry is planned.

### SSH Transport Adapter

The transport owns connection, authentication, host-key callbacks, PTY allocation, ordered reads and writes, resize, and disconnect. It emits bytes and typed state; it does not parse terminal cells, render UI, or apply product permission policy.

Android adapts SSHJ. iOS adapts Citadel/NIO SSH. Their concurrency APIs differ, but they must satisfy the same ordering, ownership, and cancellation contracts.

### Output Preprocessing and Effects

Remote output is untrusted. Bounded protocol adapters may unwrap tmux passthrough, recognize iTerm payloads, translate supported graphics, or pass ordinary bytes unchanged. Ghostty effects such as clipboard requests, notifications, bell, progress, title, and PTY responses are drained separately from render data and passed through product policy.

Equivalent parsers should share limits and behavioral fixtures even when implemented separately in Kotlin and Swift.

### Terminal Engine Adapter

Both platforms use the same pinned `libghostty-vt` revision behind a narrow adapter. The adapter owns all Ghostty handles and converts upstream C structures into platform-owned values. Ghostty API changes must not leak into transport or presentation code.

The adapter is responsible for terminal feed, resize, terminal-mode-aware input encoding, immutable snapshots, supported viewport and selection operations, effects, and deterministic cleanup.

### Native Terminal Surface

Each platform renders immutable cell snapshots with its native graphics APIs. The renderer never accesses mutable Ghostty memory and never writes directly to SSH. Input is normalized and encoded by the terminal adapter; the client does not locally echo text.

Android uses a custom `View`, Canvas, and `RenderNode` caches. iOS uses SwiftUI Canvas with a UIKit keyboard bridge. Rendering capabilities may mature at different times without changing the shared boundary.

### Secure Persistence

Persistent profiles, imported keys, trust, settings, and optional read-only archives use platform security primitives. Android uses Keystore-backed AES-GCM encrypted files. iOS uses device-only Keychain items. Passwords, passphrases, OTPs, and challenge answers are never persistent records.

## Required Data Flows

### Output

```text
SSH PTY bytes
  -> bounded preprocessing
  -> Ghostty terminal feed
  -> immutable snapshot and effects
  -> native renderer and policy handlers
```

### Input

```text
platform input
  -> normalized terminal event
  -> Ghostty mode-aware encoder
  -> ordered SSH write
```

Visible input comes from remote PTY echo. Local echo would duplicate characters and expose input when a remote program disables echo.

### Resize

```text
native viewport and font metrics
  -> non-zero columns, rows, and pixel dimensions
  -> resize Ghostty model
  -> resize remote PTY to the same dimensions
```

Rapid layout changes may be debounced, but local and remote dimensions must converge in that order.

### Trust and Authentication

Host trust and authentication are session-scoped side channels, never terminal byte sequences. Responses are delivered once to the correct connection attempt. Changed host keys block by default.

## Ownership and Concurrency Invariants

- One logical owner serializes mutations to each Ghostty terminal.
- One session owns its transport, terminal, prompts, effects, and ephemeral credentials.
- UI consumes immutable state on the platform UI thread.
- Output may be conflated for rendering, but transport byte order is preserved.
- Closing a session is idempotent and prevents later output from reaching a destroyed terminal.
- Process death or OS suspension is reported honestly; local archives do not restore remote processes.
- Platform concurrency mechanisms may differ while preserving these semantics.

## Platform Mapping

| Shared responsibility | Android | iOS |
| --- | --- | --- |
| Application shell | `MainActivity` | `GhosttyConnectApp`, `RootView`, feature views |
| Product state | Models and encrypted stores | `AppModel`, models, `SecureStore` |
| Session coordinator | `SshSessionService` session records | `TerminalSessionModel`; registry planned |
| SSH transport | `SshConnection` using SSHJ | `SSHTransport`, `CitadelSSHTransport` |
| Terminal adapter | Kotlin `GhosttyTerminal` plus JNI | `GhosttyTerminalEngine` plus XCFramework |
| Renderer/input | `GhosttyTerminalView` | `TerminalGridView`, `TerminalKeyboardCapture` |
| Secure storage | Keystore-backed encrypted files | Device-only Keychain |

Durable architecture choices are recorded in [decisions](decisions/README.md). Current capability differences belong only in the [roadmap](ROADMAP.md).
