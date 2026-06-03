--[[
    PasteSpeedTest.lua

    Tool ทดสอบความเร็ว paste text ขนาดใหญ่ ใน WoW UI หลายๆ variant
    เพื่อหาวิธีที่เร็วที่สุดสำหรับ Import Rotation.

    ปัญหาที่ต้องตรวจ:
      - Paste 100KB JSON ลง AceGUI MultiLineEditBox = freeze 1+ minute
      - หาวิธีอื่นที่เร็วกว่า

    Variants:
      1. AceGUI MultiLineEditBox (baseline — slow)
      2. AceGUI + override OnTextChanged (skip GetText())
      3. Native WoW EditBox (raw multiline)
      4. Native EditBox in ScrollFrame
      5. Macro Var paste (ไม่ paste ใน UI — read จาก _G.GERODPS_PASTE_VAR)

    UX:
      - 1 frame, 5 sections stacked vertically (scroll)
      - แต่ละ section มี: label, EditBox/button, char count, Clear button
      - "Refresh All Counts" button — update char count ของทุก variant
      - User: paste JSON ลงแต่ละ variant ครั้งละอัน, สังเกตว่าตัวไหน freeze แค่ไหน
      - แล้วแจ้ง dev ว่าเอาแบบไหน

    Public:
      GeRODPS_Tools.TogglePasteSpeedTest()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local AceGUI = LibStub and LibStub("AceGUI-3.0", true)

local FRAME_NAME = "GeRODPS_ToolsPasteSpeedTestFrame"
local DEFAULT_W, DEFAULT_H = 720, 720
local MIN_W, MIN_H = 600, 500
local MAX_W, MAX_H = 1400, 1000

-- =============================================================
-- DB helpers (persist window geometry)
-- =============================================================
local function GetDB()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    GeRODPS_ToolsDB.PasteSpeedTest = GeRODPS_ToolsDB.PasteSpeedTest or {}
    return GeRODPS_ToolsDB.PasteSpeedTest
end

-- =============================================================
-- Per-variant state
-- =============================================================
local frame   -- top-level frame
local sections = {}   -- list of variant section refs

local function formatCount(n)
    if not n then return "0" end
    if n >= 1000 then
        return string.format("%d (%.1f KB)", n, n / 1024)
    end
    return tostring(n)
end

-- =============================================================
-- Variant 1: AceGUI MultiLineEditBox baseline
-- =============================================================
local function CreateVariant1(parent, yOffset)
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetSize(680, 110)
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    box:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left=3, right=3, top=3, bottom=3 },
    })
    box:SetBackdropColor(0.05, 0.05, 0.05, 0.8)
    box:SetBackdropBorderColor(0.5, 0.4, 0.1, 1)

    local title = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -6)
    title:SetText("|cffffd2001. AceGUI MultiLineEditBox|r — baseline (slow)")

    -- Native EditBox with multiline via raw frame for testing
    -- (เราจะใช้ AceGUI's MultiLineEditBox จริงๆ แต่เพื่อ embed ใน raw frame
    -- ก็ต้อง wrap แบบนี้)
    local scroll = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",  box, "TOPLEFT",     8, -28)
    scroll:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -28, 28)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetMaxBytes(0)
    edit:SetMaxLetters(0)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(620)
    -- Mimic AceGUI's OnTextChanged behavior — call GetText() per char (slow!)
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            local txt = self:GetText()   -- ⚠ this is the slow path
            sections[1].lastLen = txt and #txt or 0
        end
    end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(edit)

    local lblCount = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lblCount:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", 8, 6)
    lblCount:SetText("Chars: 0")

    local btnClear = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    btnClear:SetSize(80, 18)
    btnClear:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -8, 6)
    btnClear:SetText("Clear")
    btnClear:SetScript("OnClick", function()
        edit:SetText("")
        sections[1].lastLen = 0
        lblCount:SetText("Chars: 0")
    end)

    return {
        getLen = function() return edit:GetText() and #edit:GetText() or 0 end,
        getEdit = function() return edit end,
        setCountLabel = function(n) lblCount:SetText("Chars: " .. formatCount(n)) end,
        lastLen = 0,
    }
end

