//! The gallery core: one Model field picks the visible section, the
//! split keeps the sidebar fraction, and the view is a map of <if>
//! gates over imported section templates. Sections carry their own
//! state as ordinary Model fields; nothing renders outside `update`.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "main-canvas";
const window_width: f32 = 1100;
const window_height: f32 = 760;

const app_permissions = [_][]const u8{ native_sdk.security.permission_command, native_sdk.security.permission_view };
const shell_views = [_]native_sdk.ShellView{
    .{ .label = canvas_label, .kind = .gpu_surface, .fill = true, .role = "Gallery canvas", .accessibility_label = "Gallery", .gpu_backend = .metal, .gpu_pixel_format = .bgra8_unorm, .gpu_present_mode = .timer, .gpu_alpha_mode = .@"opaque", .gpu_color_space = .srgb, .gpu_vsync = true },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "Native Zig Showcase",
    .width = window_width,
    .height = window_height,
    .views = &shell_views,
}};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Msg = union(enum) {
    /// Nav row payload: the row's `id` field rides the message.
    set_section: usize,
    /// Fallback for the header's Continue button (path-only payloads).
    next_section,
    /// Split divider drag/keyboard: echo the applied fraction back.
    sidebar_resized: f32,

    // ---- controls section
    /// Text entry: on-input carries a canvas.TextInputEvent per field.
    draft_edit: canvas.TextInputEvent,
    note_edit: canvas.TextInputEvent,
    search_edit: canvas.TextInputEvent,
    /// Enter in the task field or the Add button.
    submit_task,
    /// Checkbox / switch / toggle-button: flip a bool arm.
    toggle_done,
    toggle_autoplay,
    /// Radio group payload: the chosen density row's id.
    set_density: u8,
    /// Markup sliders dispatch a PLAIN change notification - the drag is
    /// engine-retained; volume_up/down move the model source.
    volume_changed,
    volume_up,
    volume_down,
    /// Select trigger + model-owned dropdown lifecycle.
    open_picker,
    close_picker,
    choose_fruit: u8,
    /// Segmented control payload: the mode row's id.
    set_view_mode: u8,
    /// Standalone toggle (not a button).
    toggle_pin,
    /// toggle-group chip payload: the align row's id.
    set_align: u8,
    /// Combobox: single-line edit events, model-owned dropdown, picks.
    combo_edit: canvas.TextInputEvent,
    combo_open,
    combo_close,
    combo_choose: u8,
    /// Composer: the input-group textarea plus its actions-row send.
    message_edit: canvas.TextInputEvent,
    send_message,
    /// Stepper navigation (0-based active index).
    stage_next,
    stage_prev,

    // ---- layout section
    /// Mini split inside the pane: echo the applied fraction.
    demo_split_resized: f32,
    /// Grid column-count segmented control payload.
    set_layout_columns: u8,
    /// Accordion disclosure.
    toggle_faq,
    /// Presentational buttons that only prove hit-testing / dispatch.
    noop,

    // ---- navigation & data section
    /// Tab strip payload: the tab row's id.
    set_data_tab: u8,
    /// Breadcrumb payload: the crumb's id.
    set_crumb: u8,
    page_prev,
    page_next,
    /// Table cell payload: the row's id.
    select_file: u8,
    /// List row payload: the row's id (also keyed identity).
    select_log: usize,
    /// Scroll mirror: the runtime-carried offset echo, stored and re-bound.
    log_scrolled: canvas.ScrollState,
    /// Infinite-fetch signal with engine-side hysteresis.
    log_reach_end,
    /// Tree row payload.
    select_node: u8,
    /// Tree disclosure payload: flips the matched folder.
    toggle_node: u8,

    // ---- overlays section
    open_dialog,
    close_dialog,
    /// Confirm in the dialog: counts a launch and closes.
    confirm_dialog,
    open_sheet,
    close_sheet,
    open_drawer,
    close_drawer,
    toggle_popover,
    close_popover,
    /// Context-menu item payload: the action row's id.
    menu_action: u8,

    // ---- rich content section
    set_channel: u8,
    /// Markdown link payload: the pressed URL.
    open_note_link: []const u8,
    /// Details-block payload: its index in document order.
    toggle_note_details: usize,
    select_step: u8,
    toggle_rich_loading,
    /// Advances the chart phase, regenerating both wave series.
    advance_chart,

    // ---- theming section
    set_theme_pack: u8,
    set_theme_scheme: u8,
    set_accent: u8,
    /// Cycles follows-OS -> on -> off.
    cycle_high_contrast,
    /// The preview spinner runs only while toggled: an always-on spinner
    /// repaints the live canvas at 60 fps, which pegs a CPU rasterizer.
    toggle_preview_spin,

    // ---- playground section
    pg_press,
    /// Press-and-hold on the same control (the release presses nothing).
    pg_hold,
    /// on-drag payload: the exact record markup requires - numeric
    /// sourceId/phase plus four f64 live-geometry fields.
    pad_dragged: DragPad,
    /// Track row payload for the click-select / double-click-play list.
    select_track: u8,
    play_track: u8,
    /// Hover containment edges on the demo tile.
    pg_hover_enter,
    pg_hover_leave,
};

