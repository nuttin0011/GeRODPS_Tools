--[[
    GeRODPS_Tools / SecretAPICheck.lua

    "Secret API Check" — ตารางเรียลไทม์ที่ยิง WoW API ทุกตัวที่ GeRODPS
    ต้องเอาค่าไปเปรียบเทียบ แล้วรายงานว่าค่าที่ได้ "เป็น secret หรือไม่"
    พร้อมค่าจริง (Ans) ในช่องเดียวกัน — รูปแบบการแสดงผลเดียวกับ Watch Var

    เกิดจากเคสจริง WoW 12.1:
        TargetCastBar.lua:265: attempt to compare a secret string value
        (UnitGroupRolesAssigned("targettarget") == "TANK")
    ค่าเดียวกันบน "player" / "party1" ไม่ secret แต่บน unit ที่วิ่งผ่าน
    enemy กลับ secret ⇒ ต้องดูทีละ unit path ไม่ใช่ทีละ API

    แบ่งเป็น "หน้า" (ไม่ใช่ scroll ยาว) — 1 หมวด = 1 หน้า ถ้าหมวดไหนยาว
    เกินความสูงหน้าจอจะตัดเป็นหน้าย่อยพร้อมหัวข้อ "(ต่อ)" ให้ capture
    ได้ทีละหน้าโดยไม่มีแถวตกหล่น

    หน้าจอ:
        [Units]        4 ช่องแก้ได้ (default player / party1 / target / targettarget)
        [Filter]       พิมพ์กรองชื่อ API หรือชื่อหมวด
        [Spell/Item ID] ค่าที่ใช้กับ probe หมวด 7 / 8
        [Only SECRET]  โชว์เฉพาะแถวที่เคยเจอ secret (กด Scan All ก่อนเพื่อให้
                       ครอบคลุมแถวที่ยังไม่เคยเปิดไปดู)
        [Freeze]       หยุดยิง API — ค้างค่าไว้ให้ capture
        [Scan All]     ยิงทุกแถวทุกหน้า 1 รอบ
        [Copy Report]  สรุปทุกหน้าเป็นข้อความ (flag + error เท่านั้น)
        [< >]          เปลี่ยนหน้า (ล้อเมาส์ก็ได้) · [Jump] เลือกหมวด

    ช่องผลลัพธ์อ่านยังไง:
        <secret>DAMAGER   = เป็น secret และค่าจริงคือ DAMAGER
        "DAMAGER"         = ค่าปกติ เทียบได้
        nil               = API คืน nil
        ERR ...           = เรียกแล้ว throw (ปกติแปลว่าโดน secret guard)
        (not sampled)     = ยัง freeze อยู่และแถวนี้ยังไม่เคยถูกยิง

    ข้อบังคับด้าน secret (GeRODPS_Tools/SECRETS.md):
      * ผลลัพธ์ออกทาง FontString เท่านั้น — EditBox รับ tainted string ไม่ได้
      * ห้าม table.concat กับ list ที่อาจมี tainted string → ใช้ ".." loop
      * ห้ามวัด GetText / GetStringWidth / GetStringHeight ของ FontString
        ที่ถือ tainted text → ขนาดทุกอย่างมาจากขนาดเฟรมล้วน
      * รายงานที่ก๊อปได้ (EditBox) ใส่ได้เฉพาะ flag + ข้อความ error ที่
        ยืนยันแล้วว่าไม่ secret

    Public:
        GeRODPS_Tools.ToggleSecretAPICheck()
        GeRODPS_Tools.ShowSecretAPICheck()
        GeRODPS_Tools.HideSecretAPICheck()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME  = "GeRODPS_ToolsSecretAPIFrame"
local REPORT_NAME = "GeRODPS_ToolsSecretAPIReportFrame"

-- Rule 10 (wow-coding): (0,0) ของ frame รวม title bar — แถวแรกต้องเผื่อ TITLE_H
local TITLE_H   = 28
local SIDE_PAD  = 12
local ROW_H     = 15
local NAME_W    = 340
local HEAD_H    = 78     -- แถบควบคุม 3 บรรทัดใต้ title bar
local BOTTOM_H  = 30     -- แถบเปลี่ยนหน้าด้านล่าง
local TICK      = 0.25

local NUM_UNITS = 4
local DEFAULT_UNITS = { "player", "party1", "target", "targettarget" }

local DEFAULT_W, DEFAULT_H = 1400, 760
local MIN_W,     MIN_H     = 1040, 380
local MAX_W,     MAX_H     = 2560, 1600
local SCREEN_MARGIN = 60

local COL_NIL = "|cff6f6f6f"
local COL_SEC = "|cffff4040"
local COL_VAL = "|cffdddddd"
local COL_ERR = "|cffff9000"
local COL_BLK = "|cff36c8ff"
local COL_HDR = "|cffffd100"
local SEP     = "|cff555555 | |r"

-- ============================================================
-- DB
-- ============================================================

local function GetDB()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    local db = GeRODPS_ToolsDB.secretAPI
    if db == nil then
        db = {}
        GeRODPS_ToolsDB.secretAPI = db
    end
    if db.units == nil then
        db.units = {}
        for i = 1, NUM_UNITS do db.units[i] = DEFAULT_UNITS[i] end
    end
    if db.spellID == nil then db.spellID = 6603 end
    if db.itemID  == nil then db.itemID  = 1180 end
    return db
end

-- ============================================================
-- Secret-safe formatting (ดู SECRETS.md — DISPLAY rule)
-- ============================================================

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

-- `..` + tostring บน secret คืน "secret string" (12.0.7) — FontString รับได้
local function FormatSecretValue(v)
    local ok, s = pcall(function() return "" .. tostring(v) end)
    if ok == true then return s end
    return "?"
end

-- ใช้ได้เฉพาะค่าที่ IsSecret-gate มาแล้วว่าไม่ secret
local function PlainValue(v)
    local t = type(v)
    if t == "nil"      then return "nil" end
    if t == "boolean"  then return tostring(v) end
    if t == "string"   then return '"' .. v .. '"' end
    if t == "number"   then
        if v % 1 == 0 then return string.format("%d", v) end
        return string.format("%.3f", v)
    end
    if t == "table"    then return "{table}" end
    if t == "function" then return "<function>" end
    return "<" .. t .. ">"
end

-- ตัด "path/file.lua:123: " ออกจากหัวข้อความ error ให้อ่านง่ายในช่องแคบ
local function ShortError(msg)
    local m = string.match(msg, "^.-%.lua:%d+:%s*(.+)$")
    if m ~= nil then return m end
    return msg
end

-- ============================================================
-- Probe execution
-- ============================================================

-- นับจำนวน return จริง (ห้ามใช้ # เพราะ nil ตรงกลางทำให้นับพลาด)
local function Pack(...)
    return select("#", ...), { ... }
end

-- คืน: displayText (อาจ tainted) · isSecret (boolean ปกติ) ·
--      plainErr (string|nil) · blockedReason (string|nil)
--
-- BLOCKED = probe รู้ล่วงหน้าจาก C_Secrets ว่าเรียกไปก็ throw เลยไม่เรียก
-- (12.1 บล็อก aura ทาง index/slot/instanceID) — ต่างจาก ERR ที่เรียกแล้วพัง
local function RunProbe(probe, unit)
    local n, t
    if probe.unitScoped == true then
        n, t = Pack(pcall(probe.fn, unit))
    else
        n, t = Pack(pcall(probe.fn))
    end

    local ok = t[1]        -- pcall คืน boolean ปกติเสมอ — เทียบได้
    if ok ~= true then
        local e = t[2]
        if IsSecret(e) then
            return COL_ERR .. "ERR|r <secret error>", false, nil
        end
        local okf, s = pcall(tostring, e)
        if okf ~= true then s = "?" end
        local short = ShortError(s)
        return COL_ERR .. "ERR|r " .. short, false, short, nil
    end

    local count = n - 1
    if count == 0 then
        return COL_NIL .. "(no return)|r", false, nil, nil
    end

    -- sentinel จาก Blocked("...") ใน SecretAPIProbes.lua
    -- IsSecret ต้องมาก่อน type() / index เสมอ
    if count == 1 then
        local bv = t[2]
        if bv ~= nil and IsSecret(bv) ~= true and type(bv) == "table" then
            local reason = bv.__blockedReason
            if reason ~= nil then
                return COL_BLK .. "BLOCKED|r " .. reason, false, nil, reason
            end
        end
    end

    local secret = false
    local out = ""
    for i = 1, count do
        local v = t[i + 1]
        local piece
        if v == nil then
            piece = COL_NIL .. "nil|r"
        elseif IsSecret(v) then
            secret = true
            piece = COL_SEC .. "<secret>|r" .. FormatSecretValue(v)
        else
            local okf, s = pcall(PlainValue, v)
            if okf ~= true then s = "<opaque>" end
            piece = COL_VAL .. s .. "|r"
        end
        if i > 1 then out = out .. SEP end
        out = out .. piece          -- ".." loop เท่านั้น ห้าม table.concat
    end
    return out, secret, nil, nil
end

-- ============================================================
-- State
-- ============================================================

local frame, reportFrame
local rows       = {}      -- pooled row widgets
local unitBoxes  = {}
local headLabels = {}
local pages      = {}      -- pages[n] = { title = <หมวด>, rows = { entry, ... } }
local curPage    = 1
local rowsPerPage = 1
local listDirty  = true
local frozen     = false
local onlySecret = false
local filterText = ""
local tickFrame, tickAccum = nil, 0
local statusFS, pageFS, filterBox, spellBox, itemBox

local function Units()
    return GetDB().units
end

-- จำนวน column ที่ต้องแสดงจริงของแถวนั้น
local function ColCount(probe)
    if probe.unitScoped == true then return NUM_UNITS end
    return 1
end

-- ============================================================
-- Page building
-- ============================================================

local function ItemEverSecret(item)
    if item._sec == nil then return false end
    for i = 1, NUM_UNITS do
        if item._sec[i] == true then return true end
    end
    return false
end

-- 1 หมวด = 1 หน้า · หมวดที่ยาวเกินความสูงหน้าจอ → ตัดเป็นหน้าย่อย "(ต่อ)"
local function BuildPages()
    pages = {}
    local cats = TOOL.SecretAPIProbes
    if cats == nil then return end

    local flt  = filterText
    local perPage = rowsPerPage
    if perPage < 2 then perPage = 2 end

    for _, cat in ipairs(cats) do
        local matched = {}
        for _, item in ipairs(cat.items) do
            if item._hay == nil then
                item._hay = string.lower(cat.title .. " " .. item.name)
            end
            local pass = true
            if flt ~= "" and string.find(item._hay, flt, 1, true) == nil then
                pass = false
            end
            if pass == true and onlySecret == true and ItemEverSecret(item) ~= true then
                pass = false
            end
            if pass == true then matched[#matched + 1] = item end
        end

        local i = 1
        local part = 0
        while i <= #matched do
            part = part + 1
            local title = cat.title
            if part > 1 then title = cat.title .. "   (ต่อ " .. part .. ")" end
            local page = { title = title, cat = cat.title, rows = {} }
            page.rows[1] = { header = title }
            while i <= #matched and #page.rows < perPage do
                page.rows[#page.rows + 1] = { item = matched[i] }
                i = i + 1
            end
            pages[#pages + 1] = page
        end
    end

    if #pages == 0 then
        pages[1] = {
            title = "(ไม่มีแถวที่ตรงกับเงื่อนไข)",
            cat   = "",
            rows  = { { header = "(ไม่มีแถวที่ตรงกับ Filter / Only SECRET)" } },
        }
    end
    if curPage > #pages then curPage = #pages end
    if curPage < 1 then curPage = 1 end
end

-- ============================================================
-- Row rendering
-- ============================================================

local function ClearRow(row)
    row.name:SetText("")
    row.bg:SetColorTexture(0, 0, 0, 0)
    for i = 1, NUM_UNITS do
        row.cells[i]:SetText("")
        row.cells[i]:Hide()
    end
    row.probe = nil
    row:Hide()
end

local function RenderRow(row, entry, zebra)
    row:Show()
    if entry.header ~= nil then
        row.bg:SetColorTexture(0.16, 0.26, 0.42, 0.60)
        row.name:SetWidth(1400)
        row.name:SetText(COL_HDR .. entry.header .. "|r")
        for i = 1, NUM_UNITS do
            row.cells[i]:SetText("")
            row.cells[i]:Hide()
        end
        row.probe = nil
        return
    end

    local item = entry.item
    row.probe = item
    row.name:SetWidth(NAME_W - 6)
    if zebra == true then
        row.bg:SetColorTexture(1, 1, 1, 0.035)
    else
        row.bg:SetColorTexture(0, 0, 0, 0)
    end

    local prefix = "|cffbfd4ff"
    if item.unitScoped ~= true then prefix = "|cffb9a7e0" end
    row.name:SetText(prefix .. item.name .. "|r")

    local cols  = ColCount(item)
    local units = Units()
    for i = 1, NUM_UNITS do
        local fs = row.cells[i]
        if i > cols then
            fs:SetText("")
            fs:Hide()
        else
            fs:Show()
            local text
            if frozen == true then
                if item._text ~= nil and item._text[i] ~= nil then
                    text = item._text[i]
                else
                    text = COL_NIL .. "(not sampled)|r"
                end
            else
                local secret, err, blk
                text, secret, err, blk = RunProbe(item, units[i])
                if item._text == nil then item._text = {} end
                item._text[i] = text
                if item._seen == nil then item._seen = {} end
                item._seen[i] = true
                if secret == true then
                    if item._sec == nil then item._sec = {} end
                    item._sec[i] = true
                end
                if err ~= nil then
                    if item._err == nil then item._err = {} end
                    item._err[i] = err
                end
                if blk ~= nil then
                    if item._blk == nil then item._blk = {} end
                    item._blk[i] = blk
                end
            end
            fs:SetText(text)
        end
    end
end

local function Refresh()
    if frame == nil or frame:IsShown() ~= true then return end
    if listDirty == true or onlySecret == true then
        BuildPages()
        listDirty = false
    end

    local page = pages[curPage]
    local list
    if page == nil then list = {} else list = page.rows end

    for i = 1, #rows do
        local row = rows[i]
        if i > rowsPerPage then
            ClearRow(row)
        else
            local entry = list[i]
            if entry == nil then
                ClearRow(row)
            else
                RenderRow(row, entry, i % 2 == 0)
            end
        end
    end

    if pageFS ~= nil then
        local title = ""
        if page ~= nil then title = page.title end
        pageFS:SetText("|cffffffffหน้า " .. curPage .. " / " .. #pages
            .. "|r   |cff9ecbff" .. title .. "|r")
    end
end

local function GotoPage(n)
    if #pages == 0 then return end
    if n < 1 then n = 1 end
    if n > #pages then n = #pages end
    if n == curPage then return end
    curPage = n
    Refresh()
end

-- ============================================================
-- Scan all (ทุกหน้า รวมแถวที่ยังไม่เคยเปิดไปดู)
-- ============================================================

local function ScanAll()
    local cats = TOOL.SecretAPIProbes
    if cats == nil then return 0 end
    local found = 0
    local units = Units()
    for _, cat in ipairs(cats) do
        for _, item in ipairs(cat.items) do
            local cols = ColCount(item)
            if item._text == nil then item._text = {} end
            if item._seen == nil then item._seen = {} end
            for i = 1, cols do
                local text, secret, err, blk = RunProbe(item, units[i])
                item._text[i] = text
                item._seen[i] = true
                if secret == true then
                    if item._sec == nil then item._sec = {} end
                    if item._sec[i] ~= true then found = found + 1 end
                    item._sec[i] = true
                end
                if err ~= nil then
                    if item._err == nil then item._err = {} end
                    item._err[i] = err
                end
                if blk ~= nil then
                    if item._blk == nil then item._blk = {} end
                    item._blk[i] = blk
                end
            end
        end
    end
    return found
end

local function ResetFlags()
    local cats = TOOL.SecretAPIProbes
    if cats == nil then return end
    for _, cat in ipairs(cats) do
        for _, item in ipairs(cat.items) do
            item._sec  = nil
            item._err  = nil
            item._blk  = nil
            item._seen = nil
            item._text = nil
        end
    end
end

-- ============================================================
-- Report (ข้อความล้วน — ห้ามใส่ค่าที่เป็น secret ลงไป)
-- ============================================================

local function BuildReport()
    local db = GetDB()
    local units = db.units
    local out = "GeRODPS Secret API Check\n"
    out = out .. "time: " .. date("%d/%m %H:%M:%S") .. "\n"

    local restr = "n/a"
    if C_Secrets ~= nil and C_Secrets.HasSecretRestrictions ~= nil then
        local ok, v = pcall(C_Secrets.HasSecretRestrictions)
        if ok == true then restr = tostring(v) end
    end
    out = out .. "HasSecretRestrictions: " .. restr
        .. "  |  InCombatLockdown: " .. tostring(InCombatLockdown())
        .. "  |  UnitAffectingCombat(player): " .. tostring(UnitAffectingCombat("player"))
        .. "\n"

    out = out .. "units:"
    for i = 1, NUM_UNITS do
        out = out .. "  " .. i .. "=" .. units[i]
    end
    out = out .. "\n"
    out = out .. "spellID=" .. tostring(db.spellID)
        .. "  itemID=" .. tostring(db.itemID) .. "\n"
    out = out .. "legend:  S = secret   B = blocked   E = error"
        .. "   . = plain   ? = not sampled\n"
    out = out .. "         B = C_Secrets บอกล่วงหน้าว่าเรียกไม่ได้ (ไม่ได้เรียกจริง)\n"
    out = out .. "         คอลัมน์เรียงตาม units 1..4 ข้างบน\n"
    out = out .. string.rep("-", 78) .. "\n"

    local cats = TOOL.SecretAPIProbes
    if cats == nil then return out .. "(SecretAPIProbes.lua ไม่ได้โหลด)\n" end

    for _, cat in ipairs(cats) do
        out = out .. "\n[" .. cat.title .. "]\n"
        for _, item in ipairs(cat.items) do
            local cols  = ColCount(item)
            local flags = ""
            for i = 1, NUM_UNITS do
                local ch = " "
                if i <= cols then
                    if item._seen == nil or item._seen[i] ~= true then
                        ch = "?"
                    elseif item._sec ~= nil and item._sec[i] == true then
                        ch = "S"
                    elseif item._blk ~= nil and item._blk[i] ~= nil then
                        ch = "B"
                    elseif item._err ~= nil and item._err[i] ~= nil then
                        ch = "E"
                    else
                        ch = "."
                    end
                end
                flags = flags .. ch
            end
            out = out .. "  " .. flags .. "  " .. item.name .. "\n"
            if item._err ~= nil then
                for i = 1, cols do
                    local e = item._err[i]
                    if e ~= nil then
                        out = out .. "        ERR[" .. i .. "] " .. e .. "\n"
                    end
                end
            end
            if item._blk ~= nil then
                for i = 1, cols do
                    local b = item._blk[i]
                    if b ~= nil then
                        out = out .. "        BLOCKED[" .. i .. "] " .. b .. "\n"
                    end
                end
            end
        end
    end
    return out
end

local function CreateReportFrame()
    if reportFrame ~= nil then return reportFrame end
    local f = CreateFrame("Frame", REPORT_NAME, UIParent, "BasicFrameTemplateWithInset")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetSize(780, 540)
    f:SetPoint("CENTER", 0, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.TitleText ~= nil then
        f.TitleText:SetText("Secret API Check — Report (Ctrl+A / Ctrl+C)")
    end

    local scroll = CreateFrame("ScrollFrame", REPORT_NAME .. "Scroll", f,
        "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", SIDE_PAD, -(TITLE_H + 8))
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(SIDE_PAD + 22), 14)

    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true)
    eb:SetFontObject("ChatFontNormal")
    eb:SetMaxLetters(0)
    eb:SetAutoFocus(false)
    eb:SetWidth(720)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(eb)
    f.editBox = eb

    table.insert(UISpecialFrames, REPORT_NAME)
    reportFrame = f
    return f
end

local function ShowReport()
    local f = CreateReportFrame()
    -- BuildReport คืน string ธรรมดาล้วน (flag + error ที่ผ่าน IsSecret แล้ว)
    -- EditBox รับ tainted text ไม่ได้ จึงห้ามใส่ค่าที่มาจาก API ตรงๆ
    local ok, txt = pcall(BuildReport)
    if ok ~= true then txt = "report error" end
    f.editBox:SetText(txt)
    f.editBox:SetCursorPosition(0)
    f:Show()
    f:Raise()
end

-- ============================================================
-- Geometry
-- ============================================================

local function SavePosition(self)
    local db = GetDB()
    local point, _, relPoint, x, y = self:GetPoint(1)
    db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

local function SaveSize(self)
    local db = GetDB()
    db.w, db.h = self:GetWidth(), self:GetHeight()
end

local function ApplySavedGeometry(self)
    local db = GetDB()
    local screenW, screenH = UIParent:GetWidth(), UIParent:GetHeight()
    local w = db.w or DEFAULT_W
    local h = db.h or DEFAULT_H
    local maxW = screenW - 2 * SCREEN_MARGIN
    local maxH = screenH - 2 * SCREEN_MARGIN
    if w > maxW then w = maxW end
    if h > maxH then h = maxH end
    if w < MIN_W then w = MIN_W end
    if h < MIN_H then h = MIN_H end

    self:ClearAllPoints()
    if db.point ~= nil and db.relPoint ~= nil and db.x ~= nil and db.y ~= nil then
        self:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    else
        self:SetPoint("CENTER")
    end
    self:SetSize(w, h)
end

-- ============================================================
-- Layout — ขนาดทุกอย่างมาจากขนาดเฟรม ไม่ได้วัดจากข้อความ
-- (วัด FontString ที่ถือ tainted text ไม่ได้ — SECRETS.md)
-- ============================================================

local function Layout()
    if frame == nil then return end
    local w = frame:GetWidth()
    local h = frame:GetHeight()

    local bodyW = w - SIDE_PAD * 2
    local valW  = math.floor((bodyW - NAME_W) / NUM_UNITS)
    if valW < 80 then valW = 80 end

    for i = 1, NUM_UNITS do
        local fs = headLabels[i]
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", frame, "TOPLEFT",
            SIDE_PAD + NAME_W + (i - 1) * valW, -(TITLE_H + HEAD_H - 16))
        fs:SetWidth(valW - 6)
    end

    local bodyTop = TITLE_H + HEAD_H
    local bodyH   = h - bodyTop - BOTTOM_H - 8
    local newPerPage = math.floor(bodyH / ROW_H)
    if newPerPage < 2 then newPerPage = 2 end
    if newPerPage > #rows then newPerPage = #rows end
    if newPerPage ~= rowsPerPage then
        rowsPerPage = newPerPage
        listDirty = true
    end

    for i = 1, #rows do
        local row = rows[i]
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame, "TOPLEFT",
            SIDE_PAD, -(bodyTop + (i - 1) * ROW_H))
        row:SetSize(bodyW, ROW_H)
        for c = 1, NUM_UNITS do
            local fs = row.cells[c]
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", row, "TOPLEFT", NAME_W + (c - 1) * valW, 0)
            fs:SetWidth(valW - 6)
        end
    end

    Refresh()
end

-- ============================================================
-- ตัวนับสถานะ (flag เป็น boolean ปกติ — นับตรงๆ ได้ ไม่แตะค่า secret)
-- ============================================================

local function CountFlags()
    local cats = TOOL.SecretAPIProbes
    if cats == nil then return 0, 0, 0 end
    local sec, err, blk = 0, 0, 0
    for _, cat in ipairs(cats) do
        for _, item in ipairs(cat.items) do
            for i = 1, NUM_UNITS do
                if item._sec ~= nil and item._sec[i] == true then sec = sec + 1 end
                if item._err ~= nil and item._err[i] ~= nil then err = err + 1 end
                if item._blk ~= nil and item._blk[i] ~= nil then blk = blk + 1 end
            end
        end
    end
    return sec, err, blk
end

-- ============================================================
-- Tick
-- ============================================================

local function Tick(_, dt)
    if frame == nil or frame:IsShown() ~= true then return end
    tickAccum = tickAccum + dt
    if tickAccum < TICK then return end
    tickAccum = 0
    Refresh()

    if statusFS ~= nil then
        local restr = "n/a"
        if C_Secrets ~= nil and C_Secrets.HasSecretRestrictions ~= nil then
            local ok, v = pcall(C_Secrets.HasSecretRestrictions)
            if ok == true then restr = tostring(v) end
        end
        local mode = "|cff88ff88LIVE|r"
        if frozen == true then mode = "|cffffcc00FROZEN|r" end
        local nSec, nErr, nBlk = CountFlags()
        statusFS:SetText(mode
            .. "  |cff999999restrict|r " .. restr
            .. "  |cff999999combat|r " .. tostring(InCombatLockdown())
            .. "  " .. COL_SEC .. "secret " .. nSec .. "|r"
            .. "  " .. COL_BLK .. "blocked " .. nBlk .. "|r"
            .. "  " .. COL_ERR .. "err " .. nErr .. "|r")
    end
end

local function EnsureTicker()
    if tickFrame ~= nil then return end
    tickFrame = CreateFrame("Frame")
    tickFrame:SetScript("OnUpdate", Tick)
end

-- ============================================================
-- Widget helpers
-- ============================================================

local function MakeLabel(parent, text, x, y, width)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if width ~= nil then fs:SetWidth(width) end
    fs:SetText(text)
    return fs
end

local function MakeEditBox(parent, x, y, width, onCommit)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    eb:SetSize(width, 20)
    eb:SetAutoFocus(false)
    eb:SetFontObject("ChatFontNormal")
    eb:SetMaxLetters(64)
    eb:SetScript("OnEnterPressed", function(self)
        onCommit(self:GetText() or "")
        self:ClearFocus()
    end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEditFocusLost", function(self)
        onCommit(self:GetText() or "")
    end)
    return eb
end

local function MakeCheck(parent, label, x, y, initial, onToggle)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb:SetSize(22, 22)
    cb:SetChecked(initial)
    local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    fs:SetText(label)
    cb:SetScript("OnClick", function(self)
        onToggle(self:GetChecked() == true)
    end)
    return cb
end

local function MakeButton(parent, label, x, y, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    b:SetSize(width, 20)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function CreateRowWidget(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_H)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(0, 0, 0, 0)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 2, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.name:SetWidth(NAME_W - 6)

    row.cells = {}
    for c = 1, NUM_UNITS do
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        row.cells[c] = fs
    end

    -- tooltip: คำอธิบาย + จุดที่โปรเจกต์ใช้ค่านั้น (ข้อความของเราเอง ไม่ tainted)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        local p = self.probe
        if p == nil then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine(p.name, 1, 0.82, 0)
        if p.note ~= nil then
            GameTooltip:AddLine(p.note, 0.8, 0.9, 1, true)
        end
        if p.unitScoped == true then
            GameTooltip:AddLine("unit-scoped: ยิงซ้ำทีละ unit ใน 4 คอลัมน์",
                0.6, 0.6, 0.6, true)
        else
            GameTooltip:AddLine("ไม่ผูกกับ unit — ผลเดียวยาวเต็มแถว",
                0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)

    row:Hide()
    return row
end

local function ShowJumpMenu(owner)
    if MenuUtil == nil or MenuUtil.CreateContextMenu == nil then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("ไปที่หมวด")
        local seen = {}
        for idx, page in ipairs(pages) do
            if page.cat ~= "" and seen[page.cat] == nil then
                seen[page.cat] = true
                local target = idx
                root:CreateButton(page.cat, function() GotoPage(target) end)
            end
        end
    end)
end

-- ============================================================
-- Frame builder
-- ============================================================

local function CreateMainFrame()
    if frame ~= nil then return frame end
    local db = GetDB()

    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetUserPlaced(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    frame:SetResizable(true)
    if frame.SetResizeBounds ~= nil then
        frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    end
    if frame.TitleText ~= nil then
        frame.TitleText:SetText("GeRODPS Tools — Secret API Check")
    end

    -- ---------- บรรทัด 1: units ----------
    -- Rule 10: แถวแรก anchor ที่ frame (ตัวนอก) + เผื่อความสูง title bar
    local y1 = -(TITLE_H + 6)
    MakeLabel(frame, "Units:", SIDE_PAD, y1 - 4, 44)
    for i = 1, NUM_UNITS do
        local idx = i
        unitBoxes[i] = MakeEditBox(frame, SIDE_PAD + 48 + (i - 1) * 148, y1, 138,
            function(text)
                local t = string.gsub(text, "^%s*(.-)%s*$", "%1")
                if t == "" then t = DEFAULT_UNITS[idx] end
                -- เปลี่ยน unit = flag เดิมใช้ไม่ได้แล้ว แต่แค่คลิกออกโดยไม่แก้
                -- ต้องไม่ล้างผล Scan All ทิ้ง
                if t == GetDB().units[idx] then return end
                GetDB().units[idx] = t
                unitBoxes[idx]:SetText(t)
                headLabels[idx]:SetText("|cff9ecbff" .. t .. "|r")
                ResetFlags()
                listDirty = true
                Refresh()
            end)
        unitBoxes[i]:SetText(db.units[i])
    end
    MakeButton(frame, "Reset units", SIDE_PAD + 48 + NUM_UNITS * 148, y1, 100, function()
        for i = 1, NUM_UNITS do
            GetDB().units[i] = DEFAULT_UNITS[i]
            unitBoxes[i]:SetText(DEFAULT_UNITS[i])
            headLabels[i]:SetText("|cff9ecbff" .. DEFAULT_UNITS[i] .. "|r")
        end
        ResetFlags()
        listDirty = true
        Refresh()
    end)

    -- ---------- บรรทัด 2: filter / input / toggle / action ----------
    local y2 = y1 - 26
    MakeLabel(frame, "Filter:", SIDE_PAD, y2 - 4, 44)
    filterBox = MakeEditBox(frame, SIDE_PAD + 48, y2, 190, function() end)
    filterBox:SetScript("OnTextChanged", function(self)
        filterText = string.lower(self:GetText() or "")
        curPage = 1
        listDirty = true
    end)

    MakeLabel(frame, "Spell ID:", SIDE_PAD + 248, y2 - 4, 56)
    spellBox = MakeEditBox(frame, SIDE_PAD + 308, y2, 70, function(text)
        local v = tonumber(text)
        if v == nil then v = GetDB().spellID end
        GetDB().spellID = v
        TOOL.SecretAPICtx.spellID = v
        spellBox:SetText(tostring(v))
    end)
    spellBox:SetText(tostring(db.spellID))

    MakeLabel(frame, "Item ID:", SIDE_PAD + 388, y2 - 4, 52)
    itemBox = MakeEditBox(frame, SIDE_PAD + 444, y2, 70, function(text)
        local v = tonumber(text)
        if v == nil then v = GetDB().itemID end
        GetDB().itemID = v
        TOOL.SecretAPICtx.itemID = v
        itemBox:SetText(tostring(v))
    end)
    itemBox:SetText(tostring(db.itemID))

    MakeCheck(frame, "Only SECRET", SIDE_PAD + 524, y2 + 2, false, function(on)
        onlySecret = on
        curPage = 1
        listDirty = true
        Refresh()
    end)
    MakeCheck(frame, "Freeze", SIDE_PAD + 654, y2 + 2, false, function(on)
        frozen = on
        Refresh()
    end)

    MakeButton(frame, "Scan All", SIDE_PAD + 744, y2, 78, function()
        local n = ScanAll()
        listDirty = true
        Refresh()
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffaaffaa[Secret API Check]|r Scan All — เจอ secret เพิ่ม " .. n .. " ช่อง")
    end)
    MakeButton(frame, "Reset flags", SIDE_PAD + 828, y2, 84, function()
        ResetFlags()
        listDirty = true
        Refresh()
    end)
    MakeButton(frame, "Copy Report", SIDE_PAD + 918, y2, 92, ShowReport)

    statusFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, y2 - 4)
    statusFS:SetJustifyH("RIGHT")
    statusFS:SetWordWrap(false)
    statusFS:SetText("")

    -- ---------- บรรทัด 3: หัวคอลัมน์ ----------
    local y3 = -(TITLE_H + HEAD_H - 16)
    MakeLabel(frame, "|cffffffffAPI / Expression|r", SIDE_PAD + 2, y3, NAME_W - 6)
    for i = 1, NUM_UNITS do
        local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        fs:SetText("|cff9ecbff" .. db.units[i] .. "|r")
        headLabels[i] = fs
    end

    local sep = frame:CreateTexture(nil, "ARTWORK")
    sep:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + HEAD_H - 2))
    sep:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + HEAD_H - 2))
    sep:SetHeight(1)
    sep:SetColorTexture(0.5, 0.5, 0.5, 0.5)

    -- ---------- rows ----------
    local maxRows = math.floor((MAX_H - TITLE_H - HEAD_H - BOTTOM_H) / ROW_H)
    for i = 1, maxRows do
        rows[i] = CreateRowWidget(frame)
    end

    -- ---------- แถบเปลี่ยนหน้า (ล่างสุด) ----------
    local prevBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    prevBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", SIDE_PAD, 8)
    prevBtn:SetSize(52, 20)
    prevBtn:SetText("< Prev")
    prevBtn:SetScript("OnClick", function() GotoPage(curPage - 1) end)

    local nextBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    nextBtn:SetPoint("LEFT", prevBtn, "RIGHT", 4, 0)
    nextBtn:SetSize(52, 20)
    nextBtn:SetText("Next >")
    nextBtn:SetScript("OnClick", function() GotoPage(curPage + 1) end)

    local jumpBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    jumpBtn:SetPoint("LEFT", nextBtn, "RIGHT", 8, 0)
    jumpBtn:SetSize(70, 20)
    jumpBtn:SetText("Jump...")
    jumpBtn:SetScript("OnClick", function(self) ShowJumpMenu(self) end)

    pageFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageFS:SetPoint("LEFT", jumpBtn, "RIGHT", 10, 0)
    pageFS:SetJustifyH("LEFT")
    pageFS:SetWordWrap(false)
    pageFS:SetWidth(700)
    pageFS:SetText("")

    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        if delta > 0 then GotoPage(curPage - 1) else GotoPage(curPage + 1) end
    end)

    frame:SetScript("OnSizeChanged", function(self)
        SaveSize(self)
        Layout()
    end)

    -- resize grip (มุมขวาล่าง เหนือแถบเปลี่ยนหน้าเล็กน้อย)
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
        if button == "LeftButton" then
            frame:StopMovingOrSizing()
            SaveSize(frame)
            Layout()
        end
    end)

    table.insert(UISpecialFrames, FRAME_NAME)
    ApplySavedGeometry(frame)

    TOOL.SecretAPICtx.spellID = db.spellID
    TOOL.SecretAPICtx.itemID  = db.itemID

    listDirty = true
    Layout()
    frame:Hide()
    return frame
end

-- ============================================================
-- Public API
-- ============================================================

function TOOL.ShowSecretAPICheck()
    local f = CreateMainFrame()
    EnsureTicker()
    if f:IsShown() ~= true then
        ApplySavedGeometry(f)
        f:Show()
        Layout()
    end
end

function TOOL.HideSecretAPICheck()
    if frame ~= nil and frame:IsShown() == true then frame:Hide() end
end

function TOOL.ToggleSecretAPICheck()
    local f = CreateMainFrame()
    EnsureTicker()
    if f:IsShown() == true then
        f:Hide()
    else
        ApplySavedGeometry(f)
        f:Show()
        Layout()
    end
end

if TOOL.RegisterTool ~= nil then
    TOOL.RegisterTool("Secret API Check (Realtime)", TOOL.ToggleSecretAPICheck)
end