-- =============================================================
-- Variant 2: Native EditBox + NO OnTextChanged (skip GetText)
-- =============================================================
local function CreateVariant2(parent, yOffset)
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetSize(680, 110)
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    box:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left=3, right=3, top=3, bottom=3 },
    })
    box:SetBackdropColor(0.05, 0.05, 0.05, 0.8)
    box:SetBackdropBorderColor(0.5, 0.4, 0.1, 1)

    local title = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -6)
    title:SetText("|cffffd2002. Native EditBox|r — NO OnTextChanged (ไม่เรียก GetText)")

    local scroll = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",  box, "TOPLEFT",     8, -28)
    scroll:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -28, 28)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetMaxBytes(0)
    edit:SetMaxLetters(0)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    edit:SetWidth(620)
    -- NO OnTextChanged handler at all → ไม่เรียก GetText() ระหว่าง paste
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(edit)

    local lblCount = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lblCount:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", 8, 6)
    lblCount:SetText("Chars: 0 (กด Refresh เพื่อ update)")

    local btnClear = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    btnClear:SetSize(80, 18)
    btnClear:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -8, 6)
    btnClear:SetText("Clear")
    btnClear:SetScript("OnClick", function()
        edit:SetText("")
        lblCount:SetText("Chars: 0")
    end)

    return {
        getLen = function() return edit:GetText() and #edit:GetText() or 0 end,
        getEdit = function() return edit end,
        setCountLabel = function(n) lblCount:SetText("Chars: " .. formatCount(n)) end,
    }
end

-- =============================================================
-- Variant 3: Native EditBox single-line (no multiline)
-- =============================================================
local function CreateVariant3(parent, yOffset)
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetSize(680, 70)
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    box:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left=3, right=3, top=3, bottom=3 },
    })
    box:SetBackdropColor(0.05, 0.05, 0.05, 0.8)
    box:SetBackdropBorderColor(0.5, 0.4, 0.1, 1)

    local title = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -6)
    title:SetText("|cffffd2003. Native EditBox single-line|r — wraps off, no multiline tokenize")

    local edit = CreateFrame("EditBox", nil, box, "InputBoxTemplate")
    edit:SetSize(580, 22)
    edit:SetPoint("TOPLEFT", box, "TOPLEFT", 16, -28)
    edit:SetMaxBytes(0)
    edit:SetMaxLetters(0)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local lblCount = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lblCount:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", 8, 6)
    lblCount:SetText("Chars: 0 (กด Refresh เพื่อ update)")

    local btnClear = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    btnClear:SetSize(80, 18)
    btnClear:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -8, 6)
    btnClear:SetText("Clear")
    btnClear:SetScript("OnClick", function()
        edit:SetText("")
        lblCount:SetText("Chars: 0")
    end)

    return {
        getLen = function() return edit:GetText() and #edit:GetText() or 0 end,
        getEdit = function() return edit end,
        setCountLabel = function(n) lblCount:SetText("Chars: " .. formatCount(n)) end,
    }
end

-- =============================================================
-- Variant 4: AceGUI MultiLineEditBox (matches Import popup)
-- =============================================================
local function CreateVariant4(parent, yOffset)
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetSize(680, 200)
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    box:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left=3, right=3, top=3, bottom=3 },
    })
    box:SetBackdropColor(0.05, 0.05, 0.05, 0.8)
    box:SetBackdropBorderColor(0.5, 0.4, 0.1, 1)

    local title = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -6)
    title:SetText("|cffffd2004. AceGUI MultiLineEditBox (เหมือนใน Import popup ปัจจุบัน)|r")

    local container = AceGUI:Create("SimpleGroup")
    container:SetLayout("Fill")
    container.frame:SetParent(box)
    container.frame:ClearAllPoints()
    container.frame:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -28)
    container.frame:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -8, 28)
    container.frame:Show()

    local mle = AceGUI:Create("MultiLineEditBox")
    mle:SetLabel("")
    mle:SetFullWidth(true)
    mle:SetFullHeight(true)
    mle:SetNumLines(8)
    mle:DisableButton(true)
    mle:SetText("")
    container:AddChild(mle)

    local lblCount = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lblCount:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", 8, 6)
    lblCount:SetText("Chars: 0")

    local btnClear = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    btnClear:SetSize(80, 18)
    btnClear:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -8, 6)
    btnClear:SetText("Clear")
    btnClear:SetScript("OnClick", function()
        mle:SetText("")
        lblCount:SetText("Chars: 0")
    end)

    return {
        getLen = function()
            local t = mle:GetText()
            return t and #t or 0
        end,
        setCountLabel = function(n) lblCount:SetText("Chars: " .. formatCount(n)) end,
        mle = mle,
        container = container,
    }
end

