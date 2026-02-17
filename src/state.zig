//! Application State Management for ChatZig
//!
//! Handles:
//! - Message history
//! - Input text binding
//! - File attachments via native file dialog
//! - Async API communication (TigersEye pattern: pending fields + dispatch)
//! - Thread dispatch for UI updates

const std = @import("std");
const log = std.log.scoped(.chatzig);
const gooey = @import("gooey");
const file_dialog = gooey.file_dialog;

const http = @import("http.zig");
const canvas_state = @import("canvas_state.zig");
const canvas_tools = @import("canvas_tools.zig");
const VirtualListState = gooey.VirtualListState;

// =============================================================================
// Constants (per CLAUDE.md: "Put a limit on everything")
// =============================================================================

pub const MAX_MESSAGES: usize = 256;
pub const MAX_MESSAGE_LEN: usize = 32768;
pub const MAX_INPUT_LEN: usize = 4096;
pub const DEFAULT_MESSAGE_HEIGHT: f32 = 60.0;
pub const MAX_RESPONSE_LEN: usize = 32768;
pub const MAX_FILE_PATH_LEN: usize = 512;
pub const MAX_ATTACHED_FILENAME_LEN: usize = 128;

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
    /// Optional attached file name (just the filename, not full path)
    attached_file: [MAX_ATTACHED_FILENAME_LEN]u8 = undefined,
    attached_file_len: usize = 0,
    cached_height: f32 = 0.0,

    pub fn getText(self: *const Message) []const u8 {
        return self.content[0..self.content_len];
    }

    pub fn hasAttachment(self: *const Message) bool {
        return self.attached_file_len > 0;
    }

    pub fn getAttachedFileName(self: *const Message) []const u8 {
        return self.attached_file[0..self.attached_file_len];
    }

    pub fn user(text: []const u8) Message {
        var msg = Message{ .role = .user };
        const len = @min(text.len, MAX_MESSAGE_LEN);
        @memcpy(msg.content[0..len], text[0..len]);
        msg.content_len = len;
        msg.cached_height = 0.0;
        return msg;
    }

    pub fn userWithFile(text: []const u8, filename: []const u8) Message {
        var msg = Message{ .role = .user };
        const len = @min(text.len, MAX_MESSAGE_LEN);
        @memcpy(msg.content[0..len], text[0..len]);
        msg.content_len = len;
        const fname_len = @min(filename.len, MAX_ATTACHED_FILENAME_LEN);
        @memcpy(msg.attached_file[0..fname_len], filename[0..fname_len]);
        msg.attached_file_len = fname_len;
        msg.cached_height = 0.0;
        return msg;
    }

    pub fn assistant(text: []const u8) Message {
        var msg = Message{ .role = .assistant };
        const len = @min(text.len, MAX_MESSAGE_LEN);
        @memcpy(msg.content[0..len], text[0..len]);
        msg.content_len = len;
        msg.cached_height = 0.0;
        return msg;
    }
};

// =============================================================================
// API Result (from HTTP thread, TigersEye pattern)
// =============================================================================

