--[[
    GeRODPS_Tools / PlayerAuraProbe.lua

    "Player Aura Probe" — ตอบคำถามเดียว: **จาก BuffFrame / DebuffFrame ของ player
    (Route B) เราดึงอะไรออกมาได้บ้าง เพื่อชุบชีวิต DefPlayerDebuff (slot 6) ที่ตาย
    เพราะ aura_present_v3 ใช้ C_UnitAuras**

    ผลวัดรอบแรก (2026-08-18 · in combat · ShouldAurasBeSecret=true):
      ✅ frame.auraInfo อ่านได้ — texture/count/duration/expirationTime/timeMod
         เป็น secret แต่ render เลขจริงได้ (= ผ่าน STS font hack ได้แน่)
      ✅ index เป็น **plain** (ไม่มีป้าย [S]) — ใช้เป็น arg ของ API ได้
      ❌ arithmetic บน secret THROW ตามคาด (expirationTime-GetTime, texture+0)
      ⚠ การเทียบ debuffType ตอนแรกวัดกับแถวที่ debuffType = nil — ไม่พิสูจน์อะไร
         (รอบนี้หาแถวที่ debuffType ≠ nil ก่อนค่อยเทียบ)
      ⚠ ยังไม่เจอ spellID — แถวปกติมีแค่ texture ⇒ รอบนี้เพิ่มหมวด "ล่า spellID"

    ผลวัดรอบสอง (2026-08-18 · in combat · debuff Bleed ติดตัว):
      ✅ debuffType render ได้ ("Bleed[S]") + ".." concat ได้ → ส่งคำ dispel type
         ผ่าน STS font hack ให้ AHK ได้เหมือน v3 เดิม (รวม "Bleed" ตรงจากเกม!)
      ❌ debuffType == "Magic" THROW — เทียบ string secret ใน Lua ไม่ได้
      ❌ C_TooltipInfo.GetUnitBuff/GetUnitDebuff (index) THROW — tooltip-by-index ตายด้วย
      ❌ timeLeft/exp arithmetic THROW → remain ต้องให้ AHK ลบ (exp เป็นวินาที + now)
      ⚠ buff ถาวร: ปุ่ม timeLeft = nil → writer จริงใช้ auraInfo rows ไม่ใช่ปุ่ม
      ✅ รอบสาม (2026-08-18): scanning tooltip ของเราเอง — SetUnitAura **ไม่ throw**
         data.id = spellID จริง (367521 = Bone Bolt · iconID 135537 ตรงกับ texture ในแถว
         · user ยืนยันด้วย GetSpellInfo) + TextLeft1 = ชื่อเวท
         ⇒ ทางนี้คือขา identity ของ DefPlayerDebuff v2

    ** `count` = **stack จริง** — source เขียน `count = auraData.applications`
       ทั้งฝั่ง buff (BuffFrame.lua:655) และ debuff (:770) — ไม่ต้องเดา
       ⚠ ยกเว้นแถว TempEnchant ที่ count = chargesRemaining (จำนวนครั้ง ไม่ใช่ stack)

    ** `btn:GetID()` — วัดเจอทั้ง nil และ 16 (2026-08-18) · source อธิบายครบ:
       `AuraButtonMixin:GetID()` (BuffFrame.lua:1105) คืน `self.buttonInfo.ID`
       และ field `ID` ถูกเซ็ต**ที่เดียว** คือแถว TempEnchant (`ID = slot`, :690)
       ⇒ **nil = ออร่าจริง** · **16/17/18 = inventory slot ของอาวุธ** (MAINHAND/OFFHAND/RANGED)
       = ปุ่ม rune/oil/poison บนอาวุธ **ไม่ใช่ aura instance ID**
       ⇒ มีประโยชน์: Blizzard เองใช้ `not self:GetID()` เป็นตัวแยกออร่าจาก enchant (:975)
       ⇒ **writer v2 ต้องข้ามแถวที่ ID ~= nil / auraType == "TempEnchant"**
         (แถวนั้นไม่มี `index` ด้วย ⇒ SetUnitAura เรียกไม่ได้ ต้องข้ามอยู่ดี)

    ที่มาของ field (source dump bfsrc/Blizzard_BuffFrame/BuffFrame.lua):
      · frame.auraInfo[]  = { auraType, debuffType(=dispelName!), index, texture,
                              count, duration, expirationTime, timeMod }  — ไม่มี spellId
      · frame.auraFrames[] = ปุ่ม (ปนกับ anchor · isAuraAnchor)
      · btn.buttonInfo / btn.timeLeft (Blizzard คำนวณ remain ให้ทุกเฟรม)
      · DebuffFrame.deadlyDebuffInfo[] = เฉพาะ deadly — มี spellID + auraInstanceID

    ⚠ ตอนกด Probe: **ต้องอยู่ใน combat + มี buff/debuff ติดตัวจริง**
      การเทียบ debuffType ต้องมี debuff ที่ dispel ได้ติดตัว (เช่น magic debuff ในดัน)
    ⚠ อ่านอย่างเดียว ห่อ pcall ทุกจุด · FontString เท่านั้น (copy = unmask)
    ⚠ secret string ห้าม table.concat / :sub / :gsub — ต่อด้วย .. เท่านั้น (เจอจริงรอบแรก)
]]

