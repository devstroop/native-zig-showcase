# Kanban

A four-column board where every card is a drag source. The `on-drag`
binding delivers one closed record on release - the card's authored
identity plus live view geometry (`phase`, `x`, `y`, `viewWidth`,
`viewHeight`) - and `update` maps the drop point to a column. The board
is rebuilt from the model on every drop: no drag state lives in the view.

```sh
native dev     # build and run with markup hot reload
native test    # headless update-logic tests (src/tests.zig)
native check   # validate markup + manifest
```

The tests feed `Tree.msgForDrag` records directly, so the drop mapping is
exercised exactly as the runtime produces it.

See the root `README.md` for the full lineup.
