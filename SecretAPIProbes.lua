--[[
    GeRODPS_Tools / SecretAPIProbes.lua

    ตารางข้อมูลของเครื่องมือ "Secret API Check" — รายชื่อ WoW API ที่
    GeRODPS เรียกใช้ "แล้วต้องเอาค่าที่ได้ไปเปรียบเทียบ / คำนวณต่อ"
    (compare / arithmetic / boolean test) ซึ่งเป็น op ที่ throw ทันที
    ถ้าค่าที่ได้เป็น secret

    ไฟล์นี้ = ข้อมูลล้วน (ไม่มี UI). UI อยู่ที่ SecretAPICheck.lua

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

    อ้างอิง: .claude/skills/wow-coding/SKILL.md Rule 1 / 1.5 / 2 / 12,
             GeRODPS/docs/SECRET_VALUES.md, GeRODPS_Tools/SECRETS.md
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
    if C_Secrets == nil then return nil end
    if C_Secrets.HasSecretRestrictions == nil then return nil end
    return C_Secrets.HasSecretRestrictions()
end, "true = restriction กำลังบังคับใช้อยู่")

G(c0, "issecretvalue ~= nil   (API present)", function()
    return issecretvalue ~= nil
end, "ถ้า false = client ไม่มีระบบ secret เลย ผลทุกแถวจะไม่มีความหมาย")

G(c0, "C_RestrictedActions ~= nil   (API present)", function()
    return C_RestrictedActions ~= nil
end, "namespace สำหรับ query สถานะ restriction (12.x)")

G(c0, "InCombatLockdown()", function() return InCombatLockdown() end)
G(c0, "UnitAffectingCombat('player')", function() return UnitAffectingCombat("player") end)
G(c0, "GetTime()", function() return GetTime() end,
    "ไม่ใช่ secret แต่ถูกใช้คู่กับค่าที่เป็น secret บ่อย (expirationTime - GetTime())")

-- ============================================================
-- 1. Unit identity / role / classification
-- ============================================================
local c1 = Cat("1. Unit identity / role / classification")

U(c1, "UnitExists(u)", function(u) return UnitExists(u) end,
    "ใช้ 50 จุดทั่วโปรเจกต์ — gate ก่อนอ่านค่าอื่น")
U(c1, "UnitName(u)", function(u) return UnitName(u) end)
U(c1, "UnitGUID(u)", function(u) return UnitGUID(u) end,
    "[!] AuraCache.lua จับคู่ nameplate<->target ด้วย GUID == GUID")
U(c1, "UnitClass(u)", function(u) return UnitClass(u) end,
    "ค่าที่ 2 (token เช่น WARRIOR) คือค่าที่เอาไปเทียบ")
U(c1, "UnitGroupRolesAssigned(u)", function(u) return UnitGroupRolesAssigned(u) end,
    "[!!] ต้นเหตุ error TargetCastBar.lua:265 — role == 'TANK' บน unit ที่วิ่งผ่าน enemy")
U(c1, "UnitClassification(u)", function(u) return UnitClassification(u) end,
    "[!] เทียบกับ 'elite' / 'worldboss' / 'rareelite' ใน Rotation condition")
U(c1, "UnitLevel(u)", function(u) return UnitLevel(u) end)
U(c1, "UnitCreatureType(u)", function(u) return UnitCreatureType(u) end)
U(c1, "UnitRace(u)", function(u) return UnitRace(u) end)
U(c1, "UnitIsPlayer(u)", function(u) return UnitIsPlayer(u) end)
U(c1, "UnitPlayerControlled(u)", function(u) return UnitPlayerControlled(u) end)
U(c1, "UnitIsUnit(u, 'player')", function(u) return UnitIsUnit(u, "player") end)
U(c1, "UnitIsUnit(u..'target', 'player')", function(u)
    return UnitIsUnit(u .. "target", "player")
end, "[!] รูปแบบเดียวกับ targetedMeCache ของ TargetCastBar.lua (pixel 14)")
U(c1, "UnitIsFriend('player', u)", function(u) return UnitIsFriend("player", u) end)
U(c1, "UnitCanAttack('player', u)", function(u) return UnitCanAttack("player", u) end,
    "[!] ใช้ 24 จุด — gate ของ pixel 4")
U(c1, "UnitCanAssist('player', u)", function(u) return UnitCanAssist("player", u) end)
U(c1, "UnitReaction('player', u)", function(u) return UnitReaction("player", u) end)
U(c1, "UnitIsDead(u)", function(u) return UnitIsDead(u) end)
U(c1, "UnitIsDeadOrGhost(u)", function(u) return UnitIsDeadOrGhost(u) end)
U(c1, "UnitIsConnected(u)", function(u) return UnitIsConnected(u) end)
U(c1, "UnitIsVisible(u)", function(u) return UnitIsVisible(u) end)
U(c1, "UnitAffectingCombat(u)", function(u) return UnitAffectingCombat(u) end,
    "[!] GeRODPS.UnitInCombatForRotation ครอบตัวนี้อีกที (TrainingDummyDetect)")
U(c1, "UnitInVehicle(u)", function(u) return UnitInVehicle(u) end)
U(c1, "UnitIsPVP(u)", function(u) return UnitIsPVP(u) end)
U(c1, "UnitFactionGroup(u)", function(u) return UnitFactionGroup(u) end)
U(c1, "UnitIsTapDenied(u)", function(u) return UnitIsTapDenied(u) end)

-- ============================================================
-- 2. Health / Power
-- ============================================================
local c2 = Cat("2. Health / Power (ค่าที่เอาไปหาร / เทียบ threshold)")

U(c2, "UnitHealth(u)", function(u) return UnitHealth(u) end,
    "[!] EnemyHP / PartyHealth — หารด้วย Max แล้วเทียบ threshold")
U(c2, "UnitHealthMax(u)", function(u) return UnitHealthMax(u) end)
U(c2, "UnitHealthPercent(u, true)", function(u)
    if UnitHealthPercent == nil then return nil end
    return UnitHealthPercent(u, true)
end, "[!] คืน ratio 0..1 ไม่ใช่ percent (wow-coding Rule 3)")
U(c2, "UnitPower(u)", function(u) return UnitPower(u) end)
U(c2, "UnitPowerMax(u)", function(u) return UnitPowerMax(u) end)
U(c2, "UnitPowerPercent(u, true)", function(u)
    if UnitPowerPercent == nil then return nil end
    return UnitPowerPercent(u, true)
end)
U(c2, "UnitPowerType(u)", function(u) return UnitPowerType(u) end)
U(c2, "UnitGetTotalAbsorbs(u)", function(u) return UnitGetTotalAbsorbs(u) end,
    "เคยส่งผ่าน STS — ยกเลิกแล้ว ย้ายไปนับสี pixel ที่ Bar 5 PartyHealth")
U(c2, "UnitGetTotalHealAbsorbs(u)", function(u) return UnitGetTotalHealAbsorbs(u) end)
U(c2, "UnitGetIncomingHeals(u)", function(u) return UnitGetIncomingHeals(u) end)
U(c2, "UnitGetDetailedHealPrediction(u)", function(u)
    if UnitGetDetailedHealPrediction == nil then return nil end
    return UnitGetDetailedHealPrediction(u)
end)
U(c2, "UnitStat(u, 1)", function(u) return UnitStat(u, 1) end,
    "DPSAverageFrame โหมด stat: (Str+Agi+Int)*10")

-- ============================================================
-- 3. Cast / Channel
-- ============================================================
local c3 = Cat("3. Cast / Channel (TargetCastBar / NamePlateCastingChannel)")

U(c3, "UnitCastingInfo(u)  [1] name", function(u)
    return (UnitCastingInfo(u))
end)
U(c3, "UnitCastingInfo(u)  [4] startTimeMS", function(u)
    return select(4, UnitCastingInfo(u))
end, "[!] เดิมเอาไปลบกับ endTime แล้วหาร 1000")
U(c3, "UnitCastingInfo(u)  [5] endTimeMS", function(u)
    return select(5, UnitCastingInfo(u))
end)
U(c3, "UnitCastingInfo(u)  [8] notInterruptible", function(u)
    return select(8, UnitCastingInfo(u))
end, "[!] pixel 10 cannotKick — boolean test บน secret boolean = throw")
U(c3, "UnitCastingInfo(u)  [9] spellID", function(u)
    return select(9, UnitCastingInfo(u))
end, "[!] เทียบกับ InterruptSkipList / MobSpellTable / pack lists")

U(c3, "UnitChannelInfo(u)  [1] name", function(u)
    return (UnitChannelInfo(u))
end)
U(c3, "UnitChannelInfo(u)  [5] endTimeMS", function(u)
    return select(5, UnitChannelInfo(u))
end)
U(c3, "UnitChannelInfo(u)  [7] notInterruptible", function(u)
    return select(7, UnitChannelInfo(u))
end, "[!] index ต่างจาก CastingInfo (7 ไม่ใช่ 8)")
U(c3, "UnitChannelInfo(u)  [8] spellID", function(u)
    return select(8, UnitChannelInfo(u))
end)

U(c3, "UnitCastingDuration(u)   [obj ~= nil]", function(u)
    local o = UnitCastingDuration(u)
    if o == nil then return nil end
    if IsSecret(o) then return o end
    return true
end, "ตัว DurationObj เอง — ค่าที่ method คืนต่างหากที่มักเป็น secret")
U(c3, "  UnitCastingDuration(u):GetElapsedPercent()", function(u)
    return DurCall(UnitCastingDuration(u), "GetElapsedPercent")
end, "[!] TargetCastBar เอาไปเทียบกับ KickPercent")
U(c3, "  UnitCastingDuration(u):GetRemainingDuration()", function(u)
    return DurCall(UnitCastingDuration(u), "GetRemainingDuration")
end, "[!] STS slot 2 TargetCastRemain — format ส่งได้ แต่เทียบไม่ได้")
U(c3, "  UnitChannelDuration(u):GetElapsedPercent()", function(u)
    return DurCall(UnitChannelDuration(u), "GetElapsedPercent")
end)
U(c3, "  UnitChannelDuration(u):GetRemainingDuration()", function(u)
    return DurCall(UnitChannelDuration(u), "GetRemainingDuration")
end)

-- ============================================================
-- 4. Aura — HARMFUL #idx
-- ============================================================
local c4 = Cat("4. Aura HARMFUL #idx (C_UnitAuras.GetAuraDataByIndex)")

local function HarmAura(u)
    return C_UnitAuras.GetAuraDataByIndex(u, CTX.auraIndex, "HARMFUL")
end

U(c4, "GetAuraDataByIndex(u, idx, 'HARMFUL')  [table]", function(u)
    local a = HarmAura(u)
    if a == nil then return nil end
    if IsSecret(a) then return a end
    return true
end, "true = ได้ table ปกติ · <secret> = ทั้ง table เป็น secret (index ไม่ได้เลย)")
U(c4, "  .name", function(u) return Field(HarmAura(u), "name") end)
U(c4, "  .spellId", function(u) return Field(HarmAura(u), "spellId") end,
    "[!] เทียบกับลิสต์ Bleed / DispelAura / condition aura_present")
U(c4, "  .applications", function(u) return Field(HarmAura(u), "applications") end,
    "[!] stack count — เทียบ >= N")
U(c4, "  .expirationTime", function(u) return Field(HarmAura(u), "expirationTime") end,
    "[!] ห้าม expirationTime - GetTime() — ใช้ GetAuraDuration แทน")
U(c4, "  .duration", function(u) return Field(HarmAura(u), "duration") end)
U(c4, "  .auraInstanceID", function(u) return Field(HarmAura(u), "auraInstanceID") end,
    "[!] ใช้เป็น key ของ AuraCache — secret เป็น table key ไม่ได้")
U(c4, "  .dispelName", function(u) return Field(HarmAura(u), "dispelName") end,
    "[!] DispelNPScanChannel ส่งดิบผ่าน STS + font hack เพราะเทียบฝั่ง Lua ไม่ได้")
U(c4, "  .sourceUnit", function(u) return Field(HarmAura(u), "sourceUnit") end)
U(c4, "  .isHelpful", function(u) return Field(HarmAura(u), "isHelpful") end)
U(c4, "  .isStealable", function(u) return Field(HarmAura(u), "isStealable") end)
U(c4, "  .isFromPlayerOrPlayerPet", function(u)
    return Field(HarmAura(u), "isFromPlayerOrPlayerPet")
end)
U(c4, "GetAuraDuration(u, instID):GetRemainingDuration()", function(u)
    local a = HarmAura(u)
    if a == nil then return nil end
    if IsSecret(a) then return a end
    local id = a.auraInstanceID
    if id == nil then return nil end
    if C_UnitAuras.GetAuraDuration == nil then return nil end
    return DurCall(C_UnitAuras.GetAuraDuration(u, id), "GetRemainingDuration")
end, "[!] ทางที่ถูกต้องแทน expirationTime - GetTime()")
U(c4, "C_UnitAuras.GetAuraSlots(u, 'HARMFUL')  [1]", function(u)
    if C_UnitAuras.GetAuraSlots == nil then return nil end
    return (C_UnitAuras.GetAuraSlots(u, "HARMFUL"))
end)

-- ============================================================
-- 5. Aura — HELPFUL #idx
-- ============================================================
local c5 = Cat("5. Aura HELPFUL #idx")

local function HelpAura(u)
    return C_UnitAuras.GetAuraDataByIndex(u, CTX.auraIndex, "HELPFUL")
end

U(c5, "GetAuraDataByIndex(u, idx, 'HELPFUL')  [table]", function(u)
    local a = HelpAura(u)
    if a == nil then return nil end
    if IsSecret(a) then return a end
    return true
end)
U(c5, "  .name", function(u) return Field(HelpAura(u), "name") end)
U(c5, "  .spellId", function(u) return Field(HelpAura(u), "spellId") end)
U(c5, "  .applications", function(u) return Field(HelpAura(u), "applications") end)
U(c5, "  .expirationTime", function(u) return Field(HelpAura(u), "expirationTime") end)
U(c5, "  .auraInstanceID", function(u) return Field(HelpAura(u), "auraInstanceID") end)
U(c5, "  .dispelName", function(u) return Field(HelpAura(u), "dispelName") end)
U(c5, "  .sourceUnit", function(u) return Field(HelpAura(u), "sourceUnit") end)
U(c5, "GetAuraDataBySpellName(u, <ชื่อจาก Spell ID>, 'HELPFUL') .spellId", function(u)
    if C_UnitAuras.GetAuraDataBySpellName == nil then return nil end
    local nm = C_Spell.GetSpellName(CTX.spellID)
    if nm == nil then return nil end
    if IsSecret(nm) then return nm end
    return Field(C_UnitAuras.GetAuraDataBySpellName(u, nm, "HELPFUL"), "spellId")
end, "ใช้ชื่อเวทจากช่อง Spell ID ด้านบน")

-- ============================================================
-- 6. Threat / Range
-- ============================================================
local c6 = Cat("6. Threat / Range")

U(c6, "UnitDetailedThreatSituation('player', u)", function(u)
    return UnitDetailedThreatSituation("player", u)
end, "[!] 5 ค่า: isTanking, status, scaledPct, rawPct, threatValue")
U(c6, "UnitThreatSituation('player', u)", function(u)
    return UnitThreatSituation("player", u)
end)
U(c6, "UnitInRange(u)", function(u) return UnitInRange(u) end,
    "ของ Blizzard — ใช้ได้เฉพาะเพื่อนร่วมกลุ่ม")
U(c6, "C_Spell.IsSpellInRange(spellID, u)", function(u)
    return C_Spell.IsSpellInRange(CTX.spellID, u)
end, "[!] HealSkill / HealPetSkill เทียบ == true / == false")
U(c6, "C_Item.IsItemInRange(itemID, u)", function(u)
    return C_Item.IsItemInRange(CTX.itemID, u)
end, "[!] RangeCheck.lua — SecretWhenInCombat เมื่อ unit เป็นเพื่อน")
U(c6, "GetUnitSpeed(u)", function(u) return GetUnitSpeed(u) end)

-- ============================================================
-- 7. Spell (ใช้ Spell ID จากช่อง input)
-- ============================================================
local c7 = Cat("7. Spell — ใช้ค่า Spell ID ในช่อง input ด้านบน")

G(c7, "C_Spell.GetSpellName(id)", function()
    return C_Spell.GetSpellName(CTX.spellID)
end)
G(c7, "C_Spell.GetSpellInfo(id) .name", function()
    return Field(C_Spell.GetSpellInfo(CTX.spellID), "name")
end)
G(c7, "C_Spell.GetSpellInfo(id) .castTime", function()
    return Field(C_Spell.GetSpellInfo(CTX.spellID), "castTime")
end, "[!] SpellCastType เทียบ > 0 เพื่อแยก instant / cast")
G(c7, "C_Spell.GetSpellInfo(id) .minRange, .maxRange", function()
    local info = C_Spell.GetSpellInfo(CTX.spellID)
    if info == nil then return nil end
    if IsSecret(info) then return info end
    return info.minRange, info.maxRange
end)
G(c7, "C_Spell.GetSpellCooldown(id)  [table]", function()
    local t = C_Spell.GetSpellCooldown(CTX.spellID)
    if t == nil then return nil end
    if IsSecret(t) then return t end
    return true
end, "[!] PlayerGCDBar.lua จดไว้ว่าทุก field ของ table นี้เป็น secret ตอน in-combat")
G(c7, "  .startTime", function()
    return Field(C_Spell.GetSpellCooldown(CTX.spellID), "startTime")
end, "[!] เทียบ > 0 เพื่อรู้ว่า GCD กำลังเดิน")
G(c7, "  .duration", function()
    return Field(C_Spell.GetSpellCooldown(CTX.spellID), "duration")
end)
G(c7, "  .isEnabled", function()
    return Field(C_Spell.GetSpellCooldown(CTX.spellID), "isEnabled")
end)
G(c7, "  .modRate", function()
    return Field(C_Spell.GetSpellCooldown(CTX.spellID), "modRate")
end)
G(c7, "C_Spell.GetSpellCooldownDuration(id):GetRemainingDuration()", function()
    if C_Spell.GetSpellCooldownDuration == nil then return nil end
    return DurCall(C_Spell.GetSpellCooldownDuration(CTX.spellID), "GetRemainingDuration")
end, "[!] ทางที่ถูกสำหรับ CD — แต่ค่าที่ได้ยังเป็น secret")
G(c7, "C_Spell.GetSpellCooldownDuration(id):GetRemainingPercent()", function()
    if C_Spell.GetSpellCooldownDuration == nil then return nil end
    return DurCall(C_Spell.GetSpellCooldownDuration(CTX.spellID), "GetRemainingPercent")
end, "[!] เขียนลง B byte ของ pixel ได้ตรงๆ แต่ห้ามเทียบ")
G(c7, "C_Spell.GetSpellCharges(id) .currentCharges", function()
    return Field(C_Spell.GetSpellCharges(CTX.spellID), "currentCharges")
end, "[!] เทียบ >= 1")
G(c7, "C_Spell.GetSpellCharges(id) .maxCharges", function()
    return Field(C_Spell.GetSpellCharges(CTX.spellID), "maxCharges")
end)
G(c7, "C_Spell.GetSpellChargeDuration(id):GetRemainingDuration()", function()
    if C_Spell.GetSpellChargeDuration == nil then return nil end
    return DurCall(C_Spell.GetSpellChargeDuration(CTX.spellID), "GetRemainingDuration")
end)
G(c7, "C_Spell.IsSpellUsable(id)", function()
    return C_Spell.IsSpellUsable(CTX.spellID)
end, "[!] คืน usable, noMana — CombatAssistIcon เทียบ == false")
G(c7, "C_Spell.IsCurrentSpell(id)", function()
    return C_Spell.IsCurrentSpell(CTX.spellID)
end)
G(c7, "C_Spell.IsSpellImportant(id)", function()
    if C_Spell.IsSpellImportant == nil then return nil end
    return C_Spell.IsSpellImportant(CTX.spellID)
end, "[!] pixel 11 isImportantSpell ของ TargetCastBar")
G(c7, "C_Spell.GetOverrideSpell(id)", function()
    return C_Spell.GetOverrideSpell(CTX.spellID)
end, "[!] SpellOverrideCache เทียบ overrideID ~= baseID")
G(c7, "C_Spell.SpellHasRange(id)", function()
    return C_Spell.SpellHasRange(CTX.spellID)
end)
G(c7, "C_Spell.DoesSpellExist(id)", function()
    return C_Spell.DoesSpellExist(CTX.spellID)
end)
G(c7, "C_Spell.GetSpellTexture(id)", function()
    return C_Spell.GetSpellTexture(CTX.spellID)
end)
G(c7, "C_SpellBook.IsSpellInSpellBook(id, PlayerBank, true)", function()
    if C_SpellBook.IsSpellInSpellBook == nil then return nil end
    local bank = 0
    if Enum ~= nil and Enum.SpellBookSpellBank ~= nil then
        bank = Enum.SpellBookSpellBank.Player
    end
    return C_SpellBook.IsSpellInSpellBook(CTX.spellID, bank, true)
end, "GeRODPS.IsSpellKnown (Util.lua) ใช้ตัวนี้")
G(c7, "C_SpellBook.FindBaseSpellByID(id)", function()
    if C_SpellBook.FindBaseSpellByID == nil then return nil end
    return C_SpellBook.FindBaseSpellByID(CTX.spellID)
end)
G(c7, "IsPlayerSpell(id)", function() return IsPlayerSpell(CTX.spellID) end)
G(c7, "GetSpellInfo(id)   [global legacy]", function()
    if GetSpellInfo == nil then return nil end
    return GetSpellInfo(CTX.spellID)
end)

-- ============================================================
-- 8. Item / Trinket (ใช้ Item ID จากช่อง input)
-- ============================================================
local c8 = Cat("8. Item / Trinket — ใช้ค่า Item ID ในช่อง input ด้านบน")

G(c8, "C_Item.GetItemCooldown(itemID)", function()
    return C_Item.GetItemCooldown(CTX.itemID)
end, "[!] คืน start, duration, enable — TrinketUse เทียบกับ GCD")
G(c8, "C_Item.GetItemSpell(itemID)", function()
    return C_Item.GetItemSpell(CTX.itemID)
end)
G(c8, "C_Item.GetItemInfo(itemID)  [1] name", function()
    return (C_Item.GetItemInfo(CTX.itemID))
end)
G(c8, "C_Item.GetItemCount(itemID)", function()
    return C_Item.GetItemCount(CTX.itemID)
end)
G(c8, "C_Item.GetItemInfoInstant(itemID)", function()
    return C_Item.GetItemInfoInstant(CTX.itemID)
end)
G(c8, "GetInventoryItemID('player', 13)", function()
    return GetInventoryItemID("player", 13)
end, "trinket slot 1")
G(c8, "GetInventoryItemID('player', 14)", function()
    return GetInventoryItemID("player", 14)
end, "trinket slot 2")

-- ============================================================
-- 9. Player state / instance / group
-- ============================================================
local c9 = Cat("9. Player state / instance / group")

G(c9, "GetSpecialization()", function() return GetSpecialization() end)
G(c9, "GetSpecializationInfo(GetSpecialization())", function()
    local s = GetSpecialization()
    if s == nil then return nil end
    if IsSecret(s) then return s end
    return GetSpecializationInfo(s)
end, "[!] PlayerInfo pixel 31 — เทียบ specID")
G(c9, "GetInstanceInfo()  [2] instanceType", function()
    return select(2, GetInstanceInfo())
end)
G(c9, "GetInstanceInfo()  [8] instanceID", function()
    return select(8, GetInstanceInfo())
end, "[!] CurrentInstance.lua PR2 slot — Map.db2 ID")
G(c9, "GetHaste()", function() return GetHaste() end)
G(c9, "IsMounted()", function() return IsMounted() end)
G(c9, "IsInGroup()", function() return IsInGroup() end)
G(c9, "IsInRaid()", function() return IsInRaid() end)
G(c9, "GetNumGroupMembers()", function() return GetNumGroupMembers() end)
G(c9, "GetActionInfo(1)", function() return GetActionInfo(1) end)
G(c9, "C_LossOfControl.GetActiveLossOfControlDataCount()", function()
    if C_LossOfControl == nil then return nil end
    if C_LossOfControl.GetActiveLossOfControlDataCount == nil then return nil end
    return C_LossOfControl.GetActiveLossOfControlDataCount()
end, "[!] PlayerCCHelper เทียบ n == 0")
G(c9, "GetActiveLossOfControlData(1) .locType", function()
    if C_LossOfControl == nil then return nil end
    if C_LossOfControl.GetActiveLossOfControlData == nil then return nil end
    return Field(C_LossOfControl.GetActiveLossOfControlData(1), "locType")
end, "[!] เทียบ == 'SCHOOL_INTERRUPT'")
G(c9, "GetActiveLossOfControlData(1) .displayText", function()
    if C_LossOfControl == nil then return nil end
    if C_LossOfControl.GetActiveLossOfControlData == nil then return nil end
    return Field(C_LossOfControl.GetActiveLossOfControlData(1), "displayText")
end, "[!] เทียบกับ LOSS_OF_CONTROL_DISPLAY_* 31 ตัว")
G(c9, "GetActiveLossOfControlData(1) .timeRemaining", function()
    if C_LossOfControl == nil then return nil end
    if C_LossOfControl.GetActiveLossOfControlData == nil then return nil end
    return Field(C_LossOfControl.GetActiveLossOfControlData(1), "timeRemaining")
end)
G(c9, "C_AssistedCombat.GetNextCastSpell(false)", function()
    if C_AssistedCombat == nil then return nil end
    if C_AssistedCombat.GetNextCastSpell == nil then return nil end
    return C_AssistedCombat.GetNextCastSpell(false)
end, "[!] CombatAssistIcon pixel 1 IROCode — secret = resolve keybind ไม่ได้")
G(c9, "C_AssistedCombat.GetRotationSpells()  [#]", function()
    if C_AssistedCombat == nil then return nil end
    if C_AssistedCombat.GetRotationSpells == nil then return nil end
    local t = C_AssistedCombat.GetRotationSpells()
    if t == nil then return nil end
    if IsSecret(t) then return t end
    return #t
end)
G(c9, "C_ChallengeMode.GetActiveKeystoneInfo()  [1] level", function()
    if C_ChallengeMode == nil then return nil end
    if C_ChallengeMode.GetActiveKeystoneInfo == nil then return nil end
    return (C_ChallengeMode.GetActiveKeystoneInfo())
end)
G(c9, "C_NamePlate.GetNamePlateForUnit('nameplate1') ~= nil", function()
    if C_NamePlate == nil then return nil end
    local f = C_NamePlate.GetNamePlateForUnit("nameplate1")
    if f == nil then return nil end
    if IsSecret(f) then return f end
    return true
end)
G(c9, "C_DamageMeter.GetAvailableCombatSessions()  [#]", function()
    if C_DamageMeter == nil then return nil end
    if C_DamageMeter.GetAvailableCombatSessions == nil then return nil end
    local t = C_DamageMeter.GetAvailableCombatSessions()
    if t == nil then return nil end
    if IsSecret(t) then return t end
    return #t
end, "[!] C_DamageMeter เป็น RESTRICTED — เรียกใน combat lockdown ไม่ได้")

TOOL.SecretAPIProbes = cats
