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
//! Gooey owns the entry point: `gooey.App(State, render, config)` creates the
//! state, runs `on_init` with the process's io and environment, drives the
//! event loop, and runs the requests in `jobs` on workers it owns.

const std = @import("std");
const gooey = @import("gooey");

const state_mod = @import("state.zig");
const layout = @import("layout.zig");
const theme = @import("theme.zig");
const limits_mod = @import("limits.zig");
const jobs = @import("jobs.zig");

pub const AppState = state_mod.AppState;

pub const App = gooey.App(AppState, layout.render, .{
    .title = "ChatAI",
    .width = 500,
    .height = 700,
    .limits = limits_mod.limits,
    // The app starts in dark mode (`AppState.dark_mode`).
    .theme = &theme.gooey_dark,
    // macOS: the toolbar shares the traffic lights' row (`layout.zig`).
    .title_bar = .transparent,
    // Narrower than the chat column's minimum, the layout clips on the right.
    .min_width = @intFromFloat(@import("components/constants.zig").WINDOW_MIN_WIDTH),
    // Ctrl+Q for Linux and Windows; macOS also gets Cmd+Q from its app menu.
    .keymap = &.{
        .{ .keys = "cmd-q", .action = gooey.ui.action(layout.Quit) },
        .{ .keys = "ctrl-q", .action = gooey.ui.action(layout.Quit) },
    },
    .jobs = &.{ jobs.ChatJob, jobs.TranscribeJob },
    .on_init = AppState.init,
    .on_deinit = AppState.deinit,
});

pub fn main(init: std.process.Init) !void {
    return App.main(init);
}
