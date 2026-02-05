//! Application State Management for ChatZig
//!
//! Handles:
//! - Message history
//! - Input text binding
//! - API communication with Anthropic
//! - Thread dispatch for UI updates

const std = @import("std");
const log = std.log.scoped(.chatzig);
const gooey = @import("gooey");

const http = @import("http.zig");
const VirtualListState = gooey.VirtualListState;

// =============================================================================
// Constants (per CLAUDE.md: "Put a limit on everything")
// =============================================================================

pub const MAX_MESSAGES: usize = 256;
pub const MAX_MESSAGE_LEN: usize = 32768;
pub const MAX_INPUT_LEN: usize = 4096;
pub const DEFAULT_MESSAGE_HEIGHT: f32 = 60.0;

// =============================================================================
// Model Selection
// =============================================================================

pub const Model = enum(u8) {
    haiku,
    sonnet,
    opus,

    pub const display_names = [_][]const u8{
        "Claude 4.5 Haiku",
        "Claude 4.5 Sonnet",
        "Claude 4.5 Opus",
    };

    pub const api_names = [_][]const u8{
        "claude-haiku-4-5-20251001",
        "claude-sonnet-4-5-20250929",
        "claude-opus-4-5-20251101",
    };

    pub fn displayName(self: Model) []const u8 {
        return display_names[@intFromEnum(self)];
    }

    pub fn apiName(self: Model) []const u8 {
        return api_names[@intFromEnum(self)];
    }
};

pub const MODEL_COUNT: usize = 3;

// =============================================================================
// Message Types
// =============================================================================

pub const MessageRole = enum {
    user,
    assistant,
    system,
};

pub const Message = struct {
    role: MessageRole,
    content: [MAX_MESSAGE_LEN]u8 = undefined,
    content_len: usize = 0,

    pub fn getText(self: *const Message) []const u8 {
        return self.content[0..self.content_len];
    }

    pub fn user(text: []const u8) Message {
        var msg = Message{ .role = .user };
        const len = @min(text.len, MAX_MESSAGE_LEN);
        @memcpy(msg.content[0..len], text[0..len]);
        msg.content_len = len;
        return msg;
    }

    pub fn assistant(text: []const u8) Message {
        var msg = Message{ .role = .assistant };
        const len = @min(text.len, MAX_MESSAGE_LEN);
        @memcpy(msg.content[0..len], text[0..len]);
        msg.content_len = len;
        return msg;
    }
};

// =============================================================================
// AppState
// =============================================================================

