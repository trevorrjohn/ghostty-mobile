# iOS Implementation and Development

This document maps the shared [architecture](../ARCHITECTURE.md) to iOS and contains iOS-specific development instructions. Shared product behavior belongs in the roadmap and contracts, not here.

## Target

- iOS 17 or newer.
- iPhone and iPad.
- Apple Silicon macOS with Xcode 16 or newer.
- XcodeGen for project generation.

## Architecture Mapping

| Shared responsibility | iOS implementation |
| --- | --- |
| Application shell | `GhosttyConnectApp`, `RootView`, and SwiftUI feature views |
| Product state | `AppModel` and models under `Models/` |
| Session coordinator | Screen-owned `TerminalSessionModel`; app registry planned |
| SSH transport | `SSHTransport` and actor-based `CitadelSSHTransport` |
| Output preprocessing | tmux and iTerm parsers, not yet wired into live output |
| Terminal adapter | `GhosttyTerminalEngine` using the Ghostty XCFramework |
| Terminal surface | `TerminalGridView` with SwiftUI Canvas and UIKit keyboard bridge |
| Secure storage | Device-only Keychain records through `SecureStore` |
| Lifecycle owner | Terminal screen today; platform-level session owner planned |

## Session Lifecycle

The current terminal screen owns one observable session model, transport, Ghostty engine, output task, and debounced resize state. Leaving the screen disconnects the session.

This is a maturity gap rather than a different product architecture. A future app-level registry must preserve shared isolation and reconnect contracts while respecting iOS suspension limits; it must not imitate Android foreground-service guarantees.

## Ghostty Integration

The build script installs a checksum-verified XCFramework for the shared pinned Ghostty revision. `GhosttyTerminalEngine` confines C API ownership and converts render state into Swift values.

The current adapter supports feed, resize, UTF-8 text encoding, plain-text formatting, and styled snapshots. Mode-aware key and paste encoding, scrollback, selection, effects, graphics, and archive capabilities remain parity work.

## Rendering and Input

`TerminalGridView` renders styled cells and cursor state through SwiftUI Canvas. `TerminalKeyboardCapture` bridges UIKit keyboard input into SwiftUI.

The renderer consumes Swift-owned snapshots and never accesses mutable Ghostty memory. Viewport dimensions resize the local terminal before the remote PTY. Input is not locally echoed.

## Generate and Build

Install dependencies and generate the Xcode project:

```sh
brew install xcodegen
cd ios
./Scripts/build-ghostty-vt.sh
xcodegen generate
open GhosttyConnect.xcodeproj
```

Select a development team, then run the `GhosttyConnect` scheme.

The Ghostty framework is installed at `ios/Vendor/ghostty-vt.xcframework`, and the generated Xcode project is intentionally ignored by Git.

## Verification

After installing the XCFramework and generating the project:

```sh
cd ios
xcodebuild test \
  -project GhosttyConnect.xcodeproj \
  -scheme GhosttyConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Choose a simulator available in the installed Xcode version when that destination name differs.

## Current Platform Gaps

Current status is maintained in the [roadmap](../ROADMAP.md). Important iOS-specific gaps include trusted-host management, connection retry and cancellation, terminal-mode-aware input, scrollback and selection, live effect policy, multiple sessions, lifecycle ownership, and accessibility.
