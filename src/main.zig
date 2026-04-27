//! ChatAI - AI Chat Application
//!
//! A beautiful chat application built with Gooey that connects to Anthropic's API.
//! Features a modern glass UI design.
//!
//! Prerequisites:
//!   Set ANTHROPIC_API_KEY environment variable
//!
//! Run with: zig build run
//!
//! Zig 0.16 notes:
//!   - `main` receives `std.process.Init`, which provides `io`, `gpa`, `arena`,
//!     and environment variables. We stash a reference on a process-global
//!     so later-constructed components (`AppState.init`, the HTTP client) can
//!     reach them without threading an extra parameter through every call.
//!   - The `Io` instance is forwarded into gooey's `App` config so that the
//!     framework, our HTTP client, and any future `io.async` work all share
//!     the same threaded IO.

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;

const state_mod = @import("state.zig");
const layout = @import("layout.zig");

pub const AppState = state_mod.AppState;

// =============================================================================
// Process-global handles populated from `std.process.Init`
// =============================================================================
//
// Gooey's `App.main()` does not forward `init` into user code — render and
// lifecycle callbacks only receive a `*Cx`. Rather than fork the framework to
// thread `init` everywhere, we publish the handles we actually need on these
// module-level variables. `AppState.init` pulls the env/IO from here.
//
// These are assigned exactly once, before `App.main()` is called, and then
// treated as read-only for the rest of the process lifetime.

pub var process_env: std.process.Environ = .empty;
pub var process_io: std.Io = undefined;

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
    .background_color = gooey.Color.rgba(0.14, 0.14, 0.16, 0.7),
    // Semi-transparent background
    .background_opacity = 0.7,
    // Enable glass effect
    .glass_style = .blur,
    .glass_corner_radius = 12.0,
    // Transparent titlebar for seamless look
    .titlebar_transparent = true,
    .full_size_content = true,
    // Lifecycle
    .init = AppState.init,
    // Handle global keyboard shortcuts
    .on_event = onEvent,
});

pub fn main(init: std.process.Init) !void {
    if (platform.is_wasm) unreachable;

    // Publish env + io so `AppState.init` can consume them once gooey calls
    // it with only a `*Cx`. Written once, before `App.main()` spins up.
    process_env = init.minimal.environ;
    process_io = init.io;

    return App.main();
}
