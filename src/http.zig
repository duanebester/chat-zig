//! Anthropic HTTP Client
//!
//! Pure HTTP client for Anthropic's Messages API.
//! No framework dependencies - just takes a request and returns a result.
//!
//! Supports:
//! - Text messages
//! - Image attachments (base64 encoded)
//! - Text file attachments (inline content)
//!
//! Usage:
//!   var client = AnthropicClient.init(api_key, allocator);
//!   const result = client.sendBlocking(request);
//!   defer result.deinit(allocator);
//!   switch (result.status) {
//!       .success => |text| { ... },
//!       .err => |msg| { ... },
//!   }

const std = @import("std");
const log = std.log.scoped(.chatzig);
const http = std.http;
const Uri = std.Uri;
const Io = std.Io;
const Allocator = std.mem.Allocator;

// =============================================================================
// Constants
// =============================================================================

const API_URL = "https://api.anthropic.com/v1/messages";
const FILES_API_URL = "https://api.anthropic.com/v1/files";
const MAX_TOKENS: u32 = 4096;
const MAX_RESPONSE_SIZE: usize = 1024 * 1024; // 1MB
const MAX_REQUEST_SIZE: usize = 8 * 1024 * 1024; // 8MB for image attachments
const LOG_PAYLOADS: bool = false;
pub const MAX_MESSAGES: usize = 256;
pub const MAX_FILE_SIZE: usize = 5 * 1024 * 1024; // 5MB max file size
pub const MAX_FILE_ID_LEN: usize = 128; // Max length for file IDs from Files API

/// Per-line buffer for the SSE reader. Anthropic `text_delta` events are
/// typically a few hundred bytes; 16 KiB gives generous headroom for any
/// single `data:` line (including the JSON envelope) without being
/// wasteful. Lines longer than this are dropped via `tossBuffered` —
/// the `gooey/src/examples/ai_canvas.zig` line reader uses the same
/// pattern. CLAUDE rule #4 (put a limit on everything) applies here.
pub const SSE_READER_BUF_SIZE: usize = 16 * 1024;

/// Maximum length of any single `text_delta` chunk we will copy out of
/// the parsed JSON. Bounded so a hostile / buggy server cannot cause an
/// unbounded `dupe()`. Picked to comfortably exceed the 16 KiB reader
/// buffer so it never trips on legitimate traffic.
pub const MAX_DELTA_TEXT_LEN: usize = 32 * 1024;

/// Maximum HTTP-request attempts before surfacing a terminal error.
/// Anthropic's docs explicitly call out 429 (rate_limit_error) and 529
/// (overloaded_error) as retry-worthy, with exponential backoff
/// recommended; 4xx other than 408/429 are deterministic and never
/// improve on retry. Capped low (3) so worst-case wall-clock to surface
/// a final error stays inside ~3.5s — same budget as
/// `gooey/src/image/loader.zig`. Tunable policy belongs higher in the
/// stack, not here.
pub const MAX_FETCH_ATTEMPTS: u32 = 3;

/// Base backoff before the second attempt. Doubled on each subsequent
/// attempt: 500ms, 1s, 2s. `u64` matches the shift operand below.
pub const BASE_BACKOFF_MS: u64 = 500;

/// ±JITTER_PERCENT of the base backoff is added on each retry. Prevents
/// thundering-herd retry storms when many clients fail simultaneously
/// (Anthropic 529 overload typically clears in waves, not one client at
/// a time).
pub const JITTER_PERCENT: u64 = 25;

/// Maximum `Retry-After` value we honor, in seconds. Caps a misbehaving
/// (or hostile) server from pinning us indefinitely. 60s is well above
/// any plausible Anthropic queueing delay.
pub const MAX_RETRY_AFTER_SECS: u64 = 60;

// =============================================================================
// Request Types (Framework-agnostic)
// =============================================================================

pub const ChatRole = enum {
    user,
    assistant,

    pub fn apiName(self: ChatRole) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
        };
    }
};

/// Content block types for multimodal messages
pub const ContentBlock = union(enum) {
    text: []const u8,
    image: ImageContent,
};

pub const ImageContent = struct {
    media_type: []const u8,
    data: []const u8, // base64 encoded
};

pub const ChatMessage = struct {
    role: ChatRole,
    /// Simple text content (for backwards compatibility)
    content: ?[]const u8 = null,
    /// Content blocks for multimodal messages (images + text)
    content_blocks: ?[]const ContentBlock = null,

    /// Create a simple text message
    pub fn text(role: ChatRole, txt: []const u8) ChatMessage {
        return .{ .role = role, .content = txt };
    }

    /// Create a multimodal message with content blocks
    pub fn multimodal(role: ChatRole, blocks: []const ContentBlock) ChatMessage {
        return .{ .role = role, .content_blocks = blocks };
    }
};

/// File attachment with its content
pub const FileAttachment = struct {
    path: []const u8,
    content: []const u8,
    media_type: []const u8,
    is_image: bool,
    is_pdf: bool,
    /// File ID from Files API (for PDFs) - null if not uploaded yet
    file_id: ?[]const u8 = null,
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []const ChatMessage,
    /// Optional file attachment (will be added to the last user message)
    attachment: ?FileAttachment = null,
};

/// Callback invoked from the HTTP fiber for each `text_delta` chunk parsed
/// from an SSE stream. Returning `error.Aborted` from the callback short-
/// circuits the read loop — useful when the consumer's staging buffer is
/// full and there is no point reading further.
///
/// The `text` slice is borrowed from the SSE reader's internal buffer and
/// is only valid for the duration of the call. Callbacks must copy the
/// bytes they want to keep (typically into a staging buffer behind a
/// happens-before edge such as `Io.Queue.putOne`).
///
/// `userdata` is the opaque pointer the caller passed alongside `callback`
/// — the SSE loop never inspects it. Callbacks that don't need state can
/// pass `undefined` and ignore the parameter.
pub const StreamSink = struct {
    pub const Error = error{Aborted};

    userdata: *anyopaque,
    callback: *const fn (userdata: *anyopaque, text: []const u8) Error!void,
};

// =============================================================================
// File Handling
// =============================================================================

/// Get MIME type from file extension
pub fn getMimeType(path: []const u8) []const u8 {
    // Find extension
    var ext_start: usize = path.len;
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '.') {
            ext_start = i + 1;
            break;
        }
        if (path[i] == '/') break;
    }

    if (ext_start >= path.len) return "application/octet-stream";

    const ext = path[ext_start..];

    // Image types
    if (eqlIgnoreCase(ext, "jpg") or eqlIgnoreCase(ext, "jpeg")) return "image/jpeg";
    if (eqlIgnoreCase(ext, "png")) return "image/png";
    if (eqlIgnoreCase(ext, "gif")) return "image/gif";
    if (eqlIgnoreCase(ext, "webp")) return "image/webp";

    // Text types
    if (eqlIgnoreCase(ext, "txt")) return "text/plain";
    if (eqlIgnoreCase(ext, "md")) return "text/markdown";
    if (eqlIgnoreCase(ext, "json")) return "application/json";
    if (eqlIgnoreCase(ext, "csv")) return "text/csv";

    // Document types
    if (eqlIgnoreCase(ext, "pdf")) return "application/pdf";

    return "application/octet-stream";
}

/// Check if MIME type is an image
pub fn isImageMimeType(mime_type: []const u8) bool {
    return std.mem.startsWith(u8, mime_type, "image/");
}

/// Check if MIME type is a supported text file
pub fn isTextMimeType(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "text/plain") or
        std.mem.eql(u8, mime_type, "text/markdown") or
        std.mem.eql(u8, mime_type, "text/csv") or
        std.mem.eql(u8, mime_type, "application/json");
}

/// Check if MIME type is a PDF (requires Files API)
pub fn isPdfMimeType(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "application/pdf");
}

/// Check if file type is supported for attachment
pub fn isSupportedFileType(mime_type: []const u8) bool {
    return isImageMimeType(mime_type) or isTextMimeType(mime_type) or isPdfMimeType(mime_type);
}

/// Case-insensitive string comparison
fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

