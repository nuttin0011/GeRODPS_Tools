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
-- ขั้น 4: หา auraInstanceID จากเฟรมอื่นของ Blizzard
-- ============================================================
-- nameplate ไม่วาด buff ของศัตรู (วัดแล้ว children=0 เสมอ)
-- แต่ **Target Frame โชว์ buff ของเป้าหมาย** — ที่คนเห็น Enrage กันปกติ
-- เป็นเฟรมที่ Blizzard วาดเอง = Route B ที่ใช้ได้ในคอมแบต
--
-- ชื่อ field ของปุ่มเปลี่ยนไปมาหลาย patch ⇒ **ไม่เดาชื่อ**
-- แต่ไล่ลูกแบบ recursive แล้วเก็บทุกเฟรมที่มี field `auraInstanceID`
-- (จำกัดความลึก กัน loop ด้วย visited set)

local AURA_ROOTS = {
    "TargetFrame", "FocusFrame",
    "Boss1TargetFrame", "Boss2TargetFrame", "Boss3TargetFrame", "Boss4TargetFrame",
}

--- ไล่หาเฟรมที่มี auraInstanceID ใต้ root (depth จำกัด)
local AID_FIELDS = { "auraInstanceID", "auraInstanceId", "auraIndex", "spellID", "spellId" }

