# Ghostty Rendering Implementation Plan

## Purpose

This document describes how Ghostty Connect will replace its temporary plain-text output view with a correct terminal powered by `libghostty-vt`. It deepens the terminal portion of the existing product scope; it does not add product features or change the SSH-only boundary.

## Current state

The application initially used a sanitized `TextView`. R0 through the first live integration slice are now implemented:

- opens a real SSH connection and requests a remote PTY;
- receives and sends bytes through SSHJ;
- pins Ghostty as a submodule and builds `libghostty-vt` for arm64 and x86_64;
- feeds raw SSH bytes through a JNI-owned Ghostty terminal;
- renders cells, styles, colors, Unicode, and cursor state with an Android Canvas View;
- accepts direct IME and hardware-key input;
- synchronizes View dimensions with the Ghostty grid and SSH PTY.

The current bridge copies a complete packed snapshot for each refresh. The next rendering work is incremental dirty-row transfer, mode-aware Ghostty key encoding, scrollback, and selection.

## Target experience

The terminal surface must:

- display characters as the remote PTY echoes them, including input typed by the user;
- render 16-color, 256-color, and true-color output;
- maintain cursor position, shape, visibility, and blinking;
- handle wrapping, scrolling, erase operations, and alternate-screen programs;
- accept direct software-keyboard and hardware-keyboard input;
- preserve terminal state when Android redraws the View;
- resize both the local terminal model and remote PTY together;
- support touch scrolling, selection, copy, and paste;
- remain responsive under sustained output without blocking the main thread.

## Dependency decision

Use `libghostty-vt`, not the larger platform embedding API.

`libghostty-vt` supplies terminal parsing, screen state, styles, scrollback, input encoding, and incremental render state. It deliberately supplies no Android UI or GPU renderer. We will build the Android surface ourselves.

There is currently no official Android AAR or Maven package. The project will therefore:

1. Pin Ghostty to an exact upstream commit.
2. Build the C-compatible VT library with Zig for supported Android ABIs.
3. Package the resulting shared libraries in the APK.
4. Access the library through a small C++ JNI adapter.
5. Keep all upstream API usage inside the native adapter.

The pin must be updated intentionally. Upstream API changes must not leak into Kotlin call sites.

## High-level architecture

```text
Remote machine
    │ SSH PTY bytes
    ▼
SSHJ reader thread
    │
    ▼
TerminalSessionController
    │ serialized native calls
    ▼
JNI adapter
    │
    ▼
libghostty-vt terminal model
    │ dirty render state / snapshots
    ▼
TerminalView on Android main thread
    │
    ▼
Canvas renderer

Android IME / hardware key / touch action
    │
    ▼
Terminal input mapper and libghostty-vt encoder
    │ encoded bytes
    ▼
SSHJ writer
```

The SSH transport must never know how cells are rendered. The View must never write directly to an SSH stream. `TerminalSessionController` owns the relationship between them.

On Android, the active session controller is hosted by a bound `connectedDevice` foreground service. The service owns both the SSH transport and Ghostty terminal across activity stops and recreation. The activity attaches a listener while visible, renders a fresh snapshot on return, and never owns or closes the live native terminal. Explicit disconnect and the notification action stop the service; process death still ends the shell and is not presented as recoverable state.

## Repository layout

Planned structure:

```text
app/src/main/java/dev/ghostty/connect/terminal/
    TerminalSessionController.kt
    TerminalState.kt
    TerminalInput.kt
    TerminalClipboard.kt
    native/GhosttyTerminal.kt
    view/TerminalView.kt
    view/TerminalRenderer.kt
    view/TerminalMetrics.kt
    view/TerminalSelection.kt

app/src/main/cpp/
    CMakeLists.txt
    ghostty_jni.cpp
    ghostty_jni.h

app/src/main/jniLibs/
    arm64-v8a/libghostty-vt.so
    x86_64/libghostty-vt.so

third_party/ghostty/
    REVISION
    LICENSE
    patches/

scripts/
    build-libghostty-vt
    verify-native-libs
```

Generated native binaries should be reproducible from the pinned revision. Whether they are committed or produced in CI will be decided after measuring build time and artifact size.

## Supported ABIs

MVP support:

- `arm64-v8a` for physical Android devices;
- `x86_64` for emulator testing.

Do not initially support 32-bit ARM or x86. Native output must meet current Android alignment and 16 KB page-size requirements. CI should inspect every `.so` rather than assuming the Zig linker selected appropriate defaults.

## Native build pipeline

The build script will:

