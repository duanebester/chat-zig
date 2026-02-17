//! Canvas State Management for ChatAI
//!
//! Manages a single AiCanvas buffer for LLM-driven drawing. All canvas
//! mutations happen on the main thread (via dispatch from HTTP worker),
//! so no synchronization primitives are needed.
//!
//! Processing pipeline:
//!   1. HTTP worker receives tool_use blocks in Anthropic API response
//!   2. Worker calls reconstructJsonLine() to convert each block to
//!      parseCommand format: {"tool":"fill_rect","x":0,...}
//!   3. Reconstructed lines are staged in AppState.pending_canvas_buf
//!   4. Main thread dispatch calls processBatch() → pushes into canvas
//!   5. paintCanvas() replays commands each frame via ui.canvas()
//!
//! Thread safety:
//!   - reconstructJsonLine / writeJsonValue are pure (no global state)
//!     → safe to call from any thread (HTTP worker)
//!   - processLine / processBatch / clearCanvas mutate the global canvas
//!     → main thread only

const std = @import("std");
const log = std.log.scoped(.canvas);
const gooey = @import("gooey");
const ai = gooey.ai;
const AiCanvas = ai.AiCanvas;
const ui = gooey.ui;
const Theme = ui.Theme;

// =============================================================================
// Constants (CLAUDE.md #4: put a limit on everything)
// =============================================================================

/// Logical canvas dimensions. The system prompt tells the LLM these bounds.
pub const CANVAS_WIDTH: f32 = 500;
pub const CANVAS_HEIGHT: f32 = 400;

/// Fixed scratch buffer for JSON parsing inside processLine.
/// Avoids heap allocation during command processing (CLAUDE.md #2).
const JSON_PARSE_BUF_SIZE: usize = 64 * 1024;

/// Maximum staging buffer for canvas command JSON lines from one API response.
pub const MAX_CANVAS_BUF: usize = 32 * 1024;

/// Hard cap on tool_use blocks processed per API response.
pub const MAX_TOOL_USE_PER_RESPONSE: usize = 256;

/// Maximum bytes per reconstructed JSON line (matches json_parser constant).
const MAX_LINE_BUF: usize = ai.MAX_JSON_LINE_SIZE;

/// Maximum number of input fields per tool_use block.
const MAX_INPUT_FIELDS: u32 = 32;

// =============================================================================
// Global State (single-buffer, main-thread only)
// =============================================================================

/// The canvas command buffer. ~280KB — lives in global state, never on stack.
/// Only `commands[0..command_count]` contains valid data.
var canvas: AiCanvas = .{};

/// Active theme for semantic color resolution at paint time.
/// Points to gooey's built-in Theme.dark or Theme.light.
var active_theme: *const Theme = &Theme.dark;

/// Monotonically increasing count of commands pushed across all batches.
var total_commands: u32 = 0;

/// Whether the canvas has any content worth displaying.
var content_present: bool = false;

// =============================================================================
// Query API (read-only, safe from render thread)
// =============================================================================

/// Returns true if the canvas has at least one command to display.
pub fn hasContent() bool {
    std.debug.assert(canvas.command_count <= ai.MAX_DRAW_COMMANDS);
    return content_present;
}

/// Returns the number of commands in the current canvas batch.
pub fn commandCount() usize {
    std.debug.assert(canvas.command_count <= ai.MAX_DRAW_COMMANDS);
    return canvas.commandCount();
}

/// Returns lifetime total of commands successfully pushed.
pub fn totalCommandsProcessed() u32 {
    std.debug.assert(total_commands <= ai.MAX_DRAW_COMMANDS * 1024);
    return total_commands;
}

// =============================================================================
// Theme Management
// =============================================================================

/// Update the active theme for paint-time ThemeColor resolution.
/// Called each frame from the render function before painting.
pub fn setTheme(dark_mode: bool) void {
    active_theme = if (dark_mode) &Theme.dark else &Theme.light;
    std.debug.assert(@intFromPtr(active_theme) != 0);
}

// =============================================================================
// Paint Callback — wired to ui.canvas()
// =============================================================================

/// Paint callback for `ui.canvas(CANVAS_WIDTH, CANVAS_HEIGHT, paintCanvas)`.
/// Replays all buffered commands into the DrawContext each frame.
pub fn paintCanvas(ctx: *ui.DrawContext) void {
    std.debug.assert(canvas.command_count <= ai.MAX_DRAW_COMMANDS);
    std.debug.assert(@intFromPtr(active_theme) != 0);
    canvas.replay(ctx, active_theme);
}

// =============================================================================
// Command Processing (main thread only)
// =============================================================================

