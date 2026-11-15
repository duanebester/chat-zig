//! Root Layout for ChatAI
//!
//! Modern chat UI layout with:
//! - A toolbar (history, settings, dark/light toggle) across the top
//! - Clean full-width message display area
//! - Elegant input area card at bottom
//!
//! This file owns only the root composition. Everything with a `render`
//! method lives in `components/` — see `components/mod.zig`.

const builtin = @import("builtin");
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

/// Gooey's Wayland backend draws no title bar when the compositor offers no
/// server-side decorations (GNOME), and it turns any left press in the top
/// 32 px that the app did not handle into a window move. Clicks fire on
/// release, so a press on a toolbar button counts as unhandled and the move
/// grab swallows the click. Keep the toolbar below that strip on Linux.
const TOOLBAR_PADDING_TOP: f32 = if (builtin.os.tag == .linux) 34 else 6;

/// Bound to Cmd+Q and Ctrl+Q in `main.zig`'s keymap.
pub const Quit = struct {};

fn quit(_: *AppState, effects: *Effects) void {
    effects.quit();
}

pub fn render(cx: *Cx) void {
    const s = cx.state(AppState);

    // Apply completed worker results BEFORE anything reads `is_loading` or
    // `messages`, so no frame shows a half-updated conversation. Gooey has
    // no way for a worker to wake the event loop, so while one runs, keep
    // asking for frames and poll its queue in each.
    s.drainResults();
    if (s.workerInFlight()) cx.requestRenderAfter(state_mod.WORKER_POLL_MS);

    cx.render(ui.box(.{
        .style = .{
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .background = .bg,
        },
        .actions = &.{.{ .action = ui.action(Quit), .handler = cx.on(quit, .{}) }},
    }, .{
        // Toolbar. Gooey 0.4 cut the transparent, full-size-content titlebar
        // these icons used to float in, so they sit in a row of their own.
        ui.box(.{ .style = .{
            .direction = .row,
            .width = .{ .grow = 1 },
            .padding = .{ .top = TOOLBAR_PADDING_TOP, .right = 10, .left = 10 },
            .gap = 2,
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
