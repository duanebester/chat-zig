//! Dark/light mode toggle, floated in the titlebar area.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Svg = gooey.components.Svg;
const Lucide = gooey.components.Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");

const AppState = state_mod.AppState;

pub const ThemeToggle = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        // Sun icon for dark mode, moon for light mode
        const icon_path = if (s.dark_mode) Lucide.sun else Lucide.moon;

        cx.render(ui.box(.{
            .width = 36,
            .height = 36,
            .corner_radius = 8,
            .alignment = .{ .main = .center, .cross = .center },
            .cursor = .pointer,
            .on_click_handler = cx.command(AppState.toggleDarkMode),
        }, .{
            Svg{ .path = icon_path, .size = 16, .no_fill = true, .stroke_color = t.icon_muted, .stroke_width = 1.0 },
        }));
    }
};
