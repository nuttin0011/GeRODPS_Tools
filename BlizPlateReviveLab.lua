--[[
    BlizPlateReviveLab.lua — อ่าน aura จาก **Blizzard nameplate** ขณะมี addon
    nameplate (Plater ฯลฯ) ทำงานอยู่ — โดยปลุกเฟรม Blizzard กลับมาแบบมองไม่เห็น

    ── ไอเดีย (user 2026-08-18) ─────────────────────────────────────────────
    Plater ซ่อน Blizzard nameplate ⇒ เรา Override ให้ Show แต่ alpha 0.01
    แล้วอ่านค่าจากเฟรม Blizzard ตามปกติ (NameplateAuraCheck ใช้ได้อยู่แล้ว
    บน UI มาตรฐาน — จุดตายตอน Plater ทำงานคือ list ว่างเพราะเฟรมถูกปิด)

    ── กลไกซ่อนของ Plater (อ่านจากซอร์สจริง Plater.lua:3825/4601-4661) ─────
      hooksecurefunc(plateFrame.UnitFrame, "Show", OnRetailNamePlateShow)
        · นอก combat (ไม่ protected)  → self:Hide()
        · ใน combat (protected)       → ClearAllPoints() + SetParent(nil)  ← detach
      + self:UnregisterAllEvents() + CompactUnitFrame_UnregisterEvents(self)
        (รวม healthBar/castBar) — **เว้นแต่**
        Plater.db.profile.aura_show_debuff_as_blizzard_does == true

    ⇒ สิ่งที่ต้องวัด/สู้ 3 ชั้น:
      1. Show/alpha — เรา Show → hook ของ Plater ซ่อนกลับทันที ⇒ keep-alive ticker
      2. ตำแหน่ง — ใน combat เฟรมถูก detach (parent nil) ⇒ ต้อง re-parent + anchor
      3. **event** — ถูกถอนไปแล้วตั้งแต่ plate โผล่ ⇒ aura list ไม่อัปเดตแม้ Show
         · ตัวชี้วัด: UnitFrame:IsEventRegistered("UNIT_AURA")
         · ทางแก้ ก: CompactUnitFrame_RegisterEvents(uf) ถ้ามี (วัดว่าพอไหม)
         · ทางแก้ ข: เปิด option aura_show_debuff_as_blizzard_does ของ Plater
           (มีปุ่ม toggle ให้ — เขียนลง profile ของ user โดยตั้งใจ กดเอง)

    ── กติกา ───────────────────────────────────────────────────────────────
      · แตะเฟรม Blizzard เท่าที่ Plater เองก็แตะ (Show/Hide/SetAlpha/SetParent
        เป็น insecure บน nameplate — Plater ทำตลอดเวลา) · ทุก call ห่อ pcall
      · อ่านผ่าน GeRODPS.GetAllAuraFromSetOfNamePlate (reader ตัวจริงของ addon)
        — วัดที่นี่ = ผลเดียวกับ production
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local TITLE_H  = 28
local SIDE_PAD = 12

local frame, statusBox, npInfoFS
local keepAlive = false
local reviveCount = 0
local logLines = {}
local lastText = nil

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
    logLines[#logLines + 1] = fmt:format(...)
end

-- ============================================================
-- เฟรม Blizzard ของ nameplate1
-- ============================================================
local function BlizUnitFrame()
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return nil, nil end
    local plate = C_NamePlate.GetNamePlateForUnit("nameplate1")
    if plate == nil then return nil, nil end
    return plate.UnitFrame, plate
end

--- สถานะครบทุกชั้นที่ Plater แตะ — ดูปราดเดียวรู้ว่าติดชั้นไหน
local function StateLines(out)
    local uf, plate = BlizUnitFrame()
    if uf == nil then
        out[#out + 1] = "  |cffff9a9aไม่มี plate.UnitFrame (ไม่มี nameplate1?)|r"
        return
    end
    local okS, shown = pcall(uf.IsShown, uf)
    local okV, vis   = pcall(uf.IsVisible, uf)
    local okA, alpha = pcall(uf.GetAlpha, uf)
    local okP, par   = pcall(uf.GetParent, uf)
    local parName = "?"
    if okP then
        if par == nil then
            parName = "|cffff5555nil (โดน detach)|r"
        elseif par == plate then
            parName = "plate (ถูกต้อง)"
        else
            local okN, nm = pcall(par.GetName, par)
            parName = okN and tostring(nm) or "(เฟรมอื่น)"
        end
    end
    local okE, evA = pcall(uf.IsEventRegistered, uf, "UNIT_AURA")
    local okPr, isProt = pcall(uf.IsProtected, uf)

    out[#out + 1] = ("  UnitFrame: shown=%s visible=%s alpha=%s protected=%s")
        :format(okS and SafeStr(shown) or "ERR", okV and SafeStr(vis) or "ERR",
                okA and ("%.2f"):format(alpha) or "ERR", okPr and SafeStr(isProt) or "ERR")
    out[#out + 1] = ("  parent = %s"):format(parName)
    out[#out + 1] = ("  IsEventRegistered(UNIT_AURA) = %s  |cffaaaaaa(false = Plater ถอน event — aura ไม่อัปเดตแม้ Show)|r")
        :format(okE and SafeStr(evA) or "ERR")

    local P = _G.Plater
    if P and P.db and P.db.profile then
        out[#out + 1] = ("  Plater option aura_show_debuff_as_blizzard_does = %s")
            :format(SafeStr(P.db.profile.aura_show_debuff_as_blizzard_does))
    end

    -- aura list ของ Blizzard (ตัวที่ reader production อ่าน)
    local af = uf.AurasFrame or uf.NameplateAurasFrame
    if af == nil then
        out[#out + 1] = "  AurasFrame = |cffff9a9aไม่มี|r"
    else
        for _, key in ipairs({ "DebuffListFrame", "BuffListFrame", "CrowdControlListFrame" }) do
            local lf = af[key]
            local n = "-"
            if lf ~= nil and lf.GetLayoutChildren then
                local okC, kids = pcall(lf.GetLayoutChildren, lf)
                if okC and type(kids) == "table" then n = tostring(#kids) end
            end
            out[#out + 1] = ("  %s children = %s"):format(key, n)
        end
    end

    -- reader ตัวจริง
    if GeRODPS and GeRODPS.GetAllAuraFromSetOfNamePlate then
        local okR, recs = pcall(GeRODPS.GetAllAuraFromSetOfNamePlate, { "nameplate1" })
        if okR and type(recs) == "table" then
            out[#out + 1] = ("  GetAllAuraFromSetOfNamePlate = %d records"):format(#recs)
            for i, r in ipairs(recs) do
                if i > 6 then out[#out + 1] = "    ..."; break end
                out[#out + 1] = ("    #%d kind=%s spellID=%s stack=%s cdText=%s st/dur=%s/%s")
                    :format(i, tostring(r.kind), SafeStr(r.spellID), SafeStr(r.stack),
                            SafeStr(r.cdText), SafeStr(r.startMs), SafeStr(r.durationMs))
            end
        else
            out[#out + 1] = "  reader ERR: " .. tostring(recs)
        end
    end
end

-- ============================================================
-- Revive — Show + alpha 0.01 + ซ่อมของที่ Plater รื้อ
-- ============================================================
local function ReviveOnce(verbose)
    local uf, plate = BlizUnitFrame()
    if uf == nil then
        if verbose then Log("|cffff9a9aไม่มี plate/UnitFrame ให้ปลุก|r") end
        return false
    end

    -- ใน combat Plater detach (SetParent(nil)) — เอากลับที่เดิมก่อน
    local okP, par = pcall(uf.GetParent, uf)
    if okP and par == nil then
        pcall(uf.SetParent, uf, plate)
        pcall(uf.SetPoint, uf, "CENTER", plate, "CENTER", 0, 0)
        if verbose then Log("  re-parent UnitFrame กลับเข้า plate + SetPoint CENTER") end
    end

    pcall(uf.SetAlpha, uf, 0.01)
    pcall(uf.Show, uf)          -- จะสะกิด hook ของ Plater — keep-alive สู้ต่อให้
    reviveCount = reviveCount + 1
    if verbose then Log("  SetAlpha(0.01) + Show()  (ครั้งที่ %d)", reviveCount) end
    return true
end

local function ReRegisterEvents()
    wipe(logLines)
    Log("== Re-register events · %s ==", date("%H:%M:%S"))
    local uf = BlizUnitFrame()
    if uf == nil then Log("|cffff9a9aไม่มี UnitFrame|r"); return end

    if _G.CompactUnitFrame_RegisterEvents then
        local ok, err = pcall(_G.CompactUnitFrame_RegisterEvents, uf)
        Log("  CompactUnitFrame_RegisterEvents(uf) -> %s", ok and "ok" or ("ERR " .. tostring(err)))
    else
        Log("  CompactUnitFrame_RegisterEvents |cffff9a9aไม่มีใน client นี้|r")
    end
    -- ลงทะเบียนตรง ๆ อีกชั้น (unit-scoped) — ถ้า handler ของเฟรมยังอยู่ แค่นี้อาจพอ
    local okU, errU = pcall(uf.RegisterUnitEvent, uf, "UNIT_AURA", "nameplate1")
    Log("  RegisterUnitEvent(UNIT_AURA, nameplate1) -> %s", okU and "ok" or ("ERR " .. tostring(errU)))
    Log("== ดู IsEventRegistered ในสถานะ — true แล้ว list ควรเริ่มขยับเมื่อ aura เปลี่ยน ==")
end

local function TogglePlaterOption()
    wipe(logLines)
    local P = _G.Plater
    if not (P and P.db and P.db.profile) then
        Log("|cffff9a9aไม่มี Plater.db.profile|r")
        return
    end
    local cur = P.db.profile.aura_show_debuff_as_blizzard_does == true
    P.db.profile.aura_show_debuff_as_blizzard_does = not cur
    Log("== Plater.aura_show_debuff_as_blizzard_does: %s -> %s ==",
        tostring(cur), tostring(not cur))
    Log("  (เขียนลง profile ของ Plater ตามที่กดเอง · มีผลกับ plate ที่โผล่ใหม่ —")
    Log("   plate เดิมโดนถอน event ไปแล้ว ต้องให้ plate เกิดใหม่: หันกล้องหนี/กลับ)")
    if P.RefreshDBUpvalues then pcall(P.RefreshDBUpvalues) end
end

-- ============================================================
-- UI
-- ============================================================
--- แถบ NP1: Exists / Name / isTarget (เทียบเฟรม — UnitIsUnit เป็น secret boolean)
local function NP1InfoText()
    if not UnitExists("nameplate1") then
        return "NP1: |cffff5555ไม่มี|r"
    end
    local name = tostring(UnitName("nameplate1"))
    local isTgt = "|cff888888ไม่มี target|r"
    if UnitExists("target") and C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        local pT = C_NamePlate.GetNamePlateForUnit("target")
        local p1 = C_NamePlate.GetNamePlateForUnit("nameplate1")
        if pT == nil or p1 == nil then
            isTgt = "ไม่รู้ (plate หาย)"
        elseif pT == p1 then
            isTgt = "|cff44ff44ใช่|r"
        else
            isTgt = "|cffff9a9aไม่ใช่|r"
        end
    end
    return ("NP1: |cff44ff44มี|r  ·  ชื่อ = |cffffd200%s|r  ·  คือ target = %s")
        :format(name, isTgt)
end

local function Tick()
    if frame == nil or not frame:IsShown() then return end
    if keepAlive then ReviveOnce(false) end
    if npInfoFS then npInfoFS:SetText(NP1InfoText()) end

    local out = {}
    for _, l in ipairs(logLines) do out[#out + 1] = l end
    out[#out + 1] = ""
    out[#out + 1] = ("-- สถานะ nameplate1 (%s) · combat=%s · keepAlive=%s (revive %d ครั้ง) --")
        :format(UnitExists("nameplate1") and tostring(UnitName("nameplate1")) or "ไม่มี",
                tostring(InCombatLockdown()), tostring(keepAlive), reviveCount)
    StateLines(out)

    local text = table.concat(out, "\n")
    if text ~= lastText then
        lastText = text
        statusBox:SetText(text)
    end
end

local function BuildFrame()
    if frame then return frame end
    frame = CreateFrame("Frame", "GeRODPSToolsBlizPlateReviveLab", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(760, 560)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    frame:SetFrameStrata("HIGH")
    if frame.TitleText then frame.TitleText:SetText("Bliz Plate Revive Lab") end

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 6))
    hint:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + 6))
    hint:SetJustifyH("LEFT")
    hint:SetSpacing(2)
    hint:SetText("|cffffd200เป้าหมาย:|r ปลุก Blizzard nameplate ใต้ Plater (Show + alpha 0.01) แล้วอ่าน aura จากมัน"
        .. "|nชั้นที่ต้องผ่าน: 1) Show/alpha (keep-alive สู้ hook)  2) re-parent ตอน combat"
        .. "  3) |cffffcc55event ถูกถอน|r — ดูบรรทัด IsEventRegistered(UNIT_AURA)")

    local btnState = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnState:SetSize(100, 24)
    btnState:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
    btnState:SetText("ล้าง Log")
    btnState:SetScript("OnClick", function() wipe(logLines); Tick() end)

    local btnRevive = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnRevive:SetSize(150, 24)
    btnRevive:SetPoint("LEFT", btnState, "RIGHT", 6, 0)
    btnRevive:SetText("Revive NP1 (ครั้งเดียว)")
    btnRevive:SetScript("OnClick", function()
        wipe(logLines)
        Log("== Revive · %s ==", date("%H:%M:%S"))
        ReviveOnce(true)
        Tick()
    end)

    local chkKeep = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    chkKeep:SetPoint("LEFT", btnRevive, "RIGHT", 10, 0)
    chkKeep:SetSize(24, 24)
    chkKeep.text:SetText("Keep alive (0.25s — สู้ hook ของ Plater)")
    chkKeep:SetScript("OnClick", function(self)
        keepAlive = self:GetChecked() and true or false
    end)

    local btnEvents = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnEvents:SetSize(150, 24)
    btnEvents:SetPoint("TOPLEFT", btnState, "BOTTOMLEFT", 0, -6)
    btnEvents:SetText("Re-register events")
    btnEvents:SetScript("OnClick", function() ReRegisterEvents(); Tick() end)

    local btnOpt = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btnOpt:SetSize(260, 24)
    btnOpt:SetPoint("LEFT", btnEvents, "RIGHT", 6, 0)
    btnOpt:SetText("Toggle Plater 'as blizzard' option")
    btnOpt:SetScript("OnClick", function() TogglePlaterOption(); Tick() end)

    -- แถบดู NP1 — user เคาะ: จำกัดเฉพาะ nameplate1 เสมอ ขอแค่ Exists/isTarget/Name
    npInfoFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    npInfoFS:SetPoint("TOPLEFT", btnEvents, "BOTTOMLEFT", 0, -8)
    npInfoFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, 0)
    npInfoFS:SetJustifyH("LEFT")
    npInfoFS:SetText("NP1: ...")

    local scroll = CreateFrame("ScrollFrame", "$parentScroll", frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", npInfoFS, "BOTTOMLEFT", 0, -8)
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

    frame:SetResizable(true)
    frame:SetResizeBounds(560, 400)
    local resize = CreateFrame("Button", nil, frame)
    resize:SetSize(16, 16)
    resize:SetPoint("BOTTOMRIGHT", -4, 4)
    resize:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    resize:SetPushedTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Down")
    resize:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then frame:StartSizing("BOTTOMRIGHT") end
    end)
    resize:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then frame:StopMovingOrSizing() end
    end)

    frame:SetScript("OnUpdate", (function()
        local acc = 0
        return function(_, dt)
            acc = acc + dt
            if acc >= 0.25 then acc = 0; Tick() end
        end
    end)())

    return frame
end

function TOOL.ShowBlizPlateReviveLab()
    local f = BuildFrame()
    if f:IsShown() then f:Hide() else f:Show(); Tick() end
end

TOOL.RegisterTool("Bliz Plate Revive Lab (อ่าน NP ใต้ Plater)", TOOL.ShowBlizPlateReviveLab)
