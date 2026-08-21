# ADR 0005: Use Platform-Secure Storage and Explicit Host Trust

- Status: Accepted
- Date: 2026-08-21

## Context

The applications persist sensitive host profiles, imported private keys, and trusted fingerprints. Android and iOS provide different mature security primitives, and a common custom encryption or database layer would not improve their guarantees.

SSH host trust must also resist silent first-use and changed-key acceptance. Current iOS trust-on-first-use behavior is an implementation gap rather than the target policy.

## Decision

Persistent sensitive records use native platform protection while sharing security semantics.

- Android uses AES-GCM encrypted private files with a non-exportable Keystore key and disabled backup.
- iOS uses Keychain records restricted to the unlocked device and unavailable for device migration.
- Passwords, passphrases, OTPs, and challenge answers are not persisted.
- Host trust is keyed by normalized hostname and port.
- Unknown keys require fingerprint display and explicit approval before public release.
- Changed keys block until explicitly replaced.
- Secure-store changes must become atomic and concurrency-safe before synchronization or concurrent management ships.

## Consequences

- Storage implementation and migration differ by platform.
- Cross-platform configuration exchange requires an independently reviewed encrypted format.
- iOS must replace silent first-use trust with an approval flow.
- Security reviews test semantic guarantees rather than identical ciphertext formats.
