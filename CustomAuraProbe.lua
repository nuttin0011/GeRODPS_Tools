--[[
    GeRODPS_Tools / CustomAuraProbe.lua

    "CustomAura Probe" — วัดว่า CustomAuraContainerTemplate (เฟรมสำเร็จรูปของ
    Blizzard ที่ CMC ใช้ทำ Add Custom Aura) ให้อะไรเรา "อ่านกลับ" ได้บ้าง
    เป้า 3 อย่าง: Present / Remain (sec หรือ %) / Stack + ของแถมทุกตัวที่หาได้

    หลักการ (จาก Blizzard_AuraContainer/CustomAuraButton.lua):
      - เราสร้าง container (CreateFrame "AuraContainer" + CustomAuraContainerTemplate)
        SetUnit(unit) + AddAuraSlot(key, filterString, { initializeFrame, candidateFilters })
      - ใน initializeFrame เราสร้าง region ของเราเอง (Texture / FontString /
        StatusBar / Cooldown) แล้ว "ยื่นให้" ปุ่มผ่าน SetIcon / SetDurationText /
        SetDurationBar / SetDurationCooldown / SetApplicationCount /
        SetApplicationBar / SetSpellName / SetDispelTypeText / AddPandemicRegion
      - Blizzard เป็นคนอ่านออร่า + ขับ region — addon ไม่แตะ C_UnitAuras เลย
      - แล้วเรา "อ่านกลับ" จาก region ที่เราเป็นเจ้าของ (GetText / GetValue /
        GetTextureFileID / GetCooldownTimes / IsShown) — ค่าอาจเป็น secret
        ก็แสดงเป็น "<secret>ค่า" (SetText รับ secret string ได้)

    สิ่งที่รู้จาก source ก่อนวัด (ไว้เทียบกับผลจริง):
      - SetDurationText   -> FS โดน AddSecretAspect(Text)     => GetText คาดว่า secret
      - SetDurationBar    -> bar โดน AddSecretAspect(BarValue) => GetValue คาดว่า secret
      - SetDurationCooldown -> โดน Cooldown+Shown aspects
      - ApplyVisibility   -> SetShown(secretwrap(auraData ~= nil)) => IsShown ของปุ่ม
        เป็น secret "โดยตั้งใจ" แม้นอกคอมแบต
      - SetIcon           -> ไม่มี AddSecretAspect => GetTextureFileID อาจ plain!
      - ApplicationCount  -> Blizzard SetText("") เมื่อไม่มีออร่า (plain empty)
        และโชว์เลขเฉพาะ stack >= 2
      - ApplicationBar    -> SetValue(auraData.applications or 0) เป็น Lua ธรรมดา

    ⚠ กติกาความปลอดภัย:
      - สร้าง container / เรียกเมธอด Set* ของปุ่ม เฉพาะนอกคอมแบต (คอมเมนต์ของ
        CMC: ทำตอนคอมแบต = container ค้างครึ่งทาง + taint template loads)
      - ห้าม and/or / เทียบ / คำนวณ บนค่าที่อ่านกลับ — ทุกตัวผ่าน pcall + Fmt เท่านั้น
      - ห้ามเก็บค่าที่อ่านได้ลง SavedVariables (secret เขียนแล้วหายเงียบ)
      - ไม่มี RemoveAuraSlot ใน API => Clear = Hide container ทิ้งทั้งอัน
        (เฟรมค้างจนกว่าจะ /reload — ยอมรับได้สำหรับ probe)

    ดูค่าเรียลไทม์ใน Watch Var:  ค่าดิบทุกตัวถูก publish ลง
        GeRODPS_Tools.CAP.V[idx].<field>
    เช่นพิมพ์ใน Watch Var:  GeRODPS_Tools.CAP.V[1].durBarValue

    Trigger: Minimap (GeRODPS Tools) -> "CustomAura Probe (Present / Remain / Stack)"
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME = "GeRODPS_ToolsCustomAuraProbeFrame"

local TITLE_H  = 28      -- BasicFrameTemplateWithInset title bar (Rule 10)
local SIDE_PAD = 10
-- MIN_W ต้องพอสำหรับแถวปุ่มบนสุด (spellbox + ปุ่ม 4 + CDM + Clear) ไม่งั้นปุ่มท้ายหลุดขอบ
local DEFAULT_W, DEFAULT_H = 1300, 700
local MIN_W,     MIN_H     = 1120, 480
local MAX_W,     MAX_H     = 2200, 1400

local ROW_H         = 178    -- ความสูงต่อ 1 probe entry (รวมบรรทัด error เต็ม)
local VISUAL_W      = 300    -- โซนซ้าย: ของที่ Blizzard ขับ
local TICK_INTERVAL = 0.2

local CONTAINER_TEMPLATE = "CustomAuraContainerTemplate"

-- ============================================================
-- Public value table (สำหรับ Watch Var) — runtime เท่านั้น ห้ามลง DB
-- ============================================================

TOOL.CAP = TOOL.CAP or {}
TOOL.CAP.V = {}

-- ============================================================
-- Secret-safe formatting (idiom เดียวกับ WatchVar.lua)
-- ============================================================

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

-- คืน string ที่ SetText ได้เสมอ · secret => "<secret>ค่า" (concat/tostring
-- บน secret ได้ผลเป็น secret string ซึ่ง SetText ยอมรับ — Rule 1.5)
local function Fmt(v)
    if v == nil then return "nil" end
    if IsSecret(v) then
        local ok, s = pcall(function() return "<secret>" .. tostring(v) end)
        if ok then return s end
        return "<secret>"
    end
    local ok, s = pcall(tostring, v)
    if ok then return s end
    return "?(tostring failed)"
end

-- "label: value" — ใช้ .. ตรงๆ (ห้าม table.concat กับ secret)
local function Line(label, v)
    local ok, s = pcall(function() return label .. ": " .. Fmt(v) end)
    if ok then return s end
    return label .. ": ?"
end

-- ถ้า v เป็นสตริง error จาก grab ("ERR:<path>:<line>: <msg>") — คืน (ป้ายสั้น, msg เต็ม)
-- v ที่เป็น secret ไม่ใช่ของเรา — ไม่แตะ (คืน nil ให้ไปทาง Line ปกติ)
local function ShortErr(v)
    if type(v) ~= "string" or IsSecret(v) then return nil end
    local err = v:match("^ERR:(.*)$")
    if not err then return nil end
    -- ตัด path+บรรทัดของไฟล์เราออก เหลือแค่ใจความ
    local msg = err:match(":%d+: (.+)") or err
    return "|cffff6b6bERR|r |cff888888(ดูบรรทัดล่าง)|r", msg
end

-- ============================================================
-- Module state
-- ============================================================

local frame, scrollFrame, content, statusFS, spellBox
local entries = {}       -- idx -> entry { container, slotBtn, regions..., readFS[] }
local ticker

local function SetStatus(text, colorHex)
    if not statusFS then return end
    if colorHex then
        statusFS:SetText("|c" .. colorHex .. text .. "|r")
    else
        statusFS:SetText(text)
    end
end

-- ============================================================
-- Probe entry — 1 container ต่อ 1 entry (ไม่มี RemoveAuraSlot ใน API)
-- ============================================================

local PROBE_KINDS = {
    { key = "help_player",  label = "Helpful (player)",         unit = "player", filter = "HELPFUL" },
    { key = "harm_player",  label = "Harmful (player) *",       unit = "player", filter = "HARMFUL" },
    { key = "harm_target",  label = "Harmful (target)",         unit = "target", filter = "HARMFUL" },
    { key = "harmP_target", label = "Harmful|PLAYER (target)",  unit = "target", filter = "HARMFUL|PLAYER" },
}
-- * = จุดวัดสำคัญ: ดีบัฟที่ "mob ใส่เรา" — ถ้าอ่านได้ = ช่องโหว่ Defensive/Bleed ปิดได้

local function ParseSpellID()
    local text = spellBox and spellBox:GetText() or ""
    text = text:gsub("%s+", "")
    if text == "" then return nil end
    return tonumber(text)
end

-- ============================================================
-- CDM Route B — อ่าน itemFrame.auraDataCached จาก 4 viewer ของ Blizzard
-- (เทียบกับ CustomAuraContainer ว่า in-combat อ่านได้ไหม)
--
-- ⚠ ห้ามเรียก itemFrame:GetAuraData() เด็ดขาด — ตัวนั้นเขียน
--   self.auraDataCached = ทำให้เฟรม CDM ติด taint ของเรา (กฎเดิมของ CDMAuraProbe)
--   ที่นี่ใช้เฉพาะ getter อ่านล้วน (GetItemFrames / GetCooldownInfo — ตรวจ
--   บอดี้แล้วว่า return self.x เฉยๆ) + อ่าน field ตรงๆ
-- ============================================================

local CDM_VIEWERS = {
    "EssentialCooldownViewer", "UtilityCooldownViewer",
    "BuffIconCooldownViewer",  "BuffBarCooldownViewer",
}

local CDM_READ_FIELDS = {
    "viewer", "present", "infoSpellID", "infoHasAura",
    "name", "spellId", "applications", "duration",
    "expirationTime", "timeNow", "dispelName", "sourceUnit",
    "auraInstanceID", "icon", "isHelpful", "isHarmful",
}

-- หา itemFrame: spellID ระบุ = match กับ cooldownInfo · ว่าง = เฟรมแรกที่มีออร่า cache
-- ทุก comparison ห่อ pcall (field ของ info อาจเป็น secret ในบางสภาพ — เทียบแล้ว throw)
local function FindCDMFrame(spellID)
    for _, vn in ipairs(CDM_VIEWERS) do
        local viewer = _G[vn]
        if viewer ~= nil and viewer.GetItemFrames ~= nil then
            local okF, framesList = pcall(function() return viewer:GetItemFrames() end)
            if okF and type(framesList) == "table" then
                for i = 1, #framesList do
                    local f = framesList[i]
                    if f ~= nil then
                        if spellID == nil then
                            if f.auraDataCached ~= nil then return f, vn end
                        else
                            local okI, info = pcall(function() return f:GetCooldownInfo() end)
                            if okI and type(info) == "table" then
                                local okM, matched = pcall(function()
                                    return info.spellID == spellID or info.overrideSpellID == spellID
                                end)
                                if okM and matched == true then return f, vn end
                            end
                        end
                    end
                end
            end
        end
    end
    return nil, nil
end

local function ReadEntryCDM(entry, V)
    local function grab(fn)
        local ok, a = pcall(fn)
        if ok then return a end
        return "ERR:" .. tostring(a)
    end

    local f, vn = FindCDMFrame(entry.spellID)
    if f == nil then
        V.viewer  = "not found (เวทไม่อยู่บน viewer ไหนเลย?)"
        V.present = nil
        for i = 3, #CDM_READ_FIELDS do V[CDM_READ_FIELDS[i]] = nil end
        return
    end

    V.viewer = vn
    do
        local okI, info = pcall(function() return f:GetCooldownInfo() end)
        if okI and type(info) == "table" then
            V.infoSpellID = grab(function() return info.spellID end)
            V.infoHasAura = grab(function() return info.hasAura end)
        else
            V.infoSpellID, V.infoHasAura = nil, nil
        end
    end

    -- present = nil-check ล้วน (ปลอดภัยเสมอ) — คาดว่าเป็น "plain boolean" ตัวเดียวของเส้นนี้
    local aura = f.auraDataCached
    V.present = (aura ~= nil)
    V.timeNow = grab(function() return GetTime() end)

    if aura == nil then
        for _, k in ipairs({ "name", "spellId", "applications", "duration",
                             "expirationTime", "dispelName", "sourceUnit",
                             "auraInstanceID", "icon", "isHelpful", "isHarmful" }) do
            V[k] = nil
        end
        return
    end

    -- อ่าน field ตรงๆ — วัดรอบก่อนยืนยันว่า auraDataCached ไม่ใช่ secret table
    -- (index ได้) แต่ค่าข้างในเป็น secret ตอนคอมแบต · pcall กันไว้ทุกตัว
    V.name           = grab(function() return aura.name end)
    V.spellId        = grab(function() return aura.spellId end)
    V.applications   = grab(function() return aura.applications end)
    V.duration       = grab(function() return aura.duration end)
    V.expirationTime = grab(function() return aura.expirationTime end)
    V.dispelName     = grab(function() return aura.dispelName end)
    V.sourceUnit     = grab(function() return aura.sourceUnit end)
    V.auraInstanceID = grab(function() return aura.auraInstanceID end)
    V.icon           = grab(function() return aura.icon end)
    V.isHelpful      = grab(function() return aura.isHelpful end)
    V.isHarmful      = grab(function() return aura.isHarmful end)
end

-- สร้าง region ทั้งหมดใน initializeFrame แล้วยื่นให้ปุ่ม — ทุก Set* ผ่าน pcall
-- + จดผลไว้ใน entry.initLog เพราะ Route E ไม่เคยถูกรันจริงมาก่อน
-- (options ผิด = อยากรู้ error จริง ไม่ใช่ตายเงียบ)
local function BuildSlotRegions(entry, slotBtn)
    entry.slotBtn = slotBtn
    local log = {}
    local function try(name, fn)
        local ok, err = pcall(fn)
        log[#log + 1] = ok and (name .. ":ok") or (name .. ":ERR " .. tostring(err))
    end

    slotBtn:SetSize(40, 40)

    -- icon (ไม่มี secret aspect ใน source — จุดลุ้น plain present)
    local icon = slotBtn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(40, 40)
    icon:SetPoint("TOPLEFT", slotBtn, "TOPLEFT", 0, 0)
    entry.icon = icon
    try("SetIcon", function() slotBtn:SetIcon(icon) end)

    -- cooldown swipe ทับ icon
    local cd = CreateFrame("Cooldown", nil, slotBtn, "CooldownFrameTemplate")
    cd:SetAllPoints(icon)
    entry.cooldown = cd
    try("SetDurationCooldown", function() slotBtn:SetDurationCooldown(cd) end)

    -- stack count มุม icon
    local countFS = slotBtn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    countFS:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1)
    entry.countFS = countFS
    try("SetApplicationCount", function() slotBtn:SetApplicationCount(countFS, nil) end)

    -- duration text ขวา icon
    local durFS = slotBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    durFS:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, -2)
    durFS:SetText("-")
    entry.durFS = durFS
    try("SetDurationText", function() slotBtn:SetDurationText(durFS, nil) end)

    -- spell name ใต้ duration text
    local nameFS = slotBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameFS:SetPoint("TOPLEFT", durFS, "BOTTOMLEFT", 0, -2)
    nameFS:SetText("-")
    entry.nameFS = nameFS
    try("SetSpellName", function() slotBtn:SetSpellName(nameFS) end)

    -- dispel type ใต้ชื่อ
    local dispelFS = slotBtn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    dispelFS:SetPoint("TOPLEFT", nameFS, "BOTTOMLEFT", 0, -2)
    dispelFS:SetText("-")
    entry.dispelFS = dispelFS
    try("SetDispelTypeText", function() slotBtn:SetDispelTypeText(dispelFS, nil) end)

    -- duration bar ใต้ icon (แนวนอน)
    local durBar = CreateFrame("StatusBar", nil, slotBtn)
    durBar:SetSize(220, 12)
    durBar:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -6)
    durBar:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
    durBar:SetStatusBarColor(0.2, 0.8, 0.3)
    entry.durBar = durBar
    try("SetDurationBar", function()
        local opts
        if Enum and Enum.StatusBarTimerDirection then
            opts = { direction = Enum.StatusBarTimerDirection.RemainingTime }
        end
        slotBtn:SetDurationBar(durBar, opts)
    end)

    -- application (stack) bar ใต้ duration bar
    local appBar = CreateFrame("StatusBar", nil, slotBtn)
    appBar:SetSize(220, 8)
    appBar:SetPoint("TOPLEFT", durBar, "BOTTOMLEFT", 0, -4)
    appBar:SetStatusBarTexture("Interface/TargetingFrame/UI-StatusBar")
    appBar:SetStatusBarColor(0.9, 0.7, 0.2)
    entry.appBar = appBar
    try("SetApplicationBar", function()
        slotBtn:SetApplicationBar(appBar, { maxApplications = 20 })
    end)

    -- pandemic marker (จุดเล็กๆ — Blizzard SetShown ให้ตอนเข้าช่วง pandemic)
    local pand = slotBtn:CreateTexture(nil, "OVERLAY")
    pand:SetSize(10, 10)
    pand:SetColorTexture(1, 0.2, 0.2, 1)
    pand:SetPoint("TOPRIGHT", icon, "TOPRIGHT", 4, 4)
    entry.pandemicTex = pand
    try("AddPandemicRegion", function() slotBtn:AddPandemicRegion(pand) end)

    entry.initLog = table.concat(log, "  ")   -- ทุกชิ้นเป็น plain string ของเรา
