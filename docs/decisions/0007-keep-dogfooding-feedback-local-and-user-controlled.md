# ADR 0007: Keep Dogfooding Feedback Local and User-Controlled

- Status: Accepted
- Date: 2026-08-21

## Context

Android is the product-discovery reference implementation. Feedback must be easy to record during real use, including live terminal sessions, but terminals and SSH profiles routinely contain secrets. A hosted feedback service, automatic diagnostics, screenshots, or terminal capture would add infrastructure and a high-risk data boundary before the product workflow is validated.

## Decision

Dogfooding feedback is a bounded, encrypted, local log of manually entered notes.

- Entries are categorized as bug, friction, or idea and include a product area and optional expected behavior.
- Automatic context uses a strict allowlist: app/build version, Android API, device model, product area, and optional session state and authentication class.
- Host details, terminal contents, command history, credentials, clipboard data, and screenshots are never captured automatically.
- Users can review, individually delete, or clear entries.
- Export requires an explicit action and warns that the reviewed data will be shared as plaintext.
- No feedback network service or telemetry endpoint is introduced.
- iOS will adopt the workflow only after Android dogfooding validates it.

## Consequences

- Feedback works offline and requires no account or backend.
- Notes remain private unless the user explicitly shares them.
- Users can still type secrets into a note, so the UI warns against it and export requires review.
- Uninstalling or clearing app data removes unexported feedback.
- Plaintext shared to another app is outside Ghostty Connect's security boundary.
- Attachments, automatic diagnostics, or direct issue submission require a future security review and ADR.
