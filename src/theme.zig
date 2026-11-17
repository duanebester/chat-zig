//! Theme Constants for ChatAI
//!
//! Four palettes share one Theme struct: ChatZig's own light and dark, and
//! Catppuccin Latte (light) and Macchiato (dark). `Choice` names them for
//! the settings `Select` and the toolbar's theme button.

const std = @import("std");
const gooey = @import("gooey");
const Color = gooey.Color;

// =============================================================================
// Theme Struct
// =============================================================================

pub const Theme = struct {
    // Background Colors
    bg: Color,
    surface: Color,
    card: Color,

    // Text Colors
    text: Color,
    text_secondary: Color,
    text_muted: Color,
    text_placeholder: Color,

    // Border Colors
    border: Color,
    border_light: Color,
    border_input: Color,

    // Accent Colors
    primary: Color,
    primary_hover: Color,
    accent: Color,

    // Status Colors
    danger: Color,
    success: Color,

    // Message Bubble Colors
    user_bubble: Color,
    user_bubble_border: Color,
    assistant_bubble: Color,

    // Input Area Colors
    input_bg: Color,
    input_area_bg: Color,

    // Shadow
    shadow_color: Color,

    // Icon Colors
    icon: Color,
    icon_muted: Color,

    // File Attachment Chip
    file_chip_bg: Color,
    file_chip_text: Color,
    file_chip_icon: Color,
};

// =============================================================================
// Light Theme
// =============================================================================

pub const light = Theme{
    // Background Colors
    .bg = Color.rgba(0.98, 0.98, 0.99, 0.85),
    .surface = Color.rgba(1.0, 1.0, 1.0, 0.95),
    .card = Color.rgba(1.0, 1.0, 1.0, 0.95),

    // Text Colors
    .text = Color.rgb(0.12, 0.12, 0.14),
    .text_secondary = Color.rgb(0.25, 0.25, 0.30),
    .text_muted = Color.rgb(0.55, 0.55, 0.60),
    .text_placeholder = Color.rgb(0.65, 0.65, 0.70),

    // Border Colors
    .border = Color.rgb(0.85, 0.85, 0.88),
    .border_light = Color.rgb(0.90, 0.90, 0.92),
    .border_input = Color.rgb(0.82, 0.82, 0.86),

    // Accent Colors
    .primary = Color.rgb(0.20, 0.20, 0.25),
    .primary_hover = Color.rgb(0.30, 0.30, 0.35),
    .accent = Color.rgb(0.545, 0.361, 0.965),

    // Status Colors
    .danger = Color.rgb(0.90, 0.25, 0.25),
    .success = Color.rgb(0.22, 0.78, 0.45),

    // Message Bubble Colors
    .user_bubble = Color.rgba(1.0, 1.0, 1.0, 0.9),
    .user_bubble_border = Color.rgb(0.88, 0.88, 0.92),
    .assistant_bubble = Color.transparent,

    // Input Area Colors
    .input_bg = Color.rgba(1.0, 1.0, 1.0, 0.95),
    .input_area_bg = Color.rgba(1.0, 1.0, 1.0, 0.92),

    // Shadow
    .shadow_color = Color.rgba(0.0, 0.0, 0.0, 0.06),

    // Icon Colors
    .icon = Color.rgb(0.40, 0.40, 0.50),
    .icon_muted = Color.rgb(0.55, 0.55, 0.62),

    // File Attachment Chip
    .file_chip_bg = Color.rgba(0.545, 0.361, 0.965, 0.12),
    .file_chip_text = Color.rgb(0.45, 0.28, 0.82),
    .file_chip_icon = Color.rgb(0.545, 0.361, 0.965),
};

// =============================================================================
// Dark Theme
// =============================================================================

pub const dark = Theme{
    // Background Colors
    .bg = Color.rgba(0.14, 0.14, 0.16, 0.92),
    .surface = Color.rgba(0.16, 0.16, 0.18, 0.95),
    .card = Color.rgba(0.18, 0.18, 0.20, 0.95),

    // Text Colors
    .text = Color.rgb(0.94, 0.94, 0.96),
    .text_secondary = Color.rgb(0.72, 0.72, 0.78),
    .text_muted = Color.rgb(0.50, 0.50, 0.56),
    .text_placeholder = Color.rgb(0.42, 0.42, 0.48),

    // Border Colors
    .border = Color.rgb(0.28, 0.28, 0.32),
    .border_light = Color.rgb(0.24, 0.24, 0.28),
    .border_input = Color.rgb(0.32, 0.32, 0.38),

    // Accent Colors
    .primary = Color.rgb(0.88, 0.88, 0.92),
    .primary_hover = Color.rgb(0.78, 0.78, 0.82),
    .accent = Color.rgb(0.545, 0.361, 0.965),

    // Status Colors
    .danger = Color.rgb(0.92, 0.30, 0.30),
    .success = Color.rgb(0.25, 0.78, 0.50),

    // Message Bubble Colors - darker with subtle border
    .user_bubble = Color.rgba(0.20, 0.20, 0.24, 0.95),
    .user_bubble_border = Color.rgb(0.30, 0.30, 0.36),
    .assistant_bubble = Color.transparent,

    // Input Area Colors - distinct card at bottom
    .input_bg = Color.rgba(0.20, 0.20, 0.24, 0.98),
    .input_area_bg = Color.rgba(0.18, 0.18, 0.22, 0.95),

    // Shadow
    .shadow_color = Color.rgba(0.0, 0.0, 0.0, 0.4),

    // Icon Colors
    .icon = Color.rgb(0.62, 0.62, 0.68),
    .icon_muted = Color.rgb(0.48, 0.48, 0.54),

    // File Attachment Chip
    .file_chip_bg = Color.rgba(0.545, 0.361, 0.965, 0.2),
    .file_chip_text = Color.rgb(0.72, 0.58, 0.98),
    .file_chip_icon = Color.rgb(0.65, 0.50, 0.95),
};

