//! Background work: the chat request and voice transcription, as Gooey jobs.
//!
//! Gooey runs each job's `run` on a worker it owns (`Config.jobs` in
//! `main.zig`). A job copies its `Input` at spawn and never touches
//! `AppState`: everything it posts arrives at an `AppState` handler on the
//! main thread, in the next drain, and each post wakes the event loop, so
//! nothing polls. At shutdown Gooey cancels and joins the jobs before
//! `on_deinit`, so no worker outlives the state.
//!
//! A chat request needs the whole conversation, which is far larger than a
//! job input. So `sendMessage` copies it into `exchange`, an app-owned
//! buffer outside `AppState`, and spawns `ChatJob`. Ownership alternates:
//!   - The main thread writes `exchange.conversation` only while no chat job
//!     runs (`AppState.chat_job == null`), right before spawning one.
//!   - The chat job reads it, and writes `exchange.summary`, until it
//!     returns; it posts a `.compaction` result only after its last write to
//!     `exchange.summary`, and the main thread reads that buffer only while
//!     delivering that result. The post's ring is the happens-before edge.
//!   - `exchange.compaction_support` belongs to chat jobs alone, and at most
//!     one runs at a time (`AppState.chat_job`).
//!   - The clients are written once in `on_init`, before any job exists.

const std = @import("std");
const log = std.log.scoped(.chatzig);
const gooey = @import("gooey");

const anthropic = @import("http/anthropic.zig");
const openai = @import("http/openai.zig");
const compaction = @import("compaction.zig");
const state = @import("state.zig");

const Model = state.Model;
const MessageRole = state.MessageRole;
const MAX_MESSAGES = state.MAX_MESSAGES;
const MAX_MESSAGE_LEN = state.MAX_MESSAGE_LEN;
const Summary = compaction.Summary;
const MAX_FILE_PATH_LEN = state.MAX_FILE_PATH_LEN;

comptime {
    // The native summary must fit the buffer whatever its length, since it
    // cannot be truncated: the output cap bounds it at ~4 bytes a token.
    std.debug.assert(anthropic.COMPACTION_MAX_TOKENS * compaction.CHARS_PER_TOKEN <=
        compaction.MAX_NATIVE_SUMMARY_LEN);
}

/// Text bytes one posted result carries: a streamed delta piece, an error
/// message, or a transcript. `MAX_INPUT_LEN`, so a transcript fits in one.
pub const text_bytes_max: usize = state.MAX_INPUT_LEN;

/// Every buffer a job reads or writes besides its input. See the file comment
/// for who owns which part when.
pub var exchange: Exchange = .{};

pub const Exchange = struct {
    anthropic_client: ?anthropic.AnthropicClient = null,
    openai_client: ?openai.OpenAIClient = null,
    conversation: Conversation = .{},
    /// The summary the chat job computed, read by `AppState.onChatResult`.
    summary: Summary = .{},
    /// Per model: does it support native on-demand compaction? Null until
    /// the Models API has answered once; an unknown answer is not cached.
    compaction_support: [state.MODEL_COUNT]?bool = @splat(null),
};

/// A piece of text a job posts, copied into the result slot.
pub const Text = struct {
    len: u16,
    bytes: [text_bytes_max]u8,

    pub fn of(text: []const u8) Text {
        const len = @min(text.len, text_bytes_max);
        var value: Text = .{ .len = @intCast(len), .bytes = undefined };
        @memcpy(value.bytes[0..len], text[0..len]);
        return value;
    }

    pub fn slice(self: *const Text) []const u8 {
        std.debug.assert(self.len <= text_bytes_max);
        return self.bytes[0..self.len];
    }
};

// =============================================================================
// Conversation snapshot
// =============================================================================

/// Which prefix of history a request omits, and the summary standing in
/// for it. Passed explicitly to the request builders because the job may
/// use a summary it just computed, which the main thread has not adopted.
pub const CompactionView = struct {
    /// Empty when nothing has been compacted, in which case `covers` is 0
    /// and the builders send the whole ring.
    summary: *const Summary,
    covers: u64,
};

