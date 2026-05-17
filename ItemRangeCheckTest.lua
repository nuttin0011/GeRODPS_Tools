--[[
    ItemRangeCheckTest.lua

    Debug viewer that lists every itemID used by GeRODPS.RangeCheck and
    shows whether C_Item.IsItemInRange returns true/false/nil for each
    one against a chosen unit. Updated once a second.

    Layout (one row per range bucket):
        [Range yd] | Harm: <id1 id2 ...> | Friend: <id1 id2 ...>

    Colors per item:
        green  = in range (true)
        red    = out of range (false)
        gray   = nil / blocked / unit doesn't exist

    The user uses this to spot which items don't probe correctly so they
    can be pruned from the FriendItems / HarmItems tables in
    GeRODPS/RangeCheck.lua.

    Trigger: Minimap (GeRODPS Tools) → "Item Range Check Test"
]]

GeRODPS_Tools = GeRODPS_Tools or {}

-- ============================================================
-- Constants
-- ============================================================

local FRAME_W       = 720
local FRAME_H       = 780
local ROW_HEIGHT    = 22
local HEADER_HEIGHT = 56
local SIDE_PAD      = 14
local UPDATE_PERIOD = 1.0

local UNIT_CHOICES = {
    "target", "focus", "mouseover",
    "party1", "party2", "party3", "party4",
    "pet",
}

-- ============================================================
-- Module state
-- ============================================================

local toolFrame
local unitDropdown
local infoFS
local scrollFrame
local contentFrame
local rowPool         = {}   -- [bucket] = { rangeFS, harmFS, friendFS, container }
local rowOrder        = {}   -- ascending bucket list (cached)
local refreshElapsed  = 0
local currentUnit     = "target"

-- ============================================================
-- Color helpers
-- ============================================================

local COLOR_IN    = "|cFF55FF55"   -- green
local COLOR_OUT   = "|cFFFF5555"   -- red
local COLOR_NIL   = "|cFF888888"   -- gray
local COLOR_END   = "|r"

local function ColorForResult(res)
    if res == true  then return COLOR_IN  end
    if res == false then return COLOR_OUT end
    return COLOR_NIL
end

-- ============================================================
-- Build the row pool (one FontString triple per bucket)
-- ============================================================

