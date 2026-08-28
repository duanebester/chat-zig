//! Root Layout for ChatAI
//!
//! Modern chat UI layout with:
//! - Dark/light mode toggle in header
//! - Clean full-width message display area
//! - Elegant input area card at bottom

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Color = gooey.Color;
const Svg = gooey.components.Svg;
const Lucide = gooey.components.Lucide;
const Select = gooey.components.Select;
const TextArea = gooey.components.TextArea;
const Easing = gooey.animation.Easing;

const state_mod = @import("state.zig");
const audio = @import("audio/mod.zig");
const theme_mod = @import("theme.zig");

const AppState = state_mod.AppState;
const Message = state_mod.Message;
const MessageRole = state_mod.MessageRole;
const Model = state_mod.Model;
const DictationModel = state_mod.DictationModel;
const Theme = theme_mod.Theme;

// =============================================================================
// Layout Constants
// =============================================================================

const INPUT_CARD_CORNER_RADIUS = 16;
const BUBBLE_CORNER_RADIUS = 12;
const BUTTON_CORNER_RADIUS = 6;
const ACTION_BUTTON_SIZE: f32 = 36;
const ACTION_ICON_SIZE: f32 = 18;
const CONTENT_PADDING = 24;
const CHAT_MIN_WIDTH: f32 = 400;

// =============================================================================
// Root Layout
// =============================================================================

pub fn render(cx: *Cx) void {
    const s = cx.state(AppState);

    // Drain any completed async worker results BEFORE reading other fields.
    // Workers push WorkerResult values into an Io.Queue on completion; the
    // render loop is the only consumer. Draining here flips `is_loading`
    // off and appends the assistant's reply into the message ring before
    // any child component reads from either — no half-updated frame.
    s.drainResults(cx);

    const size = cx.windowSize();
    const t = theme_mod.get(s.dark_mode);

    if (cx.changed("dark_mode", s.dark_mode) or cx.changed("window_width", size.width)) {
        s.invalidateCachedHeights();
    }

    // Main container - full window
    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = t.bg,
        .direction = .row,
    }, .{
        // Chat column (grows to fill, with a minimum width so it doesn't collapse)
        ui.box(.{
            .grow = true,
            .min_width = CHAT_MIN_WIDTH,
            .height = size.height,
            .direction = .column,
            .padding = .{ .each = .{ .top = 52, .bottom = 20, .left = 20, .right = 20 } },
        }, .{
            // Content area (messages or empty state)
            ContentArea{},
            // Input area card at bottom
            InputArea{},
        }),
        // Toolbar — floating in titlebar area (top-right of viewport)
        ui.box(.{
            .floating = .{
                .attach_to_parent = false,
                .element_anchor = .right_top,
                .parent_anchor = .right_top,
                .offset_x = -4,
                .offset_y = 0,
                .z_index = 200,
            },
            .direction = .row,
            .gap = 4,
        }, .{
            ThemeToggle{},
        }),
    }));
}

// =============================================================================
// Theme Toggle
// =============================================================================

const ThemeToggle = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        // Sun icon for dark mode, moon for light mode
        const icon_path = if (s.dark_mode) Lucide.sun else Lucide.moon;

        cx.render(ui.box(.{
            .width = 36,
            .height = 36,
            .corner_radius = 8,
            .alignment = .{ .main = .center, .cross = .center },
            .cursor = .pointer,
            .on_click_handler = cx.command(AppState.toggleDarkMode),
        }, .{
            Svg{ .path = icon_path, .size = 16, .no_fill = true, .stroke_color = t.icon_muted, .stroke_width = 1.0 },
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
            renderMessage,
        );
    }
};

fn renderMessage(index: u32, cx: *Cx) f32 {
    const s = cx.state(AppState);
    const message_index: usize = @intCast(index);
    const msg = s.getMessage(message_index) orelse return 0;
    const is_user = msg.role == .user;

    // Calculate max bubble width: window width minus all horizontal padding
    // Main container: 20 left + 20 right = 40
    // Virtual list: CONTENT_PADDING (24) left + CONTENT_PADDING (24) right = 48
    const max_bubble_width = cx.windowSize().width - 40 - (CONTENT_PADDING * 2);

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

// =============================================================================
// Input Area (Card at bottom)
// =============================================================================

/// Shared 0..1 slide progress for the settings panel expand/collapse
/// animation. Read by both `InputArea` (to fade out the input card's own
/// bottom border as the panel takes over that edge, see below) and
/// `SettingsPanel` (to fade in its top divider border and height) so the
/// two stay perfectly in sync — querying the same named spring twice in a
/// frame just re-reads its current value (negligible elapsed time between
/// the two calls), it doesn't double-step the physics.
fn settingsPanelProgress(cx: *Cx, s: *const AppState) f32 {
    const spring = cx.animations.springComptime("settings-panel-slide", .{
        .target = if (s.settings_expanded) 1.0 else 0.0,
        .stiffness = 320,
        .damping = 34,
    });
    return spring.clamped();
}

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
            // Keep the composer border independent from the expanding panel
            // so its rounded outline remains visually stable in both states.
            ui.box(.{
                .fill_width = true,
                .direction = .column,
            }, .{
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
                SettingsPanel{},
            }),
        }));
    }
};

