//! Render snapshots and Kitty graphics frames, in the little-endian int32
//! stream formats the Android app parses (and iOS parses too).
//!
//! Snapshot ("GVT1"):
//!   magic, columns, rows, background, foreground, cursor color (ARGB),
//!   cursor x, cursor y (-1 when not in the viewport),
//!   cursor style + 1 (0 when hidden),
//!   scroll total, scroll offset, scroll visible,
//!   cursor flags (1 blinking, 2 password input, 4 wide tail, 8 at prompt),
//!   title (length + UTF-8), pwd (length + UTF-8),
//!   dirty (0 clean, 1 partial, 2 full), dirty row count,
//!   per dirty row: row index, then `columns` cells of
//!     foreground, background, flags, underline color, text (length + UTF-8).
//!   Cell flags: 1 bold, 2 italic, 4 faint, 8 blink, 16 strikethrough,
//!   32 invisible, 64 selected, 128 overline, bits 8-10 underline style.

const std = @import("std");
const c = @import("ghostty_c");
const engine_mod = @import("engine.zig");

const Engine = engine_mod.Engine;
const Error = engine_mod.Error;
const check = engine_mod.check;
const gpa = engine_mod.gpa;
const putI32 = engine_mod.putI32;
const putI64 = engine_mod.putI64;
const argb = engine_mod.argb;

pub const snapshot_magic: i32 = 0x47565431; // GVT1

fn clampI32(value: u64) i32 {
    return @intCast(@min(value, std.math.maxInt(i32)));
}

/// `full` reports every row as dirty, for hosts that keep no row cache.
pub fn snapshot(self: *Engine, full: bool) Error![]u8 {
    self.lock();
    defer self.unlock();
    try check(c.ghostty_render_state_update(self.render_state, self.terminal));

    var columns: u16 = 0;
    var row_count: u16 = 0;
    var cursor: c.GhosttyRenderStateCursor = .{ .size = @sizeOf(c.GhosttyRenderStateCursor) };
    var colors: c.GhosttyRenderStateColors = .{ .size = @sizeOf(c.GhosttyRenderStateColors) };
    var dirty: c.GhosttyRenderStateDirty = c.GHOSTTY_RENDER_STATE_DIRTY_FULL;
    var scrollbar: c.GhosttyTerminalScrollbar = .{};
    var title: c.GhosttyString = .{};
    var pwd: c.GhosttyString = .{};
    var cursor_at_prompt = false;
    try check(c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_COLS, &columns));
    try check(c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_ROWS, &row_count));
    try check(c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor));
    try check(c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_COLORS, &colors));
    try check(c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty));
    if (self.first_snapshot or full) {
        dirty = c.GHOSTTY_RENDER_STATE_DIRTY_FULL;
        try check(c.ghostty_render_state_set(self.render_state, c.GHOSTTY_RENDER_STATE_OPT_DIRTY, &dirty));
        self.first_snapshot = false;
    }
    try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar));
    try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_TITLE, &title));
    try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_PWD, &pwd));
    try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT, &cursor_at_prompt));
    try check(c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&self.rows)));

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, 64 + @as(usize, columns) * row_count * 17);
    const foreground = argb(colors.foreground);
    const background = argb(colors.background);
    try putI32(&out, snapshot_magic);
    try putI32(&out, columns);
    try putI32(&out, row_count);
    try putI32(&out, background);
    try putI32(&out, foreground);
    try putI32(&out, if (colors.cursor_has_value) argb(colors.cursor) else foreground);
    try putI32(&out, if (cursor.viewport_has_value) cursor.viewport_x else -1);
    try putI32(&out, if (cursor.viewport_has_value) cursor.viewport_y else -1);
    try putI32(&out, if (cursor.visible) @as(i32, @intCast(cursor.visual_style)) + 1 else 0);
    try putI32(&out, clampI32(scrollbar.total));
    try putI32(&out, clampI32(scrollbar.offset));
    try putI32(&out, clampI32(scrollbar.len));
    try putI32(&out, @as(i32, @intFromBool(cursor.blinking)) | (@as(i32, @intFromBool(cursor.password_input)) << 1) |
        (@as(i32, @intFromBool(cursor.wide_tail)) << 2) | (@as(i32, @intFromBool(cursor_at_prompt)) << 3));
    try engine_mod.putBytes(&out, engine_mod.stringSlice(title));
    try engine_mod.putBytes(&out, engine_mod.stringSlice(pwd));
    try putI32(&out, @intCast(dirty));
    const update_count_offset = out.items.len;
    try putI32(&out, 0);

    var grapheme: std.ArrayList(u8) = .empty;
    defer grapheme.deinit(gpa);
    try grapheme.resize(gpa, 32);
    var rows_written: i32 = 0;
    var row_y: u16 = 0;
    while (c.ghostty_render_state_row_iterator_next_dirty(self.rows, &row_y)) {
        try putI32(&out, row_y);
        try check(c.ghostty_render_state_row_get(self.rows, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&self.cells)));
        var cells_written: usize = 0;
        while (c.ghostty_render_state_row_cells_next(self.cells)) {
            try writeCell(self, &out, &grapheme, &colors);
            cells_written += 1;
        }
        while (cells_written < columns) : (cells_written += 1) {
            try putI32(&out, foreground);
            try putI32(&out, background);
            try putI32(&out, 0);
            try putI32(&out, foreground);
            try putI32(&out, 0);
        }
        rows_written += 1;
    }
    std.mem.writeInt(i32, out.items[update_count_offset..][0..4], rows_written, .little);
    try check(c.ghostty_render_state_clean(self.render_state));
    return out.toOwnedSlice(gpa);
}