/// The part of `AppState` a chat request reads, copied by `capture`. The
/// message text is packed into one buffer, so a send copies the bytes the
/// conversation holds rather than every message's full capacity.
pub const Conversation = struct {
    count: u32 = 0,
    messages_total: u64 = 0,
    roles: [MAX_MESSAGES]MessageRole = undefined,
    starts: [MAX_MESSAGES]u32 = undefined,
    lens: [MAX_MESSAGES]u32 = undefined,
    text: [MAX_MESSAGES * MAX_MESSAGE_LEN]u8 = undefined,
    summary: Summary = .{},
    summary_covers: u64 = 0,
    model: Model = .haiku,
    attachment_path: [MAX_FILE_PATH_LEN]u8 = undefined,
    attachment_path_len: u32 = 0,

    const Self = @This();

    /// Copy the live ring, the compaction cut, the model, and the staged
    /// attachment out of `app`. Main thread, only while no chat job runs.
    pub fn capture(self: *Self, app: *const state.AppState, attachment: []const u8) void {
        std.debug.assert(app.message_count <= MAX_MESSAGES);
        std.debug.assert(attachment.len <= MAX_FILE_PATH_LEN);

        var offset: u32 = 0;
        var i: u32 = 0;
        while (i < app.message_count) : (i += 1) {
            const msg = app.getMessage(i).?;
            const text = msg.getText();
            std.debug.assert(text.len <= MAX_MESSAGE_LEN);
            self.roles[i] = msg.role;
            self.starts[i] = offset;
            self.lens[i] = @intCast(text.len);
            @memcpy(self.text[offset..][0..text.len], text);
            offset += @intCast(text.len);
        }
        std.debug.assert(offset <= self.text.len);
        self.count = i;
        self.messages_total = app.messages_total;
        self.summary.copyFrom(&app.summary);
        self.summary_covers = app.summary_covers;
        self.model = app.selected_model;
        @memcpy(self.attachment_path[0..attachment.len], attachment);
        self.attachment_path_len = @intCast(attachment.len);
    }

    fn role(self: *const Self, i: usize) MessageRole {
        std.debug.assert(i < self.count);
        return self.roles[i];
    }

    fn textOf(self: *const Self, i: usize) []const u8 {
        std.debug.assert(i < self.count);
        return self.text[self.starts[i]..][0..self.lens[i]];
    }

    fn attachmentPath(self: *const Self) []const u8 {
        std.debug.assert(self.attachment_path_len <= MAX_FILE_PATH_LEN);
        return self.attachment_path[0..self.attachment_path_len];
    }

    /// The compaction state the main thread held at capture.
    fn liveCompactionView(self: *const Self) CompactionView {
        if (self.summary.isEmpty()) std.debug.assert(self.summary_covers == 0);
        return .{ .summary = &self.summary, .covers = self.summary_covers };
    }

    /// Logical index of the first `.user` turn at or after `from`, or null
    /// if the retained tail holds none.
    fn firstUserAtOrAfter(self: *const Self, from: usize) ?usize {
        std.debug.assert(from <= self.count);
        var i = from;
        while (i < self.count) : (i += 1) {
            if (self.role(i) == .user) return i;
        }
        return null;
    }

    /// Logical index of the first message a request sends verbatim under
    /// `covers`. Snapped forward to a `.user` turn, because Anthropic
    /// requires the first message to be one — and it is exactly why the
    /// summary rides in the `system` field rather than as a synthetic
    /// leading message, which would collide with this turn.
    ///
    /// Falls back to 0 when the retained tail contains no user turn at all.
    /// That cannot happen on the send path (`sendMessage` appends the
    /// user's turn before capturing), and sending uncompacted history is the
    /// same free failure mode as a summarization request that errors out.
    fn retainedStart(self: *const Self, covers: u64) usize {
        std.debug.assert(self.count <= MAX_MESSAGES);
        std.debug.assert(covers <= self.messages_total);

        const raw = compaction.cutToIndex(.{
            .covers = covers,
            .messages_total = self.messages_total,
            .message_count = self.count,
        });
        const start = self.firstUserAtOrAfter(raw) orelse 0;
        std.debug.assert(start <= self.count);
        return start;
    }

    /// Heuristic token count for the request `view` would produce, plus
    /// `attachment_bytes` for a staged file.
    ///
    /// Deliberately not the real `usage` numbers: on the streaming path
    /// `usage` arrives in SSE events `parseSseTextDelta` discards, and this is
    /// a threshold, not a bill. Counting the attachment cannot be deferred:
    /// files are inlined into the request by the client and never appear in
    /// the messages, so a single attached file dwarfs the text history.
    fn estimatedTokens(self: *const Self, view: CompactionView, attachment_bytes: u64) u32 {
        var chars: u64 = state.CHAT_SYSTEM_INSTRUCTION.len + view.summary.text().len + attachment_bytes;
        var i = self.retainedStart(view.covers);
        while (i < self.count) : (i += 1) {
            chars += self.lens[i];
        }
        return compaction.estimateTokens(chars);
    }

    /// Where a new compaction would cut, or null if it would not make
    /// progress.
    ///
    /// Progress is the guard that keeps a long retained tail from
    /// compacting on every single turn. The returned `covers` is the
    /// realized cut, after `retainedStart` snapped it forward to a `.user`
    /// turn, converted back into `seq` space once, here.
    fn planCompactionCut(self: *const Self, live: CompactionView) ?struct {
        from: usize,
        to: usize,
        covers: u64,
    } {
        const proposed = compaction.proposedCovers(self.messages_total);
        if (proposed <= live.covers) return null;

        const from = self.retainedStart(live.covers);
        const to = self.retainedStart(proposed);
        if (to <= from) return null;

        // `to` indexes the live ring, while the cut is stored against the
        // monotonic counter, so shift it by however far index 0 has drifted
        // from `seq` 0 — the `evicted` term `cutToIndex` subtracts.
        const evicted = self.messages_total - @as(u64, self.count);
        const covers = evicted + @as(u64, @intCast(to));

        std.debug.assert(to <= self.count);
        std.debug.assert(covers > live.covers);
        std.debug.assert(covers <= self.messages_total);
        // The snap is already baked into `covers`, so re-resolving it must
        // land on the same boundary rather than sliding forward again.
        std.debug.assert(self.retainedStart(covers) == to);
        return .{ .from = from, .to = to, .covers = covers };
    }
};

