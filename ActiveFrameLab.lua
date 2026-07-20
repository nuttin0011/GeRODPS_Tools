--[[
    ActiveFrameLab.lua  (Dev tool)

    ทดสอบระบบ "Active Frame" ของ WoW แล้วออกแบบพฤติกรรม "inactive" ของเราเอง —
    ไม่ใช้วิธีแย่ง frame-strata/level กับ frame อื่น (ทดลองแล้วพบปัญหา: frame ของเรา
    "หลบไปข้างหลัง" ก็จริง แต่ทำให้ frame คนอื่นทุกใบ (ที่ไม่เกี่ยวกับ frame ที่เพิ่งคลิก)
    ดูเหมือน "โดนดันมาข้างหน้า" ไปด้วย เพราะเราไม่ได้ควบคุม frame เหล่านั้น — ไม่เหมือน
    พฤติกรรม Active Window ของ OS ที่มีแค่ 1 window มาหน้าสุด ที่เหลืออยู่ตำแหน่งเดิม)

    แนวทางใหม่: แทนที่จะแย่ง z-order กับใคร — inactive แล้ว "หด" ตัวเองเป็น "Minimize Box"
    100x100 ที่ layer สูงสุดเสมอ (ไม่ต้องแข่ง strata กับใคร เพราะพื้นที่เล็กมาก) แสดงชื่อ
    + สถานะ "inactive" ลาก Minimize Box ไปมาได้อิสระ คลิกที่กล่อง = restore กลับที่ตำแหน่ง
    เดิมของ frame จริงเสมอ (ไม่เกี่ยวกับตำแหน่งกล่อง) — inactive ครั้งถัดไป Minimize Box
    โผล่ที่ตำแหน่งล่าสุดที่เคยลากไว้ (ไม่รีเซ็ตกลับมุมซ้ายบนของ frame ทุกครั้ง)

    ปุ่ม Minimize (มุมบนซ้ายของ Frame): กดแล้ว minimize ไปเป็น Minimize Box ทันที — ทางเลือก
    เพิ่มจากการคลิกที่อื่น (เดิมมีแค่ auto-minimize ตอนคลิก frame อื่น)

    กลไกตรวจจับ "คลิกที่อื่น" (ไม่มี usage เดิมในโปรเจกต์ทั้ง 3 addon — grep ยืนยันแล้ว):
      GLOBAL_MOUSE_DOWN  → classic frame event (เพิ่มมา patch 8.3.0) ยิงทุกครั้งที่กด
                            เมาส์ปุ่มใดก็ตาม "ที่ไหนก็ได้บนจอ" ส่ง button name มาด้วย
      GetMouseFoci()     → คืน table ของ frame ใต้เมาส์ ณ ขณะนั้น (index 1 = บนสุด) —
                            ใช้ระบุว่า "คลิกโดนอะไร" แล้วเดิน parent-chain เทียบว่าเป็น
                            ลูกหลานของเราไหม

    ⚠ GetMouseFoci() บางครั้งคืน object แปลก (forbidden/restricted) ที่เรียก method
    แล้ว error — pattern ป้องกัน (pcall ครอบทั้งการเดิน chain) ยืมมาจาก
    GeRODPS/MouseOverUnitFrame.lua RawCheck ที่เจอปัญหานี้มาก่อนแล้วจริงในเกม

    ปุ่มลัดในหน้าต่าง: เปิด Character Panel / เปิด Backpack — ทดสอบว่าทำงานกับ frame
    ของ Blizzard เองได้จริง (ไม่ใช่แค่ frame ของ addon เดียวกัน)

    Log panel แสดงทุก click event ที่ตรวจจับ (คลิกโดนอะไร ตัดสินใจยังไง) real-time

    Public:
        GeRODPS_Tools.ToggleActiveFrameLab()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

-- ทั้งไฟล์นี้พึ่ง AceGUI ทั้งหมด (ตาม house convention: PasteSpeedTest.lua/RebuildLagTest.lua/
-- ReorderPerfLab.lua) — AceGUI ไม่ได้ bundle มากับ GeRODPS_Tools เอง แต่มากับ GeRODPS ที่โหลด
-- คู่กันปกติ; ไม่มี AceGUI (ปิด GeRODPS แยก) = ข้าม tool นี้ทั้งก้อนอย่างเงียบๆ แทนที่จะ error
local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
if not AceGUI then return end

local TOOL_TITLE   = "Active Frame Lab (Dev)"
local BOX_NAME_LABEL = "Active Frame Lab"   -- ชื่อในกล่อง 100x100 — สั้นกว่า TOOL_TITLE กัน wrap ชน label ล่าง
local BOX_SIZE     = 100
local MAX_LOG_LINES = 14
local OPEN_GRACE_SEC = 0.15   -- กันแฟลชกลับสถานะทันทีจากคลิกเดียวกันที่เพิ่งเปิด/restore

local frame          -- AceGUI Frame widget (singleton, สร้างครั้งเดียว ไม่ Release)
local box            -- native Button — Minimize Box 100x100 (singleton, สร้างครั้งแรกที่ minimize)
local boxNameFS
local logBox         -- AceGUI MultiLineEditBox — read-only log
local isActive    = true
local logLines    = {}
local justOpenedAt = 0   -- GetTime() ตอน show/restore ล่าสุด — ดู EnsureMouseListener guard

-- ============================================================
-- Log helper
-- ============================================================
local function AddLog(text)
    table.insert(logLines, 1, text)
    while #logLines > MAX_LOG_LINES do
        table.remove(logLines)
    end
    if logBox then
        logBox:SetText(table.concat(logLines, "\n"))
    end
end

-- ============================================================
-- Minimize (inactive -> Minimize Box) / Restore (กลับเป็น frame เต็ม ตำแหน่งเดิม)
-- ============================================================

-- สร้าง Minimize Box ครั้งแรกเท่านั้น — anchor เริ่มต้น = มุมบนซ้ายของ frame จริง ณ ตอนนั้น
-- (สัมพัทธ์ชั่วคราวแล้ว "แช่แข็ง" เป็นพิกัดสัมบูรณ์ทันที กัน box ลากตามถ้า main frame
-- ถูกย้ายภายหลัง — ตำแหน่ง box ต้อง independent จาก frame ตั้งแต่นาทีนี้เป็นต้นไป)
-- ครั้งถัดไปที่ minimize จะไม่เข้าโค้ดนี้อีก (guard `if box then return end`) — box จึงอยู่
-- ตำแหน่งล่าสุดที่ user ลากไว้เสมอ ตามสเปค
local function EnsureBox()
    if box then return end

    box = CreateFrame("Button", nil, UIParent, "BackdropTemplate")
    box:SetSize(BOX_SIZE, BOX_SIZE)
    box:SetFrameStrata("TOOLTIP")   -- layer สูงสุด — ไม่ต้องแข่ง strata กับใคร (พื้นที่เล็กมาก)
    box:SetToplevel(true)
    box:SetMovable(true)
    box:EnableMouse(true)
    box:RegisterForDrag("LeftButton")
    box:SetScript("OnDragStart", box.StartMoving)
    box:SetScript("OnDragStop", box.StopMovingOrSizing)
    box:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })

    boxNameFS = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    boxNameFS:SetPoint("TOP", box, "TOP", 0, -12)
    boxNameFS:SetWidth(BOX_SIZE - 14)
    boxNameFS:SetJustifyH("CENTER")
    boxNameFS:SetText(BOX_NAME_LABEL)   -- ชื่อย่อ (ไม่ใช่ TOOL_TITLE เต็ม) — กล่องเล็กลง กัน wrap ชนกัน

    local stateFS = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    stateFS:SetPoint("BOTTOM", box, "BOTTOM", 0, 10)
    stateFS:SetText("|cff888888(inactive)|r")

    local hintFS = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintFS:SetPoint("BOTTOM", stateFS, "TOP", 0, 1)
    hintFS:SetText("|cff666666click = restore|r")

    -- ตำแหน่งเริ่มต้น: มุมบนซ้ายของ frame จริง ณ ตอนนี้ -> แช่แข็งเป็นพิกัดสัมบูรณ์
    box:SetPoint("TOPLEFT", frame.frame, "TOPLEFT", 0, 0)
    local l, t = box:GetLeft(), box:GetTop()
    if l and t then
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
    end

    -- "Up" เท่านั้น (ไม่ใส่ "AnyDown") — ให้ engine แยกคลิกจริงกับ drag เอง (RegisterForDrag
    -- ด้านบนจับ drag ไปแล้ว; ถ้าใส่ *Down ด้วย OnClick จะยิงตั้งแต่กดลง = drag ไม่ทันเริ่มก็ถูก
    -- restore ไปก่อน + คลิกปกติจะยิงซ้อน 2 รอบ (down+up)) ดู wow-coding review ก่อน commit
    box:RegisterForClicks("LeftButtonUp")
    box:SetScript("OnClick", function()
        TOOL.RestoreActiveFrameLab()
    end)

    box:Hide()
