# Effects

The effects-channel tour: subprocesses streaming line by line, collected
stdout with the stderr tail, HTTP fetches (good host, unreachable host,
cancel), a note persisted under the app's own data directory, the system
clipboard, and a fire-and-forget notification. `update` stays a plain
function of model + message; every capability leaves through `fx` and
comes back as an ordinary `Msg`.

```sh
native dev     # build and run with markup hot reload
native test    # headless update-logic tests (src/tests.zig)
native check   # validate markup + manifest
```

The tests drive the channel's fake executor: spawns, fetches, file ops,
and clipboard ops are recorded for assertions and results are fed back as
plain Msgs, so the update logic is exercised without touching the OS.

See the root `README.md` for the full lineup.
