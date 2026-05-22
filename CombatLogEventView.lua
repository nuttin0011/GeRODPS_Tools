--[[
    GeRODPS_Tools / CombatLogEventView.lua

    "Combat Log Event View" — realtime table of COMBAT_LOG_EVENT_UNFILTERED
    payloads. Each event from CombatLogGetCurrentEventInfo() lands as a
    new row at the top; ring buffer trimmed to MAX_EVENTS (oldest tail
    is dropped).

    Native WoW UI (no AceGUI). Layout:
        Title bar + toolbar (Pause / Clear / status text)
        ScrollFrame viewport (1200×900-ish minus chrome)
          └── content Frame (3530 × MAX_EVENTS*ROW_H)
                ├── row[0]  header (sticky-ish, scrolls with content)
                └── row[1..50]  data rows, newest = row[1]
        Vertical slider (right)   — UIPanelScrollBarTemplate
        Horizontal slider (bottom) — OptionsSliderTemplate (orientation=H)
        Resize handle (bottom-right corner)

    Mouse wheel = vertical scroll. Shift + mouse wheel = horizontal.

    Secret handling — per cell, at render time:
        v == nil       → "(nil)"
        IsSecret(v)    → "|cFFFF7777<secret>|r" .. tostring(v)
        otherwise      → tostring(v)
    The result is a regular string, possibly tainted; FontString accepts
    tainted text via SetText. We never call GetText / GetStringWidth /
    GetStringHeight on these strings (would trip secret guard).

    Per Tools/SECRETS.md:
      • LOGIC rule — only v == nil and IsSecret(v) are guaranteed safe
        on a secret value. No equality / arithmetic / truthiness.
      • DISPLAY rule — "<tag>" .. tostring(v) works (taint propagates),
        FontString:SetText accepts the result.

    Render is throttled: COMBAT_LOG_EVENT_UNFILTERED can fire 200+ times
    per second in raid combat. The handler appends + sets a dirty flag;
    a 0.1 s ticker performs one Render() pass when dirty.

    Public:
        GeRODPS_Tools.ToggleCombatLogEventView()
        GeRODPS_Tools.ShowCombatLogEventView()
        GeRODPS_Tools.HideCombatLogEventView()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME    = "GeRODPS_ToolsCombatLogViewFrame"
local MAX_EVENTS    = 50
local NUM_COLS      = 26    -- 11 fixed + 15 vararg
local ROW_H         = 14
local THROTTLE      = 0.1
local SCREEN_MARGIN = 50

local DEFAULT_W, DEFAULT_H = 1200, 900
local MIN_W,     MIN_H     = 800, 400
local MAX_W,     MAX_H     = 1920, 1200

-- 11 fixed + 15 vararg = 26 widths. Sum = 1430 + 2100 = 3530.
local COL_W = {
    100, 200, 50, 220, 140, 90, 90, 220, 140, 90, 90,
    140, 140, 140, 140, 140, 140, 140, 140, 140, 140, 140, 140, 140, 140, 140,
}

local HEADERS = {
    "timestamp", "subevent", "hide",
    "sourceGUID", "sourceName", "srcFlags", "srcRaid",
    "destGUID", "destName", "dstFlags", "dstRaid",
    "arg12", "arg13", "arg14", "arg15", "arg16", "arg17", "arg18",
    "arg19", "arg20", "arg21", "arg22", "arg23", "arg24", "arg25", "arg26",
}

local CONTENT_W = 0
for i = 1, NUM_COLS do CONTENT_W = CONTENT_W + COL_W[i] end
local CONTENT_H = ROW_H * (MAX_EVENTS + 1)   -- +1 for header

-- ============================================================
-- DB (geometry only)
-- ============================================================

local function GetDB()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    GeRODPS_ToolsDB.combatLogView = GeRODPS_ToolsDB.combatLogView or {}
    return GeRODPS_ToolsDB.combatLogView
end

-- ============================================================
-- Secret-safe value formatting
-- ============================================================

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

-- DISPLAY path: ".." + tostring on a secret produces a tainted string.
-- FontString accepts it. We tag with a red color escape so the user
-- can see at a glance which cells are secret.
local function CellText(v)
    if v == nil then return "(nil)" end
    if IsSecret(v) then
        local ok, s = pcall(function() return "|cFFFF7777<secret>|r" .. tostring(v) end)
        if ok then return s end
        return "|cFFFF7777<secret>|r"
    end
    local ok, s = pcall(tostring, v)
    if ok then return s end
    return "<opaque>"
end

-- ============================================================
-- State
-- ============================================================

local frame
local content
local scroll
local vSlider, hSlider
local headerRow
local rows = {}            -- rows[1..MAX_EVENTS], data rows
local buf  = {}            -- ring buffer, buf[1] = newest
local paused = false
local dirty  = false
local ticker
local statusFS
local listenerFrame

-- ============================================================
-- Geometry persistence (same pattern as WatchVar / AuraListHelper)
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
    local screenW = UIParent:GetWidth()
    local screenH = UIParent:GetHeight()

    local w = db.w or DEFAULT_W
    local h = db.h or DEFAULT_H
    local maxW = screenW - 2 * SCREEN_MARGIN
    local maxH = screenH - 2 * SCREEN_MARGIN
    if w > maxW then w = maxW end
    if h > maxH then h = maxH end
    if w < MIN_W then w = MIN_W end
    if h < MIN_H then h = MIN_H end

    self:ClearAllPoints()
    if db.point and db.relPoint and db.x and db.y then
        self:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    else
        self:SetPoint("CENTER")
    end
    self:SetSize(w, h)

    -- Snap into margin if off-screen
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
-- Slider sync — keep slider ranges in sync with scroll viewport.
-- Called on frame resize so user can resize and still scroll fully.
-- ============================================================

local function UpdateSliderRanges()
    if not scroll or not content then return end
    local sw, sh = scroll:GetSize()
    local cw, ch = content:GetSize()
    local hMax = math.max(0, cw - sw)
    local vMax = math.max(0, ch - sh)
    if hSlider then
        hSlider:SetMinMaxValues(0, hMax)
        if hSlider:GetValue() > hMax then hSlider:SetValue(hMax) end
    end
    if vSlider then
        vSlider:SetMinMaxValues(0, vMax)
        if vSlider:GetValue() > vMax then vSlider:SetValue(vMax) end
    end
end

-- ============================================================
-- Render — flush ring buffer into the row pool. Called from the
-- throttled ticker when dirty=true. SetText only; no measurement.
-- ============================================================

local function Render()
    for r = 1, MAX_EVENTS do
        local row = rows[r]
        if not row then break end
        local ev = buf[r]
        if ev then
            -- ev is a normal Lua table (constructed with `{ ... }` from
            -- varargs). Indexing it is safe even if cells inside are
            -- secret — secret guard only blocks indexing INTO a secret
            -- TABLE, not normal tables containing secret values.
            for c = 1, NUM_COLS do
                row.fs[c]:SetText(CellText(ev[c]))
            end
        else
            for c = 1, NUM_COLS do
                row.fs[c]:SetText("")
            end
        end
    end
    if statusFS then
        statusFS:SetText(string.format("events: %d / %d%s",
            math.min(#buf, MAX_EVENTS), MAX_EVENTS,
            paused and "  |cFFFFFF00(PAUSED)|r" or ""))
    end
end

-- ============================================================
-- Event capture — push newest at index 1, drop tail at index 51+.
-- ============================================================

local function OnCombatLogEvent()
    if paused then return end
    -- Capture varargs into a fresh table. Per WoW 11/12 API,
    -- CombatLogGetCurrentEventInfo returns 11 fixed values + variable
    -- args dependent on subevent.
    local args = { CombatLogGetCurrentEventInfo() }
    table.insert(buf, 1, args)
    if #buf > MAX_EVENTS then
        buf[MAX_EVENTS + 1] = nil
    end
    dirty = true
end

local function EnsureTicker()
    if ticker then return end
    ticker = C_Timer.NewTicker(THROTTLE, function()
        if not dirty then return end
        if not frame or not frame:IsShown() then return end
        dirty = false
        Render()
    end)
end

local function EnsureListener()
    if listenerFrame then return end
    listenerFrame = CreateFrame("Frame")
    listenerFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    listenerFrame:SetScript("OnEvent", OnCombatLogEvent)
end

-- ============================================================
-- Frame builder
-- ============================================================

local function BuildContent(parent)
    content = CreateFrame("Frame", nil, parent)
    content:SetSize(CONTENT_W, CONTENT_H)

    -- Subtle striping background for content
    local bg = content:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.4)

    -- Header row
    headerRow = CreateFrame("Frame", nil, content)
    headerRow:SetSize(CONTENT_W, ROW_H)
    headerRow:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    local hbg = headerRow:CreateTexture(nil, "ARTWORK")
    hbg:SetAllPoints()
    hbg:SetColorTexture(0.15, 0.10, 0.05, 0.9)
    local x = 0
    for c = 1, NUM_COLS do
        local fs = headerRow:CreateFontString(nil, "OVERLAY", "ChatFontSmall")
        fs:SetPoint("LEFT", headerRow, "LEFT", x + 4, 0)
        fs:SetWidth(COL_W[c] - 8)
        fs:SetHeight(ROW_H)
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("MIDDLE")
        fs:SetText("|cFFFFD200" .. HEADERS[c] .. "|r")
        x = x + COL_W[c]
    end

    -- Data rows — pre-create all MAX_EVENTS rows, each with NUM_COLS
    -- FontStrings. Reused across renders; we only SetText to update.
    for r = 1, MAX_EVENTS do
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(CONTENT_W, ROW_H)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -r * ROW_H)
        if r % 2 == 0 then
            local rbg = row:CreateTexture(nil, "BACKGROUND")
            rbg:SetAllPoints()
            rbg:SetColorTexture(0.05, 0.05, 0.05, 0.5)
        end
        row.fs = {}
        local rx = 0
        for c = 1, NUM_COLS do
            local fs = row:CreateFontString(nil, "OVERLAY", "ChatFontSmall")
            fs:SetPoint("LEFT", row, "LEFT", rx + 4, 0)
            fs:SetWidth(COL_W[c] - 8)
            fs:SetHeight(ROW_H)
            fs:SetJustifyH("LEFT")
            fs:SetJustifyV("MIDDLE")
            fs:SetText("")
            row.fs[c] = fs
            rx = rx + COL_W[c]
        end
        rows[r] = row
    end
end

local function CreateFrameOnce()
    if frame then return frame end

    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
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
    elseif frame.SetMinResize then
        frame:SetMinResize(MIN_W, MIN_H)
        frame:SetMaxResize(MAX_W, MAX_H)
    end

    if frame.TitleText then
        frame.TitleText:SetText("GeRODPS Tools — Combat Log Event View")
    end

    local inset = frame.Inset or frame

    -- ── Toolbar ──────────────────────────────────────────
    local toolbar = CreateFrame("Frame", nil, inset)
    toolbar:SetHeight(28)
    toolbar:SetPoint("TOPLEFT", inset, "TOPLEFT", 8, -4)
    toolbar:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -8, -4)

    local pauseBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    pauseBtn:SetSize(80, 22)
    pauseBtn:SetPoint("LEFT", toolbar, "LEFT", 0, 0)
    pauseBtn:SetText("Pause")
    pauseBtn:SetScript("OnClick", function()
        paused = not paused
        pauseBtn:SetText(paused and "Resume" or "Pause")
        dirty = true   -- force status text refresh
    end)

    local clearBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    clearBtn:SetSize(80, 22)
    clearBtn:SetPoint("LEFT", pauseBtn, "RIGHT", 8, 0)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        buf = {}
        dirty = true
        Render()   -- immediate clear, don't wait for ticker
    end)

    statusFS = toolbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusFS:SetPoint("LEFT", clearBtn, "RIGHT", 16, 0)
    statusFS:SetText("events: 0 / " .. MAX_EVENTS)

    -- ── ScrollFrame + sliders ────────────────────────────
    -- Layout reservations: toolbar=28 top, hSlider=20 bottom, vSlider=20 right.
    scroll = CreateFrame("ScrollFrame", nil, inset)
    scroll:SetPoint("TOPLEFT",     toolbar, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", inset,   "BOTTOMRIGHT", -28, 28)
    scroll:EnableMouseWheel(true)

    BuildContent(scroll)
    scroll:SetScrollChild(content)

    -- Vertical slider on the right
    vSlider = CreateFrame("Slider", nil, inset, "UIPanelScrollBarTemplate")
    vSlider:SetPoint("TOPLEFT",    scroll, "TOPRIGHT", 4, -16)
    vSlider:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 16)
    vSlider:SetWidth(16)
    vSlider:SetMinMaxValues(0, 0)
    vSlider:SetValueStep(ROW_H)
    vSlider:SetValue(0)
    vSlider:SetScript("OnValueChanged", function(_, v)
        scroll:SetVerticalScroll(v)
    end)

    -- Horizontal slider on the bottom
    hSlider = CreateFrame("Slider", nil, inset, "OptionsSliderTemplate")
    hSlider:SetOrientation("HORIZONTAL")
    hSlider:SetPoint("TOPLEFT",     scroll, "BOTTOMLEFT", 0, -4)
    hSlider:SetPoint("TOPRIGHT",    scroll, "BOTTOMRIGHT", 0, -4)
    hSlider:SetHeight(16)
    hSlider:SetMinMaxValues(0, 0)
    hSlider:SetValueStep(40)
    hSlider:SetValue(0)
    -- OptionsSliderTemplate ships with Low / High / Text labels; we
    -- don't need them for a positional scrollbar.
    if hSlider.Low  then hSlider.Low:Hide()  end
    if hSlider.High then hSlider.High:Hide() end
    if hSlider.Text then hSlider.Text:Hide() end
    hSlider:SetScript("OnValueChanged", function(_, v)
        scroll:SetHorizontalScroll(v)
    end)

    -- Mouse wheel: V scroll; Shift+Wheel: H scroll. delta = ±1.
    scroll:SetScript("OnMouseWheel", function(_, delta)
        if IsShiftKeyDown() then
            local v = hSlider:GetValue() - delta * 80
            local lo, hi = hSlider:GetMinMaxValues()
            if v < lo then v = lo elseif v > hi then v = hi end
            hSlider:SetValue(v)
        else
            local v = vSlider:GetValue() - delta * (ROW_H * 3)
            local lo, hi = vSlider:GetMinMaxValues()
            if v < lo then v = lo elseif v > hi then v = hi end
            vSlider:SetValue(v)
        end
    end)

    -- Resize handle (bottom-right corner)
    local resize = CreateFrame("Button", nil, frame)
    resize:SetSize(16, 16)
    resize:SetPoint("BOTTOMRIGHT", -4, 4)
    resize:EnableMouse(true)
    resize:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    resize:SetPushedTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Down")
    resize:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            frame:StopMovingOrSizing()
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resize:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then
            frame:StopMovingOrSizing()
            SaveSize(frame)
            UpdateSliderRanges()
        end
    end)

    -- Initial slider range computation (after layout settles)
    scroll:SetScript("OnSizeChanged", function() UpdateSliderRanges() end)
    frame:SetScript("OnSizeChanged", function() UpdateSliderRanges() end)

    table.insert(UISpecialFrames, FRAME_NAME)
    ApplySavedGeometry(frame)
    UpdateSliderRanges()
    frame:Hide()
    return frame
end

-- ============================================================
-- Public API
-- ============================================================

function TOOL.ShowCombatLogEventView()
    local f = CreateFrameOnce()
    EnsureListener()
    EnsureTicker()
    if not f:IsShown() then
        ApplySavedGeometry(f)
        f:Show()
        UpdateSliderRanges()
        Render()
    end
end

function TOOL.HideCombatLogEventView()
    if frame and frame:IsShown() then frame:Hide() end
end

function TOOL.ToggleCombatLogEventView()
    local f = CreateFrameOnce()
    EnsureListener()
    EnsureTicker()
    if f:IsShown() then
        f:Hide()
    else
        ApplySavedGeometry(f)
        f:Show()
        UpdateSliderRanges()
        Render()
    end
end

-- Register into the minimap menu (Core.lua provides RegisterTool).
if TOOL.RegisterTool then
    TOOL.RegisterTool("Combat Log Event View", TOOL.ToggleCombatLogEventView)
end
