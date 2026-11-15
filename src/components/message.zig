//! One message in the transcript: the user's bubble or the assistant's
//! plain text, as a row of the transcript's `List`.
//!
//! The list builds only the rows in view, so it asks each row's height up
//! front: `height` measures the message's text with `cx.measureText` at the
//! row's width, in the same styles and padding `render` draws with, as Gooey
//! 0.2.9's virtual list did. Gooey caches each measured size, so only a
//! streaming reply is re-wrapped as it grows.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Lucide = @import("gooey-components").Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");
const icon = @import("icon.zig").icon;

const AppState = state_mod.AppState;
const Message = state_mod.Message;

const BUBBLE_CORNER_RADIUS = constants.BUBBLE_CORNER_RADIUS;
const MESSAGE_TEXT_SIZE: u16 = 15;

/// Padding and gaps `render` draws with, which `height` adds up.
const USER_PADDING_X: f32 = 16;
const USER_PADDING_Y: f32 = 14;
const USER_GAP: f32 = 10;
const ASSISTANT_PADDING_X: f32 = 4;
const CHIP_PADDING_X: f32 = 10;
const CHIP_PADDING_Y: f32 = 6;
const CHIP_ICON_SIZE: f32 = 14;

const message_text: ui.Text = .{ .size = MESSAGE_TEXT_SIZE, .wrap = .words };
const chip_text: ui.Text = .{ .size = 13, .weight = .medium };

pub const MessageRow = struct {
    index: u32,

    pub const count_max: u32 = state_mod.MAX_MESSAGES;

    /// The row's height at `width`: its text wrapped at the width less the
    /// row's padding, plus that padding, and the attachment chip above a
    /// user's text when there is one.
    pub fn height(cx: *Cx, index: u32, width: f32) f32 {
        std.debug.assert(width >= 0);
        const s = cx.state(AppState);
        const msg = s.getMessage(index) orelse return 0;
        switch (msg.role) {
            .user => {
                const text_width = @max(0, width - USER_PADDING_X * 2);
                const body = cx.measureText(msg.getText(), message_text, text_width);
                var total = body.height + USER_PADDING_Y * 2;
                if (msg.hasAttachment()) {
                    const name = cx.measureText(msg.getAttachedFileName(), chip_text, text_width);
                    total += @max(name.height, CHIP_ICON_SIZE) + CHIP_PADDING_Y * 2 + USER_GAP;
                }
                return total;
            },
            .assistant, .system => {
                const text_width = @max(0, width - ASSISTANT_PADDING_X * 2);
                return cx.measureText(msg.getText(), message_text, text_width).height;
            },
        }
    }

    pub fn render(self: MessageRow, cx: *Cx) void {
        const s = cx.state(AppState);
        const msg = s.getMessage(self.index) orelse return;
        const t = theme_mod.get(s.dark_mode);
        switch (msg.role) {
            .user => renderUser(cx, msg, t),
            .assistant, .system => cx.render(ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
                .padding = .symmetric(ASSISTANT_PADDING_X, 0),
            } }, .{
                MessageText{ .text = msg.getText(), .color = t.text_secondary },
            })),
        }
    }
};

fn renderUser(cx: *Cx, msg: *const Message, t: theme_mod.Theme) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .symmetric(USER_PADDING_X, USER_PADDING_Y),
        .gap = USER_GAP,
        .background = .{ .rgba = t.user_bubble },
        .border = .{ .width = 1, .color = .{ .rgba = t.user_bubble_border } },
        .corner_radius = .all(BUBBLE_CORNER_RADIUS),
    } }, .{
        if (msg.hasAttachment()) AttachmentChip{ .name = msg.getAttachedFileName() } else null,
        MessageText{ .text = msg.getText(), .color = t.text },
    }));
}

const AttachmentChip = struct {
    name: []const u8,

    pub fn render(self: AttachmentChip, cx: *Cx) void {
        const t = theme_mod.get(cx.state(AppState).dark_mode);
        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .padding = .symmetric(CHIP_PADDING_X, CHIP_PADDING_Y),
            .gap = 6,
            .alignment = .center_cross,
            .background = .{ .rgba = t.file_chip_bg },
            .corner_radius = .all(8),
        } }, .{
            icon(.{ .path = Lucide.file, .size = CHIP_ICON_SIZE, .stroke = .accent }),
            ui.text(self.name, chip_style: {
                var style = chip_text;
                style.color = .{ .rgba = t.file_chip_text };
                break :chip_style style;
            }),
        }));
    }
};

/// Wrapped message text. Gooey splits a text past one shaping run itself,
/// so a reply of any length is one `ui.text`.
pub const MessageText = struct {
    text: []const u8,
    color: gooey.Color,

    pub fn render(self: MessageText, cx: *Cx) void {
        var style = message_text;
        style.color = .{ .rgba = self.color };
        cx.render(ui.text(self.text, style));
    }
};
