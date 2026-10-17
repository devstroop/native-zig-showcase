//! The effects-channel core in Zig: `Model`, `Msg`, and an
//! effects-capable `update`. Everything that touches the OS - subprocess
//! spawns, HTTP fetches, file reads/writes, the system clipboard, a
//! notification - leaves through `fx` and answers with an ordinary Msg on
//! the same update path as a button press. The one exception is the
//! notification: fire-and-forget by design, no result to await.
//!
//! The file card writes into the app's own data directory (in-root paths
//! need no filesystem grant), and `init_fx` reads the note once on the
//! installing frame, before the first paint - the TEA boot command.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 760;
const window_height: f32 = 780;
const bundle_id = "dev.native_sdk.effects";

// `command` admits the spawn effect; `network` the fetch; `clipboard` and
// `notifications` their platform arms. The note's path resolves inside the
// app's data root, which the sandbox opens without a `filesystem` grant.
const app_permissions = [_][]const u8{
    native_sdk.security.permission_command,
    native_sdk.security.permission_view,
    native_sdk.security.permission_network,
    native_sdk.security.permission_clipboard,
    native_sdk.security.permission_notifications,
};
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Effects canvas", .accessibility_label = "Effects", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Effects",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------ effect keys

// One key per job, stored in the model and echoed on every payload: the
// key is how a result finds the model state it belongs to. Spawns,
// fetches, file ops, and clipboard ops share one key space (and the
// channel's slots); timers are the only separate namespace.
pub const stream_key: u64 = 1;
pub const collect_key: u64 = 2;
pub const fetch_key: u64 = 3;
pub const note_save_key: u64 = 4;
pub const note_load_key: u64 = 5;
pub const boot_load_key: u64 = 6;
pub const clip_write_key: u64 = 7;
pub const clip_read_key: u64 = 8;
pub const fetch_bad_key: u64 = 9;

// --------------------------------------------------------------- fixtures

/// Eight lines, one every 400ms: slow enough to watch line-by-line
/// delivery and to cancel mid-stream.
const stream_command = "i=1; while [ $i -le 8 ]; do echo \"line $i of 8\"; i=$((i+1)); sleep 0.4; done";

/// Both streams at once, then a non-zero exit: the collect msgs carry the
/// whole stdout plus the stderr tail, so this exit teaches all three.
const collect_command = "printf '{\"ok\":true,\"items\":3}\\n'; printf 'warn: item 4 skipped\\n' >&2; exit 3";

pub const fetch_url = "https://example.com/";
/// Nothing listens on port 9: a fast, honest `connect_failed`.
pub const fetch_bad_url = "http://127.0.0.1:9/";

// ---------------------------------------------------------- note location

var note_dir_buffer: [1024]u8 = undefined;
var note_path_buffer: [1024]u8 = undefined;
/// The note's path under the app data directory, resolved once in main()
/// with the same inputs the runner uses for its file-access roots, so the
/// path is in-root by construction. `pub` so the tests can assert on it.
pub var note_path: []const u8 = "note.txt";

fn resolveNotePath(init: std.process.Init) void {
    const platform = native_sdk.app_dirs.currentPlatform();
    const env = native_sdk.debug.envFromMap(init.environ_map);
    const dir = native_sdk.app_dirs.resolveOne(.{ .name = bundle_id }, platform, env, .data, &note_dir_buffer) catch return;
    note_path = native_sdk.app_dirs.join(platform, &note_path_buffer, &.{ dir, "note.txt" }) catch note_path;
}

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    // card actions, wired in app.native
    stream_start,
    stream_cancel,
    collect_start,
    collect_cancel,
    fetch_start,
    fetch_bad,
    fetch_cancel,
    note_input: canvas.TextInputEvent,
    note_save,
    note_load,
    clip_copy,
    clip_paste,
    notify,

    // effect results, dispatched by the host's drain through this same
    // update - never named from markup.
    line: native_sdk.EffectLine,
    exited: native_sdk.EffectExit,
    fetched: native_sdk.EffectResponse,
    file_result: native_sdk.EffectFileResult,
    clipboard_result: native_sdk.EffectClipboardResult,

    pub const view_unbound = .{ "line", "exited", "fetched", "file_result", "clipboard_result" };
};

/// A visible stream line: `id` is the arrival sequence, so reorders and
/// rebuilds keep engine state keyed.
pub const LogRow = struct {
    id: i64,
    title: []const u8,
};

const stream_capacity: usize = 8;

