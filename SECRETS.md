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

## Allowed operations on a secret value

**STRICT RULE (verified by repro):** the only operations the runtime
permits on a secret value are:

- `v == nil`
- `issecretvalue(v)`

That's it. Everything else is forbidden.

### Why not `..` / `tostring` / `string.format`?

In isolation they don't raise — but they silently **propagate the
taint into the resulting string**. The tainted string then breaks any
downstream code that does:

- `table.concat({tainted, ...}, sep)` — *"invalid value (secret) at
  index N in table for 'concat'"*
- Any truthiness check against the tainted string (`if s then`,
  `s and ...`, `s or fallback`)
- Re-feeding it through another `..` chain that also goes into
  `table.concat` later

Tainted strings ARE accepted by `FontString:SetText`, so a single
display path can survive — but the moment your formatter joins lines
into a multi-line output, the chain breaks.

**Don't even try.** When you detect a secret value, emit a non-tainted
literal `"<secret>"` and move on. No information about the value
content is recoverable safely.

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

### `FormatSecret(_v)`

```lua
local function FormatSecret(_v)
    return "<secret>"
end
```

That's the whole helper. No `..`, no `tostring`, no `pcall`-wrapped
attempt to read the value — all of those propagate taint. The secret
content is unrecoverable; we just emit a non-tainted marker.

### `SafeToString(v)`

```lua
local function SafeToString(v)
    if v == nil then return "" end
    if IsSecret(v) then return "<secret>" end
    local ok, s = pcall(string.format, "%s", tostring(v))
    if ok then return s end
    return "<opaque>"
end
```

Caller must gate `==nil` and `IsSecret` first via this helper before
any `tostring` / `string.format`. Used for pcall error messages and
non-secret values that just need a printable form.

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

- [ ] All `if IsSecret(v) then return "<secret>" end` guards present
    BEFORE any other op on `v`
- [ ] Only `v == nil` and `IsSecret(v)` are used against the
    suspected-secret value
- [ ] No `..`, `tostring`, `string.format` applied to `v` — those
    propagate taint into the result string
- [ ] No `==true` / `==false` / `<` / `>` / `~=` against `v` until
    AFTER both `==nil` and `IsSecret` checks have passed
- [ ] No `and` / `or` short-circuits with secret-bearing operands
    (use explicit `if/else`)
- [ ] Output goes to FontString, not EditBox
- [ ] No `GetText`, `GetStringHeight`, `GetStringWidth` on output
    that may hold tainted text
- [ ] No `table.concat` of a sequence containing tainted strings
    (since FormatSecret now emits a literal, this is automatic — but
    audit any helper that returns a built-up string)
