//! Settings icon toggle, in the toolbar next to `HistoryToggle`
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
const Lucide = @import("gooey-components").Lucide;

const state_mod = @import("../state.zig");
const constants = @import("constants.zig");
const icon = @import("icon.zig").icon;

const AppState = state_mod.AppState;

pub const SettingsToggle = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        cx.render(ui.box(.{
            .style = constants.toolbar_button,
            .on_click = cx.on(AppState.toggleSettings, .{}),
            .a11y = .{ .role = .button, .label = if (s.settings_expanded) "Back to chat" else "Settings" },
        }, .{
            if (s.settings_expanded) icon(.{ .path = Lucide.message_square, .size = 16, .stroke = .secondary, .stroke_width = 1 }) else icon(.{ .path = Lucide.settings, .size = 16, .stroke = .secondary, .stroke_width = 1 }),
        }));
    }
};
