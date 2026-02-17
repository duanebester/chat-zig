//! Anthropic-Compatible Tool Schema for AI Canvas
//!
//! Comptime-generates the Anthropic API `tools` array from Gooey's
//! DrawCommand tagged union. Each DrawCommand variant becomes an Anthropic
//! tool with `input_schema` containing `properties` and `required` arrays.
//!
//! Anthropic format (per tool):
//!   {
//!     "name": "fill_rect",
//!     "description": "Fill a rectangle with a solid color",
//!     "input_schema": {
//!       "type": "object",
//!       "properties": {
//!         "x": { "type": "number", "description": "X position ..." },
//!         ...
//!       },
//!       "required": ["x", "y", "w", "h", "color"]
//!     }
//!   }
//!
//! Also provides a system prompt that instructs the LLM about canvas
//! dimensions, coordinate system, and drawing best practices.

const std = @import("std");
const gooey = @import("gooey");
const ai = gooey.ai;
const canvas_state = @import("canvas_state.zig");

// Import types needed for comptime field type checks.
const DrawCommand = ai.DrawCommand;
const ThemeColor = ai.ThemeColor;

// =============================================================================
// Public API
// =============================================================================

/// Complete Anthropic-format tools JSON array, generated at comptime.
/// Wire directly into the request body: `"tools":` ++ anthropic_tools_json
/// Zero runtime cost — this is a string literal baked into the binary.
pub const anthropic_tools_json: []const u8 = generateAnthropicTools();

/// Number of tools in the schema (must match DrawCommand variant count).
pub const TOOL_COUNT: usize = std.meta.fields(DrawCommand).len;

/// System prompt for canvas-enabled conversations.
/// Instructs the model about canvas size, coordinate system, and tools.
pub const canvas_system_prompt: []const u8 =
    "You have access to a drawing canvas that is 500 pixels wide and 400 pixels tall. " ++
    "The coordinate system has (0,0) at the top-left corner, with X increasing rightward " ++
    "and Y increasing downward.\n\n" ++
    "When asked to draw something, use the drawing tools to create it on the canvas. " ++
    "Always start with set_background to clear the canvas before drawing a new scene.\n\n" ++
    "Color values can be hex strings like \"FF6B35\" (without the # prefix) or semantic " ++
    "theme tokens like \"primary\", \"text\", \"surface\", \"accent\", \"danger\", \"success\" " ++
    "which adapt to the user's light/dark mode automatically.\n\n" ++
    "Tips:\n" ++
    "- Layer shapes from back to front (background first, foreground last)\n" ++
    "- Use draw_text for labels and annotations\n" ++
    "- Combine fill and stroke variants for outlined shapes\n" ++
    "- Keep coordinates within the 500x400 canvas bounds\n" ++
    "- Use font_size between 12 and 24 for readable text\n" ++
    "- Use multiple tool calls in a single response to build complex scenes";

// =============================================================================
// Comptime Schema Generator
// =============================================================================

/// Generate a complete Anthropic-format tools JSON array from DrawCommand.
/// Iterates union variants at comptime; each becomes an Anthropic tool
/// with `input_schema` derived from the variant's payload struct fields.
fn generateAnthropicTools() []const u8 {
    @setEvalBranchQuota(200_000);
    comptime {
        const fields = std.meta.fields(DrawCommand);

        // Assert expected variant count — update if DrawCommand evolves.
        std.debug.assert(fields.len == 11);

        var schema: []const u8 = "[";
        for (fields, 0..) |variant, i| {
            std.debug.assert(@typeInfo(variant.type) == .@"struct");
            schema = schema ++ emitTool(variant.name, variant.type);
            if (i < fields.len - 1) {
                schema = schema ++ ",";
            }
        }
        schema = schema ++ "]";

        // Assert tool count in output matches variant count.
        std.debug.assert(comptimeCountSubstring(schema, "\"name\":") == fields.len);

        return schema;
    }
}

/// Emit a single Anthropic tool JSON object for one DrawCommand variant.
/// `name` is the variant name (e.g. "fill_rect"), `Payload` is its struct.
fn emitTool(comptime name: []const u8, comptime Payload: type) []const u8 {
    comptime {
        std.debug.assert(name.len > 0);

        var out: []const u8 = "";
        out = out ++ "{\"name\":\"" ++ name ++ "\",";
        out = out ++ "\"description\":\"" ++ toolDescription(name) ++ "\",";
        out = out ++ "\"input_schema\":{";
        out = out ++ "\"type\":\"object\",";
        out = out ++ "\"properties\":{" ++ emitProperties(Payload) ++ "},";
        out = out ++ "\"required\":[" ++ emitRequired(Payload) ++ "]";
        out = out ++ "}}";
        return out;
    }
}

/// Emit JSON `properties` object entries for all fields of a payload struct.
fn emitProperties(comptime Payload: type) []const u8 {
    comptime {
        const param_fields = std.meta.fields(Payload);
        std.debug.assert(param_fields.len >= 1);

        var out: []const u8 = "";
        for (param_fields, 0..) |field, j| {
            const ext_name = fieldExternalName(field.name);
            const json_type = fieldJsonType(field.name, field.type);
            const desc = fieldDescription(field.name);

            out = out ++ "\"" ++ ext_name ++ "\":{";
            out = out ++ "\"type\":\"" ++ json_type ++ "\",";
            out = out ++ "\"description\":\"" ++ desc ++ "\"}";
            if (j < param_fields.len - 1) {
                out = out ++ ",";
            }
        }
        return out;
    }
}

