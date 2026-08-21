# ADR 0006: Treat Remote Effects as Bounded Untrusted Input

- Status: Accepted
- Date: 2026-08-21

## Context

Terminal streams can request clipboard writes, notifications, links, graphics, title changes, and other side effects. They can also contain large, malformed, nested, or intentionally expensive protocol payloads.

Rendering all supported effects directly from the parser would allow a remote host to cross product and operating-system permission boundaries.

## Decision

Terminal effects are separate from cell rendering and pass through bounded parsers and explicit product policy.

- Clipboard and notification effects use host-scoped ask/allow/block policy.
- Hyperlinks use a reviewed scheme allowlist.
- iTerm, tmux, Kitty, and future parsers define fixed buffering, header, decoded-size, and processing limits.
- Unsupported or malformed effects fail safely without exposing raw control sequences as normal content.
- Background delivery does not bypass consent.
- Equivalent Kotlin and Swift parsers should use shared fixtures and limits.
- New effect types receive a security review before live wiring.

## Consequences

- Remote integrations require policy and platform-adapter work in addition to parsing.
- Some valid but oversized or unsupported payloads are intentionally rejected.
- iOS parser implementations remain partial until connected to live policy and rendering.
- Protocol breadth is subordinate to predictable memory, privacy, and consent behavior.
