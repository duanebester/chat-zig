//! The toolbar theme button switches between the light and dark variants
//! of the palette selected in Settings.
//! The icon shows the look of the theme a click switches to: a sun for a
//! light one, a moon for a dark one.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Lucide = @import("gooey-components").Lucide;

const state_mod = @import("../state.zig");
const constants = @import("constants.zig");
const icon_mod = @import("icon.zig");
const icon = icon_mod.icon;

const AppState = state_mod.AppState;

pub const ThemeToggle = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const next_dark = !s.theme.isDark();
        cx.render(ui.box(.{
            .style = constants.toolbarButton(cx.titleBarInset().top),
            .on_click = cx.on(AppState.toggleThemeBrightness, .{}),
            .a11y = .{ .role = .button, .label = if (next_dark)
                "Switch to dark mode"
            else
                "Switch to light mode" },
        }, .{
            if (next_dark) icon(moon_icon) else icon(sun_icon),
        }));
    }
};

const moon_icon: icon_mod.Spec = .{ .path = Lucide.moon, .size = 16, .stroke = .secondary, .stroke_width = 1 };
const sun_icon: icon_mod.Spec = .{ .path = Lucide.sun, .size = 16, .stroke = .secondary, .stroke_width = 1 };
