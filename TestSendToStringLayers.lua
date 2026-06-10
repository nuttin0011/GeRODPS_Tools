--[[
    TestSendToStringLayers.lua

    Override the 9 SendToString layers from a UI for AHK end-to-end
    verification (measured-model alpha stack, 2026-06-10).

    Each row controls ONE layer of the 9-layer SendToString channel
    (ชุดสีต้องตรงกับ GeRODPS/PixelAndBarSetup.lua LAYER_BUILD):
        L1 (top, B2) | L2 G38 | L3 G4 | L4 R46 | L5 R222 | L6 R62 |
        L7 B124 | L8 G252 | L9 (bottom, R255 alpha 1)

    Per-row controls:
      [On/Off checkbox]  [EditBox text]   <NN chars>
        On  → calls GeRODPS.SendToString.SetLayerOverride(L, text) live.
        Off → calls GeRODPS.SendToString.ClearLayerOverride(L) live.

    Closing the frame automatically clears every override so normal
    exporter behavior resumes. Re-opening restores the saved override
    set from SavedVariables.

    Pair with Test_ReadString.ahk to confirm each layer round-trips
    through alpha-blended pixels back to the AHK decoder correctly.

    Public:
      GeRODPS_Tools.ToggleTestSendToStringLayers()
      GeRODPS_Tools.ShowTestSendToStringLayers()
      GeRODPS_Tools.HideTestSendToStringLayers()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME    = "GeRODPS_ToolsTestSendToStringLayersFrame"
local DEFAULT_W     = 600
local DEFAULT_H     = 440
local SCREEN_MARGIN = 100

-- ต้อง sync กับ GeRODPS/SendToString.lua LAYER_COUNT + PixelAndBarSetup.lua
-- LAYER_BUILD (9-layer measured-model stack)
local LAYER_COUNT = 9

local LAYER_LABELS = {
    [1] = "L1  B2    (top)",
    [2] = "L2  G38",
    [3] = "L3  G4",
    [4] = "L4  R46",
    [5] = "L5  R222",
    [6] = "L6  R62",
    [7] = "L7  B124",
    [8] = "L8  G252",
    [9] = "L9  R255 a1 (bottom)",
}

local DEFAULT_TEXTS = {}
for i = 1, LAYER_COUNT do
    DEFAULT_TEXTS[i] = ("$layer%d$test%d%%"):format(i, i)
end

-- ============================================================
-- DB
-- ============================================================

local function GetDB()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    local db = GeRODPS_ToolsDB.testSendToStringLayers or {}
    GeRODPS_ToolsDB.testSendToStringLayers = db
    if db.exporterPaused == nil then db.exporterPaused = false end
    db.layers = db.layers or {}
    for i = 1, LAYER_COUNT do
        local entry = db.layers[i] or {}
        if entry.enabled == nil then entry.enabled = false           end
        if entry.text    == nil then entry.text    = DEFAULT_TEXTS[i] end
        db.layers[i] = entry
    end
    return db
end

-- ============================================================
-- State / API calls into GeRODPS
-- ============================================================

local frame
local rowCheckboxes = {}   -- [L] = CheckButton
local rowEditBoxes  = {}   -- [L] = EditBox
local rowCounters   = {}   -- [L] = FontString
local lblBackend                       -- warning when GeRODPS not loaded
local pauseCheckbox                    -- exporter-pause toggle

local function HasOverrideAPI()
    return type(_G.GeRODPS) == "table"
       and type(_G.GeRODPS.SendToString) == "table"
       and type(_G.GeRODPS.SendToString.SetLayerOverride)   == "function"
       and type(_G.GeRODPS.SendToString.ClearLayerOverride) == "function"
       and type(_G.GeRODPS.SendToString.ClearAllOverrides)  == "function"
end

local function HasPauseAPI()
    return type(_G.GeRODPS) == "table"
       and type(_G.GeRODPS.SendToString) == "table"
       and type(_G.GeRODPS.SendToString.SetExporterPaused) == "function"
end

local function ApplyPauseFromDB()
    if not HasPauseAPI() then return end
    local db = GetDB()
    _G.GeRODPS.SendToString.SetExporterPaused(db.exporterPaused and true or false)
end

local function ApplyRow(idx)
    local db = GetDB()
    local entry = db.layers[idx]
    if not HasOverrideAPI() then return end
    if entry.enabled then
        _G.GeRODPS.SendToString.SetLayerOverride(idx, entry.text or "")
    else
        _G.GeRODPS.SendToString.ClearLayerOverride(idx)
    end
end

local function ApplyAllRows()
    for i = 1, LAYER_COUNT do ApplyRow(i) end
end

local function ClearAllLive()
    if HasOverrideAPI() then
        _G.GeRODPS.SendToString.ClearAllOverrides()
    end
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
-- Row builder
-- ============================================================

local function UpdateCounter(idx)
    local fs = rowCounters[idx]
    local eb = rowEditBoxes[idx]
    if fs and eb then
        local t = eb:GetText() or ""
        fs:SetText(string.format("|cFFAAAAAA%d chars|r", #t))
    end
end

local function CreateLayerRow(parent, anchorAbove, idx)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(26)
    if anchorAbove then
        row:SetPoint("TOPLEFT",  anchorAbove, "BOTTOMLEFT",  0, -4)
        row:SetPoint("TOPRIGHT", anchorAbove, "BOTTOMRIGHT", 0, -4)
    else
        row:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, 0)
        row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
    end

    -- On/Off checkbox
    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("LEFT", row, "LEFT", 0, 0)
    cb:SetScript("OnClick", function(self)
        local db = GetDB()
        db.layers[idx].enabled = self:GetChecked() and true or false
        ApplyRow(idx)
    end)
    rowCheckboxes[idx] = cb

    -- Layer label
    local nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameFS:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    nameFS:SetWidth(150)
    nameFS:SetJustifyH("LEFT")
    nameFS:SetText("|cFFFFD200" .. LAYER_LABELS[idx] .. "|r")

    -- Char counter (right side, small)
    local counter = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    counter:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    counter:SetWidth(70)
    counter:SetJustifyH("RIGHT")
    counter:SetText("")
    rowCounters[idx] = counter

    -- Text EditBox
    local eb = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    eb:SetPoint("LEFT",  nameFS,  "RIGHT", 6, 0)
    eb:SetPoint("RIGHT", counter, "LEFT",  -6, 0)
    eb:SetHeight(20)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(256)
    eb:SetFontObject("ChatFontNormal")
    eb:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        local db = GetDB()
        db.layers[idx].text = self:GetText() or ""
        UpdateCounter(idx)
        ApplyRow(idx)
    end)
    eb:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    eb:SetScript("OnEscapePressed", function(self)
        local db = GetDB()
        self:SetText(db.layers[idx].text or "")
        self:ClearFocus()
    end)
    rowEditBoxes[idx] = eb

    return row
end

local function SyncControlsFromDB()
    local db = GetDB()
    if pauseCheckbox then
        pauseCheckbox:SetChecked(db.exporterPaused and true or false)
    end
    for i = 1, LAYER_COUNT do
        local entry = db.layers[i]
        if rowCheckboxes[i] then
            rowCheckboxes[i]:SetChecked(entry.enabled and true or false)
        end
        if rowEditBoxes[i] then
            rowEditBoxes[i]:SetText(entry.text or "")
        end
        UpdateCounter(i)
    end
    if lblBackend then
        if HasOverrideAPI() then
            lblBackend:SetText("")
        else
            lblBackend:SetText(
                "|cffff6666⚠ GeRODPS.SendToString.SetLayerOverride " ..
                "not found — load main GeRODPS addon and /reload|r")
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
            "GeRODPS Tools — Test SendToString Layers (9-layer override)")
    end

    local content = frame.Inset or frame

    -- Header description
    local headerFS = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    headerFS:SetPoint("TOPLEFT",  content, "TOPLEFT",  14, -10)
    headerFS:SetPoint("TOPRIGHT", content, "TOPRIGHT", -14, -10)
    headerFS:SetJustifyH("LEFT")
    headerFS:SetText(
        "Tick a layer to override its text. Typing applies immediately. " ..
        "Closing this window clears every override and resumes the tick.")

    -- Pause-exporter checkbox: when ticked, UpdateSendToStringTick is
    -- skipped so overrides remain visible without the normal exporter
    -- repainting layers each tick.
    pauseCheckbox = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    pauseCheckbox:SetSize(22, 22)
    pauseCheckbox:SetPoint("TOPLEFT", headerFS, "BOTTOMLEFT", 0, -4)
    local pauseLbl = pauseCheckbox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pauseLbl:SetPoint("LEFT", pauseCheckbox, "RIGHT", 2, 0)
    pauseLbl:SetText(
        "|cFFFFD200Pause normal exporter tick|r " ..
        "|cFFAAAAAA(stop UpdateSendToStringTick from repainting layers)|r")
    pauseCheckbox:SetScript("OnClick", function(self)
        local db = GetDB()
        db.exporterPaused = self:GetChecked() and true or false
        if HasPauseAPI() then
            _G.GeRODPS.SendToString.SetExporterPaused(db.exporterPaused)
        end
    end)

    -- Layer rows (1 แถวต่อ layer)
    local rowsHost = CreateFrame("Frame", nil, content)
    rowsHost:SetPoint("TOPLEFT",  pauseCheckbox, "BOTTOMLEFT",  0, -8)
    rowsHost:SetPoint("RIGHT",    content,       "RIGHT",      -14, 0)
    rowsHost:SetHeight(26 * LAYER_COUNT + 4 * (LAYER_COUNT - 1))

    local prevRow
    for i = 1, LAYER_COUNT do
        prevRow = CreateLayerRow(rowsHost, prevRow, i)
    end

    -- Buttons row
    local btnClear = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    btnClear:SetSize(160, 22)
    btnClear:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 14, 14)
    btnClear:SetText("Clear All Overrides")
    btnClear:SetScript("OnClick", function()
        local db = GetDB()
        for i = 1, LAYER_COUNT do
            db.layers[i].enabled = false
        end
        ClearAllLive()
        SyncControlsFromDB()
    end)

    local btnDefaults = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    btnDefaults:SetSize(160, 22)
    btnDefaults:SetPoint("LEFT", btnClear, "RIGHT", 8, 0)
    btnDefaults:SetText("Reset Texts to Defaults")
    btnDefaults:SetScript("OnClick", function()
        local db = GetDB()
        for i = 1, LAYER_COUNT do
            db.layers[i].text = DEFAULT_TEXTS[i]
        end
        SyncControlsFromDB()
        ApplyAllRows()
    end)

    -- Verify: print Lua-side state to chat so user can confirm whether
    -- the override API is actually receiving the calls.
    local btnVerify = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    btnVerify:SetSize(120, 22)
    btnVerify:SetPoint("LEFT", btnDefaults, "RIGHT", 8, 0)
    btnVerify:SetText("Verify (print)")
    btnVerify:SetScript("OnClick", function()
        if not HasOverrideAPI() then
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffff4444[SendToStringLayers]|r Override API not found.")
            return
        end
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff66ccff[SendToStringLayers]|r --- Override state ---")
        for i = 1, LAYER_COUNT do
            local v = _G.GeRODPS.SendToString.GetLayerOverride(i)
            local layers = _G.GeRODPS.TextSendToAHKLayers
            local fs = layers and layers[i]
            local fsText = fs and fs:GetText() or "(no FontString)"
            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                "  L%d  override=%s  fs.text=%s",
                i,
                v == nil and "|cffaaaaaaNIL|r"
                          or string.format("|cff99ff99'%s'|r", tostring(v)),
                fsText))
        end
    end)

    -- Backend warning line
    lblBackend = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lblBackend:SetPoint("BOTTOMLEFT",  content, "BOTTOMLEFT",  14, 42)
    lblBackend:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -14, 42)
    lblBackend:SetJustifyH("LEFT")
    lblBackend:SetText("")

    -- Show / Hide hooks
    frame:SetScript("OnShow", function()
        SyncControlsFromDB()
        ApplyAllRows()
        ApplyPauseFromDB()
    end)
    frame:SetScript("OnHide", function()
        -- Always clear overrides AND resume the exporter on close so the
        -- main addon returns to normal behavior even if the user left
        -- pause enabled.
        ClearAllLive()
        if HasPauseAPI() then
            _G.GeRODPS.SendToString.SetExporterPaused(false)
        end
    end)

    table.insert(UISpecialFrames, FRAME_NAME)
    ApplySavedGeometry(frame)
    frame:Hide()
    return frame
end

-- ============================================================
-- Public API
-- ============================================================

function TOOL.ShowTestSendToStringLayers()
    local f = CreateTestFrame()
    if not f:IsShown() then
        ApplySavedGeometry(f)
        f:Show()
    end
end

function TOOL.HideTestSendToStringLayers()
    if frame and frame:IsShown() then frame:Hide() end
end

function TOOL.ToggleTestSendToStringLayers()
    local f = CreateTestFrame()
    if f:IsShown() then
        f:Hide()
    else
        ApplySavedGeometry(f)
        f:Show()
    end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("Test SendToString Layers (9-layer override)",
                      TOOL.ToggleTestSendToStringLayers)
end
