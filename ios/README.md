# Ghostty Connect for iOS

Native iOS counterpart to `../ghostty-android`. This initial app implements the host, private-key, theme, settings, terminal-preview, and secure persistence workflows while keeping the SSH transport and Ghostty VT engine behind explicit interfaces.

## Generate and run

The app requires macOS, Xcode 16 or newer, and XcodeGen:

```sh
brew install xcodegen
xcodegen generate
open GhosttyConnect.xcodeproj
```

Select a development team, then run the `GhosttyConnect` scheme on iOS 17 or newer.

## Native integration

The Android app pins Ghostty at `9ae02a326f62bd88f7f5508cf1807c67e7775cb5`. Build its `ghostty-vt.xcframework` on Apple Silicon macOS with upstream's `zig build -Demit-lib-vt`, add it to the app target, and implement `TerminalEngine`. Implement `SSHTransport` with a reviewed iOS SSH library. The app intentionally reports this integration as unavailable until both are present; it never simulates a successful SSH connection.

Private keys and host profiles are stored as Keychain data with device-only, unlocked-device access. Passwords and passphrases are never persisted.
