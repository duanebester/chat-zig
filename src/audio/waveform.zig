//! Fixed-size recent-amplitude history that feeds a live "while
//! recording" meter.
//!
//! `inputCallback` (recorder.zig, running on CoreAudio's background
//! thread) computes one amplitude value per arriving PCM buffer and
//! pushes it here; the UI thread reads a snapshot each frame and springs
//! a small bar chart toward it (see gooey-dic's `main.zig` `WaveformMeter`).
//!
//! Deliberately not a scrolling waveform: `WAVEFORM_BAR_COUNT` is small
//! (a "recent glimpse", not a review-what-was-said view), so the whole
//! history fits in one fixed-capacity array with no allocation and no
//! cursor/modulo bookkeeping on the read side — the array is always in
//! chronological order, oldest first.
//!
//! Single-writer: only `inputCallback` ever calls `push`/`reset`, and
//! CoreAudio never invokes two callbacks for the same queue concurrently
//! (see recorder.zig's module doc comment), so pushes never race each
//! other. Each slot is still an atomic because the UI thread reads
//! concurrently with those pushes; a snapshot can observe a mix of an
//! old and a just-shifted value mid-push, but that only ever shows up as
//! one harmless, imperceptible transient frame, never a torn `f32`.

const std = @import("std");

/// Number of bars in the live meter. Kept small and odd (for a
/// symmetric look) — this is a compact glimpse of the last handful of
/// buffer arrivals, not a long scrolling history.
pub const WAVEFORM_BAR_COUNT: u32 = 9;

/// `rms16` output is normalized against full scale, but ordinary
/// dictation-volume speech only ever occupies a small fraction of that
/// range. This lifts it back into a visually legible range; see
/// `amplitudeToVisualLevel`.
const VISUAL_GAIN: f32 = 4.0;

pub const WaveformHistory = struct {
    /// Oldest at index 0, newest at `WAVEFORM_BAR_COUNT - 1`.
    levels: [WAVEFORM_BAR_COUNT]std.atomic.Value(f32) =
        [_]std.atomic.Value(f32){std.atomic.Value(f32).init(0)} ** WAVEFORM_BAR_COUNT,

    /// Called from `inputCallback` with a raw interleaved 16-bit PCM
    /// chunk: computes its amplitude, maps it to a `[0, 1]` visual
    /// level, and shifts it in as the newest bar.
    pub fn push(self: *WaveformHistory, pcm_bytes: []const u8) void {
        const level = amplitudeToVisualLevel(rms16(pcm_bytes));
        self.shiftIn(level);
    }

    /// Drops the oldest level and appends `level` as the newest.
    fn shiftIn(self: *WaveformHistory, level: f32) void {
        std.debug.assert(level >= 0.0);
        std.debug.assert(level <= 1.0);

        var i: usize = 0;
        while (i + 1 < WAVEFORM_BAR_COUNT) : (i += 1) {
            self.levels[i].store(self.levels[i + 1].load(.acquire), .release);
        }
        self.levels[WAVEFORM_BAR_COUNT - 1].store(level, .release);

        std.debug.assert(i == WAVEFORM_BAR_COUNT - 1);
    }

    /// Snapshot for the UI thread: one plain atomic read per bar, no
    /// locking, safe to call every frame.
    pub fn snapshot(self: *const WaveformHistory) [WAVEFORM_BAR_COUNT]f32 {
        var out: [WAVEFORM_BAR_COUNT]f32 = undefined;
        for (&out, 0..) |*level, i| level.* = self.levels[i].load(.acquire);

        std.debug.assert(out.len == WAVEFORM_BAR_COUNT);
        return out;
    }

    /// Clears history back to silence. Called at the start of each new
    /// recording so stale peaks from a previous session never flash.
    pub fn reset(self: *WaveformHistory) void {
        for (&self.levels) |*level| level.store(0, .release);
    }
};

/// Root-mean-square amplitude of interleaved little-endian 16-bit PCM,
/// normalized to `[0, 1]` against full scale. Pure and allocation-free —
/// operates on the exact buffer `inputCallback` already has in hand.
fn rms16(bytes: []const u8) f32 {
    std.debug.assert(bytes.len % 2 == 0);
    if (bytes.len == 0) return 0.0;

    var sum_squares: f64 = 0.0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 2) {
        const sample = std.mem.readInt(i16, bytes[i..][0..2], .little);
        const sample_f: f64 = @floatFromInt(sample);
        sum_squares += sample_f * sample_f;
    }
    std.debug.assert(i == bytes.len);

    const sample_count: f64 = @floatFromInt(bytes.len / 2);
    std.debug.assert(sample_count > 0.0);
    const rms = @sqrt(sum_squares / sample_count);

    const full_scale: f64 = @floatFromInt(std.math.maxInt(i16));
    const normalized: f32 = @floatCast(rms / full_scale);

    std.debug.assert(normalized >= 0.0);
    return @min(normalized, 1.0);
}

