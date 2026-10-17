//! The embedded markup import closure: every component file under
//! src/, with paths relative to the markup root (src/). The runtime
//! engine's first build reads this set; hot reload re-resolves the same
//! paths from disk rooted at the watched file's directory. Adding a
//! component file means adding a line here (and the <import> above) -
//! `native check` validates the markup side, the compiler validates this
//! side, and a missed entry fails loudly at the import site.

const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;

pub const sources = [_]canvas.ui_markup.SourceFile{
    .{ .path = "components/section-overview.native", .source = @embedFile("components/section-overview.native") },
    .{ .path = "components/section-controls.native", .source = @embedFile("components/section-controls.native") },
    .{ .path = "components/section-layout.native", .source = @embedFile("components/section-layout.native") },
    .{ .path = "components/section-data.native", .source = @embedFile("components/section-data.native") },
    .{ .path = "components/section-overlays.native", .source = @embedFile("components/section-overlays.native") },
    .{ .path = "components/section-rich.native", .source = @embedFile("components/section-rich.native") },
    .{ .path = "components/section-theming.native", .source = @embedFile("components/section-theming.native") },
    .{ .path = "components/section-playground.native", .source = @embedFile("components/section-playground.native") },
};
