# ADR 0001: Centralize Product and Engineering Documentation

- Status: Accepted
- Date: 2026-08-21

## Context

Android and iOS began as independent repositories with separate product plans. That duplicated status, allowed product direction to diverge silently, and left architecture decisions embedded in Android-specific planning documents or implementation details.

A monorepo should make shared product direction and decision history easier to discover, not preserve repository-era documentation boundaries.

## Decision

The root `docs/` directory is the canonical location for product scope, roadmap, architecture, cross-platform contracts, security policy, platform implementation notes, and architecture decision records.

- `docs/ROADMAP.md` is the only feature-status and parity matrix.
- Shared architecture is documented by responsibility and behavior.
- Platform documents describe implementation mapping and development commands only.
- Durable tradeoffs are recorded as numbered ADRs.
- Platform source directories do not maintain competing product or architecture plans.

## Consequences

- Product differences and their reasons are visible in one place.
- Documentation updates must accompany feature-status and architecture changes.
- Platform contributors need to consult centralized contracts before introducing divergent semantics.
- Build instructions are one directory farther from platform source, but a root index makes them discoverable.
