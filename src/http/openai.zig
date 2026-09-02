//! OpenAI HTTP Client — audio transcription + Chat Completions.
//!
//! Two independent capabilities live here:
//!   * Audio transcription: turn a just-finished recording (a WAV file on
//!     disk) into text via `/v1/audio/transcriptions`. The model is chosen
//!     by the caller (see `DEFAULT_TRANSCRIBE_MODEL` and the
//!     `DictationModel` picker in `state.zig`).
//!   * Streaming chat: `sendStreamingChat` drives `/v1/chat/completions`
//!     with `"stream": true` for the GPT chat models (see `state.Model`),
//!     mirroring `anthropic.AnthropicClient.sendStreaming`'s shape and SSE
//!     read loop closely enough that a reader familiar with one recognizes
//!     the other, without literally sharing types (the two APIs' request/
//!     event shapes differ enough that a shared type would just grow an
//!     `if (provider == ...)` branch inside every method).
//!
//! Shares its retry/backoff/HTTP-error-classification plumbing with
//! `http.zig` (`fetchWithRetry`, `classifyHttpStatus`, etc. — made `pub`
//! there for this purpose) rather than duplicating it: both clients retry
//! against the same shape of transient failure (connect/TLS drops,
//! 429/5xx), so the policy belongs in one place. JSON string escaping is
//! shared too, via `anthropic.writeJsonEscapedString` — same rationale
//! `session_log.zig` gives for reusing it: one escaping implementation to
//! keep correct rather than two.
//!
//! Usage (transcription):
//!   var client = OpenAIClient.init(api_key, allocator, io);
//!   var result = client.transcribeFile(audio_path, DEFAULT_TRANSCRIBE_MODEL);
//!   defer result.deinit(allocator);
//!   switch (result.status) {
//!       .success => |text| { ... },
//!       .err => |msg| { ... },
//!   }
//!
//! Usage (streaming chat):
//!   var result = client.sendStreamingChat(request, sink);
//!   defer result.deinit(allocator);
//!   switch (result.status) {
//!       .success => |text| { ... }, // full accumulated text
//!       .err => |msg| { ... },
//!   }

const std = @import("std");
const log = std.log.scoped(.chatzig);
const http_std = std.http;
const Uri = std.Uri;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const net = @import("http.zig");
const anthropic = @import("anthropic.zig");

// =============================================================================
// Constants
// =============================================================================

const TRANSCRIPTION_API_URL = "https://api.openai.com/v1/audio/transcriptions";

/// Default model used for recording -> text. Small, fast, and cheap — a
/// good fit for short voice notes dictated into a chat input box. The user
/// can pick a different transcription model in Settings (see
/// `state.DictationModel`); this is only the initial value.
pub const DEFAULT_TRANSCRIBE_MODEL = "gpt-4o-mini-transcribe";

/// Upper bound on a transcription model name's length, used to size the
/// multipart request buffer without depending on which model is actually
/// selected. Comfortably covers every model in `state.DictationModel`
/// (longest today is "gpt-4o-mini-transcribe" at 22 bytes).
const MAX_MODEL_NAME_LEN: usize = 32;

/// OpenAI rejects audio uploads over 25MB; stay comfortably under that so
/// an oversized recording fails fast locally instead of paying for the
/// upload only to have the server reject it.
pub const MAX_AUDIO_FILE_SIZE: usize = 24 * 1024 * 1024;

/// Transcription responses are a single small JSON object
/// (`{"text": "..."}`) — nowhere near chat-completion sizes.
const MAX_RESPONSE_SIZE: usize = 64 * 1024;

/// Transcripts longer than this are truncated rather than rejected — a
/// partial transcript dropped into the chat input is still useful, and
/// this comfortably covers any realistic dictated voice note.
pub const MAX_TEXT_LEN: usize = 16 * 1024;

const LOG_PAYLOADS: bool = false;

const MULTIPART_BOUNDARY = "----ChatZigTranscribeBoundary";

// =============================================================================
// Result type
// =============================================================================

