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

local function SafeStr(v)
    if v == nil then return "nil" end
    if IsSecret(v) then
        local ok, t = pcall(type, v)
        return "SECRET " .. (ok and t or "?")
    end
    return tostring(v)
end

--- ลองบวก 0 — ตัวตัดสินว่าค่านั้นเอาไปคำนวณฝั่ง Lua ได้ไหม
--- (secret number = throw ⇒ ต้องส่งดิบให้ AHK)
local function ArithTag(v)
    if v == nil then return "" end
    local ok = pcall(function() return v + 0 end)
    if ok then return " |cff44ff44[+0 ok]|r" end
    return " |cffff9a9a[+0 ERR]|r"
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
--   → รายงานจะบอกให้เห็นเอง (SafeStr + [+0] tag) ก่อนตัดสินใจว่าจะเทียบฝั่งไหน

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

--- dump ทุก texture + field ที่อาจบอกชนิด dispel
local function ProbeDispelSignature(btn, out)
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
            out[#out + 1] = "          btn." .. k .. " = " .. SafeStr(btn[k]) .. ArithTag(btn[k])
        end
    end
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

local function ProbeButton(btn, kind, idx, out)
    local sid  = btn.spellID
    local aid  = btn.auraInstanceID
    local isB  = btn.isBuff

    out[#out + 1] = ("    [%s #%d] spellID=%s%s  auraInstanceID=%s%s  isBuff=%s")
        :format(kind, idx, SafeStr(sid), ArithTag(sid), SafeStr(aid), ArithTag(aid), SafeStr(isB))

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
            out[#out + 1] = ("        stack: Count shown=%s text=%s%s   %s")
                :format(okS and SafeStr(shown) or "ERR", okT and SafeStr(txt) or "ERR",
                        okT and ArithTag(txt) or "",
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
                out[#out + 1] = ("        remain: startMs=%s%s  durationMs=%s%s  (now=%.0f)")
                    :format(SafeStr(sMs), ArithTag(sMs), SafeStr(dMs), ArithTag(dMs),
                            GetTime() * 1000)
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
        out[#out + 1] = ("        cdText: hideNumbers=%s  minDuration=%s  displayDuration=%s%s")
            :format(okH and SafeStr(hidden) or "ERR", okM and SafeStr(minMs) or "ERR",
                    okD and SafeStr(dispD) or "ERR", okD and ArithTag(dispD) or "")

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
                out[#out + 1] = ("        cdText: shown=%s visible=%s  text=%s%s")
                    :format(okS and SafeStr(shown) or "ERR", okV and SafeStr(vis) or "ERR",
                            okT and SafeStr(txt) or "ERR", okT and ArithTag(txt) or "")
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

    ProbeDispelSignature(btn, out)
end

-- ============================================================
-- probe หลัก
-- ============================================================

--- showAll = true → พิมพ์ nameplate ที่ไม่มีออร่าด้วย
function TOOL.RunNameplateAuraProbe(showAll)
    local out = {}
    out[#out + 1] = "== Nameplate Aura Probe ==" .. (showAll and "  [showAll]" or "")
    for _, l in ipairs(EnvLines()) do out[#out + 1] = l end
    out[#out + 1] = ""

    local units, anyAura, plateCount = {}, false, 0

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
                                ProbeButton(btn, L.kind, idx, lines)
                            end
                        end
                    elseif err and err ~= "ไม่มี list frame" and showAll then
                        lines[#lines + 1] = ("    [%s] %s"):format(L.kind, err)
                    end
                end
            end

            if auraN > 0 then anyAura = true end
            if auraN > 0 or showAll then
                units[#units + 1] = unit
                out[#out + 1] = ("[%s] %s  enemy=%s  auras=%d  via %s")
                    :format(unit, SafeStr(name), SafeStr(canAttack), auraN, af and how or ("-- " .. tostring(how)))
                for _, l in ipairs(lines) do out[#out + 1] = l end
            elseif auraN == 0 then
                units[#units + 1] = unit   -- ยังส่งเข้า API เพื่อทดสอบ path ว่าง
            end
        end
    end

    if plateCount == 0 then
        out[#out + 1] = "|cffff5555!! ไม่มี nameplate เลย -> เปิด nameplate ศัตรู (ปุ่ม V) ก่อน|r"
    elseif not anyAura then
        out[#out + 1] = "|cffff5555!! มี nameplate แต่ไม่มีปุ่มออร่าเลย -> ต้องมี DoT ของเราติด mob"
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
            for i, r in ipairs(recs) do
                out[#out + 1] = ("  #%d unit=%s kind=%s spellID=%s stack=%s startMs=%s durationMs=%s nowMs=%s")
                    :format(i, tostring(r.unit), tostring(r.kind), SafeStr(r.spellID),
                            SafeStr(r.stack), SafeStr(r.startMs), SafeStr(r.durationMs),
                            SafeStr(r.nowMs))
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
    out[#out + 1] = "-- อ่านผล: SECRET xxx = ผ่าน (ส่ง STS ให้ AHK ได้) / ERR = ใช้ไม่ได้ / nil = ไม่มีค่า"
    out[#out + 1] = "--         [+0 ok] = คำนวณฝั่ง Lua ได้ · [+0 ERR] = ต้องส่งดิบให้ AHK คิด"
    return table.concat(out, "\n")
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
            .. " - ต้องมี DoT ของเราติด mob ที่มี nameplate โชว์อยู่|r"
    end
    return lines
end

-- ============================================================
-- UI
-- ============================================================

local frame, editBox, scrollFrame
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

local function Refresh(showAll)
    if not editBox then return end
    local ok, text = pcall(TOOL.RunNameplateAuraProbe, showAll)
    editBox:SetText(ok and text or ("Probe พัง: " .. tostring(text)))
    editBox:SetCursorPosition(0)
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
    hint:SetText("ต้องกดตอน: อยู่ในดัน + combat + มี DoT ของเราติด mob + เปิด nameplate ศัตรู"
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

    scrollFrame = CreateFrame("ScrollFrame", "$parentScroll", frame, "UIPanelScrollFrameTemplate")
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

    -- แผง Peek — ทับพื้นที่เดียวกับรายงาน (สลับกันโชว์)
    -- ขนาดคงที่ตามกรอบ ไม่วัดข้อความ (กฎข้อ 3) — ยาวเกินก็โดนตัดล่าง
    -- ให้ user กด Full Screen หรือลากขยายกรอบเอา
    peekBox = CreateFrame("Frame", nil, frame)
    peekBox:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, 0)
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
        if button == "LeftButton" then frame:StopMovingOrSizing() end
    end)

    return frame
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
