# Ghostty Connect

An Android SSH client designed around one promise: a fast, native terminal connection to another machine.

## Current milestone

This repository contains a runnable API 36 SSH client with:

- a saved-host editor;
- password and imported private-key authentication;
- Android Keystore-encrypted private-key storage;
- explicit approval for unknown and changed host keys;
- a real PTY-backed interactive SSH shell;
- explicit interfaces for the SSH transport and Ghostty terminal engine;

Host metadata is stored in private app preferences. Private keys are encrypted with a non-exportable Android Keystore AES key. Passwords and key passphrases are requested per connection and are not persisted.

## Build

Use JDK 17 and Android SDK 36:

```sh
./gradlew assembleDebug
```

## Next integration milestones

1. Build `libghostty` for Android ABIs and implement `TerminalEngine` through JNI.
2. Stream the working SSH channel into Ghostty and propagate terminal resize.
3. Add biometric unlock for imported identities.
4. Add lifecycle-safe reconnect and a policy-compliant foreground-service experience.

The agreed product boundaries are documented in [docs/PRODUCT_SCOPE.md](docs/PRODUCT_SCOPE.md). The native terminal architecture and delivery sequence are documented in [docs/RENDERING_PLAN.md](docs/RENDERING_PLAN.md).
