--[[
    Core.lua

    Top-level addon entry. Sets up SavedVariables and the minimap
    button "GeRODPS Tools" via LibDBIcon. Left-click on the button
    opens a drop-down menu listing every registered tool. Each tool
    owns an open / toggle function the menu calls. Additional tools
    register via GeRODPS_Tools.RegisterTool(label, fn) at file load.
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

-- ============================================================
-- Tool registry — populated by each tool file at load time.
-- Order is preserved (registration order = display order in the menu).
-- ============================================================
TOOL._tools = TOOL._tools or {}

function TOOL.RegisterTool(label, fn)
    if type(label) ~= "string" or label == "" then return end
    if type(fn) ~= "function" then return end
    -- Replace if a tool with the same label re-registers (after /reload).
    for i, t in ipairs(TOOL._tools) do
        if t.label == label then
            TOOL._tools[i] = { label = label, fn = fn }
            return
        end
    end
    TOOL._tools[#TOOL._tools + 1] = { label = label, fn = fn }
end

-- Register a SUBMENU entry: label + array of { label, fn } sub-items.
-- Rendered as a nested fly-out in the minimap menu.
function TOOL.RegisterSubmenu(label, items)
    if type(label) ~= "string" or label == "" then return end
    if type(items) ~= "table" then return end
    for i, t in ipairs(TOOL._tools) do
        if t.label == label then
            TOOL._tools[i] = { label = label, submenu = items }
            return
        end
    end
    TOOL._tools[#TOOL._tools + 1] = { label = label, submenu = items }
end

-- ============================================================
-- Drop-down menu shown on minimap left-click
-- ============================================================
-- WoW 11.0 retired UIDropDownMenu / EasyMenu in favour of MenuUtil.
-- 12.0 ships only the new system, so EasyMenu is nil. We use
-- MenuUtil.CreateContextMenu and fall back to the legacy
-- UIDropDownMenu_Initialize + ToggleDropDownMenu pair for safety on
-- any client where MenuUtil isn't available.

local legacyAnchor   -- hidden frame for the legacy UIDropDownMenu fallback

local function ShowToolMenu()
    -- Modern path (TWW 11.0+ / WoW 12.0)
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(UIParent, function(_owner, rootDescription)
            if #TOOL._tools == 0 then
                rootDescription:CreateTitle("(no tools registered)")
                return
            end
            for _, t in ipairs(TOOL._tools) do
                if t.submenu then
                    local parent = rootDescription:CreateButton(t.label)
                    for _, s in ipairs(t.submenu) do
                        local sfn = s.fn
                        parent:CreateButton(s.label, function() if sfn then sfn() end end)
                    end
                else
                    local fn = t.fn
                    rootDescription:CreateButton(t.label, function() if fn then fn() end end)
                end
            end
        end)
        return
    end

    -- Legacy path (pre-11.0)
    if not legacyAnchor then
        legacyAnchor = CreateFrame(
            "Frame", "GeRODPS_Tools_MenuAnchor", UIParent,
            UIDropDownMenuTemplate and "UIDropDownMenuTemplate" or nil)
    end
    if EasyMenu then
        local menuList = {}
        if #TOOL._tools == 0 then
            menuList[#menuList + 1] = {
                text = "(no tools registered)",
                isTitle = true, notCheckable = true,
            }
        else
            for _, t in ipairs(TOOL._tools) do
                if t.submenu then
                    local sub = {}
                    for _, s in ipairs(t.submenu) do
                        sub[#sub + 1] = { text = s.label, notCheckable = true, func = s.fn }
                    end
                    menuList[#menuList + 1] = {
                        text = t.label, notCheckable = true, hasArrow = true, menuList = sub,
                    }
                else
                    menuList[#menuList + 1] = {
                        text = t.label, notCheckable = true, func = t.fn,
                    }
                end
            end
        end
        EasyMenu(menuList, legacyAnchor, "cursor", 0, 0, "MENU")
        return
    end

    DEFAULT_CHAT_FRAME:AddMessage(
        "|cffff4444[GeRODPS_Tools]|r Neither MenuUtil nor EasyMenu " ..
        "available — cannot open tool menu.")
end

-- ============================================================
-- SavedVariables + LibDBIcon registration on PLAYER_LOGIN
-- ============================================================

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, event)
    if event ~= "PLAYER_LOGIN" then return end

    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    GeRODPS_ToolsDB.minimap = GeRODPS_ToolsDB.minimap or { hide = false }

    local LDB     = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
    local LDBIcon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)
    if not LDB or not LDBIcon then
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cffff4444[GeRODPS_Tools]|r LibDataBroker / LibDBIcon missing — " ..
            "minimap button disabled.")
        return
    end

    local dataObj = LDB:NewDataObject("GeRODPS_Tools", {
        type  = "launcher",
        text  = "GeRODPS Tools",
        icon  = "Interface/Icons/inv_engineering_blueprint",
        OnClick = function(_, button)
            if button == "LeftButton" then
                ShowToolMenu()
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("|cffaaffaaGeRODPS Tools|r")
            tt:AddLine("|cffcccccc Left-click:|r open tool menu")
        end,
    })

    if not LDBIcon:IsRegistered("GeRODPS_Tools") then
        LDBIcon:Register("GeRODPS_Tools", dataObj, GeRODPS_ToolsDB.minimap)
    end
end)
