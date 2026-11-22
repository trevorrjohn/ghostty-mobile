//! Unit tests for the terminal engine, through the same functions the C ABI uses.

const std = @import("std");
const c = @import("ghostty_c");
const engine_mod = @import("engine.zig");
const render = @import("render.zig");
const selection = @import("selection.zig");
const abi = @import("engine_abi.zig");

const Engine = engine_mod.Engine;
const gpa = std.testing.allocator;
const ctrl: u32 = 1 << 1;

fn newEngine(cols: u16, rows: u16) !*Engine {
    return Engine.create(.{ .cols = cols, .rows = rows });
}

fn free(bytes: []u8) void {
    if (bytes.len > 0) engine_mod.gpa.free(bytes);
}

fn expectBytes(expected: []const u8, bytes: []u8) !void {
    defer free(bytes);
    try std.testing.expectEqualSlices(u8, expected, bytes);
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn int(self: *Reader) i32 {
        const value = std.mem.readInt(i32, self.bytes[self.at..][0..4], .little);
        self.at += 4;
        return value;
    }

    fn long(self: *Reader) u64 {
        const value = std.mem.readInt(u64, self.bytes[self.at..][0..8], .little);
        self.at += 8;
        return value;
    }

    fn string(self: *Reader) []const u8 {
        const length: usize = @intCast(self.int());
        defer self.at += length;
        return self.bytes[self.at..][0..length];
    }
};

const Parsed = struct {
    columns: usize,
    rows: usize,
    text: std.ArrayList(u8) = .empty,
    dirty: i32,
    dirty_rows: usize,
    title: []u8,
    flags: std.ArrayList(i32) = .empty,

    fn deinit(self: *Parsed) void {
        self.text.deinit(gpa);
        gpa.free(self.title);
        self.flags.deinit(gpa);
    }
};

fn parseSnapshot(bytes: []const u8) !Parsed {
    var r: Reader = .{ .bytes = bytes };
    try std.testing.expectEqual(render.snapshot_magic, r.int());
    var parsed: Parsed = .{ .columns = @intCast(r.int()), .rows = @intCast(r.int()), .dirty = 0, .dirty_rows = 0, .title = &.{} };
    errdefer parsed.deinit();
    for (0..9) |_| _ = r.int(); // colors, cursor, scrollbar
    _ = r.int(); // cursor flags
    parsed.title = try gpa.dupe(u8, r.string());
    _ = r.string(); // pwd
    parsed.dirty = r.int();
    parsed.dirty_rows = @intCast(r.int());
    for (0..parsed.dirty_rows) |_| {
        _ = r.int(); // row
        for (0..parsed.columns) |_| {
            _ = r.int();
            _ = r.int();
            try parsed.flags.append(gpa, r.int());
            _ = r.int();
            const text = r.string();
            try parsed.text.appendSlice(gpa, if (text.len == 0) " " else text);
        }
        try parsed.text.append(gpa, '\n');
    }
    try std.testing.expectEqual(bytes.len, r.at);
    return parsed;
}

fn snapshotText(engine: *Engine) !Parsed {
    const bytes = try render.snapshot(engine);
    defer free(bytes);
    return parseSnapshot(bytes);
}

test "snapshot carries text, title and dirty tracking" {
    const engine = try newEngine(10, 3);
    defer engine.destroy();
    engine.feed("\x1b]2;my title\x07hello");
    var first = try snapshotText(engine);
    defer first.deinit();
    try std.testing.expectEqual(@as(usize, 10), first.columns);
    try std.testing.expectEqual(@as(i32, 2), first.dirty);
    try std.testing.expectEqual(@as(usize, 3), first.dirty_rows);
    try std.testing.expectEqualStrings("my title", first.title);
    try std.testing.expect(std.mem.startsWith(u8, first.text.items, "hello"));

    var clean = try snapshotText(engine);
    defer clean.deinit();
    try std.testing.expectEqual(@as(usize, 0), clean.dirty_rows);

    engine.feed("\x1b[2;1Hdirty");
    var partial = try snapshotText(engine);
    defer partial.deinit();
    try std.testing.expect(partial.dirty_rows >= 1 and partial.dirty_rows < 3);
    try std.testing.expect(std.mem.indexOf(u8, partial.text.items, "dirty") != null);
}

