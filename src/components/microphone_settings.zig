//! Input device picker plus refresh button, shown in the settings panel.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Svg = gooey.components.Svg;
const Lucide = gooey.components.Lucide;
const Select = gooey.components.Select;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");

const AppState = state_mod.AppState;

const BUTTON_CORNER_RADIUS = constants.BUTTON_CORNER_RADIUS;

pub const MicrophoneSettings = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        cx.render(ui.box(.{ .fill_width = true, .direction = .row, .gap = 8, .alignment = .{ .main = .start, .cross = .center } }, .{
            Svg{ .path = Lucide.mic, .size = 16, .no_fill = true, .stroke_color = t.icon_muted, .stroke_width = 1.5 },
            Select{
                .id = "microphone-select",
                .options = s.microphone.options(),
                .selected = s.microphone.selected,
                .placeholder = "No microphones found",
                .width = 240,
                .background = t.card,
                .border_color = t.border,
                .focus_border_color = t.primary,
                .text_color = t.text_secondary,
                .hover_background = t.border,
                .option_hover_background = t.border,
                .selected_background = t.primary.withAlpha(0.15),
                .on_select = cx.onSelect(AppState.selectMicrophone),
            },
            ui.box(.{
                .width = 28,
                .height = 28,
                .corner_radius = BUTTON_CORNER_RADIUS,
                .alignment = .{ .main = .center, .cross = .center },
                .cursor = if (s.recording.active) null else .pointer,
                .on_click_handler = if (s.recording.active) null else cx.command(AppState.refreshMicrophones),
            }, .{
                Svg{ .path = Lucide.refresh_cw, .size = 14, .no_fill = true, .stroke_color = t.icon_muted, .stroke_width = 1.5 },
            }),
        }));

        if (s.recording.last_error) |capture_error| {
            cx.render(ui.text(@errorName(capture_error), .{ .color = t.danger, .size = 12 }));
        }
    }
};
