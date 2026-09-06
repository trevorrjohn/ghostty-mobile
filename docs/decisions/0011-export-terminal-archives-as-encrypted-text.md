# ADR 0011: Export Terminal Archives as Encrypted Portable Text

- Status: Accepted
- Date: 2026-09-05

## Context

Terminal history is useful for personal reference but routinely contains credentials and private output. Device-bound Ghostty state snapshots are unsuitable for deliberate export because they are engine-version-dependent and include more state than a read-only archive needs.

## Decision

An archive export is an explicit point-in-time plain-text capture of one selected live session, including retained scrollback. It excludes host metadata, timing, styling, graphics, links, title, working directory, effects, and parser state. It is never attached to diagnostics and never presented as a recording or resumable remote process.

Android's version 1 envelope is bounded to 32 MiB of plaintext and uses Argon2id (64 MiB, three iterations, one lane) with a random 128-bit salt to derive an AES-256-GCM key. Each file has a random 96-bit nonce, and the complete version and KDF header is authenticated as additional data. The passphrase is at least ten characters, is not persisted, and cannot be recovered by the application.

## Consequences

The payload is portable UTF-8 rather than tied to a Ghostty revision. Export is initially write-only; a separately reviewed viewer or command-line decoder is required to read it. Users must safeguard both the file and passphrase, and content visible only through graphics or styling is intentionally absent.
