# Documentation

This directory is the canonical source for Ghostty Mobile product and engineering documentation. Platform code may implement shared contracts differently, but product behavior and architecture decisions are recorded here once.

## Product

- [Product scope](PRODUCT_SCOPE.md)
- [Product roadmap and platform parity](ROADMAP.md)
- [SFTP product](SFTP_PRODUCT.md)

## Engineering

- [Shared architecture](ARCHITECTURE.md)
- [Cross-platform contracts](CONTRACTS.md)
- [Security and trust](SECURITY.md)
- [Android implementation and development](platforms/ANDROID.md)
- [iOS implementation and development](platforms/IOS.md)

## Decisions

- [Architecture decision record index](decisions/README.md)

## Documentation Rules

- Product scope and status belong in `PRODUCT_SCOPE.md` and `ROADMAP.md`, not platform directories.
- Stable component boundaries and invariants belong in `ARCHITECTURE.md` and `CONTRACTS.md`.
- A durable choice with meaningful tradeoffs requires an architecture decision record.
- Platform documents explain implementation differences; they do not redefine shared product behavior.
- Feature changes update the roadmap when platform status changes.
- Architecture changes update the relevant document and ADR in the same change.
