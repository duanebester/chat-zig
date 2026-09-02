//! Root Layout for ChatAI
//!
//! Modern chat UI layout with:
//! - Dark/light mode toggle in header
//! - Clean full-width message display area
//! - Elegant input area card at bottom
//!
//! This file owns only the root composition. Everything with a `render`
//! method lives in `components/` — see `components/mod.zig`.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;

const state_mod = @import("state.zig");
const theme_mod = @import("theme.zig");
const thinking_shader = @import("thinking_shader.zig");
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

pub fn render(cx: *Cx) void {
    const s = cx.state(AppState);

    // Drain any completed async worker results BEFORE reading other fields.
    // Workers push WorkerResult values into an Io.Queue on completion; the
    // render loop is the only consumer. Draining here flips `is_loading`
    // off and appends the assistant's reply into the message ring before
    // any child component reads from either — no half-updated frame.
    s.drainResults(cx);

    const size = cx.windowSize();
    const t = theme_mod.get(s.dark_mode);

    // Gate the full-frame rim glow. Unlike the thinking dot in `ContentArea`,
    // this stays lit for the whole request including streaming: the dot marks
    // "no reply yet", the glow marks "the app is busy", and the latter is
    // still true while deltas are landing.
    thinking_shader.drive(cx, s.is_loading, t.accent);

    if (cx.changed("dark_mode", s.dark_mode) or cx.changed("window_width", size.width)) {
        s.invalidateCachedHeights();
    }

    // Main container - full window
    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = t.bg,
        .direction = .row,
    }, .{
        // Chat column (grows to fill, with a minimum width so it doesn't collapse)
        ui.box(.{
            .grow = true,
            .min_width = CHAT_MIN_WIDTH,
            .height = size.height,
            .direction = .column,
            .padding = .{ .each = .{ .top = 52, .bottom = 20, .left = 20, .right = 20 } },
        }, .{
            // Content area: the message list, or (when the history or
            // settings icon is selected) a full-length view in its place.
            // The input area only makes sense against the live chat, so it
            // hides along with `ContentArea` while browsing history or
            // settings. `history_expanded` and `settings_expanded` are kept
            // mutually exclusive by `AppState.toggleHistory`/`toggleSettings`.
            ui.when(!s.history_expanded and !s.settings_expanded, .{ ContentArea{}, InputArea{} }),
            ui.when(s.history_expanded, .{HistoryPanel{}}),
            ui.when(s.settings_expanded, .{SettingsPanel{}}),
        }),
        // Toolbar — floating in titlebar area (top-right of viewport)
        ui.box(.{
            .floating = .{
                .attach_to_parent = false,
                .element_anchor = .right_top,
                .parent_anchor = .right_top,
                .offset_x = -4,
                .offset_y = 0,
                .z_index = 200,
            },
            .direction = .row,
            .gap = 2,
        }, .{
            HistoryToggle{},
            SettingsToggle{},
            ThemeToggle{},
        }),
    }));
}