// =============================================================================
// Request assembly
// =============================================================================

const SYSTEM_BUFFER_LEN: usize =
    state.CHAT_SYSTEM_INSTRUCTION.len + compaction.SUMMARY_PREAMBLE.len + compaction.MAX_NATIVE_SUMMARY_LEN;

/// Composes the system instruction a request carries: the standing
/// plain-text rules, plus the compaction summary when there is one. The
/// summary must not replace the formatting rules, so the two are
/// concatenated into `out`, sized from both operands.
fn composeSystemInstruction(out: *[SYSTEM_BUFFER_LEN]u8, summary: []const u8) []const u8 {
    if (summary.len == 0) return state.CHAT_SYSTEM_INSTRUCTION;
    std.debug.assert(summary.len <= compaction.MAX_NATIVE_SUMMARY_LEN);

    const head = state.CHAT_SYSTEM_INSTRUCTION ++ compaction.SUMMARY_PREAMBLE;
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..][0..summary.len], summary);

    const len = head.len + summary.len;
    std.debug.assert(len <= out.len);
    return out[0..len];
}

const ChatMessagesBuffer = struct {
    messages: [MAX_MESSAGES]anthropic.ChatMessage = undefined,
    count: usize = 0,
    /// Backs `composeSystemInstruction`'s output, with the same lifetime as
    /// the message slices the request borrows.
    system_buf: [SYSTEM_BUFFER_LEN]u8 = undefined,
};

/// The block a native summary is sent back as.
fn blockOf(summary: *const Summary) anthropic.CompactionBlock {
    std.debug.assert(summary.isNative());
    return .{
        .content = summary.text(),
        .signature = summary.signature(),
        .encrypted_content = summary.encryptedContent(),
    };
}