pub const TranscriptionResult = struct {
    status: union(enum) {
        success: []const u8, // transcript text (owned)
        err: []const u8, // static error message
    },
    owned: bool = false,

    pub fn success(text: []const u8) TranscriptionResult {
        return .{ .status = .{ .success = text }, .owned = true };
    }

    pub fn err(msg: []const u8) TranscriptionResult {
        return .{ .status = .{ .err = msg }, .owned = false };
    }

    pub fn deinit(self: *TranscriptionResult, allocator: Allocator) void {
        if (self.owned) {
            switch (self.status) {
                .success => |text| allocator.free(text),
                .err => {},
            }
        }
        self.* = undefined;
    }

    pub fn isSuccess(self: *const TranscriptionResult) bool {
        return switch (self.status) {
            .success => true,
            .err => false,
        };
    }

    pub fn getText(self: *const TranscriptionResult) ?[]const u8 {
        return switch (self.status) {
            .success => |text| text,
            .err => null,
        };
    }
};

// =============================================================================
// File reading
// =============================================================================

/// Reads `path` (relative to cwd — recordings live under `recordings/`,
/// see `state.RecordingState`) into an owned buffer, bounded by
/// `MAX_AUDIO_FILE_SIZE`. Mirrors `http.readFileAttachment`'s shape but
/// opens relative to cwd rather than requiring an absolute path.
fn readAudioFile(io: Io, allocator: Allocator, path: []const u8) ![]u8 {
    std.debug.assert(path.len > 0);

    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |e| {
        log.err("Failed to open recording {s}: {}", .{ path, e });
        return error.FileOpenFailed;
    };
    defer file.close(io);

    const stat = file.stat(io) catch |e| {
        log.err("Failed to stat recording {s}: {}", .{ path, e });
        return error.FileStatFailed;
    };
    if (stat.size == 0) return error.EmptyFile;
    if (stat.size > MAX_AUDIO_FILE_SIZE) return error.FileTooLarge;

    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const content = file_reader.interface.allocRemaining(
        allocator,
        Io.Limit.limited(MAX_AUDIO_FILE_SIZE),
    ) catch |e| {
        log.err("Failed to read recording {s}: {}", .{ path, e });
        return error.FileReadFailed;
    };

    std.debug.assert(content.len > 0);
    std.debug.assert(content.len <= MAX_AUDIO_FILE_SIZE);
    return content;
}

// =============================================================================
// Response parsing
// =============================================================================

const TranscriptionApiResponse = struct {
    text: []const u8,
};

/// Parses `{"text": "..."}` and returns an owned, length-capped copy.
/// Does not log on failure — the caller (`receiveResponse`) logs with the
/// full response body for context, which this helper doesn't have reason
/// to duplicate.
fn parseTranscriptText(allocator: Allocator, json_data: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(TranscriptionApiResponse, allocator, json_data, .{
        .ignore_unknown_fields = true,
    }) catch return error.JsonParseError;
    defer parsed.deinit();

    if (parsed.value.text.len == 0) return error.EmptyText;

    const capped_len = @min(parsed.value.text.len, MAX_TEXT_LEN);
    return try allocator.dupe(u8, parsed.value.text[0..capped_len]);
}

// =============================================================================
// Chat Completions (streaming) — request/result types
// =============================================================================

const CHAT_API_URL = "https://api.openai.com/v1/chat/completions";

/// Chat responses run far larger than transcription's small JSON blobs —
/// mirrors `anthropic.MAX_RESPONSE_SIZE` since both providers serve
/// comparable conversation lengths.
const MAX_CHAT_RESPONSE_SIZE: usize = 1024 * 1024; // 1MB

/// Upper bound on the request JSON buffer. Text-only (no attachments), so
/// this is far smaller than Anthropic's `MAX_HTTP_REQUEST_BODY_SIZE` budget,
/// which has to cover base64-encoded images/PDFs.
const MAX_CHAT_REQUEST_SIZE: usize = 4 * 1024 * 1024; // 4MB

const MAX_CHAT_TOKENS: u32 = 4096;

/// Mirrors `anthropic.MAX_MESSAGES` — same conversation-length budget,
/// different provider.
pub const MAX_CHAT_MESSAGES: usize = 256;

/// Per-line buffer for the SSE reader — same budget and rationale as
/// `anthropic.SSE_READER_BUF_SIZE`.
const CHAT_SSE_READER_BUF_SIZE: usize = 16 * 1024;

/// Bound on a single streamed delta chunk, mirroring
/// `anthropic.MAX_DELTA_TEXT_LEN`.
const MAX_CHAT_DELTA_TEXT_LEN: usize = 32 * 1024;

pub const ChatRole = enum {
    system,
    user,
    assistant,

    pub fn apiName(self: ChatRole) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
        };
    }
};

