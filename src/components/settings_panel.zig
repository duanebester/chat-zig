//! Full-length settings view.
//!
//! Shown by `layout.zig` in place of `ContentArea` (and `InputArea`) while
//! `AppState.settings_expanded` is true — toggled via `SettingsToggle` in the
//! titlebar toolbar, mirroring how `HistoryToggle`/`HistoryPanel` work.
//! Mutually exclusive with the history view: opening one closes the other,
//! see `AppState.toggleSettings` and `AppState.toggleHistory`.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");
const ModelSelector = @import("model_selector.zig").ModelSelector;
const DictationModelSelector = @import("dictation_model_selector.zig").DictationModelSelector;
const MicrophoneSettings = @import("microphone_settings.zig").MicrophoneSettings;
const ThemeSelector = @import("theme_selector.zig").ThemeSelector;

const AppState = state_mod.AppState;

const CONTENT_PADDING = constants.CONTENT_PADDING;
const SETTINGS_ROW_GAP: f32 = 10.0;
const SETTINGS_CARD_CORNER_RADIUS: f32 = 10;
const SETTINGS_CARD_PADDING: f32 = 16.0;

pub const SettingsPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .padding = .{ .top = 4, .bottom = 12, .left = CONTENT_PADDING, .right = CONTENT_PADDING },
        } }, .{
            ui.text("Settings", .{ .color = .text, .size = 16, .weight = .medium }),
        }));

        cx.render(ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .gap = SETTINGS_ROW_GAP,
            .padding = .{ .bottom = 16, .left = CONTENT_PADDING, .right = CONTENT_PADDING },
        } }, .{
            Card(ModelSelector){ .title = "Chat model" },
            // The dictation model card only renders when an OpenAI key is
            // configured (`DictationModelSelector`'s own rationale), so the
            // page doesn't show a picker with nothing to pick from.
            if (s.has_openai_api_key) Card(DictationModelSelector){ .title = "Dictation model" } else null,
            Card(MicrophoneSettings){ .title = "Microphone" },
            Card(ThemeSelector){ .title = "Theme" },
        }));
    }
};

/// A titled settings card around one control.
fn Card(comptime Control: type) type {
    return struct {
        title: []const u8,

        pub fn render(self: @This(), cx: *Cx) void {
            const t = theme_mod.get(cx.state(AppState).theme);
            cx.render(ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .gap = 8,
                .padding = .all(SETTINGS_CARD_PADDING),
                .background = .{ .rgba = t.card },
                .border = .{ .width = 1, .color = .{ .rgba = t.border } },
                .corner_radius = .all(SETTINGS_CARD_CORNER_RADIUS),
            } }, .{
                ui.text(self.title, .{ .color = .subtext, .size = 12, .weight = .medium }),
                Control{},
            }));
        }
    };
}
