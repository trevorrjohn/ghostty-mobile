# ADR 0012: Share Terminal and Session Logic Through a Zig Core

- Status: Accepted
- Date: 2026-11-21
- Supersedes: ADR 0003 (in part), amends ADR 0002

## Context

ADR 0003 kept the two apps independent and shared only contracts. ADR 0002 put pinned `libghostty-vt` behind a separate platform adapter on each side. In practice that means every libghostty upgrade is ported twice by hand (`GhosttyTerminalEngine.swift` and `ghostty_jni.cpp`), and small protocol algorithms (reconnect policy, tmux and iTerm parsers) drift. Android's reconnect policy has a time window and pause/resume that iOS lacks, and iOS has mouse-tracking scroll input that Android lacks.

libghostty is already Zig with a C ABI, and both platforms can link static C-ABI libraries.

## Decision

Terminal engine behavior and pure session logic live once, in a Zig core library (`core/`) exposing a C ABI. Swift and Kotlin (through a thin JNI shim) are thin bindings over it.

- The core owns the libghostty-vt dependency and is the only code that calls its C API.
- Shared in the core: terminal engine (snapshot, selection, search, input and scroll encoding, paste, effects), reconnect policy, startup command normalization, tmux passthrough and iTerm inline image parsers.
- Not shared: SSH transports, UI, secure storage, network monitoring, platform lifecycle, failure classification, and the keyboard bar model until the two definitions are reconciled.
- The core is pure: no I/O, no clocks, no threads of its own. Time is passed in as a parameter.
- Every core function is covered by `zig build test`, and the existing iOS and Android suites remain acceptance tests.
- Toolchains are pinned with `mise` (`mise.toml`) and artifacts are built locally for now. CI-built, checksum-pinned artifacts are a later decision.
- ADR 0003 still governs everything not listed as shared: the apps stay idiomatic and satisfy `docs/CONTRACTS.md`.

## Consequences

- A libghostty upgrade becomes one port plus one regression suite.
- iOS adopts Android's reconnect policy semantics.
- Zig is a hard dependency for native changes, and cross-compiling for iOS must keep working.
- Debugging crosses Swift/JNI/Zig, so the core returns structured error codes.
