# Ghostty Connect

An Android SSH client designed around one promise: a fast, native terminal connection to another machine.

## Current milestone

This repository contains a runnable API 36 SSH client with:

- an encrypted multi-host editor with optional aliases and reusable SSH identities;
- password and imported private-key authentication;
- Android Keystore-encrypted private-key storage;
- explicit approval for unknown and changed host keys;
- a real PTY-backed interactive SSH shell;
- a pinned `libghostty-vt` native terminal engine for arm64 and x86_64;
- a JNI snapshot bridge and Android Canvas terminal renderer;
- live SSH output rendered through Ghostty with colors, cursor state, and direct keyboard input;
- a configurable, horizontally scrolling terminal modifier bar with reusable key combinations;
- Ghostty-native key, paste, mouse, selection, hyperlink, and terminal-effect handling;
- incremental dirty-row rendering and encrypted read-only snapshots of the last terminal session;
- selectable Ghostty, Dracula, Nord, and Solarized Dark terminal themes;
- foreground-service session ownership so an active SSH shell survives activity backgrounding and recreation;
- a persistent connection notification with reopen and disconnect actions;

Host configurations, trusted-host fingerprints, private keys, and SSH key names are AES-GCM encrypted with a non-exportable Android Keystore key. Passwords are requested per connection and are never persisted. Key authentication connects without a credential prompt and therefore requires a private key that does not need a passphrase.

## Build

Use JDK 17 and Android SDK 36:

```sh
./gradlew assembleDebug
```

The repository includes reproducible native artifacts for ordinary Android builds. To rebuild them, initialize the Ghostty submodule, install the pinned tools through mise, and run:

```sh
git submodule update --init
mise install
./scripts/build-libghostty-vt
```

## Next integration milestones

1. Replace full snapshot copies with incremental dirty-row render updates.
2. Route all special keys through Ghostty's mode-aware key encoder.
3. Add scrollback, selection, copy, and bracketed paste.
4. Add biometric unlock for imported identities.
5. Add explicit reconnect controls and lifecycle/process-death test coverage.

The agreed product boundaries are documented in [docs/PRODUCT_SCOPE.md](docs/PRODUCT_SCOPE.md). The native terminal architecture and delivery sequence are documented in [docs/RENDERING_PLAN.md](docs/RENDERING_PLAN.md).
