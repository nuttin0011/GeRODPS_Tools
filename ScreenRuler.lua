-- ScreenRuler.lua
-- Draggable, resizable overlay rectangle — coords relative to UIParent (origin top-left)
--
-- ย้ายมาจาก addon GeRODPS เมื่อ 2026-08-18 — เป็นเครื่องมือวัดพิกเซล ไม่มี
-- ส่วนไหนเกี่ยวกับ runtime ของ addon หลัก (ไฟล์ self-contained ทั้งก้อน)
-- เปิดจากเมนู minimap ของ GeRODPS Tools

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local GRIP   = 8
local MIN_W  = 80
local MIN_H  = 70
local useScale = false   -- checkbox: multiply coordinates by UI→pixel scale

-- ============================================================
-- Main Frame
-- ============================================================
local frame = CreateFrame("Frame", "GeRODPS_ScreenRuler", UIParent, "BackdropTemplate")
frame:SetSize(300, 200)
frame:SetPoint("CENTER")
frame:SetFrameStrata("HIGH")
frame:SetFrameLevel(100)
frame:SetMovable(true)
frame:SetResizable(true)
frame:SetResizeBounds(MIN_W, MIN_H)
frame:SetClampedToScreen(false)   -- we clamp manually to UIParent
frame:EnableMouse(true)
frame:Hide()

frame:SetBackdrop({
    bgFile   = "Interface\\BUTTONS\\WHITE8x8",
    edgeFile = "Interface\\BUTTONS\\WHITE8x8",
    edgeSize = 1,
})
frame:SetBackdropColor(0.3, 0.7, 1.0, 0.5)
frame:SetBackdropBorderColor(1, 1, 1, 0.7)

-- ============================================================
-- Corner markers (visual resize hint)
-- ============================================================
local function MakeCornerMark(point)
    local t = frame:CreateTexture(nil, "ARTWORK")
    t:SetSize(6, 6)
    t:SetColorTexture(1, 1, 1, 0.9)
    t:SetPoint(point, frame, point)
end
MakeCornerMark("TOPLEFT")
MakeCornerMark("TOPRIGHT")
MakeCornerMark("BOTTOMLEFT")
MakeCornerMark("BOTTOMRIGHT")

-- ============================================================
-- Coordinate FontStrings
-- ============================================================
local topLeftText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
topLeftText:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -10)
topLeftText:SetJustifyH("LEFT")
topLeftText:SetTextColor(1, 1, 1, 1)

local topRightText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
topRightText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -10)
topRightText:SetJustifyH("RIGHT")
topRightText:SetTextColor(1, 1, 1, 1)

local bottomLeftText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
bottomLeftText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 10)
bottomLeftText:SetJustifyH("LEFT")
bottomLeftText:SetTextColor(1, 1, 1, 1)

local bottomRightText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
bottomRightText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 10)
bottomRightText:SetJustifyH("RIGHT")
bottomRightText:SetTextColor(1, 1, 1, 1)

local centerText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
centerText:SetPoint("CENTER", frame, "CENTER", 0, 10)
centerText:SetTextColor(1, 1, 0, 1)

-- ============================================================
-- Scale Checkbox (bottom-center, above bottom-corner texts)
-- ============================================================
local scaleCheck = CreateFrame(
    "CheckButton", "GeRODPS_ScreenRulerScaleCheck", frame, "UICheckButtonTemplate")
scaleCheck:SetSize(18, 18)
scaleCheck:SetPoint("BOTTOM", frame, "BOTTOM", -20, 28)
scaleCheck:SetChecked(useScale)

local scaleLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
scaleLabel:SetPoint("LEFT", scaleCheck, "RIGHT", 2, 0)
scaleLabel:SetText("|cFFFFFFFFScale|r")
scaleLabel:SetTextColor(1, 1, 1, 1)

-- ============================================================
-- Clamp frame so no edge exceeds UIParent bounds
-- ============================================================
local function ClampToUIParent()
    local uL = UIParent:GetLeft()   or 0
    local uB = UIParent:GetBottom() or 0
    local uR = UIParent:GetRight()  or GetScreenWidth()
    local uT = UIParent:GetTop()    or GetScreenHeight()

    local fL = frame:GetLeft()
    local fB = frame:GetBottom()
    if not (fL and fB) then return end

    local w = frame:GetWidth()
    local h = frame:GetHeight()

    -- clamp size first
    local maxW = uR - uL
    local maxH = uT - uB
    if w > maxW then w = maxW ; frame:SetWidth(w)  end
    if h > maxH then h = maxH ; frame:SetHeight(h) end

    -- clamp position (BOTTOMLEFT anchor)
    local newL = math.max(uL, math.min(fL, uR - w))
    local newB = math.max(uB, math.min(fB, uT - h))

    if math.abs(newL - fL) > 0.5 or math.abs(newB - fB) > 0.5 then
        frame:ClearAllPoints()
        frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", newL - uL, newB - uB)
    end
