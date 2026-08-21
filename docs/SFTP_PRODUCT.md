# SFTP Product

## Product Statement

Ghostty Mobile's SFTP experience lets a user inspect and move files on a saved remote host without leaving the app or routing file data through a terminal. It is an SFTP client and remote file browser. It does not expose the Android or iOS device as an SFTP server.

The feature uses the same saved host, authentication, and host-key trust policy as terminal connections while keeping file-transfer ownership independent from terminal sessions. Android validates the first product slice before the same behavior is implemented on iOS.

## User Need

Developers and operators regularly need to inspect a remote directory, retrieve an artifact, or upload a configuration file while away from a desktop. Doing this through shell commands on a phone is slow and makes local document selection, progress, conflicts, and cancellation difficult to understand.

The product should make a small remote file task predictable without becoming a general file manager, synchronization service, or remote editor.

## Product Principles

- **Remote work, not device hosting.** The app connects to an existing SSH server and never opens an inbound file-sharing service on the mobile device.
- **Trust before access.** Entering the browser cannot bypass unknown or changed host-key review, authentication, or ProxyJump policy.
- **Explicit destinations and effects.** The user chooses local documents and destinations through platform document APIs and confirms destructive remote actions.
- **Honest ownership.** A file-browser connection, each transfer, and every terminal session are distinct activities with visible state and independent cancellation.
- **Bounded by default.** Remote paths and metadata are untrusted, transfers stream with bounded memory, and the app does not recursively enumerate or transfer directory trees in the first slice.
- **No silent overwrite.** Existing local or remote files always result in a replace, rename, or cancel decision.

## First-Release Outcomes

A user can:

1. Open **Files** from a saved host or **Browse files** from an active terminal.
2. Complete the same host-trust and authentication flow used for a terminal connection.
3. Browse from the account's remote home directory and navigate into child directories or back to a parent.
4. Inspect an entry's name, type, size, modification time, permissions, and symlink status.
5. Refresh the current directory.
6. Download one regular file to a destination selected with the platform document picker.
7. Upload one document selected with the platform document picker to the current remote directory.
8. Create a directory, rename an entry, and delete a file or empty directory after confirmation.
9. See byte progress, completion, cancellation, interruption, and an actionable failure message for a transfer.
10. Open a separate terminal for the same saved host without ending the file browser.
11. Save favorite remote folders for a saved host and reopen them from later file-browser connections.

## Entry Points

### Saved Host

Each saved-host card has separate **Terminal** and **Files** actions. Tapping the card may continue to use the established terminal default, but file browsing must not be hidden behind a long press or a terminal-only connection.

### Active Terminal

The terminal overflow menu includes **Browse files**. This starts an independent SFTP connection using the same saved host. It does not reuse the terminal's PTY, credentials, connection state, or reconnect state.

If the underlying saved host was removed or its identity is unavailable, the app explains why browsing cannot start and offers a path back to host management.

## Connection Experience

The file browser communicates these states explicitly:

- **Connecting:** establishing SSH transport.
- **Verify host:** showing the destination, complete SHA-256 fingerprint, and whether the key is unknown or changed.
- **Authenticating:** requesting a password, key passphrase, OTP, or keyboard-interactive response for this connection only.
- **Loading:** requesting the initial or current directory.
- **Ready:** showing the current location and its entries.
- **Empty:** confirming that the directory loaded successfully but contains no visible entries.
- **Permission denied:** keeping the last safe location visible and offering retry or back navigation.
- **Disconnected:** explaining that browsing and transfers stopped and offering an explicit reconnect.
- **Failed:** showing a user-actionable failure category without exposing credentials, private paths in diagnostics, or raw protocol details.

An unknown key requires explicit trust. A changed key uses stronger warning language and requires explicit replacement. Rejecting either returns to the previous screen without saving trust.

Credentials are scoped to one connection attempt. Reconnect and **Open terminal** request authentication again when required; the interface does not imply credential retention.

## Browser Experience

The browser header shows the host display name and current remote path. The primary actions are **Upload**, **New folder**, **Refresh**, **Open terminal**, and **Close**. Parent navigation is available whenever the current location is not the filesystem root, including from the account's home directory.

