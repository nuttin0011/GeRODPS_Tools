# GeRODPS Tools

Sister addon to **GeRODPS** — bundles development & inspection tools that
shouldn't pollute the main GeRODPS load order.

Declared via `## Dependencies: GeRODPS` in the TOC, so this addon will
only load when GeRODPS is enabled. Reuses `LibDataBroker-1.1` and
`LibDBIcon-1.0` already bundled by GeRODPS for its minimap button.

## Tools

| Tool      | Status                          |
|-----------|---------------------------------|
| Dump Var  | Phase 1 — empty WoW-native frame chrome only |

## Minimap button

Appears as **GeRODPS Tools**.

| Click       | Action |
|-------------|--------|
| Left-click  | Toggle Dump Var frame |

## SavedVariables

`GeRODPS_ToolsDB` (account-wide):

```
GeRODPS_ToolsDB = {
    minimap = { hide = false, ... },  -- LibDBIcon state
    dumpVar = { point, relPoint, x, y, w, h },  -- frame geometry
}
```

## Development

Drop the folder into `World of Warcraft/_retail_/Interface/AddOns/`
alongside `GeRODPS/`. `/reload` after edits.
