const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Effects = main.Effects;

const AppMarkup = canvas.MarkupView(Model, main.Msg);

/// A registry double: records what the effects channel asked the
/// registry to do, and can be flipped into failure mode to prove the
/// model keeps the fallback visible when registration fails.
const RegistryProbe = struct {
    var register_calls: usize = 0;
    var register_bytes_calls: usize = 0;
    var unregister_calls: usize = 0;
    var last_register_id: u64 = 0;
    var last_register_width: usize = 0;
    var last_register_height: usize = 0;
    var last_register_rgba_len: usize = 0;
    var last_unregistered_id: u64 = 0;
    var fail: bool = false;

    fn reset() void {
        register_calls = 0;
        register_bytes_calls = 0;
        unregister_calls = 0;
        last_register_id = 0;
        last_register_width = 0;
        last_register_height = 0;
        last_register_rgba_len = 0;
        last_unregistered_id = 0;
        fail = false;
    }

    fn register(_: *anyopaque, id: u64, width: usize, height: usize, rgba8: []const u8) anyerror!void {
        if (fail) return error.ImageTooLarge;
        register_calls += 1;
        last_register_id = id;
        last_register_width = width;
        last_register_height = height;
        last_register_rgba_len = rgba8.len;
    }

    fn registerBytes(_: *anyopaque, id: u64, bytes: []const u8) anyerror!native_sdk.RegisteredImage {
        if (fail) return error.ImageDecodeFailed;
        register_bytes_calls += 1;
        last_register_id = id;
        last_register_rgba_len = bytes.len;
        return .{ .width = 1024, .height = 1024 };
    }

    fn unregister(_: *anyopaque, id: u64) bool {
        unregister_calls += 1;
        last_unregistered_id = id;
        return true;
    }

    fn binding() native_sdk.runtime.ImageRegistryBinding {
        return .{
            .context = undefined,
            .register_fn = register,
            .register_bytes_fn = registerBytes,
            .unregister_fn = unregister,
        };
    }
};

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

fn expectWidget(widget: canvas.Widget, name: []const u8) !void {
    if (findWidget(widget, name) == null) {
        std.debug.print("no widget named \"{s}\" in the view - if you changed app.native, update this test to match\n", .{name});
        return error.WidgetNotFound;
    }
}

fn expectText(widget: canvas.Widget, text: []const u8) !void {
    return expectWidget(widget, text);
}

fn expectAbsent(widget: canvas.Widget, name: []const u8) !void {
    if (findWidget(widget, name) != null) {
        std.debug.print("widget named \"{s}\" should not be present - if you changed app.native, update this test to match\n", .{name});
        return error.WidgetUnexpected;
    }
}

test "the lifecycle hook boots on start and ignores the rest" {
    try testing.expectEqual(main.Msg.boot, main.onLifecycle(.start).?);
    try testing.expect(main.onLifecycle(.activate) == null);
    try testing.expect(main.onLifecycle(.frame) == null);
    try testing.expect(main.onLifecycle(.stop) == null);
}

test "boot registers the bundled icon bytes and the first atlas" {
    RegistryProbe.reset();
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.bindImages(RegistryProbe.binding());

    var model = main.initialModel();
    try testing.expect(!Model.atlas_ready(&model, testing.allocator));

    main.update(&model, .boot, &fx);

    // Encoded-bytes path: id into the model only after the decode.
    try testing.expectEqual(main.icon_image_id, model.icon_id);
    try testing.expectEqual(@as(usize, 1), RegistryProbe.register_bytes_calls);

    // Raw-pixels path: generation 1 lands under base + 1 with the
    // atlas geometry and a full RGBA8 buffer.
    try testing.expectEqual(main.atlas_image_id_base + 1, model.atlas_id);
    try testing.expectEqual(@as(u32, 1), model.generation);
    try testing.expect(Model.atlas_ready(&model, testing.allocator));
    try testing.expectEqual(@as(usize, 1), RegistryProbe.register_calls);
    try testing.expectEqual(model.atlas_id, RegistryProbe.last_register_id);
    try testing.expectEqual(main.atlas_size, RegistryProbe.last_register_width);
    try testing.expectEqual(main.atlas_size, RegistryProbe.last_register_height);
    try testing.expectEqual(main.atlas_size * main.atlas_size * 4, RegistryProbe.last_register_rgba_len);
}

