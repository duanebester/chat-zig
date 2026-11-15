//! ChatZig's Gooey resource budget.
//!
//! Gooey 0.5 reserves every pool at init from one `ResourceLimits` value and
//! panics, naming the field, when a frame needs more. ChatZig's chrome (header,
//! composer, settings with three dropdowns, a 200-row history list) fits the
//! `small` profile, which also carries the four font faces it uses (regular,
//! medium, semibold, bold) and two `TextArea` slots. The transcript does not:
//! Gooey emits every glyph of every message in a scroll box each frame, and a
//! single assistant reply may be `MAX_MESSAGE_LEN` (32 KiB) of text. So the
//! message list renders at most `transcript_bytes_frame_max` bytes of the
//! newest messages (`ContentArea`), and the overrides below size the paint
//! budget for that.

const std = @import("std");
const gooey = @import("gooey");

const state = @import("state.zig");
const jobs = @import("jobs.zig");

/// Message text bytes the transcript draws per frame: the newest messages
/// whose total fits, and always the newest one. One codepoint draws at most
/// one glyph, so this also bounds the transcript's glyphs.
pub const transcript_bytes_frame_max: u32 = 40 * 1024;

/// Glyphs, quads, and text bytes for everything except the transcript, with
/// room to spare. Measured peak on the settings and history views is under
/// 2,000 glyphs and 400 quads.
const chrome_glyph_count_frame_max: u32 = 8 * 1024;

pub const limits: gooey.ResourceLimits = blk: {
    var value = gooey.ResourceLimits.small;
    // `small` has 4,096 glyphs; the transcript needs up to 40 KiB of them.
    value.paint.glyph_count_frame_max = transcript_bytes_frame_max + chrome_glyph_count_frame_max;
    // Each glyph is a paint record, beside quads, SVGs, and clips (8,192).
    value.records.paint_record_count_frame_max = 64 * 1024;
    // Text bytes the build copies per frame (64 KiB): transcript plus chrome.
    value.build.text_bytes_frame_max = 64 * 1024;
    // Distinct glyphs per frame (1,024): replies in non-Latin scripts, or with
    // many symbols, draw more distinct glyphs than a form does.
    value.text.glyph_cache_count_max = 4 * 1024;
    // Shaped runs kept between frames (128): the transcript is reshaped every
    // frame it does not fit, so keep the visible runs cached (`large`'s value).
    value.text.shaped_run_count_max = 512;
    // A job result carries up to `jobs.text_bytes_max` (4 KiB) of text: a
    // streamed piece, an error, or a transcript (2 KiB).
    value.events.job_result_bytes_max = 8 * 1024;
    break :blk value;
};

comptime {
    std.debug.assert(state.MAX_MESSAGE_LEN <= transcript_bytes_frame_max);
    std.debug.assert(transcript_bytes_frame_max + chrome_glyph_count_frame_max <=
        limits.build.text_bytes_frame_max);
    std.debug.assert(state.MAX_INPUT_LEN <= limits.text.area.bytes_max);
    std.debug.assert(@sizeOf(jobs.ChatJob.Result) <= limits.events.job_result_bytes_max);
    std.debug.assert(@sizeOf(jobs.TranscribeJob.Result) <= limits.events.job_result_bytes_max);
}