pub const ChatMessage = struct {
    role: ChatRole,
    content: []const u8,

    pub fn text(role: ChatRole, txt: []const u8) ChatMessage {
        return .{ .role = role, .content = txt };
    }
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []const ChatMessage,
};

/// Callback invoked from the HTTP fiber for each streamed content chunk.
/// Same shape as `anthropic.StreamSink` (see its doc comment for the full
/// contract — borrowed `text` slice, `error.Aborted` short-circuits the
/// read loop) but a distinct type: Zig function pointers must match their
/// declaring module's error set, so `state.zig` wires up one small adapter
/// callback per provider rather than sharing a single sink type.
pub const StreamSink = struct {
    pub const Error = error{Aborted};

    userdata: *anyopaque,
    callback: *const fn (userdata: *anyopaque, text: []const u8) Error!void,
};

pub const ChatResult = struct {
    const Self = @This();

    status: union(enum) {
        success: []const u8,
        err: []const u8,
    },

    /// Whether the response text is owned and needs freeing
    owned: bool = false,

    pub fn success(text: []const u8) Self {
        return .{ .status = .{ .success = text }, .owned = true };
    }

    pub fn err(msg: []const u8) Self {
        return .{ .status = .{ .err = msg }, .owned = false };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        if (self.owned) {
            switch (self.status) {
                .success => |text| allocator.free(text),
                .err => {},
            }
        }
    }

    pub fn isSuccess(self: *const Self) bool {
        return switch (self.status) {
            .success => true,
            .err => false,
        };
    }

    pub fn getText(self: *const Self) ?[]const u8 {
        return switch (self.status) {
            .success => |text| text,
            .err => null,
        };
    }
};

// =============================================================================
// Client
// =============================================================================