/// Builds an Anthropic request starting at `view`'s cut, with `view.summary`
/// standing in for the omitted turns: sent back as the native block when
/// `native` (the summary is one and the model supports it), otherwise as
/// text in the system prompt.
fn buildAnthropicChatRequest(
    conversation: *const Conversation,
    buf: *ChatMessagesBuffer,
    view: CompactionView,
    native: bool,
) anthropic.ChatRequest {
    if (native) std.debug.assert(view.summary.isNative());
    buf.count = 0;
    var i: usize = conversation.retainedStart(view.covers);
    while (i < conversation.count and buf.count < MAX_MESSAGES) : (i += 1) {
        const role: anthropic.ChatRole = switch (conversation.role(i)) {
            .user => .user,
            .assistant => .assistant,
            .system => continue, // Anthropic takes system via a separate field.
        };
        buf.messages[buf.count] = anthropic.ChatMessage.text(role, conversation.textOf(i));
        buf.count += 1;
    }
    return .{
        .model = conversation.model.apiName(),
        .messages = buf.messages[0..buf.count],
        .system = composeSystemInstruction(&buf.system_buf, if (native) "" else view.summary.text()),
        .compaction_block = if (native) blockOf(view.summary) else null,
    };
}

/// Builds the native compaction request for `[from, to)`: the same system
/// prompt and summary a chat request would carry, then the messages to
/// fold in. `compact` adds `"compaction":{"type":"summarize"}`. The model
/// summarizes everything it is sent, so the retained tail is left out, and
/// a previous block leads so the new one subsumes it.
fn buildNativeCompactionRequest(
    conversation: *const Conversation,
    buf: *ChatMessagesBuffer,
    live: CompactionView,
    from: usize,
    to: usize,
) anthropic.ChatRequest {
    std.debug.assert(from < to);
    std.debug.assert(to <= conversation.count);

    buf.count = 0;
    var i = from;
    while (i < to and buf.count < MAX_MESSAGES) : (i += 1) {
        const role: anthropic.ChatRole = switch (conversation.role(i)) {
            .user => .user,
            .assistant => .assistant,
            .system => continue,
        };
        buf.messages[buf.count] = anthropic.ChatMessage.text(role, conversation.textOf(i));
        buf.count += 1;
    }
    std.debug.assert(buf.count > 0);

    const native = live.summary.isNative();
    return .{
        .model = conversation.model.apiName(),
        .messages = buf.messages[0..buf.count],
        .system = composeSystemInstruction(&buf.system_buf, if (native) "" else live.summary.text()),
        .compaction_block = if (native) blockOf(live.summary) else null,
    };
}

const OpenAIChatMessagesBuffer = struct {
    messages: [MAX_MESSAGES]openai.ChatMessage = undefined,
    count: usize = 0,
    system_buf: [SYSTEM_BUFFER_LEN]u8 = undefined,
};

/// Builds an OpenAI Chat Completions request. OpenAI has no top-level
/// system field, so the composed instruction rides as the first message. A
/// summary earned on the Anthropic path is honored here too.
fn buildOpenAIChatRequest(
    conversation: *const Conversation,
    buf: *OpenAIChatMessagesBuffer,
    view: CompactionView,
) openai.ChatRequest {
    buf.count = 0;
    buf.messages[buf.count] = openai.ChatMessage.text(
        .system,
        composeSystemInstruction(&buf.system_buf, view.summary.text()),
    );
    buf.count += 1;

    var i: usize = conversation.retainedStart(view.covers);
    while (i < conversation.count and buf.count < MAX_MESSAGES) : (i += 1) {
        const role: openai.ChatRole = switch (conversation.role(i)) {
            .user => .user,
            .assistant => .assistant,
            .system => .system,
        };
        buf.messages[buf.count] = openai.ChatMessage.text(role, conversation.textOf(i));
        buf.count += 1;
    }
    return .{
        .model = conversation.model.apiName(),
        .messages = buf.messages[0..buf.count],
    };
}

