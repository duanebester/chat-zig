//! History icon toggle, floated in the titlebar area next to `ThemeToggle`.
//!
//! Selecting it swaps `ContentArea`'s message list for `HistoryPanel` — a
//! full-length list of past chat sessions — via `AppState.history_expanded`.
//! While the history panel is open, this same button swaps its icon for a
//! chat bubble so it reads as "back to chat" — the click handler is
//! unchanged (`AppState.toggleHistory` just flips back), only the icon
//! communicates the reversed action.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Svg = gooey.components.Svg;
const Lucide = gooey.components.Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");

const AppState = state_mod.AppState;

pub const HistoryToggle = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        const icon_path = if (s.history_expanded) Lucide.message_square else Lucide.history;

        cx.render(ui.box(.{
            .width = 36,
            .height = 36,
            .corner_radius = 8,
            .alignment = .{ .main = .center, .cross = .center },
            .cursor = .pointer,
            .on_click_handler = cx.command(AppState.toggleHistory),
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