The path can be entered directly as an absolute or current-directory-relative path. The server canonicalizes it before use, and an explicitly entered path may open any directory the authenticated account can access. File operations remain constrained to validated children of the resulting current directory. Favorite folders are stored encrypted against the saved host ID, remain available across browser connections, and never retain credentials or connection state.

Directories sort before other entries, and each group sorts by display name without changing the remote name. `.` and `..` are never displayed as ordinary entries.

Each entry displays:

- Remote name.
- File, directory, or symlink identity.
- Size for regular files.
- Modification time when supplied by the server.
- A compact permission summary when supplied by the server.

Selecting a directory navigates into it. Selecting a regular file opens actions for **Download**, **Rename**, and **Delete**. Directory actions are **Open**, **Rename**, and **Delete empty directory**.

Symlinks are visibly identified. The first release may display a server-provided link target in details, but it does not follow a symlink for upload, download, rename, or delete. A user can delete or rename the link itself after confirmation. This conservative behavior remains until traversal behavior is validated across supported servers.

Remote names are displayed as data, never interpreted as markup or commands. Invalid names, ambiguous separators, NUL characters, and entries that cannot be safely addressed are shown as unsupported rather than acted upon.

## Download Flow

1. The user chooses **Download** on a regular file.
2. Android opens `ACTION_CREATE_DOCUMENT` with a suggested file name; iOS uses the equivalent document destination flow.
3. If the platform reports a destination conflict, the platform or app presents replace, rename, or cancel before transfer begins.
4. The app streams bytes to only the document URI approved by the user.
5. The transfer surface shows file name, bytes transferred, total bytes when known, and a cancel control.
6. Completion confirms the destination document without placing its path in logs, notifications, or feedback context.

Cancellation or interruption closes the remote file and local stream. The app reports that the selected local document may be incomplete and does not label it successful. Where the platform document provider permits deletion of a newly created partial document, the app removes it; otherwise it clearly tells the user to review or remove the partial document.

## Upload Flow

1. The user chooses **Upload** in the current directory.
2. Android opens `ACTION_OPEN_DOCUMENT`; iOS uses the equivalent document picker.
3. The app proposes the document display name as the remote name and lets the user review or change it.
4. If the remote name exists, the app offers **Replace**, **Rename**, or **Cancel**. Replace is never preselected.
5. The app uploads to a unique temporary file in the approved current directory, then renames it to the final name only after all bytes are written successfully.
6. The transfer surface shows file name, bytes transferred, total bytes when known, and a cancel control.
7. Completion refreshes the directory and focuses the uploaded entry.

Cancellation or interruption removes the temporary remote file when the connection still permits cleanup. If cleanup cannot be confirmed, the app reports that a temporary partial file may remain and refreshes safely after reconnect. It never replaces the final destination with a known partial upload.

The app does not persist access to a selected local document beyond what is needed for the user-approved transfer.

## Remote Changes

### Create Directory

The user enters one child name for the current directory. The app rejects blank names, `.` or `..`, separators, NUL characters, and names that exceed the supported UTF-8 bound. A conflict keeps the dialog open and asks for a different name.

### Rename

Rename changes only the selected entry's child name within the current directory. Moving entries between directories is not part of the first release. If the destination exists, the app offers a different name or cancel; rename never overwrites.

### Delete

Remote deletion is disabled by default for every saved host and must be explicitly enabled in that host's settings before delete actions appear. Delete always names the selected entry and requires confirmation. Files and symlinks are unlinked without following them. Directories are removed only when empty. Permission failures, non-empty directories, and network interruption leave the browser in a refreshable state without claiming success.

## Transfers and Concurrency

The first release runs one transfer at a time per file-browser connection. Starting another transfer while one is active explains that the current transfer must finish or be canceled first.

A transfer remains independent from terminal sessions for the same host. Canceling or closing a transfer does not disconnect a terminal. Disconnecting a terminal does not cancel an unrelated transfer.

While the app process remains alive, Android may use a visible foreground transfer notification for an active upload or download. The notification includes generic progress and a cancel action but excludes hostnames, usernames, remote paths, local paths, credentials, and file contents. The app never promises continuation after force-stop, reboot, or process death.

Closing the browser with an active transfer requires a choice to keep viewing the transfer or cancel it. A completed or failed transfer remains visible until acknowledged, then does not become durable transfer history.

