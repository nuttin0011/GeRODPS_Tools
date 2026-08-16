--[[
    GeRODPS_Tools / DispelCurveTest.lua

    "Dispel Curve Test" — ตอบคำถามเดียว: **เทคนิค ColorCurve ยังถอดชนิด dispel
    ได้อยู่ไหมบน 12.1 ตอนอยู่ใน combat**

    ── ทำไมต้องมีเครื่องมือแยก ────────────────────────────────────────────
    วัดแล้ว 2026-08-16 (Nameplate Aura Probe) ว่าใน combat:
      • C_UnitAuras ตระกูล index/slot/instanceID  → **throw**
      • C_UnitAuras ตระกูล spellID/ชื่อ           → **คืน nil เงียบ ๆ**
      • combat log                                → ถูกปิดด้วย (user ยืนยัน)
    ⇒ เหลือทางเดียว: **Route B** อ่าน field จากเฟรมที่ Blizzard วาดเอง

    เทคนิค ColorCurve (กู้จาก AuraCache.lua ที่ลบไป · ThreatPlates Midnight ก็ใช้):
        curve:AddPoint(id, CreateColor(id/255, 1, 0, 1))     -- เข้ารหัส id ลงช่อง R
        color = C_UnitAuras.GetAuraDispelTypeColor(unit, auraInstanceID, curve)
        id = floor(color.r * 255 + 0.5)                       -- ถอดกลับ
    ค่าที่คืนมาเป็นสีของ **เส้นโค้งที่เราสร้างเอง** ไม่ใช่ข้อมูลของ Blizzard
    ⇒ ในทางทฤษฎีไม่ควรติด secret

    ⚠ ปมที่ยังไม่เคยทดสอบ: ใน combat หา `auraInstanceID` จาก API ไม่ได้แล้ว
      แหล่งเดียวที่เหลือคือ **ปุ่มออร่าบน nameplate** (`btn.auraInstanceID`)
      ซึ่งวัดแล้วเป็น **secret number** — ยังไม่มีใครลองส่ง secret ตัวนั้นเข้า
      GetAuraDispelTypeColor (โค้ดเดิมของ AuraCache bail ทิ้งก่อนเสมอ)
      ⇒ เครื่องมือนี้ลองให้ แล้วรายงานว่าเกิดอะไรขึ้น

    ── เงื่อนไขตอนกด ────────────────────────────────────────────────────
      ต้อง **อยู่ในดัน + combat + มี DoT ของเราติด mob** (ให้มีปุ่มออร่าให้หยิบ
      auraInstanceID) · นอก combat ออร่าไม่ secret ผลจะ "ผ่าน" แบบหลอก

    ── อ่านอย่างเดียว ───────────────────────────────────────────────────
      เรียกเฉพาะ getter + ห่อ pcall ทุกจุด ไม่เขียนค่ากลับเฟรมของ Blizzard

    Public:
        GeRODPS_Tools.ToggleDispelCurveTest()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local TITLE_H  = 28     -- Rule 10: แถวแรกต้องเผื่อความสูง title bar
local SIDE_PAD = 14

local MAX_PLATES = 30

-- dispelTypeID → ชื่อ (SpellDispelType.db2)
local DISPEL_TYPE_NAMES = {
    [0]  = "None",
    [1]  = "Magic",
    [2]  = "Curse",
    [3]  = "Disease",
    [4]  = "Poison",
    [9]  = "Enrage",
    [11] = "Bleed",
}

local LISTS = {
    { field = "DebuffListFrame",       kind = "debuff" },
    { field = "BuffListFrame",         kind = "buff"   },
    { field = "CrowdControlListFrame", kind = "cc"     },
}

-- ============================================================
-- helpers
-- ============================================================

local function IsSecret(v)
    if issecretvalue == nil then return false end
    local ok, res = pcall(issecretvalue, v)
    if not ok then return false end
    return res == true
end

local function SafeStr(v)
    if v == nil then return "nil" end
    if IsSecret(v) then
        local ok, t = pcall(type, v)
        return "SECRET " .. (ok and t or "?")
    end
    return tostring(v)
end

-- ============================================================
-- Curve
-- ============================================================

local curveCache

--- สร้าง ColorCurve ที่เข้ารหัส dispelTypeID ลงช่อง R
--- คืน (curve, errText)
local function BuildCurve()
    if curveCache then return curveCache end
    if C_CurveUtil == nil or C_CurveUtil.CreateColorCurve == nil then
        return nil, "ไม่มี C_CurveUtil.CreateColorCurve"
    end
    if CreateColor == nil then return nil, "ไม่มี CreateColor" end

    local ok, curve = pcall(C_CurveUtil.CreateColorCurve)
    if not ok then return nil, "CreateColorCurve throw: " .. tostring(curve) end
    if curve == nil then return nil, "CreateColorCurve คืน nil" end

    if Enum and Enum.LuaCurveType and Enum.LuaCurveType.Step then
        pcall(curve.SetType, curve, Enum.LuaCurveType.Step)
    end
    local added = 0
    for id in pairs(DISPEL_TYPE_NAMES) do
        local okA = pcall(curve.AddPoint, curve, id, CreateColor(id / 255, 1, 0, 1))
        if okA then added = added + 1 end
    end
    if added == 0 then return nil, "AddPoint ไม่สำเร็จสักจุด" end
    curveCache = curve
    return curve
end

--- ถอดสีกลับเป็นชื่อชนิด · คืน (text, okFlag)
local function DecodeColor(color)
    if color == nil then return "คืน nil", false end
    local r = color.r
    if r == nil and type(color) == "table" then r = color[1] end
    if r == nil then return "ไม่มีช่อง r", false end
    if IsSecret(r) then
        return "r เป็น |cffff9a9asecret|r -> ถอดฝั่ง Lua ไม่ได้ (ส่งดิบให้ AHK แทน)", false
    end
    local okF, id = pcall(function() return math.floor(r * 255 + 0.5) end)
    if not okF then return "คำนวณ r ไม่ได้", false end
    local nm = DISPEL_TYPE_NAMES[id]
    if nm == nil then
        return ("r=%s -> id=%d |cffffcc55(ไม่อยู่ในตาราง)|r"):format(tostring(r), id), false
    end
    return ("r=%s -> id=%d |cff44ff44ชนิด = %s|r"):format(tostring(r), id, nm), true
end

--- เรียก GetAuraDispelTypeColor แล้วรายงานผล
local function TryCurve(unit, aid, curve, out, pad)
    if C_UnitAuras == nil or C_UnitAuras.GetAuraDispelTypeColor == nil then
        out[#out + 1] = pad .. "|cffff9a9aไม่มี C_UnitAuras.GetAuraDispelTypeColor|r"
        return false
    end
    local ok, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, aid, curve)
    if not ok then
        out[#out + 1] = pad .. "|cffff9a9aTHROW:|r " .. tostring(color)
        return false
    end
    local text, good = DecodeColor(color)
    out[#out + 1] = pad .. text
    return good
end

-- ============================================================
-- แหล่ง auraInstanceID
-- ============================================================

local function AurasFrameOf(unit)
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return nil end
    local uf = plate.UnitFrame
    if not uf then return nil end
    return uf.AurasFrame or uf.NameplateAurasFrame
end

local function LayoutChildren(listFrame)
    if not listFrame or not listFrame.GetLayoutChildren then return nil end
    local ok, children = pcall(listFrame.GetLayoutChildren, listFrame)
    if not ok or type(children) ~= "table" then return nil end
    return children
end

-- ============================================================
-- Report
-- ============================================================

local function BuildReport()
    local out = {}
    out[#out + 1] = "== Dispel Curve Test =="

    -- env
    local inCombat = UnitAffectingCombat("player")
    local inInst, instType = IsInInstance()
    local aurasSecret = "?"
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        local ok, v = pcall(C_Secrets.ShouldAurasBeSecret)
        if ok then aurasSecret = SafeStr(v) end
    end
    out[#out + 1] = ("combat=%s  instance=%s(%s)  ShouldAurasBeSecret=%s")
        :format(SafeStr(inCombat), SafeStr(inInst), SafeStr(instType), aurasSecret)
    if aurasSecret ~= "true" then
        out[#out + 1] = "|cffff5555!! ออร่ายังไม่ secret -> ผลรอบนี้ไม่พิสูจน์อะไร"
            .. " ต้องยิงตอนอยู่ในดัน + combat|r"
    else
        out[#out + 1] = "|cff44ff44เงื่อนไขครบ - ผลรอบนี้เชื่อได้|r"
    end
    out[#out + 1] = ""

    -- ── ขั้น 1: ตัว curve เองยังสร้างได้ไหม ──
    out[#out + 1] = "-- ขั้น 1: สร้าง ColorCurve --"
    local curve, err = BuildCurve()
    if curve == nil then
        out[#out + 1] = "  |cffff9a9aล้มเหลว:|r " .. tostring(err)
        out[#out + 1] = "  => เทคนิคนี้ตายที่ต้นทาง ไม่ต้องดูขั้นต่อไป"
        return table.concat(out, "\n")
    end
    out[#out + 1] = "  |cff44ff44สร้างได้|r (เข้ารหัส 7 ชนิดลงช่อง R: None/Magic/Curse/"
        .. "Disease/Poison/Enrage/Bleed)"
    out[#out + 1] = ""

    -- ── ขั้น 2: auraInstanceID แบบ plain (baseline) ──
    out[#out + 1] = "-- ขั้น 2: baseline ด้วย auraInstanceID ที่ไม่ secret --"
    out[#out + 1] = "   (หาได้เฉพาะตอนออร่าไม่ secret — ใช้ยืนยันว่ากลไกยังถูกต้อง)"
    local didBase = false
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for _, u in ipairs({ "target", "player" }) do
            if UnitExists(u) then
                for _, flt in ipairs({ "HARMFUL", "HELPFUL" }) do
                    local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, u, 1, flt)
                    if ok and a ~= nil and a.auraInstanceID ~= nil then
                        out[#out + 1] = ("  [%s %s] aid=%s  name=%s")
                            :format(u, flt, SafeStr(a.auraInstanceID), SafeStr(a.name))
                        TryCurve(u, a.auraInstanceID, curve, out, "      ")
                        didBase = true
                    end
                end
            end
        end
    end
    if not didBase then
        out[#out + 1] = "  (หา aid แบบ plain ไม่ได้ — ปกติถ้าอยู่ใน combat)"
    end
    out[#out + 1] = ""

    -- ── ขั้น 3: ของจริง — aid จากปุ่มบน nameplate (Route B, secret) ──
    out[#out + 1] = "-- ขั้น 3: **ของจริง** aid จากปุ่มออร่าบน nameplate (Route B) --"
    out[#out + 1] = "   แหล่งเดียวที่ยังหา auraInstanceID ได้ตอน combat · ค่าเป็น secret"
    local nBtn, nGood = 0, 0
    for i = 1, MAX_PLATES do
        local unit = "nameplate" .. i
        if UnitExists(unit) then
            local af = AurasFrameOf(unit)
            if af then
                for _, L in ipairs(LISTS) do
                    local children = LayoutChildren(af[L.field])
                    if children then
                        for idx, btn in ipairs(children) do
                            local aid = btn and btn.auraInstanceID
                            if aid ~= nil then
                                nBtn = nBtn + 1
                                out[#out + 1] = ("  [%s %s#%d] aid=%s  spellID=%s")
                                    :format(unit, L.kind, idx, SafeStr(aid), SafeStr(btn.spellID))
                                if TryCurve(unit, aid, curve, out, "      ") then
                                    nGood = nGood + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if nBtn == 0 then
        out[#out + 1] = "  |cffff5555ไม่มีปุ่มออร่าให้ทดสอบเลย|r"
        out[#out + 1] = "     ต้องมี DoT ของเราติด mob (Blizzard วาดเฉพาะดีบัฟที่ source = เรา)"
        out[#out + 1] = "     ถ้าอยากได้ buff ของ mob: Blizzard ไม่วาดให้ — วัดแล้ว children=0 เสมอ"
    end
    out[#out + 1] = ""

    -- ── สรุป ──
    out[#out + 1] = "-- สรุป --"
    if nBtn == 0 then
        out[#out + 1] = "  ยังตัดสินไม่ได้ — ไม่มี auraInstanceID ให้ลอง"
    elseif nGood > 0 then
        out[#out + 1] = ("  |cff44ff44เทคนิค curve ใช้ได้ %d/%d|r — ถอดชนิด dispel จาก aid ที่ secret ได้")
            :format(nGood, nBtn)
        out[#out + 1] = "  => ต่อยอดได้: อ่าน aid จากปุ่ม แล้วถามชนิดผ่าน curve ทุก tick"
    else
        out[#out + 1] = ("  |cffff9a9aเทคนิค curve ใช้ไม่ได้ 0/%d|r"):format(nBtn)
        out[#out + 1] = "  => ถ้า r เป็น secret ยังส่งดิบให้ AHK ถอดได้ (ดูบรรทัดข้างบน)"
        out[#out + 1] = "     ถ้า THROW = ตายสนิท"
    end

    return table.concat(out, "\n")
end

-- ============================================================
-- UI
-- ============================================================

local frame, editBox, scrollFrame

local function Refresh()
    if not editBox then return end
    local ok, text = pcall(BuildReport)
    editBox:SetText(ok and text or ("พัง: " .. tostring(text)))
    editBox:SetCursorPosition(0)
end

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "GeRODPSToolsDispelCurveTest", UIParent,
        "BasicFrameTemplateWithInset")
    frame:SetSize(900, 560)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetResizable(true)
    if frame.SetResizeBounds then frame:SetResizeBounds(600, 320, 2200, 1400) end
    frame:SetClampedToScreen(true)
    frame:Hide()
    if frame.TitleText then frame.TitleText:SetText("Dispel Curve Test") end
    table.insert(UISpecialFrames, "GeRODPSToolsDispelCurveTest")

    -- Rule 10: แถวแรก anchor ที่ frame + เผื่อ TITLE_H
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 8))
    hint:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + 8))
    hint:SetJustifyH("LEFT")
    hint:SetSpacing(3)
    hint:SetText("ต้องกดตอน: |cffffcc55อยู่ในดัน + combat + มี DoT ของเราติด mob|r"
        .. "  (นอก combat ออร่าไม่ secret -> ผลหลอก)")

    local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btn:SetSize(120, 24)
    btn:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
    btn:SetText("ทดสอบ")
    btn:SetScript("OnClick", Refresh)

    local btnSel = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnSel:SetSize(120, 24)
    btnSel:SetPoint("LEFT", btn, "RIGHT", 8, 0)
    btnSel:SetText("Select All")
    btnSel:SetScript("OnClick", function()
        if editBox then editBox:SetFocus(); editBox:HighlightText() end
    end)

    scrollFrame = CreateFrame("ScrollFrame", "$parentScroll", frame,
        "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 22)

    editBox = CreateFrame("EditBox", nil, scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(scrollFrame:GetWidth())
    editBox:SetMaxLetters(0)
    editBox:SetCountInvisibleLetters(false)
    editBox:EnableMouse(true)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    editBox:SetScript("OnCursorChanged", function(self, _, y, _, ch)
        ScrollingEdit_OnCursorChanged(self, 0, y, 0, ch)
    end)
    scrollFrame:SetScript("OnSizeChanged", function(_, w)
        if editBox then editBox:SetWidth(w) end
    end)
    scrollFrame:SetScrollChild(editBox)

    local resize = CreateFrame("Button", nil, frame)
    resize:SetSize(16, 16)
    resize:SetPoint("BOTTOMRIGHT", -4, 4)
    resize:EnableMouse(true)
    resize:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    resize:SetPushedTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Down")
    resize:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            frame:StopMovingOrSizing()
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resize:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then frame:StopMovingOrSizing() end
    end)

    return frame
end

function TOOL.ToggleDispelCurveTest()
    local f = BuildFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        Refresh()
    end
end

TOOL.RegisterTool("Dispel Curve Test", TOOL.ToggleDispelCurveTest)
