//! Splits message text into pieces Gooey can shape.
//!
//! Gooey shapes each `ui.text` as one run of at most
//! `gooey.text.run_codepoint_count_max` (1,024) codepoints and panics past
//! it. Assistant replies are often longer, so `MessageText` draws them as a
//! column of chunks cut here. Kept free of gooey so `zig build test` runs it.

const std = @import("std");

/// `gooey.text.run_codepoint_count_max`; `components/message.zig` asserts
/// the two agree.
pub const codepoint_count_max: usize = 1024;

pub const Chunk = struct {
    /// Bytes to draw.
    text_len: usize,
    /// Bytes to consume: `text_len`, plus the line break the chunk ended on.
    skip_len: usize,
};

/// The longest prefix of `text` within `codepoint_count_max`
/// codepoints, ending at the last line break in reach, else the last space,
/// else the codepoint limit.
pub fn next(text: []const u8) Chunk {
    std.debug.assert(text.len > 0);
    var offset: usize = 0;
    var codepoints: usize = 0;
    var last_newline: ?usize = null;
    var last_space: ?usize = null;
    while (offset < text.len) : (codepoints += 1) {
        if (codepoints == codepoint_count_max) {
            if (last_newline) |at| return .{ .text_len = at, .skip_len = at + 1 };
            if (last_space) |at| return .{ .text_len = at + 1, .skip_len = at + 1 };
            return .{ .text_len = offset, .skip_len = offset };
        }
        const byte = text[offset];
        if (byte == '\n' and offset > 0) last_newline = offset;
        if (byte == ' ') last_space = offset;
        const length = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        offset = @min(text.len, offset + length);
    }
    return .{ .text_len = text.len, .skip_len = text.len };
}

test "next keeps short text whole" {
    const chunk = next("hello\nworld");
    try std.testing.expectEqual(@as(usize, 11), chunk.text_len);
    try std.testing.expectEqual(@as(usize, 11), chunk.skip_len);
}

test "next ends a long text at its last line break in reach" {
    // Goal: a chunk never holds more codepoints than one shaped run, and a
    // split at a line break drops that break. Method: 600 'a's, a newline,
    // 600 more; the first chunk must be exactly the first line.
    const text = repeat("a", 600) ++ "\n" ++ repeat("b", 600);
    const chunk = next(text);
    try std.testing.expectEqual(@as(usize, 600), chunk.text_len);
    try std.testing.expectEqual(@as(usize, 601), chunk.skip_len);
}

test "next counts codepoints, not bytes, and splits at a space" {
    // 700 two-byte codepoints and a space, then 700 more: within the limit
    // by codepoints only up to the space.
    const word = repeat("é", 700);
    const text = word ++ " " ++ word;
    const chunk = next(text);
    try std.testing.expectEqual(word.len + 1, chunk.text_len);
    try std.testing.expectEqual(word.len + 1, chunk.skip_len);
}

test "next hard-splits a run with no break at the codepoint limit" {
    const text = repeat("x", codepoint_count_max + 5);
    const chunk = next(text);
    try std.testing.expectEqual(codepoint_count_max, chunk.text_len);
}

/// `count` copies of `unit`, at comptime, for the tests' long inputs.
fn repeat(comptime unit: []const u8, comptime count: usize) *const [unit.len * count]u8 {
    const static = struct {
        const bytes: [unit.len * count]u8 = blk: {
            @setEvalBranchQuota(100_000);
            var result: [unit.len * count]u8 = undefined;
            for (0..count) |index| @memcpy(result[index * unit.len ..][0..unit.len], unit);
            break :blk result;
        };
    };
    return &static.bytes;
}