end

function TOOL.MinimizeActiveFrameLab()
    if not frame then return end
    isActive = false
    EnsureBox()
    frame:Hide()
    box:Show()
    AddLog("|cff888888-> minimized (Minimize Box ที่ตำแหน่งล่าสุด)|r")
end

-- restore = กลับเป็น frame เต็ม "ตำแหน่งเดิมของ frame จริง" เสมอ — ไม่เกี่ยวกับตำแหน่งกล่อง
-- (frame.frame ไม่เคยถูกแตะตำแหน่งเลยระหว่าง minimize — Hide() ไม่กระทบ GetPoint/GetLeft/GetTop)
function TOOL.RestoreActiveFrameLab()
    if not frame then return end
    isActive = true
    if box then box:Hide() end
    frame:Show()
    justOpenedAt = GetTime()   -- กันแฟลชกลับไป minimize ทันทีจากคลิกเดียวกันที่เพิ่ง restore
    AddLog("|cff3fcf5a-> restored (ตำแหน่งเดิมของ frame)|r")
end

-- ============================================================
-- Global click-elsewhere detection — GLOBAL_MOUSE_DOWN + GetMouseFoci
-- ============================================================

-- forbidden/restricted focus object anomaly — log แล้วข้าม (ไม่เปลี่ยน state)
-- pattern เดียวกับ GeRODPS/MouseOverUnitFrame.lua (เจอ bug นี้จริงมาก่อนแล้ว)
local lastBadLogAt = 0
local function LogBadFocus(errMsg)
    local now = (GetTime and GetTime()) or 0
    if (now - lastBadLogAt) < 10 then return end
    lastBadLogAt = now
    AddLog("|cffff6600anomalous focus (err=" .. tostring(errMsg) .. ")|r")
