--[[
    LayeredAlphaTextTest.lua

    Visual harness สำหรับ 6-layer alpha-encoded text channel ตาม spec
    ใน GeRODPS/LayeredAlphaEncoding.md (R R G G B B, α = 128/255).

    Layer assignment (1 = top, drawn LAST, contributes V/2; 6 = bottom,
    drawn FIRST, contributes V/64):

        L1 → B (high)   ── subLayer 6 (on top)
        L2 → B (low)    ── subLayer 5
        L3 → G (high)   ── subLayer 4
        L4 → G (low)    ── subLayer 3
        L5 → R (high)   ── subLayer 2
        L6 → R (low)    ── subLayer 1 (drawn first onto black background)

    UI:
        - Canvas สีดำ alpha 1 (พื้นหลัง)
        - 6 FontStrings ซ้อนกันบน canvas — ใช้ PixelTiny.ttf + MONOCHROME
        - Slider ปรับ font size (ปรับทีเดียวพร้อมกันทั้ง 6 layer)
        - 6 รายการ control ต่อ layer:
            * 3-state toggle (Off / Light V=64 / Dark V=255)
            * EditBox สำหรับข้อความของ layer นั้น
        - Live readout: ค่า (R, G, B) ที่คาดหวังจากตาราง encoding
          (สมมติทุก layer's glyph มี pixel "on" ตรงกัน — pixel ที่เปิดทุก
          layer จริงๆ จะอ่านเป็นค่านี้)

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
local DEFAULT_H     = 600
local SCREEN_MARGIN = 100

local CANVAS_W      = 700
local CANVAS_H      = 90

local DEFAULT_SIZE  = 32
local MIN_SIZE      = 8
local MAX_SIZE      = 96

-- ============================================================
-- Layer spec (top → bottom)
-- ============================================================

local STATE_OFF, STATE_LIGHT, STATE_DARK = "off", "light", "dark"

-- subLayer mapping leaves room for 5 black separator textures between the
-- 6 colored FontStrings. Draw order (low → high subLayer = first → last):
--    L6 (-5) sep (-4) L5 (-3) sep (-2) L4 (-1) sep (0)
--    L3 (1)  sep (2)  L2 (3)  sep (4)  L1 (5)
-- WoW subLayer range is -8..7, so 11 slots fit comfortably.
local LAYERS = {
    { idx = 1, label = "L1  B-high  (blue)",  channel = "B", subLayer =  5 },
    { idx = 2, label = "L2  B-low   (blue)",  channel = "B", subLayer =  3 },
    { idx = 3, label = "L3  G-high  (green)", channel = "G", subLayer =  1 },
    { idx = 4, label = "L4  G-low   (green)", channel = "G", subLayer = -1 },
    { idx = 5, label = "L5  R-high  (red)",   channel = "R", subLayer = -3 },
    { idx = 6, label = "L6  R-low   (red)",   channel = "R", subLayer = -5 },
}

-- Separator subLayers, in draw order (first drawn = lowest = between L6 and
-- L5). 5 separators total: one between each pair of adjacent colored layers.
local SEPARATOR_SUBLAYERS = { -4, -2, 0, 2, 4 }

local STATE_ORDER = { STATE_OFF, STATE_LIGHT, STATE_DARK }
local STATE_LABEL = { off = "Off", light = "Light", dark = "Dark" }
local STATE_V     = { off = 0,     light = 64,      dark = 255   }

-- ============================================================
-- DB
-- ============================================================

local function DefaultText(idx) return tostring(idx) end

local function GetDB()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    local db = GeRODPS_ToolsDB.layeredAlphaText or {}
    GeRODPS_ToolsDB.layeredAlphaText = db
    if db.fontSize          == nil then db.fontSize          = DEFAULT_SIZE end
    if db.useBlackSeparator == nil then db.useBlackSeparator = false        end
    db.layers = db.layers or {}
    for _, l in ipairs(LAYERS) do
        local entry = db.layers[l.idx] or {}
        if entry.state == nil then entry.state = STATE_DARK end
        if entry.text  == nil then entry.text  = "TEST123456" end
        db.layers[l.idx] = entry
    end
    return db
end

-- ============================================================
-- State
-- ============================================================

local frame
local canvas
local layerFontStrings = {}   -- [idx] = FontString
local separatorTextures = {}  -- [1..5] = Texture (black α=128/255, full-canvas)
local stateRadios      = {}   -- [idx] = { [state] = CheckButton }
local textEditBoxes    = {}   -- [idx] = EditBox
local sizeSlider, sizeValueFS
local readoutFS
local separatorCheckbox

-- ============================================================
-- Encoding math — expected pixel value for a "fully-on" pixel
-- ============================================================

-- Per-layer exponent for V / 2^exp at a "fully-on" pixel.
-- Without separator:  L_N's draw is the N-th from top → contribution V/2^N.
-- With separator:     each layer is preceded by a black α=½ rect that
--                     halves dst again, so its draw is the (2N-1)-th from
--                     the canvas baseline → contribution V/2^(2N-1).
local function ContributionExp(layerIdx, useSep)
    if useSep then return 2 * layerIdx - 1 end
    return layerIdx
end

local function ComputeExpectedRGB()
    local db = GetDB()
    local useSep = db.useBlackSeparator and true or false
    local r, g, b = 0, 0, 0
    for _, l in ipairs(LAYERS) do
        local entry = db.layers[l.idx]
        local V = STATE_V[entry.state] or 0
        if V > 0 then
            local exp = ContributionExp(l.idx, useSep)
            local contribution = math.floor(V / (2 ^ exp) + 0.5)
            if l.channel == "R" then r = r + contribution
            elseif l.channel == "G" then g = g + contribution
            elseif l.channel == "B" then b = b + contribution
            end
        end
    end
    return r, g, b
end

local function RefreshReadout()
    if not readoutFS then return end
    local db = GetDB()
    local r, g, b = ComputeExpectedRGB()
    local modeTag = db.useBlackSeparator
        and "|cFFFFAA55Mode: WITH separator|r (contrib V/2^(2N-1) — L5/L6 ≈ 0)"
        or  "|cFF99FF99Mode: original spec|r (contrib V/2^N)"
    readoutFS:SetText(string.format(
        "%s\n|cffaaaaaaExpected pixel (fully-on glyph cell): " ..
        "R=|r|cFFFF7777%d|r  |cffaaaaaaG=|r|cFF77FF77%d|r  " ..
        "|cffaaaaaaB=|r|cFF7777FF%d|r", modeTag, r, g, b))
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
    if not fs or not entry then return end

    local spec = LAYERS[idx]
    fs:SetFont(FONT_PATH, db.fontSize, "MONOCHROME")

    if entry.state == STATE_OFF then
        fs:SetText("")
        return
    end

    local V = STATE_V[entry.state] / 255
    local r, g, b = 0, 0, 0
    if     spec.channel == "R" then r = V
    elseif spec.channel == "G" then g = V
    elseif spec.channel == "B" then b = V end

    fs:SetTextColor(r, g, b, 128 / 255)
    fs:SetText(entry.text or "")
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

local function CreateStateRadio(parent, idx, stateKey)
    local cb = CreateFrame("CheckButton", nil, parent, "UIRadioButtonTemplate")
    cb:SetSize(16, 16)
    local lbl = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    lbl:SetText(STATE_LABEL[stateKey])
    cb._labelFS = lbl

    cb:SetScript("OnClick", function(self)
        local db = GetDB()
        db.layers[idx].state = stateKey

        -- Uncheck siblings in same row
        local row = stateRadios[idx]
        for s, btn in pairs(row) do
            btn:SetChecked(s == stateKey)
        end

        ApplyLayer(idx)
        RefreshReadout()
    end)

    return cb
end

local function CreateLayerRow(content, parent, anchorAbove, idx)
    local spec = LAYERS[idx]

    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(28)
    if anchorAbove then
        row:SetPoint("TOPLEFT",  anchorAbove, "BOTTOMLEFT",  0, -4)
        row:SetPoint("TOPRIGHT", anchorAbove, "BOTTOMRIGHT", 0, -4)
    else
        row:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, 0)
        row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    end

    -- Layer label
    local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameFS:SetPoint("LEFT", row, "LEFT", 0, 0)
    nameFS:SetWidth(160)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetText("|cFFFFD200" .. spec.label .. "|r")

    -- 3 radio buttons (Off / Light / Dark)
    stateRadios[idx] = {}
    local prev = nameFS
    for _, stateKey in ipairs(STATE_ORDER) do
        local cb = CreateStateRadio(row, idx, stateKey)
        if prev == nameFS then
            cb:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            cb:SetPoint("LEFT", prev, "RIGHT", 40, 0)
        end
        stateRadios[idx][stateKey] = cb
        prev = cb
    end

    -- Text EditBox
    local eb = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    eb:SetPoint("LEFT",  prev,  "RIGHT", 60, 0)
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
    if sizeSlider then sizeSlider:SetValue(db.fontSize) end
    if sizeValueFS then sizeValueFS:SetText(tostring(db.fontSize)) end
    if separatorCheckbox then
        separatorCheckbox:SetChecked(db.useBlackSeparator and true or false)
    end

    for _, l in ipairs(LAYERS) do
        local entry = db.layers[l.idx]
        local row = stateRadios[l.idx]
        if row then
            for s, btn in pairs(row) do
                btn:SetChecked(s == entry.state)
            end
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
            "GeRODPS Tools — Layered Alpha Text Test (6 layers, α=128/255)")
    end

    local content = frame.Inset or frame

    -- ── Canvas: black background, 6 stacked FontStrings ──
    canvas = CreateFrame("Frame", nil, content)
    canvas:SetSize(CANVAS_W, CANVAS_H)
    canvas:SetPoint("TOP", content, "TOP", 0, -10)

    local bg = canvas:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(canvas)
    bg:SetColorTexture(0, 0, 0, 1)

    -- Thin gray border
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

    -- The 6 FontStrings, all anchored TOPLEFT of canvas with same size.
    -- subLayer higher = drawn later = on top (matches §2 of the spec).
    layerFontStrings = {}
    for _, l in ipairs(LAYERS) do
        local fs = canvas:CreateFontString(nil, "OVERLAY")
        fs:SetDrawLayer("OVERLAY", l.subLayer)
        fs:SetPoint("TOPLEFT",     canvas, "TOPLEFT",      4,  -4)
        fs:SetPoint("BOTTOMRIGHT", canvas, "BOTTOMRIGHT", -4,   4)
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetFont(FONT_PATH, DEFAULT_SIZE, "MONOCHROME")
        fs:SetWordWrap(false)
        fs:SetNonSpaceWrap(false)
        layerFontStrings[l.idx] = fs
    end

    -- 5 black separator textures interleaved between the 6 colored layers.
    -- Each separator is (0, 0, 0) α=128/255 covering the whole canvas, so it
    -- halves whatever is below at EVERY pixel (regardless of glyph mask).
    -- Hidden by default; toggled by the "use separator" checkbox below.
    separatorTextures = {}
    for _, subLayer in ipairs(SEPARATOR_SUBLAYERS) do
        local sep = canvas:CreateTexture(nil, "OVERLAY")
        sep:SetDrawLayer("OVERLAY", subLayer)
        sep:SetPoint("TOPLEFT",     canvas, "TOPLEFT",      4,  -4)
        sep:SetPoint("BOTTOMRIGHT", canvas, "BOTTOMRIGHT", -4,   4)
        sep:SetColorTexture(0, 0, 0, 128 / 255)
        sep:Hide()
        separatorTextures[#separatorTextures + 1] = sep
    end

    -- ── Readout below canvas (2 lines: mode tag + expected RGB) ──
    readoutFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    readoutFS:SetPoint("TOPLEFT",  canvas, "BOTTOMLEFT",  0, -8)
    readoutFS:SetPoint("TOPRIGHT", canvas, "BOTTOMRIGHT", 0, -8)
    readoutFS:SetJustifyH("LEFT")
    readoutFS:SetJustifyV("TOP")
    readoutFS:SetText("")

    -- ── Separator-mode checkbox ──
    separatorCheckbox = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    separatorCheckbox:SetPoint("TOPLEFT", readoutFS, "BOTTOMLEFT", -4, -20)
    separatorCheckbox:SetSize(22, 22)
    local sepLbl = separatorCheckbox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sepLbl:SetPoint("LEFT", separatorCheckbox, "RIGHT", 2, 0)
    sepLbl:SetText(
        "Insert (0,0,0) α=128/255 separator between layers  " ..
        "|cFFFFAA55(experimental — breaks decode of L5/L6)|r")
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
    if _G[sizeSlider:GetName() and (sizeSlider:GetName() .. "Low")] then end
    -- The OptionsSliderTemplate ships its own Low/High/Text font strings via
    -- $parent suffix — we created the slider with no name, so we manually
    -- hide those if they exist. We use our own numeric readout instead.

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

    -- ── 6 layer control rows ──
    local rowsHost = CreateFrame("Frame", nil, content)
    rowsHost:SetPoint("TOPLEFT",  sizeRow, "BOTTOMLEFT",  0, -10)
    rowsHost:SetPoint("TOPRIGHT", sizeRow, "BOTTOMRIGHT", 0, -10)
    rowsHost:SetHeight(28 * #LAYERS + 4 * (#LAYERS - 1))

    local prevRow
    for _, l in ipairs(LAYERS) do
        prevRow = CreateLayerRow(content, rowsHost, prevRow, l.idx)
    end

    -- ── Reset button ──
    local resetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    resetBtn:SetSize(160, 22)
    resetBtn:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 14, 14)
    resetBtn:SetText("Reset (all Dark, '123456...')")
    resetBtn:SetScript("OnClick", function()
        local db = GetDB()
        db.fontSize          = DEFAULT_SIZE
        db.useBlackSeparator = false
        for _, l in ipairs(LAYERS) do
            db.layers[l.idx].state = STATE_DARK
            db.layers[l.idx].text  = "TEST123456"
        end
        SyncControlsFromDB()
        ApplyAllLayers()
    end)

    local hintFS = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintFS:SetPoint("LEFT", resetBtn, "RIGHT", 12, 0)
    hintFS:SetPoint("RIGHT", content, "RIGHT", -14, 0)
    hintFS:SetJustifyH("LEFT")
    hintFS:SetText(
        "ใส่ข้อความเดียวกันทุก layer = อ่าน decode ได้ที่ pixel กลาง glyph.  " ..
        "ต่างกัน = ดูได้ว่าบาง pixel จะ decode ผิดเพราะ glyph mask ไม่ตรง.")

    -- Center the size slider columns visually (Lua-side fix-up: position the
    -- canvas, readout, size row, rowsHost all anchored to content with
    -- explicit left padding so the layer rows align with the canvas).
    -- (Already handled above via TOPLEFT anchors.)

    table.insert(UISpecialFrames, FRAME_NAME)
    ApplySavedGeometry(frame)

    -- Initial state sync
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
    TOOL.RegisterTool("Test Layered Alpha Text (6 layers)",
                      TOOL.ToggleLayeredAlphaTextTest)
end