end

-- แถวแสดงผลใน scroll list
local function BuildRow(entry, idx)
    local row = CreateFrame("Frame", nil, content)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT",  content, "TOPLEFT",  0, -(idx - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -(idx - 1) * ROW_H)

    local bg = row:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(row)
    bg:SetColorTexture(1, 1, 1, idx % 2 == 0 and 0.03 or 0.06)

    local head = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -4)
    head:SetText(("|cffffd200[%d]|r %s   spellID=%s   |cff888888V[%d]|r")
        :format(idx, entry.label, entry.spellID and tostring(entry.spellID) or "(any)", idx))

    local initFS = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    initFS:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -2)
    initFS:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    initFS:SetJustifyH("LEFT")
    initFS:SetWordWrap(false)
    initFS:SetText("|cff707070" .. (entry.initLog or "") .. "|r")

    -- container (Blizzard วาด slot ของมันในนี้) วางในโซนซ้าย — เฉพาะ entry แบบ container
    if entry.container then
        entry.container:SetParent(row)
        entry.container:ClearAllPoints()
        entry.container:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -36)
        entry.container:SetSize(VISUAL_W - 20, ROW_H - 44)
        entry.container:Show()
    end

    -- โซนขวา: readback — 1 FontString ต่อ 1 ค่า (กัน secret ปน string รวม)
    local fieldList, perCol, lineH, colX
    if entry.kindCDM then
        fieldList = CDM_READ_FIELDS
        perCol, lineH = 8, 16
        colX = { 10, 470 }               -- ไม่มีโซนซ้าย — ใช้เต็มแถว
    else
        fieldList = {
            "shown", "iconFileID", "durText", "durBarValue", "durBarMinMax",
            "cdTimes", "stackText", "stackBarValue", "nameText", "dispelText",
            "pandemicShown",
        }
        perCol, lineH = 6, 18
        colX = { VISUAL_W, VISUAL_W + 390 }
    end
    entry.readFS = {}
    for i, field in ipairs(fieldList) do
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        local col = (i > perCol) and 2 or 1
        local rowInCol = (i > perCol) and (i - perCol) or i
        fs:SetPoint("TOPLEFT", row, "TOPLEFT", colX[col], -18 - rowInCol * lineH)
        fs:SetJustifyH("LEFT")
        fs:SetWidth(440)
        fs:SetWordWrap(false)
        fs:SetText(field .. ": -")
        entry.readFS[field] = fs
    end

    -- บรรทัด error เต็ม (แดง) ท้ายแถว — เอาไว้อ่านว่าคอมแบตโดนปฏิเสธด้วยข้อความอะไร
    local errFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    errFS:SetPoint("BOTTOMLEFT",  row, "BOTTOMLEFT",  6, 4)
    errFS:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -6, 4)
    errFS:SetJustifyH("LEFT")
    errFS:SetWordWrap(true)
    errFS:SetHeight(30)
    errFS:SetTextColor(1, 0.42, 0.42)
    errFS:SetText("")
    entry.errFS = errFS

    entry.row = row
