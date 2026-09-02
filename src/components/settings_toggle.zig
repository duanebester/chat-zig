//! Settings icon toggle, floated in the titlebar area next to `HistoryToggle`
//! and `ThemeToggle`.
//!
//! Selecting it swaps `ContentArea`/`InputArea` for `SettingsPanel` — a
//! full-length settings view — via `AppState.settings_expanded`. While the
//! settings panel is open, this same button swaps its icon for a chat
//! bubble so it reads as "back to chat" — the click handler is unchanged
//! (`AppState.toggleSettings` just flips back), only the icon communicates
//! the reversed action.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Svg = gooey.components.Svg;
const Lucide = gooey.components.Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");

const AppState = state_mod.AppState;

pub const SettingsToggle = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        const icon_path = if (s.settings_expanded) Lucide.message_square else Lucide.settings;

        cx.render(ui.box(.{
            .width = 36,
            .height = 36,
            .corner_radius = 8,
            .alignment = .{ .main = .center, .cross = .center },
            .cursor = .pointer,
            .on_click_handler = cx.command(AppState.toggleSettings),
        }, .{
            Svg{
                .path = icon_path,
                .size = 16,
                .no_fill = true,
                .stroke_color = t.icon_muted,
                .stroke_width = 1.0,
            },
        }));
    }
};