// =============================================================================
// Catppuccin
// =============================================================================
//
// Hex values from Catppuccin's published palette (catppuccin/palette,
// palette.json). Both flavours map roles the same way, following
// Catppuccin's style guide:
// - Backgrounds: `base` is the window; `mantle`, its "secondary pane"
//   colour, fills the cards, the composer, and the settings rows, so they
//   read as recessed panes in both the light and the dark flavour.
// - Text: `text` for body copy, `subtext1` for secondary text, `overlay1`
//   for muted labels and icons, `overlay0` for placeholders (the faintest
//   readable step), and `overlay2` for the stronger icon colour.
// - Borders: `surface0` for the faintest rule, `surface1` for the usual
//   border, and `surface2` around inputs, which need the most definition.
// - Accents: `mauve` for primary (the send and record buttons, the
//   attachment chip), whose icons draw in `base` as Catppuccin puts text
//   on accents; `blue` for the secondary accent; `red` and `green` for
//   danger and success.
// - User bubbles: `surface0` in Macchiato, a step lighter than the window
//   like the dark theme's; Latte has nothing lighter than `base`, so its
//   bubble is `mantle` with a `surface0` rule.
// Shadows are not part of the palette, so they keep the light and dark
// themes' black at the same strength.

const Palette = struct {
    base: u32,
    mantle: u32,
    crust: u32,
    surface0: u32,
    surface1: u32,
    surface2: u32,
    overlay0: u32,
    overlay1: u32,
    overlay2: u32,
    subtext0: u32,
    subtext1: u32,
    text: u32,
    mauve: u32,
    lavender: u32,
    blue: u32,
    red: u32,
    green: u32,
};

const latte_palette = Palette{
    .base = 0xeff1f5,
    .mantle = 0xe6e9ef,
    .crust = 0xdce0e8,
    .surface0 = 0xccd0da,
    .surface1 = 0xbcc0cc,
    .surface2 = 0xacb0be,
    .overlay0 = 0x9ca0b0,
    .overlay1 = 0x8c8fa1,
    .overlay2 = 0x7c7f93,
    .subtext0 = 0x6c6f85,
    .subtext1 = 0x5c5f77,
    .text = 0x4c4f69,
    .mauve = 0x8839ef,
    .lavender = 0x7287fd,
    .blue = 0x1e66f5,
    .red = 0xd20f39,
    .green = 0x40a02b,
};

const macchiato_palette = Palette{
    .base = 0x24273a,
    .mantle = 0x1e2030,
    .crust = 0x181926,
    .surface0 = 0x363a4f,
    .surface1 = 0x494d64,
    .surface2 = 0x5b6078,
    .overlay0 = 0x6e738d,
    .overlay1 = 0x8087a2,
    .overlay2 = 0x939ab7,
    .subtext0 = 0xa5adcb,
    .subtext1 = 0xb8c0e0,
    .text = 0xcad3f5,
    .mauve = 0xc6a0f6,
    .lavender = 0xb7bdf8,
    .blue = 0x8aadf4,
    .red = 0xed8796,
    .green = 0xa6da95,
};

fn catppuccin(comptime p: Palette, comptime flavour: enum { light, dark }) Theme {
    const c = Color.hex;
    const is_dark = flavour == .dark;
    return .{
        .bg = c(p.base),
        .surface = c(p.mantle),
        .card = c(p.mantle),
        .text = c(p.text),
        .text_secondary = c(p.subtext1),
        .text_muted = c(p.overlay1),
        .text_placeholder = c(p.overlay0),
        .border = c(p.surface1),
        .border_light = c(p.surface0),
        .border_input = c(p.surface2),
        .primary = c(p.mauve),
        // Unused by the layout today; lavender is mauve's lighter neighbour.
        .primary_hover = c(p.lavender),
        .accent = c(p.blue),
        .danger = c(p.red),
        .success = c(p.green),
        .user_bubble = if (is_dark) c(p.surface0) else c(p.mantle),
        .user_bubble_border = if (is_dark) c(p.surface1) else c(p.surface0),
        .assistant_bubble = Color.transparent,
        .input_bg = c(p.mantle),
        .input_area_bg = c(p.mantle),
        .shadow_color = if (is_dark) dark.shadow_color else light.shadow_color,
        .icon = c(p.overlay2),
        .icon_muted = c(p.overlay1),
        .file_chip_bg = c(p.mauve).withAlpha(if (is_dark) 0.2 else 0.12),
        .file_chip_text = c(p.mauve),
        .file_chip_icon = c(p.mauve),
    };
}