pub const NavItem = struct {
    id: usize,
    title: []const u8,
};

const nav_table = [_]NavItem{
    .{ .id = 0, .title = "Overview" },
    .{ .id = 1, .title = "Controls" },
    .{ .id = 2, .title = "Layout" },
    .{ .id = 3, .title = "Navigation & Data" },
    .{ .id = 4, .title = "Overlays" },
    .{ .id = 5, .title = "Rich Content" },
    .{ .id = 6, .title = "Theming" },
    .{ .id = 7, .title = "Playground" },
};

/// A row identity used by the controls section's <for> lists.
pub const NamedId = struct {
    id: u8,
    label: []const u8,
};

const density_table = [_]NamedId{
    .{ .id = 0, .label = "Standard" },
    .{ .id = 1, .label = "Compact" },
    .{ .id = 2, .label = "Spacious" },
};

const fruit_table = [_]NamedId{
    .{ .id = 0, .label = "Apple" },
    .{ .id = 1, .label = "Banana" },
    .{ .id = 2, .label = "Cherry" },
};

const mode_table = [_]NamedId{
    .{ .id = 0, .label = "List" },
    .{ .id = 1, .label = "Grid" },
    .{ .id = 2, .label = "Settings" },
};

const column_table = [_]NamedId{
    .{ .id = 2, .label = "2" },
    .{ .id = 3, .label = "3" },
    .{ .id = 4, .label = "4" },
};

const align_table = [_]NamedId{
    .{ .id = 0, .label = "Left" },
    .{ .id = 1, .label = "Center" },
    .{ .id = 2, .label = "Right" },
};

const people_table = [_]NamedId{
    .{ .id = 0, .label = "Ada Lovelace" },
    .{ .id = 1, .label = "Grace Hopper" },
    .{ .id = 2, .label = "Alan Turing" },
    .{ .id = 3, .label = "Margaret Hamilton" },
};

const stage_count: usize = 3;
const page_total: usize = 12;

const data_tab_table = [_]NamedId{
    .{ .id = 0, .label = "Overview" },
    .{ .id = 1, .label = "Records" },
    .{ .id = 2, .label = "Log" },
};

const crumb_table = [_]NamedId{
    .{ .id = 0, .label = "Home" },
    .{ .id = 1, .label = "Projects" },
    .{ .id = 2, .label = "Showcase" },
};

/// A row identity for the data section's table.
pub const FileRow = struct {
    id: u8,
    name: []const u8,
    size: []const u8,
    kind: []const u8,
};

const file_table = [_]FileRow{
    .{ .id = 0, .name = "app.native", .size = "4.2 KB", .kind = "markup" },
    .{ .id = 1, .name = "main.zig", .size = "9.8 KB", .kind = "core" },
    .{ .id = 2, .name = "tests.zig", .size = "1.1 KB", .kind = "test" },
    .{ .id = 3, .name = "app.json", .size = "900 B", .kind = "manifest" },
    .{ .id = 4, .name = "icon.png", .size = "12 KB", .kind = "asset" },
};

/// One derived log row: the arena-taking iterable formats titles per build.
pub const LogRow = struct {
    id: usize,
    title: []const u8,
};

/// One visible tree row: parentage is model state, so collapsed children
/// simply are not returned (and not rendered).
pub const TreeRow = struct {
    id: u8,
    label: []const u8,
    indent: u8,
    expandable: bool,
    expanded: bool,
    icon: []const u8,
};

const TreeNodeDef = struct {
    id: u8,
    label: []const u8,
    parent: u8,
    expandable: bool,
};

