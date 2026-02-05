//! Root Layout for ChatAI
//!
//! Modern chat UI layout with:
//! - Dark/light mode toggle in header
//! - Clean full-width message display area
//! - Elegant input area card at bottom

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Color = gooey.Color;
const VirtualListState = gooey.VirtualListState;
const Svg = gooey.Svg;
const Lucide = gooey.Lucide;
const Select = gooey.Select;

const state_mod = @import("state.zig");
const theme_mod = @import("theme.zig");

const AppState = state_mod.AppState;
const Message = state_mod.Message;
const MessageRole = state_mod.MessageRole;
const Model = state_mod.Model;
const Theme = theme_mod.Theme;

// =============================================================================
// Layout Constants
// =============================================================================

const INPUT_CARD_CORNER_RADIUS: f32 = 16;
const BUBBLE_CORNER_RADIUS: f32 = 12;
const BUTTON_CORNER_RADIUS: f32 = 6;
const CONTENT_PADDING: f32 = 24;

// =============================================================================
// Root Layout
// =============================================================================

pub fn render(cx: *Cx) void {
    const s = cx.state(AppState);
    const size = cx.windowSize();
    const t = theme_mod.get(s.dark_mode);

    // Initialize state on first render
    if (s.gooey_ptr == null) {
        s.init(cx.gooey());
    }

    // Main container - full window, no nested card
    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = t.bg,
        .direction = .column,
        // Account for titlebar area
        .padding = .{ .each = .{ .top = 52, .bottom = 20, .left = 20, .right = 20 } },
    }, .{
        // Content area (messages or empty state)
        ContentArea{},
        // Input area card at bottom
        InputArea{},
        // Theme toggle - floating in titlebar area (top-right of viewport)
        ui.box(.{
            .floating = .{
                .attach_to_parent = false,
                .element_anchor = .right_top,
                .parent_anchor = .right_top,
                .offset_x = -12,
                .offset_y = 8,
                .z_index = 200,
            },
        }, .{
            ThemeToggle{},
        }),
    }));
}

const ThemeToggle = struct {
    // Sun/Moon SVG paths (Lucide-style XML format)
    const sun_path = "<circle cx=\"12\" cy=\"12\" r=\"4\"/><path d=\"M12 2v2\"/><path d=\"M12 20v2\"/><path d=\"m4.93 4.93 1.41 1.41\"/><path d=\"m17.66 17.66 1.41 1.41\"/><path d=\"M2 12h2\"/><path d=\"M20 12h2\"/><path d=\"m6.34 17.66-1.41 1.41\"/><path d=\"m19.07 4.93-1.41 1.41\"/>";
    const moon_path = "<path d=\"M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z\"/>";

    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        // Sun icon for dark mode, moon for light mode
        const icon_path = if (s.dark_mode) sun_path else moon_path;

        cx.render(ui.box(.{
            .width = 36,
            .height = 36,
            .corner_radius = 8,
            .alignment = .{ .main = .center, .cross = .center },
            .on_click_handler = cx.command(AppState, AppState.toggleDarkMode),
        }, .{
            Svg{ .path = icon_path, .size = 20, .no_fill = true, .stroke_color = t.icon_muted, .stroke_width = 1.5 },
        }));
    }
};

// =============================================================================
// Content Area (Messages)
// =============================================================================

const ContentArea = struct {
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
                ui.text("👋", .{
                    .size = 48,
                }),
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
                        ui.text("Set ANTHROPIC_API_KEY to get started", .{
                            .color = t.danger,
                            .size = 13,
                        }),
                    }),
                }),
            }));
            return;
        }

        // Message list with virtual scrolling
        cx.virtualList(
            "message-list",
            &s.list_state,
            .{
                .fill_width = true,
                .grow_height = true,
                .padding = .{ .each = .{ .top = 8, .bottom = 16, .left = CONTENT_PADDING, .right = CONTENT_PADDING } },
                .gap = 24,
                .background = Color.transparent,
            },
            renderMessage,
        );
    }
};

fn renderMessage(index: u32, cx: *Cx) f32 {
    const s = cx.stateConst(AppState);
    const msg = s.getMessage(index) orelse return 0;
    const is_user = msg.role == .user;

    // Calculate max bubble width: window width minus all horizontal padding
    // Main container: 20 left + 20 right = 40
    // Virtual list: CONTENT_PADDING (24) left + CONTENT_PADDING (24) right = 48
    const max_bubble_width = cx.windowSize().width - 40 - (CONTENT_PADDING * 2);

    if (is_user) {
        return renderUserMessage(msg, s.dark_mode, max_bubble_width, cx);
    } else {
        return renderAssistantMessage(msg, s.dark_mode, max_bubble_width, cx);
    }
}

fn renderUserMessage(msg: *const Message, dark_mode: bool, max_width: f32, cx: *Cx) f32 {
    const t = theme_mod.get(dark_mode);
    const text_content = msg.getText();

    // Estimate height based on max width
    const chars_per_line: usize = @max(1, @as(usize, @intFromFloat(max_width / 8.0)));
    const lines: usize = @max(1, (msg.content_len + chars_per_line - 1) / chars_per_line);
    const height: f32 = @as(f32, @floatFromInt(lines)) * 24.0 + 32.0;

    // User message in a rounded box with subtle border
    cx.render(ui.box(.{
        .max_width = max_width,
        .padding = .{ .symmetric = .{ .x = 16, .y = 14 } },
        .background = t.user_bubble,
        .border_color = t.user_bubble_border,
        .border_width = 1,
        .corner_radius = BUBBLE_CORNER_RADIUS,
    }, .{
        ui.text(text_content, .{
            .color = t.text,
            .size = 15,
            .wrap = .words,
        }),
    }));

    return height;
}

