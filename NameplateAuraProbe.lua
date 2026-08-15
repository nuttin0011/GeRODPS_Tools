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
-- UI
-- ============================================================

local frame, editBox, scrollFrame

local function Refresh(showAll)
    if not editBox then return end
    local ok, text = pcall(TOOL.RunNameplateAuraProbe, showAll)
    editBox:SetText(ok and text or ("Probe พัง: " .. tostring(text)))
    editBox:SetCursorPosition(0)
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
