//! Shared layout metrics for the ChatAI components.
//!
//! These live in one place because sibling components have to agree on them:
//! the composer's action buttons, the record/send buttons, and the message
//! list's horizontal padding all key off the same numbers. Duplicating them
//! per file would let the UI silently drift apart.

const ui = @import("gooey").ui;

pub const INPUT_CARD_CORNER_RADIUS: f32 = 16;
pub const BUBBLE_CORNER_RADIUS: f32 = 12;
pub const BUTTON_CORNER_RADIUS: f32 = 6;
pub const ACTION_BUTTON_SIZE: f32 = 36;
pub const ACTION_ICON_SIZE: f32 = 18;
pub const CONTENT_PADDING: f32 = 24;
pub const CHAT_MIN_WIDTH: f32 = 400;
pub const TOOLBAR_BUTTON_WIDTH: f32 = 36;
pub const TOOLBAR_BUTTON_COUNT: f32 = 3;
pub const TOOLBAR_GAP: f32 = 2;
pub const TOOLBAR_PADDING_X: f32 = 10;
/// The traffic lights' inset on macOS (`cx.titleBarInset().left`), as
/// measured on macOS 26: the lights span 8 to 70 pt, plus the 8 pt margin.
pub const TRAFFIC_LIGHTS_INSET: f32 = 78;

/// The narrowest window the layout fits: the wider of the chat column's
/// `width_min`, below which the column clips on the right, and the toolbar
/// (its padding, the lights' inset, and the buttons with their gaps), below
/// which the icons clip. The column decides it today.
pub const WINDOW_MIN_WIDTH: f32 = @max(CHAT_MIN_WIDTH, toolbar_width_min);
const toolbar_width_min: f32 = 2 * TOOLBAR_PADDING_X + TRAFFIC_LIGHTS_INSET +
    TOOLBAR_BUTTON_COUNT * TOOLBAR_BUTTON_WIDTH + (TOOLBAR_BUTTON_COUNT - 1) * TOOLBAR_GAP;

/// The rounded, pointer-cursor box the toolbar's icon buttons share: 36 px
/// square, or as tall as macOS's title strip (`cx.titleBarInset().top`)
/// when the toolbar sits in it, so the icons centre on the traffic lights'
/// line. Gooey 0.4 keeps per-element fields (handlers, keys, a11y) on
/// `ui.Box`, so the style is a plain value.
pub fn toolbarButton(strip_height: f32) ui.Style {
    const height: f32 = if (strip_height > 0) @min(strip_height, 36) else 36;
    return .{
        .width = .{ .fixed = TOOLBAR_BUTTON_WIDTH },
        .height = .{ .fixed = height },
        .corner_radius = .all(8),
        .alignment = .center,
        .cursor = .pointer,
    };
}
