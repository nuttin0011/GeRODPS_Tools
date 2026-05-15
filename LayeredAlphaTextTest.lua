--[[
    LayeredAlphaTextTest.lua

    Visual harness สำหรับ 5-layer alpha-encoded channel ตาม spec ที่ใช้ได้
    จริงใน GeRODPS/LayeredAlphaEncoding.md (V_fixed-per-layer, α = 128/255).

    5-LAYER SCHEME (drawn bottom → top):
      L5 (bottom, drawn first)  R       V=255   →  R contribution {8..128}
      L4                         G-Light V=32    →  G low bits {2,4,8,16}
      L3                         G-Dark  V=255   →  G high bits {32,64,128}
      L2                         B-Dark  V=255   →  B high bits {64,128}
      L1 (top, drawn last)       B-Light V=32    →  B low bits = 16

    Each layer is on/off only (binary state, V is fixed). 5 layers = 32
    codes/pixel — robust to alpha-blend rounding via bit-mask decode.

    Decode (per pixel):
      R on      iff  R > 0
      G-Light   iff  G mod 32 ≠ 0     (L4 contribution bits)
      G-Dark    iff  G ≥ 32           (L3 contribution bits)
      B-Light   iff  B mod 32 ≠ 0     (L1 contribution)
      B-Dark    iff  B ≥ 32           (L2 contribution)

    UI:
      - Canvas สีดำ alpha 1 — 5 FontStrings + 5 Textures ซ้อนกัน
      - PixelTiny.ttf + MONOCHROME (sharp-edge)
      - Slider ปรับ font size ทุก layer พร้อมกัน
      - Per-layer:
          * On/Off CheckButton
          * EditBox สำหรับข้อความ
      - Live readout: R/G/B + decoded state (R, GL, GD, BL, BD)
      - Render mode radio: Text glyphs / Solid block (full canvas)
      - Optional: black α=½ separator between layers (experimental)

    Public:
      GeRODPS_Tools.ToggleLayeredAlphaTextTest()
      GeRODPS_Tools.ShowLayeredAlphaTextTest()
      GeRODPS_Tools.HideLayeredAlphaTextTest()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME    = "GeRODPS_ToolsLayeredAlphaTextTestFrame"
local FONT_PATH     = "Interface\\AddOns\\GeRODPS_Tools\\fonts\\PixelTiny.ttf"

local DEFAULT_W     = 760
local DEFAULT_H     = 560
local SCREEN_MARGIN = 100

local CANVAS_W      = 700
local CANVAS_H      = 90

local DEFAULT_SIZE  = 32
local MIN_SIZE      = 8
local MAX_SIZE      = 96

-- ============================================================
-- Layer spec — 5 fixed-V layers, drawn bottom-up.
-- subLayer spacing of 2 leaves room for 4 black separator textures
-- between adjacent colored layers (subLayers 3, 1, -1, -3).
-- ============================================================

local LAYERS = {
    { idx = 1, label = "L1  B-Light V=32   (top)",     channel = "B", V = 32,  subLayer =  4 },
    { idx = 2, label = "L2  B-Dark  V=255",            channel = "B", V = 255, subLayer =  2 },
    { idx = 3, label = "L3  G-Dark  V=255",            channel = "G", V = 255, subLayer =  0 },
    { idx = 4, label = "L4  G-Light V=32",             channel = "G", V = 32,  subLayer = -2 },
    { idx = 5, label = "L5  R       V=255 (bottom)",   channel = "R", V = 255, subLayer = -4 },
}

local SEPARATOR_SUBLAYERS = { 3, 1, -1, -3 }  -- 4 separators between 5 layers

-- ============================================================
-- DB
-- ============================================================

local function GetDB()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    local db = GeRODPS_ToolsDB.layeredAlphaText or {}
    GeRODPS_ToolsDB.layeredAlphaText = db
    if db.fontSize          == nil then db.fontSize          = DEFAULT_SIZE end
    if db.useBlackSeparator == nil then db.useBlackSeparator = false        end
    if db.renderMode        == nil then db.renderMode        = "text"       end
    db.layers = db.layers or {}
    for _, l in ipairs(LAYERS) do
        local entry = db.layers[l.idx] or {}
        if entry.on   == nil then entry.on   = true          end
        if entry.text == nil then entry.text = "TEST123456"  end
        db.layers[l.idx] = entry
    end
    return db
end

-- ============================================================
-- State
-- ============================================================

local frame
local canvas
local layerFontStrings  = {}  -- [idx] = FontString (text mode)
local layerTextures     = {}  -- [idx] = Texture    (solid mode)
local separatorTextures = {}  -- [1..4] = Texture (black α=128/255, full canvas)
local onCheckboxes      = {}  -- [idx] = CheckButton (binary on/off)
local textEditBoxes     = {}  -- [idx] = EditBox
local sizeSlider, sizeValueFS
local readoutFS, decodeFS
local separatorCheckbox
local renderModeRadios  = {}  -- ["text"|"solid"] = CheckButton

-- ============================================================
-- Encoding math — simulate alpha blending exactly
-- ============================================================

local function BlendInto(dstR, dstG, dstB, srcR, srcG, srcB, srcA)
    local oneMA = 1 - srcA
    return
        math.floor(srcR * srcA + dstR * oneMA + 0.5),
        math.floor(srcG * srcA + dstG * oneMA + 0.5),
        math.floor(srcB * srcA + dstB * oneMA + 0.5)
end

local function ComputeExpectedRGB()
    local db = GetDB()
    local r, g, b = 0, 0, 0
    local sepAlpha = 128 / 255
    local colAlpha = 128 / 255

    -- Draw order: L5 (bottom) → L1 (top). idx 5 first, idx 1 last.
    for idx = #LAYERS, 1, -1 do
        local spec  = LAYERS[idx]
        local entry = db.layers[idx]
        if entry and entry.on then
            local sR, sG, sB = 0, 0, 0
            if     spec.channel == "R" then sR = spec.V
            elseif spec.channel == "G" then sG = spec.V
            elseif spec.channel == "B" then sB = spec.V
            end
            r, g, b = BlendInto(r, g, b, sR, sG, sB, colAlpha)
        end
        -- Black separator AFTER this layer (between idx and idx-1).
        -- Skip after the topmost layer.
        if db.useBlackSeparator and idx > 1 then
            r, g, b = BlendInto(r, g, b, 0, 0, 0, sepAlpha)
        end
    end
    return r, g, b
end

local function DecodeStates(r, g, b)
    return {
        R       = (r > 0),
        GLight  = (g % 32 ~= 0),
        GDark   = (g >= 32),
        BLight  = (b % 32 ~= 0),
        BDark   = (b >= 32),
    }
end

local function FmtState(label, on)
    if on then return string.format("|cFF99FF99%s|r",   label) end
    return       string.format("|cFF666666%s|r",         label)
end

local function RefreshReadout()
    if not readoutFS then return end
    local db = GetDB()
    local r, g, b = ComputeExpectedRGB()
    local s = DecodeStates(r, g, b)

    local renderTag = (db.renderMode == "solid")
        and "|cFF99CCFFSolid|r"
        or  "|cFFFFFFFFText|r"
    local sepTag = db.useBlackSeparator
        and "|cFFFFAA55+separator|r"
        or  "|cFF99FF99no separator|r"

    readoutFS:SetText(string.format(
        "Render: %s   |   Encode: %s\n" ..
        "|cffaaaaaaPixel:|r  " ..
        "R=|cFFFF7777%d|r  G=|cFF77FF77%d|r  B=|cFF7777FF%d|r",
        renderTag, sepTag, r, g, b))

    if decodeFS then
        decodeFS:SetText(string.format(
            "|cffaaaaaaDecoded:|r  %s   %s   %s   %s   %s",
            FmtState("R",       s.R),
            FmtState("G-Light", s.GLight),
            FmtState("G-Dark",  s.GDark),
            FmtState("B-Light", s.BLight),
            FmtState("B-Dark",  s.BDark)))
    end
end

local function ApplySeparatorVisibility()
    local db = GetDB()
    local show = db.useBlackSeparator and true or false
    for _, sep in ipairs(separatorTextures) do
        if show then sep:Show() else sep:Hide() end
    end
end

-- ============================================================
-- Render: apply state/text/font to one layer
-- ============================================================

local function ApplyLayer(idx)
    local db    = GetDB()
    local entry = db.layers[idx]
    local fs    = layerFontStrings[idx]
    local tex   = layerTextures[idx]
    if not entry then return end

    local spec = LAYERS[idx]
    local Vraw = entry.on and spec.V or 0
    local Vn   = Vraw / 255
    local r, g, b = 0, 0, 0
    if     spec.channel == "R" then r = Vn
    elseif spec.channel == "G" then g = Vn
    elseif spec.channel == "B" then b = Vn end

    local solid = (db.renderMode == "solid")

    if fs then
        if solid then
            fs:Hide()
        else
            fs:Show()
            fs:SetFont(FONT_PATH, db.fontSize, "MONOCHROME")
            if not entry.on then
                fs:SetText("")
            else
                fs:SetTextColor(r, g, b, 128 / 255)
                fs:SetText(entry.text or "")
            end
        end
    end

    if tex then
        if (not solid) or (not entry.on) then
            tex:Hide()
        else
            tex:Show()
            tex:SetColorTexture(r, g, b, 128 / 255)
        end
    end
end

local function ApplyAllLayers()
    for _, l in ipairs(LAYERS) do ApplyLayer(l.idx) end
    ApplySeparatorVisibility()
    RefreshReadout()
end

-- ============================================================
-- Geometry persistence
-- ============================================================

local function SavePosition(self)
    local db = GetDB()
    local p, _, rp, x, y = self:GetPoint(1)
    db.point, db.relPoint, db.x, db.y = p, rp, x, y
end

local function ApplySavedGeometry(self)
    local db = GetDB()
    self:ClearAllPoints()
    if db.point and db.relPoint and db.x and db.y then
        self:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    else
        self:SetPoint("CENTER")
    end
    self:SetSize(DEFAULT_W, DEFAULT_H)

    local screenW = UIParent:GetWidth()
    local screenH = UIParent:GetHeight()
    local left, right = self:GetLeft(), self:GetRight()
    local bottom, top = self:GetBottom(), self:GetTop()
    if left and right and bottom and top then
        local dx, dy = 0, 0
        if left   < SCREEN_MARGIN             then dx = SCREEN_MARGIN - left end
        if right  > (screenW - SCREEN_MARGIN) then dx = (screenW - SCREEN_MARGIN) - right end
        if bottom < SCREEN_MARGIN             then dy = SCREEN_MARGIN - bottom end
        if top    > (screenH - SCREEN_MARGIN) then dy = (screenH - SCREEN_MARGIN) - top end
        if dx ~= 0 or dy ~= 0 then
            local point, relTo, relPoint, x, y = self:GetPoint(1)
            self:ClearAllPoints()
            self:SetPoint(point, relTo or UIParent, relPoint, x + dx, y + dy)
        end
    end
end

-- ============================================================
-- Build helpers
-- ============================================================

local function CreateLayerRow(parent, anchorAbove, idx)
    local spec = LAYERS[idx]

    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(26)
    if anchorAbove then
        row:SetPoint("TOPLEFT",  anchorAbove, "BOTTOMLEFT",  0, -4)
        row:SetPoint("TOPRIGHT", anchorAbove, "BOTTOMRIGHT", 0, -4)
    else
        row:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, 0)
        row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    end

    local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameFS:SetPoint("LEFT", row, "LEFT", 0, 0)
    nameFS:SetWidth(210)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetText("|cFFFFD200" .. spec.label .. "|r")

    -- On/Off checkbox
    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("LEFT", nameFS, "RIGHT", 6, 0)
    local onLbl = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    onLbl:SetPoint("LEFT", cb, "RIGHT", 0, 0)
    onLbl:SetText("On")
    cb:SetScript("OnClick", function(self)
        local db = GetDB()
        db.layers[idx].on = self:GetChecked() and true or false
        ApplyLayer(idx)
        RefreshReadout()
    end)
    onCheckboxes[idx] = cb

    -- Text EditBox
    local eb = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    eb:SetPoint("LEFT",  onLbl, "RIGHT", 30, 0)
    eb:SetPoint("RIGHT", row,   "RIGHT",  0, 0)
    eb:SetHeight(20)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(64)
    eb:SetFontObject("ChatFontNormal")
    eb:SetScript("OnEnterPressed", function(self)
        local db = GetDB()
        db.layers[idx].text = self:GetText() or ""
        ApplyLayer(idx)
        self:ClearFocus()
    end)
    eb:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        local db = GetDB()
        db.layers[idx].text = self:GetText() or ""
        ApplyLayer(idx)
    end)
    eb:SetScript("OnEscapePressed", function(self)
        local db = GetDB()
        self:SetText(db.layers[idx].text or "")
        self:ClearFocus()
    end)
    textEditBoxes[idx] = eb

    return row