pub const Model = struct {
    // `view_unbound`: storage the markup checker cannot see, consumed
    // through the derived methods below.
    pub const view_unbound = .{
        "stream_rows",  "stream_row_ids", "stream_row_lens",   "stream_head",
        "stream_len",   "stream_seq",     "collect_out",       "collect_err",
        "fetch_body",   "note_draft",     "clip_source",       "clip_source_len",
        "clip_text",    "note_phase",     "clip_phase",        "clip_text_len",
    };

    // subprocess: streaming card. `stream_phase`: 0 idle, 1 running,
    // 2 exited, 3 cancelled, 4 rejected, 5 could not spawn.
    stream_phase: u8 = 0,
    stream_code: i32 = -1,
    stream_count: i64 = 0,
    stream_rows: [stream_capacity][72]u8 = [_][72]u8{.{0} ** 72} ** stream_capacity,
    stream_row_ids: [stream_capacity]i64 = [_]i64{0} ** stream_capacity,
    stream_row_lens: [stream_capacity]usize = [_]usize{0} ** stream_capacity,
    stream_head: usize = 0,
    stream_len: usize = 0,
    stream_seq: i64 = 0,

    // subprocess: collect card
    collect_phase: u8 = 0,
    collect_code: i32 = -1,
    collect_out: [192]u8 = [_]u8{0} ** 192,
    collect_out_len: usize = 0,
    collect_out_truncated: bool = false,
    collect_err: [96]u8 = [_]u8{0} ** 96,
    collect_err_len: usize = 0,

    // fetch card. `fetch_phase`: 0 idle, 1 fetching, 2 ok, 3 connect
    // failed, 4 tls failed, 5 protocol failed, 6 timed out, 7 cancelled,
    // 8 rejected.
    fetch_phase: u8 = 0,
    fetch_status: u16 = 0,
    fetch_body: [180]u8 = [_]u8{0} ** 180,
    fetch_body_len: usize = 0,
    fetch_body_truncated: bool = false,

    // note card. `note_phase`: 0 idle, 1 working, 2 loaded, 3 not found,
    // 4 io failed, 5 saved, 6 write failed, 7 rejected, 8 cancelled.
    note_draft: canvas.TextBuffer(128) = .{},
    note_phase: u8 = 0,
    note_bytes: usize = 0,
    note_truncated: bool = false,

    // clipboard card. `clip_phase`: 0 idle, 1 working, 2 copied,
    // 3 copy failed, 4 pasted, 5 paste failed, 6 rejected.
    clip_phase: u8 = 0,
    clip_bytes: usize = 0,
    clip_source: [160]u8 = [_]u8{0} ** 160,
    clip_source_len: usize = 0,
    clip_text: [160]u8 = [_]u8{0} ** 160,
    clip_text_len: usize = 0,

    notify_count: usize = 0,

    // Phase names are derived, never stored: markup binds the fn and the
    // switch keeps the mapping in one place.
    pub fn stream_phase_name(model: *const Model) []const u8 {
        return switch (model.stream_phase) {
            0 => "idle",
            1 => "running",
            2 => "exited",
            3 => "cancelled",
            4 => "rejected",
            else => "spawn failed",
        };
    }

    pub fn collect_phase_name(model: *const Model) []const u8 {
        return switch (model.collect_phase) {
            0 => "idle",
            1 => "running",
            2 => "exited",
            3 => "cancelled",
            4 => "rejected",
            else => "spawn failed",
        };
    }

    pub fn fetch_phase_name(model: *const Model) []const u8 {
        return switch (model.fetch_phase) {
            0 => "idle",
            1 => "fetching",
            2 => "ok",
            3 => "connect failed",
            4 => "tls failed",
            5 => "protocol failed",
            6 => "timed out",
            7 => "cancelled",
            else => "rejected",
        };
    }

    pub fn note_phase_name(model: *const Model) []const u8 {
        return switch (model.note_phase) {
            0 => "idle",
            1 => "working",
            2 => "loaded",
            3 => "no note yet",
            4 => "read failed",
            5 => "saved",
            6 => "save failed",
            7 => "rejected",
            else => "cancelled",
        };
    }

    pub fn clip_phase_name(model: *const Model) []const u8 {
        return switch (model.clip_phase) {
            0 => "idle",
            1 => "working",
            2 => "copied",
            3 => "copy failed",
            4 => "pasted",
            5 => "paste failed",
            else => "rejected",
        };
    }

    /// The note text: the TextBuffer holds editor state, the binding
    /// wants the text it derives.
    pub fn note(model: *const Model) []const u8 {
        return model.note_draft.text();
    }

    /// The stream ring window, oldest first, with per-row identity.
    pub fn stream_log(model: *const Model, arena: std.mem.Allocator) []const LogRow {
        const out = arena.alloc(LogRow, model.stream_len) catch return &.{};
        for (out, 0..) |*row, i| {
            const slot = (model.stream_head + i) % stream_capacity;
            row.* = .{
                .id = model.stream_row_ids[slot],
                .title = model.stream_rows[slot][0..model.stream_row_lens[slot]],
            };
        }
        return out;
    }

    pub fn collect_stdout(model: *const Model) []const u8 {
        return model.collect_out[0..model.collect_out_len];
    }

    pub fn collect_stderr(model: *const Model) []const u8 {
        return model.collect_err[0..model.collect_err_len];
    }

    pub fn fetch_body_text(model: *const Model) []const u8 {
        return model.fetch_body[0..model.fetch_body_len];
    }

    pub fn clipboard_text(model: *const Model) []const u8 {
        return model.clip_text[0..model.clip_text_len];
    }
};

