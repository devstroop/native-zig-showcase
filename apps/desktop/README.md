# Desktop

Multi-window desktop integration, all in the app-model loop: secondary
windows **are model state**. `windows_fn` returns the descriptors that
should exist right now — presence is liveness — and the runtime
reconciles the OS windows against that declaration after every
dispatch.

| Piece | Where |
|---|---|
| Declared window set | `windows()` in `src/main.zig` |
| Per-window trees | `window_view()` building `CompiledMarkupView`s (`src/inspector.native`, `src/scratchpad.native`) |
| Window verbs | `minimizeWindow` / `hideWindow` / `showWindow` / `quitApp` through `fx` |
| User close | each descriptor's `on_close` → one ordinary Msg (`inspector_closed`, `scratchpad_closed`) |

## The rules this app demonstrates

- **Opening is declaring.** `Open inspector` sets `inspector_open`; the
  reconcile creates the real window. `Close it` clears the flag; the
  reconcile closes it. No window handles anywhere in the model.
- **The user's close is a Msg.** Each descriptor carries `on_close`, so
  the titlebar X dispatches like any button and the model clears its own
  flag.
- **`close_policy = .hide`** (scratchpad, where the host supports it —
  macOS): the titlebar X hides the window *without* destroying it —
  same native identity, same views — and `showWindow("scratchpad")`
  brings it back. Linux/GTK deliberately refuses the policy rather than
  strand an unreachable window, so there the descriptor falls back to
  `.quit` + `on_close` (see `scratchpad_close_policy` in `src/main.zig`);
  the Hide/Show verbs work on both hosts.
- **One model, every window.** A ping from the inspector rebuilds the
  main canvas, the scratchpad, and the inspector from the same state.
- **Canvas labels are unique**: `main-canvas`, `inspector-canvas`,
  `scratchpad-canvas` — input and automation address each window's
  canvas by its label.

## Try it

```sh
native test    # window liveness, the verb mirror, and every tree binding
native check   # the typed model contract for all three markup files
native dev     # open, ping, minimize, hide, show
```

With automation, each declared window is its own canvas:

```sh
native automate widget-click main-canvas <open-inspector-id>
native automate snapshot                     # the inspector window appears
native automate widget-click inspector-canvas <ping-id>
native automate screenshot inspector-canvas
```

## Budget and policies

At most `UiApp.max_ui_windows` (4) windows can be declared; excess
warnings are logged and ignored. `restore_policy.center_on_primary`
centers the inspector on macOS; other hosts keep their native
placement. `min_width`/`min_height` are a floor the *window* enforces,
so the user's resize stops at an honest size instead of clipping.