/// Perceptual remap so ordinary dictation-volume speech (a small
/// fraction of full scale) produces visibly distinct bar heights instead
/// of a near-flat line: square root expands the quiet end, `VISUAL_GAIN`
/// then lifts it into a usable range, and the result is clamped back to
/// `[0, 1]` since louder speech can legitimately fill the meter.
fn amplitudeToVisualLevel(normalized_rms: f32) f32 {
    std.debug.assert(normalized_rms >= 0.0);
    std.debug.assert(normalized_rms <= 1.0);

    const level = @sqrt(normalized_rms) * VISUAL_GAIN;
    std.debug.assert(!std.math.isNan(level));

    const clamped = std.math.clamp(level, 0.0, 1.0);
    std.debug.assert(clamped >= 0.0 and clamped <= 1.0);
    return clamped;
}

// =============================================================================
// Tests
// =============================================================================

test "rms16 of silence is zero" {
    const silence = [_]u8{0} ** 16;
    try std.testing.expectEqual(@as(f32, 0.0), rms16(&silence));
}

test "rms16 of an empty buffer is zero" {
    try std.testing.expectEqual(@as(f32, 0.0), rms16(&[_]u8{}));
}

test "rms16 of a full-scale square wave clamps to 1.0" {
    // Alternating min/max i16 samples: the loudest possible 16-bit signal.
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(i16, bytes[0..2], std.math.maxInt(i16), .little);
    std.mem.writeInt(i16, bytes[2..4], std.math.minInt(i16), .little);
    std.mem.writeInt(i16, bytes[4..6], std.math.maxInt(i16), .little);
    std.mem.writeInt(i16, bytes[6..8], std.math.minInt(i16), .little);

    try std.testing.expectEqual(@as(f32, 1.0), rms16(&bytes));
}

test "rms16 of a mid-scale constant tone lands near the expected fraction" {
    const value: i16 = 8192; // 1/4 of maxInt(i16), roughly
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(i16, bytes[0..2], value, .little);
    std.mem.writeInt(i16, bytes[2..4], value, .little);

    const expected: f32 = @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(std.math.maxInt(i16)));
    try std.testing.expectApproxEqAbs(expected, rms16(&bytes), 0.001);
}

test "amplitudeToVisualLevel maps the boundaries and is monotonic" {
    try std.testing.expectEqual(@as(f32, 0.0), amplitudeToVisualLevel(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), amplitudeToVisualLevel(1.0));

    const low = amplitudeToVisualLevel(0.01);
    const high = amplitudeToVisualLevel(0.5);
    try std.testing.expect(high > low);
    try std.testing.expect(low > 0.0);
}

test "WaveformHistory starts silent" {
    const history = WaveformHistory{};
    const snap = history.snapshot();
    for (snap) |level| try std.testing.expectEqual(@as(f32, 0.0), level);
}

test "WaveformHistory.shiftIn drops the oldest and appends the newest" {
    var history = WaveformHistory{};

    var i: u32 = 0;
    while (i < WAVEFORM_BAR_COUNT) : (i += 1) {
        history.shiftIn(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(WAVEFORM_BAR_COUNT - 1)));
    }

    const snap = history.snapshot();
    // After exactly WAVEFORM_BAR_COUNT pushes, slot i holds push i's value.
    for (snap, 0..) |level, idx| {
        const expected = @as(f32, @floatFromInt(idx)) / @as(f32, @floatFromInt(WAVEFORM_BAR_COUNT - 1));
        try std.testing.expectApproxEqAbs(expected, level, 0.0001);
    }

    // One more push shifts everything down by one and appends at the end.
    history.shiftIn(1.0);
    const snap2 = history.snapshot();
    try std.testing.expectEqual(@as(f32, 1.0), snap2[WAVEFORM_BAR_COUNT - 1]);
    try std.testing.expectEqual(snap[1], snap2[0]);
}

test "WaveformHistory.reset clears every bar" {
    var history = WaveformHistory{};
    history.shiftIn(1.0);
    history.shiftIn(0.7);

    history.reset();

    const snap = history.snapshot();
    for (snap) |level| try std.testing.expectEqual(@as(f32, 0.0), level);
}

test "WaveformHistory.push computes and shifts in one step" {
    var history = WaveformHistory{};

    var bytes: [4]u8 = undefined;
    std.mem.writeInt(i16, bytes[0..2], std.math.maxInt(i16), .little);
    std.mem.writeInt(i16, bytes[2..4], std.math.minInt(i16), .little);

    history.push(&bytes);

    const snap = history.snapshot();
    try std.testing.expectEqual(@as(f32, 1.0), snap[WAVEFORM_BAR_COUNT - 1]);
    for (snap[0 .. WAVEFORM_BAR_COUNT - 1]) |level| try std.testing.expectEqual(@as(f32, 0.0), level);
}