end

-- ============================================================
-- Update coordinates (relative to UIParent, origin = top-left)
-- ============================================================
local function UpdateCoordinates()
    local fL = frame:GetLeft()
    local fR = frame:GetRight()
    local fT = frame:GetTop()
    local fB = frame:GetBottom()
    if not (fL and fR and fT and fB) then return end

    local uL = UIParent:GetLeft()  or 0
    local uT = UIParent:GetTop()   or GetScreenHeight()

    local scale = 1.0
    if useScale then
        local _, physH = GetPhysicalScreenSize()
        scale = physH / GetScreenHeight()
    end

    -- convert: origin shifts to UIParent top-left, Y flips
    local pxL = math.floor((fL - uL) * scale + 0.5)
    local pxR = math.floor((fR - uL) * scale + 0.5)
    local pxT = math.floor((uT - fT) * scale + 0.5)
    local pxB = math.floor((uT - fB) * scale + 0.5)

    topLeftText:SetText(format("(%d, %d)", pxL, pxT))
    topRightText:SetText(format("(%d, %d)", pxR, pxT))
    bottomLeftText:SetText(format("(%d, %d)", pxL, pxB))
    bottomRightText:SetText(format("(%d, %d)", pxR, pxB))
    centerText:SetText(format("W: %d   H: %d", pxR - pxL, pxB - pxT))
end

scaleCheck:SetScript("OnClick", function(self)
    useScale = self:GetChecked() and true or false
    UpdateCoordinates()
end)

-- ============================================================
-- Drag to move
-- ============================================================
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self)
    self:StartMoving()
    self:SetScript("OnUpdate", UpdateCoordinates)
end)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetScript("OnUpdate", nil)
    ClampToUIParent()
    UpdateCoordinates()
end)

-- ============================================================
-- Resize grips (4 corners + 4 edges)
-- ============================================================
local function CreateGrip(dir)
    local g = CreateFrame("Frame", nil, frame)
    g:EnableMouse(true)
    g:RegisterForDrag("LeftButton")
    g:SetFrameLevel(frame:GetFrameLevel() + 5)

    local isH = (dir == "TOP" or dir == "BOTTOM")
    local isV = (dir == "LEFT" or dir == "RIGHT")

    if isH then
        g:SetHeight(GRIP)
        g:SetPoint(dir .. "LEFT",  frame, dir .. "LEFT",  GRIP, 0)
        g:SetPoint(dir .. "RIGHT", frame, dir .. "RIGHT", -GRIP, 0)
    elseif isV then
        g:SetWidth(GRIP)
        local tPt = (dir == "LEFT") and "TOPLEFT"    or "TOPRIGHT"
        local bPt = (dir == "LEFT") and "BOTTOMLEFT" or "BOTTOMRIGHT"
        g:SetPoint(tPt, frame, tPt, 0, -GRIP)
        g:SetPoint(bPt, frame, bPt, 0,  GRIP)
    else
        g:SetSize(GRIP, GRIP)
        g:SetPoint(dir, frame, dir)
    end

    g:SetScript("OnDragStart", function()
        frame:StartSizing(dir)
        frame:SetScript("OnUpdate", UpdateCoordinates)
    end)
    g:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        frame:SetScript("OnUpdate", nil)
        ClampToUIParent()
        UpdateCoordinates()
    end)
end

local gripDirs = {
    "TOPLEFT", "TOP", "TOPRIGHT",
    "LEFT",           "RIGHT",
    "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT",
}
for _, dir in ipairs(gripDirs) do
    CreateGrip(dir)
end

frame:SetScript("OnSizeChanged", UpdateCoordinates)
frame:SetScript("OnShow", function()
    ClampToUIParent()
    UpdateCoordinates()
end)

-- Right-click to hide
frame:SetScript("OnMouseDown", function(self, btn)
    if btn == "RightButton" then self:Hide() end
end)

-- ============================================================
-- Public toggle
-- ============================================================
local function ToggleRuler()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end

TOOL.ScreenRuler = { Toggle = ToggleRuler }
TOOL.RegisterTool("Screen Ruler", ToggleRuler)
