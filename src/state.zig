//! Application State Management for ChatZig
//!
//! Handles:
//! - Message history
//! - Input text binding
//! - File attachments via native file dialog
//! - Async API communication via `std.Io.Group` + `Io.Queue` (Zig 0.16)
//! - Result delivery: the render loop drains the queue each frame
//!
//! Zig 0.16 migration notes:
//!   - Replaced `std.Thread.spawn` + `dispatchOnMainThread` with
//!     `Io.Group.async` + `Io.Queue(WorkerResult)`. Workers push typed
//!     results into the queue; the render loop drains them without blocking.
//!     This eliminates the per-request heap allocations (Task, Context) and
//!     the two-hop trampoline (bg → dispatch → main) in favour of one
//!     bounded channel.
//!   - Filesystem reads, HTTP, TLS, and env lookups all thread through the
//!     single `std.Io` instance published by `main` (via `std.process.Init`).
//!   - `io_group` is registered with Gooey so that window close cancels any
//!     in-flight HTTP work cleanly — no use-after-free on shutdown.

const std = @import("std");
const log = std.log.scoped(.chatzig);
const gooey = @import("gooey");
const file_dialog = gooey.file_dialog;

const http = @import("http.zig");
const VirtualListState = gooey.VirtualListState;

// Reach back into `main` for the process-global Io + environ published from
// `std.process.Init`. `AppState.init` needs both but only receives a `*Cx`,
// so rather than thread them through every call we publish them on main.
const main_mod = @import("main.zig");

// =============================================================================
// Constants (CLAUDE rule #4: put a limit on everything)
// =============================================================================

pub const MAX_MESSAGES: usize = 256;
pub const MAX_MESSAGE_LEN: usize = 32768;
pub const MAX_INPUT_LEN: usize = 4096;
pub const DEFAULT_MESSAGE_HEIGHT: f32 = 60.0;
pub const MAX_RESPONSE_LEN: usize = 32768;
pub const MAX_FILE_PATH_LEN: usize = 512;
pub const MAX_ATTACHED_FILENAME_LEN: usize = 128;

/// Max worker results buffered between render frames. With `is_loading`
/// guarding single-flight requests, only one result is ever in flight at a
/// time; 8 is generous headroom for future parallelism (e.g. background
/// thumbnail fetch) and keeps the backing array small
/// (`8 * @sizeOf(WorkerResult)`).
pub const RESULT_QUEUE_CAPACITY: usize = 8;

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
    /// Optional attached file name (just the filename, not full path).
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
// Worker Result (delivered via std.Io.Queue from async tasks)
// =============================================================================

pub const SuccessResult = struct {
    response_len: usize,
};

pub const ErrorResult = struct {
    /// Static lifetime — either a compile-time string or a pointer into a
    /// long-lived owned buffer on `http.ChatResult`. The queue never copies
    /// the bytes; it only carries the slice header.
    message: []const u8,
};

/// Incremental delta delivered while a streaming request is in flight.
///
/// The worker fiber appends bytes to `pending_response_buf` and bumps
/// `pending_response_len`, then publishes the new high-water mark via this
/// result. The render thread copies `pending_response_buf[0..cumulative_len]`
/// into the streaming assistant message.
///
/// Why a high-water mark instead of just the new chunk? Two reasons:
///   1. Idempotent — if the queue ever delivered the same delta twice (it
///      shouldn't, but invariants are cheaper than debugging), applying the
///      same `cumulative_len` twice is a no-op rather than a duplicate
///      paste.
///   2. Self-synchronizing — the render thread always knows the exact slice
///      to read, with no need to track a separate "applied so far" counter.
pub const DeltaResult = struct {
    /// New total length of `pending_response_buf` after this delta. Always
    /// strictly greater than the previous delta's `cumulative_len` (the
    /// worker only appends, never rewinds), and always `<= MAX_RESPONSE_LEN`.
    cumulative_len: u32,
};