/// Fills `buf` with the slice of history `[from, to)` to be summarized,
/// followed by the instruction turn that asks for the summary. Any prior
/// summary leads as its own user turn so the new summary subsumes it.
fn buildSummaryRequest(
    conversation: *const Conversation,
    buf: *ChatMessagesBuffer,
    view: CompactionView,
    from: usize,
    to: usize,
) anthropic.ChatRequest {
    std.debug.assert(from < to);
    std.debug.assert(to <= conversation.count);

    buf.count = 0;
    if (!view.summary.isEmpty()) {
        // The Messages API merges consecutive same-role turns, so the only
        // rule that binds is "the first message is user", which holds. A
        // native summary's text works here too; its signature is dropped.
        buf.messages[buf.count] = anthropic.ChatMessage.text(.user, view.summary.text());
        buf.count += 1;
    }

    var i = from;
    while (i < to and buf.count + 1 < MAX_MESSAGES) : (i += 1) {
        const role: anthropic.ChatRole = switch (conversation.role(i)) {
            .user => .user,
            .assistant => .assistant,
            .system => continue,
        };
        buf.messages[buf.count] = anthropic.ChatMessage.text(role, conversation.textOf(i));
        buf.count += 1;
    }

    buf.messages[buf.count] = anthropic.ChatMessage.text(.user, compaction.REQUEST);
    buf.count += 1;
    std.debug.assert(buf.count <= MAX_MESSAGES);

    return .{
        // Summarizing with the cheapest model; the client is model-agnostic.
        .model = Model.haiku.apiName(),
        .messages = buf.messages[0..buf.count],
        .system = compaction.SYSTEM_INSTRUCTION,
    };
}

// =============================================================================
// ChatJob
// =============================================================================

