//! Simple lowercase folding for search: ASCII, Latin-1, Latin Extended-A and
//! Additional, Greek, Cyrillic, Armenian and fullwidth Latin. Characters in
//! other scripts (and special cases such as the dotted capital I) compare
//! exactly.

const std = @import("std");

pub fn lower(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0xC0...0xD6, 0xD8...0xDE => cp + 32,
        // Latin Extended-A: pairs of (upper, lower), starting on even code points.
        0x100...0x12F, 0x132...0x137, 0x14A...0x177 => if (cp % 2 == 0) cp + 1 else cp,
        // ... and pairs starting on odd code points.
        0x139...0x148, 0x179...0x17E => if (cp % 2 == 1) cp + 1 else cp,
        0x178 => 0xFF,
        0x1E00...0x1E95, 0x1EA0...0x1EFF => if (cp % 2 == 0) cp + 1 else cp,
        0x386 => 0x3AC,
        0x388...0x38A => cp + 37,
        0x38C => 0x3CC,
        0x38E, 0x38F => cp + 63,
        0x391...0x3A1, 0x3A3...0x3AB => cp + 32,
        0x400...0x40F => cp + 80,
        0x410...0x42F => cp + 32,
        0x460...0x481, 0x48A...0x4BF, 0x4D0...0x52F => if (cp % 2 == 0) cp + 1 else cp,
        0x531...0x556 => cp + 48,
        0xFF21...0xFF3A => cp + 32,
        else => cp,
    };
}

/// Appends `text` lowercased, byte for byte for anything that is not valid UTF-8.
pub fn appendLower(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!void {
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        if (length == 1 or index + length > text.len) {
            try out.append(gpa, std.ascii.toLower(text[index]));
            index += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[index..][0..length]) catch {
            try out.append(gpa, text[index]);
            index += 1;
            continue;
        };
        try appendLowerCodepoint(out, gpa, cp);
        index += length;
    }
}

pub fn appendLowerCodepoint(out: *std.ArrayList(u8), gpa: std.mem.Allocator, cp: u21) std.mem.Allocator.Error!void {
    var encoded: [4]u8 = undefined;
    const size = std.unicode.utf8Encode(lower(cp), &encoded) catch return;
    try out.appendSlice(gpa, encoded[0..size]);
}

test "lowercases common scripts" {
    try std.testing.expectEqual(@as(u21, 'a'), lower('A'));
    try std.testing.expectEqual(@as(u21, 'ä'), lower('Ä'));
    try std.testing.expectEqual(@as(u21, '×'), lower('×'));
    try std.testing.expectEqual(@as(u21, 'ž'), lower('Ž'));
    try std.testing.expectEqual(@as(u21, 'ł'), lower('Ł'));
    try std.testing.expectEqual(@as(u21, 'ω'), lower('Ω'));
    try std.testing.expectEqual(@as(u21, 'я'), lower('Я'));
    try std.testing.expectEqual(@as(u21, 'ё'), lower('Ё'));
    try std.testing.expectEqual(@as(u21, '日'), lower('日'));
}

test "appendLower keeps invalid bytes" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendLower(&out, std.testing.allocator, "ÄPFEL \xff\xc3");
    try std.testing.expectEqualStrings("äpfel \xff\xc3", out.items);
}