1. Verify the checked-out Ghostty revision against `third_party/ghostty/REVISION`.
2. Verify the expected Zig version.
3. Build `libghostty-vt` once for each ABI and Android API floor.
4. Disable features that introduce unnecessary platform dependencies.
5. Strip release artifacts while retaining separate debug symbols.
6. Copy libraries into ABI-specific `jniLibs` directories.
7. verify ELF architecture, exported symbols, page alignment, and absence of unexpected dependencies.

The Gradle build must fail with an actionable message when native artifacts are absent or stale.

## Kotlin-facing native API

Our Kotlin interface should remain small and stable even if Ghostty changes:

```kotlin
internal class GhosttyTerminal : AutoCloseable {
    fun write(bytes: ByteArray, offset: Int, length: Int): RenderUpdate
    fun resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int): RenderUpdate
    fun snapshot(viewport: Viewport): ScreenSnapshot
    fun encodeKey(event: TerminalKeyEvent): ByteArray
    fun encodeText(text: String): ByteArray
    fun encodePaste(text: String): ByteArray
    fun scroll(deltaRows: Int): RenderUpdate
    fun setSelection(selection: TerminalSelection?)
    fun selectedText(): String?
    override fun close()
}
```

Exact methods may be adjusted during the spike, but the following principles are fixed:

- Kotlin never stores a raw native pointer outside this class.
- Every native handle has explicit ownership and an idempotent `close()`.
- Calls after close fail safely.
- JNI validates array ranges and enum values.
- Native failures become typed Kotlin errors, not process aborts.
- No private terminal content is written to logs.

## Threading and ownership

The Ghostty terminal instance will have one logical owner. All mutations are serialized on a dedicated terminal executor:

- SSH reader submits output bytes.
- input events request encoded bytes.
- resize events submit new dimensions.
- scroll and selection events submit viewport changes.

The main thread only consumes immutable render snapshots. It never reads mutable native memory.

Render updates should be conflated: when output arrives faster than the display refresh rate, retain the newest terminal state rather than queueing one redraw for every SSH packet.

Lifecycle rules:

- Create the terminal model before requesting the remote shell.
- Close the SSH channel before destroying its terminal model.
- Rotation may recreate the View without recreating the active model.
- Disconnect freezes the final screen until the user leaves or reconnects.
- Backgrounding stops frame production but may continue accepting bytes while the connection is allowed to live.

## Terminal size and SSH PTY coordination

Terminal dimensions derive from the actual content area and font metrics:

```text
columns = floor(contentWidth / cellWidth)
rows    = floor(contentHeight / cellHeight)
```

Insets, the extra-key row, and any toolbar are excluded from the content area.

On the first non-zero layout:

1. Calculate rows, columns, and pixel dimensions.
2. Create or resize the Ghostty model.
3. Request the SSH PTY with the same character and pixel dimensions.
4. Start the interactive shell.

On later size changes:

1. Debounce rapid layout changes from rotation or keyboard animation.
2. Resize Ghostty first so new output uses the correct grid.
3. Send the matching SSH PTY window-change request.
4. Invalidate the whole View because line reflow may affect every row.

Never report a zero-row or zero-column PTY.

## Render snapshot model

The JNI layer should expose only data needed to draw the visible viewport:

```text
ScreenSnapshot
    generation
    columns, rows
    viewportOffset
    dirtyRows
    cursor
    cells[]

Cell
    codepoint or grapheme reference
    foreground color
    background color
    style flags
    display width
```

The spike must evaluate two transfer strategies:

1. Copy dirty rows into reusable direct buffers.
2. Copy a compact immutable snapshot into Kotlin-owned arrays.

The selected strategy must not expose native memory beyond the terminal executor and must avoid per-cell object allocation. A packed direct buffer is the preferred starting point.

## Canvas renderer

The first production renderer will be an Android custom `View` using `Canvas` and reusable `Paint` objects.

Drawing order per dirty row:

1. Coalesce adjacent cells with the same background and draw background runs.
2. Shape and draw foreground glyph runs.
3. Draw underline, strike-through, and other decorations.
4. Draw selection overlay.
5. Draw the cursor last.

Avoid allocating strings, paints, paths, or rectangles inside `onDraw`. Cache glyph runs and reuse buffers where practical.

Initial style support:

- default, indexed, and RGB foreground/background colors;
- bold, faint, italic, underline, strike-through, and inverse;
- hidden text;
- block, beam, and underline cursors;
- cursor visibility and blink state.

Font configuration:

- bundle one known-good monospace font for deterministic layout;
- use one font size across a grid;
- derive baseline, ascent, descent, and cell width once per configuration;
- support fallback glyphs without changing cell geometry;
- respect wide and combining-cell information from Ghostty rather than guessing from Java string length.

## Frame scheduling

