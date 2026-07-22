--[[
    KeyBindTimingTest.lua

    RESULTS PAGE for the "when is a keybind live?" study (2026-07-22), run to explain why
    the Rotation Studio auto-reload key sometimes missed its 2nd press.

    The live test (Ctrl+Alt+1..6 each bound at a different moment — file load, PLAYER_LOGIN,
    PLAYER_ENTERING_WORLD, C_Timer.After(0/0.1/0.5) — with both a Lua-callback macro and a
    plain macro-text body) has been RETIRED. Every variant fired on the first press.

    Conclusion: a TEMPORARY override binding (SetOverrideBindingClick) is live immediately
    no matter where the CreateFrame + SetAttribute + bind run — the only requirement is being
    out of combat. The "delay 2s after login" rule is for PERMANENT bindings, not this.

    This file no longer creates any secure button or binding; it just shows the findings.
    Open from the minimap: GeRODPS Tools -> KeyBind Timing Test.
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local TITLE_H  = 28     -- template title bar height — first row must clear it (Rule 10)
local SIDE_PAD = 18

-- { text, r, g, b } — ASCII only (WoW font, Rule 5)
local RESULT_LINES = {
    { "Study (2026-07-22): when does a keybind become live?",                  1.00, 0.82, 0.20 },
    { "Goal: explain why the Studio auto-reload key sometimes missed press #2.", 0.82, 0.82, 0.82 },
    { "", 1, 1, 1 },
    { "API:  SetOverrideBindingClick(owner, isPriority, key, buttonName [, mouseButton])", 0.65, 0.90, 1.00 },
    { "      Temporary override binding - cleared on /reload & logout, no taint.",         0.80, 0.80, 0.80 },
    { "      (NOT SetBinding + SaveBindings, which is the permanent kind.)",               0.80, 0.80, 0.80 },
    { "", 1, 1, 1 },
    { "RESULT: the bind is live immediately, no matter WHERE it is placed:",     0.55, 1.00, 0.55 },
    { "   [ok] file load (top-level)        [ok] PLAYER_LOGIN",                  0.75, 0.92, 0.75 },
    { "   [ok] PLAYER_ENTERING_WORLD        [ok] C_Timer.After(0 / 0.1 / 0.5)",  0.75, 0.92, 0.75 },
    { "", 1, 1, 1 },
    { "Works for BOTH button macro bodies:",                                    0.55, 1.00, 0.55 },
    { "   [ok] KeyBind callback:  /run GeRODPS_Tools.SomeFn(n)",                 0.75, 0.92, 0.75 },
    { "   [ok] plain macro text:  /run print(\"...\")   (and /reload)",          0.75, 0.92, 0.75 },
    { "", 1, 1, 1 },
    { "Only requirement: OUT OF COMBAT (InCombatLockdown blocks the bind).",     1.00, 0.81, 0.36 },
    { "No 2s login delay is needed for a TEMPORARY override binding - that",     0.82, 0.82, 0.82 },
    { "delay applies to PERMANENT SaveBindings / secure-env readiness only.",    0.82, 0.82, 0.82 },
    { "For safety vs future API changes, still prefer PLAYER_ENTERING_WORLD.",   0.82, 0.82, 0.82 },
    { "", 1, 1, 1 },
    { "So a missed auto-reload press is NOT a binding problem - it is a timing",  0.90, 0.75, 0.55 },
    { "problem (key sent during a loading screen / before WoW is focused).",      0.90, 0.75, 0.55 },
    { "", 1, 1, 1 },
    { "Live Ctrl+Alt+1..6 test buttons: RETIRED (this is a results page only).", 0.68, 0.68, 0.68 },
}

local viewer

local function BuildViewer()
    local f = CreateFrame("Frame", "GeRToolsKBTViewer", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(640, 400)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    if f.TitleText then f.TitleText:SetText("KeyBind Timing Test - Results") end

    local prev
    for _, line in ipairs(RESULT_LINES) do
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if prev then
            fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -4)
        else
            fs:SetPoint("TOPLEFT", f, "TOPLEFT", SIDE_PAD, -(TITLE_H + 12))
        end
        fs:SetJustifyH("LEFT")
        fs:SetText(line[1])
        fs:SetTextColor(line[2], line[3], line[4])
        prev = fs
    end
    return f
end

local function OpenViewer()
    if not viewer then viewer = BuildViewer() end
    viewer:Show()
end

TOOL.RegisterTool("KeyBind Timing Test", OpenViewer)