fn writeCell(
    self: *Engine,
    out: *std.ArrayList(u8),
    grapheme: *std.ArrayList(u8),
    colors: *const c.GhosttyRenderStateColors,
) Error!void {
    var fg: c.GhosttyColorRgb = .{};
    var bg: c.GhosttyColorRgb = .{};
    var style: c.GhosttyStyle = .{};
    const fg_result = c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg);
    const bg_result = c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg);
    try check(c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style));

    var foreground = if (fg_result == c.GHOSTTY_SUCCESS) argb(fg) else argb(colors.foreground);
    var background = if (bg_result == c.GHOSTTY_SUCCESS) argb(bg) else argb(colors.background);
    var underline = foreground;
    if (style.underline_color.tag == c.GHOSTTY_STYLE_COLOR_RGB) {
        underline = argb(style.underline_color.value.rgb);
    } else if (style.underline_color.tag == c.GHOSTTY_STYLE_COLOR_PALETTE) {
        underline = argb(colors.palette[style.underline_color.value.palette]);
    }
    const flag = struct {
        fn has(s: c.GhosttyStyle, bit: c_uint) bool {
            return (s.flags & bit) != 0;
        }
    }.has;
    if (flag(style, c.GHOSTTY_STYLE_FLAG_INVERSE)) std.mem.swap(i32, &foreground, &background);
    var flags: i32 = 0;
    if (flag(style, c.GHOSTTY_STYLE_FLAG_BOLD)) flags |= 1;
    if (flag(style, c.GHOSTTY_STYLE_FLAG_ITALIC)) flags |= 2;
    if (flag(style, c.GHOSTTY_STYLE_FLAG_FAINT)) flags |= 4;
    if (flag(style, c.GHOSTTY_STYLE_FLAG_BLINK)) flags |= 8;
    if (flag(style, c.GHOSTTY_STYLE_FLAG_STRIKETHROUGH)) flags |= 16;
    if (flag(style, c.GHOSTTY_STYLE_FLAG_INVISIBLE)) flags |= 32;
    if (flag(style, c.GHOSTTY_STYLE_FLAG_OVERLINE)) flags |= 128;
    flags |= @as(i32, @intCast((style.flags & c.GHOSTTY_STYLE_UNDERLINE_MASK) >> c.GHOSTTY_STYLE_UNDERLINE_SHIFT)) << 8;
    var selected = false;
    if (c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected) == c.GHOSTTY_SUCCESS and selected) {
        flags |= 64;
    }

    var text: c.GhosttyBuffer = .{ .ptr = grapheme.items.ptr, .cap = grapheme.items.len, .len = 0 };
    var text_result = c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &text);
    if (text_result == c.GHOSTTY_OUT_OF_SPACE) {
        try grapheme.resize(gpa, text.len);
        text = .{ .ptr = grapheme.items.ptr, .cap = grapheme.items.len, .len = 0 };
        text_result = c.ghostty_render_state_row_cells_get(self.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &text);
    }
    try check(text_result);
    try putI32(out, foreground);
    try putI32(out, background);
    try putI32(out, flags);
    try putI32(out, underline);
    try putI32(out, @intCast(text.len));
    try out.appendSlice(gpa, grapheme.items[0..text.len]);
}

const KittyImage = struct {
    id: u32,
    width: u32,
    height: u32,
    format: i32,
    generation: u64,
    data: []const u8,
};

const KittyPlacement = struct {
    image_id: u32,
    z: i32,
    x_offset: u32,
    y_offset: u32,
    render: c.GhosttyKittyGraphicsPlacementRenderInfo,
};