local TOOL = GeRODPS_Tools

local NL = string.char(10)

-- ============================================================
-- helpers
-- ============================================================

local function IsSecret(v)
    if issecretvalue ~= nil then
        local ok, r = pcall(issecretvalue, v)
        if ok and r == true then return true end
    end
    return false
end

--- render ค่าอะไรก็ได้ (secret ก็ได้ — FontString วาดได้) + ป้าย [S]
local function PeekVal(v)
    if v == nil then return "nil" end
    local tag = IsSecret(v) and "|cffffcc55[S]|r" or ""
    local ok, res = pcall(function() return "" .. tostring(v) end)
    if ok then return res .. tag end
    return "<เรนเดอร์ไม่ได้>" .. tag
end

local function ShortErr(e)
    -- e เป็น error message จริง (ไม่ secret) — gsub/sub ได้
    return (tostring(e):gsub("\n.*", ""):sub(1, 120))
end

--- tier-2: ลอง op ใน pcall — ⚠ ผลอาจเป็น secret string ห้ามเอาไป :sub ต่อ
local function TryOp(label, fn)
    local ok, r = pcall(fn)
    if ok then
        return "   |cff44ff44ได้:|r " .. label .. " = " .. PeekVal(r)
    end
    return "   |cffff9a9aTHROW:|r " .. label .. " — " .. ShortErr(r)
end

--- ต่อ out เป็นสตริงเดียว — ห้าม table.concat (บรรทัดอาจเป็น secret string)
local function JoinLines(out)
    local t = ""
    for _, line in ipairs(out) do
        t = t .. line .. NL
    end
    return t
end

-- ID = inventory slot ของแถว TempEnchant (ไม่มีในแถวออร่าจริง) — เอามาคัดแถวทิ้ง
local ROW_FIELDS = { "auraType", "debuffType", "index", "ID", "texture", "count",
                     "duration", "expirationTime", "timeMod", "auraInstanceID",
                     "spellID", "hideUnlessExpanded" }
local BTN_FIELDS = { "auraType", "timeLeft", "hasValidInfo", "isExample",
                     "isAuraAnchor", "deadlyInstanceID" }

