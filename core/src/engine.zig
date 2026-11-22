//! Terminal engine: a thin layer over libghostty-vt's C API. Shared by the iOS
//! and Android apps (ADR 0012).

const std = @import("std");
const c = @import("ghostty_c");

pub const Error = error{ Init, Feed, Format };

pub const Engine = struct {
    terminal: c.GhosttyTerminal,

    pub fn init(cols: u16, rows: u16) Error!Engine {
        var terminal: c.GhosttyTerminal = null;
        if (c.ghostty_terminal_new(null, &terminal, cols, rows) != c.GHOSTTY_SUCCESS) return Error.Init;
        var scrollback: usize = 10_000;
        if (c.ghostty_terminal_set(terminal, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollback) != c.GHOSTTY_SUCCESS) {
            c.ghostty_terminal_free(terminal);
            return Error.Init;
        }
        return .{ .terminal = terminal };
    }

    pub fn deinit(self: *Engine) void {
        c.ghostty_terminal_free(self.terminal);
    }

    pub fn feed(self: *Engine, bytes: []const u8) void {
        c.ghostty_terminal_vt_write(self.terminal, bytes.ptr, bytes.len);
    }

    pub fn resize(self: *Engine, cols: u16, rows: u16) void {
        _ = c.ghostty_terminal_resize(self.terminal, cols, rows, 0, 0);
    }
};

test "engine parses terminal output" {
    var engine = try Engine.init(20, 4);
    defer engine.deinit();
    engine.feed("hello \x1b[31mworld\x1b[0m\r\n");
    engine.resize(30, 6);
}
