//! Message display region: either the empty state or the message list.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const components = @import("gooey-components");
const Lucide = components.Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
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
            s.message_list_id = null;
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

        // The whole conversation, built only where it is in view and kept
        // at its newest message while the reader is there: a streamed reply
        // scrolls into view as it grows, and scrolling up releases it.
        cx.render(ui.box(.{
            .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } },
            .a11y = .{ .role = .list, .label = "Conversation" },
        }, .{
            TranscriptList{ .count = @intCast(s.message_count) },
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

/// The transcript `List`, built inside the box that labels it for screen
/// readers, so it records the list's id there for `sendMessage`.
const TranscriptList = struct {
    count: u32,

    pub fn render(self: TranscriptList, cx: *Cx) void {
        std.debug.assert(self.count > 0);
        std.debug.assert(self.count <= state_mod.MAX_MESSAGES);
        const key = "message-list";
        cx.state(AppState).message_list_id = cx.id(.{ .name = key });
        cx.render(components.List(MessageRow){
            .key = key,
            .count = self.count,
            .gap = 24,
            .anchor = .end,
            .style = .{ .padding = .{
                .top = 8,
                .bottom = 16,
                .left = CONTENT_PADDING,
                .right = CONTENT_PADDING,
            } },
        });
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
