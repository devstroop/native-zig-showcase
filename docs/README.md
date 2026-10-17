# Docs

Vendored Native SDK reference documentation, checked in so the showcase
is readable without the SDK installed. Everything under `sdk/` is a
verbatim copy of the SDK's own agent-facing guides.

| Copy | Source | What it covers |
|---|---|---|
| `sdk/core/` | `native skills get core` (+ `references/`) | Project anatomy, app model and runtime, native capabilities, permissions, windows, packaging |
| `sdk/native-ui/` | `native skills get native-ui` | The full Native markup (`.native`) authoring guide: elements, attributes, expressions, bindings, messages, testing |
| `sdk/zig/` | `native skills get zig` | Zig 0.16 idioms as this SDK writes them, indexed by compile error |
| `sdk/automation/` | `native skills get automation` | Driving a running app through `native automate`: snapshots, widget interaction, screenshots |

Provenance: Native SDK CLI `native 0.11.0`, `skill-data/` directory of
the `@native-sdk/cli` package. Licensed Apache-2.0 (see `sdk/LICENSE`).

Refresh after an SDK upgrade — re-copy the same trees from the installed
package (`$(npm root -g)/@native-sdk/cli/skill-data/`) or diff against
`native skills get <name>` output.
