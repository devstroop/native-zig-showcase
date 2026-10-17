const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;
const Effects = main.Effects;
const DesktopApp = native_sdk.UiApp(Model, Msg);

const AppMarkup = canvas.MarkupView(Model, Msg);
const InspectorView = canvas.CompiledMarkupView(Model, Msg, @embedFile("inspector.native"));
const ScratchpadView = canvas.CompiledMarkupView(Model, Msg, @embedFile("scratchpad.native"));

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

/// A declared window's tree, built the way `window_view` builds it.
fn buildWindowTree(arena: std.mem.Allocator, comptime View: type, model: *const Model) !AppUi.Tree {
    var ui = AppUi.init(arena);
    return ui.finalize(View.build(&ui, model));
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
        std.debug.print("no widget named \"{s}\" in the view - if you changed the markup, update this test to match\n", .{name});
        return error.WidgetNotFound;
    };
}

fn expectText(widget: canvas.Widget, text: []const u8) !void {
    if (findWidget(widget, text) == null) {
        std.debug.print("no widget with text \"{s}\" in the view - if you changed the markup, update this test to match\n", .{text});
        return error.WidgetNotFound;
    }
}

test "declared windows follow the model" {
    var model = main.initialModel();
    var scratch: DesktopApp.WindowsScratch = undefined;

    // No flags, no windows: presence is liveness.
    try testing.expectEqual(@as(usize, 0), main.windows(&model, &scratch).len);

    model.inspector_open = true;
    const one = main.windows(&model, &scratch);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("inspector", one[0].label);
    try testing.expectEqualStrings("inspector-canvas", one[0].canvas_label);
    try testing.expectEqualStrings("Inspector", one[0].title);
    try testing.expectEqual(@as(f32, 380), one[0].width);
    try testing.expectEqual(@as(f32, 440), one[0].height);
    try testing.expectEqual(native_sdk.app_manifest.WindowRestorePolicy.center_on_primary, one[0].restore_policy);
    try testing.expect(std.meta.eql(one[0].on_close.?, Msg.inspector_closed));

    // Both declared: order is inspector, then scratchpad. The
    // scratchpad's user close is a .hide where the host supports the
    // policy (macOS) and a declarative close elsewhere (Linux/GTK);
    // either way `on_close` reports the user's close.
    model.scratch_open = true;
    const two = main.windows(&model, &scratch);
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqualStrings("inspector", two[0].label);
    try testing.expectEqualStrings("scratchpad", two[1].label);
    try testing.expectEqualStrings("scratchpad-canvas", two[1].canvas_label);
    try testing.expectEqual(main.scratchpad_close_policy, two[1].close_policy);
    try testing.expect(std.meta.eql(two[1].on_close.?, Msg.scratchpad_closed));

    // Declarative close: clearing the flags empties the declared set -
    // the reconcile the runtime performs is the real close.
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    main.update(&model, .close_inspector, &fx);
    main.update(&model, .inspector_closed, &fx);
    model.scratch_open = false;
    try testing.expectEqual(@as(usize, 0), main.windows(&model, &scratch).len);
}

test "window verbs ride the effects mirror" {
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model = main.initialModel();

    main.update(&model, .open_inspector, &fx);
    main.update(&model, .minimize_inspector, &fx);
    try testing.expectEqual(@as(u32, 1), fx.windowActionState().minimize_count);
    try testing.expectEqualStrings("inspector", fx.windowActionState().lastLabel());

    main.update(&model, .hide_scratchpad, &fx);
    main.update(&model, .show_scratchpad, &fx);
    try testing.expectEqual(@as(u32, 1), fx.windowActionState().hide_count);
    try testing.expectEqual(@as(u32, 1), fx.windowActionState().show_count);
    try testing.expectEqualStrings("scratchpad", fx.windowActionState().lastLabel());

    main.update(&model, .quit_app, &fx);
    try testing.expectEqual(@as(u32, 1), fx.windowActionState().quit_count);

    // The user's own close came back as a Msg: the model clears the
    // flag, and the next declared set no longer contains the window.
    var scratch: DesktopApp.WindowsScratch = undefined;
    try testing.expectEqual(@as(usize, 1), main.windows(&model, &scratch).len);
    main.update(&model, .inspector_closed, &fx);
    try testing.expect(!model.inspector_open);
    try testing.expectEqual(@as(usize, 0), main.windows(&model, &scratch).len);
}

test "the control room mounts and the status line narrates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;

    var model = main.initialModel();
    var tree = try buildTree(arena, &model);

    _ = try expectWidget(tree.root, "Desktop");
    _ = try expectWidget(tree.root, "Open inspector");
    _ = try expectWidget(tree.root, "Minimize it");
    _ = try expectWidget(tree.root, "Close it");
    _ = try expectWidget(tree.root, "Open scratchpad");
    _ = try expectWidget(tree.root, "Hide it");
    _ = try expectWidget(tree.root, "Show it");
    _ = try expectWidget(tree.root, "Ping every window");
    _ = try expectWidget(tree.root, "Quit the app");
    try expectText(tree.root, "0 pings");
    try expectText(tree.root, "windows: none yet - nothing yet - open a window - 0 pings");

    // Pings and window flags rebuild the same tree with new text.
    main.update(&model, .ping, &fx);
    main.update(&model, .ping, &fx);
    main.update(&model, .open_inspector, &fx);
    main.update(&model, .open_scratchpad, &fx);
    tree = try buildTree(arena, &model);
    try expectText(tree.root, "2 pings");
    try expectText(tree.root, "windows: inspector + scratchpad - opened the scratchpad - 2 pings");
}

test "each declared window's tree binds the shared model" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = main.initialModel();
    model.pings = 3;

    const inspector = try buildWindowTree(arena, InspectorView, &model);
    _ = try expectWidget(inspector.root, "Inspector");
    try expectText(inspector.root, "3 pings so far");
    _ = try expectWidget(inspector.root, "Ping from the inspector");
    try expectText(inspector.root, "windows: none yet - nothing yet - open a window - 3 pings");

    const scratchpad = try buildWindowTree(arena, ScratchpadView, &model);
    _ = try expectWidget(scratchpad.root, "Scratchpad");
    try expectText(scratchpad.root, "3 pings so far - hiding never destroyed this window");
    _ = try expectWidget(scratchpad.root, "Ping from the scratchpad");
}
