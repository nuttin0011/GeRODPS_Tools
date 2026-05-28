--[[
    CardColorTune.lua  (Dev tool, not user-facing)

    Pick a palette + delta visually, then bake the chosen delta into
    GeRODPS.CardTheme.ApplyToInlineGroupForCurrentTabDarker(card, ...) by
    hand. Tool reads palettes live from GeRODPS.CardTheme.PALETTE so it
    stays in sync if palette entries change.

    Rule under test:
        Card RGB = BG RGB + delta per channel  (each channel clamped 0..1)

    Public:
        GeRODPS_Tools.ToggleCardColorTune()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME = "GeRODPS_ToolsCardColorTuneFrame"
local DEFAULT_W, DEFAULT_H = 760, 500

-- Six fixed delta presets shown side-by-side
local DELTAS = { 0.03, 0.05, 0.07, 0.09, 0.12, 0.15 }

-- Display order for palette picker row. Keeps the user's example
-- 'blue/teal/purple/green/mint' first.
local PALETTE_ORDER = {
    "blue", "teal", "purple", "green", "mint", "indigo",
    "orange", "red",  "gold",   "pink",  "lime", "amber",
}

local frame
local currentPalette = "blue"
local customDelta = 0.09

-- Live widget references — refreshed in refreshAll()
local bgRGBLabel
local previewCols = {}    -- per fixed-delta column: { bgTex, cardTex, label }
local customWidgets = {}  -- { bgTex, cardTex, label }
local slider

-- ============================================================
-- Helpers
-- ============================================================

local function getPalette(name)
    return GeRODPS
       and GeRODPS.CardTheme
       and GeRODPS.CardTheme.PALETTE
       and GeRODPS.CardTheme.PALETTE[name]
end

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function refreshAll()
    local pal = getPalette(currentPalette)
    if not pal then return end
    local b = pal.body

    bgRGBLabel:SetText(string.format(
        "Palette: |cff%s%s|r    BG: R=%.3f  G=%.3f  B=%.3f  A=%.2f",
        pal.hex or "ffffffff", currentPalette,
        b[1], b[2], b[3], b[4]))

    for i, d in ipairs(DELTAS) do
        local w = previewCols[i]
        if w then
            w.bgTex:SetColorTexture(b[1], b[2], b[3], b[4])
            local cr = clamp01(b[1] + d)
            local cg = clamp01(b[2] + d)
            local cb = clamp01(b[3] + d)
            w.cardTex:SetColorTexture(cr, cg, cb, b[4])
            w.label:SetText(string.format(
                "Δ = %.02f\n%.3f\n%.3f\n%.3f", d, cr, cg, cb))
        end
    end

    if customWidgets.bgTex then
        customWidgets.bgTex:SetColorTexture(b[1], b[2], b[3], b[4])
        local cr = clamp01(b[1] + customDelta)
        local cg = clamp01(b[2] + customDelta)
        local cb = clamp01(b[3] + customDelta)
        customWidgets.cardTex:SetColorTexture(cr, cg, cb, b[4])
        customWidgets.label:SetText(string.format(
            "Custom Δ = %.02f   →   R=%.3f  G=%.3f  B=%.3f",
            customDelta, cr, cg, cb))
    end
end

-- ============================================================
-- Build frame (lazy — created on first Show)
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
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("HIGH")
    frame.TitleText:SetText("Card Color Tuner (Dev)")

    -- BasicFrameTemplateWithInset in TWW has no child Inset frame —
    -- fallback to frame and shift children down past the title bar.
    local inset = frame.Inset or frame
    local TOP_OFF = frame.Inset and 0 or -42

    -- Palette button row
    local btnPrev
    local btnY = -10 + TOP_OFF
    for i, name in ipairs(PALETTE_ORDER) do
        local btn = CreateFrame("Button", nil, inset, "UIPanelButtonTemplate")
        btn:SetSize(58, 22)
        btn:SetText(name)
        if i == 1 then
            btn:SetPoint("TOPLEFT", inset, "TOPLEFT", 10, btnY)
        else
            btn:SetPoint("LEFT", btnPrev, "RIGHT", 2, 0)
        end
        btn:SetScript("OnClick", function()
            currentPalette = name
            refreshAll()
        end)
        btnPrev = btn
    end

    -- BG RGB readout
    bgRGBLabel = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bgRGBLabel:SetPoint("TOPLEFT", inset, "TOPLEFT", 10, -42 + TOP_OFF)
    bgRGBLabel:SetText("(loading...)")

    -- Side-by-side fixed-delta columns
    local COL_W, COL_H, COL_GAP = 110, 130, 8
    local rowY = -72 + TOP_OFF
    for i, _d in ipairs(DELTAS) do
        local x = 10 + (i - 1) * (COL_W + COL_GAP)
        -- BG swatch (outer)
        local bg = inset:CreateTexture(nil, "ARTWORK")
        bg:SetSize(COL_W, COL_H)
        bg:SetPoint("TOPLEFT", inset, "TOPLEFT", x, rowY)
        -- BG label "BG" at top-left of swatch
        local bgTag = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bgTag:SetPoint("TOPLEFT", bg, "TOPLEFT", 4, -2)
        bgTag:SetText("BG")
        -- Card swatch (inner)
        local card = inset:CreateTexture(nil, "OVERLAY")
        card:SetSize(COL_W - 30, COL_H - 60)
        card:SetPoint("TOPLEFT", bg, "TOPLEFT", 15, -20)
        local cardTag = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        cardTag:SetPoint("CENTER", card)
        cardTag:SetText("Card")
        -- Delta + RGB readout under swatch
        local lbl = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("TOP", bg, "BOTTOM", 0, -2)
        lbl:SetJustifyH("CENTER")
        lbl:SetWidth(COL_W)
        previewCols[i] = { bgTex = bg, cardTex = card, label = lbl }
    end

    -- Custom delta slider + preview
    local sliderY = rowY - COL_H - 70
    local sliderLabel = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sliderLabel:SetPoint("TOPLEFT", inset, "TOPLEFT", 10, sliderY)
    sliderLabel:SetText("Custom Δ:")

    slider = CreateFrame("Slider", FRAME_NAME .. "Slider", inset, "OptionsSliderTemplate")
    slider:SetSize(280, 18)
    slider:SetPoint("TOPLEFT", inset, "TOPLEFT", 84, sliderY)
    slider:SetMinMaxValues(0.00, 0.30)
    slider:SetValue(customDelta)
    slider:SetValueStep(0.01)
    slider:SetObeyStepOnDrag(true)
    _G[FRAME_NAME .. "SliderLow"]:SetText("0.00")
    _G[FRAME_NAME .. "SliderHigh"]:SetText("0.30")
    _G[FRAME_NAME .. "SliderText"]:SetText("")
    slider:SetScript("OnValueChanged", function(_, v)
        -- Snap to 2 decimals
        customDelta = math.floor(v * 100 + 0.5) / 100
        refreshAll()
    end)

    -- Custom preview (BG strip + Card strip + RGB readout)
    local customY = sliderY - 36
    local bgC = inset:CreateTexture(nil, "ARTWORK")
    bgC:SetSize(220, 56)
    bgC:SetPoint("TOPLEFT", inset, "TOPLEFT", 10, customY)
    local bgTagC = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bgTagC:SetPoint("TOPLEFT", bgC, "TOPLEFT", 4, -2)
    bgTagC:SetText("BG")
    local cardC = inset:CreateTexture(nil, "OVERLAY")
    cardC:SetSize(180, 32)
    cardC:SetPoint("CENTER", bgC, "CENTER", 0, -4)
    local cardTagC = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cardTagC:SetPoint("CENTER", cardC)
    cardTagC:SetText("Card")
    local lblC = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lblC:SetPoint("LEFT", bgC, "RIGHT", 12, 0)
    customWidgets.bgTex = bgC
    customWidgets.cardTex = cardC
    customWidgets.label = lblC
end

-- ============================================================
-- Public toggle
-- ============================================================

function TOOL.ShowCardColorTune()
    if not (GeRODPS and GeRODPS.CardTheme and GeRODPS.CardTheme.PALETTE) then
        print("|cffff4444[GeRODPS_Tools]|r Card Color Tuner: " ..
              "GeRODPS.CardTheme not loaded — enable GeRODPS addon then /reload.")
        return
    end
    BuildFrame()
    frame:Show()
    refreshAll()
end

function TOOL.HideCardColorTune()
    if frame then frame:Hide() end
end

function TOOL.ToggleCardColorTune()
    if frame and frame:IsShown() then
        TOOL.HideCardColorTune()
    else
        TOOL.ShowCardColorTune()
    end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("Card Color Tuner (Dev)", TOOL.ToggleCardColorTune)
end