pub const latte = catppuccin(latte_palette, .light);
pub const macchiato = catppuccin(macchiato_palette, .dark);

// =============================================================================
// Theme Choice
// =============================================================================

/// The theme the user picked: a `Select` in Settings, and the toolbar's
/// theme button, which steps through them in this order.
pub const Choice = enum(u8) {
    light,
    dark,
    latte,
    macchiato,

    pub const count = @typeInfo(Choice).@"enum".field_names.len;

    /// The settings `Select`'s options, in declaration order.
    pub const display_names = [count][]const u8{ "Light", "Dark", "Latte", "Macchiato" };

    pub fn next(self: Choice) Choice {
        return @fromBackingInt(@intCast((@as(u32, @backingInt(self)) + 1) % count));
    }

    pub fn displayName(self: Choice) []const u8 {
        return display_names[@backingInt(self)];
    }
};

pub fn get(choice: Choice) Theme {
    return switch (choice) {
        .light => light,
        .dark => dark,
        .latte => latte,
        .macchiato => macchiato,
    };
}

// =============================================================================
// Gooey Themes
// =============================================================================
//
// Gooey 0.4 components (`TextArea`, `Select`) no longer take per-instance
// colours: they resolve theme tokens. These map ChatZig's palette onto
// `gooey.Theme` so the stock components match the hand-built ones, and the
// theme toggle swaps them with `Effects.setTheme`. The window clears to
// `bg`, which is opaque because 0.4.0 cut the glass window effect.

fn gooeyTheme(comptime t: Theme) gooey.Theme {
    const theme: gooey.Theme = .{
        .bg = t.bg.withAlpha(1),
        // TextArea's fill and the Select trigger: the composer card's fill,
        // so the input sits in the card without a second visible plate.
        // Opaque: `Select` paints its menu on a popover layer in `surface`,
        // and a translucent menu shows the controls beneath it.
        .surface = t.input_area_bg.withAlpha(1),
        // Hovered Select trigger and options.
        .overlay = t.border,
        .primary = t.primary,
        // Toolbar and composer icons (`components/icon.zig` paints with
        // tokens, so the palette's icon colour needs a token of its own).
        .secondary = t.icon_muted,
        // The attachment chip's icon.
        .accent = t.file_chip_icon,
        .success = t.success,
        .warning = t.danger,
        .danger = t.danger,
        // Labels on primary and danger fills (Gooey's Button and Checkbox,
        // which ChatZig doesn't use today): the window colour, as the
        // composer's own icons on primary already are.
        .on_primary = t.bg.withAlpha(1),
        .on_danger = t.bg.withAlpha(1),
        .text = t.text,
        .subtext = t.text_secondary,
        // Placeholders and the TextArea scrollbar.
        .muted = t.text_placeholder,
        .border = t.border_input,
        .border_focus = focus_ring,
    };
    // `Select` paints its menu (`surface`) and hovered rows (`overlay`) over
    // other controls, so both must be opaque or the controls show through.
    if (theme.surface.a != 1) @compileError("gooey theme surface must be opaque");
    if (theme.overlay.a != 1) @compileError("gooey theme overlay must be opaque");
    return theme;
}

/// The blue focus outline Gooey 0.2.9's TextArea drew on both themes.
const focus_ring = Color.rgb(0.29, 0.47, 0.96);

pub const gooey_dark: gooey.Theme = gooeyTheme(dark);
pub const gooey_light: gooey.Theme = gooeyTheme(light);
pub const gooey_latte: gooey.Theme = gooeyTheme(latte);
pub const gooey_macchiato: gooey.Theme = gooeyTheme(macchiato);

/// The `gooey.Theme` for `choice`. Gooey's `Theme.isDark` picks the macOS
/// title bar's look from it: Light and Latte light, Dark and Macchiato dark.
pub fn gooeyFor(choice: Choice) *const gooey.Theme {
    return switch (choice) {
        .light => &gooey_light,
        .dark => &gooey_dark,
        .latte => &gooey_latte,
        .macchiato => &gooey_macchiato,
    };
}

comptime {
    for (std.enums.values(Choice)) |choice| {
        const expect_dark = choice == .dark or choice == .macchiato;
        if (gooeyFor(choice).isDark() != expect_dark) {
            @compileError("theme " ++ @tagName(choice) ++ " has the wrong light/dark look");
        }
    }
}
