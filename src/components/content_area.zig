//! Message display region: either the empty state or the virtual message list.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Color = gooey.Color;
const Svg = gooey.components.Svg;
const Lucide = gooey.components.Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");
const message = @import("message.zig");
const PulseDot = @import("pulse_dot.zig").PulseDot;

const AppState = state_mod.AppState;

const CONTENT_PADDING = constants.CONTENT_PADDING;

/// Assistant text sits at the list's `CONTENT_PADDING` plus the bubble's own
/// 4px inset (see `renderAssistantMessage`). Matching that here means the
/// thinking dot occupies the spot the reply will appear in, so the eye
/// doesn't have to jump when text replaces it.
const THINKING_DOT_INSET: f32 = CONTENT_PADDING + 4;

pub const ContentArea = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        if (s.message_count == 0) {
            // Empty state - centered in available space
            cx.render(ui.box(.{
                .grow = true,
                .fill_width = true,
                .alignment = .{ .main = .center, .cross = .center },
                .direction = .column,
                .gap = 16,
                .padding = .{ .all = CONTENT_PADDING },
            }, .{
                Svg{ .path = Lucide.zap, .size = 48, .no_fill = true, .stroke_color = t.primary, .stroke_width = 1.5 },
                ui.text("How can I help you today?", .{
                    .color = t.text,
                    .size = 18,
                    .weight = .medium,
                }),
                ui.when(!s.has_api_key, .{
                    ui.box(.{
                        .padding = .{ .symmetric = .{ .x = 16, .y = 10 } },
                        .background = t.danger.withAlpha(0.1),
                        .corner_radius = 8,
                    }, .{
                        ui.text("Set ANTHROPIC_API_KEY to use Claude models", .{
                            .color = t.danger,
                            .size = 13,
                        }),
                    }),
                }),
                ui.when(!s.has_openai_api_key, .{
                    ui.box(.{
                        .padding = .{ .symmetric = .{ .x = 16, .y = 10 } },
                        .background = t.danger.withAlpha(0.1),
                        .corner_radius = 8,
                    }, .{
                        ui.text("Set OPENAI_API_KEY to use GPT models & voice transcription", .{
                            .color = t.danger,
                            .size = 13,
                        }),
                    }),
                }),
            }));
            return;
        }

        // Message list with virtual scrolling
        cx.lists.virtual(
            "message-list",
            &s.list_state,
            .{
                .fill_width = true,
                .grow_height = true,
                .padding = .{ .each = .{ .top = 8, .bottom = 16, .left = CONTENT_PADDING, .right = CONTENT_PADDING } },
                .gap = 24,
                .background = Color.transparent,
            },
            message.render,
        );

        // Between `sendMessage` and the first streaming delta there is no
        // assistant bubble yet (`streaming_message_idx` is null — the
        // invariant is spelled out on that field in `state.zig`), so the
        // only other feedback is the send button turning into a stop
        // square. On a slow first token that's too subtle to read as
        // "working", hence the dot.
        if (s.is_loading and s.streaming_message_idx == null) {
            cx.render(ui.box(.{
                .fill_width = true,
                .height = 24,
                .padding = .{ .each = .{ .top = 0, .bottom = 0, .left = THINKING_DOT_INSET, .right = CONTENT_PADDING } },
                .alignment = .{ .main = .start, .cross = .center },
            }, .{
                PulseDot{ .id = "assistant-thinking", .color = t.text_secondary },
            }));
        }
    }
};
