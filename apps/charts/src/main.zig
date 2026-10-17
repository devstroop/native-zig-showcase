//! A live metrics dashboard, all in the app-model loop: a repeating
//! effects-channel timer appends one sample per tick to two rings, and
//! `update` does nothing but advance the data. Every chart is a pure
//! projection of model state through derived bindings - a line series, a
//! filled area series, a histogram bar series, and a sparkline all read
//! the same ring through different lenses, so replaying the same ticks
//! redraws the same dashboard.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 1040;
const window_height: f32 = 760;
const bundle_id = "dev.native_sdk.charts";

const app_permissions = [_][]const u8{
    native_sdk.security.permission_view,
    native_sdk.security.permission_command,
};
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Charts canvas", .accessibility_label = "Charts", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Charts",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ data

/// Seeded sample generator: a slow sine carries the trend, an LCG
/// carries the jitter, so the same tick sequence always redraws the
/// same dashboard. `Regenerate` rewinds to the boot constants and
/// refills the window - the boot curve, byte for byte.
const boot_seed: u64 = 0x9E3779B97F4A7C15;
const boot_phase: f32 = 0;

/// The ring keeps the last 48 samples; every chart renders oldest-first.
pub const sample_capacity: usize = 48;

/// Histogram buckets across the 0..100 load domain.
pub const bucket_count: usize = 8;
const bucket_span: f32 = 100.0 / @as(f32, @floatFromInt(bucket_count));
const bucket_names = [_][]const u8{ "0-12", "12-25", "25-37", "37-50", "50-62", "62-75", "75-87", "87-100" };

pub const Msg = union(enum) {
    toggle_running,
    regenerate,
    tick: native_sdk.EffectTimer,

    /// `tick` is dispatched by the host (the repeating timer fires),
    /// never from markup - this keeps the unbound-state lint honest
    /// about that.
    pub const view_unbound = .{"tick"};
};

pub const Model = struct {
    /// Storage the markup checker cannot see, consumed through the
    /// derived methods below.
    pub const view_unbound = .{ "requests", "errors", "head", "len", "phase", "seed" };

    /// Two rings: the request load and the error spikes. `head` is the
    /// next write slot, `len` the live window length (0..capacity).
    requests: [sample_capacity]f32 = [_]f32{0} ** sample_capacity,
    errors: [sample_capacity]f32 = [_]f32{0} ** sample_capacity,
    head: usize = 0,
    len: usize = 0,

    /// Seeded sample generator: a slow sine carries the trend, an LCG
    /// carries the jitter, so the same tick sequence always redraws the
    /// same dashboard.
    phase: f32 = boot_phase,
    seed: u64 = boot_seed,

    running: bool = false,

    pub fn request_series(model: *const Model, arena: std.mem.Allocator) []const f32 {
        return window(model, &model.requests, arena);
    }

    pub fn error_series(model: *const Model, arena: std.mem.Allocator) []const f32 {
        return window(model, &model.errors, arena);
    }

    pub fn sample_count(model: *const Model) usize {
        return model.len;
    }

    /// Bucket counts over the request window: the bar series' heights.
    pub fn histogram(model: *const Model, arena: std.mem.Allocator) []const f32 {
        const out = arena.alloc(f32, bucket_count) catch return &.{};
        @memset(out, 0);
        const max_bucket: f32 = @floatFromInt(bucket_count - 1);
        const start = windowStart(model);
        var index: usize = 0;
        while (index < model.len) : (index += 1) {
            const value = model.requests[(start + index) % sample_capacity];
            const bucket: usize = @intFromFloat(std.math.clamp(@floor(value / bucket_span), 0, max_bucket));
            out[bucket] += 1;
        }
        return out;
    }

    pub fn bucket_labels(_: *const Model) []const []const u8 {
        return &bucket_names;
    }

    // The stat tiles: one formatted readout each. Arena-computed so the
    // number rides the text binding.
    pub fn current_text(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d:.1}", .{latest(model, &model.requests)}) catch "-";
    }

    pub fn peak_text(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d:.1}", .{peak(model, &model.requests)}) catch "-";
    }

    pub fn mean_text(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d:.1}", .{mean(model, &model.requests)}) catch "-";
    }

    /// The status line: the one place the sampling lifecycle is narrated.
    pub fn live_status(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const mode = if (model.running) "sampling every 200ms" else "paused";
        return std.fmt.allocPrint(arena, "live: {s} - {d} samples - latest {d:.1}, peak {d:.1}", .{
            mode, model.len, latest(model, &model.requests), peak(model, &model.requests),
        }) catch "live dashboard";
    }
};

