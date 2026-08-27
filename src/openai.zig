//! OpenAI HTTP Client — audio transcription only.
//!
//! Scope is intentionally narrow: turn a just-finished recording (a WAV
//! file on disk) into text via OpenAI's `/v1/audio/transcriptions`
//! endpoint. The model is chosen by the caller (see `DEFAULT_TRANSCRIBE_MODEL`
//! and the `DictationModel` picker in `state.zig`) rather than hardcoded
//! here, since OpenAI offers several transcription models with different
//! speed/accuracy/cost tradeoffs.
//!
//! Shares its retry/backoff/HTTP-error-classification plumbing with
//! `http.zig` (`fetchWithRetry`, `classifyHttpStatus`, etc. — made `pub`
//! there for this purpose) rather than duplicating it: both clients retry
//! against the same shape of transient failure (connect/TLS drops,
//! 429/5xx), so the policy belongs in one place.
//!
//! Usage:
//!   var client = OpenAIClient.init(api_key, allocator, io);
//!   var result = client.transcribeFile(audio_path, DEFAULT_TRANSCRIBE_MODEL);
//!   defer result.deinit(allocator);
//!   switch (result.status) {
//!       .success => |text| { ... },
//!       .err => |msg| { ... },
//!   }

const std = @import("std");
const log = std.log.scoped(.chatzig);
const http_std = std.http;
const Uri = std.Uri;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const net = @import("http.zig");

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
        var client = http_std.Client{ .allocator = c.allocator, .io = c.io };
        defer client.deinit();

        var auth_buf: [600]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{c.api_key}) catch {
            return .{ .terminal = TranscriptionResult.err("API key too long") };
        };

        var req = client.request(.POST, c.uri, .{
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "multipart/form-data; boundary=" ++ MULTIPART_BOUNDARY },
                .{ .name = "Authorization", .value = auth_header },
            },
        }) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return switch (net.classifyRequestError(err)) {
                error.Transient => .{ .transient = null },
                error.Permanent => .{ .terminal = TranscriptionResult.err("Failed to create transcription request") },
            };
        };
        defer req.deinit();

        req.sendBodyComplete(c.body) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return .{ .transient = null };
        };

        return receiveResponse(c, &req);
    }
};

/// Handles the receive-head / status-check / body-read half of one
/// attempt. Split out of `TranscribeAttemptCtx.attempt` to keep that
/// function focused on request construction (CLAUDE rule #5 — 70-line
/// function limit).
fn receiveResponse(c: TranscribeAttemptCtx, req: *http_std.Client.Request) Io.Cancelable!net.AttemptOutcome(TranscriptionResult) {
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        return switch (net.classifyReceiveHeadError(err)) {
            error.Transient => .{ .transient = null },
            error.Permanent => .{ .terminal = TranscriptionResult.err("Failed to receive transcription response") },
        };
    };

    if (response.head.status != .ok) {
        const status_code: u32 = @intFromEnum(response.head.status);
        log.err("OpenAI transcription HTTP {d}", .{status_code});
        switch (net.classifyHttpStatus(response.head.status)) {
            error.Transient => {
                const retry_after_s = net.parseRetryAfterFromHead(response.head);
                if (retry_after_s) |s| log.info("OpenAI Retry-After: {d}s", .{s});
                return .{ .transient = retry_after_s };
            },
            error.Permanent => return .{ .terminal = TranscriptionResult.err("Transcription request rejected") },
        }
    }

    var transfer_buf: [64]u8 = undefined;
    var reader = response.reader(&transfer_buf);
    const response_data = reader.allocRemaining(c.allocator, Io.Limit.limited(MAX_RESPONSE_SIZE)) catch {
        return .{ .terminal = TranscriptionResult.err("Failed to read transcription response") };
    };
    defer c.allocator.free(response_data);

    if (LOG_PAYLOADS) {
        log.debug("OpenAI transcription response: {s}", .{response_data});
    }

    const text = parseTranscriptText(c.allocator, response_data) catch {
        log.err("Failed to parse transcription response: {s}", .{response_data});
        return .{ .terminal = TranscriptionResult.err("Failed to parse transcription response") };
    };

    return .{ .terminal = TranscriptionResult.success(text) };
}

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