/// One chat turn: compact if needed, then stream the reply. Compaction is
/// native (Anthropic's signed `compaction` block) on models that support
/// it, and the client-side summary otherwise or when the native call fails.
///
/// Posts any number of `.delta`s, at most one `.compaction` (before the
/// first delta), and at most one `.failure`, which is last. A reply longer
/// than `state.MAX_RESPONSE_LEN` is cut there.
pub const ChatJob = struct {
    pub const Input = struct {
        provider: state.ModelProvider,
    };

    pub const Result = union(enum) {
        delta: Text,
        failure: Text,
        /// `exchange.summary` holds the new summary.
        compaction: struct {
            /// New `AppState.summary_covers`: the realized cut.
            covers: u64,
        },
    };

    pub fn run(input: *const Input, job: *gooey.Job(Result)) !void {
        const conversation = &exchange.conversation;
        std.debug.assert(conversation.count > 0);
        var stream: Stream = .{ .job = job };
        switch (input.provider) {
            .anthropic => {
                const client = &exchange.anthropic_client.?;
                const view = try runCompaction(job, client, conversation);
                const native = view.summary.isNative() and
                    nativeCompactionSupported(client, conversation.model);
                var buf: ChatMessagesBuffer = .{};
                const request = buildAnthropicChatRequest(conversation, &buf, view, native);
                const sink = anthropic.StreamSink{
                    .userdata = &stream,
                    .callback = Stream.anthropicDelta,
                };
                const path = conversation.attachmentPath();
                if (path.len > 0) log.info("Streaming message with file attachment: {s}", .{path});
                var result = if (path.len > 0)
                    client.sendStreamingWithFile(request, path, sink)
                else
                    client.sendStreaming(request, sink);
                try finish(job, &result, client.allocator);
            },
            .openai => {
                // No compaction pass: summarizing goes through haiku, on the
                // Anthropic client. `sendMessage` refuses attachments here.
                std.debug.assert(conversation.attachment_path_len == 0);
                const client = &exchange.openai_client.?;
                var buf: OpenAIChatMessagesBuffer = .{};
                const view = conversation.liveCompactionView();
                const request = buildOpenAIChatRequest(conversation, &buf, view);
                const sink = openai.StreamSink{
                    .userdata = &stream,
                    .callback = Stream.openaiDelta,
                };
                var result = client.sendStreamingChat(request, sink);
                try finish(job, &result, client.allocator);
            },
        }
    }

    /// Post the stream's error, if any, and free the result. On success the
    /// deltas already carried the whole reply.
    fn finish(job: *gooey.Job(Result), result: anytype, allocator: std.mem.Allocator) !void {
        defer result.deinit(allocator);
        if (job.cancelled()) return error.Canceled;
        switch (result.status) {
            .success => {},
            .err => |message| _ = job.post(&.{ .failure = .of(message) }),
        }
    }

    /// Compacts if the estimated request crossed `compaction.TRIGGER_RATIO`
    /// of the model's window, and returns the view to build the request
    /// from. A skipped or failed compaction returns the live view: it costs
    /// one wasted summarization request at worst.
    fn runCompaction(
        job: *gooey.Job(Result),
        client: *anthropic.AnthropicClient,
        conversation: *const Conversation,
    ) !CompactionView {
        const live = conversation.liveCompactionView();

        const window_tokens = conversation.model.contextWindowTokens();
        const attachment_bytes = attachmentBytes(job.io(), conversation.attachmentPath());
        const estimate = conversation.estimatedTokens(live, attachment_bytes);
        if (estimate < compaction.thresholdTokens(window_tokens)) return live;

        const cut = conversation.planCompactionCut(live) orelse return live;
        log.info(
            "compaction: ~{d} tokens of a {d} window, summarizing messages {d}..{d}",
            .{ estimate, window_tokens, cut.from, cut.to },
        );

        if (nativeCompactionSupported(client, conversation.model)) {
            if (try compactNative(job, client, conversation, live, cut.from, cut.to)) {
                return adopt(job, cut.covers);
            }
        }

        var buf: ChatMessagesBuffer = .{};
        const request = buildSummaryRequest(conversation, &buf, live, cut.from, cut.to);
        var result = client.sendBlocking(request);
        defer result.deinit(client.allocator);
        if (job.cancelled()) return error.Canceled;

        const text = result.getText() orelse {
            log.warn("compaction: summarization failed ({s}), sending uncompacted", .{
                result.getError() orelse "unknown",
            });
            return live;
        };
        if (!exchange.summary.setText(text)) return live;
        log.info("compaction: client-side summary, {d} bytes", .{exchange.summary.text().len});
        return adopt(job, cut.covers);
    }

    /// Asks Anthropic for a native block over `[from, to)` and stages it in
    /// `exchange.summary`. False when the call fails or returns no block
    /// that fits, so the caller falls back to the client-side summary.
    fn compactNative(
        job: *gooey.Job(Result),
        client: *anthropic.AnthropicClient,
        conversation: *const Conversation,
        live: CompactionView,
        from: usize,
        to: usize,
    ) !bool {
        var buf: ChatMessagesBuffer = .{};
        const request = buildNativeCompactionRequest(conversation, &buf, live, from, to);
        var result = client.compact(request);
        defer result.deinit();
        if (job.cancelled()) return error.Canceled;

        const block = switch (result.status) {
            .success => |block| block,
            .err => |message| {
                log.warn("compaction: native compaction failed ({s}), using the client-side summary", .{message});
                return false;
            },
        };
        if (!exchange.summary.setNative(block.content, block.signature, block.encrypted_content)) {
            log.warn("compaction: native block too large ({d} + {d} bytes), using the client-side summary", .{
                block.content.len, block.signature.len,
            });
            return false;
        }
        log.info("compaction: native block, {d} bytes of summary", .{block.content.len});
        return true;
    }

    /// Hands the summary staged in `exchange.summary` to the main thread
    /// and returns the view this request builds from. The post is the last
    /// write's happens-before edge; this request keeps reading the buffer,
    /// which is safe because nothing writes it again in this job.
    fn adopt(job: *gooey.Job(Result), covers: u64) !CompactionView {
        std.debug.assert(!exchange.summary.isEmpty());
        if (!job.post(&.{ .compaction = .{ .covers = covers } })) return error.Canceled;
        return .{ .summary = &exchange.summary, .covers = covers };
    }

    /// Whether `model` supports native compaction, asking the Models API
    /// the first time and caching a definite answer for the process.
    fn nativeCompactionSupported(client: *anthropic.AnthropicClient, model: Model) bool {
        std.debug.assert(model.provider() == .anthropic);
        const slot = &exchange.compaction_support[@backingInt(model)];
        if (slot.*) |known| return known;
        const answer = client.compactionSupported(model.apiName()) orelse return false;
        slot.* = answer;
        log.info("compaction: {s} {s} native compaction", .{
            model.apiName(), if (answer) "supports" else "does not support",
        });
        return answer;
    }

    /// Size of the staged attachment, or 0 when none is staged or it can't
    /// be measured. A stat failure under-counts the estimate, which is
    /// better than refusing to send.
    fn attachmentBytes(io: std.Io, path: []const u8) u64 {
        if (path.len == 0) return 0;
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |e| {
            log.debug("compaction: cannot stat '{s}' for the token estimate: {t}", .{ path, e });
            return 0;
        };
        defer file.close(io);
        const stat = file.stat(io) catch |e| {
            log.debug("compaction: stat failed for '{s}': {t}", .{ path, e });
            return 0;
        };
        return stat.size;
    }
};

