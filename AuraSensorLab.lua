--[[
    GeRODPS_Tools / AuraSensorLab.lua

    "Aura Sensor Lab" v2 — พิสูจน์ดีไซน์ **sensor slot**: CustomAuraContainer +
    AddAuraSlot ให้ **ฝั่ง C เขียนข้อมูล aura ลง widget ของเรา** แล้วเราอ่าน widget
    ตัวเองใน combat (ทางเดียวกับที่อ่านปุ่ม nameplate สำเร็จ)

    ═══ ทำไม v2 ═══
    v1 ใช้ AddAuraGroup ตามแบบ BetterBlizzFrames — ตั้งครบทุกอย่างแล้ว
    (filter/candidate/maxFrameCount/layout/SetEnabled/UpdateAllAuras) ก็ยัง
    **ไม่ populate** (ปุ่ม pre-create 10+10 icon ค้าง 134400 shown=false ตลอด)
    ⇒ สลับมาเส้นทางที่ **พิสูจน์แล้วในบ้านเราเอง**: CustomAuraProbe.lua (session
    ก่อน) ใช้ **AddAuraSlot** แล้ววาดจริง (memory: "Blizzard วาดต่อใน combat")

    ═══ สูตรที่พิสูจน์แล้ว (ลอกจาก CustomAuraProbe.lua:418-470) ═══
      · **container ต่อ 1 slot** · สร้างบน UIParent ก่อน แล้วค่อยย้าย parent
      · **ห้ามสร้างใน combat** (เสี่ยง taint template — กติกาเดียวกับ CMC)
      · container:SetUnit(unit)
      · container:AddAuraSlot(key, filterString, {
            initializeFrame  = function(slotBtn) ... end,
            candidateFilters = { includeSpellIDs = { [id] = true } },  -- MAP (optional)
        })
      · ใน initializeFrame: slotBtn:SetSize + สร้าง region แล้วยื่นให้ C เขียน:
            SetIcon(texture) · SetDurationCooldown(cd) · SetApplicationCount(fs, nil)
            SetDurationText(fs, nil) · SetSpellName(fs) · SetDispelTypeText(fs, nil)
      · ไม่ต้อง UpdateAllAuras / SetEnabled / maxFrameCount / layout ใด ๆ

    ── สิ่งที่ v2 ต้องตอบ ────────────────────────────────────────────────
      S3 ใน combat: C ยังอัปเดต widget ของเราต่อไหม (icon/stack/cooldown/ชื่อ/dispel)
      S4 อ่าน widget ตัวเอง: ตัวไหน plain ตัวไหน secret
      S6 candidateFilters ราย spellID ทำงานไหม (pin id แล้วโชว์เฉพาะตัวนั้น)
      S9 SetSpellName / SetDispelTypeText — C เขียนให้จริงไหม (BBF ไม่ได้ใช้ด้วยซ้ำ)

    ⚠ อ่าน/สร้างของเราเองเท่านั้น — ไม่แตะเฟรม aura ของ Blizzard (กัน taint)
    ⚠ FontString รายงานเท่านั้น ห้าม EditBox โชว์ค่า (secret unmask ตอน copy)
    ⚠ secret string: ต่อด้วย .. เท่านั้น ห้าม table.concat/:sub/table.sort กับค่า
]]

local TOOL = GeRODPS_Tools

local NL = string.char(10)
local CONTAINER_TEMPLATE = "CustomAuraContainerTemplate"

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
-- state
-- ============================================================

local frame, reportFS, unitEB, idsEB, statusFS, sensorStrip
local _slots = {}      -- { key, filter, spellID, container, btn, icon, cd,
                       --   countFS, durFS, nameFS, dispelFS, initLog, born }

local SLOT_W, SLOT_H, SLOT_GAP = 42, 42, 8

