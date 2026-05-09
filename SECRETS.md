# WoW 12.0 Secret Values — survival guide

Notes accumulated from building Watch Var and porting other tools into
**GeRODPS Tools**. Whenever a tool inspects values returned from the
WoW API on 12.0 (Project Midnight), some of those values are flagged
as "secret" by Blizzard. Operating on a secret value the wrong way
raises an error and aborts the call.

This file is the canonical cheat-sheet. **Read it before touching any
display code in this addon.**

## Detection

```lua
local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end
```

`issecretvalue(v)` returns a regular Lua boolean (NOT secret), so
`== true` against it is safe. This is the only check that's allowed
on the value.

## Two separate rules: LOGIC vs DISPLAY

### LOGIC rule (strict)

The only operations the runtime permits on a secret value for
**control flow / decisions** are:

- `v == nil`
- `issecretvalue(v)`

NOT allowed: `==` against any other constant (true, false, "", 0, ...),
`<` `>` `~=`, arithmetic (`+`, `-`, `*`, `/`, `-v`), boolean coercion
(`if v then`, `not v`, `v and a or b`), `type(v)`, `pairs/ipairs`,
indexing (`v.field`, `v[k]`), length (`#v`).

### DISPLAY rule (permissive)

For **rendering text to a FontString**, you CAN do:

- `"any literal" .. tostring(v)` — surfaces "<tag>theValue"
- `string.format("%s", v)` — same, via tostring under the hood

The result is a regular Lua string, but the WoW runtime tags it as
**tainted** (carries the secret flag forward). `FontString:SetText`
accepts tainted strings cleanly — that's the whole point of the
permissive display path.

### Where DISPLAY breaks

Tainted strings DO raise inside:

- `table.concat({tainted, ...}, sep)` —
  *"invalid value (secret) at index N in table for 'concat'"*
- Any truthiness check on the tainted string (`if s then`,
  `s and a`, `s or b`)
- Comparison of the tainted string (`s == "literal"`)

So the formatter must NEVER feed a tainted string into `table.concat`.
Use a manual `..` loop instead — see `ConcatLines` below.

## Forbidden operations

| Op                      | Example                              | What happens                            |
|-------------------------|--------------------------------------|-----------------------------------------|
| Comparison              | `v == something`, `v < x`, `v ~= y`  | Raises secret-guard error               |
| Arithmetic              | `v + 1`, `v * 2`, `-v`               | Raises                                  |
| Boolean coercion        | `v and a or b`, `not v`, `if v then` | Raises (truthiness check on secret)     |
| `type(v)`               | `type(v) == "string"`                | `type` itself is blocked on secret      |
| `pairs(t)`, `ipairs(t)` | `for k, v in pairs(secretTbl)`       | Iteration on a secret table is blocked  |
| `t[key]`                | `secretTbl.field`, `secretTbl[1]`    | Indexing into a secret table is blocked |
| Length `#v`             | `#secretTbl`                         | Blocked                                 |
| `string.format("%d", v)`| (any non-`%s` specifier)             | Blocked (numeric coercion)              |

**Rule of thumb**: always go `IsSecret(v)` first → if true, format ONLY
via concat / tostring / `string.format("%s", ...)`. Never branch on
the value, never inspect it, never enter it.

## Display layer caveats

The string produced by `"<secret>" .. tostring(v)` is a regular Lua
string but **carries the secret taint forward**. Some sinks accept it,
others don't:

| Sink                              | Accepts tainted string? |
|-----------------------------------|-------------------------|
| `FontString:SetText(s)`           | YES                     |
| `print(s)`                        | YES (chat frame)        |
| `DEFAULT_CHAT_FRAME:AddMessage`   | YES                     |
| `EditBox:SetText(s)`              | **NO** — raises         |
| `MultiLineEditBox:SetText(s)`     | **NO** — raises         |
| `ScrollingMessageFrame:AddMessage`| Untested, assume NO     |