test "snapshot encodes style flags" {
    const engine = try newEngine(10, 2);
    defer engine.destroy();
    engine.feed("\x1b[1;3;5;9mX\x1b[0m");
    var parsed = try snapshotText(engine);
    defer parsed.deinit();
    const flags = parsed.flags.items[0];
    try std.testing.expectEqual(@as(i32, 1 | 2 | 8 | 16), flags & 0xff);
}

test "encodes control combinations and Kitty keyboard mode" {
    const engine = try newEngine(80, 24);
    defer engine.destroy();
    try expectBytes(&.{0x02}, try engine.encodeKey("b", "b", ctrl, c.GHOSTTY_KEY_ACTION_PRESS));
    try expectBytes(&.{ 0x6e }, try engine.encodeKey("n", "n", 0, c.GHOSTTY_KEY_ACTION_PRESS));
    engine.feed("\x1b[>1u");
    try expectBytes("\x1b[98;5u", try engine.encodeKey("b", "b", ctrl, c.GHOSTTY_KEY_ACTION_PRESS));
}

test "cursor keys follow the application cursor mode" {
    const engine = try newEngine(80, 24);
    defer engine.destroy();
    try expectBytes("\x1b[A", try engine.encodeKey("ARROW_UP", "", 0, c.GHOSTTY_KEY_ACTION_PRESS));
    engine.feed("\x1b[?1h");
    try expectBytes("\x1bOA", try engine.encodeKey("ARROW_UP", "", 0, c.GHOSTTY_KEY_ACTION_PRESS));
}

test "focus reports only when the mode is on" {
    const engine = try newEngine(80, 24);
    defer engine.destroy();
    try expectBytes("", try engine.encodeFocus(true));
    engine.feed("\x1b[?1004h");
    try expectBytes("\x1b[I", try engine.encodeFocus(true));
    try expectBytes("\x1b[O", try engine.encodeFocus(false));
}

test "paste is wrapped only in bracketed paste mode" {
    const engine = try newEngine(80, 24);
    defer engine.destroy();
    try expectBytes("a\rb", try engine.encodePaste("a\nb"));
    engine.feed("\x1b[?2004h");
    try expectBytes("\x1b[200~ab\x1b[201~", try engine.encodePaste("ab"));
    try std.testing.expect(engine_mod.isPasteSafe("ls -la"));
    try std.testing.expect(!engine_mod.isPasteSafe("ls\nrm -rf /"));
}

test "mouse encodes SGR events" {
    const engine = try newEngine(80, 24);
    defer engine.destroy();
    engine.feed("\x1b[?1000h\x1b[?1006h");
    try std.testing.expect(try engine.isMouseTracking());
    const bytes = try engine.encodeMouse(.{
        .action = c.GHOSTTY_MOUSE_ACTION_PRESS,
        .button = c.GHOSTTY_MOUSE_BUTTON_LEFT,
        .x = 15,
        .y = 5,
        .modifiers = 0,
        .width = 800,
        .height = 480,
        .cell_width = 10,
        .cell_height = 20,
        .any_pressed = false,
    });
    try expectBytes("\x1b[<0;2;1M", bytes);
}

test "scroll input is local without mouse tracking or the alternate screen" {
    const engine = try newEngine(20, 4);
    defer engine.destroy();
    try expectBytes("", try engine.encodeScroll(3));
    try expectBytes("", try engine.encodeScroll(0));
    // Alternate scroll mode alone does not apply on the primary screen.
    engine.feed("\x1b[?1007h");
    try expectBytes("", try engine.encodeScroll(-1));
}

