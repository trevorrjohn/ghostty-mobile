# ADR 0010: Keep Diagnostics Bounded and Redacted

- Status: Accepted
- Date: 2026-09-05

## Context

Android Keystore and biometric behavior varies by OS release and device. Failures after successful biometric recognition cannot be diagnosed from a generic user-facing message, but ordinary logs and broad exception exports risk exposing identity aliases, paths, and other private context.

## Decision

Android records a narrow automatic diagnostic stream in encrypted app-private storage. It is bounded to 50 events and contains only timestamps, allowlisted operation stages, numeric platform result codes, exception class names, app version, Android API, and device manufacturer/model. The initial event family covers biometric setup and unlock; additional subsystems must define similarly bounded, non-content metadata before recording events.

Exception messages, stack traces, Keystore aliases, identity IDs and names, hosts, remote or local paths, credentials, key material, and terminal content are not recorded. Diagnostic writes run away from the UI thread. Nothing is transmitted automatically.

The user may explicitly export the current diagnostic report as plaintext through Android's Sharesheet after reviewing a disclosure of its fields, or clear it locally at any time.

## Consequences

The report can distinguish capability, prompt, cryptographic-object, decryption, and commit failures without reproducing secret context. It may not contain enough information for every vendor-specific failure; broader collection requires a new security review and decision. Exported plaintext is outside app-private storage after the user chooses a destination.
