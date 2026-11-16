//! Live input-level waveform shown in the composer while recording.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Color = gooey.Color;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const audio = @import("../audio/mod.zig");

const AppState = state_mod.AppState;

/// Minimum bar height, so a silent input still shows a row of dots rather
/// than collapsing to nothing.
const BAR_HEIGHT_MIN: f32 = 3.0;
const BAR_HEIGHT_MAX: f32 = 24.0;
/// The meter reads levels the capture thread writes; nothing tells Gooey
/// they changed, so it asks for a frame this often while recording.
const METER_FRAME_MS: u32 = 33;

pub const MicrophoneMeter = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        if (!s.recording.active) return;
        cx.requestRenderAfter(METER_FRAME_MS);

        const t = theme_mod.get(s.theme);
        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .height = .{ .fixed = BAR_HEIGHT_MAX },
            .gap = 2,
            .alignment = .{ .main = .center, .cross = .end },
        } }, .{
            LevelBars{ .levels = s.microphoneLevels(), .color = t.danger },
        }));
    }
};

const LevelBars = struct {
    levels: [audio.WAVEFORM_BAR_COUNT]f32,
    color: Color,

    pub fn render(self: LevelBars, cx: *Cx) void {
        for (self.levels) |level| {
            std.debug.assert(level >= 0.0);
            std.debug.assert(level <= 1.0);
            cx.render(ui.box(.{ .style = .{
                .width = .{ .fixed = 3 },
                .height = .{ .fixed = BAR_HEIGHT_MIN + level * (BAR_HEIGHT_MAX - BAR_HEIGHT_MIN) },
                .corner_radius = .all(1.5),
                .background = .{ .rgba = self.color },
            } }, .{}));
        }
    }
};