local function BuildRows()
    local rc = GeRODPS and GeRODPS.RangeCheck
    if not (rc and rc.GetItemTables) then return end

    local friendItems, harmItems = rc.GetItemTables()

    -- Union of bucket keys, ascending
    local seen = {}
    rowOrder = {}
    for k in pairs(friendItems) do
        if not seen[k] then seen[k] = true; rowOrder[#rowOrder + 1] = k end
    end
    for k in pairs(harmItems) do
        if not seen[k] then seen[k] = true; rowOrder[#rowOrder + 1] = k end
    end
    table.sort(rowOrder)

    -- Tall enough content frame to fit every row
    local totalH = #rowOrder * ROW_HEIGHT + 6
    contentFrame:SetHeight(totalH)

    for i, bucket in ipairs(rowOrder) do
        local row = rowPool[bucket]
        if not row then
            local container = CreateFrame("Frame", nil, contentFrame)
            container:SetSize(FRAME_W - SIDE_PAD * 2 - 20, ROW_HEIGHT)
            container:SetPoint("TOPLEFT", contentFrame, "TOPLEFT",
                0, -(i - 1) * ROW_HEIGHT)

            local rangeFS = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            rangeFS:SetPoint("LEFT", container, "LEFT", 4, 0)
            rangeFS:SetJustifyH("LEFT")
            rangeFS:SetWidth(70)
            rangeFS:SetText(string.format("|cFFFFCC00%3d yd|r", bucket))

            local harmFS = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            harmFS:SetPoint("LEFT", rangeFS, "RIGHT", 6, 0)
            harmFS:SetJustifyH("LEFT")
            harmFS:SetWidth(290)
            harmFS:SetText("")

            local friendFS = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            friendFS:SetPoint("LEFT", harmFS, "RIGHT", 8, 0)
            friendFS:SetJustifyH("LEFT")
            friendFS:SetWidth(290)
            friendFS:SetText("")

            row = {
                container = container,
                rangeFS   = rangeFS,
                harmFS    = harmFS,
                friendFS  = friendFS,
            }
            rowPool[bucket] = row
        else
            row.container:ClearAllPoints()
            row.container:SetPoint("TOPLEFT", contentFrame, "TOPLEFT",
                0, -(i - 1) * ROW_HEIGHT)
            row.container:Show()
        end
    end
end

-- ============================================================
-- Refresh — re-probe every item against current unit
-- ============================================================

local function FormatItemList(itemIDs, unit, rc)
    if not itemIDs or #itemIDs == 0 then
        return COLOR_NIL .. "—" .. COLOR_END
    end
    local parts = {}
    for _, id in ipairs(itemIDs) do
        local res = rc.IsItemInRange(id, unit)
        parts[#parts + 1] = ColorForResult(res) .. id .. COLOR_END
    end
    return table.concat(parts, " ")
end

local function Refresh()
    local rc = GeRODPS and GeRODPS.RangeCheck
    if not (rc and rc.GetItemTables and rc.IsItemInRange) then
        if infoFS then
            infoFS:SetText("|cFFFF5555GeRODPS.RangeCheck not loaded.|r")
        end
        return
    end

    local friendItems, harmItems = rc.GetItemTables()
    local unit = currentUnit

    -- Header info: unit state
    local exists = UnitExists(unit)
    local hostility
    if not exists then
        hostility = "|cFF888888(no unit)|r"
    elseif UnitCanAttack("player", unit) then
        hostility = "|cFFFF8888hostile|r → Harm items active"
    else
        hostility = "|cFF88FF88friendly|r → Friend items active"
    end
    local name = exists and (UnitName(unit) or unit) or "—"
    infoFS:SetText(string.format(
        "Unit |cFFFFFF99%s|r  →  %s   |cFF888888(%s)|r",
        unit, hostility, name))

    -- Each row: probe per item
    for _, bucket in ipairs(rowOrder) do
        local row = rowPool[bucket]
        if row then
            row.harmFS:SetText(  FormatItemList(harmItems[bucket],  unit, rc))
            row.friendFS:SetText(FormatItemList(friendItems[bucket], unit, rc))
        end
    end
end

-- ============================================================
-- Frame build
-- ============================================================

local function BuildFrame()
    if toolFrame then return end

    toolFrame = CreateFrame("Frame", "GeRODPS_Tools_ItemRangeCheckFrame",
        UIParent, "BasicFrameTemplateWithInset")
    toolFrame:SetSize(FRAME_W, FRAME_H)
    toolFrame:SetPoint("CENTER")
    toolFrame:SetMovable(true)
    toolFrame:EnableMouse(true)
    toolFrame:RegisterForDrag("LeftButton")
    toolFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    toolFrame:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    toolFrame:SetClampedToScreen(true)
    toolFrame:SetFrameStrata("DIALOG")
    if toolFrame.TitleText then
        toolFrame.TitleText:SetText("GeRODPS Tools — Item Range Check")
    end

    local inset = toolFrame.Inset or toolFrame

    -- Unit dropdown (top-left)
    local unitLabel = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    unitLabel:SetPoint("TOPLEFT", inset, "TOPLEFT", SIDE_PAD, -8)
    unitLabel:SetText("Test unit:")

    unitDropdown = CreateFrame("DropdownButton", nil, inset,
        "WowStyle1DropdownTemplate")
    unitDropdown:SetPoint("LEFT", unitLabel, "RIGHT", 6, -2)
    unitDropdown:SetWidth(140)
    unitDropdown:SetDefaultText(currentUnit)
    unitDropdown:SetupMenu(function(_, rootDescription)
        for _, u in ipairs(UNIT_CHOICES) do
            rootDescription:CreateRadio(u,
                function() return currentUnit == u end,
                function()
                    currentUnit = u
                    unitDropdown:SetDefaultText(u)
                    refreshElapsed = UPDATE_PERIOD     -- force next tick
                    return MenuResponse.CloseAll
                end)
        end
    end)

    -- Info line (right of dropdown)
    infoFS = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    infoFS:SetPoint("LEFT", unitDropdown, "RIGHT", 12, 2)
    infoFS:SetJustifyH("LEFT")
    infoFS:SetText("")

    -- Column headers
    local hdrRange = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrRange:SetPoint("TOPLEFT", inset, "TOPLEFT", SIDE_PAD + 4, -HEADER_HEIGHT + 18)
    hdrRange:SetWidth(70)
    hdrRange:SetJustifyH("LEFT")
    hdrRange:SetText("|cFFFFCC00Range|r")

    local hdrHarm = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrHarm:SetPoint("LEFT", hdrRange, "RIGHT", 6, 0)
    hdrHarm:SetWidth(290)
    hdrHarm:SetJustifyH("LEFT")
    hdrHarm:SetText("|cFFFF8888Enemy (Harm)|r — item IDs")

    local hdrFriend = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrFriend:SetPoint("LEFT", hdrHarm, "RIGHT", 8, 0)
    hdrFriend:SetWidth(290)
    hdrFriend:SetJustifyH("LEFT")
    hdrFriend:SetText("|cFF88FF88Friend|r — item IDs")

    -- Scroll frame holding all rows
    scrollFrame = CreateFrame("ScrollFrame", nil, inset,
        "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     inset, "TOPLEFT",     SIDE_PAD, -HEADER_HEIGHT)
    scrollFrame:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -SIDE_PAD - 22, 8)

    contentFrame = CreateFrame("Frame", nil, scrollFrame)
    contentFrame:SetSize(FRAME_W - SIDE_PAD * 2 - 22, 1)   -- height adjusted in BuildRows
    scrollFrame:SetScrollChild(contentFrame)

    -- Legend (bottom)
    local legend = inset:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    legend:SetPoint("BOTTOMLEFT", inset, "BOTTOMLEFT", SIDE_PAD, -8)
    legend:SetText(
        COLOR_IN  .. "in range" .. COLOR_END .. "  " ..
        COLOR_OUT .. "out of range" .. COLOR_END .. "  " ..
        COLOR_NIL .. "nil/blocked" .. COLOR_END)

    -- Per-second refresh while shown
    toolFrame:SetScript("OnUpdate", function(_, elapsed)
        refreshElapsed = refreshElapsed + elapsed
        if refreshElapsed >= UPDATE_PERIOD then
            refreshElapsed = 0
            Refresh()
        end
    end)

    toolFrame:HookScript("OnShow", function()
        refreshElapsed = UPDATE_PERIOD   -- refresh immediately on open
    end)

    -- ESC to close
    tinsert(UISpecialFrames, "GeRODPS_Tools_ItemRangeCheckFrame")
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
        BuildRows()      -- rebuild every time it opens (catches reloads)
        toolFrame:Show()
        Refresh()        -- immediate first paint
    end
end

if GeRODPS_Tools and GeRODPS_Tools.RegisterTool then
    GeRODPS_Tools.RegisterTool("Item Range Check Test", Toggle)
end
