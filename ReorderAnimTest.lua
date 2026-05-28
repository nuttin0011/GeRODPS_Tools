--[[
    ReorderAnimTest.lua

    A/B test rig for GeRODPS.ReorderAnim engine.

    Side-by-side: AceGUI InlineGroup column (mirrors Tab2/3/6 production)
    vs raw CreateFrame column (control). Both columns drive the SAME
    GeRODPS.ReorderAnim.SwapCards / AddCard engine. If only the raw
    column animates, the AceGUI Flow layout is fighting our SetPoint
    mutations. If neither animates, the engine itself is broken. If
    both animate, integration in the real tabs has a different cause.

    Frame uses BasicFrameTemplateWithInset (no AceGUI dependency for the
    container) so this tool loads even if GeRODPS Ace3 hasn't loaded yet.
    The AceGUI cards inside ARE created via LibStub("AceGUI-3.0").

    Public:
        GeRODPS_Tools.ToggleReorderAnimTest()
        GeRODPS_Tools.ShowReorderAnimTest()
        GeRODPS_Tools.HideReorderAnimTest()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME = "GeRODPS_ToolsReorderAnimTestFrame"
local DEFAULT_W, DEFAULT_H = 760, 560
local MIN_W, MIN_H         = 600, 420
local CARD_COLORS = {
    { 0.85, 0.30, 0.30 },   -- red
    { 0.30, 0.60, 0.95 },   -- blue
    { 0.30, 0.85, 0.45 },   -- green
    { 0.95, 0.80, 0.25 },   -- yellow
    { 0.70, 0.45, 0.95 },   -- purple
    { 0.25, 0.85, 0.85 },   -- teal
    { 0.95, 0.55, 0.30 },   -- orange
}

local frame
local aceCards = {}     -- AceGUI side: array of { widget = AceGUIInlineGroup }
local rawCards = {}     -- Raw side: array of { frame = Frame, label = FontString }
local statusFS          -- status bar at top
local aceScroll         -- AceGUI ScrollFrame container
local rawScrollContent  -- Raw scroll inner frame
local _lastAceCardFrames = {}   -- mimics _lastCardFrames pattern from Tab2Body
local _lastRawCardFrames = {}

local nextCardNum = 1

local function ColorFor(i)
    return CARD_COLORS[((i - 1) % #CARD_COLORS) + 1]
end

local function HasEngine()
    return GeRODPS and GeRODPS.ReorderAnim
end

-- ============================================================
-- Status bar (refresh on a 100ms tick so user sees busy flag change live)
-- ============================================================
local function RefreshStatus()
    if not (frame and frame:IsShown() and statusFS) then return end
    if not HasEngine() then
        statusFS:SetText("|cffff4444GeRODPS.ReorderAnim NOT LOADED|r — enable GeRODPS addon, then /reload")
        return
    end
    local s = GeRODPS.ReorderAnim.GetDebugState and GeRODPS.ReorderAnim.GetDebugState() or {}
    statusFS:SetText(string.format(
        "engine: |cff%s%s|r   busy: |cff%s%s|r   tweens: |cffffff00%d|r   glow pool: %d   ace cards: %d   raw cards: %d",
        s.enabled and "44ff44" or "ff4444",
        s.enabled and "enabled" or "DISABLED (db.profile.reorderAnimEnabled = false)",
        s.busy and "ff8844" or "888888",
        tostring(s.busy),
        s.activeCount or 0,
        s.glowPoolN or 0,
        #aceCards, #rawCards))
end

-- ============================================================
-- AceGUI side (mirrors Tab2Body)
-- ============================================================
local function BuildAceCards()
    if not aceScroll then return end
    aceScroll:ReleaseChildren()
    _lastAceCardFrames = {}
    for idx, item in ipairs(aceCards) do
        if idx > 1 then
            local spacer = LibStub("AceGUI-3.0"):Create("Label")
            spacer:SetText(" "); spacer:SetFullWidth(true)
            aceScroll:AddChild(spacer)
        end

        local card = LibStub("AceGUI-3.0"):Create("InlineGroup")
        card:SetTitle("Card #" .. item.num)
        card:SetFullWidth(true)
        card:SetLayout("Flow")
        aceScroll:AddChild(card)
        _lastAceCardFrames[idx] = card.frame

        -- Color tag (texture on the InlineGroup frame for visibility)
        if not card.frame.colorTag then
            local tex = card.frame:CreateTexture(nil, "BACKGROUND")
            tex:SetPoint("LEFT", card.frame, "LEFT", 8, 0)
            tex:SetSize(14, 28)
            card.frame.colorTag = tex
        end
        local c = ColorFor(item.num)
        card.frame.colorTag:SetColorTexture(c[1], c[2], c[3], 1)

        local lbl = LibStub("AceGUI-3.0"):Create("Label")
        lbl:SetText(string.format("AceGUI Card #%d  (idx=%d)", item.num, idx))
        lbl:SetWidth(260)
        card:AddChild(lbl)

        local upBtn = LibStub("AceGUI-3.0"):Create("Button")
        upBtn:SetWidth(44); upBtn:SetText("^")
        upBtn:SetCallback("OnClick", function()
            if idx > 1 then
                local capturedIdx = idx
                GeRODPS.ReorderAnim.SwapCards(_lastAceCardFrames[capturedIdx], _lastAceCardFrames[capturedIdx - 1], {
                    idxA = capturedIdx - 1, idxB = capturedIdx,
                    refreshFrames = function() return _lastAceCardFrames end,
                }, function()
                    aceCards[capturedIdx], aceCards[capturedIdx - 1] = aceCards[capturedIdx - 1], aceCards[capturedIdx]
                    BuildAceCards()
                end)
            end
        end)
        card:AddChild(upBtn)

        local downBtn = LibStub("AceGUI-3.0"):Create("Button")
        downBtn:SetWidth(44); downBtn:SetText("v")
        downBtn:SetCallback("OnClick", function()
            if idx < #aceCards then
                local capturedIdx = idx
                GeRODPS.ReorderAnim.SwapCards(_lastAceCardFrames[capturedIdx], _lastAceCardFrames[capturedIdx + 1], {
                    idxA = capturedIdx, idxB = capturedIdx + 1,
                    refreshFrames = function() return _lastAceCardFrames end,
                }, function()
                    aceCards[capturedIdx], aceCards[capturedIdx + 1] = aceCards[capturedIdx + 1], aceCards[capturedIdx]
                    BuildAceCards()
                end)
            end
        end)
        card:AddChild(downBtn)

        local delBtn = LibStub("AceGUI-3.0"):Create("Button")
        delBtn:SetWidth(60); delBtn:SetText("Del")
        delBtn:SetCallback("OnClick", function()
            table.remove(aceCards, idx)
            BuildAceCards()
        end)
        card:AddChild(delBtn)
    end
end

local function AceAddCard()
    if not HasEngine() then return end
    nextCardNum = nextCardNum + 1
    table.insert(aceCards, { num = nextCardNum })
    BuildAceCards()
    local newIdx = #aceCards
    -- BUG-23: defer 1 frame so AceGUI layout finalizes
    C_Timer.After(0, function()
        local newFrame = _lastAceCardFrames[newIdx]
        if newFrame then GeRODPS.ReorderAnim.AddCard(newFrame) end
    end)
end

-- ============================================================
-- Raw side (control — no AceGUI, manual SetPoint chain)
-- ============================================================
local RAW_CARD_HEIGHT = 36
local RAW_CARD_GAP    = 6

local function LayoutRawCards()
    -- Manual stack layout: each card anchors TOPLEFT to scroll content TOPLEFT
    -- at y = -(idx-1)*(h+gap). This is INDEPENDENT anchoring (not chained).
    for idx, item in ipairs(rawCards) do
        local y = -((idx - 1) * (RAW_CARD_HEIGHT + RAW_CARD_GAP))
        item.frame:ClearAllPoints()
        item.frame:SetPoint("TOPLEFT", rawScrollContent, "TOPLEFT", 4, y)
        item.frame:SetPoint("RIGHT", rawScrollContent, "RIGHT", -4, 0)
        item.frame:SetHeight(RAW_CARD_HEIGHT)
        item.label:SetText(string.format("Raw Card #%d  (idx=%d)", item.num, idx))
        _lastRawCardFrames[idx] = item.frame
    end
    -- Resize content height for scroll
    if rawScrollContent then
        rawScrollContent:SetHeight(math.max(1, #rawCards * (RAW_CARD_HEIGHT + RAW_CARD_GAP) + 8))
    end
end

local function CreateRawCard(num)
    local f = CreateFrame("Frame", nil, rawScrollContent, "BackdropTemplate")
    f:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left=3, right=3, top=3, bottom=3 },
    })
    local c = ColorFor(num)
    f:SetBackdropColor(c[1] * 0.4, c[2] * 0.4, c[3] * 0.4, 1)
    f:SetBackdropBorderColor(c[1], c[2], c[3], 1)

    local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lbl:SetPoint("LEFT", 12, 0)
    lbl:SetText("Raw Card #" .. num)

    local function MkBtn(text, x, onClick)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(38, 22); b:SetText(text)
        b:SetPoint("RIGHT", x, 0)
        b:SetScript("OnClick", onClick)
        return b
    end

    -- We attach callbacks after the card is added to rawCards (closure needs item.num)
    return { frame = f, label = lbl, num = num, mkBtn = MkBtn }
end

local function WireRawCardButtons(idx)
    local item = rawCards[idx]
    if not item then return end
    -- Clear any old buttons (so we can re-wire with fresh idx closures)
    if item.upBtn   then item.upBtn:Hide();   item.upBtn:SetParent(nil); item.upBtn = nil   end
    if item.downBtn then item.downBtn:Hide(); item.downBtn:SetParent(nil); item.downBtn = nil end
    if item.delBtn  then item.delBtn:Hide();  item.delBtn:SetParent(nil); item.delBtn = nil  end

    item.upBtn = item.mkBtn("^", -150, function()
        if idx > 1 then
            local capturedIdx = idx
            GeRODPS.ReorderAnim.SwapCards(_lastRawCardFrames[capturedIdx], _lastRawCardFrames[capturedIdx - 1], {
                idxA = capturedIdx - 1, idxB = capturedIdx,
                refreshFrames = function() return _lastRawCardFrames end,
            }, function()
                rawCards[capturedIdx], rawCards[capturedIdx - 1] = rawCards[capturedIdx - 1], rawCards[capturedIdx]
                LayoutRawCards()
                for j = 1, #rawCards do WireRawCardButtons(j) end
            end)
        end
    end)
    item.downBtn = item.mkBtn("v", -106, function()
        if idx < #rawCards then
            local capturedIdx = idx
            GeRODPS.ReorderAnim.SwapCards(_lastRawCardFrames[capturedIdx], _lastRawCardFrames[capturedIdx + 1], {
                idxA = capturedIdx, idxB = capturedIdx + 1,
                refreshFrames = function() return _lastRawCardFrames end,
            }, function()
                rawCards[capturedIdx], rawCards[capturedIdx + 1] = rawCards[capturedIdx + 1], rawCards[capturedIdx]
                LayoutRawCards()
                for j = 1, #rawCards do WireRawCardButtons(j) end
            end)
        end
    end)
    item.delBtn = item.mkBtn("Del", -50, function()
        local capturedIdx = idx
        local removed = table.remove(rawCards, capturedIdx)
        if removed and removed.frame then removed.frame:Hide(); removed.frame:SetParent(nil) end
        LayoutRawCards()
        for j = 1, #rawCards do WireRawCardButtons(j) end
    end)
end

local function RawAddCard()
    if not HasEngine() then return end
    nextCardNum = nextCardNum + 1
    local item = CreateRawCard(nextCardNum)
    table.insert(rawCards, item)
    LayoutRawCards()
    for j = 1, #rawCards do WireRawCardButtons(j) end
    local newIdx = #rawCards
    -- Defer 1 frame for parity with AceGUI side (also gives layout a tick)
    C_Timer.After(0, function()
        local newFrame = _lastRawCardFrames[newIdx]
        if newFrame then GeRODPS.ReorderAnim.AddCard(newFrame) end
    end)
end

-- ============================================================
-- Build/show frame
-- ============================================================
local function BuildFrame()
    if frame then return frame end
    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(DEFAULT_W, DEFAULT_H)
    frame:SetPoint("CENTER")
    frame:SetMovable(true); frame:EnableMouse(true); frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop",  frame.StopMovingOrSizing)
    frame:SetResizable(true)
    if frame.SetResizeBounds then frame:SetResizeBounds(MIN_W, MIN_H, 1600, 1000) end
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("HIGH")
    frame.TitleText:SetText("ReorderAnim Test — AceGUI vs Raw Frame")

    -- Status bar at top
    statusFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusFS:SetPoint("TOP", frame, "TOP", 0, -28)
    statusFS:SetText("(loading...)")

    -- Two columns. BasicFrameTemplateWithInset in TWW provides Inset
    -- decorative textures (InsetBg, InsetBorder*) but no child Inset
    -- subframe — match the `frame.Inset or frame` pattern used by other
    -- Tools (AlphaStackTest, WatchVar, CombatLogEventView). Skip the
    -- inset anchor reset because there's nothing to re-anchor on fallback.
    local inset = frame.Inset or frame
    if frame.Inset then
        inset:ClearAllPoints()
        inset:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -50)
        inset:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 8)
    end
    -- When fallback (inset == frame), header offsets need to clear the
    -- title bar (~28px). Use a top-offset variable so children below
    -- compose correctly in either path.
    local TOP_OFFSET = frame.Inset and 0 or -42   -- extra drop when no inset

    local colW = (DEFAULT_W - 32) / 2

    -- Left: AceGUI side
    local leftHeader = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    leftHeader:SetPoint("TOPLEFT", inset, "TOPLEFT", 10, -10 + TOP_OFFSET)
    leftHeader:SetText("|cff5fb0ffAceGUI (production parity)|r")

    -- Embed AceGUI ScrollFrame
    if LibStub and LibStub("AceGUI-3.0", true) then
        local AceGUI = LibStub("AceGUI-3.0")
        local container = AceGUI:Create("SimpleGroup")
        container:SetLayout("Fill")
        container.frame:SetParent(inset)
        container.frame:SetPoint("TOPLEFT", inset, "TOPLEFT", 10, -36 + TOP_OFFSET)
        container.frame:SetWidth(colW)
        container.frame:SetHeight(340)
        container.frame:Show()
        aceScroll = AceGUI:Create("ScrollFrame")
        aceScroll:SetLayout("Flow")
        container:AddChild(aceScroll)
    else
        local err = inset:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        err:SetPoint("TOPLEFT", inset, "TOPLEFT", 10, -36 + TOP_OFFSET)
        err:SetText("|cffff4444AceGUI not loaded — enable GeRODPS|r")
    end

    local aceAddBtn = CreateFrame("Button", nil, inset, "UIPanelButtonTemplate")
    aceAddBtn:SetSize(colW - 20, 26)
    aceAddBtn:SetPoint("TOPLEFT", inset, "TOPLEFT", 10, -36 - 340 - 6 + TOP_OFFSET)
    aceAddBtn:SetText("+ Add AceGUI Card")
    aceAddBtn:SetScript("OnClick", AceAddCard)

    -- Right: Raw side
    local rightHeader = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    rightHeader:SetPoint("TOPLEFT", inset, "TOPLEFT", 10 + colW + 10, -10 + TOP_OFFSET)
    rightHeader:SetText("|cff44ff44Raw CreateFrame (control)|r")

    -- Raw scroll: simple ScrollFrame with inner content
    local rawScroll = CreateFrame("ScrollFrame", nil, inset, "UIPanelScrollFrameTemplate")
    rawScroll:SetPoint("TOPLEFT", inset, "TOPLEFT", 10 + colW + 10, -36 + TOP_OFFSET)
    rawScroll:SetSize(colW - 26, 340)   -- -26 to leave room for scrollbar
    rawScrollContent = CreateFrame("Frame", nil, rawScroll)
    rawScrollContent:SetSize(colW - 26, 400)
    rawScroll:SetScrollChild(rawScrollContent)

    local rawAddBtn = CreateFrame("Button", nil, inset, "UIPanelButtonTemplate")
    rawAddBtn:SetSize(colW - 20, 26)
    rawAddBtn:SetPoint("TOPLEFT", inset, "TOPLEFT", 10 + colW + 10, -36 - 340 - 6 + TOP_OFFSET)
    rawAddBtn:SetText("+ Add Raw Card")
    rawAddBtn:SetScript("OnClick", RawAddCard)

    -- Reset button (clears both sides). Bottom anchor unaffected by
    -- TOP_OFFSET since frame.Inset's bottom is roughly the frame's own
    -- bottom in fallback path.
    local resetBtn = CreateFrame("Button", nil, inset, "UIPanelButtonTemplate")
    resetBtn:SetSize(120, 22)
    resetBtn:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -10, 10)
    resetBtn:SetText("Reset Both")
    resetBtn:SetScript("OnClick", function()
        aceCards = {}; BuildAceCards()
        for _, item in ipairs(rawCards) do
            if item.frame then item.frame:Hide(); item.frame:SetParent(nil) end
        end
        rawCards = {}; LayoutRawCards()
        nextCardNum = 0
        -- Seed 3 default cards each side
        for i = 1, 3 do
            nextCardNum = nextCardNum + 1
            table.insert(aceCards, { num = nextCardNum })
        end
        BuildAceCards()
        for i = 1, 3 do
            nextCardNum = nextCardNum + 1
            local item = CreateRawCard(nextCardNum)
            table.insert(rawCards, item)
        end
        LayoutRawCards()
        for j = 1, #rawCards do WireRawCardButtons(j) end
    end)

    -- Status refresh ticker (drives 10Hz update of status bar)
    local statusTicker = CreateFrame("Frame", nil, frame)
    local accum = 0
    statusTicker:SetScript("OnUpdate", function(_, dt)
        accum = accum + dt
        if accum >= 0.1 then accum = 0; RefreshStatus() end
    end)

    return frame
end

function TOOL.ShowReorderAnimTest()
    BuildFrame()
    frame:Show()
    if #aceCards == 0 and #rawCards == 0 then
        -- Seed initial 3 cards each
        nextCardNum = 0
        for i = 1, 3 do
            nextCardNum = nextCardNum + 1
            table.insert(aceCards, { num = nextCardNum })
        end
        BuildAceCards()
        for i = 1, 3 do
            nextCardNum = nextCardNum + 1
            local item = CreateRawCard(nextCardNum)
            table.insert(rawCards, item)
        end
        LayoutRawCards()
        for j = 1, #rawCards do WireRawCardButtons(j) end
    end
    RefreshStatus()
end

function TOOL.HideReorderAnimTest()
    if frame then frame:Hide() end
end

function TOOL.ToggleReorderAnimTest()
    if frame and frame:IsShown() then
        TOOL.HideReorderAnimTest()
    else
        TOOL.ShowReorderAnimTest()
    end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("ReorderAnim Test (A/B)", TOOL.ToggleReorderAnimTest)
end