/// Read a file and prepare it as an attachment.
///
/// Zig 0.16 note: filesystem access now flows through `std.Io` — `Dir`, `File`,
/// and `File.Reader` all require an `Io` instance. We take one here rather than
/// reaching for a global; the caller (AnthropicClient) already owns one.
pub fn readFileAttachment(io: Io, allocator: Allocator, path: []const u8) !FileAttachment {
    const mime_type = getMimeType(path);

    // Check if file type is supported
    if (!isSupportedFileType(mime_type)) {
        log.err("Unsupported file type: {s} (only images, text files, and PDFs are supported)", .{mime_type});
        return error.UnsupportedFileType;
    }

    const file = Io.Dir.openFileAbsolute(io, path, .{}) catch |e| {
        log.err("Failed to open file {s}: {}", .{ path, e });
        return error.FileOpenFailed;
    };
    defer file.close(io);

    const stat = file.stat(io) catch |e| {
        log.err("Failed to stat file: {}", .{e});
        return error.FileStatFailed;
    };

    if (stat.size > MAX_FILE_SIZE) {
        log.err("File too large: {} bytes (max {})", .{ stat.size, MAX_FILE_SIZE });
        return error.FileTooLarge;
    }

    // Drain the file through a `File.Reader` into an allocated buffer, bounded
    // by MAX_FILE_SIZE. The 4 KiB stack buffer is the transfer window used by
    // the Reader's internal `drain`/`read` implementation — it is not an upper
    // bound on the returned slice.
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const content = file_reader.interface.allocRemaining(
        allocator,
        Io.Limit.limited(MAX_FILE_SIZE),
    ) catch |e| {
        log.err("Failed to read file: {}", .{e});
        return error.FileReadFailed;
    };

    const is_image = isImageMimeType(mime_type);
    const is_pdf = isPdfMimeType(mime_type);

    // Validate text files are valid UTF-8 (skip for images and PDFs which are binary)
    if (!is_image and !is_pdf) {
        if (!std.unicode.utf8ValidateSlice(content)) {
            log.err("Text file is not valid UTF-8", .{});
            allocator.free(content);
            return error.InvalidUtf8;
        }
    }

    return .{
        .path = path,
        .content = content,
        .media_type = mime_type,
        .is_image = is_image,
        .is_pdf = is_pdf,
    };
}

/// Base64 encoding for images
const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64Encode(allocator: Allocator, data: []const u8) ![]const u8 {
    const encoded_len = ((data.len + 2) / 3) * 4;
    const result = try allocator.alloc(u8, encoded_len);

    var i: usize = 0;
    var j: usize = 0;

    while (i + 2 < data.len) {
        const b0 = data[i];
        const b1 = data[i + 1];
        const b2 = data[i + 2];

        result[j] = base64_alphabet[b0 >> 2];
        result[j + 1] = base64_alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        result[j + 2] = base64_alphabet[((b1 & 0x0F) << 2) | (b2 >> 6)];
        result[j + 3] = base64_alphabet[b2 & 0x3F];

        i += 3;
        j += 4;
    }

    // Handle remaining bytes
    const remaining = data.len - i;
    if (remaining == 1) {
        const b0 = data[i];
        result[j] = base64_alphabet[b0 >> 2];
        result[j + 1] = base64_alphabet[(b0 & 0x03) << 4];
        result[j + 2] = '=';
        result[j + 3] = '=';
    } else if (remaining == 2) {
        const b0 = data[i];
        const b1 = data[i + 1];
        result[j] = base64_alphabet[b0 >> 2];
        result[j + 1] = base64_alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        result[j + 2] = base64_alphabet[(b1 & 0x0F) << 2];
        result[j + 3] = '=';
    }

    return result;
}

// =============================================================================
// Retry / Backoff
// =============================================================================
//
// HTTP fetch with bounded exponential backoff, jitter, and `Retry-After`
// header support. Mirrors `gooey/src/image/loader.zig`, with two
// chat-specific differences:
//
//   1. Generic over the result type T — both the chat completion
//      (`ChatResult`) and the Files-API upload (`FileUploadResult`)
//      flow through the same retry loop.
//   2. Honors `Retry-After` (RFC 7231 § 7.1.3, seconds form). Anthropic
//      may include this header on 429 / 503 / 529; ignoring it would be
//      bad citizenship and may further deprioritize our requests.
//
// Retry boundary: pre-stream only. Once `receiveHead` returns 200 and
// we hand off to the SSE loop, any failure is terminal — replaying the
// user turn after partial output would create a confusing UX (text
// appears, vanishes, reappears differently).
//
// Cancellation: `io.sleep` propagates `error.Canceled` so the Stop
// button stays responsive even during a long backoff. The worker
// unwinds cleanly without an extra wakeup mechanism.

/// Classification of HTTP / network failure — drives retry decisions.
/// Split from the underlying Zig error sets so the loop has a single,
/// tiny enum to switch on rather than re-classifying dozens of errors.
pub const FetchError = error{
    /// Transient: safe to retry. HTTP 408/429/5xx, connect/TLS failure,
    /// truncated read, write-during-send. The same request, replayed,
    /// has a real chance of succeeding.
    Transient,
    /// Permanent: retrying cannot help. HTTP 4xx (other than 408/429),
    /// malformed URL, OOM, unsupported scheme, decode error.
    Permanent,
};

/// Outcome of one attempt of an HTTP request.
///
/// `terminal` means "stop retrying and return this T" — covers both
/// success and definitive failure (e.g., 200 stream consumed, 400 Bad
/// Request, 401 invalid key). `transient` means "wait and retry", with
/// an optional `Retry-After` seconds override extracted from the
/// response header.
pub fn AttemptOutcome(comptime T: type) type {
    return union(enum) {
        terminal: T,
        transient: ?u64,
    };
}

/// Classify an HTTP status code. Anthropic-specific codes are folded
/// in: 429 (rate_limit_error) and 529 (overloaded_error). 408 (request
/// timeout) is also retried — almost always a transient client/server
/// desync. 4xx other than 408/429 are permanent (bad request, auth,
/// payload-too-large, etc.); 5xx other than 529 is transient.
pub fn classifyHttpStatus(status: http.Status) FetchError {
    // 529 is inside 500..599 — list it in the comment, not the match,
    // so the switch has no duplicate values.
    return switch (@intFromEnum(status)) {
        408, 429 => error.Transient,
        // 5xx (including Anthropic's 529 overloaded_error) — server is
        // recovering, retrying typically helps.
        500...599 => error.Transient,
        else => error.Permanent,
    };
}

/// Classify errors returned by `http.Client.request()`. OOM and
/// programmer-error variants (unsupported URI scheme) are permanent;
/// connect/DNS/TLS failures are transient.
pub fn classifyRequestError(err: anyerror) FetchError {
    return switch (err) {
        error.OutOfMemory,
        error.UnsupportedUriScheme,
        error.UriMissingHost,
        error.CertificateBundleLoadFailure,
        => error.Permanent,
        // ConnectionRefused, TemporaryNameServerFailure, NetworkUnreachable,
        // TlsInitializationFailed, etc. — transient by nature.
        else => error.Transient,
    };
}

/// Classify errors returned by `Request.receiveHead()`. Malformed HTTP
/// and redirect-shape errors are deterministic protocol breakage — the
/// server won't suddenly start speaking HTTP correctly on retry.
pub fn classifyReceiveHeadError(err: anyerror) FetchError {
    return switch (err) {
        error.HttpHeadersInvalid,
        error.TooManyHttpRedirects,
        error.RedirectRequiresResend,
        error.HttpRedirectLocationMissing,
        error.HttpRedirectLocationOversize,
        error.HttpRedirectLocationInvalid,
        error.HttpContentEncodingUnsupported,
        error.HttpChunkInvalid,
        error.HttpChunkTruncated,
        error.HttpHeadersOversize,
        error.UnsupportedUriScheme,
        error.OutOfMemory,
        error.CertificateBundleLoadFailure,
        => error.Permanent,
        // ReadFailed, WriteFailed, connection drops — transient.
        else => error.Transient,
    };
}

/// Parse an RFC 7231 § 7.1.3 `Retry-After` header value. Only the
/// integer-seconds form is supported; the HTTP-date form returns null
/// and callers fall back to the exponential backoff. Anthropic emits
/// seconds, so this is sufficient in practice.
fn parseRetryAfterSeconds(value: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
}

/// Extract the first `Retry-After` header from a response head. Header
/// names are case-insensitive per RFC 7230; Anthropic emits lowercase
/// `retry-after` but we don't rely on that. Returns null if missing or
/// unparseable. Must be called BEFORE `response.reader()` since that
/// invalidates the head's slices.
pub fn parseRetryAfterFromHead(head: http.Client.Response.Head) ?u64 {
    var it = head.iterateHeaders();
    while (it.next()) |hdr| {
        if (eqlIgnoreCase(hdr.name, "retry-after")) {
            return parseRetryAfterSeconds(hdr.value);
        }
    }
    return null;
}

/// Compute the backoff sleep, in milliseconds. Pure function — split
/// out so the retry loop stays focused on control flow. The
/// `Retry-After` override is treated as a floor: we use
/// `max(retry_after, exp_jittered)` so the header lengthens our wait
/// when the server explicitly asked for it, but we never shorten the
/// jittered backoff.
pub fn computeBackoffMs(attempt: u32, retry_after_s: ?u64, rng: std.Random) i64 {
    std.debug.assert(attempt < 63);
    const base_ms: u64 = BASE_BACKOFF_MS << @as(u6, @intCast(attempt));

    // Symmetric jitter in [-JITTER_PERCENT%, +JITTER_PERCENT%].
    const jitter_range_ms: u64 = base_ms * JITTER_PERCENT / 100;
    const jitter_signed: i64 = rng.intRangeAtMost(
        i64,
        -@as(i64, @intCast(jitter_range_ms)),
        @as(i64, @intCast(jitter_range_ms)),
    );
    const exp_ms: i64 = @as(i64, @intCast(base_ms)) + jitter_signed;
    // base_ms ≥ 500, jitter ≤ ±125 on attempt 0 — plenty above zero.
    // Assert so a future tweak to constants trips here instead of
    // panicking inside Duration.
    std.debug.assert(exp_ms > 0);

    if (retry_after_s) |secs| {
        const capped: u64 = @min(secs, MAX_RETRY_AFTER_SECS);
        const retry_ms: i64 = @as(i64, @intCast(capped)) * 1000;
        return @max(retry_ms, exp_ms);
    }
    return exp_ms;
}

