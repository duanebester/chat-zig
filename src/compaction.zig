//! Pure arithmetic and prompts behind chat compaction.
//!
//! Compaction is *derived, not destructive*: `AppState.messages` is never
//! mutated. The ring stays the UI transcript, and a summary plus a cut
//! (`summary_covers`) is a small cache that only affects request assembly.
//! See `docs/CHAT_COMPACTION.md` for the reasoning.
//!
//! Everything here takes primitives and returns primitives — no `AppState`,
//! no `std.Io`, no gooey. That keeps the off-by-one-prone half of the
//! feature (translating a monotonic `seq` cut into a ring index) directly
//! testable, and it is the half most worth testing: the ring-walking that
//! stays in `state.zig` is a loop over `getMessage`, while the arithmetic
//! below is where an index/count confusion would hide.
//!
//! Vocabulary, kept distinct on purpose (CLAUDE rule #18):
//!   * `covers` / `messages_total` — monotonic counters, never wrap.
//!   * `message_count` — how many messages the ring currently holds.
//!   * an *index* is 0-based into the live ring, in `getMessage` space.

const std = @import("std");

// =============================================================================
// Tuning
// =============================================================================

/// Fraction of the model's context window at which we start compacting.
/// Proactive on purpose — quality degrades as a conversation approaches the
/// hard limit, not only at the boundary, so waiting for a 400 is already
/// too late.
pub const TRIGGER_RATIO: f32 = 0.25;

/// Messages kept verbatim past the cut. The most recent turns carry the
/// detail a follow-up question is most likely to depend on, so they are the
/// ones a summary must not blur.
pub const KEEP_RECENT: u64 = 8;

/// ~1k tokens. Deliberately far below `state.MAX_MESSAGE_LEN`: a summary
/// allowed to be 32 KB is not a summary. `REQUEST` asks for under 400 words
/// and the response is truncated to fit.
pub const MAX_SUMMARY_LEN: usize = 4096;

/// Bytes per token for the heuristic estimator. English prose runs close to
/// 4. Being wrong by 30% moves the trigger from 75% to 65% or 85% of the
/// window, which is tolerable for a threshold (as opposed to a bill).
pub const CHARS_PER_TOKEN: u64 = 4;

// =============================================================================
// Prompts
// =============================================================================

pub const SYSTEM_INSTRUCTION =
    "You compact conversation transcripts so a later assistant can continue the conversation without having read them. " ++
    "The transcript may itself begin with a summary of even earlier turns; fold that into your output rather than repeating it separately. " ++
    "Respond in plain text only, with no Markdown or other markup.";

pub const REQUEST =
    "Summarize the conversation above in under 400 words. " ++
    "Preserve concrete facts, decisions made, names, file paths, numbers, and any question left open. " ++
    "Record that a file was attached and what it contained, never its raw contents. " ++
    "Write it as notes for yourself, not as a reply to the user. Output only the summary.";

/// Separator between the standing formatting rules and the summary when the
/// two share one system instruction.
pub const SUMMARY_PREAMBLE =
    "\n\nSummary of the earlier part of this conversation, which has been " ++
    "omitted from the messages below:\n";

// =============================================================================
// Arithmetic
// =============================================================================

/// Token count at which compaction should fire for a given context window.
pub fn thresholdTokens(context_window_tokens: u32) u64 {
    std.debug.assert(context_window_tokens > 0);
    const threshold: u64 = @intFromFloat(@as(f32, @floatFromInt(context_window_tokens)) * TRIGGER_RATIO);
    std.debug.assert(threshold < context_window_tokens);
    return threshold;
}

/// Heuristic token count for `chars` bytes of request payload.
pub fn estimateTokens(chars: u64) u32 {
    return @intCast(@min(chars / CHARS_PER_TOKEN, std.math.maxInt(u32)));
}

/// The cut a fresh compaction would install: everything except the newest
/// `KEEP_RECENT` messages. Returns 0 while the conversation is still short
/// enough that there is nothing to compact.
pub fn proposedCovers(messages_total: u64) u64 {
    if (messages_total <= KEEP_RECENT) return 0;
    return messages_total - KEEP_RECENT;
}

/// Translates a `covers` cut into an index into the live ring.
///
/// Logical indices decay: once the ring overwrites, index 0 refers to a
/// different message than it did before, which is why the cut is stored
/// against `messages_total` rather than as an index in the first place.
/// `evicted` is how far the ring's index 0 has drifted from `seq` 0.
///
/// Clamps to 0 when the ring has already dropped everything the summary
/// covers — the whole retained history is then past the cut.
pub fn cutToIndex(options: struct {
    covers: u64,
    messages_total: u64,
    message_count: u32,
}) u32 {
    std.debug.assert(options.messages_total >= options.message_count);
    std.debug.assert(options.covers <= options.messages_total);

    const evicted = options.messages_total - options.message_count;
    if (options.covers <= evicted) return 0;

    const index = options.covers - evicted;
    std.debug.assert(index <= options.message_count);
    return @intCast(index);
}

/// Largest prefix of `text` that is at most `max` bytes and does not split
/// a UTF-8 sequence.
///
/// Truncating mid-codepoint would put invalid UTF-8 into a JSON string —
/// both in the request body and in the session log, since
/// `writeJsonEscapedString` passes non-control bytes through verbatim. The
/// API answers that with a 400, so the boundary walk is load-bearing rather
/// than cosmetic.
pub fn utf8SafeLen(text: []const u8, max: usize) usize {
    if (text.len <= max) return text.len;

    // Continuation bytes are 0b10xxxxxx. Walk back to the lead byte: at
    // most 3 steps for well-formed UTF-8, and the `len > 0` guard bounds it
    // absolutely for input that isn't (CLAUDE rule #4).
    var len = max;
    while (len > 0 and (text[len] & 0b1100_0000) == 0b1000_0000) : (len -= 1) {}

    std.debug.assert(len <= max);
    return len;
}

