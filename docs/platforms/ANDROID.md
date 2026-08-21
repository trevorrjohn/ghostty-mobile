# Android Implementation and Development

This document maps the shared [architecture](../ARCHITECTURE.md) to Android and contains Android-specific development instructions. Shared product behavior belongs in the roadmap and contracts, not here.

## Target

- Android 16 / API 36 compile and target SDK.
- Minimum SDK 29.
- `arm64-v8a` physical devices and `x86_64` emulators.
- JDK 17.

## Architecture Mapping

| Shared responsibility | Android implementation |
| --- | --- |
| Application shell | `MainActivity` and programmatic native Views |
| Product state | Models plus specialized stores under `data/` |
| Session coordinator | Bound `SshSessionService` with isolated session records |
| SSH transport | `SshConnection` using SSHJ |
| SFTP transport | Independent `SftpBrowserService` and `SftpConnection` using SSHJ |
| Output preprocessing | tmux and iTerm parsers in `terminal/` |
| Terminal adapter | Kotlin `GhosttyTerminal` plus `ghostty_jni.cpp` |
| Terminal surface | `GhosttyTerminalView` using Canvas and `RenderNode` |
| Secure storage | Keystore-backed AES-GCM private files |
| Lifecycle owner | Non-exported `connectedDevice` foreground service |

## Session Lifecycle

The foreground service, not the activity, owns live transports and Ghostty terminals. Activities attach listeners while visible and may be recreated without terminating sessions. Each runtime session ID is independent from its saved host ID.

The service is `START_NOT_STICKY`. Process death ends live SSH transports. Automatic reconnect is bounded and creates a new shell; tmux or screen is required for remote process continuity.

The file browser uses a separate started and bound service with an independent SSH connection. It reuses host trust and authentication semantics but never creates a PTY or shares terminal credentials. Direct path entry is server-canonicalized, and per-host favorite folder paths use the encrypted local store independently of live connections. Uploads and downloads use document URIs and fixed-size buffers; an active transfer temporarily uses a generic `dataSync` foreground notification with cancellation and no host or path details. Process death and interruption do not resume transfers.

## Ghostty Integration

Ghostty is pinned as the `android/third_party/ghostty` submodule. A small JNI layer contains upstream C API use and exposes Kotlin-owned snapshots, encoders, effects, viewport operations, graphics, and read-only state serialization.

Native artifacts are included for arm64 and x86_64. They must remain reproducible from the pinned revision and satisfy current Android 16 KB page requirements.

## Rendering and Input

`GhosttyTerminalView` owns Android rendering and interaction:

- Dirty-row snapshots and per-row render caches.
- Android text shaping, fallback fonts, combining graphemes, and emoji.
- Touch scrollback, selection, search, pinch scaling, mouse reporting, and accessibility actions.
- `InputConnection`, hardware keys, configurable modifier controls, paste safety, and Ghostty mode-aware encoding.

The UI consumes immutable snapshots. Terminal parsing and SSH I/O do not run on the main thread, and the client does not locally echo input.

## Build

Install the shared debug keystore once on every development computer:

```sh
./scripts/install-android-debug-keystore
```

The installer exits successfully when the expected key is already present at `~/.android/debug.keystore`. Otherwise it retrieves the key from the `Ghostty Mobile Android Debug Keystore` document in your 1Password Private vault, verifies its certificate fingerprint and private-key entry, and installs it with owner-only permissions. Set `GHOSTTY_DEBUG_KEYSTORE_VAULT` when a team keeps the document in a shared vault instead.

The script explains how to install or authenticate 1Password CLI when `op` is unavailable. It refuses to overwrite a different existing key unless `--replace` is supplied. Replacement creates a timestamped backup; apps signed with the previous key must be uninstalled before installing the shared-key build.

The keystore is not a release credential and must not be committed to this public repository. Sharing it through 1Password allows debug builds from different computers to update the same installation and preserve local dogfooding data.

Initialize the Ghostty submodule, then run:

```sh
git submodule update --init
cd android
./gradlew assembleDebug
```

The repository includes native artifacts for ordinary builds. To rebuild them, install pinned tools through mise and run:

```sh
cd android
mise install
./scripts/build-libghostty-vt
```

## Verification

```sh
cd android
./gradlew testDebugUnitTest
./gradlew lintDebug assembleDebug
./gradlew connectedDebugAndroidTest
```

Connected tests require a compatible emulator or device. Public release also requires both ABI checks, 16 KB page compatibility, lifecycle and accessibility coverage, and reproducible native artifacts.

## Current Platform Gaps

Current status is maintained in the [roadmap](../ROADMAP.md). Important Android-specific engineering gaps include concurrent secure-store updates, key/trust management, full shell-integration validation, large-screen workflows, and release automation. The SFTP slice still needs disposable-server coverage, document-provider and network interruption testing, lifecycle/UI automation, and TalkBack validation.