pub const OpenAIClient = struct {
    const Self = @This();

    api_key: []const u8,
    allocator: Allocator,
    /// Shared `std.Io` used for filesystem access and TCP/TLS. Owned by
    /// `main()` via `std.process.Init` — the client borrows it.
    io: Io,

    pub fn init(api_key: []const u8, allocator: Allocator, io: Io) Self {
        std.debug.assert(api_key.len > 0);
        return .{ .api_key = api_key, .allocator = allocator, .io = io };
    }

    /// Reads `audio_path` off disk and uploads it to OpenAI's
    /// transcription endpoint using `model`. Returns owned text on
    /// success — the caller must `deinit()` the result. Call from a
    /// worker fiber, not the render thread (this blocks on network I/O).
    pub fn transcribeFile(self: *Self, audio_path: []const u8, model: []const u8) TranscriptionResult {
        std.debug.assert(audio_path.len > 0);
        std.debug.assert(model.len > 0);

        const audio_bytes = readAudioFile(self.io, self.allocator, audio_path) catch |e| {
            return switch (e) {
                error.FileTooLarge => TranscriptionResult.err("Recording too large to transcribe (max 24MB)"),
                error.EmptyFile => TranscriptionResult.err("Recording is empty"),
                else => TranscriptionResult.err("Failed to read recording"),
            };
        };
        defer self.allocator.free(audio_bytes);

        return self.doRequest(audio_bytes, model);
    }

    /// Streaming Chat Completions request — emits `"stream": true` and
    /// parses the response as Server-Sent Events, forwarding each content
    /// delta to `sink` as it arrives. Mirrors
    /// `anthropic.AnthropicClient.sendStreaming`'s threading contract
    /// exactly: call from a worker fiber; the sink runs synchronously on
    /// that fiber and must stay brief (copy bytes out, don't touch UI
    /// state directly).
    ///
    /// Text-only: there is no attachment parameter, unlike Anthropic's
    /// `sendStreamingWithFile`. `state.AppState.sendMessage` refuses to
    /// launch this path when a file is attached.
    pub fn sendStreamingChat(self: *Self, request: ChatRequest, sink: StreamSink) ChatResult {
        std.debug.assert(request.messages.len > 0);
        std.debug.assert(request.messages.len <= MAX_CHAT_MESSAGES);

        return self.doChatRequest(request, sink) catch |e| {
            log.err("OpenAI chat streaming request failed: {}", .{e});
            return ChatResult.err("Request failed");
        };
    }

    /// Builds the JSON body once, then drives the shared retry loop —
    /// mirrors `AnthropicClient.doRequest`'s shape.
    fn doChatRequest(self: *Self, request: ChatRequest, sink: StreamSink) !ChatResult {
        // Worst case every content byte needs a 6-byte `\uXXXX` escape,
        // plus fixed per-message JSON overhead (role/content keys, quotes,
        // braces, comma) and a small envelope for `model`/`stream`. This is
        // sized off the actual request rather than a single large fixed
        // buffer (contrast `AnthropicClient.doRequest`, which budgets for
        // multi-megabyte file attachments this client doesn't support).
        var content_bytes: usize = 0;
        for (request.messages) |msg| content_bytes += msg.content.len;
        const total_size = @min(
            MAX_CHAT_REQUEST_SIZE,
            (content_bytes * 6) + (request.messages.len * 64) + 256,
        );
        std.debug.assert(total_size > 0);

        var dynamic_buf: ?[]u8 = null;
        defer if (dynamic_buf) |buf| self.allocator.free(buf);

        var stack_buf: [64 * 1024]u8 = undefined;
        const json_buf: []u8 = if (total_size <= stack_buf.len)
            &stack_buf
        else blk: {
            dynamic_buf = try self.allocator.alloc(u8, total_size);
            break :blk dynamic_buf.?;
        };

        var fbs: Io.Writer = .fixed(json_buf);
        const writer = &fbs;

        // `max_completion_tokens` (not the older `max_tokens`) is the
        // current Chat Completions field name for reasoning-capable chat
        // models — the GPT chat models this client targets fall in that
        // family.
        try writer.print(
            "{{\"model\":\"{s}\",\"max_completion_tokens\":{d},\"stream\":true,\"messages\":[",
            .{ request.model, MAX_CHAT_TOKENS },
        );

        var first = true;
        for (request.messages) |msg| {
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.print("{{\"role\":\"{s}\",\"content\":\"", .{msg.role.apiName()});
            try anthropic.writeJsonEscapedString(writer, msg.content);
            try writer.writeAll("\"}");
        }
        try writer.writeAll("]}");

        const body = fbs.buffered();
        std.debug.assert(body.len > 0);
        std.debug.assert(body.len <= json_buf.len);
        if (LOG_PAYLOADS) log.debug("OpenAI chat request body: {s}", .{body});

        const uri = try Uri.parse(CHAT_API_URL);

        var prng = net.seedBackoffPrng(self.io);
        const ctx = ChatAttemptCtx{
            .self = self,
            .body = body,
            .uri = uri,
            .sink = sink,
        };

        return net.fetchWithRetry(
            ChatResult,
            self.io,
            prng.random(),
            ctx,
            ChatResult.err("Request failed after retries"),
            "OpenAI Chat",
        );
    }

    /// Per-request state captured for retry — same shape as
    /// `AnthropicClient.ChatAttemptCtx`. Body and URI don't depend on
    /// attempt number; the connection state does, so `attempt()` creates a
    /// fresh `http.Client` on each call.
    const ChatAttemptCtx = struct {
        self: *Self,
        body: []u8,
        uri: Uri,
        sink: StreamSink,

        pub fn attempt(c: @This()) Io.Cancelable!net.AttemptOutcome(ChatResult) {
            std.debug.assert(c.self.api_key.len > 0);
            std.debug.assert(c.body.len > 0);

            var authorization_buffer: [600]u8 = undefined;
            const authorization = std.fmt.bufPrint(&authorization_buffer, "Bearer {s}", .{c.self.api_key}) catch {
                return .{ .terminal = ChatResult.err("API key too long") };
            };
            const extra_headers = [_]http_std.Header{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Authorization", .value = authorization },
            };
            const options: net.AttemptOptions = .{
                .io = c.self.io,
                .allocator = c.self.allocator,
                .method = .POST,
                .uri = c.uri,
                .headers = .{ .accept_encoding = .{ .override = "identity" } },
                .extra_headers = &extra_headers,
                .request_body = c.body,
                .request_body_size_max = @intCast(MAX_CHAT_REQUEST_SIZE),
                .expected_status = .ok,
                .label = "OpenAI Chat Completions API",
            };
            return net.performOneHttpAttempt(ChatResult, &options, c);
        }

        pub fn requestFailed(c: @This()) ChatResult {
            std.debug.assert(c.self.api_key.len > 0);
            return ChatResult.err("Failed to build request");
        }

        pub fn receiveHeadFailed(c: @This()) ChatResult {
            std.debug.assert(c.self.api_key.len > 0);
            return ChatResult.err("HTTP receive failed");
        }

        pub fn requestRejected(c: @This(), status: http_std.Status) ChatResult {
            std.debug.assert(c.self.api_key.len > 0);
            std.debug.assert(@intFromEnum(status) >= 400);

            const status_code: u32 = @intFromEnum(status);
            log.err("OpenAI Chat Completions API HTTP {d}", .{status_code});
            const message: []const u8 = switch (status_code) {
                400 => "Bad request",
                401 => "Invalid API key",
                403 => "Forbidden",
                404 => "Not found",
                413 => "Request too large",
                422 => "Unprocessable entity",
                429 => "Rate limited",
                else => "API returned error",
            };
            return ChatResult.err(message);
        }

        pub fn consumeOkResponse(c: @This(), response: *http_std.Client.Response) Io.Cancelable!ChatResult {
            return c.self.consumeChatSseStream(response, c.sink);
        }
    };

    /// Drain a 200 OK response as an SSE stream. Bounded exactly like
    /// `AnthropicClient.consumeOkResponse`'s streaming branch: one line at a
    /// time via `CHAT_SSE_READER_BUF_SIZE`, total accumulated text capped at
    /// `MAX_CHAT_RESPONSE_SIZE`.
    fn consumeChatSseStream(self: *Self, response: *http_std.Client.Response, sink: StreamSink) ChatResult {
        var sse_buf: [CHAT_SSE_READER_BUF_SIZE]u8 = undefined;
        const reader = response.reader(&sse_buf);
        return self.readChatSseStream(reader, sink) catch |e| {
            log.err("OpenAI SSE stream failed: {}", .{e});
            return ChatResult.err("Streaming response failed");
        };
    }

    /// Drive the SSE read loop: reads one line at a time, parses `data:`
    /// lines as Chat Completions stream chunks, and forwards each
    /// `choices[0].delta.content` to `sink` while accumulating it into an
    /// owned buffer for the final `ChatResult`. Terminates on the
    /// `data: [DONE]` sentinel or EOF, whichever comes first.
    fn readChatSseStream(self: *Self, reader: *Io.Reader, sink: StreamSink) !ChatResult {
        var accum: std.Io.Writer.Allocating = .init(self.allocator);
        defer accum.deinit();

        var aborted = false;

        while (true) {
            const line_or_null = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    log.warn("OpenAI SSE line exceeded {d} bytes, dropping", .{CHAT_SSE_READER_BUF_SIZE});
                    drainChatSseLine(reader);
                    continue;
                },
                error.ReadFailed => return ChatResult.err("Streaming read failed"),
            };

            const line = line_or_null orelse break; // EOF
            const trimmed = trimCrChat(line);
            if (trimmed.len == 0) continue;
            if (!std.mem.startsWith(u8, trimmed, "data:")) continue;

            var payload = trimmed["data:".len..];
            if (payload.len > 0 and payload[0] == ' ') payload = payload[1..];
            if (payload.len == 0) continue;

            if (std.mem.eql(u8, payload, "[DONE]")) break;

            const text = parseChatSseDelta(self.allocator, payload) catch |e| {
                // Parse errors are non-fatal: unrecognized chunk shapes
                // (e.g. a `finish_reason`-only trailing chunk with no
                // `content`) are expected, not protocol breaks.
                log.debug("OpenAI SSE event ignored ({t}): {s}", .{ e, payload });
                continue;
            };
            const owned_text = text orelse continue;
            defer self.allocator.free(owned_text);

            if (!aborted) {
                sink.callback(sink.userdata, owned_text) catch |e| switch (e) {
                    error.Aborted => aborted = true,
                };
            }

            const remaining = MAX_CHAT_RESPONSE_SIZE - @min(accum.written().len, MAX_CHAT_RESPONSE_SIZE);
            if (remaining > 0) {
                const to_write = @min(owned_text.len, remaining);
                accum.writer.writeAll(owned_text[0..to_write]) catch
                    return ChatResult.err("Out of memory accumulating stream");
            }
        }

        const final_text = accum.toOwnedSlice() catch
            return ChatResult.err("Out of memory finalizing stream");

        if (final_text.len == 0) {
            self.allocator.free(final_text);
            return ChatResult.err("Empty streaming response");
        }

        if (LOG_PAYLOADS) log.debug("OpenAI SSE final ({d} bytes): {s}", .{ final_text.len, final_text });
        return ChatResult.success(final_text);
    }

    /// Builds the multipart body once (not per retry attempt — the audio
    /// bytes can be megabytes and re-encoding per retry would waste both
    /// CPU and memory), then drives the shared retry loop.
    fn doRequest(self: *Self, audio_bytes: []const u8, model: []const u8) TranscriptionResult {
        std.debug.assert(model.len > 0);
        std.debug.assert(model.len <= MAX_MODEL_NAME_LEN);

        // Generous fixed overhead for the two multipart headers + footer
        // (well above the ~270 bytes the current template actually needs) —
        // cheap insurance against a future template tweak silently
        // overflowing the buffer. Sized off `MAX_MODEL_NAME_LEN` (not
        // `model.len`) so the buffer's capacity doesn't vary by which
        // model the user picked.
        const header_size_estimate = 512 + MAX_MODEL_NAME_LEN;
        const total_size = header_size_estimate + audio_bytes.len;

        const body_buf = self.allocator.alloc(u8, total_size) catch {
            return TranscriptionResult.err("Failed to allocate transcription request buffer");
        };
        defer self.allocator.free(body_buf);

        var fbs: Io.Writer = .fixed(body_buf);
        writeMultipartBody(&fbs, model, audio_bytes) catch {
            return TranscriptionResult.err("Failed to build transcription request");
        };
        const body = fbs.buffered();

        if (LOG_PAYLOADS) {
            log.debug("OpenAI transcription request: {d} bytes", .{body.len});
        }

        const uri = Uri.parse(TRANSCRIPTION_API_URL) catch {
            return TranscriptionResult.err("Failed to parse transcription API URL");
        };

        var prng = net.seedBackoffPrng(self.io);
        const ctx = TranscribeAttemptCtx{
            .io = self.io,
            .allocator = self.allocator,
            .api_key = self.api_key,
            .uri = uri,
            .body = body,
        };

        return net.fetchWithRetry(
            TranscriptionResult,
            self.io,
            prng.random(),
            ctx,
            TranscriptionResult.err("Transcription failed after retries"),
            "OpenAI",
        ) catch TranscriptionResult.err("Transcription cancelled");
    }
};

