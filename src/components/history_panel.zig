//! Full-length list of past chat sessions.
//!
//! Shown by `layout.zig` in place of `ContentArea` while
//! `AppState.history_expanded` is true (toggled via `HistoryToggle`'s
//! history icon). Reads `AppState.session_entries`, populated from
//! `sessions/*.jsonl` by `AppState.toggleHistory` — this component only
//! renders, it never touches the filesystem itself.
//!
//! Clicking a row restores that session into the live chat via
//! `AppState.loadSession` (see `docs/CHAT_COMPACTION.md`'s "Restore"
//! section) — filename-derived timestamp, and a badge on whichever entry
//! is the session currently being written to.
//!
//! There used to be a "New chat" button in the header; it's gone now that
//! `HistoryToggle` itself doubles as "back to chat" while this panel is
//! open, so the header is just a title, mirroring `SettingsPanel`.

const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Color = gooey.Color;
const Svg = gooey.components.Svg;
const Lucide = gooey.components.Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");
const date_format = @import("../date_format.zig");

const AppState = state_mod.AppState;

const CONTENT_PADDING = constants.CONTENT_PADDING;
const HISTORY_ROW_HEIGHT = state_mod.HISTORY_ROW_HEIGHT;
const HISTORY_ROW_GAP = state_mod.HISTORY_ROW_GAP;
const TIMESTAMP_BUF_LEN = date_format.TIMESTAMP_BUF_LEN;

pub const HistoryPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .each = .{ .top = 4, .bottom = 12, .left = CONTENT_PADDING, .right = CONTENT_PADDING } },
        }, .{
            ui.text("History", .{ .color = t.text, .size = 16, .weight = .medium }),
        }));

        if (s.session_entry_count == 0) {
            cx.render(ui.box(.{
                .grow = true,
                .fill_width = true,
                .alignment = .{ .main = .center, .cross = .center },
                .padding = .{ .all = CONTENT_PADDING },
            }, .{
                ui.text("No past sessions yet", .{ .color = t.text_secondary, .size = 13 }),
            }));
            return;
        }

        cx.lists.uniform(
            "history-list",
            &s.history_list_state,
            .{
                .fill_width = true,
                .grow_height = true,
                .padding = .{ .each = .{ .top = 0, .bottom = 16, .left = CONTENT_PADDING, .right = CONTENT_PADDING } },
                .gap = HISTORY_ROW_GAP,
                .background = Color.transparent,
            },
            row,
        );
    }

    fn row(index: u32, cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.dark_mode);
        const entry = s.getSessionEntry(@intCast(index)) orelse return;
        const is_current = if (s.session_log.currentSeconds()) |cur| cur == entry.unix_seconds else false;

        var label_buf: [TIMESTAMP_BUF_LEN]u8 = undefined;
        const label = date_format.formatTimestamp(&label_buf, entry.unix_seconds);

        cx.render(ui.box(.{
            .fill_width = true,
            .height = HISTORY_ROW_HEIGHT,
            .padding = .{ .symmetric = .{ .x = 14, .y = 0 } },
            .direction = .row,
            .alignment = .{ .main = .start, .cross = .center },
            .gap = 10,
            .background = t.card,
            .border_color = if (is_current) t.primary else t.border,
            .border_width = .{ .all = 1 },
            .corner_radius = 10,
            .cursor = .pointer,
            .hover_background = t.border,
            .on_click_handler = cx.commandWith(index, AppState.loadSession),
        }, .{
            Svg{ .path = Lucide.message_square, .size = 16, .no_fill = true, .stroke_color = t.icon_muted, .stroke_width = 1.5 },
            ui.box(.{ .direction = .column, .gap = 2, .grow_width = true }, .{
                ui.text(label, .{ .color = t.text, .size = 13, .weight = .medium }),
                ui.when(is_current, .{
                    ui.text("Current session", .{ .color = t.primary, .size = 11 }),
                }),
            }),
        }));
    }
};