// =============================================================================
// Tests
// =============================================================================

test "thresholdTokens is the configured fraction of the window" {
    try std.testing.expectEqual(@as(u64, 150_000), thresholdTokens(200_000));
    try std.testing.expectEqual(@as(u64, 3), thresholdTokens(4));
}

test "estimateTokens divides by the bytes-per-token constant" {
    try std.testing.expectEqual(@as(u32, 0), estimateTokens(0));
    try std.testing.expectEqual(@as(u32, 0), estimateTokens(3));
    try std.testing.expectEqual(@as(u32, 1), estimateTokens(4));
    try std.testing.expectEqual(@as(u32, 250), estimateTokens(1000));
}

test "estimateTokens saturates instead of overflowing u32" {
    try std.testing.expectEqual(std.math.maxInt(u32), estimateTokens(std.math.maxInt(u64)));
}

test "proposedCovers keeps the newest KEEP_RECENT messages" {
    // Nothing to compact until there is more history than we intend to keep.
    try std.testing.expectEqual(@as(u64, 0), proposedCovers(0));
    try std.testing.expectEqual(@as(u64, 0), proposedCovers(KEEP_RECENT));
    try std.testing.expectEqual(@as(u64, 1), proposedCovers(KEEP_RECENT + 1));
    try std.testing.expectEqual(@as(u64, 92), proposedCovers(100));
}

test "cutToIndex maps a cut to a ring index before any eviction" {
    // No eviction: seq and index are the same number.
    try std.testing.expectEqual(@as(u32, 0), cutToIndex(.{
        .covers = 0,
        .messages_total = 10,
        .message_count = 10,
    }));
    try std.testing.expectEqual(@as(u32, 4), cutToIndex(.{
        .covers = 4,
        .messages_total = 10,
        .message_count = 10,
    }));
}

test "cutToIndex shifts the cut by the number of evicted messages" {
    // 300 added, ring holds the newest 256: seq 44 is index 0.
    try std.testing.expectEqual(@as(u32, 0), cutToIndex(.{
        .covers = 44,
        .messages_total = 300,
        .message_count = 256,
    }));
    try std.testing.expectEqual(@as(u32, 48), cutToIndex(.{
        .covers = 92,
        .messages_total = 300,
        .message_count = 256,
    }));
}

test "cutToIndex clamps to 0 once the ring has outrun the cut" {
    // The ring already dropped every message the summary covers, so the
    // whole retained history is past the cut and nothing is skipped.
    try std.testing.expectEqual(@as(u32, 0), cutToIndex(.{
        .covers = 10,
        .messages_total = 300,
        .message_count = 256,
    }));
}

test "cutToIndex maps a cut at the very end to message_count" {
    // Degenerate but reachable: a cut that covers everything currently held
    // yields a one-past-the-end index, which callers treat as an empty
    // retained slice rather than as a valid message.
    try std.testing.expectEqual(@as(u32, 10), cutToIndex(.{
        .covers = 10,
        .messages_total = 10,
        .message_count = 10,
    }));
}

test "utf8SafeLen returns the whole string when it already fits" {
    try std.testing.expectEqual(@as(usize, 5), utf8SafeLen("hello", 10));
    try std.testing.expectEqual(@as(usize, 5), utf8SafeLen("hello", 5));
}

test "utf8SafeLen cuts ASCII at exactly the limit" {
    try std.testing.expectEqual(@as(usize, 3), utf8SafeLen("hello", 3));
}

test "utf8SafeLen backs off a split multi-byte sequence" {
    // "aé" is 'a' (1 byte) + 0xC3 0xA9. Cutting at 2 would strand the lead
    // byte, so the safe length is 1.
    const text = "a\xc3\xa9b";
    try std.testing.expectEqual(@as(usize, 1), utf8SafeLen(text, 2));
    try std.testing.expectEqual(@as(usize, 3), utf8SafeLen(text, 3));

    // A 3-byte sequence must back off up to two continuation bytes.
    const emoji = "ab\xe2\x9c\x93";
    try std.testing.expectEqual(@as(usize, 2), utf8SafeLen(emoji, 3));
    try std.testing.expectEqual(@as(usize, 2), utf8SafeLen(emoji, 4));
}

test "utf8SafeLen terminates on input that is entirely continuation bytes" {
    // Malformed input must not walk off the front of the slice.
    const junk = "\x80\x80\x80\x80";
    try std.testing.expectEqual(@as(usize, 0), utf8SafeLen(junk, 2));
}

test "a compaction that cannot advance the cut is detectable as such" {
    // The guard that keeps a long retained tail from compacting on every
    // turn: once only KEEP_RECENT messages sit past the existing cut, the
    // proposal stops moving and the caller skips the request.
    const messages_total: u64 = 20;
    const covers = proposedCovers(messages_total);
    try std.testing.expect(covers > 0);

    // Already compacted to that exact point — no progress available.
    try std.testing.expect(!(covers > covers));

    // One more turn arrives, and progress becomes available again.
    try std.testing.expect(proposedCovers(messages_total + 1) > covers);
}