local function FindAuraFrames(root, depth, seen, hits)
    if root == nil or depth > 8 then return end
    if seen[root] then return end
    seen[root] = true

    local aid
    for _, fname in ipairs(AID_FIELDS) do
        local okF, v = pcall(function() return root[fname] end)
        if okF and v ~= nil then aid = v; break end
    end
    do
        local ok = aid ~= nil
        if ok then
            local vis = false
            pcall(function() vis = root:IsVisible() == true end)
            hits[#hits + 1] = { frame = root, aid = aid, visible = vis }
        end
    end

    local kids
    local okC = pcall(function() kids = { root:GetChildren() } end)
    if okC and type(kids) == "table" then
        for _, k in ipairs(kids) do
            FindAuraFrames(k, depth + 1, seen, hits)
        end
    end
end


--- dump ต้นไม้ลูกของ root — เลิกเดาชื่อ field แล้วดูของจริง
--- พิมพ์เฉพาะโหนดที่ "น่าจะเป็นปุ่มออร่า" (มี .Icon / ชื่อมี Buff|Debuff|Aura)
local function DumpTree(root, name, depth, seen, out, budget)
    if root == nil or depth > 6 or budget.n <= 0 then return end
    if seen[root] then return end
    seen[root] = true

    local looksAura = false
    if type(name) == "string" and name:match("[Bb]uff") then looksAura = true end
    if type(name) == "string" and name:match("[Aa]ura") then looksAura = true end
    local okI, icon = pcall(function() return root.Icon end)
    if okI and icon ~= nil then looksAura = true end

    if looksAura then
        budget.n = budget.n - 1
        local vis = false
        pcall(function() vis = root:IsVisible() == true end)
        local flds = {}
        pcall(function()
            for k, v in pairs(root) do
                local tv = type(v)
                if tv ~= "function" and tv ~= "table" and tv ~= "userdata" then
                    flds[#flds + 1] = tostring(k) .. "=" .. SafeStr(v)
                end
            end
        end)
        table.sort(flds)
        out[#out + 1] = ("      %s%s  visible=%s"):format(string.rep("  ", depth),
            tostring(name), tostring(vis))
        if #flds > 0 then
            local line = "        " .. string.rep("  ", depth)
            for _, f in ipairs(flds) do
                if #line > 110 then out[#out + 1] = line; line = "        " .. string.rep("  ", depth) end
                line = line .. f .. "  "
            end
            out[#out + 1] = line
        end
    end

    local kids
    local okC = pcall(function() kids = { root:GetChildren() } end)
    if okC and type(kids) == "table" then
        for i, k in ipairs(kids) do
            local kn
            pcall(function() kn = k:GetName() end)
            DumpTree(k, kn or (tostring(name) .. ".child" .. i), depth + 1, seen, out, budget)
        end
    end
end

local function ProbeOtherFrames(curve, out)
    out[#out + 1] = "-- ขั้น 4: เสริม — buff ของ mob จาก Target/Focus/Boss frame (เฉพาะตัวที่เล็ง) --"
    out[#out + 1] = "   nameplate ไม่วาด buff ของศัตรู — แต่ Target Frame โชว์ให้ (ที่คนเห็น Enrage/Magic กัน)"
    out[#out + 1] = "   |cffaaaaaaขั้นนี้ไม่ต้องมี DoT — แค่เล็ง mob ที่มี buff นั้นอยู่จริง|r"

    local total, good = 0, 0
    for _, rootName in ipairs(AURA_ROOTS) do
        local root = _G[rootName]
        if root ~= nil then
            local hits = {}
            FindAuraFrames(root, 0, {}, hits)
            if #hits == 0 then
                out[#out + 1] = ("  [%s] |cffaaaaaaไม่เจอ field ที่เดาไว้ — dump โครงจริง:|r")
                    :format(rootName)
                local budget = { n = 30 }
                DumpTree(root, rootName, 0, {}, out, budget)
                if budget.n == 30 then
                    out[#out + 1] = "        (ไม่มีลูกที่หน้าตาเหมือนปุ่มออร่าเลย)"
                end
            else
                local unit = "target"
                if rootName == "FocusFrame" then unit = "focus"
                elseif rootName:match("^Boss(%d)") then unit = "boss" .. rootName:match("^Boss(%d)") end
                out[#out + 1] = ("  [%s] เจอ %d เฟรม  (unit ที่ใช้ถาม = %s)")
                    :format(rootName, #hits, unit)
                local shown = 0
                for _, h in ipairs(hits) do
                    if h.visible then
                        shown = shown + 1
                        if shown <= 6 then
                            total = total + 1
                            local nm = "?"
                            pcall(function() nm = h.frame:GetName() or "(ไม่มีชื่อ)" end)
                            out[#out + 1] = ("      %s  aid=%s  spellID=%s")
                                :format(tostring(nm), SafeStr(h.aid), SafeStr(h.frame.spellID))
                            if TryCurve(unit, h.aid, curve, out, "          ") then
                                good = good + 1
                            end
                        end
                    end
                end
                out[#out + 1] = ("      -> ที่โชว์จริง %d / %d"):format(shown, #hits)
            end
        end
    end
    if total == 0 then
        out[#out + 1] = "  |cffff5555ไม่มีเฟรมออร่าที่โชว์อยู่เลย|r"
            .. " — ต้องเล็ง mob ที่มีออร่า (buff หรือ debuff) ตอนกด"
    end
    out[#out + 1] = ("  สรุปขั้น 4: curve หิน %d/%d"):format(good, total)
    return total, good
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
    out[#out + 1] = "-- |cffffd200ขั้น 3: **เป้าหมายหลัก** — ปุ่มออร่าบน nameplate ของ Blizzard (รวม buff ของ mob)|r --"
    out[#out + 1] = "   วัดใหม่ 2026-08-17: ถอด Plater ออกแล้ว BuffListFrame ของ Blizzard"
        .. " **มีปุ่ม buff ของ mob จริง** (fstack: Blizzard_NamePlateAuras.xml)"
    out[#out + 1] = "   |cffaaaaaaการวัดเดิมที่ว่า children=0 เสมอ ทำตอน Plater ครอบ UI อยู่|r"
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
        out[#out + 1] = "  |cffff5555ไม่มีปุ่มออร่าบน nameplate เลย|r"
        out[#out + 1] = "     buff ของ mob → ต้องเห็นไอคอนบน nameplate ด้วยตา (และต้องเป็น"
            .. " nameplate เริ่มต้นของ Blizzard — ปิด Plater/ThreatPlates ก่อน)"
        out[#out + 1] = "     debuff ของเรา → ต้องมี DoT ติด mob อยู่"
    end
    out[#out + 1] = ""

    local nOther, nOtherGood = ProbeOtherFrames(curve, out)
    out[#out + 1] = ""

    -- ── สรุป ──
    out[#out + 1] = "-- สรุป --"
    if nOther > 0 then
        if nOtherGood > 0 then
            out[#out + 1] = ("  |cff44ff44Target/Focus/Boss frame ใช้ได้ %d/%d|r"
                .. " — นี่คือทางเข้าถึง buff ของ mob"):format(nOtherGood, nOther)
        else
            out[#out + 1] = ("  |cffff9a9aTarget/Focus/Boss frame หา aid ได้ %d แต่ curve ไม่ผ่าน|r")
                :format(nOther)
        end
    end
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
-- Read Secret popup — เรนเดอร์ค่า secret ด้วย FontString (idiom WatchVar/Peek)
-- ============================================================
-- `"" .. tostring(secret)` ได้ string ที่ **ยังเป็น secret** แต่ Blizzard ยอมให้
-- FontString วาดออกจอ ⇒ user อ่านด้วยตา · ห้ามใช้ EditBox เด็ดขาด
-- (copy = GetText = unmask) — popup นี้จึง copy ไม่ได้โดยตั้งใจ
-- แถม: ลอง C_Spell.GetSpellName(secret spellID) — ส่ง secret เข้า function เป็น
-- "pass" ที่กฎอนุญาต ถ้าคืนชื่อ (secret string) ก็เรนเดอร์ได้ = เห็นชื่อ buff เลย

local secretFrame, secretFS

local function PeekVal(v)
    if v == nil then return "nil" end
    local ok, res = pcall(function() return "" .. tostring(v) end)
    if ok then return res end
    return "<เรนเดอร์ไม่ได้>"
end

local function BuildSecretText()
    local NL = string.char(10)
    local t = "|cffffd200== Read Secret — ค่าจริงบนปุ่มออร่า nameplate ==|r" .. NL
        .. "|cffaaaaaaอ่านด้วยตาเท่านั้น copy ไม่ได้ · ลากมุมขวาล่างขยายถ้าโดนตัด|r" .. NL .. NL
    local found = 0
    for i = 1, MAX_PLATES do
        local unit = "nameplate" .. i
        if UnitExists(unit) then
            local af = AurasFrameOf(unit)
            if af then
                for _, L in ipairs(LISTS) do
                    local children = LayoutChildren(af[L.field])
                    if children then
                        for idx, btn in ipairs(children) do
                            if btn and (btn.spellID ~= nil or btn.auraInstanceID ~= nil) then
                                found = found + 1
                                local nm
                                if C_Spell and C_Spell.GetSpellName then
                                    local okN, v = pcall(C_Spell.GetSpellName, btn.spellID)
                                    if okN then nm = v end
                                end
                                local stkTxt
                                local cf = btn.CountFrame
                                if cf ~= nil and cf.Count ~= nil then
                                    local okC, v = pcall(cf.Count.GetText, cf.Count)
                                    if okC then stkTxt = v end
                                end
                                local cdTxt
                                local cd = btn.Cooldown
                                if cd ~= nil and cd.GetCountdownFontString ~= nil then
                                    local okF, fs = pcall(cd.GetCountdownFontString, cd)
                                    if okF and fs ~= nil then
                                        local okT, v = pcall(fs.GetText, fs)
                                        if okT then cdTxt = v end
                                    end
                                end
                                local sMs, dMs
                                if cd ~= nil and cd.GetCooldownTimes ~= nil then
                                    local okCd, a, b = pcall(cd.GetCooldownTimes, cd)
                                    if okCd then sMs, dMs = a, b end
                                end
                                t = t .. "|cff88ccff[" .. unit .. " " .. L.kind .. "#" .. idx .. "]|r" .. NL
                                t = t .. "   spellID = " .. PeekVal(btn.spellID)
                                    .. "    ชื่อเวท = |cff44ff44" .. PeekVal(nm) .. "|r" .. NL
                                t = t .. "   auraInstanceID = " .. PeekVal(btn.auraInstanceID)
                                    .. "    stack = [" .. PeekVal(stkTxt) .. "]"
                                    .. "    cdText = [" .. PeekVal(cdTxt) .. "]" .. NL
                                t = t .. "   start = " .. PeekVal(sMs) .. "    dur = " .. PeekVal(dMs)
                                    .. NL .. NL
                            end
                        end
                    end
                end
            end
        end
    end
    if found == 0 then
        t = t .. "|cffff9a9aไม่มีปุ่มออร่าบน nameplate ตอนนี้|r" .. NL
            .. "  buff ของ mob -> ไอคอนต้องโผล่บน nameplate (Blizzard เริ่มต้น ไม่ใช่ Plater)" .. NL
            .. "  debuff -> ต้องมี DoT ของเราติด mob"
    end
    return t
end

local function RefreshSecret()
    if not secretFS then return end
    local ok, text = pcall(BuildSecretText)
    secretFS:SetText(ok and text or ("พัง: " .. tostring(text)))
end

local function BuildSecretFrame()
    if secretFrame then return secretFrame end

    secretFrame = CreateFrame("Frame", "GeRODPSToolsDispelSecretPopup", UIParent,
        "BasicFrameTemplateWithInset")
    secretFrame:SetSize(760, 560)
    secretFrame:SetPoint("CENTER", 120, 0)
    secretFrame:SetMovable(true)
    secretFrame:EnableMouse(true)
    secretFrame:RegisterForDrag("LeftButton")
    secretFrame:SetScript("OnDragStart", secretFrame.StartMoving)
    secretFrame:SetScript("OnDragStop", secretFrame.StopMovingOrSizing)
    secretFrame:SetResizable(true)
    if secretFrame.SetResizeBounds then secretFrame:SetResizeBounds(480, 300, 1800, 1300) end
    secretFrame:SetClampedToScreen(true)
    secretFrame:SetClipsChildren(true)     -- เฟรมเราเองถาวร (ไม่ใช่ pooled) — clip ได้
    secretFrame:SetFrameStrata("DIALOG")   -- ลอยเหนือหน้าต่างหลักของ tool
    if secretFrame.TitleText then secretFrame.TitleText:SetText("Read Secret — Nameplate Aura") end
    table.insert(UISpecialFrames, "GeRODPSToolsDispelSecretPopup")

    -- Rule 10: แถวแรกเผื่อ title bar
    local btnR = CreateFrame("Button", nil, secretFrame, "UIPanelButtonTemplate")
    btnR:SetSize(110, 24)
    btnR:SetPoint("TOPLEFT", secretFrame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 8))
    btnR:SetText("Refresh")
    btnR:SetScript("OnClick", RefreshSecret)

    -- ⚠ FontString เท่านั้น — ห้ามเปลี่ยนเป็น EditBox (secret จะ unmask ตอน copy)
    secretFS = secretFrame:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    secretFS:SetPoint("TOPLEFT", btnR, "BOTTOMLEFT", 0, -8)
    secretFS:SetPoint("TOPRIGHT", secretFrame, "TOPRIGHT", -SIDE_PAD, 0)
    secretFS:SetJustifyH("LEFT")
    secretFS:SetJustifyV("TOP")
    secretFS:SetWordWrap(true)
    secretFS:SetSpacing(2)

    local resize = CreateFrame("Button", nil, secretFrame)
    resize:SetSize(16, 16)
    resize:SetPoint("BOTTOMRIGHT", -4, 4)
    resize:EnableMouse(true)
    resize:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    resize:SetPushedTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Down")
    resize:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            secretFrame:StopMovingOrSizing()
            secretFrame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resize:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then secretFrame:StopMovingOrSizing() end
    end)

    return secretFrame
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
    hint:SetText(
        "|cffffd200เป้าหมายหลัก (ขั้น 3):|r อยู่ในดัน + combat + "
        .. "|cffffcc55mob มีไอคอน buff โผล่บน nameplate|r (Magic/Enrage ที่คลาสเราปลดได้)"
        .. "  — |cffff5555ต้องใช้ nameplate เริ่มต้นของ Blizzard|r"
        .. " (Plater/ThreatPlates จะครอบ UI ทำปุ่มของ Blizzard หาย)"
        .. "|n|cffffd200เสริม (ขั้น 4):|r Target/Focus/Boss frame — ได้เฉพาะตัวที่เล็งอยู่"
        .. "  |cffaaaaaa(นอก combat ออร่าไม่ secret -> ผลหลอก)|r")

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

    local btnSecret = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnSecret:SetSize(190, 24)
    btnSecret:SetPoint("LEFT", btnSel, "RIGHT", 8, 0)
    btnSecret:SetText("Read Secret (อ่านด้วยตา)")
    btnSecret:SetScript("OnClick", function()
        local f = BuildSecretFrame()
        f:Show()
        f:Raise()
        RefreshSecret()
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
