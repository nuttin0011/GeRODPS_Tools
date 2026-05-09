--[[
    GeRODPS_Tools / AuraListHelper.lua

    Native WoW UI port of GeRODPS/AuraListHelper.lua. Lists every aura
    on a single unit (target / focus / mouseover / partyN / nameplateN
    / ...) with a checkbox grid letting the user pick which AuraData
    fields to display.

    Differences from the AceGUI original:
      * Output is a FontString in a ScrollFrame, NOT a MultiLineEditBox.
        EditBox would reject strings whose secret taint propagates from
        the formatter — see SECRETS.md for the rules.
      * Interval is 4 toggle buttons instead of an AceGUI dropdown.
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

-- Strict rule: the ONLY operations allowed on a secret value are
--   v == nil
--   issecretvalue(v)
-- Anything else (tostring, ..,  string.format) silently propagates the
-- secret taint into the result string. Tainted strings still display
-- on FontString, but downstream they break things like table.concat
-- ("invalid value (secret) at index N in table for 'concat'"). So we
-- emit a non-tainted literal "<secret>" — never touch the value.
local function FormatSecret(_v)
    return "<secret>"
end

-- Convert a non-secret value to a display string. Caller MUST IsSecret-
-- gate first; this helper assumes v is not secret. nil → "".
local function SafeToString(v)
    if v == nil then return "" end
    if IsSecret(v) then return "<secret>" end
    local ok, s = pcall(string.format, "%s", tostring(v))
    if ok then return s end
    return "<opaque>"
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
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif t == "function" then return "<function>"
    elseif t == "thread"   then return "<thread>"
    elseif t == "userdata" then return "<userdata>"
    end
    return SafeToString(v)
end

-- ============================================================
-- Synthetic-field formatters (delegate to GeRODPS.AuraCache helpers)
-- ============================================================

local function FormatDispelByCurve(unit, info)
    if not (GeRODPS.AuraCache and GeRODPS.AuraCache.GetDispelTypeName) then
        return "(AuraCache.GetDispelTypeName unavailable)"
    end
    local id = info.auraInstanceID
    if id == nil then return "nil |cFF888888(no auraInstanceID)|r" end
    if IsSecret(id) then return "nil |cFF888888(auraInstanceID is <secret>)|r" end
    local name = GeRODPS.AuraCache.GetDispelTypeName(unit, id)
    -- Strict secret rule: only `==nil` and `IsSecret` allowed on `name`
    -- (don't truthiness-check it, don't concat it). Tainted name would
    -- propagate into the result and break downstream table.concat.
    if name == nil    then return "nil |cFF888888(curve API returned nil)|r" end
    if IsSecret(name) then return "<secret>" end
    return '"' .. name .. '"'
end

local function FormatBoolWithDiag(probeFn, unit, info, label)
    if not (GeRODPS.AuraCache and probeFn) then
        return "(AuraCache unavailable)"
    end
    local id = info.auraInstanceID
    if id == nil then return "nil |cFF888888(no auraInstanceID)|r" end
    if IsSecret(id) then return "nil |cFF888888(auraInstanceID is <secret>)|r" end
    local r = probeFn(unit, id)
    -- Same strict rule on `r`: `==nil` then `IsSecret` first, only THEN
    -- can we compare against `true`/`false` (now guaranteed non-secret).
    if r == nil    then return "nil |cFF888888(" .. label .. " unavailable)|r" end
    if IsSecret(r) then return "<secret>" end
    if r == true   then return "true"  end
    if r == false  then return "false" end
    return SafeToString(r)
end

local function FormatPlayerDispellable(unit, info)
    return FormatBoolWithDiag(
        GeRODPS.AuraCache and GeRODPS.AuraCache.IsPlayerDispellable,
        unit, info, "IsAuraFilteredOutByInstanceID")
end

local function FormatPlayerDispellableHELPFUL(unit, info)
    local fn = GeRODPS.AuraCache and GeRODPS.AuraCache.MatchesFilter
    if not fn then return "(MatchesFilter unavailable)" end
    return FormatBoolWithDiag(
        function(u, id) return fn(u, id, "HELPFUL|RAID_PLAYER_DISPELLABLE") end,
        unit, info, "HELPFUL|RAID_PLAYER_DISPELLABLE")
end

local function FormatPlayerDispellableHARMFUL(unit, info)
    local fn = GeRODPS.AuraCache and GeRODPS.AuraCache.MatchesFilter
    if not fn then return "(MatchesFilter unavailable)" end
    return FormatBoolWithDiag(
        function(u, id) return fn(u, id, "HARMFUL|RAID_PLAYER_DISPELLABLE") end,
        unit, info, "HARMFUL|RAID_PLAYER_DISPELLABLE")
end

local function FormatOnBlizzardNameplate(unit, info)
    return FormatBoolWithDiag(
        GeRODPS.AuraCache and GeRODPS.AuraCache.IsOnBlizzardNameplate,
        unit, info, "Blizzard nameplate aura list")
end

local function FormatFilterProbe(unit, info)
    local fn = GeRODPS.AuraCache and GeRODPS.AuraCache.MatchesFilter
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
        #hits, #PROBE_FILTERS, table.concat(hits, "\n        "))
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
    return table.concat(lines, "\n")
end

-- ============================================================
-- Aura scan
-- ============================================================

local registeredUnit = nil

local function SwapRegisteredUnit(newUnit)
    if newUnit == registeredUnit then return end
    if registeredUnit and GeRODPS and GeRODPS.AuraCache then
        GeRODPS.AuraCache.Unregister(registeredUnit)
    end
    registeredUnit = newUnit
    if registeredUnit and GeRODPS and GeRODPS.AuraCache then
        GeRODPS.AuraCache.Register(registeredUnit)
    end
end

local function ScanAuras(unit, filter)
    if not unit or unit == "" then return {} end
    if not (GeRODPS and GeRODPS.AuraCache) then return {} end
    return GeRODPS.AuraCache.GetAuras(unit, filter)
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
    return table.concat(sections, "\n")
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

local function ApplySavedGeometry(self)
    local db = GetDB()
    self:ClearAllPoints()
    if db.point and db.relPoint and db.x and db.y then
        self:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    else
        self:SetPoint("CENTER")
    end
    self:SetSize(db.w or DEFAULT_W, db.h or DEFAULT_H)
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
    resize:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    resize:SetPushedTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Down")
    resize:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    resize:SetScript("OnMouseUp",   function()
        frame:StopMovingOrSizing()
        SaveSize(frame)
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

        local scroll = CreateFrame("ScrollFrame", nil, body, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", statusFS, "BOTTOMLEFT", 0, -6)
        scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -22, 4)

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

        scroll:SetScrollChild(outputContent)
        outputContent:SetSize(math.max(1, scroll:GetWidth()), math.max(1, scroll:GetHeight()))

        -- Sync content size to viewport on ScrollFrame resize. NEVER read
        -- output text or its rendered metrics — both trip the secret guard
        -- when the text contains tainted concat results. Long output is
        -- clipped at the bottom of the viewport; user resizes the parent
        -- frame to see more.
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
    if not f:IsShown() then f:Show() end
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
