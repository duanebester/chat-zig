//! Dark/light mode toggle, in the toolbar.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Lucide = @import("gooey-components").Lucide;

const state_mod = @import("../state.zig");
const constants = @import("constants.zig");
const icon = @import("icon.zig").icon;

const AppState = state_mod.AppState;

pub const ThemeToggle = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        cx.render(ui.box(.{
            .style = constants.toolbar_button,
            .on_click = cx.on(AppState.toggleDarkMode, .{}),
            .a11y = .{ .role = .button, .label = if (s.dark_mode) "Light mode" else "Dark mode" },
        }, .{
            if (s.dark_mode) icon(.{ .path = Lucide.sun, .size = 16, .stroke = .secondary, .stroke_width = 1 }) else icon(.{ .path = Lucide.moon, .size = 16, .stroke = .secondary, .stroke_width = 1 }),
        }));
    }
};
