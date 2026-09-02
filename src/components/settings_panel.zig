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

const AppState = state_mod.AppState;

const CONTENT_PADDING = constants.CONTENT_PADDING;
const SETTINGS_ROW_GAP: f32 = 10.0;
const SETTINGS_CARD_CORNER_RADIUS = 10;
const SETTINGS_CARD_PADDING: f32 = 16.0;

pub const SettingsPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .each = .{ .top = 4, .bottom = 12, .left = CONTENT_PADDING, .right = CONTENT_PADDING } },
        }, .{
            ui.text("Settings", .{ .color = t.text, .size = 16, .weight = .medium }),
        }));

        cx.render(ui.box(.{
            .fill_width = true,
            .direction = .column,
            .gap = SETTINGS_ROW_GAP,
            .padding = .{ .each = .{ .top = 0, .bottom = 16, .left = CONTENT_PADDING, .right = CONTENT_PADDING } },
        }, .{
            ui.box(.{
                .fill_width = true,
                .direction = .column,
                .gap = 8,
                .padding = .{ .all = SETTINGS_CARD_PADDING },
                .background = t.card,
                .border_color = t.border,
                .border_width = .{ .all = 1 },
                .corner_radius = SETTINGS_CARD_CORNER_RADIUS,
            }, .{
                ui.text("Chat model", .{ .color = t.text_secondary, .size = 12, .weight = .medium }),
                ModelSelector{},
            }),
            // The dictation model card only renders when an OpenAI key is
            // configured (`DictationModelSelector`'s own rationale), so the
            // page doesn't show a picker with nothing to pick from.
            ui.when(s.has_openai_api_key, .{
                ui.box(.{
                    .fill_width = true,
                    .direction = .column,
                    .gap = 8,
                    .padding = .{ .all = SETTINGS_CARD_PADDING },
                    .background = t.card,
                    .border_color = t.border,
                    .border_width = .{ .all = 1 },
                    .corner_radius = SETTINGS_CARD_CORNER_RADIUS,
                }, .{
                    ui.text("Dictation model", .{ .color = t.text_secondary, .size = 12, .weight = .medium }),
                    DictationModelSelector{},
                }),
            }),
            ui.box(.{
                .fill_width = true,
                .direction = .column,
                .gap = 8,
                .padding = .{ .all = SETTINGS_CARD_PADDING },
                .background = t.card,
                .border_color = t.border,
                .border_width = .{ .all = 1 },
                .corner_radius = SETTINGS_CARD_CORNER_RADIUS,
            }, .{
                ui.text("Microphone", .{ .color = t.text_secondary, .size = 12, .weight = .medium }),
                MicrophoneSettings{},
            }),
        }));
    }
};
