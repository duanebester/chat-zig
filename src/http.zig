//! Anthropic HTTP Client
//!
//! Handles communication with Anthropic's Messages API.
//! Uses std.http.Client for HTTP requests.

const std = @import("std");
const log = std.log.scoped(.chatzig);
const http = std.http;
const Uri = std.Uri;
const Allocator = std.mem.Allocator;

const state_mod = @import("state.zig");
const AppState = state_mod.AppState;
const Message = state_mod.Message;
const MessageRole = state_mod.MessageRole;

// =============================================================================
// Constants
// =============================================================================

const API_URL = "https://api.anthropic.com/v1/messages";
const MAX_TOKENS: u32 = 4096;
const MAX_RESPONSE_SIZE: usize = 1024 * 1024; // 1MB
const MAX_REQUEST_SIZE: usize = 64 * 1024; // 64KB

// =============================================================================
// API Response Types (for std.json parsing)
// =============================================================================

const ContentBlock = struct {
    type: []const u8,
    text: ?[]const u8 = null,
};

const ApiResponse = struct {
    content: []const ContentBlock,
};

// =============================================================================
// Anthropic Client
// =============================================================================

pub const AnthropicClient = struct {
    const Self = @This();

    api_key: []const u8,
    allocator: Allocator = std.heap.page_allocator,

    pub fn init(api_key: []const u8) Self {
        std.debug.assert(api_key.len > 0);
        return .{ .api_key = api_key };
    }

    pub fn sendMessage(self: *Self, app: *AppState) !void {
        std.debug.assert(app.message_count > 0);
        // Spawn a thread for the HTTP request
        const thread = try std.Thread.spawn(.{}, httpWorker, .{ self, app });
        thread.detach();
    }

    fn httpWorker(self: *Self, app: *AppState) void {
        self.doRequest(app) catch |err| {
            log.err("HTTP request failed: {}", .{err});
            app.onApiError("Request failed");
        };
    }

    fn doRequest(self: *Self, app: *AppState) !void {
        var client = http.Client{ .allocator = self.allocator };
        defer client.deinit();

        // Build messages array for API
        var json_buf: [MAX_REQUEST_SIZE]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&json_buf);
        const writer = fbs.writer();

        const model_name = app.selected_model.apiName();
        try writer.print("{{\"model\":\"{s}\",\"max_tokens\":{d},\"messages\":[", .{ model_name, MAX_TOKENS });

        // Add conversation history
        var first = true;
        for (0..app.message_count) |i| {
            const msg = &app.messages[i];
            if (msg.role == .system) continue;

            if (!first) try writer.writeAll(",");
            first = false;

            try writer.print("{{\"role\":\"{s}\",\"content\":\"", .{if (msg.role == .user) "user" else "assistant"});

            // Escape the content (JSON string escaping per RFC 8259)
            try writeJsonEscapedString(writer, msg.content[0..msg.content_len]);
            try writer.writeAll("\"}");
        }

        try writer.writeAll("]}");

        const body = fbs.getWritten();

        // Assert buffer didn't overflow (would have errored, but belt-and-suspenders)
        std.debug.assert(body.len < json_buf.len);
        log.debug("Request body: {s}", .{body});

        // Parse URI
        const uri = try Uri.parse(API_URL);

        // Make request
        var req = try client.request(.POST, uri, .{
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
            app.onApiError("API returned error");
            return;
        }

        // Read response body
        var transfer_buf: [64]u8 = undefined;
        var reader = response.reader(&transfer_buf);

        const response_data = reader.allocRemaining(self.allocator, std.Io.Limit.limited(MAX_RESPONSE_SIZE)) catch |err| {
            log.err("Failed to read response: {}", .{err});
            app.onApiError("Failed to read response");
            return;
        };
        defer self.allocator.free(response_data);

        std.debug.assert(response_data.len > 0);
        log.debug("Response ({d} bytes): {s}", .{ response_data.len, response_data });

        // Parse response using std.json
        var result = parseApiResponse(self.allocator, response_data) catch |err| {
            log.err("Failed to parse response: {}", .{err});
            app.onApiError("Failed to parse response");
            return;
        };
        defer result.deinit();

        app.onApiResponse(result.text);
    }
};

// =============================================================================
// JSON Helpers
// =============================================================================

/// Escapes a string for JSON output per RFC 8259.
/// Handles all control characters (0x00-0x1F), quotes, and backslashes.
fn writeJsonEscapedString(writer: anytype, str: []const u8) !void {
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

const ParsedResponse = struct {
    text: []const u8,
    parsed: std.json.Parsed(ApiResponse),

    pub fn deinit(self: *ParsedResponse) void {
        self.parsed.deinit();
    }
};

/// Parses the Anthropic API response and extracts the text content.
/// Uses std.json for robust parsing with proper escape handling.
/// Caller must call deinit() on the returned ParsedResponse when done.
fn parseApiResponse(allocator: Allocator, json_data: []const u8) !ParsedResponse {
    const parsed = std.json.parseFromSlice(ApiResponse, allocator, json_data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.err("JSON parse error: {}", .{err});
        return error.JsonParseError;
    };

    // Find the first text content block
    for (parsed.value.content) |block| {
        if (std.mem.eql(u8, block.type, "text")) {
            if (block.text) |text| {
                std.debug.assert(text.len > 0);
                return .{ .text = text, .parsed = parsed };
            }
        }
    }

    // No text found - clean up and return error
    var mutable_parsed = parsed;
    mutable_parsed.deinit();
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

test "parseApiResponse extracts text content" {
    const allocator = std.testing.allocator;
    const json =
        \\{"content":[{"type":"text","text":"Hello, world!"}],"model":"claude"}
    ;

    var result = try parseApiResponse(allocator, json);
    defer result.deinit();
    try std.testing.expectEqualStrings("Hello, world!", result.text);
}

test "parseApiResponse handles escaped content" {
    const allocator = std.testing.allocator;
    const json =
        \\{"content":[{"type":"text","text":"Line1\nLine2"}],"model":"claude"}
    ;

    var result = try parseApiResponse(allocator, json);
    defer result.deinit();
    try std.testing.expectEqualStrings("Line1\nLine2", result.text);
}
