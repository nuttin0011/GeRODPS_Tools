--[[
    GeRODPS_Tools / AuraSensorLab.lua

    "Aura Sensor Lab" — พิสูจน์ดีไซน์ **sensor container**: สร้าง CustomAuraContainer
    ของเราเองผูกกับ unit ใดก็ได้ แล้วให้ **ฝั่ง C วาดข้อมูล aura ลง widget ของเรา**
    จากนั้นเราอ่าน widget ตัวเอง (ทางที่พิสูจน์แล้วกับปุ่ม nameplate)

    ═══ ที่มา (อ่านจาก BetterBlizzFrames midnight/modules/auras.lua · 2026-08-18) ═══
      container = CreateFrame("AuraContainer", nil, parent, "CustomAuraContainerTemplate")
      container:SetUnit(unit)
      container:AddAuraGroup(key, filterString, {
          maxFrameCount = n, layout = {...},
          initializeFrame = function(button) ... end,   -- 🔑 เรียกตอน C สร้างปุ่ม
      })
      container:SetAuraGroupCandidateFilters(key, { includeSpellIDs = {[id]=true} })
      -- ต่อปุ่ม: ยื่น widget ให้ C เขียน
      button:SetIcon(texture) · button:SetApplicationCount(fontString)
      button:SetDurationCooldown(cooldownFrame)
      filterString ใช้ AuraUtil.AuraFilters ("HELPFUL"/"HARMFUL" + "!" negation)

    ── สิ่งที่ lab นี้ต้องตอบ (ยังไม่เคยวัดสักข้อ) ────────────────────────
      S1 CreateFrame("AuraContainer") จากโค้ดเราทำงานไหม (BBF ทำได้ = น่าจะได้)
      S2 initializeFrame ถูกเรียกจริง + ปุ่มเกิดเมื่อ aura ตรง filter โผล่
      S3 **ใน combat**: C ยังเขียน stack ลง FontString ของเรา + fill Cooldown ต่อไหม
      S4 อ่าน widget ตัวเอง: Count:GetText() / Cooldown:GetCooldownTimes() /
         btn:IsShown() — ตัวไหน plain ตัวไหน secret (คาด: เหมือนปุ่ม nameplate)
      S5 GetAuraGroupFrameCount/GetAuraGroupFrame ใน combat = ได้เลข? throw?
         (BBF gate ด้วย AurasAreSecret ⇒ คาดว่า throw — วัดให้เห็น)
      S6 includeSpellIDs whitelist ทำงานไหม (ใส่ id แล้วโชว์เฉพาะตัวนั้น)
      S7 ปุ่มเกิดกลาง combat: initializeFrame ยังถูกเรียกไหม (ตัวชี้ขาดดีไซน์จริง)

    ⚠ อ่าน/สร้างของเราเองเท่านั้น — ไม่แตะเฟรม aura ของ Blizzard เลย (กัน taint)
    ⚠ FontString รายงานเท่านั้น ห้าม EditBox โชว์ค่า (secret unmask ตอน copy)
    ⚠ secret string: ต่อด้วย .. เท่านั้น ห้าม table.concat/:sub/table.sort กับค่า
]]

local TOOL = GeRODPS_Tools

local NL = string.char(10)

-- ============================================================
-- helpers (ชุดเดียวกับ probe อื่น)
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
-- sensor state
-- ============================================================

local frame, reportFS, unitEB, idsEB, statusFS
local sensor            -- AuraContainer ของเรา
local sensorStrip       -- แถบที่ให้ C วาดปุ่ม (มองเห็นจริง = หลักฐานว่ามันวาด)
local _buttons = {}     -- ปุ่มที่ initializeFrame เคยเห็น: { btn=..., grp=..., born=GetTime, inCombat=bool }
local _initLog = {}     -- log เหตุการณ์ initializeFrame (พิสูจน์ S2/S7)