test "scroll input encodes wheel events when mouse tracking is on" {
    const engine = try newEngine(20, 4);
    defer engine.destroy();
    engine.feed("\x1b[?1000h\x1b[?1006h");
    const down = try engine.encodeScroll(2);
    defer free(down);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, down, "\x1b[<65;"));
    const up = try engine.encodeScroll(-1);
    defer free(up);
    try std.testing.expect(std.mem.startsWith(u8, up, "\x1b[<64;"));
    const capped = try engine.encodeScroll(50);
    defer free(capped);
    try std.testing.expectEqual(@as(usize, 10), std.mem.count(u8, capped, "\x1b[<65;"));
}

test "scroll input sends arrows on the alternate screen" {
    const engine = try newEngine(20, 4);
    defer engine.destroy();
    engine.feed("\x1b[?1049h");
    // DEC 1007 is on by default in libghostty's terminal.
    const up = try engine.encodeScroll(-1);
    defer free(up);
    const arrow = try engine.encodeKey("ARROW_UP", "", 0, c.GHOSTTY_KEY_ACTION_PRESS);
    defer free(arrow);
    try std.testing.expectEqualSlices(u8, arrow, up);
    const down = try engine.encodeScroll(3);
    defer free(down);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, down, "\x1b[B"));

    engine.feed("\x1b[?1007l");
    try expectBytes("", try engine.encodeScroll(1));
}

test "scroll input prefers mouse tracking over arrows on the alternate screen" {
    const engine = try newEngine(20, 4);
    defer engine.destroy();
    engine.feed("\x1b[?1049h\x1b[?1000h\x1b[?1006h");
    const down = try engine.encodeScroll(1);
    defer free(down);
    try std.testing.expect(std.mem.startsWith(u8, down, "\x1b[<65;"));
}

test "selects a range and a word and reads the text" {
    const engine = try newEngine(30, 4);
    defer engine.destroy();
    engine.feed("/tmp/report.txt and more");
    try std.testing.expect(try selection.selectRange(engine, 0, 14, 0));
    try expectBytes("/tmp/report.txt", try selection.selectedText(engine));
    try std.testing.expect(selection.hasSelection(engine));
    try std.testing.expectEqual([4]i32{ 0, 0, 14, 0 }, selection.endpoints(engine));
    try std.testing.expect(try selection.extendSelection(engine, 18, 0));
    try expectBytes("/tmp/report.txt and", try selection.selectedText(engine));
    try selection.clearSelection(engine);
    try expectBytes("", try selection.selectedText(engine));
    try std.testing.expect(!selection.hasSelection(engine));
    try std.testing.expect(!try selection.extendSelection(engine, 1, 0));
    try std.testing.expect(try selection.selectWord(engine, 1, 0));
    try std.testing.expect(!try selection.selectRange(engine, -1, 3, 0));
}

test "search crosses soft wraps, ignores case and cycles" {
    const engine = try newEngine(5, 3);
    defer engine.destroy();
    try engine.resize(5, 3, 10, 20);
    engine.feed("abcdefgh");
    try std.testing.expect(try selection.search(engine, "DEF", 1));
    try expectBytes("def", try selection.selectedText(engine));
    try std.testing.expect(!try selection.search(engine, "zzz", 1));
    try std.testing.expect(!try selection.search(engine, "", 1));

    engine.feed("\r\nxx\r\nxx\r\n");
    try std.testing.expect(try selection.search(engine, "xx", 1));
    const first = engine.search.row;
    try std.testing.expect(try selection.search(engine, "xx", 1));
    const second = engine.search.row;
    try std.testing.expectEqual(first + 1, second);
    try std.testing.expect(try selection.search(engine, "xx", 1));
    try std.testing.expectEqual(first, engine.search.row);
    try std.testing.expect(try selection.search(engine, "xx", -1));
    try std.testing.expectEqual(second, engine.search.row);

    const long: [1025]u8 = @splat('a');
    try std.testing.expect(!try selection.search(engine, &long, 1));
}

