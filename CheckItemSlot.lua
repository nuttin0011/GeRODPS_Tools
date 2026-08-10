--[[
    CheckItemSlot.lua

    "Check Item Slot" — plain checklist grid. One row per equipment
    slot, 10 checkboxes per row. Display-only: no SavedVariables, no
    backing logic. State lives in memory for the session (survives
    Hide/Show, reset on /reload) since the frame is built once and
    reused, matching the other tools' frame-reuse pattern.

    Trigger: Minimap (GeRODPS Tools) → "Check Item Slot"
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

-- ============================================================
-- Constants
-- ============================================================

local SLOT_NAMES = {
    "Head", "Neck", "Shoulder", "Chest", "Back", "Wrist", "Hand", "Waist",
    "Leg", "Foot", "Ring1", "Ring2", "Trinket1", "Trinket2", "MH", "OH",
}
local NUM_COLS = 10

local LABEL_W    = 74
local COL_W      = 26
local CHECK_SIZE = 20
local ROW_H      = 24
local HEADER_H   = 22
local SIDE_PAD   = 14
local TOP_PAD    = 34

local FRAME_W = SIDE_PAD * 2 + LABEL_W + NUM_COLS * COL_W + 20
local FRAME_H = TOP_PAD + HEADER_H + #SLOT_NAMES * ROW_H + 14

-- ============================================================
-- Module state
-- ============================================================

local toolFrame

-- ============================================================
-- Frame build
-- ============================================================

local function CreateSlotRow(parent, slotName, y)
    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    row:SetSize(FRAME_W - SIDE_PAD * 2, ROW_H)

    local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    nameFS:SetPoint("LEFT", row, "LEFT", 0, 0)
    nameFS:SetWidth(LABEL_W)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetText(slotName)

    for c = 1, NUM_COLS do
        local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
        cb:SetSize(CHECK_SIZE, CHECK_SIZE)
        cb:SetPoint("LEFT", row, "LEFT", LABEL_W + (c - 1) * COL_W, 0)
    end

    return row
end

local function BuildFrame()
    if toolFrame then return end

    toolFrame = CreateFrame("Frame", "GeRODPS_Tools_CheckItemSlotFrame",
        UIParent, "BasicFrameTemplateWithInset")
    toolFrame:SetSize(FRAME_W, FRAME_H)
    toolFrame:SetPoint("CENTER")
    toolFrame:SetMovable(true)
    toolFrame:EnableMouse(true)
    toolFrame:RegisterForDrag("LeftButton")
    toolFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    toolFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    toolFrame:SetClampedToScreen(true)
    toolFrame:SetFrameStrata("DIALOG")
    if toolFrame.TitleText then
        toolFrame.TitleText:SetText("GeRODPS Tools — Check Item Slot")
    end

    local inset = toolFrame.Inset or toolFrame

    -- Column header: 1..10 above the checkbox columns
    for c = 1, NUM_COLS do
        local hdr = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hdr:SetPoint("TOPLEFT", inset, "TOPLEFT",
            SIDE_PAD + LABEL_W + (c - 1) * COL_W, -TOP_PAD + HEADER_H)
        hdr:SetWidth(COL_W)
        hdr:SetJustifyH("CENTER")
        hdr:SetText("|cFFFFCC00" .. c .. "|r")
    end

    local y = -(TOP_PAD + HEADER_H)
    for _, slotName in ipairs(SLOT_NAMES) do
        local row = CreateSlotRow(inset, slotName, y)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", inset, "TOPLEFT", SIDE_PAD, y)
        y = y - ROW_H
    end

    tinsert(UISpecialFrames, "GeRODPS_Tools_CheckItemSlotFrame")
    toolFrame:Hide()
end

-- ============================================================
-- Toggle entry
-- ============================================================

local function Toggle()
    BuildFrame()
    if not toolFrame then return end
    if toolFrame:IsShown() then
        toolFrame:Hide()
    else
        toolFrame:Show()
    end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("Check Item Slot", Toggle)
end
