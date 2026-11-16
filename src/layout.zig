//! Root Layout for ChatAI
//!
//! Modern chat UI layout with:
//! - A toolbar (history, settings, dark/light toggle) across the top, in
//!   the title bar beside the traffic lights on macOS
//! - Clean full-width message display area
//! - Elegant input area card at bottom
//!
//! This file owns only the root composition. Everything with a `render`
//! method lives in `components/` — see `components/mod.zig`.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const Effects = gooey.Effects;
const ui = gooey.ui;

const state_mod = @import("state.zig");
const components = @import("components/mod.zig");

const AppState = state_mod.AppState;

const ContentArea = components.ContentArea;
const HistoryPanel = components.HistoryPanel;
const HistoryToggle = components.HistoryToggle;
const InputArea = components.InputArea;
const SettingsPanel = components.SettingsPanel;
const SettingsToggle = components.SettingsToggle;
const ThemeToggle = components.ThemeToggle;

const CHAT_MIN_WIDTH = components.constants.CHAT_MIN_WIDTH;
const TOOLBAR_PADDING_X = components.constants.TOOLBAR_PADDING_X;

/// Bound to Cmd+Q and Ctrl+Q in `main.zig`'s keymap.
pub const Quit = struct {};

fn quit(_: *AppState, effects: *Effects) void {
    effects.quit();
}

pub fn render(cx: *Cx) void {
    const s = cx.state(AppState);
    // macOS draws its title bar over the content (`main.zig`'s
    // `.title_bar = .transparent`); elsewhere the inset is zero.
    const strip = cx.titleBarInset();

    cx.render(ui.box(.{
        .style = .{
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .background = .bg,
        },
        .actions = &.{.{ .action = ui.action(Quit), .handler = cx.on(quit, .{}) }},
    }, .{
        // Toolbar. On macOS the row is the title strip itself, so the icons
        // sit on the traffic lights' line, clear of the lights. Empty space
        // in it still moves the window; the buttons claim their presses.
        // Linux without server decorations moves the window from its top
        // 32 px the same way, so the toolbar can sit there too.
        ui.box(.{ .style = .{
            .direction = .row,
            .width = .{ .grow = 1 },
            .padding = .{
                .top = if (strip.top > 0) 0 else 6,
                .right = TOOLBAR_PADDING_X + strip.right,
                .left = TOOLBAR_PADDING_X + strip.left,
            },
            .gap = components.constants.TOOLBAR_GAP,
            .alignment = .{ .main = .end, .cross = .center },
        } }, .{
            HistoryToggle{},
            SettingsToggle{},
            ThemeToggle{},
        }),
        // Chat column (grows to fill, with a minimum width so it doesn't collapse)
        ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .width_min = CHAT_MIN_WIDTH,
            .height = .{ .grow = 1 },
            .padding = .{ .top = 4, .bottom = 20, .left = 20, .right = 20 },
        } }, .{
            // Content area: the message list, or (when the history or
            // settings icon is selected) a full-length view in its place.
            // The input area only makes sense against the live chat, so it
            // hides along with `ContentArea` while browsing history or
            // settings. `history_expanded` and `settings_expanded` are kept
            // mutually exclusive by `AppState.toggleHistory`/`toggleSettings`.
            ui.when(!s.history_expanded and !s.settings_expanded, chat),
            ui.when(s.history_expanded, history),
            ui.when(s.settings_expanded, settings),
        }),
    }));
}

fn chat(cx: *Cx) void {
    cx.render(.{ ContentArea{}, InputArea{} });
}

fn history(cx: *Cx) void {
    cx.render(HistoryPanel{});
}

fn settings(cx: *Cx) void {
    cx.render(SettingsPanel{});
}
