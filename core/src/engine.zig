//! Terminal engine: the only code that calls libghostty-vt's C API. Shared by
//! the iOS and Android apps (ADR 0012).
//!
//! An `Engine` owns one libghostty terminal plus the encoders, render state and
//! queued effects around it. All methods take the engine lock themselves, so
//! the bindings may call them from different threads. Output that is larger
//! than a scalar is returned as caller-owned byte slices (allocated with
//! `gpa`) so no returned pointer is ever shared between calls.

const std = @import("std");
const c = @import("ghostty_c");
const keys = @import("keys.zig");
const render = @import("render.zig");
const selection = @import("selection.zig");

pub const gpa = std.heap.smp_allocator;

pub const Error = error{
    /// An argument was out of range.
    InvalidArgument,
    OutOfMemory,
    /// libghostty-vt reported a failure.
    Engine,
    /// Output exceeded the engine's size limit.
    TooLarge,
};

pub const max_snapshot_bytes = 32 * 1024 * 1024;
pub const kitty_storage_limit: u64 = 32 * 1024 * 1024;
pub const kitty_apc_limit: usize = 8 * 1024 * 1024;
pub const default_scrollback_lines: usize = 10_000;

const max_pending_clipboard = 8;
const max_pending_notifications = 8;
const max_clipboard_bytes = 1024 * 1024;
const max_notification_title_bytes = 256;
const max_notification_body_bytes = 4096;
const max_pty_write_bytes = 64 * 1024;
const max_pending_bells = 10;
const max_unknown_sequences = 100;

pub fn check(result: c.GhosttyResult) Error!void {
    if (result != c.GHOSTTY_SUCCESS) return Error.Engine;
}

/// Tiny spin lock with yielding. Critical sections are short and rarely
/// contended, and this keeps the core free of OS threading primitives.
const Lock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(self: *Lock) void {
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *Lock) void {
        self.held.store(false, .release);
    }
};

pub const ClipboardWrite = struct {
    /// Null clears the clipboard.
    text: ?[]u8,
};

pub const Notification = struct {
    title: []u8,
    body: []u8,
};

/// Effects the terminal asked the host to perform. Drained by the bindings.
pub const Effects = struct {
    bells: i32 = 0,
    progress_state: i32 = -1,
    progress_value: i32 = -1,
    unknown_sequences: i32 = 0,
    pty_write: std.ArrayList(u8) = .empty,
    clipboard: std.ArrayList(ClipboardWrite) = .empty,
    notifications: std.ArrayList(Notification) = .empty,

    fn deinit(self: *Effects) void {
        self.clear();
        self.pty_write.deinit(gpa);
        self.clipboard.deinit(gpa);
        self.notifications.deinit(gpa);
    }

    fn clear(self: *Effects) void {
        self.bells = 0;
        self.progress_state = -1;
        self.progress_value = -1;
        self.unknown_sequences = 0;
        self.pty_write.clearRetainingCapacity();
        for (self.clipboard.items) |write| if (write.text) |text| gpa.free(text);
        self.clipboard.clearRetainingCapacity();
        for (self.notifications.items) |note| {
            gpa.free(note.title);
            gpa.free(note.body);
        }
        self.notifications.clearRetainingCapacity();
    }
};

pub const Config = struct {
    cols: u16,
    rows: u16,
    /// 0xRRGGBB colors; applied only when `colors` is set.
    colors: bool = false,
    foreground: u32 = 0,
    background: u32 = 0,
    cursor: u32 = 0,
    /// 256 palette entries as 0xRRGGBB, or null to keep libghostty's palette.
    palette: ?*const [256]u32 = null,
    scrollback_lines: usize = default_scrollback_lines,
};

