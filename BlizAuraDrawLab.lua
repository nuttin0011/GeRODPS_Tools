--[[
    BlizAuraDrawLab.lua — สร้าง CustomAuraContainer ของเราเอง แล้วให้ Blizzard
    วาด aura ของ nameplate1 ลงไป (โจทย์: "ทำให้ Bliz วาดให้ได้ก่อน" — อ่านค่าทีหลัง)

    ── ทำไมรอบนี้ต่างจาก AuraSensorLab v1 ที่ล้มเหลว ─────────────────────────
    v1 ลอง AddAuraGroup ตามแบบ BetterBlizzFrames แล้วไม่มีอะไรโผล่เลย
    รอบนี้ลอกลำดับเรียกจาก **Plater ที่วาดได้จริงบนเครื่องนี้** (Plater_Auras.lua
    CreateOrUpdateAuraContainers เส้น 12.x) ซึ่งมี 2 อย่างที่ v1 ไม่เคยทำ:
      · SetAuraProcessingPolicy + SetFlowLayout* ก่อนสร้าง group
      · ปิดท้ายด้วย SetEnabled(true) → **SetUnit(unit)** ← ตัวผูก container กับ unit
    และ initializeFrame ต้องสร้าง widget แล้ว "ลงทะเบียน" ให้ฝั่ง C เป็นคนเขียน:
      SetIcon / SetDurationCooldown / SetApplicationCount / SetDurationText
    (surface เดียวกับที่วัดผ่านแล้วใน AuraSensorLab v2 — AddAuraSlot)

    ── ลำดับเต็มที่ลอกมา (Plater_Auras.lua:1503-1551) ───────────────────────
      1. CreateFrame("AuraContainer", name, parent, "CustomAuraContainerTemplate")
      2. SetEnabled(false)                          ตอนสร้าง
      3. SetAuraProcessingPolicy(ProcessAura, {displayOnlyDispellableDebuffs=false,
             ignoreBuffs=false, ignoreDebuffs=false, ignoreDispelDebuffs=false})
      4. SetFlowLayoutMaximumLineSize(px) · SetFlowLayoutAnchorPoint("TOPLEFT")
         SetFlowLayoutGrowthDirection(Right, Up)
      5. AddAuraGroup("group1", filterString, auraFrameOptions)   ครั้งแรกครั้งเดียว
      6. SetAuraGroupCandidateFilters / SetAuraGroupFilterString /
         SetAuraGroupMaxFrameCount / SetAuraGroupSortMethod / SetAuraGroupLayout
      7. SetEnabled(true)
      8. SetUnit("nameplate1")
    ทุก step ห่อ pcall แยกกัน + log ผลรายบรรทัด — ถ้าพัง จะเห็นว่าพังที่ step ไหน

    ── กติกา ────────────────────────────────────────────────────────────────
      · สร้าง container **นอก combat เท่านั้น** (บทเรียน CDM: template ใน combat
        = taint risk) — Bind/Rebind ทำใน combat ได้ (เป็น C call ล้วน + pcall)
      · ห้ามแตะ container/เฟรมของ Plater — เราสร้างของเราเองทั้งก้อน
      · ปุ่มที่ C สร้างให้เก็บ ref ไว้ใน created[] เพื่อรายงานจำนวน/สถานะ
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local TITLE_H  = 28
local SIDE_PAD = 12

local ICON_W, ICON_H, ICON_GAP = 26, 26, 2
local MAX_SHOW = 12

local frame, statusBox, drawArea, liveFS
local container            -- CustomAuraContainer ของเรา (สร้างครั้งเดียว)
local created = {}         -- ปุ่มที่ initializeFrame ถูกเรียก (ตามลำดับ)
local groupAdded = false   -- AddAuraGroup เรียกได้ครั้งเดียวต่อชื่อ group
local bindLog = {}
local curFilter = "HARMFUL|PLAYER"
local lastLive = nil

local function IsSecret(v)
    if issecretvalue == nil then return false end
    local ok, res = pcall(issecretvalue, v)
    return ok and res == true
end

local function SafeStr(v)
    if v == nil then return "nil" end
    if IsSecret(v) then return "[s]" end
    return tostring(v)
end

local function Log(fmt, ...)
    bindLog[#bindLog + 1] = fmt:format(...)
end

--- เรียก method บน container แบบจับผลรายบรรทัด — หัวใจของ lab นี้
local function Step(label, fn)
    local ok, err = pcall(fn)
    if ok then
        Log("  [ok]  %s", label)
    else
        Log("  |cffff5555[ERR]|r %s -> %s", label, tostring(err))
    end
    return ok
end

-- ============================================================
-- initializeFrame — สร้าง widget + ลงทะเบียนให้ C วาด (ลอก initAuraFrame ของ Plater)
-- ============================================================
local function InitAuraButton(btn)
    btn:SetSize(ICON_W, ICON_H)
    if btn.SetMouseMotionEnabled then pcall(btn.SetMouseMotionEnabled, btn, false) end

    btn.Icon = btn:CreateTexture(nil, "ARTWORK")
    btn.Icon:SetSize(ICON_W, ICON_H)
    btn.Icon:SetPoint("CENTER")
    btn.Icon:SetTexCoord(.05, .95, .05, .95)
    pcall(btn.SetIcon, btn, btn.Icon)

    btn.Cooldown = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
    btn.Cooldown:SetAllPoints(btn.Icon)
    btn.Cooldown:EnableMouse(false)
    btn.Cooldown:SetHideCountdownNumbers(false)   -- อยากเห็นเลขชัด ๆ ว่าวาดจริง
    btn.Cooldown:SetDrawBling(false)
    pcall(btn.SetDurationCooldown, btn, btn.Cooldown)

    btn.CountText = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    btn.CountText:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 1, 0)
    pcall(btn.SetApplicationCount, btn, btn.CountText)

    created[#created + 1] = btn
end

-- ============================================================
-- Container lifecycle
-- ============================================================

local function EnsureContainer()
    if container ~= nil then return true end
    if InCombatLockdown() then
        Log("|cffff5555สร้าง container ใน combat ไม่ได้ (taint risk) — ออก combat แล้วกดใหม่|r")
        return false
    end
    local ok, c = pcall(CreateFrame, "AuraContainer", "GeRODPSToolsBlizDrawContainer",
                        drawArea, "CustomAuraContainerTemplate")
    if not ok or c == nil then
        Log("|cffff5555CreateFrame AuraContainer ERR: %s|r", tostring(c))
        return false
    end
    container = c
    container:SetPoint("TOPLEFT", drawArea, "TOPLEFT", 4, -4)
    container:SetSize((ICON_W + ICON_GAP) * MAX_SHOW, (ICON_H + ICON_GAP) * 3)
    pcall(container.SetEnabled, container, false)
    Log("[ok]  CreateFrame AuraContainer (CustomAuraContainerTemplate)")
    return true
end

local function BindNP1()
    wipe(bindLog)
    Log("== Bind nameplate1  ·  filter = %s  ·  %s ==", curFilter, date("%H:%M:%S"))
    if not EnsureContainer() then return end

    local unit = "nameplate1"
    if not UnitExists(unit) then
        Log("|cffffcc55เตือน: nameplate1 ยังไม่มีตัวตน — SetUnit จะสั่งทิ้งไว้ให้เลย|r")
    else
        Log("  nameplate1 = %s", tostring(UnitName(unit)))
    end

    local POLICY = _G.CustomAuraContainerAuraProcessingPolicy
    local SORT_M = _G.AuraContainerSortMethod
    local SORT_D = _G.AuraContainerSortDirection
    local FLOW   = _G.AnchorUtil and _G.AnchorUtil.FlowDirection
    if POLICY == nil or SORT_M == nil or FLOW == nil then
        Log("|cffff5555enum หาย: policy=%s sort=%s flow=%s — client นี้ไม่มี API ชุดนี้|r",
            tostring(POLICY ~= nil), tostring(SORT_M ~= nil), tostring(FLOW ~= nil))
        return
    end

    local layout = {
        elementSpacing   = ICON_GAP,
        lineSpacing      = ICON_GAP,
        groupSpacing     = ICON_GAP,
        groupLineSpacing = ICON_GAP,
        elementWidth     = ICON_W,
        elementHeight    = ICON_H,
        maximumLineSize  = (ICON_W + ICON_GAP) * MAX_SHOW,
    }

    Step("SetAuraProcessingPolicy(ProcessAura)", function()
        container:SetAuraProcessingPolicy(POLICY.ProcessAura, {
            displayOnlyDispellableDebuffs = false,
            ignoreBuffs        = false,
            ignoreDebuffs      = false,
            ignoreDispelDebuffs = false,
        })
    end)
    Step("SetFlowLayoutMaximumLineSize", function()
        container:SetFlowLayoutMaximumLineSize(layout.maximumLineSize)
    end)
    Step("SetFlowLayoutAnchorPoint(TOPLEFT)", function()
        container:SetFlowLayoutAnchorPoint("TOPLEFT")
    end)
    Step("SetFlowLayoutGrowthDirection(Right, Up)", function()
        container:SetFlowLayoutGrowthDirection(FLOW.Right, FLOW.Up)
    end)

    if not groupAdded then
        local opts = {
            maxFrameCount   = MAX_SHOW,
            sortMethod      = SORT_M.Default,
            sortDirection   = SORT_D and SORT_D.Normal or nil,
            templateNames   = nil,
            candidateFilters = nil,
            initializeFrame = InitAuraButton,
            layout          = layout,
        }
        if Step('AddAuraGroup("group1", "' .. curFilter .. '")', function()
            container:AddAuraGroup("group1", curFilter, opts)
        end) then
            groupAdded = true
        end
    end

    if groupAdded then
        Step("SetAuraGroupFilterString", function()
            container:SetAuraGroupFilterString("group1", curFilter)
        end)
        Step("SetAuraGroupMaxFrameCount(" .. MAX_SHOW .. ")", function()
            container:SetAuraGroupMaxFrameCount("group1", MAX_SHOW)
        end)
        Step("SetAuraGroupSortMethod(Default)", function()
            container:SetAuraGroupSortMethod("group1", SORT_M.Default,
                SORT_D and SORT_D.Normal or nil)
        end)
        Step("SetAuraGroupLayout", function()
            container:SetAuraGroupLayout("group1", layout)
        end)
    end

    Step("SetEnabled(true)", function() container:SetEnabled(true) end)
    Step('SetUnit("nameplate1")', function() container:SetUnit(unit) end)
    Log("== จบ bind — ดูบรรทัด live ด้านล่างว่า Blizzard เริ่มวาดไหม ==")
end

local function Unbind()
    if container == nil then return end
    wipe(bindLog)
    Step("SetEnabled(false)", function() container:SetEnabled(false) end)
    Log("== ปิดแล้ว (container ยังอยู่ กด Bind ใหม่ได้) ==")
end

-- ============================================================
-- Live status (ticker)
-- ============================================================
local function BuildLive()
    local out = {}
    if container == nil then
        out[#out + 1] = "container: ยังไม่ได้สร้าง — กด [Bind NP1]"
        return table.concat(out, "\n")
    end

    local np = UnitExists("nameplate1") and tostring(UnitName("nameplate1")) or "(ไม่มี)"
    out[#out + 1] = ("nameplate1 = %s   combat = %s"):format(np, tostring(InCombatLockdown()))

    -- คำถามพ่วง: GetAuraGroupFrameCount เรียกได้ไหม (โดยเฉพาะใน combat)
    if container.GetAuraGroupFrameCount then
        local ok, n = pcall(container.GetAuraGroupFrameCount, container, "group1")
        out[#out + 1] = ("GetAuraGroupFrameCount(group1) = %s"):format(ok and SafeStr(n) or ("ERR: " .. tostring(n)))
    end

    local nVis = 0
    for _, btn in ipairs(created) do
        local ok, vis = pcall(btn.IsVisible, btn)
        if ok and vis == true then nVis = nVis + 1 end
    end
    out[#out + 1] = ("ปุ่มที่ C สร้างผ่าน initializeFrame = %d  ·  มองเห็น = %d"):format(#created, nVis)

    if nVis > 0 then
        out[#out + 1] = "|cff44ff44>>> Blizzard วาดลง container ของเราแล้ว! <<<|r"
        for i, btn in ipairs(created) do
            local ok, vis = pcall(btn.IsVisible, btn)
            if ok and vis == true then
                local okT, tex = pcall(btn.Icon.GetTexture, btn.Icon)
                local okC, txt = pcall(btn.CountText.GetText, btn.CountText)
                local sMs, dMs
                if btn.Cooldown and btn.Cooldown.GetCooldownTimes then
                    local okD, a, b = pcall(btn.Cooldown.GetCooldownTimes, btn.Cooldown)
                    if okD then sMs, dMs = a, b end
                end
                out[#out + 1] = ("  btn#%d icon=%s count=%s cd=%s/%s")
                    :format(i, okT and SafeStr(tex) or "ERR", okC and SafeStr(txt) or "ERR",
                            SafeStr(sMs), SafeStr(dMs))
            end
        end
    else
        out[#out + 1] = "(ยังไม่มีปุ่มโผล่ — ใส่ DoT บน nameplate1 / เช็ค filter / ดู log ข้างบน)"
    end
    return table.concat(out, "\n")
end

local function Tick()
    if frame == nil or not frame:IsShown() then return end
    local live = BuildLive()
    local full = table.concat(bindLog, "\n") .. "\n\n-- live --\n" .. live
    if full ~= lastLive then
        lastLive = full
        statusBox:SetText(full)
    end
end

-- ============================================================
-- UI
-- ============================================================
local function BuildFrame()
    if frame then return frame end
    frame = CreateFrame("Frame", "GeRODPSToolsBlizAuraDrawLab", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(680, 560)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    frame:SetFrameStrata("HIGH")
    if frame.TitleText then frame.TitleText:SetText("Bliz Aura Draw Lab") end

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 6))
    hint:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + 6))
    hint:SetJustifyH("LEFT")
    hint:SetText("|cffffd200เป้าหมาย:|r ให้ Blizzard วาด aura ของ nameplate1 ลง container "
        .. "ที่เราสร้างเอง (ลำดับเรียกลอกจาก Plater ที่วาดได้จริง)"
        .. "|nสร้าง container นอก combat · Bind ซ้ำได้เรื่อย ๆ · ใส่ DoT บน NP1 แล้วดูช่องล่าง")

    -- ปุ่มแถวบน
    local btnBind = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnBind:SetSize(110, 24)
    btnBind:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
    btnBind:SetText("Bind NP1")
    btnBind:SetScript("OnClick", function() BindNP1(); Tick() end)

    local btnOff = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnOff:SetSize(90, 24)
    btnOff:SetPoint("LEFT", btnBind, "RIGHT", 6, 0)
    btnOff:SetText("Disable")
    btnOff:SetScript("OnClick", function() Unbind(); Tick() end)

    -- filter radio 3 ตัว
    local anchor = btnOff
    for _, f in ipairs({ "HARMFUL|PLAYER", "HARMFUL", "HELPFUL" }) do
        local r = CreateFrame("CheckButton", nil, frame, "UIRadioButtonTemplate")
        r:SetPoint("LEFT", anchor, "RIGHT", (anchor == btnOff) and 14 or 4, 0)
        r.text:SetText(f)
        r:SetChecked(f == curFilter)
        r:SetScript("OnClick", function(self)
            curFilter = f
            for _, o in ipairs(frame._filterRadios) do o:SetChecked(o._f == f) end
            -- เปลี่ยน filter บน group เดิมได้เลย (SetAuraGroupFilterString) — กด Bind ใหม่
        end)
        r._f = f
        frame._filterRadios = frame._filterRadios or {}
        frame._filterRadios[#frame._filterRadios + 1] = r
        anchor = r.text  -- ต่อท้ายข้อความ ไม่ทับ label
    end

    -- พื้นที่ให้ Blizzard วาด (พื้นดำ เห็นไอคอนชัด)
    local areaLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    areaLabel:SetPoint("TOPLEFT", btnBind, "BOTTOMLEFT", 0, -8)
    areaLabel:SetText("|cffaaffaaพื้นที่วาดของ Blizzard (container ของเรา):|r")

    drawArea = CreateFrame("Frame", nil, frame)
    drawArea:SetPoint("TOPLEFT", areaLabel, "BOTTOMLEFT", 0, -4)
    drawArea:SetPoint("RIGHT", frame, "RIGHT", -SIDE_PAD, 0)
    drawArea:SetHeight((ICON_H + ICON_GAP) * 3 + 8)
    local bg = drawArea:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)

    liveFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    liveFS:SetPoint("TOPLEFT", drawArea, "BOTTOMLEFT", 0, -6)
    liveFS:SetText("|cffaaffaaLog + สถานะ (copy ได้):|r")

    local scroll = CreateFrame("ScrollFrame", "$parentScroll", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", liveFS, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 12)

    statusBox = CreateFrame("EditBox", nil, scroll)
    statusBox:SetMultiLine(true)
    statusBox:SetAutoFocus(false)
    statusBox:SetFontObject(ChatFontNormal)
    statusBox:SetWidth(scroll:GetWidth())
    statusBox:SetMaxLetters(0)
    statusBox:EnableMouse(true)
    statusBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScript("OnSizeChanged", function(_, w) statusBox:SetWidth(w) end)
    scroll:SetScrollChild(statusBox)

    frame:SetScript("OnUpdate", (function()
        local acc = 0
        return function(_, dt)
            acc = acc + dt
            if acc >= 0.25 then acc = 0; Tick() end
        end
    end)())

    return frame
end

function TOOL.ShowBlizAuraDrawLab()
    local f = BuildFrame()
    if f:IsShown() then f:Hide() else f:Show(); Tick() end
end

TOOL.RegisterTool("Bliz Aura Draw Lab (container ของเราเอง — NP1)", TOOL.ShowBlizAuraDrawLab)