/// Bounded exponential backoff with jitter and `Retry-After` override.
///
/// `ctx` must expose an `attempt(self) Io.Cancelable!AttemptOutcome(T)`
/// method. The helper drives the retry loop, sleeping between attempts
/// via `io.sleep(.., .awake)` (monotonic clock — backoff timing must
/// not jump when the wall clock is adjusted by NTP or a sysadmin).
/// On exhaustion all attempts return `give_up`.
///
/// Cancellation: `error.Canceled` propagates from either the attempt
/// itself (via `try`) or the backoff sleep, unwinding cleanly to the
/// worker. The Stop button stays responsive throughout.
pub fn fetchWithRetry(
    comptime T: type,
    io: Io,
    rng: std.Random,
    ctx: anytype,
    give_up: T,
    label: []const u8,
) Io.Cancelable!T {
    comptime std.debug.assert(MAX_FETCH_ATTEMPTS > 0);
    std.debug.assert(label.len > 0);

    var attempt: u32 = 0;
    while (attempt < MAX_FETCH_ATTEMPTS) : (attempt += 1) {
        switch (try ctx.attempt()) {
            .terminal => |v| return v,
            .transient => |retry_after_s| {
                // Last attempt — sleeping just to give up wastes time.
                if (attempt + 1 >= MAX_FETCH_ATTEMPTS) {
                    log.info(
                        "{s} request: transient failure on final attempt {d}/{d}, giving up",
                        .{ label, attempt + 1, MAX_FETCH_ATTEMPTS },
                    );
                    return give_up;
                }

                const sleep_ms = computeBackoffMs(attempt, retry_after_s, rng);
                log.info(
                    "{s} request: transient failure on attempt {d}/{d}, backing off {d}ms{s}",
                    .{
                        label,
                        attempt + 1,
                        MAX_FETCH_ATTEMPTS,
                        sleep_ms,
                        if (retry_after_s != null) " (Retry-After honored)" else "",
                    },
                );

                try io.sleep(Io.Duration.fromMilliseconds(sleep_ms), .awake);
            },
        }
    }
    // Loop exits only via explicit return — the final iteration either
    // returned a terminal value or returned `give_up`.
    unreachable;
}

/// Seed a PRNG from the monotonic clock for backoff jitter. Chat
/// requests don't have a stable identity (unlike image URLs in
/// `gooey/src/image/loader.zig`), so we use a fresh timestamp seed
/// per call. Determinism per-call is not a requirement — independence
/// across concurrent retries is.
pub fn seedBackoffPrng(io: Io) std.Random.DefaultPrng {
    const ts = Io.Clock.Timestamp.now(io, .awake);
    const nanos: i96 = ts.raw.toNanoseconds();
    const seed: u64 = @bitCast(@as(i64, @truncate(nanos)));
    return std.Random.DefaultPrng.init(seed);
}

// =============================================================================
// Files API (for PDF uploads)
// =============================================================================

/// Result of uploading a file to the Files API
pub const FileUploadResult = struct {
    status: union(enum) {
        success: []const u8, // file_id (owned)
        err: []const u8, // error message (static)
    },
    owned: bool = false,

    pub fn success(file_id: []const u8) FileUploadResult {
        return .{ .status = .{ .success = file_id }, .owned = true };
    }

    pub fn err(msg: []const u8) FileUploadResult {
        return .{ .status = .{ .err = msg }, .owned = false };
    }

    pub fn deinit(self: *FileUploadResult, allocator: Allocator) void {
        if (self.owned) {
            switch (self.status) {
                .success => |file_id| allocator.free(file_id),
                .err => {},
            }
        }
        self.* = undefined;
    }

    pub fn isSuccess(self: *const FileUploadResult) bool {
        return switch (self.status) {
            .success => true,
            .err => false,
        };
    }

    pub fn getFileId(self: *const FileUploadResult) ?[]const u8 {
        return switch (self.status) {
            .success => |id| id,
            .err => null,
        };
    }
};

/// Upload a file to the Anthropic Files API (required for PDFs).
/// Returns a FileUploadResult containing the file_id on success.
///
/// Retries the upload itself with bounded exponential backoff on
/// transient HTTP / network failures, mirroring the chat-request retry
/// policy. The multipart body is built once (not per attempt) — files
/// can be megabytes and re-encoding per retry would defeat the purpose.
pub fn uploadFileToFilesApi(
    io: Io,
    allocator: Allocator,
    api_key: []const u8,
    attachment: FileAttachment,
) FileUploadResult {
    std.debug.assert(api_key.len > 0);
    std.debug.assert(attachment.content.len > 0);

    // Build multipart body once. None of this depends on the attempt
    // number, and the file content can be megabytes — re-encoding per
    // retry would waste both CPU and memory.
    const boundary = "----AnthropicFileBoundary";
    const file_name = getFileName(attachment.path);

    // Format: --boundary\r\nContent-Disposition: form-data; name="file"; filename="..."\r\nContent-Type: ...\r\n\r\n<content>\r\n--boundary--\r\n
    const header_template = "--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\nContent-Type: {s}\r\n\r\n";
    const footer = "\r\n--" ++ boundary ++ "--\r\n";

    // Estimate header size (generous).
    const header_size_estimate = 256 + file_name.len + attachment.media_type.len;
    const total_size = header_size_estimate + attachment.content.len + footer.len;

    const body_buf = allocator.alloc(u8, total_size) catch {
        return FileUploadResult.err("Failed to allocate upload buffer");
    };
    defer allocator.free(body_buf);

    // Zig 0.16 replaced `std.io.fixedBufferStream` with `Io.Writer.fixed`.
    // The Writer exposes `buffered()` to retrieve the filled slice.
    var fbs: Io.Writer = .fixed(body_buf);
    fbs.print(header_template, .{ boundary, file_name, attachment.media_type }) catch {
        return FileUploadResult.err("Failed to write multipart header");
    };
    fbs.writeAll(attachment.content) catch {
        return FileUploadResult.err("Failed to write file content");
    };
    fbs.writeAll(footer) catch {
        return FileUploadResult.err("Failed to write multipart footer");
    };
    const body = fbs.buffered();

    if (LOG_PAYLOADS) {
        log.debug("Files API upload: {d} bytes for {s}", .{ body.len, file_name });
    }

    // Build content-type header with boundary.
    var content_type_buf: [128]u8 = undefined;
    const content_type = std.fmt.bufPrint(&content_type_buf, "multipart/form-data; boundary={s}", .{boundary}) catch {
        return FileUploadResult.err("Failed to format content type");
    };

    const uri = Uri.parse(FILES_API_URL) catch {
        return FileUploadResult.err("Failed to parse Files API URL");
    };

    // Drive the retry loop. Cancellation propagates from `io.sleep`
    // inside `fetchWithRetry`, surfaced here as `error.Canceled` —
    // mapped to a benign error so the caller's existing `deinit` path
    // works unchanged.
    var prng = seedBackoffPrng(io);
    const ctx = UploadAttemptCtx{
        .io = io,
        .allocator = allocator,
        .api_key = api_key,
        .uri = uri,
        .body = body,
        .content_type = content_type,
    };

    return fetchWithRetry(
        FileUploadResult,
        io,
        prng.random(),
        ctx,
        FileUploadResult.err("File upload failed after retries"),
        "Anthropic",
    ) catch FileUploadResult.err("File upload cancelled");
}