end

-- เดิน parent-chain ของ focus ขึ้นไป — true ถ้าเจอ frame ของเรา (self หรือ ancestor ใดๆ)
-- เรียกผ่าน pcall เสมอ (ตัวเรียก) — method GetParent อาจ error กลางทางถ้าเจอ forbidden frame
local function IsPartOfMyFamily(focus)
    if not frame then return false end
    local mine = frame.frame
    local f = focus
    local hops = 0
    while f ~= nil and hops < 32 do   -- 32 = กันวน parent-chain ผิดปกติ (ไม่ควรลึกขนาดนี้จริง)
        if f == mine then return true end
        if f.GetParent then
            f = f:GetParent()
        else
            f = nil
        end
        hops = hops + 1
    end
    return false
end

local function SafeGetName(focus)
    local name = "(unnamed)"
    pcall(function()
        if focus.GetName then
            name = tostring(focus:GetName() or "(unnamed)")
        end
    end)
    return name
end

local mouseListener
local function EnsureMouseListener()
    if mouseListener then return end
    mouseListener = CreateFrame("Frame")
    mouseListener:RegisterEvent("GLOBAL_MOUSE_DOWN")
    mouseListener:SetScript("OnEvent", function(_, _, button)
        if not isActive then return end   -- minimized -> box คลิกเองผ่าน RestoreActiveFrameLab
        if not (frame and frame:IsShown()) then return end
        if (GetTime() - justOpenedAt) < OPEN_GRACE_SEC then return end

        local foci = GetMouseFoci and GetMouseFoci() or nil
        if not foci or #foci == 0 then
            -- ไม่มี frame ใดใต้เมาส์ (คลิกโลก 3D เปล่าๆ) — นับเป็น "คลิกที่อื่น" เช่นกัน
            AddLog(button .. ": (โลก/ไม่มี frame ใต้เมาส์) -> Minimize Box")
            TOOL.MinimizeActiveFrameLab()
            return
        end

        local topFocus = foci[1]
        if type(topFocus) ~= "table" then
            AddLog(button .. ": (focus ไม่ใช่ table ผิดปกติ) -> Minimize Box")
            TOOL.MinimizeActiveFrameLab()
            return
        end

        local ok, mine = pcall(IsPartOfMyFamily, topFocus)
        if not ok then
            LogBadFocus(mine)   -- mine = error message เมื่อ ok == false
            return
        end

        if mine then
            return   -- คลิกโดน frame ของเราเอง — active อยู่แล้ว ไม่ต้องทำอะไร
        end

        local name = SafeGetName(topFocus)
        AddLog(button .. ": " .. name .. " (frame อื่น) -> Minimize Box")
        TOOL.MinimizeActiveFrameLab()
    end)
