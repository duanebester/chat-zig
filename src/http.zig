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
    /// Optional system prompt (e.g. canvas instructions)
    system: ?[]const u8 = null,
    /// Optional Anthropic-format tools JSON array string (comptime-generated).
    /// When non-null, included verbatim in the request body as `"tools":<json>`.
    tools_json: ?[]const u8 = null,
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

/// Read a file and prepare it as an attachment
pub fn readFileAttachment(allocator: Allocator, path: []const u8) !FileAttachment {
    const mime_type = getMimeType(path);

    // Check if file type is supported
    if (!isSupportedFileType(mime_type)) {
        log.err("Unsupported file type: {s} (only images, text files, and PDFs are supported)", .{mime_type});
        return error.UnsupportedFileType;
    }

    const file = std.fs.openFileAbsolute(path, .{}) catch |e| {
        log.err("Failed to open file {s}: {}", .{ path, e });
        return error.FileOpenFailed;
    };
    defer file.close();

    const stat = file.stat() catch |e| {
        log.err("Failed to stat file: {}", .{e});
        return error.FileStatFailed;
    };

    if (stat.size > MAX_FILE_SIZE) {
        log.err("File too large: {} bytes (max {})", .{ stat.size, MAX_FILE_SIZE });
        return error.FileTooLarge;
    }

    const content = file.readToEndAlloc(allocator, MAX_FILE_SIZE) catch |e| {
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

/// Upload a file to the Anthropic Files API (required for PDFs)
/// Returns a FileUploadResult containing the file_id on success
pub fn uploadFileToFilesApi(allocator: Allocator, api_key: []const u8, attachment: FileAttachment) FileUploadResult {
    std.debug.assert(api_key.len > 0);
    std.debug.assert(attachment.content.len > 0);

    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build multipart form data
    const boundary = "----AnthropicFileBoundary";
    const file_name = getFileName(attachment.path);

    // Calculate size needed for multipart body
    // Format: --boundary\r\nContent-Disposition: form-data; name="file"; filename="..."\r\nContent-Type: ...\r\n\r\n<content>\r\n--boundary--\r\n
    const header_template = "--{s}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{s}\"\r\nContent-Type: {s}\r\n\r\n";
    const footer = "\r\n--" ++ boundary ++ "--\r\n";

    // Estimate header size (generous)
    const header_size_estimate = 256 + file_name.len + attachment.media_type.len;
    const total_size = header_size_estimate + attachment.content.len + footer.len;

    const body_buf = allocator.alloc(u8, total_size) catch {
        return FileUploadResult.err("Failed to allocate upload buffer");
    };
    defer allocator.free(body_buf);

    var fbs = std.io.fixedBufferStream(body_buf);
    const writer = fbs.writer();

    // Write multipart header
    writer.print(header_template, .{ boundary, file_name, attachment.media_type }) catch {
        return FileUploadResult.err("Failed to write multipart header");
    };

    // Write file content
    writer.writeAll(attachment.content) catch {
        return FileUploadResult.err("Failed to write file content");
    };

    // Write footer
    writer.writeAll(footer) catch {
        return FileUploadResult.err("Failed to write multipart footer");
    };

    const body = fbs.getWritten();
    if (LOG_PAYLOADS) {
        log.debug("Files API upload: {d} bytes for {s}", .{ body.len, file_name });
    }

    // Build content-type header with boundary
    var content_type_buf: [128]u8 = undefined;
    const content_type = std.fmt.bufPrint(&content_type_buf, "multipart/form-data; boundary={s}", .{boundary}) catch {
        return FileUploadResult.err("Failed to format content type");
    };

    // Parse URI
    const uri = Uri.parse(FILES_API_URL) catch {
        return FileUploadResult.err("Failed to parse Files API URL");
    };

    // Make request
    var req = client.request(.POST, uri, .{
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = content_type },
            .{ .name = "x-api-key", .value = api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "anthropic-beta", .value = "files-api-2025-04-14" },
        },
    }) catch {
        return FileUploadResult.err("Failed to create upload request");
    };
    defer req.deinit();

    // Send body
    req.transfer_encoding = .{ .content_length = body.len };
    req.sendBodyComplete(body) catch {
        return FileUploadResult.err("Failed to send upload request");
    };

    // Receive response
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch {
        return FileUploadResult.err("Failed to receive upload response");
    };

    if (response.head.status != .ok) {
        log.err("Files API error: {}", .{response.head.status});
        return FileUploadResult.err("Files API returned error");
    }

    // Read response body
    var transfer_buf: [64]u8 = undefined;
    var reader = response.reader(&transfer_buf);

    const response_data = reader.allocRemaining(allocator, std.Io.Limit.limited(MAX_RESPONSE_SIZE)) catch {
        return FileUploadResult.err("Failed to read upload response");
    };
    defer allocator.free(response_data);

    if (LOG_PAYLOADS) {
        log.debug("Files API response: {s}", .{response_data});
    }

    // Parse response to extract file_id
    // Response format: {"id":"file-xxx","type":"file",...}
    const file_id = parseFileId(allocator, response_data) catch {
        log.err("Failed to parse file_id from response: {s}", .{response_data});
        return FileUploadResult.err("Failed to parse upload response");
    };

    return FileUploadResult.success(file_id);
}

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
// Canvas Result (for tool-use based drawing)
// =============================================================================