local function ParseIDs(text)
    local list = {}
    for tok in tostring(text or ""):gmatch("[^,%s]+") do
        local id = tonumber(tok)
        if id and id > 0 then list[#list + 1] = id end
    end
    return list
end

-- ============================================================
-- slot build (ลอกลำดับจาก CustomAuraProbe.BuildSlotRegions)
-- ============================================================

local function BuildSlotRegions(entry, slotBtn)
    entry.btn = slotBtn
    local log = {}
    local function try(name, fn)
        local ok, err = pcall(fn)
        log[#log + 1] = ok and (name .. ":ok") or (name .. ":|cffff9a9aERR|r " .. ShortErr(err))
    end

    slotBtn:SetSize(SLOT_W - 2, SLOT_H - 2)

    local icon = slotBtn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints(slotBtn)
    entry.icon = icon
    try("SetIcon", function() slotBtn:SetIcon(icon) end)

    local cd = CreateFrame("Cooldown", nil, slotBtn, "CooldownFrameTemplate")
    cd:SetAllPoints(icon)
    cd:SetReverse(true)
    cd:SetDrawEdge(true)
    cd:SetHideCountdownNumbers(false)
    entry.cd = cd
    try("SetDurationCooldown", function() slotBtn:SetDurationCooldown(cd) end)

    local countFS = slotBtn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    countFS:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1)
    entry.countFS = countFS
    try("SetApplicationCount", function() slotBtn:SetApplicationCount(countFS, nil) end)

    -- 3 ตัวนี้ BBF ไม่ได้ใช้ด้วยซ้ำ — C เขียน "ข้อความ" ให้ตรง ๆ (S9)
    local durFS = slotBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    durFS:SetPoint("TOP", slotBtn, "BOTTOM", 0, -1)
    entry.durFS = durFS
    try("SetDurationText", function() slotBtn:SetDurationText(durFS, nil) end)

    local nameFS = slotBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameFS:SetPoint("BOTTOM", slotBtn, "TOP", 0, 1)
    entry.nameFS = nameFS
    try("SetSpellName", function() slotBtn:SetSpellName(nameFS) end)

    local dispelFS = slotBtn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    dispelFS:SetPoint("TOP", durFS, "BOTTOM", 0, -1)
    entry.dispelFS = dispelFS
    try("SetDispelTypeText", function() slotBtn:SetDispelTypeText(dispelFS, nil) end)

    entry.initLog = table.concat(log, "  ")   -- ทุกชิ้น plain string ของเรา
end

local function DestroySlots()
    for _, e in ipairs(_slots) do
        if e.container ~= nil then
            pcall(function() e.container:Hide() end)
            pcall(function() e.container:SetParent(nil) end)
        end
    end
    _slots = {}
end

--- สร้าง 1 slot (container ต่อ slot — สูตรที่พิสูจน์แล้ว)
local function MakeSlot(unit, filter, spellID, xOff)
    local entry = {
        key = ("s%d"):format(#_slots + 1),
        filter = filter, spellID = spellID, born = GetTime(),
    }

    local okC, container = pcall(CreateFrame, "AuraContainer", nil, UIParent,
        CONTAINER_TEMPLATE)
    if not okC or container == nil then
        return nil, "CreateFrame: " .. ShortErr(container)
    end
    entry.container = container

    local okU, errU = pcall(function() container:SetUnit(unit) end)
    if not okU then return nil, "SetUnit: " .. ShortErr(errU) end

    local slotOpts = {
        initializeFrame = function(slotBtn) BuildSlotRegions(entry, slotBtn) end,
    }
    if spellID ~= nil then
        slotOpts.candidateFilters = { includeSpellIDs = { [spellID] = true } }
    end

    local okS, errS = pcall(function()
        container:AddAuraSlot("gerodps_lab_" .. entry.key, filter, slotOpts)
    end)
    if not okS then return nil, "AddAuraSlot: " .. ShortErr(errS) end

    -- ย้ายเข้าแถบ sensor (สร้างบน UIParent ก่อนตาม idiom เดิม)
    container:SetParent(sensorStrip)
    container:SetSize(SLOT_W, SLOT_H)
    container:SetPoint("TOPLEFT", sensorStrip, "TOPLEFT", 6 + xOff, -6)
    container:Show()

    _slots[#_slots + 1] = entry
    return entry
end

local function BuildSensor()
    -- กติกาจาก probe เดิม: สร้าง container ใน combat เสี่ยง taint template
    if InCombatLockdown() then
        if statusFS then
            statusFS:SetText("|cffff3333อยู่ใน combat — สร้าง sensor ไม่ได้ (taint template) "
                .. "ออก combat ก่อนแล้วกดใหม่ · ของที่สร้างไว้แล้วยังอ่านต่อได้|r")
        end
        return
    end
    DestroySlots()

    local unit = (unitEB and unitEB:GetText() ~= "") and unitEB:GetText() or "target"
    local ids = ParseIDs(idsEB and idsEB:GetText() or "")

    -- ไม่ใส่ id: slot เปล่า 2 ตัว (aura แรกที่เข้า filter) · ใส่ id: id ละ 2 slot
    local defs = {}
    if #ids == 0 then
        defs[#defs + 1] = { filter = "HELPFUL", id = nil }
        defs[#defs + 1] = { filter = "HARMFUL", id = nil }
    else
        for i = 1, math.min(#ids, 4) do
            defs[#defs + 1] = { filter = "HELPFUL", id = ids[i] }
            defs[#defs + 1] = { filter = "HARMFUL", id = ids[i] }
        end
    end

    local made, firstErr = 0, nil
    for i, d in ipairs(defs) do
        local e, err = MakeSlot(unit, d.filter, d.id, (i - 1) * (SLOT_W + SLOT_GAP))
        if e then
            made = made + 1
        elseif firstErr == nil then
            firstErr = err
        end
    end

    if statusFS then
        if firstErr then
            statusFS:SetText(("|cffff3333สร้างได้ %d/%d — พังตัวแรก: %s|r")
                :format(made, #defs, firstErr))
        else
            statusFS:SetText(("|cff44ff44สร้างแล้ว %d slot|r unit=%s · "
                .. "AddAuraSlot ไม่ต้องสั่ง update — C เติมเอง")
                :format(made, unit))
        end
    end
end

-- ============================================================
-- รายงาน
-- ============================================================

local function ReadFS(fs)
    if fs == nil or fs.GetText == nil then return "nil" end
    local ok, v = pcall(fs.GetText, fs)
    return ok and PeekVal(v) or ("THROW " .. ShortErr(v))
end

local function BuildReport()
    local out = {}
    out[#out + 1] = "combat = " .. (InCombatLockdown()
        and "|cff44ff44IN COMBAT|r" or "|cffaaaaaaOUT|r")
        .. "   GetTime() = " .. ("%.1f"):format(GetTime())
    if C_Secrets ~= nil and C_Secrets.ShouldAurasBeSecret ~= nil then
        local okS, sv = pcall(C_Secrets.ShouldAurasBeSecret)
        out[#out + 1] = "ShouldAurasBeSecret() = " .. (okS and PeekVal(sv) or ShortErr(sv))
    end
    if #_slots == 0 then
        out[#out + 1] = ""
        out[#out + 1] = "|cffffcc55ยังไม่มี slot — ใส่ unit (+spellID ถ้าจะ pin) แล้วกด [สร้าง Sensor]|r"
        return out
    end

    local nowMs = GetTime() * 1000
    for i, e in ipairs(_slots) do
        out[#out + 1] = ""
        out[#out + 1] = ("|cffffd200[slot %d]|r %s%s"):format(i, e.filter,
            e.spellID and ("  pin id=" .. e.spellID) or "  (aura แรกที่เข้า filter)")
        if e.btn == nil then
            out[#out + 1] = "   |cffff9a9ainitializeFrame ยังไม่ถูกเรียก|r"
        else
            out[#out + 1] = "   init: " .. (e.initLog or "?")
            local okV, sv = pcall(function() return e.btn:IsShown() end)
            out[#out + 1] = "   btn shown = " .. (okV and PeekVal(sv) or "?")
            out[#out + 1] = "   |cff3fcf5astack|r = " .. ReadFS(e.countFS)
                .. "   |cff3fcf5aชื่อ|r = " .. ReadFS(e.nameFS)
            out[#out + 1] = "   |cff3fcf5adispel|r = " .. ReadFS(e.dispelFS)
                .. "   durText = " .. ReadFS(e.durFS)
            if e.icon ~= nil then
                local okI, iv = pcall(e.icon.GetTexture, e.icon)
                out[#out + 1] = "   icon = " .. (okI and PeekVal(iv) or "?")
            end
            if e.cd ~= nil then
                local okC2, st, du = pcall(e.cd.GetCooldownTimes, e.cd)
                if okC2 then
                    out[#out + 1] = "   GetCooldownTimes: st=" .. PeekVal(st)
                        .. "  dur=" .. PeekVal(du)
                        .. "  |cffaaaaaa(now*1000=" .. ("%.0f"):format(nowMs) .. ")|r"
                else
                    out[#out + 1] = "   GetCooldownTimes: THROW " .. ShortErr(st)
                end
            end
        end
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
    if frame.TitleText then frame.TitleText:SetText("Aura Sensor Lab v2 — AddAuraSlot") end
    table.insert(UISpecialFrames, "GeRODPSToolsAuraSensorLab")

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
    idsLbl:SetText("spellID pin (CSV ≤4, ว่าง=aura แรก):")

    idsEB = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    idsEB:SetSize(180, 20)
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
    statusFS:SetText("|cffaaaaaaสร้างนอก combat เท่านั้น (taint template) · in combat อ่านต่อได้|r")

    sensorStrip = CreateFrame("Frame", nil, frame)
    sensorStrip:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 66))
    sensorStrip:SetPoint("RIGHT", frame, "RIGHT", -SIDE_PAD, 0)
    sensorStrip:SetHeight(SLOT_H + 34)
    local bg = sensorStrip:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(sensorStrip)
    bg:SetColorTexture(0.06, 0.10, 0.06, 0.6)
    local stripLbl = sensorStrip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    stripLbl:SetPoint("BOTTOMLEFT", sensorStrip, "BOTTOMLEFT", 4, 2)
    stripLbl:SetText("|cff3fcf5aแถบ sensor — icon/stack/swipe ที่ C วาดจะโผล่ตรงนี้|r")

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
