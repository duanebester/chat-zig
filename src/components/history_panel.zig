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
//! Gooey 0.4 dropped `cx.lists.uniform`; at most `MAX_SESSION_ENTRIES` (200)
//! rows exist, so the panel is a plain keyed scroll box.
//!
//! There used to be a "New chat" button in the header; it's gone now that
//! `HistoryToggle` itself doubles as "back to chat" while this panel is
//! open, so the header is just a title, mirroring `SettingsPanel`.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Lucide = @import("gooey-components").Lucide;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const constants = @import("constants.zig");
const date_format = @import("../date_format.zig");
const session_log_mod = @import("../session_log.zig");
const icon = @import("icon.zig").icon;

const AppState = state_mod.AppState;

const CONTENT_PADDING = constants.CONTENT_PADDING;
const HISTORY_ROW_HEIGHT = state_mod.HISTORY_ROW_HEIGHT;
const HISTORY_ROW_GAP = state_mod.HISTORY_ROW_GAP;
const TIMESTAMP_BUF_LEN = date_format.TIMESTAMP_BUF_LEN;

pub const HistoryPanel = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .padding = .{ .top = 4, .bottom = 12, .left = CONTENT_PADDING, .right = CONTENT_PADDING },
        } }, .{
            ui.text("History", .{ .color = .text, .size = 16, .weight = .medium }),
        }));

        if (s.session_entry_count == 0) {
            cx.render(ui.box(.{ .style = .{
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
                .alignment = .center,
                .padding = .all(CONTENT_PADDING),
            } }, .{
                ui.text("No past sessions yet", .{ .color = .subtext, .size = 13 }),
            }));
            return;
        }

        cx.render(ui.box(.{
            .key = .{ .name = "history-list" },
            .style = .{
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
                .padding = .{ .bottom = 16, .left = CONTENT_PADDING, .right = CONTENT_PADDING },
                .gap = HISTORY_ROW_GAP,
                .scroll = .{},
            },
            .a11y = .{ .role = .list, .label = "Past sessions" },
        }, .{
            Rows{ .count = @intCast(s.session_entry_count) },
        }));
    }
};

const Rows = struct {
    count: u32,

    pub fn render(self: Rows, cx: *Cx) void {
        std.debug.assert(self.count <= session_log_mod.MAX_SESSION_ENTRIES);
        var index: u32 = 0;
        while (index < self.count) : (index += 1) cx.render(Row{ .index = index });
    }
};

const Row = struct {
    index: u32,

    pub fn render(self: Row, cx: *Cx) void {
        const s = cx.state(AppState);
        const t = theme_mod.get(s.theme);
        const entry = s.getSessionEntry(self.index) orelse return;
        const is_current = if (s.session_log.currentSeconds()) |cur| cur == entry.unix_seconds else false;

        var label_buf: [TIMESTAMP_BUF_LEN]u8 = undefined;
        const label = date_format.formatTimestamp(&label_buf, entry.unix_seconds);

        // Hover is not a style field in Gooey 0.4: read it and pick a colour.
        const key: gooey.Key = .{ .index = self.index };
        const hovered = cx.hovered(cx.id(key));
        cx.render(ui.box(.{
            .key = key,
            .style = .{
                .direction = .row,
                .width = .{ .grow = 1 },
                .height = .{ .fixed = HISTORY_ROW_HEIGHT },
                .padding = .symmetric(14, 0),
                .alignment = .center_cross,
                .gap = 10,
                .background = .{ .rgba = if (hovered) t.border else t.card },
                .border = .{ .width = 1, .color = .{ .rgba = if (is_current) t.primary else t.border } },
                .corner_radius = .all(10),
                .cursor = .pointer,
            },
            .on_click = cx.on(AppState.loadSession, .{ .arg = self.index }),
            .a11y = .{ .role = .listitem, .label = label },
        }, .{
            icon(.{ .path = Lucide.message_square, .size = 16, .stroke = .secondary }),
            ui.box(.{ .style = .{ .width = .{ .grow = 1 }, .gap = 2 } }, .{
                ui.text(label, .{ .color = .text, .size = 13, .weight = .medium }),
                if (is_current) ui.text("Current session", .{ .color = .primary, .size = 11 }) else null,
            }),
        }));
    }
};
