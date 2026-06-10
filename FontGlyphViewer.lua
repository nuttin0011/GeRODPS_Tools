--[[
    FontGlyphViewer.lua

    Visual inspector for Unicode glyph coverage in WoW fonts. Renders every
    glyph from GeRODPS_Tools.FontGlyphCatalog (812 glyphs across 15 Unicode
    ranges) so the user can eyeball which ones render correctly vs render
    as tofu (□ replacement square) in each WoW font template.

    Two dropdowns:
        • Category — pick one of the 15 Unicode ranges to view
        • Font     — swap the glyph column's FontObject; the codepoint and
                     name columns stay on a fixed font so they're always
                     readable for comparison

    Each row:   [glyph]   U+XXXX   ENGLISH NAME

    Trigger: Minimap (GeRODPS Tools) -> "Font Glyph Viewer"

    Companion to wow-coding skill Rule 5 (no Unicode glyphs in rendered
    text). Use this tool when adding a new font / template to confirm
    which glyph ranges are safe to ship.
]]

GeRODPS_Tools = GeRODPS_Tools or {}

-- ============================================================
-- Constants
-- ============================================================

local FRAME_W       = 760
local FRAME_H       = 660
local ROW_HEIGHT    = 24
local HEADER_HEIGHT = 130   -- bumped to accommodate filter dropdown row
local SIDE_PAD      = 14

-- Font choices for the GLYPH column. Codepoint + name columns stay on
-- GameFontHighlight so the comparison is always legible.
-- Each entry: { displayLabel, fontObjectReference }
local FONT_CHOICES = {
    { "GameFontHighlight (Friz QT 10) [default]", GameFontHighlight },
    { "GameFontHighlightSmall (Friz QT 10)",       GameFontHighlightSmall },
    { "GameFontHighlightLarge (Friz QT 14)",       GameFontHighlightLarge },
    { "GameFontHighlightHuge (Friz QT 20)",        GameFontHighlightHuge },
    { "GameFontNormal (Friz QT 10)",               GameFontNormal },
    { "GameFontNormalLarge (Friz QT 14)",          GameFontNormalLarge },
    { "GameFontNormalHuge (Friz QT 20)",           GameFontNormalHuge },
    { "NumberFontNormal (Number 14)",              NumberFontNormal },
    { "NumberFontNormalLarge (Number 16)",         NumberFontNormalLarge },
    { "ChatFontNormal (Arial Narrow 14)",          ChatFontNormal },
    { "SystemFont_Med1 (Friz QT 12)",              SystemFont_Med1 },
    { "SystemFont_Large (Friz QT 16)",             SystemFont_Large },
    { "SystemFont_Huge1 (Friz QT 20)",             SystemFont_Huge1 },
    { "Game18Font (Friz QT 18)",                   Game18Font },
    { "Game24Font (Friz QT 24)",                   Game24Font },
    { "Game32Font (Friz QT 32)",                   Game32Font },
}

-- ============================================================
-- Module state
-- ============================================================

local toolFrame
local categoryDropdown, fontDropdown, filterDropdown
local infoFS, rangeFS, notesFS, hdrFS
local scrollFrame, contentFrame
local rowPool = {}             -- reusable row containers
local currentCatIdx = 1
local currentFontObj = GameFontHighlight
local currentFilter = "all"    -- "all" | "supported" | "missing"

-- Resolve the codepoint-supported lookup. All 4 .ttf files in WoW/Fonts are
-- byte-identical (md5 confirmed via fontTools), so any entry works — use [1].
local function GetSupportedSet()
    local cov = GeRODPS_Tools.FontGlyphCoverage
    if not (cov and cov[1] and cov[1].supported) then return nil end
    return cov[1].supported
end

-- Parse "U+25B2" -> 0x25B2 (number). Returns nil on bad input.
local function ParseCodepoint(cpStr)
    if type(cpStr) ~= "string" then return nil end
    local hex = cpStr:match("^U%+(%x+)$")
    if not hex then return nil end
    return tonumber(hex, 16)
end

-- ============================================================
-- Row management
-- ============================================================

local function GetOrCreateRow(i)
    local row = rowPool[i]
    if row then return row end

    local container = CreateFrame("Frame", nil, contentFrame)
    container:SetSize(FRAME_W - SIDE_PAD * 2 - 22, ROW_HEIGHT)

    -- Coverage marker column (✓ green / x red — both ASCII-safe)
    local covFS = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    covFS:SetPoint("LEFT", container, "LEFT", 6, 0)
    covFS:SetJustifyH("CENTER")
    covFS:SetWidth(28)

    -- Glyph column (font swappable)
    local glyphFS = container:CreateFontString(nil, "OVERLAY")
    glyphFS:SetFontObject(currentFontObj)
    glyphFS:SetPoint("LEFT", covFS, "RIGHT", 4, 0)
    glyphFS:SetJustifyH("CENTER")
    glyphFS:SetWidth(60)

    -- Codepoint column (fixed font)
    local cpFS = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cpFS:SetPoint("LEFT", glyphFS, "RIGHT", 8, 0)
    cpFS:SetJustifyH("LEFT")
    cpFS:SetWidth(80)
    cpFS:SetTextColor(0.9, 0.85, 0.4)

    -- Name column (fixed font, left-justified, takes the rest)
    local nameFS = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    nameFS:SetPoint("LEFT", cpFS, "RIGHT", 8, 0)
    nameFS:SetPoint("RIGHT", container, "RIGHT", -6, 0)
    nameFS:SetJustifyH("LEFT")

    row = {
        container = container,
        covFS = covFS, glyphFS = glyphFS, cpFS = cpFS, nameFS = nameFS,
    }
    rowPool[i] = row
    return row
