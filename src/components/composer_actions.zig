//! Action row at the bottom of the composer card: attach, the live
//! microphone meter, and the record/send buttons.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Svg = gooey.components.Svg;
const Lucide = gooey.components.Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");
const MicrophoneMeter = @import("microphone_meter.zig").MicrophoneMeter;
const RecordButton = @import("record_button.zig").RecordButton;
const SendButton = @import("send_button.zig").SendButton;

const AppState = state_mod.AppState;

const ACTION_BUTTON_SIZE = constants.ACTION_BUTTON_SIZE;
const ACTION_ICON_SIZE = constants.ACTION_ICON_SIZE;
const BUTTON_CORNER_RADIUS = constants.BUTTON_CORNER_RADIUS;

pub const ComposerActions = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);
        const can_record = (s.microphone.selected != null or s.recording.active) and !s.is_transcribing;

        if (s.recording.active) cx.window().requestRender();

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .each = .{ .top = 8, .right = 12, .bottom = 12, .left = 12 } },
            .direction = .row,
            .gap = 8,
            .alignment = .{ .main = .start, .cross = .center },
        }, .{
            ui.box(.{
                .width = ACTION_BUTTON_SIZE,
                .height = ACTION_BUTTON_SIZE,
                .corner_radius = BUTTON_CORNER_RADIUS,
                .alignment = .{ .main = .center, .cross = .center },
                .cursor = .pointer,
                .on_click_handler = cx.command(AppState.openFileDialog),
            }, .{
                Svg{ .path = Lucide.paperclip, .size = ACTION_ICON_SIZE, .no_fill = true, .stroke_color = t.icon_muted, .stroke_width = 1.5 },
            }),
            ui.spacer(),
            MicrophoneMeter{},
            RecordButton{ .enabled = can_record },
            SendButton{},
        }));
    }
};
