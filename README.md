# ChatZig

An AI chat application built with [Gooey](https://github.com/duanebester/gooey) that connects
to both Anthropic's Claude and OpenAI's GPT models.

Inspired by [chat-ai](https://github.com/duanebester/chat-ai) (GPUI/Rust version).

> **Status:** Zig 0.17 / Gooey v0.6.3. Runs on macOS and on Linux (Wayland).
> HTTP runs as Gooey background jobs (`effects.spawn`) that post results back to the
> main thread; files and session logs use `std.Io.Dir` / `std.Io.File`;
> both the Anthropic and OpenAI paths use the `io`-aware `std.http.Client`.

<img src="assets/themes.png" width="820px"
  alt="ChatZig in its Light, Catppuccin Latte, Catppuccin Macchiato, and Dark themes" />

## Features

- 💬 Chat with Claude and GPT models, switchable per-conversation from the settings panel
- 🎙️ Voice dictation — record a microphone clip and transcribe it via OpenAI (`gpt-transcribe`)
- 🧹 Automatic chat compaction — long conversations are summarized so requests stay bounded, with Anthropic's native compaction where the model supports it (see [`docs/CHAT_COMPACTION.md`](docs/CHAT_COMPACTION.md))
- 💾 Session persistence — conversations are logged to `sessions/*.jsonl` and browsable/restorable from a history panel
- 🎨 Four themes — Light, Dark, and Catppuccin Latte and Macchiato — from Settings or the toolbar
- 📜 Streaming replies into a scrolling transcript of any length that follows the newest message
- 🔄 Async HTTP requests as Gooey background jobs (non-blocking UI, no polling, zero heap per result), with retry/backoff shared across providers
- ✂️ Stop button cancels the in-flight request
- ⌨️ Text input (with IME) and send button, file attachments, and a live microphone level meter while recording

## Runtime

Measured on a MacBook Pro (M2 Max) running macOS 26.6, ReleaseFast build, with a
1000×750 pt window on a 120 Hz display.

| | |
|---|---|
| Binary | 10.4 MiB (ReleaseFast), 9.3 MiB (ReleaseSmall) |
| Launch to first window | ~235 ms warm |
| Memory, idle | ~60 MB physical footprint |
| Memory, 200-message session | ~80 MB physical footprint |
| CPU, idle | 0.3% (no frames are drawn when nothing changes) |
| CPU, streaming a reply | ~5% of one core |
| Frame time, streaming | main thread p50 0.8 ms, p99 2.1 ms |
| Frame time, scrolling | steady 120 fps, main thread p99 1.6 ms |

Memory is `vmmap --summary` physical footprint; frame times come from a
`-Dframe-trace=passive` build of the same commit.

## Prerequisites

1. **Zig 0.17.0** or newer — Install from [ziglang.org](https://ziglang.org/download/). Gooey 0.6 requires it (`minimum_zig_version`).
2. **Anthropic API Key** — Get one from [Anthropic Console](https://console.anthropic.com/). Required for Claude models.
3. **OpenAI API Key** (optional) — Get one from [OpenAI Platform](https://platform.openai.com/). Enables GPT chat models and voice dictation transcription; the app runs fine without it, just with those features disabled.

Gooey is pinned to [v0.6.3](https://github.com/duanebester/gooey/releases/tag/v0.6.3) in `build.zig.zon`. To move to another release:

```bash
zig fetch --save git+https://github.com/duanebester/gooey#v0.6.3
```

**macOS** 14 or newer. **Linux** needs a Wayland compositor and Gooey's system libraries
(no X11):

```bash
# Debian/Ubuntu
sudo apt install libwayland-dev libvulkan-dev libfreetype-dev libharfbuzz-dev \
    libfontconfig-dev libpng-dev libdbus-1-dev
```

Without a Vulkan driver, build with `-Dlinux-backend=wayland_cpu`. Microphone recording
uses CoreAudio, so on Linux the record button stays disabled; everything else works.

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
zig build run -Dlinux-backend=wayland_cpu   # Linux without a GPU driver

# Run the (offline) unit tests — JSON escaping, response parsing, base64,
# compaction cut arithmetic, session log framing, date formatting, etc.
zig build test
```

## Architecture

ChatZig follows Gooey's app shape: one state struct, a render function, and handlers.

1. **`main.zig`** declares the app: `gooey.App(AppState, layout.render, .{ ... })` owns
   the state, declares the resource budget (`src/limits.zig`) and lists the background
   jobs (`.jobs = &.{ ChatJob, TranscribeJob }`).
2. **AppState** — single source of truth, initialized in place by Gooey and finished in
   `on_init`, which receives `gooey.Init` (`io`, `environ`) and creates the HTTP clients.
   Its handlers are plain methods bound with `cx.on(AppState.sendMessage, .{})`; the ones
   that need the framework take `*gooey.Effects` (spawn a job, scroll, file dialog, quit).
3. **`layout.zig` + `src/components/`** — render UI from the current state.
4. **Jobs** (`src/jobs.zig`) — the Anthropic or OpenAI request and voice transcription
   run as Gooey background jobs. Both clients share the retry/backoff policy in
   `src/http/http.zig`.

### Async result flow

`sendMessage` copies the conversation into `jobs.exchange`, an app-owned buffer, and
starts a `ChatJob` with `effects.spawn`. The job runs on a worker Gooey owns and never
touches `AppState`; each streamed piece it posts arrives at `AppState.onChatResult` on
the main thread in the next drain, and each post wakes the event loop, so nothing polls.
The Stop button calls `effects.cancelJob`, and at quit Gooey cancels and joins every job
before `on_deinit`. When no job runs the app requests no frames and sits idle.

### Resource budget

Gooey reserves every pool at startup from one `gooey.ResourceLimits` value and
panics, naming the field, if a frame needs more. ChatZig uses `.small` unchanged
(`src/limits.zig`). The transcript is a `List` whose rows measure their text with
`cx.measureText`, so it builds only the messages in view, and Gooey draws only the
glyphs a scroll box shows: a frame's cost follows the window, not the conversation.
The list is anchored at its end, so a streamed reply stays in view while you are at
the bottom; scrolling up releases it, and sending a message jumps back down.

### Compaction and session persistence

Long conversations are summarized rather than truncated: `AppState.messages`
is never mutated, and a small summary + cut index is layered on top only
when assembling the next request. On Claude models that support it, the
summary is Anthropic's native on-demand compaction block (signed, sent back
verbatim, and kept in the session log); other models, or a failed
compaction call, fall back to a client-side summary. See
[`docs/CHAT_COMPACTION.md`](docs/CHAT_COMPACTION.md) for the full design,
including how the cut is computed across ring-buffer overflow and how
sessions are framed and restored from `sessions/*.jsonl`.

## License

MIT
