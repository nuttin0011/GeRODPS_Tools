--[[
    GeRODPS_Tools / PlayerAuraProbe.lua

    "Player Aura Probe" — ตอบคำถามเดียว: **จาก BuffFrame / DebuffFrame ของ player
    (Route B) เราดึงอะไรออกมาได้บ้าง เพื่อชุบชีวิต DefPlayerDebuff (slot 6) ที่ตาย
    เพราะ aura_present_v3 ใช้ C_UnitAuras**

    ที่มาของ field (อ่านจาก source dump bfsrc/Blizzard_BuffFrame/BuffFrame.lua):
      · frame.auraInfo[]  = { auraType, debuffType(=dispelName!), index, texture,
                              count, duration, expirationTime, timeMod }
        ⚠ แถวปกติ **ไม่มี spellId** — ตัวระบุตัวตนมีแค่ texture (icon fileID)
      · frame.auraFrames[] = ปุ่ม (AuraButtonTemplate) — ปนกับ anchor (isAuraAnchor)
      · btn.buttonInfo    = แถว auraInfo ที่ปุ่มถืออยู่
      · btn.timeLeft      = ⭐ remain วินาที Blizzard คำนวณให้ทุกเฟรม (OnUpdate)
      · btn.Duration      = FontString ("8 s" หยาบ)
      · DebuffFrame.deadlyDebuffInfo[] = เฉพาะ deadly — มี spellID + auraInstanceID จริง

    วัด 2 ชั้นแบบ NameplateAuraProbe:
      (1) หยิบออกมาได้ไหม (PeekVal render + ป้าย [S] = secret)
      (2) **เอาไปคำนวณ/เทียบใน Lua ได้ไหม** (arithmetic / string-compare ใน pcall)
          — ตัวตัดสินว่า writer ใหม่คำนวณเองได้ หรือส่งดิบให้ AHK เหมือน NMA/Dispel v2

    ⚠ ตอนกด Probe: **ต้องอยู่ใน combat + มี buff/debuff ติดตัวจริง** (นอก combat
      ออร่าไม่ secret ผลจะ "ผ่านหมด" แบบหลอก ๆ) · debuff หาได้จากยืนในของพื้นในดัน
    ⚠ อ่านอย่างเดียว — getter + field read เท่านั้น ห่อ pcall ทุกจุด ห้ามเขียนสถานะ
    ⚠ FontString เท่านั้น ห้าม EditBox (copy = GetText = unmask secret)
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

--- render ค่าอะไรก็ได้เป็นข้อความ (secret ก็ได้ — FontString วาดได้) + ป้าย [S]
local function PeekVal(v)
    if v == nil then return "nil" end
    local tag = IsSecret(v) and "|cffffcc55[S]|r" or ""
    local ok, res = pcall(function() return "" .. tostring(v) end)
    if ok then return res .. tag end
    return "<เรนเดอร์ไม่ได้>" .. tag
end

local function ShortErr(e)
    return (tostring(e):gsub("\n.*", ""):sub(1, 90))
end

--- tier-2: ลองทำ op ใน pcall แล้วรายงานผล (นี่คือตัวตัดสินดีไซน์ writer ใหม่)
-- ⚠ ผลลัพธ์อาจเป็น secret string (PeekVal ของค่า secret) — ห้ามเอาไป :sub/:gsub ต่อ
local function TryOp(label, fn)
    local ok, r = pcall(fn)
    if ok then
        return "      |cff44ff44Lua ทำได้:|r " .. label .. " = " .. PeekVal(r)
    end
    return "      |cffff9a9aLua ทำไม่ได้ (THROW):|r " .. label .. " — " .. ShortErr(r)
end

-- field ตามลำดับจาก source (bfsrc) — เดินตามนี้ก่อน แล้วค่อยกวาด key แปลก
local ROW_FIELDS = { "auraType", "debuffType", "index", "texture", "count",
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
    -- กวาด key ที่ source ไม่ได้บอก (กันตกหล่น field ใหม่ของ 12.1)
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

-- ============================================================
-- probe ต่อเฟรม (BuffFrame / DebuffFrame)
-- ============================================================

local MAX_ROWS = 6      -- แถว auraInfo ที่โชว์ละเอียด
local MAX_BTNS = 6      -- ปุ่มที่โชว์ละเอียด

local function ProbeFrame(frameName, out)
    local f = _G[frameName]
    out[#out + 1] = "|cff88ccff== " .. frameName .. " ==|r"
    if f == nil then
        out[#out + 1] = "   |cffff9a9aไม่มีเฟรมนี้|r"
        return
    end

    -- ── ชั้นข้อมูล: frame.auraInfo ────────────────────────────────────
    local info = f.auraInfo
    if type(info) ~= "table" then
        out[#out + 1] = "   auraInfo = " .. PeekVal(info) .. " |cffff9a9a(ไม่ใช่ table — อ่านทางนี้ไม่ได้)|r"
    else
        out[#out + 1] = ("   auraInfo = table  #%d แถว"):format(#info)
        for i = 1, math.min(#info, MAX_ROWS) do
            local row = info[i]
            out[#out + 1] = ("   |cffffd200[แถว %d]|r"):format(i)
            if type(row) == "table" then
                DumpKnown(row, ROW_FIELDS, "      ", out)
                if i == 1 then
                    -- tier-2 กับแถวแรก: อะไรคำนวณ/เทียบใน Lua ได้บ้าง
                    out[#out + 1] = "   |cffffd200-- tier-2 (แถว 1): Lua คำนวณเองได้ไหม --|r"
                    local exp, tex, dt = row.expirationTime, row.texture, row.debuffType
                    out[#out + 1] = TryOp("expirationTime - GetTime()",
                        function() return exp - GetTime() end)
                    out[#out + 1] = TryOp("texture + 0 (เลข icon)",
                        function() return tex + 0 end)
                    out[#out + 1] = TryOp('debuffType == "Magic"',
                        function() return dt == "Magic" end)
                    out[#out + 1] = TryOp("debuffType == nil (เทียบ nil เฉย ๆ)",
                        function() return dt == nil end)
                end
            else
                out[#out + 1] = "      = " .. PeekVal(row)
            end
        end
        if #info > MAX_ROWS then
            out[#out + 1] = ("   ... อีก %d แถว"):format(#info - MAX_ROWS)
        end
    end

    -- ── ชั้นปุ่ม: frame.auraFrames ────────────────────────────────────
    local btns = f.auraFrames
    if type(btns) ~= "table" then
        out[#out + 1] = "   auraFrames = " .. PeekVal(btns) .. " |cffff9a9a(ไม่ใช่ table)|r"
    else
        out[#out + 1] = ("   auraFrames = table  #%d ปุ่ม (รวม anchor)"):format(#btns)
        local shown = 0
        for i = 1, #btns do
            if shown >= MAX_BTNS then break end
            local b = btns[i]
            if type(b) == "table" then
                -- ข้าม anchor แบบ plain-true เท่านั้น (secret boolean ห้าม if-test)
                local anchor = b.isAuraAnchor
                local skipAnchor = (anchor == true) and not IsSecret(anchor)
                local vis = false
                local okV, sv = pcall(function() return b:IsShown() end)
                if okV and sv == true then vis = true end
                if not skipAnchor and vis then
                    shown = shown + 1
                    out[#out + 1] = ("   |cffffd200[ปุ่ม %d]|r"):format(i)
                    DumpKnown(b, BTN_FIELDS, "      ", out)
                    -- Duration FontString (ทางหยาบ) + Icon texture
                    if b.Duration ~= nil and b.Duration.GetText ~= nil then
                        local okT, txt = pcall(b.Duration.GetText, b.Duration)
                        out[#out + 1] = "      Duration:GetText() = "
                            .. (okT and PeekVal(txt) or ("THROW " .. ShortErr(txt)))
                    end
                    if b.Icon ~= nil and b.Icon.GetTexture ~= nil then
                        local okI, texv = pcall(b.Icon.GetTexture, b.Icon)
                        out[#out + 1] = "      Icon:GetTexture() = "
                            .. (okI and PeekVal(texv) or ("THROW " .. ShortErr(texv)))
                    end
                    -- buttonInfo = แถว auraInfo ที่ปุ่มถือ
                    if type(b.buttonInfo) == "table" then
                        out[#out + 1] = "      buttonInfo:"
                        DumpKnown(b.buttonInfo, ROW_FIELDS, "         ", out)
                    else
                        out[#out + 1] = "      buttonInfo = " .. PeekVal(b.buttonInfo)
                    end
                    if shown == 1 then
                        out[#out + 1] = "   |cffffd200-- tier-2 (ปุ่มแรก): timeLeft ใช้ตรง ๆ ได้ไหม --|r"
                        local tl = b.timeLeft
                        out[#out + 1] = TryOp("timeLeft + 0",
                            function() return tl + 0 end)
                        out[#out + 1] = TryOp("timeLeft > 0.4",
                            function() return tl > 0.4 end)
                    end
                end
            end
        end
        if shown == 0 then
            out[#out + 1] = "   |cffaaaaaa(ไม่มีปุ่มที่แสดงอยู่ — ไม่มีออร่า หรือ anchor ล้วน)|r"
        end
    end
end

-- ============================================================
-- ประกอบข้อความทั้งหมด
-- ============================================================

local function BuildText()
    local out = {}
    out[#out + 1] = "|cffffd200== Player Aura Probe — BuffFrame / DebuffFrame (Route B) ==|r"
    out[#out + 1] = "|cffaaaaaaอ่านด้วยตาเท่านั้น copy ไม่ได้ · [S] = ค่าเป็น secret · ลากมุมขวาล่างขยาย|r"
    out[#out + 1] = ""

    -- ── ENV: สถานะที่ทำให้ผลตีความได้ ────────────────────────────────
    local inCombat = InCombatLockdown() and "|cff44ff44IN COMBAT|r" or "|cffff9a9aOUT OF COMBAT (ผลหลอก!)|r"
    out[#out + 1] = "combat = " .. inCombat .. "    GetTime() = " .. ("%.1f"):format(GetTime())
    if C_Secrets ~= nil and C_Secrets.ShouldAurasBeSecret ~= nil then
        local okS, sv = pcall(C_Secrets.ShouldAurasBeSecret)
        out[#out + 1] = "ShouldAurasBeSecret() = " .. (okS and PeekVal(sv) or ShortErr(sv))
    end
    -- เส้นเก่า (ที่ DefPlayerDebuff ใช้แล้วตาย) — โชว์สถานะสด ๆ เทียบกัน
    if C_UnitAuras ~= nil and C_UnitAuras.GetAuraDataByIndex ~= nil then
        local okA, d = pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, "HARMFUL")
        if not okA then
            out[#out + 1] = 'เส้นเก่า GetAuraDataByIndex("player",1,"HARMFUL") : |cffff9a9aTHROW|r '
                .. ShortErr(d)
        elseif d == nil then
            out[#out + 1] = 'เส้นเก่า GetAuraDataByIndex("player",1,"HARMFUL") : nil'
                .. ' (ไม่มี debuff หรือโดนบล็อกเงียบ)'
        else
            out[#out + 1] = 'เส้นเก่า GetAuraDataByIndex("player",1,"HARMFUL") : '
                .. '|cff44ff44ได้ table|r (ยังไม่ secret ตอนนี้)'
        end
    end
    out[#out + 1] = ""

    ProbeFrame("BuffFrame", out)
    out[#out + 1] = ""
    ProbeFrame("DebuffFrame", out)
    out[#out + 1] = ""

    -- ── deadly debuff (มี spellID จริง — เฉพาะเวทในลิสต์ deadly ของ Blizzard) ──
    out[#out + 1] = "|cff88ccff== DebuffFrame.deadlyDebuffInfo (มี spellID เฉพาะ deadly) ==|r"
    local df = _G["DebuffFrame"]
    local dd = df and df.deadlyDebuffInfo
    if type(dd) ~= "table" then
        out[#out + 1] = "   = " .. PeekVal(dd)
    else
        out[#out + 1] = ("   #%d แถว"):format(#dd)
        for i = 1, math.min(#dd, 4) do
            local row = dd[i]
            out[#out + 1] = ("   |cffffd200[deadly %d]|r"):format(i)
            if type(row) == "table" then
                DumpKnown(row, { "spellID", "auraInstanceID", "debuffType", "texture",
                    "count", "duration", "expirationTime", "warningText", "priority" }, "      ", out)
            end
        end
    end

    -- ⚠ ห้าม table.concat — บางบรรทัดเป็น secret string (invalid value (secret) for concat
    -- เจอจริง 2026-08-18) · ต่อด้วย .. ทีละบรรทัด = taint-preserving ถูกกติกา
    local t = ""
    for _, line in ipairs(out) do
        t = t .. line .. NL
    end
    return t
end

-- ============================================================
-- UI — FontString popup (แบบเดียวกับ Read Secret ของ DispelCurveTest)
-- ============================================================

local frame, fs

local TITLE_H  = 24
local SIDE_PAD = 12

local function Refresh()
    if not fs then return end
    local ok, text = pcall(BuildText)
    fs:SetText(ok and text or ("พัง: " .. tostring(text)))
end

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "GeRODPSToolsPlayerAuraProbe", UIParent,
        "BasicFrameTemplateWithInset")
    frame:SetSize(820, 640)
    frame:SetPoint("CENTER", 60, 0)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetResizable(true)
    if frame.SetResizeBounds then frame:SetResizeBounds(520, 320, 1900, 1350) end
    frame:SetClampedToScreen(true)
    frame:SetClipsChildren(true)
    frame:SetFrameStrata("DIALOG")
    if frame.TitleText then frame.TitleText:SetText("Player Aura Probe — Buff/Debuff Frame") end
    table.insert(UISpecialFrames, "GeRODPSToolsPlayerAuraProbe")

    -- Rule 10: แถวแรกเผื่อ title bar
    local btnR = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnR:SetSize(110, 24)
    btnR:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 8))
    btnR:SetText("Refresh")
    btnR:SetScript("OnClick", Refresh)

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("LEFT", btnR, "RIGHT", 10, 0)
    hint:SetText("|cffaaaaaaกดตอน IN COMBAT + มี buff/debuff ติดตัวจริงเท่านั้น (นอก combat = ผลหลอก)|r")

    -- ⚠ FontString เท่านั้น — ห้ามเปลี่ยนเป็น EditBox (secret unmask ตอน copy)
    fs = frame:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    fs:SetPoint("TOPLEFT", btnR, "BOTTOMLEFT", 0, -8)
    fs:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, 0)
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(true)
    fs:SetSpacing(2)

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
