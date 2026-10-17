//! Desktop integration, in the app-model loop: secondary windows ARE
//! model state. `windows_fn` returns the window descriptors that should
//! exist right now - presence is liveness - and the runtime reconciles
//! the OS windows against that declaration after every dispatch:
//! opening a window is setting a flag, closing it is clearing one, and
//! every open window's tree rebuilds from the same model.
//!
//! Window verbs (`minimizeWindow`, `hideWindow`, `showWindow`,
//! `quitApp`) leave through the effects channel like any other effect,
//! and the user's own close affordance comes back as a Msg: the
//! inspector's titlebar X dispatches `inspector_closed`.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 900;
const window_height: f32 = 640;
const bundle_id = "dev.native_sdk.desktop";

const app_permissions = [_][]const u8{
    native_sdk.security.permission_view,
    native_sdk.security.permission_command,
    native_sdk.security.permission_window,
};
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Desktop canvas", .accessibility_label = "Desktop", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Desktop",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    open_inspector,
    close_inspector,
    minimize_inspector,
    open_scratchpad,
    hide_scratchpad,
    show_scratchpad,
    ping,
    quit_app,
    inspector_closed,
    scratchpad_closed,

    /// `inspector_closed`/`scratchpad_closed` are dispatched by the
    /// descriptors' `on_close` when the user hits a window's own close
    /// affordance - never from markup.
    pub const view_unbound = .{ "inspector_closed", "scratchpad_closed" };
};

pub const Model = struct {
    /// Open flags and the narration string are consumed through the
    /// derived methods below and `windows_fn`.
    pub const view_unbound = .{ "inspector_open", "scratch_open", "last_action" };

    inspector_open: bool = false,
    scratch_open: bool = false,
    pings: i64 = 0,
    last_action: []const u8 = "nothing yet - open a window",

    pub fn status(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "windows: {s} - {s} - {d} pings", .{
            openText(model), model.last_action, model.pings,
        }) catch "desktop";
    }
};

/// The declared-set summary, folded into `status` (the only consumer -
/// private, so the markup lint counts nothing unbound).
fn openText(model: *const Model) []const u8 {
    if (model.inspector_open and model.scratch_open) return "inspector + scratchpad";
    if (model.inspector_open) return "inspector";
    if (model.scratch_open) return "scratchpad";
    return "none yet";
}

pub const Effects = native_sdk.Effects(Msg);

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .open_inspector => {
            model.inspector_open = true;
            model.last_action = "opened the inspector";
        },
        .close_inspector, .inspector_closed => {
            // Declarative close: dropping the declaration is what closes
            // the real window (the user's X echoed the same way).
            model.inspector_open = false;
            model.last_action = "closed the inspector";
        },
        .minimize_inspector => {
            model.last_action = "minimized the inspector";
            fx.minimizeWindow("inspector");
        },
        .open_scratchpad => {
            model.scratch_open = true;
            model.last_action = "opened the scratchpad";
        },
        .scratchpad_closed => {
            model.scratch_open = false;
            model.last_action = "closed the scratchpad";
        },
        .hide_scratchpad => {
            model.last_action = "hid the scratchpad";
            fx.hideWindow("scratchpad");
        },
        .show_scratchpad => {
            model.last_action = "showed the scratchpad";
            fx.showWindow("scratchpad");
        },
        .ping => {
            model.pings += 1;
            model.last_action = "pinged from a window";
        },
        .quit_app => {
            model.last_action = "quitting";
            fx.quitApp();
        },
    }
}

// ---------------------------------------------------------------- windows

pub const AppUi = canvas.Ui(Msg);
const DesktopApp = native_sdk.UiApp(Model, Msg);

/// The declared window set: presence is liveness. The inspector closes
/// declaratively (its user close echoes `inspector_closed`, which
/// clears the flag). The scratchpad's user close affordance is a
/// `.hide` where the host supports the policy - the window and its
/// views stay alive for `showWindow`; hosts that refuse it (Linux/GTK)
/// fall back to a declarative close, and `on_close` reports it.
pub const scratchpad_close_policy: native_sdk.app_manifest.WindowClosePolicy =
    if (@import("builtin").os.tag == .linux) .quit else .hide;

pub fn windows(model: *const Model, scratch: *DesktopApp.WindowsScratch) []const DesktopApp.WindowDescriptor {
    var count: usize = 0;
    if (model.inspector_open) {
        scratch.windows[count] = .{
            .label = "inspector",
            .canvas_label = "inspector-canvas",
            .title = "Inspector",
            .width = 380,
            .height = 440,
            .min_width = 320,
            .min_height = 320,
            .restore_policy = .center_on_primary,
            .on_close = .inspector_closed,
        };
        count += 1;
    }
    if (model.scratch_open) {
        scratch.windows[count] = .{
            .label = "scratchpad",
            .canvas_label = "scratchpad-canvas",
            .title = "Scratchpad",
            .width = 420,
            .height = 320,
            .close_policy = scratchpad_close_policy,
            .on_close = .scratchpad_closed,
        };
        count += 1;
    }
    return scratch.windows[0..count];
}

const InspectorView = canvas.CompiledMarkupView(Model, Msg, @embedFile("inspector.native"));
const ScratchpadView = canvas.CompiledMarkupView(Model, Msg, @embedFile("scratchpad.native"));

/// One tree per declared window, keyed by window label; the runtime
/// rebuilds it for every open window on every dispatched Msg.
pub fn windowView(ui: *AppUi, model: *const Model, window_label: []const u8) AppUi.Node {
    if (std.mem.eql(u8, window_label, "inspector")) return InspectorView.build(ui, model);
    if (std.mem.eql(u8, window_label, "scratchpad")) return ScratchpadView.build(ui, model);
    return ui.text(.{}, "unknown window");
}

// ------------------------------------------------------------------- view

pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

pub fn initialModel() Model {
    return .{};
}

pub fn main(init: std.process.Init) !void {
    const app_state = try DesktopApp.create(std.heap.page_allocator, .{
        .name = "desktop",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
        .windows_fn = windows,
        .window_view = windowView,
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "desktop",
        .window_title = "Desktop",
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
