# ADR 0002: Use Pinned libghostty-vt Behind Platform Adapters

- Status: Accepted
- Date: 2026-08-21

## Context

Both applications need the same terminal semantics without embedding Ghostty's desktop application UI. Ghostty exposes a C-compatible VT library, but its API and packaging differ from normal Android and iOS dependencies.

Alternatives include separate terminal emulators, a shared cross-platform renderer, or a plain-text compatibility fallback. Those options would undermine semantic parity, native interaction, or terminal correctness.

## Decision

Both platforms use the same intentionally pinned `libghostty-vt` revision behind a narrow platform adapter.

- Android packages native artifacts and contains C API usage behind C++ JNI and a Kotlin owner.
- iOS installs a checksum-verified XCFramework and contains C API usage in `GhosttyTerminalEngine`.
- Upstream handles and structures do not escape the adapter.
- Adapters return platform-owned immutable snapshots and typed effects.
- Revision upgrades are deliberate, tested on both platforms, and update provenance checks.
- Native initialization failure is explicit; production does not silently claim terminal compatibility through plain-text rendering.

## Consequences

- Both apps share terminal parsing behavior while retaining native UI.
- Each platform maintains FFI and packaging code.
- Feature parity depends on exposing equivalent adapter capabilities, not merely using the same library revision.
- Upstream API gaps can block graphics or snapshot features on both platforms.