/// Oldest-first copy of one ring's live window: index 0 is the oldest
/// sample the chart draws.
fn window(model: *const Model, ring: []const f32, arena: std.mem.Allocator) []const f32 {
    const out = arena.alloc(f32, model.len) catch return &.{};
    const start = windowStart(model);
    for (out, 0..) |*value, index| {
        value.* = ring[(start + index) % sample_capacity];
    }
    return out;
}

fn windowStart(model: *const Model) usize {
    return (model.head + sample_capacity - model.len) % sample_capacity;
}

fn latest(model: *const Model, ring: []const f32) f32 {
    if (model.len == 0) return 0;
    return ring[(model.head + sample_capacity - 1) % sample_capacity];
}

fn peak(model: *const Model, ring: []const f32) f32 {
    var out: f32 = 0;
    const start = windowStart(model);
    var index: usize = 0;
    while (index < model.len) : (index += 1) {
        out = @max(out, ring[(start + index) % sample_capacity]);
    }
    return out;
}

fn mean(model: *const Model, ring: []const f32) f32 {
    if (model.len == 0) return 0;
    const start = windowStart(model);
    var total: f32 = 0;
    var index: usize = 0;
    while (index < model.len) : (index += 1) {
        total += ring[(start + index) % sample_capacity];
    }
    return total / @as(f32, @floatFromInt(model.len));
}

/// One sample writes both series. Deterministic: the sine advances the
/// trend by a fixed step and the LCG draws the jitter, so tick N always
/// yields the same point.
const Sample = struct { request: f32, spike: f32 };

fn sample(model: *Model) Sample {
    model.seed = model.seed *% 6364136223846793005 +% 1442695040888963407;
    const noise = @as(f32, @floatFromInt((model.seed >> 40) & 0xFFFF)) / 65535.0;
    model.phase += 0.31;
    const wave = @sin(model.phase);
    const request = std.math.clamp(52 + wave * 24 + (noise - 0.5) * 12, 2, 99);
    const spike = @max(0, (noise - 0.82) * 140 + (wave + 1) * 1.5);
    return .{ .request = request, .spike = spike };
}

fn push(model: *Model, point: Sample) void {
    model.requests[model.head] = point.request;
    model.errors[model.head] = point.spike;
    model.head = (model.head + 1) % sample_capacity;
    if (model.len < sample_capacity) model.len += 1;
}

// ----------------------------------------------------------------- update

pub const Effects = native_sdk.Effects(Msg);

/// The repeating sampling timer's effects-channel key: starting an
/// active key replaces the timer in place, so toggling never
/// double-registers.
pub const live_timer_key: u64 = 1;

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .toggle_running => {
            model.running = !model.running;
            // Recurring effects are timers on the effects channel: while
            // `running` holds, the host fires `tick` every 200ms; flip
            // it off and the timer stops.
            if (model.running) {
                fx.startTimer(.{
                    .key = live_timer_key,
                    .interval_ms = 200,
                    .mode = .repeating,
                    .on_fire = Effects.timerMsg(.tick),
                });
            } else {
                fx.cancelTimer(live_timer_key);
            }
        },
        .regenerate => {
            // Rewind to the boot constants and refill the whole ring
            // with one deterministic LCG walk, so the charts have a
            // full window without waiting on the timer - the exact
            // curve a fresh launch draws.
            model.phase = boot_phase;
            model.seed = boot_seed;
            model.head = 0;
            model.len = 0;
            var index: usize = 0;
            while (index < sample_capacity) : (index += 1) push(model, sample(model));
        },
        .tick => |timer| {
            if (timer.outcome != .fired) return;
            push(model, sample(model));
        },
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const ChartsApp = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    var model = Model{};
    var index: usize = 0;
    while (index < sample_capacity) : (index += 1) push(&model, sample(&model));
    return model;
}

pub fn main(init: std.process.Init) !void {
    const app_state = try ChartsApp.create(std.heap.page_allocator, .{
        .name = "charts",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "charts",
        .window_title = "Charts",
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
