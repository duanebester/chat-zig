//! Message display region: either the empty state or the message list.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Lucide = @import("gooey-components").Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const limits_mod = @import("../limits.zig");
const constants = @import("constants.zig");
const icon = @import("icon.zig").icon;
const MessageRow = @import("message.zig").MessageRow;
const PulseDot = @import("pulse_dot.zig").PulseDot;

const AppState = state_mod.AppState;

const CONTENT_PADDING = constants.CONTENT_PADDING;

/// Assistant text sits at the list's `CONTENT_PADDING` plus the bubble's own
/// 4px inset (see `MessageRow`). Matching that here means the thinking dot
/// occupies the spot the reply will appear in, so the eye doesn't have to
/// jump when text replaces it.
const THINKING_DOT_INSET: f32 = CONTENT_PADDING + 4;

/// 500 px window, less the column's and the list's padding.
const KEY_BANNER_WIDTH_MAX: f32 = 500 - 40 - CONTENT_PADDING * 2;

pub const ContentArea = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        if (s.message_count == 0) {
            cx.render(ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
                .alignment = .center,
                .gap = 16,
                .padding = .all(CONTENT_PADDING),
            } }, .{
                icon(.{ .path = Lucide.zap, .size = 48, .stroke = .primary }),
                ui.text("How can I help you today?", .{
                    .color = .text,
                    .size = 18,
                    .weight = .medium,
                }),
                if (s.has_api_key) null else KeyBanner{
                    .text = "Set ANTHROPIC_API_KEY to use Claude models",
                },
                if (s.has_openai_api_key) null else KeyBanner{
                    .text = "Set OPENAI_API_KEY to use GPT models & voice transcription",
                },
            }));
            return;
        }

        const first = transcriptStart(s);
        cx.render(ui.box(.{
            .key = .{ .name = "message-list" },
            .style = .{
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
                .padding = .{ .top = 8, .bottom = 16, .left = CONTENT_PADDING, .right = CONTENT_PADDING },
                .gap = 24,
                .scroll = .{},
            },
            .a11y = .{ .role = .list, .label = "Conversation" },
        }, .{
            if (first > 0) EarlierNote{ .count = first, .color = t.text_muted } else null,
            Transcript{ .first = first, .count = @intCast(s.message_count) },
        }));

        // Between `sendMessage` and the first streaming delta there is no
        // assistant bubble yet (`streaming_message_idx` is null — the
        // invariant is spelled out on that field in `state.zig`), so the
        // only other feedback is the send button turning into a stop
        // square. On a slow first token that's too subtle to read as
        // "working", hence the dot.
        if (s.is_loading and s.streaming_message_idx == null) {
            cx.render(ui.box(.{ .style = .{
                .direction = .row,
                .width = .{ .grow = 1 },
                .height = .{ .fixed = 24 },
                .padding = .{ .left = THINKING_DOT_INSET, .right = CONTENT_PADDING },
                .alignment = .center_cross,
            } }, .{
                PulseDot{ .color = t.text_secondary },
            }));
        }
    }
};

/// Index of the oldest message the list draws. Gooey emits every glyph in a
/// scroll box each frame, so the list draws the newest messages that fit in
/// `transcript_bytes_frame_max`, and always the newest one. Older turns are
/// still in history and still sent; only drawing stops.
fn transcriptStart(s: *const AppState) u32 {
    std.debug.assert(s.message_count > 0);
    var first: usize = s.message_count - 1;
    var bytes: usize = s.getMessage(first).?.content_len;
    std.debug.assert(bytes <= limits_mod.transcript_bytes_frame_max);
    while (first > 0) {
        const len = s.getMessage(first - 1).?.content_len;
        if (bytes + len > limits_mod.transcript_bytes_frame_max) break;
        bytes += len;
        first -= 1;
    }
    return @intCast(first);
}

const Transcript = struct {
    first: u32,
    count: u32,

    pub fn render(self: Transcript, cx: *Cx) void {
        std.debug.assert(self.first < self.count);
        std.debug.assert(self.count <= state_mod.MAX_MESSAGES);
        var index = self.first;
        while (index < self.count) : (index += 1) {
            cx.render(MessageRow{ .index = index });
        }
    }
};

const EarlierNote = struct {
    count: u32,
    color: gooey.Color,

    pub fn render(self: EarlierNote, cx: *Cx) void {
        var buffer: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&buffer, "{d} earlier messages not shown", .{self.count}) catch
            unreachable; // 64 bytes holds the template and any u32.
        cx.render(ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .alignment = .center } }, .{
            ui.text(label, .{ .color = .{ .rgba = self.color }, .size = 12 }),
        }));
    }
};

const KeyBanner = struct {
    text: []const u8,

    pub fn render(self: KeyBanner, cx: *Cx) void {
        const t = theme_mod.get(cx.state(AppState).dark_mode);
        cx.render(ui.box(.{
            .style = .{
                // A fit-width box does not shrink to its parent, so its text
                // only wraps under an explicit cap: the list's width in the
                // default 500 px window. Wider fonts (DejaVu on Linux) wrap.
                .width_max = KEY_BANNER_WIDTH_MAX,
                .padding = .symmetric(16, 10),
                .background = .{ .rgba = t.danger.withAlpha(0.1) },
                .corner_radius = .all(8),
            },
        }, .{
            ui.text(self.text, .{
                .color = .{ .rgba = t.danger },
                .size = 13,
                .wrap = .words,
                .alignment = .center,
            }),
        }));
    }
};
