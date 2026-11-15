//! ChatAI - AI Chat Application
//!
//! A chat client built with Gooey that talks to Anthropic's and OpenAI's APIs.
//!
//! Prerequisites:
//!   Set ANTHROPIC_API_KEY environment variable
//!   Optionally set OPENAI_API_KEY to enable GPT models and voice recording ->
//!   text transcription (gpt-4o-mini-transcribe)
//!
//! Run with: zig build run
//!
//! Gooey 0.5 owns the entry point: `gooey.App(State, render, config)` creates
//! the state, runs `on_init`, and drives the event loop. It does not hand the
//! process's `std.Io` or environment to app code, so `main` publishes both on
//! module globals before calling `App.main`. `AppState` uses them for the
//! API keys, the HTTP workers, and the session log.

const std = @import("std");
const gooey = @import("gooey");

const state_mod = @import("state.zig");
const layout = @import("layout.zig");
const theme = @import("theme.zig");
const limits_mod = @import("limits.zig");

pub const AppState = state_mod.AppState;

// =============================================================================
// Process-global handles populated from `std.process.Init`
// =============================================================================
//
// Assigned exactly once, before `App.main` runs `on_init`, and read-only for
// the rest of the process lifetime.

pub var process_env: std.process.Environ = .empty;
pub var process_io: std.Io = undefined;

pub const App = gooey.App(AppState, layout.render, .{
    .title = "ChatAI",
    .width = 500,
    .height = 700,
    .limits = limits_mod.limits,
    // The app starts in dark mode (`AppState.dark_mode`).
    .theme = &theme.gooey_dark,
    // Ctrl+Q for Linux and Windows; macOS also gets Cmd+Q from its app menu.
    .keymap = &.{
        .{ .keys = "cmd-q", .action = gooey.ui.action(layout.Quit) },
        .{ .keys = "ctrl-q", .action = gooey.ui.action(layout.Quit) },
    },
    .on_init = AppState.init,
});

pub fn main(init: std.process.Init) !void {
    process_env = init.minimal.environ;
    process_io = init.io;
    return App.main(init);
}
