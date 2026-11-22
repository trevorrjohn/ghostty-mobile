//! C ABI of the terminal engine (see include/seance_core.h for the contract).

const std = @import("std");
const engine_mod = @import("engine.zig");
const render = @import("render.zig");
const selection = @import("selection.zig");

const Engine = engine_mod.Engine;
const gpa = engine_mod.gpa;

pub const ScStatus = enum(i32) {
    ok = 0,
    invalid_argument = -1,
    out_of_memory = -2,
    engine = -3,
    too_large = -4,
};

pub const ScBytes = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,
};

pub const ScEngineConfig = extern struct {
    size: usize,
    cols: u16,
    rows: u16,
    has_colors: bool,
    foreground: u32,
    background: u32,
    cursor: u32,
    palette: ?*const [256]u32,
    scrollback_lines: u32,
};

pub const ScMouseInput = extern struct {
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

fn status(err: engine_mod.Error) i32 {
    return @intFromEnum(switch (err) {
        error.InvalidArgument => ScStatus.invalid_argument,
        error.OutOfMemory => ScStatus.out_of_memory,
        error.Engine => ScStatus.engine,
        error.TooLarge => ScStatus.too_large,
    });
}

const ok: i32 = 0;

fn slice(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (len == 0) return &.{};
    return (ptr orelse return null)[0..len];
}

/// Hands an owned slice to the caller. Empty slices are never allocated.
fn deliver(out: *ScBytes, bytes: []u8) i32 {
    if (bytes.len == 0) {
        out.* = .{};
    } else {
        out.* = .{ .ptr = bytes.ptr, .len = bytes.len };
    }
    return ok;
}

fn deliverResult(out: *ScBytes, result: engine_mod.Error![]u8) i32 {
    out.* = .{};
    const bytes = result catch |err| return status(err);
    return deliver(out, bytes);
}

pub export fn sc_bytes_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |bytes| if (len > 0) gpa.free(bytes[0..len]);
}

pub export fn sc_engine_new(config: *const ScEngineConfig, out: *?*Engine) i32 {
    out.* = null;
    if (config.size < @sizeOf(ScEngineConfig)) return status(error.InvalidArgument);
    out.* = Engine.create(.{
        .cols = config.cols,
        .rows = config.rows,
        .colors = config.has_colors,
        .foreground = config.foreground,
        .background = config.background,
        .cursor = config.cursor,
        .palette = config.palette,
        .scrollback_lines = if (config.scrollback_lines == 0) engine_mod.default_scrollback_lines else config.scrollback_lines,
    }) catch |err| return status(err);
    return ok;
}

pub export fn sc_engine_restore(data: ?[*]const u8, len: usize, out: *?*Engine) i32 {
    out.* = null;
    const bytes = slice(data, len) orelse return status(error.InvalidArgument);
    out.* = Engine.restore(bytes) catch |err| return status(err);
    return ok;
}

pub export fn sc_engine_free(engine: ?*Engine) void {
    if (engine) |e| e.destroy();
}

pub export fn sc_engine_write(engine: *Engine, data: ?[*]const u8, len: usize) i32 {
    const bytes = slice(data, len) orelse return status(error.InvalidArgument);
    engine.feed(bytes);
    return ok;
}

pub export fn sc_engine_resize(engine: *Engine, cols: u32, rows: u32, cell_width: u32, cell_height: u32) i32 {
    if (cols == 0 or rows == 0 or cols > std.math.maxInt(u16) or rows > std.math.maxInt(u16)) return status(error.InvalidArgument);
    engine.resize(@intCast(cols), @intCast(rows), cell_width, cell_height) catch |err| return status(err);
    return ok;
}

pub export fn sc_engine_scroll(engine: *Engine, delta_rows: i32) void {
    engine.scrollRows(delta_rows);
}

pub export fn sc_engine_scroll_to_bottom(engine: *Engine) void {
    engine.scrollToBottom();
}

pub export fn sc_engine_snapshot(engine: *Engine, out: *ScBytes) i32 {
    return deliverResult(out, render.snapshot(engine));
}

pub export fn sc_engine_kitty_frame(engine: *Engine, known_generation: u64, out: *ScBytes) i32 {
    return deliverResult(out, render.kittyFrame(engine, known_generation));
}

pub export fn sc_engine_encode_state(engine: *Engine, out: *ScBytes) i32 {
    return deliverResult(out, engine.encodeState());
}

pub export fn sc_engine_drain_effects(engine: *Engine, out: *ScBytes) i32 {
    return deliverResult(out, engine.drainEffects());
}

