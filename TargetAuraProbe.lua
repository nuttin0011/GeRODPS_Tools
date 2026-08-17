--[[
    GeRODPS_Tools / TargetAuraProbe.lua

    "Target Aura Probe" — ตอบ 2 คำถามที่แยกกันเด็ดขาด:

      A) อ่านออร่าของ **target** จากเฟรมของ Blizzard ได้ไหม
         path จาก fstack ของ user (2026-08-18):
           TargetFrame.TargetFrameContent.TargetFrameContentContextual.Auras
           SOURCE Blizzard_UnitFrame/Mainline/TargetFrame.xml:324
         ⚠ **ไม่มี source dump ของ TargetFrame ในเครื่อง** ⇒ ต้องค้นโครงตอน runtime
           (ต่างจาก BuffFrame ที่มี bfsrc/ ให้อ่าน) ⇒ tool นี้เดินต้นไม้เฟรมจริง
           แล้ว dump ทุก field ที่เจอ ไม่เดาชื่อ field

      B) 🔑 **enumerate ด้วย scanning tooltip เพียว ๆ ได้ไหม** (ไม่แตะเฟรมเลย)
         สมมติฐาน: `tip:SetUnitAura(unit, i, filter)` วน i = 1..N ได้เลย
         ถ้าจริง = **ใช้ได้กับทุก unit** (target/focus/boss/party) โดยไม่ต้องรู้จัก
         เฟรมของแต่ละ unit — จะใหญ่กว่าคำตอบ A มาก เพราะ:
           · ไม่ผูกกับโครง UI ของ Blizzard (เปลี่ยนแพตช์ก็ไม่พัง)
           · ไม่ต้องสน addon ที่ replace unit frame (ElvUI/Plater)
           · ได้ทั้ง unit ที่ไม่มีเฟรมโชว์อยู่
         สิ่งที่ต้องรู้จากการวัด: index ที่ **เกินจำนวนออร่าจริง** ให้ผลอะไร
         (nil เงียบ = ใช้เป็นจุดหยุด loop ได้ · throw = ต้องรู้จำนวนจากที่อื่น ·
          คืนค่าค้างของ tooltip เดิม = **อันตรายที่สุด** ต้องเคลียร์ก่อนทุกครั้ง)

    ═══ คำตัดสินสายเฟรม (2026-08-18 · จาก source Gethe/wow-ui-source + วัดจริง) ═══
    ปุ่มออร่าของ TargetFrame สร้างด้วย self.auraPools:CreatePool("AuraButton", ...)
    template TargetFrameBuff/DebuffButtonTemplate — มี <Texture parentKey="Icon"> +
    <FontString parentKey="Count" inherits="NumberFontNormalSmall"> มุมขวาล่าง +
    Cooldown · stack เซ็ตด้วย self.Count:SetText(auraData.applications)
    ⇒ โครงเหมือน BuffFrame ทุกอย่าง... แต่:
    ❌ mixin แบ่งเป็น Inbound (public) / **Private** + มี template ตระกูล **Forbidden...**
       วัดจริง (in combat + target มี debuff โชว์ไอคอน): ค่าบน .Auras = 0 key ·
       GetChildren()=0 · ไม่เห็น auraPools — ทั้งที่ source บอกว่ามี
       ⇒ **ปุ่มอยู่ฝั่ง private sandbox — โค้ด addon มองไม่เห็นโดยดีไซน์** (ตันถาวร)
    ✅ stack ของ unit ใช้ทางที่พิสูจน์แล้วแทน: ปุ่ม nameplate ของ unit นั้น
       (CountFrame — GetAllAuraFromSetOfNamePlate) + identity/remain/dispel จาก tooltip

    ⚠ ต้องมี target ที่มีออร่า + อยู่ใน combat (นอก combat ค่าไม่ secret = ผลหลอก)
    ⚠ อ่านอย่างเดียว ห่อ pcall · FontString เท่านั้น (copy = unmask secret)
    ⚠ secret string ห้าม table.concat / :sub / :gsub — ต่อด้วย .. เท่านั้น
]]

local TOOL = GeRODPS_Tools

local NL = string.char(10)

-- ============================================================
-- helpers (ชุดเดียวกับ PlayerAuraProbe)
-- ============================================================

local function IsSecret(v)
    if issecretvalue ~= nil then
        local ok, r = pcall(issecretvalue, v)
        if ok and r == true then return true end
    end
    return false
end

local function PeekVal(v)
    if v == nil then return "nil" end
    local tag = IsSecret(v) and "|cffffcc55[S]|r" or ""
    local ok, res = pcall(function() return "" .. tostring(v) end)
    if ok then return res .. tag end
    return "<เรนเดอร์ไม่ได้>" .. tag
end

local function ShortErr(e)
    return (tostring(e):gsub("\n.*", ""):sub(1, 110))
end

-- ============================================================
-- A · ค้นโครงเฟรมของ target ตอน runtime
-- ============================================================

local AURA_PATH = { "TargetFrameContent", "TargetFrameContentContextual", "Auras" }

