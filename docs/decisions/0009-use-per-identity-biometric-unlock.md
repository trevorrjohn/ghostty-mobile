# ADR 0009: Use Per-Identity Biometric Unlock

- Status: Accepted
- Date: 2026-09-05

## Context

Imported SSH private keys are long-lived secrets. A global app lock does not establish whether a specific identity may be decrypted for a new SSH or SFTP attempt, while retaining decrypted key material would weaken lifecycle and reconnect guarantees.

## Decision

Biometric protection is an opt-in property of an SSH identity, not a host. A protected private-key blob uses a distinct Android Keystore AES-GCM key requiring a strong biometric for each new connection attempt. The protected blob is bound to its identity ID, and no ordinary encrypted fallback remains after protection is committed.

Biometric enrollment changes do not invalidate the encryption key. Newly enrolled strong biometrics may authorize later use, matching Android's device-owner authentication model. Removing protection requires a successful biometric decryption first.

New protected blobs use a five-second strong-biometric authorization window to accommodate KeyMint implementations that reject zero-duration operation-bound tokens after a successful prompt. Seance Shell presents a fresh strong-biometric prompt, then initializes and completes the cipher inside that window; it never reuses the window to skip an app-level prompt or permit unattended work. Existing version-one blobs retain their operation-bound `CryptoObject` flow.

Decrypted private-key bytes and an optional SSH passphrase remain transient mutable credentials. They are cleared after handoff or failure, never enter saved state, notifications, or logs, and are loaded into SSHJ from memory rather than a plaintext temporary file. A protected identity never qualifies for unattended reconnect.

The UI must not claim StrongBox or hardware-backed storage. Biometric protection does not protect an already active transport and does not replace an SSH key's own passphrase.

## Consequences

Each terminal or SFTP connection using a protected identity requires user presence. Automatic reconnect stops for reauthentication. Enabling and disabling protection require recovery-safe ordering across the protected blob, identity index, ordinary encrypted blob, and Keystore alias. Startup reconciles a stale ordinary fallback after an interrupted enable; a failed disable removes its newly written fallback before returning an error. Interruption may retain an encrypted orphan but must not publish missing authoritative data.

Devices without an enrolled strong biometric can continue using standard encrypted identity storage. Recovery from a missing Keystore key or corrupt protected blob requires reimporting the original private key.
