--[[
    AuraListHelper.lua

    Lists every aura on a single unit (target / focus / mouseover /
    partyN / nameplateN / ...) with a checkbox grid letting the user
    pick which AuraData fields to display.

    UI notes:
      * Output is a FontString in a ScrollFrame, NOT an EditBox.
        EditBox would reject strings whose secret taint propagates
        from the formatter — see SECRETS.md for the rules.
      * Interval is 4 toggle buttons.
      * Field selection is split across three button-tabs:
        Display / Native Fields / Custom Fields.
      * Geometry persisted in GeRODPS_ToolsDB.auraListHelper.

    Public:
        GeRODPS_Tools.ToggleAuraListHelper()
        GeRODPS_Tools.ShowAuraListHelper()
        GeRODPS_Tools.HideAuraListHelper()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME = "GeRODPS_ToolsAuraListHelperFrame"

local DEFAULT_W, DEFAULT_H = 740, 640
local MIN_W, MIN_H = 560, 460
local MAX_W, MAX_H = 1600, 1200

-- ============================================================
-- Field schema (mirrors original AuraListHelper)
-- ============================================================
-- Split into Native (AuraData struct fields) vs Custom (synthetic /
-- probed via AuraCache helpers, NOT on the AuraData object). Each tab
-- in the UI shows its own subset; AURA_FIELDS is the union used by the
-- per-aura formatter so display order stays stable.

local NATIVE_FIELDS = {
    "name", "spellId", "auraInstanceID",
    "icon", "applications", "charges", "maxCharges",
    "duration", "expirationTime", "timeMod",
    "dispelName",
    "sourceUnit", "points",
    "isHelpful", "isHarmful", "isStealable",
    "isFromPlayerOrPlayerPet", "isBossAura", "isRaid",
    "isNameplateOnly", "nameplateShowAll", "nameplateShowPersonal",
    "canApplyAura",
    "isDPSRoleAura", "isHealerRoleAura", "isTankRoleAura",
}

local CUSTOM_FIELDS = {
    "dispelNameByCurve",
    "isPlayerDispellable",
    "isPlayerDispellable_HELPFUL", "isPlayerDispellable_HARMFUL",
    "isOnBlizzardNameplate",
    "filterProbe",
    "canActivePlayerDispel",
}

-- Union — display order in the per-aura formatter. Native first, then custom,
-- so the more useful fields surface near the top of each aura entry.
local AURA_FIELDS = {}
for _, f in ipairs(NATIVE_FIELDS) do AURA_FIELDS[#AURA_FIELDS + 1] = f end
for _, f in ipairs(CUSTOM_FIELDS) do AURA_FIELDS[#AURA_FIELDS + 1] = f end

local DEFAULT_ENABLED_FIELDS = {
    name = true, spellId = true,
    dispelName = true, dispelNameByCurve = true,
    isPlayerDispellable = true,
    isOnBlizzardNameplate = true,
    filterProbe = true,
    applications = true, duration = true, expirationTime = true,
    sourceUnit = true, isStealable = true, isBossAura = true,
    nameplateShowAll = true, nameplateShowPersonal = true,
}

local PROBE_FILTERS = {
    "HELPFUL|RAID_PLAYER_DISPELLABLE",
    "HARMFUL|RAID_PLAYER_DISPELLABLE",
    "HELPFUL|RAID_IN_COMBAT",   "HELPFUL|RAID",
    "HARMFUL|RAID_IN_COMBAT",   "HARMFUL|RAID",
    "HELPFUL|PLAYER",           "HARMFUL|PLAYER",
    "HELPFUL|PLAYER|RAID_IN_COMBAT", "HELPFUL|PLAYER|RAID",
    "HELPFUL|IMPORTANT",        "HARMFUL|IMPORTANT",
    "HELPFUL|BIG_DEFENSIVE",    "HELPFUL|EXTERNAL_DEFENSIVE",
    "HELPFUL",                  "HARMFUL",
    "HELPFUL|INCLUDE_NAME_PLATE_ONLY", "HARMFUL|INCLUDE_NAME_PLATE_ONLY",
}

local INTERVAL_OPTIONS = { 0.2, 0.4, 1.2, 4.8 }
local DEFAULT_UNIT     = "target"
local DEFAULT_INTERVAL = 0.4

-- Layout constants
local FIELD_COLS = 4
local FIELD_ROW_H = 22
local FIELD_COL_W = 175
local LINE_HEIGHT = 14   -- approx 1 line of ChatFontNormal

-- ============================================================
-- DB
-- ============================================================

local function GetDB()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    GeRODPS_ToolsDB.auraListHelper = GeRODPS_ToolsDB.auraListHelper or {}
    local db = GeRODPS_ToolsDB.auraListHelper
    if db.unit     == nil then db.unit     = DEFAULT_UNIT     end
    if db.interval == nil then db.interval = DEFAULT_INTERVAL end
    if db.fields   == nil then
        db.fields = {}
        for k, v in pairs(DEFAULT_ENABLED_FIELDS) do db.fields[k] = v end
    end
    return db
end

-- ============================================================
-- Secret-aware formatting (see SECRETS.md)
-- ============================================================

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

-- DISPLAY rule: `..` and `tostring(v)` against a secret value DO work
-- — they produce a regular Lua string (with the secret taint flagged
-- into the metadata). FontString:SetText accepts tainted strings, so
-- we can show the user a readable "<secret>theActualValue".
--
-- LOGIC rule: NEVER do anything else with a secret value. No `==`,
-- no `<` `>` `~=`, no arithmetic, no `if v then`, no `and`/`or`. Only
-- `v == nil` and `IsSecret(v)` are guaranteed safe.
--
-- Downstream caveat: tainted strings break `table.concat` (raises
-- "invalid value (secret) at index N in table for 'concat'"). All
-- string aggregation in this file uses ConcatLines (below) instead.
local function FormatSecret(v)
    local ok, s = pcall(function() return "<secret>" .. tostring(v) end)
    if ok then return s end
    return "<secret>"
end

-- Convert a non-secret value to a display string. nil → "".
local function SafeToString(v)
    if v == nil then return "" end
    if IsSecret(v) then return FormatSecret(v) end
    local ok, s = pcall(string.format, "%s", tostring(v))
    if ok then return s end
    return "<opaque>"
end

-- Manual `..` chain that tolerates tainted entries. Use this instead
-- of `table.concat` whenever the array might contain values produced
-- by FormatSecret / VarToText / Format* — those carry the secret
-- taint forward and table.concat refuses to splice them.
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

local function VarToText(v)
    if IsSecret(v) then return FormatSecret(v) end
    local t = type(v)
    if     t == "nil"      then return "nil"
    elseif t == "boolean"  then return tostring(v)
    elseif t == "number"   then
        if v == math.floor(v) then return tostring(math.floor(v)) end
        return string.format("%.3f", v)
    elseif t == "string"   then
        if #v > 80 then return '"' .. v:sub(1, 80) .. '..."' end
        return '"' .. v .. '"'
    elseif t == "table"    then
        local n = #v
        if n == 0 then return "{}" end
        local parts = {}
        for i = 1, math.min(n, 8) do
            parts[i] = VarToText(v[i])
        end
        if n > 8 then parts[#parts + 1] = "..." end
        return "{" .. ConcatLines(parts, ", ") .. "}"
    elseif t == "function" then return "<function>"
    elseif t == "thread"   then return "<thread>"
    elseif t == "userdata" then return "<userdata>"
    end
    return SafeToString(v)
end

-- ============================================================
-- Synthetic-field formatters
-- ============================================================
-- A few "Custom Fields" (filter probes, dispel-type curve,
-- IsPlayerDispellable, IsOnBlizzardNameplate, ...) lean on an external
-- AuraCache helper if one happens to be available in the global table.
-- When it isn't, those fields read "(AuraCache unavailable)" — every
-- native AuraData field continues to work either way.

local function GetAuraCache()
    local g = _G.GeRODPS
    return g and g.AuraCache or nil
end

local function FormatDispelByCurve(unit, info)
    local ac = GetAuraCache()
    if not (ac and ac.GetDispelTypeName) then
        return "(AuraCache.GetDispelTypeName unavailable)"
    end
    local id = info.auraInstanceID
    if id == nil then return "nil |cFF888888(no auraInstanceID)|r" end
    if IsSecret(id) then return "nil |cFF888888(auraInstanceID is <secret>)|r" end
    local name = ac.GetDispelTypeName(unit, id)
    -- Strict logic rule: only `==nil` and `IsSecret` allowed BEFORE we
    -- decide what to do with `name` (no truthiness check on a possibly
    -- tainted string). Once we know it's a real (non-secret) string,
    -- `..` is fine; tainted-string concat is what FormatSecret does.
    if name == nil    then return "nil |cFF888888(curve API returned nil)|r" end
    if IsSecret(name) then return FormatSecret(name) end
    return '"' .. name .. '"'
end

local function FormatBoolWithDiag(probeFn, unit, info, label)
    local ac = GetAuraCache()
    if not (ac and probeFn) then
        return "(AuraCache unavailable)"
    end
    local id = info.auraInstanceID
    if id == nil then return "nil |cFF888888(no auraInstanceID)|r" end
    if IsSecret(id) then return "nil |cFF888888(auraInstanceID is <secret>)|r" end
    local r = probeFn(unit, id)
    -- Same logic rule on `r`: `==nil` and `IsSecret` first; only after
    -- both checks pass is r guaranteed non-secret and safe to compare
    -- against true/false.
    if r == nil    then return "nil |cFF888888(" .. label .. " unavailable)|r" end
    if IsSecret(r) then return FormatSecret(r) end
    if r == true   then return "true"  end
    if r == false  then return "false" end
    return SafeToString(r)
end

local function FormatPlayerDispellable(unit, info)
    local ac = GetAuraCache()
    return FormatBoolWithDiag(
        ac and ac.IsPlayerDispellable,
        unit, info, "IsAuraFilteredOutByInstanceID")
end

local function FormatPlayerDispellableHELPFUL(unit, info)
    local ac = GetAuraCache()
    local fn = ac and ac.MatchesFilter
    if not fn then return "(MatchesFilter unavailable)" end
    return FormatBoolWithDiag(
        function(u, id) return fn(u, id, "HELPFUL|RAID_PLAYER_DISPELLABLE") end,
        unit, info, "HELPFUL|RAID_PLAYER_DISPELLABLE")
end

local function FormatPlayerDispellableHARMFUL(unit, info)
    local ac = GetAuraCache()
    local fn = ac and ac.MatchesFilter
    if not fn then return "(MatchesFilter unavailable)" end
    return FormatBoolWithDiag(
        function(u, id) return fn(u, id, "HARMFUL|RAID_PLAYER_DISPELLABLE") end,
        unit, info, "HARMFUL|RAID_PLAYER_DISPELLABLE")
end

local function FormatOnBlizzardNameplate(unit, info)
    local ac = GetAuraCache()
    return FormatBoolWithDiag(
        ac and ac.IsOnBlizzardNameplate,
        unit, info, "Blizzard nameplate aura list")
end

local function FormatFilterProbe(unit, info)
    local ac = GetAuraCache()
    local fn = ac and ac.MatchesFilter
    if not fn then return "(MatchesFilter unavailable)" end
    local id = info.auraInstanceID
    if id == nil then return "nil |cFF888888(no auraInstanceID)|r" end
    if IsSecret(id) then return "nil |cFF888888(auraInstanceID is <secret>)|r" end
    local hits, misses, errs = {}, 0, 0
    for _, filter in ipairs(PROBE_FILTERS) do
        local r = fn(unit, id, filter)
        -- Strict secret rule: gate `==nil` and `IsSecret` first before
        -- comparing against `true`/`false`.
        if r == nil then
            errs = errs + 1
        elseif IsSecret(r) then
            errs = errs + 1
        elseif r == true then
            hits[#hits + 1] = filter
        elseif r == false then
            misses = misses + 1
        else
            errs = errs + 1
        end
    end
    if #hits == 0 then
        return string.format("|cFF888888(0 hits / %d misses / %d errs)|r", misses, errs)
    end
    return string.format("|cFF66FF66%d hit(s)|r |cFF888888(of %d)|r:\n        %s",
        #hits, #PROBE_FILTERS, ConcatLines(hits, "\n        "))
end

-- ============================================================
-- Per-aura formatter
-- ============================================================

local function FormatAura(idx, kind, info, enabledFields, unit)
    if IsSecret(info) then
        return string.format("[%d] %s -- %s", idx, kind, FormatSecret(info))
    end
    local nameVal = info.name
    local headerName
    if IsSecret(nameVal) then
        headerName = FormatSecret(nameVal)
    elseif nameVal == nil then
        headerName = "?"
    else
        headerName = SafeToString(nameVal)
    end
    local lines = { string.format("[%d] %s -- %s", idx, kind, headerName) }
    for _, field in ipairs(AURA_FIELDS) do
        if enabledFields[field] then
            local rendered
            if field == "dispelNameByCurve" then
                rendered = FormatDispelByCurve(unit, info)
            elseif field == "isPlayerDispellable" then
                rendered = FormatPlayerDispellable(unit, info)
            elseif field == "isPlayerDispellable_HELPFUL" then
                rendered = FormatPlayerDispellableHELPFUL(unit, info)
            elseif field == "isPlayerDispellable_HARMFUL" then
                rendered = FormatPlayerDispellableHARMFUL(unit, info)
            elseif field == "isOnBlizzardNameplate" then
                rendered = FormatOnBlizzardNameplate(unit, info)
            elseif field == "filterProbe" then
                rendered = FormatFilterProbe(unit, info)
            else
                rendered = VarToText(info[field])
            end
            lines[#lines + 1] = string.format("    %s = %s", field, rendered)
        end
    end
    return ConcatLines(lines, "\n")
end

-- ============================================================
-- Aura scan
-- ============================================================

local registeredUnit = nil

local function SwapRegisteredUnit(newUnit)
    if newUnit == registeredUnit then return end
    local ac = GetAuraCache()
    if registeredUnit and ac then ac.Unregister(registeredUnit) end
    registeredUnit = newUnit
    if registeredUnit and ac then ac.Register(registeredUnit) end
end

-- Without GeRODPS.AuraCache we fall back to a direct C_UnitAuras call —
-- the standalone path loses the cache's batched/event-driven refresh
-- but still surfaces every aura on the unit so the helper isn't useless.
local function ScanAuras(unit, filter)
    if not unit or unit == "" then return {} end
    local ac = GetAuraCache()
    if ac and ac.GetAuras then
        return ac.GetAuras(unit, filter)
    end
    if not (C_UnitAuras and UnitExists and UnitExists(unit)) then return {} end
    local out = {}
    if C_UnitAuras.GetUnitAuras then
        local sortRule = (Enum and Enum.UnitAuraSortRule and Enum.UnitAuraSortRule.Unsorted) or nil
        local list = C_UnitAuras.GetUnitAuras(unit, filter, nil, sortRule)
        if list then
            for _, info in ipairs(list) do out[#out + 1] = info end
        end
    end
    return out
end

local function BuildOutputText()
    local s = GetDB()
    local unit = s.unit or DEFAULT_UNIT
    if not unit or unit == "" then return "(no unit token specified)" end
    if not UnitExists(unit) then
        return string.format("(unit %q does not exist)", unit)
    end
    local helpful = ScanAuras(unit, "HELPFUL")
    local harmful = ScanAuras(unit, "HARMFUL")
    local enabled = s.fields or DEFAULT_ENABLED_FIELDS
    if #helpful == 0 and #harmful == 0 then
        return string.format("(unit %q has no auras)", unit)
    end
    local sections = {}
    sections[#sections + 1] = string.format(
        "=== %s -- %d buff(s), %d debuff(s) ===",
        unit, #helpful, #harmful)
    if #helpful > 0 then
        sections[#sections + 1] = ""
        sections[#sections + 1] = "-- BUFFS (HELPFUL) --"
        for i, info in ipairs(helpful) do
            sections[#sections + 1] = FormatAura(i, "BUFF", info, enabled, unit)
        end
    end
    if #harmful > 0 then
        sections[#sections + 1] = ""
        sections[#sections + 1] = "-- DEBUFFS (HARMFUL) --"
        for i, info in ipairs(harmful) do
            sections[#sections + 1] = FormatAura(i, "DEBUFF", info, enabled, unit)
        end
    end
    return ConcatLines(sections, "\n")
end

-- ============================================================
-- State
-- ============================================================

local frame
local outputFS
local outputContent
local statusFS
local fieldCheckboxes = {}
local intervalButtons = {}
local tickFrame
local tickAccum = 0

-- ============================================================
-- Geometry persistence
-- ============================================================

local function SavePosition(self)
    local db = GetDB()
    local point, _, relPoint, x, y = self:GetPoint(1)
    db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

local function SaveSize(self)
    local db = GetDB()
    db.w, db.h = self:GetWidth(), self:GetHeight()
end

-- Minimum gap between every frame edge and the nearest screen edge
-- when restoring saved geometry. Saved size larger than the safe area
-- gets clamped; saved position that pushes any edge past the margin
-- gets shifted inward (preserving user position whenever possible).
local SCREEN_MARGIN = 100

local function ApplySavedGeometry(self)
    local db = GetDB()
    local screenW = UIParent:GetWidth()
    local screenH = UIParent:GetHeight()

    -- 1. Clamp size to fit within (screen - 2 * margin).
    local w = db.w or DEFAULT_W
    local h = db.h or DEFAULT_H
    local maxW = screenW - 2 * SCREEN_MARGIN
    local maxH = screenH - 2 * SCREEN_MARGIN
    if w > maxW then w = maxW end
    if h > maxH then h = maxH end
    if w < MIN_W then w = MIN_W end
    if h < MIN_H then h = MIN_H end

    -- 2. Apply saved anchor (or default to CENTER) and size.
    self:ClearAllPoints()
    if db.point and db.relPoint and db.x and db.y then
        self:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    else
        self:SetPoint("CENTER")
    end
    self:SetSize(w, h)

    -- 3. If any edge violates the margin, shift the frame inward.
    --    Offsets translate the frame regardless of which anchor pair was
    --    used, so we can re-apply the original point with adjusted x/y.
    local left, right = self:GetLeft(), self:GetRight()
    local bottom, top = self:GetBottom(), self:GetTop()
    if left and right and bottom and top then
        local dx, dy = 0, 0
        if left < SCREEN_MARGIN then
            dx = SCREEN_MARGIN - left
        elseif right > (screenW - SCREEN_MARGIN) then
            dx = (screenW - SCREEN_MARGIN) - right
        end
        if bottom < SCREEN_MARGIN then
            dy = SCREEN_MARGIN - bottom
        elseif top > (screenH - SCREEN_MARGIN) then
            dy = (screenH - SCREEN_MARGIN) - top
        end
        if dx ~= 0 or dy ~= 0 then
            local point, relTo, relPoint, x, y = self:GetPoint(1)
            self:ClearAllPoints()
            self:SetPoint(point, relTo or UIParent, relPoint, x + dx, y + dy)
        end
    end
end

-- ============================================================
-- Render
-- ============================================================

local function RenderStatus()
    if not statusFS then return end
    local s = GetDB()
    local enabledCount = 0
    for _, v in pairs(s.fields or {}) do if v then enabledCount = enabledCount + 1 end end
    statusFS:SetText(string.format(
        "|cFFAEE3F5Unit:|r %s   |cFFAEE3F5Interval:|r %ss   |cFFAEE3F5Fields:|r %d/%d",
        s.unit or "?", tostring(s.interval), enabledCount, #AURA_FIELDS))
end

local function RenderOutput()
    if not outputFS then return end
    -- Pure SetText. No measurement of the result (would trip secret
    -- guard for tainted strings).
    local ok, text = pcall(BuildOutputText)
    if ok then
        outputFS:SetText(text)
    else
        outputFS:SetText("|cffff8888build error:|r " .. SafeToString(text))
    end
    RenderStatus()
end

-- ============================================================
-- Interval button helpers
-- ============================================================

local function RefreshIntervalHighlights()
    local s = GetDB()
    for _, btn in ipairs(intervalButtons) do
        if btn._interval == s.interval then
            btn:LockHighlight()
        else
            btn:UnlockHighlight()
        end
    end
end

-- ============================================================
-- Tick: scan + render every interval
-- ============================================================

local function OnTick(_, dt)
    if not frame or not frame:IsShown() then return end
    tickAccum = tickAccum + dt
    local s = GetDB()
    if tickAccum < (s.interval or DEFAULT_INTERVAL) then return end
    tickAccum = 0
    RenderOutput()
end

local function EnsureTicker()
    if tickFrame then return end
    tickFrame = CreateFrame("Frame")
    tickFrame:SetScript("OnUpdate", OnTick)
end

-- ============================================================
-- Build UI
-- ============================================================

local function CreateAuraListHelperFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    -- Mark as user-placed; without this some Blizzard templates re-anchor
    -- the frame to its default position/size as soon as StartSizing fires,
    -- which manifests as an instant ~2x snap on the first resize click.
    frame:SetUserPlaced(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)

    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    else
        frame:SetMinResize(MIN_W, MIN_H)
        frame:SetMaxResize(MAX_W, MAX_H)
    end

    local resize = CreateFrame("Button", nil, frame)
    resize:SetSize(16, 16)
    resize:SetPoint("BOTTOMRIGHT", -4, 4)
    resize:EnableMouse(true)
    resize:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    resize:SetPushedTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Down")
    resize:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            frame:StopMovingOrSizing()  -- clear any stale state
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resize:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then
            frame:StopMovingOrSizing()
            SaveSize(frame)
        end
    end)

    if frame.TitleText then
        frame.TitleText:SetText("GeRODPS Tools — Aura List Helper")
    end

    local content = frame.Inset or frame
    local s = GetDB()

    -- ── Row 1: Unit token + Refresh Now ────────────────────────
    local unitLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    unitLbl:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -22)
    unitLbl:SetText("|cFFFFD200Unit Token|r (target / focus / mouseover / partyN / nameplateN)")

    local unitEB = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    unitEB:SetPoint("TOPLEFT", unitLbl, "BOTTOMLEFT", 6, -4)
    unitEB:SetSize(280, 22)
    unitEB:SetAutoFocus(false)
    unitEB:SetFontObject("ChatFontNormal")
    unitEB:SetMaxLetters(64)
    unitEB:SetText(s.unit or DEFAULT_UNIT)
    unitEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    unitEB:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    unitEB:SetScript("OnTextChanged", function(self)
        local txt = (self:GetText() or ""):match("^%s*(.-)%s*$") or ""
        local db = GetDB()
        db.unit = (txt ~= "") and txt or DEFAULT_UNIT
        SwapRegisteredUnit(db.unit ~= "" and db.unit or nil)
        tickAccum = 1e9   -- force scan next OnUpdate
    end)

    local refreshBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    refreshBtn:SetPoint("LEFT", unitEB, "RIGHT", 12, 0)
    refreshBtn:SetSize(110, 22)
    refreshBtn:SetText("Refresh Now")
    refreshBtn:SetScript("OnClick", function()
        tickAccum = 1e9
        RenderOutput()
    end)

    -- ── Row 2: Interval toggle buttons ─────────────────────────
    local intLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    intLbl:SetPoint("TOPLEFT", unitEB, "BOTTOMLEFT", -6, -10)
    intLbl:SetText("|cFFFFD200Refresh interval:|r")

    intervalButtons = {}
    local prevAnchor = intLbl
    for i, secs in ipairs(INTERVAL_OPTIONS) do
        local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        b:SetSize(54, 20)
        if i == 1 then
            b:SetPoint("LEFT", intLbl, "RIGHT", 8, 0)
        else
            b:SetPoint("LEFT", prevAnchor, "RIGHT", 4, 0)
        end
        b:SetText(secs .. "s")
        b._interval = secs
        b:SetScript("OnClick", function(self)
            local db = GetDB()
            db.interval = self._interval
            tickAccum = 0
            RefreshIntervalHighlights()
            RenderStatus()
        end)
        intervalButtons[#intervalButtons + 1] = b
        prevAnchor = b
    end
    RefreshIntervalHighlights()

    -- ── Row 3: Tab buttons (button-as-tab fallback; no template dep) ──
    local tabDef = {
        { name = "display", label = "Display"        },
        { name = "native",  label = "Native Fields"  },
        { name = "custom",  label = "Custom Fields"  },
    }
    local tabButtons = {}
    local prevTabAnchor
    for i, td in ipairs(tabDef) do
        local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        b:SetSize(120, 22)
        if i == 1 then
            b:SetPoint("TOPLEFT", intLbl, "BOTTOMLEFT", 0, -10)
        else
            b:SetPoint("LEFT", prevTabAnchor, "RIGHT", 4, 0)
        end
        b:SetText(td.label)
        b._tab = td.name
        tabButtons[td.name] = b
        prevTabAnchor = b
    end

    -- Body area below tabs — every tab body anchors to it via SetAllPoints.
    local bodyArea = CreateFrame("Frame", nil, content)
    bodyArea:SetPoint("TOPLEFT", tabButtons.display, "BOTTOMLEFT", 0, -6)
    bodyArea:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -8, 8)

    local bodies = {}
    fieldCheckboxes = {}

    local function RefreshFieldCheckboxes()
        local db = GetDB()
        for _, cb in ipairs(fieldCheckboxes) do
            cb:SetChecked(db.fields and db.fields[cb._field] or false)
        end
        tickAccum = 1e9
        RenderStatus()
    end

    -- ── Display body: status + ScrollFrame output ─────────────
    do
        local body = CreateFrame("Frame", nil, bodyArea)
        body:SetAllPoints(bodyArea)
        bodies.display = body

        statusFS = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        statusFS:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -4)
        statusFS:SetPoint("RIGHT", body, "RIGHT", -4, 0)
        statusFS:SetJustifyH("LEFT")
        statusFS:SetText("")

        -- Plain Frame (NOT UIPanelScrollFrameTemplate). The template's
        -- internal OnScrollRangeChanged calls ScrollUp/Down:SetEnabled with
        -- a boolean derived from scrollChild metrics — and our outputFS gets
        -- secret-tainted text from C_UnitAuras / combat-session APIs, which
        -- propagates into the FontString's measured height and trips
        -- SecureScrollTemplates.lua:140 'Secret values are not allowed'.
        -- Content is already clamped to viewport, so scrolling never works
        -- anyway; the template was pure liability.
        local scroll = CreateFrame("Frame", nil, body)
        scroll:SetPoint("TOPLEFT", statusFS, "BOTTOMLEFT", 0, -6)
        scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -4, 4)

        outputContent = CreateFrame("Frame", nil, scroll)
        outputContent:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)

        outputFS = outputContent:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
        outputFS:SetPoint("TOPLEFT", outputContent, "TOPLEFT", 4, -2)
        outputFS:SetPoint("TOPRIGHT", outputContent, "TOPRIGHT", -4, -2)
        outputFS:SetJustifyH("LEFT")
        outputFS:SetJustifyV("TOP")
        outputFS:SetWordWrap(true)
        outputFS:SetNonSpaceWrap(true)
        outputFS:SetText("")

        outputContent:SetSize(math.max(1, scroll:GetWidth()), math.max(1, scroll:GetHeight()))

        -- Sync content size to viewport. NEVER read output text or its
        -- rendered metrics — both trip the secret guard when the text
        -- contains tainted concat results. Long output is clipped at the
        -- bottom of the viewport; user resizes the parent frame to see more.
        scroll:SetScript("OnSizeChanged", function(_, w, h)
            if w <= 0 or h <= 0 then return end
            outputContent:SetSize(w, h)
        end)

        local bg = body:CreateTexture(nil, "BACKGROUND")
        bg:SetPoint("TOPLEFT", scroll, "TOPLEFT", -2, 2)
        bg:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 2, -2)
        bg:SetColorTexture(0, 0, 0, 0.45)
    end

    -- ── Field-tab body builder: All/None/Default + checkbox grid ──
    local function BuildFieldsBody(fieldList)
        local body = CreateFrame("Frame", nil, bodyArea)
        body:SetAllPoints(bodyArea)

        local allBtn = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
        allBtn:SetPoint("TOPLEFT", body, "TOPLEFT", 4, -4)
        allBtn:SetSize(64, 20)
        allBtn:SetText("All")

        local noneBtn = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
        noneBtn:SetPoint("LEFT", allBtn, "RIGHT", 4, 0)
        noneBtn:SetSize(64, 20)
        noneBtn:SetText("None")

        local defBtn = CreateFrame("Button", nil, body, "UIPanelButtonTemplate")
        defBtn:SetPoint("LEFT", noneBtn, "RIGHT", 4, 0)
        defBtn:SetSize(64, 20)
        defBtn:SetText("Default")

        for i, field in ipairs(fieldList) do
            local col = (i - 1) % FIELD_COLS
            local row = math.floor((i - 1) / FIELD_COLS)
            local cb = CreateFrame("CheckButton", nil, body, "UICheckButtonTemplate")
            cb:SetSize(20, 20)
            cb:SetPoint("TOPLEFT", allBtn, "BOTTOMLEFT",
                col * FIELD_COL_W, -10 - row * FIELD_ROW_H)
            cb._field = field
            cb:SetChecked(s.fields and s.fields[field] or false)
            cb.text:SetText(field)
            cb.text:ClearAllPoints()
            cb.text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
            cb:SetScript("OnClick", function(self)
                local db = GetDB()
                db.fields = db.fields or {}
                db.fields[self._field] = self:GetChecked() and true or false
                tickAccum = 1e9
                RenderStatus()
            end)
            fieldCheckboxes[#fieldCheckboxes + 1] = cb
        end

        -- Per-tab All/None/Default operate on this tab's field list only.
        allBtn:SetScript("OnClick", function()
            local db = GetDB()
            db.fields = db.fields or {}
            for _, f in ipairs(fieldList) do db.fields[f] = true end
            RefreshFieldCheckboxes()
        end)
        noneBtn:SetScript("OnClick", function()
            local db = GetDB()
            db.fields = db.fields or {}
            for _, f in ipairs(fieldList) do db.fields[f] = false end
            RefreshFieldCheckboxes()
        end)
        defBtn:SetScript("OnClick", function()
            local db = GetDB()
            db.fields = db.fields or {}
            for _, f in ipairs(fieldList) do
                db.fields[f] = DEFAULT_ENABLED_FIELDS[f] or false
            end
            RefreshFieldCheckboxes()
        end)

        return body
    end

    bodies.native = BuildFieldsBody(NATIVE_FIELDS)
    bodies.custom = BuildFieldsBody(CUSTOM_FIELDS)

    -- ── Tab switcher ─────────────────────────────────────────
    local function SwitchTab(name)
        for tn, b in pairs(bodies) do
            if tn == name then b:Show() else b:Hide() end
        end
        for tn, btn in pairs(tabButtons) do
            if tn == name then btn:LockHighlight() else btn:UnlockHighlight() end
        end
        if name == "display" then
            tickAccum = 1e9
            RenderOutput()
        end
    end
    for _, btn in pairs(tabButtons) do
        btn:SetScript("OnClick", function(self) SwitchTab(self._tab) end)
    end
    SwitchTab("display")

    -- Subscribe AuraCache to current unit
    SwapRegisteredUnit(s.unit ~= "" and s.unit or nil)

    table.insert(UISpecialFrames, FRAME_NAME)
    ApplySavedGeometry(frame)
    RenderStatus()
    frame:Hide()
    return frame
end

-- ============================================================
-- Public API
-- ============================================================

function TOOL.ShowAuraListHelper()
    local f = CreateAuraListHelperFrame()
    EnsureTicker()
    if not f:IsShown() then
        ApplySavedGeometry(f)   -- snap into margin on every open
        f:Show()
    end
    tickAccum = 1e9   -- render immediately
    RenderOutput()
end

function TOOL.HideAuraListHelper()
    if frame and frame:IsShown() then
        frame:Hide()
        SwapRegisteredUnit(nil)
    end
end

function TOOL.ToggleAuraListHelper()
    local f = CreateAuraListHelperFrame()
    EnsureTicker()
    if f:IsShown() then
        f:Hide()
        SwapRegisteredUnit(nil)
    else
        ApplySavedGeometry(f)   -- snap into margin on every open
        f:Show()
        local s = GetDB()
        SwapRegisteredUnit(s.unit ~= "" and s.unit or nil)
        tickAccum = 1e9
        RenderOutput()
    end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("Aura List Helper", TOOL.ToggleAuraListHelper)
end
