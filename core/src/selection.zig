//! Selection, search, hyperlinks and text extraction.

const std = @import("std");
const c = @import("ghostty_c");
const engine_mod = @import("engine.zig");

const Engine = engine_mod.Engine;
const Error = engine_mod.Error;
const check = engine_mod.check;
const gpa = engine_mod.gpa;

pub const max_search_query_bytes = 1024;

pub const SearchState = struct {
    query: std.ArrayList(u8) = .empty,
    row: usize = 0,
    start: usize = 0,
    end: usize = 0,

    pub fn deinit(self: *SearchState) void {
        self.query.deinit(gpa);
    }

    /// Forgets the current match (the screen changed).
    pub fn reset(self: *SearchState) void {
        self.query.clearRetainingCapacity();
    }
};

const Point = struct { column: i32, row: i32 };

fn viewportRef(terminal: c.GhosttyTerminal, column: i32, row: i32) ?c.GhosttyGridRef {
    if (column < 0 or column > std.math.maxInt(u16) or row < 0) return null;
    const point: c.GhosttyPoint = .{
        .tag = c.GHOSTTY_POINT_TAG_VIEWPORT,
        .value = .{ .coordinate = .{ .x = @intCast(column), .y = @intCast(row) } },
    };
    var ref: c.GhosttyGridRef = .{};
    if (c.ghostty_terminal_grid_ref(terminal, point, &ref) != c.GHOSTTY_SUCCESS) return null;
    return ref;
}

fn screenRef(terminal: c.GhosttyTerminal, row: usize, column: u16) ?c.GhosttyGridRef {
    if (row > std.math.maxInt(u32)) return null;
    const point: c.GhosttyPoint = .{
        .tag = c.GHOSTTY_POINT_TAG_SCREEN,
        .value = .{ .coordinate = .{ .x = column, .y = @intCast(row) } },
    };
    var ref: c.GhosttyGridRef = .{};
    if (c.ghostty_terminal_grid_ref(terminal, point, &ref) != c.GHOSTTY_SUCCESS) return null;
    return ref;
}

fn install(self: *Engine, sel: ?*const c.GhosttySelection) Error!void {
    try check(c.ghostty_terminal_set(self.terminal, c.GHOSTTY_TERMINAL_OPT_SELECTION, sel));
}

fn currentSelection(self: *Engine) ?c.GhosttySelection {
    var sel: c.GhosttySelection = .{};
    if (c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_SELECTION, &sel) != c.GHOSTTY_SUCCESS) return null;
    return sel;
}

pub fn selectWord(self: *Engine, column: i32, row: i32) Error!bool {
    self.lock();
    defer self.unlock();
    const ref = viewportRef(self.terminal, column, row) orelse return false;
    var options: c.GhosttyTerminalSelectWordOptions = .{ .size = @sizeOf(c.GhosttyTerminalSelectWordOptions), .ref = ref };
    var sel: c.GhosttySelection = .{};
    if (c.ghostty_terminal_select_word(self.terminal, &options, &sel) != c.GHOSTTY_SUCCESS) return false;
    try install(self, &sel);
    return true;
}

pub fn selectRange(self: *Engine, start_column: i32, end_column: i32, row: i32) Error!bool {
    if (start_column < 0 or end_column < start_column or row < 0 or end_column > std.math.maxInt(u16)) return false;
    self.lock();
    defer self.unlock();
    const start = viewportRef(self.terminal, start_column, row) orelse return false;
    const end = viewportRef(self.terminal, end_column, row) orelse return false;
    const sel: c.GhosttySelection = .{ .start = start, .end = end };
    try install(self, &sel);
    return true;
}

/// Moves the end of the current selection to the viewport cell.
pub fn extendSelection(self: *Engine, column: i32, row: i32) Error!bool {
    return setEndpoint(self, false, column, row);
}

pub fn setEndpoint(self: *Engine, start: bool, column: i32, row: i32) Error!bool {
    self.lock();
    defer self.unlock();
    var sel = currentSelection(self) orelse return false;
    const ref = viewportRef(self.terminal, column, row) orelse return false;
    if (start) sel.start = ref else sel.end = ref;
    try install(self, &sel);
    return true;
}