**Implication**: tools that need to surface secret values (Watch Var,
Aura List Helper) must use `FontString` for output, NOT `EditBox`.
The trade-off is losing drag-select / Ctrl+C copy.

## Measurement caveats

Reading content back from a widget that holds tainted text also fails:

| Call                           | Status                                  |
|--------------------------------|-----------------------------------------|
| `FontString:GetText()`         | **NO** — raises if text holds tainted   |
| `FontString:GetStringHeight()` | **NO** — same                           |
| `FontString:GetStringWidth()`  | **NO** — same                           |
| `EditBox:GetText()`            | YES (only because EditBox can't hold tainted text in the first place — SetText would have failed earlier) |

**Implication**: don't auto-size FontStrings based on their rendered
metrics when the text might be tainted. All sizes must be derived
from frame dimensions the user controls (resize handle).

## Required plumbing patterns

### `FormatSecret(v)`

```lua
local function FormatSecret(v)
    local ok, s = pcall(function() return "<secret>" .. tostring(v) end)
    if ok then return s end
    return "<secret>"
end
```

Surfaces the actual value as `"<secret>theValue"`. The result is
tainted but FontString accepts it. pcall-wrapped because tostring on
a few exotic secret variants may still raise.

### `SafeToString(v)`

```lua
local function SafeToString(v)
    if v == nil then return "" end
    if IsSecret(v) then return FormatSecret(v) end
    local ok, s = pcall(string.format, "%s", tostring(v))
    if ok then return s end
    return "<opaque>"
end
```

Gates `==nil` and `IsSecret` first; routes secret values through
`FormatSecret` (taint preserved); only then runs format/tostring on
the guaranteed-non-secret value.

### `ConcatLines(arr, sep)`

```lua
local function ConcatLines(arr, sep)
    sep = sep or ""
    local n = #arr
    if n == 0 then return "" end
    local out = arr[1]
    for i = 2, n do
        out = out .. sep .. arr[i]
    end
    return out
end
```

Drop-in replacement for `table.concat` when the array might contain
tainted strings produced by the formatter chain. Each `..` propagates
taint forward but never raises; the final string ends up tainted (or
not, if no element was) and feeds cleanly into `FontString:SetText`.

### Iteration guard

```lua
if IsSecret(tbl) then return FormatSecret(tbl) end
-- Now safe to use pairs / ipairs / # / direct indexing
```

ALWAYS guard before any iteration / indexing.

### Per-element guard inside iteration

```lua
for k, v in pairs(nonSecretTable) do
    if IsSecret(v) then
        write(FormatSecret(v))
    else
        -- safe to inspect v
        write(VarToText(v))
    end
end
```

A non-secret table may contain secret values per-key. Re-check inside
the loop.

## What MAY happen on inspection

Don't assume the addon will gracefully degrade if you violate these
rules. Symptoms observed in the wild:

- Error popup with stack trace, addon disabled until `/reload`
- Frame stops updating but no error fires (silent freeze)
- BugSack / BugGrabber spam (one entry per offending tick — can be
  hundreds per minute)

## Check-before-ship

Before merging any code that touches values produced by `pcall(fn)`
or `loadstring("return " .. userInput)`:

- [ ] LOGIC paths gate `v == nil` and `IsSecret(v)` BEFORE any other
    op on `v` (no `==true` / `==false` / `<` / `>` / `~=` / `if v then` /
    `and` / `or` until both checks have passed)
- [ ] DISPLAY paths route secret values through `FormatSecret(v)` —
    `..` and `tostring` are OK because they only produce a tainted
    string for FontString, never feed control flow
- [ ] Output goes to `FontString`, not `EditBox`
- [ ] No `GetText`, `GetStringHeight`, `GetStringWidth` on output
    that may hold tainted text
- [ ] No `table.concat` of a sequence that might contain tainted
    strings — use `ConcatLines` instead
- [ ] No `or ""` / `and X` short-circuits applied to a value that
    might be tainted — use explicit `if/else`
