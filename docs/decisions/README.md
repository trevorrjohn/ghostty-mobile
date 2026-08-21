# Architecture Decision Records

Architecture decision records capture durable choices that affect both applications or constrain future implementation. They explain why a choice was made, not current feature status.

## Index

| ADR | Status | Decision |
| --- | --- | --- |
| [0001](0001-centralize-product-and-engineering-documentation.md) | Accepted | Centralize product and engineering documentation |
| [0002](0002-use-pinned-libghostty-vt-behind-platform-adapters.md) | Accepted | Use pinned `libghostty-vt` behind platform adapters |
| [0003](0003-share-contracts-not-platform-implementation.md) | Accepted | Share contracts, not platform implementation |
| [0004](0004-own-sessions-explicitly-and-reconnect-honestly.md) | Accepted | Own sessions explicitly and reconnect honestly |
| [0005](0005-use-platform-secure-storage-and-explicit-host-trust.md) | Accepted | Use platform-secure storage and explicit host trust |
| [0006](0006-treat-remote-effects-as-bounded-untrusted-input.md) | Accepted | Treat remote effects as bounded untrusted input |
| [0007](0007-keep-dogfooding-feedback-local-and-user-controlled.md) | Accepted | Keep dogfooding feedback local and user-controlled |

## Process

1. Copy the template below into the next numbered file.
2. Use `Proposed` while the choice is under review.
3. Change to `Accepted` when implementation proceeds.
4. Never rewrite an accepted decision to hide a changed direction; add a new ADR and mark the old one `Superseded`.
5. Link affected architecture, contracts, security rules, and roadmap capabilities.

## Template

```markdown
# ADR NNNN: Decision Title

- Status: Proposed
- Date: YYYY-MM-DD

## Context

What forces a choice, including constraints and alternatives.

## Decision

The chosen direction and its required invariants.

## Consequences

Positive and negative consequences, follow-up work, and known limits.
```
