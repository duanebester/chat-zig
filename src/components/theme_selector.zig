//! Theme picker, shown in the settings panel: the same four themes the
//! toolbar's theme button steps through (`theme.Choice`).

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const Handler = gooey.Handler;
const Select = @import("gooey-components").Select;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");

const AppState = state_mod.AppState;
const Choice = theme_mod.Choice;

pub const ThemeSelector = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        // One handler per option, as `Select` requires.
        var on_select: [Choice.count]Handler = undefined;
        for (&on_select, 0..) |*handler, index| {
            handler.* = cx.on(AppState.selectTheme, .{ .arg = @as(u32, @intCast(index)) });
        }
        std.debug.assert(on_select.len == Choice.display_names.len);

        cx.render(Select{
            .key = "theme-select",
            .options = &Choice.display_names,
            .on_select = &on_select,
            .on_toggle = cx.on(AppState.toggleSelect, .{ .arg = state_mod.SelectId.theme }),
            .on_close = cx.on(AppState.closeSelect, .{ .arg = state_mod.SelectId.theme }),
            .selected = @backingInt(s.theme),
            .open = s.open_select == .theme,
            .width = 240,
            .accessible_name = "Theme",
        });
    }
};