end

-- ============================================================
-- Window
-- ============================================================
local function BuildWindow()
    frame = AceGUI:Create("Frame")
    frame:SetTitle(TOOL_TITLE)
    frame:SetStatusText("คลิกที่อื่น (รวม Blizzard panel) หรือกดปุ่ม [_] มุมบนขวา = หดเป็น Minimize Box | คลิกกล่อง = restore ตำแหน่งเดิม")
    frame:SetWidth(520)
    frame:SetHeight(400)
    frame:SetLayout("Flow")
    frame:SetCallback("OnClose", function(w)
        w:Hide()
        if box then box:Hide() end
    end)   -- ไม่ Release — เก็บ state ไว้ใช้ซ้ำ (singleton, เหมือน ReorderPerfLab/DPSAverageFrame)

    -- ปุ่ม Minimize มุมบนขวาของ Frame — ทางลัด minimize เอง (ไม่ต้องรอคลิก frame อื่น)
    -- เป็น native Button ผูกกับ frame.frame ตรงๆ (นอกระบบ Flow layout ของ AceGUI) เพราะต้อง
    -- ปักอยู่ตำแหน่งมุมสัมบูรณ์ — AceGUI Frame title tab อยู่กลางบน + ปุ่ม Close จริงอยู่ล่างขวา
    -- (ดู AceGUIContainer-Frame.lua:199-204) มุมบนขวาจึงว่าง ไม่ทับอะไร
    --
    -- ดีไซน์ = "B8 + C1" จาก gallery เทียบ 20 แบบ (planHTML ไม่ได้ทำ, เทียบผ่าน Artifact):
    --   B8 = flat, ไม่มี Blizzard skin — gradient แดงอ่อนบน/เข้มล่าง (CreateColor+SetGradient ล้วน
    --        ไม่พึ่ง texture file ใดๆ — SetColorTexture/SetGradient ทำงานได้เองไม่ต้องมี template)
    --   C1 = glyph "_" (underscore) แทน "-"
    -- ขนาด 29x26 = ใหญ่กว่าปุ่มเดิม 24x22 อีก 20%
    local BTN_W, BTN_H = 29, 26
    local minimizeBtn = CreateFrame("Button", nil, frame.frame)
    minimizeBtn:SetSize(BTN_W, BTN_H)
    minimizeBtn:SetPoint("TOPRIGHT", frame.frame, "TOPRIGHT", -8, -6)
    minimizeBtn:SetFrameLevel(frame.frame:GetFrameLevel() + 10)

    -- ขอบ (border) = texture สีทึบชั้นล่าง + fill gradient inset 1px ทับด้านบน — ไม่มี skin/texture file
    local btnBorder = minimizeBtn:CreateTexture(nil, "BACKGROUND")
    btnBorder:SetAllPoints(minimizeBtn)
    btnBorder:SetColorTexture(0.36, 0.11, 0.11, 1)

    local GRAD_TOP    = CreateColor(0.76, 0.29, 0.29, 1)
    local GRAD_BOTTOM = CreateColor(0.48, 0.14, 0.14, 1)
    local GRAD_TOP_HI    = CreateColor(0.85, 0.35, 0.35, 1)   -- hover
    local GRAD_BOTTOM_HI = CreateColor(0.55, 0.17, 0.17, 1)
    local btnFill = minimizeBtn:CreateTexture(nil, "BACKGROUND", nil, 1)
    btnFill:SetPoint("TOPLEFT", btnBorder, "TOPLEFT", 1, -1)
    btnFill:SetPoint("BOTTOMRIGHT", btnBorder, "BOTTOMRIGHT", -1, 1)
    btnFill:SetGradient("VERTICAL", GRAD_TOP, GRAD_BOTTOM)

    local btnGlyph = minimizeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btnGlyph:SetPoint("CENTER", minimizeBtn, "CENTER", 0, 1)
    btnGlyph:SetText("_")
    btnGlyph:SetTextColor(0.96, 0.93, 0.88, 1)

    minimizeBtn:SetScript("OnEnter", function() btnFill:SetGradient("VERTICAL", GRAD_TOP_HI, GRAD_BOTTOM_HI) end)
    minimizeBtn:SetScript("OnLeave", function() btnFill:SetGradient("VERTICAL", GRAD_TOP, GRAD_BOTTOM) end)
    minimizeBtn:SetScript("OnClick", function()
        TOOL.MinimizeActiveFrameLab()
    end)

    local info = AceGUI:Create("Label")
    info:SetFullWidth(true)
    info:SetText("|cffe8d8a0คลิก frame นี้แล้วอยู่หน้าสุดได้ฟรีจาก AceGUI (SetToplevel ในตัวเอง). "
        .. "ทดสอบฝั่งตรงข้าม: คลิกที่อื่น (รวม Blizzard panel เอง) หรือกดปุ่ม [_] มุมบนขวา -> "
        .. "frame นี้หดเป็น Minimize Box 100x100 มุมบนซ้ายของตำแหน่งเดิม (ครั้งถัดไปคงตำแหน่งที่ลากไว้ล่าสุด). "
        .. "คลิกที่กล่อง = กลับมาที่เดิมเป๊ะ|r")
    frame:AddChild(info)

    -- ปุ่มทดสอบกับ frame ของ Blizzard เอง
    local testRow = AceGUI:Create("SimpleGroup")
    testRow:SetFullWidth(true); testRow:SetLayout("Flow")
    frame:AddChild(testRow)

    local btnChar = AceGUI:Create("Button")
    btnChar:SetText("Toggle Character Panel (Blizzard)")
    btnChar:SetWidth(270)
    btnChar:SetCallback("OnClick", function()
        if ToggleCharacter then ToggleCharacter("PaperDollFrame") end
    end)
    testRow:AddChild(btnChar)

    local btnBag = AceGUI:Create("Button")
    btnBag:SetText("Toggle Backpack (Blizzard)")
    btnBag:SetWidth(220)
    btnBag:SetCallback("OnClick", function()
        if ToggleAllBags then ToggleAllBags() elseif ToggleBackpack then ToggleBackpack() end
    end)
    testRow:AddChild(btnBag)

    -- log
    local logLabel = AceGUI:Create("Label")
    logLabel:SetFullWidth(true); logLabel:SetFontObject(GameFontHighlight)
    logLabel:SetText("|cffffd200Log (คลิกล่าสุดอยู่บนสุด)|r")
    frame:AddChild(logLabel)

    local logGroup = AceGUI:Create("SimpleGroup")
    logGroup:SetFullWidth(true); logGroup:SetHeight(180); logGroup:SetLayout("Fill")
    frame:AddChild(logGroup)

    logBox = AceGUI:Create("MultiLineEditBox")
    logBox:SetLabel("")
    logBox:SetFullWidth(true); logBox:SetFullHeight(true)
    logBox:DisableButton(true)
    logGroup:AddChild(logBox)

    local clearBtn = AceGUI:Create("Button")
    clearBtn:SetText("Clear Log")
    clearBtn:SetWidth(120)
    clearBtn:SetCallback("OnClick", function()
        logLines = {}
        if logBox then logBox:SetText("") end
    end)
    frame:AddChild(clearBtn)

    EnsureMouseListener()

    -- AceGUI Frame:OnAcquire เรียก Show() ให้เองเสมอ (ยืนยันจาก AceGUIContainer-Frame.lua) —
    -- Hide() ทันทีหลังสร้าง กัน ToggleActiveFrameLab เรียกครั้งแรกแล้วเจอ frame โชว์อยู่แล้ว
    -- (จะตีความว่า "เปิดอยู่ กดปิด" แล้วซ่อนกลับไปเงียบๆ โดย user ไม่เห็นหน้าต่างเลยสักครั้ง)
    frame:Hide()
end

-- ============================================================
-- Public toggle + registration
-- ============================================================
function TOOL.ToggleActiveFrameLab()
    if not frame then
        BuildWindow()
    end
    local frameShown = frame:IsShown()
    local boxShown = box and box:IsShown()
    if frameShown or boxShown then
        frame:Hide()
        if box then box:Hide() end
        return
    end
    isActive = true
    frame:Show()
    justOpenedAt = GetTime()   -- กันแฟลชเป็น minimize ทันทีจากคลิก (menu item) ที่เพิ่งเปิดหน้าต่างนี้
    AddLog("|cff888888--- เปิดหน้าต่าง ---|r")
end

TOOL.RegisterTool("Active Frame Lab (click-to-front / minimize-elsewhere)", TOOL.ToggleActiveFrameLab)
