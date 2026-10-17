//! The app core in Zig: `Model`, `Msg`, and `update` - the same
//! counter-with-effects starter the TypeScript template builds. The view
//! lives in `app.native` (embedded into the binary, and watched for hot
//! reload in dev); recurring work and clock reads ride the effects
//! channel, so `update` stays a plain function of model + message.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 480;
const window_height: f32 = 320;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Counter canvas", .accessibility_label = "Counter", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Counter",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    increment,
    decrement,
    reset,
    toggle_ticking,
    stamp,
    tick: native_sdk.EffectTimer,

    // `tick` is dispatched by the host (the repeating timer fires),
    // never from markup - this keeps the unbound-state lint honest
    // about that.
    pub const view_unbound = .{"tick"};
};

pub const Model = struct {
    count: i64 = 0,
    ticking: bool = false,
    tick_count: i64 = 0,
    stamped_ms: i64 = -1,

    // Public single-model helpers become bindings too: `{total}` in
    // app.native reads this.
    pub fn total(model: *const Model) i64 {
        return model.count + model.tick_count;
    }
};

pub const Effects = native_sdk.Effects(Msg);

/// The repeating tick's effects-channel key: starting an active key
/// replaces the timer in place, so toggling never double-registers.
pub const tick_timer_key: u64 = 1;

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .increment => model.count += 1,
        .decrement => model.count -= 1,
        .reset => {
            model.count = 0;
            model.tick_count = 0;
        },
        .toggle_ticking => {
            model.ticking = !model.ticking;
            // Recurring effects are timers on the effects channel: while
            // `ticking` holds, the host fires `tick` every second; flip
            // it off and the timer stops.
            if (model.ticking) {
                fx.startTimer(.{
                    .key = tick_timer_key,
                    .interval_ms = 1000,
                    .mode = .repeating,
                    .on_fire = Effects.timerMsg(.tick),
                });
            } else {
                fx.cancelTimer(tick_timer_key);
            }
        },
        // The journaled clock read - deterministic under session replay,
        // the Zig equivalent of the TypeScript starter's `Cmd.now`.
        .stamp => model.stamped_ms = fx.wallMs(),
        .tick => |timer| {
            if (timer.outcome != .fired) return;
            model.tick_count += 1;
        },
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const CounterApp = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    return .{};
}

pub fn main(init: std.process.Init) !void {
    // The app struct (and any real Model) is multi-MB: `create`
    // heap-allocates and constructs everything in place, so neither
    // ever rides the stack. Mutate `app_state.model` through the
    // pointer before running if boot state is not the default.
    const app_state = try CounterApp.create(std.heap.page_allocator, .{
        .name = "counter",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "counter",
        .window_title = "Counter",
        .bundle_id = "dev.native_sdk.counter",
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