/// Process a single JSON line into a canvas DrawCommand.
///
/// The line must be in parseCommand format:
///   `{"tool":"fill_rect","x":0,"y":0,"w":100,"h":50,"color":"FF0000"}`
///
/// Returns true if the command was successfully parsed and pushed.
/// Returns false on malformed input, unknown tool, full buffer, etc.
pub fn processLine(json_line: []const u8) bool {
    std.debug.assert(json_line.len <= ai.MAX_JSON_LINE_SIZE);
    if (json_line.len == 0) return false;

    // Fixed scratch buffer for JSON parsing — no heap (CLAUDE.md #2).
    var parse_buf: [JSON_PARSE_BUF_SIZE]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_buf);

    const cmd = ai.parseCommand(
        fba.allocator(),
        json_line,
        &canvas.texts,
    ) orelse return false;

    const pushed = canvas.pushCommand(cmd);
    if (pushed) {
        total_commands += 1;
        content_present = true;
    }
    return pushed;
}

/// Process a batch of newline-separated JSON lines.
///
/// Each non-empty line is parsed as a DrawCommand and pushed to the canvas.
/// Returns the number of commands successfully processed.
pub fn processBatch(data: []const u8) u32 {
    std.debug.assert(data.len <= MAX_CANVAS_BUF);
    if (data.len == 0) return 0;

    var count: u32 = 0;
    var iter = std.mem.splitScalar(u8, data, '\n');

    // CLAUDE.md #4: hard cap on iterations.
    var iterations: u32 = 0;
    while (iter.next()) |line| {
        if (iterations >= MAX_TOOL_USE_PER_RESPONSE) break;
        iterations += 1;

        const trimmed = std.mem.trim(u8, line, &[_]u8{ ' ', '\t', '\r' });
        if (trimmed.len == 0) continue;

        if (processLine(trimmed)) {
            count += 1;
        }
    }

    if (count > 0) {
        log.info("Processed {d} draw commands ({d} total)", .{ count, total_commands });
    }
    return count;
}

/// Clear all canvas content and reset counters.
/// Call this at the start of each new user drawing request.
pub fn clearCanvas() void {
    std.debug.assert(canvas.command_count <= ai.MAX_DRAW_COMMANDS);
    canvas.clearAll();
    content_present = false;
    log.info("Canvas cleared", .{});
}

// =============================================================================
// JSON Line Reconstruction (pure functions — thread-safe)
//
// Anthropic tool_use format:
//   { "type":"tool_use", "id":"toolu_xxx", "name":"fill_rect",
//     "input": { "x":0, "y":0, "w":100, "h":50, "color":"FF0000" } }
//
// Gooey parseCommand format:
//   { "tool":"fill_rect", "x":0, "y":0, "w":100, "h":50, "color":"FF0000" }
//
// reconstructJsonLine flattens the tool_use input into parseCommand format.
// =============================================================================

/// Reconstruct a JSON line from a tool name and its input object map.
///
/// Writes `{"tool":"<name>", ...input_fields...}` into `buf`.
/// Returns the written slice, or null if the buffer overflows or
/// the input contains unsupported value types.
///
/// Pure function — no global state, safe to call from any thread.
pub fn reconstructJsonLine(
    buf: []u8,
    tool_name: []const u8,
    input: std.json.ObjectMap,
) ?[]const u8 {
    // CLAUDE.md #3: assert inputs are reasonable.
    std.debug.assert(tool_name.len > 0);
    std.debug.assert(buf.len >= 64);

    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    writer.writeAll("{\"tool\":\"") catch return null;
    writer.writeAll(tool_name) catch return null;
    writer.writeByte('"') catch return null;

    // Flatten input object fields into the top-level JSON object.
    var iter = input.iterator();
    var field_count: u32 = 0;

    while (iter.next()) |entry| {
        // CLAUDE.md #4: cap field count.
        if (field_count >= MAX_INPUT_FIELDS) break;
        field_count += 1;

        writer.writeAll(",\"") catch return null;
        writer.writeAll(entry.key_ptr.*) catch return null;
        writer.writeAll("\":") catch return null;
        writeJsonValue(writer, entry.value_ptr.*) catch return null;
    }

    writer.writeByte('}') catch return null;
    return fbs.getWritten();
}

/// Serialize a single std.json.Value to JSON text.
///
/// Supports string, integer, float, bool, null — the types used by
/// drawing tool inputs. Arrays and objects return error.UnsupportedType.
///
/// Pure function — no global state, safe to call from any thread.
pub fn writeJsonValue(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .string => |s| {
            try writer.writeByte('"');
            try writeEscapedString(writer, s);
            try writer.writeByte('"');
        },
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .null => try writer.writeAll("null"),
        .number_string => |s| try writer.writeAll(s),
        .array, .object => return error.UnsupportedType,
    }
}

/// Write a JSON-escaped string (without surrounding quotes).
/// Escapes quotes, backslashes, and control characters.
fn writeEscapedString(writer: anytype, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x07, 0x0B, 0x0E...0x1F => {
                const hex = "0123456789abcdef";
                try writer.writeAll("\\u00");
                try writer.writeByte(hex[c >> 4]);
                try writer.writeByte(hex[c & 0x0F]);
            },
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => try writer.writeByte(c),
        }
    }
}

// =============================================================================
// Anthropic Response Extraction (pure functions — thread-safe)
//
// These functions extract tool_use blocks and text from a raw Anthropic
// API response. Called by the HTTP worker thread.
// =============================================================================

