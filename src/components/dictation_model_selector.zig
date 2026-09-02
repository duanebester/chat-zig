//! OpenAI dictation (transcription) model picker, shown in the settings panel.

const std = @import("std");
const gooey = @import("gooey");
const Cx = gooey.Cx;
const ui = gooey.ui;
const Svg = gooey.components.Svg;
const Lucide = gooey.components.Lucide;
const Select = gooey.components.Select;

const state_mod = @import("../state.zig");
const theme_mod = @import("../theme.zig");

const AppState = state_mod.AppState;
const DictationModel = state_mod.DictationModel;

pub const DictationModelSelector = struct {
    // OpenAI logomark SVG path (viewBox: 0 0 24 24)
    const openai_icon = "<path d=\"M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z\"/>";

    /// One dropdown-option icon per `DictationModel` variant, index-aligned
    /// with `DictationModel.display_names`. Every option is OpenAI today,
    /// but the logo lives on the row (`Select.option_icons`) rather than
    /// the trigger for the same reason as `ModelSelector`: a picker whose
    /// options could someday span providers shouldn't hardcode one logo
    /// next to the trigger.
    const option_icons = [state_mod.DICTATION_MODEL_COUNT]?Select.OptionIcon{
        .{ .path = openai_icon },
        .{ .path = openai_icon },
    };

    comptime {
        std.debug.assert(option_icons.len == DictationModel.display_names.len);
    }

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
            // Generic "talking" icon — the OpenAI logo moved onto the
            // dropdown option (see `option_icons`). `speech` reads more
            // clearly as "voice input" than a bare microphone glyph.
            // Lucide icons are open/stroke paths (per `Svg`'s own doc
            // comment), so `no_fill` + `stroke_color` is required for them
            // to render as their intended outline rather than a solid blob
            // — same treatment as `Lucide.zap` in `content_area.zig`.
            ui.box(.{
                .height = 32,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                Svg{
                    .path = Lucide.speech,
                    .size = 18,
                    .no_fill = true,
                    .stroke_color = t.icon_muted,
                    .stroke_width = 1.5,
                },
            }),
            // Dictation model select dropdown
            Select{
                .id = "dictation-model-select",
                .options = &DictationModel.display_names,
                .option_icons = &option_icons,
                .option_icon_color = t.icon_muted,
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
