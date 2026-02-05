# ChatZig

A simple AI chat application built with [Gooey](https://github.com/duanebester/gooey) that connects to Anthropic's Claude API.

Inspired by [chat-ai](https://github.com/duanebester/chat-ai) (GPUI/Rust version).

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
- 🔄 Async HTTP requests (non-blocking UI)
- ⌨️ Simple text input with send button

## Prerequisites

1. **Zig 0.15.2+** - Install from [ziglang.org](https://ziglang.org/download/)
2. **Anthropic API Key** - Get one from [Anthropic Console](https://console.anthropic.com/)

## Setup

```bash
# Clone
git clone https://github.com/yourusername/chat-zig
cd chat-zig

# Set your API key
export ANTHROPIC_API_KEY="your-key-here"

# Build and run
zig build run
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

This follows the Gooey pattern for stateful apps:

1. **AppState** - Single source of truth for app data
2. **Layout functions** - Render UI based on current state
3. **Command handlers** - Update state in response to user actions
4. **Async dispatch** - Thread-safe UI updates from HTTP callbacks

```zig
// State mutation via command handlers
pub fn sendMessage(self: *Self, g: *gooey.Gooey) void {
    // Add user message
    self.addMessage(Message.user(self.input_slice));

    // Make async API call
    self.http_client.?.sendMessage(self);

    g.requestRender();
}

// Callback dispatches to main thread
pub fn onApiResponse(self: *Self, response: []const u8) void {
    self.addMessage(Message.assistant(response));
    self.dispatchToMain(); // Triggers UI re-render
}
```

## License

MIT