/// Extract tool_use blocks from a parsed Anthropic content array and
/// reconstruct them as newline-separated JSON lines in `out_buf`.
///
/// Returns the number of bytes written to `out_buf`.
/// Pure function — safe to call from the HTTP worker thread.
pub fn extractToolUseLines(
    out_buf: []u8,
    content_array: []const std.json.Value,
) usize {
    std.debug.assert(out_buf.len > 0);
    std.debug.assert(content_array.len <= MAX_TOOL_USE_PER_RESPONSE * 2);

    var offset: usize = 0;
    var line_buf: [MAX_LINE_BUF]u8 = undefined;
    const max_blocks = @min(content_array.len, MAX_TOOL_USE_PER_RESPONSE);

    for (content_array[0..max_blocks]) |block| {
        const tool_name = extractToolName(block) orelse continue;
        const input_obj = extractInputObject(block) orelse continue;

        const line = reconstructJsonLine(&line_buf, tool_name, input_obj) orelse continue;

        // Ensure we don't overflow the output buffer.
        if (offset + line.len + 1 > out_buf.len) break;

        @memcpy(out_buf[offset..][0..line.len], line);
        offset += line.len;
        out_buf[offset] = '\n';
        offset += 1;
    }

    return offset;
}

/// Extract text content from a parsed Anthropic content array.
///
/// Concatenates all "text" type blocks, separated by newlines.
/// Returns the number of bytes written to `out_buf`.
/// Pure function — safe to call from the HTTP worker thread.
pub fn extractTextContent(
    out_buf: []u8,
    content_array: []const std.json.Value,
) usize {
    std.debug.assert(out_buf.len > 0);

    var offset: usize = 0;

    for (content_array) |block| {
        const obj = switch (block) {
            .object => |o| o,
            else => continue,
        };

        const type_val = obj.get("type") orelse continue;
        const type_str = switch (type_val) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, type_str, "text")) continue;

        const text_val = obj.get("text") orelse continue;
        const text = switch (text_val) {
            .string => |s| s,
            else => continue,
        };

        // Append separator if not first.
        if (offset > 0 and offset + 1 < out_buf.len) {
            out_buf[offset] = '\n';
            offset += 1;
        }

        const copy_len = @min(text.len, out_buf.len - offset);
        if (copy_len == 0) break;

        @memcpy(out_buf[offset..][0..copy_len], text[0..copy_len]);
        offset += copy_len;
    }

    return offset;
}

/// Extract all tool_use IDs from a content array.
///
/// Writes IDs as newline-separated strings into `out_buf`.
/// Returns the number of bytes written. Used for sending tool results
/// back to the API in a continuation loop.
pub fn extractToolUseIds(
    out_buf: []u8,
    content_array: []const std.json.Value,
) usize {
    std.debug.assert(out_buf.len > 0);

    var offset: usize = 0;

    for (content_array) |block| {
        const obj = switch (block) {
            .object => |o| o,
            else => continue,
        };

        // Only tool_use blocks have IDs.
        const type_val = obj.get("type") orelse continue;
        const type_str = switch (type_val) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, type_str, "tool_use")) continue;

        const id_val = obj.get("id") orelse continue;
        const id_str = switch (id_val) {
            .string => |s| s,
            else => continue,
        };

        // Append separator if not first.
        if (offset > 0 and offset + 1 < out_buf.len) {
            out_buf[offset] = '\n';
            offset += 1;
        }

        const copy_len = @min(id_str.len, out_buf.len - offset);
        if (copy_len == 0) break;

        @memcpy(out_buf[offset..][0..copy_len], id_str[0..copy_len]);
        offset += copy_len;
    }

    return offset;
}

// =============================================================================
// Internal Helpers
// =============================================================================

/// Extract tool name from a content block if it's a tool_use type.
fn extractToolName(block: std.json.Value) ?[]const u8 {
    const obj = switch (block) {
        .object => |o| o,
        else => return null,
    };

    const type_val = obj.get("type") orelse return null;
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return null,
    };
    if (!std.mem.eql(u8, type_str, "tool_use")) return null;

    const name_val = obj.get("name") orelse return null;
    return switch (name_val) {
        .string => |s| s,
        else => null,
    };
}

/// Extract the input ObjectMap from a tool_use content block.
fn extractInputObject(block: std.json.Value) ?std.json.ObjectMap {
    const obj = switch (block) {
        .object => |o| o,
        else => return null,
    };

    const input_val = obj.get("input") orelse return null;
    return switch (input_val) {
        .object => |o| o,
        else => null,
    };
}

// =============================================================================
// Compile-time Assertions (CLAUDE.md #3)
// =============================================================================

comptime {
    // Canvas buffer must fit comfortably in memory.
    std.debug.assert(@sizeOf(AiCanvas) < 300 * 1024);

    // Staging buffer must hold at least a few lines.
    std.debug.assert(MAX_CANVAS_BUF >= MAX_LINE_BUF * 4);

    // Block limit must be reasonable.
    std.debug.assert(MAX_TOOL_USE_PER_RESPONSE >= 16);
    std.debug.assert(MAX_TOOL_USE_PER_RESPONSE <= 4096);
}