const no_parent: u8 = 255;
const tree_table = [_]TreeNodeDef{
    .{ .id = 0, .label = "src", .parent = no_parent, .expandable = true },
    .{ .id = 1, .label = "app.native", .parent = 0, .expandable = false },
    .{ .id = 2, .label = "main.zig", .parent = 0, .expandable = false },
    .{ .id = 3, .label = "docs", .parent = no_parent, .expandable = true },
    .{ .id = 4, .label = "FEATURES.md", .parent = 3, .expandable = false },
};

/// One declared context-menu row: separators keep their slot, disabled
/// items present but do not dispatch.
pub const MenuAction = struct {
    id: u8,
    label: []const u8,
    separator: bool = false,
    disabled: bool = false,
};

const context_table = [_]MenuAction{
    .{ .id = 0, .label = "Rename" },
    .{ .id = 1, .label = "Duplicate" },
    .{ .id = 2, .label = "", .separator = true },
    .{ .id = 3, .label = "Delete", .disabled = true },
};

const channel_table = [_]NamedId{
    .{ .id = 0, .label = "stable" },
    .{ .id = 1, .label = "beta" },
};

/// One visible timeline row; selection is derived from `timeline_sel`,
/// so the static definition stays pure data.
pub const TimelineRow = struct {
    id: u8,
    title: []const u8,
    description: []const u8,
    meta: []const u8,
    tone: []const u8,
    connector: bool,
    sel: bool,
};

const TimelineDef = struct {
    id: u8,
    title: []const u8,
    description: []const u8,
    meta: []const u8,
    tone: []const u8,
    connector: bool,
};

const timeline_table = [_]TimelineDef{
    .{ .id = 0, .title = "Design sweep", .description = "Token coverage and contrast pass on both schemes.", .meta = "2d ago", .tone = "primary", .connector = true },
    .{ .id = 1, .title = "Layout sweep", .description = "Every breakpoint under the clean-scene audit.", .meta = "1d ago", .tone = "primary", .connector = true },
    .{ .id = 2, .title = "Accessibility sweep", .description = "Names, focus reach, and identically labeled siblings.", .meta = "4h ago", .tone = "secondary", .connector = true },
    .{ .id = 3, .title = "Release notes", .description = "Drafted against the stable channel.", .meta = "now", .tone = "outline", .connector = false },
};

const cpu_points = [_]f32{ 0.12, 0.31, 0.22, 0.58, 0.44, 0.71, 0.38, 0.62, 0.55, 0.83, 0.47, 0.36, 0.67 };

const theme_pack_table = [_]NamedId{
    .{ .id = 0, .label = "house" },
    .{ .id = 1, .label = "geist" },
};

const theme_scheme_table = [_]NamedId{
    .{ .id = 0, .label = "system" },
    .{ .id = 1, .label = "light" },
    .{ .id = 2, .label = "dark" },
};

/// One accent choice: label plus the literal color the model hands the
/// runtime (null = no brand accent; high contrast suppresses it anyway).
pub const AccentChoice = struct {
    id: u8,
    label: []const u8,
    color: ?canvas.Color,
};

const accent_table = [_]AccentChoice{
    .{ .id = 0, .label = "default", .color = null },
    .{ .id = 1, .label = "violet", .color = canvas.Color.rgb8(124, 58, 237) },
    .{ .id = 2, .label = "emerald", .color = canvas.Color.rgb8(16, 185, 129) },
    .{ .id = 3, .label = "rose", .color = canvas.Color.rgb8(225, 29, 72) },
};

/// One track row in the playground's double-click list; selection and
/// playing state derive from the model ids.
pub const TrackRow = struct {
    id: u8,
    name: []const u8,
    sel: bool,
    state: []const u8,
    tone: []const u8,
};

const TrackDef = struct {
    id: u8,
    name: []const u8,
};

const track_table = [_]TrackDef{
    .{ .id = 0, .name = "signal drift" },
    .{ .id = 1, .name = "night compile" },
    .{ .id = 2, .name = "arena alloc" },
};

/// The playground's on-drag record. Field names and widths are the
/// contract: markup fills sourceId from the binding, the runtime fills
/// phase and the f64 live geometry.
pub const DragPad = struct {
    sourceId: i64,
    phase: i64,
    x: f64,
    y: f64,
    viewWidth: f64,
    viewHeight: f64,
};

const snippet_text =
    \\pub const Model = struct {
    \\    /// Fields consumed via derived methods.
    \\    pub const view_unbound = .{ "task_draft" };
    \\
    \\    section: u8 = 0,
    \\    tasks: std.ArrayListUnmanaged(Task) = .empty,
    \\};
    \\
    \\pub fn update(model: *Model, msg: Msg) void {
    \\    switch (msg) {
    \\        .set_section => |id| model.section = id,
    \\        .noop => {},
    \\    }
    \\}
