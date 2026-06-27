--[[
    ScrollUITests.lua

    Sandbox สำหรับทดสอบ "overflow / scroll" UI หลายแบบ ก่อนเอาไปใช้จริงใน
    Defensive list (Add Spell ID / Bleed). ตอบคำถาม: เอา Frame ที่กว้าง/สูง
    ซ้อนเข้าไปใน Frame ที่เล็กกว่า แล้วเลื่อนดูด้วย scrollbar ได้ไหม? → ได้
    ด้วย native ScrollFrame (SetScrollChild + SetHorizontalScroll/SetVerticalScroll).

    Demos (เปิดผ่าน minimap submenu "Scroll / Overflow UI Tests"):
      A. Native H+V  — content กว้าง 1100 × สูงหลายแถว ใน viewport เล็ก
                       (resize หน้าต่างให้เล็ก → scrollbar โผล่ทั้งแนวนอน/ตั้ง)
      B. Native cap 20 rows — viewport สูง = 20 แถวพอดี; >20 → vertical scroll,
                       กว้างเกิน → horizontal scroll (= behavior ที่อยากได้ใน Defensive)
      C. AceGUI ScrollFrame — vertical อย่างเดียว (โชว์ข้อจำกัด: ไม่มี horizontal)

    แถว dummy เลียนแบบ Defensive row: [spellID] = name [MDT][X][▲][▼]

    Public: GeRODPS_Tools.ToggleScrollUITest("A"|"B"|"C")
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME = "GeRODPS_ToolsScrollUITestFrame"
local ROW_H      = 30
local ROW_W      = 760          -- ความกว้างเนื้อหา 1 แถว (id+name+4 ปุ่ม)
local CONTENT_W  = 1100         -- demo A: content กว้างกว่า ROW_W เพื่อโชว์ขอบขวาว่าง + h-scroll
local N_ROWS     = 35           -- จำนวนแถว dummy (>20 เพื่อโชว์ vertical scroll)

local frame, demoLabel
local _curDemo

-- ============================================================
-- ปุ่มเล็ก (mimic ปุ่ม row จริง)
-- ============================================================
local function MakeMiniButton(parent, text, w)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w or 40, 22)
    b:SetText(text)
    b:SetNormalFontObject(GameFontNormalSmall)
    b:SetHighlightFontObject(GameFontHighlightSmall)
    return b
end

-- 1 แถว dummy บน content frame ที่ y กำหนด
local function BuildDummyRow(content, idx, y)
    local row = CreateFrame("Frame", nil, content)
    row:SetSize(ROW_W, ROW_H - 4)
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 6, y)

    -- spellID box (EditBox จริง เพื่อโชว์ว่า native widget เลื่อนตามได้)
    local eb = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    eb:SetSize(84, 22); eb:SetPoint("LEFT", row, "LEFT", 4, 0)
    eb:SetAutoFocus(false); eb:SetText(tostring(1000000 + idx))
    eb:SetFontObject(GameFontHighlightSmall)

    local nm = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nm:SetPoint("LEFT", eb, "RIGHT", 10, 0); nm:SetWidth(240); nm:SetJustifyH("LEFT")
    nm:SetText("|cffe8ebf2= Demo Spell Name " .. idx .. "|r")

    local x = 300
    for _, spec in ipairs({ { "MDT", 70 }, { "X", 40 }, { "▲", 40 }, { "▼", 40 } }) do
        local b = MakeMiniButton(row, spec[1], spec[2])
        b:SetPoint("LEFT", row, "LEFT", x, 0)
        x = x + spec[2] + 6
    end
    return row
end

-- ============================================================
-- Slider (track + thumb) — ใช้ทั้งแนวตั้ง/นอน. onValue(v) เรียกตอนเลื่อน
-- ============================================================
local function MakeSlider(parent, orientation)
    local s = CreateFrame("Slider", nil, parent)
    s:SetOrientation(orientation)               -- "HORIZONTAL" | "VERTICAL"
    s:SetObeyStepOnDrag(true)
    s:SetValueStep(1)
    s:SetMinMaxValues(0, 0); s:SetValue(0)
    if orientation == "HORIZONTAL" then s:SetHeight(16) else s:SetWidth(16) end

    local bg = s:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(s); bg:SetColorTexture(0, 0, 0, 0.45)

    local thumb = s:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.55, 0.55, 0.6, 0.95)
    if orientation == "HORIZONTAL" then thumb:SetSize(40, 14) else thumb:SetSize(14, 40) end
    s:SetThumbTexture(thumb)
    return s
end