// =============================================================================
// Microphone Controls
// =============================================================================

const MicrophoneLevelBar = struct {
    height: f32,
    color: Color,
};

const ComposerActions = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);
        const can_record = (s.microphone.selected != null or s.recording.active) and !s.is_transcribing;

        if (s.recording.active) cx.window().requestRender();

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .each = .{ .top = 8, .right = 12, .bottom = 12, .left = 12 } },
            .direction = .row,
            .gap = 8,
            .alignment = .{ .main = .start, .cross = .center },
        }, .{
            ui.box(.{
                .width = ACTION_BUTTON_SIZE,
                .height = ACTION_BUTTON_SIZE,
                .corner_radius = BUTTON_CORNER_RADIUS,
                .alignment = .{ .main = .center, .cross = .center },
                .cursor = .pointer,
                .on_click_handler = cx.command(AppState.openFileDialog),
            }, .{
                Svg{ .path = Lucide.paperclip, .size = ACTION_ICON_SIZE, .no_fill = true, .stroke_color = t.icon_muted, .stroke_width = 1.5 },
            }),
            ui.box(.{
                .width = ACTION_BUTTON_SIZE,
                .height = ACTION_BUTTON_SIZE,
                .corner_radius = BUTTON_CORNER_RADIUS,
                .background = if (s.settings_expanded) t.primary.withAlpha(0.15) else Color.transparent,
                .alignment = .{ .main = .center, .cross = .center },
                .cursor = .pointer,
                .on_click_handler = cx.command(AppState.toggleSettings),
            }, .{
                Svg{ .path = Lucide.settings, .size = ACTION_ICON_SIZE, .no_fill = true, .stroke_color = if (s.settings_expanded) t.primary else t.icon_muted, .stroke_width = 1.5 },
            }),
            ui.spacer(),
            MicrophoneMeter{},
            RecordButton{ .enabled = can_record },
            SendButton{},
        }));
    }
};

const RecordButton = struct {
    enabled: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        cx.render(ui.box(.{
            .width = ACTION_BUTTON_SIZE,
            .height = ACTION_BUTTON_SIZE,
            .corner_radius = BUTTON_CORNER_RADIUS,
            .background = if (s.recording.active) t.danger else if (self.enabled) t.primary else t.border,
            .alignment = .{ .main = .center, .cross = .center },
            .cursor = if (self.enabled) .pointer else null,
            .on_click_handler = if (self.enabled) cx.command(AppState.toggleRecording) else null,
        }, .{
            Svg{
                .path = if (s.recording.active) Lucide.square else Lucide.mic,
                .size = if (s.recording.active) 12 else ACTION_ICON_SIZE,
                .color = if (s.recording.active) Color.white else Color.transparent,
                .no_fill = !s.recording.active,
                .stroke_color = if (s.recording.active) Color.transparent else if (self.enabled) t.card else t.icon_muted,
                .stroke_width = 1.5,
            },
        }));
    }
};

const SendButton = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        cx.render(ui.box(.{
            .width = ACTION_BUTTON_SIZE,
            .height = ACTION_BUTTON_SIZE,
            .corner_radius = BUTTON_CORNER_RADIUS,
            .background = if (s.is_loading) t.danger else if (s.input_slice.len > 0 and s.has_api_key) t.primary else t.border,
            .alignment = .{ .main = .center, .cross = .center },
            .cursor = if (s.is_loading or (s.has_api_key and s.input_slice.len > 0)) .pointer else null,
            .on_click_handler = if (s.is_loading) cx.command(AppState.cancelInFlight) else if (s.has_api_key and s.input_slice.len > 0) cx.command(AppState.sendMessage) else null,
        }, .{
            Svg{
                .path = if (s.is_loading) Lucide.square else Lucide.send,
                .size = if (s.is_loading) 12 else ACTION_ICON_SIZE,
                .color = if (s.is_loading) Color.white else Color.transparent,
                .no_fill = !s.is_loading,
                .stroke_width = 1,
                .stroke_color = if (s.is_loading) Color.transparent else if (s.input_slice.len > 0 and s.has_api_key) (if (s.dark_mode) t.card else Color.white) else t.icon_muted,
            },
        }));
    }
};

const SettingsPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);
        const progress = settingsPanelProgress(cx, s);
        const padding_y = progress * 14.0;
        const content_opacity = std.math.clamp((progress - 0.72) / 0.18, 0.0, 1.0);
        std.debug.assert(content_opacity >= 0.0);
        std.debug.assert(content_opacity <= 1.0);

        // The dictation model row only renders when an OpenAI key is
        // configured (`DictationModelSelector`), so the panel's resting
        // height shrinks back down when that row is absent instead of
        // leaving a blank gap.
        const panel_height: f32 = if (s.has_openai_api_key) 184.0 else 140.0;

        cx.render(ui.box(.{
            .fill_width = true,
            .height = progress * panel_height,
            .padding = .{ .symmetric = .{ .x = 12, .y = 0 } },
            .direction = .column,
            .pointer_events = if (s.settings_expanded) .auto else .none,
        }, .{
            ui.box(.{
                .fill_width = true,
                .padding = .{ .each = .{ .top = padding_y, .bottom = padding_y, .left = 16, .right = 16 } },
                .background = t.input_area_bg.withAlpha(0.72),
                .border_color = t.border_light.withAlpha(0.65),
                .border_width = .{ .all = 1 },
                .corner_radii = ui.CornerRadius.bottom(12),
                .opacity = progress,
                .direction = .column,
                .pointer_events = if (s.settings_expanded) .auto else .none,
            }, .{
                ui.box(.{
                    .fill_width = true,
                    .opacity = content_opacity,
                    .direction = .column,
                    .gap = 12,
                    .pointer_events = if (s.settings_expanded) .auto else .none,
                }, .{
                    ui.text("Settings", .{ .color = t.text, .size = 13, .weight = .medium }),
                    ModelSelector{},
                    DictationModelSelector{},
                    MicrophoneSettings{},
                }),
            }),
        }));
    }
};

const MicrophoneSettings = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        cx.render(ui.box(.{ .fill_width = true, .direction = .row, .gap = 8, .alignment = .{ .main = .start, .cross = .center } }, .{
            Svg{ .path = Lucide.mic, .size = 16, .no_fill = true, .stroke_color = t.icon_muted, .stroke_width = 1.5 },
            Select{
                .id = "microphone-select",
                .options = s.microphone.options(),
                .selected = s.microphone.selected,
                .placeholder = "No microphones found",
                .width = 240,
                .background = t.card,
                .border_color = t.border,
                .focus_border_color = t.primary,
                .text_color = t.text_secondary,
                .hover_background = t.border,
                .option_hover_background = t.border,
                .selected_background = t.primary.withAlpha(0.15),
                .on_select = cx.onSelect(AppState.selectMicrophone),
            },
            ui.box(.{
                .width = 28,
                .height = 28,
                .corner_radius = BUTTON_CORNER_RADIUS,
                .alignment = .{ .main = .center, .cross = .center },
                .cursor = if (s.recording.active) null else .pointer,
                .on_click_handler = if (s.recording.active) null else cx.command(AppState.refreshMicrophones),
            }, .{
                Svg{ .path = Lucide.refresh_cw, .size = 14, .no_fill = true, .stroke_color = t.icon_muted, .stroke_width = 1.5 },
            }),
        }));

        if (s.recording.last_error) |capture_error| {
            cx.render(ui.text(@errorName(capture_error), .{ .color = t.danger, .size = 12 }));
        }
    }
};

const MicrophoneMeter = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        if (!s.recording.active) return;

        const t = theme_mod.get(s.dark_mode);
        const levels = s.microphoneLevels();
        var bars: [audio.WAVEFORM_BAR_COUNT]MicrophoneLevelBar = undefined;
        for (levels, 0..) |level, level_index| {
            std.debug.assert(level >= 0.0);
            std.debug.assert(level <= 1.0);
            bars[level_index] = .{ .height = 3.0 + level * 21.0, .color = t.danger };
        }

        cx.render(ui.box(.{
            .height = 24,
            .direction = .row,
            .gap = 2,
            .alignment = .{ .main = .center, .cross = .end },
        }, .{
            ui.each(&bars, renderMicrophoneLevelBar),
        }));
    }
};