fn renderAssistantMessage(msg: *const Message, dark_mode: bool, max_width: f32, cx: *Cx) f32 {
    const t = theme_mod.get(dark_mode);
    const text_content = msg.getText();

    // Estimate height based on max width
    const chars_per_line: usize = @max(1, @as(usize, @intFromFloat(max_width / 8.0)));
    const lines: usize = @max(1, (msg.content_len + chars_per_line - 1) / chars_per_line);
    const height: f32 = @as(f32, @floatFromInt(lines)) * 24.0 + 16.0;

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

    return height;
}

// =============================================================================
// Input Area (Card at bottom)
// =============================================================================

const InputArea = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        cx.render(ui.box(.{
            .fill_width = true,
            .direction = .column,
            .gap = 12,
        }, .{
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
            // Input card container
            ui.box(.{
                .fill_width = true,
                .background = t.input_area_bg,
                .border_color = t.border_input,
                .border_width = 1,
                .corner_radius = INPUT_CARD_CORNER_RADIUS,
                .direction = .column,
            }, .{
                // Attach file row
                ui.box(.{
                    .fill_width = true,
                    .padding = .{ .symmetric = .{ .x = 16, .y = 12 } },
                    .direction = .row,
                    .gap = 12,
                    .alignment = .{ .main = .start, .cross = .center },
                }, .{
                    // Attachment icon
                    ui.text("📎", .{
                        .color = t.icon,
                        .size = 16,
                    }),
                    // Divider
                    ui.box(.{
                        .width = 1,
                        .height = 18,
                        .background = t.border,
                    }, .{}),
                    // Attach file text
                    ui.text("Attach file", .{
                        .color = t.text_secondary,
                        .size = 14,
                    }),
                }),
                // Text input area - full width
                ui.box(.{
                    .fill_width = true,
                    .padding = .{ .symmetric = .{ .x = 16, .y = 8 } },
                }, .{
                    gooey.TextArea{
                        .id = "chat-input",
                        .placeholder = if (s.has_api_key) "Ask me anything" else "API key required",
                        .bind = @constCast(&s.input_slice),
                        .rows = 2,
                        .background = Color.transparent,
                        .border_color = Color.transparent,
                        .text_color = t.text,
                        .placeholder_color = t.text_placeholder,
                        .fill_width = true,
                    },
                }),
                // Bottom row with model selector and send button
                ui.box(.{
                    .fill_width = true,
                    .padding = .{ .symmetric = .{ .x = 16, .y = 12 } },
                    .direction = .row,
                    .alignment = .{ .main = .start, .cross = .center },
                }, .{
                    // Model selector
                    ModelSelector{},
                    // Spacer
                    ui.spacer(),
                    // Send button (circular)
                    ui.box(.{
                        .width = 36,
                        .height = 36,
                        .corner_radius = BUTTON_CORNER_RADIUS,
                        .background = if (s.input_slice.len > 0 and s.has_api_key and !s.is_loading) t.primary else t.border,
                        .alignment = .{ .main = .center, .cross = .center },
                        .on_click_handler = if (s.has_api_key and !s.is_loading and s.input_slice.len > 0)
                            cx.command(AppState, AppState.sendMessage)
                        else
                            null,
                    }, .{
                        Svg{
                            .path = if (s.is_loading) Lucide.loader else Lucide.send,
                            .size = 18,
                            .no_fill = true,
                            // .stroke_color = ui.Color.hex(0xe2e8f0),
                            .stroke_width = 1,
                            .stroke_color = if (s.input_slice.len > 0 and s.has_api_key)
                                (if (s.dark_mode) t.card else Color.white)
                            else
                                t.icon_muted,
                        },
                    }),
                }),
            }),
        }));
    }
};

// =============================================================================
// Model Selector Component
// =============================================================================

const ModelSelector = struct {
    // Anthropic logo SVG path (viewBox: 0 0 92.2 65)
    const anthropic_icon = "<path d=\"M66.5,0H52.4l25.7,65h14.1L66.5,0z M25.7,0L0,65h14.4l5.3-13.6h26.9L51.8,65h14.4L40.5,0C40.5,0,25.7,0,25.7,0z M24.3,39.3l8.8-22.8l8.8,22.8H24.3z\"/>";

    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        cx.render(ui.box(.{
            .direction = .row,
            .alignment = .{ .main = .start, .cross = .center },
            .gap = 8,
        }, .{
            // Anthropic icon (aspect ratio 92.2:65 ≈ 1.42:1)
            ui.box(.{
                .height = 32,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                Svg{
                    .path = anthropic_icon,
                    .size = 18,
                    .color = t.text,
                    .viewbox = 92.2,
                },
            }),
            // Model select dropdown
            Select{
                .id = "model-select",
                .options = &Model.display_names,
                .selected = @intFromEnum(s.selected_model),
                .is_open = s.model_select_open,
                .width = 160,
                .background = t.card,
                .border_color = t.border,
                .focus_border_color = t.primary,
                .text_color = t.text_secondary,
                .hover_background = t.border,
                .selected_background = t.primary.withAlpha(0.15),
                .on_toggle_handler = cx.command(AppState, AppState.toggleModelSelect),
                .on_close_handler = cx.command(AppState, AppState.closeModelSelect),
                .handlers = &.{
                    cx.updateWith(AppState, @as(usize, 0), AppState.selectModel),
                    cx.updateWith(AppState, @as(usize, 1), AppState.selectModel),
                    cx.updateWith(AppState, @as(usize, 2), AppState.selectModel),
                },
            },
        }));
    }
};
