--[[
    GeRODPS_Tools / WatchVar.lua

    "Watch Var" — 4 realtime expression watchers in a separate frame.
    User types a Lua expression (anything that follows `return ...`) into
    one of 4 input boxes; the result is re-evaluated every TICK_INTERVAL
    seconds and shown in the output box below.

    Native WoW UI (no AceGUI). Output box = read-only-feeling EditBox
    inside a ScrollFrame (drag-select + Ctrl+C copy still works).

    Secret values are surfaced via `"<secret>" .. tostring(v)` — Lua's
    `..` concatenation routes through tostring, which WoW's secret
    guard ALLOWS (only comparison / arithmetic on the underlying value
    are blocked). Wrapped in pcall as a safety net.

    Resize logic redistributes vertical space among the 4 output boxes
    based on each box's text length: boxes with more content get more
    lines; boxes whose content fits in MIN_LINES stay compact. Pool of
    extra lines = floor((frameH - BASELINE) / LINE_HEIGHT).

    Public:
        GeRODPS_Tools.ToggleWatchVar()
        GeRODPS_Tools.ShowWatchVar()
        GeRODPS_Tools.HideWatchVar()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME    = "GeRODPS_ToolsWatchVarFrame"
local NUM_WATCHES   = 4
local TICK_INTERVAL = 0.1

local DEFAULT_W, DEFAULT_H = 720, 560
local MIN_W,     MIN_H     = 480, 380
local MAX_W,     MAX_H     = 1600, 1200

-- Layout constants for resize math.
local LINE_HEIGHT      = 14    -- approx pixel height of one line in ChatFontNormal
local MIN_OUTPUT_LINES = 6     -- minimum visible lines per output box
local FIXED_PER_SECTION = 14   -- label (12) + input (20) + 2 gaps (~6+6) ≈ 44.
                               -- That's the height OUTSIDE the output box;
                               -- captured separately as INPUT_BLOCK_H below.
local INPUT_BLOCK_H    = 14 + 22 + 6   -- label + input + gap before output

-- ============================================================
-- DB
-- ============================================================

local function GetDB()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    GeRODPS_ToolsDB.watchVar = GeRODPS_ToolsDB.watchVar or {}
    GeRODPS_ToolsDB.watchVar.exprs = GeRODPS_ToolsDB.watchVar.exprs or {}
    return GeRODPS_ToolsDB.watchVar
end

-- ============================================================
-- Secret + value formatting
-- ============================================================

local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

local function FormatSecret(v)
    -- "<secret>" .. tostring(v) — concat is allowed on secret values
    -- per WoW's secret guard. pcall as belt-and-braces.
    local ok, s = pcall(function() return "<secret>" .. tostring(v) end)
    return ok and s or "<secret>"
end

local function VarToText(v)
    if IsSecret(v) then return FormatSecret(v) end
    local t = type(v)
    if     t == "nil"      then return "nil"
    elseif t == "boolean"  then return v and "true" or "false"
    elseif t == "number"   then return tostring(v)
    elseif t == "string"   then return '"' .. v .. '"'
    elseif t == "table"    then return "[table]"
    elseif t == "function" then return "<function>"
    elseif t == "thread"   then return "<thread>"
    elseif t == "userdata" then return "<userdata>"
    end
    return tostring(v)
end

local function TableToShallowText(tbl, maxItems)
    maxItems = maxItems or 15
    if IsSecret(tbl) then return FormatSecret(tbl) end
    if type(tbl) ~= "table" then return VarToText(tbl) end
    local total = 0
    for _ in pairs(tbl) do total = total + 1 end
    local sorted = {}
    for k, v in pairs(tbl) do sorted[#sorted + 1] = { k = k, v = v } end
    table.sort(sorted, function(a, b)
        return tostring(a.k):lower() < tostring(b.k):lower()
    end)
    local items = {}
    local count = 0
    for _, kv in ipairs(sorted) do
        count = count + 1
        if count > maxItems then
            items[#items + 1] = string.format("  ... (+%d more)", total - maxItems)
            break
        end
        local vstr
        if IsSecret(kv.v) then
            vstr = FormatSecret(kv.v)
        elseif type(kv.v) == "table" then
            local sub = 0
            if not IsSecret(kv.v) then
                for _ in pairs(kv.v) do sub = sub + 1 end
            end
            vstr = string.format("[table: %d items]", sub)
        else
            vstr = VarToText(kv.v)
        end
        items[#items + 1] = string.format("  [%s] = %s", tostring(kv.k), vstr)
    end
    return string.format("{table: %d items}\n%s", total, table.concat(items, "\n"))
end

local function VarToDisplayText(v)
    if IsSecret(v) then return FormatSecret(v) end
    if type(v) == "table" then return TableToShallowText(v) end
    return VarToText(v)
end

local function MultiReturnToText(results, n)
    if n == 0 then return "(no return value)" end
    if n == 1 then return VarToDisplayText(results[1]) end
    local lines = {}
    for i = 1, n do
        local v = results[i]
        local vstr
        if IsSecret(v) then
            vstr = FormatSecret(v)
        elseif type(v) == "table" then
            vstr = TableToShallowText(v, 10)
        else
            vstr = VarToText(v)
        end
        lines[#lines + 1] = string.format("[%d] = %s", i, vstr)
    end
    return table.concat(lines, "\n")
end

-- ============================================================
-- State
-- ============================================================

local frame
local watches = {}    -- [i] = { section, input, output, scroll, expr }
local tickFrame
local tickAccum = 0

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
    self:ClearAllPoints()
    if db.point and db.relPoint and db.x and db.y then
        self:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    else
        self:SetPoint("CENTER")
    end
    self:SetSize(db.w or DEFAULT_W, db.h or DEFAULT_H)
end

-- ============================================================
-- Resize: redistribute output box heights
-- ============================================================

local function CountTextLines(text)
    if not text or text == "" then return 1 end
    local n = 1
    for _ in text:gmatch("\n") do n = n + 1 end
    return n
end

local function LayoutSections()
    if not frame then return end
    local content = frame.Inset or frame
    local availW = content:GetWidth() - 16
    local availH = content:GetHeight() - 12

    -- Each section consumes INPUT_BLOCK_H plus its dynamic output area.
    -- Gap between sections = 6.
    local sectionGap = 6
    local fixedPerSection = INPUT_BLOCK_H
    local totalFixed = NUM_WATCHES * fixedPerSection + (NUM_WATCHES - 1) * sectionGap
    local outputPool = math.max(NUM_WATCHES * MIN_OUTPUT_LINES * LINE_HEIGHT,
        availH - totalFixed)

    -- Compute per-box "needs" (lines of text, clamped to a sane upper bound
    -- so a runaway output doesn't starve the others).
    local NEED_CAP = 60
    local needs = {}
    local totalNeed = 0
    for i, w in ipairs(watches) do
        local lines = CountTextLines(w.output and w.output:GetText() or "")
        if lines < MIN_OUTPUT_LINES then lines = MIN_OUTPUT_LINES end
        if lines > NEED_CAP        then lines = NEED_CAP        end
        needs[i] = lines
        totalNeed = totalNeed + lines
    end

    -- Distribute pool proportionally to need; never below MIN_OUTPUT_LINES.
    local poolLines = math.floor(outputPool / LINE_HEIGHT)
    local heights = {}
    if totalNeed <= poolLines then
        -- Every box fits — give each its exact need, idle space goes to the
        -- last box so the layout fully fills the frame.
        local used = 0
        for i = 1, NUM_WATCHES do
            heights[i] = needs[i] * LINE_HEIGHT
            used = used + heights[i]
        end
        if used < outputPool then
            heights[NUM_WATCHES] = heights[NUM_WATCHES] + (outputPool - used)
        end
    else
        -- Proportional shrink — every box still gets MIN_OUTPUT_LINES first,
        -- then the remaining pool is split by need above min.
        local minLines = MIN_OUTPUT_LINES * NUM_WATCHES
        local extraPool = poolLines - minLines
        local extraNeedTotal = 0
        local extraNeeds = {}
        for i = 1, NUM_WATCHES do
            local extra = math.max(0, needs[i] - MIN_OUTPUT_LINES)
            extraNeeds[i] = extra
            extraNeedTotal = extraNeedTotal + extra
        end
        for i = 1, NUM_WATCHES do
            local extra = (extraNeedTotal > 0)
                and math.floor(extraPool * (extraNeeds[i] / extraNeedTotal))
                or 0
            heights[i] = (MIN_OUTPUT_LINES + extra) * LINE_HEIGHT
        end
    end

    -- Apply per-section anchors and sizes.
    local y = -6
    for i, w in ipairs(watches) do
        local sectionH = fixedPerSection + heights[i]
        w.section:ClearAllPoints()
        w.section:SetPoint("TOPLEFT", content, "TOPLEFT", 8, y)
        w.section:SetSize(availW, sectionH)
        y = y - sectionH - sectionGap
    end
end

-- ============================================================
-- Tick: re-evaluate every input expression
-- ============================================================

local function EvalAndDisplay(w)
    local expr = w.expr or ""
    if expr == "" then
        if w.output then w.output:SetText("") end
        return
    end
    local fn, parseErr = loadstring("return " .. expr)
    if not fn then
        w.output:SetText("|cffff8888parse error:|r " .. tostring(parseErr or ""))
        return
    end
    local packed = { pcall(fn) }
    local ok = packed[1]
    if not ok then
        w.output:SetText("|cffff8888error:|r " .. tostring(packed[2] or ""))
        return
    end
    local n = #packed - 1
    local results = {}
    for ri = 2, #packed do results[ri - 1] = packed[ri] end
    -- pcall the formatter too — secret-aware paths can still raise on
    -- exotic inputs. Falling back to "<error>" prevents the watch from
    -- silently freezing.
    local okFmt, display = pcall(MultiReturnToText, results, n)
    w.output:SetText(okFmt and display or "<format error>")
end

local function Tick(_, dt)
    if not frame or not frame:IsShown() then return end
    tickAccum = tickAccum + dt
    if tickAccum < TICK_INTERVAL then return end
    tickAccum = 0
    for _, w in ipairs(watches) do
        EvalAndDisplay(w)
    end
    LayoutSections()  -- text grew/shrunk → redistribute heights
end

local function EnsureTicker()
    if tickFrame then return end
    tickFrame = CreateFrame("Frame")
    tickFrame:SetScript("OnUpdate", Tick)
end

-- ============================================================
-- Build one watch section
-- ============================================================

local function CreateWatchSection(parent, idx)
    local section = CreateFrame("Frame", nil, parent)

    local lbl = section:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", section, "TOPLEFT", 0, 0)
    lbl:SetText("|cffaaffaaWatch " .. idx .. ":|r")

    local input = CreateFrame("EditBox", nil, section, "InputBoxTemplate")
    input:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 6, -2)
    input:SetPoint("RIGHT", section, "RIGHT", -8, 0)
    input:SetHeight(20)
    input:SetAutoFocus(false)
    input:SetFontObject("ChatFontNormal")
    input:SetMaxLetters(2048)

    local scroll = CreateFrame("ScrollFrame", nil, section, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", input, "BOTTOMLEFT", -6, -4)
    scroll:SetPoint("BOTTOMRIGHT", section, "BOTTOMRIGHT", -22, 4)

    -- Output: editable EditBox with multi-line so user can drag-select
    -- and Ctrl+C. We don't need true read-only — the tick loop overwrites
    -- text every TICK_INTERVAL anyway.
    local output = CreateFrame("EditBox", nil, scroll)
    output:SetMultiLine(true)
    output:SetAutoFocus(false)
    output:SetFontObject("ChatFontNormal")
    output:SetWidth(scroll:GetWidth())
    output:SetText("")
    output:SetScript("OnEscapePressed", output.ClearFocus)
    -- Resize content width with parent so word-wrap follows resize
    scroll:SetScript("OnSizeChanged", function(s, w)
        output:SetWidth(w)
    end)
    scroll:SetScrollChild(output)

    -- Mild background for the output area so it visually reads as a panel
    local bg = section:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", scroll, "TOPLEFT", -2, 2)
    bg:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 2, -2)
    bg:SetColorTexture(0, 0, 0, 0.45)

    local entry = {
        section = section, input = input, output = output, scroll = scroll,
        expr = "",
    }

    -- Input wiring: text changes update the expression; tick loop picks
    -- up the new value on the next interval. Enter just clears focus.
    input:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    input:SetScript("OnTextChanged", function(self)
        local txt = self:GetText() or ""
        entry.expr = txt
        local db = GetDB()
        db.exprs[idx] = txt
        if txt == "" then
            output:SetText("")
        end
    end)

    return entry
end

-- ============================================================
-- Frame builder
-- ============================================================

local function CreateWatchVarFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)

    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)

    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    else
        frame:SetMinResize(MIN_W, MIN_H)
        frame:SetMaxResize(MAX_W, MAX_H)
    end

    local resize = CreateFrame("Button", nil, frame)
    resize:SetSize(16, 16)
    resize:SetPoint("BOTTOMRIGHT", -4, 4)
    resize:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    resize:SetPushedTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Down")
    resize:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    resize:SetScript("OnMouseUp",   function()
        frame:StopMovingOrSizing()
        SaveSize(frame)
        LayoutSections()
    end)

    if frame.TitleText then
        frame.TitleText:SetText("GeRODPS Tools — Watch Var")
    end

    -- Build 4 sections
    local content = frame.Inset or frame
    for i = 1, NUM_WATCHES do
        watches[i] = CreateWatchSection(content, i)
    end

    -- Restore saved expressions
    local db = GetDB()
    for i = 1, NUM_WATCHES do
        local saved = db.exprs and db.exprs[i] or ""
        watches[i].expr = saved
        watches[i].input:SetText(saved)
    end

    -- Re-layout on resize
    frame:SetScript("OnSizeChanged", LayoutSections)

    table.insert(UISpecialFrames, FRAME_NAME)
    ApplySavedGeometry(frame)
    LayoutSections()
    frame:Hide()
    return frame
end

-- ============================================================
-- Public API
-- ============================================================

function TOOL.ShowWatchVar()
    local f = CreateWatchVarFrame()
    EnsureTicker()
    if not f:IsShown() then f:Show() end
end

function TOOL.HideWatchVar()
    if frame and frame:IsShown() then frame:Hide() end
end

function TOOL.ToggleWatchVar()
    local f = CreateWatchVarFrame()
    EnsureTicker()
    if f:IsShown() then f:Hide() else f:Show() end
end

-- Register into the minimap menu (Core.lua provides RegisterTool).
if TOOL.RegisterTool then
    TOOL.RegisterTool("Watch Var (Realtime ×4)", TOOL.ToggleWatchVar)
end