Terminal output can arrive at thousands of chunks per second. Rendering every chunk would waste battery and block interaction.

Use this policy:

- native writes update state immediately on the terminal executor;
- mark the affected rows dirty;
- schedule at most one callback for the next display frame;
- consume the newest dirty snapshot during that callback;
- request another frame only if updates arrived while drawing.

Cursor blinking is a separate low-frequency invalidation and pauses when the app is not visible.

## Software keyboard and IME

`TerminalView` will be focusable and implement an `InputConnection`. The separate command input field will be removed.

IME behavior:

- committed text is encoded and sent immediately;
- composing text is displayed as an Android overlay until committed, not inserted into remote terminal state prematurely;
- deletion maps to the configured terminal backspace sequence;
- Enter sends carriage return;
- extracted/full-screen editor mode is disabled;
- autocorrect, capitalization, and personalized learning are disabled by default for terminal input;
- paste uses Ghostty's paste-safety and bracketed-paste behavior.

The terminal does not locally echo committed characters. Visibility comes from remote PTY echo. This prevents duplicate characters and respects applications that disable echo, such as password prompts.

## Hardware and extra-key input

Normalize Android events into `TerminalKeyEvent` before encoding:

```text
key: character or named terminal key
modifiers: Shift, Alt, Control, Meta
action: press, repeat, release where supported
```

Ghostty's current terminal modes determine the encoded sequence. This is important for application cursor mode, function keys, and modern keyboard protocols.

The existing extra-key row becomes another producer of the same normalized events. It must not contain hard-coded escape strings once the Ghostty encoder is active.

Minimum key coverage:

- Escape, Tab, Enter, Backspace, Delete;
- arrows, Home, End, Page Up, Page Down, Insert;
- Control A–Z and common punctuation combinations;
- Alt-modified characters;
- F1–F12;
- key repeat;
- external keyboard shortcuts for copy and paste.

## Touch, scrollback, and selection

Gesture priority:

1. Two-finger pinch to resize terminal text and the remote PTY grid.
2. Active selection handles.
3. Mouse-reporting mode when enabled by the remote application.
4. Scrollback navigation.
5. Tap to focus and show the keyboard.

MVP scroll behavior:

- vertical drag moves through Ghostty's scrollback;
- drag distance accumulates at sub-row precision and flings decelerate naturally;
- new output follows the bottom only when already at the bottom;
- a visible `Live` affordance returns to current output;
- typing returns to live output so the active prompt remains above the resized keyboard;
- the Android window resizes for the IME, preserving system swipe/back keyboard dismissal;
- resize preserves a sensible viewport anchor through reflow.
- pinch zoom scales from 9sp to 30sp and keeps glyph and cell metrics synchronized.

Selection behavior:

- long press begins cell-based selection;
- drag handles expand by grapheme-aware terminal coordinates;
- Copy reads selected text through the terminal model;
- selection clears on normal typing unless the user is browsing scrollback;
- clipboard operations follow the app's sensitive-clipboard policy.

## Color and theme handling

Ghostty resolves terminal styles against a terminal palette. The Android layer supplies theme defaults for:

- foreground and background;
- cursor and cursor text;
- selection background and text;
- ANSI colors 0–15;
- optional minimum contrast adjustment.

Application-provided indexed and true colors remain intact. Switching the app theme invalidates the whole viewport without resetting terminal contents.

## Accessibility

Canvas-drawn cells are not automatically visible to accessibility services. The terminal View must provide:

- a content description summarizing connection state;
- an accessibility action to read visible terminal text;
- copy/select actions where feasible;
- announcements for connection failures and host-key prompts;
- scalable font size and adequate extra-key touch targets.

Fine-grained virtual accessibility nodes for every cell are explicitly not required for the first rendering milestone; they would be expensive and difficult to navigate meaningfully.

## Failure handling

Native initialization failure must produce a clear terminal-unavailable screen, not fall back silently to a view that claims full compatibility.

Handle these cases explicitly:

- unsupported ABI or missing `.so`;
- JNI/API revision mismatch;
- native allocation failure;
- invalid UTF-8 or malformed escape sequences;
- SSH output arriving after terminal closure;
- renderer exception or lost View surface;
- resize while disconnected;
- native crash captured by release diagnostics without terminal contents.

The plain-text decoder may remain available only as an internal diagnostic mode during development. It is not the release fallback.

## Testing strategy

### Native conformance tests

Feed recorded byte streams into `libghostty-vt` and assert stable screen snapshots for:

- plain text, wrapping, carriage return, backspace, and tabs;
- SGR styles and 16/256/true-color output;
- OSC title and shell-integration sequences;
- cursor addressing, insertion, deletion, and erase operations;
- alternate-screen entry and exit;
- combining marks, emoji, and double-width characters;
- malformed and packet-split escape sequences;
- resize and reflow with scrollback.

### Android renderer tests

- screenshot tests for representative grids and cursor styles;
- font metrics across supported densities and font scales;
- dirty-row updates do not alter clean rows;
- rotation and software-keyboard appearance send correct sizes;
- selection and scroll gestures map to expected terminal coordinates;
- IME commit, composition, delete, Enter, and paste behavior;
- hardware-key events and modifiers.

### SSH integration tests

Run an isolated test SSH server with deterministic credentials and scripts that emit fixtures. Verify:

- successful host verification and authentication;
- typed text appears once when echo is enabled and never when disabled;
- `printf` color fixtures match expected screenshots;
- `vim`, `less`, and `top` enter and leave alternate screen correctly;
- `stty size` matches the displayed grid before and after rotation;
- sustained output does not freeze input;
- disconnect retains the last coherent frame.

### Performance gates

Measure on a representative physical arm64 device:

- time from receiving SSH bytes to visible frame;
- main-thread time per frame;
- dropped frames during sustained output;
- allocations per frame;
- memory use for configured scrollback;
- native write throughput;
- idle and active battery impact.

Initial targets are no per-cell Kotlin allocations during drawing, no main-thread terminal parsing, and smooth interaction at the device refresh rate under ordinary shell output. Numeric budgets will be fixed after the rendering spike establishes a baseline.

## Delivery sequence

### R0 — Recorded-stream native spike

- Pin Ghostty and build `libghostty-vt` for `arm64-v8a` and `x86_64`.
- Create and destroy a native terminal through JNI.
- Feed a recorded ANSI fixture.
- Return a visible grid containing colors, styles, and cursor state.

Exit criteria: the emulator displays a deterministic colored terminal fixture without SSH.

Status: complete on the Android 15/API 35 x86_64 emulator. The same native revision is built for arm64-v8a.

### R1 — Live read-only terminal

- Feed live SSH output into Ghostty.
- Render dirty rows with Canvas.
- Couple initial and subsequent PTY sizes.
- Support cursor, wrapping, erase operations, alternate screen, and color.

Exit criteria: shell prompts plus read-only `top` and colored command output render correctly.

Status: in progress. Live SSH bytes, Canvas rendering, and PTY resizing are connected; full-screen application fixtures remain to be verified.

### R2 — Direct terminal input

- Implement `InputConnection`.
- Route software, hardware, and extra-key events through the Ghostty encoder.
- Remove the separate command field and hard-coded key sequences.
- Implement bracketed paste.

Exit criteria: interactive shell editing, password prompts, Vim navigation, and modifier keys behave correctly.

Status: in progress. Direct IME commit, deletion, hardware keys, control letters, and extra keys are connected. Mode-aware Ghostty key encoding and IME composition polish remain.

### R3 — Scrollback and selection

- Add touch scrollback, viewport anchoring, selection, copy, and paste.
- Add font-size changes and theme palette configuration.
- Preserve model state across View recreation.

Exit criteria: users can navigate and copy long output without interrupting the remote process.

### R4 — Hardening

- Complete automated fixtures and screenshot coverage.
- Profile and optimize render-state transfer and drawing.
- Verify native binaries, release symbols, lifecycle behavior, and accessibility baseline.
- Remove the plain-text renderer from production builds.

Exit criteria: terminal acceptance criteria pass on emulator and representative physical Android devices.

## Definition of done

Ghostty rendering is complete for the MVP when:

- no raw ANSI, CSI, OSC, or shell-integration metadata is displayed;
- typed characters appear exactly once when the remote PTY has echo enabled;
- colors, cursor movement, wrapping, erasing, and alternate screens are correct;
- Vim, `less`, and `top` are usable with touch and hardware keyboards;
- terminal and remote PTY dimensions remain synchronized through rotation and font changes;
- scrollback, selection, copy, and bracketed paste work;
- terminal parsing and SSH I/O do not run on the Android main thread;
- native resources close cleanly across disconnects and Activity recreation;
- arm64 and x86_64 native artifacts pass build verification;
- automated conformance, renderer, and SSH integration tests pass.

## Decisions intentionally deferred

The following implementation choices do not change MVP scope and will be decided using spike measurements:

- packed direct buffers versus copied primitive arrays for snapshots;
- bundled font choice and fallback strategy;
- exact scrollback default and maximum;
- Canvas text drawing versus a later GPU renderer;
- whether generated native artifacts are committed or built only in CI;
- exact handling of advanced image protocols beyond ensuring they fail safely.
