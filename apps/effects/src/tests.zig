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
        // Name the app.native position instead of leaving a bare error
        // trace: the usual causes are a binding without a matching
        // Model field or an on-* message without a Msg arm.
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    return ui.finalize(node);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

/// A miss fails the test with the mismatch spelled out instead of a
/// null-unwrap panic: the usual cause is app.native and this test
/// drifting apart after an edit.
fn expectByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) !canvas.Widget {
    return findByText(widget, kind, text) orelse {
        std.debug.print("no {t} with text \"{s}\" in the view - if you changed app.native, update this test to match\n", .{ kind, text });
        return error.WidgetNotFound;
    };
}

/// A real effects channel in fake-executor mode: requests are recorded
/// for assertions instead of touching the OS.
fn testFx() Effects {
    var fx = Effects.init(testing.allocator);
    fx.executor = .fake;
    return fx;
}

test "the streaming spawn delivers line Msgs into a keyed ring window" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = testFx();
    defer fx.deinit();

    var model = main.initialModel();

    // Click "Run": one spawn request is recorded, keyed to the model's
    // stream slot, in line mode.
    var tree = try buildTree(arena, &model);
    const run = try expectByText(tree.root, .button, "Run");
    main.update(&model, tree.msgForPointer(run.id, .up).?, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    const request = fx.pendingSpawnAt(0).?;
    try testing.expectEqual(main.stream_key, request.key);
    try testing.expectEqual(native_sdk.EffectOutputMode.lines, request.output);
    try testing.expectEqualStrings("sh", request.argv[0]);
    try testing.expectEqualStrings("-c", request.argv[1]);

    // Ten lines arrive as ordinary Msgs: the count is the total and the
    // ring keeps the newest eight, keyed by arrival sequence.
    var line_buffer: [32]u8 = undefined;
    for (1..11) |i| {
        const text = try std.fmt.bufPrint(&line_buffer, "line {d} of 8", .{i});
        main.update(&model, .{ .line = .{ .key = main.stream_key, .line = text } }, &fx);
    }
    try testing.expectEqual(@as(i64, 10), model.stream_count);
    const rows = Model.stream_log(&model, arena);
    try testing.expectEqual(@as(usize, 8), rows.len);
    try testing.expectEqual(@as(i64, 3), rows[0].id);
    try testing.expectEqualStrings("line 3 of 8", rows[0].title);
    try testing.expectEqual(@as(i64, 10), rows[7].id);
    try testing.expectEqualStrings("line 10 of 8", rows[7].title);

    // Cancel, then the cancelled exit: the phase lands on cancelled and
    // the tree says so.
    main.update(&model, .stream_cancel, &fx);
    main.update(&model, .{ .exited = .{ .key = main.stream_key, .reason = .cancelled } }, &fx);
    try testing.expectEqual(@as(u8, 3), model.stream_phase);

    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "stream: cancelled");
    _ = try expectByText(tree.root, .text, "10 lines");
}

test "the collect spawn delivers stdout and the stderr tail on one exit Msg" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = testFx();
    defer fx.deinit();

    var model = main.initialModel();

    var tree = try buildTree(arena, &model);
    // "Run" belongs to both subprocess cards; the collect one follows the
    // streaming one in document order.
    const run = try expectNthButton(tree.root, "Run", 1);
    main.update(&model, tree.msgForPointer(run.id, .up).?, &fx);

    try testing.expectEqual(@as(usize, 1), fx.pendingSpawnCount());
    const request = fx.pendingSpawnAt(0).?;
    try testing.expectEqual(main.collect_key, request.key);
    try testing.expectEqual(native_sdk.EffectOutputMode.collect, request.output);

    // One terminal exit carries everything: stdout, the stderr tail, the
    // code, and no line Msgs ever fired.
    const stdout_text = "{\"ok\":true,\"items\":3}";
    const stderr_text = "warn: item 4 skipped";
    main.update(&model, .{ .exited = .{
        .key = main.collect_key,
        .code = 3,
        .reason = .exited,
        .output = stdout_text,
        .stderr_tail = stderr_text,
    } }, &fx);

    try testing.expectEqual(@as(u8, 2), model.collect_phase);
    try testing.expectEqual(@as(i32, 3), model.collect_code);
    try testing.expectEqualStrings(stdout_text, Model.collect_stdout(&model));
    try testing.expectEqualStrings(stderr_text, Model.collect_stderr(&model));

    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "collect: exited");
    _ = try expectByText(tree.root, .text, "exit code 3");
    _ = try expectByText(tree.root, .text, "stdout (21 bytes):");
    _ = try expectByText(tree.root, .text, stdout_text);
}

