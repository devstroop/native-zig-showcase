# Feature coverage

Which SDK surface is demonstrated where. Every app is a Zig core
(`Model` / `Msg` / `update`) plus `.native` markup; the focused demos
show the deeper runtime features, and the gallery is the exhaustive
element reference.

## App model

| Feature | Demonstrated in |
|---|---|
| `Model` / `Msg` / `update` loop with a typed Msg union | every app (`src/main.zig`) |
| Derived bindings — model functions the view calls per rebuild (counts, sums, formatted strings) | `counter` (`total`), `charts` (stat tiles), `gallery` (`section_title`, log rows) |
| Arena-derived methods returning slices (`fn (model, arena) []const …`) | `charts` (`request_series`), `gallery`, `effects` |
| Windowed virtual-list rows query — `fn (model, range, arena) []const Row` returning exactly the visible slice | `stream` |
| Boot-time effects through `Options.on_lifecycle` (`.start` → Msg before the first frame) | `images` |
| `view_unbound` — the lint opt-out for state markup sees only through derived methods | all apps |
| No view state: the board rebuilds from the model on every drop | `kanban` |
| Replayable model math — one sample is a pure function of model fields | `charts` |
| Journaled wall clock (`fx.wallMs`) | `counter` |

## Effects channel

| Feature | Demonstrated in |
|---|---|
| Repeating timer (`fx.startTimer` / `fx.cancelTimer`, `.on_fire = Effects.timerMsg(…)`) | `counter`, `charts` |
| Subprocess spawn, streaming stdout line by line, collected stdout + stderr tail | `effects` |
| HTTP fetch: reachable host, unreachable host, cancel | `effects` |
| File persistence under the app's data directory | `effects` |
| System clipboard | `effects` |
| Fire-and-forget notification | `effects` |
| Image registry: `registerImage` (raw RGBA atlas), `registerImageBytes` (platform decode), `unregisterImage` | `images` |
| Fake executor in tests — operations recorded, results fed back as plain Msgs | `counter`, `effects`, `charts`, `desktop` |

## View tier (Native markup)

| Feature | Demonstrated in |
|---|---|
| Element breadth: layout, controls, data views, overlays, rich content, theming, gestures | `gallery` — eight sections, self-documenting markup |
| Charts: `line` / `area` / `bar` series, sparkline, `y-min`/`y-max`, `grid-lines`, `y-labels`, `baseline`, `x-labels` | `charts`, `gallery` |
| Drag and drop: the `on-drag` release record (authored identity + live geometry) maps a drop point to a column | `kanban` |
| `<for>` / `<if>` / `<else>`, `<template>` + `<use>` composition, `<import>` | `gallery`, `charts`, `kanban` |
| Structure tags: `status-bar`, `spacer`, `separator`, `scroll` | every app |
| Markdown and inline code | `gallery` (rich content) |
| Theming and style tokens | `gallery` (theming section) |
| Text input: `text-field` / `textarea` / `search-field` with `on-input` on a model `TextBuffer` | `effects`, `gallery` (controls section) |
| Windowed virtual lists: `<virtual-window>` + `<virtual-list>` (uniform extent, overscan, `on-reach-end` infinite fetch, live `range.*` bindings) | `stream` |
| Images: `<image>` / `<avatar>` bound to model-owned registry ids, with the `0` sentinel fallback | `images` |

## Desktop integration

| Feature | Demonstrated in |
|---|---|
| Model-declared secondary windows: `windows_fn` (presence is liveness) + `window_view` | `desktop` |
| Per-window markup trees (`CompiledMarkupView`) addressed by canvas label | `desktop` |
| Window verbs: `minimizeWindow`, `hideWindow`, `showWindow`, `quitApp` through `fx` | `desktop` |
| `close_policy` `.quit` and `.hide` (with the Linux/GTK fallback gate) | `desktop` |
| User close as an ordinary Msg: each descriptor's `on_close` | `desktop` |
| One shared model across main + secondary windows | `desktop` |
| `restore_policy = .center_on_primary`, `min_width` / `min_height` floors | `desktop` |
| Hidden titlebar (`titlebar = .hidden_inset`), the `window-drag` header region, and the `on_chrome` overlay-geometry channel | `desktop` |

## Verification

| Feature | Demonstrated in |
|---|---|
| Headless update-logic tests (`native test`, `src/tests.zig`) | every app |
| Markup + manifest validation (`native check`) | every app |
| Deterministic data assertions against a fake timer | `charts`, `counter` |
| Window liveness, verb mirror (`windowActionState`), tree bindings | `desktop` |
| Image registry double via `bindImages` (recorded register/unregister calls, failure fallback) | `images` |
| Live verification: snapshots, widget clicks, screenshots (`native automate`) | all apps were verified live; see `docs/sdk/automation/` |