## Failure Language

User-facing failures are grouped into actionable categories:

- Host identity requires review.
- Authentication was rejected, canceled, or timed out.
- The server does not provide the SFTP subsystem.
- Permission was denied.
- The file or directory no longer exists.
- A destination already exists.
- The directory is not empty.
- The name or remote entry is unsupported.
- The local document provider could not read or write the selected document.
- The network connection was interrupted.
- The operation failed for an unexpected reason.

Raw exceptions may inform development diagnostics only after redaction. Product messages do not include credentials, file contents, or paths outside the currently visible user context.

## Accessibility and Device Behavior

- Every entry exposes its name, type, relevant metadata, and available actions to TalkBack or VoiceOver.
- Progress is announced at useful intervals rather than for every buffer update.
- Destructive confirmation does not rely on color alone.
- Loading, empty, disconnected, and failed states have text labels.
- Keyboard and switch navigation can reach browser actions and entry menus in a stable order.
- Layouts support phone portrait and landscape without hiding cancellation or back navigation.
- Rotation or activity recreation reattaches to an in-process browser/transfer owner rather than starting a duplicate transfer.

## Security and Privacy Requirements

- SFTP runs as an SSH subsystem, never through shell commands, terminal output parsing, or a PTY.
- Host-key verification and authentication semantics match terminal connections.
- Passwords, passphrases, OTPs, and challenge answers remain memory-only and are cleared where the platform permits.
- Remote names, paths, metadata, permissions, and symlink targets are untrusted.
- Child operations are constrained to the current directory and a validated single child name.
- Transfers use fixed-size buffers and never load a complete file into memory.
- Local file access uses user-selected platform document URIs without broad storage permission.
- File names, paths, contents, host details, and credentials are excluded from logs, analytics, notifications, crash context, and automatic feedback context.
- SFTP connections and transfers have explicit owners, idempotent cancellation, and bounded prompt lifetimes.
- ProxyJump is unavailable for SFTP until the shared ProxyJump policy is implemented and every hop is independently verified.

## First-Release Exclusions

- Running an SFTP or SSH server on the mobile device.
- Recursive directory upload or download.
- Background synchronization, watched folders, or scheduled transfers.
- In-app remote text or binary editing.
- Transfer queues or multiple simultaneous transfers in one browser.
- Resume after interruption or process death.
- Durable transfer history.
- `chmod`, `chown`, ACL, or extended-attribute management.
- Moving an entry between directories.
- Following symlinks for transfer operations.
- Cross-host copying.
- Share-sheet and deep-link initiated transfers.

## Release Acceptance

The Android slice is ready for product validation when:

- All first-release outcomes work against a disposable SSH server with SFTP enabled.
- Unknown and changed host keys cannot be bypassed through either entry point.
- Password, imported-key, and keyboard-interactive authentication follow existing transient-secret policy.
- Large upload and download use bounded memory and report progress without blocking a terminal session.
- Local and remote conflicts never overwrite silently.
- Canceling or interrupting a transfer cannot publish a known partial upload as the final remote file.
- Remote child-name validation and conservative symlink handling prevent an approved operation from escaping its current-directory scope.
- Canceling a transfer leaves unrelated terminal sessions connected.
- Rotation, backgrounding, process death, and network loss produce honest state without duplicate operations or false completion.
- TalkBack can browse entries, inspect metadata, start and cancel a transfer, and confirm destructive actions.
- Unit, disposable-server integration, Android connected, lint, and debug build checks pass.

After Android validation, iOS should implement the same outcomes and contracts using native document and lifecycle APIs rather than copying Android implementation details.

## Validation Questions

Dogfooding should answer:

- Can users distinguish terminal and file-browser ownership for the same host?
- Do users understand where a download will be saved before it begins?
- Are conflict choices and partial-file messages clear enough to prevent accidental loss?
- Is one transfer at a time sufficient for the first public release?
- Does conservative symlink handling block common workflows that justify a separately reviewed follow-up?
- Are foreground progress and cancellation reliable across supported Android versions and document providers?

Product feedback remains manually authored and follows the existing local-only feedback policy. Adding automatic usage or transfer analytics requires a separate privacy and security review.
