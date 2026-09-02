//! Microphone record/stop toggle in the composer action row.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Color = gooey.Color;
const Svg = gooey.components.Svg;
const Lucide = gooey.components.Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");

const AppState = state_mod.AppState;

const ACTION_BUTTON_SIZE = constants.ACTION_BUTTON_SIZE;
const ACTION_ICON_SIZE = constants.ACTION_ICON_SIZE;
const BUTTON_CORNER_RADIUS = constants.BUTTON_CORNER_RADIUS;

pub const RecordButton = struct {
    enabled: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        cx.render(ui.box(.{
            .width = ACTION_BUTTON_SIZE,
            .height = ACTION_BUTTON_SIZE,
            .corner_radius = BUTTON_CORNER_RADIUS,
            .background = if (s.recording.active) t.danger else if (self.enabled) t.primary else t.border,
            .alignment = .{ .main = .center, .cross = .center },
            .cursor = if (self.enabled) .pointer else null,
            .on_click_handler = if (self.enabled) cx.command(AppState.toggleRecording) else null,
        }, .{
            Svg{
                .path = if (s.recording.active) Lucide.square else Lucide.mic,
                .size = if (s.recording.active) 12 else ACTION_ICON_SIZE,
                .color = if (s.recording.active) Color.white else Color.transparent,
                .no_fill = !s.recording.active,
                .stroke_color = if (s.recording.active) Color.transparent else if (self.enabled) t.card else t.icon_muted,
                .stroke_width = 1.5,
            },
        }));
    }
};
