--[[
    GeRODPS_Tools / CDMRouteTest.lua

    "CDM Route Test" — ตรวจ "เส้นทางที่เหลือ" ที่ CDM Aura Probe ยังไม่ได้ตอบ
    (CDM Aura Probe ตอบเรื่อง item frame ไปแล้ว: auraDataCached / Bar / Cooldown / IsActive)

    เกณฑ์เดิม: ได้ค่าเป็น secret = **ผ่าน** (ส่งเข้า pixel/STS ให้ AHK อ่าน)
               เรียกแล้ว throw หรือ index ไม่ได้ = **ตก**

    ── ตรวจ 3 เส้นทาง ────────────────────────────────────────────────────
      [A] C_CooldownViewer API — ได้ลิสต์เวทที่ CDM ติดตาม **โดยไม่ต้องมี frame**
          และไม่ขึ้นกับว่า viewer เปิดอยู่หรือไม่
              GetCooldownViewerCategorySet(category, allowUnlearned) -> {cooldownID}
              GetCooldownViewerCooldownInfo(cooldownID)              -> 15 field
          ถ้าผ่าน = เลิกพึ่ง viewer:GetItemFrames() สำหรับ "ทำลิสต์" ได้

      [D] ทาง spellID — GetPlayerAuraBySpellID / GetUnitAuraBySpellID /
          GetAuraDataBySpellName  (+ C_Secrets.GetSpellAuraSecrecy คัดกรองล่วงหน้า)
          ⚠ ทั้ง 3 ตัวติด predicate RequiresNonSecretAura ซึ่งเอกสารระบุว่า
            "ไม่ throw แต่ return no values" ⇒ คาดว่าได้ **nil** กับเวทที่ secret
            การทดสอบนี้คือดูว่าเวทของเราเข้าข่ายไหนบ้าง

      [M] itemFrame:GetCooldownValues() — method (ไม่ใช่ field) บน BuffIcon/BuffBar
          body อ่าน GetAuraDataCached() ล้วน ไม่เรียก API ⇒ คาดว่าผ่าน

    ── ⚠ ต้องกดตอนไหน ───────────────────────────────────────────────────
      อยู่ในดัน + combat + มีบัฟ/ดีบัฟที่ CDM ติดตามติดอยู่จริง
      (นอก combat ออร่าไม่ secret -> ทาง D จะดูผ่านแบบหลอก)
      หัวหน้าต่างขึ้นแถบเขียว/แดงบอกให้เอง

    ── ⚠ ไม่แตะ Lua ของ Blizzard ที่เขียนสถานะ ─────────────────────────
      เหตุผลเดียวกับ CDMAuraProbe.lua — CooldownManagerLab.lua เคยเจอ taint ค้าง
      บน viewer frame แล้วโค้ด Blizzard เองพังทุก UNIT_AURA
      ที่นี่เรียกแต่ C_* API กับ getter ที่ไม่เขียนสถานะ

    Public:
        GeRODPS_Tools.ShowCDMRouteTest()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local TITLE_H  = 28     -- Rule 10: แถวแรกต้องเผื่อความสูง title bar
local SIDE_PAD = 14
local MIN_W, MIN_H = 700, 380
local MAX_W, MAX_H = 2400, 1500

-- category ที่ Blizzard เดินจริง — **ตัด GroupBuff(4) ออก** เพราะมี API ของตัวเอง
local CATEGORIES = {
    { id = 0, name = "Essential" },
    { id = 1, name = "Utility" },
    { id = 2, name = "TrackedBuff" },
    { id = 3, name = "TrackedBar" },
    { id = 5, name = "SpecAgnosticEssential" },
    { id = 6, name = "SpecAgnosticTracked" },
    { id = 7, name = "EquipSlotEssential" },
    { id = 8, name = "EquipSlotTracked" },
}

local VIEWERS = {
    { name = "BuffIconCooldownViewer", label = "TrackedBuff" },
    { name = "BuffBarCooldownViewer",  label = "TrackedBar" },
}

-- ============================================================
-- helper — ห้าม compare / arithmetic บน secret (wow-coding Rule 1.5)
-- ============================================================

local function IsSecret(v)
    if issecretvalue == nil then return false end
    local ok, res = pcall(issecretvalue, v)
    if not ok then return false end
    return res == true
end

-- string ธรรมดาเสมอ — กัน secret หลุดเข้า list ที่จะ table.concat ตอนท้าย
local function SafeStr(v)
    if v == nil then return "nil" end
    if IsSecret(v) then
        local ok, t = pcall(type, v)
        return "SECRET " .. (ok and t or "?")
    end
    return tostring(v)
end

local function Cls(v)
    if v == nil then return "nil" end
    if IsSecret(v) then
        local ok, t = pcall(type, v)
        return "SECRET " .. (ok and t or "?")
    end
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then
        return t .. " " .. tostring(v)
    end
    return t
end

-- table เป็น secret table ไหม (ถ้าใช่ = index ไม่ได้ = ตัน)
local function TableState(t)
    if t == nil then return "nil", false end
    if type(t) ~= "table" then return "NOT-TABLE(" .. type(t) .. ")", false end
    if issecrettable ~= nil then
        local ok, res = pcall(issecrettable, t)
        if ok and res == true then return "SECRET-TABLE(ตัน)", false end
        if ok then return "table(index ได้)", true end
    end
    return "table", true
end

local function Field(t, key)
    local ok, v = pcall(function() return t[key] end)
    if not ok then return "ERR" end
    return Cls(v)
end

-- เรียก API/getter แบบกัน throw — คืน (ok, ...) เป็นข้อความล้วน
local function CallDesc(fn, ...)
    if type(fn) ~= "function" then return "no-func" end
    local res = { pcall(fn, ...) }
    if res[1] ~= true then return "ERR " .. SafeStr(res[2]) end
    local parts = {}
    for i = 2, #res do parts[#parts + 1] = Cls(res[i]) end
    if #parts == 0 then return "(ไม่คืนค่า)" end
    local out = parts[1]
    for i = 2, #parts do out = out .. " , " .. parts[i] end
    return out
end

local function SecrecyName(v)
    if v == nil then return "nil" end
    if IsSecret(v) then return "SECRET" end
    if Enum and Enum.SecrecyLevel then
        for k, n in pairs(Enum.SecrecyLevel) do
            if n == v then return tostring(v) .. "=" .. k end
        end
    end
    return tostring(v)
end

-- ============================================================
-- สภาพแวดล้อม
-- ============================================================

local function EnvLines(out)
    local inCombat = UnitAffectingCombat("player")
    local inInst, instType = IsInInstance()
    local aurasSecret = "?"
    if C_Secrets ~= nil and C_Secrets.ShouldAurasBeSecret ~= nil then
        local ok, v = pcall(C_Secrets.ShouldAurasBeSecret)
        if ok then aurasSecret = SafeStr(v) end
    end
    out[#out + 1] = ("combat=%s  instance=%s(%s)  ShouldAurasBeSecret=%s  target=%s")
        :format(SafeStr(inCombat), SafeStr(inInst), SafeStr(instType), aurasSecret,
                SafeStr(UnitExists("target")))
    local warn = {}
    if IsSecret(inCombat) then
        warn[#warn + 1] = "combat เป็น secret"
    elseif inCombat ~= true then
        warn[#warn + 1] = "ยังไม่อยู่ใน combat"
    end
    if aurasSecret ~= "true" then warn[#warn + 1] = "ออร่ายังไม่ secret" end
    if #warn > 0 then
        out[#out + 1] = "|cffff5555!! " .. table.concat(warn, " · ")
            .. " -> ทาง D จะดูผ่านแบบหลอก ต้องยิงตอนในดัน+combat|r"
    else
        out[#out + 1] = "|cff44ff44เงื่อนไขครบ - ผลรอบนี้เชื่อได้|r"
    end
end

-- ============================================================
-- [A] C_CooldownViewer API — ไม่ใช้ frame เลย
-- คืน list ของ { id, spellID, name, hasAura, selfAura, category }
-- ============================================================

local function RouteA(out)
    out[#out + 1] = "[A] C_CooldownViewer API (ไม่ใช้ frame / ไม่สนว่า viewer เปิดอยู่ไหม)"

    if C_CooldownViewer == nil then
        out[#out + 1] = "  |cffff5555C_CooldownViewer ไม่มีใน client นี้|r"
        return {}
    end

    out[#out + 1] = "  IsCooldownViewerAvailable() = "
        .. CallDesc(C_CooldownViewer.IsCooldownViewerAvailable)

    local entries, totalIDs, auraCount = {}, 0, 0

    for _, c in ipairs(CATEGORIES) do
        local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, c.id, true)
        if not ok then
            out[#out + 1] = ("  %-22s : ERR %s"):format(c.name, SafeStr(ids))
        elseif type(ids) ~= "table" then
            out[#out + 1] = ("  %-22s : %s"):format(c.name, Cls(ids))
        else
            local nAura = 0
            for _, id in ipairs(ids) do
                totalIDs = totalIDs + 1
                local ok2, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, id)
                if ok2 and type(info) == "table" then
                    local _, indexable = TableState(info)
                    if indexable then
                        local okS, sid = pcall(function() return info.spellID end)
                        local okA, hasAura = pcall(function() return info.hasAura end)
                        if okA and hasAura == true then
                            nAura = nAura + 1
                            auraCount = auraCount + 1
                            if okS and type(sid) == "number" then
                                local nm
                                if C_Spell and C_Spell.GetSpellName then
                                    local okN, n2 = pcall(C_Spell.GetSpellName, sid)
                                    if okN then nm = n2 end
                                end
                                entries[#entries + 1] = {
                                    id = id, spellID = sid, name = nm, cat = c.name,
                                }
                            end
                        end
                    end
                end
            end
            out[#out + 1] = ("  %-22s : %d ids  (hasAura %d)"):format(c.name, #ids, nAura)
        end
    end

    out[#out + 1] = "  GetGroupBuffItems() = " .. CallDesc(C_CooldownViewer.GetGroupBuffItems)

    -- โชว์ field ครบของ entry แรกที่มีออร่า เพื่อยืนยันว่า info อ่านได้จริง
    if entries[1] then
        local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, entries[1].id)
        if ok and type(info) == "table" then
            local st, indexable = TableState(info)
            out[#out + 1] = ("  ตัวอย่าง cooldownInfo (id=%d) = %s"):format(entries[1].id, st)
            if indexable then
                out[#out + 1] = ("    spellID=%s  overrideSpellID=%s  hasAura=%s  selfAura=%s  charges=%s  isKnown=%s  category=%s")
                    :format(Field(info, "spellID"), Field(info, "overrideSpellID"),
                            Field(info, "hasAura"), Field(info, "selfAura"),
                            Field(info, "charges"), Field(info, "isKnown"), Field(info, "category"))
            end
        end
    end

    if totalIDs > 0 then
        out[#out + 1] = ("  |cff44ff44=> ผ่าน: ได้ %d cooldownID (มีออร่า %d) โดยไม่แตะ frame เลย|r")
            :format(totalIDs, auraCount)
    else
        out[#out + 1] = "  |cffff5555=> ไม่ผ่าน: ไม่ได้ id เลย|r"
    end
    return entries
end

-- ============================================================
-- [D] ทาง spellID — บรรทัดละเวท
-- ============================================================

local function AuraResult(fn, ...)
    if type(fn) ~= "function" then return "no-func" end
    local ok, a = pcall(fn, ...)
    if not ok then return "ERR" end
    if a == nil then return "nil" end
    local st, indexable = TableState(a)
    if not indexable then return st end
    -- อ่าน field ตัวอย่าง 1 ตัวเพื่อดูว่า index เข้าได้จริง
    return st .. "/app=" .. Field(a, "applications")
end

local function RouteD(out, entries, manualID)
    out[#out + 1] = ""
    out[#out + 1] = "[D] ทาง spellID (GetPlayerAuraBySpellID / GetUnitAuraBySpellID / GetAuraDataBySpellName)"
    out[#out + 1] = "    รูปแบบ: secrecy | player | target | byName"

    if C_UnitAuras == nil then
        out[#out + 1] = "  |cffff5555C_UnitAuras ไม่มี|r"
        return
    end

    local list = {}
    if manualID ~= nil then
        local nm
        if C_Spell and C_Spell.GetSpellName then
            local okN, n2 = pcall(C_Spell.GetSpellName, manualID)
            if okN then nm = n2 end
        end
        list[#list + 1] = { spellID = manualID, name = nm, cat = "(พิมพ์เอง)" }
    end
    for _, e in ipairs(entries) do list[#list + 1] = e end

    if #list == 0 then
        out[#out + 1] = "  (ไม่มีเวทให้ทดสอบ — ทาง A ไม่คืนเวทที่มีออร่า)"
        return
    end

    local nData, nNil, nErr = 0, 0, 0
    local shown = 0
    for _, e in ipairs(list) do
        if shown >= 40 then break end
        shown = shown + 1

        local secrecy = "?"
        if C_Secrets ~= nil and C_Secrets.GetSpellAuraSecrecy ~= nil then
            local ok, v = pcall(C_Secrets.GetSpellAuraSecrecy, e.spellID)
            if ok then secrecy = SecrecyName(v) else secrecy = "ERR" end
        end

        local rPlayer = AuraResult(C_UnitAuras.GetPlayerAuraBySpellID, e.spellID)
        local rTarget = "no-target"
        if UnitExists("target") then
            rTarget = AuraResult(C_UnitAuras.GetUnitAuraBySpellID, "target", e.spellID)
        end
        local rName = "no-name"
        if type(e.name) == "string" and not IsSecret(e.name) then
            rName = AuraResult(C_UnitAuras.GetAuraDataBySpellName, "player", e.name, "HELPFUL")
        elseif IsSecret(e.name) then
            rName = "name-secret"
        end

        for _, r in ipairs({ rPlayer, rTarget, rName }) do
            if r == "nil" then nNil = nNil + 1
            elseif r == "ERR" then nErr = nErr + 1
            elseif r ~= "no-target" and r ~= "no-name" and r ~= "no-func" then nData = nData + 1 end
        end

        out[#out + 1] = ("  %-7s %-26s [%s] %s | P:%s | T:%s | N:%s")
            :format(SafeStr(e.spellID), SafeStr(e.name), SafeStr(e.cat),
                    secrecy, rPlayer, rTarget, rName)
    end

    if #list > shown then
        out[#out + 1] = ("  ... อีก %d เวท (ตัดไว้ให้อ่านง่าย)"):format(#list - shown)
    end
    out[#out + 1] = ("  |cffffcc55=> สรุป: ได้ข้อมูล %d · nil %d · ERR %d|r"):format(nData, nNil, nErr)
    out[#out + 1] = "  |cffaaaaaa   nil = RequiresNonSecretAura ตัดทิ้ง (ไม่ error แต่ไม่ได้ข้อมูล)"
    out[#out + 1] = "     ถ้าได้ข้อมูลเฉพาะเวทที่ secrecy = NeverSecret แปลว่าทางนี้ใช้เป็น fast-path ได้เท่านั้น|r"
end

-- ============================================================
-- [M] itemFrame:GetCooldownValues()
-- ============================================================

local function RouteM(out)
    out[#out + 1] = ""
    out[#out + 1] = "[M] itemFrame:GetCooldownValues()  (method — body อ่าน auraDataCached ล้วน)"
    local any = false
    for _, v in ipairs(VIEWERS) do
        local viewer = _G[v.name]
        if viewer ~= nil then
            local ok, frames = pcall(function() return viewer:GetItemFrames() end)
            if ok and type(frames) == "table" then
                for i = 1, #frames do
                    local f = frames[i]
                    local okA, a = pcall(function() return f.auraDataCached end)
                    if okA and a ~= nil then
                        any = true
                        local sid = "?"
                        local okC, ci = pcall(function() return f.cooldownInfo end)
                        if okC and type(ci) == "table" then sid = Field(ci, "spellID") end
                        local fn
                        local okF, res = pcall(function() return f.GetCooldownValues end)
                        if okF then fn = res end
                        out[#out + 1] = ("  %-24s [%d] spellID=%s"):format(v.label, i, sid)
                        out[#out + 1] = ("      GetCooldownValues() = %s"):format(
                            type(fn) == "function" and CallDesc(fn, f) or "ไม่มี method นี้")
                    end
                end
            end
        end
    end
    if not any then
        out[#out + 1] = "  (ไม่มีแถวไหนมีออร่าติดอยู่ตอนนี้ — ต้องมีบัฟ/ดีบัฟติดจริง)"
    end
end

-- ============================================================
-- รวม
-- ============================================================

function TOOL.RunCDMRouteTest(manualID)
    local out = {}
    out[#out + 1] = "== CDM Route Test =="
    EnvLines(out)
    out[#out + 1] = ""
    local entries = RouteA(out)
    RouteD(out, entries, manualID)
    RouteM(out)
    if TOOL.RouteELines then TOOL.RouteELines(out) end
    out[#out + 1] = ""
    out[#out + 1] = "-- อ่านผล: SECRET xxx = ผ่าน (ส่งเข้า pixel ได้) / SECRET-TABLE = ตัน"
    out[#out + 1] = "--         ERR = throw = ใช้ไม่ได้ / nil = ไม่มีข้อมูล (ไม่ error)"
    return table.concat(out, "\n")
end

-- ============================================================
-- UI
-- ============================================================

local frame, editBox, idBox

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "GeRODPSToolsCDMRouteTest", UIParent, "BasicFrameTemplateWithInset")
    local defW = math.min(MAX_W, math.max(MIN_W, math.floor(UIParent:GetWidth() * 0.88)))
    local defH = math.min(MAX_H, math.max(MIN_H, math.floor(UIParent:GetHeight() * 0.82)))
    frame:SetSize(defW, defH)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetResizable(true)
    if frame.SetResizeBounds then frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H) end
    frame:SetClampedToScreen(true)
    frame:Hide()
    if frame.TitleText then frame.TitleText:SetText("CDM Route Test") end
    table.insert(UISpecialFrames, "GeRODPSToolsCDMRouteTest")

    -- แถวแรก anchor ที่ frame + เผื่อ TITLE_H (Rule 10)
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 8))
    hint:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + 8))
    hint:SetJustifyH("LEFT")
    hint:SetText("[A] ลิสต์จาก API ไม่ใช้ frame  ·  [D] ทาง spellID  ·  [M] GetCooldownValues()"
        .. "   |cffaaaaaaกดตอนในดัน + combat + มีบัฟติด|r")

    local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btn:SetSize(110, 24)
    btn:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
    btn:SetText("Run")

    local lbl = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", btn, "RIGHT", 10, 0)
    lbl:SetText("Spell ID เพิ่มเอง:")

    idBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    idBox:SetSize(90, 22)
    idBox:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    idBox:SetAutoFocus(false)
    idBox:SetNumeric(true)
    idBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local btnCopy = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnCopy:SetSize(110, 24)
    btnCopy:SetPoint("LEFT", idBox, "RIGHT", 12, 0)
    btnCopy:SetText("Select All")
    btnCopy:SetScript("OnClick", function()
        if editBox then editBox:SetFocus(); editBox:HighlightText() end
    end)

    local btnE = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnE:SetSize(130, 24)
    btnE:SetPoint("LEFT", btnCopy, "RIGHT", 12, 0)
    btnE:SetText("สร้าง ทาง E")
    btnE:SetScript("OnClick", function()
        if TOOL.BuildCDMRouteE then
            TOOL.BuildCDMRouteE(tonumber(idBox:GetText()))
        end
        if frame._run then frame._run() end
    end)

    local scrollFrame = CreateFrame("ScrollFrame", "$parentScroll", frame, "UIPanelScrollFrameTemplate")
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

    local function Run()
        local manual = tonumber(idBox:GetText())
        local ok, text = pcall(TOOL.RunCDMRouteTest, manual)
        editBox:SetText(ok and text or ("Run พัง: " .. tostring(text)))
        editBox:SetCursorPosition(0)
    end
    btn:SetScript("OnClick", Run)
    idBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); Run() end)
    frame._run = Run

    local resize = CreateFrame("Button", nil, frame)
    resize:SetSize(16, 16)
    resize:SetPoint("BOTTOMRIGHT", -4, 4)
    resize:EnableMouse(true)
    resize:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    resize:SetPushedTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Down")
    resize:SetScript("OnMouseDown", function(_, b)
        if b == "LeftButton" then frame:StopMovingOrSizing(); frame:StartSizing("BOTTOMRIGHT") end
    end)
    resize:SetScript("OnMouseUp", function(_, b)
        if b == "LeftButton" then frame:StopMovingOrSizing() end
    end)

    return frame
end

function TOOL.ShowCDMRouteTest()
    local f = BuildFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        if f._run then f._run() end
    end
end


-- ============================================================
-- [E] CustomAuraContainer — ท่อที่ Blizzard เปิดให้ addon
--
-- หลักการ: เรายื่น FontString / StatusBar ของเราเองให้ Blizzard แล้วโค้ด secure
-- ของมันเขียน stack + เวลาที่เหลือลงไปให้ ⇒ Lua เราไม่ต้องแตะ secret เลย
--
-- ⚠ อ่านค่ากลับใน Lua ไม่ได้ (widget ถูกตี SecretAspect) ⇒ **ตัดสินด้วยตา**
--   ถ้าเห็นแถบเดินถอยหลัง + ตัวเลข stack ขึ้น = ผ่าน
--
-- กฎที่ยืนยันจาก source (พลาดข้อใดข้อหนึ่ง = ไม่ขึ้นอะไรเลย เงียบ ๆ):
--   * container = CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")
--     (XML ของ container มี allowUntaintedCreation="true" — ของปุ่มไม่มี)
--   * **ห้ามส่ง templateNames** — provider prepend "CustomAuraButtonTemplate" ให้เองเสมอ
--   * candidateFilters.includeSpellIDs เป็น **map { [spellID] = true }** ไม่ใช่ array
--   * container ต้อง Show() ไม่งั้นไม่ register UNIT_AURA เลย
--   * 1 container = 1 unit ⇒ player กับ target ต้องคนละตัว
--   * slot frame ต้อง SetSize + SetPoint เอง (ไม่เข้า dynamic layout)
--   * ทุกอย่างต้องทำใน initializeFrame — access restriction ลงหลัง callback จบ
--   * region ที่ยื่นให้ ต้องเป็น "ลูก" ของ frame นั้น (RegionUtil.IsDescendantOf)
--   * duration bar default direction = ElapsedTime (เดินหน้า) ต้องสั่ง RemainingTime เอง
--   * target ไม่ auto-refresh ตอนเปลี่ยนเป้า ต้องเรียก UpdateAllAuras() เอง
-- ============================================================

local eState = { built = false, log = {} }

local function BuildOneContainer(parent, unitToken, filterString, spellID, yOffset, label)
    local log = eState.log
    local container = CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yOffset)
    container:Show()                      -- บังคับ: ไม่ Show = ไม่ register UNIT_AURA
    container:SetUnit(unitToken)          -- 1 container = 1 unit

    local function InitSlotFrame(slotFrame)
        -- ทุกอย่างต้องอยู่ในนี้ — restriction ลงทันทีที่ callback จบ
        slotFrame:SetSize(36, 36)
        slotFrame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)

        local icon = slotFrame:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints(slotFrame)
        slotFrame:SetIcon(icon)

        local count = slotFrame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        count:SetPoint("BOTTOMRIGHT", slotFrame, "BOTTOMRIGHT", -2, 2)
        slotFrame:SetApplicationCount(count, nil)   -- stack (ว่างถ้า <= 1 เมื่อไม่ใส่ formatter)

        local bar = CreateFrame("StatusBar", nil, slotFrame)
        bar:SetPoint("LEFT", slotFrame, "RIGHT", 6, 0)
        bar:SetSize(180, 14)
        bar:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
        bar:SetStatusBarColor(0.2, 0.7, 1.0)
        local dirOpts = {}
        if Enum and Enum.StatusBarTimerDirection then
            dirOpts.direction = Enum.StatusBarTimerDirection.RemainingTime
        end
        if Enum and Enum.StatusBarInterpolation then
            dirOpts.interpolation = Enum.StatusBarInterpolation.Immediate
        end
        slotFrame:SetDurationBar(bar, dirOpts)

        local timeText = slotFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        timeText:SetPoint("LEFT", bar, "RIGHT", 8, 0)
        slotFrame:SetDurationText(timeText, nil)

        local nameFS = slotFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        nameFS:SetPoint("LEFT", timeText, "RIGHT", 10, 0)
        nameFS:SetText(label)                  -- ป้ายของเราเอง ไม่ใช่ของ Blizzard
    end

    local okSlot, err = pcall(function()
        return container:AddAuraSlot("probe", filterString, {
            initializeFrame  = InitSlotFrame,
            -- templateNames  = ห้ามใส่
            candidateFilters = { includeSpellIDs = { [spellID] = true } },
        })
    end)
    log[#log + 1] = ("  %-28s unit=%-7s filter=%-14s AddAuraSlot=%s")
        :format(label, unitToken, filterString, okSlot and "OK" or ("ERR " .. SafeStr(err)))
    return container
end

function TOOL.BuildCDMRouteE(spellID)
    eState.log = {}
    local log = eState.log
    if spellID == nil then
        log[#log + 1] = "  |cffff5555ใส่ Spell ID ในช่องก่อน|r"
        return
    end
    if eState.built then
        log[#log + 1] = "  |cffffcc55สร้างไปแล้วรอบนี้ — ถ้าจะเปลี่ยน spellID ต้อง /reload ก่อน|r"
        log[#log + 1] = "  |cffaaaaaa(ไม่มี RemoveAuraSlot ใน API — slot ถอดไม่ได้)|r"
        return
    end

    local host = CreateFrame("Frame", "GeRODPSToolsRouteEHost", UIParent)
    host:SetSize(460, 96)
    host:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
    local bg = host:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(host)
    bg:SetColorTexture(0, 0, 0, 0.55)
    eState.host = host

    local ok1 = pcall(BuildOneContainer, host, "player", "HELPFUL", spellID, -8, "player buff")
    local ok2, tgtContainer = pcall(BuildOneContainer, host, "target", "HARMFUL|PLAYER", spellID, -50, "target debuff")
    if ok2 then eState.targetContainer = tgtContainer end
    local okAll = ok1 and ok2

    if ok2 then
        -- target ไม่ auto-refresh ตอนเปลี่ยนเป้า ต้องสั่งเอง
        local ev = CreateFrame("Frame")
        ev:RegisterEvent("PLAYER_TARGET_CHANGED")
        ev:SetScript("OnEvent", function()
            if eState.targetContainer then
                pcall(function() eState.targetContainer:UpdateAllAuras() end)
            end
        end)
    end

    eState.built = true
    log[#log + 1] = okAll and "  |cff44ff44สร้างสำเร็จ - ดูกล่องดำกลางจอ|r"
                           or "  |cffff5555สร้างไม่สำเร็จ ดู ERR ข้างบน|r"
end

function TOOL.RouteELines(out)
    out[#out + 1] = ""
    out[#out + 1] = "[E] CustomAuraContainer (ท่อที่ Blizzard เปิดให้ addon)"
    if not eState.built then
        out[#out + 1] = "  ยังไม่ได้สร้าง — ใส่ Spell ID แล้วกดปุ่ม \"สร้าง ทาง E\""
        out[#out + 1] = "  |cffaaaaaaอ่านค่ากลับใน Lua ไม่ได้ (widget ถูกตี SecretAspect)"
        out[#out + 1] = "  => ตัดสินด้วยตา: เห็นแถบเดินถอยหลัง + เลข stack = ผ่าน|r"
        return
    end
    for _, l in ipairs(eState.log) do out[#out + 1] = l end
    out[#out + 1] = "  |cffaaaaaaถ้ากล่องว่างเปล่าทั้งที่ออร่าติดอยู่ = ทางนี้ใช้ไม่ได้"
    out[#out + 1] = "  ถ้าเห็นไอคอน+แถบเดิน = ผ่าน (Blizzard เขียนค่า secret ลง widget ของเราให้)|r"
end

TOOL.RegisterTool("CDM Route Test (API ทาง A / spellID ทาง D)", TOOL.ShowCDMRouteTest)