;

pub const Model = struct {
    /// TextBuffers are consumed through derived methods (`{draft}`), so
    /// the markup checker cannot see a field-level binding.
    pub const view_unbound = .{ "task_draft", "note_draft", "search_query", "selected_file", "tree_sel", "src_open", "docs_open", "menu_pick", "timeline_sel", "chart_phase", "link_buffer", "link_len", "high_contrast", "track_playing", "combo_query", "message_draft", "drag_x", "drag_view_width", "drag_phase", "track_sel" };

    // gallery chrome
    section_index: usize = 0,
    sidebar_split: f32 = 0.24,

    // controls section: each control's state is an ordinary field.
    task_draft: canvas.TextBuffer(64) = .{},
    note_draft: canvas.TextBuffer(128) = .{},
    search_query: canvas.TextBuffer(48) = .{},
    submitted: i64 = 0,
    search_hits: i64 = 0,
    done_checked: bool = false,
    density: u8 = 0,
    volume: f32 = 0.6,
    volume_changes: u64 = 0,
    autoplay: bool = false,
    picker_open: bool = false,
    fruit_id: u8 = 0,
    view_mode: u8 = 0,
    pin_summary: bool = false,
    text_align: u8 = 0,
    combo_query: canvas.TextBuffer(32) = .{},
    combo_open: bool = false,
    /// 255 = nothing picked yet; else a people_table id.
    combo_pick: u8 = 255,
    message_draft: canvas.TextBuffer(160) = .{},
    sent_count: u8 = 0,
    stage: usize = 0,

    // layout section
    demo_split: f32 = 0.45,
    layout_columns: u8 = 3,
    faq_open: bool = false,

    // navigation & data section
    data_tab: u8 = 0,
    crumb: u8 = 2,
    page: usize = 1,
    selected_file: u8 = 0,
    log_count: usize = 24,
    log_sel: usize = 0,
    log_scroll: f32 = 0,
    fetch_count: usize = 0,
    tree_sel: u8 = 0,
    src_open: bool = true,
    docs_open: bool = false,

    // overlays section
    dialog_open: bool = false,
    sheet_open: bool = false,
    drawer_open: bool = false,
    popover_open: bool = false,
    launches: u8 = 0,
    /// Context-menu result: 255 = nothing picked yet; else a MenuAction id.
    menu_pick: u8 = 255,

    // rich content section
    release_channel: u8 = 0,
    note_details: [8]bool = .{false} ** 8,
    /// The last pressed markdown link, COPIED out of the Msg payload -
    /// event payload slices are transient and must never be retained.
    link_buffer: [128]u8 = undefined,
    link_len: usize = 0,
    timeline_sel: u8 = 0,
    rich_loading: bool = false,
    chart_phase: u8 = 0,

    // theming section
    theme_pack: u8 = 0,
    theme_scheme: u8 = 0,
    accent_pick: u8 = 0,
    high_contrast: ?bool = null,
    /// Default off so no section idles at 60 fps repaints.
    preview_spin: bool = false,

    // playground section
    pg_press_count: i64 = 0,
    pg_hold_count: i64 = 0,
    /// The on-drag source binding: the pad's declared integer identity.
    drag_track_id: i64 = 1,
    /// Pointer x over view width from the last drag event (0..1).
    drag_pct: f32 = 0,
    drag_x: f64 = 0,
    drag_view_width: f64 = 0,
    /// Out of range until a drag arrives, so the readout starts "idle".
    drag_phase: i64 = 99,
    track_sel: u8 = 0,
    /// 255 = nothing playing yet; else a TrackRow id.
    track_playing: u8 = 255,
    pg_hovered: bool = false,

    // Bindings: a slice-returning public method drives <for>, a scalar
    // one drives text. Markup binds the FN (text="{draft}"), never the
    // TextBuffer itself - the buffer holds editor state, the binding
    // wants the text it derives.
    pub fn nav_items(_: *const Model) []const NavItem {
        return &nav_table;
    }

    pub fn section_title(model: *const Model) []const u8 {
        const idx = @min(model.section_index, nav_table.len - 1);
        return nav_table[idx].title;
    }

    pub fn densities(_: *const Model) []const NamedId {
        return &density_table;
    }

    pub fn fruits(_: *const Model) []const NamedId {
        return &fruit_table;
    }

    pub fn modes(_: *const Model) []const NamedId {
        return &mode_table;
    }

    pub fn column_choices(_: *const Model) []const NamedId {
        return &column_table;
    }

    pub fn draft(model: *const Model) []const u8 {
        return model.task_draft.text();
    }

    pub fn note(model: *const Model) []const u8 {
        return model.note_draft.text();
    }

    pub fn query(model: *const Model) []const u8 {
        return model.search_query.text();
    }

    pub fn fruit_name(model: *const Model) []const u8 {
        for (fruit_table) |f| if (f.id == model.fruit_id) return f.label;
        return "Pick one";
    }

    pub fn density_name(model: *const Model) []const u8 {
        return switch (model.density) {
            0 => "Standard",
            1 => "Compact",
            2 => "Spacious",
            else => "?",
        };
    }

    pub fn view_mode_name(model: *const Model) []const u8 {
        return switch (model.view_mode) {
            0 => "List",
            1 => "Grid",
            2 => "Settings",
            else => "?",
        };
    }

    pub fn aligns(_: *const Model) []const NamedId {
        return &align_table;
    }

    pub fn align_name(model: *const Model) []const u8 {
        for (align_table) |a| if (a.id == model.text_align) return a.label;
        return "?";
    }

    pub fn combo_text(model: *const Model) []const u8 {
        return model.combo_query.text();
    }

    fn person_matches(needle: []const u8, person: NamedId) bool {
        return needle.len == 0 or std.ascii.indexOfIgnoreCase(person.label, needle) != null;
    }

    /// The combobox's filtered options: the query lives in the model, so
    /// the dropdown is a pure function of it.
    pub fn combo_matches(model: *const Model, arena: std.mem.Allocator) []const NamedId {
        const needle = model.combo_query.text();
        if (needle.len == 0) return &people_table;
        const out = arena.alloc(NamedId, people_table.len) catch return &.{};
        var count: usize = 0;
        for (people_table) |p| {
            if (person_matches(needle, p)) {
                out[count] = p;
                count += 1;
            }
        }
        return out[0..count];
    }

    pub fn combo_count(model: *const Model) usize {
        const needle = model.combo_query.text();
        var count: usize = 0;
        for (people_table) |p| {
            if (person_matches(needle, p)) count += 1;
        }
        return count;
    }

    pub fn combo_name(model: *const Model) []const u8 {
        for (people_table) |p| if (p.id == model.combo_pick) return p.label;
        return "none";
    }

    pub fn message_text(model: *const Model) []const u8 {
        return model.message_draft.text();
    }

    // ---- navigation & data section

    pub fn data_tabs(_: *const Model) []const NamedId {
        return &data_tab_table;
    }

    pub fn crumbs(_: *const Model) []const NamedId {
        return &crumb_table;
    }

    pub fn file_rows(_: *const Model) []const FileRow {
        return &file_table;
    }

    pub fn page_count(_: *const Model) usize {
        return page_total;
    }

    pub fn data_tab_name(model: *const Model) []const u8 {
        for (data_tab_table) |t| if (t.id == model.data_tab) return t.label;
        return "?";
    }

    /// The visible ancestor path is derived, never stored.
    pub fn crumb_path(model: *const Model) []const u8 {
        return switch (@min(model.crumb, crumb_table.len - 1)) {
            0 => "Home",
            1 => "Home / Projects",
            else => "Home / Projects / Showcase",
        };
    }

    pub fn file_name(model: *const Model) []const u8 {
        for (file_table) |f| if (f.id == model.selected_file) return f.name;
        return "?";
    }

    /// The log window is model state (`log_count`); titles are formatted
    /// into the build arena per rebuild - derived, never stored.
    pub fn logs(model: *const Model, arena: std.mem.Allocator) []const LogRow {
        const out = arena.alloc(LogRow, model.log_count) catch return &.{};
        for (out, 0..) |*row, i| {
            const kind = switch (i % 3) {
                0 => "sync ok",
                1 => "batch fetched",
                else => "cached",
            };
            row.* = .{
                .id = i,
                .title = std.fmt.allocPrint(arena, "log {d:0>3} · {s}", .{ i + 1, kind }) catch "",
            };
        }
        return out;
    }

    /// Visible rows: an expandable row's children appear only while it is
    /// open, so the disclosure tree renders exactly what the model says.
    pub fn tree_rows(model: *const Model, arena: std.mem.Allocator) []const TreeRow {
        const out = arena.alloc(TreeRow, tree_table.len) catch return &.{};
        var count: usize = 0;
        for (tree_table) |n| {
            if (n.parent != no_parent and !model.node_open(n.parent)) continue;
            const open = model.node_open(n.id);
            out[count] = .{
                .id = n.id,
                .label = n.label,
                .indent = if (n.parent == no_parent) 0 else 24,
                .expandable = n.expandable,
                .expanded = open,
                .icon = if (n.expandable) (if (open) "folder-open" else "folder") else "file-text",
            };
            count += 1;
        }
        return out[0..count];
    }

    fn node_open(model: *const Model, id: u8) bool {
        return switch (id) {
            0 => model.src_open,
            3 => model.docs_open,
            else => false,
        };
    }

    pub fn tree_node_label(model: *const Model) []const u8 {
        for (tree_table) |n| if (n.id == model.tree_sel) return n.label;
        return "?";
    }

    // ---- overlays section

    pub fn context_actions(_: *const Model) []const MenuAction {
        return &context_table;
    }

    pub fn menu_pick_name(model: *const Model) []const u8 {
        for (context_table) |a| if (!a.separator and a.id == model.menu_pick) return a.label;
        return "none";
    }

    // ---- rich content section

    pub fn channels(_: *const Model) []const NamedId {
        return &channel_table;
    }

    pub fn channel_name(model: *const Model) []const u8 {
        for (channel_table) |c| if (c.id == model.release_channel) return c.label;
        return "?";
    }

    pub fn timeline_rows(model: *const Model, arena: std.mem.Allocator) []const TimelineRow {
        const out = arena.alloc(TimelineRow, timeline_table.len) catch return &.{};
        for (out, timeline_table) |*row, def| {
            row.* = .{
                .id = def.id,
                .title = def.title,
                .description = def.description,
                .meta = def.meta,
                .tone = def.tone,
                .connector = def.connector,
                .sel = def.id == model.timeline_sel,
            };
        }
        return out;
    }

    pub fn step_name(model: *const Model) []const u8 {
        for (timeline_table) |t| if (t.id == model.timeline_sel) return t.title;
        return "?";
    }

    /// Two wave series offset by the model-owned phase: pressing
    /// "Advance data" changes value equality, so the chart repaints.
    pub fn chart_wave(model: *const Model, arena: std.mem.Allocator) []const f32 {
        return wave(model.chart_phase, 0, arena);
    }

    pub fn chart_echo(model: *const Model, arena: std.mem.Allocator) []const f32 {
        return wave(model.chart_phase, 1.4, arena);
    }

    fn wave(phase: u8, offset: f32, arena: std.mem.Allocator) []const f32 {
        const out = arena.alloc(f32, 24) catch return &.{};
        const phase_f: f32 = @floatFromInt(phase);
        for (out, 0..) |*v, i| {
            const x: f32 = @floatFromInt(i);
            v.* = 0.5 + 0.42 * @sin(x * 0.45 + phase_f * 0.35 + offset);
        }
        return out;
    }

    pub fn cpu_trace(_: *const Model) []const f32 {
        return &cpu_points;
    }

    pub fn zig_snippet(_: *const Model) []const u8 {
        return snippet_text;
    }

    /// The retained link URL. The event payload is copied into the
    /// model buffer by update(), so this slice owns its bytes.
    pub fn last_link(model: *const Model) []const u8 {
        if (model.link_len == 0) return "-";
        return model.link_buffer[0..model.link_len];
    }

    /// The whole markdown document is composed into the build arena;
    /// the channel toggle changes both the heading and the prose.
    pub fn release_brief(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena,
            \\## Build report - {s} channel
            \\
            \\**{s}** passed the sweep on the *{s}* channel. The markdown host lowered this whole document - headings, emphasis, task lists, a fence, a details block - into ordinary widgets.
            \\
            \\- [x] layout sweep clean
            \\- [x] a11y sweep clean
            \\- [ ] release notes drafted
            \\
            \\> Markdown is a leaf: one binding in, widgets out.
            \\
            \\```zig
            \\pub fn update(model: *Model, msg: Msg) void {{
            \\    switch (msg) {{
            \\        .set_section => |id| model.section = id,
            \\        .noop => {{}},
            \\    }}
            \\}}
            \\```
            \\
            \\<details><summary>How is this rendered?</summary>Every block lowers through ui primitives - no hidden engine feature, no web view.</details>
            \\
            \\Links dispatch on-link, e.g. [the toolkit docs](https://native-sdk.dev) or ref #12.
        , .{ channel_name(model), model.file_name(), channel_name(model) }) catch "";
    }

    // ---- theming section

    pub fn theme_packs(_: *const Model) []const NamedId {
        return &theme_pack_table;
    }

    pub fn theme_schemes(_: *const Model) []const NamedId {
        return &theme_scheme_table;
    }

    pub fn accent_choices(_: *const Model) []const AccentChoice {
        return &accent_table;
    }

    pub fn pack_name(model: *const Model) []const u8 {
        for (theme_pack_table) |p| if (p.id == model.theme_pack) return p.label;
        return "?";
    }

    pub fn scheme_name(model: *const Model) []const u8 {
        for (theme_scheme_table) |s| if (s.id == model.theme_scheme) return s.label;
        return "?";
    }

    pub fn accent_name(model: *const Model) []const u8 {
        for (accent_table) |a| if (a.id == model.accent_pick) return a.label;
        return "?";
    }

    pub fn hc_active(model: *const Model) bool {
        return model.high_contrast orelse false;
    }

    pub fn hc_name(model: *const Model) []const u8 {
        return if (model.high_contrast) |on| (if (on) "on" else "off") else "OS";
    }

    // ---- playground section

    pub fn tracks(model: *const Model, arena: std.mem.Allocator) []const TrackRow {
        const out = arena.alloc(TrackRow, track_table.len) catch return &.{};
        for (out, track_table) |*row, def| {
            const playing = def.id == model.track_playing;
            const sel = def.id == model.track_sel;
            row.* = .{
                .id = def.id,
                .name = def.name,
                .sel = sel,
                .state = if (playing) "playing" else if (sel) "selected" else "idle",
                .tone = if (playing) "primary" else if (sel) "secondary" else "outline",
            };
        }
        return out;
    }

    pub fn pad_status(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "x = {d:.0} of {d:.0} · {d:.0}% · source {d}", .{
            model.drag_x,
            model.drag_view_width,
            model.drag_pct * 100,
            model.drag_track_id,
        }) catch "";
    }

    pub fn drag_phase_name(model: *const Model) []const u8 {
        return switch (model.drag_phase) {
            0 => "change",
            1 => "end",
            2 => "cancel",
            else => "idle",
        };
    }
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        // gallery chrome
        .set_section => |idx| model.section_index = @min(idx, nav_table.len - 1),
        .next_section => model.section_index = @min(model.section_index + 1, nav_table.len - 1),
        .sidebar_resized => |fraction| model.sidebar_split = fraction,

        // controls: text entry applies the runtime's edit event to the
        // model-owned buffer; nothing edits text outside update().
        .draft_edit => |event| model.task_draft.apply(event),
        .note_edit => |event| model.note_draft.apply(event),
        .search_edit => |event| {
            model.search_query.apply(event);
            model.search_hits = @intCast(model.search_query.text().len);
        },
        .submit_task => {
            model.submitted += 1;
            model.task_draft.clear();
        },
        .toggle_done => model.done_checked = !model.done_checked,
        .toggle_autoplay => model.autoplay = !model.autoplay,
        .set_density => |id| model.density = id,
        .volume_changed => model.volume_changes += 1,
        .volume_up => model.volume = @min(1.0, model.volume + 0.1),
        .volume_down => model.volume = @max(0.0, model.volume - 0.1),
        .open_picker => model.picker_open = true,
        .close_picker => model.picker_open = false,
        .choose_fruit => |id| {
            model.fruit_id = id;
            model.picker_open = false;
        },
        .set_view_mode => |id| model.view_mode = id,
        .toggle_pin => model.pin_summary = !model.pin_summary,
        .set_align => |id| model.text_align = id,
        .combo_edit => |event| model.combo_query.apply(event),
        .combo_open => model.combo_open = true,
        .combo_close => model.combo_open = false,
        .combo_choose => |id| {
            model.combo_pick = id;
            model.combo_open = false;
            model.combo_query.clear();
        },
        .message_edit => |event| model.message_draft.apply(event),
        .send_message => {
            model.sent_count +%= 1;
            model.message_draft.clear();
        },
        .stage_next => model.stage = @min(stage_count - 1, model.stage + 1),
        .stage_prev => model.stage = @max(1, model.stage) - 1,

        // layout
        .demo_split_resized => |fraction| model.demo_split = fraction,
        .set_layout_columns => |count| model.layout_columns = count,
        .toggle_faq => model.faq_open = !model.faq_open,
        .noop => {},

        // navigation & data
        .set_data_tab => |id| model.data_tab = id,
        .set_crumb => |id| model.crumb = id,
        .page_prev => model.page = if (model.page > 1) model.page - 1 else 1,
        .page_next => model.page = @min(model.page + 1, page_total),
        .select_file => |id| model.selected_file = id,
        .select_log => |id| model.log_sel = id,
        .log_scrolled => |state| model.log_scroll = state.offset_y,
        .log_reach_end => {
            model.fetch_count += 1;
            model.log_count = @min(model.log_count + 12, 240);
        },
        .select_node => |id| model.tree_sel = id,
        .toggle_node => |id| switch (id) {
            0 => model.src_open = !model.src_open,
            3 => model.docs_open = !model.docs_open,
            else => {},
        },

        // overlays
        .open_dialog => model.dialog_open = true,
        .close_dialog => model.dialog_open = false,
        .confirm_dialog => {
            model.dialog_open = false;
            model.launches += 1;
        },
        .open_sheet => model.sheet_open = true,
        .close_sheet => model.sheet_open = false,
        .open_drawer => model.drawer_open = true,
        .close_drawer => model.drawer_open = false,
        .toggle_popover => model.popover_open = !model.popover_open,
        .close_popover => model.popover_open = false,
        .menu_action => |id| model.menu_pick = id,

        // rich content
        .set_channel => |id| model.release_channel = id,
        .open_note_link => |url| {
            const n = @min(url.len, model.link_buffer.len);
            @memcpy(model.link_buffer[0..n], url[0..n]);
            model.link_len = n;
        },
        .toggle_note_details => |index| if (index < model.note_details.len) {
            model.note_details[index] = !model.note_details[index];
        },
        .select_step => |id| model.timeline_sel = id,
        .toggle_rich_loading => model.rich_loading = !model.rich_loading,
        .advance_chart => model.chart_phase +%= 1,

        // theming
        .set_theme_pack => |id| model.theme_pack = id,
        .set_theme_scheme => |id| model.theme_scheme = id,
        .set_accent => |id| model.accent_pick = id,
        .cycle_high_contrast => model.high_contrast = if (model.high_contrast == null) true else if (model.high_contrast.? == true) false else null,
        .toggle_preview_spin => model.preview_spin = !model.preview_spin,

        // playground
        .pg_press => model.pg_press_count += 1,
        .pg_hold => model.pg_hold_count += 1,
        // x is view geometry, so the fraction is x / viewWidth - clamped
        // because a drag may legitimately report out-of-view points.
        .pad_dragged => |drag| {
            model.drag_phase = drag.phase;
            model.drag_x = drag.x;
            model.drag_view_width = drag.viewWidth;
            const pct: f64 = if (drag.viewWidth > 0) drag.x / drag.viewWidth else 0;
            model.drag_pct = @floatCast(@max(0, @min(pct, 1)));
        },
        .select_track => |id| model.track_sel = id,
        .play_track => |id| {
            model.track_sel = id;
            model.track_playing = id;
        },
        .pg_hover_enter => model.pg_hovered = true,
        .pg_hover_leave => model.pg_hovered = false,
    }
}

