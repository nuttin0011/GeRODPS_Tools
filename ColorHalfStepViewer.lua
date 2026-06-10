--[[
    ColorHalfStepViewer.lua

    Viewer สีแบบ "ลดทีละครึ่ง" สำหรับ capture หน้าจอแล้ววัดสีจริง
    เพื่อพิสูจน์ว่า WoW แปลง float (0..1) -> pixel 8-bit ด้วยการปัดแบบไหน
    (floor หรือ round) — ผลใช้เลือก model ของ SendToString layer stack

    มี 2 กลุ่มทดสอบ บน canvas ดำสนิท (alpha 1):

    A) Direct float — SetColorTexture(1/2^k, 0, 0, 1) วาดสีตรงๆ
       วัดการ quantize ของค่าสี float ครั้งเดียว
       เช่น k=1: 0.5*255 = 127.5 -> อ่านได้ 127 (floor) หรือ 128 (round)?

    B) Alpha stack — สี่เหลี่ยมฐานสีเต็ม 1.0 (alpha 1) แล้วทับด้วย
       texture ดำ alpha 0.5 จำนวน k ชั้น
       วัดการปัดเศษของ GPU alpha-blend จริงต่อการทับ 1 ครั้ง
       (= พฤติกรรมเดียวกับ layer stack ที่จะใช้งานจริง)
       เช่น k=1: 255 ถูกทับ 1 ชั้น -> 127.5 -> 127 หรือ 128?

    แต่ละช่องมี label ใต้สี่เหลี่ยมเป็นค่าคาดหวัง "floor/round"
    เทียบกับสีที่วัดได้ -> ตรงกับฝั่งไหน = WoW ปัดแบบนั้น

    แถว R / G / B แยกกันเพื่อยืนยันว่าทุก channel ปัดเหมือนกัน

    Public:
        GeRODPS_Tools.ToggleColorHalfStepViewer()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME = "GeRODPS_ToolsColorHalfStepFrame"
local SQ        = 38    -- ขนาดสี่เหลี่ยม (px)
local GAP       = 6     -- ระยะห่างคอลัมน์
local STEPS     = 9     -- k = 0..8
local LABEL_W   = 56    -- ความกว้าง label หน้าแถว (R/G/B)
local ROW_H     = SQ + 16
local SIDE_PAD  = 12

local CONTENT_W = LABEL_W + STEPS * (SQ + GAP)
local FRAME_W   = CONTENT_W + SIDE_PAD * 2 + 16
local FRAME_H   = 898

-- Group D: ความเข้มที่ใช้ทดสอบการเขียน alpha 0.5 ครั้งแรกบนพื้นดำ
-- เลือกชุดที่มีทั้งกรณีหารลงตัว (192, 64) และกรณีเศษ .5 (255, 253, 129, ...)
local DIRECT_ALPHA_VALUES = { 255, 253, 192, 129, 127, 65, 64, 3, 1 }

local toolFrame

-- channel index -> สี (v = ความเข้ม 0..1)
local CHANNELS = {
    { name = "R", fn = function(v) return v, 0, 0 end },
    { name = "G", fn = function(v) return 0, v, 0 end },
    { name = "B", fn = function(v) return 0, 0, v end },
}

-- ============================================================
-- ค่าคาดหวัง
-- ============================================================

-- Group A: quantize ครั้งเดียวของ 255 / 2^k
local function ExpectedDirect(k)
    local raw = 255 / (2 ^ k)
    return math.floor(raw), math.floor(raw + 0.5), raw
end

-- Group B/C: ไล่ chain ทับดำ alpha 0.5 ทีละชั้น (ปัดทุกชั้น) จากค่าฐาน base
local function ExpectedStack(base, k)
    local f, r = base, base
    for _ = 1, k do
        f = math.floor(f / 2)
        r = math.floor(r / 2 + 0.5)
    end
    return f, r
end

-- ============================================================
-- Frame build
-- ============================================================

local function MakeText(parent, text, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetText(text)
    return fs
end

-- วาดกลุ่มทดสอบ 1 กลุ่ม (3 แถว R/G/B x STEPS คอลัมน์)
-- buildSquare(parent, chIdx, k) ต้องคืน frame ขนาด SQ x SQ
-- expectedFn(k) -> floorVal, roundVal
-- colLabelFn(k) -> ข้อความหัวคอลัมน์ (default "k=N")
local function BuildGroup(canvas, yTop, title, buildSquare, expectedFn, colLabelFn)
    local hdr = MakeText(canvas, title, "GameFontNormal")
    hdr:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, yTop)
    local y = yTop - 18

    -- column headers
    for k = 0, STEPS - 1 do
        local x = LABEL_W + k * (SQ + GAP)
        local ch = MakeText(canvas, colLabelFn and colLabelFn(k) or ("k=" .. k))
        ch:SetPoint("TOPLEFT", canvas, "TOPLEFT", x + 2, y)
    end
    y = y - 14

    for ci, chan in ipairs(CHANNELS) do
        local rowLbl = MakeText(canvas, chan.name, "GameFontNormalLarge")
        rowLbl:SetPoint("TOPLEFT", canvas, "TOPLEFT", 8, y - (SQ / 2) + 8)

        for k = 0, STEPS - 1 do
            local x = LABEL_W + k * (SQ + GAP)
            local sq = buildSquare(canvas, ci, k)
            sq:SetPoint("TOPLEFT", canvas, "TOPLEFT", x, y)

            -- label คาดหวังใต้สี่เหลี่ยม (เฉพาะแถวล่างสุดพอ — ค่าเท่ากันทุกแถว)
            if ci == #CHANNELS then
                local f, r = expectedFn(k)
                local txt = (f == r) and tostring(f)
                    or (tostring(f) .. "/" .. tostring(r))
                local lbl = MakeText(canvas, txt)
                lbl:SetPoint("TOP", sq, "BOTTOM", 0, -2)
            end
        end
        y = y - ROW_H
    end
    return y - 16   -- yTop ของ block ถัดไป
