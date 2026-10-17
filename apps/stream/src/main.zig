//! A hundred-thousand-event telemetry feed through ONE windowed
//! virtual list. The runtime owns the viewport math (retained scroll
//! offset + viewport -> visible index range), the model owns the
//! corpus, and the view is the seam: `rows()` materializes only the
//! rows the runtime asked for, one keyed node each, so the widget tree
//! stays viewport-sized at 100k events.
//!
//! Row content is a pure function of the row index (a hash picks the
//! source, level, and phrasing; the timestamp walks a fixed stride), so
//! the same index always renders the same event - tests assert the
//! exact strings the feed produces, and the scrollbar geometry is
//! honest arithmetic.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 980;
const window_height: f32 = 720;
const bundle_id = "dev.native_sdk.stream";

const app_permissions = [_][]const u8{
    native_sdk.security.permission_view,
    native_sdk.security.permission_command,
};
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Event stream canvas", .accessibility_label = "Event stream", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Stream",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ data

/// The corpus the feed can ever hold, and the batch a reach-end appends.
pub const corpus_total: usize = 100_000;
pub const batch_size: usize = 10_000;

/// The first window's item count: the feed opens with the first batch
/// already loaded.
pub const initial_rows: usize = batch_size;

/// Fixed row geometry: uniform rows make the 100k scrollbar pure
/// arithmetic (the v1 virtual-list fast path).
pub const row_extent: f32 = 44;

const row_sources = [_][]const u8{ "gateway", "auth", "billing", "search", "media", "profiles", "notify", "export" };
const row_details = [_][]const u8{
    "request completed",
    "cache miss, refilled",
    "queue drained",
    "token rotated",
    "index segment merged",
    "retry after upstream 502",
    "payload verified",
    "rate limit near threshold",
};

pub const Msg = union(enum) {
    /// A row was pressed: the index becomes the selection.
    select: i64,
    /// The list reached its end: append the next batch.
    load_more,
};

/// One event row, exactly as the markup reads it. Every text field is
/// arena-backed for this build; the row itself exists only while its
/// window is mounted.
pub const Row = struct {
    index: i64,
    time: []const u8,
    level: []const u8,
    source: []const u8,
    detail: []const u8,
    trouble: bool,
};

pub const Model = struct {
    /// Items currently loaded (the virtual window's item count).
    loaded: usize = initial_rows,
    /// The selected row index, or -1.
    selected: i64 = -1,

    /// The windowed row query: the runtime hands the visible range
    /// (plus overscan), this returns exactly `end_index - start_index`
    /// rows in rendered order. Nothing else is ever materialized -
    /// at `corpus_total` items the per-build cost stays proportional
    /// to the window, not the corpus.
    pub fn rows(_: *const Model, range: canvas.VirtualListRange, arena: std.mem.Allocator) []const Row {
        const count = range.end_index - range.start_index;
        const out = arena.alloc(Row, count) catch return &.{};
        for (out, 0..) |*row, offset| {
            row.* = makeRow(range.start_index + offset, arena);
        }
        return out;
    }

    pub fn loaded_text(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d} of {d} events", .{ model.loaded, corpus_total }) catch "events";
    }

    pub fn selected_text(model: *const Model, arena: std.mem.Allocator) []const u8 {
        if (model.selected < 0) return "none";
        return std.fmt.allocPrint(arena, "event #{d}", .{model.selected}) catch "none";
    }
};

/// Mixed hash: scrambles the row index into the choice bits. Splitmix64
/// finals keep consecutive indices decorrelated, so the feed looks like
/// traffic, not a cycle.
fn mix(index: usize) u64 {
    var hash: u64 = @as(u64, @intCast(index)) +% 0x9E3779B97F4A7C15;
    hash ^= hash >> 30;
    hash *%= 0xBF58476D1CE4E5B9;
    hash ^= hash >> 27;
    hash *%= 0x94D049BB133111EB;
    hash ^= hash >> 31;
    return hash;
}

/// The one row generator: everything about row N derives from N and the
/// hash of N, so tests can assert any index's exact rendering and a
/// rewind to the top redraws byte-identical rows.
fn makeRow(index: usize, arena: std.mem.Allocator) Row {
    const hash = mix(index);
    const level_roll = hash % 20;
    const level = if (level_roll < 14) "info" else if (level_roll < 18) "warn" else "error";
    const source = row_sources[(hash >> 8) % row_sources.len];
    const phrasing = row_details[(hash >> 24) % row_details.len];

    const total_ms: u64 = 9 * 3_600_000 + @as(u64, @intCast(index)) * 137;
    const time = std.fmt.allocPrint(arena, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        total_ms / 3_600_000, (total_ms / 60_000) % 60, (total_ms / 1000) % 60, total_ms % 1000,
    }) catch "00:00:00.000";
    const detail = std.fmt.allocPrint(arena, "{s} - event #{d}", .{ phrasing, index }) catch phrasing;

    return .{
        .index = @intCast(index),
        .time = time,
        .level = level,
        .source = source,
        .detail = detail,
        .trouble = level_roll >= 18,
    };
}

// ----------------------------------------------------------------- update

pub const Effects = native_sdk.Effects(Msg);

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    _ = fx;
    switch (msg) {
        .select => |index| {
            // Selection is model state at CORPUS scale: the index must
            // still be inside what the feed has loaded.
            if (index < 0 or index >= @as(i64, @intCast(model.loaded))) return;
            model.selected = index;
        },
        .load_more => {
            // The reach-end batch: append the next window of events,
            // clamped at the corpus cap. `on-reach-end` re-arms when
            // the extent grows, so one approach yields one batch.
            model.loaded = @min(model.loaded + batch_size, corpus_total);
        },
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const StreamApp = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    return Model{};
}

pub fn main(init: std.process.Init) !void {
    const app_state = try StreamApp.create(std.heap.page_allocator, .{
        .name = "stream",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "stream",
        .window_title = "Stream",
        .bundle_id = bundle_id,
        .icon_path = "assets/icon.png",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .js_window_api = false,
        .security = .{
            .permissions = &app_permissions,
            .navigation = .{ .allowed_origins = &.{ "zero://inline", "zero://app" } },
        },
    }, init);
}

test {
    _ = @import("tests.zig");
}