// ------------------------------------------------------------------- view

const app_sources = @import("app_sources.zig");

pub const AppUi = canvas.Ui(Msg);
pub const app_markup = @embedFile("app.native");

// -------------------------------------------------------------------- app

const GalleryApp = native_sdk.UiApp(Model, Msg);

pub fn initialModel() Model {
    return .{};
}

/// The runtime asks the model for its theme on every rebuild; every
/// token reference in the view re-resolves against what this returns.
fn themeState(model: *const Model) GalleryApp.ThemeState {
    return .{
        .pack = switch (model.theme_pack) {
            0 => .house,
            else => .geist,
        },
        .color_scheme = switch (model.theme_scheme) {
            1 => .light,
            2 => .dark,
            else => .system,
        },
        .accent = accentColor(model),
        .high_contrast = model.high_contrast,
    };
}

fn accentColor(model: *const Model) ?canvas.Color {
    for (accent_table) |a| if (a.id == model.accent_pick) return a.color;
    return null;
}

pub fn main(init: std.process.Init) !void {
    const app_state = try GalleryApp.create(std.heap.page_allocator, .{
        .name = "gallery",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .theme_state_fn = themeState,
        .markup = .{ .source = app_markup, .sources = &app_sources.sources, .watch_path = "src/app.native", .io = init.io },
    });
    defer app_state.destroy();
    app_state.model = initialModel();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "gallery",
        .window_title = "Native Zig Showcase",
        .bundle_id = "dev.native_sdk.gallery",
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
