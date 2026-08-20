--[[
    GeRODPS_Tools / SecretAPIProbes.lua

    ตารางข้อมูลของเครื่องมือ "Secret API Check" — รายชื่อ WoW API ที่
    GeRODPS เรียกใช้ "แล้วต้องเอาค่าที่ได้ไปเปรียบเทียบ / คำนวณต่อ"
    (compare / arithmetic / boolean test) ซึ่งเป็น op ที่ throw ทันที
    ถ้าค่าที่ได้เป็น secret

    ไฟล์นี้ = ข้อมูลล้วน (ไม่มี UI). UI อยู่ที่ SecretAPICheck.lua

    ── สิ่งที่ 12.1 เปลี่ยน (Patch 12.1.0/API changes) ──────────────
    1) Aura API ที่หาด้วย **index / slot / auraInstanceID**
       (GetAuraDataByIndex · GetBuffDataByIndex · GetDebuffDataByIndex ·
        GetAuraDataBySlot · GetAuraSlots · GetAuraDataByAuraInstanceID ·
        GetAuraDuration) → **Lua error** เมื่อ addon เรียกตอน aura เป็น
       secret (combat / encounter / M+ / PvP) ไม่ใช่แค่คืนค่า secret:
           "Auras cannot be accessed when secret while tainted by 'X'"
       ⇒ ต้องถาม C_Secrets ก่อนเรียกเสมอ (หมวด 1) แล้วข้ามไปเลยถ้า secret
    2) Aura API ที่หาด้วย **spellID / spell name** ยังเรียกได้ตามปกติ
       (GetUnitAuraBySpellID · GetPlayerAuraBySpellID · GetAuraDataBySpellName)
       ⇒ นี่คือทางที่เหลือของ addon — ดูหมวด 6
    3) API ที่คืน secret เพิ่มเมื่อ "unit identity" เป็น secret:
       UnitClass · UnitClassBase · UnitSex · UnitRace · UnitPhaseReason ·
       UnitGroupRolesAssigned · UnitIsPVP · UnitInRaid · UnitIsGroupLeader ·
       UnitIsRaidOfficer · GetInspectSpecialization ฯลฯ

    โครงสร้าง:
        GeRODPS_Tools.SecretAPIProbes = {
            { title = "<หมวด>", items = {
                { name       = "<ข้อความคำสั่งที่แสดง>",
                  unitScoped = true|false,
                  fn         = function(unit) ... end,   -- unitScoped = true
                  fn         = function() ... end,       -- unitScoped = false
                  note       = "<คำอธิบาย / จุดที่ใช้ในโปรเจกต์>" },
            } },
        }

    กติกาการเขียน fn (สำคัญ — ห้ามพลาด):
      * fn ต้อง "คืนค่าดิบ" เท่านั้น ห้าม compare / arithmetic / boolean-test
        ค่าที่ได้จาก API ข้างใน fn เอง มิฉะนั้นเครื่องมือจะรายงาน ERR
        แทนที่จะรายงานว่าค่านั้นเป็น secret
      * ก่อน index table (`t.field`) ต้อง IsSecret(t) ก่อนเสมอ —
        indexing เข้า secret table = forbidden (wow-coding Rule 1.5)
      * ก่อนเรียก method ของ DurationObj ต้อง guard ที่ "ตัว object" (Rule 2)
        และ IsSecret(obj) ด้วย
      * nil check ใช้ `== nil` / `~= nil` เท่านั้น ห้าม `if v then`
      * API ที่ 12.1 ทำให้ throw ต้อง gate ด้วย C_Secrets แล้วคืน
        Blocked("เหตุผล") — อย่าปล่อยให้ throw เพื่อเอา ERR มาโชว์
        (ยกเว้นแถวที่จงใจตั้งชื่อว่า [ไม่ guard] ไว้เป็นหลักฐาน)

    signature ของ C_Secrets / C_UnitAuras ยืนยันจาก annotation ที่ IDE ใช้:
      ~/.vscode/extensions/ketho.wow-api-*/Annotations/Core/
        Blizzard_APIDocumentationGenerated/SecretPredicateAPIDocumentation.lua
        Blizzard_APIDocumentationGenerated/UnitAuraDocumentation.lua
    (ไฟล์นี้ generate จาก APIDocumentation ของ Blizzard — แม่นกว่าเดา
     แต่ตาม build ช้ากว่าเกม: CanCompareUnitTokens / ShouldUnitStatsBeSecret
     ยังไม่มีในไฟล์ แต่มีจริงในเกม 12.1)

    อ้างอิง: .claude/skills/wow-coding/SKILL.md Rule 1 / 1.5 / 2 / 12,
             GeRODPS/docs/SECRET_VALUES.md, GeRODPS_Tools/SECRETS.md,
             warcraft.wiki.gg/wiki/Patch_12.1.0/API_changes,
             warcraft.wiki.gg/wiki/Secret_Values
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

-- ============================================================
-- Shared input context — UI เขียน, probe อ่าน
-- ============================================================
TOOL.SecretAPICtx = TOOL.SecretAPICtx or {
    spellID   = 6603,   -- Auto Attack (ทุกคลาสมี) — เปลี่ยนได้ในหน้าจอ
    itemID    = 1180,   -- Scroll of Stamina = probe item 30 yd (harm) ของ RangeCheck.lua
    auraIndex = 1,
}
local CTX = TOOL.SecretAPICtx

-- ============================================================
-- Secret-safe primitives
-- ============================================================

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

-- "ไม่ได้เรียก เพราะรู้ล่วงหน้าว่าจะ throw" — UI แสดงเป็น BLOCKED ไม่ใช่ ERR
local function Blocked(reason)
    return { __blockedReason = reason }
end

-- อ่าน field เดียวจาก table ที่ API คืนมา
-- guard IsSecret ที่ "ตัว table" ก่อน — index เข้า secret table = forbidden
local function Field(t, key)
    if t == nil then return nil end
    if IsSecret(t) then return t end
    return t[key]
end

-- เรียก method ของ DurationObj (Rule 2: guard ที่ obj ไม่ใช่ที่ค่าที่ method คืน)
local function DurCall(obj, method)
    if obj == nil then return nil end
    if IsSecret(obj) then return obj end
    local fn = obj[method]
    if fn == nil then return nil end
    return fn(obj)
end

-- เรียก C_Secrets.<name>(...) แบบปลอดภัย — คืน nil ถ้า client ไม่มีฟังก์ชันนั้น
local function Sec(name, ...)
    if C_Secrets == nil then return nil end
    local fn = C_Secrets[name]
    if fn == nil then return nil end
    return fn(...)