/// Per-upload state captured for retry. Body, URI, and headers don't
/// depend on attempt number; the connection state does, so `attempt()`
/// creates a fresh `http.Client` on each call.
const UploadAttemptCtx = struct {
    io: Io,
    allocator: Allocator,
    api_key: []const u8,
    uri: Uri,
    body: []u8,
    content_type: []const u8,

    fn attempt(c: @This()) Io.Cancelable!AttemptOutcome(FileUploadResult) {
        var client = http.Client{ .allocator = c.allocator, .io = c.io };
        defer client.deinit();

        var req = client.request(.POST, c.uri, .{
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = c.content_type },
                .{ .name = "x-api-key", .value = c.api_key },
                .{ .name = "anthropic-version", .value = "2023-06-01" },
                .{ .name = "anthropic-beta", .value = "files-api-2025-04-14" },
            },
        }) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return switch (classifyRequestError(err)) {
                error.Transient => .{ .transient = null },
                error.Permanent => .{ .terminal = FileUploadResult.err("Failed to create upload request") },
            };
        };
        defer req.deinit();

        req.sendBodyComplete(c.body) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            // Send-side failures are always transient — retry is the
            // right response. Body slice is reusable across attempts.
            return .{ .transient = null };
        };

        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return switch (classifyReceiveHeadError(err)) {
                error.Transient => .{ .transient = null },
                error.Permanent => .{ .terminal = FileUploadResult.err("Failed to receive upload response") },
            };
        };

        if (response.head.status != .ok) {
            const status_code: u32 = @intFromEnum(response.head.status);
            log.err("Files API HTTP {d}", .{status_code});
            switch (classifyHttpStatus(response.head.status)) {
                error.Transient => {
                    // Read Retry-After before `response.reader()` so the
                    // head's slices are still valid.
                    const retry_after_s = parseRetryAfterFromHead(response.head);
                    if (retry_after_s) |s| log.info("Files API Retry-After: {d}s", .{s});
                    return .{ .transient = retry_after_s };
                },
                error.Permanent => {
                    return .{ .terminal = FileUploadResult.err("Files API returned error") };
                },
            }
        }

        // 200 — past the retry boundary. Read body + parse file_id.
        var transfer_buf: [64]u8 = undefined;
        var reader = response.reader(&transfer_buf);
        const response_data = reader.allocRemaining(c.allocator, Io.Limit.limited(MAX_RESPONSE_SIZE)) catch {
            return .{ .terminal = FileUploadResult.err("Failed to read upload response") };
        };
        defer c.allocator.free(response_data);

        if (LOG_PAYLOADS) {
            log.debug("Files API response: {s}", .{response_data});
        }

        // Parse response to extract file_id.
        // Response format: {"id":"file-xxx","type":"file",...}
        const file_id = parseFileId(c.allocator, response_data) catch {
            log.err("Failed to parse file_id from response: {s}", .{response_data});
            return .{ .terminal = FileUploadResult.err("Failed to parse upload response") };
        };

        return .{ .terminal = FileUploadResult.success(file_id) };
    }
};

/// Parse file_id from Files API response JSON
fn parseFileId(allocator: Allocator, response: []const u8) ![]const u8 {
    // Look for "id":"..." pattern
    const id_key = "\"id\":\"";
    const id_start = std.mem.indexOf(u8, response, id_key) orelse return error.IdNotFound;
    const value_start = id_start + id_key.len;

    // Find closing quote
    const value_end = std.mem.indexOfPos(u8, response, value_start, "\"") orelse return error.IdNotFound;

    const file_id = response[value_start..value_end];
    if (file_id.len == 0 or file_id.len > MAX_FILE_ID_LEN) return error.InvalidId;

    // Allocate and copy the file_id
    const result = try allocator.alloc(u8, file_id.len);
    @memcpy(result, file_id);

    return result;
}

// =============================================================================
// Response Types
// =============================================================================

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

    pub fn getError(self: *const Self) ?[]const u8 {
        return switch (self.status) {
            .success => null,
            .err => |msg| msg,
        };
    }
};

// =============================================================================
// API Response Types (for std.json parsing)
// =============================================================================

const ApiContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
};

const ApiResponse = struct {
    content: []const ApiContentBlock,
};

// =============================================================================
// Anthropic Client
// =============================================================================

