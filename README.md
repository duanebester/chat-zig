# ChatZig

A simple AI chat application built with [Gooey](https://github.com/duanebester/gooey) that connects to Anthropic's Claude API.

Inspired by [chat-ai](https://github.com/duanebester/chat-ai) (GPUI/Rust version).

> **Status:** Zig 0.16 / Gooey v0.1.0. Uses the new `std.Io` stack end-to-end —
> `std.Io.Group` for fiber lifecycle, `std.Io.Queue(T)` for cross-thread result
> delivery, `std.Io.Dir` / `std.Io.File` for attachment reads, and the
> `io`-aware `std.http.Client` for the Anthropic request path.

<table>
  <tr>
    <td><img src="https://github.com/duanebester/chat-zig/blob/main/assets/light.png" height="300px" /></td>
    <td><img src="https://github.com/duanebester/chat-zig/blob/main/assets/dark.png" height="300px" /></td>
  </tr>
</table>

## Features

- 💬 Chat with Claude AI
- 🎨 Dark theme UI
- 📜 Virtual list for efficient message rendering
- 🔄 Async HTTP requests via `std.Io.Group` + `std.Io.Queue` (non-blocking UI, zero heap per result)
- 🧹 Structured cancellation — window close cleanly unwinds in-flight fetches
- ⌨️ Simple text input with send button

## Prerequisites

1. **Zig 0.16.0** — Install from [ziglang.org](https://ziglang.org/download/). Older versions will not build; the code depends on `std.Io`, `std.process.Init`, and the new `std.http.Client.io` field.
2. **Anthropic API Key** — Get one from [Anthropic Console](https://console.anthropic.com/).

Gooey is pinned to [v0.1.0](https://github.com/duanebester/gooey/releases/tag/v0.1.0) in `build.zig.zon` (tarball URL + hash), so no local checkout of Gooey is needed.

## Setup

```bash
# Clone
git clone https://github.com/yourusername/chat-zig
cd chat-zig

# Set your API key
export ANTHROPIC_API_KEY="your-key-here"

# Build and run
zig build run

# Run the (offline) unit tests — JSON escaping, response parsing, base64, etc.
zig build test
```

## Project Structure

```
chat-zig/
├── build.zig         # Build configuration
├── build.zig.zon     # Dependencies (Gooey)
└── src/
    ├── main.zig      # Entry point & app setup
    ├── state.zig     # Application state & message handling
    ├── layout.zig    # UI components (Header, MessageList, InputArea)
    ├── http.zig      # Anthropic API client
    └── theme.zig     # Color definitions
```

## Architecture

This follows the Gooey pattern for stateful apps, using Zig 0.16's `std.Io`
primitives for all async work:

1. **`main(init: std.process.Init)`** — pulls `io` + `environ` from the
   runtime-provided `Init` struct and publishes them on module-level
   globals so `AppState.init` can reach them without extra plumbing.
2. **AppState** — single source of truth. Owns a `std.Io.Group` (for fiber
   lifecycle), a `std.Io.Queue(WorkerResult)` (for result delivery), and
   the staging buffers that workers fill.
3. **Layout functions** — render UI based on current state. The top of
   `render` calls `s.drainResults(cx)` to apply any completed worker
   outputs before anything else reads `is_loading` or `messages`.
4. **Command handlers** — update state in response to user actions.
   `sendMessage` launches an HTTP worker via `io_group.async(...)` instead
   of spawning a raw `std.Thread` + dispatcher trampoline.

### Async result flow

```zig
// sendMessage launches a fiber on the shared Io instance.
// The Io.Group owns the task — cancellation on window close unwinds it.
self.io_group.async(io, httpWorker, .{
    io,
    &self.http_client.?,
    self,
    &self.result_queue,
});

// httpWorker runs off the main thread, blocks on the HTTP call, writes
// the response text into the staging buffer, and signals completion.
fn httpWorker(
    io: std.Io,
    client: *http.AnthropicClient,
    app: *AppState,
    queue: *std.Io.Queue(WorkerResult),
) void {
    var result = client.sendBlocking(request);
    defer result.deinit(client.allocator);

    // Write staging buffer BEFORE putOne — `putOne` is the happens-before
    // edge that makes these writes visible to the render thread.
    const outcome: WorkerResult = ...;
    queue.putOne(io, outcome) catch {};
    app.requestRenderFromWorker(); // nudge the event loop
}

// The render loop drains the queue each frame — non-blocking, bounded.
pub fn drainResults(self: *AppState, cx: *gooey.Cx) void {
    var buf: [RESULT_QUEUE_CAPACITY]WorkerResult = undefined;
    for (cx.drainQueue(WorkerResult, &self.result_queue, &buf)) |r| {
        switch (r) {
            .chat_success => |ok| self.applyChatSuccess(ok),
            .chat_error => |err| self.applyChatError(err),
            .canvas => |cr| self.applyCanvasResult(cr),
        }
    }
}
```

No per-request heap allocation, no dispatcher trampoline, and the
`std.Io.Group` registration with Gooey guarantees that window close
cancels any in-flight fetch before `AppState` is torn down.

## License

MIT