fn renderMicrophoneLevelBar(bar: MicrophoneLevelBar, _: usize) @TypeOf(ui.box(ui.Box{}, .{})) {
    std.debug.assert(bar.height >= 3.0);
    std.debug.assert(bar.height <= 24.0);
    return ui.box(.{
        .width = 3,
        .height = bar.height,
        .corner_radius = 2,
        .background = bar.color,
    }, .{});
}

// =============================================================================
// Model Selector Component
// =============================================================================

// =============================================================================
// Loading Spinner (Animated 3-Dot Pulse)
// =============================================================================

const LoadingSpinner = struct {
    size: f32 = 18,
    color: Color = Color.white,

    pub fn render(self: @This(), cx: *Cx) void {
        // Continuous animation for the spinner
        const pulse = cx.animations.tween("loading-spinner", .{
            .duration_ms = 1200,
            .easing = Easing.linear,
            .mode = .loop,
        });

        const progress = pulse.progress;
        const dot_size = self.size * 0.3;
        const gap = (self.size - dot_size * 3) / 2.0;

        cx.render(ui.box(.{
            .width = self.size,
            .height = self.size,
            .direction = .row,
            .gap = gap,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            PulseDot{ .index = 0, .progress = progress, .dot_size = dot_size, .color = self.color },
            PulseDot{ .index = 1, .progress = progress, .dot_size = dot_size, .color = self.color },
            PulseDot{ .index = 2, .progress = progress, .dot_size = dot_size, .color = self.color },
        }));
    }
};

const PulseDot = struct {
    index: u8,
    progress: f32,
    dot_size: f32,
    color: Color,

    pub fn render(self: @This(), cx: *Cx) void {
        // Each dot pulses with a phase offset (0, 0.33, 0.66)
        const phase_offset = @as(f32, @floatFromInt(self.index)) * 0.33;
        var phase = self.progress + phase_offset;
        if (phase >= 1.0) phase -= 1.0;

        // Create a smooth pulse: fade in, then fade out
        // Use a sine-like curve for smoother animation
        const pulse_progress = if (phase < 0.5)
            phase * 2.0 // 0 to 1 during first half
        else
            (1.0 - phase) * 2.0; // 1 to 0 during second half

        const scale = 0.6 + 0.4 * pulse_progress;
        const opacity = 0.3 + 0.7 * pulse_progress;
        const size = self.dot_size * scale;

        cx.render(ui.box(.{
            .width = self.dot_size,
            .height = self.dot_size,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            ui.rect(.{
                .width = size,
                .height = size,
                .corner_radius = size / 2.0,
                .background = self.color.withAlpha(opacity),
            }),
        }));
    }
};

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
                    .color = t.icon_muted,
                    .viewbox = 92.2,
                },
            }),
            // Model select dropdown
            Select{
                .id = "model-select",
                .options = &Model.display_names,
                .selected = @intFromEnum(s.selected_model),
                .width = 240,
                .background = t.card,
                .border_color = t.border,
                .focus_border_color = t.primary,
                .text_color = t.text_secondary,
                .hover_background = t.border,
                .option_hover_background = t.border,
                .selected_background = t.primary.withAlpha(0.15),
                .on_select = cx.onSelect(AppState.selectModel),
            },
        }));
    }
};

const DictationModelSelector = struct {
    // OpenAI logomark SVG path (viewBox: 0 0 24 24)
    const openai_icon = "<path d=\"M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z\"/>";

    /// OpenAI dictation model picker. Hidden entirely when no OpenAI key is
    /// configured — same rationale as the rest of the transcription feature
    /// (`has_openai_api_key` in `state.zig`): voice recording works fine
    /// without it, so there's nothing useful to pick from.
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        if (!s.has_openai_api_key) return;

        const t = theme_mod.get(s.dark_mode);

        cx.render(ui.box(.{
            .direction = .row,
            .alignment = .{ .main = .start, .cross = .center },
            .gap = 8,
        }, .{
            // OpenAI icon (square 24x24 viewbox, gooey's Svg default)
            ui.box(.{
                .height = 32,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                Svg{
                    .path = openai_icon,
                    .size = 16,
                    .color = t.icon_muted,
                },
            }),
            // Dictation model select dropdown
            Select{
                .id = "dictation-model-select",
                .options = &DictationModel.display_names,
                .selected = @intFromEnum(s.selected_dictation_model),
                .width = 240,
                .background = t.card,
                .border_color = t.border,
                .focus_border_color = t.primary,
                .text_color = t.text_secondary,
                .hover_background = t.border,
                .option_hover_background = t.border,
                .selected_background = t.primary.withAlpha(0.15),
                .on_select = cx.onSelect(AppState.selectDictationModel),
            },
        }));
    }
};