--- เดิน path จาก TargetFrame ตาม fstack — คืน frame ปลายทาง + ข้อความรายทาง
local function WalkAuraFrame(out)
    local cur = _G["TargetFrame"]
    if cur == nil then
        out[#out + 1] = "|cffff9a9aไม่มี TargetFrame|r"
        return nil
    end
    out[#out + 1] = "TargetFrame |cff44ff44ok|r"
    for _, key in ipairs(AURA_PATH) do
        local nxt = cur[key]
        if nxt == nil then
            out[#out + 1] = "   ." .. key .. " = |cffff9a9anil (โครงเปลี่ยน?)|r"
            return nil
        end
        out[#out + 1] = "   ." .. key .. " |cff44ff44ok|r"
        cur = nxt
    end
    return cur
end

-- field ที่ "น่าจะมี" บนปุ่มออร่า (เดาจากฝั่ง nameplate + BuffFrame) — ไม่เจอก็ไม่เป็นไร
-- ตัวจริงมาจากการกวาด key ทั้งหมดข้างล่าง
local GUESS_FIELDS = { "spellID", "spellId", "auraInstanceID", "isBuff", "auraType",
                       "debuffType", "index", "count", "duration", "expirationTime",
                       "timeMod", "texture", "unit", "filter", "buttonInfo", "auraData" }

--- dump **ทุก** string key ของ frame — แยกฟังก์ชันออกจากค่า
--- ⚠ เดิมกรองแค่ key ที่มีคำ aura/buff/pool ⇒ key ชื่อ count/stack/num*
---   ไม่มีทางโผล่เลยแม้มีอยู่จริง (user จับได้ 2026-08-18) — ห้ามกรองอีก
local function DumpAllKeys(fr, label, indent, out)
    local vals, fns = {}, {}
    local ok = pcall(function()
        for k, v in pairs(fr) do
            if type(k) == "string" then
                if type(v) == "function" then
                    fns[#fns + 1] = k
                else
                    vals[#vals + 1] = k
                end
            end
        end
    end)
    if not ok then
        out[#out + 1] = indent .. "|cffff9a9a" .. label .. ": pairs() THROW|r"
        return
    end
    table.sort(vals)   -- ชื่อ key เป็น plain เสมอ ⇒ sort ได้
    table.sort(fns)
    out[#out + 1] = indent .. "|cffffd200" .. label .. " — ค่า (" .. #vals .. "):|r"
    if #vals == 0 then
        out[#out + 1] = indent .. "   |cffaaaaaa(ไม่มี)|r"
    end
    for _, k in ipairs(vals) do
        local v = fr[k]
        local shown
        if type(v) == "table" then
            local cnt = 0
            pcall(function() cnt = #v end)
            shown = "<table> #" .. cnt
        else
            shown = PeekVal(v)
        end
        -- ไฮไลต์ key ที่น่าจะเป็น stack
        local lk = k:lower()
        if lk:find("count") or lk:find("stack") or lk:find("num") then
            out[#out + 1] = indent .. "   |cff3fcf5a" .. k .. " = " .. shown .. "|r"
        else
            out[#out + 1] = indent .. "   " .. k .. " = " .. shown
        end
    end
    -- ชื่อฟังก์ชันรวมบรรทัดเดียว (ไม่กินที่)
    local fl = ""
    for _, k in ipairs(fns) do fl = fl .. k .. " " end
    out[#out + 1] = indent .. "|cff888888" .. label .. " — ฟังก์ชัน (" .. #fns .. "): "
        .. fl .. "|r"
end

local function DumpButton(b, indent, out)
    local seen = {}
    for _, k in ipairs(GUESS_FIELDS) do
        seen[k] = true
        if b[k] ~= nil then
            local v = b[k]
            if type(v) == "table" then
                out[#out + 1] = indent .. k .. " = <table>"
            else
                out[#out + 1] = indent .. k .. " = " .. PeekVal(v)
            end
        end
    end
    -- ข้อความบน FontString ลูก — **ทางหา stack ที่เหลืออยู่**
    -- (tooltip ไม่มีเลข stack — วัดแล้ว 2026-08-18 · nameplate โชว์ 16 แต่ tooltip ไม่มี)
    for _, ck in ipairs({ "Count", "count", "Stack", "stack", "Duration", "Icon" }) do
        local child = b[ck]
        if child ~= nil and type(child) == "table" then
            if child.GetText ~= nil then
                local okC, tv = pcall(child.GetText, child)
                out[#out + 1] = indent .. "|cff3fcf5a" .. ck .. ":GetText() = "
                    .. (okC and PeekVal(tv) or "?") .. "|r"
            end
            if child.GetTexture ~= nil then
                local okX, xv = pcall(child.GetTexture, child)
                out[#out + 1] = indent .. ck .. ":GetTexture() = "
                    .. (okX and PeekVal(xv) or "?")
            end
        end
    end
    -- GetID (บทเรียน BuffFrame: บางปุ่มเก็บ index/slot ไว้ที่นี่)
    if b.GetID ~= nil then
        local okI, iv = pcall(b.GetID, b)
        out[#out + 1] = indent .. "GetID() = " .. (okI and PeekVal(iv) or ShortErr(iv))
    end
    -- ชื่อเฟรม (fstack โชว์ address = ไม่มีชื่อ)
    if b.GetName ~= nil then
        local okN, nv = pcall(b.GetName, b)
        out[#out + 1] = indent .. "GetName() = " .. (okN and PeekVal(nv) or "?")
    end
    -- กวาด key ที่ไม่ได้เดาไว้ — ตัวนี้คือคำตอบจริงว่าโครงมีอะไร
    local extra = {}
    local okP = pcall(function()
        for k in pairs(b) do
            if type(k) == "string" and not seen[k] then extra[#extra + 1] = k end
        end
    end)
    if okP and #extra > 0 then
        table.sort(extra)
        local line, n = "", 0
        for _, k in ipairs(extra) do
            n = n + 1
            if n > 26 then break end
            line = line .. k .. ", "
        end
        out[#out + 1] = indent .. "|cff888888key อื่น: " .. line .. "|r"
    end
end

local function BuildColALines()
    local out = {}
    local u = "target"
    out[#out + 1] = "combat = " .. (InCombatLockdown()
        and "|cff44ff44IN COMBAT|r" or "|cffff9a9aOUT (ผลหลอก!)|r")
    out[#out + 1] = "target มีตัวไหม = " .. (UnitExists(u) and "|cff44ff44yes|r" or "|cffff9a9ano|r")
    if not UnitExists(u) then
        out[#out + 1] = "|cffff3333>>> ไม่มี target — ปุ่มออร่าไม่ถูกสร้าง ทุกชั้นจะเป็น 0/ว่างหมด"
        out[#out + 1] = "เลงเป้าที่มี debuff stack (เช่น dummy ที่เห็น 16/8 บน nameplate)"
        out[#out + 1] = "แล้วกด Refresh ใหม่ — ผลรอบนี้สรุปอะไรไม่ได้ <<<|r"
    end
    if C_Secrets ~= nil and C_Secrets.ShouldAurasBeSecret ~= nil then
        local okS, sv = pcall(C_Secrets.ShouldAurasBeSecret)
        out[#out + 1] = "ShouldAurasBeSecret() = " .. (okS and PeekVal(sv) or ShortErr(sv))
    end
    out[#out + 1] = ""
    out[#out + 1] = "|cffff3333>>> คอลัมน์นี้คือที่หา STACK <<<|r"
    out[#out + 1] = "|cffaaaaaatooltip ไม่มีเลข stack (วัดแล้ว) ⇒ stack อยู่บนปุ่มเท่านั้น|r"
    out[#out + 1] = ""
    out[#out + 1] = "|cff88ccff== A) เดิน path จาก fstack ==|r"
    local af = WalkAuraFrame(out)
    if af == nil then return out end

    -- ผลวัด 2026-08-18: .Auras มีจริงแต่ GetChildren() = 0
    -- ⇒ ปุ่มอยู่ลึกกว่า · ขุดต่อ 4 ทาง (เดินตามโครงที่ BuffFrame ใช้จริง)

    -- ทาง 1: **ทุก** key บนตัว Auras เอง (ห้ามกรอง — count อาจอยู่ตรงนี้)
    DumpAllKeys(af, ".Auras", "   ", out)

    -- ทาง 2: GetLayoutChildren() — แพตเทิร์นเดียวกับ nameplate list frame
    -- (NameplateAuraCheck ใช้อยู่ — layout children ≠ GetChildren)
    if af.GetLayoutChildren ~= nil then
        local okL, lc = pcall(af.GetLayoutChildren, af)
        if okL and type(lc) == "table" then
            out[#out + 1] = ("   |cff3fcf5aGetLayoutChildren() = %d เฟรม|r"):format(#lc)
            for li = 1, math.min(#lc, 3) do
                out[#out + 1] = ("   |cffffd200[layout %d]|r"):format(li)
                if type(lc[li]) == "table" then DumpButton(lc[li], "      ", out) end
            end
        else
            out[#out + 1] = "   GetLayoutChildren(): " .. (okL and "ไม่ใช่ table" or "THROW")
        end
    else
        out[#out + 1] = "   |cffaaaaaaไม่มี GetLayoutChildren|r"
    end

    -- ทาง 3: TargetFrame:GetAuraContainer() — method ที่เจอจากการกวาด key
    do
        local tf = _G["TargetFrame"]
        if tf ~= nil and tf.GetAuraContainer ~= nil then
            local okG, ac = pcall(tf.GetAuraContainer, tf)
            if okG and type(ac) == "table" then
                out[#out + 1] = "   |cff3fcf5aGetAuraContainer() คืน frame|r"
                DumpAllKeys(ac, "AuraContainer", "      ", out)
                if ac.GetChildren ~= nil then
                    local okC2, res2 = pcall(function() return { ac:GetChildren() } end)
                    if okC2 and type(res2) == "table" then
                        out[#out + 1] = ("      ลูก = %d เฟรม"):format(#res2)
                        for ci = 1, math.min(#res2, 3) do
                            if type(res2[ci]) == "table" then
                                out[#out + 1] = ("      |cffffd200[ลูก %d]|r"):format(ci)
                                DumpButton(res2[ci], "         ", out)
                            end
                        end
                    end
                end
                if ac.GetLayoutChildren ~= nil then
                    local okL2, lc2 = pcall(ac.GetLayoutChildren, ac)
                    if okL2 and type(lc2) == "table" then
                        out[#out + 1] = ("      GetLayoutChildren() = %d"):format(#lc2)
                    end
                end
            else
                out[#out + 1] = "   GetAuraContainer(): " .. (okG and "ไม่ใช่ frame" or "THROW")
            end
        else
            out[#out + 1] = "   |cffaaaaaaไม่มี TargetFrame:GetAuraContainer|r"
        end
    end

    -- ทาง 5: FramePool — Dragonflight+ หลายที่ใช้ pool แล้วปุ่มที่ active
    -- ไม่จำเป็นต้องเป็นลูกของเฟรมที่เราเดินหา ⇒ ต้องดึงออกจาก pool เอง
    do
        local tf = _G["TargetFrame"]
        local pools = tf and tf.auraPools
        if pools ~= nil then
            out[#out + 1] = "   |cffffd200TargetFrame.auraPools:|r"
            local shown = 0
            local okE = pcall(function()
                -- FramePoolCollection: EnumerateActive() คืน iterator ของทุก pool
                if pools.EnumerateActive ~= nil then
                    for obj in pools:EnumerateActive() do
                        shown = shown + 1
                        if shown <= 3 and type(obj) == "table" then
                            out[#out + 1] = ("      |cffffd200[active %d]|r"):format(shown)
                            DumpButton(obj, "         ", out)
                        end
                    end
                end
            end)
            if not okE then
                out[#out + 1] = "      |cffff9a9aEnumerateActive() THROW|r"
            else
                out[#out + 1] = ("      active ทั้งหมด = %d"):format(shown)
            end
        else
            out[#out + 1] = "   |cffaaaaaaไม่มี TargetFrame.auraPools|r"
        end
    end

    -- ทาง 6: สแกนลูกหลานของ Auras ลึก 2 ชั้น — หาเฟรมที่มี FontString เลข
    -- (หา stack แบบไม่สนชื่อ field — เอาที่ "มีตัวเลขสั้น ๆ ที่วาดอยู่" เลย)
    do
        out[#out + 1] = "   |cffffd200สแกนลูกหลานหา FontString ที่มีข้อความ:|r"
        local found = 0
        local function ScanRegions(fr, depth, path)
            if depth > 4 or found >= 12 then return end
            local okR, regs = pcall(function() return { fr:GetRegions() } end)
            if okR and type(regs) == "table" then
                for _, rg in ipairs(regs) do
                    if type(rg) == "table" and rg.GetText ~= nil then
                        local okT, tv = pcall(rg.GetText, rg)
                        if okT and tv ~= nil and tv ~= "" then
                            found = found + 1
                            if found <= 8 then
                                out[#out + 1] = "      |cff3fcf5a" .. path .. " = "
                                    .. PeekVal(tv) .. "|r"
                            end
                        end
                    end
                end
            end
            local okC, ch = pcall(function() return { fr:GetChildren() } end)
            if okC and type(ch) == "table" then
                for ci, c in ipairs(ch) do
                    if type(c) == "table" then
                        ScanRegions(c, depth + 1, path .. ">" .. ci)
                    end
                end
            end
        end
        -- ราก = TargetFrame ทั้งต้น (เดิมเริ่มที่ .Auras ซึ่งลูก = 0 ⇒ สแกนไม่เจออะไรแน่นอน
        -- · ปุ่มอาจเป็นลูกของชั้นอื่น ไม่ใช่ของ .Auras ตรง ๆ)
        pcall(ScanRegions, _G["TargetFrame"], 0, "TF")
        if found == 0 then
            out[#out + 1] = "      |cffaaaaaaไม่เจอ FontString ที่มีข้อความเลย|r"
        end
    end

    -- ทาง 4: GetChildren() ตามเดิม (เก็บไว้เทียบ)
    local kids
    if af.GetChildren ~= nil then
        local okC, res = pcall(function() return { af:GetChildren() } end)
        if okC then kids = res end
    end
    if type(kids) ~= "table" then
        out[#out + 1] = "   |cffff9a9aGetChildren() อ่านไม่ได้|r"
        return out
    end
    out[#out + 1] = ("   GetChildren() = %d เฟรม"):format(#kids)

    local shownN = 0
    for i = 1, #kids do
        local b = kids[i]
        if type(b) == "table" then
            local vis = false
            local okV, sv = pcall(function() return b:IsShown() end)
            if okV and sv == true then vis = true end
            if vis then
                shownN = shownN + 1
                if shownN <= 4 then
                    out[#out + 1] = ("   |cffffd200[ลูกที่แสดง %d]|r"):format(i)
                    DumpButton(b, "      ", out)
                end
            end
        end
    end
    out[#out + 1] = ("   ที่แสดงอยู่ = %d เฟรม"):format(shownN)
    if shownN == 0 then
        out[#out + 1] = "   |cffaaaaaa(target ไม่มีออร่า หรือโครงไม่ใช่ลูกตรง ๆ)|r"
    end
    return out
end

-- ============================================================
-- B · legacy global names + ทางเลือกโครงอื่น
-- ============================================================

local function BuildColBLines()
    local out = {}
    out[#out + 1] = "|cff88ccff== ชื่อ global แบบเก่า ==|r"
    local found = 0
    for _, base in ipairs({ "TargetFrameBuff", "TargetFrameDebuff" }) do
        for i = 1, 4 do
            local g = _G[base .. i]
            if g ~= nil then
                found = found + 1
                out[#out + 1] = "|cffffd200" .. base .. i .. "|r"
                DumpButton(g, "   ", out)
            end
        end
    end
    if found == 0 then
        out[#out + 1] = "|cffaaaaaaไม่มีเลย (Blizzard เลิกตั้งชื่อ global แล้ว —"
        out[#out + 1] = "ตรงกับที่ fstack โชว์เป็น address)|r"
    end
    out[#out + 1] = ""

    -- pool-based (Dragonflight+ ใช้ FramePool กับ aura ของ unit frame)
    out[#out + 1] = "|cff88ccff== field บน TargetFrame ที่น่าจะเก็บ aura ==|r"
    local tf = _G["TargetFrame"]
    if tf == nil then
        out[#out + 1] = "|cffff9a9aไม่มี TargetFrame|r"
    else
        local KEYS = { "auraPools", "auras", "activeBuffs", "activeDebuffs",
                       "buffs", "debuffs", "maxBuffs", "maxDebuffs",
                       "totalAuras", "auraRows" }
        local any = false
        for _, k in ipairs(KEYS) do
            if tf[k] ~= nil then
                any = true
                local v = tf[k]
                if type(v) == "table" then
                    local cnt = 0
                    pcall(function() cnt = #v end)
                    out[#out + 1] = "   " .. k .. " = <table> #" .. cnt
                else
                    out[#out + 1] = "   " .. k .. " = " .. PeekVal(v)
                end
            end
        end
        if not any then
            out[#out + 1] = "   |cffaaaaaaไม่เจอชื่อที่เดาไว้เลย|r"
        end
        -- **ทุก** key ของ TargetFrame (เดิมกรองแค่ aura/buff — พลาด count ไป)
        DumpAllKeys(tf, "TargetFrame", "   ", out)
    end
    return out
end

-- ============================================================
-- C · 🔑 enumerate ด้วย scanning tooltip เพียว ๆ (ไม่แตะเฟรม)
-- ============================================================

local TIP_NAME = "GeRODPSToolsTAPScanTip"
local _tip, _tipL1

local function GetTip()
    if _tip ~= nil then return _tip, _tipL1 end
    local ok, f = pcall(CreateFrame, "GameTooltip", TIP_NAME, nil, "GameTooltipTemplate")
    if not ok or f == nil then return nil, nil end
    _tip = f
    _tipL1 = _G[TIP_NAME .. "TextLeft1"]
    return _tip, _tipL1
end

--- 1 index: คืน ok(ไม่ throw), id, name, err, lines  ⚠ ClearLines ก่อนทุกครั้ง
--- ถ้าไม่เคลียร์ index ที่ว่างจะอ่านค่าค้างของ index ก่อนหน้า = นับเกินเงียบ ๆ
--- @param method string|nil  "SetUnitAura"(default) / "SetUnitBuff" / "SetUnitDebuff"
---   2 ตัวหลังรับ (unit, index) ไม่มี filter — เอามาเทียบกันเผื่อตัวไหนให้ข้อมูลมากกว่า
--- lines = ทุกบรรทัดซ้ายของ tooltip (หา stack/เวลาที่เหลือจากที่นี่ได้ไหม)
local MAX_TIP_LINES = 6
local function ProbeIndex(unit, i, filter, method)
    local tip, l1 = GetTip()
    if tip == nil then return false, nil, nil, "สร้าง tooltip ไม่ได้", nil end
    if method == nil then method = "SetUnitAura" end
    local fn = tip[method]
    if fn == nil then return false, nil, nil, "ไม่มี method " .. method, nil end
    local okSet, err = pcall(function()
        tip:SetOwner(UIParent, "ANCHOR_NONE")
        tip:ClearLines()
        if method == "SetUnitAura" then
            fn(tip, unit, i, filter)
        else
            fn(tip, unit, i)
        end
    end)
    if not okSet then
        pcall(function() tip:Hide() end)
        return false, nil, nil, ShortErr(err), nil
    end
    local id, nm, rawData
    if tip.GetTooltipData ~= nil then
        local okD, d = pcall(tip.GetTooltipData, tip)
        if okD and type(d) == "table" then
            id = d.id
            rawData = d
        end
    end
    if l1 ~= nil and l1.GetText ~= nil then
        local okT, v = pcall(l1.GetText, l1)
        if okT then nm = v end
    end
    -- ทุกบรรทัด — FontString ชื่อ <tip>TextLeftN / TextRightN
    -- (อ่านตรง ไม่ผ่าน GetTooltipData เพราะ lines[] ซ้อนอีกชั้น)
    -- ⚠ ช่อง **ขวา** คือที่ tooltip มาตรฐานเอาไว้ใส่ข้อมูลสั้น ๆ — stack อาจอยู่ที่นี่
    local lines, rlines = {}, {}
    for li = 1, MAX_TIP_LINES do
        local fs = _G[TIP_NAME .. "TextLeft" .. li]
        if fs == nil or fs.GetText == nil then break end
        local okL, txt = pcall(fs.GetText, fs)
        if okL and txt ~= nil then
            lines[#lines + 1] = txt
        end
        local fr = _G[TIP_NAME .. "TextRight" .. li]
        if fr ~= nil and fr.GetText ~= nil then
            local okR, rtxt = pcall(fr.GetText, fr)
            if okR and rtxt ~= nil then
                rlines[#rlines + 1] = ("R" .. li .. "=") .. PeekVal(rtxt)
            end
        end
    end
    pcall(function() tip:Hide() end)
    return true, id, nm, nil, lines, rlines, rawData
end

local MAX_IDX = 12

local function EnumUnit(unit, filter, label, out)
    out[#out + 1] = "   |cffffd200" .. label .. "|r"
    local hit, blank = 0, 0
    for i = 1, MAX_IDX do
        local ok, id, nm, err, lines, rlines, rawData = ProbeIndex(unit, i, filter, "SetUnitAura")
        if not ok then
            out[#out + 1] = ("      [%d] |cffff9a9aTHROW|r %s"):format(i, err or "?")
            break
        end
        if id == nil and nm == nil then
            blank = blank + 1
            if blank == 1 then
                out[#out + 1] = ("      [%d] |cffaaaaaaว่าง (id=nil name=nil)|r"):format(i)
            end
            if blank >= 2 then
                out[#out + 1] = ("      ... ว่างต่อเนื่อง หยุดที่ %d"):format(i)
                break
            end
        else
            hit = hit + 1
            blank = 0
            out[#out + 1] = ("      [%d] id=|cff3fcf5a"):format(i) .. PeekVal(id)
                .. "|r  ชื่อ=" .. PeekVal(nm)
            -- hit แรก: เค้นทุกซอกที่ stack อาจซ่อนอยู่
            if hit == 1 then
                if type(lines) == "table" then
                    for li = 2, #lines do
                        out[#out + 1] = ("         L%d = "):format(li) .. PeekVal(lines[li])
                    end
                end
                -- ช่องขวาของทุกบรรทัด (tooltip มาตรฐานเอาไว้ใส่ข้อมูลสั้น)
                if type(rlines) == "table" and #rlines > 0 then
                    local rr = "         ขวา: "
                    for _, t in ipairs(rlines) do rr = rr .. t .. "  " end
                    out[#out + 1] = rr
                else
                    out[#out + 1] = "         |cffaaaaaaช่องขวาว่างทั้งหมด|r"
                end
                -- subfield ของทุก line — เผื่อมี line ชนิดที่เก็บ stack แยก
                if type(rawData) == "table" and type(rawData.lines) == "table" then
                    for li = 1, math.min(#rawData.lines, 4) do
                        local ln = rawData.lines[li]
                        if type(ln) == "table" then
                            local kn2 = {}
                            pcall(function()
                                for k in pairs(ln) do
                                    if type(k) == "string" and k ~= "leftText" then
                                        kn2[#kn2 + 1] = k
                                    end
                                end
                            end)
                            table.sort(kn2)
                            local ll = ("         line%d: "):format(li)
                            for _, k in ipairs(kn2) do
                                ll = ll .. k .. "=" .. PeekVal(ln[k]) .. " "
                            end
                            out[#out + 1] = ll
                        end
                    end
                end
                -- ทุก key ของ GetTooltipData — เราอ่านแค่ .id มาตลอด อาจมี stack หลงอยู่
                if type(rawData) == "table" then
                    -- ⚠ ห้าม table.sort ที่นี่ — PeekVal(v) คืน secret string เมื่อ v เป็น secret
                    -- และ sort เทียบสมาชิกด้วย `<` ⇒ compare secret string ⇒ THROW
                    -- (เจอจริง 2026-08-18: คอลัมน์ 2/3 พังหมด) — เรียง key ก่อนค่อย render
                    local kn = {}
                    pcall(function()
                        for k in pairs(rawData) do
                            if type(k) == "string" and k ~= "lines" then
                                kn[#kn + 1] = k
                            end
                        end
                    end)
                    table.sort(kn)      -- ชื่อ key เป็น plain เสมอ — sort ได้
                    local kk = "         data: "
                    for _, k in ipairs(kn) do
                        kk = kk .. k .. "=" .. PeekVal(rawData[k]) .. "  "
                    end
                    out[#out + 1] = kk
                end
            end
        end
    end
    out[#out + 1] = ("      -> เจอ %d ตัว"):format(hit)
end

--- @param units table   รายชื่อ unit ที่จะไล่
--- @param withHead boolean  ใส่หัวข้อ + คำเตือนไหม (เฉพาะคอลัมน์แรก)
--- @param withApi boolean   ต่อท้ายด้วยหัวข้อเทียบ API ไหม
local function BuildEnumLines(units, withHead, withApi)
    local out = {}
    if withHead then
    out[#out + 1] = "|cff88ccff== C) enumerate ด้วย tooltip เพียว ๆ ==|r"
    out[#out + 1] = "|cff44ff44✅ วัดแล้ว 2026-08-18: arg unit ทำงานจริง|r"
    out[#out + 1] = "|cffaaaaaa(target=dummy ได้ Total Damage Done / Touch of the Magi ไม่ใช่ buff ของเรา)"
    out[#out + 1] = "รอบก่อนที่เหมือน player หมด เพราะเลงตัวเองอยู่ ⇒ บรรทัด identity ข้างล่างกันอ่านผิดซ้ำ|r"
    out[#out + 1] = "|cffaaaaaaClearLines ก่อนทุก index (กันอ่านค่าค้างของ index ก่อนหน้า)|r"
    out[#out + 1] = ""
    end

    -- กันอ่านผิด unit: บอกตรง ๆ ว่า unit นี้เป็นตัวเราเองหรือเปล่า
    local function IdentityLine(u)
        local nm, same, atk
        local okN, v = pcall(UnitName, u); if okN then nm = v end
        local okS, v2 = pcall(UnitIsUnit, u, "player"); if okS then same = v2 end
        local okA, v3 = pcall(UnitCanAttack, "player", u); if okA then atk = v3 end
        return "   |cffaaaaaaชื่อ=" .. PeekVal(nm)
            .. "  เป็นตัวเราเอง?=" .. PeekVal(same)
            .. "  ตีได้?=" .. PeekVal(atk) .. "|r"
    end

    -- เทียบ 3 method ที่ index 1 — ตัวไหนให้ข้อมูลมากสุด
    local function MethodCompare(u, out2)
        out2[#out2 + 1] = "   |cffffd200เทียบ 3 method ที่ index 1:|r"
        local specs = { { "SetUnitAura", "HARMFUL" }, { "SetUnitBuff", nil },
                        { "SetUnitDebuff", nil } }
        for _, sp in ipairs(specs) do
            local ok, id, nm2, err = ProbeIndex(u, 1, sp[2], sp[1])
            if not ok then
                out2[#out2 + 1] = "      " .. sp[1] .. ": |cffff9a9a" .. (err or "?") .. "|r"
            else
                out2[#out2 + 1] = "      " .. sp[1] .. ": id=|cff3fcf5a" .. PeekVal(id)
                    .. "|r  ชื่อ=" .. PeekVal(nm2)
            end
        end
    end

    for _, u in ipairs(units) do
        local exists = UnitExists(u)
        out[#out + 1] = "|cff88ccffunit \"" .. u .. "\" "
            .. (exists and "|cff44ff44(มีตัว)|r" or "|cffff9a9a(ไม่มีตัว)|r")
        if exists then
            out[#out + 1] = IdentityLine(u)
            MethodCompare(u, out)
            EnumUnit(u, "HELPFUL", "HELPFUL (buff)", out)
            EnumUnit(u, "HARMFUL", "HARMFUL (debuff)", out)
        end
        out[#out + 1] = ""
    end

    if not withApi then return out end

    -- เทียบกับ API ที่ ship แล้ว (ResolveSpellByIndex รับ unit ได้)
    out[#out + 1] = "|cff88ccff== เทียบกับ API PlayerAuraCheck ==|r"
    local PAC = GeRODPS and GeRODPS.PlayerAuraCheck
    if PAC == nil or PAC.ResolveSpellByIndex == nil then
        out[#out + 1] = "|cffff9a9aPlayerAuraCheck ยังไม่โหลด|r"
    else
        for _, u in ipairs({ "target", "player" }) do
            if UnitExists(u) then
                local okR, id, nm = pcall(PAC.ResolveSpellByIndex, 1, "HARMFUL", u)
                if okR then
                    out[#out + 1] = "   " .. u .. " HARMFUL#1 -> id=" .. PeekVal(id)
                        .. "  ชื่อ=" .. PeekVal(nm)
                else
                    out[#out + 1] = "   " .. u .. ": |cffff9a9aTHROW|r " .. ShortErr(id)
                end
            end
        end
    end
    return out
end

-- ============================================================
-- จัดเนื้อหาลง 3 คอลัมน์ (ตามที่ user สั่ง 2026-08-18)
--   1 = A (เดิน path เฟรม) + B (ชื่อ global / key ของ TargetFrame) ต่อกัน
--   2 = enumerate target + focus      (คู่ที่เอามาเทียบกันบ่อยสุด)
--   3 = enumerate boss1 + nameplate1 + เทียบ API
-- ============================================================

--- คอลัมน์ 3: nameplate หลายตัว + boss — สร้างลิสต์ตอน runtime
--- (user ชี้ 2026-08-18: สนามจริง nameplate เยอะมาก และนอก raid ไม่มี boss1)
local function BuildPlateLines()
    local units, nBoss, nPlate = {}, 0, 0
    for b = 1, 4 do
        if UnitExists("boss" .. b) then
            nBoss = nBoss + 1
            if #units < 1 then units[#units + 1] = "boss" .. b end
        end
    end
    for i = 1, 30 do
        local u = "nameplate" .. i
        if UnitExists(u) then
            nPlate = nPlate + 1
            if #units < 4 then units[#units + 1] = u end
        end
    end
    local head = {}
    head[#head + 1] = "|cff88ccff== nameplate / boss ==|r"
    head[#head + 1] = ("|cffaaaaaaboss ที่มี = %d · nameplate ที่มี = %d ⇒ โชว์ %d ตัวแรก|r")
        :format(nBoss, nPlate, #units)
    if #units == 0 then
        head[#head + 1] = "|cffff9a9aไม่มี unit เลย (เปิด nameplate ด้วยปุ่ม V ก่อน)|r"
        return head
    end
    for _, l in ipairs(BuildEnumLines(units, false, true)) do head[#head + 1] = l end
    return head
end

-- ============================================================
-- UI — 3 คอลัมน์ (แบบเดียวกับ PlayerAuraProbe)
-- ============================================================

local frame
local colFS = {}
local pageLabel

-- เนื้อหาทั้งหมดเป็นบรรทัดเดียว ๆ แล้วไหลลง 3 คอลัมน์ต่อหน้าแบบหนังสือพิมพ์
-- (user ขอ 2026-08-18: ข้อมูลเต็มเฟรม ทำเป็นหลายหน้า)
local _lines = {}
local _page  = 1
local LINE_H = 16          -- ChatFontNormal ~14 + spacing 2 (บรรทัด wrap อาจกิน 2 แถว —
                           -- ค่าประมาณพอ เปลี่ยนหน้า/ขยายหน้าต่างได้)

local TITLE_H  = 24
local SIDE_PAD = 12
local COL_GAP  = 14
local TOP_ROW  = TITLE_H + 8 + 24 + 8

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

local function LinesPerCol()
    local h = 600
    if frame ~= nil then h = frame:GetHeight() - TOP_ROW - 28 end
    local n = math.floor(h / LINE_H)
    if n < 10 then n = 10 end
    return n
end

local function RenderPage()
    if not colFS[1] then return end
    local per = LinesPerCol()
    local totalPages = math.ceil(#_lines / (per * 3))
    if totalPages < 1 then totalPages = 1 end
    if _page > totalPages then _page = totalPages end
    if _page < 1 then _page = 1 end
    for c = 1, 3 do
        local startIdx = (_page - 1) * per * 3 + (c - 1) * per + 1
        local t = ""
        local last = startIdx + per - 1
        if last > #_lines then last = #_lines end
        for i = startIdx, last do
            t = t .. _lines[i] .. NL       -- ต่อด้วย .. (บรรทัดอาจเป็น secret string)
        end
        colFS[c]:SetText(t)
    end
    if pageLabel ~= nil then
        pageLabel:SetText(("หน้า %d/%d · %d บรรทัด"):format(_page, totalPages, #_lines))
    end
end

local function PageStep(d)
    _page = _page + d
    RenderPage()
end

local function Refresh()
    if not colFS[1] then return end
    _lines = {}
    local function add(arrFn, ...)
        local ok, arr = pcall(arrFn, ...)
        if ok and type(arr) == "table" then
            for _, l in ipairs(arr) do _lines[#_lines + 1] = l end
        else
            _lines[#_lines + 1] = "|cffff9a9aพัง: " .. tostring(arr) .. "|r"
        end
        _lines[#_lines + 1] = ""
    end
    add(BuildColALines)
    add(BuildColBLines)
    add(BuildEnumLines, { "target", "focus" }, true, false)
    add(BuildPlateLines)
    _page = 1
    RenderPage()
end

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "GeRODPSToolsTargetAuraProbe", UIParent,
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
    frame:SetScript("OnSizeChanged", function()
        Relayout()
        RenderPage()
    end)
    if frame.TitleText then frame.TitleText:SetText("Target Aura Probe — TargetFrame / tooltip enum") end
    table.insert(UISpecialFrames, "GeRODPSToolsTargetAuraProbe")

    local btnR = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnR:SetSize(110, 24)
    btnR:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 8))
    btnR:SetText("Refresh")
    btnR:SetScript("OnClick", Refresh)

    local btnPrev = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnPrev:SetSize(28, 24)
    btnPrev:SetPoint("LEFT", btnR, "RIGHT", 8, 0)
    btnPrev:SetText("<")
    btnPrev:SetScript("OnClick", function() PageStep(-1) end)

    local btnNext = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnNext:SetSize(28, 24)
    btnNext:SetPoint("LEFT", btnPrev, "RIGHT", 4, 0)
    btnNext:SetText(">")
    btnNext:SetScript("OnClick", function() PageStep(1) end)

    pageLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageLabel:SetPoint("LEFT", btnNext, "RIGHT", 8, 0)
    pageLabel:SetText("หน้า 1/1")

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", pageLabel, "RIGHT", 12, 0)
    hint:SetText("|cffaaaaaaเล็ง mob ที่มี DoT ของเรา (ห้ามเล็งตัวเอง) + อยู่ใน combat · "
        .. "คอลัมน์ 3 dump ทุกบรรทัดของ tooltip เพื่อหา stack/เวลา|r")

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

function TOOL.ShowTargetAuraProbe()
    local f = BuildFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        Refresh()
    end
end

TOOL.RegisterTool("Target Aura Probe (TargetFrame / tooltip enum)", TOOL.ShowTargetAuraProbe)
