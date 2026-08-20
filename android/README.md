# Ghostty Connect

An Android SSH client designed around one promise: a fast, native terminal connection to another machine.

## Current milestone

This repository contains a runnable API 36 SSH client with:

- a saved-host editor;
- password and imported private-key authentication;
- Android Keystore-encrypted private-key storage;
- explicit approval for unknown and changed host keys;
- a real PTY-backed interactive SSH shell;
- a pinned `libghostty-vt` native terminal engine for arm64 and x86_64;
- a JNI snapshot bridge and Android Canvas terminal renderer;
- live SSH output rendered through Ghostty with colors, cursor state, and direct keyboard input;

Host metadata is stored in private app preferences. Private keys are encrypted with a non-exportable Android Keystore AES key. Passwords and key passphrases are requested per connection and are not persisted.

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
5. Add lifecycle-safe reconnect and a policy-compliant foreground-service experience.

The agreed product boundaries are documented in [docs/PRODUCT_SCOPE.md](docs/PRODUCT_SCOPE.md). The native terminal architecture and delivery sequence are documented in [docs/RENDERING_PLAN.md](docs/RENDERING_PLAN.md).
