//! The image registry end to end, entirely from `update`:
//!
//! - `fx.registerImageBytes` decodes the bundled PNG (the platform
//!   codec does the work) and registers the pixels under an id.
//! - `fx.registerImage` uploads a raw straight-alpha RGBA8 buffer the
//!   app generated itself - the generated atlas.
//! - `fx.unregisterImage` retires an id; widgets bound to it fall back.
//!
//! `0` is the no-image sentinel: an id lands in the model only after a
//! successful registration, so the view's fallbacks (avatar initials,
//! the empty-state card) double as the loading/error story. Boot runs
//! through `Options.on_lifecycle` (`.start` -> `.boot`), the one hook
//! that fires before the first frame.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 980;
const window_height: f32 = 720;
const bundle_id = "dev.native_sdk.images";

const app_permissions = [_][]const u8{
    native_sdk.security.permission_view,
    native_sdk.security.permission_command,
};
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Image registry canvas", .accessibility_label = "Image registry", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Images",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ ids

/// Registry slots: the bundled icon takes the low id; each atlas
/// generation takes a fresh id above the base, so a regenerate is a
/// fresh binding the view diff cannot miss.
pub const icon_image_id: u64 = 1;
pub const atlas_image_id_base: u64 = 16;

/// The generated atlas is a plain 128x128 RGBA8 buffer.
pub const atlas_size: usize = 128;

pub const Msg = union(enum) {
    /// Lifecycle `.start`: register the bundled icon and the first
    /// atlas before the first frame.
    boot,
    /// Retire the current atlas and register the next generation.
    regenerate,
    /// Unregister the atlas: the widget falls back to the empty state.
    clear,

    /// `boot` is dispatched by the runtime (on_lifecycle), never by
    /// markup.
    pub const view_unbound = .{"boot"};
};

pub const Model = struct {
    /// Id of the decoded PNG (`registerImageBytes`), 0 until registered.
    icon_id: u64 = 0,
    /// Id of the current generated atlas (`registerImage`), 0 = none.
    atlas_id: u64 = 0,
    /// Completed atlas generations; the id above is `base + generation`.
    generation: u32 = 0,

    pub fn atlas_ready(model: *const Model, arena: std.mem.Allocator) bool {
        _ = arena;
        return model.atlas_id != 0;
    }

    pub fn status_text(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "atlas #{d} - generation {d}", .{
            model.atlas_id, model.generation,
        }) catch "atlas";
    }
};

// -------------------------------------------------------------- pixels

/// Scratch for the generated atlas. The effects channel copies the
/// pixels before `registerImage` returns, so one buffer serves every
/// generation.
var atlas_pixels: [atlas_size * atlas_size * 4]u8 = undefined;

/// Fill the scratch buffer with generation G's atlas: a plaid gradient
/// whose phase rotates 37 units per generation, so each Regenerate is
/// visibly a different texture with identical geometry. Deterministic:
/// the same generation always paints the same pixels.
pub fn fillAtlas(generation: u32) []const u8 {
    const phase: usize = @intCast((generation *% 37) & 0xff);
    for (0..atlas_size) |y| {
        for (0..atlas_size) |x| {
            const offset = (y * atlas_size + x) * 4;
            atlas_pixels[offset + 0] = @intCast((x * 2 + phase) & 0xff);
            atlas_pixels[offset + 1] = @intCast((y * 2 + phase * 3) & 0xff);
            atlas_pixels[offset + 2] = @intCast((x + y + phase * 5) & 0xff);
            atlas_pixels[offset + 3] = 255;
        }
    }
    return &atlas_pixels;
}

// ----------------------------------------------------------------- update

pub const Effects = native_sdk.Effects(Msg);

/// The declared lifecycle hook: boot on `.start`, ignore the rest.
pub fn onLifecycle(event: native_sdk.LifecycleEvent) ?Msg {
    return switch (event) {
        .start => .boot,
        else => null,
    };
}

/// Register the next atlas generation. The old id is retired first;
/// the new generation id and count land in the model only if the
/// registration succeeded, so any failure keeps the fallback visible.
fn generateAtlas(model: *Model, fx: *Effects) void {
    const next = model.generation + 1;
    const id = atlas_image_id_base + next;
    if (model.atlas_id != 0) _ = fx.unregisterImage(model.atlas_id);
    model.atlas_id = 0;
    fx.registerImage(id, atlas_size, atlas_size, fillAtlas(next)) catch return;
    model.generation = next;
    model.atlas_id = id;
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .boot => {
            // The bundled bytes path: one synchronous decode+register,
            // id into the model only on success. The bytes live beside
            // main.zig because @embedFile reads inside the package.
            if (fx.registerImageBytes(icon_image_id, @embedFile("bundled_badge.png"))) |_| {
                model.icon_id = icon_image_id;
            } else |_| {}
            generateAtlas(model, fx);
        },
        .regenerate => generateAtlas(model, fx),
        .clear => {
            if (model.atlas_id != 0) _ = fx.unregisterImage(model.atlas_id);
            model.atlas_id = 0;
        },
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const ImagesApp = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    return Model{};
}

pub fn main(init: std.process.Init) !void {
    const app_state = try ImagesApp.create(std.heap.page_allocator, .{
        .name = "images",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .on_lifecycle = onLifecycle,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "images",
        .window_title = "Images",
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