/// Tagged union over every kind of worker outcome so a single `Io.Queue` can
/// carry chat results. The render loop switches on the tag and applies the
/// matching staging buffer.
///
/// Keep this small: it is copied into the queue's ring buffer by value.
///
/// Streaming flow: `chat_delta` may fire many times before exactly one of
/// `chat_success` / `chat_error` terminates the stream. Non-streaming
/// flow: `chat_delta` never fires.
pub const WorkerResult = union(enum) {
    chat_delta: DeltaResult,
    chat_success: SuccessResult,
    chat_error: ErrorResult,
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
    dark_mode: bool = true, // Start in dark mode like the reference image.

    selected_model: Model = .haiku,

    // =========================================================================
    // File Attachment State
    // =========================================================================
    attached_file_path: [MAX_FILE_PATH_LEN]u8 = undefined,
    attached_file_path_len: usize = 0,
    has_attached_file: bool = false,

    // =========================================================================
    // HTTP Client (borrows `std.Io` from main)
    // =========================================================================
    http_client: ?http.AnthropicClient = null,

    // =========================================================================
    // Staging Buffers (written by worker, read by render after queue drain)
    // =========================================================================
    //
    // Threading invariant: these buffers are written ONLY by a worker fiber,
    // and ONLY before it calls `queue.putOne`. They are read ONLY by the
    // render thread, and ONLY after `cx.drainQueue` returns the matching
    // `WorkerResult`. The queue's internal synchronization provides the
    // happens-before edge that makes the writes visible.
    //
    // This is the same discipline as the pre-0.16 "TigersEye" pattern, but
    // without the dispatcher trampoline — the queue IS the synchronization.
    //
    // Streaming refinement: `pending_response_buf` is *append-only* during
    // a streaming request. The worker writes bytes at offsets
    // `[old_len, new_len)` and publishes `new_len` via a `chat_delta`. The
    // render thread only ever reads `[0, last_delivered_len)`. Because
    // those ranges are disjoint and each `putOne` is a happens-before edge
    // for the bytes it announces, no atomics or mutex are required.

    pending_response_buf: [MAX_RESPONSE_LEN]u8 = undefined,
    pending_response_len: usize = 0,

    pending_file_path: [MAX_FILE_PATH_LEN]u8 = undefined,
    pending_file_path_len: usize = 0,

    /// Ring-buffer index of the placeholder assistant `Message` we are
    /// currently streaming into, or `null` if no stream is in flight.
    ///
    /// Set by `applyChatDelta` on the first delta (which appends an empty
    /// `Message.assistant("")`), cleared by `applyChatSuccess` /
    /// `applyChatError` when the stream terminates. The index is into the
    /// public `getMessage(i)` space (0..message_count) — the same one the
    /// virtual list iterates — *not* the underlying `messages[]` slot.
    ///
    /// Invariants:
    ///   * If `streaming_message_idx == null`, `is_loading` may still be
    ///     true (request sent, no deltas yet).
    ///   * If `streaming_message_idx == i`, `getMessage(i).?.role` is
    ///     `.assistant` and `is_loading` is true.
    streaming_message_idx: ?u32 = null,

    // =========================================================================
    // Async Result Plumbing — Zig 0.16 std.Io
    // =========================================================================
    //
    // `io_group` tracks every background fiber launched by `sendMessage`. It
    // is registered with Gooey on init, so window close cancels all in-flight
    // work before AppState is torn down — no dangling pointers from a worker
    // into freed state.
    //
    // `result_queue` carries `WorkerResult` values from worker → render. The
    // backing storage lives inline on AppState (`RESULT_QUEUE_CAPACITY`
    // slots); the queue object holds a pointer into it, so AppState must not
    // be moved after `init` runs.

    io_group: std.Io.Group = .init,
    result_buffer: [RESULT_QUEUE_CAPACITY]WorkerResult = undefined,
    result_queue: std.Io.Queue(WorkerResult) = undefined,

    // =========================================================================
    // Framework handles
    // =========================================================================
    //
    // `gooey_ptr` is retained (despite the dispatcher going away) so workers
    // can nudge the event loop via `g.requestRender()` — that call is
    // threadsafe by contract and does not touch any shared state, it just
    // wakes the run loop so the next frame drains the queue.
    gooey_ptr: ?*gooey.Gooey = null,

    // =========================================================================
    // Initialization
    // =========================================================================

    pub fn init(cx: *gooey.Cx) void {
        const self = cx.state(Self);
        const g = cx.gooey();
        self.gooey_ptr = g;

        // Set initial window appearance from the persisted dark_mode flag.
        g.setAppearance(self.dark_mode);

        // Wire up the async plumbing. The queue is built in place; its
        // backing buffer already lives at its final address on AppState (we
        // are past the stack→heap move because `init` is called on the
        // mounted, committed state pointer).
        self.result_queue = std.Io.Queue(WorkerResult).init(&self.result_buffer);
        cx.registerCancelGroup(&self.io_group);

        // Look up the API key through the environ published by `main`. On
        // macOS this replaces libc's `getenv`, which `std.posix` no longer
        // wraps in 0.16.
        const api_key = main_mod.process_env.getPosix("ANTHROPIC_API_KEY");
        self.has_api_key = api_key != null and api_key.?.len > 0;

        if (self.has_api_key) {
            // AnthropicClient holds `std.Io` so it can spin up `http.Client`
            // per request. `page_allocator` is threadsafe and thus safe to
            // hand to a fiber that runs on a worker thread.
            self.http_client = http.AnthropicClient.init(
                api_key.?,
                std.heap.page_allocator,
                main_mod.process_io,
            );
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
            self.messages[(self.message_head + self.message_count) % MAX_MESSAGES] = msg;
            self.message_count += 1;
        } else {
            // Ring-buffer overflow: overwrite the oldest message.
            self.messages[self.message_head] = msg;
            self.message_head = (self.message_head + 1) % MAX_MESSAGES;
        }

        // Freshly-added messages start with no cached height. Being explicit
        // here guards against a caller constructing `msg` with a stale value.
        const tail_idx = if (self.message_count == 0)
            self.message_head
        else
            (self.message_head + self.message_count - 1) % MAX_MESSAGES;
        self.messages[tail_idx].cached_height = 0.0;

        // Keep the virtual list in sync with the message ring, and scroll so
        // the freshly-added message is visible. These are UI-side mutations
        // that live on the same thread as the caller (main thread — callers
        // are either `sendMessage` or the render-loop drain).
        self.list_state.setItemCount(@intCast(self.message_count));
        self.list_state.scrollToBottom();
    }

    pub fn getMessage(self: *const Self, i: usize) ?*const Message {
        if (i >= self.message_count) return null;
        std.debug.assert(i < MAX_MESSAGES);
        const idx = (self.message_head + i) % MAX_MESSAGES;
        return &self.messages[idx];
    }

    pub fn getMessageCachedHeight(self: *const Self, i: usize) f32 {
        if (i >= self.message_count) return 0.0;
        std.debug.assert(i < MAX_MESSAGES);
        const idx = (self.message_head + i) % MAX_MESSAGES;
        return self.messages[idx].cached_height;
    }

    pub fn setMessageCachedHeight(self: *Self, i: usize, h: f32) void {
        if (i >= self.message_count) return;
        std.debug.assert(i < MAX_MESSAGES);
        const idx = (self.message_head + i) % MAX_MESSAGES;
        self.messages[idx].cached_height = h;
    }

    pub fn invalidateCachedHeights(self: *Self) void {
        var i: usize = 0;
        while (i < self.message_count) : (i += 1) {
            const idx = (self.message_head + i) % MAX_MESSAGES;
            self.messages[idx].cached_height = 0.0;
        }
    }

    pub fn clearMessages(self: *Self) void {
        self.message_count = 0;
        self.message_head = 0;
        self.error_message = null;
        self.is_loading = false;
        self.list_state.setItemCount(0);
        self.list_state.scrollToTop();
    }

    // =========================================================================
    // Chat Request Assembly
    // =========================================================================

    const ChatMessagesBuffer = struct {
        messages: [MAX_MESSAGES]http.ChatMessage = undefined,
        count: usize = 0,
    };

    fn buildChatRequest(self: *Self, buf: *ChatMessagesBuffer) http.ChatRequest {
        // Snapshot the ring buffer into a contiguous slice of ChatMessages.
        // Called from the worker fiber, but `is_loading` guards single-flight
        // so the main thread cannot mutate `messages` concurrently.
        buf.count = 0;
        var i: usize = 0;
        while (i < self.message_count and buf.count < MAX_MESSAGES) : (i += 1) {
            const msg = self.getMessage(i) orelse break;
            const role: http.ChatRole = switch (msg.role) {
                .user => .user,
                .assistant => .assistant,
                .system => continue, // Anthropic takes system via a separate field.
            };
            buf.messages[buf.count] = http.ChatMessage.text(role, msg.getText());
            buf.count += 1;
        }
        return .{
            .model = self.selected_model.apiName(),
            .messages = buf.messages[0..buf.count],
        };
    }

    // =========================================================================
    // Send Message — launches an async worker via Io.Group
    // =========================================================================

    pub fn sendMessage(self: *Self, g: *gooey.Gooey) void {
        self.gooey_ptr = g;

        if (self.input_slice.len == 0) return;
        // Single-flight: swallow a second click while the first request is
        // still outstanding. This is also what keeps the worker's snapshot
        // read of `messages` race-free (see `buildChatRequest`).
        if (self.is_loading) return;

        // Capture the attached file path before clearing, so the worker
        // fiber reads from a stable staging slot rather than the live input
        // slot (which the next user action could mutate).
        var attached_path_len: usize = 0;
        if (self.has_attached_file) {
            attached_path_len = self.attached_file_path_len;
            @memcpy(
                self.pending_file_path[0..attached_path_len],
                self.attached_file_path[0..attached_path_len],
            );
        }

        // Add the user's message to the visible history.
        if (self.has_attached_file) {
            self.addMessage(Message.userWithFile(self.input_slice, self.getAttachedFileName()));
        } else {
            self.addMessage(Message.user(self.input_slice));
        }

        self.pending_file_path_len = attached_path_len;

        // Clear input + attachment from the UI.
        self.input_slice = "";
        if (g.textArea("chat-input")) |ta| {
            ta.clear();
        }
        self.has_attached_file = false;
        self.attached_file_path_len = 0;

        self.is_loading = true;
        self.error_message = null;

        if (self.http_client == null) {
            self.error_message = "No API key configured";
            self.is_loading = false;
            g.requestRender();
            return;
        }

        // Launch the worker on the shared Io instance. The group owns the
        // task — cancellation on window close unwinds it cleanly. Worker
        // functions take only primitives + pointers, never a `self` style
        // receiver, so the Io runtime can cache arguments in registers
        // (CLAUDE rule 20 — "Hot Loop Extraction" applied to the fiber
        // entry point).
        const io = main_mod.process_io;
        self.io_group.async(io, httpWorker, .{
            io,
            &self.http_client.?,
            self,
            &self.result_queue,
        });

        g.requestRender();
    }

    // =========================================================================
    // Workers — run on an Io fiber, off the main thread
    // =========================================================================

    /// Bundle the worker fiber needs to forward each SSE delta to the
    /// render thread. Lives on the worker's stack — the sink callback only
    /// runs while `httpWorker` is on the stack, so the pointers are valid
    /// for the entire stream's lifetime by construction.
    const StreamCtx = struct {
        io: std.Io,
        app: *AppState,
        queue: *std.Io.Queue(WorkerResult),
    };

    /// SSE sink callback — runs on the worker fiber for each `text_delta`
    /// chunk. Appends to the staging buffer and pushes a `chat_delta`
    /// result. Returning `error.Aborted` short-circuits the SSE read loop;
    /// we do that once the staging buffer is full so the worker doesn't
    /// keep parsing bytes it has nowhere to put.
    fn onStreamDelta(userdata: *anyopaque, text: []const u8) http.StreamSink.Error!void {
        const ctx: *StreamCtx = @ptrCast(@alignCast(userdata));
        const app = ctx.app;

        // Append-only into the staging buffer. CLAUDE rule #4: bounded.
        const old_len = app.pending_response_len;
        std.debug.assert(old_len <= MAX_RESPONSE_LEN);
        const remaining = MAX_RESPONSE_LEN - old_len;

        // No room left — tell the SSE loop to stop reading. The
        // accumulated message stays as-is; the user sees a (truncated)
        // response, the stream tears down cleanly.
        if (remaining == 0) return error.Aborted;

        const to_copy = @min(text.len, remaining);
        @memcpy(
            app.pending_response_buf[old_len .. old_len + to_copy],
            text[0..to_copy],
        );
        const new_len = old_len + to_copy;
        app.pending_response_len = new_len;

        // Publish the new high-water mark. `putOne` is the happens-before
        // edge: the bytes we just wrote at `[old_len, new_len)` are visible
        // to the render thread only after it drains this result.
        //
        // The queue is bounded (RESULT_QUEUE_CAPACITY = 8) so `putOne`
        // blocks the worker if the render thread falls behind — natural
        // backpressure that keeps the staging buffer in sync with what the
        // UI has actually displayed.
        const cumulative_len: u32 = @intCast(new_len);
        ctx.queue.putOne(ctx.io, .{ .chat_delta = .{ .cumulative_len = cumulative_len } }) catch |e| {
            // Queue closed (window closing) — abort the stream so the
            // worker unwinds quickly. Truncation is the right behavior:
            // by the time the queue is closed, AppState is being torn
            // down anyway.
            log.debug("onStreamDelta: queue closed ({t}), aborting", .{e});
            return error.Aborted;
        };

        // Nudge the run loop. `requestRender` is threadsafe by contract.
        app.requestRenderFromWorker();
    }

    /// Chat worker: builds the request, opens an SSE stream against
    /// Anthropic's Messages API, forwards each `text_delta` to the render
    /// thread via `onStreamDelta`, and finally signals stream completion
    /// (success or error). Never touches UI state directly.
    ///
    /// Streaming is unconditional — the API supports it on every model
    /// and the UX is strictly better. The non-streaming `sendBlocking`
    /// path on `AnthropicClient` remains available for tests / future
    /// callers, but this worker does not exercise it.
    fn httpWorker(
        io: std.Io,
        client: *http.AnthropicClient,
        app: *Self,
        queue: *std.Io.Queue(WorkerResult),
    ) void {
        // Reset the staging buffer for this request. Worker is single-flight
        // (guarded by `is_loading`), so no other fiber can be reading or
        // writing here. We reset *before* touching the queue so a stale
        // `pending_response_len` from a previous request can never leak
        // into the first delta.
        app.pending_response_len = 0;

        var buf: ChatMessagesBuffer = .{};
        const request = app.buildChatRequest(&buf);

        var ctx = StreamCtx{ .io = io, .app = app, .queue = queue };
        const sink = http.StreamSink{
            .userdata = @ptrCast(&ctx),
            .callback = onStreamDelta,
        };

        var result: http.ChatResult = undefined;
        if (app.pending_file_path_len > 0) {
            const file_path = app.pending_file_path[0..app.pending_file_path_len];
            log.info("Streaming message with file attachment: {s}", .{file_path});
            result = client.sendStreamingWithFile(request, file_path, sink);
        } else {
            result = client.sendStreaming(request, sink);
        }
        defer result.deinit(client.allocator);

        // Terminal result. Note that on success, `result.text` is the full
        // accumulated response — but the staging buffer already holds it
        // (built up via deltas), so we don't re-copy. We just signal
        // "stream done, the bytes you've already drained are final".
        //
        // On error, the staging buffer may hold a partial response. We
        // leave it in place so the assistant message keeps whatever it
        // managed to render — same UX as a network drop mid-paragraph.
        const outcome: WorkerResult = switch (result.status) {
            .success => .{ .chat_success = .{ .response_len = app.pending_response_len } },
            .err => |msg| .{ .chat_error = .{ .message = msg } },
        };

        queue.putOne(io, outcome) catch |e| {
            // Queue closed (teardown) or task cancelled: main thread is
            // tearing down, drop the result.
            log.debug("httpWorker: terminal result dropped ({t})", .{e});
        };

        app.requestRenderFromWorker();
    }

    /// Request a render from a worker fiber. Safe to call from any thread —
    /// `Gooey.requestRender` is threadsafe by contract and only nudges the
    /// event loop; the actual result delivery still flows through the
    /// Io.Queue drain on the main thread.
    fn requestRenderFromWorker(self: *Self) void {
        const g = self.gooey_ptr orelse return;
        g.requestRender();
    }

    // =========================================================================
    // Render-loop Drain — apply pending results on the main thread
    // =========================================================================

    /// Drain the result queue and apply any completed worker outputs. Call
    /// this at the top of the render function, before anything reads
    /// `is_loading` or iterates `messages`.
    ///
    /// Non-blocking: returns immediately if the queue is empty. The internal
    /// buffer is sized to match `RESULT_QUEUE_CAPACITY` so a single drain
    /// cannot leave backlog.
    pub fn drainResults(self: *Self, cx: *gooey.Cx) void {
        var buf: [RESULT_QUEUE_CAPACITY]WorkerResult = undefined;
        const drained = cx.drainQueue(WorkerResult, &self.result_queue, &buf);
        std.debug.assert(drained.len <= RESULT_QUEUE_CAPACITY);
        for (drained) |r| {
            switch (r) {
                .chat_delta => |d| self.applyChatDelta(d),
                .chat_success => |ok| self.applyChatSuccess(ok),
                .chat_error => |err| self.applyChatError(err),
            }
        }
    }

    /// Apply one streaming delta. Lazily creates an empty assistant
    /// `Message` on the first delta of a stream, then grows it in-place
    /// for every subsequent delta. The cached layout height is
    /// invalidated each time so the virtual list re-measures the
    /// growing bubble on the next frame.
    fn applyChatDelta(self: *Self, d: DeltaResult) void {
        std.debug.assert(d.cumulative_len <= MAX_RESPONSE_LEN);
        std.debug.assert(self.is_loading);

        // First delta: append the placeholder assistant message and
        // remember its index. `addMessage` does the virtual-list /
        // scroll bookkeeping; we just have to capture the index *after*
        // the message is appended (so it survives any future overwrites
        // — which can't happen during a single stream, but the
        // assertion below pins the invariant either way).
        if (self.streaming_message_idx == null) {
            self.addMessage(Message.assistant(""));
            std.debug.assert(self.message_count > 0);
            self.streaming_message_idx = @intCast(self.message_count - 1);
        }

        const idx = self.streaming_message_idx.?;
        std.debug.assert(idx < self.message_count);

        // Compute the slot in the underlying ring and grow the message in
        // place. Worker only appends, so `cumulative_len` only goes up;
        // an out-of-order delta would trip the assertion below.
        const ring_idx = (self.message_head + idx) % MAX_MESSAGES;
        std.debug.assert(self.messages[ring_idx].role == .assistant);

        const new_len: usize = @intCast(d.cumulative_len);
        const cap = @min(new_len, MAX_MESSAGE_LEN);
        std.debug.assert(cap >= self.messages[ring_idx].content_len);

        @memcpy(
            self.messages[ring_idx].content[0..cap],
            self.pending_response_buf[0..cap],
        );
        self.messages[ring_idx].content_len = cap;
        // Invalidate cached height — the bubble just grew. The virtual
        // list will re-measure on the next render pass.
        self.messages[ring_idx].cached_height = 0.0;

        // Keep the freshly-grown message visible. `scrollToBottom` is
        // idempotent and cheap.
        self.list_state.scrollToBottom();
    }

    fn applyChatSuccess(self: *Self, r: SuccessResult) void {
        std.debug.assert(r.response_len <= MAX_RESPONSE_LEN);

        // Streaming path: deltas already populated the assistant message.
        // We only need to clear the "stream in flight" tracking.
        if (self.streaming_message_idx != null) {
            self.streaming_message_idx = null;
            self.error_message = null;
            self.is_loading = false;
            return;
        }

        // Fallback: stream completed without producing any deltas (zero-
        // length response). Surface as a single empty assistant message
        // for visual consistency rather than silently dropping the turn.
        const response = self.pending_response_buf[0..r.response_len];
        self.addMessage(Message.assistant(response));
        self.error_message = null;
        self.is_loading = false;
    }

    fn applyChatError(self: *Self, e: ErrorResult) void {
        // If the stream already produced visible output, leave the
        // partial assistant message in place — it's better UX than
        // wiping a half-typed paragraph. The error banner still tells
        // the user something went wrong.
        self.streaming_message_idx = null;
        self.error_message = e.message;
        self.is_loading = false;
    }

    // =========================================================================
    // Theme / Model Toggles
    // =========================================================================

    pub fn toggleDarkMode(self: *Self, g: *gooey.Gooey) void {
        self.dark_mode = !self.dark_mode;
        g.setAppearance(self.dark_mode);
        g.requestRender();
    }

    pub fn selectModel(self: *Self, index: usize) void {
        self.selected_model = @enumFromInt(index);
    }

    // =========================================================================
    // File Attachment Handlers
    // =========================================================================

    pub fn openFileDialog(self: *Self, g: *gooey.Gooey) void {
        _ = self;
        // Defer to avoid deadlock — the native file dialog blocks and
        // processes events, which can re-enter input handlers while the
        // render mutex is held.
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
            // Supported file types: images (base64), text files (inline), PDFs (Files API).
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
        // Find the last '/' to extract just the filename.
        var last_slash: usize = 0;
        for (path, 0..) |c, i| {
            if (c == '/') last_slash = i + 1;
        }
        return path[last_slash..];
    }
};
