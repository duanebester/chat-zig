//! Action row at the bottom of the composer card: attach, the live
//! microphone meter, and the record/send buttons.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Lucide = @import("gooey-components").Lucide;

const state_mod = @import("../state.zig");
const constants = @import("constants.zig");
const icon = @import("icon.zig").icon;
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
        const can_record = (s.microphone.selected != null or s.recording.active) and !s.is_transcribing;

        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .width = .{ .grow = 1 },
            .padding = .{ .top = 8, .right = 12, .bottom = 12, .left = 12 },
            .gap = 8,
            .alignment = .center_cross,
        } }, .{
            ui.box(.{
                .style = .{
                    .width = .{ .fixed = ACTION_BUTTON_SIZE },
                    .height = .{ .fixed = ACTION_BUTTON_SIZE },
                    .corner_radius = .all(BUTTON_CORNER_RADIUS),
                    .alignment = .center,
                    .cursor = .pointer,
                },
                .on_click = cx.on(AppState.openFileDialog, .{}),
                .a11y = .{ .role = .button, .label = "Attach file" },
            }, .{
                icon(.{ .path = Lucide.paperclip, .size = ACTION_ICON_SIZE, .stroke = .secondary }),
            }),
            // Spacer: pushes the meter and buttons to the right edge.
            ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{}),
            MicrophoneMeter{},
            RecordButton{ .enabled = can_record },
            SendButton{},
        }));
    }
};
