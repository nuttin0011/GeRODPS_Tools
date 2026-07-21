--[[
    GeRODPS_Tools / GeRoInput.lua

    POC: พิสูจน์ว่า Python (ภายนอก) ป้อนข้อมูลเข้า WoW ได้ 2 ทาง เพื่อเลือก
    transport ของ Rotation Studio "Studio Bridge":

      (A) /geroinput <text>           -> รับ text ตรงจาก slash arg (ทดสอบ chat cap ~255)
      (B) /geroinputeditbox           -> เปิด multi-line EditBox (focus อัตโนมัติ)
                                         Python วาง clipboard + Ctrl+V + ปิดท้ายด้วย
                                         sentinel "<<GEROK>>" -> addon auto-accept
                                         (= "Python กด OK ให้เอง" โดยไม่ต้องหา coord ปุ่ม)

    ทั้ง 2 ทาง addon จะรายงาน bytes/lines/sum ลง chat + เก็บใน SavedVariables
    (GeRODPS_ToolsDB.geroInput) ให้ Python เทียบว่าข้อมูลตรงกับที่ส่งไหม.

    native EditBox + debounce (ไม่เรียก GetText ต่อ char) -> กัน freeze ตาม
    บทเรียนใน PasteSpeedTest.lua (paste ใหญ่ใน per-char OnTextChanged = O(n^2)).

    Public:
        GeRODPS_Tools.ShowGeRoInput()
        GeRODPS_Tools.ToggleGeRoInput()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME = "GeRODPS_ToolsGeRoInputFrame"
local SENTINEL   = "<<GEROK>>"     -- Python ต่อท้าย payload -> auto-accept
local TITLE_H    = 28              -- Rule 10: แถวแรกเผื่อ title bar

local frame          -- lazily created
local editBox        -- ref to the EditBox
local countFS        -- live char/line counter
local resultFS       -- shows last accepted report

-- ============================================================
-- helpers
-- ============================================================
local function countLines(s)
    if s == "" then return 0 end
    local n = 1
    for _ in s:gmatch("\n") do n = n + 1 end
    return n
end

local function checksum(s)
    -- sum ของทุก byte mod 1e6 -- Python คำนวณเหมือนกันได้ (ASCII payload)
    local sum = 0
    for i = 1, #s do
        sum = (sum + s:byte(i)) % 1000000
    end
    return sum
end

-- รายงานผล: chat + SavedVariables (ให้ Python เทียบ)
local function Report(source, text)
    text = text or ""
    text = text:gsub("\r", "")          -- normalize CR ออก (OS/clipboard อาจแทรก)
    local bytes = #text
    local lines = countLines(text)
    local sum   = checksum(text)
    local head  = text:sub(1, 24):gsub("\n", "\\n")
    local tail  = text:sub(-16):gsub("\n", "\\n")

    print(("|cff33ff99[GeRoInput]|r %s: bytes=%d lines=%d sum=%d head=%q tail=%q")
        :format(source, bytes, lines, sum, head, tail))

    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    GeRODPS_ToolsDB.geroInput = {
        source = source, bytes = bytes, lines = lines, sum = sum,
        text = text, at = date("%H:%M:%S"),
    }

    if resultFS then
        resultFS:SetText(("last: %s | bytes=%d lines=%d sum=%d")
            :format(source, bytes, lines, sum))
    end
end

local function UpdateCount()
    if not (editBox and countFS) then return end
    local t = editBox:GetText() or ""
    t = t:gsub("\r", "")
    countFS:SetText(("chars: %d | lines: %d"):format(#t, countLines(t)))
end

local function HideFrame()
    if frame and frame:IsShown() then frame:Hide() end
end

-- ============================================================
-- slash A: direct arg (ทดสอบ chat cap ~255)
-- ============================================================
SLASH_GEROINPUT1 = "/geroinput"
SlashCmdList["GEROINPUT"] = function(msg)
    Report("slash", msg or "")
end

-- ============================================================
-- slash B: open EditBox
-- ============================================================
SLASH_GEROINPUTEDITBOX1 = "/geroinputeditbox"
SlashCmdList["GEROINPUTEDITBOX"] = function()
    TOOL.ShowGeRoInput()
end

-- ============================================================
-- EditBox submit paths
-- ============================================================
local function AcceptEditText(raw, source)
    raw = raw or ""
    -- ตัด sentinel + newline ก่อนหน้าออก ถ้ามี
    local idx = raw:find(SENTINEL, 1, true)
    if idx then
        raw = raw:sub(1, idx - 1):gsub("\n$", "")
    end
    Report(source, raw)
    if editBox then editBox:SetText("") end
    HideFrame()
end

-- debounce: OnTextChanged ยิงหลายครั้งตอน paste -> รวมเป็น check เดียวหลัง 0.25s
-- (ไม่เรียก GetText ต่อ char -> กัน freeze)
local pendingCheck = false
local function OnEditChanged(_, userInput)
    if not userInput then return end
    if pendingCheck then return end
    pendingCheck = true
    C_Timer.After(0.25, function()
        pendingCheck = false
        if not editBox then return end
        local t = editBox:GetText() or ""
        if t:find(SENTINEL, 1, true) then
            AcceptEditText(t, "editbox-auto")   -- Python ส่ง sentinel -> auto-accept
        else
            UpdateCount()
        end
    end)
end

-- ============================================================
-- frame
-- ============================================================
local function CreateFrameOnce()
    if frame then return frame end

    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(640, 460)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("FULLSCREEN_DIALOG")   -- อยู่เหนือ frame อื่น ให้ paste ลงถูก
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    if frame.TitleText then
        frame.TitleText:SetText("GeRODPS Tools - GeRoInput (paste transport test)")
    end

    -- คำอธิบาย (Rule 10: แถวแรกเผื่อ TITLE_H)
    local info = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    info:SetPoint("TOPLEFT",  frame, "TOPLEFT",  16, -(TITLE_H + 8))
    info:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -(TITLE_H + 8))
    info:SetJustifyH("LEFT")
    info:SetText("Python: set clipboard -> Ctrl+V ลงกล่องนี้ (ปิดท้าย " .. SENTINEL ..
        " = auto-accept). หรือกด OK เอง. ผลออก chat + SavedVariables.")

    -- ScrollFrame + native multiline EditBox
    local scroll = CreateFrame("ScrollFrame", FRAME_NAME .. "Scroll", frame,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     frame, "TOPLEFT",     16, -(TITLE_H + 40))
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -34, 74)

    local eb = CreateFrame("EditBox", FRAME_NAME .. "Edit", scroll)
    eb:SetMultiLine(true)
    eb:SetMaxBytes(0)
    eb:SetMaxLetters(0)
    eb:SetAutoFocus(false)
    eb:SetFontObject("ChatFontNormal")
    eb:SetWidth(560)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnTextChanged", OnEditChanged)
    scroll:SetScrollChild(eb)
    editBox = eb

    -- counters
    countFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    countFS:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 48)
    countFS:SetText("chars: 0 | lines: 0")

    resultFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    resultFS:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 30)
    resultFS:SetTextColor(0.7, 0.9, 1)
    resultFS:SetText("last: (none)")

    -- buttons
    local btnOK = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnOK:SetSize(120, 22)
    btnOK:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 12)
    btnOK:SetText("OK (Accept)")
    btnOK:SetScript("OnClick", function()
        AcceptEditText(editBox and editBox:GetText() or "", "editbox-ok")
    end)

    local btnClear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnClear:SetSize(90, 22)
    btnClear:SetPoint("RIGHT", btnOK, "LEFT", -8, 0)
    btnClear:SetText("Clear")
    btnClear:SetScript("OnClick", function()
        if editBox then editBox:SetText(""); editBox:SetFocus() end
        UpdateCount()
    end)

    local btnCancel = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnCancel:SetSize(90, 22)
    btnCancel:SetPoint("RIGHT", btnClear, "LEFT", -8, 0)
    btnCancel:SetText("Cancel")
    btnCancel:SetScript("OnClick", HideFrame)

    frame:SetScript("OnShow", function()
        if editBox then
            editBox:SetText("")
            editBox:SetFocus()      -- ให้ Ctrl+V ของ Python ลงกล่องนี้
        end
        UpdateCount()
    end)

    table.insert(UISpecialFrames, FRAME_NAME)   -- ESC ปิด
    frame:Hide()
    return frame
end

function TOOL.ShowGeRoInput()
    local f = CreateFrameOnce()
    f:Show()
    -- SetFocus อีกครั้งหลัง show settle (บาง client focus หลุดตอนสร้างเฟรม)
    C_Timer.After(0.05, function()
        if editBox and f:IsShown() then editBox:SetFocus() end
    end)
end

function TOOL.ToggleGeRoInput()
    local f = CreateFrameOnce()
    if f:IsShown() then f:Hide() else TOOL.ShowGeRoInput() end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("GeRoInput (paste transport test)", TOOL.ToggleGeRoInput)
end