end

local function AddProbe(kind)
    if InCombatLockdown() then
        SetStatus("อยู่ในคอมแบต — สร้าง container ตอนนี้เสี่ยง taint template " ..
                  "(กติกาเดียวกับ CMC) ออกคอมแบตก่อนแล้วค่อยกด", "FFFF6B6B")
        return
    end

    local spellID = ParseSpellID()
    local idx = #entries + 1
    local entry = {
        label   = kind.label,
        unit    = kind.unit,
        filter  = kind.filter,
        spellID = spellID,
    }

    -- container ต่อ entry — สร้างบน UIParent ก่อน (idiom เดียวกับ CMC) แล้วค่อยย้ายเข้า row
    local okC, container = pcall(CreateFrame, "AuraContainer", nil, UIParent, CONTAINER_TEMPLATE)
    if not okC or not container then
        SetStatus("CreateFrame AuraContainer ล้มเหลว: " .. tostring(container), "FFFF6B6B")
        return
    end
    entry.container = container

    local okU, errU = pcall(function() container:SetUnit(kind.unit) end)
    if not okU then
        SetStatus("SetUnit(" .. kind.unit .. ") ล้มเหลว: " .. tostring(errU), "FFFF6B6B")
        container:Hide()
        return
    end

    local slotOpts = {
        initializeFrame = function(slotBtn) BuildSlotRegions(entry, slotBtn) end,
    }
    if spellID then
        slotOpts.candidateFilters = { includeSpellIDs = { [spellID] = true } }  -- MAP ไม่ใช่ array
    end

    local okS, errS = pcall(function()
        container:AddAuraSlot("gerodps_probe_" .. idx, kind.filter, slotOpts)
    end)
    if not okS then
        SetStatus("AddAuraSlot ล้มเหลว: " .. tostring(errS), "FFFF6B6B")
        container:Hide()
        return
    end

    entries[idx] = entry
    TOOL.CAP.V[idx] = { label = entry.label, spellID = spellID }
    BuildRow(entry, idx)
    content:SetHeight(math.max(#entries * ROW_H, 1))
    SetStatus(("เพิ่ม [%d] %s  unit=%s filter=%s %s — ดูค่าโซนขวา / Watch Var: GeRODPS_Tools.CAP.V[%d]")
        :format(idx, kind.label, kind.unit, kind.filter,
                spellID and ("spellID=" .. spellID) or "(ออร่าแรกที่เข้า filter)", idx),
        "FF88FF88")
end

-- เพิ่มแถวอ่าน CDM Route B — อ่านอย่างเดียว ไม่มีการเขียนใส่เฟรม CDM
-- ⇒ ไม่ต้องกันคอมแบต (นั่นคือประเด็นที่จะวัด: in-combat อ่านได้ไหม)
local function AddCDMProbe()
    local spellID = ParseSpellID()
    local idx = #entries + 1
    local entry = {
        kindCDM = true,
        label   = "CDM auraDataCached (Route B)",
        spellID = spellID,
        initLog = "Route B: GetItemFrames/GetCooldownInfo (getter อ่านล้วน) + field read — ไม่เขียนอะไรใส่เฟรม CDM · ห้าม GetAuraData()",
    }
    entries[idx] = entry
    TOOL.CAP.V[idx] = { label = entry.label, spellID = spellID }
    BuildRow(entry, idx)
    content:SetHeight(math.max(#entries * ROW_H, 1))
    SetStatus(("เพิ่ม [%d] CDM Route B %s — เวทต้องถูกวางบน CDM viewer ก่อนถึงจะเจอเฟรม")
        :format(idx, spellID and ("spellID=" .. spellID) or "(เฟรมแรกที่มีออร่า cache)"),
        "FF88FF88")
end

local function ClearAll()
    for _, e in ipairs(entries) do
        if e.container then e.container:Hide() end
        if e.row then e.row:Hide() end
    end
    wipe(entries)
    wipe(TOOL.CAP.V)
    content:SetHeight(1)
    SetStatus("ล้างแล้ว — เฟรม container เก่าค้างในหน่วยความจำจนกว่าจะ /reload (API ไม่มี RemoveAuraSlot)", "FFFFCC00")
end

-- ============================================================
-- Readback tick — อ่านจาก region ของเราเอง (ไม่เรียกโค้ด Blizzard เลย
-- ยกเว้น getter อ่านล้วนบน slot button) — ปลอดภัยแม้ in combat
-- ============================================================

local function ReadEntry(entry, V)
    -- ทุกตัว: pcall แยก · ผิดพลาด = เก็บข้อความ error (เป็นข้อมูลเหมือนกัน)
    local function grab(fn)
        local ok, a, b = pcall(fn)
        if ok then return a, b end
        return "ERR:" .. tostring(a)
    end

    -- ⚠ ห้าม and/or ตรงนี้ — IsShown ของปุ่มเป็น secret boolean โดยตั้งใจ
    --   (ApplyVisibility ทำ SetShown(secretwrap(...))) truthiness test = throw
    V.shown = grab(function()
        if entry.slotBtn == nil then return nil end
        return entry.slotBtn:IsShown()
    end)
    V.iconFileID  = grab(function() return entry.icon:GetTextureFileID() end)
    V.durText     = grab(function() return entry.durFS:GetText() end)
    V.durBarValue = grab(function() return entry.durBar:GetValue() end)
    do
        local mn, mx = grab(function() return entry.durBar:GetMinMaxValues() end)
        V.durBarMin, V.durBarMax = mn, mx
    end
    do
        local st, du = grab(function() return entry.cooldown:GetCooldownTimes() end)
        V.cdStart, V.cdDuration = st, du
    end
    V.stackText     = grab(function() return entry.countFS:GetText() end)
    V.stackBarValue = grab(function() return entry.appBar:GetValue() end)
    V.nameText      = grab(function() return entry.nameFS:GetText() end)
    V.dispelText    = grab(function() return entry.dispelFS:GetText() end)
    V.pandemicShown = grab(function() return entry.pandemicTex:IsShown() end)
end

local function PaintEntry(entry, V)
    local fs = entry.readFS
    if not fs then return end

    local firstErr   -- error เต็มตัวแรกของ tick นี้ (ปกติทุกช่องพังด้วยเหตุเดียวกัน)

    local function paint(fsKey, label, v)
        local short, full = ShortErr(v)
        if short then
            fs[fsKey]:SetText(label .. ": " .. short)
            if not firstErr then firstErr = full end
        else
            fs[fsKey]:SetText(Line(label, v))
        end
    end

    paint("shown",         "shown",         V.shown)
    paint("iconFileID",    "iconFileID",    V.iconFileID)
    paint("durText",       "durText",       V.durText)
    paint("durBarValue",   "durBarValue",   V.durBarValue)
    do
        local short, full = ShortErr(V.durBarMin)
        if short then
            fs.durBarMinMax:SetText("durBar min/max: " .. short)
            if not firstErr then firstErr = full end
        else
            local ok, s = pcall(function()
                return "durBar min/max: " .. Fmt(V.durBarMin) .. " / " .. Fmt(V.durBarMax)
            end)
            fs.durBarMinMax:SetText(ok and s or "durBar min/max: ?")
        end
    end
    do
        local short, full = ShortErr(V.cdStart)
        if short then
            fs.cdTimes:SetText("cdTimes: " .. short)
            if not firstErr then firstErr = full end
        else
            local ok, s = pcall(function()
                return "cdTimes: " .. Fmt(V.cdStart) .. " / " .. Fmt(V.cdDuration)
            end)
            fs.cdTimes:SetText(ok and s or "cdTimes: ?")
        end
    end
    paint("stackText",     "stackText",     V.stackText)
    paint("stackBarValue", "stackBarValue", V.stackBarValue)
    paint("nameText",      "nameText",      V.nameText)
    paint("dispelText",    "dispelText",    V.dispelText)
    paint("pandemicShown", "pandemicShown", V.pandemicShown)

    if entry.errFS then
        if firstErr then
            entry.errFS:SetText(firstErr)
            V.lastError = firstErr          -- อ่านผ่าน Watch Var ได้ด้วย
        else
            entry.errFS:SetText("")
        end
    end
end

local function PaintEntryCDM(entry, V)
    local fs = entry.readFS
    if not fs then return end
    local firstErr
    for _, field in ipairs(CDM_READ_FIELDS) do
        local v = V[field]
        local short, full = ShortErr(v)
        if short then
            fs[field]:SetText(field .. ": " .. short)
            if not firstErr then firstErr = full end
        else
            fs[field]:SetText(Line(field, v))
        end
    end
    if entry.errFS then
        if firstErr then
            entry.errFS:SetText(firstErr)
            V.lastError = firstErr
        else
            entry.errFS:SetText("")
        end
    end
end

local function Tick()
    for idx, entry in ipairs(entries) do
        local V = TOOL.CAP.V[idx]
        if V then
            if entry.kindCDM then
                ReadEntryCDM(entry, V)
                PaintEntryCDM(entry, V)
            else
                ReadEntry(entry, V)
                PaintEntry(entry, V)
            end
        end
    end
end

-- ============================================================
-- Dump Table — ขุดทุกอย่างที่มองเห็นจาก object ของ container / slot button
--   1) direct keys (pairs)      2) เดิน metatable __index chain = ชื่อ method ทั้งหมด
--   3) C_AuraContainerUtil      4) เช็ค global mixin (คาดว่า nil เพราะ
--      Blizzard_AuraContainer โหลดใน UseSecureEnvironment)
-- ทุกบรรทัดเป็น plain string เสมอ (ค่า secret ใส่แค่ type ไม่ใส่ค่า)
-- => table.concat ปลอดภัย
-- ============================================================

