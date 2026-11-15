//! A single dot that breathes in scale and opacity on a loop.
//!
//! Used as the "assistant is thinking" indicator during the window between
//! sending a request and the first streaming delta arriving — see
//! `content_area.zig`. Once deltas start landing the growing text is its own
//! progress indicator, so the dot goes away.
//!
//! Gooey 0.4's animation helpers (`tween`, `tweenOn`, `motion`) play once
//! or spring to a target; none loops. So the dot reads the clock and asks
//! for its next frame itself (`cx.requestRenderAfter`) while it is on screen.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Color = gooey.Color;

/// Scale and opacity at the bottom of the breath. Neither bottoms out at
/// zero — a dot that fully vanishes reads as a flicker rather than a pulse.
const SCALE_MIN: f32 = 0.6;
const OPACITY_MIN: f32 = 0.3;

/// Default breath period.
pub const PERIOD_MS_DEFAULT: u32 = 1200;

/// About 30 frames per second is smooth for an 8 px dot.
const FRAME_MS: u32 = 33;

pub const PulseDot = struct {
    color: Color,
    size: f32 = 8,
    period_ms: u32 = PERIOD_MS_DEFAULT,

    pub fn render(self: @This(), cx: *Cx) void {
        std.debug.assert(self.size > 0.0);
        std.debug.assert(self.period_ms > 0);

        const now_ms: u64 = @divFloor(cx.now(), std.time.ns_per_ms);
        const phase = @as(f32, @floatFromInt(now_ms % self.period_ms)) /
            @as(f32, @floatFromInt(self.period_ms));
        cx.requestRenderAfter(FRAME_MS);

        const breath = triangleWave(phase);
        const scale = SCALE_MIN + (1.0 - SCALE_MIN) * breath;
        const opacity = OPACITY_MIN + (1.0 - OPACITY_MIN) * breath;
        const drawn_size = self.size * scale;

        // Outer box stays at full `size` so the surrounding layout doesn't
        // twitch as the inner dot scales.
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = self.size },
            .height = .{ .fixed = self.size },
            .alignment = .center,
        } }, .{
            ui.box(.{ .style = .{
                .width = .{ .fixed = drawn_size },
                .height = .{ .fixed = drawn_size },
                .corner_radius = .all(drawn_size / 2.0),
                .background = .{ .rgba = self.color.withAlpha(opacity) },
            } }, .{}),
        }));
    }
};

/// Fold 0..1 into 0→1→0, so one period is one full breath in and out
/// rather than a sawtooth that snaps back at the wrap.
fn triangleWave(phase: f32) f32 {
    std.debug.assert(phase >= 0.0);
    std.debug.assert(phase <= 1.0);

    const folded = if (phase < 0.5) phase * 2.0 else (1.0 - phase) * 2.0;

    std.debug.assert(folded >= 0.0);
    std.debug.assert(folded <= 1.0);
    return folded;
}