/// Kitty graphics frame for the visible viewport:
///   generation (int64), image count, per image: id, generation (int64),
///   width, height, format, pixel length (0 when `known_generation` equals the
///   current generation) + pixels, placement count, per placement: image id,
///   z, x offset, y offset, pixel width, pixel height, viewport column, viewport
///   row, source x, source y, source width, source height.
pub fn kittyFrame(self: *Engine, known_generation: u64) Error![]u8 {
    self.lock();
    defer self.unlock();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var graphics: c.GhosttyKittyGraphics = null;
    if (c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, @ptrCast(&graphics)) != c.GHOSTTY_SUCCESS or graphics == null) {
        try putI64(&out, 0);
        try putI32(&out, 0);
        try putI32(&out, 0);
        return out.toOwnedSlice(gpa);
    }
    var generation: u64 = 0;
    try check(c.ghostty_kitty_graphics_get(graphics, c.GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION, &generation));
    try check(c.ghostty_kitty_graphics_get(graphics, c.GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, @ptrCast(&self.kitty_placements)));

    var images: std.ArrayList(KittyImage) = .empty;
    defer images.deinit(gpa);
    var placements: std.ArrayList(KittyPlacement) = .empty;
    defer placements.deinit(gpa);

    const iterator = self.kitty_placements;
    while (c.ghostty_kitty_graphics_placement_next(iterator)) {
        var image_id: u32 = 0;
        var x_offset: u32 = 0;
        var y_offset: u32 = 0;
        var z: i32 = 0;
        var is_virtual = false;
        try check(c.ghostty_kitty_graphics_placement_get(iterator, c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &image_id));
        try check(c.ghostty_kitty_graphics_placement_get(iterator, c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, &is_virtual));
        if (is_virtual) continue;
        try check(c.ghostty_kitty_graphics_placement_get(iterator, c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET, &x_offset));
        try check(c.ghostty_kitty_graphics_placement_get(iterator, c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET, &y_offset));
        try check(c.ghostty_kitty_graphics_placement_get(iterator, c.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z, &z));
        var info: c.GhosttyKittyGraphicsPlacementRenderInfo = .{ .size = @sizeOf(c.GhosttyKittyGraphicsPlacementRenderInfo) };
        const image = c.ghostty_kitty_graphics_image(graphics, image_id);
        if (image == null or
            c.ghostty_kitty_graphics_placement_render_info(iterator, image, self.terminal, &info) != c.GHOSTTY_SUCCESS or
            !info.viewport_visible) continue;
        try placements.append(gpa, .{ .image_id = image_id, .z = z, .x_offset = x_offset, .y_offset = y_offset, .render = info });
        if (hasImage(images.items, image_id)) continue;
        var value: KittyImage = .{ .id = image_id, .width = 0, .height = 0, .format = c.GHOSTTY_KITTY_IMAGE_FORMAT_RGBA, .generation = 0, .data = &.{} };
        var format: c.GhosttyKittyImageFormat = c.GHOSTTY_KITTY_IMAGE_FORMAT_RGBA;
        try check(c.ghostty_kitty_graphics_image_get(image, c.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_WIDTH, &value.width));
        try check(c.ghostty_kitty_graphics_image_get(image, c.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_HEIGHT, &value.height));
        try check(c.ghostty_kitty_graphics_image_get(image, c.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_FORMAT, &format));
        try check(c.ghostty_kitty_graphics_image_get(image, c.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_GENERATION, &value.generation));
        value.format = @intCast(format);
        var pixels: c.GhosttyString = .{};
        if (c.ghostty_kitty_graphics_image_get(image, c.GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS, &pixels) != c.GHOSTTY_SUCCESS) continue;
        value.data = engine_mod.stringSlice(pixels);
        try images.append(gpa, value);
    }

    try putI64(&out, generation);
    try putI32(&out, @intCast(images.items.len));
    const include_pixels = generation != known_generation;
    for (images.items) |image| {
        try putI32(&out, @bitCast(image.id));
        try putI64(&out, image.generation);
        try putI32(&out, @bitCast(image.width));
        try putI32(&out, @bitCast(image.height));
        try putI32(&out, image.format);
        const data = if (include_pixels) image.data else image.data[0..0];
        try putI32(&out, @intCast(data.len));
        try out.appendSlice(gpa, data);
    }
    try putI32(&out, @intCast(placements.items.len));
    for (placements.items) |placement| {
        try putI32(&out, @bitCast(placement.image_id));
        try putI32(&out, placement.z);
        try putI32(&out, @bitCast(placement.x_offset));
        try putI32(&out, @bitCast(placement.y_offset));
        try putI32(&out, @bitCast(placement.render.pixel_width));
        try putI32(&out, @bitCast(placement.render.pixel_height));
        try putI32(&out, placement.render.viewport_col);
        try putI32(&out, placement.render.viewport_row);
        try putI32(&out, @bitCast(placement.render.source_x));
        try putI32(&out, @bitCast(placement.render.source_y));
        try putI32(&out, @bitCast(placement.render.source_width));
        try putI32(&out, @bitCast(placement.render.source_height));
    }
    return out.toOwnedSlice(gpa);
}

fn hasImage(images: []const KittyImage, id: u32) bool {
    for (images) |image| if (image.id == id) return true;
    return false;
}
