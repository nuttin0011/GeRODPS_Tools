--[[
    GeRODPS_Tools / CDMAuraProbe.lua

    "CDM Aura Probe" — ตอบคำถามเดียว: **ของ 4 viewer ของ Cooldown Manager
    เราอ่าน "มีออร่าไหม / เหลือกี่วิ / กี่ stack" ออกมาได้จริงไหม และจากช่องไหน**

    เกณฑ์ของโปรเจกต์: ค่าที่ได้เป็น secret = **ผ่าน** (ส่งเข้า pixel/STS ให้ AHK อ่านต่อได้)
    ค่าที่เรียกแล้ว throw หรือ index ไม่ได้ = **ตก**
    ⇒ เครื่องมือนี้จึงไม่ได้ถามว่า "secret ไหม" เป็นหลัก แต่ถามว่า "หยิบออกมาได้ไหม"

    ── ⚠ ต้องมีอะไรตอนกด Probe (สำคัญมาก) ────────────────────────────────
      1. **ต้องมีบัฟ/ดีบัฟที่ CDM ติดตามอยู่ ติดอยู่จริง** ณ ตอนกด
         (เช่น Avatar / Bloodlust / บัฟ spec ตัวเอง) — ไม่มีออร่า = auraDataCached
         เป็น nil ทุกแถว ผลจะว่างเปล่าและพิสูจน์อะไรไม่ได้เลย
      2. **ต้องอยู่ใน combat** และ**อยู่ในดัน/ดันเจี้ยน** — นอก combat ออร่าไม่ secret
         ผลจะดู "ผ่านหมด" แบบหลอก ๆ (บทเรียนจากรอบที่วัดด้วย spellID 6603)
      3. viewer ที่จะดู **ต้องเปิดแสดงอยู่** — CooldownViewerMixin:OnHide() unregister
         UNIT_AURA ⇒ viewer ที่ซ่อนอยู่ค้างข้อมูลเก่า
      หัวหน้าต่างจะบอกให้เองว่าตอนนี้เงื่อนไขครบหรือยัง (แถบเขียว/แดง)

    ── ⚠ ทำไมไฟล์นี้ "อ่าน field" เป็นหลัก แทนที่จะเรียก method ────────────
      CooldownManagerLab.lua เจอมาแล้วว่าการไปยุ่งกับ Lua ของ Blizzard ทิ้ง taint ไว้บน
      viewer frame แล้ว **โค้ดของ Blizzard เองพัง** ทุก UNIT_AURA จนกว่าจะ /reload:
          CooldownViewer.lua:1861: attempted to index a table that cannot be
          accessed while tainted (execution tainted by 'GeRODPS_Tools')
      (เพราะ CooldownViewerSecure.lua ตี DisallowTaintedAccess ไว้ที่
       auraInstanceIDToItemFramesMap)
      ⇒ ที่นี่จึงอ่าน **field ธรรมดาบนเฟรม** เป็นหลัก (ไม่เขียนอะไรกลับ) และ method ที่
        เรียกมีแต่ getter ที่ไม่เขียนสถานะ · **ห้ามเพิ่มการเรียก GetAuraData() เด็ดขาด**
        (ตัวนั้นเขียน self.auraDataCached = ทำให้เฟรมติด taint ของเรา)

    ── สิ่งที่วัด (ต่อ item frame) ────────────────────────────────────────
      ระบุตัวตน : cooldownInfo.spellID · auraSpellID · wasSetFromAura
      มีออร่า   : auraDataCached ~= nil · IsActive()
      Remain    : auraDataCached.expirationTime/.duration · Bar:GetValue() ·
                  Cooldown:GetCooldownTimes()
      Stack     : auraDataCached.applications · Applications FontString:GetText()

    Public:
        GeRODPS_Tools.ShowCDMAuraProbe()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local TITLE_H  = 28     -- Rule 10: แถวแรกต้องเผื่อความสูง title bar
local SIDE_PAD = 14

-- ขอบเขตการย่อ/ขยายหน้าต่าง (ผลลัพธ์บรรทัดยาว จึงเผื่อกว้างไว้เยอะ)
local MIN_W, MIN_H = 700, 380
local MAX_W, MAX_H = 2400, 1500

local VIEWERS = {
    { name = "EssentialCooldownViewer", kind = "cooldown", label = "Essential" },
    { name = "UtilityCooldownViewer",   kind = "cooldown", label = "Utility" },
    { name = "BuffIconCooldownViewer",  kind = "buffIcon", label = "TrackedBuff" },
    { name = "BuffBarCooldownViewer",   kind = "buffBar",  label = "TrackedBar" },
}

-- ============================================================
-- ตัวจำแนกค่า — ห้าม compare / arithmetic บน secret (wow-coding Rule 1.5)
-- ใช้ได้แค่: เทียบกับ nil literal · type() · issecretvalue() · tostring()
-- ============================================================

local function IsSecret(v)
    if issecretvalue == nil then return false end
    local ok, res = pcall(issecretvalue, v)
    if not ok then return false end
    return res == true
end

-- แปลงเป็น "string ธรรมดา" เสมอ — กันไม่ให้ secret string หลุดเข้า out[]
-- (สำคัญ: บรรทัดสุดท้ายใช้ table.concat ซึ่ง throw ถ้ามี secret ปนอยู่ - Rule 1.5)
local function SafeStr(v)
    if v == nil then return "nil" end
    if IsSecret(v) then
        local ok, t = pcall(type, v)
        return "SECRET " .. (ok and t or "?")
    end
    return tostring(v)
end

-- คืนข้อความอธิบายค่า 1 ตัว โดยไม่ unmask
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

-- table เป็น "secret table" ไหม — ถ้าใช่ ห้าม index (forbidden = throw)
local function TableState(t)
    if t == nil then return "nil", false end
    if type(t) ~= "table" then return "NOT-TABLE(" .. type(t) .. ")", false end
    if issecrettable ~= nil then
        local ok, res = pcall(issecrettable, t)
        if ok and res == true then
            return "SECRET-TABLE (index=FORBIDDEN)", false
        end
        if ok then return "table (index ได้)", true end
        return "table (issecrettable ERR)", true
    end
    return "table (ไม่มี issecrettable ใน client นี้)", true
end

-- อ่าน field แบบกัน throw
local function Field(t, key)
    local ok, v = pcall(function() return t[key] end)
    if not ok then return "ERR " .. tostring(v) end
    return Cls(v)
end

-- เรียก getter แบบกัน throw (เฉพาะ getter ที่ไม่เขียนสถานะ)
local function Call(obj, method, ...)
    if obj == nil then return "nil-obj" end
    local ok, fn = pcall(function() return obj[method] end)
    if not ok then return "ERR index " .. tostring(fn) end
    if type(fn) ~= "function" then return "no-method" end
    local res = { pcall(fn, obj, ...) }
    if res[1] ~= true then return "ERR " .. tostring(res[2]) end
    local out = Cls(res[2])
    if res[3] ~= nil then out = out .. " , " .. Cls(res[3]) end
    return out
end

-- หา region ลูกแบบกัน nil ทีละชั้น
local function Sub(obj, ...)
    local cur = obj
    for i = 1, select("#", ...) do
        if cur == nil then return nil end
        local key = select(i, ...)
        local ok, nxt = pcall(function() return cur[key] end)
        if not ok then return nil end
        cur = nxt
    end
    return cur
end

-- ============================================================
-- สภาพแวดล้อมตอนวัด — บอก user ว่าผลเชื่อได้แค่ไหน
-- ============================================================

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

    -- ธงเตือนว่าเงื่อนไขยังไม่ครบ
    -- ⚠ เทียบ boolean ได้ต่อเมื่อไม่ใช่ secret (Rule 1.5: boolean test บน secret boolean = throw)
    local warn = {}
    if IsSecret(inCombat) then
        warn[#warn + 1] = "combat เป็น secret (เทียบไม่ได้)"
    elseif inCombat ~= true then
        warn[#warn + 1] = "ยังไม่อยู่ใน combat"
    end
    if aurasSecret ~= "true" then warn[#warn + 1] = "ออร่ายังไม่ secret" end
    if #warn > 0 then
        out[#out + 1] = "|cffff5555!! " .. table.concat(warn, " · ")
            .. " -> ผลยังพิสูจน์อะไรไม่ได้ ต้องยิงตอนอยู่ในดัน+combat+มีบัฟติด|r"
    else
        out[#out + 1] = "|cff44ff44เงื่อนไขครบ - ผลรอบนี้เชื่อได้|r"
    end
    return out
end

-- ============================================================
-- Probe หลัก
-- ============================================================

local function ProbeItem(f, kind, out, idx)
    -- ระบุตัวตน (คาดว่า plain ทั้งหมด)
    local ci = Sub(f, "cooldownInfo")
    local ciState, ciIndexable = TableState(ci)
    local spellID = ciIndexable and Field(ci, "spellID") or "-"

    out[#out + 1] = ("  [%d] spellID=%s  auraSpellID=%s  wasSetFromAura=%s  cooldownInfo=%s")
        :format(idx, spellID, Field(f, "auraSpellID"), Field(f, "wasSetFromAura"), ciState)

    -- มีออร่าไหม
    local a = Sub(f, "auraDataCached")
    local aState, aIndexable = TableState(a)
    out[#out + 1] = ("       auraDataCached=%s  auraDataUnit=%s  IsActive()=%s")
        :format(aState, Field(f, "auraDataUnit"), Call(f, "IsActive"))

    -- ค่าในตารางออร่า — index ได้ก็ต่อเมื่อไม่ใช่ secret table
    if aIndexable then
        out[#out + 1] = ("       .applications=%s  .expirationTime=%s  .duration=%s  .timeMod=%s")
            :format(Field(a, "applications"), Field(a, "expirationTime"),
                    Field(a, "duration"), Field(a, "timeMod"))
    end

    -- region ต่อชนิด viewer
    if kind == "buffBar" then
        local bar = Sub(f, "Bar")
        out[#out + 1] = ("       Bar:GetValue()=%s  GetMinMaxValues()=%s")
            :format(Call(bar, "GetValue"), Call(bar, "GetMinMaxValues"))
        out[#out + 1] = ("       Bar.Duration:GetText()=%s  Icon.Applications:GetText()=%s")
            :format(Call(Sub(f, "Bar", "Duration"), "GetText"),
                    Call(Sub(f, "Icon", "Applications"), "GetText"))
    elseif kind == "buffIcon" then
        out[#out + 1] = ("       Cooldown:GetCooldownTimes()=%s  GetCooldownDuration()=%s")
            :format(Call(Sub(f, "Cooldown"), "GetCooldownTimes"),
                    Call(Sub(f, "Cooldown"), "GetCooldownDuration"))
        out[#out + 1] = ("       Applications.Applications:GetText()=%s")
            :format(Call(Sub(f, "Applications", "Applications"), "GetText"))
    else -- cooldown (Essential / Utility)
        out[#out + 1] = ("       cooldownStartTime=%s  cooldownDuration=%s  cooldownModRate=%s")
            :format(Field(f, "cooldownStartTime"), Field(f, "cooldownDuration"),
                    Field(f, "cooldownModRate"))
        out[#out + 1] = ("       Cooldown:GetCooldownTimes()=%s  ChargeCount.Current:GetText()=%s")
            :format(Call(Sub(f, "Cooldown"), "GetCooldownTimes"),
                    Call(Sub(f, "ChargeCount", "Current"), "GetText"))
    end
end

-- คืน item frame ของ viewer โดยพยายามไม่แตะ Lua ของ Blizzard ถ้าเลี่ยงได้
local function GetItems(viewer)
    local ok, frames = pcall(function() return viewer:GetItemFrames() end)
    if ok and type(frames) == "table" then return frames, "GetItemFrames()" end
    -- fallback: GetChildren() เป็น C API ล้วน ไม่ผ่าน mixin ของ Blizzard
    local ok2, res = pcall(function() return { viewer:GetChildren() } end)
    if ok2 and type(res) == "table" then return res, "GetChildren() (fallback)" end
    return nil, "อ่านลูกไม่ได้: " .. tostring(frames)
end

-- showAll = true -> พิมพ์แถวที่ไม่มีออร่าด้วย (ไว้ยืนยันว่า IsActive() ตอน false ยัง plain
--                    และ auraDataCached เป็น nil จริง ไม่ใช่ secret table)
function TOOL.RunCDMAuraProbe(showAll)
    local out = {}
    out[#out + 1] = "== CDM Aura Probe ==" .. (showAll and "  [showAll]" or "")
    for _, l in ipairs(EnvLines()) do out[#out + 1] = l end
    out[#out + 1] = ""

    local anyAura = false

    for _, v in ipairs(VIEWERS) do
        local viewer = _G[v.name]
        if viewer == nil then
            out[#out + 1] = ("[%s] (%s) -- ไม่มี frame นี้"):format(v.name, v.label)
        else
            -- ⚠ IsVisible/IsShown ติด SecretReturnsForAspect{Shown} -> อาจคืน secret boolean
            --   ห้ามเอาไป `~= true` ตรง ๆ (Rule 1.5) ต้องเช็ค IsSecret ก่อน
            local okS, shown = pcall(function() return viewer:IsVisible() end)
            if not okS then shown = nil end

            local frames, how = GetItems(viewer)
            local n = frames and #frames or 0
            out[#out + 1] = ("[%s] (%s)  visible=%s  items=%d  via %s")
                :format(v.name, v.label, SafeStr(shown), n, how)
            if not IsSecret(shown) and shown ~= true then
                out[#out + 1] = "  |cffff5555!! viewer ถูกซ่อน -> OnHide unregister UNIT_AURA = ข้อมูลค้างเก่า|r"
            end

            if frames ~= nil then
                local printed, withAura = 0, 0
                for i = 1, n do
                    local f = frames[i]
                    -- ปกติสนใจเฉพาะแถวที่มีออร่าติดอยู่จริง (ไม่งั้นยาวและไม่มีข้อมูล)
                    -- showAll = ดูแถวเปล่าด้วย เพื่อเทียบว่า "ไม่มีออร่า" หน้าตาเป็นยังไง
                    local hasAura = false
                    local okA, a = pcall(function() return f.auraDataCached end)
                    if okA and a ~= nil then hasAura = true end
                    if hasAura then withAura = withAura + 1; anyAura = true end
                    if hasAura or showAll then
                        printed = printed + 1
                        ProbeItem(f, v.kind, out, i)
                    end
                end
                if withAura == 0 and printed == 0 then
                    out[#out + 1] = "  (ไม่มีแถวไหนมีออร่าติดอยู่ตอนนี้)"
                end
            end
            out[#out + 1] = ""
        end
    end

    if not anyAura then
        out[#out + 1] = "|cffff5555!! ไม่เจอออร่าเลยสักแถว -> ต้องกดตอนมีบัฟ/ดีบัฟที่ CDM ติดตามติดอยู่จริง"
        out[#out + 1] = "   ไม่งั้นผลรอบนี้ไม่ได้พิสูจน์อะไร|r"
    end

    out[#out + 1] = "-- อ่านผล: SECRET-TABLE = ตัน (index ไม่ได้) / SECRET xxx = ผ่าน (ส่งเข้า pixel ได้)"
    out[#out + 1] = "--         ERR = เรียกแล้ว throw = ใช้ไม่ได้ / nil = ไม่มีค่า"
    return table.concat(out, "\n")
end

-- ============================================================
-- UI
-- ============================================================

local frame, editBox, scrollFrame

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "GeRODPSToolsCDMAuraProbe", UIParent, "BasicFrameTemplateWithInset")
    -- แถวผลลัพธ์ยาว (~110 ตัวอักษร/บรรทัด) และมีหลายสิบบรรทัดต่อ viewer
    -- -> เริ่มที่เกือบเต็มจอ แล้วให้ย่อ/ขยายเองได้
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
    if frame.TitleText then frame.TitleText:SetText("CDM Aura Probe") end
    table.insert(UISpecialFrames, "GeRODPSToolsCDMAuraProbe")

    -- แถวแรก anchor ที่ frame + เผื่อ TITLE_H (Rule 10 — ห้ามพึ่ง frame.Inset)
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 8))
    hint:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + 8))
    hint:SetJustifyH("LEFT")
    hint:SetSpacing(3)
    hint:SetText("ต้องกดตอน: อยู่ในดัน + combat + มีบัฟ/ดีบัฟที่ CDM ติดตามติดอยู่จริง"
        .. "  |cffaaaaaa(นอก combat ออร่าไม่ secret -> ผลหลอก)|r")

    local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btn:SetSize(120, 24)
    btn:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
    btn:SetText("Probe")

    local btnCopy = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnCopy:SetSize(120, 24)
    btnCopy:SetPoint("LEFT", btn, "RIGHT", 8, 0)
    btnCopy:SetText("Select All")
    btnCopy:SetScript("OnClick", function()
        if editBox then editBox:SetFocus(); editBox:HighlightText() end
    end)

    scrollFrame = CreateFrame("ScrollFrame", "$parentScroll", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -8)
    -- เว้นล่าง 22 ให้ที่จับขยายมุมขวาล่าง ไม่ทับข้อความ
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

    btn:SetScript("OnClick", function()
        local ok, text = pcall(TOOL.RunCDMAuraProbe)
        editBox:SetText(ok and text or ("Probe พัง: " .. tostring(text)))
        editBox:SetCursorPosition(0)
    end)

    -- ที่จับย่อ/ขยายมุมขวาล่าง
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

    -- ปุ่มขยายเต็มจอ / คืนขนาดเดิม (เผื่อเวลาผลยาวมาก)
    local btnMax = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnMax:SetSize(120, 24)
    btnMax:SetPoint("LEFT", btnCopy, "RIGHT", 8, 0)
    btnMax:SetText("Full Screen")
    -- แถวที่ไม่มีออร่าถูกซ่อนไว้ปกติ — ปุ่มนี้โชว์ทั้งหมดเพื่อเทียบว่า "ไม่มีออร่า" หน้าตาเป็นยังไง
    local btnAll = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnAll:SetSize(150, 24)
    btnAll:SetPoint("LEFT", btn, "RIGHT", 8, 0)
    btnAll:SetText("Probe (ทุกแถว)")
    btnAll:SetScript("OnClick", function()
        local ok, text = pcall(TOOL.RunCDMAuraProbe, true)
        editBox:SetText(ok and text or ("Probe พัง: " .. tostring(text)))
        editBox:SetCursorPosition(0)
    end)
    btnCopy:ClearAllPoints()
    btnCopy:SetPoint("LEFT", btnAll, "RIGHT", 8, 0)

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

    return frame
end

function TOOL.ShowCDMAuraProbe()
    local f = BuildFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        local ok, text = pcall(TOOL.RunCDMAuraProbe)
        editBox:SetText(ok and text or ("Probe พัง: " .. tostring(text)))
        editBox:SetCursorPosition(0)
    end
end

TOOL.RegisterTool("CDM Aura Probe (มีออร่า / Remain / Stack)", TOOL.ShowCDMAuraProbe)
