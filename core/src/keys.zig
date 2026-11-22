//! Key names used by the C ABI. The names are the W3C-style identifiers the
//! Android app already uses ("ARROW_UP", "F5", "a", ...), mapped to
//! libghostty-vt key codes.

const std = @import("std");
const c = @import("ghostty_c");

const table = std.StaticStringMap(c.GhosttyKey).initComptime(.{
    .{ "ESCAPE", c.GHOSTTY_KEY_ESCAPE },
    .{ "SPACE", c.GHOSTTY_KEY_SPACE },
    .{ "BACKQUOTE", c.GHOSTTY_KEY_BACKQUOTE },
    .{ "BACKSLASH", c.GHOSTTY_KEY_BACKSLASH },
    .{ "BRACKET_LEFT", c.GHOSTTY_KEY_BRACKET_LEFT },
    .{ "BRACKET_RIGHT", c.GHOSTTY_KEY_BRACKET_RIGHT },
    .{ "COMMA", c.GHOSTTY_KEY_COMMA },
    .{ "EQUAL", c.GHOSTTY_KEY_EQUAL },
    .{ "MINUS", c.GHOSTTY_KEY_MINUS },
    .{ "PERIOD", c.GHOSTTY_KEY_PERIOD },
    .{ "QUOTE", c.GHOSTTY_KEY_QUOTE },
    .{ "SEMICOLON", c.GHOSTTY_KEY_SEMICOLON },
    .{ "SLASH", c.GHOSTTY_KEY_SLASH },
    .{ "TAB", c.GHOSTTY_KEY_TAB },
    .{ "ENTER", c.GHOSTTY_KEY_ENTER },
    .{ "BACKSPACE", c.GHOSTTY_KEY_BACKSPACE },
    .{ "DELETE", c.GHOSTTY_KEY_DELETE },
    .{ "INSERT", c.GHOSTTY_KEY_INSERT },
    .{ "HOME", c.GHOSTTY_KEY_HOME },
    .{ "END", c.GHOSTTY_KEY_END },
    .{ "PAGE_UP", c.GHOSTTY_KEY_PAGE_UP },
    .{ "PAGE_DOWN", c.GHOSTTY_KEY_PAGE_DOWN },
    .{ "ARROW_UP", c.GHOSTTY_KEY_ARROW_UP },
    .{ "ARROW_DOWN", c.GHOSTTY_KEY_ARROW_DOWN },
    .{ "ARROW_LEFT", c.GHOSTTY_KEY_ARROW_LEFT },
    .{ "ARROW_RIGHT", c.GHOSTTY_KEY_ARROW_RIGHT },
    .{ "SHIFT_LEFT", c.GHOSTTY_KEY_SHIFT_LEFT },
    .{ "SHIFT_RIGHT", c.GHOSTTY_KEY_SHIFT_RIGHT },
    .{ "CONTROL_LEFT", c.GHOSTTY_KEY_CONTROL_LEFT },
    .{ "CONTROL_RIGHT", c.GHOSTTY_KEY_CONTROL_RIGHT },
    .{ "ALT_LEFT", c.GHOSTTY_KEY_ALT_LEFT },
    .{ "ALT_RIGHT", c.GHOSTTY_KEY_ALT_RIGHT },
    .{ "META_LEFT", c.GHOSTTY_KEY_META_LEFT },
    .{ "META_RIGHT", c.GHOSTTY_KEY_META_RIGHT },
    .{ "CAPS_LOCK", c.GHOSTTY_KEY_CAPS_LOCK },
    .{ "NUM_LOCK", c.GHOSTTY_KEY_NUM_LOCK },
    .{ "SCROLL_LOCK", c.GHOSTTY_KEY_SCROLL_LOCK },
    .{ "NUMPAD_0", c.GHOSTTY_KEY_NUMPAD_0 },
    .{ "NUMPAD_1", c.GHOSTTY_KEY_NUMPAD_1 },
    .{ "NUMPAD_2", c.GHOSTTY_KEY_NUMPAD_2 },
    .{ "NUMPAD_3", c.GHOSTTY_KEY_NUMPAD_3 },
    .{ "NUMPAD_4", c.GHOSTTY_KEY_NUMPAD_4 },
    .{ "NUMPAD_5", c.GHOSTTY_KEY_NUMPAD_5 },
    .{ "NUMPAD_6", c.GHOSTTY_KEY_NUMPAD_6 },
    .{ "NUMPAD_7", c.GHOSTTY_KEY_NUMPAD_7 },
    .{ "NUMPAD_8", c.GHOSTTY_KEY_NUMPAD_8 },
    .{ "NUMPAD_9", c.GHOSTTY_KEY_NUMPAD_9 },
    .{ "NUMPAD_ADD", c.GHOSTTY_KEY_NUMPAD_ADD },
    .{ "NUMPAD_SUBTRACT", c.GHOSTTY_KEY_NUMPAD_SUBTRACT },
    .{ "NUMPAD_MULTIPLY", c.GHOSTTY_KEY_NUMPAD_MULTIPLY },
    .{ "NUMPAD_DIVIDE", c.GHOSTTY_KEY_NUMPAD_DIVIDE },
    .{ "NUMPAD_DECIMAL", c.GHOSTTY_KEY_NUMPAD_DECIMAL },
    .{ "NUMPAD_COMMA", c.GHOSTTY_KEY_NUMPAD_COMMA },
    .{ "NUMPAD_ENTER", c.GHOSTTY_KEY_NUMPAD_ENTER },
    .{ "NUMPAD_EQUAL", c.GHOSTTY_KEY_NUMPAD_EQUAL },
    .{ "NUMPAD_PAREN_LEFT", c.GHOSTTY_KEY_NUMPAD_PAREN_LEFT },
    .{ "NUMPAD_PAREN_RIGHT", c.GHOSTTY_KEY_NUMPAD_PAREN_RIGHT },
    .{ "PRINT_SCREEN", c.GHOSTTY_KEY_PRINT_SCREEN },
    .{ "PAUSE", c.GHOSTTY_KEY_PAUSE },
    .{ "CONTEXT_MENU", c.GHOSTTY_KEY_CONTEXT_MENU },
});

