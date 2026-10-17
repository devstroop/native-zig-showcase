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

test "toggling live arms the repeating sampling timer" {
    // A real effects channel in fake-executor mode: requests are
    // recorded for assertions instead of touching the OS.
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model = main.initialModel();

    main.update(&model, .toggle_running, &fx);
    try testing.expect(model.running);
    try testing.expectEqual(@as(usize, 1), fx.pendingTimerCount());
    const timer = fx.pendingTimerAt(0).?;
    try testing.expectEqual(main.live_timer_key, timer.key);
    try testing.expectEqual(@as(u64, 200), timer.interval_ms);
    try testing.expectEqual(native_sdk.TimerMode.repeating, timer.mode);

    // Toggling off cancels the timer: no pending fake timers remain.
    main.update(&model, .toggle_running, &fx);
    try testing.expect(!model.running);
    try testing.expectEqual(@as(usize, 0), fx.pendingTimerCount());
}

test "ticks append samples and wrap the ring at capacity" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model = main.initialModel();
    try testing.expectEqual(main.sample_capacity, Model.sample_count(&model));

    // The window is full, so the next tick overwrites the oldest sample
    // and the ring head advances one slot.
    const head_before = model.head;
    main.update(&model, .{ .tick = .{ .key = main.live_timer_key, .timestamp_ns = 0, .outcome = .fired } }, &fx);
    try testing.expectEqual(main.sample_capacity, Model.sample_count(&model));
    try testing.expectEqual((head_before + 1) % main.sample_capacity, model.head);

    // A non-`fired` outcome (a rejected timer) must not append.
    main.update(&model, .{ .tick = .{ .key = main.live_timer_key, .timestamp_ns = 0, .outcome = .rejected } }, &fx);
    try testing.expectEqual((head_before + 1) % main.sample_capacity, model.head);
}

test "regenerate refills the ring with a full deterministic window" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    const first_current = Model.current_text(&model, arena);

    // Drain the window to empty, then regenerate: the ring is full
    // again and the seeded generator redraws the same first window.
    model.len = 0;
    model.head = 0;
    try testing.expectEqual(@as(usize, 0), Model.sample_count(&model));
    try testing.expectEqualStrings("0.0", Model.current_text(&model, arena));

    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .regenerate, &fx);
    try testing.expectEqual(main.sample_capacity, Model.sample_count(&model));

    // A fresh model holds the same boot curve, so regenerate from a
    // drained ring redraws exactly the launch window - replayable.
    var again = main.initialModel();
    const same = Model.request_series(&again, arena);
    const regenerated = Model.request_series(&model, arena);
    try testing.expectEqual(same.len, regenerated.len);
    for (same, regenerated) |a, b| try testing.expectEqual(a, b);
    try testing.expectEqualStrings(first_current, Model.current_text(&model, arena));

    // The histogram buckets partition the window: counts sum to len.
    const buckets = Model.histogram(&again, arena);
    try testing.expectEqual(main.bucket_count, buckets.len);
    var total: f32 = 0;
    for (buckets) |count| total += count;
    try testing.expectEqual(@as(f32, @floatFromInt(main.sample_capacity)), total);

    // And the x-labels pair one-per-bucket.
    try testing.expectEqual(main.bucket_count, Model.bucket_labels(&again).len);
}

test "the dashboard mounts every chart and the paused status line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = main.initialModel();
    const tree = try buildTree(arena, &model);

    // Every card and tile is present.
    _ = try expectWidget(tree.root, "Live metrics");
    _ = try expectWidget(tree.root, "Requests and error spikes");
    _ = try expectWidget(tree.root, "Load histogram");
    _ = try expectWidget(tree.root, "Requests sparkline");
    _ = try expectWidget(tree.root, "Current load");
    _ = try expectWidget(tree.root, "Peak load");
    _ = try expectWidget(tree.root, "Mean load");
    _ = try expectWidget(tree.root, "Window");

    // The status line starts paused with the full window of samples.
    const status = Model.live_status(&model, arena);
    try testing.expect(std.mem.startsWith(u8, status, "live: paused - 48 samples"));
    try expectText(tree.root, status);

    // The badge counts the live window.
    try expectText(tree.root, "48 samples");
}
