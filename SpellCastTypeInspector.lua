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
local ShowSecretViewer    -- forward declaration (defined below)
local ShowTooltipDetail   -- forward declaration (defined below)

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

                    -- Guard secret spellID — if secret we can't safely use it
                    -- as table key (taint propagates through comparisons later).
                    local sidSecret = isSecret(sid)
                    if sidSecret then
                        LogSecret("(unknown)", 0, "SpellBookItem.spellID", sid)
                    end

                    if not sidSecret and not seen[sid] then
                        seen[sid] = true

                        local iconID
                        if C_Spell and C_Spell.GetSpellTexture then
                            local tOK, t = pcall(C_Spell.GetSpellTexture, sid)
                            if tOK and t then
                                if isSecret(t) then
                                    LogSecret("Spell #" .. sid, sid,
                                        "GetSpellTexture", t)
                                else
                                    iconID = t
                                end
                            end
                        end

                        -- Guard secret name: secret string can't be compared
                        local safeName, hasSecretName
                        if item.name then
                            if isSecret(item.name) then
                                hasSecretName = true
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
                            id            = sid,
                            name          = safeName,
                            hasSecretName = hasSecretName,
                            iconID        = iconID,
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

    -- Read Tooltip button — scans current spell's tooltip and shows per-line
    -- secret state in a popup (so user can verify which spells have secret
    -- tooltips vs just some).
    row.readBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.readBtn:SetSize(56, 18)
    row.readBtn:SetPoint("LEFT", row.source, "RIGHT", 6, 0)
    row.readBtn:SetText("Read TT")
    row.readBtn:SetScript("OnClick", function(self)
        if not row.spellID then return end
        ShowTooltipDetail(row.spellID, row.spellName or ("Spell #" .. row.spellID))
    end)

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
        row.spellName = nil
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
        row.spellName = sp.name  -- always non-secret (safeName from CollectAllSpells)
        if sp.iconID then
            row.icon:SetTexture(sp.iconID)
            row.icon:Show()
        else
            row.icon:Hide()
        end

        -- Name: placeholder only — never put secret content in scroll row
        -- (FontString:SetText accepts secret, but the FontString's measured
        -- dimensions then propagate taint to parent ScrollFrame.)
        if sp.hasSecretName then
            row.name:SetText("|cffff8855<secret name>|r")
        else
            row.name:SetText(sp.name or "?")
        end
        row.id:SetText("|cff888888" .. tostring(sp.id) .. "|r")

        local typeLabel = TYPE_LABEL[det.type] or "?"
        if det.hadSecret or sp.hasSecretName then
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

-- Clamp scroll to valid range and reposition content
local function ApplySecretScroll()
    if not secretFrame or not secretFrame.content then return end
    local viewH = secretFrame.viewport:GetHeight()
    local contentH = secretFrame.content:GetHeight()
    local maxScroll = math.max(0, contentH - viewH)
    local s = secretFrame.scrollY or 0
    if s < 0 then s = 0 end
    if s > maxScroll then s = maxScroll end
    secretFrame.scrollY = s
    secretFrame.content:ClearAllPoints()
    secretFrame.content:SetPoint("TOPLEFT", secretFrame.viewport,
        "TOPLEFT", 0, s)
end

