# Images

The **image registry** end to end, entirely from `update` — no asset
pipeline, no view-layer file loading:

| Path | Call | What it demonstrates |
|---|---|---|
| Bundled PNG | `fx.registerImageBytes` | The platform codec decodes `src/bundled_badge.png` (embedded at compile time) and registers the pixels under `icon_image_id` in one synchronous call. |
| Generated atlas | `fx.registerImage` | A raw straight-alpha RGBA8 buffer the app generates itself (128×128 plaid gradient whose phase rotates per generation). |
| Retirement | `fx.unregisterImage` | The old generation's id is dropped; widgets bound to it fall back immediately. |

`0` is the **no-image sentinel**. Every id lands in the model only
after a successful registration, so the fallbacks double as the
loading/error story:

- the avatar keeps its **initials** while `icon_id` is 0,
- the atlas pane keeps its **empty-state card** while `atlas_id` is 0
  (flip the registry double into failure mode in the tests and that is
  exactly what you get),
- the status bar reports `atlas #<id> - generation <n>`.

## Boot

Registration happens in **`Options.on_lifecycle`**: the runtime maps
`.start` to a `.boot` Msg before the first frame. That hook is the only
place app code runs before the canvas draws, so boot-time effects live
there.

```zig
fn onLifecycle(event: native_sdk.LifecycleEvent) ?Msg {
    return switch (event) {
        .start => .boot,
        else => null,
    };
}
```

## View side

`<image image="{id}">` and `<avatar image="{id}">initials</avatar>`
bind model-owned ids (the avatar always fits `cover` over its circle;
the image leaf stretches into its frame — Zig markup has no `fit`
attribute yet, that is a compiled-view feature).
`Regenerate` swaps in a **fresh id** (`base + generation`) so the view
diff cannot miss the change; `Clear` unregisters and the pane falls
back to the empty-state card.

## Try it

```sh
native test    # registry lifecycle, failure fallback, pixel determinism
native check   # the typed model contract behind every binding
native dev     # press Regenerate and Clear
```
