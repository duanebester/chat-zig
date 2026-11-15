//! OpenAI dictation (transcription) model picker, shown in the settings panel.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Handler = gooey.Handler;
const components = @import("gooey-components");
const Lucide = components.Lucide;
const Select = components.Select;

const state_mod = @import("../state.zig");
const icon = @import("icon.zig").icon;

const AppState = state_mod.AppState;
const DictationModel = state_mod.DictationModel;

pub const DictationModelSelector = struct {
    /// OpenAI dictation model picker. Hidden entirely when no OpenAI key is
    /// configured — same rationale as the rest of the transcription feature
    /// (`has_openai_api_key` in `state.zig`): voice recording works fine
    /// without it, so there's nothing useful to pick from.
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);
        if (!s.has_openai_api_key) return;

        var on_select: [state_mod.DICTATION_MODEL_COUNT]Handler = undefined;
        for (&on_select, 0..) |*handler, index| {
            handler.* = cx.on(AppState.selectDictationModel, .{ .arg = @as(u32, @intCast(index)) });
        }
        std.debug.assert(on_select.len == DictationModel.display_names.len);

        cx.render(ui.box(.{ .style = .{
            .direction = .row,
            .alignment = .center_cross,
            .gap = 10,
        } }, .{
            // `speech` reads more clearly as "voice input" than a bare
            // microphone glyph.
            ui.box(.{ .style = .{ .height = .{ .fixed = 32 }, .alignment = .center } }, .{
                icon(.{ .path = Lucide.speech, .size = 18, .stroke = .secondary }),
            }),
            Select{
                .key = "dictation-model-select",
                .options = &DictationModel.display_names,
                .on_select = &on_select,
                .on_toggle = cx.on(AppState.toggleSelect, .{ .arg = state_mod.SelectId.dictation_model }),
                .on_close = cx.on(AppState.closeSelect, .{ .arg = state_mod.SelectId.dictation_model }),
                .selected = @backingInt(s.selected_dictation_model),
                .open = s.open_select == .dictation_model,
                .width = 240,
                .accessible_name = "Dictation model",
            },
        }));
    }
};