local function DumpKnown(t, fields, indent, out)
    local seen = {}
    for _, k in ipairs(fields) do
        seen[k] = true
        if t[k] ~= nil then
            out[#out + 1] = indent .. k .. " = " .. PeekVal(t[k])
        end
    end
    local extra = {}
    local ok = pcall(function()
        for k in pairs(t) do
            if type(k) == "string" and not seen[k] then extra[#extra + 1] = k end
        end
    end)
    if ok and #extra > 0 then
        table.sort(extra)
        out[#out + 1] = indent .. "|cff888888key อื่น: " .. table.concat(extra, ", ") .. "|r"
    end
end

--- ปุ่มแรกที่แสดงอยู่และไม่ใช่ anchor (คืน btn หรือ nil)
local function FirstShownButton(f)
    local btns = f and f.auraFrames
    if type(btns) ~= "table" then return nil end
    for i = 1, #btns do
        local b = btns[i]
        if type(b) == "table" then
            local anchor = b.isAuraAnchor
            local skipAnchor = (anchor == true) and not IsSecret(anchor)
            local okV, sv = pcall(function() return b:IsShown() end)
            if not skipAnchor and okV and sv == true then return b, i end
        end
    end
    return nil
end

-- ============================================================
-- probe ต่อเฟรม (คอลัมน์ 1 = BuffFrame · คอลัมน์ 2 = DebuffFrame)
-- ============================================================

local MAX_ROWS = 6
local MAX_BTNS = 3

local function ProbeFrame(frameName, out)
    local f = _G[frameName]
    out[#out + 1] = "|cff88ccff== " .. frameName .. " ==|r"
    if f == nil then
        out[#out + 1] = "   |cffff9a9aไม่มีเฟรมนี้|r"
        return
    end

    local info = f.auraInfo
    if type(info) ~= "table" then
        out[#out + 1] = "   auraInfo = " .. PeekVal(info) .. " |cffff9a9a(ไม่ใช่ table)|r"
    else
        out[#out + 1] = ("   auraInfo = #%d แถว"):format(#info)
        for i = 1, math.min(#info, MAX_ROWS) do
            local row = info[i]
            if type(row) ~= "table" then
                out[#out + 1] = ("   [แถว %d] = "):format(i) .. PeekVal(row)
            elseif i == 1 then
                out[#out + 1] = ("   |cffffd200[แถว %d]|r"):format(i)
                DumpKnown(row, ROW_FIELDS, "      ", out)
                local exp, tex = row.expirationTime, row.texture
                out[#out + 1] = TryOp("exp - GetTime()", function() return exp - GetTime() end)
                out[#out + 1] = TryOp("texture + 0", function() return tex + 0 end)
            else
                -- แถว 2+ ย่อบรรทัดเดียว กันคอลัมน์ล้นจอ (field ชุดเดียวกับแถว 1)
                local dtPart = (row.debuffType ~= nil)
                    and ("  |cff3fcf5adt=" .. PeekVal(row.debuffType) .. "|r") or ""
                out[#out + 1] = ("   |cffffd200[%d]|r "):format(i)
                    .. "tex=" .. PeekVal(row.texture)
                    .. " cnt=" .. PeekVal(row.count)
                    .. " exp=" .. PeekVal(row.expirationTime) .. dtPart
            end
        end
        if #info > MAX_ROWS then
            out[#out + 1] = ("   ... อีก %d แถว"):format(#info - MAX_ROWS)
        end
    end

    local btns = f.auraFrames
    if type(btns) ~= "table" then
        out[#out + 1] = "   auraFrames = " .. PeekVal(btns) .. " |cffff9a9a(ไม่ใช่ table)|r"
        return
    end
    out[#out + 1] = ("   auraFrames = #%d ปุ่ม (รวม anchor)"):format(#btns)
    local shown = 0
    for i = 1, #btns do
        if shown >= MAX_BTNS then break end
        local b = btns[i]
        if type(b) == "table" then
            local anchor = b.isAuraAnchor
            local skipAnchor = (anchor == true) and not IsSecret(anchor)
            local vis = false
            local okV, sv = pcall(function() return b:IsShown() end)
            if okV and sv == true then vis = true end
            if not skipAnchor and vis then
                shown = shown + 1
                if shown == 1 then
                    out[#out + 1] = ("   |cffffd200[ปุ่ม %d]|r"):format(i)
                    DumpKnown(b, BTN_FIELDS, "      ", out)
                    local okID, idv = pcall(b.GetID, b)
                    local idMean = ""
                    if okID then
                        if idv == nil then
                            idMean = "  |cff3fcf5a(nil = ออร่าจริง)|r"
                        else
                            idMean = "  |cffffcc55(= inventory slot → ปุ่ม TempEnchant ไม่ใช่ออร่า)|r"
                        end
                    end
                    out[#out + 1] = "      GetID() = "
                        .. (okID and PeekVal(idv) or ShortErr(idv)) .. idMean
                    if b.Duration ~= nil and b.Duration.GetText ~= nil then
                        local okT, txt = pcall(b.Duration.GetText, b.Duration)
                        out[#out + 1] = "      Duration:GetText() = "
                            .. (okT and PeekVal(txt) or ("THROW " .. ShortErr(txt)))
                    end
                    if type(b.buttonInfo) == "table" then
                        out[#out + 1] = "      buttonInfo:"
                        DumpKnown(b.buttonInfo, ROW_FIELDS, "         ", out)
                    else
                        out[#out + 1] = "      buttonInfo = " .. PeekVal(b.buttonInfo)
                    end
                    local tl = b.timeLeft
                    out[#out + 1] = TryOp("timeLeft + 0", function() return tl + 0 end)
                    out[#out + 1] = TryOp("timeLeft > 0.4", function() return tl > 0.4 end)
                else
                    -- ปุ่ม 2+ ย่อบรรทัดเดียว
                    local durTxt = ""
                    if b.Duration ~= nil and b.Duration.GetText ~= nil then
                        local okT, txt = pcall(b.Duration.GetText, b.Duration)
                        if okT then durTxt = "  Dur=" .. PeekVal(txt) end
                    end
                    local okID2, idv2 = pcall(b.GetID, b)
                    out[#out + 1] = ("   |cffffd200[ปุ่ม %d]|r "):format(i)
                        .. "timeLeft=" .. PeekVal(b.timeLeft) .. durTxt
                        .. "  GetID=" .. (okID2 and PeekVal(idv2) or "?")
                end
            end
        end
    end
    if shown == 0 then
        out[#out + 1] = "   |cffaaaaaa(ไม่มีปุ่มที่แสดงอยู่)|r"
    end
end

-- ============================================================
-- คอลัมน์ 3 — ① เทียบ debuffType กับแถวที่ไม่ nil  ② ล่า spellID
-- ============================================================

--- หาแถวแรก (ทั้ง 2 เฟรม) ที่ debuffType ~= nil — เทียบ nil เป็น op ที่ปลอดภัยเสมอ
local function FindDispelRow()
    for _, fname in ipairs({ "DebuffFrame", "BuffFrame" }) do
        local f = _G[fname]
        local info = f and f.auraInfo
        if type(info) == "table" then
            for i = 1, #info do
                local row = info[i]
                if type(row) == "table" and row.debuffType ~= nil then
                    return row, fname, i
                end
            end
        end
    end
    return nil
end

local function BuildCol3()
    local out = {}

    -- ── ① เทียบ string secret กับแถวที่ debuffType ≠ nil เท่านั้น ──────
    out[#out + 1] = "|cff88ccff== tier-2: เทียบ debuffType (แถวที่ไม่ nil เท่านั้น) ==|r"
    local row, fname, ri = FindDispelRow()
    if not row then
        out[#out + 1] = "|cffffcc55ยังวัดไม่ได้ — ไม่มีแถวไหน debuffType ≠ nil|r"
        out[#out + 1] = "|cffaaaaaaต้องมี debuff ที่ dispel ได้ติดตัว (magic/curse/poison/"
        out[#out + 1] = "disease ในดัน) แล้วกด Refresh ใหม่ — ผลเทียบรอบก่อนที่ได้ true/false"
        out[#out + 1] = "มาจากแถว nil = ไม่พิสูจน์อะไร|r"
    else
        out[#out + 1] = ("เจอที่ %s แถว %d:"):format(fname, ri)
        local dt = row.debuffType
        out[#out + 1] = "   debuffType = " .. PeekVal(dt)
        out[#out + 1] = TryOp('debuffType == "Magic"', function() return dt == "Magic" end)
        out[#out + 1] = TryOp('debuffType == "Curse"', function() return dt == "Curse" end)
        out[#out + 1] = TryOp('".." concat (ส่ง STS ได้ไหม)', function() return ";" .. dt end)
        out[#out + 1] = TryOp("if-test (boolean coerce)",
            function() if dt then return "truthy" end return "falsy" end)
    end
    out[#out + 1] = ""

    -- ── ② ล่า spellID ────────────────────────────────────────────────
    out[#out + 1] = "|cff88ccff== ล่า spellID (แถวปกติมีแค่ texture) ==|r"

    -- (ก) ตระกูล C_TooltipInfo แบบ index — index วัดแล้วเป็น plain ใช้เป็น arg ได้
    local function TipByIndex(label, apiName, f)
        local btn = FirstShownButton(f)
        local bi = btn and btn.buttonInfo
        local idx = (type(bi) == "table") and bi.index or nil
        if idx == nil then
            out[#out + 1] = "   " .. label .. ": |cffaaaaaa(ไม่มีปุ่ม/ไม่มี index)|r"
            return
        end
        local api = C_TooltipInfo and C_TooltipInfo[apiName]
        if api == nil then
            out[#out + 1] = "   " .. label .. ": |cff777777ไม่มี API " .. apiName .. "|r"
            return
        end
        local ok, data = pcall(api, "player", idx)
        if not ok then
            out[#out + 1] = "   " .. label .. "(player," .. PeekVal(idx) .. "): |cffff9a9aTHROW|r "
                .. ShortErr(data)
        elseif data == nil then
            out[#out + 1] = "   " .. label .. "(player," .. PeekVal(idx) .. "): nil"
        else
            out[#out + 1] = "   |cff44ff44" .. label .. ": ได้ table|r"
            out[#out + 1] = "      data.id (spellID?) = " .. PeekVal(data.id)
            local lines = data.lines
            if type(lines) == "table" and type(lines[1]) == "table" then
                out[#out + 1] = "      line1 = " .. PeekVal(lines[1].leftText)
            end
        end
    end
    TipByIndex("GetUnitBuff", "GetUnitBuff", _G["BuffFrame"])
    TipByIndex("GetUnitDebuff", "GetUnitDebuff", _G["DebuffFrame"])

    -- (ก2) scanning tooltip ของเราเอง — **ทุก icon ทั้ง 2 เฟรม ไม่ต้อง hover**
    -- call เดียวกับ Blizzard OnEnter fallback (bfsrc/BuffFrame.lua:909) ·
    -- index จาก auraInfo เป็น plain · เฟรมของเราเอง = taint ไม่โดน GameTooltip จริง
    out[#out + 1] = ""
    out[#out + 1] = "|cffffd200Scanning tooltip (ทุก icon · ไม่ต้อง hover) — spellID + stack ต่อแถว:|r"
    out[#out + 1] = "|cffaaaaaacnt = count จาก auraInfo = applications = stack (ยืนยันจาก source)|r"
    do
        local tip = _G["GeRODPSToolsPAPScanTip"]
        if tip == nil then
            tip = CreateFrame("GameTooltip", "GeRODPSToolsPAPScanTip", nil,
                "GameTooltipTemplate")
        end
        local fsL = _G["GeRODPSToolsPAPScanTipTextLeft1"]
        local function ScanAll(frameName, filter)
            out[#out + 1] = "   |cff88ccff" .. frameName .. " (" .. filter .. "):|r"
            local fr = _G[frameName]
            local info = fr and fr.auraInfo
            if type(info) ~= "table" or #info == 0 then
                out[#out + 1] = "      (ไม่มีแถว auraInfo)"
                return
            end
            for i = 1, math.min(#info, 10) do
                local r2 = info[i]
                local idx = (type(r2) == "table") and r2.index or nil
                if idx == nil then
                    -- แถว TempEnchant ไม่มี index (มี ID = slot แทน) ⇒ SetUnitAura เรียกไม่ได้
                    local why = "index=nil"
                    if type(r2) == "table" and r2.ID ~= nil then
                        why = "TempEnchant (ID=" .. PeekVal(r2.ID) .. " = ช่องอาวุธ)"
                    end
                    out[#out + 1] = ("      [%d] ข้าม — "):format(i) .. why
                else
                    local okSet, errSet = pcall(function()
                        tip:SetOwner(UIParent, "ANCHOR_NONE")
                        tip:SetUnitAura("player", idx, filter)
                    end)
                    if not okSet then
                        out[#out + 1] = ("      [%d] idx="):format(i) .. PeekVal(idx)
                            .. " |cffff9a9aTHROW|r " .. ShortErr(errSet)
                    else
                        local idPart, nmPart = "nil", "nil"
                        if tip.GetTooltipData ~= nil then
                            local okD, d = pcall(tip.GetTooltipData, tip)
                            if okD and type(d) == "table" then idPart = PeekVal(d.id) end
                        end
                        if fsL ~= nil and fsL.GetText ~= nil then
                            local okT, nm = pcall(fsL.GetText, fsL)
                            if okT then nmPart = PeekVal(nm) end
                        end
                        local cntPart = "nil"
                        if r2.count ~= nil then cntPart = PeekVal(r2.count) end
                        out[#out + 1] = ("      [%d] idx="):format(i) .. PeekVal(idx)
                            .. "  data.id=|cff3fcf5a" .. idPart .. "|r"
                            .. "  cnt=|cff3fcf5a" .. cntPart .. "|r  ชื่อ=" .. nmPart
                    end
                end
            end
        end
        ScanAll("BuffFrame", "HELPFUL")
        ScanAll("DebuffFrame", "HARMFUL")
        pcall(function() tip:Hide() end)
    end

    -- (ข) GameTooltip ตอน hover — Blizzard (secure) เป็นคน fill ให้เอง
    out[#out + 1] = ""
    out[#out + 1] = "|cffffd200GameTooltip (ชี้เมาส์ค้างที่ไอคอน buff/debuff แล้วกด Refresh):|r"
    local gt = _G["GameTooltip"]
    local okShown, gtShown = pcall(function() return gt:IsShown() end)
    if not (okShown and gtShown == true) then
        out[#out + 1] = "   |cffaaaaaa(GameTooltip ไม่ได้เปิดอยู่ตอนนี้)|r"
    else
        if gt.GetTooltipData ~= nil then
            local okD, d = pcall(gt.GetTooltipData, gt)
            if not okD then
                out[#out + 1] = "   GetTooltipData(): |cffff9a9aTHROW|r " .. ShortErr(d)
            elseif type(d) == "table" then
                out[#out + 1] = "   |cff44ff44GetTooltipData(): ได้ table|r"
                out[#out + 1] = "      data.id (spellID?) = " .. PeekVal(d.id)
                if type(d.lines) == "table" and type(d.lines[1]) == "table" then
                    out[#out + 1] = "      line1 = " .. PeekVal(d.lines[1].leftText)
                end
            else
                out[#out + 1] = "   GetTooltipData() = " .. PeekVal(d)
            end
        end
        if TooltipUtil ~= nil and TooltipUtil.GetDisplayedSpell ~= nil then
            local okS, nm, sid = pcall(TooltipUtil.GetDisplayedSpell, gt)
            if okS then
                out[#out + 1] = "   GetDisplayedSpell: name = " .. PeekVal(nm)
                    .. "  spellID = " .. PeekVal(sid)
            else
                out[#out + 1] = "   GetDisplayedSpell: |cffff9a9aTHROW|r " .. ShortErr(nm)
            end
        end
    end
    out[#out + 1] = ""

    -- ── deadly debuff (มี spellID จริง — เฉพาะเวทลิสต์ deadly ของ Blizzard) ──
    out[#out + 1] = "|cff88ccff== DebuffFrame.deadlyDebuffInfo (spellID เฉพาะ deadly) ==|r"
    local df = _G["DebuffFrame"]
    local dd = df and df.deadlyDebuffInfo
    if type(dd) ~= "table" then
        out[#out + 1] = "   = " .. PeekVal(dd)
    else
        out[#out + 1] = ("   #%d แถว"):format(#dd)
        for i = 1, math.min(#dd, 3) do
            local r = dd[i]
            out[#out + 1] = ("   |cffffd200[deadly %d]|r"):format(i)
            if type(r) == "table" then
                DumpKnown(r, { "spellID", "auraInstanceID", "debuffType", "texture",
                    "count", "duration", "expirationTime", "warningText" }, "      ", out)
            end
        end
    end

    return JoinLines(out)
end

-- ============================================================
-- ประกอบ 3 คอลัมน์
-- ============================================================

local function BuildCol1()
    local out = {}
    local inCombat = InCombatLockdown() and "|cff44ff44IN COMBAT|r"
        or "|cffff9a9aOUT OF COMBAT (ผลหลอก!)|r"
    out[#out + 1] = "combat = " .. inCombat
    out[#out + 1] = "GetTime() = " .. ("%.1f"):format(GetTime())
    if C_Secrets ~= nil and C_Secrets.ShouldAurasBeSecret ~= nil then
        local okS, sv = pcall(C_Secrets.ShouldAurasBeSecret)
        out[#out + 1] = "ShouldAurasBeSecret() = " .. (okS and PeekVal(sv) or ShortErr(sv))
    end
    if C_UnitAuras ~= nil and C_UnitAuras.GetAuraDataByIndex ~= nil then
        local okA, d = pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, "HARMFUL")
        if not okA then
            out[#out + 1] = "เส้นเก่า GetAuraDataByIndex: |cffff9a9aTHROW|r"
        elseif d == nil then
            out[#out + 1] = "เส้นเก่า GetAuraDataByIndex: nil"
        else
            out[#out + 1] = "เส้นเก่า GetAuraDataByIndex: |cff44ff44ได้ table|r (ยังไม่ secret)"
        end
    end
    out[#out + 1] = ""
    ProbeFrame("BuffFrame", out)
    return JoinLines(out)
end

local function BuildCol2()
    local out = {}
    ProbeFrame("DebuffFrame", out)
    return JoinLines(out)
end

-- ============================================================
-- UI — 3 คอลัมน์ FontString (secret-safe · copy ไม่ได้โดยตั้งใจ)
-- ============================================================

local frame
local colFS = {}

local TITLE_H  = 24
local SIDE_PAD = 12
local COL_GAP  = 14
local TOP_ROW  = TITLE_H + 8 + 24 + 8   -- title + ปุ่ม Refresh + ช่องไฟ

local function Relayout()
    if not frame then return end
    local w = frame:GetWidth() - SIDE_PAD * 2 - COL_GAP * 2
    if w < 300 then w = 300 end
    local colW = w / 3
    for i = 1, 3 do
        local f = colFS[i]
        if f then
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", frame, "TOPLEFT",
                SIDE_PAD + (i - 1) * (colW + COL_GAP), -TOP_ROW)
            f:SetWidth(colW)
        end
    end
end

local function Refresh()
    if not colFS[1] then return end
    local builders = { BuildCol1, BuildCol2, BuildCol3 }
    for i = 1, 3 do
        local ok, text = pcall(builders[i])
        colFS[i]:SetText(ok and text or ("พัง: " .. tostring(text)))
    end
end

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "GeRODPSToolsPlayerAuraProbe", UIParent,
        "BasicFrameTemplateWithInset")
    frame:SetSize(1360, 760)
    frame:SetPoint("CENTER", 40, 0)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetResizable(true)
    if frame.SetResizeBounds then frame:SetResizeBounds(960, 400, 2400, 1400) end
    frame:SetClampedToScreen(true)
    frame:SetClipsChildren(true)
    frame:SetFrameStrata("DIALOG")
    frame:SetScript("OnSizeChanged", Relayout)
    if frame.TitleText then frame.TitleText:SetText("Player Aura Probe — Buff/Debuff Frame") end
    table.insert(UISpecialFrames, "GeRODPSToolsPlayerAuraProbe")

    local btnR = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnR:SetSize(110, 24)
    btnR:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 8))
    btnR:SetText("Refresh")
    btnR:SetScript("OnClick", Refresh)

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", btnR, "RIGHT", 10, 0)
    hint:SetText("|cffaaaaaaกดตอน IN COMBAT + มี debuff ที่ dispel ได้ติดตัว · คอลัมน์ 3 มีวิธีล่า spellID|r")

    -- ⚠ FontString เท่านั้น — ห้าม EditBox (secret unmask ตอน copy)
    for i = 1, 3 do
        local f = frame:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
        f:SetJustifyH("LEFT")
        f:SetJustifyV("TOP")
        f:SetWordWrap(true)
        f:SetSpacing(2)
        colFS[i] = f
    end
    Relayout()

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

function TOOL.ShowPlayerAuraProbe()
    local f = BuildFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        Refresh()
    end
end

TOOL.RegisterTool("Player Aura Probe (Buff/Debuff Frame)", TOOL.ShowPlayerAuraProbe)