pub const AnthropicClient = struct {
    const Self = @This();

    api_key: []const u8,
    allocator: Allocator,
    /// Shared `std.Io` used for filesystem access, TCP/TLS, and DNS.
    /// Owned by `main()` via `std.process.Init` — the client borrows it.
    io: Io,

    pub fn init(api_key: []const u8, allocator: Allocator, io: Io) Self {
        std.debug.assert(api_key.len > 0);
        return .{ .api_key = api_key, .allocator = allocator, .io = io };
    }

    /// Blocking HTTP request - call from a background thread.
    /// Returns a ChatResult that the caller must deinit().
    pub fn sendBlocking(self: *Self, request: ChatRequest) ChatResult {
        std.debug.assert(request.messages.len > 0);
        std.debug.assert(request.messages.len <= MAX_MESSAGES);

        return self.doRequest(request, null) catch |e| {
            log.err("HTTP request failed: {}", .{e});
            return ChatResult.err("Request failed");
        };
    }

    /// Streaming HTTP request — emits `"stream": true` in the request body
    /// and parses the response as Server-Sent Events. Each `text_delta`
    /// chunk is delivered to `sink` as it arrives. The returned
    /// `ChatResult` carries the *final accumulated text* on success (so
    /// callers that don't care about incremental delivery still get the
    /// full response), or an error message on failure.
    ///
    /// Threading: same contract as `sendBlocking` — call from a worker
    /// fiber. The sink is invoked synchronously from this fiber, so the
    /// callback must be brief and must not call back into UI state
    /// directly. Pattern: copy the bytes into a staging buffer, then push
    /// a `WorkerResult.chat_delta` onto the result queue.
    pub fn sendStreaming(self: *Self, request: ChatRequest, sink: StreamSink) ChatResult {
        std.debug.assert(request.messages.len > 0);
        std.debug.assert(request.messages.len <= MAX_MESSAGES);

        return self.doRequest(request, sink) catch |e| {
            log.err("HTTP streaming request failed: {}", .{e});
            return ChatResult.err("Request failed");
        };
    }

    /// Send with a file attachment - reads the file, encodes if needed, and sends
    /// For PDFs: uploads via Files API first, then references by file_id
    /// For images: base64 encodes inline
    /// For text: includes content inline
    pub fn sendWithFile(self: *Self, request: ChatRequest, file_path: []const u8) ChatResult {
        // Read and prepare the file
        var attachment = readFileAttachment(self.io, self.allocator, file_path) catch |e| {
            return switch (e) {
                error.UnsupportedFileType => ChatResult.err("Unsupported file type. Only images (jpg, png, gif, webp), text files (txt, md, json, csv), and PDFs are supported."),
                error.FileTooLarge => ChatResult.err("File too large (max 5MB)"),
                error.InvalidUtf8 => ChatResult.err("Text file contains invalid UTF-8 characters"),
                else => ChatResult.err("Failed to read attachment"),
            };
        };
        defer self.allocator.free(attachment.content);

        // For PDFs, upload via Files API first
        var file_id_buf: ?[]u8 = null;
        defer if (file_id_buf) |id| self.allocator.free(id);

        if (attachment.is_pdf) {
            log.info("Uploading PDF via Files API: {s}", .{getFileName(file_path)});

            var upload_result = uploadFileToFilesApi(self.io, self.allocator, self.api_key, attachment);
            defer upload_result.deinit(self.allocator);

            if (!upload_result.isSuccess()) {
                return switch (upload_result.status) {
                    .err => |msg| ChatResult.err(msg),
                    .success => unreachable,
                };
            }

            // Copy the file_id since upload_result will be deinitialized
            const file_id = upload_result.getFileId() orelse return ChatResult.err("No file ID returned");
            file_id_buf = self.allocator.alloc(u8, file_id.len) catch return ChatResult.err("Failed to allocate file ID");
            @memcpy(file_id_buf.?, file_id);

            attachment.file_id = file_id_buf;
            log.info("PDF uploaded successfully, file_id: {s}", .{file_id_buf.?});
        }

        // Create a new request with the attachment
        var req_with_file = request;
        req_with_file.attachment = attachment;

        return self.doRequest(req_with_file, null) catch |e| {
            log.err("HTTP request failed: {}", .{e});
            return ChatResult.err("Request failed");
        };
    }

    /// Streaming variant of `sendWithFile`. See `sendStreaming` for the
    /// sink contract; file handling is identical to the non-streaming
    /// path (PDFs go through the Files API first, images are base64'd
    /// inline, text is embedded).
    pub fn sendStreamingWithFile(
        self: *Self,
        request: ChatRequest,
        file_path: []const u8,
        sink: StreamSink,
    ) ChatResult {
        // Read and prepare the file. This mirrors `sendWithFile` exactly —
        // duplicated rather than factored out because the error→ChatResult
        // mapping is the only meaningful body and inlining it keeps the
        // control flow legible at the call site.
        var attachment = readFileAttachment(self.io, self.allocator, file_path) catch |e| {
            return switch (e) {
                error.UnsupportedFileType => ChatResult.err("Unsupported file type. Only images (jpg, png, gif, webp), text files (txt, md, json, csv), and PDFs are supported."),
                error.FileTooLarge => ChatResult.err("File too large (max 5MB)"),
                error.InvalidUtf8 => ChatResult.err("Text file contains invalid UTF-8 characters"),
                else => ChatResult.err("Failed to read attachment"),
            };
        };
        defer self.allocator.free(attachment.content);

        var file_id_buf: ?[]u8 = null;
        defer if (file_id_buf) |id| self.allocator.free(id);

        if (attachment.is_pdf) {
            log.info("Uploading PDF via Files API: {s}", .{getFileName(file_path)});

            var upload_result = uploadFileToFilesApi(self.io, self.allocator, self.api_key, attachment);
            defer upload_result.deinit(self.allocator);

            if (!upload_result.isSuccess()) {
                return switch (upload_result.status) {
                    .err => |msg| ChatResult.err(msg),
                    .success => unreachable,
                };
            }

            const file_id = upload_result.getFileId() orelse return ChatResult.err("No file ID returned");
            file_id_buf = self.allocator.alloc(u8, file_id.len) catch return ChatResult.err("Failed to allocate file ID");
            @memcpy(file_id_buf.?, file_id);

            attachment.file_id = file_id_buf;
            log.info("PDF uploaded successfully, file_id: {s}", .{file_id_buf.?});
        }

        var req_with_file = request;
        req_with_file.attachment = attachment;

        return self.doRequest(req_with_file, sink) catch |e| {
            log.err("HTTP streaming request failed: {}", .{e});
            return ChatResult.err("Request failed");
        };
    }

    fn doRequest(self: *Self, request: ChatRequest, sink: ?StreamSink) !ChatResult {
        // For large requests with attachments, use dynamic allocation
        var dynamic_buf: ?[]u8 = null;
        defer if (dynamic_buf) |buf| self.allocator.free(buf);

        // Encode attachment if it's an image
        var base64_data: ?[]const u8 = null;
        defer if (base64_data) |data| self.allocator.free(data);

        if (request.attachment) |attachment| {
            if (attachment.is_image) {
                base64_data = base64Encode(self.allocator, attachment.content) catch {
                    return ChatResult.err("Failed to encode image");
                };
            }
        }

        // Calculate buffer size needed
        const base_size: usize = MAX_REQUEST_SIZE;
        const attachment_size: usize = if (base64_data) |data| data.len + 1024 else if (request.attachment) |att| att.content.len * 2 + 1024 else 0;
        const total_size = base_size + attachment_size;

        // Use stack buffer for small requests, heap for large ones
        var stack_buf: [64 * 1024]u8 = undefined;
        const json_buf: []u8 = if (total_size <= stack_buf.len)
            &stack_buf
        else blk: {
            dynamic_buf = try self.allocator.alloc(u8, total_size);
            break :blk dynamic_buf.?;
        };

        // Zig 0.16 writer: `Io.Writer.fixed` replaces fixedBufferStream.
        var fbs: Io.Writer = .fixed(json_buf);
        const writer = &fbs;

        try writer.print("{{\"model\":\"{s}\",\"max_tokens\":{d}", .{ request.model, MAX_TOKENS });

        // Streaming flag: when a sink is provided, ask the server for SSE.
        // Emitting this before `messages` keeps the JSON shape stable for
        // anyone scanning the prefix in logs.
        if (sink != null) try writer.writeAll(",\"stream\":true");

        try writer.writeAll(",\"messages\":[");

        // Add conversation history
        var first = true;
        for (request.messages, 0..) |msg, msg_idx| {
            if (!first) try writer.writeAll(",");
            first = false;

            const is_last_user_msg = msg.role == .user and isLastUserMessage(request.messages, msg_idx);
            const should_attach = is_last_user_msg and request.attachment != null;

            try writer.print("{{\"role\":\"{s}\",\"content\":", .{msg.role.apiName()});

            if (should_attach) {
                // Multimodal content with attachment
                try writer.writeAll("[");

                // Add image/file content first
                if (request.attachment) |attachment| {
                    if (attachment.is_pdf) {
                        // PDF via Files API - reference by file_id
                        if (attachment.file_id) |file_id| {
                            try writer.print("{{\"type\":\"document\",\"source\":{{\"type\":\"file\",\"file_id\":\"{s}\"}}}},", .{file_id});
                        } else {
                            // Fallback: mention the PDF but note it couldn't be uploaded
                            try writer.writeAll("{\"type\":\"text\",\"text\":\"[PDF file attached but upload failed]\"},");
                        }
                    } else if (attachment.is_image) {
                        // Image as base64
                        try writer.print("{{\"type\":\"image\",\"source\":{{\"type\":\"base64\",\"media_type\":\"{s}\",\"data\":\"", .{attachment.media_type});
                        if (base64_data) |data| {
                            try writer.writeAll(data);
                        }
                        try writer.writeAll("\"}},");
                    } else {
                        // Text file - include as text block with file indicator
                        try writer.writeAll("{\"type\":\"text\",\"text\":\"");
                        try writer.writeAll("[Attached file: ");
                        try writeJsonEscapedString(writer, getFileName(attachment.path));
                        try writer.writeAll("]\\n\\n");
                        try writeJsonEscapedString(writer, attachment.content);
                        try writer.writeAll("\"},");
                    }
                }

                // Add the text content
                try writer.writeAll("{\"type\":\"text\",\"text\":\"");
                if (msg.content) |content| {
                    try writeJsonEscapedString(writer, content);
                }
                try writer.writeAll("\"}]");
            } else {
                // Simple text content
                try writer.writeAll("\"");
                if (msg.content) |content| {
                    try writeJsonEscapedString(writer, content);
                } else if (msg.content_blocks) |blocks| {
                    // Handle pre-built content blocks
                    for (blocks) |block| {
                        switch (block) {
                            .text => |txt| try writeJsonEscapedString(writer, txt),
                            .image => {}, // Skip images in simple format
                        }
                    }
                }
                try writer.writeAll("\"");
            }

            try writer.writeAll("}");
        }

        try writer.writeAll("]}");

        const body = fbs.buffered();

        // Assert buffer didn't overflow (would have errored, but belt-and-suspenders).
        std.debug.assert(body.len < json_buf.len);
        if (LOG_PAYLOADS) {
            log.debug("Request body: {s}", .{body});
        }

        const uri = try Uri.parse(API_URL);

        // The files-api beta header is conditional on PDF attachments —
        // sending it unconditionally would also work, but stripping it
        // when not needed keeps log noise down on the Anthropic side.
        const needs_files_beta = if (request.attachment) |att| att.is_pdf and att.file_id != null else false;

        // Pre-stream retry only: each attempt rebuilds the connection
        // (fresh client) and runs through `attemptOnce`. Once a 200 is
        // observed and we hand off to the SSE loop, all further failures
        // are terminal — replaying after partial output would create a
        // confusing UX where text appears, vanishes, reappears different.
        // Body and URI are computed once above; the retry budget runs
        // over only the network roundtrip and head parse.
        var prng = seedBackoffPrng(self.io);
        const ctx = ChatAttemptCtx{
            .self = self,
            .body = body,
            .uri = uri,
            .needs_files_beta = needs_files_beta,
            .sink = sink,
        };

        return fetchWithRetry(
            ChatResult,
            self.io,
            prng.random(),
            ctx,
            ChatResult.err("Request failed after retries"),
            "Anthropic",
        );
    }

    /// Per-request state captured for retry. Body, URI, and headers
    /// don't depend on attempt number; the connection state does, so
    /// `attempt()` creates a fresh `http.Client` on each call.
    const ChatAttemptCtx = struct {
        self: *Self,
        body: []u8,
        uri: Uri,
        needs_files_beta: bool,
        sink: ?StreamSink,

        fn attempt(c: @This()) Io.Cancelable!AttemptOutcome(ChatResult) {
            return c.self.attemptOnce(c.body, c.uri, c.needs_files_beta, c.sink);
        }
    };

    /// Run one request → receive-head → body-or-stream attempt. Errors
    /// before the SSE handoff are classified for retry; after the
    /// handoff (200 reached, sink invoked at least once) all failures
    /// are terminal. Cancellation propagates as `error.Canceled` —
    /// `fetchWithRetry` catches it via `try ctx.attempt()` and unwinds.
    fn attemptOnce(
        self: *Self,
        body: []u8,
        uri: Uri,
        needs_files_beta: bool,
        sink: ?StreamSink,
    ) Io.Cancelable!AttemptOutcome(ChatResult) {
        var client = http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        // Headers MUST be built on this stack frame, not in a helper —
        // `RequestOptions.extra_headers` is documented as "Externally-
        // owned; must outlive the Request". A previous version of this
        // code factored the construction into `buildPostRequest`, which
        // returned the Request while the `&.{...}` array literal lived
        // on the helper's frame — by the time `sendHead` walked the
        // header slice it was reading freed stack memory (segfault at
        // 0xa0 in `prepareCiphertextRecord` during TLS write).
        //
        // The slice's lifetime now matches `req`'s: both die at the
        // end of this function, after `defer req.deinit()` runs.
        const standard_headers: http.Client.Request.Headers = .{
            // Disable compression — server sends gzip by default which we don't decode.
            .accept_encoding = .{ .override = "identity" },
        };
        const extra_headers_full = [_]http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "anthropic-beta", .value = "files-api-2025-04-14" },
        };
        const extra_headers_basic = [_]http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
        };
        // Slice off either the 4-header or 3-header form. Both array
        // literals live on this frame, so the slice we hand to
        // `client.request` outlives `req` regardless of branch.
        const extra_headers: []const http.Header = if (needs_files_beta)
            &extra_headers_full
        else
            &extra_headers_basic;

        var req = client.request(.POST, uri, .{
            .headers = standard_headers,
            .extra_headers = extra_headers,
        }) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return switch (classifyRequestError(err)) {
                error.Transient => .{ .transient = null },
                error.Permanent => .{ .terminal = ChatResult.err("Failed to build request") },
            };
        };
        defer req.deinit();

        // Send body. Zig 0.16: `sendBodyComplete` sets transfer_encoding
        // internally from the body length. Send-side errors are always
        // transient — connection drop, peer close, write timeout —
        // retry is exactly the right response. The body slice is
        // reusable across attempts.
        req.sendBodyComplete(body) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return .{ .transient = null };
        };

        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            return switch (classifyReceiveHeadError(err)) {
                error.Transient => .{ .transient = null },
                error.Permanent => .{ .terminal = ChatResult.err("HTTP receive failed") },
            };
        };

        if (response.head.status != .ok) {
            const status_code: u32 = @intFromEnum(response.head.status);
            log.err("Anthropic API HTTP {d}", .{status_code});

            switch (classifyHttpStatus(response.head.status)) {
                error.Transient => {
                    // Read Retry-After BEFORE `response.reader()` so the
                    // head's slices are still valid (reader invalidates).
                    const retry_after_s = parseRetryAfterFromHead(response.head);
                    if (retry_after_s) |s| log.info("Anthropic Retry-After: {d}s", .{s});
                    return .{ .transient = retry_after_s };
                },
                error.Permanent => {
                    // Coarse mapping — richer parsing of the Anthropic
                    // `error.type` JSON envelope (rate_limit_error,
                    // invalid_request_error, etc.) is a follow-up.
                    const msg: []const u8 = switch (status_code) {
                        400 => "Bad request",
                        401 => "Invalid API key",
                        402 => "Payment required",
                        403 => "Forbidden",
                        404 => "Not found",
                        413 => "Request too large",
                        422 => "Unprocessable entity",
                        else => "API returned error",
                    };
                    return .{ .terminal = ChatResult.err(msg) };
                },
            }
        }

        // 200 — past the retry boundary. From here on, all failures
        // are terminal (no replay after partial stream output).
        return .{ .terminal = self.consumeOkResponse(&response, sink) };
    }

    /// Drain a 200 OK response: SSE stream when `sink` is set, otherwise
    /// blocking read + JSON parse. All failures here are terminal — see
    /// `attemptOnce` for the retry-boundary rationale. The reader
    /// buffer holds one full SSE line (`data: ` + JSON envelope); 16 KiB
    /// is generous for text_delta events (typical chunk < 1 KiB).
    fn consumeOkResponse(
        self: *Self,
        response: *http.Client.Response,
        sink: ?StreamSink,
    ) ChatResult {
        if (sink) |s| {
            var sse_buf: [SSE_READER_BUF_SIZE]u8 = undefined;
            // `Response.reader` already returns a `*Io.Reader` — taking
            // its address would yield a `**Io.Reader` and confuse the
            // type checker. Pass the pointer through verbatim.
            const reader = response.reader(&sse_buf);
            return self.readSseStream(reader, s) catch |e| blk: {
                log.err("SSE stream failed: {}", .{e});
                break :blk ChatResult.err("Streaming response failed");
            };
        }

        // Non-streaming branch: read the whole body, then parse.
        var transfer_buf: [64]u8 = undefined;
        var reader = response.reader(&transfer_buf);
        const response_data = reader.allocRemaining(self.allocator, Io.Limit.limited(MAX_RESPONSE_SIZE)) catch |e| {
            log.err("Failed to read response: {}", .{e});
            return ChatResult.err("Failed to read response");
        };
        defer self.allocator.free(response_data);

        std.debug.assert(response_data.len > 0);
        if (LOG_PAYLOADS) {
            log.debug("Response ({d} bytes): {s}", .{ response_data.len, response_data });
        }

        const text = parseAndExtractText(self.allocator, response_data) catch |e| {
            log.err("Failed to parse response: {}", .{e});
            return ChatResult.err("Failed to parse response");
        };
        return ChatResult.success(text);
    }

    /// Drive the SSE read loop. Reads one line at a time via
    /// `Io.Reader.takeDelimiter`, parses `data:` lines as Anthropic stream
    /// events, and forwards `text_delta` text to `sink` while also
    /// accumulating it into an owned buffer for the final ChatResult.
    ///
    /// Bounded by SSE_READER_BUF_SIZE per line and MAX_RESPONSE_SIZE total
    /// (CLAUDE rule #4 — put a limit on everything). Lines longer than
    /// the reader buffer are dropped via `tossBuffered`, mirroring the
    /// `gooey/src/examples/ai_canvas.zig` line reader.
    fn readSseStream(self: *Self, reader: *Io.Reader, sink: StreamSink) !ChatResult {
        // Accumulator for the final response text. Grows dynamically up to
        // MAX_RESPONSE_SIZE — past that, further deltas are dropped from
        // the accumulator (and from the sink) so we fail closed rather than
        // OOM. The aggregated text is what `ChatResult.success` carries.
        var accum: std.Io.Writer.Allocating = .init(self.allocator);
        defer accum.deinit();

        // We key off each `data:` payload's `type` field rather than the
        // sibling `event:` line — Anthropic emits both, and the JSON
        // payload is authoritative.
        var aborted = false;

        while (true) {
            const line_or_null = reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    // Oversized line — drop the whole line and resync to the
                    // next newline. Real Anthropic events never exceed the
                    // reader buffer; this is defensive against future
                    // protocol changes.
                    log.warn("SSE line exceeded {d} bytes, dropping", .{SSE_READER_BUF_SIZE});
                    drainSseLine(reader);
                    continue;
                },
                error.ReadFailed => return ChatResult.err("Streaming read failed"),
            };

            const line = line_or_null orelse break; // EOF
            const trimmed = trimCr(line);

            // Blank line ends an SSE event — we already process each
            // `data:` line eagerly, so blank lines are no-ops.
            if (trimmed.len == 0) continue;

            // Comment / event-name lines — ignore. Only `data:` carries
            // the JSON payload we care about.
            if (!std.mem.startsWith(u8, trimmed, "data:")) continue;

            // Strip the prefix and any single leading space (per RFC 6455
            // for SSE: most servers emit `data: ` with one space).
            var payload = trimmed["data:".len..];
            if (payload.len > 0 and payload[0] == ' ') payload = payload[1..];
            if (payload.len == 0) continue;

            const text = parseSseTextDelta(self.allocator, payload) catch |e| {
                // Parse errors are non-fatal — Anthropic may add new event
                // shapes, and `ping` events have no `delta` field. Log at
                // debug so a real protocol break is still discoverable.
                log.debug("SSE event ignored ({t}): {s}", .{ e, payload });
                continue;
            };
            const owned_text = text orelse continue; // not a text_delta
            defer self.allocator.free(owned_text);

            // Forward to sink first — if it aborts, stop reading the
            // stream but still return whatever we've accumulated so the
            // caller can present a partial response.
            if (!aborted) {
                sink.callback(sink.userdata, owned_text) catch |e| switch (e) {
                    error.Aborted => aborted = true,
                };
            }

            // Append to the accumulator, capped at MAX_RESPONSE_SIZE. Past
            // the cap we silently drop further deltas — the sink may have
            // its own (smaller) cap, and the accumulator's job is just to
            // produce the final ChatResult.
            const remaining = MAX_RESPONSE_SIZE - @min(accum.written().len, MAX_RESPONSE_SIZE);
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

        if (LOG_PAYLOADS) {
            log.debug("SSE final ({d} bytes): {s}", .{ final_text.len, final_text });
        }

        return ChatResult.success(final_text);
    }
};

