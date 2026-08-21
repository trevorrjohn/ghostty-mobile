# Ghostty Connect for iOS

Native iOS counterpart to `../ghostty-android`. This initial app implements the host, private-key, theme, settings, terminal-preview, and secure persistence workflows while keeping the SSH transport and Ghostty VT engine behind explicit interfaces.

## Generate and run

The app requires Apple Silicon macOS, Xcode 16 or newer, and XcodeGen:

```sh
brew install xcodegen
./Scripts/build-ghostty-vt.sh
xcodegen generate
open GhosttyConnect.xcodeproj
```

Select a development team, then run the `GhosttyConnect` scheme on iOS 17 or newer.

## Native integration

The Ghostty VT integration is pinned at `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`. Install the checksum-verified official XCFramework before generating the project:

```sh
./Scripts/build-ghostty-vt.sh
xcodegen generate
```

To build from source instead, set `GHOSTTY_SOURCE_DIR` to a checkout at the pinned revision and install Zig 0.16.0 or newer. The XCFramework is installed at `Vendor/ghostty-vt.xcframework` and intentionally ignored by Git. `GhosttyTerminalEngine` is compiled automatically when that module is available.

The adapter provides VT parsing, resizing, UTF-8 input encoding, plain-text formatting, and styled cell snapshots rendered by SwiftUI. Interactive SSH uses Citadel with a real `xterm-256color` PTY. Password and imported OpenSSH Ed25519/RSA key authentication are supported.

Host keys use trust on first use. The first key presented by each `host:port` is stored in the device-only Keychain, and later key changes are blocked. Passwords remain in memory only for the connection and are never persisted.

To test, create a host from the Hosts tab, open it, authenticate, then tap the terminal to type directly into the remote PTY. Software and hardware keyboards are supported, including Return, Backspace, arrows, Escape, and common control sequences. The terminal resizes automatically with its viewport. The terminal menu can disconnect or forget a pinned host key after an intentional server key change.

Private keys and host profiles are stored as Keychain data with device-only, unlocked-device access. Passwords and passphrases are never persisted.
