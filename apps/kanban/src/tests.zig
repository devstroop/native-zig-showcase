const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;

const AppMarkup = canvas.MarkupView(Model, main.Msg);

fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    var view = try AppMarkup.init(arena, main.app_markup);
    var ui = AppUi.init(arena);
    const node = view.build(&ui, model) catch |err| {
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    return ui.finalize(node);
}

fn findWidget(widget: canvas.Widget, name: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.text, name) or std.mem.eql(u8, widget.semantics.label, name)) return widget;
    for (widget.children) |child| {
        if (findWidget(child, name)) |found| return found;
    }
    return null;
}

fn expectWidget(widget: canvas.Widget, name: []const u8) !canvas.Widget {
    return findWidget(widget, name) orelse {
        std.debug.print("no widget named \"{s}\" in the view - if you changed app.native, update this test to match\n", .{name});
        return error.WidgetNotFound;
    };
}

fn expectText(widget: canvas.Widget, text: []const u8) !void {
    if (findWidget(widget, text) == null) {
        std.debug.print("no widget with text \"{s}\" in the view - if you changed app.native, update this test to match\n", .{text});
        return error.WidgetNotFound;
    }
}

/// One live drag step for a card, exactly as the runtime builds it from a
/// handler: the authored sourceId plus the injected phase and geometry.
fn dragStep(tree: AppUi.Tree, card: canvas.Widget, phase: canvas.WidgetDragPhase, x: f64) !main.Msg {
    return tree.msgForDrag(card.id, .{
        .source_id = 0,
        .phase = phase,
        .point = .{ .x = @floatCast(x), .y = 120 },
        .delta = .{},
    }, geometry.SizeF{ .width = 1000, .height = 600 }) orelse {
        std.debug.print("card \"{s}\" has no on-drag handler - app.native lost its binding\n", .{card.text});
        return error.NoDragHandler;
    };
}

test "dropping a card on a column moves it there" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();

    // "Sketch the board" starts in Backlog (column 0).
    try testing.expectEqual(@as(u8, 0), model.columns[0]);
    var tree = try buildTree(arena, &model);
    const card = try expectWidget(tree.root, "Sketch the board");

    // Live drag: phase 0 narrates without moving anything. x=700 of 1000
    // lands in the third column (Doing).
    main.update(&model, try dragStep(tree, card, .change, 700));
    try testing.expectEqual(@as(u8, 1), model.drag_phase);
    try testing.expectEqual(@as(u8, 2), model.drag_target);
    try testing.expectEqual(@as(u8, 0), model.columns[0]);

    // Release: the drop point is the whole decision - the card moves and
    // the source column count drops.
    main.update(&model, try dragStep(tree, card, .end, 700));
    try testing.expectEqual(@as(u8, 2), model.columns[0]);
    try testing.expectEqual(@as(u8, 2), model.drag_phase);
    try testing.expectEqual(@as(usize, 2), Model.backlog_count(&model));
    try testing.expectEqual(@as(usize, 3), Model.doing_count(&model));

    // The rebuilt tree shows the card under Doing and the status line
    // narrates the move.
    tree = try buildTree(arena, &model);
    const doing_cards = Model.doing_cards(&model, arena);
    var found_moved = false;
    for (doing_cards) |row| {
        if (std.mem.eql(u8, row.title, "Sketch the board")) found_moved = true;
    }
    try testing.expect(found_moved);
    try expectText(tree.root, "Moved \"Sketch the board\" to Doing.");
}

test "the drop point clamps and a cancelled drag changes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();

    var tree = try buildTree(arena, &model);
    const card = try expectWidget(tree.root, "Ship the demo");

    // Drags past the left/right edges clamp into the first/last column.
    main.update(&model, try dragStep(tree, card, .change, -40));
    try testing.expectEqual(@as(u8, 0), model.drag_target);
    main.update(&model, try dragStep(tree, card, .change, 1200));
    try testing.expectEqual(@as(u8, 3), model.drag_target);

    // Cancel: phase 2 walks back to cancelled and the board is untouched.
    main.update(&model, try dragStep(tree, card, .cancel, 1200));
    try testing.expectEqual(@as(u8, 3), model.drag_phase);
    try testing.expectEqual(@as(u8, 3), model.columns[7]);

    tree = try buildTree(arena, &model);
    try expectText(tree.root, "Drop cancelled - \"Ship the demo\" stays put.");
    try testing.expectEqual(@as(usize, 1), Model.done_count(&model));
}

test "the board mounts every column and the idle status line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = main.initialModel();
    const tree = try buildTree(arena, &model);

    // Column headers and the initial card distribution.
    _ = try expectWidget(tree.root, "Backlog");
    _ = try expectWidget(tree.root, "Todo");
    _ = try expectWidget(tree.root, "Doing");
    _ = try expectWidget(tree.root, "Done");
    for (main.card_titles) |title| _ = try expectWidget(tree.root, title);

    // The status line starts with the instruction, and every count text
    // renders through the binding.
    try expectText(tree.root, "Drag any card into another column - the drop point picks the column.");
    try testing.expectEqual(@as(usize, 3), Model.backlog_count(&model));
    try testing.expectEqual(@as(usize, 2), Model.todo_count(&model));
    try testing.expectEqual(@as(usize, 2), Model.doing_count(&model));
    try testing.expectEqual(@as(usize, 1), Model.done_count(&model));
}
