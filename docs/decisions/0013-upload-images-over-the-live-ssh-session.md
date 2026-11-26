# ADR 0013: Upload Images Over the Live SSH Session

- Status: Proposed
- Date: 2026-11-25

## Context

Users want to send a screenshot or photo from the phone to the machine they are working on and have its path typed into the terminal, from inside the app or from another app's share sheet. [SFTP_PRODUCT.md](../SFTP_PRODUCT.md) requires the Files browser to open its own SSH connection and authenticate again, which keeps file-transfer ownership independent from terminals. That is the wrong cost for this feature: a share-in that stops at a password prompt is not seamless, and credentials are intentionally never retained.

The terminal already reports its current directory through OSC 7 or bounded absolute-path metadata, and Files already uses it as a starting location.

## Decision

Image upload may open an additional SFTP channel on a terminal session's already-authenticated SSH connection. The Files browser keeps its independent connection.

- The session owns the transport. Closing the upload channel never closes the session, and ending the session cancels the upload and says so.
- With no live session, the upload connects through the normal host-trust and authentication flow. No credential is cached to make this smoother.
- The destination is chosen by a per-host setting: **Ask every time**, **Current directory**, or **Uploads folder**. The in-terminal menu defaults to Current directory; a share-in from another app defaults to Ask, because the user cannot see the terminal.
- **Current directory** uses the terminal's reported directory read when the user picks the image. If it is unknown, not a directory, or not writable, the upload goes to the **uploads folder** (`~/.seance/uploads`, created with mode `0700`) and the user is told.
- The prompt is skipped when there is only one sensible answer. A fallback is only attempted before any bytes are read, so a failed first attempt never leaves a half-consumed input.
- File names are generated (`screenshot-YYYYMMDD-HHmmss-xxxx.ext`), so an upload never asks about a name conflict. Uploads still write a temporary file and rename it only after all bytes arrive.
- The path is typed into the terminal as paste input, absolute and shell-quoted only when needed. It never ends with a newline.
- Images are capped in size, have location and camera metadata removed, and are converted from HEIC before upload.

## Consequences

- Image upload is fast and prompt-free on an active session.
- A long upload shares the connection with the terminal, so it must not block terminal I/O or reconnect handling.
- A reported directory can be on a different filesystem than the SSH host (nested `ssh`, containers). A failed directory check falls back to the uploads folder instead of failing.
- Screenshots can land inside a git working tree. The per-host destination setting is the control for this.
- Without shell integration that emits OSC 7, there is no current directory and uploads go to the uploads folder.
- The Files browser rules for reconnect, credentials and ownership are unchanged.
