//! Theme button, in the toolbar: steps through Light, Dark, Latte, and
//! Macchiato (`theme.Choice`). Settings has the same choice as a `Select`.
//! The icon shows the look of the theme a click switches to: a sun for a
//! light one, a moon for a dark one.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Lucide = @import("gooey-components").Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");
const icon_mod = @import("icon.zig");
const icon = icon_mod.icon;

const AppState = state_mod.AppState;

pub const ThemeToggle = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const next = s.theme.next();
        const next_dark = theme_mod.gooeyFor(next).isDark();
        cx.render(ui.box(.{
            .style = constants.toolbarButton(cx.titleBarInset().top),
            .on_click = cx.on(AppState.cycleTheme, .{}),
            .a11y = .{ .role = .button, .label = labels[@backingInt(next)] },
        }, .{
            if (next_dark) icon(moon_icon) else icon(sun_icon),
        }));
    }
};

const moon_icon: icon_mod.Spec = .{ .path = Lucide.moon, .size = 16, .stroke = .secondary, .stroke_width = 1 };
const sun_icon: icon_mod.Spec = .{ .path = Lucide.sun, .size = 16, .stroke = .secondary, .stroke_width = 1 };

/// The button's accessible name, by the theme it switches to.
const labels = [theme_mod.Choice.count][]const u8{
    "Switch to Light theme",
    "Switch to Dark theme",
    "Switch to Latte theme",
    "Switch to Macchiato theme",
};
