--[[
    AlphaStackTest.lua

    เครื่องมือทดสอบการ blend ของ texture ที่มี alpha เมื่อซ้อนกัน 3 ชั้น
    บน background สีดำ alpha 1.

    Use case: ออกแบบ pixel ใหม่ที่ encode หลาย boolean flag (เช่น
    Casting / CanInterrupt / ImportantSpell) ลงในกองพิกเซลเดียวด้วยการ
    ซ้อน 3 texture สีต่างกันมี alpha ต่างกัน — ต้องการรู้ว่า WoW
    blend แล้วได้สีสุดท้ายเป็นอะไร เพื่อให้ AHK script อ่าน RGB กลับ
    ออกมาได้.

    UI:
      - Frame title: "ทดสอบการซ้อนของ Alpha"
      - Canvas สีดำ alpha 1
      - 3 สี่เหลี่ยมจัดเรียงเป็นรูปสามเหลี่ยม overlap กันบางส่วน
        (เลียนแบบ pattern ที่ user แสดงในรูป)
      - Z-order: Blue ล่าง → Green กลาง → Red บน
      - แต่ละสี่เหลี่ยมมี EditBox 4 ช่อง (R / G / B / A; 0..255)
        ปรับสีและ alpha ได้สด ๆ
      - Status row โชว์ค่าปัจจุบันของแต่ละสี่เหลี่ยม

    Default per user spec:
      Blue   (z=bottom): R=0   G=0   B=255 A=255   (1.00)  "Casting"
      Green  (z=middle): R=0   G=255 B=0   A=128   (0.50)  "Can Interrupt"
      Red    (z=top)   : R=255 G=0   B=0   A=128   (0.50)  "Important Spell"

    Public:
        GeRODPS_Tools.ToggleAlphaStackTest()
        GeRODPS_Tools.ShowAlphaStackTest()
        GeRODPS_Tools.HideAlphaStackTest()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME    = "GeRODPS_ToolsAlphaStackTestFrame"
local DEFAULT_W, DEFAULT_H = 620, 540
local MIN_W,     MIN_H     = 520, 460
local MAX_W,     MAX_H     = 1400, 1000
local SCREEN_MARGIN        = 100

-- Canvas geometry (drawn inside frame.Inset)
local CANVAS_W   = 320
local CANVAS_H   = 260
local RECT_SIZE  = 130

-- Each entry describes one of the 3 stacked test rectangles.
-- posOffset is from the canvas TOPLEFT (x positive = right, y negative = down).
-- zLevel: higher = drawn on top (Frame:SetFrameLevel).
local RECTS = {
    {
        key         = "blue",
        title       = "Blue (z=bottom)  default 'Casting'",
        defaultRGBA = { 0,   0,   255, 255 },
        zLevel      = 1,
        posOffset   = { 140,  -60 },   -- top-right area
    },
    {
        key         = "green",
        title       = "Green (z=middle) default 'Can Interrupt'",
        defaultRGBA = { 0,   255, 0,   128 },
        zLevel      = 2,
        posOffset   = {  80, -120 },   -- bottom-center
    },
    {
        key         = "red",
        title       = "Red   (z=top)    default 'Important Spell'",
        defaultRGBA = { 255, 0,   0,   128 },
        zLevel      = 3,
        posOffset   = {  40,  -20 },   -- top-left (shifted right +20 from 20→40)
    },
}

-- ============================================================
-- DB
-- ============================================================

local function CopyRGBA(t)
    return { t[1], t[2], t[3], t[4] }
end

local function GetDB()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    GeRODPS_ToolsDB.alphaStackTest = GeRODPS_ToolsDB.alphaStackTest or {}
    local db = GeRODPS_ToolsDB.alphaStackTest
    for _, r in ipairs(RECTS) do
        if type(db[r.key]) ~= "table" or #db[r.key] ~= 4 then
            db[r.key] = CopyRGBA(r.defaultRGBA)
        end
    end
    return db
end

local function ResetToDefaults()
    local db = GetDB()
    for _, r in ipairs(RECTS) do
        db[r.key] = CopyRGBA(r.defaultRGBA)
    end
end

-- ============================================================
-- State
-- ============================================================

local frame
local rectTextures = {}   -- [key] = Texture
local rectEditBoxes = {}  -- [key] = { r=EditBox, g=, b=, a= }
local rectReadouts  = {}  -- [key] = FontString

-- ============================================================
-- Geometry persistence + 100 px screen margin
-- ============================================================

local function SavePosition(self)
    local db = GetDB()
    local p, _, rp, x, y = self:GetPoint(1)
    db.point, db.relPoint, db.x, db.y = p, rp, x, y
end

local function SaveSize(self)
    local db = GetDB()
    db.w, db.h = self:GetWidth(), self:GetHeight()
end

local function ApplySavedGeometry(self)
    local db = GetDB()
    local screenW = UIParent:GetWidth()
    local screenH = UIParent:GetHeight()

    local w = db.w or DEFAULT_W
    local h = db.h or DEFAULT_H
    local maxW = screenW - 2 * SCREEN_MARGIN
    local maxH = screenH - 2 * SCREEN_MARGIN
    if w > maxW then w = maxW end
    if h > maxH then h = maxH end
    if w < MIN_W then w = MIN_W end
    if h < MIN_H then h = MIN_H end

    self:ClearAllPoints()
    if db.point and db.relPoint and db.x and db.y then
        self:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    else
        self:SetPoint("CENTER")
    end
    self:SetSize(w, h)

    local left, right = self:GetLeft(), self:GetRight()
    local bottom, top = self:GetBottom(), self:GetTop()
    if left and right and bottom and top then
        local dx, dy = 0, 0
        if left < SCREEN_MARGIN then
            dx = SCREEN_MARGIN - left
        elseif right > (screenW - SCREEN_MARGIN) then
            dx = (screenW - SCREEN_MARGIN) - right
        end
        if bottom < SCREEN_MARGIN then
            dy = SCREEN_MARGIN - bottom
        elseif top > (screenH - SCREEN_MARGIN) then
            dy = (screenH - SCREEN_MARGIN) - top
        end
        if dx ~= 0 or dy ~= 0 then
            local point, relTo, relPoint, x, y = self:GetPoint(1)
            self:ClearAllPoints()
            self:SetPoint(point, relTo or UIParent, relPoint, x + dx, y + dy)
        end
    end
end

-- ============================================================
-- Render helpers
-- ============================================================

local function ApplyRect(key)
    local db   = GetDB()
    local rgba = db[key]
    local tex  = rectTextures[key]
    if tex and rgba then
        tex:SetColorTexture(rgba[1] / 255, rgba[2] / 255, rgba[3] / 255, rgba[4] / 255)
    end
    if rectReadouts[key] and rgba then
        rectReadouts[key]:SetText(string.format(
            "R %d  G %d  B %d  A %d  (a=%.3f)",
            rgba[1], rgba[2], rgba[3], rgba[4], rgba[4] / 255))
    end
end

local function ApplyAllRects()
    for _, r in ipairs(RECTS) do ApplyRect(r.key) end
end

local function SyncEditBoxes()
    local db = GetDB()
    for _, r in ipairs(RECTS) do
        local box = rectEditBoxes[r.key]
        local rgba = db[r.key]
        if box and rgba then
            box.r:SetText(tostring(rgba[1]))
            box.g:SetText(tostring(rgba[2]))
            box.b:SetText(tostring(rgba[3]))
            box.a:SetText(tostring(rgba[4]))
        end
    end
end

-- ============================================================
-- Build helpers
-- ============================================================

local CHANNEL_IDX = { r = 1, g = 2, b = 3, a = 4 }

local function CreateChannelEditBox(parent, channelKey, rectKey)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(72, 22)

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("LEFT", row, "LEFT", 0, 0)
    lbl:SetText(string.upper(channelKey))

    local eb = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    eb:SetPoint("LEFT", lbl, "RIGHT", 4, 0)
    eb:SetSize(44, 22)
    eb:SetAutoFocus(false)
    eb:SetNumeric(true)
    eb:SetMaxLetters(3)
    eb:SetFontObject("ChatFontNormal")

    eb:SetScript("OnEnterPressed", function(self)
        local v = tonumber(self:GetText() or "") or 0
        if v < 0   then v = 0   end
        if v > 255 then v = 255 end
        self:SetText(tostring(v))
        GetDB()[rectKey][CHANNEL_IDX[channelKey]] = v
        ApplyRect(rectKey)
        self:ClearFocus()
    end)
    eb:SetScript("OnEscapePressed", function(self)
        self:SetText(tostring(GetDB()[rectKey][CHANNEL_IDX[channelKey]]))
        self:ClearFocus()
    end)

    return row, eb
end

-- ============================================================
-- Frame build
-- ============================================================

local function CreateAlphaStackTestFrame()
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

    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
    else
        frame:SetMinResize(MIN_W, MIN_H)
        frame:SetMaxResize(MAX_W, MAX_H)
    end

    local resize = CreateFrame("Button", nil, frame)
    resize:SetSize(16, 16)
    resize:SetPoint("BOTTOMRIGHT", -4, 4)
    resize:EnableMouse(true)
    resize:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    resize:SetPushedTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Down")
    resize:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            frame:StopMovingOrSizing()
            frame:StartSizing("BOTTOMRIGHT")
        end
    end)
    resize:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then
            frame:StopMovingOrSizing()
            SaveSize(frame)
        end
    end)

    if frame.TitleText then
        frame.TitleText:SetText("GeRODPS Tools — ทดสอบการซ้อนของ Alpha")
    end

    local content = frame.Inset or frame

    -- ── Canvas: black background + 3 stacked colored rectangles ──
    local canvas = CreateFrame("Frame", nil, content)
    canvas:SetSize(CANVAS_W, CANVAS_H)
    canvas:SetPoint("TOP", content, "TOP", 0, -14)

    -- Black background (alpha 1) covers entire canvas
    local bg = canvas:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(canvas)
    bg:SetColorTexture(0, 0, 0, 1)

    -- Thin white border to make the canvas visible at the edge
    local border = canvas:CreateTexture(nil, "BORDER")
    border:SetAllPoints(canvas)
    border:SetColorTexture(0, 0, 0, 0)   -- placeholder
    -- Draw border using 4 thin textures
    local function MakeEdge(anchor1, anchor2, sx, sy)
        local edge = canvas:CreateTexture(nil, "OVERLAY")
        edge:SetPoint(anchor1, canvas, anchor1, 0, 0)
        edge:SetPoint(anchor2, canvas, anchor2, 0, 0)
        edge:SetColorTexture(0.4, 0.4, 0.4, 1)
        if sx then edge:SetWidth(sx) end
        if sy then edge:SetHeight(sy) end
        return edge
    end
    MakeEdge("TOPLEFT",    "TOPRIGHT",    nil, 1)
    MakeEdge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    MakeEdge("TOPLEFT",    "BOTTOMLEFT",  1,   nil)
    MakeEdge("TOPRIGHT",   "BOTTOMRIGHT", 1,   nil)

    -- 3 test rectangles. Each is a child Frame with a single Texture so
    -- we can control draw order via SetFrameLevel (Texture-only on the
    -- canvas itself would all share the canvas layer).
    rectTextures = {}
    local canvasBaseLevel = canvas:GetFrameLevel()
    for _, r in ipairs(RECTS) do
        local rect = CreateFrame("Frame", nil, canvas)
        rect:SetSize(RECT_SIZE, RECT_SIZE)
        rect:SetPoint("TOPLEFT", canvas, "TOPLEFT", r.posOffset[1], r.posOffset[2])
        rect:SetFrameLevel(canvasBaseLevel + r.zLevel)

        local tex = rect:CreateTexture(nil, "ARTWORK")
        tex:SetAllPoints(rect)
        rectTextures[r.key] = tex
    end

    -- ── Control panel below canvas: one row per rectangle ──
    local panelTop = -(14 + CANVAS_H + 14)   -- gap below canvas

    rectEditBoxes = {}
    rectReadouts  = {}

    for i, r in ipairs(RECTS) do
        local rowY = panelTop - (i - 1) * 40

        -- Title row
        local titleFS = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        titleFS:SetPoint("TOPLEFT", content, "TOPLEFT", 14, rowY)
        titleFS:SetText("|cFFFFD200" .. r.title .. "|r")

        -- Readout to the right of the title
        local readout = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        readout:SetPoint("LEFT", titleFS, "RIGHT", 14, 0)
        rectReadouts[r.key] = readout

        -- 4 channel EditBoxes (R / G / B / A), 0..255
        local prevAnchor
        local boxes = {}
        for chIdx, ch in ipairs({ "r", "g", "b", "a" }) do
            local row, eb = CreateChannelEditBox(content, ch, r.key)
            if chIdx == 1 then
                row:SetPoint("TOPLEFT", titleFS, "BOTTOMLEFT", 0, -2)
            else
                row:SetPoint("LEFT", prevAnchor, "RIGHT", 6, 0)
            end
            boxes[ch] = eb
            prevAnchor = row
        end
        rectEditBoxes[r.key] = boxes
    end

    -- ── Reset button (bottom row) ──
    local resetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    resetBtn:SetSize(180, 22)
    resetBtn:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 14, 14)
    resetBtn:SetText("Reset to defaults")
    resetBtn:SetScript("OnClick", function()
        ResetToDefaults()
        SyncEditBoxes()
        ApplyAllRects()
    end)

    -- Info text on the right
    local infoFS = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    infoFS:SetPoint("LEFT", resetBtn, "RIGHT", 14, 0)
    infoFS:SetText("0..255 per channel; SetColorTexture receives ch/255")

    table.insert(UISpecialFrames, FRAME_NAME)
    ApplySavedGeometry(frame)
    SyncEditBoxes()
    ApplyAllRects()
    frame:Hide()
    return frame
end

-- ============================================================
-- Public API
-- ============================================================

function TOOL.ShowAlphaStackTest()
    local f = CreateAlphaStackTestFrame()
    if not f:IsShown() then
        ApplySavedGeometry(f)
        SyncEditBoxes()
        ApplyAllRects()
        f:Show()
    end
end

function TOOL.HideAlphaStackTest()
    if frame and frame:IsShown() then frame:Hide() end
end

function TOOL.ToggleAlphaStackTest()
    local f = CreateAlphaStackTestFrame()
    if f:IsShown() then
        f:Hide()
    else
        ApplySavedGeometry(f)
        SyncEditBoxes()
        ApplyAllRects()
        f:Show()
    end
end

if TOOL.RegisterTool then
    TOOL.RegisterTool("ทดสอบการซ้อนของ Alpha", TOOL.ToggleAlphaStackTest)
end