local GROUPS = {
    { key = "buff",   filter = "HELPFUL" },
    { key = "debuff", filter = "HARMFUL" },
}

local function ParseIDs(text)
    local set, n = {}, 0
    for tok in tostring(text or ""):gmatch("[^,%s]+") do
        local id = tonumber(tok)
        if id and id > 0 then
            set[id] = true
            n = n + 1
        end
    end
    return set, n
end

--- ผูก widget ของเราเข้าปุ่มที่ C เพิ่งสร้าง (ลอกลำดับจาก BBF InitAuraButton)
local function InitSensorButton(button, grpKey)
    _initLog[#_initLog + 1] = ("%.1f %s%s"):format(GetTime(), grpKey,
        InCombatLockdown() and " |cffff9a9a(เกิดกลาง combat!)|r" or "")

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetAllPoints(button)
    button.gerIcon = icon
    button:SetIcon(icon)

    local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    cd:SetAllPoints(icon)
    cd:SetReverse(true)
    cd:SetDrawEdge(true)
    cd:SetDrawBling(false)
    cd:SetHideCountdownNumbers(false)
    button.gerCooldown = cd
    button:SetDurationCooldown(cd)

    local overlay = CreateFrame("Frame", nil, button)
    overlay:SetAllPoints(button)
    overlay:SetFrameLevel(cd:GetFrameLevel() + 1)
    local cnt = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    cnt:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 1, 0)
    button.gerCount = cnt
    button:SetApplicationCount(cnt)

    _buttons[#_buttons + 1] = {
        btn = button, grp = grpKey,
        born = GetTime(), inCombat = InCombatLockdown() and true or false,
    }
end

local function DestroySensor()
    if sensor ~= nil then
        pcall(function() sensor:Hide() end)
        pcall(function() sensor:SetParent(nil) end)
        sensor = nil
    end
    _buttons = {}
    _initLog = {}
end

--- สร้าง sensor ใหม่ตามช่อง unit + spellID CSV
local function BuildSensor()
    DestroySensor()

    local unit = (unitEB and unitEB:GetText() ~= "" ) and unitEB:GetText() or "target"
    local ids, nIDs = ParseIDs(idsEB and idsEB:GetText() or "")

    local ok, c = pcall(CreateFrame, "AuraContainer", nil, sensorStrip,
        "CustomAuraContainerTemplate")
    if not ok or c == nil then
        if statusFS then
            statusFS:SetText("|cffff3333CreateFrame(AuraContainer) พัง: "
                .. ShortErr(c) .. "|r")
        end
        return
    end
    sensor = c
    sensor:SetPoint("TOPLEFT", sensorStrip, "TOPLEFT", 4, -4)
    sensor:SetSize(1, 1)
    sensor:SetUnit(unit)
    if sensor.SetFlowLayoutAxis then
        sensor:SetFlowLayoutAxis(AnchorUtil.FlowLayoutAxis.Horizontal)
        sensor:SetFlowLayoutAnchorPoint("TOPLEFT")
        sensor:SetFlowLayoutGrowthDirection(AnchorUtil.FlowDirection.Right,
            AnchorUtil.FlowDirection.Down)
        sensor:SetFlowLayoutPadding(0, 0, 0, 0)
    end

    -- ลำดับ apply ครบชุดตาม BBF ConfigureContainer (:1454-1526) — รอบก่อน
    -- ไม่ populate เพราะขาด SetAuraGroupMaxFrameCount (explicit) + layout ใช้
    -- key ผิด (elementSize ไม่มีจริง — ของจริงคือ elementWidth/elementHeight
    -- จาก ApplyGroupLayout :1372 ⇒ ปุ่มอาจ 0x0)
    for gi, g in ipairs(GROUPS) do
        local grpKey = g.key
        sensor:AddAuraGroup(grpKey, g.filter, {
            maxFrameCount = 0,
            initializeFrame = function(button)
                InitSensorButton(button, grpKey)
            end,
        })
        -- candidate filters: BBF เรียกเสมอ (ว่าง = ไม่กรอง)
        if sensor.SetAuraGroupCandidateFilters then
            if nIDs > 0 then
                sensor:SetAuraGroupCandidateFilters(grpKey, { includeSpellIDs = ids })
            else
                sensor:SetAuraGroupCandidateFilters(grpKey, {})
            end
        end
        -- จำนวนปุ่มที่ให้แสดง — BBF: 0 = ปิด group ⇒ ต้องตั้ง explicit
        sensor:SetAuraGroupMaxFrameCount(grpKey, 8)
        -- layout: field ชื่อจริงจาก BBF layoutScratch (:1381-1386)
        sensor:SetAuraGroupLayout(grpKey, {
            elementSpacing   = 3,
            lineSpacing      = 3,
            elementWidth     = 30,
            elementHeight    = 30,
            layoutIndex      = gi,
            groupLineSpacing = 3,
        })
    end
    if sensor.SetEnabled then sensor:SetEnabled(true) end
    sensor:Show()

    -- ** จุดที่ขาดรอบแรก (วัด 2026-08-18: ปุ่ม pre-create 10+10 แต่ไม่ populate เลย
    -- icon ค้าง 134400) — BBF เรียก container:UpdateAllAuras() หลังตั้งค่าเสมอ (:3147)
    local okU, errU = pcall(sensor.UpdateAllAuras, sensor)
    if not okU and statusFS then
        statusFS:SetText("|cffff3333UpdateAllAuras พัง: " .. ShortErr(errU) .. "|r")
        return
    end

    if statusFS then
        statusFS:SetText(("|cff44ff44สร้างแล้ว|r unit=%s · filter id %d ตัว"
            .. " (0 = เอาทุก aura) · ปุ่มจะโผล่ในแถบล่างเมื่อ aura ตรงเงื่อนไข")
            :format(unit, nIDs))
    end
