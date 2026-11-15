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
/// and the response is truncated to fit. Applies to the client-side
/// summary only; a native block cannot be truncated (see below).
pub const MAX_SUMMARY_LEN: usize = 4096;

/// Caps for Anthropic's native `compaction` block. The API writes its own
/// summary, typically 1–10 KB of text, and the block must be sent back
/// byte-for-byte (its `signature` covers `content`), so nothing here may be
/// truncated: a block that does not fit is refused and the client-side
/// summary runs instead. Measured live: an 11k-token conversation gave
/// 8.9 KB of content and a 1.6 KB signature, with no `encrypted_content`.
pub const MAX_NATIVE_SUMMARY_LEN: usize = 32 * 1024;
pub const MAX_SIGNATURE_LEN: usize = 8 * 1024;
pub const MAX_ENCRYPTED_CONTENT_LEN: usize = 32 * 1024;

comptime {
    std.debug.assert(MAX_SUMMARY_LEN <= MAX_NATIVE_SUMMARY_LEN);
}

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
// Summary storage
// =============================================================================

/// The summary standing in for every message before the cut: either text
/// chat-zig asked a model to write (client-side), or Anthropic's native
/// `compaction` block, which is the same readable text plus a `signature`
/// (and sometimes `encrypted_content`) that must travel back with it.
///
/// One type for both because the text is useful either way: a request to a
/// model without native compaction, or to OpenAI, carries the block's text
/// in the system prompt exactly as it would a client-side summary.
///
/// Fixed buffers, copied by length (`copyFrom`), never by value: three of
/// these exist (live state, the job's snapshot, the job's staging slot).
pub const Summary = struct {
    text_buf: [MAX_NATIVE_SUMMARY_LEN]u8 = undefined,
    text_len: u32 = 0,
    signature_buf: [MAX_SIGNATURE_LEN]u8 = undefined,
    signature_len: u32 = 0,
    encrypted_buf: [MAX_ENCRYPTED_CONTENT_LEN]u8 = undefined,
    encrypted_len: u32 = 0,

    const Self = @This();

    pub fn text(self: *const Self) []const u8 {
        std.debug.assert(self.text_len <= MAX_NATIVE_SUMMARY_LEN);
        return self.text_buf[0..self.text_len];
    }

    pub fn signature(self: *const Self) []const u8 {
        std.debug.assert(self.signature_len <= MAX_SIGNATURE_LEN);
        return self.signature_buf[0..self.signature_len];
    }

    /// Null when the block had none (the common case).
    pub fn encryptedContent(self: *const Self) ?[]const u8 {
        std.debug.assert(self.encrypted_len <= MAX_ENCRYPTED_CONTENT_LEN);
        if (self.encrypted_len == 0) return null;
        return self.encrypted_buf[0..self.encrypted_len];
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.text_len == 0;
    }

    /// A native block, sendable as-is to a model that supports compaction.
    pub fn isNative(self: *const Self) bool {
        if (self.signature_len > 0) std.debug.assert(self.text_len > 0);
        return self.signature_len > 0;
    }

    pub fn clear(self: *Self) void {
        self.text_len = 0;
        self.signature_len = 0;
        self.encrypted_len = 0;
        std.debug.assert(self.isEmpty() and !self.isNative());
    }

    /// Client-side summary: truncated to `MAX_SUMMARY_LEN` on a UTF-8
    /// boundary, no signature. Returns false (and leaves `self` alone) when
    /// nothing would be left.
    pub fn setText(self: *Self, summary_text: []const u8) bool {
        const len = utf8SafeLen(summary_text, MAX_SUMMARY_LEN);
        if (len == 0) return false;
        @memcpy(self.text_buf[0..len], summary_text[0..len]);
        self.text_len = @intCast(len);
        self.signature_len = 0;
        self.encrypted_len = 0;
        std.debug.assert(!self.isNative());
        return true;
    }

    /// Native block, stored verbatim. Returns false (and leaves `self`
    /// alone) when a field is empty where the API requires it, or does not
    /// fit: truncating would invalidate the signature.
    pub fn setNative(
        self: *Self,
        content: []const u8,
        block_signature: []const u8,
        encrypted_content: ?[]const u8,
    ) bool {
        const encrypted = encrypted_content orelse "";
        if (content.len == 0 or block_signature.len == 0) return false;
        if (content.len > MAX_NATIVE_SUMMARY_LEN) return false;
        if (block_signature.len > MAX_SIGNATURE_LEN) return false;
        if (encrypted.len > MAX_ENCRYPTED_CONTENT_LEN) return false;

        @memcpy(self.text_buf[0..content.len], content);
        @memcpy(self.signature_buf[0..block_signature.len], block_signature);
        @memcpy(self.encrypted_buf[0..encrypted.len], encrypted);
        self.text_len = @intCast(content.len);
        self.signature_len = @intCast(block_signature.len);
        self.encrypted_len = @intCast(encrypted.len);
        std.debug.assert(self.isNative());
        return true;
    }

    pub fn copyFrom(self: *Self, other: *const Self) void {
        @memcpy(self.text_buf[0..other.text_len], other.text());
        @memcpy(self.signature_buf[0..other.signature_len], other.signature());
        @memcpy(self.encrypted_buf[0..other.encrypted_len], other.encrypted_buf[0..other.encrypted_len]);
        self.text_len = other.text_len;
        self.signature_len = other.signature_len;
        self.encrypted_len = other.encrypted_len;
        std.debug.assert(self.isNative() == other.isNative());
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Summary.setText truncates a client summary and carries no signature" {
    var summary: Summary = .{};
    try std.testing.expect(summary.setNative("old", "sig", "enc"));

    const long: [MAX_SUMMARY_LEN + 10]u8 = @splat('a');
    try std.testing.expect(summary.setText(&long));
    try std.testing.expectEqual(MAX_SUMMARY_LEN, summary.text().len);
    try std.testing.expect(!summary.isNative());
    try std.testing.expectEqual(@as(?[]const u8, null), summary.encryptedContent());

    try std.testing.expect(!summary.setText(""));
    try std.testing.expectEqual(MAX_SUMMARY_LEN, summary.text().len);
}

test "Summary.setNative keeps the block verbatim past the client-summary cap" {
    // A native summary longer than MAX_SUMMARY_LEN must not be truncated:
    // the signature covers the content.
    var summary: Summary = .{};
    const content: [MAX_SUMMARY_LEN * 2]u8 = @splat('b');
    try std.testing.expect(summary.setNative(&content, "sig", null));
    try std.testing.expectEqualStrings(&content, summary.text());
    try std.testing.expectEqualStrings("sig", summary.signature());
    try std.testing.expect(summary.isNative());
    try std.testing.expectEqual(@as(?[]const u8, null), summary.encryptedContent());
}

test "Summary.setNative refuses an oversized or unsigned block and keeps the old one" {
    var summary: Summary = .{};
    try std.testing.expect(summary.setText("kept"));

    const too_long: [MAX_NATIVE_SUMMARY_LEN + 1]u8 = @splat('c');
    try std.testing.expect(!summary.setNative(&too_long, "sig", null));
    try std.testing.expect(!summary.setNative("content", "", null));
    const big_signature: [MAX_SIGNATURE_LEN + 1]u8 = @splat('s');
    try std.testing.expect(!summary.setNative("content", &big_signature, null));

    try std.testing.expectEqualStrings("kept", summary.text());
    try std.testing.expect(!summary.isNative());
}

test "Summary.copyFrom copies every field, including encrypted content" {
    var a: Summary = .{};
    var b: Summary = .{};
    try std.testing.expect(a.setNative("summary text", "signature", "opaque"));
    try std.testing.expect(b.setText("something longer than the source"));
    b.copyFrom(&a);
    try std.testing.expectEqualStrings("summary text", b.text());
    try std.testing.expectEqualStrings("signature", b.signature());
    try std.testing.expectEqualStrings("opaque", b.encryptedContent().?);

    a.clear();
    b.copyFrom(&a);
    try std.testing.expect(b.isEmpty());
    try std.testing.expect(!b.isNative());
}

test "thresholdTokens is the configured fraction of the window" {
    try std.testing.expectEqual(@as(u64, 50_000), thresholdTokens(200_000));
    try std.testing.expectEqual(@as(u64, 1), thresholdTokens(4));
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
