//! Send / cancel button in the composer action row. Doubles as the in-flight
//! cancel affordance while a request is streaming.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Color = gooey.Color;
const Lucide = @import("gooey-components").Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");
const icon = @import("icon.zig").icon;

const AppState = state_mod.AppState;

const ACTION_BUTTON_SIZE = constants.ACTION_BUTTON_SIZE;
const ACTION_ICON_SIZE = constants.ACTION_ICON_SIZE;
const BUTTON_CORNER_RADIUS = constants.BUTTON_CORNER_RADIUS;

pub const SendButton = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);
        const can_send = s.has_api_key and s.input_slice.len > 0;

        cx.render(ui.box(.{
            .style = .{
                .width = .{ .fixed = ACTION_BUTTON_SIZE },
                .height = .{ .fixed = ACTION_BUTTON_SIZE },
                .corner_radius = .all(BUTTON_CORNER_RADIUS),
                .background = .{ .rgba = if (s.is_loading) t.danger else if (can_send) t.primary else t.border },
                .alignment = .center,
                .cursor = if (s.is_loading or can_send) .pointer else null,
            },
            .on_click = if (s.is_loading)
                cx.on(AppState.cancelInFlight, .{})
            else if (can_send)
                cx.on(AppState.sendMessage, .{})
            else
                null,
            .a11y = .{
                .role = .button,
                .label = if (s.is_loading) "Stop" else "Send",
                .disabled = !s.is_loading and !can_send,
            },
        }, .{
            if (s.is_loading)
                icon(stop_icon)
            else if (can_send)
                icon(send_ready_icon)
            else
                icon(send_idle_icon),
        }));
    }
};

const stop_icon: @import("icon.zig").Spec = .{
    .path = Lucide.square,
    .size = 12,
    .fill = .{ .rgba = Color.white },
};
/// On the primary-coloured button: the window background reads as the
/// card colour in dark mode and white in light mode, as in 0.2.9.
const send_ready_icon: @import("icon.zig").Spec = .{
    .path = Lucide.send,
    .size = ACTION_ICON_SIZE,
    .stroke = .bg,
    .stroke_width = 1,
};
const send_idle_icon: @import("icon.zig").Spec = .{
    .path = Lucide.send,
    .size = ACTION_ICON_SIZE,
    .stroke = .secondary,
    .stroke_width = 1,
};
