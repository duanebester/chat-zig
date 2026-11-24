//! Palette picker; brightness is independent and controlled by the toolbar.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Handler = gooey.Handler;
const components = @import("gooey-components");
const Select = components.Select;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");
const icon = @import("icon.zig").icon;

const AppState = state_mod.AppState;
const Family = theme_mod.Family;

pub const ThemeSelector = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        const options = std.enums.EnumArray(Family, []const u8).init(.{
            .default = "Default",
            .catppuccin = "Catppuccin",
        });
        var on_select: std.enums.EnumArray(Family, Handler) = undefined;
        for (std.enums.values(Family)) |family| {
            on_select.set(family, cx.on(AppState.selectPalette, .{ .arg = family }));
        }

        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .width = .{ .grow = 1 },
            .gap = 10,
            .alignment = .center_cross,
        } }, .{
            icon(.{ .path = components.Lucide.palette, .size = 16, .stroke = .secondary }),
            Select{
                .key = "palette-select",
                .options = &options.values,
                .on_select = &on_select.values,
                .selected = @backingInt(s.theme.family()),
                .width = 240,
                .accessible_name = "Palette",
            },
        }));
    }
};