/// Forwards each SSE text delta to the main thread as `.delta` results.
const Stream = struct {
    job: *gooey.Job(ChatJob.Result),
    /// Reply bytes posted so far, at most `state.MAX_RESPONSE_LEN`.
    posted_bytes: usize = 0,

    fn anthropicDelta(userdata: *anyopaque, text: []const u8) anthropic.StreamSink.Error!void {
        const self: *Stream = @ptrCast(@alignCast(userdata));
        return self.forward(text);
    }

    fn openaiDelta(userdata: *anyopaque, text: []const u8) openai.StreamSink.Error!void {
        const self: *Stream = @ptrCast(@alignCast(userdata));
        return self.forward(text);
    }

    /// Post `text` in pieces of at most `text_bytes_max`. Returning
    /// `error.Aborted` stops the SSE read: when the reply is full, or once
    /// the job is cancelled (`post` returns false).
    fn forward(self: *Stream, text: []const u8) error{Aborted}!void {
        std.debug.assert(self.posted_bytes <= state.MAX_RESPONSE_LEN);
        const room = state.MAX_RESPONSE_LEN - self.posted_bytes;
        if (room == 0) return error.Aborted;
        const kept = text[0..@min(text.len, room)];

        var offset: usize = 0;
        // Bounded: each pass posts at least one byte of `kept`.
        while (offset < kept.len) {
            const piece = kept[offset..][0..@min(kept.len - offset, text_bytes_max)];
            std.debug.assert(piece.len > 0);
            if (!self.job.post(&.{ .delta = .of(piece) })) return error.Aborted;
            offset += piece.len;
        }
        self.posted_bytes += kept.len;
    }
};

// =============================================================================
// TranscribeJob
// =============================================================================

/// Transcribes a finished recording with the selected OpenAI model.
pub const TranscribeJob = struct {
    pub const Input = struct {
        /// A copy of the recording's path: a new recording overwrites
        /// `RecordingState.path_buffer` while this job may still run.
        path: [state.RECORDING_PATH_MAX_LEN]u8,
        path_len: u16,
        model: state.DictationModel,
    };

    pub const Result = union(enum) {
        /// Capped at `MAX_INPUT_LEN`: it goes straight into the input box.
        transcript: Text,
        failure: Text,
    };

    pub fn run(input: *const Input, job: *gooey.Job(Result)) !void {
        std.debug.assert(input.path_len > 0);
        std.debug.assert(input.path_len <= state.RECORDING_PATH_MAX_LEN);
        const client = &exchange.openai_client.?;

        var result = client.transcribeFile(input.path[0..input.path_len], input.model.apiName());
        defer result.deinit(client.allocator);
        if (job.cancelled()) return error.Canceled;

        _ = switch (result.status) {
            .success => |text| job.post(&.{ .transcript = .of(text) }),
            .err => |message| job.post(&.{ .failure = .of(message) }),
        };
    }
};