end

-- true = ตอนนี้ aura เป็น secret ⇒ ห้ามเรียก API ตระกูล index/slot/instanceID
local function AurasAreSecret()
    local v = Sec("ShouldAurasBeSecret")
    if v == nil then return false end
    if IsSecret(v) then return true end
    return v == true
end

-- gate ต่อ index (ละเอียดกว่า ShouldAurasBeSecret) — fallback ไปตัวรวมถ้าไม่มี
local function AuraIndexIsSecret(unit, index, filter)
    local v = Sec("ShouldUnitAuraIndexBeSecret", unit, index, filter)
    if v == nil then return AurasAreSecret() end
    if IsSecret(v) then return true end
    return v == true
end

local AURA_BLOCK_MSG = "auras secret — 12.1 ห้าม addon อ่าน aura ทาง index/slot/instanceID"

-- ============================================================
-- Heal prediction calculator (ใช้ซ้ำตัวเดียว เหมือน PartyHealth.lua)
-- UnitGetDetailedHealPrediction(unit [, healerUnit], calculator) ไม่ได้คืนค่า
-- — ผลไปโผล่ที่ getter ของ calculator
-- ============================================================
local healCalc

local function HealCalc()
    if healCalc ~= nil then return healCalc end
    if CreateUnitHealPredictionCalculator == nil then return nil end
    local c = CreateUnitHealPredictionCalculator()
    if c == nil then return nil end
    if Enum ~= nil and Enum.UnitDamageAbsorbClampMode ~= nil
        and c.SetDamageAbsorbClampMode ~= nil then
        c:SetDamageAbsorbClampMode(
            Enum.UnitDamageAbsorbClampMode.MissingHealthWithoutIncomingHeals)
    end
    if Enum ~= nil and Enum.UnitHealAbsorbMode ~= nil
        and c.SetHealAbsorbMode ~= nil then
        c:SetHealAbsorbMode(Enum.UnitHealAbsorbMode.ReducedByIncomingHeals)
    end
    healCalc = c
    return healCalc
end

local function HealPred(unit, getter)
    local c = HealCalc()
    if c == nil then return nil end
    if UnitGetDetailedHealPrediction == nil then return nil end
    UnitGetDetailedHealPrediction(unit, unit, c)
    local fn = c[getter]
    if fn == nil then return nil end
    return fn(c)
end

-- ============================================================
-- Registry builders
-- ============================================================

local cats = {}