end

-- ============================================================
-- รายงาน
-- ============================================================

local function BuildReport()
    local out = {}
    out[#out + 1] = "combat = " .. (InCombatLockdown()
        and "|cff44ff44IN COMBAT|r" or "|cffaaaaaaOUT|r")
        .. "   GetTime() = " .. ("%.1f"):format(GetTime())
    if C_Secrets ~= nil and C_Secrets.ShouldAurasBeSecret ~= nil then
        local okS, sv = pcall(C_Secrets.ShouldAurasBeSecret)
        out[#out + 1] = "ShouldAurasBeSecret() = " .. (okS and PeekVal(sv) or ShortErr(sv))
    end
    if sensor == nil then
        out[#out + 1] = ""
        out[#out + 1] = "|cffffcc55ยังไม่ได้สร้าง sensor — ใส่ unit + spellID แล้วกด [สร้าง Sensor]|r"
        return out
    end

    do
        local okE, ev = pcall(sensor.IsEnabled, sensor)
        out[#out + 1] = "IsEnabled() = " .. (okE and PeekVal(ev) or ShortErr(ev))
    end

    -- S8: UpdateAllAuras ใน combat ทำได้ไหม (เรียกทุก Refresh — ถ้า throw
    -- แปลว่า container ต้องพึ่ง event ของตัวเองใน combat ห้ามสั่งเอง)
    do
        local okU, errU = pcall(sensor.UpdateAllAuras, sensor)
        out[#out + 1] = ""
        if okU then
            out[#out + 1] = "S8: UpdateAllAuras() |cff44ff44ไม่ throw|r"
        else
            out[#out + 1] = "S8: UpdateAllAuras(): |cffff9a9aTHROW|r " .. ShortErr(errU)
        end
    end

    -- S5: enumeration API ใน combat ทำได้ไหม (BBF เลี่ยง — วัดให้เห็นกับตา)
    out[#out + 1] = ""
    out[#out + 1] = "|cff88ccff== S5: enumeration API (คาดว่า throw ใน combat) ==|r"
    for _, g in ipairs(GROUPS) do
        local okN, n = pcall(sensor.GetAuraGroupFrameCount, sensor, g.key)
        if okN then
            out[#out + 1] = "   GetAuraGroupFrameCount(" .. g.key .. ") = " .. PeekVal(n)
        else
            out[#out + 1] = "   GetAuraGroupFrameCount(" .. g.key .. "): |cffff9a9aTHROW|r "
                .. ShortErr(n)
        end
    end

    -- S2/S7: ปุ่มที่เคยเกิด + log
    out[#out + 1] = ""
    out[#out + 1] = ("|cff88ccff== ปุ่มที่ initializeFrame เคยเห็น = %d ==|r"):format(#_buttons)
    for i = 1, math.min(#_initLog, 6) do
        out[#out + 1] = "   |cff888888init: " .. _initLog[i] .. "|r"
    end

    -- S3/S4: อ่าน widget ของเราเอง
    local nowS = GetTime()
    for i, rec in ipairs(_buttons) do
        if i > 10 then
            out[#out + 1] = ("   ... อีก %d ปุ่ม"):format(#_buttons - 10)
            break
        end
        local b = rec.btn
        local shown = "?"
        local okV, sv = pcall(function() return b:IsShown() end)
        if okV then shown = PeekVal(sv) end
        out[#out + 1] = ("|cffffd200[%d · %s]|r shown=%s"):format(i, rec.grp, shown)

        if b.gerCount ~= nil then
            local okT, tv = pcall(b.gerCount.GetText, b.gerCount)
            out[#out + 1] = "   stack (Count:GetText) = |cff3fcf5a"
                .. (okT and PeekVal(tv) or ShortErr(tv)) .. "|r"
        end
        if b.gerCooldown ~= nil then
            local okC, st, du = pcall(b.gerCooldown.GetCooldownTimes, b.gerCooldown)
            if okC then
                out[#out + 1] = "   GetCooldownTimes: st=" .. PeekVal(st)
                    .. "  dur=" .. PeekVal(du)
                    .. "  |cffaaaaaa(now*1000=" .. ("%.0f"):format(nowS * 1000) .. ")|r"
            else
                out[#out + 1] = "   GetCooldownTimes: |cffff9a9aTHROW|r " .. ShortErr(st)
            end
            if b.gerCooldown.GetCountdownFontString ~= nil then
                local okF, fs2 = pcall(b.gerCooldown.GetCountdownFontString, b.gerCooldown)
                if okF and fs2 ~= nil then
                    local okX, xv = pcall(fs2.GetText, fs2)
                    out[#out + 1] = "   countdown text = " .. (okX and PeekVal(xv) or "?")
                end
            end
        end
        if b.gerIcon ~= nil then
            local okI, iv = pcall(b.gerIcon.GetTexture, b.gerIcon)
            out[#out + 1] = "   icon = " .. (okI and PeekVal(iv) or "?")
        end
    end
    if #_buttons == 0 then
        out[#out + 1] = "   |cffaaaaaa(ยังไม่มีปุ่มเกิด — unit นั้นยังไม่มี aura ที่ตรง filter"
        out[#out + 1] = "   หรือ filter id ไม่ตรงสักตัว)|r"
    end
    return out
end

local function Refresh()
    if not reportFS then return end
    local ok, lines = pcall(BuildReport)
    if not ok then
        reportFS:SetText("พัง: " .. tostring(lines))
        return
    end
    local t = ""
    for _, l in ipairs(lines) do
        t = t .. l .. NL          -- ต่อด้วย .. (บรรทัดอาจเป็น secret string)
    end
    reportFS:SetText(t)
end

-- ============================================================
-- UI
-- ============================================================

local TITLE_H  = 24
local SIDE_PAD = 12

local function BuildFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "GeRODPSToolsAuraSensorLab", UIParent,
        "BasicFrameTemplateWithInset")
    frame:SetSize(880, 720)
    frame:SetPoint("CENTER", 80, 0)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetResizable(true)
    if frame.SetResizeBounds then frame:SetResizeBounds(640, 420, 1800, 1300) end
    frame:SetClampedToScreen(true)
    frame:SetClipsChildren(true)
    frame:SetFrameStrata("DIALOG")
    if frame.TitleText then frame.TitleText:SetText("Aura Sensor Lab — CustomAuraContainer") end
    table.insert(UISpecialFrames, "GeRODPSToolsAuraSensorLab")

    -- แถวควบคุม (Rule 10: เผื่อ title bar)
    local unitLbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    unitLbl:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 12))
    unitLbl:SetText("unit:")

    unitEB = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    unitEB:SetSize(90, 20)
    unitEB:SetPoint("LEFT", unitLbl, "RIGHT", 8, 0)
    unitEB:SetAutoFocus(false)
    unitEB:SetText("target")

    local idsLbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    idsLbl:SetPoint("LEFT", unitEB, "RIGHT", 12, 0)
    idsLbl:SetText("spellID (CSV, ว่าง=ทุกตัว):")

    idsEB = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    idsEB:SetSize(220, 20)
    idsEB:SetPoint("LEFT", idsLbl, "RIGHT", 8, 0)
    idsEB:SetAutoFocus(false)
    idsEB:SetText("")

    local btnMake = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnMake:SetSize(110, 24)
    btnMake:SetPoint("LEFT", idsEB, "RIGHT", 10, 0)
    btnMake:SetText("สร้าง Sensor")
    btnMake:SetScript("OnClick", function()
        BuildSensor()
        Refresh()
    end)

    local btnR = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnR:SetSize(90, 24)
    btnR:SetPoint("LEFT", btnMake, "RIGHT", 6, 0)
    btnR:SetText("Refresh")
    btnR:SetScript("OnClick", Refresh)

    statusFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    statusFS:SetPoint("TOPLEFT", unitLbl, "BOTTOMLEFT", 0, -8)
    statusFS:SetPoint("RIGHT", frame, "RIGHT", -SIDE_PAD, 0)
    statusFS:SetJustifyH("LEFT")
    statusFS:SetText("|cffaaaaaaใส่ unit (target/focus/player) + spellID ที่จะเฝ้า แล้วกด สร้าง Sensor|r")

    -- แถบ sensor (ให้ C วาดปุ่มตรงนี้ — มองเห็นจริง = หลักฐาน)
    sensorStrip = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    sensorStrip:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 62))
    sensorStrip:SetPoint("RIGHT", frame, "RIGHT", -SIDE_PAD, 0)
    sensorStrip:SetHeight(76)
    local bg = sensorStrip:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(sensorStrip)
    bg:SetColorTexture(0.06, 0.10, 0.06, 0.6)
    local stripLbl = sensorStrip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stripLbl:SetPoint("BOTTOMLEFT", sensorStrip, "BOTTOMLEFT", 4, 3)
    stripLbl:SetText("|cff3fcf5aแถบ sensor — ปุ่มที่ C วาดจะโผล่ตรงนี้|r")

    -- รายงาน
    reportFS = frame:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    reportFS:SetPoint("TOPLEFT", sensorStrip, "BOTTOMLEFT", 0, -8)
    reportFS:SetPoint("RIGHT", frame, "RIGHT", -SIDE_PAD, 0)
    reportFS:SetJustifyH("LEFT")
    reportFS:SetJustifyV("TOP")
    reportFS:SetWordWrap(true)
    reportFS:SetSpacing(2)

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

function TOOL.ShowAuraSensorLab()
    local f = BuildFrame()
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        Refresh()
    end
end

TOOL.RegisterTool("Aura Sensor Lab (CustomAuraContainer)", TOOL.ShowAuraSensorLab)
