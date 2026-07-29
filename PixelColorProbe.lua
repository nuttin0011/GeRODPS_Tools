--[[
    PixelColorProbe.lua

    วาด "ลายทดสอบสี" ทับแถบ pixel ของ GeRODPS (PixelAndBarSetup.lua) ที่ตำแหน่งเดียวกันเป๊ะ
    เพื่อพิสูจน์ว่า **สีที่ Lua สั่ง = สีที่ AHK อ่านได้จากหน้าจอ** หรือเพี้ยนระหว่างทาง

    ทำไมต้องมี: ถ้าสี pixel เพี้ยนแม้แต่นิดเดียว Rotation/Heal/Defensive อ่านค่าผิดหมด
    แต่แถบจริงมีค่าเปลี่ยนตลอดเวลา เทียบไม่ได้ ต้องมีลายที่ "รู้คำตอบล่วงหน้า" มาทับ

    วิธีใช้:
      1. เปิดจากเมนู minimap ของ GeRODPS Tools → "Pixel Color Probe (ตรวจสีเพี้ยน)"
      2. รัน GeRODPS_PixelColorCheck.ahk
      3. อ่านผล: เปิดอยู่ควรตรงทุกจุด · ไม่เปิดควรไม่ตรง (เพราะเป็นค่าจริงที่วิ่งอยู่)
         **เปิดแล้วยังไม่ตรง = สีเพี้ยนจริง**

    ⚠ ตัวเลขในไฟล์นี้ต้องตรงกับ GeRODPS_PixelColorCheck.ahk เป๊ะ — แก้ที่ไหนต้องแก้ทั้งคู่

    ── ลายบนแถวที่ 1 (pixel 0..99, y = 0) ────────────────────────────────────
      0        0x888888        marker เริ่มแถว — คงไว้ให้ AHK หาแถบเจอเหมือนเดิม
      1..16    (i, i, i)       เทาไล่ 1..16      ← ช่วงมืดมาก (STS layer stack ใช้ช่วงนี้)
      17..32   (i-16, 0, 0)    แดงไล่ 1..16
      33..48   (0, i-32, 0)    เขียวไล่ 1..16
      49..64   (0, 0, i-48)    น้ำเงินไล่ 1..16
      65..80   (k,k,k) k=(i-64)*16   เทาไล่หยาบ 16..256(→255)
      81..90   สีที่ระบบใช้งานจริง (ตารางตายตัว — ดู SPECIAL)
      91..98   มุมของช่วงสี (ดำ/ขาว/3 แม่สี/3 สีผสม)
      99       0x999999        marker จบแถว

    ── ลายบนแถวที่ 2 (slot 0..251, y = 1 px) ─────────────────────────────────
      0        0x666666        marker เริ่ม Row2
      251      0x444444        marker จบ Row2
      1..250   (s, 255-s, (s*5) mod 256)

    Public:
        GeRODPS_Tools.TogglePixelColorProbe()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local probeFrame          -- parent เดียว คุม show/hide ทั้งลาย
local ROW1_N = 100
local ROW2_N = 252

-- สีที่ระบบใช้งานจริง (index บนแถว 1 → {r,g,b} 0-255)
-- เลือกมาจากค่าที่ pipeline พึ่งพาจริง — ถ้าตัวไหนเพี้ยนคือพังทันที
local SPECIAL = {
    [81] = { 0x88, 0x88, 0x88 },   -- marker เริ่มแถว 1
    [82] = { 0x99, 0x99, 0x99 },   -- marker จบแถว 1
    [83] = { 0x66, 0x66, 0x66 },   -- marker เริ่มแถว 2
    [84] = { 0x44, 0x44, 0x44 },   -- marker จบแถว 2
    [85] = { 0x77, 0x77, 0x77 },   -- boundary ของ bar
    [86] = { 0x55, 0x55, 0x55 },   -- stop marker
    [87] = {   10,  150,   10 },   -- เส้นเขียวเริ่ม SendToString  ← ตัวที่เคยเพี้ยนเป็น 149
    [88] = {    0,    1,    1 },   -- background ของโซน bar
    [89] = {   10,   10,   40 },   -- PartyHealth: HP / Shield / Incoming
    [90] = {   10,   40,   10 },   -- PartyHealth: HealAbsorb
    [91] = {    0,    0,    0 },
    [92] = {  255,  255,  255 },
    [93] = {  255,    0,    0 },
    [94] = {    0,  255,    0 },
    [95] = {    0,    0,  255 },
    [96] = {  255,  255,    0 },
    [97] = {    0,  255,  255 },
    [98] = {  255,    0,  255 },
}

-- สีที่ควรได้ของ pixel แถว 1 ตำแหน่ง i (0..99) — คืน r,g,b เป็น 0-255
-- ⚠ ต้องเหมือนฟังก์ชัน ExpectedRow1() ใน GeRODPS_PixelColorCheck.ahk
local function ExpectedRow1(i)
    if i == 0  then return 0x88, 0x88, 0x88 end
    if i == 99 then return 0x99, 0x99, 0x99 end
    if SPECIAL[i] then
        local c = SPECIAL[i]
        return c[1], c[2], c[3]
    end
    if i <= 16 then return i, i, i end
    if i <= 32 then return i - 16, 0, 0 end
    if i <= 48 then return 0, i - 32, 0 end
    if i <= 64 then return 0, 0, i - 48 end
    local k = (i - 64) * 16
    if k > 255 then k = 255 end
    return k, k, k
end

-- สีที่ควรได้ของ slot แถว 2 ตำแหน่ง s (0..251)
local function ExpectedRow2(s)
    if s == 0   then return 0x66, 0x66, 0x66 end
    if s == 251 then return 0x44, 0x44, 0x44 end
    return s, 255 - s, (s * 5) % 256
end

-- 1 texture = 1 พิกเซลจริงบนจอ วางทับตำแหน่งเดียวกับ PixelAndBarSetup
--   PixelAndBarSetup: CreatePixel(pixelposition/scale, y, onePixel, ...) โดย onePixel = 1/scale
--   ⇒ pixel ที่ index i กินพื้นที่ x = i px จริง, กว้าง/สูง 1 px จริง
local function MakeDot(parent, xIndex, yPixels, onePixel, r, g, b)
    local t = parent:CreateTexture(nil, "OVERLAY", nil, 7)
    t:SetSize(onePixel, onePixel)
    t:SetPoint("TOPLEFT", parent, "TOPLEFT", xIndex * onePixel, -(yPixels * onePixel))
    t:SetSnapToPixelGrid(true)
    t:SetTexelSnappingBias(0)
    t:SetColorTexture(r / 255, g / 255, b / 255, 1)
    return t
end

local function Build()
    local scale = UIParent:GetEffectiveScale()
    local onePixel = 1 / scale

    probeFrame = CreateFrame("Frame", "GeRODPSPixelColorProbe", UIParent)
    probeFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    probeFrame:SetSize(onePixel * ROW2_N, onePixel * 2)
    -- ต้องอยู่เหนือ pixel จริงทุกกรณี ไม่งั้นทับไม่ติดแล้ววัดค่าเดิม
    probeFrame:SetFrameStrata("TOOLTIP")
    probeFrame:SetFrameLevel(9999)

    for i = 0, ROW1_N - 1 do
        MakeDot(probeFrame, i, 0, onePixel, ExpectedRow1(i))
    end
    for s = 0, ROW2_N - 1 do
        MakeDot(probeFrame, s, 1, onePixel, ExpectedRow2(s))
    end
    probeFrame:Hide()
end

function TOOL.TogglePixelColorProbe()
    if not probeFrame then Build() end
    if probeFrame:IsShown() then
        probeFrame:Hide()
        print("|cffffd100PixelColorProbe|r: ปิดลายทดสอบ — แถบกลับไปเป็นค่าจริง")
        return
    end
    probeFrame:Show()
    print("|cffffd100PixelColorProbe|r: เปิดลายทดสอบทับแถบแล้ว "
        .. "(แถว 1 = 100 จุด · แถว 2 = 252 จุด) — รัน GeRODPS_PixelColorCheck.ahk เพื่อเทียบ")
    print("  |cff9fc6ee81-90|r = สีที่ระบบใช้จริง (marker/เส้นเขียว/PartyHealth) "
        .. "· |cff9fc6ee1-64|r = ค่ามืดมาก ช่วงที่ STS layer ใช้")
end

SLASH_GERODPSPIXELPROBE1 = "/gepixelprobe"
SlashCmdList["GERODPSPIXELPROBE"] = function()
    TOOL.TogglePixelColorProbe()
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("Pixel Color Probe (ตรวจสีเพี้ยน)", TOOL.TogglePixelColorProbe)
end