pub const MAX_CANVAS_LINES_BUF: usize = 32 * 1024;
pub const MAX_CANVAS_TEXT_BUF: usize = 32 * 1024;

/// Result from a canvas-enabled API call. Contains byte counts for data
/// written to caller-provided buffers (canvas command lines + text content).
/// Small struct — actual data lives in the caller's staging buffers.
pub const CanvasResult = struct {
    /// Bytes written to the canvas_lines output buffer.
    canvas_lines_len: usize = 0,
    /// Bytes written to the text output buffer.
    text_len: usize = 0,
    /// Whether an error occurred during the request.
    has_error: bool = false,
    /// Static error message (not allocated, no cleanup needed).
    error_message: []const u8 = "",

    pub fn err(msg: []const u8) CanvasResult {
        return .{ .has_error = true, .error_message = msg };
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

    pub fn init(api_key: []const u8, allocator: Allocator) Self {
        std.debug.assert(api_key.len > 0);
        return .{ .api_key = api_key, .allocator = allocator };
    }

    /// Blocking HTTP request - call from a background thread.
    /// Returns a ChatResult that the caller must deinit().
    pub fn sendBlocking(self: *Self, request: ChatRequest) ChatResult {
        std.debug.assert(request.messages.len > 0);
        std.debug.assert(request.messages.len <= MAX_MESSAGES);

        return self.doRequest(request) catch |e| {
            log.err("HTTP request failed: {}", .{e});
            return ChatResult.err("Request failed");
        };
    }

    /// Send with a file attachment - reads the file, encodes if needed, and sends
    /// For PDFs: uploads via Files API first, then references by file_id
    /// For images: base64 encodes inline
    /// For text: includes content inline
    pub fn sendWithFile(self: *Self, request: ChatRequest, file_path: []const u8) ChatResult {
        // Read and prepare the file
        var attachment = readFileAttachment(self.allocator, file_path) catch |e| {
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

            var upload_result = uploadFileToFilesApi(self.allocator, self.api_key, attachment);
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

        return self.doRequest(req_with_file) catch |e| {
            log.err("HTTP request failed: {}", .{e});
            return ChatResult.err("Request failed");
        };
    }

    // =========================================================================
    // Canvas (Tool-Use) API
    // =========================================================================

    /// Send a canvas-enabled request with drawing tools. Extracts tool_use
    /// blocks as parseCommand-format JSON lines and text content into the
    /// caller-provided output buffers.
    pub fn sendForCanvas(
        self: *Self,
        request: ChatRequest,
        canvas_lines_out: []u8,
        text_out: []u8,
    ) CanvasResult {
        std.debug.assert(request.messages.len > 0);
        std.debug.assert(canvas_lines_out.len > 0);
        std.debug.assert(text_out.len > 0);

        return self.doCanvasRequest(request, canvas_lines_out, text_out) catch |e| {
            log.err("Canvas request failed: {}", .{e});
            return CanvasResult.err("Canvas request failed");
        };
    }

    /// Build and send the HTTP request for canvas, parse the response.
    fn doCanvasRequest(
        self: *Self,
        request: ChatRequest,
        canvas_out: []u8,
        text_out: []u8,
    ) !CanvasResult {
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        var body_buf: [64 * 1024]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&body_buf);
        const w = fbs.writer();

        try w.print("{{\"model\":\"{s}\",\"max_tokens\":{d}", .{ request.model, MAX_TOKENS });
        if (request.system) |sys| {
            try w.writeAll(",\"system\":\"");
            try writeJsonEscapedString(w, sys);
            try w.writeByte('"');
        }
        if (request.tools_json) |tools| {
            try w.writeAll(",\"tools\":");
            try w.writeAll(tools);
        }
        try w.writeAll(",\"messages\":[");

        var first = true;
        for (request.messages) |msg| {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("{{\"role\":\"{s}\",\"content\":\"", .{msg.role.apiName()});
            if (msg.content) |content| try writeJsonEscapedString(w, content);
            try w.writeAll("\"}");
        }
        try w.writeAll("]}");

        const body = fbs.getWritten();
        std.debug.assert(body.len < body_buf.len);
        if (LOG_PAYLOADS) log.debug("Canvas request: {s}", .{body});

        const uri = try Uri.parse(API_URL);
        var req = try client.request(.POST, uri, .{
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "x-api-key", .value = self.api_key },
                .{ .name = "anthropic-version", .value = "2023-06-01" },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        try req.sendBodyComplete(body);

        var redir_buf: [8 * 1024]u8 = undefined;
        var resp = try req.receiveHead(&redir_buf);
        if (resp.head.status != .ok) {
            log.err("Canvas API status: {}", .{resp.head.status});
            return CanvasResult.err("API returned error");
        }

        var xfer_buf: [64]u8 = undefined;
        var reader = resp.reader(&xfer_buf);
        const data = reader.allocRemaining(
            self.allocator,
            std.Io.Limit.limited(MAX_RESPONSE_SIZE),
        ) catch return CanvasResult.err("Failed to read response");
        defer self.allocator.free(data);

        if (LOG_PAYLOADS) log.debug("Canvas resp: {s}", .{data});
        return parseCanvasResponse(self.allocator, data, canvas_out, text_out);
    }

    /// Parse raw API JSON, extracting tool_use blocks as JSON command lines
    /// and text blocks into separate output buffers.
    fn parseCanvasResponse(
        allocator: Allocator,
        data: []const u8,
        canvas_out: []u8,
        text_out: []u8,
    ) CanvasResult {
        std.debug.assert(data.len > 0);

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            data,
            .{},
        ) catch return CanvasResult.err("JSON parse failed");
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |o| o,
            else => return CanvasResult.err("Not a JSON object"),
        };
        const content_items = switch (root.get("content") orelse
            return CanvasResult.err("No content")) {
            .array => |a| a.items,
            else => return CanvasResult.err("Content not array"),
        };

        var result = CanvasResult{};
        var line_buf: [4096]u8 = undefined;
        var lines_off: usize = 0;

        for (content_items) |block| {
            const obj = switch (block) {
                .object => |o| o,
                else => continue,
            };
            const tstr = switch (obj.get("type") orelse continue) {
                .string => |s| s,
                else => continue,
            };

            if (std.mem.eql(u8, tstr, "tool_use")) {
                const name = switch (obj.get("name") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                const input = switch (obj.get("input") orelse continue) {
                    .object => |o| o,
                    else => continue,
                };
                const n = writeToolUseLine(&line_buf, name, input);
                if (n > 0 and lines_off + n + 1 <= canvas_out.len) {
                    @memcpy(canvas_out[lines_off..][0..n], line_buf[0..n]);
                    lines_off += n;
                    canvas_out[lines_off] = '\n';
                    lines_off += 1;
                }
            } else if (std.mem.eql(u8, tstr, "text")) {
                const txt = switch (obj.get("text") orelse continue) {
                    .string => |s| s,
                    else => continue,
                };
                if (result.text_len > 0 and result.text_len < text_out.len) {
                    text_out[result.text_len] = '\n';
                    result.text_len += 1;
                }
                const clen = @min(txt.len, text_out.len - result.text_len);
                if (clen > 0) {
                    @memcpy(text_out[result.text_len..][0..clen], txt[0..clen]);
                    result.text_len += clen;
                }
            }
        }

        result.canvas_lines_len = lines_off;
        return result;
    }

    /// Reconstruct a parseCommand-format JSON line from tool name + input.
    /// Returns bytes written, or 0 on buffer overflow.
    fn writeToolUseLine(buf: []u8, name: []const u8, input: std.json.ObjectMap) usize {
        var fbs = std.io.fixedBufferStream(buf);
        const tw = fbs.writer();

        tw.writeAll("{\"tool\":\"") catch return 0;
        tw.writeAll(name) catch return 0;
        tw.writeByte('"') catch return 0;

        var iter = input.iterator();
        while (iter.next()) |entry| {
            tw.writeAll(",\"") catch return 0;
            tw.writeAll(entry.key_ptr.*) catch return 0;
            tw.writeAll("\":") catch return 0;
            writeJsonVal(tw, entry.value_ptr.*) catch return 0;
        }

        tw.writeByte('}') catch return 0;
        return fbs.getWritten().len;
    }

    /// Serialize a std.json.Value to JSON text (for tool_use reconstruction).
    fn writeJsonVal(tw: anytype, value: std.json.Value) !void {
        switch (value) {
            .string => |s| {
                try tw.writeByte('"');
                try writeJsonEscapedString(tw, s);
                try tw.writeByte('"');
            },
            .integer => |i| try tw.print("{d}", .{i}),
            .float => |f| try tw.print("{d}", .{f}),
            .bool => |b| try tw.writeAll(if (b) "true" else "false"),
            .null => try tw.writeAll("null"),
            .number_string => |s| try tw.writeAll(s),
            .array, .object => try tw.writeAll("null"),
        }
    }

    fn doRequest(self: *Self, request: ChatRequest) !ChatResult {
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

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

        var fbs = std.io.fixedBufferStream(json_buf);
        const writer = fbs.writer();

        try writer.print("{{\"model\":\"{s}\",\"max_tokens\":{d}", .{ request.model, MAX_TOKENS });

        // Optional system prompt (for canvas-enabled conversations).
        if (request.system) |sys| {
            try writer.writeAll(",\"system\":\"");
            try writeJsonEscapedString(writer, sys);
            try writer.writeByte('"');
        }

        // Optional tools array (comptime-generated Anthropic format).
        if (request.tools_json) |tools| {
            try writer.writeAll(",\"tools\":");
            try writer.writeAll(tools);
        }

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

        const body = fbs.getWritten();

        // Assert buffer didn't overflow (would have errored, but belt-and-suspenders)
        std.debug.assert(body.len < json_buf.len);
        if (LOG_PAYLOADS) {
            log.debug("Request body: {s}", .{body});
        }

        // Parse URI
        const uri = try Uri.parse(API_URL);

        // Check if we need the files beta header (for PDF attachments)
        const needs_files_beta = if (request.attachment) |att| att.is_pdf and att.file_id != null else false;

        // Make request
        var req = if (needs_files_beta)
            try client.request(.POST, uri, .{
                .headers = .{
                    // Disable compression - server sends gzip by default which we don't decode
                    .accept_encoding = .{ .override = "identity" },
                },
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/json" },
                    .{ .name = "x-api-key", .value = self.api_key },
                    .{ .name = "anthropic-version", .value = "2023-06-01" },
                    .{ .name = "anthropic-beta", .value = "files-api-2025-04-14" },
                },
            })
        else
            try client.request(.POST, uri, .{
                .headers = .{
                    // Disable compression - server sends gzip by default which we don't decode
                    .accept_encoding = .{ .override = "identity" },
                },
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/json" },
                    .{ .name = "x-api-key", .value = self.api_key },
                    .{ .name = "anthropic-version", .value = "2023-06-01" },
                },
            });
        defer req.deinit();

        // Send body
        req.transfer_encoding = .{ .content_length = body.len };
        try req.sendBodyComplete(body);

        // Receive response
        var redirect_buf: [8 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            log.err("API error: {}", .{response.head.status});
            return ChatResult.err("API returned error");
        }

        // Read response body
        var transfer_buf: [64]u8 = undefined;
        var reader = response.reader(&transfer_buf);

        const response_data = reader.allocRemaining(self.allocator, std.Io.Limit.limited(MAX_RESPONSE_SIZE)) catch |e| {
            log.err("Failed to read response: {}", .{e});
            return ChatResult.err("Failed to read response");
        };
        defer self.allocator.free(response_data);

        std.debug.assert(response_data.len > 0);
        if (LOG_PAYLOADS) {
            log.debug("Response ({d} bytes): {s}", .{ response_data.len, response_data });
        }

        // Parse response and extract text
        const text = parseAndExtractText(self.allocator, response_data) catch |e| {
            log.err("Failed to parse response: {}", .{e});
            return ChatResult.err("Failed to parse response");
        };

        return ChatResult.success(text);
    }
};

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
pub fn writeJsonEscapedString(writer: anytype, str: []const u8) !void {
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
    var fbs = std.io.fixedBufferStream(&buf);

    try writeJsonEscapedString(fbs.writer(), "hello\nworld");
    try std.testing.expectEqualStrings("hello\\nworld", fbs.getWritten());

    fbs.reset();
    try writeJsonEscapedString(fbs.writer(), "tab\there");
    try std.testing.expectEqualStrings("tab\\there", fbs.getWritten());

    fbs.reset();
    try writeJsonEscapedString(fbs.writer(), "quote\"here");
    try std.testing.expectEqualStrings("quote\\\"here", fbs.getWritten());

    fbs.reset();
    try writeJsonEscapedString(fbs.writer(), "null\x00char");
    try std.testing.expectEqualStrings("null\\u0000char", fbs.getWritten());

    fbs.reset();
    try writeJsonEscapedString(fbs.writer(), "bell\x07char");
    try std.testing.expectEqualStrings("bell\\u0007char", fbs.getWritten());
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