pub const Engine = struct {
    mutex: Lock = .{},
    terminal: c.GhosttyTerminal = null,
    key_encoder: c.GhosttyKeyEncoder = null,
    key_event: c.GhosttyKeyEvent = null,
    mouse_encoder: c.GhosttyMouseEncoder = null,
    mouse_event: c.GhosttyMouseEvent = null,
    render_state: c.GhosttyRenderState = null,
    rows: c.GhosttyRenderStateRowIterator = null,
    cells: c.GhosttyRenderStateRowCells = null,
    kitty_placements: c.GhosttyKittyGraphicsPlacementIterator = null,
    first_snapshot: bool = true,
    effects: Effects = .{},
    search: selection.SearchState = .{},

    /// Creates a terminal with its own colors and scrollback.
    pub fn create(config: Config) Error!*Engine {
        if (config.cols == 0 or config.rows == 0) return Error.InvalidArgument;
        const self = try gpa.create(Engine);
        self.* = .{};
        errdefer self.destroy();
        try check(c.ghostty_terminal_new(null, &self.terminal, config.cols, config.rows));
        try self.configureTerminal();
        try self.configureColors(config);
        var scrollback = config.scrollback_lines;
        try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollback));
        try self.createHelpers();
        return self;
    }

    /// Restores a terminal from `encodeState()` output.
    pub fn restore(data: []const u8) Error!*Engine {
        if (data.len == 0 or data.len > max_snapshot_bytes) return Error.InvalidArgument;
        const self = try gpa.create(Engine);
        self.* = .{};
        errdefer self.destroy();
        var decoder: c.GhosttySnapshotDecoder = null;
        try check(c.ghostty_snapshot_decoder_new_buf(null, &decoder, data.ptr, data.len));
        const result = c.ghostty_snapshot_decoder_decode(decoder, &self.terminal);
        c.ghostty_snapshot_decoder_free(decoder);
        try check(result);
        try self.configureTerminal();
        try self.createHelpers();
        return self;
    }

    pub fn destroy(self: *Engine) void {
        c.ghostty_key_event_free(self.key_event);
        c.ghostty_key_encoder_free(self.key_encoder);
        c.ghostty_mouse_event_free(self.mouse_event);
        c.ghostty_mouse_encoder_free(self.mouse_encoder);
        c.ghostty_render_state_row_cells_free(self.cells);
        c.ghostty_kitty_graphics_placement_iterator_free(self.kitty_placements);
        c.ghostty_render_state_row_iterator_free(self.rows);
        c.ghostty_render_state_free(self.render_state);
        c.ghostty_terminal_free(self.terminal);
        self.effects.deinit();
        self.search.deinit();
        gpa.destroy(self);
    }

    fn configureTerminal(self: *Engine) Error!void {
        const t = self.terminal;
        var storage_limit = kitty_storage_limit;
        var apc_limit = kitty_apc_limit;
        var unknown_limit: usize = 256;
        var continuation_limit = kitty_apc_limit;
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &storage_limit));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES_KITTY, &apc_limit));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_USERDATA, self));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_BELL, @ptrCast(&onBell)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(&onWritePty)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, @ptrCast(&onClipboard)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, @ptrCast(&onNotification)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, @ptrCast(&onProgress)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE, @ptrCast(&onUnknownSequence)));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES, &unknown_limit));
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation_limit));
        const terminfo: c.GhosttyString = .{ .ptr = "xterm-256color", .len = "xterm-256color".len };
        try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &terminfo));
    }

    fn configureColors(self: *Engine, config: Config) Error!void {
        const t = self.terminal;
        if (config.colors) {
            const foreground = rgb(config.foreground);
            const background = rgb(config.background);
            const cursor = rgb(config.cursor);
            try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground));
            try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background));
            try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor));
        }
        if (config.palette) |colors| {
            var palette: [256]c.GhosttyColorRgb = undefined;
            for (colors, &palette) |value, *slot| slot.* = rgb(value);
            try check(c.ghostty_terminal_set(t, c.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette));
        }
    }

    fn createHelpers(self: *Engine) Error!void {
        try check(c.ghostty_key_encoder_new(null, &self.key_encoder));
        try check(c.ghostty_key_event_new(null, &self.key_event));
        try check(c.ghostty_mouse_encoder_new(null, &self.mouse_encoder));
        try check(c.ghostty_mouse_event_new(null, &self.mouse_event));
        try check(c.ghostty_render_state_new(null, &self.render_state));
        try check(c.ghostty_render_state_row_iterator_new(null, &self.rows));
        try check(c.ghostty_render_state_row_cells_new(null, &self.cells));
        try check(c.ghostty_kitty_graphics_placement_iterator_new(null, &self.kitty_placements));
    }

    pub fn lock(self: *Engine) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *Engine) void {
        self.mutex.unlock();
    }

    // MARK: Output and size

    pub fn feed(self: *Engine, bytes: []const u8) void {
        self.lock();
        defer self.unlock();
        self.search.reset();
        c.ghostty_terminal_vt_write(self.terminal, bytes.ptr, bytes.len);
    }

    pub fn resize(self: *Engine, cols: u16, rows: u16, cell_width: u32, cell_height: u32) Error!void {
        if (cols == 0 or rows == 0) return Error.InvalidArgument;
        self.lock();
        defer self.unlock();
        try check(c.ghostty_terminal_resize(self.terminal, cols, rows, cell_width, cell_height));
    }

    pub fn scrollRows(self: *Engine, delta: i32) void {
        self.lock();
        defer self.unlock();
        const behavior: c.GhosttyTerminalScrollViewport = .{
            .tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA,
            .value = .{ .delta = delta },
        };
        _ = c.ghostty_terminal_scroll_viewport(self.terminal, behavior);
    }

    pub fn scrollToBottom(self: *Engine) void {
        self.lock();
        defer self.unlock();
        const behavior: c.GhosttyTerminalScrollViewport = .{ .tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM };
        _ = c.ghostty_terminal_scroll_viewport(self.terminal, behavior);
    }

    /// libghostty-vt's own saved-state encoding of the terminal.
    pub fn encodeState(self: *Engine) Error![]u8 {
        self.lock();
        defer self.unlock();
        var bytes: ?[*]u8 = null;
        var length: usize = 0;
        try check(c.ghostty_snapshot_encode_alloc(self.terminal, null, @ptrCast(&bytes), &length));
        defer c.ghostty_free(null, bytes, length);
        if (length > max_snapshot_bytes) return Error.TooLarge;
        return gpa.dupe(u8, (bytes orelse return Error.Engine)[0..length]);
    }

    // MARK: Effects

    /// Wire format (little-endian int32 unless noted):
    ///   bells, progress_state (-1 none), progress_value (-1 none),
    ///   unknown_sequences, processing_error (0/1),
    ///   pty_write (length + bytes),
    ///   clipboard_count, then per write: kind (0 clear, 1 text) + text (length + bytes),
    ///   notification_count, then per notification: title + body (length + bytes each).
    pub fn drainEffects(self: *Engine) Error![]u8 {
        self.lock();
        defer self.unlock();
        var processing_error = false;
        try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR, &processing_error));
        const effects = &self.effects;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try putI32(&out, effects.bells);
        try putI32(&out, effects.progress_state);
        try putI32(&out, effects.progress_value);
        try putI32(&out, effects.unknown_sequences);
        try putI32(&out, @intFromBool(processing_error));
        try putBytes(&out, effects.pty_write.items);
        try putI32(&out, @intCast(effects.clipboard.items.len));
        for (effects.clipboard.items) |write| {
            try putI32(&out, if (write.text != null) 1 else 0);
            try putBytes(&out, write.text orelse "");
        }
        try putI32(&out, @intCast(effects.notifications.items.len));
        for (effects.notifications.items) |note| {
            try putBytes(&out, note.title);
            try putBytes(&out, note.body);
        }
        effects.clear();
        return out.toOwnedSlice(gpa);
    }

    fn fromUserdata(userdata: ?*anyopaque) *Engine {
        return @ptrCast(@alignCast(userdata.?));
    }

    fn onBell(_: c.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
        const self = fromUserdata(userdata);
        self.effects.bells = @min(self.effects.bells + 1, max_pending_bells);
    }

    fn onWritePty(_: c.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
        const self = fromUserdata(userdata);
        if (len == 0 or data == null) return;
        const queue = &self.effects.pty_write;
        if (len > max_pty_write_bytes - queue.items.len) return;
        queue.appendSlice(gpa, data[0..len]) catch {};
    }

    fn onUnknownSequence(_: c.GhosttyTerminal, userdata: ?*anyopaque, _: [*c]const c.GhosttyTerminalUnknownSequence) callconv(.c) void {
        const self = fromUserdata(userdata);
        self.effects.unknown_sequences = @min(self.effects.unknown_sequences + 1, max_unknown_sequences);
    }

    fn onProgress(_: c.GhosttyTerminal, userdata: ?*anyopaque, report: [*c]const c.GhosttyTerminalProgressReport) callconv(.c) void {
        const self = fromUserdata(userdata);
        if (report.*.state > c.GHOSTTY_TERMINAL_PROGRESS_STATE_PAUSE) return;
        self.effects.progress_state = @intCast(report.*.state);
        const value: i32 = report.*.progress;
        self.effects.progress_value = if (value >= 0 and value <= 100) value else -1;
    }

    fn onNotification(_: c.GhosttyTerminal, userdata: ?*anyopaque, note: [*c]const c.GhosttyTerminalDesktopNotification) callconv(.c) void {
        const self = fromUserdata(userdata);
        const title = stringSlice(note.*.title);
        const body = stringSlice(note.*.body);
        if (title.len > max_notification_title_bytes or body.len > max_notification_body_bytes) return;
        if (!std.unicode.utf8ValidateSlice(title) or !std.unicode.utf8ValidateSlice(body)) return;
        const queue = &self.effects.notifications;
        if (queue.items.len >= max_pending_notifications) return;
        const owned_title = gpa.dupe(u8, title) catch return;
        const owned_body = gpa.dupe(u8, body) catch {
            gpa.free(owned_title);
            return;
        };
        queue.append(gpa, .{ .title = owned_title, .body = owned_body }) catch {
            gpa.free(owned_title);
            gpa.free(owned_body);
        };
    }

    fn onClipboard(_: c.GhosttyTerminal, userdata: ?*anyopaque, write: [*c]const c.GhosttyClipboardWrite) callconv(.c) void {
        const self = fromUserdata(userdata);
        var reply: c.GhosttyClipboardWriteReply = .{ .size = @sizeOf(c.GhosttyClipboardWriteReply) };
        reply.result = self.captureClipboard(write.*);
        write.*.reply.?(write, &reply);
    }

    fn captureClipboard(self: *Engine, write: c.GhosttyClipboardWrite) c.GhosttyClipboardWriteResult {
        if (write.location != c.GHOSTTY_CLIPBOARD_LOCATION_STANDARD) return c.GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED;
        const queue = &self.effects.clipboard;
        if (write.contents_len == 0) {
            if (queue.items.len >= max_pending_clipboard) return c.GHOSTTY_CLIPBOARD_WRITE_RESULT_BUSY;
            queue.append(gpa, .{ .text = null }) catch return c.GHOSTTY_CLIPBOARD_WRITE_RESULT_IO_ERROR;
            return c.GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
        }
        if (write.contents == null) return c.GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA;
        for (write.contents[0..write.contents_len]) |content| {
            const mime = stringSlice(content.mime);
            if (!std.mem.eql(u8, mime, "text/plain") and !std.mem.eql(u8, mime, "text/plain;charset=utf-8")) continue;
            const data = stringSlice(content.data);
            if (data.len > max_clipboard_bytes or !std.unicode.utf8ValidateSlice(data)) {
                return c.GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA;
            }
            if (queue.items.len >= max_pending_clipboard) return c.GHOSTTY_CLIPBOARD_WRITE_RESULT_BUSY;
            const owned = gpa.dupe(u8, data) catch return c.GHOSTTY_CLIPBOARD_WRITE_RESULT_IO_ERROR;
            queue.append(gpa, .{ .text = owned }) catch {
                gpa.free(owned);
                return c.GHOSTTY_CLIPBOARD_WRITE_RESULT_IO_ERROR;
            };
            return c.GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
        }
        return c.GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED;
    }

    // MARK: Input encoding

    pub fn isMouseTracking(self: *Engine) Error!bool {
        self.lock();
        defer self.unlock();
        var tracking = false;
        try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking));
        return tracking;
    }

    /// Empty unless the application enabled focus reporting (DEC 1004).
    pub fn encodeFocus(self: *Engine, focused: bool) Error![]u8 {
        self.lock();
        defer self.unlock();
        if (!try self.modeEnabled(c.ghostty_mode_new(1004, false))) return &.{};
        var buffer: [8]u8 = undefined;
        var written: usize = 0;
        try check(c.ghostty_focus_encode(
            if (focused) c.GHOSTTY_FOCUS_GAINED else c.GHOSTTY_FOCUS_LOST,
            &buffer,
            buffer.len,
            &written,
        ));
        return gpa.dupe(u8, buffer[0..written]);
    }

    pub const MouseInput = struct {
        action: u32,
        button: u32,
        x: f32,
        y: f32,
        modifiers: u32,
        width: u32,
        height: u32,
        cell_width: u32,
        cell_height: u32,
        any_pressed: bool,
    };

    pub fn encodeMouse(self: *Engine, input: MouseInput) Error![]u8 {
        self.lock();
        defer self.unlock();
        return self.encodeMouseLocked(input);
    }

    fn encodeMouseLocked(self: *Engine, input: MouseInput) Error![]u8 {
        _ = c.ghostty_mouse_encoder_set_from_terminal(self.mouse_encoder, self.terminal);
        var size: c.GhosttyMouseEncoderSize = .{
            .size = @sizeOf(c.GhosttyMouseEncoderSize),
            .screen_width = input.width,
            .screen_height = input.height,
            .cell_width = input.cell_width,
            .cell_height = input.cell_height,
        };
        var pressed = input.any_pressed;
        var track_last_cell = true;
        _ = c.ghostty_mouse_encoder_set(self.mouse_encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
        _ = c.ghostty_mouse_encoder_set(self.mouse_encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);
        _ = c.ghostty_mouse_encoder_set(self.mouse_encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &track_last_cell);
        _ = c.ghostty_mouse_event_set_action(self.mouse_event, input.action);
        _ = c.ghostty_mouse_event_set_button(self.mouse_event, input.button);
        _ = c.ghostty_mouse_event_set_mods(self.mouse_event, @intCast(input.modifiers));
        _ = c.ghostty_mouse_event_set_position(self.mouse_event, .{ .x = input.x, .y = input.y });
        var buffer: [128]u8 = undefined;
        var written: usize = 0;
        try check(c.ghostty_mouse_encoder_encode(self.mouse_encoder, self.mouse_event, &buffer, buffer.len, &written));
        return gpa.dupe(u8, buffer[0..written]);
    }

    /// Turns a scroll gesture into terminal input, or returns an empty slice
    /// when the app should scroll its local scrollback instead.
    ///
    /// `rows` is positive for content moving down (towards newer output).
    ///   - Mouse tracking on: that many wheel button 4/5 events, encoded by the
    ///     mouse encoder for the active tracking format.
    ///   - Alternate screen with alternate-scroll mode (DEC 1007) and no mouse
    ///     tracking: that many Down/Up arrow key presses.
    ///   - Otherwise: nothing.
    /// The count is capped at 10 per call.
    pub fn encodeScroll(self: *Engine, rows: i32) Error![]u8 {
        if (rows == 0) return &.{};
        const count: usize = @min(@abs(rows), 10);
        const down = rows > 0;

        self.lock();
        defer self.unlock();
        var tracking = false;
        var screen: c.GhosttyTerminalScreen = c.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        var cols: u16 = 0;
        var term_rows: u16 = 0;
        try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking));
        try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen));
        try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_COLS, &cols));
        try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_ROWS, &term_rows));

        var single: []u8 = &.{};
        if (tracking and cols > 0 and term_rows > 0) {
            // The wheel event is reported at the center of a nominal 10x20 cell grid.
            single = try self.encodeMouseLocked(.{
                .action = c.GHOSTTY_MOUSE_ACTION_PRESS,
                .button = if (down) c.GHOSTTY_MOUSE_BUTTON_FIVE else c.GHOSTTY_MOUSE_BUTTON_FOUR,
                .x = @as(f32, @floatFromInt(cols)) * 5,
                .y = @as(f32, @floatFromInt(term_rows)) * 10,
                .modifiers = 0,
                .width = @as(u32, cols) * 10,
                .height = @as(u32, term_rows) * 20,
                .cell_width = 10,
                .cell_height = 20,
                .any_pressed = false,
            });
        } else if (screen == c.GHOSTTY_TERMINAL_SCREEN_ALTERNATE and
            try self.modeEnabled(c.ghostty_mode_new(1007, false)))
        {
            single = try self.encodeKeyLocked(if (down) "ARROW_DOWN" else "ARROW_UP", "", 0, c.GHOSTTY_KEY_ACTION_PRESS);
        } else return &.{};
        defer if (single.len > 0) gpa.free(single);
        if (single.len == 0) return &.{};

        const out = try gpa.alloc(u8, single.len * count);
        for (0..count) |index| @memcpy(out[index * single.len ..][0..single.len], single);
        return out;
    }

    pub fn encodeKey(self: *Engine, name: []const u8, text: []const u8, modifiers: u32, action: u32) Error![]u8 {
        self.lock();
        defer self.unlock();
        return self.encodeKeyLocked(name, text, modifiers, action);
    }

    fn encodeKeyLocked(self: *Engine, name: []const u8, text: []const u8, modifiers: u32, action: u32) Error![]u8 {
        _ = c.ghostty_key_encoder_set_from_terminal(self.key_encoder, self.terminal);
        _ = c.ghostty_key_event_set_action(self.key_event, action);
        _ = c.ghostty_key_event_set_key(self.key_event, keys.fromName(name));
        _ = c.ghostty_key_event_set_mods(self.key_event, @intCast(modifiers));
        _ = c.ghostty_key_event_set_consumed_mods(self.key_event, 0);
        _ = c.ghostty_key_event_set_composing(self.key_event, false);
        _ = c.ghostty_key_event_set_unshifted_codepoint(self.key_event, keys.unshiftedCodepoint(name));
        _ = c.ghostty_key_event_set_utf8(self.key_event, .{ .ptr = text.ptr, .len = text.len });
        var buffer: [128]u8 = undefined;
        var written: usize = 0;
        const result = c.ghostty_key_encoder_encode(self.key_encoder, self.key_event, &buffer, buffer.len, &written);
        if (result == c.GHOSTTY_OUT_OF_SPACE) {
            const dynamic = try gpa.alloc(u8, written);
            errdefer gpa.free(dynamic);
            try check(c.ghostty_key_encoder_encode(self.key_encoder, self.key_event, dynamic.ptr, dynamic.len, &written));
            return dynamic[0..written];
        }
        try check(result);
        return gpa.dupe(u8, buffer[0..written]);
    }

    pub fn encodePaste(self: *Engine, text: []const u8) Error![]u8 {
        self.lock();
        defer self.unlock();
        const bracketed = try self.modeEnabled(c.ghostty_mode_new(2004, false));
        // libghostty sanitizes in place, so give it a copy with room for the brackets.
        const out = try gpa.alloc(u8, text.len + if (bracketed) @as(usize, 12) else 0);
        errdefer gpa.free(out);
        const input = try gpa.dupe(u8, text);
        defer gpa.free(input);
        var written: usize = 0;
        try check(c.ghostty_paste_encode(input.ptr, input.len, bracketed, out.ptr, out.len, &written));
        return gpa.realloc(out, written) catch out[0..written];
    }

    fn modeEnabled(self: *Engine, mode: c.GhosttyMode) Error!bool {
        var config: c.GhosttyTerminalModeConfig = .{ .mode = mode, .value = false };
        try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_MODE, &config));
        return config.value;
    }
};