/// Maps a key name to a libghostty key; unknown names map to UNIDENTIFIED.
pub fn fromName(name: []const u8) c.GhosttyKey {
    if (name.len == 1) {
        const key = name[0];
        if (key >= 'A' and key <= 'Z') return @intCast(c.GHOSTTY_KEY_A + (key - 'A'));
        if (key >= 'a' and key <= 'z') return @intCast(c.GHOSTTY_KEY_A + (key - 'a'));
        if (key >= '0' and key <= '9') return @intCast(c.GHOSTTY_KEY_DIGIT_0 + (key - '0'));
    }
    if (table.get(name)) |key| return key;
    if (name.len >= 2 and name[0] == 'F') {
        const number = std.fmt.parseInt(u8, name[1..], 10) catch return c.GHOSTTY_KEY_UNIDENTIFIED;
        if (number >= 1 and number <= 25) return @intCast(c.GHOSTTY_KEY_F1 + (number - 1));
    }
    return c.GHOSTTY_KEY_UNIDENTIFIED;
}

/// The unshifted codepoint libghostty needs for the Kitty keyboard protocol,
/// or 0 when the key name has none.
pub fn unshiftedCodepoint(name: []const u8) u32 {
    if (name.len == 1) {
        const key = name[0];
        if (key >= 'A' and key <= 'Z') return key - 'A' + 'a';
        return key;
    }
    const map = std.StaticStringMap(u8).initComptime(.{
        .{ "SPACE", ' ' },
        .{ "BACKQUOTE", '`' },
        .{ "BACKSLASH", '\\' },
        .{ "BRACKET_LEFT", '[' },
        .{ "BRACKET_RIGHT", ']' },
        .{ "COMMA", ',' },
        .{ "EQUAL", '=' },
        .{ "MINUS", '-' },
        .{ "PERIOD", '.' },
        .{ "QUOTE", '\'' },
        .{ "SEMICOLON", ';' },
        .{ "SLASH", '/' },
    });
    return map.get(name) orelse 0;
}

test "names map to keys" {
    try std.testing.expectEqual(@as(c.GhosttyKey, c.GHOSTTY_KEY_A), fromName("a"));
    try std.testing.expectEqual(@as(c.GhosttyKey, c.GHOSTTY_KEY_A + 1), fromName("B"));
    try std.testing.expectEqual(@as(c.GhosttyKey, c.GHOSTTY_KEY_DIGIT_0 + 7), fromName("7"));
    try std.testing.expectEqual(@as(c.GhosttyKey, c.GHOSTTY_KEY_F1 + 11), fromName("F12"));
    try std.testing.expectEqual(@as(c.GhosttyKey, c.GHOSTTY_KEY_ARROW_UP), fromName("ARROW_UP"));
    try std.testing.expectEqual(@as(c.GhosttyKey, c.GHOSTTY_KEY_UNIDENTIFIED), fromName("F26"));
    try std.testing.expectEqual(@as(c.GhosttyKey, c.GHOSTTY_KEY_UNIDENTIFIED), fromName("nope"));
    try std.testing.expectEqual(@as(u32, 'a'), unshiftedCodepoint("A"));
    try std.testing.expectEqual(@as(u32, '/'), unshiftedCodepoint("SLASH"));
    try std.testing.expectEqual(@as(u32, 0), unshiftedCodepoint("ENTER"));
}
