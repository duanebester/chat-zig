//! Shared layout metrics for the ChatAI components.
//!
//! These live in one place because sibling components have to agree on them:
//! the composer's action buttons, the record/send buttons, and the message
//! list's horizontal padding all key off the same numbers. Duplicating them
//! per file would let the UI silently drift apart.

pub const INPUT_CARD_CORNER_RADIUS = 16;
pub const BUBBLE_CORNER_RADIUS = 12;
pub const BUTTON_CORNER_RADIUS = 6;
pub const ACTION_BUTTON_SIZE: f32 = 36;
pub const ACTION_ICON_SIZE: f32 = 18;
pub const CONTENT_PADDING = 24;
pub const CHAT_MIN_WIDTH: f32 = 400;

/// Horizontal chrome between the window edge and a message bubble: the root
/// chat column's 20px on each side, plus the virtual list's `CONTENT_PADDING`
/// on each side. `message.zig` subtracts this from the window width to get
/// the bubble's max width, and both the measure and render paths must use
/// the same value or cached heights won't match what's drawn.
pub const MESSAGE_HORIZONTAL_CHROME: f32 = 40 + (CONTENT_PADDING * 2);