test "regenerate retires the previous id before registering the new atlas" {
    RegistryProbe.reset();
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.bindImages(RegistryProbe.binding());

    var model = main.initialModel();
    main.update(&model, .boot, &fx);
    const first_id = model.atlas_id;

    main.update(&model, .regenerate, &fx);
    try testing.expectEqual(first_id + 1, model.atlas_id);
    try testing.expectEqual(@as(u32, 2), model.generation);
    try testing.expectEqual(@as(usize, 1), RegistryProbe.unregister_calls);
    try testing.expectEqual(first_id, RegistryProbe.last_unregistered_id);
    try testing.expectEqual(model.atlas_id, RegistryProbe.last_register_id);

    main.update(&model, .regenerate, &fx);
    try testing.expectEqual(@as(u32, 3), model.generation);
    try testing.expectEqual(@as(usize, 2), RegistryProbe.unregister_calls);
    try testing.expectEqual(first_id + 1, RegistryProbe.last_unregistered_id);
}

test "clear unregisters and keeps the fallback until the next generate" {
    RegistryProbe.reset();
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.bindImages(RegistryProbe.binding());

    var model = main.initialModel();
    main.update(&model, .boot, &fx);
    const first_id = model.atlas_id;

    main.update(&model, .clear, &fx);
    try testing.expectEqual(@as(u64, 0), model.atlas_id);
    try testing.expect(!Model.atlas_ready(&model, testing.allocator));
    try testing.expectEqual(@as(usize, 1), RegistryProbe.unregister_calls);
    try testing.expectEqual(first_id, RegistryProbe.last_unregistered_id);

    main.update(&model, .regenerate, &fx);
    try testing.expectEqual(first_id + 1, model.atlas_id);
    try testing.expectEqual(@as(u32, 2), model.generation);

    // Clear again with nothing registered is a no-op, not an error.
    main.update(&model, .clear, &fx);
    main.update(&model, .clear, &fx);
    try testing.expectEqual(@as(usize, 2), RegistryProbe.unregister_calls);
}

test "a registry failure keeps the fallback visible and retries cleanly" {
    RegistryProbe.reset();
    var fx = Effects.init(testing.allocator);
    defer fx.deinit();
    fx.executor = .fake;
    fx.bindImages(RegistryProbe.binding());
    RegistryProbe.fail = true;

    var model = main.initialModel();
    main.update(&model, .boot, &fx);
    try testing.expectEqual(@as(u64, 0), model.icon_id);
    try testing.expectEqual(@as(u64, 0), model.atlas_id);
    try testing.expectEqual(@as(u32, 0), model.generation);
    try testing.expectEqual(@as(usize, 0), RegistryProbe.register_calls);
    try testing.expectEqual(@as(usize, 0), RegistryProbe.unregister_calls);

    RegistryProbe.fail = false;
    main.update(&model, .regenerate, &fx);
    try testing.expectEqual(@as(u64, main.atlas_image_id_base + 1), model.atlas_id);
    try testing.expectEqual(@as(u32, 1), model.generation);
}

test "the atlas pixels are deterministic and generation-scoped" {
    var generation_one: [main.atlas_size * main.atlas_size * 4]u8 = undefined;
    @memcpy(&generation_one, main.fillAtlas(1));
    var generation_one_again: [main.atlas_size * main.atlas_size * 4]u8 = undefined;
    @memcpy(&generation_one_again, main.fillAtlas(1));
    var generation_two: [main.atlas_size * main.atlas_size * 4]u8 = undefined;
    @memcpy(&generation_two, main.fillAtlas(2));

    try testing.expectEqualSlices(u8, &generation_one, &generation_one_again);
    try testing.expect(!std.mem.eql(u8, &generation_one, &generation_two));

    // Generation 1 puts phase 37 on the top-left pixel: r = 37,
    // g = 3 * 37, b = 5 * 37, opaque.
    try testing.expectEqual(@as(u8, 37), generation_one[0]);
    try testing.expectEqual(@as(u8, 111), generation_one[1]);
    try testing.expectEqual(@as(u8, 185), generation_one[2]);
    try testing.expectEqual(@as(u8, 255), generation_one[3]);
}

test "the view narrates the fallback state before anything is registered" {
    const model = main.initialModel();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try buildTree(arena, &model);

    try expectText(tree.root, "no atlas registered - press Regenerate");
    try expectText(tree.root, "atlas #0 - generation 0");
    // The avatar keeps its initials while the icon id is 0.
    try expectWidget(tree.root, "NS");
}

test "the view binds the registered ids and generation" {
    var model = main.initialModel();
    model.icon_id = main.icon_image_id;
    model.atlas_id = main.atlas_image_id_base + 2;
    model.generation = 2;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree = try buildTree(arena, &model);

    try expectAbsent(tree.root, "no atlas registered - press Regenerate");
    try expectWidget(tree.root, "Generated atlas");
    try expectWidget(tree.root, "Bundled icon avatar");
    try expectText(tree.root, "atlas #18 - generation 2");
    try expectText(tree.root, "generation 2");
}
