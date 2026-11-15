//! Bottom composer card: error banner, text area, attachment chip, and actions.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const components = @import("gooey-components");
const Lucide = components.Lucide;
const TextArea = components.TextArea;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");
const icon = @import("icon.zig").icon;
const ComposerActions = @import("composer_actions.zig").ComposerActions;
const WidthProbe = @import("width_probe.zig").WidthProbe;

const AppState = state_mod.AppState;

const INPUT_CARD_CORNER_RADIUS = constants.INPUT_CARD_CORNER_RADIUS;
/// The text row's horizontal padding inside the card.
const TEXT_ROW_PADDING_X: f32 = 16;
/// Narrowest the input gets, whatever the probe reports.
const TEXT_AREA_WIDTH_MIN: f32 = 120;

pub const InputArea = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        // Compaction marker. Deliberately a banner rather than a row in
        // the message list: the ring still holds every turn, so scrolling
        // up shows real history — what the user needs told is that the
        // older part is being *sent* in condensed form.
        const compaction_banner = s.compactionBanner();

        // `TextArea` takes a fixed width and render cannot read the window's,
        // so a zero-height probe below the input measures the row each frame
        // (`WidthProbe`) and the next build uses it. When the width just
        // changed (a resize), build once more so the input catches up even
        // if nothing else renders.
        if (s.composer_width != s.composer_width_used) cx.requestRenderAfter(16);
        s.composer_width_used = s.composer_width;
        s.composer_probe = .{ .width = &s.composer_width };
        const text_area_width = @max(TEXT_AREA_WIDTH_MIN, s.composer_width_used);

        // Both boxes are keyed so the `TextArea`'s id stays put. An unkeyed
        // box's id comes from its position among its siblings, and the
        // banners above the card and the thinking dot above the composer
        // come and go; a moved id would retain a new text engine and drop
        // the old one's text, focus, and pool slot.
        cx.render(ui.box(.{
            .key = .{ .name = "composer" },
            .style = .{ .width = .{ .grow = 1 }, .gap = 12 },
        }, .{
            if (compaction_banner) |text| CompactionBanner{ .text = text } else null,
            if (s.error_message) |text| ErrorBanner{ .text = text } else null,
            ui.box(.{
                .key = .{ .name = "composer-card" },
                .style = .{
                    .width = .{ .grow = 1 },
                    .background = .{ .rgba = t.input_area_bg },
                    .border = .{ .width = 1, .color = .{ .rgba = t.border_input } },
                    .corner_radius = .all(INPUT_CARD_CORNER_RADIUS),
                },
            }, .{
                ui.box(.{ .style = .{
                    .width = .{ .grow = 1 },
                    .padding = .{ .top = 16, .left = TEXT_ROW_PADDING_X, .right = TEXT_ROW_PADDING_X },
                } }, .{
                    TextArea{
                        .key = "chat-input",
                        .placeholder = if (s.is_transcribing)
                            "Transcribing..."
                        else if (s.has_api_key)
                            "Ask me anything"
                        else
                            "API key required",
                        .bind = &s.input_slice,
                        .rows = 2,
                        .width = text_area_width,
                    },
                    ui.paint(WidthProbe, &s.composer_probe, WidthProbe.paint, .{
                        .width = .{ .grow = 1 },
                        .height = .{ .fixed = 0 },
                    }),
                }),
                if (s.has_attached_file) AttachedFile{ .name = s.getAttachedFileName() } else null,
                ComposerActions{},
            }),
        }));
    }
};

const CompactionBanner = struct {
    text: []const u8,

    pub fn render(self: CompactionBanner, cx: *Cx) void {
        const t = theme_mod.get(cx.state(AppState).dark_mode);
        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .width = .{ .grow = 1 },
            .padding = .symmetric(12, 8),
            .gap = 8,
            .alignment = .center_cross,
            .background = .{ .rgba = t.text_secondary.withAlpha(0.08) },
            .corner_radius = .all(10),
        } }, .{
            icon(.{ .path = Lucide.archive, .size = 14, .stroke = .subtext }),
            ui.text(self.text, .{ .color = .subtext, .size = 12 }),
        }));
    }
};

const ErrorBanner = struct {
    text: []const u8,

    pub fn render(self: ErrorBanner, cx: *Cx) void {
        const t = theme_mod.get(cx.state(AppState).dark_mode);
        cx.render(ui.box(.{
            .style = .{
                .width = .{ .grow = 1 },
                .padding = .all(12),
                .background = .{ .rgba = t.danger.withAlpha(0.08) },
                .corner_radius = .all(10),
            },
            .a11y = .{ .role = .alert, .label = self.text, .live = .assertive },
        }, .{
            ui.text(self.text, .{ .color = .danger, .size = 13, .wrap = .words }),
        }));
    }
};

const AttachedFile = struct {
    name: []const u8,

    pub fn render(self: AttachedFile, cx: *Cx) void {
        const t = theme_mod.get(cx.state(AppState).dark_mode);
        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .padding = .symmetric(16, 4),
            .alignment = .center_cross,
        } }, .{
            ui.box(.{ .style = .{
                .direction = .row,
                .padding = .{ .top = 6, .right = 6, .bottom = 6, .left = 10 },
                .gap = 8,
                .alignment = .center_cross,
                .background = .{ .rgba = t.primary.withAlpha(0.1) },
                .corner_radius = .all(8),
            } }, .{
                icon(.{ .path = Lucide.paperclip, .size = 14, .stroke = .primary }),
                ui.text(self.name, .{ .color = .primary, .size = 13 }),
                ui.box(.{
                    .style = .{
                        .width = .{ .fixed = 20 },
                        .height = .{ .fixed = 20 },
                        .corner_radius = .all(10),
                        .alignment = .center,
                        .cursor = .pointer,
                    },
                    .on_click = cx.on(AppState.clearAttachedFile, .{}),
                    .a11y = .{ .role = .button, .label = "Remove attachment" },
                }, .{
                    icon(.{ .path = Lucide.x, .size = 12, .stroke = .subtext }),
                }),
            }),
        }));
    }
};