// =============================================================================
// SSE Helpers
// =============================================================================

/// SSE event payload shape we care about. Anthropic emits a wide variety of
/// event types (`message_start`, `content_block_start`, `ping`, etc.); the
/// only ones with text we want to stream are `content_block_delta` events
/// whose `delta.type == "text_delta"`. `ignore_unknown_fields` lets the
/// parser skip every other field (including the entire `message` object on
/// `message_start`) without us spelling them out.
const SseDelta = struct {
    type: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

const SseEvent = struct {
    type: []const u8,
    delta: ?SseDelta = null,
};

/// Parse one `data:` payload from the Anthropic SSE stream. Returns an
/// owned copy of the delta text on `text_delta` events, or `null` for any
/// other event type (`ping`, `message_start`, `content_block_stop`, …).
/// The owned slice is bounded by `MAX_DELTA_TEXT_LEN`; longer chunks are
/// truncated rather than rejected so a single oversize event cannot stall
/// the stream.
///
/// Errors propagate from the JSON parser only — malformed payloads are
/// surfaced so the caller can log them at debug. The caller should treat
/// any error as "skip this event and keep reading", matching how the
/// Anthropic docs describe handling unknown event types.
pub fn parseSseTextDelta(allocator: Allocator, payload: []const u8) !?[]const u8 {
    std.debug.assert(payload.len > 0);

    const parsed = try std.json.parseFromSlice(SseEvent, allocator, payload, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    // Only `content_block_delta` events carry incremental text. Everything
    // else (ping, message_start, content_block_stop, message_stop, error)
    // is meaningful at the protocol level but not here.
    if (!std.mem.eql(u8, parsed.value.type, "content_block_delta")) return null;

    const delta = parsed.value.delta orelse return null;
    const delta_type = delta.type orelse return null;
    if (!std.mem.eql(u8, delta_type, "text_delta")) return null;

    const text = delta.text orelse return null;
    if (text.len == 0) return null;

    // Truncate before duplicating so the bounded copy is paid for once.
    const len = @min(text.len, MAX_DELTA_TEXT_LEN);
    return try allocator.dupe(u8, text[0..len]);
}

/// After `error.StreamTooLong`, the reader buffer is full with no newline
/// found. Drain buffered bytes and keep reading until the next newline (or
/// EOF / read error). Mirrors the helper in
/// `gooey/src/examples/ai_canvas.zig` so the failure mode is identical.
fn drainSseLine(reader: *Io.Reader) void {
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

/// Trim a trailing '\r' if present. SSE on the wire is technically
/// `\r\n`-delimited per the W3C spec, so even though we split on `\n`
/// alone we still need to strip the carriage return.
fn trimCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

// =============================================================================
// JSON Helpers
// =============================================================================

/// Check if this is the last user message in the array
fn isLastUserMessage(messages: []const ChatMessage, current_idx: usize) bool {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i].role == .user) {
            return i == current_idx;
        }
    }
    return false;
}

