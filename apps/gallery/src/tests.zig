const std = @import("std");
const app = @import("main.zig");
const native_sdk = @import("native_sdk");
const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const PlaygroundMarkup = canvas.MarkupView(app.Model, app.Msg);

/// The gesture wiring a live rebuild shows, driven through the same
/// handler table the runtime uses (Tree.msgFor* resolve real handlers).
const playground_smoke_source =
    \\<column gap="8">
    \\  <button on-press="pg_press" on-hold="pg_hold">hold for more</button>
    \\  <panel on-drag="pad_dragged:{drag_track_id}" label="Drag pad" padding="12">
    \\    <progress value="{drag_pct}" label="Pointer position"/>
    \\  </panel>
    \\  <for each="tracks" key="id" as="t">
    \\    <list-item on-press="select_track:{t.id}" on-double-press="play_track:{t.id}" label="{t.name}" selected="{t.sel}"><text>{t.name}</text></list-item>
    \\  </for>
    \\  <panel on-hover-enter="pg_hover_enter" on-hover-leave="pg_hover_leave" label="Hover tile"><text>move the pointer</text></panel>
    \\</column>
;

fn findWidget(widget: canvas.Widget, name: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.text, name) or std.mem.eql(u8, widget.semantics.label, name)) return widget;
    for (widget.children) |child| {
        if (findWidget(child, name)) |found| return found;
    }
    return null;
}

test "section navigation clamps to the last section" {
    var model = app.Model{};
    app.update(&model, .{ .set_section = 7 });
    try std.testing.expectEqual(@as(usize, 7), model.section_index);
    app.update(&model, .{ .set_section = 99 });
    try std.testing.expectEqual(@as(usize, 7), model.section_index);
}

test "next_section walks forward and stops at the end" {
    var model = app.Model{};
    for (0..20) |_| app.update(&model, .next_section);
    try std.testing.expectEqual(@as(usize, 7), model.section_index);
}

test "sidebar split echoes the applied fraction" {
    var model = app.Model{};
    app.update(&model, .{ .sidebar_resized = 0.35 });
    try std.testing.expectEqual(@as(f32, 0.35), model.sidebar_split);
}

test "section_title follows the model" {
    var model = app.Model{};
    try std.testing.expectEqualStrings("Overview", app.Model.section_title(&model));
    app.update(&model, .{ .set_section = 4 });
    try std.testing.expectEqualStrings("Overlays", app.Model.section_title(&model));
}

// ---- navigation & data section

test "page navigation clamps at both ends" {
    var model = app.Model{};
    app.update(&model, .page_prev);
    try std.testing.expectEqual(@as(usize, 1), model.page);
    for (0..20) |_| app.update(&model, .page_next);
    try std.testing.expectEqual(app.Model.page_count(&model), model.page);
}

test "reach-end grows the log window and counts fetches, capped" {
    var model = app.Model{};
    app.update(&model, .log_reach_end);
    try std.testing.expectEqual(@as(usize, 36), model.log_count);
    try std.testing.expectEqual(@as(usize, 1), model.fetch_count);
    for (0..40) |_| app.update(&model, .log_reach_end);
    try std.testing.expectEqual(@as(usize, 240), model.log_count);
}

test "tree disclosure gates child visibility" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var model = app.Model{};
    try std.testing.expectEqual(@as(usize, 4), app.Model.tree_rows(&model, arena.allocator()).len);
    app.update(&model, .{ .toggle_node = 3 });
    try std.testing.expectEqual(@as(usize, 5), app.Model.tree_rows(&model, arena.allocator()).len);
    app.update(&model, .{ .toggle_node = 3 });
    try std.testing.expectEqual(@as(usize, 4), app.Model.tree_rows(&model, arena.allocator()).len);
}

// ---- overlays section

test "dialog confirm closes and counts a launch" {
    var model = app.Model{};
    app.update(&model, .open_dialog);
    app.update(&model, .confirm_dialog);
    try std.testing.expect(!model.dialog_open);
    try std.testing.expectEqual(@as(u8, 1), model.launches);
}

test "menu picks start empty and store the action id" {
    var model = app.Model{};
    try std.testing.expectEqualStrings("none", app.Model.menu_pick_name(&model));
    app.update(&model, .{ .menu_action = 1 });
    try std.testing.expectEqualStrings("Duplicate", app.Model.menu_pick_name(&model));
}

// ---- rich content section

test "open_note_link copies the payload and truncates to the buffer" {
    var model = app.Model{};
    app.update(&model, .{ .open_note_link = "gallery://issue/12" });
    try std.testing.expectEqualStrings("gallery://issue/12", app.Model.last_link(&model));
    var big: [200]u8 = undefined;
    @memset(&big, 'u');
    app.update(&model, .{ .open_note_link = &big });
    try std.testing.expectEqual(@as(usize, 128), model.link_len);
}

test "details toggles are index-guarded" {
    var model = app.Model{};
    app.update(&model, .{ .toggle_note_details = 2 });
    try std.testing.expect(model.note_details[2]);
    app.update(&model, .{ .toggle_note_details = 99 });
    try std.testing.expect(!model.note_details[0]);
}

