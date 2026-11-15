//! Input device picker plus refresh button, shown in the settings panel.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Handler = gooey.Handler;
const components = @import("gooey-components");
const Lucide = components.Lucide;
const Select = components.Select;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");
const audio = @import("../audio/mod.zig");
const icon = @import("icon.zig").icon;

const AppState = state_mod.AppState;

const BUTTON_CORNER_RADIUS = constants.BUTTON_CORNER_RADIUS;

pub const MicrophoneSettings = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);
        const options = s.microphone.options();

        var on_select: [audio.MAX_INPUT_DEVICES]Handler = undefined;
        std.debug.assert(options.len <= on_select.len);
        for (on_select[0..options.len], 0..) |*handler, index| {
            handler.* = cx.on(AppState.selectMicrophone, .{ .arg = @as(u32, @intCast(index)) });
        }

        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .width = .{ .grow = 1 },
            .gap = 10,
            .alignment = .center_cross,
        } }, .{
            icon(.{ .path = Lucide.mic, .size = 16, .stroke = .secondary }),
            Select{
                .key = "microphone-select",
                .options = options,
                .on_select = on_select[0..options.len],
                .on_toggle = cx.on(AppState.toggleSelect, .{ .arg = state_mod.SelectId.microphone }),
                .on_close = cx.on(AppState.closeSelect, .{ .arg = state_mod.SelectId.microphone }),
                .selected = s.microphone.selected,
                .open = s.open_select == .microphone,
                .placeholder = "No microphones",
                .disabled = options.len == 0,
                .width = 240,
                .accessible_name = "Microphone",
            },
            ui.box(.{
                .style = .{
                    .width = .{ .fixed = 28 },
                    .height = .{ .fixed = 28 },
                    .corner_radius = .all(BUTTON_CORNER_RADIUS),
                    .alignment = .center,
                    .cursor = if (s.recording.active) null else .pointer,
                },
                .on_click = if (s.recording.active) null else cx.on(AppState.refreshMicrophones, .{}),
                .a11y = .{ .role = .button, .label = "Refresh microphones", .disabled = s.recording.active },
            }, .{
                icon(.{ .path = Lucide.refresh_cw, .size = 14, .stroke = .secondary }),
            }),
        }));

        if (s.recording.last_error) |capture_error| {
            cx.render(ui.text(@errorName(capture_error), .{ .color = .{ .rgba = t.danger }, .size = 12 }));
        }
    }
};
