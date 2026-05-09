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

-- Layout constants — heights are user-driven via frame resize, not auto-
-- computed from text (we can't measure secret-tainted strings).
local LINE_HEIGHT   = 14                    -- approx 1 line of ChatFontNormal
local INPUT_BLOCK_H = 14 + 22 + 6           -- label + input + gap before output

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

-- Strict rule: ONLY `==nil` and `issecretvalue` allowed on secret values.
-- Even `..` / tostring / string.format silently propagate the secret
-- taint into the result string; FontString:SetText accepts tainted
-- strings but downstream operations (table.concat, truthiness) reject
-- them. Emit a non-tainted literal instead — never touch the value.
local function FormatSecret(_v)
    return "<secret>"
end

local function VarToText(v)
    if IsSecret(v) then return FormatSecret(v) end
    local t = type(v)
    if     t == "nil"      then return "nil"
    elseif t == "boolean"  then return tostring(v)
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
-- Layout: equal-split sections by user-controlled frame height
-- ============================================================
-- We can't measure text length / height because reading FontString
-- text or rendered metrics on a secret-tainted string would trip
-- WoW's secret guard. So heights are static — driven entirely by the
-- frame size the user has set. Resize the frame larger to see more
-- content per box; smaller to compact.

local function LayoutSections()
    if not frame then return end
    local content = frame.Inset or frame
    local availW = content:GetWidth() - 16
    local availH = content:GetHeight() - 12

    local sectionGap = 6
    local totalGap   = (NUM_WATCHES - 1) * sectionGap
    local sectionH   = math.floor((availH - totalGap) / NUM_WATCHES)
    if sectionH < INPUT_BLOCK_H + LINE_HEIGHT then
        sectionH = INPUT_BLOCK_H + LINE_HEIGHT
    end

    local y = -6
    for _, w in ipairs(watches) do
        w.section:ClearAllPoints()
        w.section:SetPoint("TOPLEFT", content, "TOPLEFT", 8, y)
        w.section:SetSize(availW, sectionH)
        y = y - sectionH - sectionGap
    end
end

-- ============================================================
-- Tick: re-evaluate every input expression
-- ============================================================

-- Convert a NON-secret value to a display string. Caller must
-- IsSecret-gate first; this helper bails to "<secret>" if v turns
-- out to be secret (defence-in-depth). Strict rule: only `==nil`
-- and IsSecret allowed before any other op on a possibly-secret v.
local function SafeToString(v)
    if v == nil then return "" end
    if IsSecret(v) then return "<secret>" end
    local ok, s = pcall(string.format, "%s", tostring(v))
    if ok then return s end
    return "<opaque>"
end

local function EvalAndDisplay(w)
    local expr = w.expr or ""
    if expr == "" then
        if w.SetOutput then w.SetOutput("") end
        return
    end
    local fn, parseErr = loadstring("return " .. expr)
    if not fn then
        w.SetOutput("|cffff8888parse error:|r " .. SafeToString(parseErr))
        return
    end
    local packed = { pcall(fn) }
    local ok = packed[1]   -- always a Lua boolean (not secret)
    if not ok then
        w.SetOutput("|cffff8888error:|r " .. SafeToString(packed[2]))
        return
    end
    local n = #packed - 1
    local results = {}
    for ri = 2, #packed do results[ri - 1] = packed[ri] end
    -- pcall the formatter too — secret-aware paths can still raise on
    -- exotic inputs. Explicit if/else on the boolean ok flag (NOT on the
    -- formatter's secret-bearing return) so we never short-circuit on a
    -- value that could itself be secret.
    local okFmt, display = pcall(MultiReturnToText, results, n)
    if okFmt then
        w.SetOutput(display)
    else
        w.SetOutput("|cffff8888format error:|r " .. SafeToString(display))
    end
end

local function Tick(_, dt)
    if not frame or not frame:IsShown() then return end
    tickAccum = tickAccum + dt
    if tickAccum < TICK_INTERVAL then return end
    tickAccum = 0
    for _, w in ipairs(watches) do
        EvalAndDisplay(w)
    end
    -- No layout call here — heights are user-controlled via frame
    -- resize, not text-driven.
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

    -- Output: read-only FontString inside a content Frame matching the
    -- ScrollFrame viewport size. We never measure GetStringHeight or
    -- GetText (would trip secret guard on tainted strings), so the
    -- content frame size = viewport size; long output is clipped at the
    -- bottom of the section. User resizes the parent frame larger to
    -- see more.
    local content = CreateFrame("Frame", nil, scroll)
    content:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
    local output = content:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
    output:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    output:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    output:SetJustifyH("LEFT")
    output:SetJustifyV("TOP")
    output:SetWordWrap(true)
    output:SetNonSpaceWrap(true)
    output:SetText("")
    scroll:SetScrollChild(content)
    content:SetSize(math.max(1, scroll:GetWidth()), math.max(1, scroll:GetHeight()))

    -- Sync content size to viewport whenever ScrollFrame resizes. No
    -- text-driven resizing — user controls heights via parent frame
    -- resize → LayoutSections → section size → ScrollFrame size → here.
    scroll:SetScript("OnSizeChanged", function(_, w, h)
        if w <= 0 or h <= 0 then return end
        content:SetSize(w, h)
    end)

    -- Mild background for the output area so it visually reads as a panel
    local bg = section:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", scroll, "TOPLEFT", -2, 2)
    bg:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 2, -2)
    bg:SetColorTexture(0, 0, 0, 0.45)

    local entry = {
        section = section, input = input, output = output,
        scroll = scroll, content = content,
        expr = "",
    }

    -- Helper: set output text. Pure SetText — no measurement of the
    -- result (would trip secret guard for tainted strings).
    function entry.SetOutput(text)
        output:SetText(text or "")
    end

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
            entry.SetOutput("")
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