pub export fn sc_engine_is_mouse_tracking(engine: *Engine) i32 {
    return @intFromBool(engine.isMouseTracking() catch |err| return status(err));
}

pub export fn sc_engine_encode_focus(engine: *Engine, focused: bool, out: *ScBytes) i32 {
    return deliverResult(out, engine.encodeFocus(focused));
}

pub export fn sc_engine_encode_mouse(engine: *Engine, input: *const ScMouseInput, out: *ScBytes) i32 {
    return deliverResult(out, engine.encodeMouse(.{
        .action = input.action,
        .button = input.button,
        .x = input.x,
        .y = input.y,
        .modifiers = input.modifiers,
        .width = input.width,
        .height = input.height,
        .cell_width = input.cell_width,
        .cell_height = input.cell_height,
        .any_pressed = input.any_pressed,
    }));
}

pub export fn sc_engine_encode_scroll(engine: *Engine, rows: i32, out: *ScBytes) i32 {
    return deliverResult(out, engine.encodeScroll(rows));
}

pub export fn sc_engine_encode_key(
    engine: *Engine,
    name: ?[*]const u8,
    name_len: usize,
    text: ?[*]const u8,
    text_len: usize,
    modifiers: u32,
    action: u32,
    out: *ScBytes,
) i32 {
    out.* = .{};
    const key_name = slice(name, name_len) orelse return status(error.InvalidArgument);
    const key_text = slice(text, text_len) orelse return status(error.InvalidArgument);
    return deliverResult(out, engine.encodeKey(key_name, key_text, modifiers, action));
}

pub export fn sc_paste_is_safe(data: ?[*]const u8, len: usize) bool {
    return engine_mod.isPasteSafe(slice(data, len) orelse return false);
}

pub export fn sc_engine_encode_paste(engine: *Engine, data: ?[*]const u8, len: usize, out: *ScBytes) i32 {
    out.* = .{};
    const text = slice(data, len) orelse return status(error.InvalidArgument);
    return deliverResult(out, engine.encodePaste(text));
}

fn boolResult(result: engine_mod.Error!bool) i32 {
    return @intFromBool(result catch |err| return status(err));
}

pub export fn sc_engine_select_word(engine: *Engine, column: i32, row: i32) i32 {
    return boolResult(selection.selectWord(engine, column, row));
}

pub export fn sc_engine_select_range(engine: *Engine, start_column: i32, end_column: i32, row: i32) i32 {
    return boolResult(selection.selectRange(engine, start_column, end_column, row));
}

pub export fn sc_engine_extend_selection(engine: *Engine, column: i32, row: i32) i32 {
    return boolResult(selection.extendSelection(engine, column, row));
}

pub export fn sc_engine_set_selection_endpoint(engine: *Engine, start: bool, column: i32, row: i32) i32 {
    return boolResult(selection.setEndpoint(engine, start, column, row));
}

pub export fn sc_engine_selection_endpoints(engine: *Engine, out: *[4]i32) void {
    out.* = selection.endpoints(engine);
}

pub export fn sc_engine_has_selection(engine: *Engine) bool {
    return selection.hasSelection(engine);
}

pub export fn sc_engine_clear_selection(engine: *Engine) i32 {
    selection.clearSelection(engine) catch |err| return status(err);
    return ok;
}

pub export fn sc_engine_select_latest_output(engine: *Engine) i32 {
    return boolResult(selection.selectLatestOutput(engine));
}

pub export fn sc_engine_select_output(engine: *Engine, column: i32, row: i32) i32 {
    return boolResult(selection.selectOutput(engine, column, row));
}

pub export fn sc_engine_jump_prompt(engine: *Engine, direction: i32) i32 {
    return boolResult(selection.jumpPrompt(engine, direction));
}

pub export fn sc_engine_selected_text(engine: *Engine, out: *ScBytes) i32 {
    return deliverResult(out, selection.selectedText(engine));
}

pub export fn sc_engine_plain_text(engine: *Engine, out: *ScBytes) i32 {
    return deliverResult(out, selection.plainText(engine));
}

pub export fn sc_engine_search(engine: *Engine, query: ?[*]const u8, query_len: usize, direction: i32) i32 {
    const text = slice(query, query_len) orelse return status(error.InvalidArgument);
    return boolResult(selection.search(engine, text, direction));
}

pub export fn sc_engine_hyperlink(engine: *Engine, column: i32, row: i32, out: *ScBytes) i32 {
    return deliverResult(out, selection.hyperlink(engine, column, row));
}