end

local function SyncControlsFromDB()
    local db = GetDB()
    if sizeSlider  then sizeSlider:SetValue(db.fontSize) end
    if sizeValueFS then sizeValueFS:SetText(tostring(db.fontSize)) end
    if separatorCheckbox then
        separatorCheckbox:SetChecked(db.useBlackSeparator and true or false)
    end
    for k, btn in pairs(renderModeRadios) do
        btn:SetChecked(k == db.renderMode)
    end

    for _, l in ipairs(LAYERS) do
        local entry = db.layers[l.idx]
        if onCheckboxes[l.idx] then
            onCheckboxes[l.idx]:SetChecked(entry.on and true or false)
        end
        if textEditBoxes[l.idx] then
            textEditBoxes[l.idx]:SetText(entry.text or "")
        end
    end
end

-- ============================================================
-- Build frame
-- ============================================================

local function CreateTestFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetUserPlaced(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)

    if frame.TitleText then
        frame.TitleText:SetText(
            "GeRODPS Tools — Layered Alpha Test (5 layers, V-fixed, α=128/255)")
    end

    local content = frame.Inset or frame

    -- ── Canvas: black background ──
    canvas = CreateFrame("Frame", nil, content)
    canvas:SetSize(CANVAS_W, CANVAS_H)
    canvas:SetPoint("TOP", content, "TOP", 0, -10)

    local bg = canvas:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(canvas)
    bg:SetColorTexture(0, 0, 0, 1)

    local function MakeEdge(a1, a2, sx, sy)
        local e = canvas:CreateTexture(nil, "OVERLAY")
        e:SetPoint(a1, canvas, a1, 0, 0)
        e:SetPoint(a2, canvas, a2, 0, 0)
        e:SetColorTexture(0.35, 0.35, 0.35, 1)
        if sx then e:SetWidth(sx) end
        if sy then e:SetHeight(sy) end
    end
    MakeEdge("TOPLEFT",    "TOPRIGHT",    nil, 1)
    MakeEdge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    MakeEdge("TOPLEFT",    "BOTTOMLEFT",  1,   nil)
    MakeEdge("TOPRIGHT",   "BOTTOMRIGHT", 1,   nil)

    -- 5 FontStrings + 5 Textures (one of each shown per render mode).
    -- IMPORTANT: subLayer is set via the 4-arg form of CreateFontString /
    -- CreateTexture (the documented way). Calling :SetDrawLayer() after
    -- creation does not reliably update the subLevel for FontStrings on
    -- some WoW builds — texts stayed at subLevel 0 (default) and z-order
    -- collapsed to creation order (L5 visually on top instead of L1).
    layerFontStrings = {}
    layerTextures    = {}
    for _, l in ipairs(LAYERS) do
        local fs = canvas:CreateFontString(nil, "OVERLAY", nil, l.subLayer)
        fs:SetPoint("TOPLEFT",     canvas, "TOPLEFT",      4,  -4)
        fs:SetPoint("BOTTOMRIGHT", canvas, "BOTTOMRIGHT", -4,   4)
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetFont(FONT_PATH, DEFAULT_SIZE, "MONOCHROME")
        fs:SetWordWrap(false)
        fs:SetNonSpaceWrap(false)
        layerFontStrings[l.idx] = fs

        local tex = canvas:CreateTexture(nil, "OVERLAY", nil, l.subLayer)
        tex:SetPoint("TOPLEFT",     canvas, "TOPLEFT",      4,  -4)
        tex:SetPoint("BOTTOMRIGHT", canvas, "BOTTOMRIGHT", -4,   4)
        tex:SetColorTexture(0, 0, 0, 0)
        tex:Hide()
        layerTextures[l.idx] = tex
    end

    -- 4 black separator textures (hidden by default)
    separatorTextures = {}
    for _, subLayer in ipairs(SEPARATOR_SUBLAYERS) do
        local sep = canvas:CreateTexture(nil, "OVERLAY", nil, subLayer)
        sep:SetPoint("TOPLEFT",     canvas, "TOPLEFT",      4,  -4)
        sep:SetPoint("BOTTOMRIGHT", canvas, "BOTTOMRIGHT", -4,   4)
        sep:SetColorTexture(0, 0, 0, 128 / 255)
        sep:Hide()
        separatorTextures[#separatorTextures + 1] = sep
    end

    -- ── Readout (2 lines: mode + raw RGB) ──
    readoutFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    readoutFS:SetPoint("TOPLEFT",  canvas, "BOTTOMLEFT",  0, -8)
    readoutFS:SetPoint("TOPRIGHT", canvas, "BOTTOMRIGHT", 0, -8)
    readoutFS:SetJustifyH("LEFT")
    readoutFS:SetJustifyV("TOP")
    readoutFS:SetText("")

    -- Decoded states line (separate FS for alignment)
    decodeFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    decodeFS:SetPoint("TOPLEFT",  readoutFS, "BOTTOMLEFT",  0, -18)
    decodeFS:SetPoint("TOPRIGHT", readoutFS, "BOTTOMRIGHT", 0, -18)
    decodeFS:SetJustifyH("LEFT")
    decodeFS:SetText("")

    -- ── Render-mode row ──
    local modeRow = CreateFrame("Frame", nil, content)
    modeRow:SetSize(CANVAS_W, 24)
    modeRow:SetPoint("TOPLEFT", decodeFS, "BOTTOMLEFT", 0, -12)

    local modeLabel = modeRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    modeLabel:SetPoint("LEFT", modeRow, "LEFT", 0, 0)
    modeLabel:SetText("Render mode:")

    local function MakeModeRadio(modeKey, labelText, anchorTo, anchorXOff)
        local rb = CreateFrame("CheckButton", nil, modeRow, "UIRadioButtonTemplate")
        rb:SetSize(18, 18)
        rb:SetPoint("LEFT", anchorTo, "RIGHT", anchorXOff, 0)
        local lbl = rb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        lbl:SetPoint("LEFT", rb, "RIGHT", 2, 0)
        lbl:SetText(labelText)
        rb:SetScript("OnClick", function()
            local db = GetDB()
            db.renderMode = modeKey
            for k, btn in pairs(renderModeRadios) do
                btn:SetChecked(k == modeKey)
            end
            ApplyAllLayers()
        end)
        renderModeRadios[modeKey] = rb
        return rb, lbl
    end

    local _, textLbl = MakeModeRadio("text",
        "Text glyphs (decode only at all-glyphs-on pixels)", modeLabel, 8)
    MakeModeRadio("solid",
        "Solid block (math-pure at every pixel)", textLbl, 12)

    -- ── Separator-mode checkbox ──
    separatorCheckbox = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    separatorCheckbox:SetPoint("TOPLEFT", modeRow, "BOTTOMLEFT", -4, -4)
    separatorCheckbox:SetSize(22, 22)
    local sepLbl = separatorCheckbox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sepLbl:SetPoint("LEFT", separatorCheckbox, "RIGHT", 2, 0)
    sepLbl:SetText(
        "Insert (0,0,0) α=128/255 separator between layers  " ..
        "|cFFFFAA55(experimental — extra halving)|r")
    separatorCheckbox:SetScript("OnClick", function(self)
        local db = GetDB()
        db.useBlackSeparator = self:GetChecked() and true or false
        ApplyAllLayers()
    end)

    -- ── Font size slider ──
    local sizeRow = CreateFrame("Frame", nil, content)
    sizeRow:SetSize(CANVAS_W, 24)
    sizeRow:SetPoint("TOPLEFT", separatorCheckbox, "BOTTOMLEFT", 4, -8)

    local sizeLabel = sizeRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sizeLabel:SetPoint("LEFT", sizeRow, "LEFT", 0, 0)
    sizeLabel:SetText("Font Size:")

    sizeSlider = CreateFrame("Slider", nil, sizeRow, "OptionsSliderTemplate")
    sizeSlider:SetPoint("LEFT", sizeLabel, "RIGHT", 8, 0)
    sizeSlider:SetWidth(380)
    sizeSlider:SetHeight(16)
    sizeSlider:SetMinMaxValues(MIN_SIZE, MAX_SIZE)
    sizeSlider:SetValueStep(1)
    sizeSlider:SetObeyStepOnDrag(true)
    sizeSlider:SetValue(DEFAULT_SIZE)

    sizeValueFS = sizeRow:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sizeValueFS:SetPoint("LEFT", sizeSlider, "RIGHT", 16, 0)
    sizeValueFS:SetText(tostring(DEFAULT_SIZE))

    sizeSlider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value + 0.5)
        local db = GetDB()
        if value == db.fontSize then return end
        db.fontSize = value
        if sizeValueFS then sizeValueFS:SetText(tostring(value)) end
        ApplyAllLayers()
    end)

    -- ── 5 layer control rows ──
    local rowsHost = CreateFrame("Frame", nil, content)
    rowsHost:SetPoint("TOPLEFT",  sizeRow, "BOTTOMLEFT",  0, -10)
    rowsHost:SetPoint("TOPRIGHT", sizeRow, "BOTTOMRIGHT", 0, -10)
    rowsHost:SetHeight(26 * #LAYERS + 4 * (#LAYERS - 1))

    local prevRow
    for _, l in ipairs(LAYERS) do
        prevRow = CreateLayerRow(rowsHost, prevRow, l.idx)
    end

    -- ── Reset button ──
    local resetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    resetBtn:SetSize(160, 22)
    resetBtn:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 14, 14)
    resetBtn:SetText("Reset (all On, 'TEST123456')")
    resetBtn:SetScript("OnClick", function()
        local db = GetDB()
        db.fontSize          = DEFAULT_SIZE
        db.useBlackSeparator = false
        db.renderMode        = "text"
        for _, l in ipairs(LAYERS) do
            db.layers[l.idx].on   = true
            db.layers[l.idx].text = "TEST123456"
        end
        SyncControlsFromDB()
        ApplyAllLayers()
    end)

    local hintFS = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintFS:SetPoint("LEFT", resetBtn, "RIGHT", 12, 0)
    hintFS:SetPoint("RIGHT", content, "RIGHT", -14, 0)
    hintFS:SetJustifyH("LEFT")
    hintFS:SetText(
        "Solid mode → ทุก pixel encode ได้ครบ.  Text mode → decode " ..
        "ได้เฉพาะ pixel ที่ทุก layer's glyph on พร้อมกัน.")

    table.insert(UISpecialFrames, FRAME_NAME)
    ApplySavedGeometry(frame)
    SyncControlsFromDB()
    ApplyAllLayers()
    frame:Hide()
    return frame
end

-- ============================================================
-- Public API
-- ============================================================

function TOOL.ShowLayeredAlphaTextTest()
    local f = CreateTestFrame()
    if not f:IsShown() then
        ApplySavedGeometry(f)
        SyncControlsFromDB()
        ApplyAllLayers()
        f:Show()
    end
end

function TOOL.HideLayeredAlphaTextTest()
    if frame and frame:IsShown() then frame:Hide() end
end

function TOOL.ToggleLayeredAlphaTextTest()
    local f = CreateTestFrame()
    if f:IsShown() then
        f:Hide()
    else
        ApplySavedGeometry(f)
        SyncControlsFromDB()
        ApplyAllLayers()
        f:Show()
    end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("Test Layered Alpha Text (5 layers)",
                      TOOL.ToggleLayeredAlphaTextTest)
end
