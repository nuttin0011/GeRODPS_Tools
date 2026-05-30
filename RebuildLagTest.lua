--[[
    RebuildLagTest.lua  (Dev tool)

    Tests several rebuild strategies for AceGUI InlineGroup card lists to
    isolate the "1-frame flash" reported on Tab 2/4/5/6 popup edit.

    Hypothesis: card is added to scroll before its children → AceGUI lays
    out an undersized card → children get added → card resizes → visible
    flash of one frame.

    The tool seeds ~6 cards mimicking the size/complexity of real cond
    cards (heading + button row + dropdown + editbox + label) and lets
    user trigger rebuilds with different strategies. Click a button →
    rebuild fires → observe visual smoothness. Status bar shows the last
    strategy + elapsed ms.

    Strategies:
      A. Baseline plain    — ReleaseChildren + AddChild, no theme, no bars
      B. + Theme           — adds CardTheme.ApplyToInlineGroupForCurrentTabLighter
      C. + Theme + Bars    — adds level bars (full cond-row real setup)
      D. ScrollHide masking— scroll.frame:Hide() during build, Show via C_Timer
      E. AlphaFade masking — scroll.frame:SetAlpha(0) → build → C_Timer alpha=1
      F. PreSetHeight      — explicit card:SetHeight(140) before children added
      G. NoAutoHeight      — set card.noAutoHeight=true + manual SetHeight

    Auto-repeat: clicks the LAST strategy every 1 s — useful for
    visualizing the flash on a steady cadence.

    Public:
        GeRODPS_Tools.ToggleRebuildLagTest()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME = "GeRODPS_ToolsRebuildLagTestFrame"
local DEFAULT_W, DEFAULT_H = 720, 540
local NUM_CARDS = 6

-- Bar style constants matched to production (SkillCardShared.RenderLevelBars)
local BAR_W       = 10
local BAR_GAP     = 1
local BAR_INSET_L = 1
local BAR_INSET_TB = 1
local BAR_RGBA    = { 1, 0.82, 0, 0.55 }

local frame, scroll, statusText
local autoRepeat = false
local autoRepeatTimer
local lastStrategy = nil
local lastDuration = 0

-- ============================================================
-- Card content seed — simulates a real cond row's child set
-- ============================================================

local function HasAce()
    return LibStub and LibStub("AceGUI-3.0", true)
end

local function MakeCardContent(card, idx, levels)
    local AceGUI = LibStub("AceGUI-3.0")

    local heading = AceGUI:Create("Label")
    heading:SetText("|cffffcc00Condition " .. idx .. "|r  (test)")
    heading:SetFullWidth(true)
    card:AddChild(heading)

    local upBtn = AceGUI:Create("Button")
    upBtn:SetWidth(44); upBtn:SetText("^")
    card:AddChild(upBtn)

    local downBtn = AceGUI:Create("Button")
    downBtn:SetWidth(44); downBtn:SetText("v")
    card:AddChild(downBtn)

    local notCB = AceGUI:Create("CheckBox")
    notCB:SetLabel("NOT"); notCB:SetWidth(70)
    card:AddChild(notCB)

    local condDD = AceGUI:Create("Dropdown")
    condDD:SetLabel("Condition"); condDD:SetWidth(200)
    condDD:SetList({ a = "alpha", b = "beta", c = "gamma" }, { "a", "b", "c" })
    condDD:SetValue("a")
    card:AddChild(condDD)

    local delBtn = AceGUI:Create("Button")
    delBtn:SetWidth(80); delBtn:SetText("Delete")
    card:AddChild(delBtn)

    local cmpDD = AceGUI:Create("Dropdown")
    cmpDD:SetLabel("Compare"); cmpDD:SetWidth(100)
    cmpDD:SetList({ [">"] = ">", ["<"] = "<" }, { ">", "<" })
    cmpDD:SetValue(">")
    card:AddChild(cmpDD)

    local thEB = AceGUI:Create("EditBox")
    thEB:SetLabel("Value"); thEB:SetWidth(120)
    thEB:SetText(tostring(idx * 11))
    card:AddChild(thEB)

    local summary = AceGUI:Create("Label")
    summary:SetText("|cff88bbffCard #" .. idx .. " — levels=" .. levels .. "  (filler text to fill row)|r")
    summary:SetFullWidth(true)
    card:AddChild(summary)
end

-- ============================================================
-- Bar renderer (copy of production for parity with cond row look)
-- ============================================================

local function RenderBars(card, levels)
    if not card.content then return end
    local content = card.content
    local border = content:GetParent()
    if not border then return end
    border._barsTest = border._barsTest or {}

    for _, tex in ipairs(border._barsTest) do tex:Hide() end

    if levels > 0 then
        for i = 1, levels do
            local tex = border._barsTest[i]
            if not tex then
                tex = border:CreateTexture(nil, "OVERLAY")
                border._barsTest[i] = tex
            end
            local x = BAR_INSET_L + (i - 1) * (BAR_W + BAR_GAP)
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT",    border, "TOPLEFT",    x, -BAR_INSET_TB)
            tex:SetPoint("BOTTOMLEFT", border, "BOTTOMLEFT", x,  BAR_INSET_TB)
            tex:SetWidth(BAR_W)
            tex:SetColorTexture(BAR_RGBA[1], BAR_RGBA[2], BAR_RGBA[3], BAR_RGBA[4])
            tex:Show()
        end
        local barsWidth = levels * BAR_W + (levels - 1) * BAR_GAP + BAR_INSET_L + 4
        content:ClearAllPoints()
        content:SetPoint("TOPLEFT",     border, "TOPLEFT",     10 + barsWidth, -10)
        content:SetPoint("BOTTOMRIGHT", border, "BOTTOMRIGHT", -10,              10)
        if content.width and barsWidth > 0 then
            content.width = math.max(0, content.width - barsWidth)
        end
    end
end

-- ============================================================
-- Strategy implementations
-- ============================================================

local function ApplyTheme(card)
    if GeRODPS and GeRODPS.CardTheme
        and GeRODPS.CardTheme.ApplyToInlineGroupForCurrentTabLighter then
        GeRODPS.CardTheme.ApplyToInlineGroupForCurrentTabLighter(card, 0.09)
    end
end

-- Rebuild N cards into scroll with the chosen strategy. Returns elapsed ms.
local function Rebuild(strategy)
    if not (scroll and HasAce()) then return 0 end
    local AceGUI = LibStub("AceGUI-3.0")
    local t0 = debugprofilestop and debugprofilestop() or 0

    -- Preserve scroll offset across rebuild (matches Tab2Body / SpellNameHelper
    -- pattern) so user's scroll position doesn't snap to 0 each click.
    local _st = scroll.status or scroll.localstatus
    local savedOffset = (_st and _st.offset) or 0

    if strategy == "D" then
        scroll.frame:Hide()
    elseif strategy == "E" then
        scroll.frame:SetAlpha(0)
    end

    scroll:ReleaseChildren()

    for idx = 1, NUM_CARDS do
        local levels = (idx % 4)   -- 0..3 cycling

        local card = AceGUI:Create("InlineGroup")
        card:SetTitle("Card " .. idx)
        card:SetFullWidth(true)
        card:SetLayout("Flow")

        if strategy == "F" then
            -- Pre-set height to typical final height before AddChild loop.
            -- AceGUI's LayoutFinished still fires and may overwrite — set
            -- AFTER scroll:AddChild so OnHeightSet propagates.
            scroll:AddChild(card)
            card:SetHeight(140)
        elseif strategy == "G" then
            -- noAutoHeight disables AceGUI's auto-resize in LayoutFinished
            scroll:AddChild(card)
            card.noAutoHeight = true
            card:SetHeight(140)
        else
            scroll:AddChild(card)
        end

        if strategy == "B" or strategy == "C"
            or strategy == "D" or strategy == "E"
            or strategy == "F" or strategy == "G" then
            ApplyTheme(card)
        end

        if strategy == "C" or strategy == "D" or strategy == "E"
            or strategy == "F" or strategy == "G" then
            RenderBars(card, levels)
        end

        MakeCardContent(card, idx, levels)
    end

    if strategy == "D" then
        C_Timer.After(0, function()
            if scroll and scroll.frame then scroll.frame:Show() end
        end)
    elseif strategy == "E" then
        C_Timer.After(0, function()
            if scroll and scroll.frame then scroll.frame:SetAlpha(1) end
        end)
    end

    -- SYNC scroll offset restore (same frame as the AddChild loop).
    -- Previously deferred via C_Timer.After(0, ...) — but that puts the
    -- offset snap on FRAME N+1 after content already painted at offset=0
    -- on FRAME N. The 1-frame snap is the user-visible flicker.
    -- Sync restore means painter only sees the FINAL state once.
    local st = scroll.status or scroll.localstatus
    if st then st.offset = savedOffset end
    if scroll.FixScroll then scroll:FixScroll() end

    local t1 = debugprofilestop and debugprofilestop() or 0
    return t1 - t0
end

local STRATEGY_LABELS = {
    A = "A. Baseline plain (no theme, no bars)",
    B = "B. + Theme",
    C = "C. + Theme + Bars (real cond row)",
    D = "D. Theme + Bars + ScrollHide mask",
    E = "E. Theme + Bars + AlphaFade mask",
    F = "F. Theme + Bars + PreSetHeight(140)",
    G = "G. Theme + Bars + NoAutoHeight + SetHeight",
}

local function DoStrategy(key)
    lastStrategy = key
    lastDuration = Rebuild(key)
    if statusText then
        statusText:SetText(string.format(
            "Last: |cffffd200%s|r   %.2f ms",
            STRATEGY_LABELS[key] or key, lastDuration))
    end
end

-- ============================================================
-- Auto-repeat
-- ============================================================

local function StartAutoRepeat()
    if autoRepeatTimer then return end
    autoRepeatTimer = C_Timer.NewTicker(1.0, function()
        if not autoRepeat then return end
        if lastStrategy then DoStrategy(lastStrategy) end
    end)
end

local function StopAutoRepeat()
    if autoRepeatTimer then
        autoRepeatTimer:Cancel()
        autoRepeatTimer = nil
    end
end

-- ============================================================
-- Build frame
-- ============================================================

local function BuildFrame()
    if frame then return end
    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(DEFAULT_W, DEFAULT_H)
    frame:SetPoint("CENTER")
    frame:SetMovable(true); frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop",  frame.StopMovingOrSizing)
    frame:SetResizable(true)
    if frame.SetResizeBounds then frame:SetResizeBounds(560, 380, 1400, 900) end
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("HIGH")
    frame.TitleText:SetText("Rebuild Lag Test (Dev)")

    local inset = frame.Inset or frame
    local TOP_OFF = frame.Inset and 0 or -42

    -- Status bar
    statusText = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    statusText:SetPoint("TOPLEFT", inset, "TOPLEFT", 10, -8 + TOP_OFF)
    statusText:SetText("(click a strategy button to rebuild)")

    -- Strategy buttons row
    local btnSpecs = {
        { key="A", x=10  }, { key="B", x=90  }, { key="C", x=170 },
        { key="D", x=250 }, { key="E", x=330 }, { key="F", x=410 }, { key="G", x=490 },
    }
    for _, spec in ipairs(btnSpecs) do
        local b = CreateFrame("Button", nil, inset, "UIPanelButtonTemplate")
        b:SetSize(74, 22)
        b:SetPoint("TOPLEFT", inset, "TOPLEFT", spec.x, -30 + TOP_OFF)
        b:SetText("[" .. spec.key .. "]")
        b:SetScript("OnClick", function() DoStrategy(spec.key) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(STRATEGY_LABELS[spec.key] or spec.key, 1, 0.82, 0)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- Auto-repeat toggle
    local autoBtn = CreateFrame("CheckButton", nil, inset, "UICheckButtonTemplate")
    autoBtn:SetSize(20, 20)
    autoBtn:SetPoint("TOPLEFT", inset, "TOPLEFT", 580, -28 + TOP_OFF)
    local autoLbl = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoLbl:SetPoint("LEFT", autoBtn, "RIGHT", 2, 0)
    autoLbl:SetText("Auto repeat 1/s")
    autoBtn:SetScript("OnClick", function(self)
        autoRepeat = self:GetChecked()
        if autoRepeat then StartAutoRepeat() else StopAutoRepeat() end
    end)

    -- Scroll container (raw WoW scroll holding an AceGUI ScrollFrame)
    if HasAce() then
        local AceGUI = LibStub("AceGUI-3.0")
        local container = AceGUI:Create("SimpleGroup")
        container:SetLayout("Fill")
        container.frame:SetParent(inset)
        container.frame:SetPoint("TOPLEFT",     inset, "TOPLEFT",     10, -60 + TOP_OFF)
        container.frame:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -10, 10)
        container.frame:Show()
        scroll = AceGUI:Create("ScrollFrame")
        scroll:SetLayout("Flow")
        container:AddChild(scroll)
    else
        local err = inset:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        err:SetPoint("TOPLEFT", inset, "TOPLEFT", 10, -60 + TOP_OFF)
        err:SetText("|cffff4444AceGUI not loaded — enable GeRODPS addon then /reload|r")
    end
end

-- ============================================================
-- Public toggle
-- ============================================================

function TOOL.ShowRebuildLagTest()
    BuildFrame()
    frame:Show()
    -- Seed an initial baseline rebuild so user sees something
    if scroll then DoStrategy("A") end
end

function TOOL.HideRebuildLagTest()
    autoRepeat = false
    StopAutoRepeat()
    if frame then frame:Hide() end
end

function TOOL.ToggleRebuildLagTest()
    if frame and frame:IsShown() then
        TOOL.HideRebuildLagTest()
    else
        TOOL.ShowRebuildLagTest()
    end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("Rebuild Lag Test (Dev)", TOOL.ToggleRebuildLagTest)
end
