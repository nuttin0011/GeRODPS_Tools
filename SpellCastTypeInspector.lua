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
-- Secret value log (Midnight 12.0 taint guard)
-- ใน combat / instance บางค่าจะเป็น secret string ที่อ่าน/process ไม่ได้
-- (ทั้ง :lower(), :find(), comparison ฯลฯ จะ taint).
-- เก็บ secrets ใน log → แสดงใน Secret Viewer frame
-- (FontString:SetText จัดการ secret value ได้ — Blizzard widget)
-- =============================================================
local secretLog = {}   -- array of { spellName, spellID, field, value (secret) }
local ShowSecretViewer  -- forward declaration (defined below)

local function isSecret(v)
    return type(issecretvalue) == "function" and issecretvalue(v) or false
end

local function LogSecret(spellName, spellID, field, value)
    secretLog[#secretLog + 1] = {
        spellName = spellName,
        spellID   = spellID,
        field     = field,
        value     = value,   -- can be secret — only ever passed to FontString:SetText
    }
end

local function ClearSecretLog()
    wipe(secretLog)
end

-- =============================================================
-- ScanTooltipForChannel(spellID, spellName) — secret-safe
-- Returns: "channeled", duration | "instant", 0 | nil
-- Side effect: logs secret tooltip lines via LogSecret
-- =============================================================
local function ScanTooltipForChannel(spellID, spellName)
    local tip = GetScanTip()
    tip:ClearLines()
    -- Re-set owner ทุกครั้งเผื่อ frame ถูก reuse (defensive)
    tip:SetOwner(WorldFrame, "ANCHOR_NONE")

    local ok = pcall(tip.SetSpellByID, tip, spellID)
    if not ok then return nil end

    for i = 1, tip:NumLines() do
        local line = _G["GeRODPS_ToolsSpellCastTypeScanTipTextLeft" .. i]
        if line then
            local text = line:GetText()
            if text then
                -- ⚠ Guard: text อาจเป็น secret string ใน combat/instance
                -- :lower()/:find()/:match() จะ taint ถ้า text เป็น secret
                if isSecret(text) then
                    LogSecret(spellName, spellID,
                        "tooltip line " .. i, text)
                else
                    -- Safe to inspect — ENG keyword match
                    local lower = text:lower()
                    if lower:find("channeled") then
                        local dur = text:match("([%d%.]+)%s*sec")
                                  or text:match("for%s+([%d%.]+)")
                        return "channeled", tonumber(dur)
                    end
                    if lower:find("instant") then
                        return "instant", 0
                    end
                end
            end
        end
    end
    return nil
end

