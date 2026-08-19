--[[
    NPAuraLiveView.lua — ดู Aura ของ nameplate แบบ **อ่านตลอดเวลา** (UI เรียบ)

    ── สเปกจาก user (2026-08-18) ────────────────────────────────────────────
      · อ่านด้วย "วิธีอ่านจาก Nameplate" เท่านั้น (reader ตัวจริงของ addon —
        GeRODPS.GetAllAuraFromSetOfNamePlate) ไม่มีการทดสอบ Lua API อื่นปน
      · 1 หน้า = 2 คอลัมน์ = nameplate 2 ตัว · มีหลายหน้าเมื่อ nameplate เยอะ
      · status in-combat เขียนไว้ข้างบน
      · โชว์แค่ Aura Spell ID — และต้องเป็น **FontString** เพราะค่าเป็น secret:
        FontString render ค่าจริงของ secret ได้ (หลัก Secret Peek) ส่วน
        multi-line EditBox แสดง secret ไม่ได้
      · เกิดจากผลวัด: เปิด option Plater "Show Debuffs Blizzard Nameplates show"
        (aura_show_debuff_as_blizzard_does) แล้ว DebuffListFrame ของ Blizzard
        populate ใต้ Plater ⇒ reader เดิมอ่านได้เลย — tool นี้ไว้เฝ้าดูสด ๆ
        (สลับ option ใน Plater แล้วเห็นผลทันทีในนี้)

    ── กติกา secret ──────────────────────────────────────────────────────────
      · spellID เป็น secret ⇒ ทำได้แค่ ".." concat / tostring แล้ว SetText
        ห้ามเทียบ/วัดความยาว/เก็บเป็น key
      · แถวเป็น FontString pool (reuse) — ไม่มี EditBox ในหน้าต่างนี้เลย
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local TITLE_H  = 28
local SIDE_PAD = 12
local COLS     = 2        -- user เคาะ: หน้าละ 2 nameplate
local MAX_ROWS = 16       -- แถว aura ต่อคอลัมน์ (pool)
local ROW_H    = 15
local TICK_SEC = 0.3

local frame, statusFS, pageLabel, btnPrev, btnNext
local btnOverride, btnForce
local lastAction = ""     -- ผลของปุ่มล่าสุด (โชว์บนจอ + print ลงแชต)
local cols = {}           -- [c] = { header = FS, rows = {FS...} }
local page = 1

-- ============================================================
-- Platynator fix — สมัคร UNIT_AURA คืนให้เฟรม Blizzard
-- ============================================================
-- ซอร์ส Platynator (Display/Initialize.lua:869): ทุก NAME_PLATE_UNIT_ADDED มัน
--   SetParent(hiddenFrame) + UnitFrame:UnregisterAllEvents()  ← ไม่มีเงื่อนไข/ไม่มี option
-- แต่ **ไม่มี hook Show / ไม่รื้อซ้ำ** (ต่างจาก Plater) ⇒ เราสมัคร event คืน
-- ทีหลังได้เลย ไม่มีใครมาสู้ · เฟรมยังซ่อนอยู่ (parent เป็น hiddenFrame) ซึ่งดี:
-- ไม่มีภาพซ้อน และเคส Plater พิสูจน์แล้วว่า "ซ่อน + event มา = ลิสต์ populate"
-- ⚠ UnregisterAllEvents ถอนแค่การสมัคร ไม่แตะ OnEvent handler / self.unit
-- ⚠ หลัง fix ลิสต์จะเริ่มขยับเมื่อ aura ของ unit นั้น "เปลี่ยน" ครั้งถัดไป
--   (ใส่ DoT ใหม่ / รอ tick) — ไม่ได้ populate ย้อนหลังทันที
local platyFix = false
local fixCount = 0        -- จำนวน plate ที่สมัครคืนสำเร็จ (เฉพาะที่หายจริง)
local fixerFrame          -- รับ NAME_PLATE_UNIT_ADDED เพื่อ fix plate ใหม่

--- ตรวจว่าใช้ nameplate ของใครอยู่ — "Plater" / "Platynator" / "Blizzard"
local function DetectNPUI()
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        local okP, p = pcall(C_AddOns.IsAddOnLoaded, "Plater")
        if okP and p then return "Plater" end
        local okY, y = pcall(C_AddOns.IsAddOnLoaded, "Platynator")
        if okY and y then return "Platynator" end
    end
    return "Blizzard"
end

local function FixUnitAuraEvents(unit)
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return end
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    local uf = plate and plate.UnitFrame
    if uf == nil then return end
    local okE, reg = pcall(uf.IsEventRegistered, uf, "UNIT_AURA")
    if okE and reg == true then return end     -- สมัครอยู่แล้ว (Blizzard UI) = no-op
    if pcall(uf.RegisterUnitEvent, uf, "UNIT_AURA", unit) then
        fixCount = fixCount + 1
    end
end

local function FixAllExisting()
    for i = 1, 30 do
        local u = "nameplate" .. i
        if UnitExists(u) then FixUnitAuraEvents(u) end
    end
end

local function EnsureFixer()
    if fixerFrame then return end
    fixerFrame = CreateFrame("Frame")
    fixerFrame:SetScript("OnEvent", function(_, _, unit)
        if not platyFix then return end
        -- หน่วง 1 เฟรม — ให้ handler ของ Platynator (ตัวถอน) วิ่งจบก่อนเสมอ
        C_Timer.After(0, function()
            if platyFix and unit then FixUnitAuraEvents(unit) end
        end)
    end)
end

local function SetPlatyFix(on)
    platyFix = on and true or false
    EnsureFixer()
    if platyFix then
        fixerFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        FixAllExisting()
    else
        fixerFrame:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
    end
end

-- ============================================================
-- ทาง 2: ตั้ง option ของ Plater ให้เอง + บังคับให้ plate เกิดใหม่
-- ============================================================
-- ทำไมต้องมาทางนี้: auto-fix ของเรา (สมัคร UNIT_AURA คืน) **ใช้ไม่ได้** เพราะ Plater
-- ทำ 2 อย่างตอนซ่อนเฟรม ([Plater.lua:4645-4661] Plater.OnRetailNamePlateShow):
--     self:UnregisterAllEvents()               -- (A) ถอนการสมัคร event
--     CompactUnitFrame_UnregisterEvents(self)  -- (B) ถอน **OnEvent handler**
-- เราคืนแค่ (A) ⇒ event ยิงเข้ามาแล้วไม่มี handler ให้ทำงาน ⇒ ลิสต์ไม่ populate
-- (คอมเมนต์ของ Plater เองบรรทัด 4647 เขียนไว้ว่า "only removes event handler functions")
-- ทั้ง (A) และ (B) ถูก gate ด้วย option เดียวกัน ⇒ ตั้ง option = ไม่ถอดตั้งแต่แรก
--
-- ⚠ **นี่คือการเขียนทับ setting ใน addon ของคนอื่น** — จึงอยู่ใน Tools เป็นปุ่มที่ user
--   กดเอง เท่านั้น · addon จริงยังไม่ทำอะไรทั้งสิ้นจนกว่าจะได้ผลวัดว่าคุมได้ 100%

local function PlaterProfile()
    local P = _G.Plater
    if P == nil or P.db == nil then return nil end
    return P.db.profile
end

local function GetCV(k)
    if C_CVar and C_CVar.GetCVar then
        local ok, v = pcall(C_CVar.GetCVar, k)
        if ok then return v end
    end
    return nil
end

local function SetCV(k, v)
    if C_CVar and C_CVar.SetCVar then return pcall(C_CVar.SetCVar, k, v) end
    return false
end

--- ปุ่ม 1 — สลับค่า option ของ Plater แล้ว **อ่านกลับ** เพื่อยืนยันว่าเขียนติดจริง
--- ไม่ทำอย่างอื่นเลย (ไม่ refresh ไม่ respawn) — จะได้รู้ว่าลำพังการเขียนพอไหม
local function OverrideOption()
    local prof = PlaterProfile()
    if prof == nil then
        lastAction = "|cffff5555Override: ไม่มี Plater / อ่าน profile ไม่ได้|r"
        print("|cffffcc00[NP Aura Live]|r " .. lastAction)
        return
    end
    local KEY = "aura_show_debuff_as_blizzard_does"
    local before = prof[KEY]
    local want = (before ~= true)
    local okW = pcall(function() prof[KEY] = want end)
    local after = prof[KEY]
    -- Plater ตัดสินใจ strip จาก db **ตรง ๆ** (Plater.lua:4648) แต่ยังมี upvalue
    -- DB_AURA_SHOW_AS_BLIZZARD ที่ใช้ที่อื่น (Plater_Auras.lua:4437) -> sync ให้ตรงกัน
    local okR = false
    if _G.Plater and _G.Plater.RefreshDBUpvalues then
        okR = pcall(_G.Plater.RefreshDBUpvalues)
    end
    lastAction = "Override: " .. tostring(before) .. " -> " .. tostring(want)
        .. "  · เขียน " .. (okW and "ok" or "|cffff5555ERR|r")
        .. "  · อ่านกลับได้ " .. (after == want and "|cff44ff44ตรง|r" or "|cffff5555ไม่ตรง|r")
        .. "  · RefreshDBUpvalues " .. (okR and "ok" or "ข้าม")
    print("|cffffcc00[NP Aura Live]|r " .. lastAction)
end

--- ปุ่ม 2 — บังคับให้ plate ที่มีอยู่แล้ว "เกิดใหม่"
--- user วัดแล้ว: เปลี่ยน option แล้วต้อง spawn nameplate ใหม่ถึงมีผล (กด V / เดินออก-เข้า / reload)
--- ⇒ ลอง 2 ระดับแล้วรายงานทีละขั้น จะได้รู้ว่าอันไหนพอ
---   1) Plater.UpdateAllPlates()  = สิ่งที่ปุ่ม option ของ Plater เองเรียก
---      (ถ้าพอ user คงไม่ต้องกด V — แต่ user บอกว่าต้องกด ⇒ คาดว่าไม่พอ)
---   2) สลับ CVar nameplateShowEnemies = สิ่งที่ปุ่ม V ทำจริง ⇒ plate ถูกสร้างใหม่ทั้งหมด
local function ForceUpdateNP()
    local msgs = {}
    local P = _G.Plater
    if P and P.RefreshDBUpvalues then
        msgs[#msgs + 1] = "RefreshDBUpvalues " .. (pcall(P.RefreshDBUpvalues) and "ok" or "ERR")
    end
    if P and P.UpdateAllPlates then
        msgs[#msgs + 1] = "UpdateAllPlates " .. (pcall(P.UpdateAllPlates) and "ok" or "ERR")
    else
        msgs[#msgs + 1] = "UpdateAllPlates ไม่มี"
    end

    local KEY = "nameplateShowEnemies"
    local cur = GetCV(KEY)
    if cur == nil then
        msgs[#msgs + 1] = "|cffff9a9aอ่าน CVar ไม่ได้|r"
    elseif InCombatLockdown() then
        -- ไม่ลองใน combat — CVar บางตัวถูกบล็อก และถ้าพลาดคือ nameplate หายกลางไฟต์
        msgs[#msgs + 1] = "|cffff9a9aCVar respawn ข้าม (in combat)|r"
    else
        local okOff = SetCV(KEY, "0")
        C_Timer.After(0.3, function() SetCV(KEY, cur) end)
        msgs[#msgs + 1] = "CVar respawn " .. (okOff and "ok" or "|cffff5555ERR|r")
            .. " (คืนเป็น " .. tostring(cur) .. " ใน 0.3s)"
    end

    lastAction = "Force: " .. table.concat(msgs, " · ")
    print("|cffffcc00[NP Aura Live]|r " .. lastAction)
end

local function SyncControlButtons()
    if btnOverride == nil then return end
    local prof = PlaterProfile()
    if prof == nil then
        btnOverride:SetText("Override: ไม่มี Plater")
        btnOverride:SetEnabled(false)
        return
    end
    btnOverride:SetEnabled(true)
    if prof.aura_show_debuff_as_blizzard_does == true then
        btnOverride:SetText("Plater Opt = ON  (กดเพื่อปิด)")
    else
        btnOverride:SetText("Plater Opt = OFF  (กดเพื่อเปิด)")
    end
end

--- event UNIT_AURA ของเฟรม Blizzard ยังสมัครอยู่ไหม (ตัวชี้วัดผลของ fix)
local function UnitAuraEventOn(unit)
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    local uf = plate and plate.UnitFrame
    if uf == nil then return nil end
    local ok, v = pcall(uf.IsEventRegistered, uf, "UNIT_AURA")
    if not ok then return nil end
    return v == true
end

-- ============================================================
-- ข้อมูล
-- ============================================================

--- รายชื่อ nameplate ที่มีตัวตน (เรียง index) — จับคู่ลงหน้า ตามลำดับนี้
local function ExistingUnits()
    local units = {}
    for i = 1, 30 do
        local u = "nameplate" .. i
        if UnitExists(u) then units[#units + 1] = u end
    end
    return units
end

--- "unit นี้คือ target ไหม" — เทียบเฟรม (UnitIsUnit เป็น secret boolean ห้าม if-test)
local function IsTargetUnit(u)
    if not UnitExists("target") then return nil end
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil end
    local pT = C_NamePlate.GetNamePlateForUnit("target")
    local pU = C_NamePlate.GetNamePlateForUnit(u)
    if pT == nil or pU == nil then return nil end
    return pT == pU
end

local KIND_TAG = { debuff = "[d]", buff = "[b]", cc = "[cc]", unknown = "[?]" }

--- นับลูกของ list frame ของ Blizzard ตรง ๆ — แยกให้ออกว่า "ลิสต์ไหนว่าง"
--- (reader รวมทุกลิสต์เป็นก้อนเดียว ⇒ ถ้า buff ว่างจะดูไม่ออกจากผลรวม)
--- ใช้ตอนลอง option ของ Plater: ติ๊กแล้วลิสต์ไหนขยับ
local LIST_KEYS = {
    { field = "DebuffListFrame",        tag = "debuff" },
    { field = "BuffListFrame",          tag = "buff" },
    { field = "CrowdControlListFrame",  tag = "cc" },
}

local function ListCounts(unit)
    local out = { debuff = "-", buff = "-", cc = "-" }
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return out end
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if plate == nil then return out end
    local uf = plate.UnitFrame
    if uf == nil then return out end
    local af = uf.AurasFrame or uf.NameplateAurasFrame
    if af == nil then return out end
    for _, L in ipairs(LIST_KEYS) do
        local lf = af[L.field]
        if lf ~= nil and lf.GetLayoutChildren then
            local ok, kids = pcall(lf.GetLayoutChildren, lf)
            if ok and type(kids) == "table" then out[L.tag] = tostring(#kids) end
        end
    end
    return out
end

-- ============================================================
-- วาด
-- ============================================================

local function UpdateStatus()
    local combat = InCombatLockdown()
    local parts = combat and "|cffff5555IN COMBAT|r" or "|cff44ff44out of combat|r"

    -- บรรทัด detect — ตอบคำถาม "ใช้ UI ไหนอยู่ + fix ทำงานไหม"
    local ui = DetectNPUI()
    parts = parts .. "   ·   UI = |cffffd200" .. ui .. "|r"
    if ui ~= "Blizzard" then
        parts = parts .. "  · fix=" .. (platyFix and "|cff44ff44on|r" or "|cffff9a9aoff|r")
        if fixCount > 0 then
            parts = parts .. " |cff44ff44(ซ่อมแล้ว " .. fixCount .. " plate)|r"
        end
    end
    if ui == "Platynator" then
        statusFS:SetText(parts .. "   |cff888888(ถอน event ทุก plate — ไม่มี option ให้ตั้ง)|r")
        return
    end
    if ui == "Blizzard" then
        statusFS:SetText(parts .. "   |cff888888(อ่านได้ตามปกติ)|r")
        return
    end

    local P = _G.Plater
    local prof = P and P.db and P.db.profile
    if prof == nil then
        statusFS:SetText(parts)
        return
    end

    -- option ของ Plater ที่เกี่ยวกับ aura — สลับทีละตัวแล้วดูว่าลิสต์ไหนขยับ
    -- (อ่านอย่างเดียว — ไม่เคยเขียน profile ของ user)
    local OPTS = {
        { k = "aura_show_debuff_as_blizzard_does", n = "as-blizzard(debuff)" },
        { k = "aura_show_dispellable",             n = "dispellable" },
        { k = "aura_show_buff_on_enemy_npc",       n = "buff-enemy-npc" },
        { k = "aura_show_buff_by_the_player",      n = "buff-by-you" },
        { k = "aura_show_crowdcontrol",            n = "cc" },
        { k = "debuff_show_cc",                    n = "cc-in-debuff" },
    }
    local line = "Plater:"
    for _, o in ipairs(OPTS) do
        local v = prof[o.k]
        line = line .. "  " .. o.n .. "="
            .. (v == true and "|cff44ff44on|r" or "|cffff9a9a" .. tostring(v) .. "|r")
    end
    if lastAction ~= "" then line = line .. "\n" .. lastAction end
    statusFS:SetText(parts .. "\n" .. line)
end

local function UpdateColumn(c, unit)
    local col = cols[c]
    if unit == nil then
        col.header:SetText("|cff888888(ไม่มี nameplate ช่องนี้)|r")
        for _, fs in ipairs(col.rows) do fs:SetText("") end
        return
    end

    local name = tostring(UnitName(unit))
    local tgt = IsTargetUnit(unit)
    local tgtTxt = ""
    if tgt == true then
        tgtTxt = "  |cff44ff44<< target|r"
    end
    local lc = ListCounts(unit)
    local function paint(n)
        if n == "-" then return "|cff666666-|r" end
        if n == "0" then return "|cffff9a9a0|r" end
        return "|cff44ff44" .. n .. "|r"
    end
    -- ev = UNIT_AURA ยังสมัครอยู่ไหม — ตัวบอกว่า addon nameplate ถอน event หรือ fix แล้ว
    local ev = UnitAuraEventOn(unit)
    local evTxt = (ev == true and "|cff44ff44on|r") or (ev == false and "|cffff5555off|r") or "|cff666666?|r"
    col.header:SetText(("|cffffd200%s|r  %s%s\n  list: debuff %s · buff %s · cc %s · ev=%s")
        :format(unit, name, tgtTxt, paint(lc.debuff), paint(lc.buff), paint(lc.cc), evTxt))

    local recs = {}
    if GeRODPS and GeRODPS.GetAllAuraFromSetOfNamePlate then
        local ok, r = pcall(GeRODPS.GetAllAuraFromSetOfNamePlate, { unit })
        if ok and type(r) == "table" then recs = r end
    end

    for i = 1, MAX_ROWS do
        local fs = col.rows[i]
        local r = recs[i]
        if r == nil then
            if i == 1 then
                fs:SetText("|cff666666(ไม่มี aura)|r")
            else
                fs:SetText("")
            end
        else
            -- spellID เป็น secret — ".." concat ได้ · FontString render ค่าจริงได้
            local tag = KIND_TAG[r.kind] or "[?]"
            fs:SetText("  #" .. i .. "  " .. tag .. "  spellID = " .. tostring(r.spellID))
        end
    end
    if #recs > MAX_ROWS and col.rows[MAX_ROWS] then
        col.rows[MAX_ROWS]:SetText(("  ... อีก %d ตัว (เกิน %d แถว)"):format(#recs - MAX_ROWS, MAX_ROWS))
    end
end

local function Tick()
    if frame == nil or not frame:IsShown() then return end
    UpdateStatus()
    -- sync ทุก tick — user อาจไปสลับ option ที่แผงของ Plater เอง ป้ายบนปุ่มต้องตามทัน
    SyncControlButtons()

    local units = ExistingUnits()
    local totalPages = math.ceil(#units / COLS)
    if totalPages < 1 then totalPages = 1 end
    if page > totalPages then page = totalPages end
    if page < 1 then page = 1 end

    for c = 1, COLS do
        UpdateColumn(c, units[(page - 1) * COLS + c])
    end

    pageLabel:SetText(("หน้า %d/%d  ·  nameplate ทั้งหมด %d"):format(page, totalPages, #units))
    btnPrev:SetEnabled(page > 1)
    btnNext:SetEnabled(page < totalPages)
end

-- ============================================================
-- UI
-- ============================================================
local function LayoutColumns()
    if btnOverride == nil then return end   -- ยังสร้างปุ่มไม่เสร็จ (BuildFrame ครั้งแรก)
    local w = frame:GetWidth() - SIDE_PAD * 2
    local colW = (w - 10) / COLS
    for c = 1, COLS do
        local x = SIDE_PAD + (c - 1) * (colW + 10)
        local col = cols[c]
        col.header:ClearAllPoints()
        col.header:SetPoint("TOPLEFT", btnOverride, "BOTTOMLEFT", x - SIDE_PAD, -10)
        col.header:SetWidth(colW)
        for i, fs in ipairs(col.rows) do
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", col.header, "BOTTOMLEFT", 0, -6 - (i - 1) * ROW_H)
            fs:SetWidth(colW)
        end
    end
end

local function BuildFrame()
    if frame then return frame end
    frame = CreateFrame("Frame", "GeRODPSToolsNPAuraLiveView", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(700, 460)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    frame:SetFrameStrata("HIGH")
    if frame.TitleText then frame.TitleText:SetText("NP Aura Live View") end

    -- status บนสุด — user เคาะ: in-combat ต้องอยู่ข้างบน
    statusFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    statusFS:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 8))
    statusFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + 8))
    statusFS:SetJustifyH("LEFT")
    statusFS:SetText("...")

    btnPrev = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnPrev:SetSize(40, 22)
    btnPrev:SetPoint("TOPLEFT", statusFS, "BOTTOMLEFT", 0, -8)
    btnPrev:SetText("<")
    btnPrev:SetScript("OnClick", function() page = page - 1; Tick() end)

    btnNext = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnNext:SetSize(40, 22)
    btnNext:SetPoint("LEFT", btnPrev, "RIGHT", 6, 0)
    btnNext:SetText(">")
    btnNext:SetScript("OnClick", function() page = page + 1; Tick() end)

    pageLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageLabel:SetPoint("LEFT", btnNext, "RIGHT", 12, 0)
    pageLabel:SetText("")

    -- ปุ่มเดียวจบ: detect ว่าใช้ UI ไหน + เปิด fix (สมัคร UNIT_AURA คืนทุก plate
    -- ที่ถูกถอน — generic: Blizzard = no-op · Plater/Platynator = ซ่อม)
    local btnFix = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnFix:SetSize(200, 22)
    btnFix:SetPoint("LEFT", pageLabel, "RIGHT", 16, 0)
    local function syncFixBtn()
        if platyFix then
            btnFix:SetText("Fix: ON — " .. DetectNPUI() .. " (กดปิด)")
        else
            btnFix:SetText("Auto Detect + Fix")
        end
    end
    btnFix:SetScript("OnClick", function()
        SetPlatyFix(not platyFix)
        syncFixBtn()
        Tick()
    end)
    syncFixBtn()

    -- ยิง Tooltip Probe ใส่ unit ของคอลัมน์นั้นตรง ๆ (ตอบคำถาม "ดึง tooltip ของ
    -- aura บน nameplate ได้ไหม / spellID ที่ได้เป็น plain หรือ secret")
    -- ⚠ ต้องอ่าน unit **สดตอนคลิก** — user เปลี่ยนหน้าได้ตลอด ห้าม capture
    local probeBtns = {}
    for c = 1, COLS do
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(112, 22)
        if c == 1 then
            b:SetPoint("LEFT", btnFix, "RIGHT", 10, 0)
        else
            b:SetPoint("LEFT", probeBtns[c - 1], "RIGHT", 4, 0)
        end
        b:SetText("Tooltip #" .. c)
        b:SetScript("OnClick", function()
            local units = ExistingUnits()
            local u = units[(page - 1) * COLS + c]
            if u == nil then
                print("|cffffcc00[GeRODPS Tools]|r คอลัมน์ " .. c .. " ไม่มี nameplate")
                return
            end
            if TOOL.ShowNPAuraTooltipProbe then TOOL.ShowNPAuraTooltipProbe(u) end
        end)
        probeBtns[c] = b
    end

    -- แถวปุ่มที่ 2 — ทาง 2 (คุม Plater ตรง ๆ) · แยก 2 ปุ่มเพราะเป็นคนละคำถาม
    btnOverride = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnOverride:SetSize(210, 22)
    btnOverride:SetPoint("TOPLEFT", btnPrev, "BOTTOMLEFT", 0, -4)
    btnOverride:SetText("Plater Opt")
    btnOverride:SetScript("OnClick", function()
        OverrideOption(); SyncControlButtons(); Tick()
    end)

    btnForce = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnForce:SetSize(190, 22)
    btnForce:SetPoint("LEFT", btnOverride, "RIGHT", 6, 0)
    btnForce:SetText("Force Update Nameplate")
    btnForce:SetScript("OnClick", function()
        ForceUpdateNP(); Tick()
    end)
    SyncControlButtons()

    for c = 1, COLS do
        local col = { rows = {} }
        col.header = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        col.header:SetJustifyH("LEFT")
        col.header:SetSpacing(2)          -- header มี 2 บรรทัด (ชื่อ + จำนวนต่อลิสต์)
        for i = 1, MAX_ROWS do
            local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            col.rows[i] = fs
        end
        cols[c] = col
    end
    LayoutColumns()

    frame:SetResizable(true)
    frame:SetResizeBounds(480, 320)
    local resize = CreateFrame("Button", nil, frame)
    resize:SetSize(16, 16)
    resize:SetPoint("BOTTOMRIGHT", -4, 4)
    resize:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    resize:SetPushedTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Down")
    resize:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then frame:StartSizing("BOTTOMRIGHT") end
    end)
    resize:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then frame:StopMovingOrSizing(); LayoutColumns() end
    end)
    frame:SetScript("OnSizeChanged", function() if cols[1] then LayoutColumns() end end)

    frame:SetScript("OnUpdate", (function()
        local acc = 0
        return function(_, dt)
            acc = acc + dt
            if acc >= TICK_SEC then acc = 0; Tick() end
        end
    end)())

    return frame
end

function TOOL.ShowNPAuraLiveView()
    local f = BuildFrame()
    if f:IsShown() then f:Hide() else f:Show(); Tick() end
end

TOOL.RegisterTool("NP Aura Live View (spellID · อ่านตลอดเวลา)", TOOL.ShowNPAuraLiveView)