// =============================================================================
// Chat Completions SSE helpers
// =============================================================================

/// SSE chunk payload shape from `/v1/chat/completions` with `"stream":
/// true`. `ignore_unknown_fields` lets the parser skip everything else
/// (`id`, `created`, `model`, `finish_reason`, ...) without spelling it out.
const ChatSseDelta = struct {
    content: ?[]const u8 = null,
};

const ChatSseChoice = struct {
    delta: ?ChatSseDelta = null,
};

const ChatSseEvent = struct {
    choices: []const ChatSseChoice = &.{},
};

/// Parse one `data:` payload from the Chat Completions SSE stream. Returns
/// an owned copy of the delta text, or `null` when the chunk carries no
/// content (e.g. the role-announcing first chunk, or a trailing chunk that
/// only sets `finish_reason`). Bounded by `MAX_CHAT_DELTA_TEXT_LEN`, same
/// rationale as `anthropic.parseSseTextDelta`.
fn parseChatSseDelta(allocator: Allocator, payload: []const u8) !?[]const u8 {
    std.debug.assert(payload.len > 0);

    const parsed = try std.json.parseFromSlice(ChatSseEvent, allocator, payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) return null;
    const delta = parsed.value.choices[0].delta orelse return null;
    const text = delta.content orelse return null;
    if (text.len == 0) return null;

    const len = @min(text.len, MAX_CHAT_DELTA_TEXT_LEN);
    return try allocator.dupe(u8, text[0..len]);
}