test "search finds scrollback history" {
    const engine = try newEngine(10, 3);
    defer engine.destroy();
    engine.feed("needle\r\n");
    for (0..10) |index| {
        var line: [16]u8 = undefined;
        engine.feed(std.fmt.bufPrint(&line, "line {d}\r\n", .{index}) catch unreachable);
    }
    try std.testing.expect(try selection.search(engine, "needle", 1));
    try expectBytes("needle", try selection.selectedText(engine));
}

test "reads OSC 8 hyperlinks" {
    const engine = try newEngine(30, 3);
    defer engine.destroy();
    engine.feed("\x1b]8;;https://example.com\x07link\x1b]8;;\x07 plain");
    try expectBytes("https://example.com", try selection.hyperlink(engine, 1, 0));
    try expectBytes("", try selection.hyperlink(engine, 8, 0));
}

test "plain text unwraps and trims" {
    const engine = try newEngine(5, 3);
    defer engine.destroy();
    engine.feed("abcdefgh");
    try expectBytes("abcdefgh", try selection.plainText(engine));
}

test "saved state restores terminal text" {
    const engine = try newEngine(10, 3);
    defer engine.destroy();
    engine.feed("persisted");
    const state = try engine.encodeState();
    defer free(state);
    const restored = try Engine.restore(state);
    defer restored.destroy();
    var parsed = try snapshotText(restored);
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, parsed.text.items, "persisted") != null);
    try std.testing.expectError(error.Engine, Engine.restore("not a snapshot"));
}

test "scrolls through retained history" {
    const engine = try newEngine(10, 3);
    defer engine.destroy();
    for (0..20) |index| {
        var line: [16]u8 = undefined;
        engine.feed(std.fmt.bufPrint(&line, "row {d}\r\n", .{index}) catch unreachable);
    }
    engine.scrollRows(-5);
    var scrolled = try snapshotText(engine);
    defer scrolled.deinit();
    try std.testing.expect(scrolled.dirty == 2);
    engine.scrollToBottom();
    var bottom = try snapshotText(engine);
    defer bottom.deinit();
    try std.testing.expect(!std.mem.eql(u8, scrolled.text.items, bottom.text.items));
}

test "drains bell, pty responses and unknown-sequence counts" {
    const engine = try newEngine(20, 4);
    defer engine.destroy();
    engine.feed("\x07\x07\x1b[6n");
    const drained = try engine.drainEffects();
    defer free(drained);
    var r: Reader = .{ .bytes = drained };
    try std.testing.expectEqual(@as(i32, 2), r.int());
    try std.testing.expectEqual(@as(i32, -1), r.int());
    try std.testing.expectEqual(@as(i32, -1), r.int());
    _ = r.int(); // unknown sequences
    try std.testing.expectEqual(@as(i32, 0), r.int());
    try std.testing.expectEqualStrings("\x1b[1;1R", r.string());
    try std.testing.expectEqual(@as(i32, 0), r.int());
    try std.testing.expectEqual(@as(i32, 0), r.int());
    try std.testing.expectEqual(drained.len, r.at);
}

test "drains progress, notifications and OSC 52 clipboard writes" {
    const engine = try newEngine(20, 4);
    defer engine.destroy();
    engine.feed("\x1b]9;4;1;42\x07\x1b]777;notify;Build;Done\x07\x1b]52;c;aGVsbG8=\x07");
    const drained = try engine.drainEffects();
    defer free(drained);
    var r: Reader = .{ .bytes = drained };
    _ = r.int(); // bells
    try std.testing.expectEqual(@as(i32, c.GHOSTTY_TERMINAL_PROGRESS_STATE_SET), r.int());
    try std.testing.expectEqual(@as(i32, 42), r.int());
    _ = r.int();
    _ = r.int();
    _ = r.string(); // pty
    try std.testing.expectEqual(@as(i32, 1), r.int());
    try std.testing.expectEqual(@as(i32, 1), r.int());
    try std.testing.expectEqualStrings("hello", r.string());
    try std.testing.expectEqual(@as(i32, 1), r.int());
    try std.testing.expectEqualStrings("Build", r.string());
    try std.testing.expectEqualStrings("Done", r.string());
    try std.testing.expectEqual(drained.len, r.at);
}

