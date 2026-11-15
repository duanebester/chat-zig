//! One message in the transcript: the user's bubble or the assistant's
//! plain text.
//!
//! Gooey 0.2.9 measured each row up front for a virtual list. Gooey 0.5's
//! `List` still needs every row's height before layout, but render has no
//! text measurement, so the transcript is a plain scroll box and layout wraps
//! each message itself (see `ContentArea` for how its size is bounded).

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Lucide = @import("gooey-components").Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");
const icon = @import("icon.zig").icon;
const text_chunk = @import("../text_chunk.zig");

const AppState = state_mod.AppState;
const Message = state_mod.Message;

const BUBBLE_CORNER_RADIUS = constants.BUBBLE_CORNER_RADIUS;
const MESSAGE_TEXT_SIZE: u16 = 15;

comptime {
    // `text_chunk.zig` stays gooey-free so `zig build test` can run it;
    // this pins its limit to the one Gooey enforces.
    std.debug.assert(text_chunk.codepoint_count_max == gooey.text.run_codepoint_count_max);
}

pub const MessageRow = struct {
    index: u32,

    pub fn render(self: MessageRow, cx: *Cx) void {
        const s = cx.state(AppState);
        const msg = s.getMessage(self.index) orelse return;
        const t = theme_mod.get(s.dark_mode);
        switch (msg.role) {
            .user => renderUser(cx, msg, t),
            .assistant, .system => cx.render(ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .padding = .symmetric(4, 0),
            } }, .{
                MessageText{ .text = msg.getText(), .color = t.text_secondary },
            })),
        }
    }
};

fn renderUser(cx: *Cx, msg: *const Message, t: theme_mod.Theme) void {
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .padding = .symmetric(16, 14),
        .gap = 10,
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
            .padding = .symmetric(10, 6),
            .gap = 6,
            .alignment = .center_cross,
            .background = .{ .rgba = t.file_chip_bg },
            .corner_radius = .all(8),
        } }, .{
            icon(.{ .path = Lucide.file, .size = 14, .stroke = .accent }),
            ui.text(self.name, .{
                .color = .{ .rgba = t.file_chip_text },
                .size = 13,
                .weight = .medium,
            }),
        }));
    }
};

/// Wrapped message text, as one `ui.text` per chunk of at most
/// `text_chunk.codepoint_count_max` codepoints: Gooey shapes a text as one
/// run and panics past that, and replies run longer. Chunks end at a line break where
/// one is in reach, so a split is invisible; only a single paragraph longer
/// than a chunk breaks its line early, at a space.
pub const MessageText = struct {
    text: []const u8,
    color: gooey.Color,

    pub fn render(self: MessageText, cx: *Cx) void {
        var rest = self.text;
        // Each pass consumes at least one byte, so this ends; the bound is
        // the bytes themselves.
        var pass: usize = 0;
        while (rest.len > 0) : (pass += 1) {
            std.debug.assert(pass < self.text.len);
            const split = text_chunk.next(rest);
            std.debug.assert(split.skip_len >= split.text_len);
            cx.render(ui.text(rest[0..split.text_len], .{
                .color = .{ .rgba = self.color },
                .size = MESSAGE_TEXT_SIZE,
                .wrap = .words,
            }));
            rest = rest[split.skip_len..];
        }
    }
};