end

local function ReleaseRowsFrom(startIdx)
    for i = startIdx, #rowPool do
        if rowPool[i] then
            rowPool[i].container:Hide()
        end
    end
end

-- Re-skin every visible row's glyph FontString to the current font.
-- Called when fontDropdown changes selection.
local function ApplyGlyphFont()
    for _, row in ipairs(rowPool) do
        if row.container:IsShown() then
            row.glyphFS:SetFontObject(currentFontObj)
        end
    end
end

-- ============================================================
-- Render selected category
-- ============================================================

local function RenderCategory()
    local catalog = GeRODPS_Tools.FontGlyphCatalog
    if not catalog then
        infoFS:SetText("|cFFFF5555FontGlyphCatalog data not loaded.|r")
        return
    end

    local cat = catalog[currentCatIdx]
    if not cat then
        infoFS:SetText("|cFFFF5555Invalid category index.|r")
        return
    end

    local supported = GetSupportedSet()

    -- Filter entries based on current filter setting
    local visibleEntries = {}
    local supCount, totCount = 0, #cat.entries
    for _, e in ipairs(cat.entries) do
        local cp = ParseCodepoint(e[2])
        local isSup = supported and cp and supported[cp] or false
        if isSup then supCount = supCount + 1 end
        local include = (currentFilter == "all")
                     or (currentFilter == "supported" and isSup)
                     or (currentFilter == "missing"   and not isSup)
        if include then
            visibleEntries[#visibleEntries + 1] = { e, isSup }
        end
    end

    infoFS:SetText(string.format(
        "|cFFFFCC00%s|r  -  |cFF66FF66%d|r / %d supported  |cFF888888(showing %d)|r",
        cat.title, supCount, totCount, #visibleEntries))
    rangeFS:SetText(cat.unicodeRange or "")
    notesFS:SetText(cat.notes or "")

    local total = #visibleEntries
    contentFrame:SetHeight(total * ROW_HEIGHT + 6)

    for i, pair in ipairs(visibleEntries) do
        local e, isSup = pair[1], pair[2]
        local row = GetOrCreateRow(i)
        row.container:ClearAllPoints()
        row.container:SetPoint("TOPLEFT", contentFrame, "TOPLEFT",
            0, -(i - 1) * ROW_HEIGHT)
        row.container:Show()
        if isSup then
            row.covFS:SetText("|cFF66FF66OK|r")
        else
            row.covFS:SetText("|cFFFF5555x|r")
        end
        row.glyphFS:SetFontObject(currentFontObj)
        row.glyphFS:SetText(e[1])      -- glyph
        row.cpFS:SetText(e[2])         -- codepoint
        row.nameFS:SetText(e[3])       -- name
    end

    ReleaseRowsFrom(total + 1)

    if scrollFrame then
        scrollFrame:SetVerticalScroll(0)
    end
end

-- ============================================================
-- Frame build
-- ============================================================

local function BuildFrame()
    if toolFrame then return end

    toolFrame = CreateFrame("Frame", "GeRODPS_Tools_FontGlyphViewerFrame",
        UIParent, "BasicFrameTemplateWithInset")
    toolFrame:SetSize(FRAME_W, FRAME_H)
    toolFrame:SetPoint("CENTER")
    toolFrame:SetMovable(true)
    toolFrame:EnableMouse(true)
    toolFrame:RegisterForDrag("LeftButton")
    toolFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    toolFrame:SetScript("OnDragStop",  function(self) self:StopMovingOrSizing() end)
    toolFrame:SetClampedToScreen(true)
    toolFrame:SetFrameStrata("DIALOG")
    if toolFrame.TitleText then
        toolFrame.TitleText:SetText("GeRODPS Tools - Font Glyph Viewer")
    end

    local inset = toolFrame.Inset or toolFrame

    -- ── Row 1: Category dropdown ──
    local catLabel = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    catLabel:SetPoint("TOPLEFT", inset, "TOPLEFT", SIDE_PAD, -8)
    catLabel:SetText("Category:")

    categoryDropdown = CreateFrame("DropdownButton", nil, inset,
        "WowStyle1DropdownTemplate")
    categoryDropdown:SetPoint("LEFT", catLabel, "RIGHT", 6, -2)
    categoryDropdown:SetWidth(260)
    categoryDropdown:SetupMenu(function(_, rootDescription)
        local catalog = GeRODPS_Tools.FontGlyphCatalog or {}
        for i, cat in ipairs(catalog) do
            local label = string.format("%s (%d)", cat.title, #cat.entries)
            rootDescription:CreateRadio(label,
                function() return currentCatIdx == i end,
                function()
                    currentCatIdx = i
                    categoryDropdown:SetDefaultText(label)
                    RenderCategory()
                    return MenuResponse.CloseAll
                end)
        end
    end)

    infoFS = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    infoFS:SetPoint("LEFT", categoryDropdown, "RIGHT", 12, 2)
    infoFS:SetJustifyH("LEFT")

    -- ── Row 2: Font dropdown ──
    local fontLabel = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fontLabel:SetPoint("TOPLEFT", catLabel, "BOTTOMLEFT", 0, -10)
    fontLabel:SetText("Glyph font:")

    fontDropdown = CreateFrame("DropdownButton", nil, inset,
        "WowStyle1DropdownTemplate")
    fontDropdown:SetPoint("LEFT", fontLabel, "RIGHT", 6, -2)
    fontDropdown:SetWidth(310)
    fontDropdown:SetupMenu(function(_, rootDescription)
        for i, choice in ipairs(FONT_CHOICES) do
            local label, fontObj = choice[1], choice[2]
            rootDescription:CreateRadio(label,
                function() return currentFontObj == fontObj end,
                function()
                    currentFontObj = fontObj
                    fontDropdown:SetDefaultText(label)
                    ApplyGlyphFont()
                    return MenuResponse.CloseAll
                end)
        end
    end)

    rangeFS = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rangeFS:SetPoint("LEFT", fontDropdown, "RIGHT", 12, 2)
    rangeFS:SetJustifyH("LEFT")
    rangeFS:SetTextColor(0.7, 0.85, 1)

    -- ── Filter dropdown ──
    local filterLabel = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    filterLabel:SetPoint("TOPLEFT", fontLabel, "BOTTOMLEFT", 0, -10)
    filterLabel:SetText("Filter:")

    local FILTER_CHOICES = {
        { "all",       "All glyphs" },
        { "supported", "Supported only (renders correctly)" },
        { "missing",   "Missing only (renders as tofu)" },
    }
    filterDropdown = CreateFrame("DropdownButton", nil, inset,
        "WowStyle1DropdownTemplate")
    filterDropdown:SetPoint("LEFT", filterLabel, "RIGHT", 6, -2)
    filterDropdown:SetWidth(260)
    filterDropdown:SetDefaultText(FILTER_CHOICES[1][2])
    filterDropdown:SetupMenu(function(_, rootDescription)
        for _, choice in ipairs(FILTER_CHOICES) do
            local key, label = choice[1], choice[2]
            rootDescription:CreateRadio(label,
                function() return currentFilter == key end,
                function()
                    currentFilter = key
                    filterDropdown:SetDefaultText(label)
                    RenderCategory()
                    return MenuResponse.CloseAll
                end)
        end
    end)

    -- ── Notes row ──
    notesFS = inset:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    notesFS:SetPoint("TOPLEFT", filterLabel, "BOTTOMLEFT", 0, -10)
    notesFS:SetPoint("RIGHT", inset, "RIGHT", -SIDE_PAD, 0)
    notesFS:SetJustifyH("LEFT")
    notesFS:SetHeight(14)

    -- ── Column header ──
    hdrFS = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrFS:SetPoint("TOPLEFT", inset, "TOPLEFT", SIDE_PAD + 4, -HEADER_HEIGHT + 18)
    hdrFS:SetWidth(FRAME_W - SIDE_PAD * 2 - 30)
    hdrFS:SetJustifyH("LEFT")
    hdrFS:SetText("|cFFFFCC00OK?|r   |cFFFFCC00Glyph|r       |cFFFFCC00Codepoint|r   |cFFFFCC00English Name|r")

    -- ── Scroll frame holds rows ──
    scrollFrame = CreateFrame("ScrollFrame", nil, inset,
        "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT",     inset, "TOPLEFT",     SIDE_PAD, -HEADER_HEIGHT)
    scrollFrame:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -SIDE_PAD - 22, 8)

    contentFrame = CreateFrame("Frame", nil, scrollFrame)
    contentFrame:SetSize(FRAME_W - SIDE_PAD * 2 - 22, 1)
    scrollFrame:SetScrollChild(contentFrame)

    -- Default selections shown on first open
    local catalog = GeRODPS_Tools.FontGlyphCatalog or {}
    if catalog[currentCatIdx] then
        local cat = catalog[currentCatIdx]
        categoryDropdown:SetDefaultText(
            string.format("%s (%d)", cat.title, #cat.entries))
    end
    fontDropdown:SetDefaultText(FONT_CHOICES[1][1])

    -- ESC to close
    tinsert(UISpecialFrames, "GeRODPS_Tools_FontGlyphViewerFrame")
end

-- ============================================================
-- Toggle entry
-- ============================================================

local function Toggle()
    BuildFrame()
    if not toolFrame then return end
    if toolFrame:IsShown() then
        toolFrame:Hide()
    else
        toolFrame:Show()
        RenderCategory()
    end
end

if GeRODPS_Tools and GeRODPS_Tools.RegisterTool then
    GeRODPS_Tools.RegisterTool("Font Glyph Viewer", Toggle)
end