/// Viewport coordinates of the selection ends as {startX, startY, endX, endY};
/// -1 for an end that is not in the viewport or when nothing is selected.
pub fn endpoints(self: *Engine) [4]i32 {
    self.lock();
    defer self.unlock();
    var points: [4]i32 = .{ -1, -1, -1, -1 };
    const sel = currentSelection(self) orelse return points;
    var start: c.GhosttyPointCoordinate = .{};
    var end: c.GhosttyPointCoordinate = .{};
    if (c.ghostty_terminal_point_from_grid_ref(self.terminal, &sel.start, c.GHOSTTY_POINT_TAG_VIEWPORT, &start) == c.GHOSTTY_SUCCESS) {
        points[0] = start.x;
        points[1] = @intCast(@min(start.y, std.math.maxInt(i32)));
    }
    if (c.ghostty_terminal_point_from_grid_ref(self.terminal, &sel.end, c.GHOSTTY_POINT_TAG_VIEWPORT, &end) == c.GHOSTTY_SUCCESS) {
        points[2] = end.x;
        points[3] = @intCast(@min(end.y, std.math.maxInt(i32)));
    }
    return points;
}

pub fn hasSelection(self: *Engine) bool {
    self.lock();
    defer self.unlock();
    return currentSelection(self) != null;
}

pub fn clearSelection(self: *Engine) Error!void {
    self.lock();
    defer self.unlock();
    try install(self, null);
}

fn format(self: *Engine, sel: ?*const c.GhosttySelection) Error![]u8 {
    var formatter: c.GhosttyFormatter = null;
    try check(c.ghostty_formatter_terminal_new(null, &formatter, self.terminal));
    defer c.ghostty_formatter_free(formatter);
    var unwrap = true;
    var trim = true;
    try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap));
    try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_TRIM, &trim));
    if (sel) |value| try check(c.ghostty_formatter_set(formatter, c.GHOSTTY_FORMATTER_OPT_SELECTION, value));
    var bytes: ?[*]u8 = null;
    var length: usize = 0;
    const result = c.ghostty_formatter_format_alloc(formatter, null, @ptrCast(&bytes), &length);
    if (result == c.GHOSTTY_NO_VALUE) return &.{};
    try check(result);
    defer c.ghostty_free(null, bytes, length);
    if (length > engine_mod.max_snapshot_bytes) return Error.TooLarge;
    if (length == 0) return &.{};
    return gpa.dupe(u8, (bytes orelse return Error.Engine)[0..length]);
}

/// UTF-8 text of the current selection, unwrapped and trimmed; empty when
/// nothing is selected.
pub fn selectedText(self: *Engine) Error![]u8 {
    self.lock();
    defer self.unlock();
    var sel = currentSelection(self) orelse return &.{};
    return format(self, &sel);
}

/// The whole screen including scrollback as UTF-8, unwrapped and trimmed.
pub fn plainText(self: *Engine) Error![]u8 {
    self.lock();
    defer self.unlock();
    return format(self, null);
}

fn isPromptRow(ref: *const c.GhosttyGridRef) bool {
    var raw_row: c.GhosttyRow = 0;
    var prompt: c.GhosttyRowSemanticPrompt = c.GHOSTTY_ROW_SEMANTIC_NONE;
    return c.ghostty_grid_ref_row(ref, &raw_row) == c.GHOSTTY_SUCCESS and
        c.ghostty_row_get(raw_row, c.GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &prompt) == c.GHOSTTY_SUCCESS and
        prompt == c.GHOSTTY_ROW_SEMANTIC_PROMPT;
}

/// Selects the output of the most recent command (shell integration marks).
pub fn selectLatestOutput(self: *Engine) Error!bool {
    self.lock();
    defer self.unlock();
    var total_rows: usize = 0;
    var columns: u16 = 0;
    try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total_rows));
    try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_COLS, &columns));
    var row = total_rows;
    while (row > 0) {
        row -= 1;
        const first = screenRef(self.terminal, row, 0) orelse continue;
        if (isPromptRow(&first)) return false;
        for (0..columns) |column| {
            var ref = screenRef(self.terminal, row, @intCast(column)) orelse continue;
            var cell: c.GhosttyCell = 0;
            var semantic: c.GhosttyCellSemanticContent = c.GHOSTTY_CELL_SEMANTIC_PROMPT;
            if (c.ghostty_grid_ref_cell(&ref, &cell) == c.GHOSTTY_SUCCESS and
                c.ghostty_cell_get(cell, c.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, &semantic) == c.GHOSTTY_SUCCESS and
                semantic == c.GHOSTTY_CELL_SEMANTIC_OUTPUT)
            {
                var sel: c.GhosttySelection = .{};
                try check(c.ghostty_terminal_select_output(self.terminal, &ref, &sel));
                try install(self, &sel);
                return true;
            }
        }
    }
    return false;
}

