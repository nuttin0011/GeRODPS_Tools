--[[
    TestSendToStringLength.lua

    เครื่องมือทดสอบความยาวสูงสุดของ SendToString text frame.

    Override การเขียน GeRODPS.TextSendToAHK ให้เป็นข้อความทดสอบที่ user
    ควบคุมความยาวเอง รูปแบบเหมือนของจริง: `$XXXX$XXXX...%`
      - เริ่มต้นและลงท้ายด้วย $ ... % เสมอ
      - แต่ละ block = "$" + 4 random digits = 5 ตัวอักษร
      - 1 block แรก: "$1234%" (6 ตัวอักษร)
      - 2 blocks: "$1234$1234%" (11 ตัวอักษร)
      - N blocks → (5N + 1) ตัวอักษร

    ปุ่ม:
      [+ Add block]   เพิ่มอีก 1 block (5 ตัวอักษร) — สุ่ม 4 หลักใหม่ทุกครั้ง
      [− Remove]      ลบ block สุดท้ายออก 1 block (ขั้นต่ำ 1 block เพื่อให้
                      มี $...% ติดกัน)
      [Reset]         รีเซ็ตเป็น 1 block

    Override ทำงานต่อเมื่อ Frame เปิดอยู่ — ปิด Frame เมื่อใดก็จะคืนการ
    ทำงานปกติของ SendToString.lua ทันที (ไม่ uninstall hook แต่ flag off
    → wrapper ปล่อยให้ string เดิมผ่าน)

    Use case: ดูในเกมว่า `%` ตัวสุดท้ายโดน text frame ตัดไหม เพื่อหาความ
    ยาวสูงสุดที่ปลอดภัย — ข้อมูลนี้ใช้วางแผน 6-layer alpha encoding ที่
    ต้องรู้ว่า render พื้นที่กี่ pixel.

    Public:
        GeRODPS_Tools.ToggleTestSendToStringLength()
        GeRODPS_Tools.ShowTestSendToStringLength()
        GeRODPS_Tools.HideTestSendToStringLength()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME = "GeRODPS_ToolsTestSendToStringLengthFrame"
local DEFAULT_W, DEFAULT_H = 520, 260
local SCREEN_MARGIN        = 100
local MIN_BLOCKS           = 1

-- ============================================================
-- Override state — shared between hook wrapper and UI
-- ============================================================

local overrideActive   = false
local currentTestStr   = nil              -- the string we force-write
local blockCount       = MIN_BLOCKS
local originalSetText  = nil              -- saved once on first install

-- ============================================================
-- DB
-- ============================================================

local function GetDB()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    GeRODPS_ToolsDB.testSendToStringLength = GeRODPS_ToolsDB.testSendToStringLength or {}
    return GeRODPS_ToolsDB.testSendToStringLength
end

-- ============================================================
-- String builder
-- ============================================================

local function RandBlock()
    return "$" .. string.format("%04d", math.random(0, 9999))
end

local function BuildTestString(nBlocks)
    if nBlocks < MIN_BLOCKS then nBlocks = MIN_BLOCKS end
    local s = ""
    for _ = 1, nBlocks do
        s = s .. RandBlock()
    end
    return s .. "%"
end

-- ============================================================
-- Hook install — wrap GeRODPS.TextSendToAHK:SetText once.
-- The hook is permanent across open/close cycles; the flag
-- overrideActive controls whether we force the test string.
-- ============================================================

local function InstallHook()
    if originalSetText then return true end
    if not _G.GeRODPS or not _G.GeRODPS.TextSendToAHK then return false end

    local target = _G.GeRODPS.TextSendToAHK
    originalSetText = target.SetText
    target.SetText = function(self, str)
        if overrideActive and currentTestStr then
            return originalSetText(self, currentTestStr)
        end
        return originalSetText(self, str)
    end
    return true
end

-- Push the current test string immediately (don't wait 50ms tick)
local function ForceWriteNow()
    if not overrideActive or not currentTestStr then return end
    if _G.GeRODPS and _G.GeRODPS.TextSendToAHK and originalSetText then
        originalSetText(_G.GeRODPS.TextSendToAHK, currentTestStr)
    end
end

-- ============================================================
-- Frame state
-- ============================================================

local frame
local lblStatus, lblBlocks, lblChars, lblPreview, lblHookWarn

local function RefreshDisplay()
    if not frame then return end
    currentTestStr = BuildTestString(blockCount)

    if lblStatus then
        if overrideActive then
            lblStatus:SetText("|cff66ff66Override: ON|r " ..
                "(Frame เปิดอยู่ — TextSendToAHK ถูก override)")
        else
            lblStatus:SetText("|cffaaaaaaOverride: OFF|r")
        end
    end

    if lblBlocks then
        lblBlocks:SetText(string.format("Blocks: |cFFFFD200%d|r", blockCount))
    end
    if lblChars then
        local n = #currentTestStr
        lblChars:SetText(string.format("Total chars: |cFFFFD200%d|r", n))
    end
    if lblPreview then
        lblPreview:SetText(currentTestStr)
    end

    if lblHookWarn then
        if originalSetText then
            lblHookWarn:SetText("")
        else
            lblHookWarn:SetText(
                "|cffff6666⚠ GeRODPS.TextSendToAHK ยังไม่พร้อม — " ..
                "Override ไม่ทำงาน (โหลด GeRODPS แล้ว /reload)|r")
        end
    end

    ForceWriteNow()
end

-- ============================================================
-- Geometry persistence
-- ============================================================

local function SavePosition(self)
    local db = GetDB()
    local p, _, rp, x, y = self:GetPoint(1)
    db.point, db.relPoint, db.x, db.y = p, rp, x, y
end

local function ApplySavedGeometry(self)
    local db = GetDB()
    local screenW = UIParent:GetWidth()
    local screenH = UIParent:GetHeight()

    self:ClearAllPoints()
    if db.point and db.relPoint and db.x and db.y then
        self:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    else
        self:SetPoint("CENTER")
    end
    self:SetSize(DEFAULT_W, DEFAULT_H)

    -- Keep at least SCREEN_MARGIN inside the screen
    local left, right = self:GetLeft(), self:GetRight()
    local bottom, top = self:GetBottom(), self:GetTop()
    if left and right and bottom and top then
        local dx, dy = 0, 0
        if left   < SCREEN_MARGIN              then dx = SCREEN_MARGIN - left end
        if right  > (screenW - SCREEN_MARGIN)  then dx = (screenW - SCREEN_MARGIN) - right end
        if bottom < SCREEN_MARGIN              then dy = SCREEN_MARGIN - bottom end
        if top    > (screenH - SCREEN_MARGIN)  then dy = (screenH - SCREEN_MARGIN) - top end
        if dx ~= 0 or dy ~= 0 then
            local point, relTo, relPoint, x, y = self:GetPoint(1)
            self:ClearAllPoints()
            self:SetPoint(point, relTo or UIParent, relPoint, x + dx, y + dy)
        end
    end
end

-- ============================================================
-- Build frame
-- ============================================================

local function CreateTestFrame()
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

    if frame.TitleText then
        frame.TitleText:SetText("GeRODPS Tools — Test SendToString Length")
    end

    local content = frame.Inset or frame

    -- ── Status line ──
    lblStatus = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lblStatus:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -14)
    lblStatus:SetJustifyH("LEFT")
    lblStatus:SetText("")

    -- ── Counters ──
    lblBlocks = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lblBlocks:SetPoint("TOPLEFT", lblStatus, "BOTTOMLEFT", 0, -10)
    lblBlocks:SetText("")

    lblChars = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lblChars:SetPoint("LEFT", lblBlocks, "RIGHT", 30, 0)
    lblChars:SetText("")

    -- ── String preview ──
    local previewBox = CreateFrame("Frame", nil, content, "BackdropTemplate")
    previewBox:SetPoint("TOPLEFT", lblBlocks, "BOTTOMLEFT", 0, -8)
    previewBox:SetPoint("RIGHT",   content,   "RIGHT",      -14, 0)
    previewBox:SetHeight(70)
    if previewBox.SetBackdrop then
        previewBox:SetBackdrop({
            bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            tile     = true, tileSize = 8, edgeSize = 12,
            insets   = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        previewBox:SetBackdropColor(0, 0, 0, 0.6)
        previewBox:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end

    lblPreview = previewBox:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    lblPreview:SetPoint("TOPLEFT",     previewBox, "TOPLEFT",      6,  -6)
    lblPreview:SetPoint("BOTTOMRIGHT", previewBox, "BOTTOMRIGHT", -6,   6)
    lblPreview:SetJustifyH("LEFT")
    lblPreview:SetJustifyV("TOP")
    lblPreview:SetWordWrap(true)
    lblPreview:SetNonSpaceWrap(true)
    lblPreview:SetText("")

    -- ── Buttons row ──
    local btnRemove = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    btnRemove:SetSize(140, 24)
    btnRemove:SetPoint("TOPLEFT", previewBox, "BOTTOMLEFT", 0, -12)
    btnRemove:SetText("−  Remove block")
    btnRemove:SetScript("OnClick", function()
        if blockCount > MIN_BLOCKS then
            blockCount = blockCount - 1
            RefreshDisplay()
        end
    end)

    local btnAdd = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    btnAdd:SetSize(140, 24)
    btnAdd:SetPoint("LEFT", btnRemove, "RIGHT", 8, 0)
    btnAdd:SetText("+  Add block")
    btnAdd:SetScript("OnClick", function()
        blockCount = blockCount + 1
        RefreshDisplay()
    end)

    local btnReset = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    btnReset:SetSize(100, 24)
    btnReset:SetPoint("LEFT", btnAdd, "RIGHT", 16, 0)
    btnReset:SetText("Reset")
    btnReset:SetScript("OnClick", function()
        blockCount = MIN_BLOCKS
        RefreshDisplay()
    end)

    -- ── Warning line (hook not installed) ──
    lblHookWarn = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lblHookWarn:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 14, 14)
    lblHookWarn:SetPoint("RIGHT",      content, "RIGHT",     -14, 0)
    lblHookWarn:SetJustifyH("LEFT")
    lblHookWarn:SetText("")

    -- ── Show/Hide hooks ──
    frame:SetScript("OnShow", function()
        InstallHook()
        overrideActive = true
        RefreshDisplay()
    end)
    frame:SetScript("OnHide", function()
        overrideActive = false
        currentTestStr = nil
        -- Normal SendToString tick will resume writing real values on its
        -- next 0.05s pass. We do NOT uninstall the hook so re-open is
        -- instant and avoids double-wrapping.
    end)

    table.insert(UISpecialFrames, FRAME_NAME)
    ApplySavedGeometry(frame)
    frame:Hide()
    return frame
end

-- ============================================================
-- Public API
-- ============================================================

function TOOL.ShowTestSendToStringLength()
    local f = CreateTestFrame()
    if not f:IsShown() then
        ApplySavedGeometry(f)
        f:Show()
    end
end

function TOOL.HideTestSendToStringLength()
    if frame and frame:IsShown() then frame:Hide() end
end

function TOOL.ToggleTestSendToStringLength()
    local f = CreateTestFrame()
    if f:IsShown() then
        f:Hide()
    else
        ApplySavedGeometry(f)
        f:Show()
    end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("Test SendToString Length",
                      TOOL.ToggleTestSendToStringLength)
end
