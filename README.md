# ChatZig

An AI chat application built with [Gooey](https://github.com/duanebester/gooey) that connects
to both Anthropic's Claude and OpenAI's GPT models.

Inspired by [chat-ai](https://github.com/duanebester/chat-ai) (GPUI/Rust version).

> **Status:** Zig 0.16 / Gooey v0.2.9. Uses the new `std.Io` stack end-to-end —
> `std.Io.Group` for fiber lifecycle, `std.Io.Queue(T)` for cross-thread result
> delivery, `std.Io.Dir` / `std.Io.File` for attachment and session-log reads,
> and the `io`-aware `std.http.Client` for both the Anthropic and OpenAI
> request paths.

<table>
  <tr>
    <td><img src="https://github.com/duanebester/chat-zig/blob/main/assets/light.png" height="300px" /></td>
    <td><img src="https://github.com/duanebester/chat-zig/blob/main/assets/dark.png" height="300px" /></td>
  </tr>
</table>

## Features

- 💬 Chat with Claude and GPT models, switchable per-conversation from the settings panel
- 🎙️ Voice dictation — record a microphone clip and transcribe it via OpenAI (`gpt-4o-mini-transcribe`)
- 🧹 Automatic chat compaction — long conversations are summarized so requests stay bounded (see [`docs/CHAT_COMPACTION.md`](docs/CHAT_COMPACTION.md))
- 💾 Session persistence — conversations are logged to `sessions/*.jsonl` and browsable/restorable from a history panel
- 🎨 Light/dark theme, glass window effect
- 📜 Virtual list for efficient message rendering
- 🔄 Async HTTP requests via `std.Io.Group` + `std.Io.Queue` (non-blocking UI, zero heap per result), with retry/backoff shared across providers
- ✂️ Structured cancellation — window close cleanly unwinds in-flight fetches
- ⌨️ Text input with send button, file attachments, and a live microphone level meter while recording

## Prerequisites

1. **Zig 0.16.0** — Install from [ziglang.org](https://ziglang.org/download/). Older versions will not build; the code depends on `std.Io`, `std.process.Init`, and the new `std.http.Client.io` field.
2. **Anthropic API Key** — Get one from [Anthropic Console](https://console.anthropic.com/). Required for Claude models.
3. **OpenAI API Key** (optional) — Get one from [OpenAI Platform](https://platform.openai.com/). Enables GPT chat models and voice dictation transcription; the app runs fine without it, just with those features disabled.

Gooey is pinned to [v0.2.9](https://github.com/duanebester/gooey/releases/tag/v0.2.9) in `build.zig.zon` (tarball URL + hash), so no local checkout of Gooey is needed.

macOS only for now — audio capture uses CoreAudio/AudioToolbox directly.

## Setup

```bash
# Clone
git clone https://github.com/yourusername/chat-zig
cd chat-zig

# Set your API key(s)
export ANTHROPIC_API_KEY="your-key-here"
export OPENAI_API_KEY="your-key-here"   # optional: GPT models + voice dictation

# Build and run
zig build run

# Run the (offline) unit tests — JSON escaping, response parsing, base64,
# compaction cut arithmetic, session log framing, date formatting, etc.
zig build test
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
3. **`layout.zig` + `src/components/`** — render UI based on current state.
   The top of `render` calls `s.drainResults(cx)` to apply any completed
   worker outputs before anything else reads `is_loading` or `messages`.
   `layout.zig` composes the root from the components in `src/components/`;
   each component reaches for its siblings directly rather than through a
   shared registry, so the dependency edges stay visible in each file's
   imports.
4. **Command handlers** — update state in response to user actions.
   `sendMessage` launches an HTTP worker via `io_group.async(...)` instead
   of spawning a raw `std.Thread` + dispatcher trampoline. The worker picks
   the Anthropic or OpenAI client based on `AppState.selected_model`'s
   provider; both clients share the retry/backoff policy in `src/http/http.zig`.

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
        }
    }
}
```

No per-request heap allocation, no dispatcher trampoline, and the
`std.Io.Group` registration with Gooey guarantees that window close
cancels any in-flight fetch before `AppState` is torn down.

### Compaction and session persistence

Long conversations are summarized rather than truncated: `AppState.messages`
is never mutated, and a small summary + cut index is layered on top only
when assembling the next request. See
[`docs/CHAT_COMPACTION.md`](docs/CHAT_COMPACTION.md) for the full design,
including how the cut is computed across ring-buffer overflow and how
sessions are framed and restored from `sessions/*.jsonl`.

## License

MIT