/// Selects the command output containing the viewport cell.
pub fn selectOutput(self: *Engine, column: i32, row: i32) Error!bool {
    self.lock();
    defer self.unlock();
    var ref = viewportRef(self.terminal, column, row) orelse return false;
    var sel: c.GhosttySelection = .{};
    if (c.ghostty_terminal_select_output(self.terminal, &ref, &sel) != c.GHOSTTY_SUCCESS) return false;
    try install(self, &sel);
    return true;
}

/// Scrolls to the previous (direction < 0) or next shell prompt.
pub fn jumpPrompt(self: *Engine, direction: i32) Error!bool {
    self.lock();
    defer self.unlock();
    var total_rows: usize = 0;
    var scrollbar: c.GhosttyTerminalScrollbar = .{};
    try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total_rows));
    try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar));
    const step: i64 = if (direction < 0) -1 else 1;
    var row: i64 = @as(i64, @intCast(scrollbar.offset)) + step;
    while (row >= 0 and row < total_rows) : (row += step) {
        const ref = screenRef(self.terminal, @intCast(row), 0) orelse continue;
        if (isPromptRow(&ref)) {
            const behavior: c.GhosttyTerminalScrollViewport = .{
                .tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW,
                .value = .{ .row = @intCast(row) },
            };
            _ = c.ghostty_terminal_scroll_viewport(self.terminal, behavior);
            return true;
        }
    }
    return false;
}

/// The OSC 8 hyperlink at the viewport cell, or empty.
pub fn hyperlink(self: *Engine, column: i32, row: i32) Error![]u8 {
    self.lock();
    defer self.unlock();
    var ref = viewportRef(self.terminal, column, row) orelse return &.{};
    var length: usize = 0;
    const result = c.ghostty_grid_ref_hyperlink_uri(&ref, null, 0, &length);
    if (result == c.GHOSTTY_SUCCESS and length == 0) return &.{};
    if (result != c.GHOSTTY_OUT_OF_SPACE) try check(result);
    const bytes = try gpa.alloc(u8, length);
    errdefer gpa.free(bytes);
    try check(c.ghostty_grid_ref_hyperlink_uri(&ref, bytes.ptr, bytes.len, &length));
    return gpa.realloc(bytes, length) catch bytes[0..length];
}

// MARK: Search

const Cell = struct { row: usize, column: u16 };
const Match = struct { start: Cell, end: Cell };

/// One logical (soft-wrapped) line: lowercased text plus the grid cell each
/// UTF-8 byte came from.
const Line = struct {
    text: std.ArrayList(u8) = .empty,
    cells: std.ArrayList(Cell) = .empty,

    fn deinit(self: *Line) void {
        self.text.deinit(gpa);
        self.cells.deinit(gpa);
    }

    fn clear(self: *Line) void {
        self.text.clearRetainingCapacity();
        self.cells.clearRetainingCapacity();
    }
};

fn appendRow(self: *Engine, line: *Line, row: usize, columns: u16) Error!void {
    var codepoints: [32]u32 = undefined;
    for (0..columns) |index| {
        const column: u16 = @intCast(index);
        var ref = screenRef(self.terminal, row, column) orelse continue;
        var cell: c.GhosttyCell = 0;
        var wide: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
        if (c.ghostty_grid_ref_cell(&ref, &cell) != c.GHOSTTY_SUCCESS) continue;
        _ = c.ghostty_cell_get(cell, c.GHOSTTY_CELL_DATA_WIDE, &wide);
        if (wide == c.GHOSTTY_CELL_WIDE_SPACER_TAIL) continue;

        const start = line.text.items.len;
        var length: usize = 0;
        const result = c.ghostty_grid_ref_graphemes(&ref, &codepoints, codepoints.len, &length);
        if (result == c.GHOSTTY_SUCCESS) {
            for (codepoints[0..length]) |codepoint| {
                var encoded: [4]u8 = undefined;
                const size = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch continue;
                try line.text.appendSlice(gpa, encoded[0..size]);
            }
        } else if (result == c.GHOSTTY_OUT_OF_SPACE and length > 0) {
            const heap = try gpa.alloc(u32, length);
            defer gpa.free(heap);
            if (c.ghostty_grid_ref_graphemes(&ref, heap.ptr, heap.len, &length) == c.GHOSTTY_SUCCESS) {
                for (heap[0..length]) |codepoint| {
                    var encoded: [4]u8 = undefined;
                    const size = std.unicode.utf8Encode(@intCast(codepoint), &encoded) catch continue;
                    try line.text.appendSlice(gpa, encoded[0..size]);
                }
            }
        }
        if (line.text.items.len == start) try line.text.append(gpa, ' ');
        for (line.text.items[start..]) |*byte| byte.* = std.ascii.toLower(byte.*);
        try line.cells.appendNTimes(gpa, .{ .row = row, .column = column }, line.text.items.len - start);
    }
}