-- ============================================================
-- Native ScrollFrame demo (A / B) — content กว้าง/สูง ใน viewport เล็ก
--   capRows: ถ้า > 0 → viewport สูง = capRows แถวพอดี (demo B)
-- ============================================================
local function BuildNativeScrollArea(host, contentW, nRows, capRows)
    -- host = พื้นที่ใต้ title. สร้าง viewport + content + 2 scrollbar
    local PAD = 12
    local sf = CreateFrame("ScrollFrame", nil, host)
    -- เว้นขวา 18 (v-bar) + ล่าง 18 (h-bar)
    sf:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -PAD)
    sf:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -PAD - 18, PAD + 18)

    -- กรอบ viewport ให้เห็นขอบชัด
    local bd = sf:CreateTexture(nil, "BACKGROUND")
    bd:SetPoint("TOPLEFT", sf, -2, 2); bd:SetPoint("BOTTOMRIGHT", sf, 2, -2)
    bd:SetColorTexture(0.08, 0.09, 0.12, 0.9)

    local contentH = nRows * ROW_H + 12
    local content = CreateFrame("Frame", nil, sf)
    content:SetSize(contentW, contentH)
    sf:SetScrollChild(content)

    for i = 1, nRows do
        BuildDummyRow(content, i, -((i - 1) * ROW_H) - 6)
    end

    -- ถ้า cap: บังคับ viewport สูง = capRows แถว (host จะสูงกว่าได้ แต่ sf สูงเท่า cap)
    if capRows and capRows > 0 then
        sf:ClearAllPoints()
        sf:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -PAD)
        sf:SetSize(contentW + 0, capRows * ROW_H)   -- width จะถูก clamp ด้วย host จริงตอน show
        sf:SetPoint("RIGHT", host, "RIGHT", -PAD - 18, 0)   -- ให้กว้างตาม host (clamp)
        sf:SetHeight(capRows * ROW_H)
    end

    local hbar = MakeSlider(host, "HORIZONTAL")
    hbar:SetPoint("TOPLEFT", sf, "BOTTOMLEFT", 0, -4)
    hbar:SetPoint("RIGHT", sf, "RIGHT", 0, 0)
    hbar:SetScript("OnValueChanged", function(_, v) sf:SetHorizontalScroll(v) end)

    local vbar = MakeSlider(host, "VERTICAL")
    vbar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 4, 0)
    vbar:SetPoint("BOTTOM", sf, "BOTTOM", 0, 0)
    vbar:SetScript("OnValueChanged", function(_, v) sf:SetVerticalScroll(v) end)

    local function UpdateRanges()
        local hRange = sf:GetHorizontalScrollRange()
        local vRange = sf:GetVerticalScrollRange()
        hbar:SetMinMaxValues(0, math.max(0, hRange))
        vbar:SetMinMaxValues(0, math.max(0, vRange))
        -- ซ่อน bar ถ้าไม่ต้องเลื่อน
        if hRange and hRange > 1 then hbar:Show() else hbar:Hide() end
        if vRange and vRange > 1 then vbar:Show() else vbar:Hide() end
    end
    sf:SetScript("OnScrollRangeChanged", UpdateRanges)
    sf:SetScript("OnSizeChanged", UpdateRanges)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(_, delta)
        local v = vbar:GetValue() - delta * ROW_H * 2
        local lo, hi = vbar:GetMinMaxValues()
        if v < lo then v = lo elseif v > hi then v = hi end
        vbar:SetValue(v)
    end)
    C_Timer.After(0, UpdateRanges)   -- หลัง layout settle
    return sf
end