local function RefreshSecretList()
    if not secretFrame or not secretFrame:IsShown() then return end

    ReleaseAllSecretRows()

    -- Build summary: count secret fields per spell
    local perSpell = {}
    local order = {}
    for _, entry in ipairs(secretLog) do
        local key = tostring(entry.spellID) .. "|" .. (entry.spellName or "?")
        local agg = perSpell[key]
        if not agg then
            agg = { spellName = entry.spellName, spellID = entry.spellID,
                    count = 0 }
            perSpell[key] = agg
            order[#order + 1] = key
        end
        agg.count = agg.count + 1
    end

    local rowIdx = 0
    local contentW = secretFrame.content:GetWidth() - 8

    -- ----- Section: per-spell summary header -----
    if #order > 0 then
        for _, key in ipairs(order) do
            local agg = perSpell[key]
            rowIdx = rowIdx + 1
            local row = AcquireSecretRow(secretFrame.content)
            if rowIdx == 1 then
                row:SetPoint("TOPLEFT", secretFrame.content, "TOPLEFT", 4, -4)
            else
                row:SetPoint("TOPLEFT", secretActiveRows[rowIdx - 1],
                    "BOTTOMLEFT", 0, -1)
            end
            row:SetWidth(contentW)
            row:SetBackdropColor(0.20, 0.10, 0.04, 0.6)  -- header tint

            row.spellName:SetText("|cffffd200" .. (agg.spellName or "?") .. "|r")
            row.spellID:SetText("|cff888888#" .. tostring(agg.spellID) .. "|r")
            row.field:SetText("|cff66ddff[summary]|r")
            row.value:SetText(
                "|cffff8855" .. agg.count .. " secret field(s)|r")
            secretActiveRows[rowIdx] = row
        end

        -- Divider row
        rowIdx = rowIdx + 1
        local divRow = AcquireSecretRow(secretFrame.content)
        divRow:SetPoint("TOPLEFT", secretActiveRows[rowIdx - 1],
            "BOTTOMLEFT", 0, -1)
        divRow:SetWidth(contentW)
        divRow:SetBackdropColor(0.05, 0.05, 0.05, 0.9)
        divRow.spellName:SetText("|cff66ddffDetail|r")
        divRow.spellID:SetText("")
        divRow.field:SetText("")
        divRow.value:SetText("")
        secretActiveRows[rowIdx] = divRow
    end

    -- ----- Section: detailed entries -----
    for _, entry in ipairs(secretLog) do
        rowIdx = rowIdx + 1
        local row = AcquireSecretRow(secretFrame.content)
        if rowIdx == 1 then
            row:SetPoint("TOPLEFT", secretFrame.content, "TOPLEFT", 4, -4)
        else
            row:SetPoint("TOPLEFT", secretActiveRows[rowIdx - 1],
                "BOTTOMLEFT", 0, -1)
        end
        row:SetWidth(contentW)
        row:SetBackdropColor(0.05, 0.02, 0.02, 0.4)

        row.spellName:SetText(entry.spellName or "?")
        row.spellID:SetText("|cff888888#" .. tostring(entry.spellID) .. "|r")
        row.field:SetText("|cffffd200" .. (entry.field or "?") .. "|r")

        -- Value: may be secret. FontString:SetText is secret-safe.
        -- Concat via .. is allowed; result string stays tainted but
        -- FontString accepts it without throwing.
        row.value:SetText("= " .. entry.value)

        secretActiveRows[rowIdx] = row
    end

    -- Set content height (non-secret math)
    local totalH = rowIdx * (SECRET_ROW_HEIGHT + 1) + 8
    secretFrame.content:SetHeight(totalH)

    ApplySecretScroll()

    secretFrame.lblCount:SetText(string.format(
        "|cffff5555%d secret values logged|r  |cff888888(across %d spells)|r",
        #secretLog, #order))
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

    -- Manual scroll viewport (NOT UIPanelScrollFrameTemplate — that template
    -- runs Blizzard SecureScrollTemplates which does numeric conversion on
    -- child dimensions. If any child FontString shows a secret string, the
    -- child's measured size becomes tainted → Blizzard throws on tonumber().)
    local viewport = CreateFrame("Frame", nil, secretFrame, "BackdropTemplate")
    viewport:SetPoint("TOPLEFT",  header, "BOTTOMLEFT", 0, -4)
    viewport:SetPoint("BOTTOMRIGHT", secretFrame, "BOTTOMRIGHT", -16, 36)
    viewport:SetClipsChildren(true)
    viewport:EnableMouseWheel(true)
    viewport:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    })
    viewport:SetBackdropColor(0, 0, 0, 0.3)

    -- Content frame is the "moving" inner frame; its height = sum of rows.
    -- We slide it up/down via SetPoint y-offset on mouse wheel.
    -- Fixed width derived from secretFrame size (avoids first-call zero width).
    local content = CreateFrame("Frame", nil, viewport)
    content:SetPoint("TOPLEFT", viewport, "TOPLEFT", 0, 0)
    content:SetWidth(secretFrame:GetWidth() - 32)
    content:SetHeight(1)

    secretFrame.viewport = viewport
    secretFrame.content  = content
    secretFrame.scrollY  = 0

    viewport:SetScript("OnMouseWheel", function(_, delta)
        secretFrame.scrollY = (secretFrame.scrollY or 0) - delta * 30
        ApplySecretScroll()
    end)
    viewport:SetScript("OnSizeChanged", function(_, w)
        content:SetWidth(w)
    end)

    -- Status
    local lblCount = secretFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lblCount:SetPoint("BOTTOMLEFT", secretFrame, "BOTTOMLEFT", 16, 14)
    lblCount:SetText("0 secret values logged")
    secretFrame.lblCount = lblCount

    -- Hint (mouse wheel to scroll)
    local hint = secretFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMRIGHT", secretFrame, "BOTTOMRIGHT", -16, 14)
    hint:SetText("|cff666666scroll with mouse wheel|r")

    return secretFrame
end

-- Assign forward-declared local (closes the upvalue from the OnClick handler)
ShowSecretViewer = function()
    CreateSecretViewerFrame()
    secretFrame:Show()
    RefreshSecretList()
end

-- =============================================================
-- Tooltip Detail Popup — per-spell tooltip line inspector
-- Lets user verify which tooltip lines are secret for a specific spell.
-- Uses manual-scroll Frame (not UIPanelScrollFrameTemplate) to keep secret
-- content isolated from Blizzard SecureScrollTemplates.
-- =============================================================
local ttDetailFrame
local ttDetailScanTip  -- second hidden tooltip; separate from ScanTooltipForChannel
local ttRowPool = {}
local ttActiveRows = {}
local TT_ROW_HEIGHT = 22

local function GetTTDetailScanTip()
    if not ttDetailScanTip then
        ttDetailScanTip = CreateFrame("GameTooltip",
            "GeRODPS_ToolsSpellTTDetailScanTip", UIParent, "GameTooltipTemplate")
        ttDetailScanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    end
    return ttDetailScanTip
end

local function ReleaseAllTTRows()
    for i = #ttActiveRows, 1, -1 do
        local r = ttActiveRows[i]
        r:Hide()
        r:ClearAllPoints()
        ttRowPool[#ttRowPool + 1] = r
        ttActiveRows[i] = nil
    end
end

local function CreateTTRow(parent)
    if #ttRowPool > 0 then
        local r = table.remove(ttRowPool)
        r:Show()
        return r
    end
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetHeight(TT_ROW_HEIGHT)
    row:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    })

    row.lineNo = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.lineNo:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.lineNo:SetWidth(40)
    row.lineNo:SetJustifyH("LEFT")

    row.tag = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.tag:SetPoint("LEFT", row.lineNo, "RIGHT", 4, 0)
    row.tag:SetWidth(80)
    row.tag:SetJustifyH("LEFT")

    row.content = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.content:SetPoint("LEFT", row.tag, "RIGHT", 4, 0)
    row.content:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.content:SetJustifyH("LEFT")
    row.content:SetWordWrap(false)

    return row
end

local function ApplyTTScroll()
    if not ttDetailFrame or not ttDetailFrame.content then return end
    local viewH = ttDetailFrame.viewport:GetHeight()
    local contentH = ttDetailFrame.content:GetHeight()
    local maxScroll = math.max(0, contentH - viewH)
    local s = ttDetailFrame.scrollY or 0
    if s < 0 then s = 0 end
    if s > maxScroll then s = maxScroll end
    ttDetailFrame.scrollY = s
    ttDetailFrame.content:ClearAllPoints()
    ttDetailFrame.content:SetPoint("TOPLEFT", ttDetailFrame.viewport,
        "TOPLEFT", 0, s)
end

local function CreateTooltipDetailFrame()
    if ttDetailFrame then return ttDetailFrame end

    ttDetailFrame = CreateFrame("Frame", "GeRODPS_ToolsSpellTTDetail",
        UIParent, "BackdropTemplate")
    ttDetailFrame:SetSize(720, 420)
    ttDetailFrame:SetPoint("CENTER", UIParent, "CENTER", -40, 40)
    ttDetailFrame:SetBackdrop({
        bgFile   = "Interface/DialogFrame/UI-DialogBox-Background-Dark",
        edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left=11, right=12, top=12, bottom=11 },
    })
    ttDetailFrame:SetBackdropColor(0, 0, 0, 0.95)
    ttDetailFrame:SetFrameStrata("DIALOG")
    ttDetailFrame:SetMovable(true)
    ttDetailFrame:EnableMouse(true)
    ttDetailFrame:RegisterForDrag("LeftButton")
    ttDetailFrame:SetScript("OnDragStart", ttDetailFrame.StartMoving)
    ttDetailFrame:SetScript("OnDragStop",  ttDetailFrame.StopMovingOrSizing)
    ttDetailFrame:Hide()

    local title = ttDetailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", ttDetailFrame, "TOP", 0, -16)
    title:SetText("Tooltip Detail")
    ttDetailFrame.title = title

    local subtitle = ttDetailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -2)
    subtitle:SetText("|cff888888each line of the spell's tooltip + secret flag|r")
    ttDetailFrame.subtitle = subtitle

    local close = CreateFrame("Button", nil, ttDetailFrame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", ttDetailFrame, "TOPRIGHT", -6, -6)

    -- Header columns
    local header = CreateFrame("Frame", nil, ttDetailFrame, "BackdropTemplate")
    header:SetPoint("TOPLEFT",  ttDetailFrame, "TOPLEFT",  16, -62)
    header:SetPoint("TOPRIGHT", ttDetailFrame, "TOPRIGHT", -16, -62)
    header:SetHeight(20)
    header:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background" })
    header:SetBackdropColor(0.15, 0.10, 0.04, 0.9)

    local function makeHeaderText(parent, text, x, w)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", parent, "LEFT", x, 0)
        fs:SetWidth(w)
        fs:SetJustifyH("LEFT")
        fs:SetText("|cffffd200" .. text .. "|r")
    end
    makeHeaderText(header, "Line", 6, 40)
    makeHeaderText(header, "Tag", 50, 80)
    makeHeaderText(header, "Content", 134, 540)

    -- Viewport + content (manual scroll)
    local viewport = CreateFrame("Frame", nil, ttDetailFrame, "BackdropTemplate")
    viewport:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    viewport:SetPoint("BOTTOMRIGHT", ttDetailFrame, "BOTTOMRIGHT", -16, 36)
    viewport:SetClipsChildren(true)
    viewport:EnableMouseWheel(true)
    viewport:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
    })
    viewport:SetBackdropColor(0, 0, 0, 0.3)

    local content = CreateFrame("Frame", nil, viewport)
    content:SetPoint("TOPLEFT", viewport, "TOPLEFT", 0, 0)
    content:SetWidth(ttDetailFrame:GetWidth() - 32)
    content:SetHeight(1)

    ttDetailFrame.viewport = viewport
    ttDetailFrame.content  = content
    ttDetailFrame.scrollY  = 0

    viewport:SetScript("OnMouseWheel", function(_, delta)
        ttDetailFrame.scrollY = (ttDetailFrame.scrollY or 0) - delta * 30
        ApplyTTScroll()
    end)

    -- Status bar
    local lblStatus = ttDetailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lblStatus:SetPoint("BOTTOMLEFT", ttDetailFrame, "BOTTOMLEFT", 16, 14)
    lblStatus:SetText("0 lines")
    ttDetailFrame.lblStatus = lblStatus

    local hint = ttDetailFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMRIGHT", ttDetailFrame, "BOTTOMRIGHT", -16, 14)
    hint:SetText("|cff666666scroll with mouse wheel|r")

    return ttDetailFrame