/// After `error.StreamTooLong`, the reader buffer is full with no newline
/// found. Drain buffered bytes and resync to the next newline (or EOF).
/// Mirrors `anthropic.drainSseLine` exactly.
fn drainChatSseLine(reader: *Io.Reader) void {
    reader.tossBuffered();
    while (true) {
        _ = reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                reader.tossBuffered();
                continue;
            },
            error.ReadFailed => return,
        };
        return;
    }
}

/// Trim a trailing '\r'. Mirrors `anthropic.trimCr` exactly.
fn trimCrChat(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

/// Writes the two-part (`model`, `file`) multipart/form-data body.
/// `writer` must be backed by a buffer already sized for
/// `512 + MAX_MODEL_NAME_LEN + audio_bytes.len` bytes (see `doRequest`).
fn writeMultipartBody(writer: *Io.Writer, model: []const u8, audio_bytes: []const u8) !void {
    std.debug.assert(model.len > 0);
    std.debug.assert(audio_bytes.len > 0);

    try writer.print(
        "--{s}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n{s}\r\n",
        .{ MULTIPART_BOUNDARY, model },
    );
    try writer.print(
        "--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n",
        .{MULTIPART_BOUNDARY},
    );
    try writer.writeAll(audio_bytes);
    try writer.print("\r\n--{s}--\r\n", .{MULTIPART_BOUNDARY});
}

/// Per-request state captured for retry. Body and URI don't depend on
/// attempt number; the connection state does, so `attempt()` creates a
/// fresh `http.Client` on each call — same shape as
/// `http.UploadAttemptCtx`.
const TranscribeAttemptCtx = struct {
    io: Io,
    allocator: Allocator,
    api_key: []const u8,
    uri: Uri,
    body: []u8,

    pub fn attempt(c: @This()) Io.Cancelable!net.AttemptOutcome(TranscriptionResult) {
        std.debug.assert(c.api_key.len > 0);
        std.debug.assert(c.body.len > 0);

        var authorization_buffer: [600]u8 = undefined;
        const authorization = std.fmt.bufPrint(&authorization_buffer, "Bearer {s}", .{c.api_key}) catch {
            return .{ .terminal = TranscriptionResult.err("API key too long") };
        };
        const extra_headers = [_]http_std.Header{
            .{ .name = "Content-Type", .value = "multipart/form-data; boundary=" ++ MULTIPART_BOUNDARY },
            .{ .name = "Authorization", .value = authorization },
        };
        const options: net.AttemptOptions = .{
            .io = c.io,
            .allocator = c.allocator,
            .method = .POST,
            .uri = c.uri,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = &extra_headers,
            .request_body = c.body,
            .request_body_size_max = @intCast(MAX_AUDIO_FILE_SIZE + 1024),
            .expected_status = .ok,
            .label = "OpenAI transcription",
        };
        return net.performOneHttpAttempt(TranscriptionResult, &options, c);
    }

    pub fn requestFailed(c: @This()) TranscriptionResult {
        std.debug.assert(c.api_key.len > 0);
        std.debug.assert(c.body.len > 0);
        return TranscriptionResult.err("Failed to create transcription request");
    }

    pub fn receiveHeadFailed(c: @This()) TranscriptionResult {
        std.debug.assert(c.api_key.len > 0);
        std.debug.assert(c.body.len > 0);
        return TranscriptionResult.err("Failed to receive transcription response");
    }

    pub fn requestRejected(c: @This(), status: http_std.Status) TranscriptionResult {
        std.debug.assert(c.api_key.len > 0);
        std.debug.assert(@intFromEnum(status) >= 400);
        log.err("OpenAI transcription HTTP {d}", .{@intFromEnum(status)});
        return TranscriptionResult.err("Transcription request rejected");
    }

    pub fn consumeOkResponse(c: @This(), response: *http_std.Client.Response) Io.Cancelable!TranscriptionResult {
        std.debug.assert(c.api_key.len > 0);
        std.debug.assert(c.body.len > 0);

        const response_data = net.readBoundedResponse(
            c.allocator,
            response,
            @intCast(MAX_RESPONSE_SIZE),
        ) catch return TranscriptionResult.err("Failed to read transcription response");
        defer c.allocator.free(response_data);

        if (LOG_PAYLOADS) log.debug("OpenAI transcription response: {s}", .{response_data});
        const text = parseTranscriptText(c.allocator, response_data) catch {
            log.err("Failed to parse transcription response: {s}", .{response_data});
            return TranscriptionResult.err("Failed to parse transcription response");
        };
        return TranscriptionResult.success(text);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "TranscriptionResult lifecycle" {
    const allocator = std.testing.allocator;

    const owned = try allocator.dupe(u8, "hello world");
    var success_result = TranscriptionResult.success(owned);
    try std.testing.expect(success_result.isSuccess());
    try std.testing.expectEqualStrings("hello world", success_result.getText().?);
    success_result.deinit(allocator);

    var err_result = TranscriptionResult.err("boom");
    try std.testing.expect(!err_result.isSuccess());
    try std.testing.expect(err_result.getText() == null);
    err_result.deinit(allocator); // no-op: not owned
}

test "parseTranscriptText extracts text content" {
    const allocator = std.testing.allocator;
    const json = "{\"text\":\"hello from whisper\"}";

    const text = try parseTranscriptText(allocator, json);
    defer allocator.free(text);

    try std.testing.expectEqualStrings("hello from whisper", text);
}

test "parseTranscriptText rejects empty text" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.EmptyText, parseTranscriptText(allocator, "{\"text\":\"\"}"));
}

test "parseTranscriptText surfaces malformed JSON" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.JsonParseError, parseTranscriptText(allocator, "not json"));
}

