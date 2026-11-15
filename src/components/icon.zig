//! Lucide (or any SVG path) icons, drawn with `Painter.svg`.
//!
//! Gooey 0.4 removed the `Svg` component; an icon is now a `ui.paint` leaf.
//! A paint element keeps a pointer to its data until the frame is emitted,
//! after the component that built it has returned, so the data cannot be a
//! component's by-value field. `icon` therefore takes a comptime spec and
//! points at a static copy of it, and colours are theme tokens that resolve
//! against the active `gooey.Theme` when the icon is painted, so one constant
//! serves both palettes.

const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;

pub const Spec = struct {
    path: []const u8,
    size: f32,
    /// Outline colour; Lucide icons are stroked paths.
    stroke: ?ui.ColorToken = null,
    /// Fill colour, for solid glyphs such as the stop square or a logo.
    fill: ?ui.ColorToken = null,
    stroke_width: f32 = 1.5,
    /// The path's coordinate space (Lucide's is 24).
    viewbox: f32 = 24,
};

pub fn icon(comptime spec: Spec) ui.Paint(Spec) {
    comptime std.debug.assert(spec.size > 0);
    comptime std.debug.assert(spec.stroke != null or spec.fill != null);
    const static = struct {
        const value = spec;
    };
    return ui.paint(Spec, &static.value, paint, .{
        .width = .{ .fixed = spec.size },
        .height = .{ .fixed = spec.size },
    });
}

fn paint(spec: *const Spec, painter: *ui.Painter) void {
    const theme = painter.theme();
    painter.svg(spec.path, painter.bounds, .{
        .fill = if (spec.fill) |token| token.resolve(theme) else null,
        .stroke = if (spec.stroke) |token| token.resolve(theme) else null,
        .stroke_width = spec.stroke_width,
        .viewbox = spec.viewbox,
    });
}
