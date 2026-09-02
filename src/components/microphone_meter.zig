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

const MicrophoneLevelBar = struct {
    height: f32,
    color: Color,
};

pub const MicrophoneMeter = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        if (!s.recording.active) return;

        const t = theme_mod.get(s.dark_mode);
        const levels = s.microphoneLevels();
        var bars: [audio.WAVEFORM_BAR_COUNT]MicrophoneLevelBar = undefined;
        for (levels, 0..) |level, level_index| {
            std.debug.assert(level >= 0.0);
            std.debug.assert(level <= 1.0);
            bars[level_index] = .{
                .height = BAR_HEIGHT_MIN + level * (BAR_HEIGHT_MAX - BAR_HEIGHT_MIN),
                .color = t.danger,
            };
        }

        cx.render(ui.box(.{
            .height = 24,
            .direction = .row,
            .gap = 2,
            .alignment = .{ .main = .center, .cross = .end },
        }, .{
            ui.each(&bars, renderLevelBar),
        }));
    }
};

fn renderLevelBar(bar: MicrophoneLevelBar, _: usize) @TypeOf(ui.box(ui.Box{}, .{})) {
    std.debug.assert(bar.height >= BAR_HEIGHT_MIN);
    std.debug.assert(bar.height <= BAR_HEIGHT_MAX);
    return ui.box(.{
        .width = 3,
        .height = bar.height,
        .corner_radius = 2,
        .background = bar.color,
    }, .{});
}