pub const AppState = struct {
    const Self = @This();

    // =========================================================================
    // Message History
    // =========================================================================
    messages: [MAX_MESSAGES]Message = undefined,
    message_count: usize = 0,

    // =========================================================================
    // Input State
    // =========================================================================
    input_text: [MAX_INPUT_LEN]u8 = undefined,
    input_slice: []const u8 = "",

    // =========================================================================
    // UI State
    // =========================================================================
    list_state: VirtualListState = VirtualListState.initWithGap(0, DEFAULT_MESSAGE_HEIGHT, 8),
    is_loading: bool = false,
    has_api_key: bool = false,
    error_message: ?[]const u8 = null,
    dark_mode: bool = true, // Start in dark mode like the reference image

    // =========================================================================
    // Model Selection State
    // =========================================================================
    selected_model: Model = .haiku,
    model_select_open: bool = false,

    // =========================================================================
    // HTTP Client
    // =========================================================================
    http_client: ?http.AnthropicClient = null,

    // =========================================================================
    // Threading
    // =========================================================================
    gooey_ptr: ?*gooey.Gooey = null,

    // =========================================================================
    // Initialization
    // =========================================================================

    pub fn init(self: *Self, g: *gooey.Gooey) void {
        self.gooey_ptr = g;

        // Check for API key
        const api_key = std.posix.getenv("ANTHROPIC_API_KEY");
        self.has_api_key = api_key != null and api_key.?.len > 0;

        if (self.has_api_key) {
            self.http_client = http.AnthropicClient.init(api_key.?);
            log.info("Anthropic API key found", .{});
        } else {
            log.warn("ANTHROPIC_API_KEY not set", .{});
        }
    }

    // =========================================================================
    // Message Management
    // =========================================================================

    pub fn addMessage(self: *Self, msg: Message) void {
        if (self.message_count >= MAX_MESSAGES) {
            // Shift messages to make room
            for (0..MAX_MESSAGES - 1) |i| {
                self.messages[i] = self.messages[i + 1];
            }
            self.message_count = MAX_MESSAGES - 1;
        }

        self.messages[self.message_count] = msg;
        self.message_count += 1;

        // Update list state
        self.list_state.setItemCount(@intCast(self.message_count));

        // Scroll to bottom
        self.list_state.scrollToBottom();
    }

    pub fn getMessage(self: *const Self, index: usize) ?*const Message {
        if (index >= self.message_count) return null;
        return &self.messages[index];
    }

    pub fn clearMessages(self: *Self) void {
        self.message_count = 0;
        self.list_state.setItemCount(0);
        self.list_state.scrollToTop();
    }

    // =========================================================================
    // Send Message (command handler - takes *gooey.Gooey)
    // =========================================================================

    pub fn sendMessage(self: *Self, g: *gooey.Gooey) void {
        self.gooey_ptr = g;

        // Get input text
        if (self.input_slice.len == 0) return;

        // Add user message
        self.addMessage(Message.user(self.input_slice));

        // Clear input
        self.input_slice = "";
        if (g.textArea("chat-input")) |ta| {
            ta.clear();
        }

        // Set loading state
        self.is_loading = true;
        self.error_message = null;

        // Send to API
        if (self.http_client) |*client| {
            client.sendMessage(self) catch |err| {
                log.err("Failed to send message: {}", .{err});
                self.error_message = "Failed to send message";
                self.is_loading = false;
            };
        } else {
            self.error_message = "No API key configured";
            self.is_loading = false;
        }

        g.requestRender();
    }

    // =========================================================================
    // Theme Toggle
    // =========================================================================

    pub fn toggleDarkMode(self: *Self, g: *gooey.Gooey) void {
        self.dark_mode = !self.dark_mode;
        g.requestRender();
    }

    // =========================================================================
    // Model Selection Handlers
    // =========================================================================

    pub fn toggleModelSelect(self: *Self, _: *gooey.Gooey) void {
        self.model_select_open = !self.model_select_open;
    }

    pub fn closeModelSelect(self: *Self, _: *gooey.Gooey) void {
        self.model_select_open = false;
    }

    pub fn selectModel(self: *Self, index: usize) void {
        self.selected_model = @enumFromInt(index);
        self.model_select_open = false;
    }

    // =========================================================================
    // Thread Dispatch
    // =========================================================================

    const DispatchCtx = struct { app: *Self };

    pub fn dispatchToMain(self: *Self) void {
        const g = self.gooey_ptr orelse {
            log.warn("dispatchToMain: no Gooey pointer", .{});
            return;
        };

        g.dispatchOnMainThread(
            DispatchCtx,
            .{ .app = self },
            dispatchHandler,
        ) catch {
            log.warn("dispatchToMain: dispatch failed", .{});
        };
    }

    fn dispatchHandler(ctx: *DispatchCtx) void {
        const s = ctx.app;
        const g = s.gooey_ptr orelse return;
        g.requestRender();
    }

    // =========================================================================
    // API Response Handling
    // =========================================================================

    pub fn onApiResponse(self: *Self, response: []const u8) void {
        self.addMessage(Message.assistant(response));
        self.is_loading = false;
        self.dispatchToMain();
    }

    pub fn onApiError(self: *Self, err_msg: []const u8) void {
        self.error_message = err_msg;
        self.is_loading = false;
        self.dispatchToMain();
    }
};