end

-- Group A square: สีตรง v = 1/2^k
local function BuildDirectSquare(canvas, ci, k)
    local f = CreateFrame("Frame", nil, canvas)
    f:SetSize(SQ, SQ)
    local t = f:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints(f)
    local v = 1 / (2 ^ k)
    t:SetColorTexture(CHANNELS[ci].fn(v))
    return f
end

-- Group B/C square: ฐานความเข้ม baseInt (0..255) + ทับดำ alpha 0.5 จำนวน k ชั้น
-- คืน builder function ตาม signature ของ BuildGroup
local function MakeStackSquareBuilder(baseInt)
    return function(canvas, ci, k)
        local f = CreateFrame("Frame", nil, canvas)
        f:SetSize(SQ, SQ)
        local base = f:CreateTexture(nil, "BACKGROUND")
        base:SetAllPoints(f)
        base:SetColorTexture(CHANNELS[ci].fn(baseInt / 255))
        for i = 1, k do
            -- ARTWORK subLevel -8..0 — วาดเรียงตามลำดับ = blend ทีละชั้นจริง
            local ov = f:CreateTexture(nil, "ARTWORK", nil, -8 + i)
            ov:SetAllPoints(f)
            ov:SetColorTexture(0, 0, 0, 0.5)
        end
        return f
    end
end

-- Group D square: วาดสีความเข้ม C ด้วย alpha 0.5 ตรงๆ บนพื้นดำ
-- (= การเขียนครั้งแรกของ layer จริงใน scheme: 0*0.5 + C*0.5)
local function BuildDirectAlphaSquare(canvas, ci, k)
    local f = CreateFrame("Frame", nil, canvas)
    f:SetSize(SQ, SQ)
    local C = DIRECT_ALPHA_VALUES[k + 1]
    local t = f:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints(f)
    local r, g, b = CHANNELS[ci].fn(C / 255)
    t:SetColorTexture(r, g, b, 0.5)
    return f
end

local function ExpectedDirectAlpha(k)
    local C = DIRECT_ALPHA_VALUES[k + 1]
    return math.floor(C / 2), math.floor(C / 2 + 0.5)
end

local function BuildFrame()
    if toolFrame then return end

    toolFrame = CreateFrame("Frame", FRAME_NAME, UIParent,
        "BasicFrameTemplateWithInset")
    toolFrame:SetSize(FRAME_W, FRAME_H)
    toolFrame:SetPoint("CENTER")
    toolFrame:SetMovable(true)
    toolFrame:EnableMouse(true)
    toolFrame:RegisterForDrag("LeftButton")
    toolFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    toolFrame:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    toolFrame:SetClampedToScreen(true)
    toolFrame:SetFrameStrata("DIALOG")
    if toolFrame.TitleText then
        toolFrame.TitleText:SetText("GeRODPS Tools - Color Half-Step Viewer")
    end

    local inset = toolFrame.Inset or toolFrame

    -- canvas ดำสนิทกันสีพื้นรบกวนการวัด
    local canvas = CreateFrame("Frame", nil, inset)
    canvas:SetPoint("TOPLEFT", inset, "TOPLEFT", SIDE_PAD, -10)
    canvas:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -SIDE_PAD, 10)
    local bg = canvas:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints(canvas)
    bg:SetColorTexture(0, 0, 0, 1)

    local y = -4
    y = BuildGroup(canvas, y,
        "A) Direct float : SetColorTexture(1/2^k)  (label = floor/round)",
        BuildDirectSquare, ExpectedDirect)
    y = BuildGroup(canvas, y,
        "B) Alpha stack : base 255 + black a=0.5 x k layers  (label = floor/round)",
        MakeStackSquareBuilder(255),
        function(k) return ExpectedStack(255, k) end)
    y = BuildGroup(canvas, y,
        "C) Alpha stack : base 128 + black a=0.5 x k layers  (label = floor/round)",
        MakeStackSquareBuilder(128),
        function(k) return ExpectedStack(128, k) end)
    y = BuildGroup(canvas, y,
        "D) Direct alpha : SetColorTexture(C/255, a=0.5) on black  (label = floor/round)",
        BuildDirectAlphaSquare, ExpectedDirectAlpha,
        function(k) return "C=" .. DIRECT_ALPHA_VALUES[k + 1] end)

    local hint = MakeText(canvas,
        "Capture หน้าจอแล้ววัดสีกลางช่อง: ตรงเลขซ้าย = WoW ปัดลง (floor), "
        .. "ตรงเลขขวา = ปัดขึ้น (round)")
    hint:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, y)
    hint:SetWidth(CONTENT_W)
    hint:SetJustifyH("LEFT")
end

-- ============================================================
-- Public API + register
-- ============================================================

function TOOL.ToggleColorHalfStepViewer()
    BuildFrame()
    if toolFrame:IsShown() then
        toolFrame:Hide()
    else
        toolFrame:Show()
    end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("Color Half-Step Viewer (วัดการปัดสี)",
        TOOL.ToggleColorHalfStepViewer)
end
