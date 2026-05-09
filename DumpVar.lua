--[[
    GeRODPS_Tools / DumpVar.lua

    WoW-native UI rewrite of the AceGUI Dump Var tool. Phase 1 ships
    only the empty frame skeleton — title bar, close button, drag,
    resize, persisted size/position — so the user can verify the
    chrome behaves correctly before any content (input box / watch
    panel / tree) is wired in.

    Frame name: GeRODPS_ToolsDumpVarFrame (LoadAddOn-stable global).

    Public:
        GeRODPS_Tools.ToggleDumpVar()
        GeRODPS_Tools.ShowDumpVar()
        GeRODPS_Tools.HideDumpVar()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME = "GeRODPS_ToolsDumpVarFrame"

-- Lazily created on first toggle so the UI doesn't pay creation cost
-- until the user actually opens it.
local frame

local DEFAULT_W, DEFAULT_H = 720, 520
local MIN_W,     MIN_H     = 480, 320
local MAX_W,     MAX_H     = 1600, 1200

local function GetDB()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    GeRODPS_ToolsDB.dumpVar = GeRODPS_ToolsDB.dumpVar or {}
    return GeRODPS_ToolsDB.dumpVar
end

local function SavePosition(self)
    local db = GetDB()
    local point, _, relPoint, x, y = self:GetPoint(1)
    db.point    = point
    db.relPoint = relPoint
    db.x        = x
    db.y        = y
end

local function SaveSize(self)
    local db = GetDB()
    db.w = self:GetWidth()
    db.h = self:GetHeight()
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

local function CreateDumpVarFrame()
    if frame then return frame end

    -- BasicFrameTemplateWithInset gives us the WoW gold-trimmed border,
    -- title bar background, and a built-in close button. No taint risk
    -- since we never read protected state from this frame.
    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)

    -- Drag from the title bar (top ~22 px region of the template)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)

    -- Resize handle in the bottom-right corner
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    else
        -- Pre-10.0 fallback
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
    end)

    -- Title text (TitleBg/TitleText come from BasicFrameTemplateWithInset)
    if frame.TitleText then
        frame.TitleText:SetText("GeRODPS Tools — Dump Var")
    end

    -- Empty content area placeholder. Future phases will fill the
    -- frame.Inset region with input box, tree, and watch panels.
    local placeholder = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    placeholder:SetPoint("CENTER", frame.Inset or frame, "CENTER", 0, 0)
    placeholder:SetText("(empty — Phase 1 chrome only)")
    frame.placeholder = placeholder

    -- ESC closes (UISpecialFrames adds it to the global ESC list)
    table.insert(UISpecialFrames, FRAME_NAME)

    ApplySavedGeometry(frame)
    frame:Hide()
    return frame
end

function TOOL.ShowDumpVar()
    local f = CreateDumpVarFrame()
    if not f:IsShown() then f:Show() end
end

function TOOL.HideDumpVar()
    if frame and frame:IsShown() then frame:Hide() end
end

function TOOL.ToggleDumpVar()
    local f = CreateDumpVarFrame()
    if f:IsShown() then f:Hide() else f:Show() end
end