-- =============================================================
-- Variant 5: Macro Var paste (bypass UI entirely)
-- =============================================================
local function CreateVariant5(parent, yOffset)
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetSize(680, 110)
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    box:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left=3, right=3, top=3, bottom=3 },
    })
    box:SetBackdropColor(0.05, 0.05, 0.05, 0.8)
    box:SetBackdropBorderColor(0.5, 0.4, 0.1, 1)

    local title = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -6)
    title:SetText("|cffffd2005. Macro Var paste|r — bypass UI ทั้งหมด")

    local instructions = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    instructions:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -28)
    instructions:SetPoint("RIGHT", box, "RIGHT", -8, 0)
    instructions:SetJustifyH("LEFT")
    instructions:SetJustifyV("TOP")
    instructions:SetText(
        "วิธีใช้:\n" ..
        "1. สร้าง macro ใน WoW (กด ESC → Macros) ใส่: |cffaaaaff/run GERODPS_PASTE_VAR = [[<json>]]|r\n" ..
        "2. แก้ <json> เป็น JSON ที่ copy มา (ปุ่ม Edit ของ macro รองรับ paste ใหญ่ได้)\n" ..
        "3. กด macro → กดปุ่ม 'Check Var' ด้านล่าง"
    )

    local lblCount = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lblCount:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", 8, 6)
    lblCount:SetText("GERODPS_PASTE_VAR: (ยังไม่ได้ตั้งค่า)")

    local btnCheck = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    btnCheck:SetSize(100, 18)
    btnCheck:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -8, 6)
    btnCheck:SetText("Check Var")
    btnCheck:SetScript("OnClick", function()
        local v = _G.GERODPS_PASTE_VAR
        if type(v) == "string" then
            lblCount:SetText("GERODPS_PASTE_VAR: " .. formatCount(#v))
        else
            lblCount:SetText("|cffff6666GERODPS_PASTE_VAR: ไม่ใช่ string (type=" ..
                type(v) .. ")|r")
        end
    end)

    return {
        getLen = function()
            local v = _G.GERODPS_PASTE_VAR
            return type(v) == "string" and #v or 0
        end,
        setCountLabel = function(n)
            lblCount:SetText("GERODPS_PASTE_VAR: " .. formatCount(n))
        end,
    }
end

-- =============================================================
-- Build full frame
-- =============================================================
local function CreatePasteSpeedTestFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BackdropTemplate")
    frame:SetSize(DEFAULT_W, DEFAULT_H)
    frame:SetPoint("CENTER")
    frame:SetBackdrop({
        bgFile   = "Interface/DialogFrame/UI-DialogBox-Background-Dark",
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
    title:SetText("Paste Speed Test — เปรียบเทียบ paste 100KB ใน UI variants")

    -- Drag bar
    local dragBar = CreateFrame("Frame", nil, frame)
    dragBar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  10, -10)
    dragBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -10)
    dragBar:SetHeight(28)
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
    end)

    -- Scroll area for sections
    local scrollOuter = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scrollOuter:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -52)
    scrollOuter:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -36, 48)

    local scrollChild = CreateFrame("Frame", nil, scrollOuter)
    scrollChild:SetSize(680, 1200)   -- enough for all sections
    scrollOuter:SetScrollChild(scrollChild)

    -- Build all variant sections
    sections[1] = CreateVariant1(scrollChild, -10)
    sections[2] = CreateVariant2(scrollChild, -130)
    sections[3] = CreateVariant3(scrollChild, -250)
    sections[4] = CreateVariant4(scrollChild, -330)
    sections[5] = CreateVariant5(scrollChild, -550)

    -- Bottom controls — Refresh All
    local btnRefresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnRefresh:SetSize(140, 22)
    btnRefresh:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 20, 16)
    btnRefresh:SetText("Refresh All Counts")
    btnRefresh:SetScript("OnClick", function()
        for i, s in ipairs(sections) do
            if s.getLen and s.setCountLabel then
                s.setCountLabel(s.getLen())
            end
        end
    end)

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("LEFT", btnRefresh, "RIGHT", 10, 0)
    hint:SetText("|cffaaaaaaTest: paste JSON ใหญ่ลงแต่ละ variant — สังเกตว่าตัวไหน freeze มากที่สุด|r")

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
function TOOL.TogglePasteSpeedTest()
    local f = CreatePasteSpeedTestFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("Paste Speed Test (100KB import)", TOOL.TogglePasteSpeedTest)
end
