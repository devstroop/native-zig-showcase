const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Effects = main.Effects;

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

fn countWidgets(widget: canvas.Widget) usize {
    var total: usize = 1;
    for (widget.children) |child| total += countWidgets(child);
    return total;
}

fn range(start: usize, end: usize) canvas.VirtualListRange {
    return .{ .start_index = start, .end_index = end, .first_visible_index = start, .last_visible_index = end -| 1 };
}

test "the rows query materializes exactly the requested window" {
    var model = main.initialModel();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const first = Model.rows(&model, range(1_000, 1_020), arena);
    try testing.expectEqual(@as(usize, 20), first.len);
    try testing.expectEqual(@as(i64, 1_000), first[0].index);
    try testing.expectEqual(@as(i64, 1_019), first[19].index);

    // Rows derive from their index alone: the same index renders the
    // same event on every build.
    const again = Model.rows(&model, range(1_005, 1_006), arena);
    const repeat = Model.rows(&model, range(1_005, 1_006), arena);
    try testing.expectEqualStrings(again[0].detail, repeat[0].detail);
    try testing.expectEqualStrings(again[0].time, repeat[0].time);
    try testing.expectEqualStrings(again[0].source, repeat[0].source);

    // The timestamp walks the fixed 137 ms stride from the feed's
    // 09:00:00 origin: 1,000 events in, the clock reads 09:02:17.000.
    const stride = Model.rows(&model, range(1_000, 1_001), arena);
    try testing.expectEqualStrings("09:02:17.000", stride[0].time);

    // `loaded` is untouched by a query: the corpus is model state, the
    // window is view-side arithmetic.
    try testing.expectEqual(main.initial_rows, model.loaded);
}

test "reaching the end appends one batch and clamps at the corpus cap" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model = main.initialModel();
    try testing.expectEqual(main.initial_rows, model.loaded);

    main.update(&model, .load_more, &fx);
    try testing.expectEqual(main.initial_rows + main.batch_size, model.loaded);

    // The last batch is partial: near the cap the append clamps once
    // and further approaches are no-ops.
    model.loaded = main.corpus_total - 1;
    main.update(&model, .load_more, &fx);
    try testing.expectEqual(main.corpus_total, model.loaded);
    main.update(&model, .load_more, &fx);
    try testing.expectEqual(main.corpus_total, model.loaded);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const status = Model.loaded_text(&model, arena_state.allocator());
    try testing.expectEqualStrings("100000 of 100000 events", status);
}

test "selection lands on the row and rejects indices outside the load" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model = main.initialModel();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("none", Model.selected_text(&model, arena));

    main.update(&model, .{ .select = 4_096 }, &fx);
    try testing.expectEqual(@as(i64, 4_096), model.selected);
    try testing.expectEqualStrings("event #4096", Model.selected_text(&model, arena));

    // Past the loaded edge, negative, and beyond the corpus all leave
    // the selection alone.
    main.update(&model, .{ .select = @intCast(model.loaded) }, &fx);
    try testing.expectEqual(@as(i64, 4_096), model.selected);
    main.update(&model, .{ .select = -1 }, &fx);
    try testing.expectEqual(@as(i64, 4_096), model.selected);
    main.update(&model, .{ .select = @intCast(main.corpus_total + 1) }, &fx);
    try testing.expectEqual(@as(i64, 4_096), model.selected);
}

test "the virtual list mounts a viewport-sized window, not the corpus" {
    var model = main.initialModel();
    model.selected = 42;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try buildTree(arena, &model);

    try expectText(tree.root, "Event stream");
    try expectText(tree.root, "10000 of 100000 events");

    // The first window's rows are built...
    const row_zero = Model.rows(&model, range(0, 1), arena);
    _ = try expectWidget(tree.root, row_zero[0].detail);
    // ...and exactly those: an event deep in the corpus is not in the
    // tree, because its row was never asked for.
    const far_row = Model.rows(&model, range(90_000, 90_001), arena);
    try testing.expect(findWidget(tree.root, far_row[0].detail) == null);

    // The proof in one number: ~30 mounted rows is bounded no matter
    // how large `loaded` grows.
    const mounted = countWidgets(tree.root);
    try testing.expect(mounted < 400);
}