test "parseTranscriptText truncates oversized text to MAX_TEXT_LEN" {
    const allocator = std.testing.allocator;

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeAll("{\"text\":\"");
    try buf.writer.splatByteAll('a', MAX_TEXT_LEN + 100);
    try buf.writer.writeAll("\"}");

    const text = try parseTranscriptText(allocator, buf.written());
    defer allocator.free(text);

    try std.testing.expectEqual(MAX_TEXT_LEN, text.len);
}

test "writeMultipartBody includes model, filename, and audio bytes" {
    var buf: [512]u8 = undefined;
    var fbs: Io.Writer = .fixed(&buf);
    const audio_bytes = "RIFF....WAVEfmt ";

    try writeMultipartBody(&fbs, DEFAULT_TRANSCRIBE_MODEL, audio_bytes);
    const body = fbs.buffered();

    try std.testing.expect(std.mem.indexOf(u8, body, MULTIPART_BOUNDARY) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, DEFAULT_TRANSCRIBE_MODEL) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "filename=\"recording.wav\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Content-Type: audio/wav") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, audio_bytes) != null);
    try std.testing.expect(std.mem.endsWith(u8, body, "--" ++ MULTIPART_BOUNDARY ++ "--\r\n"));
}

test "ChatResult lifecycle" {
    const allocator = std.testing.allocator;

    const owned = try allocator.dupe(u8, "hello from gpt");
    var success_result = ChatResult.success(owned);
    try std.testing.expect(success_result.isSuccess());
    try std.testing.expectEqualStrings("hello from gpt", success_result.getText().?);
    success_result.deinit(allocator);

    var err_result = ChatResult.err("boom");
    try std.testing.expect(!err_result.isSuccess());
    try std.testing.expect(err_result.getText() == null);
    err_result.deinit(allocator); // no-op: not owned
}

