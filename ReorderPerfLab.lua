--[[
    ReorderPerfLab.lua  (Dev tool)

    ทดสอบความเร็วปุ่ม [^][v] (สลับลำดับ item ใน list) เมื่อ item เยอะมาก —
    เทียบ 3 วิธี ให้เลือกไปใช้กับ list จริง (Defensive / Interrupt-Stun):

      A. Full Rebuild (แบบปัจจุบันใน project) — swap data แล้ว ReleaseChildren +
         สร้าง AceGUI widget ใหม่ทุกแถว (แถวละ ~7 widget) → O(n) ต่อคลิก
      B. In-place Swap — สร้างแถว AceGUI ครั้งเดียว (data-driven: แถว i แสดง data[i]);
         [^][v] แค่ swap data แล้ว SetText เฉพาะ 2 แถวที่เกี่ยว → O(1) ต่อคลิก
         (หมายเหตุ: list จริงมี separator คนละหน้าตา — ของจริงต้องทำเป็น
          "rebuild เฉพาะแถวที่เปลี่ยน" แทน SetText ล้วน แต่ต้นทุนยัง O(1) เท่ากัน)
      C. Virtual Scroll — native frame pool แสดงเฉพาะแถวที่มองเห็น (~15 แถว)
         + slider/ล้อเมาส์; [^][v] = swap data + refresh เฉพาะ window → O(visible)
         คงที่ไม่ว่า item กี่พัน (ทั้ง build แรกและทุกคลิก)

    UI: ปุ่มสลับโหมด A/B/C · [+1][+5][+10] add random item · [Reset 200] ·
    status: จำนวน item + เวลา build โหมด + เวลาที่ใช้ต่อการกด [^][v] ล่าสุด (ms)
    เวลาวัดด้วย debugprofilestop() คร่อมทั้ง handler (swap + UI update ที่เกิด
    synchronous ใน click) — GPU paint ไม่นับ แต่เทียบระหว่างโหมดได้ตรง

    Public:
        GeRODPS_Tools.ToggleReorderPerfLab()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME = "GeRODPS_ToolsReorderPerfLabFrame"
local DEFAULT_W, DEFAULT_H = 860, 620
local SEED_COUNT = 200

local frame                 -- native window
local statusFS, timeFS      -- status FontStrings
local modeButtons = {}
local currentMode = "A"

-- ============================================================
-- Mock data
-- ============================================================
local items = {}            -- { {id, name}, ... }
local _nameWords = { "Arcane", "Void", "Burst", "Screech", "Nova", "Bolt", "Surge",
    "Shackles", "Vacuum", "Winds", "Fissure", "Ambush", "Beam", "Residue", "Dispersal" }

local function RandomItem()
    local id = math.random(100000, 1299999)
    local name = _nameWords[math.random(#_nameWords)] .. " " .. _nameWords[math.random(#_nameWords)]
    return { id = id, name = name }
end

local function SeedItems(n)
    items = {}
    for _ = 1, n do items[#items + 1] = RandomItem() end
end

-- ============================================================
-- Status
-- ============================================================
local lastBuildMs, lastMoveMs = 0, nil

local function UpdateStatus()
    if statusFS then
        statusFS:SetText(("Items: |cffffd200%d|r   Mode: |cffffd200%s|r   build: %.2f ms")
            :format(#items, currentMode, lastBuildMs))
    end
    if timeFS then
        timeFS:SetText(lastMoveMs
            and ("|cff3fcf5a[^][v] ล่าสุด: %.2f ms|r"):format(lastMoveMs)
            or "|cff888888(ยังไม่ได้กด [^][v])|r")
    end
end

-- ============================================================
-- Mode plumbing — แต่ละโหมด implement { Build(host), Move(idx, dir), AddItems(n) }
--   Build = สร้าง UI list ใหม่ทั้งหมดใน host (native frame)
--   Move  = swap data + อัปเดต UI ตามวิธีของโหมด (คืน ms ไม่ต้อง — วัดข้างนอก)
-- ============================================================
local modes = {}
local listHost             -- native frame พื้นที่ list (ลูกของ frame)
local activeModeObj

local function SwapData(idx, dir)
    local j = idx + dir
    if items[idx] and items[j] then
        items[idx], items[j] = items[j], items[idx]
        return j
    end
    return nil
end

local function TimedMove(idx, dir)
    if not activeModeObj then return end
    local t0 = debugprofilestop()
    activeModeObj.Move(idx, dir)
    lastMoveMs = debugprofilestop() - t0
    UpdateStatus()
end

local function TimedBuild()
    if not activeModeObj then return end
    local t0 = debugprofilestop()
    activeModeObj.Build(listHost)
    lastBuildMs = debugprofilestop() - t0
    UpdateStatus()
end

local function HasAce()
    return LibStub and LibStub("AceGUI-3.0", true)
end

-- ============================================================
-- helper: เคลียร์ host (ทั้ง AceGUI container ที่ฝากไว้ + native children)
-- ============================================================
local function ResetHost()
    if listHost._aceContainer then
        listHost._aceContainer:Release()
        listHost._aceContainer = nil
    end
    if listHost._virtualRows then
        for _, r in ipairs(listHost._virtualRows) do r:Hide() end
        listHost._virtualRows = nil
        if listHost._slider then listHost._slider:Hide() end
    end
    listHost._rowRefs = nil
end

-- ============================================================
-- AceGUI row (โหมด A/B ใช้ร่วม) — เลียนแถวจริง: [idEB][name][sum][Edit][X][^][v]
-- refs (โหมด B) เก็บ widget ที่ต้อง SetText ตอน swap
-- ============================================================
local function BuildAceRow(AceGUI, scrollAce, idx, onMove, refs)
    local row = AceGUI:Create("SimpleGroup")
    row:SetWidth(760); row:SetLayout("Flow")
    scrollAce:AddChild(row)

    local it = items[idx]
    local idEB = AceGUI:Create("EditBox")
    idEB:SetLabel(""); idEB:SetWidth(86); idEB:SetText(tostring(it.id))
    row:AddChild(idEB)

    local nameLbl = AceGUI:Create("Label")
    nameLbl:SetWidth(170); nameLbl:SetText("|cffe8ebf2= " .. it.name .. "|r")
    row:AddChild(nameLbl)

    local sumLbl = AceGUI:Create("Label")
    sumLbl:SetWidth(150); sumLbl:SetText("|cff9fb3c8#" .. idx .. " · kick|r")
    row:AddChild(sumLbl)

    local edBtn = AceGUI:Create("Button"); edBtn:SetText("Edit"); edBtn:SetWidth(70)
    row:AddChild(edBtn)
    local xBtn = AceGUI:Create("Button"); xBtn:SetText("X"); xBtn:SetWidth(44)
    row:AddChild(xBtn)

    local up = AceGUI:Create("Button"); up:SetText("^"); up:SetWidth(44)
    up:SetCallback("OnClick", function() onMove(idx, -1) end)
    row:AddChild(up)
    local dn = AceGUI:Create("Button"); dn:SetText("v"); dn:SetWidth(44)
    dn:SetCallback("OnClick", function() onMove(idx, 1) end)
    row:AddChild(dn)

    if refs then
        refs[idx] = { idEB = idEB, nameLbl = nameLbl, sumLbl = sumLbl }
    end
end

local function MakeAceScroll(AceGUI)
    local container = AceGUI:Create("SimpleGroup")
    container:SetLayout("Fill")
    container.frame:SetParent(listHost)
    container.frame:ClearAllPoints()
    container.frame:SetAllPoints(listHost)
    container.frame:Show()
    local scrollAce = AceGUI:Create("ScrollFrame")
    scrollAce:SetLayout("List")
    container:AddChild(scrollAce)
    listHost._aceContainer = container
    return scrollAce
end

-- ============================================================
-- Mode A — Full Rebuild (แบบปัจจุบัน): ทุกคลิก = สร้างใหม่ทุกแถว
-- ============================================================
modes.A = {
    Build = function()
        ResetHost()
        local AceGUI = HasAce(); if not AceGUI then return end
        local scrollAce = MakeAceScroll(AceGUI)
        listHost._aceScroll = scrollAce
        for i = 1, #items do
            BuildAceRow(AceGUI, scrollAce, i, TimedMove, nil)
        end
    end,
    Move = function(idx, dir)
        if not SwapData(idx, dir) then return end
        -- เหมือน RefreshDamageList จริง: ReleaseChildren + สร้างทุกแถวใหม่
        local AceGUI = HasAce(); if not AceGUI then return end
        local scrollAce = listHost._aceScroll
        scrollAce:ReleaseChildren()
        for i = 1, #items do
            BuildAceRow(AceGUI, scrollAce, i, TimedMove, nil)
        end
    end,
    AddItems = function(n)
        for _ = 1, n do items[#items + 1] = RandomItem() end
        TimedBuild()   -- แบบปัจจุบัน: add แล้ว rebuild ทั้ง list
    end,
}

-- ============================================================
-- Mode B — In-place Swap: แถวอยู่กับที่ (ผูกกับ "ตำแหน่ง"), swap แล้ว SetText 2 แถว
-- ============================================================
local function BRefreshRow(refs, i)
    local r = refs[i]; local it = items[i]
    if not (r and it) then return end
    r.idEB:SetText(tostring(it.id))
    r.nameLbl:SetText("|cffe8ebf2= " .. it.name .. "|r")
    r.sumLbl:SetText("|cff9fb3c8#" .. i .. " · kick|r")
end

modes.B = {
    Build = function()
        ResetHost()
        local AceGUI = HasAce(); if not AceGUI then return end
        local scrollAce = MakeAceScroll(AceGUI)
        listHost._aceScroll = scrollAce
        local refs = {}
        listHost._rowRefs = refs
        for i = 1, #items do
            BuildAceRow(AceGUI, scrollAce, i, TimedMove, refs)
        end
    end,
    Move = function(idx, dir)
        local j = SwapData(idx, dir)
        if not j then return end
        local refs = listHost._rowRefs
        BRefreshRow(refs, idx)
        BRefreshRow(refs, j)
    end,
    AddItems = function(n)
        -- append เฉพาะแถวใหม่ (ไม่แตะแถวเดิม)
        local AceGUI = HasAce(); if not AceGUI then return end
        local scrollAce = listHost._aceScroll
        local refs = listHost._rowRefs
        if not (scrollAce and refs) then return end
        for _ = 1, n do
            items[#items + 1] = RandomItem()
            BuildAceRow(AceGUI, scrollAce, #items, TimedMove, refs)
        end
    end,
}

-- ============================================================
-- Mode C — Virtual Scroll: native row pool แสดงเฉพาะที่มองเห็น + slider
-- ============================================================
local C_ROW_H = 26

local function CEnsureRows()
    if listHost._virtualRows then return end
    local h = listHost:GetHeight()
    if not h or h < C_ROW_H then h = DEFAULT_H - 134 end   -- frame ยังไม่ layout → fallback
    local visible = math.floor(h / C_ROW_H)
    local rows = {}
    for k = 1, visible do
        local r = CreateFrame("Frame", nil, listHost)
        r:SetSize(listHost:GetWidth() - 24, C_ROW_H - 2)
        r:SetPoint("TOPLEFT", 0, -(k - 1) * C_ROW_H)

        r.idFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.idFS:SetPoint("LEFT", 4, 0); r.idFS:SetWidth(80); r.idFS:SetJustifyH("LEFT")
        r.nameFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.nameFS:SetPoint("LEFT", 90, 0); r.nameFS:SetWidth(190); r.nameFS:SetJustifyH("LEFT")
        r.sumFS = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.sumFS:SetPoint("LEFT", 290, 0); r.sumFS:SetWidth(150); r.sumFS:SetJustifyH("LEFT")

        local function mkBtn(text, xOfs, onClick)
            local b = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
            b:SetSize(40, C_ROW_H - 4)
            b:SetPoint("LEFT", xOfs, 0)
            b:SetText(text)
            b:SetScript("OnClick", onClick)
            return b
        end
        mkBtn("Edit", 450, function() end)
        mkBtn("X",    494, function() end)
        mkBtn("^",    538, function() if r.dataIdx then TimedMove(r.dataIdx, -1) end end)
        mkBtn("v",    582, function() if r.dataIdx then TimedMove(r.dataIdx, 1) end end)
        rows[k] = r
    end
    listHost._virtualRows = rows

    -- slider ขวา (ไม่พึ่ง template — บาง template ถูกถอดใน 12.0)
    local slider = listHost._slider
    if not slider then
        slider = CreateFrame("Slider", nil, listHost)
        slider:SetOrientation("VERTICAL")
        slider:SetPoint("TOPRIGHT", 0, 0)
        slider:SetPoint("BOTTOMRIGHT", 0, 0)
        slider:SetWidth(16)
        local bg = slider:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(slider)
        bg:SetColorTexture(0, 0, 0, 0.35)
        slider:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
        slider:SetValueStep(1)
        slider:SetObeyStepOnDrag(true)
        slider:SetScript("OnValueChanged", function(_, v)
            listHost._offset = math.floor(v + 0.5)
            modes.C.Refresh()
        end)
        listHost._slider = slider
    end
    slider:Show()

    listHost:EnableMouseWheel(true)
    listHost:SetScript("OnMouseWheel", function(_, delta)
        local s = listHost._slider
        if s and s:IsShown() then s:SetValue(s:GetValue() - delta * 3) end
    end)
end

modes.C = {
    Build = function()
        ResetHost()
        listHost._offset = listHost._offset or 0
        CEnsureRows()
        local visible = #listHost._virtualRows
        local maxOfs = math.max(0, #items - visible)
        listHost._slider:SetMinMaxValues(0, maxOfs)
        if listHost._offset > maxOfs then listHost._offset = maxOfs end
        listHost._slider:SetValue(listHost._offset)
        modes.C.Refresh()
    end,
    Refresh = function()
        local rows = listHost._virtualRows
        if not rows then return end
        local ofs = listHost._offset or 0
        for k, r in ipairs(rows) do
            local i = ofs + k
            local it = items[i]
            if it then
                r.dataIdx = i
                r.idFS:SetText(tostring(it.id))
                r.nameFS:SetText("|cffe8ebf2= " .. it.name .. "|r")
                r.sumFS:SetText("|cff9fb3c8#" .. i .. " · kick|r")
                r:Show()
            else
                r.dataIdx = nil
                r:Hide()
            end
        end
    end,
    Move = function(idx, dir)
        if not SwapData(idx, dir) then return end
        modes.C.Refresh()   -- refresh เฉพาะ window ที่มองเห็น
    end,
    AddItems = function(n)
        for _ = 1, n do items[#items + 1] = RandomItem() end
        local visible = #(listHost._virtualRows or {})
        local maxOfs = math.max(0, #items - math.max(visible, 1))
        listHost._slider:SetMinMaxValues(0, maxOfs)
        modes.C.Refresh()
    end,
}

-- ============================================================
-- โหมดสลับ + ปุ่ม add
-- ============================================================
local function SelectMode(m)
    currentMode = m
    activeModeObj = modes[m]
    for key, b in pairs(modeButtons) do
        b:SetEnabled(key ~= m)
    end
    lastMoveMs = nil
    TimedBuild()
end

local function AddItems(n)
    if not activeModeObj then return end
    local t0 = debugprofilestop()
    activeModeObj.AddItems(n)
    lastBuildMs = debugprofilestop() - t0
    UpdateStatus()
end

-- ============================================================
-- Window
-- ============================================================
local function BuildWindow()
    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BackdropTemplate")
    frame:SetSize(DEFAULT_W, DEFAULT_H)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    tinsert(UISpecialFrames, FRAME_NAME)   -- ESC ปิดได้

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText("|cffffd200Reorder Perf Lab — [^][v] speed test|r")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    -- แถวปุ่มโหมด
    local function mkTopBtn(text, w, x, onClick)
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(w, 24)
        b:SetPoint("TOPLEFT", x, -40)
        b:SetText(text)
        b:SetScript("OnClick", onClick)
        return b
    end
    modeButtons.A = mkTopBtn("A: Full Rebuild (เดิม)", 170, 14,  function() SelectMode("A") end)
    modeButtons.B = mkTopBtn("B: In-place Swap",       150, 188, function() SelectMode("B") end)
    modeButtons.C = mkTopBtn("C: Virtual Scroll",      150, 342, function() SelectMode("C") end)

    -- แถวปุ่ม add
    local function mkAddBtn(text, w, x, n)
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(w, 24)
        b:SetPoint("TOPLEFT", x, -68)
        b:SetText(text)
        b:SetScript("OnClick", function() AddItems(n) end)
        return b
    end
    mkAddBtn("add random x1", 120, 14, 1)
    mkAddBtn("add random x5", 120, 138, 5)
    mkAddBtn("add random x10", 120, 262, 10)
    local resetBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    resetBtn:SetSize(120, 24)
    resetBtn:SetPoint("TOPLEFT", 386, -68)
    resetBtn:SetText("Reset " .. SEED_COUNT)
    resetBtn:SetScript("OnClick", function()
        SeedItems(SEED_COUNT)
        lastMoveMs = nil
        TimedBuild()
    end)

    -- status
    statusFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    statusFS:SetPoint("TOPLEFT", 16, -98)
    statusFS:SetJustifyH("LEFT")
    timeFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    timeFS:SetPoint("TOPLEFT", 440, -96)
    timeFS:SetJustifyH("LEFT")

    -- list host
    listHost = CreateFrame("Frame", nil, frame)
    listHost:SetPoint("TOPLEFT", 14, -120)
    listHost:SetPoint("BOTTOMRIGHT", -14, 14)
end

function TOOL.ToggleReorderPerfLab()
    if frame and frame:IsShown() then
        frame:Hide()
        return
    end
    if not frame then
        BuildWindow()
        SeedItems(SEED_COUNT)
        SelectMode("A")
    end
    frame:Show()
    UpdateStatus()
end

TOOL.RegisterTool("Reorder Perf Lab ([^][v] speed)", TOOL.ToggleReorderPerfLab)
