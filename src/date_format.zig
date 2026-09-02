//! Small, dependency-free date formatting helper.
//!
//! Split out from `components/history_panel.zig` so it can be unit tested
//! without pulling in gooey — mirroring the narrow, gooey-free test modules
//! `build.zig` already wires up for `session_log.zig`, `http/anthropic.zig`,
//! `http/openai.zig`, and `audio/mod.zig`.

const std = @import("std");

/// "YYYY-MM-DD HH:MM" is 16 characters; round up for headroom.
pub const TIMESTAMP_BUF_LEN: usize = 24;

/// Formats a unix timestamp (seconds) as `"YYYY-MM-DD HH:MM"` in UTC.
/// `buf` must be at least `TIMESTAMP_BUF_LEN` bytes long.
pub fn formatTimestamp(buf: []u8, unix_seconds: i64) []const u8 {
    std.debug.assert(buf.len >= TIMESTAMP_BUF_LEN);
    std.debug.assert(unix_seconds >= 0);

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    }) catch buf[0..0];
}

test "formatTimestamp renders a fixed known instant" {
    // 2024-01-15 12:30:00 UTC.
    var buf: [TIMESTAMP_BUF_LEN]u8 = undefined;
    const label = formatTimestamp(&buf, 1705321800);
    try std.testing.expectEqualStrings("2024-01-15 12:30", label);
}

test "formatTimestamp renders the epoch" {
    var buf: [TIMESTAMP_BUF_LEN]u8 = undefined;
    const label = formatTimestamp(&buf, 0);
    try std.testing.expectEqualStrings("1970-01-01 00:00", label);
}

test "formatTimestamp pads single-digit month, day, hour, and minute" {
    // 2024-03-05 04:07:00 UTC.
    var buf: [TIMESTAMP_BUF_LEN]u8 = undefined;
    const label = formatTimestamp(&buf, 1709611620);
    try std.testing.expectEqualStrings("2024-03-05 04:07", label);
}