-- =============================================================
-- DetectCastType(spellID, spellName) → { type, duration, source, hadSecret }
-- type: "passive" | "cast" | "channeled" | "instant" | "unknown"
-- secrets ถูก log ไป secretLog แยก (ไม่ inspect ที่นี่)
-- =============================================================
local function DetectCastType(spellID, spellName)
    if not spellID or spellID == 0 then
        return { type = "unknown", duration = 0, source = "none", hadSecret = false }
    end

    local hadSecret = false

    -- Layer 1: Passive
    if C_Spell and C_Spell.IsSpellPassive then
        local pOK, p = pcall(C_Spell.IsSpellPassive, spellID)
        if pOK then
            if isSecret(p) then
                LogSecret(spellName, spellID, "IsSpellPassive", p)
                hadSecret = true
                -- fall through to next layer (assume not passive)
            elseif p then
                return { type = "passive", duration = 0, source = "api",
                         hadSecret = hadSecret }
            end
        end
    end

    -- Layer 2: castTime via API
    local castMs = 0
    if C_Spell and C_Spell.GetSpellInfo then
        local iOK, info = pcall(C_Spell.GetSpellInfo, spellID)
        if iOK and info then
            local ct = info.castTime
            if ct ~= nil then
                if isSecret(ct) then
                    LogSecret(spellName, spellID, "GetSpellInfo.castTime", ct)
                    hadSecret = true
                else
                    castMs = ct
                end
            end
        end
    end

    if castMs > 0 then
        return { type = "cast", duration = castMs / 1000, source = "api",
                 hadSecret = hadSecret }
    end

    -- Layer 3: Tooltip scan (could be channeled OR instant)
    local scanType, scanDur = ScanTooltipForChannel(spellID, spellName)
    if scanType == "channeled" then
        return { type = "channeled", duration = scanDur or 0, source = "tooltip",
                 hadSecret = hadSecret }
    end

    -- Layer 4: Default instant (castTime=0 ไม่ใช่ passive, ไม่ใช่ channeled)
    return { type = "instant", duration = 0, source = "default",
             hadSecret = hadSecret }
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
                            if tOK and t and not isSecret(t) then
                                iconID = t
                            end
                        end
                        -- Guard secret name: secret string can't be compared
                        local safeName, secretName
                        if item.name then
                            if isSecret(item.name) then
                                secretName = item.name
                                safeName = "Spell #" .. sid
                                LogSecret("Spell #" .. sid, sid,
                                    "SpellBookItem.name", item.name)
                            else
                                if item.name ~= "" then
                                    safeName = item.name
                                else
                                    safeName = "Spell #" .. sid
                                end
                            end
                        else
                            safeName = "Spell #" .. sid
                        end
                        out[#out + 1] = {
                            id         = sid,
                            name       = safeName,
                            secretName = secretName,
                            iconID     = iconID,
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

    ClearSecretLog()

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

        local det = DetectCastType(sp.id, sp.name)

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

        -- Name: secret-safe via FontString:SetText
        if sp.secretName then
            row.name:SetText(sp.secretName)
        else
            row.name:SetText(sp.name or "?")
        end
        row.id:SetText("|cff888888" .. tostring(sp.id) .. "|r")

        local typeLabel = TYPE_LABEL[det.type] or "?"
        if det.hadSecret or sp.secretName then
            typeLabel = typeLabel .. " |cffff5555<secret>|r"
        end
        local color = TYPE_COLOR[det.type] or "ffffffff"
        row.castType:SetText("|c" .. color .. typeLabel .. "|r")

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
    local secretCount = #secretLog
    local statusText = string.format("%d spells | %d shown | %d changed",
        #spells, #filtered, changedCount)
    if secretCount > 0 then
        statusText = statusText
            .. string.format(" | |cffff5555%d secret|r", secretCount)
    end
    frame.lblCount:SetText(statusText)
    local ts = date("%H:%M:%S")
    frame.lblLastRefresh:SetText("Last refresh: " .. ts)

    -- Update Secret button
    if frame.btnShowSecrets then
        if secretCount > 0 then
            frame.btnShowSecrets:SetText("Show Secrets (" .. secretCount .. ")")
            frame.btnShowSecrets:Enable()
        else
            frame.btnShowSecrets:SetText("Show Secrets (0)")
            frame.btnShowSecrets:Disable()
        end
    end
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
-- Secret Viewer Frame
-- Raw CreateFrame + FontString rows (FontString:SetText is secret-safe).
-- Each entry shows: spell name, spellID, field, value (may be secret).
-- =============================================================
local secretFrame
local secretRowPool = {}
local secretActiveRows = {}

local SECRET_ROW_HEIGHT = 22

local function ReleaseAllSecretRows()
    for i = #secretActiveRows, 1, -1 do
        local row = secretActiveRows[i]
        row:Hide()
        row:ClearAllPoints()
        secretRowPool[#secretRowPool + 1] = row
        secretActiveRows[i] = nil
    end
end

local function CreateSecretRow(parent)
    if #secretRowPool > 0 then
        local r = table.remove(secretRowPool)
        r:Show()
        return r
    end
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetHeight(SECRET_ROW_HEIGHT)
    row:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    })
    row:SetBackdropColor(0.05, 0.02, 0.02, 0.4)

    row.spellName = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.spellName:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.spellName:SetWidth(180)
    row.spellName:SetJustifyH("LEFT")

    row.spellID = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.spellID:SetPoint("LEFT", row.spellName, "RIGHT", 4, 0)
    row.spellID:SetWidth(60)
    row.spellID:SetJustifyH("LEFT")

    row.field = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.field:SetPoint("LEFT", row.spellID, "RIGHT", 4, 0)
    row.field:SetWidth(180)
    row.field:SetJustifyH("LEFT")

    row.value = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.value:SetPoint("LEFT", row.field, "RIGHT", 4, 0)
    row.value:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.value:SetJustifyH("LEFT")
    row.value:SetWordWrap(false)

    return row
end

local function AcquireSecretRow(parent)
    return CreateSecretRow(parent)
end

local function RefreshSecretList()
    if not secretFrame or not secretFrame:IsShown() then return end

    ReleaseAllSecretRows()

    for idx, entry in ipairs(secretLog) do
        local row = AcquireSecretRow(secretFrame.scrollChild)
        if idx == 1 then
            row:SetPoint("TOPLEFT", secretFrame.scrollChild, "TOPLEFT", 4, -4)
        else
            row:SetPoint("TOPLEFT", secretActiveRows[idx - 1],
                "BOTTOMLEFT", 0, -1)
        end
        row:SetWidth(secretFrame.scrollChild:GetWidth() - 8)

        -- Spell name (string — safe)
        row.spellName:SetText(entry.spellName or "?")
        row.spellID:SetText("|cff888888#" .. tostring(entry.spellID) .. "|r")
        row.field:SetText("|cffffd200" .. (entry.field or "?") .. "|r")

        -- Value: may be secret. FontString:SetText is secret-safe.
        -- Concat via .. is allowed; result string stays tainted but
        -- FontString accepts it without throwing.
        row.value:SetText("= " .. entry.value)

        secretActiveRows[idx] = row
    end

    local totalH = #secretActiveRows * (SECRET_ROW_HEIGHT + 1) + 8
    secretFrame.scrollChild:SetHeight(
        math.max(totalH, secretFrame.scrollOuter:GetHeight()))

    secretFrame.lblCount:SetText(
        string.format("|cffff5555%d secret values logged|r", #secretLog))
end

local function CreateSecretViewerFrame()
    if secretFrame then return secretFrame end

    secretFrame = CreateFrame("Frame", "GeRODPS_ToolsSpellCastTypeSecrets",
        UIParent, "BackdropTemplate")
    secretFrame:SetSize(820, 460)
    secretFrame:SetPoint("CENTER", UIParent, "CENTER", 30, -30)
    secretFrame:SetBackdrop({
        bgFile   = "Interface/DialogFrame/UI-DialogBox-Background-Dark",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left=11, right=12, top=12, bottom=11 },
    })
    secretFrame:SetBackdropColor(0, 0, 0, 0.95)
    secretFrame:SetFrameStrata("DIALOG")
    secretFrame:SetMovable(true)
    secretFrame:EnableMouse(true)
    secretFrame:RegisterForDrag("LeftButton")
    secretFrame:SetScript("OnDragStart", secretFrame.StartMoving)
    secretFrame:SetScript("OnDragStop",  secretFrame.StopMovingOrSizing)
    secretFrame:Hide()

    local title = secretFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", secretFrame, "TOP", 0, -16)
    title:SetText("|cffff8855Secret Values|r — fields tainted by secret-value system")

    local close = CreateFrame("Button", nil, secretFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", secretFrame, "TOPRIGHT", -6, -6)

    -- Header
    local header = CreateFrame("Frame", nil, secretFrame, "BackdropTemplate")
    header:SetPoint("TOPLEFT",  secretFrame, "TOPLEFT",  16, -46)
    header:SetPoint("TOPRIGHT", secretFrame, "TOPRIGHT", -36, -46)
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
    makeHeaderText(header, "Spell",      6,   180)
    makeHeaderText(header, "ID",         190, 60)
    makeHeaderText(header, "Field",      254, 180)
    makeHeaderText(header, "Value",      438, 320)

    -- Scroll
    local scrollOuter = CreateFrame("ScrollFrame", nil, secretFrame, "UIPanelScrollFrameTemplate")
    scrollOuter:SetPoint("TOPLEFT",  header, "BOTTOMLEFT",  0, -4)
    scrollOuter:SetPoint("BOTTOMRIGHT", secretFrame, "BOTTOMRIGHT", -32, 36)

    local scrollChild = CreateFrame("Frame", nil, scrollOuter)
    scrollChild:SetSize(scrollOuter:GetWidth() - 4, 1)
    scrollOuter:SetScrollChild(scrollChild)

    secretFrame.scrollOuter = scrollOuter
    secretFrame.scrollChild = scrollChild

    -- Status
    local lblCount = secretFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lblCount:SetPoint("BOTTOMLEFT", secretFrame, "BOTTOMLEFT", 16, 14)
    lblCount:SetText("0 secret values logged")
    secretFrame.lblCount = lblCount

    return secretFrame
end

-- Assign forward-declared local (closes the upvalue from the OnClick handler)
ShowSecretViewer = function()
    CreateSecretViewerFrame()
    secretFrame:Show()
    RefreshSecretList()
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

    -- Show Secrets button (right side)
    local btnShowSecrets = CreateFrame("Button", nil, controls, "UIPanelButtonTemplate")
    btnShowSecrets:SetSize(140, 22)
    btnShowSecrets:SetPoint("RIGHT", controls, "RIGHT", 0, 0)
    btnShowSecrets:SetText("Show Secrets (0)")
    btnShowSecrets:Disable()
    btnShowSecrets:SetScript("OnClick", function()
        ShowSecretViewer()
    end)
    frame.btnShowSecrets = btnShowSecrets

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
