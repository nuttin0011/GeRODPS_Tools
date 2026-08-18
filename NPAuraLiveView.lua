--[[
    NPAuraLiveView.lua — ดู Aura ของ nameplate แบบ **อ่านตลอดเวลา** (UI เรียบ)

    ── สเปกจาก user (2026-08-18) ────────────────────────────────────────────
      · อ่านด้วย "วิธีอ่านจาก Nameplate" เท่านั้น (reader ตัวจริงของ addon —
        GeRODPS.GetAllAuraFromSetOfNamePlate) ไม่มีการทดสอบ Lua API อื่นปน
      · 1 หน้า = 2 คอลัมน์ = nameplate 2 ตัว · มีหลายหน้าเมื่อ nameplate เยอะ
      · status in-combat เขียนไว้ข้างบน
      · โชว์แค่ Aura Spell ID — และต้องเป็น **FontString** เพราะค่าเป็น secret:
        FontString render ค่าจริงของ secret ได้ (หลัก Secret Peek) ส่วน
        multi-line EditBox แสดง secret ไม่ได้
      · เกิดจากผลวัด: เปิด option Plater "Show Debuffs Blizzard Nameplates show"
        (aura_show_debuff_as_blizzard_does) แล้ว DebuffListFrame ของ Blizzard
        populate ใต้ Plater ⇒ reader เดิมอ่านได้เลย — tool นี้ไว้เฝ้าดูสด ๆ
        (สลับ option ใน Plater แล้วเห็นผลทันทีในนี้)

    ── กติกา secret ──────────────────────────────────────────────────────────
      · spellID เป็น secret ⇒ ทำได้แค่ ".." concat / tostring แล้ว SetText
        ห้ามเทียบ/วัดความยาว/เก็บเป็น key
      · แถวเป็น FontString pool (reuse) — ไม่มี EditBox ในหน้าต่างนี้เลย
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local TITLE_H  = 28
local SIDE_PAD = 12
local COLS     = 2        -- user เคาะ: หน้าละ 2 nameplate
local MAX_ROWS = 16       -- แถว aura ต่อคอลัมน์ (pool)
local ROW_H    = 15
local TICK_SEC = 0.3

local frame, statusFS, pageLabel, btnPrev, btnNext
local cols = {}           -- [c] = { header = FS, rows = {FS...} }
local page = 1

-- ============================================================
-- ข้อมูล
-- ============================================================

--- รายชื่อ nameplate ที่มีตัวตน (เรียง index) — จับคู่ลงหน้า ตามลำดับนี้
local function ExistingUnits()
    local units = {}
    for i = 1, 30 do
        local u = "nameplate" .. i
        if UnitExists(u) then units[#units + 1] = u end
    end
    return units
end

--- "unit นี้คือ target ไหม" — เทียบเฟรม (UnitIsUnit เป็น secret boolean ห้าม if-test)
local function IsTargetUnit(u)
    if not UnitExists("target") then return nil end
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
    local pT = C_NamePlate.GetNamePlateForUnit("target")
    local pU = C_NamePlate.GetNamePlateForUnit(u)
    if pT == nil or pU == nil then return nil end
    return pT == pU
end

local KIND_TAG = { debuff = "[d]", buff = "[b]", cc = "[cc]", unknown = "[?]" }

-- ============================================================
-- วาด
-- ============================================================

local function UpdateStatus()
    local combat = InCombatLockdown()
    local parts = combat and "|cffff5555IN COMBAT|r" or "|cff44ff44out of combat|r"

    local P = _G.Plater
    if P then
        local opt = P.db and P.db.profile and P.db.profile.aura_show_debuff_as_blizzard_does
        parts = parts .. "   ·   Plater: มี · as-blizzard = "
            .. (opt == true and "|cff44ff44true|r" or "|cffff5555" .. tostring(opt) .. "|r")
    else
        parts = parts .. "   ·   Plater: ไม่ได้โหลด (Blizzard UI ล้วน)"
    end
    statusFS:SetText(parts)
end

local function UpdateColumn(c, unit)
    local col = cols[c]
    if unit == nil then
        col.header:SetText("|cff888888(ไม่มี nameplate ช่องนี้)|r")
        for _, fs in ipairs(col.rows) do fs:SetText("") end
        return
    end

    local name = tostring(UnitName(unit))
    local tgt = IsTargetUnit(unit)
    local tgtTxt = ""
    if tgt == true then
        tgtTxt = "  |cff44ff44<< target|r"
    end
    col.header:SetText(("|cffffd200%s|r  %s%s"):format(unit, name, tgtTxt))

    local recs = {}
    if GeRODPS and GeRODPS.GetAllAuraFromSetOfNamePlate then
        local ok, r = pcall(GeRODPS.GetAllAuraFromSetOfNamePlate, { unit })
        if ok and type(r) == "table" then recs = r end
    end

    for i = 1, MAX_ROWS do
        local fs = col.rows[i]
        local r = recs[i]
        if r == nil then
            if i == 1 then
                fs:SetText("|cff666666(ไม่มี aura)|r")
            else
                fs:SetText("")
            end
        else
            -- spellID เป็น secret — ".." concat ได้ · FontString render ค่าจริงได้
            local tag = KIND_TAG[r.kind] or "[?]"
            fs:SetText("  #" .. i .. "  " .. tag .. "  spellID = " .. tostring(r.spellID))
        end
    end
    if #recs > MAX_ROWS and col.rows[MAX_ROWS] then
        col.rows[MAX_ROWS]:SetText(("  ... อีก %d ตัว (เกิน %d แถว)"):format(#recs - MAX_ROWS, MAX_ROWS))
    end
end

local function Tick()
    if frame == nil or not frame:IsShown() then return end
    UpdateStatus()

    local units = ExistingUnits()
    local totalPages = math.ceil(#units / COLS)
    if totalPages < 1 then totalPages = 1 end
    if page > totalPages then page = totalPages end
    if page < 1 then page = 1 end

    for c = 1, COLS do
        UpdateColumn(c, units[(page - 1) * COLS + c])
    end

    pageLabel:SetText(("หน้า %d/%d  ·  nameplate ทั้งหมด %d"):format(page, totalPages, #units))
    btnPrev:SetEnabled(page > 1)
    btnNext:SetEnabled(page < totalPages)
end

-- ============================================================
-- UI
-- ============================================================
local function LayoutColumns()
    local w = frame:GetWidth() - SIDE_PAD * 2
    local colW = (w - 10) / COLS
    for c = 1, COLS do
        local x = SIDE_PAD + (c - 1) * (colW + 10)
        local col = cols[c]
        col.header:ClearAllPoints()
        col.header:SetPoint("TOPLEFT", btnPrev, "BOTTOMLEFT", x - SIDE_PAD, -10)
        col.header:SetWidth(colW)
        for i, fs in ipairs(col.rows) do
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", col.header, "BOTTOMLEFT", 0, -4 - (i - 1) * ROW_H)
            fs:SetWidth(colW)
        end
    end
end

local function BuildFrame()
    if frame then return frame end
    frame = CreateFrame("Frame", "GeRODPSToolsNPAuraLiveView", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(640, 420)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    frame:SetFrameStrata("HIGH")
    if frame.TitleText then frame.TitleText:SetText("NP Aura Live View") end

    -- status บนสุด — user เคาะ: in-combat ต้องอยู่ข้างบน
    statusFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    statusFS:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 8))
    statusFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + 8))
    statusFS:SetJustifyH("LEFT")
    statusFS:SetText("...")

    btnPrev = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnPrev:SetSize(40, 22)
    btnPrev:SetPoint("TOPLEFT", statusFS, "BOTTOMLEFT", 0, -8)
    btnPrev:SetText("<")
    btnPrev:SetScript("OnClick", function() page = page - 1; Tick() end)

    btnNext = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnNext:SetSize(40, 22)
    btnNext:SetPoint("LEFT", btnPrev, "RIGHT", 6, 0)
    btnNext:SetText(">")
    btnNext:SetScript("OnClick", function() page = page + 1; Tick() end)

    pageLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageLabel:SetPoint("LEFT", btnNext, "RIGHT", 12, 0)
    pageLabel:SetText("")

    for c = 1, COLS do
        local col = { rows = {} }
        col.header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        col.header:SetJustifyH("LEFT")
        for i = 1, MAX_ROWS do
            local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            col.rows[i] = fs
        end
        cols[c] = col
    end
    LayoutColumns()

    frame:SetResizable(true)
    frame:SetResizeBounds(480, 320)
    local resize = CreateFrame("Button", nil, frame)
    resize:SetSize(16, 16)
    resize:SetPoint("BOTTOMRIGHT", -4, 4)
    resize:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    resize:SetPushedTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Down")
    resize:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then frame:StartSizing("BOTTOMRIGHT") end
    end)
    resize:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then frame:StopMovingOrSizing(); LayoutColumns() end
    end)
    frame:SetScript("OnSizeChanged", function() if cols[1] then LayoutColumns() end end)

    frame:SetScript("OnUpdate", (function()
        local acc = 0
        return function(_, dt)
            acc = acc + dt
            if acc >= TICK_SEC then acc = 0; Tick() end
        end
    end)())

    return frame
end

function TOOL.ShowNPAuraLiveView()
    local f = BuildFrame()
    if f:IsShown() then f:Hide() else f:Show(); Tick() end
end

TOOL.RegisterTool("NP Aura Live View (spellID · อ่านตลอดเวลา)", TOOL.ShowNPAuraLiveView)
