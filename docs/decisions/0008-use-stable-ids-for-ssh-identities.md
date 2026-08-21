# ADR 0008: Use Stable IDs for SSH Identities

- Status: Accepted
- Date: 2026-08-21

## Context

Android originally indexed imported SSH keys by display name and derived encrypted filenames from Java's 32-bit `String.hashCode()`. Hosts also referenced keys by mutable display name. Duplicate names could silently replace key material, hash collisions could map different names to one file, and rename or deletion could leave saved hosts and reconnecting sessions with ambiguous references.

Existing encrypted keys and host profiles are persisted on dogfooding devices, so migration must survive interruption without deleting the legacy recovery source.

## Decision

Android SSH identities use stable UUIDs independent from display names.

- A versioned encrypted identity index stores UUID, display name, algorithm, full fingerprint, passphrase requirement, and public-key text when derivable.
- Private-key blobs use UUID-derived filenames.
- Hosts reference an identity UUID rather than a display name.
- Imports create unique display names and never overwrite an existing identity.
- Identity blobs commit before their index entry; the identity index commits before host references migrate.
- Migration is idempotent and uses atomic replacement for each aggregate record.
- Legacy indexes, hash-derived blobs, host key names, and preferences remain untouched in this release as rollback sources.
- Interrupted migration may leave encrypted orphan UUID blobs; they are retained rather than risking deletion of key material.
- Identity mutation is process-wide serialized, and destructive management remains blocked while active sessions depend on an identity.

## Consequences

- Rename and deletion can update metadata without changing private-key filenames.
- Hosts and sessions retain unambiguous identity references.
- Cross-file migration cannot be one transaction, so ordering and retained legacy data provide recovery.
- Some migrated PEM identities may not have public-key text or a full fingerprint until they are unlocked and derived later.
- Downgrading the app will not see identities imported after migration because new imports are not dual-written into the unsafe legacy schema.
- Legacy cleanup requires a later migration after field experience confirms the new schema.
