//! Theme Constants for ChatAI
//!
//! Supports both light and dark modes with a unified Theme struct.

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
};

// =============================================================================
// Theme Selection Helper
// =============================================================================

pub fn get(is_dark_mode: bool) Theme {
    return if (is_dark_mode) dark else light;
}

// =============================================================================
// Glass Background Colors (for window configuration)
// =============================================================================

pub const glass_light = Color.init(0.96, 0.96, 0.97, 1.0);
pub const glass_dark = Color.init(0.12, 0.12, 0.14, 1.0);

pub fn getGlassColor(is_dark_mode: bool) Color {
    return if (is_dark_mode) glass_dark else glass_light;
}