test "parseChatSseDelta extracts content text" {
    const allocator = std.testing.allocator;
    const payload =
        "{\"id\":\"chatcmpl-1\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}";

    const text = try parseChatSseDelta(allocator, payload);
    defer allocator.free(text.?);

    try std.testing.expectEqualStrings("Hello", text.?);
}

test "parseChatSseDelta returns null for role-announcing and finish chunks" {
    const allocator = std.testing.allocator;

    // First chunk of a stream: announces the role, no content yet.
    const role_chunk = "{\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"},\"finish_reason\":null}]}";
    try std.testing.expectEqual(@as(?[]const u8, null), try parseChatSseDelta(allocator, role_chunk));

    // Trailing chunk: empty delta, finish_reason set.
    const finish_chunk = "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}";
    try std.testing.expectEqual(@as(?[]const u8, null), try parseChatSseDelta(allocator, finish_chunk));
}

test "parseChatSseDelta truncates oversized content to MAX_CHAT_DELTA_TEXT_LEN" {
    const allocator = std.testing.allocator;

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeAll("{\"choices\":[{\"delta\":{\"content\":\"");
    try buf.writer.splatByteAll('a', MAX_CHAT_DELTA_TEXT_LEN + 100);
    try buf.writer.writeAll("\"}}]}");

    const text = try parseChatSseDelta(allocator, buf.written());
    defer allocator.free(text.?);

    try std.testing.expectEqual(MAX_CHAT_DELTA_TEXT_LEN, text.?.len);
}

test "ChatRole.apiName maps every role" {
    try std.testing.expectEqualStrings("system", ChatRole.system.apiName());
    try std.testing.expectEqualStrings("user", ChatRole.user.apiName());
    try std.testing.expectEqualStrings("assistant", ChatRole.assistant.apiName());
}
