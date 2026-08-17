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

local function JoinLines(out)
    local t = ""
    for _, line in ipairs(out) do
        t = t .. line .. NL
    end
    return t
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

local function BuildColA()
    local out = {}
    local u = "target"
    out[#out + 1] = "combat = " .. (InCombatLockdown()
        and "|cff44ff44IN COMBAT|r" or "|cffff9a9aOUT (ผลหลอก!)|r")
    out[#out + 1] = "target มีตัวไหม = " .. (UnitExists(u) and "|cff44ff44yes|r" or "|cffff9a9ano|r")
    if C_Secrets ~= nil and C_Secrets.ShouldAurasBeSecret ~= nil then
        local okS, sv = pcall(C_Secrets.ShouldAurasBeSecret)
        out[#out + 1] = "ShouldAurasBeSecret() = " .. (okS and PeekVal(sv) or ShortErr(sv))
    end
    out[#out + 1] = ""
    out[#out + 1] = "|cff88ccff== A) เดิน path จาก fstack ==|r"
    local af = WalkAuraFrame(out)
    if af == nil then return JoinLines(out) end

    -- ลูกของ Auras frame
    local kids
    if af.GetChildren ~= nil then
        local okC, res = pcall(function() return { af:GetChildren() } end)
        if okC then kids = res end
    end
    if type(kids) ~= "table" then
        out[#out + 1] = "   |cffff9a9aGetChildren() อ่านไม่ได้|r"
        return JoinLines(out)
    end
    out[#out + 1] = ("   ลูกทั้งหมด = %d เฟรม"):format(#kids)

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
    return JoinLines(out)
end

-- ============================================================
-- B · legacy global names + ทางเลือกโครงอื่น
-- ============================================================

local function BuildColB()
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
        -- กวาด key ของ TargetFrame ที่มีคำว่า aura/buff (case-insensitive)
        local hits = {}
        pcall(function()
            for k in pairs(tf) do
                if type(k) == "string" then
                    local lk = k:lower()
                    if lk:find("aura") or lk:find("buff") then hits[#hits + 1] = k end
                end
            end
        end)
        if #hits > 0 then
            table.sort(hits)
            local line = ""
            for _, k in ipairs(hits) do line = line .. k .. ", " end
            out[#out + 1] = "   |cff3fcf5akey ที่มีคำ aura/buff:|r " .. line
        end
    end
    return JoinLines(out)
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
    local id, nm
    if tip.GetTooltipData ~= nil then
        local okD, d = pcall(tip.GetTooltipData, tip)
        if okD and type(d) == "table" then id = d.id end
    end
    if l1 ~= nil and l1.GetText ~= nil then
        local okT, v = pcall(l1.GetText, l1)
        if okT then nm = v end
    end
    -- ทุกบรรทัด — FontString ชื่อ <tip>TextLeftN (อ่านตรง ไม่ผ่าน GetTooltipData
    -- เพราะ lines[] ของ data อาจเป็น table ซ้อนที่อ่านยากกว่า)
    local lines = {}
    for li = 1, MAX_TIP_LINES do
        local fs = _G[TIP_NAME .. "TextLeft" .. li]
        if fs == nil or fs.GetText == nil then break end
        local okL, txt = pcall(fs.GetText, fs)
        if okL and txt ~= nil then
            lines[#lines + 1] = txt
        end
    end
    pcall(function() tip:Hide() end)
    return true, id, nm, nil, lines
end

local MAX_IDX = 12

local function EnumUnit(unit, filter, label, out)
    out[#out + 1] = "   |cffffd200" .. label .. "|r"
    local hit, blank = 0, 0
    for i = 1, MAX_IDX do
        local ok, id, nm, err, lines = ProbeIndex(unit, i, filter, "SetUnitAura")
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
            -- hit แรก: dump ทุกบรรทัด — ดูว่า stack/เวลาอยู่ในข้อความไหม
            if hit == 1 and type(lines) == "table" then
                for li = 2, #lines do
                    out[#out + 1] = ("         line%d = "):format(li) .. PeekVal(lines[li])
                end
            end
        end
    end
    out[#out + 1] = ("      -> เจอ %d ตัว"):format(hit)
end

local function BuildColC()
    local out = {}
    out[#out + 1] = "|cff88ccff== C) enumerate ด้วย tooltip เพียว ๆ ==|r"
    out[#out + 1] = "|cff44ff44✅ วัดแล้ว 2026-08-18: arg unit ทำงานจริง|r"
    out[#out + 1] = "|cffaaaaaa(target=dummy ได้ Total Damage Done / Touch of the Magi ไม่ใช่ buff ของเรา)"
    out[#out + 1] = "รอบก่อนที่เหมือน player หมด เพราะเลงตัวเองอยู่ ⇒ บรรทัด identity ข้างล่างกันอ่านผิดซ้ำ|r"
    out[#out + 1] = "|cffaaaaaaClearLines ก่อนทุก index (กันอ่านค่าค้างของ index ก่อนหน้า)|r"
    out[#out + 1] = ""

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

    for _, u in ipairs({ "target", "focus", "boss1", "nameplate1" }) do
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
    return JoinLines(out)
end

-- ============================================================
-- UI — 3 คอลัมน์ (แบบเดียวกับ PlayerAuraProbe)
-- ============================================================

local frame
local colFS = {}

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

local function Refresh()
    if not colFS[1] then return end
    local builders = { BuildColA, BuildColB, BuildColC }
    for i = 1, 3 do
        local ok, text = pcall(builders[i])
        colFS[i]:SetText(ok and text or ("พัง: " .. tostring(text)))
    end
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
    frame:SetScript("OnSizeChanged", Relayout)
    if frame.TitleText then frame.TitleText:SetText("Target Aura Probe — TargetFrame / tooltip enum") end
    table.insert(UISpecialFrames, "GeRODPSToolsTargetAuraProbe")

    local btnR = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnR:SetSize(110, 24)
    btnR:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 8))
    btnR:SetText("Refresh")
    btnR:SetScript("OnClick", Refresh)

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", btnR, "RIGHT", 10, 0)
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