end

ShowTooltipDetail = function(spellID, spellName)
    CreateTooltipDetailFrame()
    ttDetailFrame:Show()

    -- Title
    ttDetailFrame.title:SetText(string.format(
        "Tooltip Detail — %s |cff888888#%d|r",
        spellName or "?", spellID or 0))

    -- Scan tooltip
    local tip = GetTTDetailScanTip()
    tip:ClearLines()
    tip:SetOwner(WorldFrame, "ANCHOR_NONE")
    local scanOK = pcall(tip.SetSpellByID, tip, spellID)

    ReleaseAllTTRows()

    if not scanOK then
        ttDetailFrame.lblStatus:SetText(
            "|cffff5555scan failed (pcall error)|r")
        ApplyTTScroll()
        return
    end

    local lineCount = tip:NumLines() or 0
    local secretCount = 0
    local rowIdx = 0
    local contentW = ttDetailFrame.content:GetWidth() - 8

    for i = 1, lineCount do
        local fs = _G["GeRODPS_ToolsSpellTTDetailScanTipTextLeft" .. i]
        local text = fs and fs:GetText()
        if text ~= nil then
            rowIdx = rowIdx + 1
            local row = CreateTTRow(ttDetailFrame.content)
            if rowIdx == 1 then
                row:SetPoint("TOPLEFT", ttDetailFrame.content, "TOPLEFT", 4, -4)
            else
                row:SetPoint("TOPLEFT", ttActiveRows[rowIdx - 1],
                    "BOTTOMLEFT", 0, -1)
            end
            row:SetWidth(contentW)

            row.lineNo:SetText("|cff888888" .. i .. "|r")

            if isSecret(text) then
                secretCount = secretCount + 1
                row.tag:SetText("|cffff5555[SECRET]|r")
                row:SetBackdropColor(0.20, 0.04, 0.04, 0.7)
                -- text is secret — SetText accepts it (Blizzard widget)
                row.content:SetText(text)
            else
                row.tag:SetText("|cff66dd66[VISIBLE]|r")
                row:SetBackdropColor(0.04, 0.10, 0.04, 0.5)
                row.content:SetText(text)
            end

            ttActiveRows[rowIdx] = row
        end
    end

    local totalH = rowIdx * (TT_ROW_HEIGHT + 1) + 8
    ttDetailFrame.content:SetHeight(totalH)
    ttDetailFrame.scrollY = 0
    ApplyTTScroll()

    ttDetailFrame.lblStatus:SetText(string.format(
        "%d lines  |  |cffff5555%d secret|r  |  |cff66dd66%d visible|r",
        rowIdx, secretCount, rowIdx - secretCount))
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