/// The (n+1)th button with this text, in document order: "Run" appears in
/// both subprocess cards, so tests address them by position.
fn findNthButton(widget: canvas.Widget, text: []const u8, n: usize) ?canvas.Widget {
    var remaining = n;
    return findNthButtonInner(widget, text, &remaining);
}

fn findNthButtonInner(widget: canvas.Widget, text: []const u8, remaining: *usize) ?canvas.Widget {
    if (widget.kind == .button and std.mem.eql(u8, widget.text, text)) {
        if (remaining.* == 0) return widget;
        remaining.* -= 1;
    }
    for (widget.children) |child| {
        if (findNthButtonInner(child, text, remaining)) |found| return found;
    }
    return null;
}

fn expectNthButton(widget: canvas.Widget, text: []const u8, n: usize) !canvas.Widget {
    return findNthButton(widget, text, n) orelse {
        std.debug.print("fewer than {d} buttons with text \"{s}\" in the view - if you changed app.native, update this test to match\n", .{ n + 1, text });
        return error.WidgetNotFound;
    };
}

test "fetch reports the status and body for the good host, the outcome for the bad one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = testFx();
    defer fx.deinit();

    var model = main.initialModel();

    var tree = try buildTree(arena, &model);
    const good = try expectByText(tree.root, .button, "Fetch example.com");
    main.update(&model, tree.msgForPointer(good.id, .up).?, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingFetchCount());
    const request = fx.pendingFetchAt(0).?;
    try testing.expectEqual(main.fetch_key, request.key);
    try testing.expectEqualStrings(main.fetch_url, request.url);

    // An ok response: status and body land in the model, the preview text
    // is derived, and the tree shows both facts.
    const body = "<html>body</html>";
    main.update(&model, .{ .fetched = .{ .key = main.fetch_key, .status = 200, .body = body } }, &fx);
    try testing.expectEqual(@as(u8, 2), model.fetch_phase);
    try testing.expectEqual(@as(u16, 200), model.fetch_status);
    try testing.expectEqualStrings(body, Model.fetch_body_text(&model));

    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "fetch: ok");
    _ = try expectByText(tree.root, .text, "HTTP 200 - 17 bytes");
    _ = try expectByText(tree.root, .text, body);

    // The bad host never connects: the outcome alone drives the label.
    const bad = try expectByText(tree.root, .button, "Bad host");
    main.update(&model, tree.msgForPointer(bad.id, .up).?, &fx);
    const bad_request = fx.pendingFetchAt(1).?;
    try testing.expectEqual(main.fetch_bad_key, bad_request.key);
    try testing.expectEqualStrings(main.fetch_bad_url, bad_request.url);

    main.update(&model, .{ .fetched = .{ .key = main.fetch_bad_key, .outcome = .connect_failed } }, &fx);
    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "fetch: connect failed");
}

test "note save and reload round-trip through the channel" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = testFx();
    defer fx.deinit();

    var model = main.initialModel();
    _ = model.note_draft.set("hello effects");

    // Save: the recorded write carries the editor text and the resolved
    // in-root path; the ok result only flips the phase and byte count.
    var tree = try buildTree(arena, &model);
    const save = try expectByText(tree.root, .button, "Save");
    main.update(&model, tree.msgForPointer(save.id, .up).?, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    const write_request = fx.pendingFileAt(0).?;
    try testing.expectEqual(main.note_save_key, write_request.key);
    try testing.expectEqual(native_sdk.EffectFileOp.write, write_request.op);
    try testing.expect(std.mem.endsWith(u8, write_request.path, "note.txt"));
    try testing.expectEqualStrings("hello effects", write_request.bytes);

    main.update(&model, .{ .file_result = .{ .key = main.note_save_key, .op = .write } }, &fx);
    try testing.expectEqual(@as(u8, 5), model.note_phase);
    try testing.expectEqual(@as(usize, 13), model.note_bytes);

    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "note: saved");
    _ = try expectByText(tree.root, .text, "13 bytes");

    // Reload: the read request is recorded; its ok result fills the
    // editor buffer and re-derives the binding.
    const reload = try expectByText(tree.root, .button, "Reload");
    main.update(&model, tree.msgForPointer(reload.id, .up).?, &fx);
    const read_request = fx.pendingFileAt(1).?;
    try testing.expectEqual(main.note_load_key, read_request.key);
    try testing.expectEqual(native_sdk.EffectFileOp.read, read_request.op);
    try testing.expectEqualStrings(main.note_path, read_request.path);

    main.update(&model, .{ .file_result = .{ .key = main.note_load_key, .bytes = "hello again" } }, &fx);
    try testing.expectEqual(@as(u8, 2), model.note_phase);
    try testing.expectEqualStrings("hello again", model.note_draft.text());
    try testing.expectEqual(@as(usize, 11), model.note_bytes);

    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "note: loaded");
}