/// Extract filename from path
fn getFileName(path: []const u8) []const u8 {
    var last_slash: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/') last_slash = i + 1;
    }
    return path[last_slash..];
}

/// Escapes a string for JSON output per RFC 8259.
/// Handles all control characters (0x00-0x1F), quotes, and backslashes.
///
/// Takes a concrete `*Io.Writer`. The old `anytype` signature was a holdover
/// from Zig 0.15 generic streams; 0.16's unified `Io.Writer` interface gives
/// us a single concrete type and better error messages at call sites.
pub fn writeJsonEscapedString(writer: *Io.Writer, str: []const u8) !void {
    const hex_digits = "0123456789abcdef";

    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"), // backspace
            0x0C => try writer.writeAll("\\f"), // form feed
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                // Other control characters: use \u00XX format
                try writer.writeAll("\\u00");
                try writer.writeByte(hex_digits[c >> 4]);
                try writer.writeByte(hex_digits[c & 0x0F]);
            },
            else => try writer.writeByte(c),
        }
    }
}

/// Parses the Anthropic API response and extracts the text content.
/// Returns an owned copy of the text that must be freed by the caller.
fn parseAndExtractText(allocator: Allocator, json_data: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(ApiResponse, allocator, json_data, .{
        .ignore_unknown_fields = true,
    }) catch |e| {
        log.err("JSON parse error: {}", .{e});
        return error.JsonParseError;
    };
    defer parsed.deinit();

    // Find the first text content block
    for (parsed.value.content) |block| {
        if (std.mem.eql(u8, block.type, "text")) {
            if (block.text) |text| {
                std.debug.assert(text.len > 0);
                // Return an owned copy since we're deferring parsed.deinit()
                return try allocator.dupe(u8, text);
            }
        }
    }

    log.err("No text content found in response", .{});
    return error.NoTextContent;
}

// =============================================================================
// Tests
// =============================================================================

test "writeJsonEscapedString escapes control characters" {
    var buf: [256]u8 = undefined;

    // Zig 0.16: a fresh `Io.Writer.fixed` replaces the old `fbs.reset()` dance.
    // Each case gets its own writer, which is a cleaner invariant anyway —
    // the previous buffer contents cannot leak into the next assertion.
    {
        var w: Io.Writer = .fixed(&buf);
        try writeJsonEscapedString(&w, "hello\nworld");
        try std.testing.expectEqualStrings("hello\\nworld", w.buffered());
    }

    {
        var w: Io.Writer = .fixed(&buf);
        try writeJsonEscapedString(&w, "tab\there");
        try std.testing.expectEqualStrings("tab\\there", w.buffered());
    }

    {
        var w: Io.Writer = .fixed(&buf);
        try writeJsonEscapedString(&w, "quote\"here");
        try std.testing.expectEqualStrings("quote\\\"here", w.buffered());
    }

    {
        var w: Io.Writer = .fixed(&buf);
        try writeJsonEscapedString(&w, "null\x00char");
        try std.testing.expectEqualStrings("null\\u0000char", w.buffered());
    }

    {
        var w: Io.Writer = .fixed(&buf);
        try writeJsonEscapedString(&w, "bell\x07char");
        try std.testing.expectEqualStrings("bell\\u0007char", w.buffered());
    }
}

test "parseAndExtractText extracts text content" {
    const allocator = std.testing.allocator;
    const json =
        \\{"content":[{"type":"text","text":"Hello, world!"}],"model":"claude"}
    ;

    const text = try parseAndExtractText(allocator, json);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello, world!", text);
}

test "parseAndExtractText handles escaped content" {
    const allocator = std.testing.allocator;
    const json =
        \\{"content":[{"type":"text","text":"Line1\nLine2"}],"model":"claude"}
    ;

    const text = try parseAndExtractText(allocator, json);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Line1\nLine2", text);
}

test "ChatResult lifecycle" {
    const allocator = std.testing.allocator;

    // Test success result
    const text = try allocator.dupe(u8, "Hello");
    var result = ChatResult.success(text);
    try std.testing.expect(result.isSuccess());
    try std.testing.expectEqualStrings("Hello", result.getText().?);
    result.deinit(allocator);

    // Test error result (no allocation)
    var err_result = ChatResult.err("Something went wrong");
    try std.testing.expect(!err_result.isSuccess());
    try std.testing.expectEqualStrings("Something went wrong", err_result.getError().?);
    err_result.deinit(allocator); // No-op for errors
}

test "ChatRequest structure" {
    const messages = [_]ChatMessage{
        ChatMessage.text(.user, "Hello"),
        ChatMessage.text(.assistant, "Hi there!"),
    };

    const request = ChatRequest{
        .model = "claude-haiku-4-5-20251001",
        .messages = &messages,
    };

    try std.testing.expectEqualStrings("claude-haiku-4-5-20251001", request.model);
    try std.testing.expectEqual(@as(usize, 2), request.messages.len);
    try std.testing.expectEqualStrings("user", request.messages[0].role.apiName());
}

test "getMimeType returns correct types" {
    try std.testing.expectEqualStrings("image/jpeg", getMimeType("/path/to/image.jpg"));
    try std.testing.expectEqualStrings("image/jpeg", getMimeType("/path/to/image.JPEG"));
    try std.testing.expectEqualStrings("image/png", getMimeType("photo.png"));
    try std.testing.expectEqualStrings("text/plain", getMimeType("readme.txt"));
    try std.testing.expectEqualStrings("text/markdown", getMimeType("doc.md"));
    try std.testing.expectEqualStrings("application/json", getMimeType("data.json"));
    try std.testing.expectEqualStrings("application/octet-stream", getMimeType("unknown"));
}

test "isImageMimeType" {
    try std.testing.expect(isImageMimeType("image/jpeg"));
    try std.testing.expect(isImageMimeType("image/png"));
    try std.testing.expect(!isImageMimeType("text/plain"));
    try std.testing.expect(!isImageMimeType("application/json"));
}

test "isTextMimeType" {
    try std.testing.expect(isTextMimeType("text/plain"));
    try std.testing.expect(isTextMimeType("text/markdown"));
    try std.testing.expect(isTextMimeType("application/json"));
    try std.testing.expect(!isTextMimeType("image/png"));
    try std.testing.expect(!isTextMimeType("application/pdf"));
}

test "isSupportedFileType" {
    try std.testing.expect(isSupportedFileType("image/jpeg"));
    try std.testing.expect(isSupportedFileType("text/plain"));
    try std.testing.expect(isSupportedFileType("application/pdf")); // PDFs now supported via Files API
    try std.testing.expect(!isSupportedFileType("application/octet-stream"));
}

test "isPdfMimeType" {
    try std.testing.expect(isPdfMimeType("application/pdf"));
    try std.testing.expect(!isPdfMimeType("image/png"));
    try std.testing.expect(!isPdfMimeType("text/plain"));
}

test "parseFileId extracts file ID from response" {
    const allocator = std.testing.allocator;

    const response =
        \\{"id":"file-abc123","type":"file","filename":"test.pdf"}
    ;

    const file_id = try parseFileId(allocator, response);
    defer allocator.free(file_id);
    try std.testing.expectEqualStrings("file-abc123", file_id);
}

test "FileUploadResult lifecycle" {
    const allocator = std.testing.allocator;

    // Test success result
    const file_id = try allocator.dupe(u8, "file-xyz789");
    var result = FileUploadResult.success(file_id);
    try std.testing.expect(result.isSuccess());
    try std.testing.expectEqualStrings("file-xyz789", result.getFileId().?);
    result.deinit(allocator);

    // Test error result (no allocation)
    var err_result = FileUploadResult.err("Upload failed");
    try std.testing.expect(!err_result.isSuccess());
    try std.testing.expect(err_result.getFileId() == null);
    err_result.deinit(allocator); // No-op for errors
}

