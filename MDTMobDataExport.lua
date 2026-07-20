--[[
    GeRODPS_Tools / MDTMobDataExport.lua

    "MDT Mob Data Export" tool — walk every dungeon/mob/spell that Mythic
    Dungeon Tools has loaded (current season) and dump a plain-text report
    the user can copy (Ctrl+A / Ctrl+C) and paste to an AI to decide, per
    spell, whether it is interruptible or must be defensive'd against.

    Data sources (all read from the in-memory MDT tables — MDT loads its
    current-season enemy DB eagerly at addon load, no window open needed):
      • MDT.dungeonSelectionToIndex[1]  → current-season dungeon indices
      • MDT.dungeonEnemies[dungeonIdx]  → array of enemy entries
          .name .id .count .health .level .creatureType .isBoss
          .encounterID .characteristics .spells = { [spellID] = flagTbl }
      • MDT:GetDungeonName(idx)          → localized dungeon name
      • MDT.dungeonTotalCount[idx].normal→ enemy-forces total
      • MDT:GetEnemyInfoSpellBlacklist() → player-debuff noise to hide
    MDT stores ONLY 7 boolean flags per spell (interruptible/magic/poison/
    disease/curse/bleed/enrage). Range / cast time / description come from
    the GAME tooltip, so this tool reads them itself:
      • C_Spell.GetSpellInfo(id).castTime  (ms; non-secret out-of-combat)
      • C_TooltipInfo.GetSpellByID(id)      (lines → leftText)

    Scan is async (BATCH per frame) + out-of-combat gated (tooltip text is
    secret in combat) + prefetches spell data (C_Spell.RequestLoadSpellData)
    and retries tooltips that aren't loaded yet (the repo's other MDT scans
    silently skip unloaded tooltips — this one retries).

    Output goes to a NATIVE multiline EditBox (not AceGUI MultiLineEditBox —
    PasteSpeedTest proved AceGUI MLEB freezes 1min+ on ~100KB text).

    Public:
        GeRODPS_Tools.ShowMDTMobDataExport()
        GeRODPS_Tools.HideMDTMobDataExport()
        GeRODPS_Tools.ToggleMDTMobDataExport()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME    = "GeRODPS_ToolsMDTMobDataExportFrame"
local SCREEN_MARGIN = 50
-- Frame (0,0) includes the title bar, so the first content row must clear it.
-- Anchor to `frame` + reserve TITLE_H — never rely on `frame.Inset` (nil on
-- some clients → silent title-bar overlap). (wow-coding Rule 10)
local TITLE_H       = 28
local SIDE_PAD      = 12
local TOP_PAD       = 6

local DEFAULT_W, DEFAULT_H = 900, 620
local MIN_W,     MIN_H     = 620, 400
local MAX_W,     MAX_H     = 1500, 1000

local BATCH     = 40              -- spellIDs read per frame
local MAX_RETRY = 5               -- tooltip retry rounds (0.5s apart)
local RETRY_GAP = 0.5

-- MDT per-spell flag keys, in MDT's own render order.
local STATUS_ORDER = { "interruptible", "magic", "poison", "disease", "curse", "bleed", "enrage" }

-- ============================================================
-- DB (geometry + last options)
-- ============================================================

local function GetDB()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    GeRODPS_ToolsDB.mdtMobExport = GeRODPS_ToolsDB.mdtMobExport or {}
    return GeRODPS_ToolsDB.mdtMobExport
end

-- Options (persisted). tooltip/flags/cast/stats default ON, hidden OFF.
local function GetOpt()
    local db = GetDB()
    db.opt = db.opt or {}
    local o = db.opt
    if o.tooltip == nil then o.tooltip = true end
    if o.flags   == nil then o.flags   = true end
    if o.cast    == nil then o.cast    = true end
    if o.stats   == nil then o.stats   = true end
    if o.hidden  == nil then o.hidden  = false end
    return o
end

-- ============================================================
-- MDT availability
-- ============================================================

local function GetMDT()
    if not (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("MythicDungeonTools")) then
        return nil
    end
    local MDT = _G.MDT
    if not (MDT and MDT.dungeonEnemies) then return nil end
    return MDT
end

-- ============================================================
-- Formatting helpers (MDT data is plain addon data — NOT secret)
-- ============================================================

local function FormatHP(n)
    n = tonumber(n)
    if not n then return "?" end
    if n >= 1e6 then return string.format("%.2fm", n / 1e6) end
    if n >= 1e3 then return string.format("%.0fk", n / 1e3) end
    return tostring(math.floor(n))
end

local function FlagString(ft)
    if type(ft) ~= "table" then return "-" end
    local t = {}
    for _, k in ipairs(STATUS_ORDER) do
        if ft[k] then t[#t + 1] = k end
    end
    if #t == 0 then return "-" end
    return table.concat(t, ",")
end

local function CCString(ch)
    if type(ch) ~= "table" then return "-" end
    local t = {}
    for k, v in pairs(ch) do
        if v then t[#t + 1] = tostring(k) end
    end
    if #t == 0 then return "-" end
    table.sort(t)
    return table.concat(t, ",")
end

local function DungeonName(MDT, idx)
    local ok, name = pcall(function() return MDT:GetDungeonName(idx) end)
    if ok and type(name) == "string" and name ~= "" and name ~= "-" then return name end
    local dl = MDT.dungeonList and MDT.dungeonList[idx]
    if type(dl) == "string" and dl ~= "" then return dl end
    return "Dungeon " .. tostring(idx)
end

-- Current-season dungeon indices (retail = MDT.dungeonSelectionToIndex[1]).
-- Falls back to sorted keys of dungeonEnemies if the season table is absent.
local function SeasonDungeonIndices(MDT)
    local out = {}
    local sel = MDT.dungeonSelectionToIndex and MDT.dungeonSelectionToIndex[1]
    if type(sel) == "table" then
        for _, di in ipairs(sel) do
            if MDT.dungeonEnemies[di] then out[#out + 1] = di end
        end
    end
    if #out == 0 then
        for di in pairs(MDT.dungeonEnemies) do out[#out + 1] = di end
        table.sort(out)
    end
    return out
end

-- ============================================================
-- Phase A — traverse MDT (sync): structured dungeons + unique spellIDs
-- ============================================================

local function GatherDungeons(MDT, selectedIdx, includeHidden)
    local blacklist = {}
    if not includeHidden and MDT.GetEnemyInfoSpellBlacklist then
        local ok, bl = pcall(function() return MDT:GetEnemyInfoSpellBlacklist() end)
        if ok and type(bl) == "table" then blacklist = bl end
    end

    local idxList
    if selectedIdx and selectedIdx > 0 and MDT.dungeonEnemies[selectedIdx] then
        idxList = { selectedIdx }
    else
        idxList = SeasonDungeonIndices(MDT)
    end

    local dungeons, spellSet = {}, {}
    for _, di in ipairs(idxList) do
        local enemies = MDT.dungeonEnemies[di]
        if type(enemies) == "table" then
            local tc = MDT.dungeonTotalCount and MDT.dungeonTotalCount[di]
            local d = {
                idx    = di,
                name   = DungeonName(MDT, di),
                forces = tc and tc.normal or nil,
                mobs   = {},
            }
            for _, edata in ipairs(enemies) do
                if type(edata) == "table" and edata.name then
                    local mob = {
                        name         = (MDT.L and MDT.L[edata.name]) or edata.name,
                        id           = edata.id,
                        isBoss       = edata.isBoss,
                        encounterID  = edata.encounterID,
                        health       = edata.health,
                        level        = edata.level,
                        creatureType = edata.creatureType,
                        count        = edata.count,
                        cc           = CCString(edata.characteristics),
                        spells       = {},
                    }
                    if type(edata.spells) == "table" then
                        local sids = {}
                        for sid in pairs(edata.spells) do
                            local n = tonumber(sid)
                            if n and n > 0 and not blacklist[n] then
                                sids[#sids + 1] = n
                            end
                        end
                        table.sort(sids)
                        for _, sid in ipairs(sids) do
                            mob.spells[#mob.spells + 1] = { id = sid, flags = FlagString(edata.spells[sid]) }
                            spellSet[sid] = true
                        end
                    end
                    d.mobs[#d.mobs + 1] = mob
                end
            end
            dungeons[#dungeons + 1] = d
        end
    end
    return dungeons, spellSet
end

-- ============================================================
-- Tooltip read — returns array of leftText lines, or nil if not loaded yet
-- (nil = "retry later"; empty array = "read OK, no readable text")
-- ============================================================

local function ReadTooltipLines(sid)
    if not (C_TooltipInfo and C_TooltipInfo.GetSpellByID) then return nil end
    local data = C_TooltipInfo.GetSpellByID(sid)
    if not data or not data.lines then return nil end
    local out = {}
    for _, line in ipairs(data.lines) do
        if TooltipUtil and TooltipUtil.SurfaceArgs then TooltipUtil.SurfaceArgs(line) end
        local t = line.leftText
        if t ~= nil and not (issecretvalue and issecretvalue(t)) then
            local s = tostring(t)
            if s ~= "" then out[#out + 1] = s end
        end
    end
    return out
end

-- ============================================================
-- Build export text from structured data + spell cache
--   cache[sid] = { name, castMs, tip = {lines} | nil }
-- ============================================================

local function CastSegment(c)
    if not c then return "instant" end
    local ms = c.castMs
    if ms == nil or ms == 0 then return "instant" end
    return string.format("cast %.1fs", ms / 1000)
end

local function BuildExportText(dungeons, cache, opt, totalIds)
    local L = {}
    local function push(s) L[#L + 1] = s end

    push("=== GeRODPS MDT Mob Data Export ===")
    push("Format: '### Dungeon' -> '-- Mob | NPC id | Boss/Trash | HP | Lv | Type | Forces | CC'")
    push("        '* [SpellID] Name | cast | MDT-flags'  then tooltip lines prefixed '>'")
    push("MDT flags = interruptible/magic/poison/disease/curse/bleed/enrage (static, from MDT data)")

    -- Header stats line
    local okC, missC = 0, 0
    if opt.tooltip then
        for _, c in pairs(cache) do
            if c.tip and #c.tip > 0 then okC = okC + 1 else missC = missC + 1 end
        end
    end
    local hdr = string.format("Dungeons: %d | Spells: %d", #dungeons, totalIds)
    if opt.tooltip then
        hdr = hdr .. string.format(" (tooltip ok %d, missing %d)", okC, missC)
    end
    push(hdr)
    push("")

    local seenTip = {}      -- sid -> printed once (dedup tooltip across mobs)

    for _, d in ipairs(dungeons) do
        local dline = "### Dungeon: " .. d.name .. " [" .. tostring(d.idx) .. "]"
        if d.forces then dline = dline .. " | Total Forces: " .. tostring(d.forces) end
        push(dline)

        for _, mob in ipairs(d.mobs) do
            if opt.stats then
                local bossTag
                if mob.isBoss then
                    bossTag = mob.encounterID and ("BOSS (enc " .. tostring(mob.encounterID) .. ")") or "BOSS"
                else
                    bossTag = "Trash"
                end
                push(string.format(
                    "-- %s | NPC %s | %s | HP %s | Lv %s | %s | Forces %s | CC: %s",
                    mob.name, tostring(mob.id or "?"), bossTag, FormatHP(mob.health),
                    tostring(mob.level or "?"), tostring(mob.creatureType or "?"),
                    tostring(mob.count or 0), mob.cc))
            else
                push(string.format("-- %s | NPC %s", mob.name, tostring(mob.id or "?")))
            end

            for _, sp in ipairs(mob.spells) do
                local sid = sp.id
                local c = cache[sid]
                local name = (c and c.name) or ("Spell #" .. sid)
                local segs = {}
                if opt.cast  then segs[#segs + 1] = CastSegment(c) end
                if opt.flags then segs[#segs + 1] = "MDT: " .. sp.flags end
                local sline = "* [" .. sid .. "] " .. name
                if #segs > 0 then sline = sline .. " | " .. table.concat(segs, " | ") end
                push(sline)

                if opt.tooltip then
                    if seenTip[sid] then
                        push("  > (see [" .. sid .. "] above)")
                    else
                        seenTip[sid] = true
                        if c and c.tip and #c.tip > 0 then
                            for _, tl in ipairs(c.tip) do
                                if tl ~= name then push("  > " .. tl) end
                            end
                        else
                            push("  > (tooltip unavailable)")
                        end
                    end
                end
            end
        end
        push("")
    end

    return table.concat(L, "\n")
end

-- ============================================================
-- State
-- ============================================================

local frame
local editBox, scrollFrame
local statusFS, charFS, dungeonBtn
local checks = {}                -- key -> CheckButton
local _selectedDungeon = 0       -- 0 = All (season)
local _scanning = false

local function SetStatus(text, color)
    if not statusFS then return end
    local c = color or "FFFFD200"
    statusFS:SetText("|c" .. c .. text .. "|r")
end

local function SetOutput(text)
    if not editBox then return end
    editBox:SetText(text)
    editBox:SetCursorPosition(0)
    if charFS then charFS:SetText(string.format("%d chars", #text)) end
end

-- ============================================================
-- Async scan
-- ============================================================

local function StartScan()
    if _scanning then return end
    local MDT = GetMDT()
    if not MDT then
        SetStatus("MDT not loaded — open/enable the MythicDungeonTools addon.", "FFFF6B6B")
        return
    end
    if InCombatLockdown() then
        SetStatus("In combat — scan needs out-of-combat (tooltip text is secret in combat).", "FFFF6B6B")
        return
    end

    local opt = GetOpt()
    local dungeons, spellSet = GatherDungeons(MDT, _selectedDungeon, opt.hidden)
    if #dungeons == 0 then
        SetOutput("No MDT dungeon data found.")
        SetStatus("No dungeon data.", "FFFF6B6B")
        return
    end

    local ids = {}
    for sid in pairs(spellSet) do ids[#ids + 1] = sid end
    table.sort(ids)
    local totalIds = #ids

    -- Prefetch spell data so names/cast/tooltip warm up.
    if C_Spell and C_Spell.RequestLoadSpellData then
        for _, sid in ipairs(ids) do
            if not (C_Spell.IsSpellDataCached and C_Spell.IsSpellDataCached(sid)) then
                C_Spell.RequestLoadSpellData(sid)
            end
        end
    end

    local cache = {}
    local work  = ids
    local pend  = {}
    local idx, round = 0, 0
    _scanning = true

    local function NeedsRetry(c)
        if c.name == nil then return true end
        if opt.tooltip and c.tip == nil then return true end
        return false
    end

    local Finish, Step

    Finish = function(reason)
        _scanning = false
        local text = BuildExportText(dungeons, cache, opt, totalIds)
        SetOutput(text)
        local done = string.format("Done: %d dungeon, %d spell", #dungeons, totalIds)
        if reason then
            SetStatus(done .. " [" .. reason .. "]", "FFFFB84D")
        else
            SetStatus(done, "FF7FD07F")
        end
    end

    Step = function()
        if InCombatLockdown() then Finish("combat_abort"); return end
        local stop = math.min(idx + BATCH, #work)
        while idx < stop do
            idx = idx + 1
            local sid = work[idx]
            local c = cache[sid]
            if not c then c = {}; cache[sid] = c end

            if c.name == nil or (opt.cast and c.castMs == nil) then
                local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(sid)
                if info then
                    local nm = info.name
                    if nm ~= nil and not (issecretvalue and issecretvalue(nm)) then
                        c.name = tostring(nm)
                    end
                    local ct = info.castTime
                    if ct ~= nil and not (issecretvalue and issecretvalue(ct)) then
                        c.castMs = ct
                    end
                end
            end

            if opt.tooltip and c.tip == nil then
                c.tip = ReadTooltipLines(sid)   -- nil = not loaded → retry
            end

            if NeedsRetry(c) then pend[#pend + 1] = sid end
        end

        SetStatus(string.format("Scanning %d/%d spells%s ...", idx, #work,
            (round > 0) and (" (retry " .. round .. "/" .. MAX_RETRY .. ", pending " .. #work .. ")") or ""))

        if idx < #work then
            C_Timer.After(0, Step)
        elseif #pend > 0 and round < MAX_RETRY then
            round = round + 1
            work, pend, idx = pend, {}, 0
            C_Timer.After(RETRY_GAP, Step)
        else
            Finish()
        end
    end

    SetStatus("Scanning " .. totalIds .. " spells across " .. #dungeons .. " dungeon ...")
    Step()
end

-- ============================================================
-- Geometry persistence
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
    if w > screenW - 2 * SCREEN_MARGIN then w = screenW - 2 * SCREEN_MARGIN end
    if h > screenH - 2 * SCREEN_MARGIN then h = screenH - 2 * SCREEN_MARGIN end
    if w < MIN_W then w = MIN_W end
    if h < MIN_H then h = MIN_H end
    self:ClearAllPoints()
    if db.point and db.relPoint and db.x and db.y then
        self:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    else
        self:SetPoint("CENTER")
    end
    self:SetSize(w, h)
end

-- ============================================================
-- Dungeon picker (MenuUtil context menu)
-- ============================================================

local function UpdateDungeonBtnText()
    if not dungeonBtn then return end
    if _selectedDungeon == 0 then
        dungeonBtn:SetText("Dungeon: All (Season)")
        return
    end
    local MDT = GetMDT()
    local name = MDT and DungeonName(MDT, _selectedDungeon) or ("Dungeon " .. _selectedDungeon)
    dungeonBtn:SetText("Dungeon: " .. name)
end

local function ShowDungeonMenu()
    local MDT = GetMDT()
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(dungeonBtn, function(_owner, root)
        root:CreateButton("All (Season)", function()
            _selectedDungeon = 0; UpdateDungeonBtnText()
        end)
        if MDT then
            for _, di in ipairs(SeasonDungeonIndices(MDT)) do
                local idx = di
                root:CreateButton(DungeonName(MDT, di), function()
                    _selectedDungeon = idx; UpdateDungeonBtnText()
                end)
            end
        end
    end)
end

-- ============================================================
-- Frame builder
-- ============================================================

local function MakeCheck(parent, key, label, x, y)
    local opt = GetOpt()
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    cb:SetChecked(opt[key] and true or false)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    fs:SetText(label)
    cb:SetScript("OnClick", function(self)
        GetOpt()[key] = self:GetChecked() and true or false
    end)
    checks[key] = cb
    return cb
end

local function CreateFrameOnce()
    if frame then return frame end

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
    if frame.SetResizeBounds then
        frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    end
    if frame.TitleText then
        frame.TitleText:SetText("GeRODPS Tools — MDT Mob Data Export")
    end

    -- ── Row 1: dungeon picker + scan + select-all + status ──
    -- Anchor to `frame` and reserve the title bar height explicitly (Rule 10).
    local toolbar = CreateFrame("Frame", nil, frame)
    toolbar:SetHeight(26)
    toolbar:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + TOP_PAD))
    toolbar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + TOP_PAD))

    dungeonBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    dungeonBtn:SetSize(230, 22)
    dungeonBtn:SetPoint("LEFT", toolbar, "LEFT", 0, 0)
    dungeonBtn:SetText("Dungeon: All (Season)")
    dungeonBtn:SetScript("OnClick", ShowDungeonMenu)

    local scanBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    scanBtn:SetSize(130, 22)
    scanBtn:SetPoint("LEFT", dungeonBtn, "RIGHT", 8, 0)
    scanBtn:SetText("Scan & Export")
    scanBtn:SetScript("OnClick", StartScan)

    local selBtn = CreateFrame("Button", nil, toolbar, "UIPanelButtonTemplate")
    selBtn:SetSize(90, 22)
    selBtn:SetPoint("LEFT", scanBtn, "RIGHT", 8, 0)
    selBtn:SetText("Select All")
    selBtn:SetScript("OnClick", function()
        if editBox then editBox:SetFocus(); editBox:HighlightText() end
    end)

    statusFS = toolbar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusFS:SetPoint("LEFT", selBtn, "RIGHT", 12, 0)
    statusFS:SetPoint("RIGHT", toolbar, "RIGHT", -4, 0)
    statusFS:SetJustifyH("LEFT")
    statusFS:SetText("")

    -- ── Row 2: option checkboxes ───────────────────────────
    local optRow = CreateFrame("Frame", nil, frame)
    optRow:SetHeight(24)
    optRow:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -4)
    optRow:SetPoint("TOPRIGHT", toolbar, "BOTTOMRIGHT", 0, -4)
    MakeCheck(optRow, "tooltip", "Tooltip text",          0,   0)
    MakeCheck(optRow, "flags",   "MDT flags",             150, 0)
    MakeCheck(optRow, "cast",    "Cast time",             270, 0)
    MakeCheck(optRow, "stats",   "Mob stats",             390, 0)
    MakeCheck(optRow, "hidden",  "Include hidden spells", 510, 0)

    -- ── Copy hint ──────────────────────────────────────────
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", optRow, "BOTTOMLEFT", 2, -4)
    hint:SetText("Click 'Scan & Export', then 'Select All' (or Ctrl+A) and Ctrl+C to copy.")

    charFS = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    charFS:SetPoint("TOPRIGHT", optRow, "BOTTOMRIGHT", -4, -4)
    charFS:SetJustifyH("RIGHT")
    charFS:SetText("0 chars")

    -- ── Output scroll + native EditBox ─────────────────────
    scrollFrame = CreateFrame("ScrollFrame", "$parentScroll", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -6)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 12)

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

    -- ── Resize grabber ─────────────────────────────────────
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
        end
    end)

    table.insert(UISpecialFrames, FRAME_NAME)
    ApplySavedGeometry(frame)
    UpdateDungeonBtnText()
    frame:Hide()
    return frame
end

-- ============================================================
-- Public API
-- ============================================================

local function OnShow()
    UpdateDungeonBtnText()
    if not GetMDT() then
        SetStatus("MDT not loaded — open/enable the MythicDungeonTools addon.", "FFFF6B6B")
    else
        SetStatus("Ready. Click 'Scan & Export'.")
    end
end

function TOOL.ShowMDTMobDataExport()
    local f = CreateFrameOnce()
    if not f:IsShown() then
        ApplySavedGeometry(f)
        f:Show()
        OnShow()
    end
end

function TOOL.HideMDTMobDataExport()
    if frame and frame:IsShown() then frame:Hide() end
end

function TOOL.ToggleMDTMobDataExport()
    local f = CreateFrameOnce()
    if f:IsShown() then
        f:Hide()
    else
        ApplySavedGeometry(f)
        f:Show()
        OnShow()
    end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("MDT Mob Data Export", TOOL.ToggleMDTMobDataExport)
end
