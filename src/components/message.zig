//! Message row rendering and height measurement for the virtual list.
//!
//! `render` is the callback handed to `cx.lists.virtual`, so it has to both
//! draw the row and return its height. Heights are cached on `AppState` and
//! invalidated when the theme or window width changes, because a re-measure
//! costs a full text shaping pass per message.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Svg = gooey.components.Svg;
const Lucide = gooey.components.Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");

const AppState = state_mod.AppState;
const Message = state_mod.Message;

const BUBBLE_CORNER_RADIUS = constants.BUBBLE_CORNER_RADIUS;
const MESSAGE_HORIZONTAL_CHROME = constants.MESSAGE_HORIZONTAL_CHROME;

/// Virtual-list row callback: draws message `index` and returns its height.
pub fn render(index: u32, cx: *Cx) f32 {
    const s = cx.state(AppState);
    const message_index: usize = @intCast(index);
    const msg = s.getMessage(message_index) orelse return 0;
    const is_user = msg.role == .user;

    const max_bubble_width = cx.windowSize().width - MESSAGE_HORIZONTAL_CHROME;

    var height = s.getMessageCachedHeight(message_index);
    if (height <= 0.0) {
        height = if (is_user)
            measureUserMessageHeight(cx, msg, max_bubble_width)
        else
            measureAssistantMessageHeight(cx, msg, max_bubble_width);
        s.setMessageCachedHeight(message_index, height);
    }

    if (is_user) {
        renderUserMessage(msg, s.dark_mode, max_bubble_width, cx);
    } else {
        renderAssistantMessage(msg, s.dark_mode, max_bubble_width, cx);
    }

    return height;
}

/// Measure user message height using the platform text shaper (CoreText/HarfBuzz/browser).
/// Falls back to character-width heuristic if measureText is unavailable.
fn measureUserMessageHeight(cx: *Cx, msg: *const Message, max_width: f32) f32 {
    const has_attachment = msg.hasAttachment();
    const h_padding: f32 = 32.0; // .symmetric = .{ .x = 16, .y = 14 } → 16 * 2
    const v_padding: f32 = 28.0; // 14 * 2

    const m = cx.measureText(msg.getText(), .{
        .max_width = max_width - h_padding,
        .font_size = 15,
    }) catch {
        return fallbackUserHeight(msg, max_width);
    };

    var height = m.height + v_padding;
    if (has_attachment) {
        height += 32.0; // chip height + gap
    }
    return height;
}

/// Measure assistant message height using the platform text shaper.
/// Falls back to character-width heuristic if measureText is unavailable.
fn measureAssistantMessageHeight(cx: *Cx, msg: *const Message, max_width: f32) f32 {
    const h_padding: f32 = 8.0; // .symmetric = .{ .x = 4 } → 4 * 2

    const m = cx.measureText(msg.getText(), .{
        .max_width = max_width - h_padding,
        .font_size = 15,
    }) catch {
        return fallbackAssistantHeight(msg, max_width);
    };

    return m.height;
}

// ── Fallback heuristics (used when measureText is unavailable) ───────────

fn fallbackUserHeight(msg: *const Message, max_width: f32) f32 {
    const chars_per_line: usize = @max(1, @as(usize, @intFromFloat(max_width / 8.0)));
    const lines: usize = @max(1, (msg.content_len + chars_per_line - 1) / chars_per_line);
    var height: f32 = @as(f32, @floatFromInt(lines)) * 24.0 + 32.0;
    if (msg.hasAttachment()) {
        height += 32.0;
    }
    return height;
}

fn fallbackAssistantHeight(msg: *const Message, max_width: f32) f32 {
    const chars_per_line: usize = @max(1, @as(usize, @intFromFloat(max_width / 8.0)));
    const lines: usize = @max(1, (msg.content_len + chars_per_line - 1) / chars_per_line);
    return @as(f32, @floatFromInt(lines)) * 24.0 + 16.0;
}

fn renderUserMessage(msg: *const Message, dark_mode: bool, max_width: f32, cx: *Cx) void {
    const t = theme_mod.get(dark_mode);
    const text_content = msg.getText();
    const has_attachment = msg.hasAttachment();

    // User message in a rounded box with subtle border
    cx.render(ui.box(.{
        .max_width = max_width,
        .padding = .{ .symmetric = .{ .x = 16, .y = 14 } },
        .background = t.user_bubble,
        .border_color = t.user_bubble_border,
        .border_width = .{ .all = 1 },
        .corner_radius = BUBBLE_CORNER_RADIUS,
    }, .{
        ui.box(.{ .direction = .column, .gap = 10 }, .{
            // File attachment chip (if present)
            ui.when(has_attachment, .{
                ui.box(.{
                    .padding = .{ .symmetric = .{ .x = 10, .y = 6 } },
                    .background = t.file_chip_bg,
                    .corner_radius = 8,
                }, .{
                    ui.box(.{ .direction = .row, .gap = 6, .alignment = .{ .main = .start, .cross = .center } }, .{
                        // File icon
                        Svg{
                            .path = Lucide.file,
                            .size = 14,
                            .no_fill = true,
                            .stroke_color = t.file_chip_icon,
                            .stroke_width = 1.5,
                        },
                        ui.text(msg.getAttachedFileName(), .{
                            .color = t.file_chip_text,
                            .size = 13,
                            .weight = .medium,
                        }),
                    }),
                }),
            }),
            // Message text
            ui.text(text_content, .{
                .color = t.text,
                .size = 15,
                .wrap = .words,
            }),
        }),
    }));
}

fn renderAssistantMessage(msg: *const Message, dark_mode: bool, max_width: f32, cx: *Cx) void {
    const t = theme_mod.get(dark_mode);
    const text_content = msg.getText();

    // Assistant response - plain text, no bubble
    cx.render(ui.box(.{
        .max_width = max_width,
        .padding = .{ .symmetric = .{ .x = 4, .y = 0 } },
    }, .{
        ui.text(text_content, .{
            .color = t.text_secondary,
            .size = 15,
            .wrap = .words,
        }),
    }));
}
