//! Send / cancel button in the composer action row. Doubles as the in-flight
//! cancel affordance while a request is streaming.

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

pub const SendButton = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        cx.render(ui.box(.{
            .width = ACTION_BUTTON_SIZE,
            .height = ACTION_BUTTON_SIZE,
            .corner_radius = BUTTON_CORNER_RADIUS,
            .background = if (s.is_loading) t.danger else if (s.input_slice.len > 0 and s.has_api_key) t.primary else t.border,
            .alignment = .{ .main = .center, .cross = .center },
            .cursor = if (s.is_loading or (s.has_api_key and s.input_slice.len > 0)) .pointer else null,
            .on_click_handler = if (s.is_loading) cx.command(AppState.cancelInFlight) else if (s.has_api_key and s.input_slice.len > 0) cx.command(AppState.sendMessage) else null,
        }, .{
            Svg{
                .path = if (s.is_loading) Lucide.square else Lucide.send,
                .size = if (s.is_loading) 12 else ACTION_ICON_SIZE,
                .color = if (s.is_loading) Color.white else Color.transparent,
                .no_fill = !s.is_loading,
                .stroke_width = 1,
                .stroke_color = if (s.is_loading) Color.transparent else if (s.input_slice.len > 0 and s.has_api_key) (if (s.dark_mode) t.card else Color.white) else t.icon_muted,
            },
        }));
    }
};
