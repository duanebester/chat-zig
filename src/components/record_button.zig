//! Microphone record/stop toggle in the composer action row.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Color = gooey.Color;
const Lucide = @import("gooey-components").Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");
const icon_mod = @import("icon.zig");
const icon = icon_mod.icon;

const AppState = state_mod.AppState;

const ACTION_BUTTON_SIZE = constants.ACTION_BUTTON_SIZE;
const ACTION_ICON_SIZE = constants.ACTION_ICON_SIZE;
const BUTTON_CORNER_RADIUS = constants.BUTTON_CORNER_RADIUS;

pub const RecordButton = struct {
    enabled: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.theme);

        cx.render(ui.box(.{
            .style = .{
                .width = .{ .fixed = ACTION_BUTTON_SIZE },
                .height = .{ .fixed = ACTION_BUTTON_SIZE },
                .corner_radius = .all(BUTTON_CORNER_RADIUS),
                .background = .{ .rgba = if (s.recording.active) t.danger else if (self.enabled) t.primary else t.border },
                .alignment = .center,
                .cursor = if (self.enabled) .pointer else null,
            },
            .on_click = if (self.enabled) cx.on(AppState.toggleRecording, .{}) else null,
            .a11y = .{
                .role = .button,
                .label = if (s.recording.active) "Stop recording" else "Record",
                .disabled = !self.enabled,
            },
        }, .{
            if (s.recording.active)
                icon(stop_icon)
            else if (self.enabled)
                icon(mic_ready_icon)
            else
                icon(mic_idle_icon),
        }));
    }
};

const stop_icon: icon_mod.Spec = .{ .path = Lucide.square, .size = 12, .fill = .{ .rgba = Color.white } };
const mic_ready_icon: icon_mod.Spec = .{ .path = Lucide.mic, .size = ACTION_ICON_SIZE, .stroke = .bg };
const mic_idle_icon: icon_mod.Spec = .{ .path = Lucide.mic, .size = ACTION_ICON_SIZE, .stroke = .secondary };