test "clipboard queue is bounded and rejects bad writes" {
    const engine = try newEngine(20, 4);
    defer engine.destroy();
    for (0..12) |_| engine.feed("\x1b]52;c;aGVsbG8=\x07");
    engine.feed("\x1b]52;c;!!!\x07");
    const drained = try engine.drainEffects();
    defer free(drained);
    var r: Reader = .{ .bytes = drained };
    for (0..5) |_| _ = r.int();
    _ = r.string();
    try std.testing.expectEqual(@as(i32, 8), r.int());
}

test "kitty frame reports placements with pixels only when the generation changed" {
    const engine = try newEngine(20, 6);
    defer engine.destroy();
    try engine.resize(20, 6, 10, 20);
    // 1x1 RGBA pixel, transmitted and displayed.
    engine.feed("\x1b_Ga=T,f=32,s=1,v=1,i=7;/wAA/w==\x1b\\");
    const frame = try render.kittyFrame(engine, 0);
    defer free(frame);
    var r: Reader = .{ .bytes = frame };
    const generation = r.long();
    try std.testing.expectEqual(@as(i32, 1), r.int());
    try std.testing.expectEqual(@as(i32, 7), r.int());
    _ = r.long();
    try std.testing.expectEqual(@as(i32, 1), r.int());
    try std.testing.expectEqual(@as(i32, 1), r.int());
    try std.testing.expectEqual(@as(i32, c.GHOSTTY_KITTY_IMAGE_FORMAT_RGBA), r.int());
    try std.testing.expectEqual(@as(i32, 4), r.int());
    r.at += 4;
    try std.testing.expectEqual(@as(i32, 1), r.int());
    try std.testing.expectEqual(@as(i32, 7), r.int());
    try std.testing.expectEqual(frame.len, r.at + 11 * 4);

    const known = try render.kittyFrame(engine, generation);
    defer free(known);
    var k: Reader = .{ .bytes = known };
    _ = k.long();
    _ = k.int();
    _ = k.int();
    _ = k.long();
    _ = k.int();
    _ = k.int();
    _ = k.int();
    try std.testing.expectEqual(@as(i32, 0), k.int());
}

test "c abi round trip" {
    var engine: ?*Engine = null;
    const config: abi.ScEngineConfig = .{
        .size = @sizeOf(abi.ScEngineConfig),
        .cols = 10,
        .rows = 3,
        .has_colors = true,
        .foreground = 0xf1f3f8,
        .background = 0x0a0c10,
        .cursor = 0x8be9b3,
        .palette = null,
        .scrollback_lines = 0,
    };
    try std.testing.expectEqual(@as(i32, 0), abi.sc_engine_new(&config, &engine));
    defer abi.sc_engine_free(engine);
    try std.testing.expectEqual(@as(i32, 0), abi.sc_engine_write(engine.?, "abc", 3));
    var bytes: abi.ScBytes = .{};
    try std.testing.expectEqual(@as(i32, 0), abi.sc_engine_snapshot(engine.?, &bytes));
    defer abi.sc_bytes_free(bytes.ptr, bytes.len);
    var parsed = try parseSnapshot(bytes.ptr.?[0..bytes.len]);
    defer parsed.deinit();
    try std.testing.expect(std.mem.startsWith(u8, parsed.text.items, "abc"));

    var scroll: abi.ScBytes = .{ .len = 99 };
    try std.testing.expectEqual(@as(i32, 0), abi.sc_engine_encode_scroll(engine.?, 3, &scroll));
    try std.testing.expectEqual(@as(usize, 0), scroll.len);
    try std.testing.expectEqual(@as(i32, -1), abi.sc_engine_resize(engine.?, 0, 3, 1, 1));
    var bad = config;
    bad.cols = 0;
    var none: ?*Engine = null;
    try std.testing.expectEqual(@as(i32, -1), abi.sc_engine_new(&bad, &none));
    try std.testing.expect(none == null);
}
