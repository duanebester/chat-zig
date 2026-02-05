//! ChatAI - AI Chat Application
//!
//! A beautiful chat application built with Gooey that connects to Anthropic's API.
//! Features a modern glass UI design.
//!
//! Prerequisites:
//!   Set ANTHROPIC_API_KEY environment variable
//!
//! Run with: zig build run

const gooey = @import("gooey");
const platform = gooey.platform;

const state_mod = @import("state.zig");
const layout = @import("layout.zig");

pub const AppState = state_mod.AppState;

var state = AppState{};

/// Handle global keyboard shortcuts
fn onEvent(cx: *gooey.Cx, event: gooey.InputEvent) bool {
    switch (event) {
        .key_down => |k| {
            // Cmd+Q to quit
            if (k.key == .q and k.modifiers.cmd) {
                cx.quit();
                return true;
            }
        },
        else => {},
    }
    return false;
}

const App = gooey.App(AppState, &state, layout.render, .{
    .title = "ChatAI",
    .width = 500,
    .height = 700,
    // Dark background for glass effect (app starts in dark mode)
    .background_color = gooey.Color.init(0.14, 0.14, 0.16, 0.7),
    // Semi-transparent background
    .background_opacity = 0.7,
    // Enable glass effect
    .glass_style = .blur,
    .glass_corner_radius = 12.0,
    // Transparent titlebar for seamless look
    .titlebar_transparent = true,
    .full_size_content = true,
    // Handle global keyboard shortcuts
    .on_event = onEvent,
});

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}
