# Charts

A live metrics dashboard: one effects-channel timer appends a sample to
two rings every 200ms, and every chart on the screen is a pure binding
over that state.

| Chart | Series | Reading of the ring |
|---|---|---|
| Requests and error spikes | `line` + `area` | the two rings as-is |
| Load histogram | `bar` | request samples bucketed over 0..100, with `x-labels` |
| Requests sparkline | `line` | the same request window at small size |

Four stat tiles (`current`, `peak`, `mean`, `window`) are derived
readouts of the same data — the point is that no chart owns state: kill
the timer and the dashboard still stands, restart it and the next frame
redraws.

## The data flow

- `Model` holds two fixed rings (`requests`, `errors`), a write head,
  and a live window length. Both are `view_unbound` storage: markup sees
  them only through derived methods.
- One sample is a deterministic function of two model fields — a sine
  carrying the trend, an LCG carrying the jitter — so tick N always
  yields the same point. Tests assert the replayable curve.
- `Live` starts a repeating timer (`.on_fire = Effects.timerMsg(.tick)`)
  and cancels it on toggle-off; `Regenerate` refills the whole ring with
  one LCG walk, no timer involved.

## Try it

```sh
native test    # the replayable data math, with a fake executor
native check   # the typed model contract behind every binding
native dev     # walk it
```

Toggle **Live** and watch the line advance; press **Regenerate** while
paused to redraw a deterministic window.

## Markup notes

Series `values` bind model iterables of `f32` (a `[]const f32` derived
method here); `x-labels` binds an iterable of strings, one per histogram
bucket. `chart` options used: `y-min`, `y-max`, `grid-lines`, `y-labels`,
`baseline`, `label`. Series `kind`s are the closed vocabulary
`line` / `area` / `bar`.
