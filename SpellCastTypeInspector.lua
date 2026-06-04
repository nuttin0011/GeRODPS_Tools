--[[
    SpellCastTypeInspector.lua

    Tool ทดสอบ Cast Type detection ของ spell ใน Spell Book ก่อน implement
    เข้า project จริง.

    Features:
      - List ทุก spell ใน Spell Book (active spells + passives)
      - แสดง: Icon | Name | SpellID | Cast Type | Duration
      - Cast Type:
          • Passive       (via C_Spell.IsSpellPassive)
          • Cast (X sec)  (via C_Spell.GetSpellInfo.castTime > 0)
          • Channeled     (via tooltip scan "Channeled")
          • Instant       (default fallback when castTime=0 ไม่ใช่ channeled)
      - Duration: cast time (sec) สำหรับ cast, parsed sec จาก tooltip สำหรับ channeled
      - Refresh Now button — recompute ทั้งหมด
      - Auto-Refresh 0.5s toggle — สำหรับ test buff ที่เปลี่ยน cast type
        (เช่น Hot Streak ทำให้ Pyroblast cast 4s → instant)
      - Filter input — กรองรายชื่อ
      - Change highlight — row ที่ cast type เปลี่ยนตั้งแต่ refresh ก่อน
        จะ highlight green 2 sec

    Public:
      GeRODPS_Tools.ToggleSpellCastTypeInspector()

    See: planHTML/skill_cast_type_detection.html
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME = "GeRODPS_ToolsSpellCastTypeInspector"
local DEFAULT_W, DEFAULT_H = 720, 600
local MIN_W, MIN_H = 600, 400
local MAX_W, MAX_H = 1400, 1000

local ROW_HEIGHT  = 22
local AUTO_REFRESH_INTERVAL = 0.5

-- =============================================================
-- DB helpers (persist window geometry + auto-refresh state)
-- =============================================================
local function GetDB()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    GeRODPS_ToolsDB.SpellCastTypeInspector =
        GeRODPS_ToolsDB.SpellCastTypeInspector or {}
    return GeRODPS_ToolsDB.SpellCastTypeInspector
end

-- =============================================================
-- Scanning tooltip (hidden — never shown to user)
-- =============================================================
local scanTip
local function GetScanTip()
    if scanTip then return scanTip end
    scanTip = CreateFrame("GameTooltip",
        "GeRODPS_ToolsSpellCastTypeScanTip", nil, "GameTooltipTemplate")
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    return scanTip
end

-- =============================================================
-- ScanTooltipForChannel(spellID) — returns "channeled", duration | "instant", 0 | nil
-- Locale-sensitive: scans for "Channeled" / "Instant" English keywords.
-- For Thai client, may need locale table (TODO if needed).
-- =============================================================
local function ScanTooltipForChannel(spellID)
    local tip = GetScanTip()
    tip:ClearLines()
    -- Re-set owner ทุกครั้งเผื่อ frame ถูก reuse (defensive)
    tip:SetOwner(WorldFrame, "ANCHOR_NONE")

    local ok = pcall(tip.SetSpellByID, tip, spellID)
    if not ok then return nil end

    for i = 1, tip:NumLines() do
        local line = _G["GeRODPS_ToolsSpellCastTypeScanTipTextLeft" .. i]
        if line then
            local text = line:GetText() or ""
            -- ⚠ ENG keyword. For TH client: add localized matchers later.
            local lower = text:lower()

            if lower:find("channeled") then
                -- Try to extract duration — common patterns:
                --   "Channels for X sec"
                --   "over X sec"  (e.g., Eye Beam "16,823 damage over 2.2 sec")
                --   "for X sec"
                local dur = text:match("([%d%.]+)%s*sec")
                          or text:match("for%s+([%d%.]+)")
                return "channeled", tonumber(dur)
            end
            if lower:find("instant") then
                return "instant", 0
            end
        end
    end
    return nil
end

-- =============================================================
-- DetectCastType(spellID) → { type = "passive"|"cast"|"channeled"|"instant",
--                              duration = number (sec), source = "api"|"tooltip" }
-- =============================================================
local function DetectCastType(spellID)
    if not spellID or spellID == 0 then
        return { type = "unknown", duration = 0, source = "none" }
    end

    -- Layer 1: Passive
    if C_Spell and C_Spell.IsSpellPassive then
        local pOK, p = pcall(C_Spell.IsSpellPassive, spellID)
        if pOK and p then
            return { type = "passive", duration = 0, source = "api" }
        end
    end

    -- Layer 2: castTime via API
    local castMs = 0
    if C_Spell and C_Spell.GetSpellInfo then
        local iOK, info = pcall(C_Spell.GetSpellInfo, spellID)
        if iOK and info and info.castTime then
            castMs = info.castTime
        end
    end

    if castMs > 0 then
        return { type = "cast", duration = castMs / 1000, source = "api" }
    end

    -- Layer 3: Tooltip scan (could be channeled OR instant)
    local scanType, scanDur = ScanTooltipForChannel(spellID)
    if scanType == "channeled" then
        return { type = "channeled", duration = scanDur or 0, source = "tooltip" }
    end

    -- Layer 4: Default instant (castTime=0 ไม่ใช่ passive, ไม่ใช่ channeled)
    return { type = "instant", duration = 0, source = "default" }
end

-- =============================================================
-- CollectAllSpells() — iterate spell book → array of { id, name, iconID }
-- รวม passives (เพื่อ user เห็นใน list)
-- =============================================================
local function CollectAllSpells()
    local out = {}
    local seen = {}

    if not C_SpellBook or not C_SpellBook.GetNumSpellBookSkillLines then
        return out
    end

    local playerBank = (Enum and Enum.SpellBookSpellBank
                       and Enum.SpellBookSpellBank.Player) or 0
    local spellEnum = (Enum and Enum.SpellBookItemType
                      and Enum.SpellBookItemType.Spell) or 1

    local linesOK, lines = pcall(C_SpellBook.GetNumSpellBookSkillLines)
    if not linesOK or not lines or lines == 0 then return out end

    for lineIdx = 1, lines do
        local skOK, info = pcall(C_SpellBook.GetSpellBookSkillLineInfo, lineIdx)
        if skOK and info and info.numSpellBookItems
           and info.numSpellBookItems > 0 then
            local baseOffset = info.itemIndexOffset or 0
            for i = baseOffset + 1, baseOffset + info.numSpellBookItems do
                local itemOK, item = pcall(
                    C_SpellBook.GetSpellBookItemInfo, i, playerBank)
                if itemOK and item and item.spellID
                   and (item.itemType == nil or item.itemType == spellEnum) then
                    local sid = item.spellID
                    if not seen[sid] then
                        seen[sid] = true
                        local iconID
                        if C_Spell and C_Spell.GetSpellTexture then
                            local tOK, t = pcall(C_Spell.GetSpellTexture, sid)
                            iconID = tOK and t or nil
                        end
                        out[#out + 1] = {
                            id   = sid,
                            name = (item.name and item.name ~= "")
                                   and item.name or ("Spell #" .. sid),
                            iconID = iconID,
                        }
                    end
                end
            end
        end
    end

    -- Sort by name (case-insensitive)
    table.sort(out, function(a, b)
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)

    return out
end

-- =============================================================
-- Type → color/label
-- =============================================================
local TYPE_LABEL = {
    passive   = "Passive",
    cast      = "Cast",
    channeled = "Channeled",
    instant   = "Instant",
    unknown   = "Unknown",
}
local TYPE_COLOR = {
    passive   = "ff8888aa",   -- gray-blue
    cast      = "ffffd200",   -- yellow (warn — has cast time)
    channeled = "ffff8866",   -- orange (longer)
    instant   = "ff66dd66",   -- green (no gate needed)
    unknown   = "ff666666",   -- dark gray
}

-- =============================================================
-- Frame + row state
-- =============================================================
local frame
local rowPool = {}     -- pooled row widgets
local activeRows = {}  -- currently-visible rows
local lastDetections = {}   -- [spellID] = { type, duration } from previous refresh
local autoTimer        -- C_Timer.NewTicker handle

-- =============================================================
-- CreateRow — make a single row widget
-- =============================================================
local function CreateRow(parent)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetSize(680, ROW_HEIGHT)

    -- Hover backdrop
    row:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    })
    row:SetBackdropColor(0, 0, 0, 0)

    -- Icon
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)

    -- Name
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetWidth(260)
    row.name:SetJustifyH("LEFT")

    -- SpellID
    row.id = row:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    row.id:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
    row.id:SetWidth(80)
    row.id:SetJustifyH("LEFT")

    -- Cast Type
    row.castType = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.castType:SetPoint("LEFT", row.id, "RIGHT", 6, 0)
    row.castType:SetWidth(100)
    row.castType:SetJustifyH("LEFT")

    -- Duration
    row.duration = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.duration:SetPoint("LEFT", row.castType, "RIGHT", 6, 0)
    row.duration:SetWidth(80)
    row.duration:SetJustifyH("LEFT")

    -- Source (api/tooltip/default)
    row.source = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.source:SetPoint("LEFT", row.duration, "RIGHT", 6, 0)
    row.source:SetWidth(60)
    row.source:SetJustifyH("LEFT")

    -- Hover tooltip: full info
    row:SetScript("OnEnter", function(self)
        if not self.spellID then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetSpellByID(self.spellID)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return row
end

local function AcquireRow(parent)
    local row = table.remove(rowPool)
    if not row then row = CreateRow(parent) end
    row:Show()
    return row
end

local function ReleaseAllRows()
    for _, row in ipairs(activeRows) do
        row:Hide()
        row:ClearAllPoints()
        row.spellID = nil
        row:SetBackdropColor(0, 0, 0, 0)
        rowPool[#rowPool + 1] = row
    end
    wipe(activeRows)
end

-- =============================================================
-- ApplyFilter(text) — return filtered spell list
-- =============================================================
local function ApplyFilter(spells, filterText)
    if not filterText or filterText == "" then return spells end
    local needle = filterText:lower()
    local out = {}
    for _, s in ipairs(spells) do
        if (s.name or ""):lower():find(needle, 1, true)
           or tostring(s.id):find(needle, 1, true) then
            out[#out + 1] = s
        end
    end
    return out
end

-- =============================================================
-- RefreshList — compute + render
-- =============================================================
local function RefreshList()
    if not frame or not frame:IsShown() then return end

    local spells = CollectAllSpells()
    local filtered = ApplyFilter(spells, frame.filterText)

    ReleaseAllRows()

    local changedCount = 0
    local now = GetTime()

    for idx, sp in ipairs(filtered) do
        local row = AcquireRow(frame.scrollChild)
        if idx == 1 then
            row:SetPoint("TOPLEFT", frame.scrollChild, "TOPLEFT", 4, -4)
        else
            row:SetPoint("TOPLEFT", activeRows[idx - 1], "BOTTOMLEFT", 0, -1)
        end
        row:SetWidth(frame.scrollChild:GetWidth() - 8)

        local det = DetectCastType(sp.id)

        -- Detect change from last refresh
        local prev = lastDetections[sp.id]
        if prev and (prev.type ~= det.type or prev.duration ~= det.duration) then
            changedCount = changedCount + 1
            -- Highlight green
            row:SetBackdropColor(0.0, 0.5, 0.0, 0.45)
            row._highlightUntil = now + 2
        end
        lastDetections[sp.id] = { type = det.type, duration = det.duration }

        row.spellID = sp.id
        if sp.iconID then
            row.icon:SetTexture(sp.iconID)
            row.icon:Show()
        else
            row.icon:Hide()
        end
        row.name:SetText(sp.name or "?")
        row.id:SetText("|cff888888" .. tostring(sp.id) .. "|r")

        local color = TYPE_COLOR[det.type] or "ffffffff"
        row.castType:SetText("|c" .. color .. (TYPE_LABEL[det.type] or "?") .. "|r")

        if det.type == "cast" or det.type == "channeled" then
            local d = det.duration or 0
            if d > 0 then
                row.duration:SetText(string.format("%.2f sec", d))
            else
                row.duration:SetText("|cffaaaaaa? sec|r")
            end
        else
            row.duration:SetText("-")
        end

        row.source:SetText("|cff666666" .. (det.source or "") .. "|r")

        activeRows[idx] = row
    end

    -- Resize scroll child
    local totalH = #activeRows * (ROW_HEIGHT + 1) + 8
    frame.scrollChild:SetHeight(math.max(totalH, frame.scrollOuter:GetHeight()))

    -- Update status bar
    frame.lblCount:SetText(string.format("%d spells | %d shown | %d changed",
        #spells, #filtered, changedCount))
    local ts = date("%H:%M:%S")
    frame.lblLastRefresh:SetText("Last refresh: " .. ts)
end

-- =============================================================
-- ClearHighlightTick — fade out green highlights after 2s
-- =============================================================
local function ClearExpiredHighlights()
    local now = GetTime()
    for _, row in ipairs(activeRows) do
        if row._highlightUntil and now >= row._highlightUntil then
            row:SetBackdropColor(0, 0, 0, 0)
            row._highlightUntil = nil
        end
    end
end

-- =============================================================
-- Auto-refresh control
-- =============================================================
local function StartAutoRefresh()
    if autoTimer then autoTimer:Cancel() end
    autoTimer = C_Timer.NewTicker(AUTO_REFRESH_INTERVAL, function()
        if frame and frame:IsShown() then
            RefreshList()
        end
    end)
    GetDB().autoRefresh = true
end

local function StopAutoRefresh()
    if autoTimer then
        autoTimer:Cancel()
        autoTimer = nil
    end
    GetDB().autoRefresh = false
end

-- =============================================================
-- Build frame
-- =============================================================
local function CreateInspectorFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BackdropTemplate")
    frame:SetSize(DEFAULT_W, DEFAULT_H)
    frame:SetPoint("CENTER")
    frame:SetBackdrop({
        bgFile = "Interface/DialogFrame/UI-DialogBox-Background-Dark",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left=11, right=12, top=12, bottom=11 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.95)
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    end
    frame:EnableMouse(true)
    frame:SetFrameStrata("DIALOG")
    frame:Hide()

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", frame, "TOP", 0, -16)
    title:SetText("Spell Book Cast Type Inspector")

    -- Drag bar
    local dragBar = CreateFrame("Frame", nil, frame)
    dragBar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  10, -10)
    dragBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -10)
    dragBar:SetHeight(30)
    dragBar:EnableMouse(true)
    dragBar:RegisterForDrag("LeftButton")
    dragBar:SetScript("OnDragStart", function() frame:StartMoving() end)
    dragBar:SetScript("OnDragStop",  function()
        frame:StopMovingOrSizing()
        local p, _, rp, x, y = frame:GetPoint(1)
        local db = GetDB()
        db.point, db.rel, db.x, db.y = p, rp, x, y
    end)

    -- Close button
    local btnClose = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    btnClose:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    btnClose:SetScript("OnClick", function() frame:Hide() end)

    -- Resize handle
    local resize = CreateFrame("Button", nil, frame)
    resize:SetSize(20, 20)
    resize:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 6)
    resize:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    resize:SetPushedTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Down")
    resize:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    resize:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    resize:SetScript("OnMouseUp",   function()
        frame:StopMovingOrSizing()
        local db = GetDB()
        db.w, db.h = frame:GetWidth(), frame:GetHeight()
        -- Reflow rows to new width
        RefreshList()
    end)

    -- Top control bar
    local controls = CreateFrame("Frame", nil, frame)
    controls:SetPoint("TOPLEFT",  frame, "TOPLEFT",  16, -50)
    controls:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -36, -50)
    controls:SetHeight(28)

    local btnRefresh = CreateFrame("Button", nil, controls, "UIPanelButtonTemplate")
    btnRefresh:SetSize(110, 22)
    btnRefresh:SetPoint("LEFT", controls, "LEFT", 0, 0)
    btnRefresh:SetText("Refresh Now")
    btnRefresh:SetScript("OnClick", RefreshList)

    -- Auto-refresh toggle button
    local btnAuto = CreateFrame("Button", nil, controls, "UIPanelButtonTemplate")
    btnAuto:SetSize(160, 22)
    btnAuto:SetPoint("LEFT", btnRefresh, "RIGHT", 6, 0)
    local function updateAutoBtnText()
        if autoTimer then
            btnAuto:SetText("|cff66ff66Auto 0.5s: ON|r — click to stop")
        else
            btnAuto:SetText("Auto 0.5s: OFF")
        end
    end
    btnAuto:SetScript("OnClick", function()
        if autoTimer then
            StopAutoRefresh()
        else
            StartAutoRefresh()
        end
        updateAutoBtnText()
    end)
    updateAutoBtnText()

    -- Filter input
    local lblFilter = controls:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lblFilter:SetPoint("LEFT", btnAuto, "RIGHT", 12, 0)
    lblFilter:SetText("Filter:")

    local filterBox = CreateFrame("EditBox", nil, controls, "InputBoxTemplate")
    filterBox:SetSize(180, 20)
    filterBox:SetPoint("LEFT", lblFilter, "RIGHT", 8, 0)
    filterBox:SetMaxBytes(64)
    filterBox:SetAutoFocus(false)
    filterBox:SetScript("OnTextChanged", function(self)
        frame.filterText = self:GetText() or ""
        RefreshList()
    end)
    filterBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Header row
    local header = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    header:SetPoint("TOPLEFT",  controls, "BOTTOMLEFT",  0, -4)
    header:SetPoint("TOPRIGHT", controls, "BOTTOMRIGHT", 0, -4)
    header:SetHeight(20)
    header:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    })
    header:SetBackdropColor(0.15, 0.10, 0.04, 0.9)

    local function makeHeaderText(parent, text, x, w)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", parent, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH("LEFT")
        fs:SetText("|cffffd200" .. text .. "|r")
        return fs
    end
    makeHeaderText(header, "Icon",     4,                       24)
    makeHeaderText(header, "Spell",    4 + 24 + 6,              260)
    makeHeaderText(header, "SpellID",  4 + 24 + 6 + 260 + 6,    80)
    makeHeaderText(header, "Type",     4 + 24 + 6 + 260 + 6 + 80 + 6, 100)
    makeHeaderText(header, "Duration", 4 + 24 + 6 + 260 + 6 + 80 + 6 + 100 + 6, 80)
    makeHeaderText(header, "Src",      4 + 24 + 6 + 260 + 6 + 80 + 6 + 100 + 6 + 80 + 6, 60)

    -- Scroll area
    local scrollOuter = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scrollOuter:SetPoint("TOPLEFT",     header,      "BOTTOMLEFT",     0, -2)
    scrollOuter:SetPoint("BOTTOMRIGHT", frame,       "BOTTOMRIGHT",   -36, 36)
    frame.scrollOuter = scrollOuter

    local scrollChild = CreateFrame("Frame", nil, scrollOuter)
    scrollChild:SetSize(680, 1)
    scrollOuter:SetScrollChild(scrollChild)
    frame.scrollChild = scrollChild

    -- Status bar
    local statusBar = CreateFrame("Frame", nil, frame)
    statusBar:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  16, 14)
    statusBar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -36, 14)
    statusBar:SetHeight(18)

    frame.lblCount = statusBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.lblCount:SetPoint("LEFT", statusBar, "LEFT", 0, 0)
    frame.lblCount:SetText("0 spells")

    frame.lblLastRefresh = statusBar:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    frame.lblLastRefresh:SetPoint("RIGHT", statusBar, "RIGHT", 0, 0)
    frame.lblLastRefresh:SetText("Last refresh: -")

    frame.filterText = ""
    frame._filterBox = filterBox

    -- OnUpdate — clear expired highlights (cheap; only when frame shown)
    frame:SetScript("OnUpdate", function()
        if #activeRows > 0 then ClearExpiredHighlights() end
    end)

    -- Stop auto-timer ตอน frame ปิด
    frame:SetScript("OnHide", StopAutoRefresh)

    -- Restore geometry
    local db = GetDB()
    if db.w and db.h then frame:SetSize(db.w, db.h) end
    if db.point and db.rel then
        frame:ClearAllPoints()
        frame:SetPoint(db.point, UIParent, db.rel, db.x or 0, db.y or 0)
    end

    return frame
end

-- =============================================================
-- Public API
-- =============================================================
function TOOL.ToggleSpellCastTypeInspector()
    local f = CreateInspectorFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        RefreshList()
        -- Resume auto-refresh ถ้า user เคยเปิด
        if GetDB().autoRefresh then
            StartAutoRefresh()
        end
    end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("Spell Cast Type Inspector", TOOL.ToggleSpellCastTypeInspector)
end