test "advance_chart wraps the phase" {
    var model = app.Model{};
    model.chart_phase = 255;
    app.update(&model, .advance_chart);
    try std.testing.expectEqual(@as(u8, 0), model.chart_phase);
}

// ---- theming section

test "high contrast cycles follows-OS -> on -> off" {
    var model = app.Model{};
    try std.testing.expectEqualStrings("OS", app.Model.hc_name(&model));
    app.update(&model, .cycle_high_contrast);
    try std.testing.expect(model.high_contrast.?);
    app.update(&model, .cycle_high_contrast);
    try std.testing.expect(!model.high_contrast.?);
    app.update(&model, .cycle_high_contrast);
    try std.testing.expectEqual(@as(?bool, null), model.high_contrast);
}

// ---- playground section

test "press and hold count separately" {
    var model = app.Model{};
    app.update(&model, .pg_press);
    app.update(&model, .pg_press);
    app.update(&model, .pg_hold);
    try std.testing.expectEqual(@as(i64, 2), model.pg_press_count);
    try std.testing.expectEqual(@as(i64, 1), model.pg_hold_count);
}

test "drag pct clamps to the view" {
    var model = app.Model{};
    app.update(&model, .{ .pad_dragged = .{ .sourceId = 1, .phase = 0, .x = 400, .y = 10, .viewWidth = 800, .viewHeight = 600 } });
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), model.drag_pct, 0.0001);
    try std.testing.expectEqualStrings("change", app.Model.drag_phase_name(&model));
    app.update(&model, .{ .pad_dragged = .{ .sourceId = 1, .phase = 1, .x = 1200, .y = 10, .viewWidth = 800, .viewHeight = 600 } });
    try std.testing.expectEqual(@as(f32, 1.0), model.drag_pct);
    app.update(&model, .{ .pad_dragged = .{ .sourceId = 1, .phase = 2, .x = -20, .y = 10, .viewWidth = 800, .viewHeight = 600 } });
    try std.testing.expectEqual(@as(f32, 0.0), model.drag_pct);
    try std.testing.expectEqualStrings("cancel", app.Model.drag_phase_name(&model));
}

test "double-press plays and keeps the row selected" {
    var model = app.Model{};
    app.update(&model, .{ .select_track = 2 });
    try std.testing.expectEqual(@as(u8, 2), model.track_sel);
    try std.testing.expectEqual(@as(u8, 255), model.track_playing);
    app.update(&model, .{ .play_track = 1 });
    try std.testing.expectEqual(@as(u8, 1), model.track_sel);
    try std.testing.expectEqual(@as(u8, 1), model.track_playing);
}

test "hover containment flips the flag" {
    var model = app.Model{};
    app.update(&model, .pg_hover_enter);
    try std.testing.expect(model.pg_hovered);
    app.update(&model, .pg_hover_leave);
    try std.testing.expect(!model.pg_hovered);
}

// ---- gesture dispatch through the real markup handler table

test "hold, drag, double-press, and hover resolve to their Msgs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = app.Model{};

    var view = try PlaygroundMarkup.init(arena, playground_smoke_source);
    var ui = canvas.Ui(app.Msg).init(arena);
    const tree = try ui.finalize(try view.build(&ui, &model));

    const hold_button = findWidget(tree.root, "hold for more").?;
    try std.testing.expectEqual(app.Msg.pg_press, tree.msgFor(hold_button.id, .press).?);
    try std.testing.expectEqual(app.Msg.pg_hold, tree.msgFor(hold_button.id, .hold).?);

    const pad = findWidget(tree.root, "Drag pad").?;
    const drag_msg = tree.msgForDrag(pad.id, .{
        .source_id = 0,
        .phase = .change,
        .point = .{ .x = 640, .y = 60 },
        .delta = .{},
    }, geometry.SizeF{ .width = 800, .height = 600 }).?;
    switch (drag_msg) {
        .pad_dragged => |drag| {
            try std.testing.expectEqual(@as(i64, 1), drag.sourceId);
            try std.testing.expectEqual(@as(i64, 0), drag.phase);
            try std.testing.expectEqual(@as(f64, 640), drag.x);
            try std.testing.expectEqual(@as(f64, 800), drag.viewWidth);
            try std.testing.expectEqual(@as(f64, 600), drag.viewHeight);
        },
        else => return error.UnexpectedMsg,
    }

    const row = findWidget(tree.root, "night compile").?;
    switch (tree.msgForPointerClick(row.id, .up, 1).?) {
        .select_track => |id| try std.testing.expectEqual(@as(u8, 1), id),
        else => return error.UnexpectedMsg,
    }
    switch (tree.msgForPointerClick(row.id, .up, 2).?) {
        .play_track => |id| try std.testing.expectEqual(@as(u8, 1), id),
        else => return error.UnexpectedMsg,
    }

    const tile = findWidget(tree.root, "Hover tile").?;
    try std.testing.expectEqual(app.Msg.pg_hover_enter, tree.msgFor(tile.id, .hover_enter).?);
    try std.testing.expectEqual(app.Msg.pg_hover_leave, tree.msgFor(tile.id, .hover_leave).?);
}