pub const Effects = native_sdk.Effects(Msg);

/// Copy a payload slice into model-owned storage, bounded. Payload slices
/// are valid only during the receiving update; the model owns what it
/// keeps. Returns the copied length.
fn copyInto(dest: []u8, text: []const u8) usize {
    const n = @min(text.len, dest.len);
    @memcpy(dest[0..n], text[0..n]);
    return n;
}

fn pushStreamRow(model: *Model, line: []const u8, id: i64) void {
    var slot: usize = undefined;
    if (model.stream_len < stream_capacity) {
        slot = (model.stream_head + model.stream_len) % stream_capacity;
        model.stream_len += 1;
    } else {
        slot = model.stream_head;
        model.stream_head = (model.stream_head + 1) % stream_capacity;
    }
    model.stream_row_lens[slot] = copyInto(&model.stream_rows[slot], line);
    model.stream_row_ids[slot] = id;
}

/// The boot command: read the note once on the installing frame, before
/// the first paint, so any loaded state is in the very first build.
pub fn boot(model: *Model, fx: *Effects) void {
    model.note_phase = 1;
    fx.readFile(.{
        .key = boot_load_key,
        .path = note_path,
        .on_result = Effects.fileMsg(.file_result),
    });
}

pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    switch (msg) {
        .stream_start => {
            model.stream_phase = 1;
            model.stream_code = -1;
            model.stream_count = 0;
            model.stream_head = 0;
            model.stream_len = 0;
            model.stream_seq = 0;
            fx.spawn(.{
                .key = stream_key,
                .argv = &.{ "sh", "-c", stream_command },
                .output = .lines,
                .on_line = Effects.lineMsg(.line),
                .on_exit = Effects.exitMsg(.exited),
            });
        },
        .stream_cancel => fx.cancel(stream_key),

        .line => |event| {
            if (event.key != stream_key) return;
            model.stream_count += 1;
            model.stream_seq += 1;
            pushStreamRow(model, event.line, model.stream_seq);
        },
        .exited => |exit| switch (exit.key) {
            stream_key => {
                model.stream_phase = switch (exit.reason) {
                    .exited, .signaled => 2,
                    .cancelled => 3,
                    .rejected => 4,
                    .spawn_failed => 5,
                };
                if (exit.reason == .exited or exit.reason == .signaled) model.stream_code = exit.code;
            },
            collect_key => {
                model.collect_phase = switch (exit.reason) {
                    .exited, .signaled => 2,
                    .cancelled => 3,
                    .rejected => 4,
                    .spawn_failed => 5,
                };
                if (model.collect_phase != 2) {
                    model.collect_code = -1;
                    return;
                }
                model.collect_code = exit.code;
                model.collect_out_len = copyInto(&model.collect_out, exit.output);
                model.collect_out_truncated = exit.output_truncated or exit.output.len > model.collect_out.len;
                model.collect_err_len = copyInto(&model.collect_err, exit.stderr_tail);
            },
            else => {},
        },

        .collect_start => {
            model.collect_phase = 1;
            model.collect_code = -1;
            model.collect_out_len = 0;
            model.collect_out_truncated = false;
            model.collect_err_len = 0;
            fx.spawn(.{
                .key = collect_key,
                .argv = &.{ "sh", "-c", collect_command },
                .output = .collect,
                .on_exit = Effects.exitMsg(.exited),
            });
        },
        .collect_cancel => fx.cancel(collect_key),

        .fetch_start => {
            model.fetch_phase = 1;
            model.fetch_status = 0;
            model.fetch_body_len = 0;
            model.fetch_body_truncated = false;
            fx.fetch(.{
                .key = fetch_key,
                .url = fetch_url,
                .timeout_ms = 15_000,
                .on_response = Effects.responseMsg(.fetched),
            });
        },
        .fetch_bad => {
            model.fetch_phase = 1;
            model.fetch_status = 0;
            model.fetch_body_len = 0;
            model.fetch_body_truncated = false;
            fx.fetch(.{
                .key = fetch_bad_key,
                .url = fetch_bad_url,
                .timeout_ms = 5_000,
                .on_response = Effects.responseMsg(.fetched),
            });
        },
        .fetch_cancel => fx.cancel(fetch_key),
        .fetched => |response| {
            if (response.key != fetch_key and response.key != fetch_bad_key) return;
            model.fetch_phase = switch (response.outcome) {
                .ok => 2,
                .connect_failed => 3,
                .tls_failed => 4,
                .protocol_failed => 5,
                .timed_out => 6,
                .cancelled => 7,
                .rejected => 8,
            };
            if (response.outcome != .ok) return;
            model.fetch_status = response.status;
            model.fetch_body_len = copyInto(&model.fetch_body, response.body);
            model.fetch_body_truncated = response.truncated or response.body.len > model.fetch_body.len;
        },

        .note_input => |event| model.note_draft.apply(event),
        .note_save => {
            model.note_phase = 1;
            fx.writeFile(.{
                .key = note_save_key,
                .path = note_path,
                .bytes = model.note_draft.text(),
                .on_result = Effects.fileMsg(.file_result),
            });
        },
        .note_load => {
            model.note_phase = 1;
            model.note_truncated = false;
            fx.readFile(.{
                .key = note_load_key,
                .path = note_path,
                .on_result = Effects.fileMsg(.file_result),
            });
        },
        .file_result => |result| {
            if (result.key == note_save_key) {
                model.note_phase = switch (result.outcome) {
                    .ok => 5,
                    .rejected => 7,
                    .cancelled => 8,
                    else => 6,
                };
                if (result.outcome == .ok) model.note_bytes = model.note_draft.text().len;
            } else if (result.key == note_load_key or result.key == boot_load_key) {
                model.note_phase = switch (result.outcome) {
                    .ok, .truncated => 2,
                    .not_found => 3,
                    .rejected => 7,
                    .cancelled => 8,
                    else => 4,
                };
                if (result.outcome == .ok or result.outcome == .truncated) {
                    model.note_draft.set(result.bytes);
                    model.note_bytes = result.bytes.len;
                    model.note_truncated = result.outcome == .truncated;
                } else {
                    model.note_truncated = false;
                }
            }
        },

        .clip_copy => {
            // The summary is written straight into the model buffer that
            // the model keeps; the literal is only a fallback when the
            // formatted one does not fit.
            model.clip_source_len = if (std.fmt.bufPrint(&model.clip_source, "Native SDK effects: {d} stream lines, {d} fetch bytes, {d} notifications", .{
                model.stream_count,
                model.fetch_body_len,
                model.notify_count,
            })) |summary| summary.len else |_| copyInto(&model.clip_source, "Native SDK effects demo");
            model.clip_phase = 1;
            model.clip_bytes = model.clip_source_len;
            fx.writeClipboard(.{
                .key = clip_write_key,
                .text = model.clip_source[0..model.clip_source_len],
                .on_result = Effects.clipboardMsg(.clipboard_result),
            });
        },
        .clip_paste => {
            model.clip_phase = 1;
            fx.readClipboard(.{
                .key = clip_read_key,
                .on_result = Effects.clipboardMsg(.clipboard_result),
            });
        },
        .clipboard_result => |result| {
            if (result.op == .write) {
                model.clip_phase = switch (result.outcome) {
                    .ok => 2,
                    .failed => 3,
                    else => 6,
                };
            } else {
                model.clip_phase = switch (result.outcome) {
                    .ok => 4,
                    .failed => 5,
                    else => 6,
                };
                if (result.outcome == .ok) {
                    model.clip_text_len = copyInto(&model.clip_text, result.text);
                    model.clip_bytes = model.clip_text_len;
                }
            }
        },

        .notify => {
            model.notify_count += 1;
            // Fire-and-forget by design: there is no result Msg to await.
            fx.showNotification(.{
                .id = "effects-demo",
                .title = "Native Effects",
                .body = "Sent from update() over the effects channel.",
            });
        },
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const EffectsApp = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    return .{};
}

pub fn main(init: std.process.Init) !void {
    resolveNotePath(init);

    const app_state = try EffectsApp.create(std.heap.page_allocator, .{
        .name = "effects",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update_fx = update,
        .init_fx = boot,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "effects",
        .window_title = "Effects",
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
