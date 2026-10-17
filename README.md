# native-zig-showcase

A complete, professionally maintained demonstration of the
[Native SDK](https://native-sdk.dev) native GUI toolkit **written in
Zig** — every element, layout rule, gesture, effect, and desktop
integration the SDK offers, spread across one flagship gallery app and a
set of focused demos.

No WebView, no npm, no JavaScript at runtime: each app is a Zig core
(`Model` / `Msg` / `update`) plus declarative `.native` markup, built
and run entirely by the `native` CLI.

## Apps

| App | What it demonstrates |
|---|---|
| `apps/counter` | The app-model loop: state, messages, effects (timer, clock) |
| `apps/effects` | The effects channel: subprocesses, HTTP, files, clipboard, notifications |
| `apps/kanban` | Drag and drop: the `on-drag` release record drives a reorderable board |
| `apps/charts` | Data visualization: line, area, bar, and sparkline series over a live effects-channel timer |
| `apps/gallery` | ★ The flagship — all ~50 elements, layout, theming, gestures, with self-documenting markup |

The showcase is growing: multi-window desktop integration is on the
roadmap.

## Getting started

Install the Native SDK CLI (`native`), then start with the gallery:

```sh
cd apps/gallery
native dev
```

## Commands (any app)

```sh
native dev     # Debug build + run, markup hot reload
native test    # headless update-logic tests
native check   # validate markup, bindings, and manifest
native build   # ReleaseFast binary in zig-out/bin/
```

Note: `native dev` runs a Debug build, which is fine for editing but
noticeably slower at painting than the ReleaseFast binary from
`native build` — use `native build` (or `native dev` only for markup
iteration) when testing how an app actually feels.

## Layout

```
native-zig-showcase/
├── README.md            # this file
└── apps/                # one Native SDK app per directory
```
