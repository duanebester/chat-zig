//! A zero-height paint leaf that reports the width layout gave it.

const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;

/// Records the width layout gave it, for `AppState.composer_width`. Paint
/// runs on the main thread after layout, so this is the only public way to
/// learn a grown element's size outside a handler.
pub const WidthProbe = struct {
    width: ?*f32 = null,

    pub fn paint(self: *const WidthProbe, painter: *ui.Painter) void {
        std.debug.assert(painter.bounds.width >= 0);
        const width = self.width orelse return;
        width.* = @round(painter.bounds.width);
    }
};
