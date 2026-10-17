//! A drag-and-drop board, all in the app-model loop. Every card is a
//! drag source: markup's `on-drag` binding authors the card's identity
//! (`card_dropped:{c.id}`) and the runtime fills the release record -
//! phase, point, and the receiving view size. `update` maps the drop
//! point's x to a column, so the whole feature is one pure function of
//! model + message: no pointer state in the view, and the board is
//! rebuilt from `columns` on the next frame.
//!
//! The drag phases come from `canvas.WidgetDragPhase`: 0 change (live,
//! still dragging), 1 end (released), 2 cancel. Only `end` moves a card.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 1040;
const window_height: f32 = 680;
const bundle_id = "dev.native_sdk.kanban";

const app_permissions = [_][]const u8{
    native_sdk.security.permission_view,
};
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Kanban canvas", .accessibility_label = "Kanban", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Kanban",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ---------------------------------------------------------------- the board

pub const column_count: usize = 4;
pub const column_names = [_][]const u8{ "Backlog", "Todo", "Doing", "Done" };

pub const card_count: usize = 8;
pub const card_titles = [_][]const u8{
    "Sketch the board",
    "Model the cards",
    "Bind the drag channel",
    "Map drops to columns",
    "Style the columns",
    "Write the tests",
    "Polish the icon",
    "Ship the demo",
};

/// The `on-drag` payload shape: field names and widths are the contract.
/// `sourceId` comes from the authored binding (`card_dropped:{c.id}`); the
/// runtime injects `phase` and the f64 live geometry.
pub const DragRecord = struct {
    sourceId: i64,
    phase: i64,
    x: f64,
    y: f64,
    viewWidth: f64,
    viewHeight: f64,
};

pub const Msg = union(enum) {
    card_dropped: DragRecord,
};

/// One rendered card: identity for the `for` key, title for the label.
pub const CardRow = struct {
    id: i64,
    title: []const u8,
};

pub const Model = struct {
    /// Storage the markup checker cannot see, consumed through the
    /// derived methods below.
    pub const view_unbound = .{ "columns", "drag_card", "drag_target", "drag_phase" };

    /// Card slot -> column index (0..3). The whole board state.
    columns: [card_count]u8 = .{ 0, 0, 0, 1, 1, 2, 2, 3 },

    /// Drag bookkeeping. `drag_phase`: 0 idle, 1 dragging, 2 dropped,
    /// 3 cancelled.
    drag_card: i64 = -1,
    drag_target: u8 = 0,
    drag_phase: u8 = 0,

    fn cardsIn(model: *const Model, arena: std.mem.Allocator, column: u8) []const CardRow {
        var count: usize = 0;
        for (model.columns) |c| {
            if (c == column) count += 1;
        }
        const out = arena.alloc(CardRow, count) catch return &.{};
        var at: usize = 0;
        for (model.columns, 0..) |c, index| {
            if (c != column) continue;
            out[at] = .{ .id = @intCast(index + 1), .title = card_titles[index] };
            at += 1;
        }
        return out;
    }

    fn countIn(model: *const Model, column: u8) usize {
        var count: usize = 0;
        for (model.columns) |c| {
            if (c == column) count += 1;
        }
        return count;
    }

    // One derived list and count per column: `for each` binds a method
    // name, and four static columns beat one dynamic indirection here.
    pub fn backlog_cards(model: *const Model, arena: std.mem.Allocator) []const CardRow {
        return cardsIn(model, arena, 0);
    }
    pub fn todo_cards(model: *const Model, arena: std.mem.Allocator) []const CardRow {
        return cardsIn(model, arena, 1);
    }
    pub fn doing_cards(model: *const Model, arena: std.mem.Allocator) []const CardRow {
        return cardsIn(model, arena, 2);
    }
    pub fn done_cards(model: *const Model, arena: std.mem.Allocator) []const CardRow {
        return cardsIn(model, arena, 3);
    }

    pub fn backlog_count(model: *const Model) usize {
        return countIn(model, 0);
    }
    pub fn todo_count(model: *const Model) usize {
        return countIn(model, 1);
    }
    pub fn doing_count(model: *const Model) usize {
        return countIn(model, 2);
    }
    pub fn done_count(model: *const Model) usize {
        return countIn(model, 3);
    }

    /// The status line: the one place the drag lifecycle is narrated.
    /// Arena-computed so the card title and column name ride the text.
    pub fn drag_status(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const title = cardTitle(model.drag_card);
        return switch (model.drag_phase) {
            1 => std.fmt.allocPrint(arena, "Dragging \"{s}\" - release over a column to move it.", .{title}) catch "Dragging a card.",
            2 => std.fmt.allocPrint(arena, "Moved \"{s}\" to {s}.", .{ title, column_names[model.drag_target] }) catch "Card moved.",
            3 => std.fmt.allocPrint(arena, "Drop cancelled - \"{s}\" stays put.", .{title}) catch "Drop cancelled.",
            else => "Drag any card into another column - the drop point picks the column.",
        };
    }
};

fn cardTitle(id: i64) []const u8 {
    if (id < 1 or id > card_count) return "";
    return card_titles[@intCast(id - 1)];
}

/// Column under a view-x: the four columns split the view evenly, so the
/// closed-form mapping is the whole drop policy. Out-of-view drags clamp.
fn columnAt(x: f64, width: f64) u8 {
    if (!(width > 0)) return 0;
    const scaled = std.math.floor((x / width) * @as(f64, @floatFromInt(column_count)));
    return @intFromFloat(std.math.clamp(scaled, 0, @as(f64, @floatFromInt(column_count - 1))));
}

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .card_dropped => |drag| {
            if (drag.sourceId < 1 or drag.sourceId > card_count) return;
            const index: usize = @intCast(drag.sourceId - 1);
            model.drag_card = drag.sourceId;
            model.drag_target = columnAt(drag.x, drag.viewWidth);
            if (drag.phase == 1) {
                // Released: the drop point decides the card's new column.
                model.columns[index] = model.drag_target;
                model.drag_phase = 2;
            } else if (drag.phase == 2) {
                model.drag_phase = 3;
            } else {
                model.drag_phase = 1;
            }
        },
    }
}

// ------------------------------------------------------------------- view

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const KanbanApp = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    return .{};
}

pub fn main(init: std.process.Init) !void {
    const app_state = try KanbanApp.create(std.heap.page_allocator, .{
        .name = "kanban",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .markup = .{ .source = app_markup, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "kanban",
        .window_title = "Kanban",
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
