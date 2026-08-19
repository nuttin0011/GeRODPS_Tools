--[[
    NPAuraTooltipProbe.lua — "ดึง Tooltip ออกมาจาก Aura ของ Nameplate ได้ไหม?"

    ── ทำไมคำถามนี้สำคัญ ────────────────────────────────────────────────────
    spellID บนปุ่ม nameplate เป็น **secret** ⇒ ฝั่ง Lua เทียบไม่ได้เลย ⇒ ทุกฟีเจอร์
    (nameplate_mob_aura · Dispel v2 · Aura Present V6) ต้องยัด record ดิบลง STS
    ให้ AHK match — เปลืองงบสาย + ตรรกะกระจายไป 2 ภาษา

    **แต่** Aura Present V5 ใช้ "scanning tooltip" กับ player แล้วได้ spellID ที่เป็น
    **plain** กลับมา (PlayerAuraCheck.ResolveSpellByIndex → tip:SetUnitAura(unit, i,
    filter) → tip:GetTooltipData().id) ⇒ ถ้าท่าเดียวกันใช้กับ unit ของ nameplate ได้
    **ในคอมแบต** เราจะกรอง/เทียบ spellID ฝั่ง Lua ได้ทันที = ออกแบบใหม่ได้ทั้งหมด

    เครื่องมือนี้ไม่ตัดสินอะไรเอง — มันแค่ยิงทุกท่าที่เป็นไปได้แล้วรายงานว่า
    **ท่าไหนคืนค่าอะไร · ค่านั้น plain หรือ secret · หรือ throw**

    ── 5 ท่าที่ยิง ──────────────────────────────────────────────────────────
      A. scanning tooltip ตาม index   tip:SetUnitAura(unit, i, filter)
      B. ตาม auraInstanceID ของปุ่ม   tip:SetUnitDebuffByAuraInstanceID(...)
      C. ปุ่มมี tooltip ในตัวไหม      OnEnter / IsMouseEnabled / UpdateTooltip
                                       (สมมติฐาน user: "Blizzard ใส่มาแต่ปิดไว้")
      D. dump field ของปุ่ม           หา index / auraInstanceID / อะไรที่ยังไม่รู้จัก
      E. C_TooltipInfo                GetUnitDebuff / GetUnitBuff (data API ตรง ๆ)

    ── กติกา secret (ต้องอ่านก่อนแก้ไฟล์นี้) ─────────────────────────────────
      · ทุก call ต้อง pcall — API ที่โดนบล็อกจะ throw ไม่ใช่คืน nil
      · ผลลัพธ์แสดงด้วย **FontString เท่านั้น** (render secret ได้ · EditBox ไม่ได้)
      · ห้าม compare / arithmetic / `#` กับค่าที่ได้ — ทำได้แค่ tostring + ".."
      · `issecretvalue(v)` เรียกได้ปลอดภัย = ตัวชี้ขาดว่าท่านั้น "ใช้ได้จริง" ไหม
        (ได้ค่ากลับมาแต่เป็น secret = ไม่ช่วยอะไร เพราะยังเทียบใน Lua ไม่ได้)
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local TITLE_H   = 28
local SIDE_PAD  = 12
local ROW_H     = 13
local MAX_ROWS  = 34
local MAX_INDEX = 6       -- ไล่ index กี่ตัวต่อ filter
local MAX_FIELD = 26      -- dump field ของปุ่มกี่ตัว

local frame, rowsFS, headerFS, pageLabel, btnPrev, btnNext
local lines = {}
local page  = 1
local lastUnit = "nameplate1"

-- ============================================================
-- scanning tooltip ของเราเอง (ห้ามใช้ GameTooltip จริง = taint)
-- ============================================================
local TIP_NAME = "GeRODPSToolsNPAuraScanTip"
local _tip, _tipLine1

local function GetTip()
    if _tip ~= nil then return _tip, _tipLine1 end
    local ok, f = pcall(CreateFrame, "GameTooltip", TIP_NAME, nil, "GameTooltipTemplate")
    if not ok or f == nil then return nil, nil end
    _tip = f
    _tipLine1 = _G[TIP_NAME .. "TextLeft1"]
    return _tip, _tipLine1
end

-- ============================================================
-- helper แสดงผล (secret-safe ทั้งหมด)
-- ============================================================

--- ป้ายบอกว่าค่านี้ secret หรือ plain — นี่คือคำตอบที่เราตามหาจริง ๆ
local function Tag(v)
    if v == nil then return "|cff666666nil|r" end
    if issecretvalue ~= nil then
        local ok, isSec = pcall(issecretvalue, v)
        if ok and isSec == true then return "|cffff9a9aSECRET|r" end
    end
    return "|cff44ff44plain|r"
end

--- tostring ที่ไม่มีทาง throw (ค่า secret tostring ได้ แต่ metatable แปลก ๆ อาจพัง)
local function Str(v)
    local ok, s = pcall(tostring, v)
    if ok then return s end
    return "|cffff5555<tostring throw>|r"
end

local function Add(fmt, ...)
    local n = select("#", ...)
    if n == 0 then
        lines[#lines + 1] = fmt
        return
    end
    -- ห้ามใช้ string.format กับค่า secret ที่ไม่รู้ชนิด — ต่อด้วย ".." ล้วน
    local s = fmt
    for i = 1, n do
        s = s .. Str((select(i, ...)))
    end
    lines[#lines + 1] = s
end

local function Head(t)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "|cffffd200" .. t .. "|r"
end

-- ============================================================
-- ตัวช่วยหาปุ่ม aura ของ nameplate
-- ============================================================

local function AurasFrameOf(unit)
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if not ok or plate == nil then return nil end
    local uf = plate.UnitFrame
    if uf == nil then return nil end
    return uf.AurasFrame or uf.NameplateAurasFrame
end

--- ปุ่มตัวแรกของลิสต์ที่มีของ (คืน btn, ชื่อลิสต์)
local function FirstButton(unit)
    local af = AurasFrameOf(unit)
    if af == nil then return nil, nil end
    for _, key in ipairs({ "DebuffListFrame", "BuffListFrame", "CrowdControlListFrame" }) do
        local lf = af[key]
        if lf ~= nil and lf.GetLayoutChildren ~= nil then
            local ok, children = pcall(lf.GetLayoutChildren, lf)
            if ok and type(children) == "table" and children[1] ~= nil then
                return children[1], key
            end
        end
    end
    return nil, nil
end

-- ============================================================
-- A · scanning tooltip ตาม index
-- ============================================================
-- ท่าเดียวกับ Aura Present V5 (PlayerAuraCheck.ResolveSpellByIndex) เป๊ะ —
-- ต่างแค่ unit เป็นของศัตรู · ถ้าท่านี้ผ่านและได้ id เป็น **plain** แปลว่า
-- เราสามารถเลิกยัด record ดิบลง STS ได้ทั้งระบบ
local function ProbeA(unit)
    Head("A · scanning tooltip ตาม index — tip:SetUnitAura(unit, i, filter)")
    local tip, line1 = GetTip()
    if tip == nil then
        Add("  |cffff5555สร้าง scanning tooltip ไม่ได้|r")
        return
    end
    for _, filter in ipairs({ "HARMFUL", "HELPFUL" }) do
        for i = 1, MAX_INDEX do
            local okSet, err = pcall(function()
                tip:SetOwner(UIParent, "ANCHOR_NONE")
                tip:SetUnitAura(unit, i, filter)
            end)
            if not okSet then
                Add("  " .. filter .. " #" .. i .. "  |cffff5555THROW|r  ", err)
                break                       -- throw แล้วไม่ต้องไล่ต่อ
            end
            local sid, nm, dtype
            if tip.GetTooltipData ~= nil then
                local okD, d = pcall(tip.GetTooltipData, tip)
                if okD and type(d) == "table" then
                    sid, dtype = d.id, d.type
                end
            end
            if line1 ~= nil and line1.GetText ~= nil then
                local okT, v = pcall(line1.GetText, line1)
                if okT then nm = v end
            end
            pcall(function() tip:Hide() end)
            if sid == nil and nm == nil then
                Add("  " .. filter .. " #" .. i .. "  |cff666666(ว่าง — หมด aura แล้ว)|r")
                break
            end
            Add("  " .. filter .. " #" .. i
                .. "  id=" .. Str(sid) .. " [" .. Tag(sid) .. "]"
                .. "  type=" .. Str(dtype)
                .. "  name=" .. Str(nm) .. " [" .. Tag(nm) .. "]")
        end
    end
end

-- ============================================================
-- B · ตาม auraInstanceID ของปุ่ม
-- ============================================================
-- ปุ่มถือ auraInstanceID อยู่แล้ว (อาจ secret) — secret **ส่งเป็น argument ได้**
-- (wow-coding Rule 1.5: store/pass ได้ · ห้ามแค่ compare/arithmetic)
-- ถ้าท่านี้คืน id เป็น plain แปลว่าเราไม่ต้องพึ่ง index เลย
local function ProbeB(unit)
    Head("B · ตาม auraInstanceID ของปุ่ม — SetUnit(De)BuffByAuraInstanceID")
    local btn, listName = FirstButton(unit)
    if btn == nil then
        Add("  |cff666666ไม่มีปุ่ม aura บน nameplate นี้|r")
        return
    end
    Add("  ปุ่มตัวแรกจาก " .. Str(listName)
        .. "  · auraInstanceID = " .. Str(btn.auraInstanceID) .. " [" .. Tag(btn.auraInstanceID) .. "]")

    local tip = GetTip()
    if tip == nil then return end
    for _, m in ipairs({ "SetUnitDebuffByAuraInstanceID", "SetUnitBuffByAuraInstanceID" }) do
        if tip[m] == nil then
            Add("  " .. m .. "  |cff666666ไม่มีเมธอดนี้ในไคลเอนต์|r")
        elseif btn.auraInstanceID == nil then
            Add("  " .. m .. "  |cff666666ปุ่มไม่มี auraInstanceID|r")
        else
            local okSet, err = pcall(function()
                tip:SetOwner(UIParent, "ANCHOR_NONE")
                tip[m](tip, unit, btn.auraInstanceID)
            end)
            if not okSet then
                Add("  " .. m .. "  |cffff5555THROW|r  ", err)
            else
                local sid
                if tip.GetTooltipData ~= nil then
                    local okD, d = pcall(tip.GetTooltipData, tip)
                    if okD and type(d) == "table" then sid = d.id end
                end
                pcall(function() tip:Hide() end)
                Add("  " .. m .. "  id=" .. Str(sid) .. " [" .. Tag(sid) .. "]")
            end
        end
    end
end

-- ============================================================
-- C · ปุ่มมี tooltip ในตัวไหม (สมมติฐานของ user)
-- ============================================================
local function ProbeC(unit)
    Head("C · ปุ่มมี tooltip ในตัวไหม — \"ใส่มาแต่ปิดไว้\" จริงหรือเปล่า")
    local btn, listName = FirstButton(unit)
    if btn == nil then
        Add("  |cff666666ไม่มีปุ่ม aura บน nameplate นี้|r")
        return
    end
    local function q(label, fn)
        local ok, v = pcall(fn)
        if not ok then
            Add("  " .. label .. " = |cffff5555THROW|r")
        else
            Add("  " .. label .. " = " .. Str(v) .. " [" .. Tag(v) .. "]")
        end
    end
    Add("  ปุ่มจาก " .. Str(listName))
    q("GetScript(OnEnter)",      function() return btn:GetScript("OnEnter") end)
    q("GetScript(OnLeave)",      function() return btn:GetScript("OnLeave") end)
    q("IsMouseEnabled()",        function() return btn:IsMouseEnabled() end)
    q("IsMouseMotionEnabled()",  function() return btn:IsMouseMotionEnabled() end)
    q("IsMouseClickEnabled()",   function() return btn:IsMouseClickEnabled() end)
    q(".UpdateTooltip",          function() return btn.UpdateTooltip end)
    q("parent:IsMouseEnabled()", function() return btn:GetParent():IsMouseEnabled() end)
    Add("  |cff888888ถ้า OnEnter มีแต่ IsMouseMotionEnabled = false"
        .. " แปลว่า Blizzard ใส่มาแล้วปิดไว้จริง|r")
end

-- ============================================================
-- D · dump field ของปุ่ม
-- ============================================================
-- หาว่ามี field ที่ยังไม่รู้จักไหม (โดยเฉพาะ "index" — ถ้ามี ท่า A จะเล็งได้ตรงตัว
-- แทนที่จะไล่ 1..N)
local function ProbeD(unit)
    Head("D · field บนปุ่ม (หา index / อะไรที่ยังไม่รู้จัก)")
    local btn = FirstButton(unit)
    if btn == nil then
        Add("  |cff666666ไม่มีปุ่ม aura บน nameplate นี้|r")
        return
    end
    local ok, keys = pcall(function()
        local out = {}
        for k, v in pairs(btn) do
            if type(k) == "string" then out[#out + 1] = { k = k, v = v } end
        end
        table.sort(out, function(a, b) return a.k < b.k end)
        return out
    end)
    if not ok or keys == nil then
        Add("  |cffff5555pairs(btn) throw|r")
        return
    end
    local objs = ""
    local n = 0
    for _, e in ipairs(keys) do
        local t = type(e.v)
        if t == "function" or t == "table" or t == "userdata" then
            objs = objs .. e.k .. " "
        elseif n < MAX_FIELD then
            n = n + 1
            Add("  ." .. e.k .. " = " .. Str(e.v) .. " [" .. Tag(e.v) .. "]")
        end
    end
    if objs ~= "" then
        Add("  |cff888888(table/function): " .. objs .. "|r")
    end
end

-- ============================================================
-- E · C_TooltipInfo (data API ตรง ๆ ไม่ต้องมีเฟรม)
-- ============================================================
local function ProbeE(unit)
    Head("E · C_TooltipInfo — data API ตรง ๆ")
    if C_TooltipInfo == nil then
        Add("  |cff666666ไม่มี C_TooltipInfo|r")
        return
    end
    for _, m in ipairs({ "GetUnitDebuff", "GetUnitBuff" }) do
        if C_TooltipInfo[m] == nil then
            Add("  " .. m .. "  |cff666666ไม่มีเมธอดนี้|r")
        else
            for i = 1, 3 do
                local ok, d = pcall(C_TooltipInfo[m], unit, i)
                if not ok then
                    Add("  " .. m .. " #" .. i .. "  |cffff5555THROW|r  ", d)
                    break
                elseif type(d) ~= "table" then
                    Add("  " .. m .. " #" .. i .. "  |cff666666(ว่าง)|r")
                    break
                else
                    Add("  " .. m .. " #" .. i .. "  id=" .. Str(d.id) .. " [" .. Tag(d.id) .. "]")
                end
            end
        end
    end
end

-- ============================================================
-- Run
-- ============================================================

local function Run(unit)
    lastUnit = unit or "nameplate1"
    lines = {}
    page = 1

    local exists = false
    local okE, v = pcall(UnitExists, lastUnit)
    if okE then exists = (v == true) end

    Add("|cffffd200unit|r = " .. lastUnit
        .. "   |cffffd200ชื่อ|r = " .. Str(UnitName(lastUnit))
        .. "   exists = " .. Str(exists))
    Add("|cffffd200in-combat|r = " .. Str(InCombatLockdown())
        .. "   |cff888888(คำตอบที่ต้องการคือ \"ใช้ได้ตอน combat ไหม\" — กดปุ่มนี้กลางคอมแบตด้วย)|r")

    ProbeA(lastUnit)
    ProbeB(lastUnit)
    ProbeC(lastUnit)
    ProbeD(lastUnit)
    ProbeE(lastUnit)

    Add("")
    Add("|cff888888อ่านผลยังไง: ท่าไหนที่ id = ตัวเลข และป้ายเป็น |r|cff44ff44plain|r"
        .. "|cff888888 = ใช้ได้จริง ⇒ เลิกยัด record ดิบลง STS ได้|r")
    Add("|cff888888ถ้าได้ค่าแต่ป้ายเป็น |r|cffff9a9aSECRET|r|cff888888 = ไม่ช่วยอะไร"
        .. " (ยังเทียบใน Lua ไม่ได้เหมือนเดิม)|r")
end

-- ============================================================
-- UI
-- ============================================================

local function Refresh()
    if frame == nil then return end
    local total = math.ceil(#lines / MAX_ROWS)
    if total < 1 then total = 1 end
    if page > total then page = total end
    if page < 1 then page = 1 end

    headerFS:SetText("|cffffd200NP Aura Tooltip Probe|r   unit ล่าสุด: " .. lastUnit)
    for i = 1, MAX_ROWS do
        local ln = lines[(page - 1) * MAX_ROWS + i]
        rowsFS[i]:SetText(ln or "")
    end
    pageLabel:SetText(("หน้า %d/%d  ·  %d บรรทัด"):format(page, total, #lines))
    btnPrev:SetEnabled(page > 1)
    btnNext:SetEnabled(page < total)
end

local function BuildFrame()
    if frame then return frame end
    frame = CreateFrame("Frame", "GeRODPSToolsNPAuraTooltipProbe", UIParent,
                        "BasicFrameTemplateWithInset")
    frame:SetSize(880, TITLE_H + 40 + MAX_ROWS * ROW_H + 46)
    frame:SetPoint("CENTER")
    frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    frame:SetResizable(true)
    if frame.SetResizeBounds then frame:SetResizeBounds(520, 260) end
    if frame.TitleText then frame.TitleText:SetText("NP Aura Tooltip Probe") end

    headerFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    headerFS:SetPoint("TOPLEFT", SIDE_PAD, -TITLE_H - 4)
    headerFS:SetJustifyH("LEFT")

    -- ปุ่มเลือก unit ที่จะยิง
    local x = SIDE_PAD
    local function mkBtn(label, w, fn)
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(w, 20)
        b:SetPoint("TOPLEFT", x, -TITLE_H - 22)
        b:SetText(label)
        b:SetScript("OnClick", fn)
        x = x + w + 4
        return b
    end
    for i = 1, 3 do
        mkBtn("np" .. i, 44, function() Run("nameplate" .. i); Refresh() end)
    end
    mkBtn("target", 62, function() Run("target"); Refresh() end)
    mkBtn("focus", 56, function() Run("focus"); Refresh() end)
    mkBtn("Re-run", 66, function() Run(lastUnit); Refresh() end)

    rowsFS = {}
    for i = 1, MAX_ROWS do
        local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", SIDE_PAD, -TITLE_H - 46 - (i - 1) * ROW_H)
        fs:SetPoint("RIGHT", frame, "RIGHT", -SIDE_PAD, 0)
        fs:SetJustifyH("LEFT")
        fs:SetHeight(ROW_H)
        rowsFS[i] = fs
    end

    btnPrev = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnPrev:SetSize(60, 20)
    btnPrev:SetPoint("BOTTOMLEFT", SIDE_PAD, 10)
    btnPrev:SetText("^ ก่อน")
    btnPrev:SetScript("OnClick", function() page = page - 1; Refresh() end)

    btnNext = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnNext:SetSize(60, 20)
    btnNext:SetPoint("LEFT", btnPrev, "RIGHT", 6, 0)
    btnNext:SetText("v ถัดไป")
    btnNext:SetScript("OnClick", function() page = page + 1; Refresh() end)

    pageLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pageLabel:SetPoint("LEFT", btnNext, "RIGHT", 10, 0)

    local resize = CreateFrame("Button", nil, frame)
    resize:SetSize(16, 16)
    resize:SetPoint("BOTTOMRIGHT", -4, 4)
    resize:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resize:SetScript("OnMouseDown", function(_, b)
        if b == "LeftButton" then frame:StartSizing("BOTTOMRIGHT") end
    end)
    resize:SetScript("OnMouseUp", function(_, b)
        if b == "LeftButton" then frame:StopMovingOrSizing() end
    end)

    return frame
end

--- @param unit string|nil  ยิงทันทีที่เปิด (ให้ NP Aura Live View เรียกพร้อม unit ของคอลัมน์)
function TOOL.ShowNPAuraTooltipProbe(unit)
    local f = BuildFrame()
    f:Show()
    Run(unit or lastUnit)
    Refresh()
end

TOOL.RegisterTool("NP Aura Tooltip Probe (ดึง spellID แบบ plain ได้ไหม)",
    function() TOOL.ShowNPAuraTooltipProbe() end)