test "boot reads the note on the installing frame, before the first paint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = testFx();
    defer fx.deinit();

    // boot() is what the host runs on the installing frame: one read
    // request for the note, keyed to the boot slot.
    var model = main.initialModel();
    main.boot(&model, &fx);
    try testing.expectEqual(@as(u8, 1), model.note_phase);
    try testing.expectEqual(@as(usize, 1), fx.pendingFileCount());
    const request = fx.pendingFileAt(0).?;
    try testing.expectEqual(main.boot_load_key, request.key);
    try testing.expectEqual(native_sdk.EffectFileOp.read, request.op);
    try testing.expectEqualStrings(main.note_path, request.path);

    // No note on disk yet: the not_found outcome is a state, not an
    // error - the card starts empty and says so.
    main.update(&model, .{ .file_result = .{ .key = main.boot_load_key, .outcome = .not_found } }, &fx);
    try testing.expectEqual(@as(u8, 3), model.note_phase);

    const tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, "note: no note yet");
    _ = try expectByText(tree.root, .text, "0 bytes");
}

test "clipboard round-trips through the channel and notify just counts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fx = testFx();
    defer fx.deinit();

    var model = main.initialModel();

    // Copy summary: the recorded write carries a generated summary; its
    // ok result lands on "copied".
    var tree = try buildTree(arena, &model);
    const copy = try expectByText(tree.root, .button, "Copy summary");
    main.update(&model, tree.msgForPointer(copy.id, .up).?, &fx);
    try testing.expectEqual(@as(usize, 1), fx.pendingClipboardCount());
    const write_request = fx.pendingClipboardAt(0).?;
    try testing.expectEqual(main.clip_write_key, write_request.key);
    try testing.expectEqual(native_sdk.EffectClipboardOp.write, write_request.op);
    try testing.expect(std.mem.startsWith(u8, write_request.text, "Native SDK effects:"));

    main.update(&model, .{ .clipboard_result = .{ .key = main.clip_write_key, .op = .write } }, &fx);
    try testing.expectEqual(@as(u8, 2), model.clip_phase);

    // Paste: the read request is recorded; its ok result copies the text
    // into model-owned storage and the tree shows it.
    tree = try buildTree(arena, &model);
    var status_buffer: [64]u8 = undefined;
    _ = try expectByText(tree.root, .text, try std.fmt.bufPrint(&status_buffer, "clipboard: copied - {d} bytes", .{model.clip_bytes}));
    const paste = try expectByText(tree.root, .button, "Paste");
    main.update(&model, tree.msgForPointer(paste.id, .up).?, &fx);
    const read_request = fx.pendingClipboardAt(1).?;
    try testing.expectEqual(main.clip_read_key, read_request.key);
    try testing.expectEqual(native_sdk.EffectClipboardOp.read, read_request.op);

    main.update(&model, .{ .clipboard_result = .{ .key = main.clip_read_key, .op = .read, .text = "clip echo" } }, &fx);
    try testing.expectEqual(@as(u8, 4), model.clip_phase);
    try testing.expectEqualStrings("clip echo", Model.clipboard_text(&model));

    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .text, try std.fmt.bufPrint(&status_buffer, "clipboard: pasted - {d} bytes", .{model.clip_bytes}));
    _ = try expectByText(tree.root, .text, "clip echo");

    // Notify is fire-and-forget: nothing is recorded to await, the
    // counter is the whole observable.
    const notify = try expectByText(tree.root, .button, "Notify");
    main.update(&model, tree.msgForPointer(notify.id, .up).?, &fx);
    main.update(&model, .notify, &fx);
    try testing.expectEqual(@as(usize, 2), model.notify_count);

    tree = try buildTree(arena, &model);
    _ = try expectByText(tree.root, .badge, "2 notifications");
}

test "the layout mounts all five cards and the status bar" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = main.initialModel();
    const tree = try buildTree(arena, &model);

    // Card titles: one per capability.
    _ = try expectByText(tree.root, .text, "Subprocess - streaming stdout");
    _ = try expectByText(tree.root, .text, "Subprocess - collected stdout and stderr tail");
    _ = try expectByText(tree.root, .text, "HTTP fetch");
    _ = try expectByText(tree.root, .text, "Files - a note in the app data directory");
    _ = try expectByText(tree.root, .text, "Clipboard");

    // Every idle status reads from the derived phase names, and the
    // status bar summarizes all four phases.
    _ = try expectByText(tree.root, .text, "stream: idle");
    _ = try expectByText(tree.root, .text, "collect: idle");
    _ = try expectByText(tree.root, .text, "fetch: idle");
    _ = try expectByText(tree.root, .text, "note: idle");
    _ = try expectByText(tree.root, .text, "clipboard: idle - 0 bytes");
    _ = try expectByText(tree.root, .status_bar, "idle - idle - idle - idle");
}