local function Cat(title)
    local c = { title = title, items = {} }
    cats[#cats + 1] = c
    return c
end

-- unit-scoped probe (รัน 1 ครั้งต่อ 1 unit column)
local function U(c, name, fn, note)
    c.items[#c.items + 1] = { name = name, unitScoped = true, fn = fn, note = note }
end

-- global probe (ไม่ผูกกับ unit — แสดงผลช่องเดียวยาวเต็มแถว)
local function G(c, name, fn, note)
    c.items[#c.items + 1] = { name = name, unitScoped = false, fn = fn, note = note }
end

-- ============================================================
-- 0. สถานะระบบ secret + combat
-- ============================================================
local c0 = Cat("0. Secret system / combat state")

G(c0, "C_Secrets.HasSecretRestrictions()", function()
    return Sec("HasSecretRestrictions")
end, "true = restriction กำลังบังคับใช้อยู่")
G(c0, "C_Secrets.ShouldAurasBeSecret()", function()
    return Sec("ShouldAurasBeSecret")
end, "[!!] true = ห้ามเรียก GetAuraDataByIndex/BySlot/ByInstanceID เลย (12.1 = Lua error)")
G(c0, "C_Secrets.ShouldCooldownsBeSecret()", function()
    return Sec("ShouldCooldownsBeSecret")
end)
G(c0, "issecretvalue ~= nil   (API present)", function()
    return issecretvalue ~= nil
end, "ถ้า false = client ไม่มีระบบ secret เลย ผลทุกแถวจะไม่มีความหมาย")
G(c0, "C_Secrets ~= nil   (API present)", function()
    return C_Secrets ~= nil
end)
G(c0, "C_RestrictedActions ~= nil   (API present)", function()
    return C_RestrictedActions ~= nil
end, "namespace สำหรับ query สถานะ restriction (12.x)")
G(c0, "InCombatLockdown()", function() return InCombatLockdown() end)
G(c0, "UnitAffectingCombat('player')", function() return UnitAffectingCombat("player") end)
G(c0, "GetTime()", function() return GetTime() end,
    "ไม่ใช่ secret แต่ถูกใช้คู่กับค่าที่เป็น secret บ่อย (expirationTime - GetTime())")

-- ============================================================
-- 1. C_Secrets predicates — ถามล่วงหน้าว่าค่าจะ secret ไหม
--    (นี่คือทางที่ถูกต้อง: gate ก่อนเรียก แทนการ pcall แล้วลุ้น)
-- ============================================================
local c1 = Cat("1. C_Secrets predicates — ถามล่วงหน้าก่อนเรียกจริง")

U(c1, "ShouldUnitIdentityBeSecret(u)", function(u)
    return Sec("ShouldUnitIdentityBeSecret", u)
end, "[!!] true ⇒ UnitName/UnitGUID/UnitClass/UnitRace/UnitGroupRolesAssigned จะเป็น secret")
U(c1, "ShouldUnitAuraIndexBeSecret(u, idx, 'HARMFUL')", function(u)
    return Sec("ShouldUnitAuraIndexBeSecret", u, CTX.auraIndex, "HARMFUL")
end, "[!!] gate ที่ต้องเรียกก่อน GetAuraDataByIndex ทุกครั้งใน 12.1")
U(c1, "ShouldUnitAuraIndexBeSecret(u, idx, 'HELPFUL')", function(u)
    return Sec("ShouldUnitAuraIndexBeSecret", u, CTX.auraIndex, "HELPFUL")
end)
U(c1, "ShouldUnitAuraSlotBeSecret(u, 1)", function(u)
    return Sec("ShouldUnitAuraSlotBeSecret", u, 1)
end)
U(c1, "CanCompareUnitTokens(u, 'player')", function(u)
    return Sec("CanCompareUnitTokens", u, "player")
end, "[!] false ⇒ UnitIsUnit(u,'player') จะใช้ไม่ได้ (RequiresComparableUnitTokens)")
U(c1, "ShouldUnitComparisonBeSecret(u, 'player')", function(u)
    return Sec("ShouldUnitComparisonBeSecret", u, "player")
end)
U(c1, "ShouldUnitHealthMaxBeSecret(u)", function(u)
    return Sec("ShouldUnitHealthMaxBeSecret", u)
end, "[!] true ⇒ UnitHealth/UnitHealthMax หารกันไม่ได้")
U(c1, "ShouldUnitPowerBeSecret(u)", function(u)
    return Sec("ShouldUnitPowerBeSecret", u)
end)
U(c1, "ShouldUnitPowerMaxBeSecret(u)", function(u)
    return Sec("ShouldUnitPowerMaxBeSecret", u)
end)
U(c1, "ShouldUnitStatsBeSecret(u)", function(u)
    return Sec("ShouldUnitStatsBeSecret", u)
end)
U(c1, "ShouldUnitSpellCastBeSecret(u, spellID)", function(u)
    -- signature = (unit, spellIdentifier) — arg 2 บังคับ ใช้ค่าจากช่อง Spell ID
    return Sec("ShouldUnitSpellCastBeSecret", u, CTX.spellID)
end, "[!] ถามเป็นราย spell ว่า unit นี้ร่ายเวทนี้แล้วจะ secret ไหม")
U(c1, "ShouldUnitSpellCastingBeSecret(u)", function(u)
    return Sec("ShouldUnitSpellCastingBeSecret", u)
end, "[!] ตัวรวม (ไม่ระบุ spell) — true ⇒ UnitCastingInfo/UnitChannelInfo คืน secret")
U(c1, "ShouldUnitThreatStateBeSecret('player', u)", function(u)
    -- signature = (unit, mobUnit?) — จับคู่กับ UnitDetailedThreatSituation('player', u)
    return Sec("ShouldUnitThreatStateBeSecret", "player", u)
end)
U(c1, "ShouldUnitThreatValuesBeSecret('player', u)", function(u)
    -- signature = (unit, mobUnit) — arg 2 บังคับ (ต่างจาก ThreatState ที่ optional)
    return Sec("ShouldUnitThreatValuesBeSecret", "player", u)
end)
G(c1, "ShouldSpellCooldownBeSecret(spellID)", function()
    return Sec("ShouldSpellCooldownBeSecret", CTX.spellID)
end)
G(c1, "ShouldSpellAuraBeSecret(spellID)", function()
    return Sec("ShouldSpellAuraBeSecret", CTX.spellID)
end)
G(c1, "GetSpellAuraSecrecy(spellID)", function()
    return Sec("GetSpellAuraSecrecy", CTX.spellID)
end, "คืน Enum.SecrecyLevel (ตัวเลข) ไม่ใช่ boolean")
G(c1, "GetSpellCastSecrecy(spellID)", function()
    return Sec("GetSpellCastSecrecy", CTX.spellID)
end, "คืน Enum.SecrecyLevel (ตัวเลข)")
G(c1, "GetSpellCooldownSecrecy(spellID)", function()
    return Sec("GetSpellCooldownSecrecy", CTX.spellID)
end, "คืน Enum.SecrecyLevel (ตัวเลข)")
G(c1, "GetPowerTypeSecrecy(0)", function()
    return Sec("GetPowerTypeSecrecy", 0)
end, "0 = Mana · คืน Enum.SecrecyLevel (ตัวเลข)")

G(c1, "ShouldSpellBookItemCooldownBeSecret(1, PlayerBank)", function()
    local bank = 0
    if Enum ~= nil and Enum.SpellBookSpellBank ~= nil then
        bank = Enum.SpellBookSpellBank.Player
    end
    return Sec("ShouldSpellBookItemCooldownBeSecret", 1, bank)
end, "signature = (spellBookItemSlotIndex, spellBookItemSpellBank)")
G(c1, "ShouldActionCooldownBeSecret(1)", function()
    return Sec("ShouldActionCooldownBeSecret", 1)
end, "action bar slot 1")
G(c1, "ShouldTotemSlotBeSecret(1)", function()
    return Sec("ShouldTotemSlotBeSecret", 1)
end)
G(c1, "ShouldTotemSpellBeSecret(spellID)", function()
    return Sec("ShouldTotemSpellBeSecret", CTX.spellID)
end)

-- ============================================================
-- 2. Unit identity / role / classification
-- ============================================================
local c2 = Cat("2. Unit identity / role / classification")

U(c2, "UnitExists(u)", function(u) return UnitExists(u) end,
    "ใช้ 50 จุดทั่วโปรเจกต์ — gate ก่อนอ่านค่าอื่น")
U(c2, "UnitName(u)", function(u) return UnitName(u) end,
    "12.1: ไม่คืน secret ระหว่าง PvP match แล้ว แต่ยัง secret ตาม unit identity")
U(c2, "UnitGUID(u)", function(u) return UnitGUID(u) end,
    "[!] AuraCache.lua จับคู่ nameplate<->target ด้วย GUID == GUID")
U(c2, "UnitClass(u)", function(u) return UnitClass(u) end,
    "[!] 12.1 เพิ่มเข้ากลุ่ม unit-identity — ค่าที่ 2 (token) คือค่าที่เอาไปเทียบ")
U(c2, "UnitGroupRolesAssigned(u)", function(u) return UnitGroupRolesAssigned(u) end,
    "[!!] ต้นเหตุ error TargetCastBar.lua:265 — role == 'TANK' บน unit ที่วิ่งผ่าน enemy")
U(c2, "UnitClassification(u)", function(u) return UnitClassification(u) end,
    "[!] เทียบกับ 'elite' / 'worldboss' / 'rareelite' ใน Rotation condition")
U(c2, "UnitLevel(u)", function(u) return UnitLevel(u) end)
U(c2, "UnitCreatureType(u)", function(u) return UnitCreatureType(u) end)
U(c2, "UnitRace(u)", function(u) return UnitRace(u) end,
    "12.1 เพิ่มเข้ากลุ่ม unit-identity")
U(c2, "UnitIsPlayer(u)", function(u) return UnitIsPlayer(u) end)
U(c2, "UnitPlayerControlled(u)", function(u) return UnitPlayerControlled(u) end)
U(c2, "UnitIsUnit(u, 'player')", function(u) return UnitIsUnit(u, "player") end,
    "[!] ต้องผ่าน CanCompareUnitTokens ก่อน (หมวด 1)")
U(c2, "UnitIsUnit(u..'target', 'player')", function(u)
    return UnitIsUnit(u .. "target", "player")
end, "[!] รูปแบบเดียวกับ targetedMeCache ของ TargetCastBar.lua (pixel 14)")
U(c2, "UnitIsFriend('player', u)", function(u) return UnitIsFriend("player", u) end)
U(c2, "UnitCanAttack('player', u)", function(u) return UnitCanAttack("player", u) end,
    "[!] ใช้ 24 จุด — gate ของ pixel 4")
U(c2, "UnitCanAssist('player', u)", function(u) return UnitCanAssist("player", u) end)
U(c2, "UnitReaction('player', u)", function(u) return UnitReaction("player", u) end)
U(c2, "UnitIsDead(u)", function(u) return UnitIsDead(u) end)
U(c2, "UnitIsDeadOrGhost(u)", function(u) return UnitIsDeadOrGhost(u) end)
U(c2, "UnitIsConnected(u)", function(u) return UnitIsConnected(u) end)
U(c2, "UnitIsVisible(u)", function(u) return UnitIsVisible(u) end)
U(c2, "UnitAffectingCombat(u)", function(u) return UnitAffectingCombat(u) end,
    "[!] GeRODPS.UnitInCombatForRotation ครอบตัวนี้อีกที (TrainingDummyDetect)")
U(c2, "UnitInVehicle(u)", function(u) return UnitInVehicle(u) end)
U(c2, "UnitIsPVP(u)", function(u) return UnitIsPVP(u) end,
    "12.1 เพิ่มเข้ากลุ่ม unit-identity")
U(c2, "UnitFactionGroup(u)", function(u) return UnitFactionGroup(u) end)
U(c2, "UnitIsTapDenied(u)", function(u) return UnitIsTapDenied(u) end)

-- ============================================================
-- 3. Health / Power
-- ============================================================
local c3 = Cat("3. Health / Power (ค่าที่เอาไปหาร / เทียบ threshold)")

U(c3, "UnitHealth(u)", function(u) return UnitHealth(u) end,
    "[!] EnemyHP / PartyHealth — หารด้วย Max แล้วเทียบ threshold")
U(c3, "UnitHealthMax(u)", function(u) return UnitHealthMax(u) end)
U(c3, "UnitHealthPercent(u, true)", function(u)
    if UnitHealthPercent == nil then return nil end
    return UnitHealthPercent(u, true)
end, "[!] คืน ratio 0..1 ไม่ใช่ percent (wow-coding Rule 3)")
U(c3, "UnitPower(u)", function(u) return UnitPower(u) end)
U(c3, "UnitPowerMax(u)", function(u) return UnitPowerMax(u) end)
U(c3, "UnitPowerPercent(u, nil, true)", function(u)
    if UnitPowerPercent == nil then return nil end
    -- signature = (unit, powerType, unmodified) — powerType เป็น optional
    -- ⚠ ไม่ใช่ (unit, ratioFlag) แบบ UnitHealthPercent
    -- ตัวอย่างในโปรเจกต์: Condition_Setting_Category.lua:234
    return UnitPowerPercent(u, nil, true)
end, "[!] 3 พารามิเตอร์ ต่างจาก UnitHealthPercent(unit, unmodified) ที่มี 2")
U(c3, "UnitPowerType(u)", function(u) return UnitPowerType(u) end)
U(c3, "UnitGetTotalAbsorbs(u)", function(u) return UnitGetTotalAbsorbs(u) end,
    "เคยส่งผ่าน STS — ยกเลิกแล้ว ย้ายไปนับสี pixel ที่ Bar 5 PartyHealth")
U(c3, "UnitGetTotalHealAbsorbs(u)", function(u) return UnitGetTotalHealAbsorbs(u) end)
U(c3, "UnitGetIncomingHeals(u)", function(u) return UnitGetIncomingHeals(u) end)
U(c3, "UnitStat(u, 1)", function(u) return UnitStat(u, 1) end,
    "DPSAverageFrame โหมด stat: (Str+Agi+Int)*10")

-- UnitGetDetailedHealPrediction(unit [, healerUnit], calculator)
-- ตัวฟังก์ชันไม่คืนค่า — ผลไปโผล่ที่ getter ของ calculator (แบบ PartyHealth.lua)
U(c3, "HealPrediction :GetCurrentHealth()", function(u)
    return HealPred(u, "GetCurrentHealth")
end, "[!] UnitGetDetailedHealPrediction(u, u, calc) แล้วอ่านจาก calc — Bar 5 PartyHealth")
U(c3, "HealPrediction :GetMaximumHealth()", function(u)
    return HealPred(u, "GetMaximumHealth")
end)
U(c3, "HealPrediction :GetDamageAbsorbs()", function(u)
    return HealPred(u, "GetDamageAbsorbs")
end)
U(c3, "HealPrediction :GetIncomingHeals()", function(u)
    return HealPred(u, "GetIncomingHeals")
end)
U(c3, "HealPrediction :GetHealAbsorbs()", function(u)
    return HealPred(u, "GetHealAbsorbs")
end)

-- ============================================================
-- 4. Cast / Channel
-- ============================================================
local c4 = Cat("4. Cast / Channel (TargetCastBar / NamePlateCastingChannel)")

U(c4, "UnitCastingInfo(u)  [1] name", function(u)
    return (UnitCastingInfo(u))
end)
U(c4, "UnitCastingInfo(u)  [4] startTimeMS", function(u)
    return select(4, UnitCastingInfo(u))
end, "[!] เดิมเอาไปลบกับ endTime แล้วหาร 1000")
U(c4, "UnitCastingInfo(u)  [5] endTimeMS", function(u)
    return select(5, UnitCastingInfo(u))
end)
U(c4, "UnitCastingInfo(u)  [8] notInterruptible", function(u)
    return select(8, UnitCastingInfo(u))
end, "[!] pixel 10 cannotKick — boolean test บน secret boolean = throw")
U(c4, "UnitCastingInfo(u)  [9] spellID", function(u)
    return select(9, UnitCastingInfo(u))
end, "[!] เทียบกับ InterruptSkipList / MobSpellTable / pack lists")

U(c4, "UnitChannelInfo(u)  [1] name", function(u)
    return (UnitChannelInfo(u))
end)
U(c4, "UnitChannelInfo(u)  [5] endTimeMS", function(u)
    return select(5, UnitChannelInfo(u))
end)
U(c4, "UnitChannelInfo(u)  [7] notInterruptible", function(u)
    return select(7, UnitChannelInfo(u))
end, "[!] index ต่างจาก CastingInfo (7 ไม่ใช่ 8)")
U(c4, "UnitChannelInfo(u)  [8] spellID", function(u)
    return select(8, UnitChannelInfo(u))
end)

U(c4, "UnitCastingDuration(u)   [obj ~= nil]", function(u)
    local o = UnitCastingDuration(u)
    if o == nil then return nil end
    if IsSecret(o) then return o end
    return true
end, "ตัว DurationObj เอง — ค่าที่ method คืนต่างหากที่มักเป็น secret")
U(c4, "  UnitCastingDuration(u):GetElapsedPercent()", function(u)
    return DurCall(UnitCastingDuration(u), "GetElapsedPercent")
end, "[!] TargetCastBar เอาไปเทียบกับ KickPercent")
U(c4, "  UnitCastingDuration(u):GetRemainingDuration()", function(u)
    return DurCall(UnitCastingDuration(u), "GetRemainingDuration")
end, "[!] STS slot 2 TargetCastRemain — format ส่งได้ แต่เทียบไม่ได้")
U(c4, "  UnitChannelDuration(u):GetElapsedPercent()", function(u)
    return DurCall(UnitChannelDuration(u), "GetElapsedPercent")
end)
U(c4, "  UnitChannelDuration(u):GetRemainingDuration()", function(u)
    return DurCall(UnitChannelDuration(u), "GetRemainingDuration")
end)

-- ============================================================
-- 5. Aura ทาง INDEX / SLOT / INSTANCE — 12.1 = Lua error ตอน aura secret
--    ทุกแถว gate ด้วย C_Secrets ก่อน (ยกเว้นแถว [ไม่ guard] ที่จงใจไว้ดู error จริง)
-- ============================================================
local c5 = Cat("5. Aura ทาง index/slot/instanceID (12.1 บล็อกตอน combat)")

local function HarmAura(u)
    if AuraIndexIsSecret(u, CTX.auraIndex, "HARMFUL") then return nil, true end
    return C_UnitAuras.GetAuraDataByIndex(u, CTX.auraIndex, "HARMFUL"), false
end

-- อ่าน field จาก aura HARMFUL #idx โดยผ่าน gate — คืน Blocked ถ้าห้ามเรียก
local function HarmField(u, key)
    local a, blocked = HarmAura(u)
    if blocked == true then return Blocked(AURA_BLOCK_MSG) end
    if key == nil then
        if a == nil then return nil end
        if IsSecret(a) then return a end
        return true
    end
    return Field(a, key)
end

U(c5, "GetAuraDataByIndex(u, idx, 'HARMFUL')  [ไม่ guard]", function(u)
    return C_UnitAuras.GetAuraDataByIndex(u, CTX.auraIndex, "HARMFUL")
end, "[!!] จงใจไม่ gate ไว้เป็นหลักฐาน — 12.1 จะ throw 'Auras cannot be accessed when secret'")
U(c5, "GetAuraDataByIndex(u, idx, 'HARMFUL')  [gate แล้ว]", function(u)
    return HarmField(u, nil)
end, "[!!] แถวนี้ BLOCKED/ERR = ไม่ได้ table มาตั้งแต่แรก ⇒ ทุกแถว .field ข้างล่าง "
   .. "จบตามทั้งหมด (ไม่ใช่ secret ทีละ field — เข้าไม่ถึงทั้งก้อน)")
U(c5, "  .name", function(u) return HarmField(u, "name") end)
U(c5, "  .spellId", function(u) return HarmField(u, "spellId") end,
    "[!] เทียบกับลิสต์ DispelAura / condition aura_present")
U(c5, "  .applications", function(u) return HarmField(u, "applications") end,
    "[!] stack count — เทียบ >= N")
U(c5, "  .expirationTime", function(u) return HarmField(u, "expirationTime") end,
    "[!] ห้าม expirationTime - GetTime() — ใช้ GetAuraDuration แทน")
U(c5, "  .duration", function(u) return HarmField(u, "duration") end)
U(c5, "  .auraInstanceID", function(u) return HarmField(u, "auraInstanceID") end,
    "wiki: auraInstanceID เป็น NeverSecret — แต่ตัว API ที่ใช้อ่านยังโดนบล็อก")
U(c5, "  .dispelName", function(u) return HarmField(u, "dispelName") end,
    "[!] DispelNPScanChannel ส่งดิบผ่าน STS + font hack เพราะเทียบฝั่ง Lua ไม่ได้")
U(c5, "  .sourceUnit", function(u) return HarmField(u, "sourceUnit") end)
U(c5, "  .isHelpful", function(u) return HarmField(u, "isHelpful") end,
    "wiki: NeverSecret")
U(c5, "  .isStealable", function(u) return HarmField(u, "isStealable") end)
U(c5, "  .isFromPlayerOrPlayerPet", function(u)
    return HarmField(u, "isFromPlayerOrPlayerPet")
end, "wiki: NeverSecret")
U(c5, "GetAuraDataByIndex(u, idx, 'HELPFUL')  [gate แล้ว] .spellId", function(u)
    if AuraIndexIsSecret(u, CTX.auraIndex, "HELPFUL") then
        return Blocked(AURA_BLOCK_MSG)
    end
    return Field(C_UnitAuras.GetAuraDataByIndex(u, CTX.auraIndex, "HELPFUL"), "spellId")
end)
U(c5, "GetAuraDuration(u, instID):GetRemainingDuration()", function(u)
    local a, blocked = HarmAura(u)
    if blocked == true then return Blocked(AURA_BLOCK_MSG) end
    if a == nil then return nil end
    if IsSecret(a) then return a end
    local id = a.auraInstanceID
    if id == nil then return nil end
    if C_UnitAuras.GetAuraDuration == nil then return nil end
    return DurCall(C_UnitAuras.GetAuraDuration(u, id), "GetRemainingDuration")
end, "[!] ทางที่ถูกต้องแทน expirationTime - GetTime() — แต่ instanceID-based ⇒ โดนบล็อกด้วย")
U(c5, "C_UnitAuras.GetAuraSlots(u, 'HARMFUL')  [1]", function(u)
    if AurasAreSecret() then return Blocked(AURA_BLOCK_MSG) end
    if C_UnitAuras.GetAuraSlots == nil then return nil end
    return (C_UnitAuras.GetAuraSlots(u, "HARMFUL"))
end)

-- ============================================================
-- 6. Aura ทาง SPELL ID / NAME — 12.1 บอกว่ายังเรียกได้ตามปกติ
--    "non-secret spells still return non-secrets"  ⇒ ทางรอดของ addon
-- ============================================================
local c6 = Cat("6. Aura ทาง spellID / spell name (ทางที่ 12.1 ยังเปิดให้)")

-- ทางนี้ไม่โดนบล็อก ⇒ ได้ table จริงมาแจกแจงทีละ field ได้
-- ⚠ ต้องมี aura ของ Spell ID ในช่อง input อยู่บน unit นั้นจริง ไม่งั้นได้ nil ทุกแถว
local function SpellAura(u)
    if C_UnitAuras.GetUnitAuraBySpellID == nil then return nil end
    return C_UnitAuras.GetUnitAuraBySpellID(u, CTX.spellID)
end

local function SpellAuraField(u, key)
    return Field(SpellAura(u), key)
end

U(c6, "GetUnitAuraBySpellID(u, spellID)  [มี aura ไหม]", function(u)
    local a = SpellAura(u)
    if a == nil then return nil end
    if IsSecret(a) then return a end
    return true
end, "[!!] ทางหลักที่เหลือ · true = มี aura นี้อยู่ · nil = ไม่มี (ไม่ใช่โดนบล็อก)")

-- ---- 23 field ของ AuraData (ตาม Annotations/Core/Type/Structure.lua) ----
-- wiki ระบุว่า 5 ตัวนี้ NeverSecret: auraInstanceID · isFromPlayerOrPlayerPet ·
-- isHarmful · isHelpful · isNameplateOnly
U(c6, "  .name", function(u) return SpellAuraField(u, "name") end)
U(c6, "  .spellId", function(u) return SpellAuraField(u, "spellId") end,
    "[!] เทียบกับลิสต์ DispelAura / condition aura_present")
U(c6, "  .icon", function(u) return SpellAuraField(u, "icon") end)
U(c6, "  .applications", function(u) return SpellAuraField(u, "applications") end,
    "[!] stack count — เทียบ >= N")
U(c6, "  .charges", function(u) return SpellAuraField(u, "charges") end)
U(c6, "  .maxCharges", function(u) return SpellAuraField(u, "maxCharges") end)
U(c6, "  .duration", function(u) return SpellAuraField(u, "duration") end)
U(c6, "  .expirationTime", function(u) return SpellAuraField(u, "expirationTime") end,
    "[!] ห้าม expirationTime - GetTime() — ใช้ GetAuraDuration แทน")
U(c6, "  .timeMod", function(u) return SpellAuraField(u, "timeMod") end)
U(c6, "  .auraInstanceID", function(u) return SpellAuraField(u, "auraInstanceID") end,
    "[NeverSecret ตาม wiki] key ของ AuraCache")
U(c6, "  .dispelName", function(u) return SpellAuraField(u, "dispelName") end,
    "[!] DispelNPScanChannel ส่งดิบผ่าน STS + font hack เพราะเทียบฝั่ง Lua ไม่ได้")
U(c6, "  .sourceUnit", function(u) return SpellAuraField(u, "sourceUnit") end)
U(c6, "  .isHelpful", function(u) return SpellAuraField(u, "isHelpful") end,
    "[NeverSecret ตาม wiki]")
U(c6, "  .isHarmful", function(u) return SpellAuraField(u, "isHarmful") end,
    "[NeverSecret ตาม wiki]")
U(c6, "  .isFromPlayerOrPlayerPet", function(u)
    return SpellAuraField(u, "isFromPlayerOrPlayerPet")
end, "[NeverSecret ตาม wiki]")
U(c6, "  .isNameplateOnly", function(u) return SpellAuraField(u, "isNameplateOnly") end,
    "[NeverSecret ตาม wiki]")
U(c6, "  .isBossAura", function(u) return SpellAuraField(u, "isBossAura") end)
U(c6, "  .isStealable", function(u) return SpellAuraField(u, "isStealable") end)
U(c6, "  .isRaid", function(u) return SpellAuraField(u, "isRaid") end)
U(c6, "  .canApplyAura", function(u) return SpellAuraField(u, "canApplyAura") end)
U(c6, "  .nameplateShowAll", function(u) return SpellAuraField(u, "nameplateShowAll") end)
U(c6, "  .nameplateShowPersonal", function(u)
    return SpellAuraField(u, "nameplateShowPersonal")
end)
U(c6, "  .points  [#]", function(u)
    local pts = SpellAuraField(u, "points")
    if pts == nil then return nil end
    if IsSecret(pts) then return pts end
    return #pts
end)

-- ---- ทางอื่นในตระกูล spellID / name ----
U(c6, "GetAuraDataBySpellName(u, <ชื่อจาก Spell ID>) .spellId", function(u)
    if C_UnitAuras.GetAuraDataBySpellName == nil then return nil end
    local nm = C_Spell.GetSpellName(CTX.spellID)
    if nm == nil then return nil end
    if IsSecret(nm) then return nm end
    return Field(C_UnitAuras.GetAuraDataBySpellName(u, nm, "HELPFUL"), "spellId")
end, "signature = (unit, spellName, filter?)")
U(c6, "GetAuraDuration(u, <instID จากทาง spellID>)", function(u)
    local a = SpellAura(u)
    if a == nil then return nil end
    if IsSecret(a) then return a end
    local id = a.auraInstanceID
    if id == nil then return nil end
    if C_UnitAuras.GetAuraDuration == nil then return nil end
    return DurCall(C_UnitAuras.GetAuraDuration(u, id), "GetRemainingDuration")
end, "[!!] instanceID ได้มาจากทาง spellID (ไม่โดนบล็อก) แล้วเอามาขอ duration — "
   .. "ถ้าแถวนี้ทำงานได้ตอน combat = ยังคำนวณ remain ได้")
G(c6, "GetPlayerAuraBySpellID(spellID)  [มี aura ไหม]", function()
    if C_UnitAuras.GetPlayerAuraBySpellID == nil then return nil end
    local a = C_UnitAuras.GetPlayerAuraBySpellID(CTX.spellID)
    if a == nil then return nil end
    if IsSecret(a) then return a end
    return true
end, "[!] เฉพาะ player — ไม่ต้องส่ง unit")
G(c6, "GetPlayerAuraBySpellID(spellID) .expirationTime", function()
    if C_UnitAuras.GetPlayerAuraBySpellID == nil then return nil end
    return Field(C_UnitAuras.GetPlayerAuraBySpellID(CTX.spellID), "expirationTime")
end)
G(c6, "GetCooldownAuraBySpellID(spellID)", function()
    if C_UnitAuras.GetCooldownAuraBySpellID == nil then return nil end
    return C_UnitAuras.GetCooldownAuraBySpellID(CTX.spellID)
end)

-- ============================================================
-- 7. Threat / Range
-- ============================================================
local c7 = Cat("7. Threat / Range")

U(c7, "UnitDetailedThreatSituation('player', u)", function(u)
    return UnitDetailedThreatSituation("player", u)
end, "[!] 5 ค่า: isTanking, status, scaledPct, rawPct, threatValue")
U(c7, "UnitThreatSituation('player', u)", function(u)
    return UnitThreatSituation("player", u)
end)
U(c7, "UnitInRange(u)", function(u) return UnitInRange(u) end,
    "ของ Blizzard — ใช้ได้เฉพาะเพื่อนร่วมกลุ่ม")
U(c7, "C_Spell.IsSpellInRange(spellID, u)", function(u)
    return C_Spell.IsSpellInRange(CTX.spellID, u)
end, "[!] HealSkill / HealPetSkill เทียบ == true / == false")
U(c7, "C_Item.IsItemInRange(itemID, u)", function(u)
    return C_Item.IsItemInRange(CTX.itemID, u)
end, "[!] RangeCheck.lua — SecretWhenInCombat เมื่อ unit เป็นเพื่อน")
U(c7, "GetUnitSpeed(u)", function(u) return GetUnitSpeed(u) end)

-- ============================================================
-- 8. Spell (ใช้ Spell ID จากช่อง input)
-- ============================================================
local c8 = Cat("8. Spell — ใช้ค่า Spell ID ในช่อง input ด้านบน")

G(c8, "C_Spell.GetSpellName(id)", function()
    return C_Spell.GetSpellName(CTX.spellID)
end)
G(c8, "C_Spell.GetSpellInfo(id) .name", function()
    return Field(C_Spell.GetSpellInfo(CTX.spellID), "name")
end)
G(c8, "C_Spell.GetSpellInfo(id) .castTime", function()
    return Field(C_Spell.GetSpellInfo(CTX.spellID), "castTime")
end, "[!] SpellCastType เทียบ > 0 เพื่อแยก instant / cast")
G(c8, "C_Spell.GetSpellInfo(id) .minRange, .maxRange", function()
    local info = C_Spell.GetSpellInfo(CTX.spellID)
    if info == nil then return nil end
    if IsSecret(info) then return info end
    return info.minRange, info.maxRange
end)
G(c8, "C_Spell.GetSpellCooldown(id)  [table]", function()
    local t = C_Spell.GetSpellCooldown(CTX.spellID)
    if t == nil then return nil end
    if IsSecret(t) then return t end
    return true
end, "[!] PlayerGCDBar.lua จดไว้ว่าทุก field ของ table นี้เป็น secret ตอน in-combat")
G(c8, "  .startTime", function()
    return Field(C_Spell.GetSpellCooldown(CTX.spellID), "startTime")
end, "[!] เทียบ > 0 เพื่อรู้ว่า GCD กำลังเดิน")
G(c8, "  .duration", function()
    return Field(C_Spell.GetSpellCooldown(CTX.spellID), "duration")
end)
G(c8, "  .isEnabled", function()
    return Field(C_Spell.GetSpellCooldown(CTX.spellID), "isEnabled")
end)
G(c8, "  .modRate", function()
    return Field(C_Spell.GetSpellCooldown(CTX.spellID), "modRate")
end)
G(c8, "C_Spell.GetSpellCooldownDuration(id):GetRemainingDuration()", function()
    if C_Spell.GetSpellCooldownDuration == nil then return nil end
    return DurCall(C_Spell.GetSpellCooldownDuration(CTX.spellID), "GetRemainingDuration")
end, "[!] ทางที่ถูกสำหรับ CD — แต่ค่าที่ได้ยังเป็น secret")
G(c8, "C_Spell.GetSpellCooldownDuration(id):GetRemainingPercent()", function()
    if C_Spell.GetSpellCooldownDuration == nil then return nil end
    return DurCall(C_Spell.GetSpellCooldownDuration(CTX.spellID), "GetRemainingPercent")
end, "[!] เขียนลง B byte ของ pixel ได้ตรงๆ แต่ห้ามเทียบ")
G(c8, "C_Spell.GetSpellCharges(id) .currentCharges", function()
    return Field(C_Spell.GetSpellCharges(CTX.spellID), "currentCharges")
end, "[!] เทียบ >= 1")
G(c8, "C_Spell.GetSpellCharges(id) .maxCharges", function()
    return Field(C_Spell.GetSpellCharges(CTX.spellID), "maxCharges")
end)
G(c8, "C_Spell.GetSpellChargeDuration(id):GetRemainingDuration()", function()
    if C_Spell.GetSpellChargeDuration == nil then return nil end
    return DurCall(C_Spell.GetSpellChargeDuration(CTX.spellID), "GetRemainingDuration")
end)
G(c8, "C_Spell.IsSpellUsable(id)", function()
    return C_Spell.IsSpellUsable(CTX.spellID)
end, "[!] คืน usable, noMana — CombatAssistIcon เทียบ == false")
G(c8, "C_Spell.IsCurrentSpell(id)", function()
    return C_Spell.IsCurrentSpell(CTX.spellID)
end)
G(c8, "C_Spell.IsSpellImportant(id)", function()
    if C_Spell.IsSpellImportant == nil then return nil end
    return C_Spell.IsSpellImportant(CTX.spellID)
end, "[!] pixel 11 isImportantSpell ของ TargetCastBar")
G(c8, "C_Spell.GetOverrideSpell(id)", function()
    return C_Spell.GetOverrideSpell(CTX.spellID)
end, "[!] SpellOverrideCache เทียบ overrideID ~= baseID")
G(c8, "C_Spell.SpellHasRange(id)", function()
    return C_Spell.SpellHasRange(CTX.spellID)
end)
G(c8, "C_Spell.DoesSpellExist(id)", function()
    return C_Spell.DoesSpellExist(CTX.spellID)
end)
G(c8, "C_Spell.GetSpellTexture(id)", function()
    return C_Spell.GetSpellTexture(CTX.spellID)
end)
G(c8, "C_SpellBook.IsSpellInSpellBook(id, PlayerBank, true)", function()
    if C_SpellBook.IsSpellInSpellBook == nil then return nil end
    local bank = 0
    if Enum ~= nil and Enum.SpellBookSpellBank ~= nil then
        bank = Enum.SpellBookSpellBank.Player
    end
    return C_SpellBook.IsSpellInSpellBook(CTX.spellID, bank, true)
end, "GeRODPS.IsSpellKnown (Util.lua) ใช้ตัวนี้")
G(c8, "C_SpellBook.FindBaseSpellByID(id)", function()
    if C_SpellBook.FindBaseSpellByID == nil then return nil end
    return C_SpellBook.FindBaseSpellByID(CTX.spellID)
end)
G(c8, "IsPlayerSpell(id)", function() return IsPlayerSpell(CTX.spellID) end)
G(c8, "GetSpellInfo(id)   [global legacy]", function()
    if GetSpellInfo == nil then return nil end
    return GetSpellInfo(CTX.spellID)
end)

-- ============================================================
-- 9. Item / Trinket (ใช้ Item ID จากช่อง input)
-- ============================================================
local c9 = Cat("9. Item / Trinket — ใช้ค่า Item ID ในช่อง input ด้านบน")

G(c9, "C_Item.GetItemCooldown(itemID)", function()
    return C_Item.GetItemCooldown(CTX.itemID)
end, "[!] คืน start, duration, enable — TrinketUse เทียบกับ GCD")
G(c9, "C_Item.GetItemSpell(itemID)", function()
    return C_Item.GetItemSpell(CTX.itemID)
end)
G(c9, "C_Item.GetItemInfo(itemID)  [1] name", function()
    return (C_Item.GetItemInfo(CTX.itemID))
end)
G(c9, "C_Item.GetItemCount(itemID)", function()
    return C_Item.GetItemCount(CTX.itemID)
end)
G(c9, "C_Item.GetItemInfoInstant(itemID)", function()
    return C_Item.GetItemInfoInstant(CTX.itemID)
end)
G(c9, "GetInventoryItemID('player', 13)", function()
    return GetInventoryItemID("player", 13)
end, "trinket slot 1")
G(c9, "GetInventoryItemID('player', 14)", function()
    return GetInventoryItemID("player", 14)
end, "trinket slot 2")

-- ============================================================
-- 10. Player state / instance / group
-- ============================================================
local c10 = Cat("10. Player state / instance / group")

G(c10, "GetSpecialization()", function() return GetSpecialization() end)
G(c10, "GetSpecializationInfo(GetSpecialization())", function()
    local s = GetSpecialization()
    if s == nil then return nil end
    if IsSecret(s) then return s end
    return GetSpecializationInfo(s)
end, "[!] PlayerInfo pixel 31 — เทียบ specID")
G(c10, "GetInstanceInfo()  [2] instanceType", function()
    return select(2, GetInstanceInfo())
end)
G(c10, "GetInstanceInfo()  [8] instanceID", function()
    return select(8, GetInstanceInfo())
end, "[!] CurrentInstance.lua PR2 slot — Map.db2 ID")
G(c10, "GetHaste()", function() return GetHaste() end)
G(c10, "IsMounted()", function() return IsMounted() end)
G(c10, "IsInGroup()", function() return IsInGroup() end)
G(c10, "IsInRaid()", function() return IsInRaid() end)
G(c10, "GetNumGroupMembers()", function() return GetNumGroupMembers() end)
G(c10, "GetActionInfo(1)", function() return GetActionInfo(1) end)
G(c10, "C_LossOfControl.GetActiveLossOfControlDataCount()", function()
    if C_LossOfControl == nil then return nil end
    if C_LossOfControl.GetActiveLossOfControlDataCount == nil then return nil end
    return C_LossOfControl.GetActiveLossOfControlDataCount()
end, "[!] PlayerCCHelper เทียบ n == 0")
G(c10, "GetActiveLossOfControlData(1) .locType", function()
    if C_LossOfControl == nil then return nil end
    if C_LossOfControl.GetActiveLossOfControlData == nil then return nil end
    return Field(C_LossOfControl.GetActiveLossOfControlData(1), "locType")
end, "[!] เทียบ == 'SCHOOL_INTERRUPT'")
G(c10, "GetActiveLossOfControlData(1) .displayText", function()
    if C_LossOfControl == nil then return nil end
    if C_LossOfControl.GetActiveLossOfControlData == nil then return nil end
    return Field(C_LossOfControl.GetActiveLossOfControlData(1), "displayText")
end, "[!] เทียบกับ LOSS_OF_CONTROL_DISPLAY_* 31 ตัว")
G(c10, "GetActiveLossOfControlData(1) .timeRemaining", function()
    if C_LossOfControl == nil then return nil end
    if C_LossOfControl.GetActiveLossOfControlData == nil then return nil end
    return Field(C_LossOfControl.GetActiveLossOfControlData(1), "timeRemaining")
end)
G(c10, "C_AssistedCombat.GetNextCastSpell(false)", function()
    if C_AssistedCombat == nil then return nil end
    if C_AssistedCombat.GetNextCastSpell == nil then return nil end
    return C_AssistedCombat.GetNextCastSpell(false)
end, "[!] CombatAssistIcon pixel 1 IROCode — secret = resolve keybind ไม่ได้")
G(c10, "C_AssistedCombat.GetRotationSpells()  [#]", function()
    if C_AssistedCombat == nil then return nil end
    if C_AssistedCombat.GetRotationSpells == nil then return nil end
    local t = C_AssistedCombat.GetRotationSpells()
    if t == nil then return nil end
    if IsSecret(t) then return t end
    return #t
end)
G(c10, "C_ChallengeMode.GetActiveKeystoneInfo()  [1] level", function()
    if C_ChallengeMode == nil then return nil end
    if C_ChallengeMode.GetActiveKeystoneInfo == nil then return nil end
    return (C_ChallengeMode.GetActiveKeystoneInfo())
end)
G(c10, "C_NamePlate.GetNamePlateForUnit('nameplate1') ~= nil", function()
    if C_NamePlate == nil then return nil end
    local f = C_NamePlate.GetNamePlateForUnit("nameplate1")
    if f == nil then return nil end
    if IsSecret(f) then return f end
    return true
end)
G(c10, "C_DamageMeter.GetAvailableCombatSessions()  [#]", function()
    if C_DamageMeter == nil then return nil end
    if C_DamageMeter.GetAvailableCombatSessions == nil then return nil end
    local t = C_DamageMeter.GetAvailableCombatSessions()
    if t == nil then return nil end
    if IsSecret(t) then return t end
    return #t
end, "[!] C_DamageMeter เป็น RESTRICTED — เรียกใน combat lockdown ไม่ได้")

TOOL.SecretAPIProbes = cats
