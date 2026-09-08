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
| Session coordinator | App-owned `TerminalSessionRegistry` with one `TerminalSessionModel` per runtime session |
| SSH transport | `SSHTransport` and actor-based `CitadelSSHTransport` |
| SFTP transport | Independent actor-based `CitadelSFTPTransport` and screen-owned `SFTPBrowserModel` |
| Output preprocessing | tmux and iTerm parsers, not yet wired into live output |
| Terminal adapter | `GhosttyTerminalEngine` using the Ghostty XCFramework |
| Terminal surface | `TerminalGridView` with SwiftUI Canvas and UIKit keyboard bridge |
| Secure storage | Device-only Keychain records through `SecureStore` |
| Lifecycle owner | Application registry; backgrounding disconnects transports and retains records for manual reconnect |

## Session Lifecycle

The application owns a registry of runtime session records, each with an independent observable session model, Ghostty engine, output task, and debounced resize state. Runtime session IDs are separate from saved-host IDs, so multiple connections to one host remain distinct. Leaving a terminal screen preserves its live session; users can reopen, switch, or explicitly disconnect sessions from the Hosts screen or terminal controls. Entering the background disconnects transports without implying remote process continuity and retains records for an explicit manual reconnect.

Each connection or manual retry creates a fresh transport. Remote closure publishes disconnected or failed state before transport teardown, closes the transport before waiting on pending writes, and prevents a retry from starting until that teardown completes.

An app-owned `NWPathMonitor` distributes default-route availability to each session. Saved hosts have bounded 1-10 attempt retry budgets and Fast, Balanced, or Conservative backoff. Retry timers pause while the path is unavailable and resume when it becomes usable. Only imported keys that require no passphrase are retained as reusable retry material; passwords and protected-key passphrases are discarded after each attempt and require explicit reauthentication. Explicit disconnect, background disconnect, and session removal cancel pending retries. A successful reconnect starts and visibly identifies a new remote shell, and a connection must remain stable before its retry budget resets.

Citadel 0.12.1 exposes parent-channel closure but not a public SSH keepalive/global-request API or prompt cancellation of its underlying NIO connect future. Those remain explicit transport limitations rather than being approximated with terminal input or reachability alone.

The registry respects iOS suspension limits rather than imitating Android foreground-service guarantees. Automated coverage verifies same-host isolation, selective close, and background disconnect ownership; physical-device interruption and restoration validation remains.

## Ghostty Integration

The build script installs a checksum-verified XCFramework for the shared pinned Ghostty revision. `GhosttyTerminalEngine` confines C API ownership and converts render state into Swift values.

The current adapter supports feed, resize, UTF-8 text encoding, mode-aware named-key and paste encoding, bounded custom actions containing up to eight ordered key events, bounded scrollback, Unicode-aware history search with cyclic previous/next navigation, word/range/semantic-output selection, bounded OSC 8 hyperlink lookup, plain-text formatting, and styled snapshots. Imported SSH identities use stable UUID host references with migration from unambiguous legacy names; Settings supports inspection, collision-safe rename, affected-host deletion warnings, and OpenSSH public-key sharing when metadata is derivable. Advanced selection interactions, effects, graphics, and archive capabilities remain parity work.

## SFTP

`SFTPBrowserScreen` opens an independent Citadel SFTP subsystem connection with the same transient password/imported-key authentication and strict Keychain host verification as terminal sessions. It canonicalizes entered paths, validates server-provided child names, keeps the current directory and search in one field, exposes global actions through one menu, and shows complete filenames with long-press details and actions. Upload and download use fixed-size chunks, temporary previews are bounded and deleted after handoff, deletion is per-host opt-in, and favorites plus ten recent canonical directories use device-only Keychain storage.

The implementation remains partial until live OpenSSH, document-provider, interruption, cancellation, key-authentication, host-key rotation, accessibility, and large hostile-directory behavior are validated. Citadel 0.12.1 buffers a complete directory listing before returning it and does not expose a bounded incremental listing API; this prevents claiming a hard client-side listing-memory bound without an upstream or vendored transport change.

## Rendering and Input

`TerminalGridView` renders styled and selected cells plus cursor state through SwiftUI Canvas. Its UIKit interaction overlay maps row-based touch scrolling, long-press word selection with multi-row drag extension and bounded edge autoscroll, post-lift draggable endpoint handles, and contextual double-tap selection into terminal-owned state, while `TerminalKeyboardCapture` bridges software/hardware input and explicit copy/paste actions into SwiftUI. Selection endpoints come from immutable viewport-relative Ghostty snapshots, so handles are hidden when their endpoint is offscreen. A non-resizing search overlay navigates retained history and reuses ordinary terminal selection highlighting. The configurable keyboard bar persists enablement, ordered built-in controls, and bounded custom key-plus-modifier actions, including standard ASCII punctuation, separately from ephemeral one-shot, locked, and last-used state. It supports Ghostty's Ctrl, Alt, Shift, Meta, Caps Lock, and Num Lock modifier bits. External keyboard handling maps standard ASCII punctuation identities and their Shift variants, maps Option to terminal Alt, preserves Caps Lock state, and leaves Command combinations available to app and system shortcuts.

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

## TestFlight

Each upload must use a new `CURRENT_PROJECT_VERSION` in `ios/project.yml`. Keep the app and Quick Connect extension on the same marketing version and build number.

Prepare and test the generated project:

```sh
cd ios
./Scripts/build-ghostty-vt.sh
xcodegen generate
xcodebuild test \
  -project GhosttyConnect.xcodeproj \
  -scheme GhosttyConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Create and upload an App Store Connect archive:

```sh
xcodebuild archive \
  -project GhosttyConnect.xcodeproj \
  -scheme GhosttyConnect \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/TestFlight/SeanceShell.xcarchive \
  -allowProvisioningUpdates

xcodebuild -exportArchive \
  -archivePath build/TestFlight/SeanceShell.xcarchive \
  -exportPath build/TestFlight/Upload \
  -exportOptionsPlist TestFlightExportOptions.plist \
  -allowProvisioningUpdates
```

The upload uses automatic App Store signing for team `6GRZ874TZY`. Confirm that App Store Connect finishes processing the build before assigning internal testers. External testing additionally requires Beta App Review information and valid public privacy and support URLs.

## Current Platform Gaps

Current status is maintained in the [roadmap](../ROADMAP.md). Important iOS-specific gaps include prompt in-progress connect cancellation, keepalive, physical Wi-Fi/cellular/VPN retry validation, physical external-keyboard layout validation, broader pointer selection, live effect policy, physical-device lifecycle validation, SFTP live-server/document-provider validation and bounded incremental listings, and accessibility.