-- ============================================================
-- Vertical-only demo (C) — เลียนพฤติกรรม AceGUI ScrollFrame:
--   content width = viewport width (ตัดขวา ไม่มี h-bar), เลื่อนได้แค่แนวตั้ง
-- ============================================================
local function BuildVerticalOnlyArea(host)
    local PAD = 12
    local sf = CreateFrame("ScrollFrame", nil, host)
    sf:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -PAD)
    sf:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -PAD - 18, PAD)

    local bd = sf:CreateTexture(nil, "BACKGROUND")
    bd:SetPoint("TOPLEFT", sf, -2, 2); bd:SetPoint("BOTTOMRIGHT", sf, 2, -2)
    bd:SetColorTexture(0.08, 0.09, 0.12, 0.9)

    local contentH = N_ROWS * ROW_H + 12
    local content = CreateFrame("Frame", nil, sf)
    content:SetHeight(contentH)
    -- content กว้างเท่า viewport เสมอ (เลียน AceGUI: TOPLEFT+TOPRIGHT → ตัดขวา)
    content:SetWidth(ROW_W)
    sf:SetScrollChild(content)
    local function MatchWidth() content:SetWidth(sf:GetWidth()) end
    sf:SetScript("OnSizeChanged", MatchWidth)
    C_Timer.After(0, MatchWidth)

    for i = 1, N_ROWS do
        BuildDummyRow(content, i, -((i - 1) * ROW_H) - 6)
    end

    local vbar = MakeSlider(host, "VERTICAL")
    vbar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 4, 0)
    vbar:SetPoint("BOTTOM", sf, "BOTTOM", 0, 0)
    vbar:SetScript("OnValueChanged", function(_, v) sf:SetVerticalScroll(v) end)
    local function UpdateV()
        local vRange = sf:GetVerticalScrollRange()
        vbar:SetMinMaxValues(0, math.max(0, vRange))
        if vRange and vRange > 1 then vbar:Show() else vbar:Hide() end
    end
    sf:HookScript("OnScrollRangeChanged", UpdateV)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(_, delta)
        local v = vbar:GetValue() - delta * ROW_H * 2
        local lo, hi = vbar:GetMinMaxValues()
        v = math.max(lo, math.min(hi, v)); vbar:SetValue(v)
    end)
    C_Timer.After(0, UpdateV)
end

-- ============================================================
-- หน้าต่างหลัก (reuse, rebuild ต่อ demo)
-- ============================================================
local function ClearHost(host)
    -- ลบ child frames + ปล่อย AceGUI ที่ฝากไว้
    if host._aceRelease then host._aceRelease(); host._aceRelease = nil end
    for _, c in ipairs({ host:GetChildren() }) do c:Hide(); c:SetParent(nil) end
    for _, r in ipairs({ host:GetRegions() }) do if r.GetObjectType and r:GetObjectType() == "FontString" then r:Hide() end end
end

local DEMOS = {
    A = {
        title = "A · Native H+V — content 1100px ใน viewport เล็ก (resize หน้าต่างให้เล็ก → 2 scrollbar)",
        build = function(host) BuildNativeScrollArea(host, CONTENT_W, N_ROWS, 0) end,
    },
    B = {
        title = "B · Native cap 20 rows — >20 = v-scroll, กว้างเกิน = h-scroll (= ที่อยากได้ใน Defensive)",
        build = function(host) BuildNativeScrollArea(host, ROW_W, N_ROWS, 20) end,
    },
    C = {
        title = "C · Vertical-only (เลียน AceGUI) — กว้างเกิน = ตัดขวา ไม่มี h-scroll",
        build = function(host) BuildVerticalOnlyArea(host) end,
    },
}

local function BuildFrame()
    if frame then return frame end
    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(640, 720)   -- สูงพอแสดง ~20 แถว (demo B); ย่อเล็กเพื่อทดสอบ scroll ได้
    frame:SetPoint("CENTER")
    frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetResizable(true)
    if frame.SetResizeBounds then frame:SetResizeBounds(360, 240, 1500, 1000) end
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("HIGH")
    frame.TitleText:SetText("Scroll / Overflow UI Tests")

    demoLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    demoLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -28)
    demoLabel:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
    demoLabel:SetJustifyH("LEFT"); demoLabel:SetText("")

    -- host = พื้นที่เนื้อหา (ใต้ demoLabel)
    local host = CreateFrame("Frame", nil, frame)
    host:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -46)
    host:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 8)
    frame.host = host

    -- resize grip มุมล่างขวา
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16); grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

    return frame
end

local function ShowDemo(key)
    local d = DEMOS[key]; if not d then return end
    BuildFrame()
    ClearHost(frame.host)
    demoLabel:SetText("|cff7fb8d0" .. d.title .. "|r")
    d.build(frame.host)
    _curDemo = key
    frame:Show()
end

function TOOL.ToggleScrollUITest(key)
    key = key or "A"
    if frame and frame:IsShown() and _curDemo == key then
        frame:Hide(); return
    end
    ShowDemo(key)
end

-- ============================================================
-- Register submenu ใน minimap
-- ============================================================
if TOOL.RegisterSubmenu then
    TOOL.RegisterSubmenu("Scroll / Overflow UI Tests", {
        { label = "A · Native H+V (wide-in-small)", fn = function() TOOL.ToggleScrollUITest("A") end },
        { label = "B · Native cap 20 rows",         fn = function() TOOL.ToggleScrollUITest("B") end },
        { label = "C · AceGUI vertical-only",        fn = function() TOOL.ToggleScrollUITest("C") end },
    })
elseif TOOL.RegisterTool then
    TOOL.RegisterTool("Scroll UI Test (A)", function() TOOL.ToggleScrollUITest("A") end)
end