fn rowWraps(terminal: c.GhosttyTerminal, row: usize) bool {
    const ref = screenRef(terminal, row, 0) orelse return false;
    var raw_row: c.GhosttyRow = 0;
    var wraps = false;
    return c.ghostty_grid_ref_row(&ref, &raw_row) == c.GHOSTTY_SUCCESS and
        c.ghostty_row_get(raw_row, c.GHOSTTY_ROW_DATA_WRAP, &wraps) == c.GHOSTTY_SUCCESS and wraps;
}

/// Case-insensitive search across scrollback and screen, joining soft-wrapped
/// rows. Selects the match and scrolls it into view. Repeating the same query
/// moves to the next (direction >= 0) or previous match, wrapping around.
/// Returns whether a match was selected.
pub fn search(self: *Engine, query_text: []const u8, direction: i32) Error!bool {
    if (query_text.len == 0 or query_text.len > max_search_query_bytes) return false;
    var query_buffer: [max_search_query_bytes]u8 = undefined;
    const query = query_buffer[0..query_text.len];
    for (query, query_text) |*out, byte| out.* = std.ascii.toLower(byte);

    self.lock();
    defer self.unlock();
    var total_rows: usize = 0;
    var columns: u16 = 0;
    var scrollbar: c.GhosttyTerminalScrollbar = .{};
    try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total_rows));
    try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_COLS, &columns));
    try check(c.ghostty_terminal_get(self.terminal, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar));
    if (total_rows == 0 or columns == 0) return false;

    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(gpa);
    var line: Line = .{};
    defer line.deinit();
    for (0..total_rows) |row| {
        try appendRow(self, &line, row, columns);
        if (rowWraps(self.terminal, row) and row + 1 < total_rows) continue;
        var offset = std.mem.indexOfPos(u8, line.text.items, 0, query);
        while (offset) |at| {
            if (at + query.len > line.cells.items.len) break;
            try matches.append(gpa, .{ .start = line.cells.items[at], .end = line.cells.items[at + query.len - 1] });
            offset = std.mem.indexOfPos(u8, line.text.items, at + 1, query);
        }
        line.clear();
    }
    if (matches.items.len == 0) return false;

    const state = &self.search;
    const count = matches.items.len;
    const continuing = std.mem.eql(u8, state.query.items, query) and state.query.items.len > 0 and state.row < total_rows;
    var selected: usize = 0;
    var found_current = false;
    if (continuing) {
        for (matches.items, 0..) |match, index| {
            if (match.start.row == state.row and match.start.column == state.start) {
                selected = if (direction < 0) (index + count - 1) % count else (index + 1) % count;
                found_current = true;
                break;
            }
        }
    }
    if (!found_current) {
        if (direction < 0) {
            selected = count - 1;
            var index = count;
            while (index > 0) {
                index -= 1;
                if (matches.items[index].start.row <= scrollbar.offset) {
                    selected = index;
                    break;
                }
            }
        } else {
            selected = 0;
            for (matches.items, 0..) |match, index| {
                if (match.start.row >= scrollbar.offset) {
                    selected = index;
                    break;
                }
            }
        }
    }

    const match = matches.items[selected];
    const sel: c.GhosttySelection = .{
        .start = screenRef(self.terminal, match.start.row, match.start.column) orelse return false,
        .end = screenRef(self.terminal, match.end.row, match.end.column) orelse return false,
    };
    try install(self, &sel);
    state.query.clearRetainingCapacity();
    try state.query.appendSlice(gpa, query);
    state.row = match.start.row;
    state.start = match.start.column;
    state.end = match.end.column;
    const target = if (match.start.row > scrollbar.len / 3) match.start.row - scrollbar.len / 3 else 0;
    const behavior: c.GhosttyTerminalScrollViewport = .{
        .tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW,
        .value = .{ .row = target },
    };
    _ = c.ghostty_terminal_scroll_viewport(self.terminal, behavior);
    return true;
}