/// Emit the `required` array entries — all fields are required for tools.
fn emitRequired(comptime Payload: type) []const u8 {
    comptime {
        const param_fields = std.meta.fields(Payload);
        std.debug.assert(param_fields.len >= 1);

        var out: []const u8 = "";
        for (param_fields, 0..) |field, j| {
            out = out ++ "\"" ++ fieldExternalName(field.name) ++ "\"";
            if (j < param_fields.len - 1) {
                out = out ++ ",";
            }
        }
        return out;
    }
}

// =============================================================================
// Comptime Lookups — Names, Types, Descriptions
//
// These mirror gooey's schema.zig mappings exactly, ensuring the Anthropic
// tool schema stays consistent with the JSON parser's expectations.
// =============================================================================

/// Map variant name to a human-readable tool description.
fn toolDescription(comptime name: []const u8) []const u8 {
    const descriptions = .{
        .{ "fill_rect", "Fill a rectangle with a solid color" },
        .{ "fill_rounded_rect", "Fill a rounded rectangle with a solid color" },
        .{ "fill_circle", "Fill a circle with a solid color" },
        .{ "fill_ellipse", "Fill an ellipse with a solid color" },
        .{ "fill_triangle", "Fill a triangle defined by three vertices" },
        .{ "stroke_rect", "Stroke a rectangle outline" },
        .{ "stroke_circle", "Stroke a circle outline" },
        .{ "line", "Draw a line between two points" },
        .{ "draw_text", "Render text at a position on the canvas" },
        .{ "draw_text_centered", "Render text vertically centered at a Y position" },
        .{ "set_background", "Fill the entire canvas with a background color" },
    };
    inline for (descriptions) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    @compileError("unknown tool variant: " ++ name);
}

/// Map internal field name to external JSON schema name.
/// Handles the text_idx → text alias; all others pass through unchanged.
fn fieldExternalName(comptime name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "text_idx")) return "text";
    std.debug.assert(name.len > 0);
    return name;
}

/// Map a field to its JSON schema type string.
/// - `f32`       → `"number"`
/// - `ThemeColor` → `"string"` (hex color or semantic theme token)
/// - `text_idx: u16` → `"string"` (schema aliasing: pool index → text)
/// - `u16` (non-aliased) → `"number"`
fn fieldJsonType(comptime name: []const u8, comptime T: type) []const u8 {
    // Schema aliasing: text_idx is u16 internally but string externally.
    if (std.mem.eql(u8, name, "text_idx")) {
        std.debug.assert(T == u16);
        return "string";
    }
    if (T == f32) return "number";
    if (T == ThemeColor) return "string";
    if (T == u16) return "number";
    @compileError("unsupported field type for schema generation");
}

/// Map field name to a human-readable parameter description.
///
/// The `"color"` description is generated at comptime from the `SemanticToken`
/// enum — if a new token is added to Theme/SemanticToken, the schema
/// description updates automatically. Single source of truth, zero drift.
fn fieldDescription(comptime name: []const u8) []const u8 {
    // Color description: derived from SemanticToken enum at comptime.
    if (std.mem.eql(u8, name, "color")) {
        return "Hex color string (e.g. FF6B35) or theme token: " ++ ai.semantic_token_list;
    }

    const descriptions = .{
        .{ "x", "X position (pixels from left)" },
        .{ "y", "Y position (pixels from top)" },
        .{ "w", "Width in pixels" },
        .{ "h", "Height in pixels" },
        .{ "cx", "Center X" },
        .{ "cy", "Center Y" },
        .{ "rx", "Horizontal radius in pixels" },
        .{ "ry", "Vertical radius in pixels" },
        .{ "radius", "Radius in pixels" },
        .{ "width", "Stroke width in pixels" },
        .{ "text_idx", "The text content to render" },
        .{ "font_size", "Font size in pixels" },
        .{ "x1", "First point X" },
        .{ "y1", "First point Y" },
        .{ "x2", "Second point X" },
        .{ "y2", "Second point Y" },
        .{ "x3", "Third point X" },
        .{ "y3", "Third point Y" },
        .{ "y_center", "Y position to vertically center text on" },
    };
    inline for (descriptions) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    @compileError("unknown field for description: " ++ name);
}

// =============================================================================
// Comptime Utilities
// =============================================================================

/// Count non-overlapping occurrences of `needle` in `haystack` at comptime.
fn comptimeCountSubstring(comptime haystack: []const u8, comptime needle: []const u8) usize {
    @setEvalBranchQuota(200_000);
    comptime {
        std.debug.assert(needle.len > 0);
        std.debug.assert(haystack.len >= needle.len);

        var count: usize = 0;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
                count += 1;
                i += needle.len - 1; // Skip past match (non-overlapping).
            }
        }
        return count;
    }
}

// =============================================================================
// Compile-time Assertions (CLAUDE.md #3)
// =============================================================================

comptime {
    // Tool count must match DrawCommand variant count (11 tools).
    std.debug.assert(TOOL_COUNT == 11);

    // Canvas dimensions in system prompt must match canvas_state constants.
    std.debug.assert(canvas_state.CANVAS_WIDTH == 500);
    std.debug.assert(canvas_state.CANVAS_HEIGHT == 400);

    // Schema string must be non-empty and reasonably sized.
    std.debug.assert(anthropic_tools_json.len > 100);
    std.debug.assert(anthropic_tools_json.len < 64 * 1024);

    // System prompt must be non-empty.
    std.debug.assert(canvas_system_prompt.len > 100);
}