test "base64Encode" {
    const allocator = std.testing.allocator;

    // Test basic encoding
    const encoded = try base64Encode(allocator, "Hello");
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("SGVsbG8=", encoded);

    // Test empty string
    const empty = try base64Encode(allocator, "");
    defer allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);

    // Test padding cases
    const one_byte = try base64Encode(allocator, "M");
    defer allocator.free(one_byte);
    try std.testing.expectEqualStrings("TQ==", one_byte);

    const two_bytes = try base64Encode(allocator, "Ma");
    defer allocator.free(two_bytes);
    try std.testing.expectEqualStrings("TWE=", two_bytes);
}

test "getFileName extracts filename from path" {
    try std.testing.expectEqualStrings("file.txt", getFileName("/path/to/file.txt"));
    try std.testing.expectEqualStrings("image.png", getFileName("image.png"));
    try std.testing.expectEqualStrings("doc.pdf", getFileName("/a/b/c/doc.pdf"));
}

// =============================================================================
// SSE Tests
// =============================================================================
//
// These cover the pure SSE helpers — `parseSseTextDelta` and `trimCr`. The
// `readSseStream` loop itself isn't exercised here because it requires a
// live `Io.Reader`; the helpers carry the parsing contract so unit tests
// against the wire format are sufficient. Sample payloads come from the
// Anthropic streaming docs (see docs.claude.com → Streaming Messages).

test "parseSseTextDelta extracts text from content_block_delta" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
    ;

    const text = (try parseSseTextDelta(allocator, payload)) orelse return error.TestExpectedNonNull;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("Hello", text);
}

test "parseSseTextDelta returns null for non-text_delta events" {
    const allocator = std.testing.allocator;

    // ping — no delta at all.
    const ping = "{\"type\": \"ping\"}";
    try std.testing.expect((try parseSseTextDelta(allocator, ping)) == null);

    // message_start — has a `message` field but no `delta.text`.
    const message_start =
        \\{"type":"message_start","message":{"id":"msg_x","role":"assistant","content":[]}}
    ;
    try std.testing.expect((try parseSseTextDelta(allocator, message_start)) == null);

    // content_block_stop — content_block_delta sibling but no text payload.
    const stop =
        \\{"type":"content_block_stop","index":0}
    ;
    try std.testing.expect((try parseSseTextDelta(allocator, stop)) == null);
}

test "parseSseTextDelta ignores input_json_delta (tool use) events" {
    // We deliberately surface only `text_delta`. Tool-use partial JSON
    // would corrupt the assistant message bubble if it leaked through.
    const allocator = std.testing.allocator;
    const payload =
        \\{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"location\":"}}
    ;
    try std.testing.expect((try parseSseTextDelta(allocator, payload)) == null);
}

test "parseSseTextDelta ignores thinking_delta events" {
    // Extended-thinking content streams via a separate delta type. We
    // ignore it for the chat surface — exposing private reasoning would
    // be the wrong UX.
    const allocator = std.testing.allocator;
    const payload =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"step 1"}}
    ;
    try std.testing.expect((try parseSseTextDelta(allocator, payload)) == null);
}

test "parseSseTextDelta handles JSON-escaped text" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"line1\nline2\t\"quoted\""}}
    ;

    const text = (try parseSseTextDelta(allocator, payload)) orelse return error.TestExpectedNonNull;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("line1\nline2\t\"quoted\"", text);
}

test "parseSseTextDelta returns null for empty text" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""}}
    ;
    try std.testing.expect((try parseSseTextDelta(allocator, payload)) == null);
}

test "parseSseTextDelta truncates oversized text to MAX_DELTA_TEXT_LEN" {
    // A pathological server could emit a `text_delta` larger than our
    // bound. Truncation is the right behavior — fail closed with a
    // visible-but-bounded chunk rather than allowing an unbounded
    // dupe(). Build the input dynamically so the test source stays
    // readable even when MAX_DELTA_TEXT_LEN moves.
    const allocator = std.testing.allocator;
    const oversize_len = MAX_DELTA_TEXT_LEN + 1024;

    const payload_buf = try allocator.alloc(u8, oversize_len + 128);
    defer allocator.free(payload_buf);

    var w: Io.Writer = .fixed(payload_buf);
    try w.writeAll("{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"");
    var i: usize = 0;
    while (i < oversize_len) : (i += 1) try w.writeByte('a');
    try w.writeAll("\"}}");

    const text = (try parseSseTextDelta(allocator, w.buffered())) orelse return error.TestExpectedNonNull;
    defer allocator.free(text);
    try std.testing.expectEqual(@as(usize, MAX_DELTA_TEXT_LEN), text.len);
}

test "parseSseTextDelta surfaces parse errors for malformed JSON" {
    const allocator = std.testing.allocator;
    const payload = "not json at all";
    try std.testing.expectError(error.SyntaxError, parseSseTextDelta(allocator, payload));
}

test "trimCr strips trailing carriage return" {
    try std.testing.expectEqualStrings("hello", trimCr("hello\r"));
    try std.testing.expectEqualStrings("hello", trimCr("hello"));
    try std.testing.expectEqualStrings("", trimCr(""));
    try std.testing.expectEqualStrings("", trimCr("\r"));
    // Only the last \r is stripped — embedded \r should pass through.
    try std.testing.expectEqualStrings("a\rb", trimCr("a\rb"));
}

// =============================================================================
// Retry / Backoff Tests
// =============================================================================
//
// We test the pure classification + parsing helpers in isolation. The
// retry loop itself isn't easily unit-testable without a fake `Io`
// (we'd need a mock that records sleep durations and a fake HTTP
// transport that replays scripted responses). Instead we exercise the
// loop in live runs via `log.info` retry traces — see `fetchWithRetry`.

test "classifyHttpStatus retry-worthy codes" {
    // Anthropic-specific: 429 (rate_limit_error), 529 (overloaded_error).
    // 408 is also retried — it's almost always a transient client/server
    // desync rather than a stable rejection.
    try std.testing.expect(classifyHttpStatus(@enumFromInt(408)) == error.Transient);
    try std.testing.expect(classifyHttpStatus(@enumFromInt(429)) == error.Transient);
    try std.testing.expect(classifyHttpStatus(@enumFromInt(529)) == error.Transient);

    // 5xx server errors: server is recovering, retrying typically helps.
    try std.testing.expect(classifyHttpStatus(.internal_server_error) == error.Transient);
    try std.testing.expect(classifyHttpStatus(.bad_gateway) == error.Transient);
    try std.testing.expect(classifyHttpStatus(.service_unavailable) == error.Transient);
    try std.testing.expect(classifyHttpStatus(.gateway_timeout) == error.Transient);
}

test "classifyHttpStatus permanent codes" {
    // Anthropic 4xx errors: deterministic, retrying cannot help.
    try std.testing.expect(classifyHttpStatus(.bad_request) == error.Permanent);
    try std.testing.expect(classifyHttpStatus(.unauthorized) == error.Permanent);
    try std.testing.expect(classifyHttpStatus(.payment_required) == error.Permanent);
    try std.testing.expect(classifyHttpStatus(.forbidden) == error.Permanent);
    try std.testing.expect(classifyHttpStatus(.not_found) == error.Permanent);
    try std.testing.expect(classifyHttpStatus(.payload_too_large) == error.Permanent);
    try std.testing.expect(classifyHttpStatus(.unprocessable_entity) == error.Permanent);

    // 200 OK isn't a "failure" but exercises the else arm — classifying
    // a success would be a programmer error in the call site, but the
    // function should not panic on it.
    try std.testing.expect(classifyHttpStatus(.ok) == error.Permanent);
}

test "parseRetryAfterSeconds parses integer seconds" {
    try std.testing.expectEqual(@as(?u64, 5), parseRetryAfterSeconds("5"));
    try std.testing.expectEqual(@as(?u64, 60), parseRetryAfterSeconds("60"));
    try std.testing.expectEqual(@as(?u64, 0), parseRetryAfterSeconds("0"));
    // Whitespace tolerated — RFC 7230 allows surrounding OWS.
    try std.testing.expectEqual(@as(?u64, 30), parseRetryAfterSeconds("  30  "));
    try std.testing.expectEqual(@as(?u64, 12), parseRetryAfterSeconds("\t12"));
}

test "parseRetryAfterSeconds rejects HTTP-date and garbage" {
    // RFC 7231 § 7.1.3 also allows an HTTP-date format. We don't
    // support it (Anthropic emits seconds), so we return null and the
    // caller falls back to plain exponential backoff. Better than
    // crashing on an unparseable date.
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds("Wed, 21 Oct 2015 07:28:00 GMT"));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds(""));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds("   "));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds("not-a-number"));
    // Negative values are nonsensical for a delay; parseInt(u64) rejects.
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfterSeconds("-5"));
}
