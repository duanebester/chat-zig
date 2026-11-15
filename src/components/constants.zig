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

/// The 36 px square, rounded, pointer-cursor box the toolbar's icon buttons
/// share. A shared `ui.Style` constant: Gooey 0.4 keeps per-element fields
/// (handlers, keys, a11y) on `ui.Box`, so styles can be reused as values.
pub const toolbar_button: ui.Style = .{
    .width = .{ .fixed = 36 },
    .height = .{ .fixed = 36 },
    .corner_radius = .all(8),
    .alignment = .center,
    .cursor = .pointer,
};
