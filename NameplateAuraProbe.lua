--[[
    GeRODPS_Tools / NameplateAuraProbe.lua

    "Nameplate Aura Probe" — ตอบคำถามเดียว: **บนปุ่มออร่าของ nameplate ศัตรู
    เราอ่าน spellID / stack / remain ออกมาได้จริงไหม และค่าที่ได้เอาไปคำนวณ
    ฝั่ง Lua ได้หรือต้องส่งดิบให้ AHK**

    เกณฑ์ของโปรเจกต์: ค่าที่ได้เป็น secret = **ผ่าน** (ส่งเข้า STS ให้ AHK อ่านต่อได้)
    ค่าที่เรียกแล้ว throw / index ไม่ได้ = **ตก**
    ⇒ probe นี้จึงวัด 2 ชั้น: (1) หยิบออกมาได้ไหม (2) **เอาไป + ได้ไหม** (arithmetic test)
       ข้อ 2 คือตัวตัดสินว่า remain คำนวณฝั่ง Lua ได้ หรือต้องส่ง start/duration/now
       ให้ AHK คิด (แบบที่ NameplateAuraCheck.lua ออกแบบไว้)

    ── ⚠ ต้องมีอะไรตอนกด Probe (สำคัญมาก) ────────────────────────────────
      1. **ต้องมี nameplate ศัตรูที่มีออร่าติดอยู่จริง** — ปกติคือ DoT ของเราเอง
         (Blizzard กรอง debuff list ด้วย requireSourceIsLocalPlayer ⇒ ดีบัฟของคนอื่น
         ไม่ขึ้นปุ่ม = อ่านไม่ได้ทางนี้ ไม่ใช่บั๊ก)
      2. **ต้องอยู่ใน combat + อยู่ในดัน** — นอก combat ออร่าไม่ secret ผลจะดู
         "ผ่านหมด" แบบหลอก ๆ (บทเรียนเดียวกับ CDMAuraProbe)
      3. **nameplate ต้องเปิดแสดงอยู่** (V key / CVar nameplateShowEnemies) และ
         CVar ที่ปิดการโชว์ aura บน nameplate จะทำให้ไม่มีปุ่มให้อ่านเลย
      หัวหน้าต่างบอกให้เองว่าเงื่อนไขครบหรือยัง (แถบเขียว/แดง)

    ── ⚠ อ่าน field เท่านั้น ไม่เรียก method ที่เขียนสถานะ ─────────────────
      บทเรียนจาก CooldownManagerLab: แตะ Lua ของ Blizzard แบบเขียนค่า = เฟรมติด
      taint แล้วโค้ด Blizzard เองพังจนกว่าจะ /reload · ที่นี่เรียกเฉพาะ getter
      (GetLayoutChildren / IsShown / GetText / GetCooldownTimes) ทั้งหมดห่อ pcall

    ── สิ่งที่วัด (ต่อปุ่มออร่า) ──────────────────────────────────────────
      ระบุตัวตน : btn.spellID · btn.auraInstanceID · btn.isBuff
      Stack     : CountFrame.Count:IsShown() + :GetText()   (Blizzard ซ่อนเมื่อ ≤1)
      Remain    : Cooldown:GetCooldownTimes() → startMs, durationMs
      Arithmetic: ลอง (v + 0) กับทุกค่าที่หยิบได้ → บอกว่าคำนวณฝั่ง Lua ได้ไหม

    ── ส่วน B ของรายงาน ─────────────────────────────────────────────────
      เรียก API จริงของ addon: GeRODPS.GetAllAuraFromSetOfNamePlate(units)
      แล้วพิมพ์ record ที่ได้ → ยืนยันว่า API ใช้งานได้จริงในสภาพ combat

    ── ปุ่ม "Peek ค่าจริง" ───────────────────────────────────────────────
      รายงานข้างบนบอกได้แค่ "SECRET string" — บอกไม่ได้ว่าข้อความ**หน้าตายังไง**
      (จะรู้ format ของ countdown text ต้องเห็นของจริง) · ปุ่มนี้สลับไปแผงที่
      เรนเดอร์ค่าจริงลง **FontString** ด้วย idiom ของ WatchVar.lua
      (`"" .. tostring(v)` = string ที่ยังเป็น secret แต่ Blizzard ยอมให้วาด)
      ⇒ user อ่านด้วยตาแล้วบอกกลับมา · แผงนี้ **copy ไม่ได้** โดยตั้งใจ
      (copy = GetText = unmask) — รายงานที่ copy ได้อยู่อีกแผง

    Public:
        GeRODPS_Tools.ShowNameplateAuraProbe()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local TITLE_H  = 28     -- Rule 10: แถวแรกต้องเผื่อความสูง title bar
local SIDE_PAD = 14

local MIN_W, MIN_H = 700, 380
local MAX_W, MAX_H = 2400, 1500

local MAX_PLATES = 30

local LISTS = {
    { field = "DebuffListFrame",       kind = "debuff" },
    { field = "BuffListFrame",         kind = "buff"   },
    { field = "CrowdControlListFrame", kind = "cc"     },
}

-- ============================================================
-- helpers (idiom เดียวกับ CDMAuraProbe)
-- ============================================================

local function IsSecret(v)
    if issecretvalue == nil then return false end
    local ok, res = pcall(issecretvalue, v)
    if not ok then return false end
    return res == true
end

--- ค่า secret แสดงเป็น [s] เฉย ๆ — สั้นพอสำหรับคอลัมน์แคบ และเป็นข้อมูลเดียวที่ต้องรู้
--- (จะเป็น number หรือ string ก็เอาไปคำนวณ/เทียบฝั่ง Lua ไม่ได้อยู่ดี ⇒ ต้องส่งดิบให้ AHK)
local function SafeStr(v)
    if v == nil then return "nil" end
    if IsSecret(v) then return "[s]" end
    return tostring(v)
end

--- เรียก getter แบบปลอดภัย — คืน (okFlag, value) โดยที่ค่า secret ถือว่า ok
local function Get(obj, method)
    if obj == nil or obj[method] == nil then return false, nil, "no method" end
    local ok, a, b = pcall(obj[method], obj)
    if not ok then return false, nil, "ERR: " .. tostring(a) end
    return true, a, nil, b
end

local function EnvLines()
    local out = {}
    local inCombat = UnitAffectingCombat("player")
    local inInst, instType = IsInInstance()

    local hasRestrict, aurasSecret = "?", "?"
    if C_Secrets ~= nil then
        if C_Secrets.HasSecretRestrictions ~= nil then
            local ok, v = pcall(C_Secrets.HasSecretRestrictions)
            if ok then hasRestrict = SafeStr(v) end
        end
        if C_Secrets.ShouldAurasBeSecret ~= nil then
            local ok, v = pcall(C_Secrets.ShouldAurasBeSecret)
            if ok then aurasSecret = SafeStr(v) end
        end
    end

    out[#out + 1] = ("combat=%s  instance=%s(%s)  HasSecretRestrictions=%s  ShouldAurasBeSecret=%s")
        :format(SafeStr(inCombat), SafeStr(inInst), SafeStr(instType), hasRestrict, aurasSecret)

    local warn = {}
    if IsSecret(inCombat) then
        warn[#warn + 1] = "combat เป็น secret (เทียบไม่ได้)"
    elseif inCombat ~= true then
        warn[#warn + 1] = "ยังไม่อยู่ใน combat"
    end
    if aurasSecret ~= "true" then warn[#warn + 1] = "ออร่ายังไม่ secret" end
    if #warn > 0 then
        out[#out + 1] = "|cffff5555!! " .. table.concat(warn, " · ")
            .. " -> ผลยังพิสูจน์อะไรไม่ได้ ต้องยิงตอนอยู่ในดัน+combat+มี DoT ติด mob|r"
    else
        out[#out + 1] = "|cff44ff44เงื่อนไขครบ - ผลรอบนี้เชื่อได้|r"
    end
    return out
end

-- ============================================================
-- frame path
-- ============================================================

--- คืน AurasFrame + ชื่อ field ที่เจอ (ยืนยัน fallback ใน NameplateAuraCheck)
local function AurasFrameOf(unit)
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil, "ไม่มี C_NamePlate" end
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return nil, "ไม่มี nameplate frame" end
    local uf = plate.UnitFrame
    if not uf then return nil, "ไม่มี .UnitFrame" end
    if uf.AurasFrame then return uf.AurasFrame, "UnitFrame.AurasFrame" end
    if uf.NameplateAurasFrame then return uf.NameplateAurasFrame, "UnitFrame.NameplateAurasFrame" end
    return nil, "ไม่มีทั้ง AurasFrame / NameplateAurasFrame"
end

local function LayoutChildren(listFrame)
    if not listFrame then return nil, "ไม่มี list frame" end
    if not listFrame.GetLayoutChildren then return nil, "ไม่มี GetLayoutChildren" end
    local ok, children = pcall(listFrame.GetLayoutChildren, listFrame)
    if not ok then return nil, "ERR: " .. tostring(children) end
    if type(children) ~= "table" then return nil, "ไม่ใช่ table" end
    return children
end


-- ============================================================
-- ร่องรอย dispel type บนปุ่มออร่า
-- ============================================================
-- สมมติฐาน (จากซอร์ส Blizzard_BuffFrame ที่มีในเครื่อง):
--     AuraUtil.SetAuraBorderAtlas(self.DebuffBorder, buttonInfo.debuffType, show)
--     AuraUtil.SetAuraSymbol(self.Symbol, buttonInfo.debuffType)
-- ⇒ Blizzard เข้ารหัส "ชนิด dispel" ลงไปที่ **atlas ของ texture** ไม่ใช่ field ข้อมูล
--   ถ้าปุ่มบน nameplate ทำแบบเดียวกัน จะอ่านกลับด้วย GetAtlas() ได้ = frame read ล้วน
--   (ทางเดียวกับที่ Route B ใช้อยู่ — ไม่แตะ C_UnitAuras ที่ตายบน 12.1)
--
-- อีกสมมติฐานที่ต้องยืนยัน: **BuffListFrame ของ nameplate ศัตรูโชว์เฉพาะ buff ที่
-- คลาสเราปลดได้** ถ้าจริง แค่ "มีปุ่มอยู่ในลิสต์ buff" ก็เป็นคำตอบครึ่งหนึ่งแล้ว
-- (เหลือแค่แยก Magic / Enrage ซึ่งเป็นหน้าที่ของ atlas)
--
-- ⚠ ค่า atlas อาจเป็น secret ถ้า Blizzard ตั้งมาจาก dispelName ที่ secret
--   → รายงานจะบอกให้เห็นเอง (SafeStr → [s]) ก่อนตัดสินใจว่าจะเทียบฝั่งไหน

local TEX_FIELD_GUESS = {
    "Border", "DebuffBorder", "Symbol", "Overlay", "EdgeHighlight",
    "TempEnchantBorder", "Stealable", "Icon",
}
local DATA_FIELD_GUESS = {
    "dispelName", "debuffType", "isStealable", "isHarmful", "isBuff", "auraType",
}

local function DumpTexture(label, tex, out, pad)
    if tex == nil then return end
    local okA, atlas = Get(tex, "GetAtlas")
    local okT, path  = Get(tex, "GetTexture")
    local okS, shown = Get(tex, "IsShown")
    local line = pad .. label
        .. "  shown=" .. (okS and SafeStr(shown) or "ERR")
        .. "  atlas=" .. (okA and SafeStr(atlas) or "ERR")
        .. "  tex=" .. (okT and SafeStr(path) or "ERR")
    if tex.GetVertexColor then
        local okC, r, g, b = pcall(tex.GetVertexColor, tex)
        if okC and r ~= nil then
            local okFmt, cs = pcall(string.format, "  rgb=%.2f,%.2f,%.2f",
                r, g or 0, b or 0)
            if okFmt then line = line .. cs else line = line .. "  rgb=SECRET" end
        end
    end
    out[#out + 1] = line
end


-- ============================================================
-- ทางที่ 2: ถอดชนิด dispel ผ่าน ColorCurve (กู้จาก AuraCache.lua ที่ลบไปแล้ว)
-- ============================================================
-- ตาราง AuraUtil.GetDebuffDisplayInfoTable **ไม่มี Enrage** เพราะเป็นตารางของ
-- *debuff* ล้วน (Magic/Curse/Disease/Poison/Bleed/None) — Enrage เป็น **buff**
-- ที่ปลดได้ (Hunter Tranq Shot / Druid Soothe) ⇒ atlas/สีจากตารางนั้นบอกไม่ได้
--
-- แต่ AuraCache.lua (ลบไปแล้ว — กู้ผ่าน git) มีทางที่ครอบ Enrage ด้วย:
--   ยัด **ColorCurve ที่เราสร้างเอง** เข้า C_UnitAuras.GetAuraDispelTypeColor
--   โดยเข้ารหัส dispelTypeID ลงช่อง R (R = id/255) ⇒ ค่าที่ API คืนมาเป็น
--   สีของ **เส้นโค้งของเราเอง** ไม่ใช่ข้อมูลของ Blizzard ⇒ ถอด R กลับเป็น id ได้
--     Magic=1 · Curse=2 · Disease=3 · Poison=4 · **Enrage=9** · Bleed=11
--
-- ⚠ ปมเดียวที่ต้องวัด: auraInstanceID บนปุ่ม nameplate เป็น **secret**
--   โค้ดเดิมของ AuraCache bail ทิ้งทันทีเมื่อเจอ secret (issecretvalue guard)
--   ⇒ ยังไม่มีใครเคยลองส่ง secret เข้าไปจริง ๆ · ส่ง secret เข้า API = "pass"
--   ซึ่งกฎอนุญาต แต่สีที่คืนมาอาจติด taint ตามไปด้วย (แล้ว math.floor จะ throw)
--   probe นี้ลองทั้ง 2 ทางแล้วรายงานว่าเกิดอะไรขึ้น

local DISPEL_TYPE_NAMES = {
    [0]  = "None",
    [1]  = "Magic",
    [2]  = "Curse",
    [3]  = "Disease",
    [4]  = "Poison",
    [9]  = "Enrage",
    [11] = "Bleed",
}

local dispelCurve
local function BuildDispelCurve()
    if dispelCurve then return dispelCurve end
    if not (C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor) then return nil end
    local ok, curve = pcall(C_CurveUtil.CreateColorCurve)
    if not ok or curve == nil then return nil end
    if Enum and Enum.LuaCurveType and Enum.LuaCurveType.Step then
        pcall(curve.SetType, curve, Enum.LuaCurveType.Step)
    end
    for id in pairs(DISPEL_TYPE_NAMES) do
        pcall(curve.AddPoint, curve, id, CreateColor(id / 255, 1, 0, 1))
    end
    dispelCurve = curve
    return curve
end

--- ถอดชนิด dispel จาก auraInstanceID ตรง ๆ (ใช้ได้ทั้งจากปุ่มและจาก ForEachAura)
function ProbeDispelViaCurveID(unit, aid, out, pad)
    pad = pad or "          "

    local curve = BuildDispelCurve()
    if curve == nil then
        out[#out + 1] = pad .. "curve: |cffff9a9aสร้าง ColorCurve ไม่ได้|r"
        return
    end
    if not (C_UnitAuras and C_UnitAuras.GetAuraDispelTypeColor) then
        out[#out + 1] = pad .. "curve: |cffff9a9aไม่มี GetAuraDispelTypeColor|r"
        return
    end

    local ok, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, aid, curve)
    if not ok then
        out[#out + 1] = pad .. "curve: |cffff9a9aTHROW:|r " .. tostring(color)
        return
    end
    if color == nil then
        out[#out + 1] = pad .. "curve: คืน nil"
        return
    end

    local r = color.r
    if r == nil and type(color) == "table" then r = color[1] end
    local line = pad .. "curve: ได้สี  r=" .. SafeStr(r)
    if r ~= nil and not IsSecret(r) then
        local okF, id = pcall(function() return math.floor(r * 255 + 0.5) end)
        if okF then
            line = line .. "  -> id=" .. tostring(id)
                .. "  |cff44ff44ชนิด = " .. tostring(DISPEL_TYPE_NAMES[id] or "?") .. "|r"
        end
    else
        line = line .. "  |cffff9a9a<- secret: ถอดฝั่ง Lua ไม่ได้ ต้องส่งดิบให้ AHK|r"
    end
    out[#out + 1] = line

    -- ถามตรง ๆ ว่า "คลาส/ทาเลนต์เราปลดออร่านี้ได้ไหม" (talent-aware ของ Blizzard เอง)
    if C_UnitAuras.IsAuraFilteredOutByInstanceID then
        for _, flt in ipairs({ "HELPFUL|RAID_PLAYER_DISPELLABLE",
                               "HARMFUL|RAID_PLAYER_DISPELLABLE" }) do
            local okF, filteredOut = pcall(C_UnitAuras.IsAuraFilteredOutByInstanceID, unit, aid, flt)
            local res
            if not okF then
                res = "|cffff9a9aTHROW|r " .. tostring(filteredOut)
            elseif IsSecret(filteredOut) then
                res = "SECRET boolean (เทียบฝั่ง Lua ไม่ได้)"
            elseif filteredOut == false then
                res = "|cff44ff44ปลดได้|r"
            else
                res = "ปลดไม่ได้"
            end
            out[#out + 1] = pad .. "filter " .. flt .. " -> " .. res
        end
    end
end

--- dump ทุก texture + field ที่อาจบอกชนิด dispel
local function ProbeDispelSignature(unit, btn, out)
    out[#out + 1] = "        |cffaaaaaa--- ร่องรอย dispel type ---|r"

    local found = false
    for _, k in ipairs(TEX_FIELD_GUESS) do
        if btn[k] ~= nil then
            DumpTexture("btn." .. k, btn[k], out, "          ")
            found = true
        end
    end
    if not found then
        out[#out + 1] = "          (ไม่มี field texture ที่เดาไว้เลย — ดู region ดิบข้างล่าง)"
    end

    -- region ดิบ เผื่อชื่อ field ไม่ตรงที่เดา (nameplate ใช้ template คนละตัวกับ BuffFrame)
    local okR, regions = pcall(function() return { btn:GetRegions() } end)
    if okR and type(regions) == "table" then
        for i, rg in ipairs(regions) do
            local okO, objType = pcall(rg.GetObjectType, rg)
            if okO and objType == "Texture" then
                DumpTexture("region#" .. i, rg, out, "          ")
            end
        end
    end

    for _, k in ipairs(DATA_FIELD_GUESS) do
        if btn[k] ~= nil then
            out[#out + 1] = "          btn." .. k .. " = " .. SafeStr(btn[k])
        end
    end

    if btn.auraInstanceID ~= nil then ProbeDispelViaCurveID(unit, btn.auraInstanceID, out) end
end

--- แผนที่ debuffType → atlas/สี ที่ Blizzard ใช้ (มีตัวเดียวทั้งเกม)
--- ใช้แปล atlas ที่อ่านได้จากปุ่มกลับเป็นชื่อชนิด dispel
local function DispelInfoLines()
    local out = {}
    out[#out + 1] = "-- แผนที่ debuffType -> atlas/สี (AuraUtil.GetDebuffDisplayInfoTable) --"
    if AuraUtil == nil or AuraUtil.GetDebuffDisplayInfoTable == nil then
        out[#out + 1] = "  |cffff9a9a(ไม่มี AuraUtil.GetDebuffDisplayInfoTable ในเวอร์ชันนี้)|r"
        return out
    end
    local ok, t = pcall(AuraUtil.GetDebuffDisplayInfoTable)
    if not ok or type(t) ~= "table" then
        out[#out + 1] = "  |cffff9a9a(เรียกไม่ได้)|r"
        return out
    end
    local n = 0
    for k, v in pairs(t) do
        n = n + 1
        local line = "  [" .. tostring(k) .. "]"
        if type(v) == "table" then
            for kk, vv in pairs(v) do
                if type(vv) ~= "table" and type(vv) ~= "function" then
                    line = line .. "  " .. tostring(kk) .. "=" .. tostring(vv)
                end
            end
        else
            line = line .. "  " .. tostring(v)
        end
        out[#out + 1] = line
    end
    if n == 0 then out[#out + 1] = "  (ตารางว่าง)" end
    return out
end

-- ============================================================
-- probe ต่อปุ่ม
-- ============================================================

local function ProbeButton(btn, kind, idx, out, unitToken)
    local sid  = btn.spellID
    local aid  = btn.auraInstanceID
    local isB  = btn.isBuff

    out[#out + 1] = ("    [%s #%d] spellID=%s  auraInstanceID=%s  isBuff=%s")
        :format(kind, idx, SafeStr(sid), SafeStr(aid), SafeStr(isB))

    -- ── Stack: CountFrame.Count (Blizzard :Hide() เมื่อ applications <= 1) ──
    local cf = btn.CountFrame
    if cf == nil then
        out[#out + 1] = "        stack: ไม่มี .CountFrame"
    else
        local fs = cf.Count
        if fs == nil then
            out[#out + 1] = "        stack: มี CountFrame แต่ไม่มี .Count"
        else
            local okS, shown = Get(fs, "IsShown")
            local okT, txt   = Get(fs, "GetText")
            out[#out + 1] = ("        stack: Count shown=%s text=%s   %s")
                :format(okS and SafeStr(shown) or "ERR", okT and SafeStr(txt) or "ERR",
                        (okS and shown ~= true and not IsSecret(shown))
                            and "|cffaaaaaa(ซ่อน = stack 1)|r" or "")
        end
    end

    -- ── Remain: Cooldown:GetCooldownTimes() → startMs, durationMs ──
    local cd = btn.Cooldown
    if cd == nil then
        out[#out + 1] = "        remain: ไม่มี .Cooldown"
    else
        if cd.GetCooldownTimes == nil then
            out[#out + 1] = "        remain: ไม่มี GetCooldownTimes"
        else
            local ok, sMs, dMs = pcall(cd.GetCooldownTimes, cd)
            if not ok then
                out[#out + 1] = "        remain: GetCooldownTimes ERR: " .. tostring(sMs)
            else
                out[#out + 1] = ("        remain: startMs=%s  durationMs=%s  (now=%.0f)")
                    :format(SafeStr(sMs), SafeStr(dMs), GetTime() * 1000)
                -- ทดสอบสูตรจริงที่ AHK จะใช้ — ถ้าอันนี้ ok = คำนวณฝั่ง Lua ได้เลย
                local okCalc = pcall(function()
                    return (sMs + dMs - GetTime() * 1000) / 1000
                end)
                out[#out + 1] = "        remain-calc ฝั่ง Lua: "
                    .. (okCalc and "|cff44ff44ทำได้|r" or "|cffff9a9aทำไม่ได้ -> ต้องส่งให้ AHK|r")
            end
        end
    end

    -- ── Remain ทางที่ 2: ข้อความ countdown ที่ Blizzard วาดบนไอคอน ──
    -- Cooldown:GetCountdownFontString() = getter อย่างเป็นทางการของ Widget API
    -- (คืน SimpleFontString) ⇒ ถ้าอ่าน :GetText() ได้ = ส่งข้อความนี้แทน
    -- start/dur ได้เลย ไม่ต้องให้ AHK ลบเอง
    -- ⚠ ที่ต้องดูให้ครบ 3 อย่าง:
    --   1. hideNumbers — NamePlateAuraItemMixin เรียก SetHideCountdownNumbers(duration > 60)
    --      ⇒ ออร่ายาวเกิน 60 วิ Blizzard ซ่อนเลข = ไม่มีข้อความให้อ่าน
    --   2. รูปแบบข้อความ — ปัดเป็นวินาที / ย่อเป็น "2m" "1h" เมื่อเหลือเยอะ
    --      (ปลายทางต้อง parse ไม่ใช่ตัวเลขล้วน)
    --   3. secret หรือไม่ — ถ้า secret ก็ยังส่งผ่าน STS ได้ปกติ
    if cd ~= nil then
        local okH, hidden = Get(cd, "GetHideCountdownNumbers")
        local okM, minMs  = Get(cd, "GetMinimumCountdownDuration")
        local okD, dispD  = Get(cd, "GetCooldownDisplayDuration")
        out[#out + 1] = ("        cdText: hideNumbers=%s  minDuration=%s  displayDuration=%s")
            :format(okH and SafeStr(hidden) or "ERR", okM and SafeStr(minMs) or "ERR",
                    okD and SafeStr(dispD) or "ERR")

        if cd.GetCountdownFontString == nil then
            out[#out + 1] = "        cdText: |cffff9a9aไม่มี GetCountdownFontString บน widget นี้|r"
        else
            local okF, fs = pcall(cd.GetCountdownFontString, cd)
            if not okF then
                out[#out + 1] = "        cdText: |cffff9a9aGetCountdownFontString ERR:|r " .. tostring(fs)
            elseif fs == nil then
                out[#out + 1] = "        cdText: |cffff9a9aGetCountdownFontString คืน nil|r"
            else
                local okS, shown = Get(fs, "IsShown")
                local okV, vis   = Get(fs, "IsVisible")
                local okT, txt   = Get(fs, "GetText")
                -- visible=false เกิดได้ 2 สาเหตุ และต้องแยกให้ออก:
                --   (ก) Blizzard ไม่ได้วาดเลขนี้ (เวลาเหลือยาวเกินเกณฑ์) → cd/btn ยัง visible
                --   (ข) ทั้ง plate/ปุ่มไม่ถูกวาดตอนนั้น → cd/btn ก็ false ด้วย
                -- สองกรณีนี้ต้องทำคนละอย่างฝั่ง reader (ก = "-" ตัดสินไม่ได้ · ข = ข้ามทั้ง mob)
                local _, btnVis = Get(btn, "IsVisible")
                local _, cdVis  = Get(cd,  "IsVisible")
                out[#out + 1] = ("        cdText chain: btn.visible=%s  cooldown.visible=%s")
                    :format(SafeStr(btnVis), SafeStr(cdVis))
                out[#out + 1] = ("        cdText: shown=%s visible=%s  text=%s")
                    :format(okS and SafeStr(shown) or "ERR", okV and SafeStr(vis) or "ERR",
                            okT and SafeStr(txt) or "ERR")
                -- ⚠ ห้ามเทียบ txt ~= "" ตรง ๆ ตอนเป็น secret (compare = unmask)
                -- secret string = "มีข้อความแน่นอน" อยู่แล้ว → usable
                local usable
                if (not okT) or txt == nil then
                    usable = false
                elseif IsSecret(txt) then
                    usable = true
                else
                    usable = (txt ~= "")
                end
                out[#out + 1] = "        cdText verdict: "
                    .. (usable and "|cff44ff44มีข้อความ -> ใช้แทน start/dur ได้|r"
                                or "|cffff9a9aไม่มีข้อความ -> ใช้แทนไม่ได้ ต้องใช้ start/dur|r")
            end
        end
    end

    ProbeDispelSignature(unitToken, btn, out)
end


-- ============================================================
-- config ของ list frame — "ทำไม buff ของ mob ไม่โผล่"
-- ============================================================
-- วัดแล้ว 2 รอบ: DebuffListFrame มีปุ่มได้จริง (DoT ของเรา) แต่ BuffListFrame
-- ว่างเสมอแม้ mob กำลัง enrage ⇒ path ไม่ผิด แต่ Blizzard **ไม่วาด buff ของ mob**
-- ให้ด้วย filter ปัจจุบัน
--
-- ตัวกรองอยู่บนตัว list frame เอง (NamePlateAuraListFrame มี field คุม เช่น
-- requireSourceIsLocalPlayer / maxAuraItemsDisplayed / filter string)
-- ⇒ อ่าน field ทั้งหมดออกมาดูก่อน จะได้รู้ว่ามีสวิตช์ให้เปิดไหม
-- ห้ามเซ็ตค่ากลับ (เขียน = taint เฟรม Blizzard — บทเรียน CooldownManagerLab)

--- ทางของ Plater สำหรับ nameplate ตัวนี้ — เดินเส้นทางเดียวกับ NameplateAuraCheck
--- โชว์ในคอลัมน์ของ plate นั้นเลย ⇒ เห็นทันทีว่าติดขัดขั้นไหน (ไม่ต้องเลื่อนไปส่วน F)
local function DumpPlaterForUnit(unit, out)
    if _G.Plater == nil then return end
    out[#out + 1] = "    -- Plater --"
    local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit
        and C_NamePlate.GetNamePlateForUnit(unit) or nil
    if plate == nil then
        out[#out + 1] = "      |cffff9a9aไม่มี plate|r"
        return
    end
    local uf, how = plate.unitFrame, "plate.unitFrame"
    if uf == nil then
        local okN, nm = pcall(plate.GetName, plate)
        if okN and type(nm) == "string" then
            uf, how = _G[nm .. "PlaterUnitFrame"], "_G[" .. nm .. "PlaterUnitFrame]"
        end
    end
    if uf == nil then
        out[#out + 1] = "      |cffff9a9aหา Plater unitFrame ไม่เจอ (ทั้ง plate.unitFrame และชื่อ global)|r"
        return
    end

    local P = _G.Plater
    local sep = P and P.db and P.db.profile and P.db.profile.buffs_on_aura2
    out[#out + 1] = ("      unitFrame via %s  ·  Separate Buffs = %s"):format(how, SafeStr(sep))

    for _, key in ipairs({ "BuffFrame", "BuffFrame2" }) do
        local bf = uf[key]
        if bf == nil then
            out[#out + 1] = ("      [%s] |cffff9a9aไม่มี|r"):format(key)
        elseif type(bf.PlaterBuffList) ~= "table" then
            out[#out + 1] = ("      [%s] |cffff9a9aไม่มี PlaterBuffList|r"):format(key)
        else
            local nAll, nLive = #bf.PlaterBuffList, 0
            for _, icon in ipairs(bf.PlaterBuffList) do
                local okS, shown = pcall(icon.IsShown, icon)
                if icon.InUse == true and okS and shown == true and icon.SpellId ~= nil then
                    nLive = nLive + 1
                    if nLive <= 4 then
                        out[#out + 1] = ("        icon#%d SpellId=%s Stacks=%s isBuff=%s Expiration=%s Duration=%s")
                            :format(nLive, SafeStr(icon.SpellId), SafeStr(icon.Stacks),
                                    SafeStr(icon.isBuff), SafeStr(icon.ExpirationTime),
                                    SafeStr(icon.Duration))
                    end
                end
            end
            out[#out + 1] = ("      [%s] pool=%d  ใช้งานจริง(InUse+shown+SpellId)=%d")
                :format(key, nAll, nLive)
        end

        -- เส้นทางของ WoW 12.x: Plater สร้าง CustomAuraContainer ของ Blizzard
        -- แล้วเก็บปุ่มที่มันสร้างไว้ใน .auraButtons (PlaterBuffList เป็น stub ว่าง)
        -- คำถามที่ต้องตอบ: ปุ่มเหล่านี้มีอะไรให้อ่านได้บ้าง (โดยเฉพาะใน combat)
        if bf ~= nil and type(bf.auraButtons) == "table" then
            local nB, nVis = #bf.auraButtons, 0
            for _, ab in ipairs(bf.auraButtons) do
                local okV, vis = pcall(ab.IsVisible, ab)
                if okV and vis == true then
                    nVis = nVis + 1
                    if nVis <= 3 then
                        local okC, sMs, dMs = false, nil, nil
                        if ab.Cooldown ~= nil and ab.Cooldown.GetCooldownTimes ~= nil then
                            okC, sMs, dMs = pcall(ab.Cooldown.GetCooldownTimes, ab.Cooldown)
                        end
                        local okT, tex = false, nil
                        if ab.Icon ~= nil then okT, tex = pcall(ab.Icon.GetTexture, ab.Icon) end
                        out[#out + 1] = ("        auraBtn#%d  cooldown=%s/%s  icon=%s")
                            :format(nVis,
                                okC and SafeStr(sMs) or "ERR", okC and SafeStr(dMs) or "ERR",
                                okT and SafeStr(tex) or "ERR")
                        DumpScalarFields(ab, out, "          ", 12)
                    end
                end
            end
            out[#out + 1] = ("      [%s] auraButtons=%d  ที่มองเห็น=%d  |cffffcc55(เส้น CustomAuraContainer)|r")
                :format(key, nB, nVis)
        end
    end
end

local function DumpListConfig(listFrame, label, out)
    if listFrame == nil then
        out[#out + 1] = "    [" .. label .. "] |cffff9a9aไม่มี list frame|r"
        return
    end
    local n = "?"
    local children = LayoutChildren(listFrame)
    if children then n = tostring(#children) end
    local okS, shown = Get(listFrame, "IsShown")

    -- คำถาม: "มีออร่าที่อยู่ใน data แต่ไม่ถูกวาดบน nameplate ไหม?"
    -- ถ้ามี → NameplateAuraCheck ที่กรองแค่ spellID ~= nil จะส่งออร่าผีออกไป
    -- (นับ "มี Aura" เกินจริง / "ไม่มี Aura" ขาด) — btn:IsShown() เป็น plain จึงนับได้
    local nShown, nHiddenWithID, nNoID = 0, 0, 0
    if children then
        for _, btn in ipairs(children) do
            local okB, vis = pcall(btn.IsShown, btn)
            local isVis = (okB and vis == true)
            if isVis then nShown = nShown + 1 end
            if btn.spellID == nil then
                nNoID = nNoID + 1
            elseif not isVis then
                nHiddenWithID = nHiddenWithID + 1
            end
        end
    end

    out[#out + 1] = ("    [%s] children=%s shown=%s  |  ปุ่มที่วาดจริง=%d  ไม่มี spellID=%d  %s")
        :format(label, n, okS and SafeStr(shown) or "ERR", nShown, nNoID,
            nHiddenWithID > 0
                and ("|cffff5555ซ่อนแต่มี spellID=" .. nHiddenWithID .. " (ออร่าผี!)|r")
                or "|cff44ff44ไม่มีปุ่มซ่อนที่ยังถือ spellID|r")

    -- field ที่ไม่ใช่ function/table ทั้งหมด = ตัวกรองที่ Blizzard ตั้งไว้
    local keys = {}
    local okP = pcall(function()
        for k, v in pairs(listFrame) do
            local tv = type(v)
            if tv ~= "function" and tv ~= "table" and tv ~= "userdata" then
                keys[#keys + 1] = tostring(k) .. "=" .. SafeStr(v)
            end
        end
    end)
    if not okP then
        out[#out + 1] = "        (อ่าน field ไม่ได้)"
        return
    end
    table.sort(keys)
    if #keys == 0 then
        out[#out + 1] = "        (ไม่มี field ค่าเดี่ยว)"
        return
    end
    local line = "        "
    for _, k in ipairs(keys) do
        if #line > 110 then out[#out + 1] = line; line = "        " end
        line = line .. k .. "  "
    end
    out[#out + 1] = line
end

--- CVar ที่คุมการโชว์ออร่าบน nameplate
local NP_CVARS = {
    "nameplateShowAll", "nameplateShowEnemies", "nameplateShowFriends",
    "nameplateShowDebuffsOnFriendly", "nameplateShowSelf",
    "nameplateResourceOnTarget", "showNameplateLoseAggroFlash",
    "UnitNameplatesShowBuffs", "UnitNameplatesShowDebuffs",
    "nameplateShowOnlyNames",
}

local function CVarLines()
    local out = {}
    out[#out + 1] = "-- CVar ที่เกี่ยวกับออร่าบน nameplate --"
    local line = "  "
    for _, cv in ipairs(NP_CVARS) do
        local ok, v = pcall(GetCVar, cv)
        if ok and v ~= nil then
            if #line > 100 then out[#out + 1] = line; line = "  " end
            line = line .. cv .. "=" .. tostring(v) .. "  "
        end
    end
    out[#out + 1] = line
    return out
end


-- ============================================================
-- ส่วน D: enumerate ออร่าด้วย API ตรง ๆ (ทางที่ ThreatPlates ใช้)
-- ============================================================
-- ThreatPlates (และ Plater) **ไม่อ่านปุ่มของ Blizzard เลย** — สร้างเฟรมเองแล้วเรียก
--     local slots = { GetAuraSlots(unitid, effect, max, token) }
--     GetAuraDataBySlot(unitid, slots[i])
-- ซึ่งเป็น API ตระกูลที่โปรเจกต์เราบันทึกไว้ว่า "ตายบน 12.1"
--
-- ⚠ แต่บันทึกนั้นอาจสรุปเร็วไป: probe นี้พิสูจน์แล้วว่า btn.spellID **คืนค่ามาได้
--   แต่เป็น secret** ไม่ได้ throw ⇒ เป็นไปได้ว่า GetAuraDataBySlot ก็คืน table ที่มี
--   field เป็น secret เหมือนกัน (ไม่ throw) ซึ่งแปลว่า **enumerate ได้**
--   แค่เทียบฝั่ง Lua ไม่ได้ → ส่งดิบให้ AHK เหมือน pattern อื่นในโปรเจกต์
--
-- ถ้าเป็นจริง ทางนี้จะกู้เรื่อง dispel ได้ทั้งกลุ่ม เพราะ aura.dispelName คือคำตอบตรง
-- (secret string → STS font hack → AHK เทียบ — pattern เดียวกับ targetRole ที่ใช้จริงอยู่)
--
-- ส่วนนี้จึงวัด 3 อย่างต่อ 1 filter: เรียกแล้ว throw ไหม · ได้กี่ตัว · field ไหน secret

local API_FILTERS = { "HELPFUL", "HARMFUL" }

local function DumpAuraData(a, out, pad)
    if type(a) ~= "table" then
        out[#out + 1] = pad .. "(ไม่ใช่ table: " .. SafeStr(a) .. ")"
        return
    end
    local keys = { "spellId", "name", "dispelName", "applications", "isHelpful",
                   "isHarmful", "auraInstanceID", "duration", "expirationTime",
                   "sourceUnit", "isStealable", "canApplyAura" }
    for _, k in ipairs(keys) do
        local v = a[k]
        if v ~= nil then
            out[#out + 1] = pad .. k .. " = " .. SafeStr(v)
        end
    end
end

local function ProbeAuraAPI(unit, out)
    out[#out + 1] = "[" .. unit .. "]"

    for _, flt in ipairs(API_FILTERS) do
        -- ── 1) GetAuraSlots + GetAuraDataBySlot (ทางของ ThreatPlates) ──
        local fn = C_UnitAuras and C_UnitAuras.GetAuraSlots
        if fn == nil then
            out[#out + 1] = "  " .. flt .. " GetAuraSlots: |cffff9a9aไม่มีฟังก์ชัน|r"
        else
            local ok, res = pcall(function() return { fn(unit, flt, 20) } end)
            if not ok then
                out[#out + 1] = "  " .. flt .. " GetAuraSlots: |cffff9a9aTHROW|r " .. tostring(res)
            else
                -- res[1] = continuationToken · res[2..] = slot
                local nSlot = math.max(0, #res - 1)
                out[#out + 1] = ("  %s GetAuraSlots: |cff44ff44เรียกได้|r  slots=%d  token=%s")
                    :format(flt, nSlot, SafeStr(res[1]))
                if nSlot > 0 and C_UnitAuras.GetAuraDataBySlot then
                    local okD, data = pcall(C_UnitAuras.GetAuraDataBySlot, unit, res[2])
                    if not okD then
                        out[#out + 1] = "    GetAuraDataBySlot: |cffff9a9aTHROW|r " .. tostring(data)
                    elseif data == nil then
                        out[#out + 1] = "    GetAuraDataBySlot: คืน nil"
                    else
                        out[#out + 1] = "    |cff44ff44GetAuraDataBySlot: ได้ table|r (ตัวแรก)"
                        DumpAuraData(data, out, "      ")
                    end
                end
            end
        end

        -- ── 1.5) AuraUtil.ForEachAura — **ทางที่ ThreatPlates Midnight ใช้จริง** ──
        -- AurasWidgetMidnight.lua: AuraUtil.ForEachAura(unitid, effect, nil, HandleAura, true)
        -- (เขา comment GetAuraSlots/GetAuraDataBySlot ทิ้งแล้ว เขียนกำกับว่า deprecated)
        if AuraUtil and AuraUtil.ForEachAura then
            local n, first = 0, nil
            local okE, err = pcall(AuraUtil.ForEachAura, unit, flt, nil, function(a)
                n = n + 1
                if first == nil then first = a end
                return n >= 5      -- หยุดที่ 5 พอ
            end, true)
            if not okE then
                out[#out + 1] = "  " .. flt .. " ForEachAura: |cffff9a9aTHROW|r " .. tostring(err)
            else
                out[#out + 1] = ("  %s |cff44ff44ForEachAura: เรียกได้|r  เจอ %d ออร่า")
                    :format(flt, n)
                if first ~= nil then
                    DumpAuraData(first, out, "      ")
                    -- ถามต่อ 2 คำถามที่ ThreatPlates ใช้ตัดสินเรื่อง dispel
                    local aid = first.auraInstanceID
                    if aid ~= nil and C_UnitAuras and C_UnitAuras.IsAuraFilteredOutByInstanceID then
                        local okF, fo = pcall(C_UnitAuras.IsAuraFilteredOutByInstanceID,
                            unit, aid, flt .. "|RAID_PLAYER_DISPELLABLE")
                        local res
                        if not okF then res = "|cffff9a9aTHROW|r " .. tostring(fo)
                        elseif IsSecret(fo) then res = "SECRET boolean"
                        elseif fo == false then res = "|cff44ff44ปลดได้|r"
                        else res = "ปลดไม่ได้" end
                        out[#out + 1] = "      RAID_PLAYER_DISPELLABLE -> " .. res
                    end
                    if aid ~= nil then
                        ProbeDispelViaCurveID(unit, aid, out, "      ")
                    end
                end
            end
        end

        -- ── 2) GetAuraDataByIndex (ทางที่โค้ดเก่าของเราใช้) ──
        local fnI = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
        if fnI ~= nil then
            local okI, d1 = pcall(fnI, unit, 1, flt)
            if not okI then
                out[#out + 1] = "  " .. flt .. " GetAuraDataByIndex(1): |cffff9a9aTHROW|r " .. tostring(d1)
            elseif d1 == nil then
                out[#out + 1] = "  " .. flt .. " GetAuraDataByIndex(1): คืน nil (ไม่มีออร่า)"
            else
                out[#out + 1] = "  " .. flt .. " GetAuraDataByIndex(1): |cff44ff44ได้ table|r"
                DumpAuraData(d1, out, "      ")
            end
        end
    end
end


-- ============================================================
-- ส่วน E: API ที่หาด้วย spellID / ชื่อ — **ทางที่เหลืออยู่ทางเดียว**
-- ============================================================
-- ข้อความ error ของ 12.1 บอกชัด: "Auras cannot be accessed when secret while
-- tainted by '<addon>'" ⇒ ตระกูล index/slot/instanceID **throw** ไม่ใช่คืน secret
-- แต่เอกสาร Blizzard ระบุว่า API ที่หาด้วย **spellID / ชื่อเวท ยังเรียกได้ตามเดิม**
--
-- ถ้าจริง = เส้นทางกู้ทั้งกลุ่มที่ตายไป เพราะโปรเจกต์เรามี "ลิสต์ spellID" อยู่แล้ว
-- (DispelAura pack 50 แถว · Bleed 12 · ฯลฯ) ⇒ ไม่ต้อง enumerate เลย
-- ถามทีละ spellID ที่สนใจตรง ๆ
--
-- ⚠ รอบก่อนทดสอบด้วย 6603 (Auto Attack — ไม่ใช่ออร่า) ผลเลยสรุปไม่ได้
--   ต้องใส่ spellID ของออร่าที่ **ติดอยู่จริงตอนนั้น** เท่านั้น
--   (เช่น 980 Agony ที่ probe เคยเห็นบน nameplate มาแล้ว)

local BY_ID_UNITS = { "target", "nameplate1", "nameplate2", "nameplate3", "player" }

local function ProbeBySpellID(spellID, out)
    out[#out + 1] = "== ส่วน E: API ที่หาด้วย spellID (spellID = " .. tostring(spellID) .. ") =="
    if type(spellID) ~= "number" or spellID <= 0 then
        out[#out + 1] = "|cffff9a9aใส่ spellID ที่เป็นตัวเลขก่อน|r"
        return
    end
    out[#out + 1] = "|cffaaaaaaต้องเป็น spellID ของออร่าที่ติดอยู่จริงตอนนี้ ไม่งั้น nil = แปลผลไม่ได้|r"

    -- GetPlayerAuraBySpellID (ออร่าบนตัวเราเอง)
    if C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local ok, a = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
        if not ok then
            out[#out + 1] = "  GetPlayerAuraBySpellID: |cffff9a9aTHROW|r " .. tostring(a)
        elseif a == nil then
            out[#out + 1] = "  GetPlayerAuraBySpellID: คืน nil (ไม่มีออร่านี้บนตัวเรา)"
        else
            out[#out + 1] = "  |cff44ff44GetPlayerAuraBySpellID: ได้ table|r"
            DumpAuraData(a, out, "      ")
        end
    end

    for _, u in ipairs(BY_ID_UNITS) do
        local okE, exists = pcall(UnitExists, u)
        if okE and exists then
            -- GetUnitAuraBySpellID
            if C_UnitAuras and C_UnitAuras.GetUnitAuraBySpellID then
                local ok, a = pcall(C_UnitAuras.GetUnitAuraBySpellID, u, spellID)
                if not ok then
                    out[#out + 1] = "  [" .. u .. "] GetUnitAuraBySpellID: |cffff9a9aTHROW|r " .. tostring(a)
                elseif a == nil then
                    out[#out + 1] = "  [" .. u .. "] GetUnitAuraBySpellID: คืน nil"
                else
                    out[#out + 1] = "  [" .. u .. "] |cff44ff44GetUnitAuraBySpellID: ได้ table|r"
                    DumpAuraData(a, out, "      ")
                    local aid = a.auraInstanceID
                    if aid ~= nil then ProbeDispelViaCurveID(u, aid, out, "      ") end
                end
            end
            -- GetAuraDataBySpellName (ต้องรู้ชื่อ — ดึงจาก C_Spell)
            if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName and C_Spell and C_Spell.GetSpellName then
                local okN, nm = pcall(C_Spell.GetSpellName, spellID)
                if okN and nm ~= nil and not IsSecret(nm) then
                    for _, flt in ipairs({ "HELPFUL", "HARMFUL" }) do
                        local ok2, a2 = pcall(C_UnitAuras.GetAuraDataBySpellName, u, nm, flt)
                        if not ok2 then
                            out[#out + 1] = ("  [%s] GetAuraDataBySpellName(%s,%s): |cffff9a9aTHROW|r %s")
                                :format(u, nm, flt, tostring(a2))
                        elseif a2 ~= nil then
                            out[#out + 1] = ("  [%s] |cff44ff44GetAuraDataBySpellName(%s,%s): ได้ table|r")
                                :format(u, nm, flt)
                            DumpAuraData(a2, out, "      ")
                        end
                    end
                end
            end
        end
    end
end


-- ============================================================
-- ส่วน F: dump เฟรมออร่าของ Plater
-- ============================================================
-- Frame Stack ของ user ชี้ว่าไอคอน Enrage ที่เห็นคือ
--     NamePlate3PlaterUnitFrameBuffFrame1  (SOURCE: Plater/Plater_Auras.lua)
-- = **ของ Plater ไม่ใช่ของ Blizzard** — อธิบายว่าทำไม BuffListFrame
-- ของ Blizzard ได้ children=0 ตลอด (Blizzard ไม่วาด buff ของ mob)
--
-- อ่านเฟรมของ addon อื่น = Route B เหมือนกัน ทำได้
-- ⚠ แต่มีเงื่อนไขใหญ่: Plater ก็เป็น addon (tainted) เหมือนกัน
--   ถ้ามันดึงข้อมูลจาก C_UnitAuras เหมือนเรา ในดันมันก็จะว่างเหมือนกัน
--   ⇒ dump นี้ต้องยิง **ทั้งนอกดันและในดัน** แล้วเทียบ
--   ถ้าในดันก็ว่าง = ทางนี้ตาย ถ้ายังมี = Plater มีแหล่งข้อมูลอื่น (เช่น combat log)

local function DumpScalarFields(obj, out, pad, maxN)
    local keys = {}
    pcall(function()
        for k, v in pairs(obj) do
            local tv = type(v)
            if tv ~= "function" and tv ~= "table" and tv ~= "userdata" then
                keys[#keys + 1] = tostring(k) .. "=" .. SafeStr(v)
            end
        end
    end)
    table.sort(keys)
    local line, n = pad, 0
    for _, k in ipairs(keys) do
        n = n + 1
        if maxN and n > maxN then break end
        if #line > 110 then out[#out + 1] = line; line = pad end
        line = line .. k .. "  "
    end
    if line ~= pad then out[#out + 1] = line end
end

local function ProbePlaterFrames(out)
    out[#out + 1] = "== ส่วน F: เฟรมออร่าของ Plater =="
    if _G.Plater == nil then
        out[#out + 1] = "  (ไม่ได้ติดตั้ง Plater — ส่วนนี้ข้าม)"
        return
    end
    local found = 0
    for n = 1, 12 do
        local base = "NamePlate" .. n .. "PlaterUnitFrame"
        local uf = _G[base]
        if uf ~= nil then
            for _, cname in ipairs({ "BuffFrame1", "BuffFrame2", "BuffFrame3" }) do
                local cf = _G[base .. cname] or uf[cname]
                if cf ~= nil then
                    local okS, shown = Get(cf, "IsShown")
                    local kids = {}
                    pcall(function() kids = { cf:GetChildren() } end)
                    out[#out + 1] = ("  [%s%s] shown=%s children=%d")
                        :format(base, cname, okS and SafeStr(shown) or "ERR", #kids)
                    DumpScalarFields(cf, out, "      ", 14)
                    -- นับเฉพาะไอคอนที่ **โชว์จริง** — children คือ pool ที่ Plater
                    -- สร้างรอไว้ (30/10 ตัว) ไม่ใช่จำนวนออร่าจริง
                    local nShown = 0
                    for ci, kid in ipairs(kids) do
                        local vis = false
                        pcall(function() vis = kid:IsVisible() == true end)
                        if vis then
                            nShown = nShown + 1
                            if nShown <= 4 then
                                local ot = "?"
                                pcall(function() ot = kid:GetObjectType() end)
                                out[#out + 1] = ("      icon#%d (%s) |cff44ff44โชว์อยู่|r"):format(ci, tostring(ot))
                                DumpScalarFields(kid, out, "        ", 24)
                            end
                        end
                    end
                    out[#out + 1] = ("      -> ไอคอนที่โชว์จริง %d / %d"):format(nShown, #kids)
                    found = found + 1
                end
            end
        end
    end
    if found == 0 then
        out[#out + 1] = "  (มี Plater แต่หาเฟรม NamePlateNPlaterUnitFrameBuffFrameN ไม่เจอ)"
    end
end

-- ============================================================
-- probe หลัก
-- ============================================================

--- showAll = true → พิมพ์ nameplate ที่ไม่มีออร่าด้วย
function TOOL.RunNameplateAuraProbe(showAll)
    local out = {}
    out[#out + 1] = "== Nameplate Aura Probe ==" .. (showAll and "  [showAll]" or "")
    for _, l in ipairs(EnvLines()) do out[#out + 1] = l end
    for _, l in ipairs(CVarLines()) do out[#out + 1] = l end
    out[#out + 1] = ""

    local units, anyAura, plateCount = {}, false, 0
    -- บล็อกราย nameplate (หน้าละ 2 ตัว ตัวละคอลัมน์) — ส่วนที่เหลือไป out = ส่วนรวม
    local plateBlocks = {}

    out[#out + 1] = "-- ส่วน D: enumerate ด้วย API ตรง (ทางที่ ThreatPlates ใช้) -----"
    out[#out + 1] = "   ถ้าคืน table ได้ = ทางนี้รอด · aura.dispelName คือคำตอบของเรื่อง dispel"
    do
        local nD = 0
        for i = 1, MAX_PLATES do
            local u = "nameplate" .. i
            if UnitExists(u) and nD < 3 then
                nD = nD + 1
                ProbeAuraAPI(u, out)
            end
        end
        if UnitExists("target") then ProbeAuraAPI("target", out) end
        if nD == 0 then out[#out + 1] = "   (ไม่มี nameplate ให้ทดสอบ)" end
    end
    out[#out + 1] = ""

    ProbePlaterFrames(out)
    out[#out + 1] = ""

    out[#out + 1] = "-- ส่วน A: field ดิบบนปุ่มออร่า --------------------------------"
    for i = 1, MAX_PLATES do
        local unit = "nameplate" .. i
        if UnitExists(unit) then
            plateCount = plateCount + 1
            local af, how = AurasFrameOf(unit)
            local name = UnitName(unit)
            local canAttack = UnitCanAttack("player", unit)

            local lines, auraN = {}, 0
            if af then
                for _, L in ipairs(LISTS) do
                    local listFrame = af[L.field]
                    local children, err = LayoutChildren(listFrame)
                    if children then
                        for idx, btn in ipairs(children) do
                            if btn and btn.spellID ~= nil then
                                auraN = auraN + 1
                                ProbeButton(btn, L.kind, idx, lines, unit)
                            end
                        end
                    elseif err and err ~= "ไม่มี list frame" and showAll then
                        lines[#lines + 1] = ("    [%s] %s"):format(L.kind, err)
                    end
                end
            end

            if auraN > 0 then anyAura = true end
            -- ⚠ เก็บบล็อกนี้เสมอแม้ 0 ปุ่ม — กรณี "0 ปุ่ม" คือกรณีที่ต้องการข้อมูลมากสุด
            -- บล็อกของแต่ละ nameplate เก็บแยกกัน — UI เอาไปวางคนละคอลัมน์ (หน้าละ 2 ตัว)
            do
                units[#units + 1] = unit
                local blk = {}
                blk[#blk + 1] = ("[%s] %s  enemy=%s  auras=%d  via %s")
                    :format(unit, SafeStr(name), SafeStr(canAttack), auraN, af and how or ("-- " .. tostring(how)))
                -- แยกรายลิสต์เสมอ แม้ 0 ปุ่ม — ตัวชี้ว่า "buff ไม่โผล่" เกิดที่ลิสต์ไหน
                if af then
                    for _, L in ipairs(LISTS) do
                        DumpListConfig(af[L.field], L.kind, blk)
                    end
                end
                for _, l in ipairs(lines) do blk[#blk + 1] = l end
                DumpPlaterForUnit(unit, blk)
                plateBlocks[#plateBlocks + 1] = { unit = unit, lines = blk }
            end
        end
    end

    if plateCount == 0 then
        out[#out + 1] = "|cffff5555!! ไม่มี nameplate เลย -> เปิด nameplate ศัตรู (ปุ่ม V) ก่อน|r"
    elseif not anyAura then
        out[#out + 1] = "|cffff5555!! มี nameplate แต่ไม่มีปุ่มออร่าเลย"
        out[#out + 1] = "   วัด Debuff -> ต้องมี DoT ของเราติด mob"
        out[#out + 1] = "   วัด Dispel -> ต้องเล็ง mob ที่ **มี buff ที่คลาสเราปลดได้** ตอนนั้นจริง ๆ"
        out[#out + 1] = "   (Hunter = Enrage/Magic · สัตว์ที่ enrage ตอนเลือดต่ำ / mob ที่ buff ตัวเอง)"
        out[#out + 1] = "   (Blizzard โชว์เฉพาะดีบัฟที่ source = ตัวเราเอง) หรือ CVar aura บน nameplate ปิดอยู่|r"
    end

    -- ── ส่วน B: API จริงของ addon ─────────────────────────────
    out[#out + 1] = ""
    for _, l in ipairs(DispelInfoLines()) do out[#out + 1] = l end
    out[#out + 1] = ""

    out[#out + 1] = "-- ส่วน B: GeRODPS.GetAllAuraFromSetOfNamePlate ----------------"
    if GeRODPS == nil or GeRODPS.GetAllAuraFromSetOfNamePlate == nil then
        out[#out + 1] = "|cffff5555ไม่มี API (addon GeRODPS ไม่ได้โหลด หรือยังไม่ได้ /reload)|r"
    else
        local ok, recs = pcall(GeRODPS.GetAllAuraFromSetOfNamePlate, units)
        if not ok then
            out[#out + 1] = "|cffff5555API throw: " .. tostring(recs) .. "|r"
        elseif type(recs) ~= "table" then
            out[#out + 1] = "API คืนค่าไม่ใช่ table: " .. SafeStr(recs)
        else
            out[#out + 1] = ("units=%d  records=%d"):format(#units, #recs)
            -- record เป็นของราย unit ⇒ ย้ายไปอยู่กับบล็อกของ nameplate นั้น (อ่านเทียบกับส่วน A ได้เลย)
            local byUnit = {}
            for _, b in ipairs(plateBlocks) do byUnit[b.unit] = b end
            for i, r in ipairs(recs) do
                local ln = ("  #%d unit=%s kind=%s spellID=%s stack=%s startMs=%s durationMs=%s nowMs=%s")
                    :format(i, tostring(r.unit), tostring(r.kind), SafeStr(r.spellID),
                            SafeStr(r.stack), SafeStr(r.startMs), SafeStr(r.durationMs),
                            SafeStr(r.nowMs))
                local b = byUnit[tostring(r.unit)]
                if b then
                    if not b._apiHdr then
                        b._apiHdr = true
                        b.lines[#b.lines + 1] = ""
                        b.lines[#b.lines + 1] = "-- ส่วน B: record จาก GetAllAuraFromSetOfNamePlate --"
                    end
                    b.lines[#b.lines + 1] = ln
                else
                    out[#out + 1] = ln
                end
            end
            if #recs == 0 then
                out[#out + 1] = "  (ว่าง — ตรงกับส่วน A ที่ไม่มีปุ่มออร่า)"
            end
        end
        -- เทียบกับ API เดิม (ต้องได้จำนวนเท่ากันเสมอ)
        if GeRODPS.GetAllSpellIDFromSetOfNamePlate then
            local ok2, ids = pcall(GeRODPS.GetAllSpellIDFromSetOfNamePlate, units)
            out[#out + 1] = ok2 and type(ids) == "table"
                and ("API เดิม (spellID-only) คืน %d ตัว — ต้องเท่ากับ records ข้างบน"):format(#ids)
                or  ("API เดิม throw: " .. tostring(ids))
        end
    end

    out[#out + 1] = ""
    out[#out + 1] = "-- อ่านผล: [s] = ค่า secret (อ่านได้ ส่ง STS ให้ AHK ได้ แต่คำนวณ/เทียบฝั่ง Lua ไม่ได้)"
    out[#out + 1] = "--         ERR = ใช้ไม่ได้ / nil = ไม่มีค่า"

    local plates = {}
    for _, b in ipairs(plateBlocks) do
        plates[#plates + 1] = { unit = b.unit, text = table.concat(b.lines, "\n") }
    end
    return { shared = table.concat(out, "\n"), plates = plates }
end

-- ============================================================
-- Secret Peek — เรนเดอร์ "ค่าจริง" ของ field ที่เป็น secret ออกจอ
-- ============================================================
-- idiom จาก WatchVar.lua: `"" .. tostring(v)` ได้ string ที่ FontString
-- **เรนเดอร์ได้** (ผลยังเป็น secret แต่ Blizzard ยอมให้วาด) ⇒ user อ่านด้วยตา
-- แล้วบอกกลับมาว่า format หน้าตาเป็นยังไง — ทางเดียวที่จะรู้ format ของ
-- secret string เพราะ Lua เทียบ/วัด/แปลงมันไม่ได้เลย
--
-- ⚠ กฎเหล็กของแผงนี้ (ผิดข้อใดข้อหนึ่ง = Lua error กลาง combat):
--   1. ปลายทางต้องเป็น **FontString** เท่านั้น — ห้าม EditBox
--      (EditBox ของรายงานหลักต้อง copy ได้ = ต้องเรียก GetText ซึ่งบน
--       secret string เป็นการ unmask)
--   2. ห้ามเรียก GetText / GetStringWidth / GetStringHeight บน FontString นี้
--   3. ห้ามวัดความสูงเพื่อ resize — ขนาดคงที่ตามกรอบ ให้ user กด Full Screen เอา
--   4. ประกอบด้วย `..` / tostring เท่านั้น (Rule 1.5) ห้าม compare/arith
local function PeekVal(v)
    if v == nil then return "nil" end
    local ok, res = pcall(function() return "" .. tostring(v) end)
    if ok then return res end
    return "<เรนเดอร์ไม่ได้>"
end

--- อ่านค่าจริงของทุกปุ่มออร่าบน nameplate → string เดียว (secret) สำหรับ FontString
--- เน้น cdText เป็นหลัก (คำถามที่ต้องตอบ: countdown text เป็น format ไหน)
local function BuildPeekText()
    local lines = "|cffffd200== ค่าจริง (อ่านด้วยตา - copy ไม่ได้) ==|r" .. "\n"
    lines = lines .. "|cffaaaaaaถ้า cdText ว่างเปล่า = Blizzard ไม่ได้วาดเลข (hideNumbers)|r" .. "\n\n"
    local found = 0
    for i = 1, MAX_PLATES do
        local unit = "nameplate" .. i
        local af = AurasFrameOf(unit)
        if af then
            for _, L in ipairs(LISTS) do
                local children = LayoutChildren(af[L.field])
                if children then
                    for idx, btn in ipairs(children) do
                        if btn and btn.spellID ~= nil then
                            found = found + 1
                            local cdTxt, cdShown = nil, nil
                            local cd = btn.Cooldown
                            if cd ~= nil and cd.GetCountdownFontString ~= nil then
                                local okF, fs = pcall(cd.GetCountdownFontString, cd)
                                if okF and fs ~= nil then
                                    local okT; okT, cdTxt = Get(fs, "GetText")
                                    if not okT then cdTxt = nil end
                                    local okS; okS, cdShown = Get(fs, "IsShown")
                                    if not okS then cdShown = nil end
                                end
                            end
                            local stkTxt = nil
                            local cf = btn.CountFrame
                            if cf ~= nil and cf.Count ~= nil then
                                local okC; okC, stkTxt = Get(cf.Count, "GetText")
                                if not okC then stkTxt = nil end
                            end
                            local sMs, dMs = nil, nil
                            if cd ~= nil and cd.GetCooldownTimes ~= nil then
                                local okCd, a, b = pcall(cd.GetCooldownTimes, cd)
                                if okCd then sMs, dMs = a, b end
                            end
                            local dispD = nil
                            if cd ~= nil then
                                local okD; okD, dispD = Get(cd, "GetCooldownDisplayDuration")
                                if not okD then dispD = nil end
                            end

                            lines = lines .. "|cff88ccff[" .. unit .. " " .. L.kind
                                .. " #" .. idx .. "]|r" .. "\n"
                            lines = lines .. "   cdText = [" .. PeekVal(cdTxt) .. "]"
                                .. "   shown=" .. PeekVal(cdShown) .. "\n"
                            lines = lines .. "   stack  = [" .. PeekVal(stkTxt) .. "]"
                                .. "   spellID=" .. PeekVal(btn.spellID) .. "\n"
                            lines = lines .. "   start  = " .. PeekVal(sMs)
                                .. "   dur = " .. PeekVal(dMs)
                                .. "   displayDuration = " .. PeekVal(dispD) .. "\n"
                            lines = lines .. "   now    = " .. string.format("%.0f", GetTime() * 1000)
                                .. "\n\n"
                        end
                    end
                end
            end
        end
    end
    if found == 0 then
        lines = lines .. "|cffff9a9aไม่เจอปุ่มออร่าบน nameplate เลย"
            .. " - วัด Debuff ต้องมี DoT ของเรา · วัด Dispel ต้องมี buff ที่ปลดได้บน mob|r"
    end
    return lines
end

-- ============================================================
-- UI
-- ============================================================

local frame, editBox, scrollFrame          -- editBox/scrollFrame = คอลัมน์ซ้าย (index 1)
local colBox, colScroll, colTitle = {}, {}, {}   -- 2 คอลัมน์ = 2 nameplate ต่อหน้า
local pageLabel, btnPrev, btnNext
local _report = nil                        -- { shared = "...", plates = { {unit,text}, ... } }
local _page   = 1
-- user เคาะ 2026-08-18: เหลือหน้าละ 1 nameplate — ดูแค่ NP1 อยู่แล้ว
-- และต้องการที่ว่างสำหรับรายละเอียดที่จะเพิ่มทีหลัง (เปลี่ยนค่านี้ค่าเดียว layout ตามเอง)
local PER_PAGE = 1
local peekBox, peekFS

local function RefreshPeek()
    if not peekFS then return end
    -- SetText ล้วน — ไม่วัดผลลัพธ์ (ผลเป็น secret string)
    local ok, text = pcall(BuildPeekText)
    if ok then
        peekFS:SetText(text)
    else
        peekFS:SetText("|cffff9a9aPeek พัง:|r " .. tostring(text))
    end
end

--- จำนวนหน้า (อย่างน้อย 1 เสมอ เพื่อให้ป้ายไม่โชว์ 0/0)
local function TotalPages()
    local n = (_report and #_report.plates) or 0
    local t = math.ceil(n / PER_PAGE)
    if t < 1 then t = 1 end
    return t
end

--- วาดหน้าปัจจุบันลง 2 คอลัมน์ (คอลัมน์ที่ไม่มี nameplate = ว่าง)
local function RenderPage()
    if not colBox[1] then return end
    local total = TotalPages()
    if _page > total then _page = total end
    if _page < 1 then _page = 1 end

    local names = {}
    for c = 1, PER_PAGE do
        local idx = (_page - 1) * PER_PAGE + c
        local pl  = _report and _report.plates[idx]
        local body, head
        if pl then
            head = ("|cffffd200%s|r  (ตัวที่ %d/%d)"):format(pl.unit, idx, #_report.plates)
            body = pl.text
            names[#names + 1] = pl.unit
        else
            head = "|cff888888(ไม่มี nameplate ช่องนี้)|r"
            body = ""
        end
        colTitle[c]:SetText(head)
        colBox[c]:SetText(body)
        colBox[c]:SetCursorPosition(0)
    end

    if pageLabel then
        local n = (_report and #_report.plates) or 0
        local who = (#names > 0) and table.concat(names, ", ") or "-"
        pageLabel:SetText(("หน้า %d/%d  ·  nameplate ทั้งหมด %d  ·  หน้านี้: %s")
            :format(_page, total, n, who))
    end
    if btnPrev then btnPrev:SetEnabled(_page > 1) end
    if btnNext then btnNext:SetEnabled(_page < total) end
end

local function PageStep(d)
    _page = _page + d
    RenderPage()
end

local function Refresh(showAll)
    if not editBox then return end
    local ok, res = pcall(TOOL.RunNameplateAuraProbe, showAll)
    if not ok or type(res) ~= "table" then
        _report = nil
        editBox:SetText("Probe พัง: " .. tostring(res))
        editBox:SetCursorPosition(0)
        RenderPage()
        return
    end
    _report = res
    _page = 1
    editBox:SetText(res.shared)              -- กล่องล่าง = ส่วนรวม (ไม่ขึ้นกับหน้า)
    editBox:SetCursorPosition(0)
    RenderPage()
    if peekBox and peekBox:IsShown() then RefreshPeek() end
end

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "GeRODPSToolsNameplateAuraProbe", UIParent, "BasicFrameTemplateWithInset")
    local uiW, uiH = UIParent:GetWidth(), UIParent:GetHeight()
    local defW = math.min(MAX_W, math.max(MIN_W, math.floor(uiW * 0.88)))
    local defH = math.min(MAX_H, math.max(MIN_H, math.floor(uiH * 0.82)))
    frame:SetSize(defW, defH)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    end
    frame:SetClampedToScreen(true)
    frame:Hide()
    if frame.TitleText then frame.TitleText:SetText("Nameplate Aura Probe") end
    table.insert(UISpecialFrames, "GeRODPSToolsNameplateAuraProbe")

    -- Rule 10: แถวแรก anchor ที่ frame + เผื่อ TITLE_H
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 8))
    hint:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + 8))
    hint:SetJustifyH("LEFT")
    hint:SetSpacing(3)
    hint:SetText(
        "|cffffd200วัด Debuff (spellID/stack/remain):|r อยู่ในดัน + combat + "
        .. "|cffffcc55มี DoT ของเราติด mob|r + เปิด nameplate ศัตรู"
        .. "|n|cffffd200วัด Dispel:|r เล็ง mob ที่ |cffffcc55มี buff ที่คลาสเราปลดได้|r "
        .. "(Hunter = Enrage/Magic) — คนละเงื่อนไขกับข้างบน ไม่ต้องมี DoT"
        .. "  |cffaaaaaa(นอก combat ออร่าไม่ secret -> ผลหลอก)|r")

    local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btn:SetSize(120, 24)
    btn:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
    btn:SetText("Probe")
    btn:SetScript("OnClick", function() Refresh(false) end)

    local btnAll = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnAll:SetSize(170, 24)
    btnAll:SetPoint("LEFT", btn, "RIGHT", 8, 0)
    btnAll:SetText("Probe (ทุก nameplate)")
    btnAll:SetScript("OnClick", function() Refresh(true) end)

    local btnCopy = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnCopy:SetSize(120, 24)
    btnCopy:SetPoint("LEFT", btnAll, "RIGHT", 8, 0)
    btnCopy:SetText("Select All")
    btnCopy:SetScript("OnClick", function()
        if editBox then editBox:SetFocus(); editBox:HighlightText() end
    end)

    local btnMax = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnMax:SetSize(120, 24)
    btnMax:SetPoint("LEFT", btnCopy, "RIGHT", 8, 0)
    btnMax:SetText("Full Screen")
    btnMax:SetScript("OnClick", function()
        if frame._maximized then
            frame:ClearAllPoints()
            frame:SetPoint("CENTER")
            frame:SetSize(defW, defH)
            frame._maximized = nil
            btnMax:SetText("Full Screen")
        else
            frame:ClearAllPoints()
            frame:SetPoint("CENTER")
            frame:SetSize(math.min(MAX_W, UIParent:GetWidth() - 20),
                          math.min(MAX_H, UIParent:GetHeight() - 20))
            frame._maximized = true
            btnMax:SetText("Restore")
        end
    end)

    local btnPeek = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnPeek:SetSize(190, 24)
    btnPeek:SetPoint("LEFT", btnMax, "RIGHT", 8, 0)
    btnPeek:SetText("Peek ค่าจริง (อ่านด้วยตา)")
    btnPeek:SetScript("OnClick", function()
        if not peekBox then return end
        if peekBox:IsShown() then
            peekBox:Hide()
            btnPeek:SetText("Peek ค่าจริง (อ่านด้วยตา)")
        else
            RefreshPeek()
            peekBox:Show()
            btnPeek:SetText("กลับไปดูรายงาน (copy ได้)")
        end
    end)

    local idBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    idBox:SetSize(90, 22)
    idBox:SetPoint("LEFT", btnPeek, "RIGHT", 14, 0)
    idBox:SetAutoFocus(false)
    idBox:SetNumeric(true)
    idBox:SetText("980")
    idBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local btnById = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnById:SetSize(150, 24)
    btnById:SetPoint("LEFT", idBox, "RIGHT", 6, 0)
    btnById:SetText("ทดสอบ BySpellID")
    btnById:SetScript("OnClick", function()
        if not editBox then return end
        if peekBox and peekBox:IsShown() then peekBox:Hide() end
        local ok, text = pcall(TOOL.RunBySpellIDProbe, idBox:GetText())
        editBox:SetText(ok and text or ("พัง: " .. tostring(text)))
        editBox:SetCursorPosition(0)
    end)

    -- ── แถวเปลี่ยนหน้า (1 หน้า = 2 nameplate เรียงข้างกัน) ──────────────
    btnPrev = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnPrev:SetSize(40, 24)
    btnPrev:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -6)
    btnPrev:SetText("<")
    btnPrev:SetScript("OnClick", function() PageStep(-1) end)

    btnNext = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnNext:SetSize(40, 24)
    btnNext:SetPoint("LEFT", btnPrev, "RIGHT", 6, 0)
    btnNext:SetText(">")
    btnNext:SetScript("OnClick", function() PageStep(1) end)

    pageLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageLabel:SetPoint("LEFT", btnNext, "RIGHT", 12, 0)
    pageLabel:SetJustifyH("LEFT")
    pageLabel:SetText("หน้า 1/1")

    -- ── 2 คอลัมน์: คอลัมน์ละ 1 nameplate (กล่องเลื่อนแยกกัน copy ได้ทั้งคู่) ──
    -- ครองพื้นที่ส่วนบน · ส่วนรวมอยู่กล่องล่าง (scrollFrame เดิม)
    local COL_GAP  = 10
    local SHARED_H = 150                    -- ความสูงของกล่อง "ส่วนรวม" ด้านล่าง
    for c = 1, PER_PAGE do
        colTitle[c] = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        colTitle[c]:SetJustifyH("LEFT")
        colTitle[c]:SetText("")

        colScroll[c] = CreateFrame("ScrollFrame", "$parentCol" .. c, frame,
                                   "UIPanelScrollFrameTemplate")
        colBox[c] = CreateFrame("EditBox", nil, colScroll[c])
        colBox[c]:SetMultiLine(true)
        colBox[c]:SetAutoFocus(false)
        colBox[c]:SetFontObject(ChatFontNormal)
        colBox[c]:SetMaxLetters(0)
        colBox[c]:SetCountInvisibleLetters(false)
        colBox[c]:EnableMouse(true)
        colBox[c]:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        colBox[c]:SetScript("OnCursorChanged", function(self, _, y, _, ch)
            ScrollingEdit_OnCursorChanged(self, 0, y, 0, ch)
        end)
        colScroll[c]:SetScript("OnSizeChanged", function(_, w)
            if colBox[c] then colBox[c]:SetWidth(w) end
        end)
        colScroll[c]:SetScrollChild(colBox[c])
    end

    -- วาง/ปรับขนาดคอลัมน์ตามความกว้างกรอบ (เรียกซ้ำได้ตอน resize)
    local function LayoutColumns()
        local w = frame:GetWidth() - SIDE_PAD * 2 - 30
        if w < 200 then w = 200 end
        local colW = (w - COL_GAP) / PER_PAGE
        for c = 1, PER_PAGE do
            local dx = (c - 1) * (colW + COL_GAP)
            -- ยึดกับปุ่มเปลี่ยนหน้าจริง — อย่าเดา offset จากขอบบน (hint สูงไม่คงที่
            -- ตามความกว้างกรอบ ⇒ ตัวเลขตายตัวจะทับแถวปุ่มเวลาย่อกรอบ)
            colTitle[c]:ClearAllPoints()
            colTitle[c]:SetPoint("TOPLEFT", btnPrev, "BOTTOMLEFT", dx, -8)
            colTitle[c]:SetWidth(colW)

            -- สูงมาจาก anchor บน+ล่าง (ไม่คำนวณเอง) → resize กรอบแล้วตามเอง
            colScroll[c]:ClearAllPoints()
            colScroll[c]:SetPoint("TOPLEFT", colTitle[c], "BOTTOMLEFT", 0, -4)
            colScroll[c]:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT",
                                  SIDE_PAD + dx, SHARED_H + 46)
            colScroll[c]:SetWidth(colW)
            colBox[c]:SetWidth(colW)
        end
    end
    frame._LayoutColumns = LayoutColumns
    LayoutColumns()

    -- กล่อง "ส่วนรวม" (env / CVar / ส่วน D / สรุป) — ไม่ขึ้นกับหน้า
    local sharedTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sharedTitle:SetPoint("TOPLEFT", colScroll[1], "BOTTOMLEFT", 0, -6)
    sharedTitle:SetText("|cffaaffaaส่วนรวม (ไม่ขึ้นกับหน้า)|r")

    scrollFrame = CreateFrame("ScrollFrame", "$parentScroll", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", sharedTitle, "BOTTOMLEFT", 0, -4)
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

    -- แผง Peek — ทับพื้นที่เดียวกับรายงาน (สลับกันโชว์)
    -- ขนาดคงที่ตามกรอบ ไม่วัดข้อความ (กฎข้อ 3) — ยาวเกินก็โดนตัดล่าง
    -- ให้ user กด Full Screen หรือลากขยายกรอบเอา
    peekBox = CreateFrame("Frame", nil, frame)
    peekBox:SetPoint("TOPLEFT", colScroll[1], "TOPLEFT", 0, 0)
    peekBox:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 22)
    peekBox:Hide()
    local peekBg = peekBox:CreateTexture(nil, "BACKGROUND")
    peekBg:SetAllPoints(peekBox)
    peekBg:SetColorTexture(0, 0, 0, 0.55)
    peekFS = peekBox:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    peekFS:SetPoint("TOPLEFT", peekBox, "TOPLEFT", 6, -6)
    peekFS:SetPoint("TOPRIGHT", peekBox, "TOPRIGHT", -6, -6)
    peekFS:SetJustifyH("LEFT")
    peekFS:SetJustifyV("TOP")
    peekFS:SetWordWrap(true)
    peekFS:SetNonSpaceWrap(true)
    peekFS:SetSpacing(2)
    peekFS:SetText("")

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
        if button == "LeftButton" then
            frame:StopMovingOrSizing()
            if frame._LayoutColumns then frame._LayoutColumns() end
        end
    end)
    -- ปุ่ม Full Screen / Restore ก็เปลี่ยนขนาดกรอบ → จัดคอลัมน์ตามด้วย
    frame:SetScript("OnSizeChanged", function(self)
        if self._LayoutColumns then self._LayoutColumns() end
    end)

    return frame
end

--- รันเฉพาะส่วน E (ปุ่ม + ช่องกรอก spellID)
function TOOL.RunBySpellIDProbe(spellID)
    local out = {}
    for _, l in ipairs(EnvLines()) do out[#out + 1] = l end
    out[#out + 1] = ""
    ProbeBySpellID(tonumber(spellID) or 0, out)
    return table.concat(out, "\n")
end

function TOOL.ShowNameplateAuraProbe()
    local f = BuildFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        Refresh(false)
    end
end

TOOL.RegisterTool("Nameplate Aura Probe (spellID / Stack / Remain)", TOOL.ShowNameplateAuraProbe)
