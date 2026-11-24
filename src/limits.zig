//! ChatZig's Gooey resource budget.
//!
//! Gooey reserves every pool at init from one `ResourceLimits` value and
//! panics, naming the field, when a frame needs more. ChatZig fits the
//! `small` profile, which also carries the four font faces it uses (regular,
//! medium, semibold, bold) and two `TextArea` slots. The transcript is a
//! `List` that builds only the messages in view, and Gooey draws only the
//! glyphs a scroll box shows, so its cost follows the window, not the length
//! of the conversation.

const std = @import("std");
const gooey = @import("gooey");

const state = @import("state.zig");
const jobs = @import("jobs.zig");

pub const limits: gooey.ResourceLimits = blk: {
    var value = gooey.ResourceLimits.small;
    // A job result carries up to `jobs.text_bytes_max` (4 KiB) of text: a
    // streamed piece, an error, or a transcript (2 KiB).
    value.events.job_result_bytes_max = 8 * 1024;
    break :blk value;
};

comptime {
    // The rows in view copy their text into the frame: a full-length message
    // fits, beside the chrome.
    std.debug.assert(state.MAX_MESSAGE_LEN < limits.build.text_bytes_frame_max);
    std.debug.assert(state.MAX_INPUT_LEN <= limits.text.area.bytes_max);
    std.debug.assert(limits.events.job_count_max >= 2);
    std.debug.assert(jobs.ChatJob.posts_max + jobs.TranscribeJob.posts_max <= limits.events.job_result_count_max);
    std.debug.assert(@sizeOf(jobs.ChatJob.Result) <= limits.events.job_result_bytes_max);
    std.debug.assert(@sizeOf(jobs.TranscribeJob.Result) <= limits.events.job_result_bytes_max);
    // One row per message, and one cached size per message text.
    std.debug.assert(state.MAX_MESSAGES <= limits.text.text_size_slot_count_max);
}
