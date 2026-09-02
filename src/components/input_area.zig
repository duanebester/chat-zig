//! Bottom composer card: error banner, text area, attachment chip, and actions.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Color = gooey.Color;
const Svg = gooey.components.Svg;
const Lucide = gooey.components.Lucide;
const TextArea = gooey.components.TextArea;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");
const ComposerActions = @import("composer_actions.zig").ComposerActions;

const AppState = state_mod.AppState;

const INPUT_CARD_CORNER_RADIUS = constants.INPUT_CARD_CORNER_RADIUS;

pub const InputArea = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        // Compaction marker. Deliberately a banner rather than a row in
        // the message list: the ring still holds every turn, so scrolling
        // up shows real history — what the user needs told is that the
        // older part is being *sent* in condensed form.
        const compaction_banner = s.compactionBanner();

        cx.render(ui.box(.{
            .fill_width = true,
            .direction = .column,
            .gap = 12,
        }, .{
            ui.when(compaction_banner != null, .{
                ui.box(.{
                    .fill_width = true,
                    .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
                    .direction = .row,
                    .gap = 8,
                    .alignment = .{ .main = .start, .cross = .center },
                    .background = t.text_secondary.withAlpha(0.08),
                    .corner_radius = 10,
                }, .{
                    Svg{ .path = Lucide.archive, .size = 14, .no_fill = true, .stroke_color = t.text_secondary, .stroke_width = 1.5 },
                    ui.text(compaction_banner orelse "", .{
                        .color = t.text_secondary,
                        .size = 12,
                    }),
                }),
            }),
            // Error message (if any)
            ui.when(s.error_message != null, .{
                ui.box(.{
                    .fill_width = true,
                    .padding = .{ .all = 12 },
                    .background = t.danger.withAlpha(0.08),
                    .corner_radius = 10,
                }, .{
                    ui.text(s.error_message orelse "", .{
                        .color = t.danger,
                        .size = 13,
                    }),
                }),
            }),
            ui.box(.{
                .fill_width = true,
                .background = t.input_area_bg,
                .border_color = t.border_input,
                .border_width = .{ .all = 1 },
                .corner_radius = INPUT_CARD_CORNER_RADIUS,
                .direction = .column,
            }, .{
                // Text input area - full width
                ui.box(.{
                    .fill_width = true,
                    .padding = .{ .symmetric = .{ .x = 16, .y = 8 } },
                }, .{
                    TextArea{
                        .id = "chat-input",
                        .placeholder = if (s.is_transcribing) "Transcribing..." else if (s.has_api_key) "Ask me anything" else "API key required",
                        .bind = &s.input_slice,
                        .rows = 2,
                        .background = Color.transparent,
                        .border_color = Color.transparent,
                        .text_color = t.text,
                        .placeholder_color = t.text_placeholder,
                        .fill_width = true,
                    },
                }),
                ui.when(s.has_attached_file, .{
                    ui.box(.{
                        .padding = .{ .symmetric = .{ .x = 16, .y = 4 } },
                        .direction = .row,
                        .alignment = .{ .main = .start, .cross = .center },
                    }, .{
                        ui.box(.{
                            .padding = .{ .each = .{ .top = 6, .right = 6, .bottom = 6, .left = 10 } },
                            .direction = .row,
                            .gap = 8,
                            .alignment = .{ .main = .start, .cross = .center },
                            .background = t.primary.withAlpha(0.1),
                            .corner_radius = 8,
                        }, .{
                            Svg{ .path = Lucide.paperclip, .size = 14, .no_fill = true, .stroke_color = t.primary, .stroke_width = 1.5 },
                            ui.text(s.getAttachedFileName(), .{
                                .color = t.primary,
                                .size = 13,
                            }),
                            ui.box(.{
                                .width = 20,
                                .height = 20,
                                .corner_radius = 10,
                                .alignment = .{ .main = .center, .cross = .center },
                                .cursor = .pointer,
                                .on_click_handler = cx.command(AppState.clearAttachedFile),
                            }, .{
                                Svg{ .path = Lucide.x, .size = 12, .no_fill = true, .stroke_color = t.text_secondary, .stroke_width = 1.5 },
                            }),
                        }),
                    }),
                }),
                ComposerActions{},
            }),
        }));
    }
};
