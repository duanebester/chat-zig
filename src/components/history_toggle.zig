//! History icon toggle, in the toolbar next to `ThemeToggle`.
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
const Lucide = @import("gooey-components").Lucide;

const state_mod = @import("../state.zig");
const constants = @import("constants.zig");
const icon = @import("icon.zig").icon;

const AppState = state_mod.AppState;

pub const HistoryToggle = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        cx.render(ui.box(.{
            .style = constants.toolbar_button,
            .on_click = cx.on(AppState.toggleHistory, .{}),
            .a11y = .{ .role = .button, .label = if (s.history_expanded) "Back to chat" else "History" },
        }, .{
            if (s.history_expanded) icon(.{ .path = Lucide.message_square, .size = 16, .stroke = .secondary, .stroke_width = 1 }) else icon(.{ .path = Lucide.history, .size = 16, .stroke = .secondary, .stroke_width = 1 }),
        }));
    }
};
