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

The foreground service, not the activity, owns live transports and Ghostty terminals. Activities attach listeners while visible, preserve the selected runtime session across recreation, and may be recreated without terminating sessions. Each runtime session ID is independent from its saved host ID; same-host sessions expose distinct IDs and monotonic durations.

The service is `START_NOT_STICKY`. Process death ends live SSH transports. Each connection setup worker is explicitly owned and cancellation closes SSHJ resources, interrupts prompt waits, and finishes credential cleanup before a retry starts. A generation-owned default-network callback follows Wi-Fi, cellular, Ethernet, and VPN routing, pauses retries while the app's route is unavailable or blocked, and ignores stale callback registrations. Automatic reconnect uses a bounded per-host attempt and backoff policy, requires reusable credentials, and creates a new shell; tmux or screen is required for remote process continuity. Exhausted retries remain available through notification or in-app reauthentication without silently discarding the session.

The file browser uses a separate started and bound service with an independent SSH connection. It reuses host trust and authentication semantics but never creates a PTY or shares terminal credentials. Direct path entry is server-canonicalized, current-folder search and sorting operate on immutable listings, and per-host favorite paths plus a bounded recent-folder history use the encrypted local store independently of live connections. Open uses a bounded app-private temporary content URI; uploads and durable downloads use document URIs and fixed-size buffers. An active transfer temporarily uses a generic `dataSync` foreground notification with cancellation and no host or path details. Process death and interruption do not resume transfers.

## Ghostty Integration

Ghostty is pinned as the `android/third_party/ghostty` submodule. A small JNI layer contains upstream C API use and exposes Kotlin-owned snapshots, encoders, effects, viewport operations, graphics, and read-only state serialization.

Native artifacts are included for arm64 and x86_64. They must remain reproducible from the pinned revision and satisfy current Android 16 KB page requirements.

Imported identities use encrypted app-private blobs. An identity can opt into a separate Android Keystore key with a five-second strong-biometric authorization window while the app still requires a fresh biometric prompt for each terminal or SFTP connection. The short window accommodates KeyMint implementations that reject zero-duration operation tokens after successful authentication. Protected identities cannot reconnect unattended, and decrypted key bytes are passed to SSHJ in memory rather than written to a temporary plaintext file. This policy does not claim StrongBox or hardware backing.

Tailscale SSH is an explicit credential-free host mode using SSH `none` authentication on port 22. The separately installed Tailscale app owns VPN and tailnet login. Ghostty Connect continues strict SSH host-key verification, bounds untrusted authentication banners, and only offers HTTPS check-mode links for the Tailscale login authority after a user action.

## Rendering and Input

`GhosttyTerminalView` owns Android rendering and interaction:

- Dirty-row snapshots and per-row render caches.
- Android text shaping, fallback fonts, combining graphemes, and emoji.
- Touch scrollback, explicit local selection over remote mouse mode, search, pinch scaling, mouse reporting, and accessibility actions.
- A configurable four-direction quick-navigation menu. A stationary hold claims the gesture before remote mouse input is emitted; lifting leaves the menu open for an explicit action tap or bottom cancel control, while early movement remains a normal remote drag. Text selection and touch exploration disable the gesture. Session actions switch among service-owned sessions without disconnecting them.
- `InputConnection`, hardware keys, configurable volume-button and modifier controls, paste safety, and Ghostty mode-aware encoding.

The UI consumes immutable snapshots. Terminal parsing and SSH I/O do not run on the main thread, and the client does not locally echo input.
Connected terminals render full-bleed with immersive system bars and a transient hostname overlay so application chrome does not reduce the PTY viewport. Tapping the terminal reveals the hostname, and tapping the hostname opens terminal controls; connection and retry failures remain visible.

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

Run the opt-in OpenSSH integration suite with a single connected emulator or device and Docker available:

```sh
cd android
./scripts/run-live-ssh-tests
```

The script builds and starts an isolated OpenSSH container, routes its random loopback port through `adb reverse`, runs only the live SSH tests, and removes both routes and container afterward. Set `ANDROID_SERIAL` when multiple devices are attached. The suite covers real password authentication, unknown-host approval and trust reuse, PTY traffic and abrupt transport loss, and bounded SFTP upload, download, and cancellation.

Connected tests require a compatible emulator or device. Public release also requires both ABI checks, 16 KB page compatibility, lifecycle and accessibility coverage, and reproducible native artifacts.

## Current Platform Gaps

Current status is maintained in the [roadmap](../ROADMAP.md). Important Android-specific engineering gaps include full shell-integration validation, large-screen workflows, and release automation. The SFTP slice has a first disposable OpenSSH integration tier but still needs key authentication, host-key rotation, server-side interruption, document-provider and connected lifecycle testing, UI automation, and TalkBack validation.