local dumpFrame, dumpEB

local function TypeAndVal(v)
    local t = type(v)                       -- type() ใช้กับ secret ได้ คืน type จริง
    if IsSecret(v) then return t .. " <secret>" end
    if t == "string" or t == "number" or t == "boolean" then
        local ok, s = pcall(tostring, v)
        if ok then return t .. " = " .. s end
    end
    return t
end

local function DumpObject(out, label, obj)
    out[#out + 1] = ""
    out[#out + 1] = "========== " .. label .. " =========="
    if obj == nil then
        out[#out + 1] = "(nil)"
        return
    end

    local keys = {}
    local okP, errP = pcall(function()
        for k, v in pairs(obj) do
            keys[#keys + 1] = tostring(k) .. " : " .. TypeAndVal(v)
        end
    end)
    if not okP then out[#out + 1] = "pairs() ERR: " .. tostring(errP) end
    table.sort(keys)
    out[#out + 1] = ("-- direct keys (%d):"):format(#keys)
    for _, l in ipairs(keys) do out[#out + 1] = "  " .. l end

    -- เดิน __index chain — ชื่อ method อยู่ที่นี่
    local seen, cur = {}, obj
    for depth = 1, 6 do
        local okM, mt = pcall(getmetatable, cur)
        if not okM then out[#out + 1] = "getmetatable ERR: " .. tostring(mt) break end
        if mt == nil then break end
        if type(mt) ~= "table" then
            out[#out + 1] = "-- metatable depth " .. depth .. " = " .. type(mt) .. " (เดินต่อไม่ได้)"
            break
        end
        if seen[mt] then break end
        seen[mt] = true
        local idx = rawget(mt, "__index")
        if type(idx) ~= "table" then
            out[#out + 1] = "-- __index depth " .. depth .. " = " .. type(idx) .. " (เดินต่อไม่ได้)"
            break
        end
        local names = {}
        local okE, errE = pcall(function()
            for k, v in pairs(idx) do
                names[#names + 1] = tostring(k) .. " (" .. type(v) .. ")"
            end
        end)
        if not okE then out[#out + 1] = "__index pairs ERR: " .. tostring(errE) end
        table.sort(names)
        out[#out + 1] = ("-- __index depth %d (%d keys):"):format(depth, #names)
        for _, n in ipairs(names) do out[#out + 1] = "  " .. n end
        cur = idx
    end
end

local function ShowDumpWindow(text)
    if not dumpFrame then
        dumpFrame = CreateFrame("Frame", "GeRODPS_ToolsCustomAuraDumpFrame", UIParent,
                                "BasicFrameTemplateWithInset")
        dumpFrame:SetSize(760, 560)
        dumpFrame:SetPoint("CENTER", 40, 0)
        dumpFrame:SetMovable(true)
        dumpFrame:EnableMouse(true)
        dumpFrame:RegisterForDrag("LeftButton")
        dumpFrame:SetScript("OnDragStart", dumpFrame.StartMoving)
        dumpFrame:SetScript("OnDragStop", dumpFrame.StopMovingOrSizing)
        dumpFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        dumpFrame.TitleText:SetText("CustomAuraContainer — Dump Table")

        local sel = CreateFrame("Button", nil, dumpFrame, "UIPanelButtonTemplate")
        sel:SetSize(90, 20)
        sel:SetPoint("TOPRIGHT", dumpFrame, "TOPRIGHT", -28, -(TITLE_H + 4))
        sel:SetText("Select All")
        sel:SetScript("OnClick", function()
            if dumpEB then dumpEB:SetFocus() dumpEB:HighlightText() end
        end)

        local sf = CreateFrame("ScrollFrame", nil, dumpFrame, "UIPanelScrollFrameTemplate")
        sf:SetPoint("TOPLEFT",     dumpFrame, "TOPLEFT",     10, -(TITLE_H + 28))
        sf:SetPoint("BOTTOMRIGHT", dumpFrame, "BOTTOMRIGHT", -30, 10)

        dumpEB = CreateFrame("EditBox", nil, sf)
        dumpEB:SetMultiLine(true)
        dumpEB:SetAutoFocus(false)
        dumpEB:SetFontObject(ChatFontNormal)
        dumpEB:SetWidth(700)
        dumpEB:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        sf:SetScrollChild(dumpEB)

        table.insert(UISpecialFrames, "GeRODPS_ToolsCustomAuraDumpFrame")
    end
    dumpEB:SetText(text)
    dumpEB:SetCursorPosition(0)
    dumpFrame:Show()
end

local function DoDumpTables()
    local out = {}
    out[#out + 1] = "CustomAuraContainer dump — " .. date("%Y-%m-%d %H:%M:%S")
    if InCombatLockdown() then
        out[#out + 1] = "!! IN COMBAT — การอ่านหลายอย่างจะ ERR (forbidden object) ลองซ้ำนอกคอมแบต"
    end

    -- container + slot จาก entry แบบ container ตัวแรกที่มี
    local target
    for _, e in ipairs(entries) do
        if not e.kindCDM and e.container then target = e break end
    end
    if target then
        DumpObject(out, "container (" .. (target.label or "?") .. ")", target.container)
        DumpObject(out, "slot button", target.slotBtn)
    else
        out[#out + 1] = ""
        out[#out + 1] = "!! ยังไม่มี probe แบบ container — กด + Helpful/Harmful ก่อนแล้วค่อย Dump"
    end

    DumpObject(out, "C_AuraContainerUtil (C namespace)", _G.C_AuraContainerUtil)

    -- global mixin — คาดว่า nil (UseSecureEnvironment) · ถ้าไม่ nil = ขุมทรัพย์
    out[#out + 1] = ""
    out[#out + 1] = "========== globals check =========="
    for _, gname in ipairs({
        "CustomAuraContainerSharedMixin", "CustomAuraContainerPrivateMixin",
        "CustomAuraButtonSharedMixin", "CustomAuraButtonPrivateMixin",
        "AuraContainerUtil", "AuraContainerRuntime",
    }) do
        out[#out + 1] = ("  _G.%s = %s"):format(gname, type(_G[gname]))
    end
    for _, ename in ipairs({ "CustomAuraButtonUpdateMode", "StatusBarTimerDirection" }) do
        local e = Enum and Enum[ename]
        if type(e) == "table" then
            local parts = {}
            for k, v in pairs(e) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
            table.sort(parts)
            out[#out + 1] = ("  Enum.%s: %s"):format(ename, table.concat(parts, "  "))
        else
            out[#out + 1] = ("  Enum.%s = %s"):format(ename, type(e))
        end
    end

    ShowDumpWindow(table.concat(out, "\n"))
end

-- ============================================================
-- Frame
-- ============================================================

local function MakeButton(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function CreateProbeFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(DEFAULT_W, DEFAULT_H)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")
    frame.TitleText:SetText("CustomAura Probe — Present / Remain / Stack")

    -- resize grabber (บทเรียนจาก CDM Aura Probe: ต้องมีตั้งแต่แรก)
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

    -- แถวบน: spellID + ปุ่มเพิ่ม probe
    local bar1 = CreateFrame("Frame", nil, frame)
    bar1:SetHeight(24)
    bar1:SetPoint("TOPLEFT",  frame, "TOPLEFT",  SIDE_PAD, -(TITLE_H + 6))
    bar1:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + 6))

    local lbl = bar1:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("LEFT", bar1, "LEFT", 2, 0)
    lbl:SetText("SpellID (ว่าง = ออร่าแรกที่เข้า filter):")

    spellBox = CreateFrame("EditBox", nil, bar1, "InputBoxTemplate")
    spellBox:SetSize(90, 20)
    spellBox:SetPoint("LEFT", lbl, "RIGHT", 10, 0)
    spellBox:SetAutoFocus(false)
    spellBox:SetNumeric(true)
    spellBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    spellBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    local prev = spellBox
    for _, kind in ipairs(PROBE_KINDS) do
        local b = MakeButton(bar1, "+ " .. kind.label, 185, function() AddProbe(kind) end)
        b:SetPoint("LEFT", prev, "RIGHT", 8, 0)
        prev = b
    end

    local bCDM = MakeButton(bar1, "+ CDM auraDataCached", 170, AddCDMProbe)
    bCDM:SetPoint("LEFT", prev, "RIGHT", 14, 0)

    local bClear = MakeButton(bar1, "Clear All", 80, ClearAll)
    bClear:SetPoint("LEFT", bCDM, "RIGHT", 14, 0)

    -- แถวสถานะ + ปุ่ม Dump Table ขวาสุด
    local bDump = MakeButton(frame, "Dump Table", 100, DoDumpTables)
    bDump:SetPoint("TOPRIGHT", bar1, "BOTTOMRIGHT", 0, -2)

    statusFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusFS:SetPoint("TOPLEFT",  bar1, "BOTTOMLEFT",  2, -4)
    statusFS:SetPoint("TOPRIGHT", bDump, "TOPLEFT", -8, -2)
    statusFS:SetJustifyH("LEFT")
    statusFS:SetHeight(26)
    statusFS:SetText("Harmful (player) = จุดวัดสำคัญ: ดีบัฟที่ mob ใส่เรา · " ..
                     "Watch Var: GeRODPS_Tools.CAP.V[idx].durBarValue ฯลฯ")

    -- scroll list
    scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     frame, "TOPLEFT",     SIDE_PAD, -(TITLE_H + 62))
    scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -(SIDE_PAD + 22), SIDE_PAD)

    content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 1)
    scrollFrame:SetScrollChild(content)
    scrollFrame:SetScript("OnSizeChanged", function(_, w)
        if w and w > 1 then content:SetWidth(w) end
    end)

    frame:SetScript("OnShow", function()
        if not ticker then
            ticker = C_Timer.NewTicker(TICK_INTERVAL, Tick)
        end
    end)
    frame:SetScript("OnHide", function()
        if ticker then
            ticker:Cancel()
            ticker = nil
        end
    end)

    frame:Hide()
    table.insert(UISpecialFrames, FRAME_NAME)   -- Esc ปิดได้
    return frame
end

-- ============================================================
-- Public
-- ============================================================

function TOOL.ShowCustomAuraProbe()
    CreateProbeFrame()
    frame:Show()
end

function TOOL.HideCustomAuraProbe()
    if frame then frame:Hide() end
end

function TOOL.ToggleCustomAuraProbe()
    CreateProbeFrame()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("CustomAura Probe (Present / Remain / Stack)", TOOL.ToggleCustomAuraProbe)
end
