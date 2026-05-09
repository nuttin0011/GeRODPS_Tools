--[[
    GeRODPS_Tools / Core.lua

    Sister addon to GeRODPS (declared via TOC `## Dependencies: GeRODPS`).
    Hosts development / inspection tools that we don't want polluting the
    main GeRODPS load order.

    Minimap button "GeRODPS Tools". Left-click opens a Blizzard
    UIDropDown menu listing every registered tool. Each tool owns an
    open / toggle function the menu calls. New tools register via
    GeRODPS_Tools.RegisterTool(label, fn).

    Reuses the LibDataBroker / LibDBIcon stubs that GeRODPS already
    loads (cheaper than re-vendoring; we're a hard dependency anyway).
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

-- ============================================================
-- Drop-down menu shown on minimap left-click
-- ============================================================

local menuAnchor   -- hidden frame used as the EasyMenu anchor (one per session)

local function ShowToolMenu()
    if not menuAnchor then
        menuAnchor = CreateFrame(
            "Frame", "GeRODPS_Tools_MenuAnchor", UIParent, "UIDropDownMenuTemplate")
    end

    local menuList = {}
    if #TOOL._tools == 0 then
        menuList[#menuList + 1] = {
            text         = "(no tools registered)",
            isTitle      = true,
            notCheckable = true,
        }
    else
        for _, t in ipairs(TOOL._tools) do
            menuList[#menuList + 1] = {
                text         = t.label,
                notCheckable = true,
                func         = t.fn,
            }
        end
    end

    EasyMenu(menuList, menuAnchor, "cursor", 0, 0, "MENU")
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
