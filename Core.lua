--[[
    GeRODPS_Tools / Core.lua

    Sister addon to GeRODPS (declared via TOC `## Dependencies: GeRODPS`).
    Hosts development / inspection tools that we don't want polluting the
    main GeRODPS load order.

    Phase 1: a single Minimap button "GeRODPS Tools" that opens an
    empty Dump Var frame (native WoW UI, no AceGUI). Future tools will
    register via GeRODPS_Tools.RegisterTool(name, openFn) and surface
    in a dropdown, but for now left-click → toggles the Dump Var frame
    directly so the user can verify the empty-frame plumbing first.

    Reuses the LibDataBroker / LibDBIcon stubs that GeRODPS already
    loads (cheaper than re-vendoring; we're a hard dependency anyway).
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

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
                if TOOL.ToggleDumpVar then TOOL.ToggleDumpVar() end
            end
        end,
        OnTooltipShow = function(tt)
            tt:AddLine("|cffaaffaaGeRODPS Tools|r")
            tt:AddLine("|cffcccccc Left-click:|r toggle Dump Var")
        end,
    })

    if not LDBIcon:IsRegistered("GeRODPS_Tools") then
        LDBIcon:Register("GeRODPS_Tools", dataObj, GeRODPS_ToolsDB.minimap)
    end
end)
