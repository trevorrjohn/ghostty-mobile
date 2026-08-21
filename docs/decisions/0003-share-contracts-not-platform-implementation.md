# ADR 0003: Share Contracts, Not Platform Implementation

- Status: Accepted
- Date: 2026-08-21

## Context

Android and iOS use different UI frameworks, concurrency models, lifecycle APIs, SSH libraries, secure stores, and native packaging. Forcing a shared runtime framework would add abstraction while weakening platform integration.

At the same time, unconstrained independent implementations can diverge in trust, session, terminal, and privacy behavior.

## Decision

The applications share logical layers and behavioral contracts, not application source code or identical class structures.

Shared responsibilities are application shell, product state, session coordination, SSH transport, bounded output preprocessing, terminal adapter, immutable render snapshot, native terminal surface, and secure persistence.

- Android may use Views, services, threads, SSHJ, JNI, and Keystore-backed files.
- iOS may use SwiftUI, actors, tasks, Citadel, XCFrameworks, and Keychain.
- Both satisfy the contracts in `docs/CONTRACTS.md`.
- Duplicated protocol algorithms use equivalent limits and shared fixtures where practical.
- A semantic platform exception requires documentation and, when durable, a superseding ADR.

## Consequences

- Each app remains idiomatic and can use platform lifecycle guarantees honestly.
- Shared behavior requires deliberate parity tests instead of compile-time shared interfaces.
- Some parsers and models remain duplicated.
- Architecture reviews focus on ownership and semantics rather than matching file layouts.
