# GeRODPS Tools

> Personal-use World of Warcraft 12.0 addon for poking at the API at
> runtime. This repository is **public for convenience** — fork it,
> modify it, ship it, do whatever. No warranty, no support promised.

---

## ⚠️ About this project

* **Personal use.** I built it for myself; it's not a polished product.
  If something breaks, I'll fix it on my own schedule.
* **AI-assisted code.** Most of the code, comments, and this README
  were drafted with an AI coding assistant. I read every diff before
  committing but the prose style and a lot of micro-decisions reflect
  the tool, not me.
* **Fork freely.** No CLA, no contributor list, no licence headers.
  If you find any of this useful, fork the repo, rename the addon,
  and ship your own version. PRs/issues are welcome but I won't
  promise to act on them.

---

## What it does

A standalone addon that adds a minimap launcher with three runtime
inspection tools. All UI is native WoW frames (no AceGUI), so it
gracefully accepts WoW 12.0 secret-tagged values into FontString
output (see `SECRETS.md` for the full ruleset learned the hard way).

| Tool | Status | What it shows |
|---|---|---|
| **Dump Var (Secret Read)** | Phase 1 — empty chrome | Placeholder frame; tree + watch inspector planned |
| **Watch Var (Realtime ×4)** | Live | 4 input boxes, each evaluates `return ...` every 100 ms and prints the result. Long output gets clipped — resize the frame larger to see more |
| **Aura List Helper** | Live | Lists every aura on a unit token (`target`, `focus`, `partyN`, `nameplateN`, ...), with a checkbox grid in three tabs (Display / Native Fields / Custom Fields) for picking which AuraData fields to surface |

Geometry is persisted per-account; opening any tool re-snaps the
frame to fit within a 100 px screen-edge margin so saved positions
never push the frame off-screen.

---

## Standalone vs paired with GeRODPS

The TOC lists `## OptionalDeps: GeRODPS`. The addon runs fine without
it; with GeRODPS loaded, the **Aura List Helper** also surfaces a few
synthetic fields that delegate to its `AuraCache` (filter probes,
dispel-type curve, raid-frame dispellable flags). Without GeRODPS
those fields read `(AuraCache unavailable)`; native AuraData fields
work either way.

Bundled libraries (under `Libs/`):

* `LibStub`
* `CallbackHandler-1.0`
* `LibDataBroker-1.1`
* `LibDBIcon-1.0`

LibStub deduplicates across loaded addons, so if another addon already
brought a newer copy, that one wins.

---

## Install

```text
World of Warcraft/_retail_/Interface/AddOns/
└── GeRODPS_Tools/
    ├── GeRODPS_Tools.toc
    ├── Core.lua
    ├── DumpVar.lua
    ├── WatchVar.lua
    ├── AuraListHelper.lua
    ├── SECRETS.md
    └── Libs/
        ├── LibStub/
        ├── CallbackHandler-1.0/
        ├── LibDataBroker-1.1/
        └── LibDBIcon-1.0/
```

`/reload` after editing any Lua file.

---

## SavedVariables shape

```
GeRODPS_ToolsDB = {
    minimap         = { hide = false, ... },               -- LibDBIcon state
    dumpVar         = { point, relPoint, x, y, w, h },     -- frame geometry
    watchVar        = {
        point, relPoint, x, y, w, h,                       -- frame geometry
        exprs = { [1..4] = "<lua expr>" },                 -- persisted inputs
    },
    auraListHelper  = {
        point, relPoint, x, y, w, h,                       -- frame geometry
        unit, interval, fields = { [<field>] = bool },     -- panel state
    },
}
```

---

## Files in this repo

| File | What |
|---|---|
| `Core.lua` | Tool registry, minimap button via LibDBIcon, drop-down menu |
| `DumpVar.lua` | Empty WoW-native frame (Phase 1 chrome only) |
| `WatchVar.lua` | 4 realtime expression watchers |
| `AuraListHelper.lua` | Tabbed unit-aura inspector |
| `SECRETS.md` | LOGIC vs DISPLAY rules for handling 12.0 secret-tagged values |

---

## Licence-ish

No licence file, no claim. Copy, modify, ship — just don't expect
support. The code style is whatever the AI happened to emit on the
day plus a thin layer of human review. If you fork and find anything
useful, that's a bonus.