pub fn isPasteSafe(text: []const u8) bool {
    return c.ghostty_paste_is_safe(text.ptr, text.len);
}

pub fn rgb(value: u32) c.GhosttyColorRgb {
    return .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) };
}

pub fn stringSlice(value: c.GhosttyString) []const u8 {
    if (value.ptr == null or value.len == 0) return &.{};
    return value.ptr[0..value.len];
}

pub fn putI32(out: *std.ArrayList(u8), value: i32) Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}

pub fn putI64(out: *std.ArrayList(u8), value: u64) Error!void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}

pub fn putBytes(out: *std.ArrayList(u8), value: []const u8) Error!void {
    try putI32(out, @intCast(value.len));
    try out.appendSlice(gpa, value);
}

pub fn argb(color: c.GhosttyColorRgb) i32 {
    return @bitCast(0xff000000 | (@as(u32, color.r) << 16) | (@as(u32, color.g) << 8) | color.b);
}

test {
    _ = keys;
    _ = render;
    _ = selection;
}

test "feeds output and reports effects" {
    const engine = try Engine.create(.{ .cols = 20, .rows = 4 });
    defer engine.destroy();
    engine.feed("hello \x1b[31mworld\x1b[0m\x07");
    const drained = try engine.drainEffects();
    defer gpa.free(drained);
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, drained[0..4], .little));
    const again = try engine.drainEffects();
    defer gpa.free(again);
    try std.testing.expectEqual(@as(i32, 0), std.mem.readInt(i32, again[0..4], .little));
}
