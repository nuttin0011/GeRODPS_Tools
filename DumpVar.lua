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

-- See AuraListHelper.lua for the full rationale; same 100 px margin
-- applied on every restore.
local SCREEN_MARGIN = 100

local function ApplySavedGeometry(self)
    local db = GetDB()
    local screenW = UIParent:GetWidth()
    local screenH = UIParent:GetHeight()

    local w = db.w or DEFAULT_W
    local h = db.h or DEFAULT_H
    local maxW = screenW - 2 * SCREEN_MARGIN
    local maxH = screenH - 2 * SCREEN_MARGIN
    if w > maxW then w = maxW end
    if h > maxH then h = maxH end
    if w < MIN_W then w = MIN_W end
    if h < MIN_H then h = MIN_H end

    self:ClearAllPoints()
    if db.point and db.relPoint and db.x and db.y then
        self:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    else
        self:SetPoint("CENTER")
    end
    self:SetSize(w, h)

    local left, right = self:GetLeft(), self:GetRight()
    local bottom, top = self:GetBottom(), self:GetTop()
    if left and right and bottom and top then
        local dx, dy = 0, 0
        if left < SCREEN_MARGIN then
            dx = SCREEN_MARGIN - left
        elseif right > (screenW - SCREEN_MARGIN) then
            dx = (screenW - SCREEN_MARGIN) - right
        end
        if bottom < SCREEN_MARGIN then
            dy = SCREEN_MARGIN - bottom
        elseif top > (screenH - SCREEN_MARGIN) then
            dy = (screenH - SCREEN_MARGIN) - top
        end
        if dx ~= 0 or dy ~= 0 then
            local point, relTo, relPoint, x, y = self:GetPoint(1)
            self:ClearAllPoints()
            self:SetPoint(point, relTo or UIParent, relPoint, x + dx, y + dy)
        end
    end
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
    -- Mark user-placed so the template's auto-anchor doesn't fight the
    -- resize handler on first click — see AuraListHelper.lua note.
    frame:SetUserPlaced(true)
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

    -- Title text (TitleBg/TitleText come from BasicFrameTemplateWithInset)
    if frame.TitleText then
        frame.TitleText:SetText("GeRODPS Tools — Dump Var (Secret Read)")
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

-- Register into the minimap drop-down menu (from Core.lua).
if TOOL.RegisterTool then
    TOOL.RegisterTool("Dump Var (Secret Read)", TOOL.ToggleDumpVar)
end