pub const ApiResult = union(enum) {
    success: SuccessResult,
    err: ErrorResult,

    pub const SuccessResult = struct {
        response_len: usize,
    };

    pub const ErrorResult = struct {
        message: []const u8,
    };
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
    message_head: usize = 0,
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
    // Canvas State
    // =========================================================================
    canvas_enabled: bool = false,

    // =========================================================================
    // Model Selection State
    // =========================================================================
    selected_model: Model = .haiku,

    // =========================================================================
    // File Attachment State
    // =========================================================================
    attached_file_path: [MAX_FILE_PATH_LEN]u8 = undefined,
    attached_file_path_len: usize = 0,
    has_attached_file: bool = false,

    // =========================================================================
    // HTTP Client (pure, no framework deps)
    // =========================================================================
    http_client: ?http.AnthropicClient = null,

    // =========================================================================
    // Pending API Result (TigersEye pattern: staging area from IO thread)
    // =========================================================================
    pending_result: ?ApiResult = null,
    pending_response_buf: [MAX_RESPONSE_LEN]u8 = undefined,
    pending_response_len: usize = 0,

    // Pending file path for worker thread
    pending_file_path: [MAX_FILE_PATH_LEN]u8 = undefined,
    pending_file_path_len: usize = 0,

    // =========================================================================
    // Pending Canvas Result (staging area from IO thread)
    // =========================================================================
    pending_canvas_lines: [canvas_state.MAX_CANVAS_BUF]u8 = undefined,
    pending_canvas_lines_len: usize = 0,
    pending_canvas_text: [MAX_RESPONSE_LEN]u8 = undefined,
    pending_canvas_text_len: usize = 0,
    pending_canvas_result: ?http.CanvasResult = null,

    // =========================================================================
    // Threading
    // =========================================================================
    gooey_ptr: ?*gooey.Gooey = null,

    // =========================================================================
    // Initialization
    // =========================================================================

    pub fn init(cx: *gooey.Cx) void {
        const self = cx.state(Self);
        const g = cx.gooey();
        self.gooey_ptr = g;

        // Set initial window appearance based on dark_mode state
        g.setAppearance(self.dark_mode);

        // Check for API key
        const api_key = std.posix.getenv("ANTHROPIC_API_KEY");
        self.has_api_key = api_key != null and api_key.?.len > 0;

        if (self.has_api_key) {
            self.http_client = http.AnthropicClient.init(api_key.?, std.heap.page_allocator);
            log.info("Anthropic API key found", .{});
        } else {
            log.warn("ANTHROPIC_API_KEY not set", .{});
        }
    }

    // =========================================================================
    // Message Management
    // =========================================================================

    pub fn addMessage(self: *Self, msg: Message) void {
        std.debug.assert(self.message_count <= MAX_MESSAGES);
        std.debug.assert(self.message_head < MAX_MESSAGES);

        if (self.message_count < MAX_MESSAGES) {
            const insert_index = (self.message_head + self.message_count) % MAX_MESSAGES;
            self.messages[insert_index] = msg;
            self.message_count += 1;
        } else {
            const overwrite_index = self.message_head;
            self.messages[overwrite_index] = msg;
            self.message_head = (self.message_head + 1) % MAX_MESSAGES;
            self.message_count = MAX_MESSAGES;
        }

        // Update list state
        self.list_state.setItemCount(@intCast(self.message_count));

        // Scroll to bottom
        self.list_state.scrollToBottom();
    }

    pub fn getMessage(self: *const Self, index: usize) ?*const Message {
        std.debug.assert(self.message_count <= MAX_MESSAGES);
        std.debug.assert(self.message_head < MAX_MESSAGES);
        if (index >= self.message_count) return null;
        const physical_index = (self.message_head + index) % MAX_MESSAGES;
        return &self.messages[physical_index];
    }

    pub fn getMessageCachedHeight(self: *const Self, index: usize) f32 {
        std.debug.assert(self.message_count <= MAX_MESSAGES);
        if (index >= self.message_count) return 0.0;
        const physical_index = (self.message_head + index) % MAX_MESSAGES;
        return self.messages[physical_index].cached_height;
    }

    pub fn setMessageCachedHeight(self: *Self, index: usize, height: f32) void {
        std.debug.assert(self.message_count <= MAX_MESSAGES);
        std.debug.assert(index < self.message_count);
        std.debug.assert(height >= 0.0);
        const physical_index = (self.message_head + index) % MAX_MESSAGES;
        self.messages[physical_index].cached_height = height;
    }

    pub fn invalidateCachedHeights(self: *Self) void {
        std.debug.assert(self.message_count <= MAX_MESSAGES);
        std.debug.assert(self.message_head < MAX_MESSAGES);
        for (0..self.message_count) |i| {
            const physical_index = (self.message_head + i) % MAX_MESSAGES;
            self.messages[physical_index].cached_height = 0.0;
        }
    }

    pub fn clearMessages(self: *Self) void {
        std.debug.assert(self.message_count <= MAX_MESSAGES);
        self.message_head = 0;
        self.message_count = 0;
        self.list_state.setItemCount(0);
        self.list_state.scrollToTop();
    }

    // =========================================================================
    // Build Chat Request from State
    // =========================================================================

    const ChatMessagesBuffer = struct {
        messages: [MAX_MESSAGES]http.ChatMessage = undefined,
        count: usize = 0,
    };

    fn buildChatRequest(self: *const Self, buf: *ChatMessagesBuffer) http.ChatRequest {
        buf.count = 0;

        for (0..self.message_count) |i| {
            const msg = self.getMessage(i) orelse unreachable;
            if (msg.role == .system) continue;

            buf.messages[buf.count] = .{
                .role = if (msg.role == .user) .user else .assistant,
                .content = msg.getText(),
            };
            buf.count += 1;
        }

        return .{
            .model = self.selected_model.apiName(),
            .messages = buf.messages[0..buf.count],
        };
    }

    // =========================================================================
    // Send Message (command handler - takes *gooey.Gooey)
    // =========================================================================

    pub fn sendMessage(self: *Self, g: *gooey.Gooey) void {
        self.gooey_ptr = g;

        // Get input text
        if (self.input_slice.len == 0) return;

        // Don't send if already loading
        if (self.is_loading) return;

        // Capture attached file path before clearing (copy to pending buffer)
        var attached_path_len: usize = 0;
        if (self.has_attached_file) {
            attached_path_len = self.attached_file_path_len;
            @memcpy(self.pending_file_path[0..attached_path_len], self.attached_file_path[0..attached_path_len]);
        }

        // Add user message (with optional file attachment)
        if (self.has_attached_file) {
            self.addMessage(Message.userWithFile(self.input_slice, self.getAttachedFileName()));
        } else {
            self.addMessage(Message.user(self.input_slice));
        }

        // Store attached file path for worker thread
        self.pending_file_path_len = attached_path_len;

        // Clear input and attachment
        self.input_slice = "";
        if (g.textArea("chat-input")) |ta| {
            ta.clear();
        }
        self.has_attached_file = false;
        self.attached_file_path_len = 0;

        // Set loading state
        self.is_loading = true;
        self.error_message = null;

        // Check for client
        if (self.http_client == null) {
            self.error_message = "No API key configured";
            self.is_loading = false;
            g.requestRender();
            return;
        }

        // Spawn worker thread — canvas or normal path
        if (self.canvas_enabled) {
            const thread = std.Thread.spawn(.{}, canvasWorker, .{
                &self.http_client.?,
                self,
            }) catch |err| {
                log.err("Failed to spawn canvas thread: {}", .{err});
                self.error_message = "Failed to send message";
                self.is_loading = false;
                g.requestRender();
                return;
            };
            thread.detach();
        } else {
            const thread = std.Thread.spawn(.{}, httpWorker, .{
                &self.http_client.?,
                self,
            }) catch |err| {
                log.err("Failed to spawn HTTP thread: {}", .{err});
                self.error_message = "Failed to send message";
                self.is_loading = false;
                g.requestRender();
                return;
            };
            thread.detach();
        }

        g.requestRender();
    }

    // =========================================================================
    // HTTP Worker Thread (TigersEye pattern)
    // =========================================================================

    fn httpWorker(client: *http.AnthropicClient, app: *Self) void {
        // Build request from current state
        // Note: This reads app state from worker thread, but message_count and
        // messages are only written from main thread before spawning this worker
        var buf: ChatMessagesBuffer = .{};
        const request = app.buildChatRequest(&buf);

        // Execute blocking HTTP request (with or without file attachment)
        var result: http.ChatResult = undefined;
        if (app.pending_file_path_len > 0) {
            const file_path = app.pending_file_path[0..app.pending_file_path_len];
            log.info("Sending message with file attachment: {s}", .{file_path});
            result = client.sendWithFile(request, file_path);
        } else {
            result = client.sendBlocking(request);
        }
        defer result.deinit(client.allocator);

        // Copy result to pending staging area
        switch (result.status) {
            .success => |text| {
                const len = @min(text.len, MAX_RESPONSE_LEN);
                @memcpy(app.pending_response_buf[0..len], text[0..len]);
                app.pending_response_len = len;
                app.pending_result = .{ .success = .{ .response_len = len } };
            },
            .err => |msg| {
                app.pending_result = .{ .err = .{ .message = msg } };
            },
        }

        // Dispatch to main thread
        app.dispatchToMain();
    }

    // =========================================================================
    // Canvas Worker Thread (tool-use path)
    // =========================================================================

    fn canvasWorker(client: *http.AnthropicClient, app: *Self) void {
        var buf: ChatMessagesBuffer = .{};
        var request = app.buildChatRequest(&buf);

        // Attach canvas system prompt and tools to the request.
        request.system = canvas_tools.canvas_system_prompt;
        request.tools_json = canvas_tools.anthropic_tools_json;

        log.info("Sending canvas request with {d} tools", .{canvas_tools.TOOL_COUNT});

        const result = client.sendForCanvas(
            request,
            &app.pending_canvas_lines,
            &app.pending_canvas_text,
        );

        if (result.has_error) {
            app.pending_result = .{ .err = .{ .message = result.error_message } };
            app.pending_canvas_result = null;
        } else {
            app.pending_canvas_lines_len = result.canvas_lines_len;
            app.pending_canvas_text_len = result.text_len;
            app.pending_canvas_result = result;
            app.pending_result = null; // Canvas path uses its own result
        }

        app.dispatchToMain();
    }

    // =========================================================================
    // Thread Dispatch (TigersEye pattern)
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

        // Apply pending canvas result if present (canvas path)
        if (s.pending_canvas_result) |cr| {
            s.applyCanvasResult(cr);
            s.pending_canvas_result = null;
        }

        // Apply pending result if present (normal path)
        if (s.pending_result) |result| {
            s.applyResult(result);
            s.pending_result = null;
        }

        g.requestRender();
    }

    // =========================================================================
    // Apply Result (TigersEye pattern - main thread only)
    // =========================================================================

    fn applyResult(self: *Self, result: ApiResult) void {
        switch (result) {
            .success => |r| {
                // Add assistant message from staging buffer
                const response = self.pending_response_buf[0..r.response_len];
                self.addMessage(Message.assistant(response));
                self.error_message = null;
            },
            .err => |e| {
                self.error_message = e.message;
            },
        }

        self.is_loading = false;
    }

    // =========================================================================
    // Apply Canvas Result (main thread only)
    // =========================================================================

    fn applyCanvasResult(self: *Self, result: http.CanvasResult) void {
        if (result.has_error) {
            self.error_message = result.error_message;
            self.is_loading = false;
            return;
        }

        // Clear canvas for fresh batch, then process command lines.
        canvas_state.clearCanvas();
        if (result.canvas_lines_len > 0) {
            const lines = self.pending_canvas_lines[0..result.canvas_lines_len];
            const count = canvas_state.processBatch(lines);
            log.info("Canvas: applied {d} draw commands", .{count});
        }

        // Show any text response from the LLM in the chat.
        if (result.text_len > 0) {
            const text = self.pending_canvas_text[0..result.text_len];
            self.addMessage(Message.assistant(text));
        } else if (result.canvas_lines_len > 0) {
            // If only tool calls, add a minimal confirmation message.
            self.addMessage(Message.assistant("(drew on canvas)"));
        }

        self.error_message = null;
        self.is_loading = false;
    }

    // =========================================================================
    // Theme Toggle
    // =========================================================================

    pub fn toggleDarkMode(self: *Self, g: *gooey.Gooey) void {
        self.dark_mode = !self.dark_mode;
        g.setAppearance(self.dark_mode);
        g.requestRender();
    }

    // =========================================================================
    // Canvas Toggle
    // =========================================================================

    pub fn toggleCanvas(self: *Self, _: *gooey.Gooey) void {
        self.canvas_enabled = !self.canvas_enabled;
    }

    // =========================================================================
    // Model Selection Handlers
    // =========================================================================

    pub fn selectModel(self: *Self, index: usize) void {
        self.selected_model = @enumFromInt(index);
    }

    // =========================================================================
    // File Attachment Handlers
    // =========================================================================

    pub fn openFileDialog(self: *Self, g: *gooey.Gooey) void {
        _ = self;
        // Defer to avoid deadlock - file dialog blocks and processes events
        // which can trigger input handlers while render mutex is held
        g.deferCommand(Self.openFileDialogDeferred);
    }

    fn openFileDialogDeferred(self: *Self, g: *gooey.Gooey) void {
        _ = g;

        if (file_dialog.promptForPaths(std.heap.page_allocator, .{
            .files = true,
            .directories = false,
            .multiple = false,
            .prompt = "Attach",
            .message = "Select a file to attach",
            // Supported file types: images (base64), text files (inline), and PDFs (via Files API)
            .allowed_extensions = &.{ "txt", "md", "json", "csv", "png", "jpg", "jpeg", "gif", "webp", "pdf" },
        })) |result| {
            defer result.deinit();
            if (result.paths.len > 0) {
                const path = result.paths[0];
                const len = @min(path.len, MAX_FILE_PATH_LEN);
                @memcpy(self.attached_file_path[0..len], path[0..len]);
                self.attached_file_path_len = len;
                self.has_attached_file = true;
                log.info("File attached: {s}", .{self.getAttachedFilePath()});
            }
        } else {
            log.debug("File dialog cancelled", .{});
        }
    }

    pub fn clearAttachedFile(self: *Self, _: *gooey.Gooey) void {
        self.has_attached_file = false;
        self.attached_file_path_len = 0;
    }

    pub fn getAttachedFilePath(self: *const Self) []const u8 {
        return self.attached_file_path[0..self.attached_file_path_len];
    }

    pub fn getAttachedFileName(self: *const Self) []const u8 {
        const path = self.getAttachedFilePath();
        // Find the last '/' to extract just the filename
        var last_slash: usize = 0;
        for (path, 0..) |c, i| {
            if (c == '/') last_slash = i + 1;
        }
        return path[last_slash..];
    }
};
