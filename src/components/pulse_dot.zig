//! A single dot that breathes in scale and opacity on a loop.
//!
//! Used as the "assistant is thinking" indicator during the window between
//! sending a request and the first streaming delta arriving — see
//! `content_area.zig`. Once deltas start landing the growing text is its own
//! progress indicator, so the dot goes away.
//!
//! The dot owns its tween rather than taking progress from a parent: there
//! is exactly one animation to drive, and `Window.endFrame` keeps requesting
//! frames on its own while any tween is running, so callers don't have to
//! pump it.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Color = gooey.Color;
const Easing = gooey.animation.Easing;

/// Scale and opacity at the bottom of the breath. Neither bottoms out at
/// zero — a dot that fully vanishes reads as a flicker rather than a pulse.
const SCALE_MIN: f32 = 0.6;
const OPACITY_MIN: f32 = 0.3;

/// Default breath period. Exported because `thinking_shader.zig` matches it,
/// so the window's rim glow and this dot move at the same tempo.
pub const PERIOD_MS_DEFAULT: u32 = 1200;

pub const PulseDot = struct {
    /// Animation key. Distinct per instance, so two dots on screen don't
    /// share one tween and pulse in lockstep.
    id: []const u8,
    color: Color,
    size: f32 = 8,
    period_ms: u32 = PERIOD_MS_DEFAULT,

    pub fn render(self: @This(), cx: *Cx) void {
        std.debug.assert(self.size > 0.0);
        std.debug.assert(self.period_ms > 0);

        // Linear loop, folded into a triangle wave below. Easing the tween
        // itself would make the fold discontinuous at the turnaround.
        const pulse = cx.animations.tween(self.id, .{
            .duration_ms = self.period_ms,
            .easing = Easing.linear,
            .mode = .loop,
        });

        const breath = triangleWave(pulse.progress);
        const scale = SCALE_MIN + (1.0 - SCALE_MIN) * breath;
        const opacity = OPACITY_MIN + (1.0 - OPACITY_MIN) * breath;
        const drawn_size = self.size * scale;

        // Outer box stays at full `size` so the surrounding layout doesn't
        // twitch as the inner rect scales.
        cx.render(ui.box(.{
            .width = self.size,
            .height = self.size,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.rect(.{
                .width = drawn_size,
                .height = drawn_size,
                .corner_radius = drawn_size / 2.0,
                .background = self.color.withAlpha(opacity),
            }),
        }));
    }
};

/// Fold 0..1 into 0→1→0, so one loop of the tween is one full breath in and
/// out rather than a sawtooth that snaps back at the wrap.
fn triangleWave(phase: f32) f32 {
    std.debug.assert(phase >= 0.0);
    std.debug.assert(phase <= 1.0);

    const folded = if (phase < 0.5) phase * 2.0 else (1.0 - phase) * 2.0;

    std.debug.assert(folded >= 0.0);
    std.debug.assert(folded <= 1.0);
    return folded;
}
