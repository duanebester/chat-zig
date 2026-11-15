//! Chat model picker (Anthropic + OpenAI), shown in the settings panel.
//!
//! Gooey 0.2.9's `Select` drew a provider logo on each option. Gooey 0.4's
//! `Select` takes text options only, so the logo of the selected model's
//! provider sits beside the trigger instead.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Handler = gooey.Handler;
const Select = @import("gooey-components").Select;

const state_mod = @import("../state.zig");
const icon = @import("icon.zig").icon;
const logos = @import("provider_logos.zig");

const AppState = state_mod.AppState;
const Model = state_mod.Model;

pub const ModelSelector = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        // One handler per option, as `Select` requires; the array only has
        // to live through this build.
        var on_select: [state_mod.MODEL_COUNT]Handler = undefined;
        for (&on_select, 0..) |*handler, index| {
            handler.* = cx.on(AppState.selectModel, .{ .arg = @as(u32, @intCast(index)) });
        }
        std.debug.assert(on_select.len == Model.display_names.len);

        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .alignment = .center_cross,
            .gap = 10,
        } }, .{
            ui.box(.{ .style = .{ .height = .{ .fixed = 32 }, .alignment = .center } }, .{
                switch (s.selected_model.provider()) {
                    .anthropic => icon(.{
                        .path = logos.anthropic,
                        .size = 18,
                        .fill = .secondary,
                        .viewbox = logos.anthropic_viewbox,
                    }),
                    .openai => icon(.{ .path = logos.openai, .size = 18, .fill = .secondary }),
                },
            }),
            Select{
                .key = "model-select",
                .options = &Model.display_names,
                .on_select = &on_select,
                .on_toggle = cx.on(AppState.toggleSelect, .{ .arg = state_mod.SelectId.model }),
                .on_close = cx.on(AppState.closeSelect, .{ .arg = state_mod.SelectId.model }),
                .selected = @backingInt(s.selected_model),
                .open = s.open_select == .model,
                .width = 240,
                .accessible_name = "Chat model",
            },
        }));
    }
};
