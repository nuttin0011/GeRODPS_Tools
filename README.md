# GeRODPS Tools

Sister addon to **GeRODPS** — bundles development & inspection tools that
shouldn't pollute the main GeRODPS load order.

Declared via `## Dependencies: GeRODPS` in the TOC, so this addon will
only load when GeRODPS is enabled. Reuses `LibDataBroker-1.1` and
`LibDBIcon-1.0` already bundled by GeRODPS for its minimap button.

## Tools

| Tool                       | Status                          |
|----------------------------|---------------------------------|
| Dump Var (Secret Read)     | Phase 1 — empty WoW-native frame chrome only |
| Watch Var (Realtime ×4)    | Live — 4 expression watchers with smart resize |

### Watch Var

4 input boxes accept a Lua expression each (`return ` is prepended
automatically). The result re-evaluates every 0.1 s and renders into a
multi-line output below. Output box heights redistribute on every tick:
boxes whose content fits in 6 lines stay compact; boxes with longer
content get extra lines proportional to need.

Secret values are surfaced via `<secret>` .. `tostring(v)` — string
concatenation routes through `tostring`, which WoW's secret guard
allows (only comparison / arithmetic on the underlying value are
blocked).

Expressions persist per-character in `GeRODPS_ToolsDB.watchVar.exprs`.

## Minimap button

Appears as **GeRODPS Tools**.

| Click       | Action |
|-------------|--------|
| Left-click  | Toggle Dump Var frame |

## SavedVariables

`GeRODPS_ToolsDB` (account-wide):

```
GeRODPS_ToolsDB = {
    minimap  = { hide = false, ... },              -- LibDBIcon state
    dumpVar  = { point, relPoint, x, y, w, h },    -- frame geometry
    watchVar = {
        point, relPoint, x, y, w, h,               -- frame geometry
        exprs = { [1..4] = "<lua expr>" },         -- persisted inputs
    },
}
```

## Development

Drop the folder into `World of Warcraft/_retail_/Interface/AddOns/`
alongside `GeRODPS/`. `/reload` after edits.
