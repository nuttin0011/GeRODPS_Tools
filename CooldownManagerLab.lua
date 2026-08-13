--[[
    GeRODPS_Tools / CooldownManagerLab.lua

    "Cooldown Manager Lab" — test bench for Blizzard's Cooldown Manager
    (Blizzard_CooldownViewer, WoW 12.x): list every entry, move entries between
    categories (= add/remove them from the bars, items included), snapshot the
    whole configuration and restore it.

    ⚠ WHY THIS TOOL NEVER CALLS BLIZZARD'S LUA
    The first version drove Blizzard's own mixins
    (CooldownViewerSettings:GetDataProvider():SetCooldownToCategory(...) +
    SaveCurrentLayout()). That works, but it leaves addon taint on the viewer
    frames, and CooldownViewerSecure.lua marks
    CooldownViewerMixin.auraInstanceIDToItemFramesMap with
    Enum.TableSecurityOption.DisallowTaintedAccess. The next UNIT_AURA then
    throws, once per aura, forever:

        CooldownViewer.lua:1861: attempted to index a table that cannot be
        accessed while tainted (execution tainted by 'GeRODPS_Tools')

    So this file touches NOTHING owned by Blizzard's Lua — not the settings
    frame, not the data provider, not the layout manager, not even ItemUtil or
    FlagsUtil. It only uses C functions and its own tables:

        READ   C_CooldownViewer.GetCooldownViewerCategorySet(category, true)
               C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownID)
                 -> the STATIC catalog + each entry's DEFAULT category
               C_CooldownViewer.GetLayoutData()
                 -> the saved layout store, decoded here, which holds the
                    player's per-category overrides on top of those defaults
        WRITE  decode the store -> edit our own copy -> re-encode ->
               C_CooldownViewer.SetLayoutData(newBlob)

    Cost of staying clean: the game parses that store only at load, so every
    change needs a /reload. The list updates immediately and shows what the
    bars WILL look like after the reload.

    Layout store format (Blizzard_CooldownViewer/
    CooldownViewerSettingsDataStoreSerialization.lua):
        "<encodingVersion>|" .. base64(deflate(CBOR(data)))
        data[1] = save format version (5 today)
        data[2] = activeLayoutID     keyed by classAndSpecTag
        data[3] = layouts            keyed by classAndSpecTag -> layoutID
        data[4] = layoutID -> name
        layout[1] = ordered cooldownIDs
        layout[2] = category overrides:  category -> { cooldownID, ... }
        layout[3] = alert overrides   layout[4]/[5] = group-buff state
        classAndSpecTag = classID * 10 + specIndex   (CooldownViewerUtil.lua)
    Only NON-DEFAULT categories live in [2]; everything else comes from the
    static catalog. The store is per-character
    (WTF/Account/<acct>/<Realm>/<Char>/cooldownmanager.txt).

    Typical test run:
        Save Snapshot -> move things (here or in Blizzard's own panel)
        -> Compare -> Restore Snapshot -> /reload -> Compare (0 differences).

    Trigger: Minimap (GeRODPS Tools) -> "Cooldown Manager Lab"

    Public:
        GeRODPS_Tools.ShowCooldownManagerLab()
        GeRODPS_Tools.HideCooldownManagerLab()
        GeRODPS_Tools.ToggleCooldownManagerLab()
        GeRODPS_Tools.CDM  -- reusable read/write API for other addons.
                           -- Full usage docs are in the "PUBLIC API" block
                           -- further down this file.
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local FRAME_NAME    = "GeRODPS_ToolsCooldownManagerLabFrame"
local SCREEN_MARGIN = 50

-- Frame (0,0) includes the title bar, so the first content row must clear it.
-- Anchor to `frame` + reserve TITLE_H — never rely on `frame.Inset` (that child
-- does not exist on BasicFrameTemplateWithInset). (wow-coding Rule 10)
local TITLE_H  = 28
local SIDE_PAD = 12
local TOP_PAD  = 6

local DEFAULT_W, DEFAULT_H = 1020, 640
-- MIN_W must fit the row-1 button chain plus both side pads, or the last
-- button renders outside the frame when the user shrinks it.
local MIN_W,     MIN_H     = 800,  420
local MAX_W,     MAX_H     = 1800, 1100

local ROW_H       = 22
local ICON_SIZE   = 18
local COL_ID_W    = 44
local COL_SPELL_W = 62
local COL_KIND_W  = 46
local COL_DEF_W   = 150
local COL_CAT_W   = 160

local QUESTION_ICON = 134400   -- Interface/Icons/INV_Misc_QuestionMark

-- Layout store field IDs, mirroring the SAVE_FIELD_ID_* locals in
-- CooldownViewerSettingsDataStoreSerialization.lua.
local BLOB_FIELD_VERSION       = 1
local BLOB_FIELD_ACTIVE_LAYOUT = 2
local BLOB_FIELD_LAYOUTS       = 3
local BLOB_FIELD_LAYOUT_NAMES  = 4
local LAYOUT_FIELD_ORDER       = 1
local LAYOUT_FIELD_CATEGORIES  = 2

-- ============================================================
-- DB
-- ============================================================

local function GetDB()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    GeRODPS_ToolsDB.cdmLab = GeRODPS_ToolsDB.cdmLab or {}
    return GeRODPS_ToolsDB.cdmLab
end

local function GetOpt()
    local db = GetDB()
    db.opt = db.opt or {}
    local o = db.opt
    if o.knownOnly    == nil then o.knownOnly    = false end
    if o.allowIllegal == nil then o.allowIllegal = false end
    return o
end

local function SnapshotKey()
    local name  = UnitName("player") or "?"
    local realm = GetRealmName() or "?"
    return name .. "-" .. realm
end

local function GetSnapshotStore()
    local db = GetDB()
    db.snapshots = db.snapshots or {}
    return db.snapshots
end

local function GetSnapshot()
    return GetSnapshotStore()[SnapshotKey()]
end

-- ============================================================
-- Module state
-- ============================================================

local frame, scrollFrame, content, statusFS, snapFS, barsFS, countFS, filterBox
local reloadBtn
local rows    = {}      -- row frame pool (index -> frame)
local entries = {}      -- current filtered list shown in the scroll area

-- Set once we have written the layout store: the bars keep showing the old
-- state until the UI reloads.
local pendingReload = false

-- ============================================================
-- Enum access
--
-- Everything here tolerates Blizzard renaming members between patches (12.0
-- shipped HiddenSpell/HiddenAura, 12.1 renamed them to HiddenActive /
-- HiddenPassive), so names are resolved, never assumed.
-- ============================================================

local function CDMApiPresent()
    return C_CooldownViewer ~= nil
        and C_CooldownViewer.GetCooldownViewerCategorySet ~= nil
        and Enum ~= nil and Enum.CooldownViewerCategory ~= nil
end

local function EnumCat(...)
    local t = Enum and Enum.CooldownViewerCategory
    if not t then return nil end
    for i = 1, select("#", ...) do
        local v = t[select(i, ...)]
        if v ~= nil then return v end
    end
    return nil
end

-- The 8 real, assignable categories. GroupBuff is deliberately excluded — it is
-- not part of this catalog and is served by C_CooldownViewer.GetGroupBuffItems.
local REAL_CATEGORY_NAMES = {
    "Essential", "Utility", "TrackedBuff", "TrackedBar",
    "EquipSlotEssential", "EquipSlotTracked",
    "SpecAgnosticEssential", "SpecAgnosticTracked",
}

local function RealCategories()
    local list = {}
    for _, n in ipairs(REAL_CATEGORY_NAMES) do
        local v = EnumCat(n)
        if v ~= nil then list[#list + 1] = v end
    end
    return list
end

-- HiddenActive/HiddenPassive are NOT part of the C enum: Blizzard assigns them
-- onto the Lua table in CooldownViewerSettingsConstants.lua (-1 / -2). 12.1
-- renamed them from HiddenSpell/HiddenAura but kept the values, hence the
-- literal fallback. Never pass these to GetCooldownViewerCategorySet.
local function HiddenActiveCat()  return EnumCat("HiddenActive", "HiddenSpell") or -1 end
local function HiddenPassiveCat() return EnumCat("HiddenPassive", "HiddenAura")  or -2 end

local function CategoryEnumName(cat)
    if cat == nil then return "?" end
    if cat == HiddenActiveCat()  then return "HiddenActive"  end
    if cat == HiddenPassiveCat() then return "HiddenPassive" end
    if Enum and Enum.CooldownViewerCategory then
        for name, value in pairs(Enum.CooldownViewerCategory) do
            if value == cat then return name end
        end
    end
    return tostring(cat)
end

-- Item entries are never parked in Hidden*: their "off the bars" state is their
-- OWN container (EquipSlot* / SpecAgnostic*). Blizzard says so in
-- CooldownViewerSettingsDataProvider.lua's hidden-category mapping: "the
-- default hidden category for item OnUse/Proc entries is in their own
-- container". So for an item, EquipSlot*/SpecAgnostic* == off the main bars,
-- and Essential/Utility/TrackedBuff/TrackedBar == on a bar.
local itemContainerCats
local function IsItemContainerCategory(cat)
    if not itemContainerCats then
        itemContainerCats = {}
        for _, n in ipairs({ "EquipSlotEssential", "EquipSlotTracked",
                             "SpecAgnosticEssential", "SpecAgnosticTracked" }) do
            local v = EnumCat(n)
            if v ~= nil then itemContainerCats[v] = true end
        end
    end
    return itemContainerCats[cat] == true
end

local function IsHiddenCategory(cat)
    if cat == nil then return false end
    return cat == HiddenActiveCat() or cat == HiddenPassiveCat()
end

-- "Not drawn on any Cooldown Manager bar."
local function IsOffBarCategory(cat)
    return IsHiddenCategory(cat) or IsItemContainerCategory(cat)
end

-- Full picker list: the real categories plus the two hidden pseudo-categories.
local categoryDefs
local function CategoryDefs()
    if categoryDefs then return categoryDefs end
    local defs = {}
    for _, cat in ipairs(RealCategories()) do
        defs[#defs + 1] = { cat = cat, name = CategoryEnumName(cat), hidden = false }
    end
    for _, cat in ipairs({ HiddenActiveCat(), HiddenPassiveCat() }) do
        defs[#defs + 1] = { cat = cat, name = CategoryEnumName(cat), hidden = true }
    end
    categoryDefs = defs
    return defs
end

local function CategoryLabel(cat)
    local name = CategoryEnumName(cat)
    if IsHiddenCategory(cat) then return "|cffff8080" .. name .. "|r" end
    if IsItemContainerCategory(cat) then return "|cffffcc00" .. name .. "|r" end
    return name
end

-- Mirror of Blizzard's drag-and-drop legality table
-- (CooldownViewerSettings.lua legalOriginalSourceCategoryToTargetCategory),
-- keyed by the entry's DEFAULT category exactly like CanBeTargetFor does.
-- Blizzard's identity case (target == the default category) is NOT in that
-- table — it is short-circuited inside CanCategoryBeTargetForSourceCategory —
-- so the caller has to add it back.
-- Nothing enforces this when writing the store directly, which is why the panel
-- has an "Allow illegal moves" switch: breaking the rule on purpose is a valid
-- experiment here.
local legalTargets
local function LegalTargetSet(defaultCat)
    if not legalTargets then
        local function set(fromName, ...)
            local from = EnumCat(fromName)
            if from == nil then return end
            local t = {}
            for i = 1, select("#", ...) do
                local to = EnumCat(select(i, ...))
                if to ~= nil then t[to] = true end
            end
            legalTargets[from] = t
        end
        legalTargets = {}
        set("Essential",             "Utility", "HiddenActive", "HiddenSpell")
        set("Utility",               "Essential", "HiddenActive", "HiddenSpell")
        set("EquipSlotEssential",    "Essential", "Utility", "SpecAgnosticEssential")
        set("SpecAgnosticEssential", "Essential", "Utility", "EquipSlotEssential")
        set("TrackedBuff",           "TrackedBar", "HiddenPassive", "HiddenAura")
        set("TrackedBar",            "TrackedBuff", "HiddenPassive", "HiddenAura")
        set("EquipSlotTracked",      "TrackedBuff", "TrackedBar", "SpecAgnosticTracked")
        set("SpecAgnosticTracked",   "TrackedBuff", "TrackedBar", "EquipSlotTracked")
        -- The hidden pseudo-categories are keyed by value, not by enum name.
        legalTargets[HiddenActiveCat()] = {
            [EnumCat("Essential")] = true, [EnumCat("Utility")] = true,
        }
        legalTargets[HiddenPassiveCat()] = {
            [EnumCat("TrackedBuff")] = true, [EnumCat("TrackedBar")] = true,
        }
    end
    return legalTargets[defaultCat]
end

-- ============================================================
-- Layout store codec (pure C API + our own tables)
-- ============================================================

local function EncodingReady()
    return C_EncodingUtil ~= nil
       and C_EncodingUtil.DecodeBase64 ~= nil
       and C_EncodingUtil.DeserializeCBOR ~= nil
       and Enum and Enum.CompressionMethod ~= nil
end

-- Returns dataTable, encodingVersion | nil, errorMessage
local function DecodeBlob(blob)
    if type(blob) ~= "string" or blob == "" then
        return nil, "the layout store is empty (nothing has been customised yet)"
    end
    if not EncodingReady() then return nil, "C_EncodingUtil unavailable on this client" end

    local sep = string.find(blob, "|", 1, true)
    if not sep then return nil, "layout store has no version delimiter" end
    local encVersion = tonumber(string.sub(blob, 1, sep - 1))
    if encVersion ~= 1 then
        return nil, "unsupported layout encoding version " .. tostring(encVersion)
    end

    local payload = string.sub(blob, sep + 1)
    local ok, decoded = pcall(C_EncodingUtil.DecodeBase64, payload)
    if not ok or decoded == nil then return nil, "base64 decode failed" end

    local ok2, inflated = pcall(C_EncodingUtil.DecompressString, decoded, Enum.CompressionMethod.Deflate)
    if not ok2 or inflated == nil then return nil, "inflate failed" end

    local ok3, data = pcall(C_EncodingUtil.DeserializeCBOR, inflated)
    if not ok3 or type(data) ~= "table" then return nil, "CBOR decode failed" end

    return data, encVersion
end

local function EncodeBlob(data, encVersion)
    if not EncodingReady() then return nil, "C_EncodingUtil unavailable" end
    local ok, serialized = pcall(C_EncodingUtil.SerializeCBOR, data)
    if not ok or serialized == nil then return nil, "CBOR encode failed" end
    local ok2, compressed = pcall(C_EncodingUtil.CompressString, serialized, Enum.CompressionMethod.Deflate)
    if not ok2 or compressed == nil then return nil, "deflate failed" end
    local ok3, encoded = pcall(C_EncodingUtil.EncodeBase64, compressed)
    if not ok3 or encoded == nil then return nil, "base64 encode failed" end
    return tostring(encVersion or 1) .. "|" .. encoded
end

local function ReadStore()
    if not (C_CooldownViewer and C_CooldownViewer.GetLayoutData) then
        return nil, nil, "C_CooldownViewer.GetLayoutData missing"
    end
    local ok, blob = pcall(C_CooldownViewer.GetLayoutData)
    if not ok then return nil, nil, "GetLayoutData error" end
    local data, err = DecodeBlob(blob)
    if not data then return nil, blob, err end
    return data, blob
end

-- classAndSpecTag = classID * 10 + specIndex (CooldownViewerUtil.lua)
local function CurrentSpecTag()
    local classID = select(3, UnitClass("player"))
    local specIndex
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
        specIndex = C_SpecializationInfo.GetSpecialization()
    elseif GetSpecialization then
        specIndex = GetSpecialization()
    end
    if not classID or not specIndex or specIndex >= 10 then return nil end
    return classID * 10 + specIndex
end

-- The layout the game is currently using for this spec, or nil when the player
-- is on the untouched starter layout (Blizzard never stores that one).
local function ActiveLayout(data, specTag)
    if not (data and specTag) then return nil end
    local active  = data[BLOB_FIELD_ACTIVE_LAYOUT]
    local layouts = data[BLOB_FIELD_LAYOUTS]
    local layoutID = active and active[specTag]
    local bucket   = layouts and layouts[specTag]
    if layoutID == nil or type(bucket) ~= "table" then return nil, layoutID end
    local layout = bucket[layoutID]
    if type(layout) ~= "table" then return nil, layoutID end
    return layout, layoutID
end

local function LayoutName(data, layoutID)
    local names = data and data[BLOB_FIELD_LAYOUT_NAMES]
    local n = names and layoutID and names[layoutID]
    if type(n) == "string" and n ~= "" then return n end
    return nil
end

-- cooldownID -> category, from the active layout's overrides.
local function OverridesFromLayout(layout)
    local map = {}
    local cats = layout and layout[LAYOUT_FIELD_CATEGORIES]
    if type(cats) ~= "table" then return map end
    for cat, ids in pairs(cats) do
        if type(ids) == "table" then
            for _, id in ipairs(ids) do map[id] = cat end
        end
    end
    return map
end

-- ============================================================
-- Catalog (static data + HideByDefault remap)
-- ============================================================

-- Items: equipped ones carry equipSlot (13/14 for trinkets), bag ones carry
-- spellCategoryID (potions, healthstone).
local function IsItemEntry(info)
    return info.equipSlot ~= nil or info.spellCategoryID ~= nil
end

local function ItemIDForEntry(info)
    if info.spellCategoryID and C_Spell and C_Spell.GetLastCategoryCooldownSource then
        local ok, _, itemID = pcall(C_Spell.GetLastCategoryCooldownSource, info.spellCategoryID)
        if ok and itemID then return itemID end
    end
    return nil
end

local function ResolveIcon(info)
    if info.equipSlot and GetInventoryItemTexture then
        local ok, tex = pcall(GetInventoryItemTexture, "player", info.equipSlot)
        if ok and tex then return tex end
    end

    local itemID = ItemIDForEntry(info)
    if itemID and C_Item and C_Item.GetItemIconByID then
        local ok, icon = pcall(C_Item.GetItemIconByID, itemID)
        if ok and icon then return icon end
    end

    local spellID = info.overrideSpellID or info.spellID
    if spellID and C_Spell and C_Spell.GetSpellTexture then
        local ok, tex = pcall(C_Spell.GetSpellTexture, spellID)
        if ok and tex then return tex end
    end

    return QUESTION_ICON
end

local function ResolveName(info)
    local spellID = info.overrideSpellID or info.spellID
    if spellID and C_Spell then
        if C_Spell.GetSpellName then
            local ok, name = pcall(C_Spell.GetSpellName, spellID)
            if ok and type(name) == "string" and name ~= "" then return name end
        end
        if C_Spell.GetSpellInfo then
            local ok, si = pcall(C_Spell.GetSpellInfo, spellID)
            if ok and type(si) == "table" and type(si.name) == "string" and si.name ~= "" then
                return si.name
            end
        end
    end

    local itemID = ItemIDForEntry(info)
    if itemID and C_Item and C_Item.GetItemNameByID then
        local ok, name = pcall(C_Item.GetItemNameByID, itemID)
        if ok and type(name) == "string" and name ~= "" then return name end
    end

    if info.equipSlot then return "(equip slot " .. tostring(info.equipSlot) .. ")" end
    return "(unnamed)"
end

-- Roughly half the catalog is flagged HideByDefault, and the raw C API still
-- reports those under their nominal category. Blizzard remaps them in
-- CheckBuildDisplayData: spell categories fold into Hidden*, item categories
-- map to THEMSELVES (their own container already means "off the bars").
local function DefaultCategoryOf(info)
    local hideFlag = Enum and Enum.CooldownSetSpellFlags and Enum.CooldownSetSpellFlags.HideByDefault
    local cat = info.category
    if hideFlag == nil or info.flags == nil then return cat end

    local isSet = false
    if bit and bit.band then
        local ok, v = pcall(bit.band, info.flags, hideFlag)
        isSet = ok and v ~= 0
    end
    if not isSet then return cat end

    if IsItemContainerCategory(cat) then return cat end
    if cat == EnumCat("Essential") or cat == EnumCat("Utility") then
        return HiddenActiveCat()
    end
    if cat == EnumCat("TrackedBuff") or cat == EnumCat("TrackedBar") then
        return HiddenPassiveCat()
    end
    return cat
end

-- The whole catalog with the player's overrides applied.
-- Returns entries, contextTable
local function CollectAll()
    local out = {}
    local ctx = { hasStore = false, hasLayout = false }
    if not CDMApiPresent() then return out, ctx end

    local data, _, err = ReadStore()
    ctx.storeError = err
    ctx.hasStore   = data ~= nil
    ctx.specTag    = CurrentSpecTag()

    local layout, layoutID
    if data then
        ctx.saveVersion = data[BLOB_FIELD_VERSION]
        layout, layoutID = ActiveLayout(data, ctx.specTag)
        ctx.hasLayout  = layout ~= nil
        ctx.layoutID   = layoutID
        ctx.layoutName = LayoutName(data, layoutID)
        -- Display order lives beside the category overrides. It is not part of
        -- the category map, so Compare reports it separately.
        local order = layout and layout[LAYOUT_FIELD_ORDER]
        if type(order) == "table" then
            local copy = {}
            for i, id in ipairs(order) do copy[i] = id end
            ctx.order = copy
        end
    end
    local overrides = OverridesFromLayout(layout)

    local seen = {}
    for _, cat in ipairs(RealCategories()) do
        local ok, ids = pcall(C_CooldownViewer.GetCooldownViewerCategorySet, cat, true)
        if ok and type(ids) == "table" then
            for _, cooldownID in ipairs(ids) do
                if not seen[cooldownID] then
                    seen[cooldownID] = true
                    local ok2, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cooldownID)
                    if ok2 and type(info) == "table" then
                        local defCat = DefaultCategoryOf(info)
                        local effective = overrides[cooldownID]
                        if effective == nil then effective = defCat end
                        out[#out + 1] = {
                            id          = cooldownID,
                            spellID     = info.overrideSpellID or info.spellID,
                            baseSpellID = info.spellID,
                            name        = ResolveName(info),
                            icon        = ResolveIcon(info),
                            isItem      = IsItemEntry(info),
                            itemID      = ItemIDForEntry(info),
                            equipSlot   = info.equipSlot,
                            isKnown     = info.isKnown ~= false,
                            cat         = effective,
                            defCat      = defCat,
                            override    = overrides[cooldownID] ~= nil,
                            onBar       = not IsOffBarCategory(effective),
                            raw         = info,
                        }
                    end
                end
            end
        end
    end

    table.sort(out, function(a, b) return a.id < b.id end)
    return out, ctx
end

-- ============================================================
-- Writes (edit our decoded copy, hand the store back)
-- ============================================================

local function WriteStore(data, encVersion)
    local blob, err = EncodeBlob(data, encVersion)
    if not blob then return false, err end
    if not (C_CooldownViewer and C_CooldownViewer.SetLayoutData) then
        return false, "C_CooldownViewer.SetLayoutData missing"
    end
    local ok, e = pcall(C_CooldownViewer.SetLayoutData, blob)
    if not ok then return false, "SetLayoutData error: " .. tostring(e) end
    pendingReload = true
    return true, blob
end

local NO_LAYOUT_MSG =
    "This spec is still on Blizzard's untouched starter layout, which is never " ..
    "written to the store, so there is nothing to edit yet. Make ONE change in " ..
    "Blizzard's own Cooldown Manager panel (Edit Mode), then /reload and come back."

local RELOAD_HINT = "Written to the store — reload now (the game holds the old copy " ..
                    "in memory and would save it back over this)."

-- Apply { [cooldownID] = category, ... } in ONE read-modify-write.
-- Returns ok, message, changedCount
local function ApplyCategoryMap(map)
    if type(map) ~= "table" then return false, "ApplyCategoryMap needs a table" end

    local data, _, err = ReadStore()
    if not data then return false, err or "cannot read the layout store" end

    local specTag = CurrentSpecTag()
    if not specTag then return false, "cannot determine class/spec" end

    local layout = ActiveLayout(data, specTag)
    if not layout then return false, NO_LAYOUT_MSG end

    local cats = layout[LAYOUT_FIELD_CATEGORIES]
    if type(cats) ~= "table" then
        cats = {}
        layout[LAYOUT_FIELD_CATEGORIES] = cats
    end

    local changed = 0
    for cooldownID, category in pairs(map) do
        if type(cooldownID) == "number" and type(category) == "number" then
            -- One cooldownID must appear under exactly one category, otherwise
            -- Blizzard's pairs() walk over the overrides picks a winner at random.
            for cat, ids in pairs(cats) do
                if type(ids) == "table" then
                    for i = #ids, 1, -1 do
                        if ids[i] == cooldownID then table.remove(ids, i) end
                    end
                    if #ids == 0 then cats[cat] = nil end
                end
            end
            cats[category] = cats[category] or {}
            table.insert(cats[category], cooldownID)
            changed = changed + 1
        end
    end

    if changed == 0 then return false, "nothing to apply" end

    -- Encoding version is always 1: versionedEncoders in Blizzard's serializer
    -- has exactly one entry. data[BLOB_FIELD_VERSION] is the SAVE FORMAT
    -- version and is left untouched.
    local ok, res = WriteStore(data, 1)
    if not ok then return false, res end
    return true, ("%d entr%s written. %s"):format(changed, changed == 1 and "y" or "ies", RELOAD_HINT), changed
end

-- Returns ok, message
local function SetEntryCategory(cooldownID, category)
    local ok, msg = ApplyCategoryMap({ [cooldownID] = category })
    if not ok then return false, msg end
    return true, ("Moved %d -> %s. %s")
        :format(cooldownID, CategoryEnumName(category), RELOAD_HINT)
end

-- Where an entry goes when you want it OFF the bars. Items park in their own
-- container, spells/auras in the matching Hidden* pseudo-category.
local function OffBarCategoryFor(entry)
    if entry.isItem and IsItemContainerCategory(entry.defCat) then return entry.defCat end
    local d = entry.defCat
    if d == EnumCat("TrackedBuff") or d == EnumCat("TrackedBar")
       or d == HiddenPassiveCat() or d == EnumCat("EquipSlotTracked")
       or d == EnumCat("SpecAgnosticTracked") then
        return HiddenPassiveCat()
    end
    return HiddenActiveCat()
end

-- Where an entry goes when you want it ON a bar and did not name a category.
local function OnBarCategoryFor(entry)
    local d = entry.defCat
    if d == EnumCat("TrackedBuff") or d == EnumCat("TrackedBar")
       or d == HiddenPassiveCat() or d == EnumCat("EquipSlotTracked")
       or d == EnumCat("SpecAgnosticTracked") then
        return EnumCat("TrackedBuff")
    end
    return EnumCat("Essential")
end

-- ============================================================
-- Snapshot / restore / compare
-- ============================================================

local function CaptureSnapshot()
    if not CDMApiPresent() then return nil, "C_CooldownViewer missing." end

    local all, ctx = CollectAll()
    if #all == 0 then return nil, "Nothing to snapshot (catalog empty / not loaded)." end

    local map = {}
    for _, e in ipairs(all) do map[e.id] = e.cat end

    local blob
    if C_CooldownViewer.GetLayoutData then
        local ok, data = pcall(C_CooldownViewer.GetLayoutData)
        if ok and type(data) == "string" then blob = data end
    end

    local specName, specID
    local specIndex
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
        specIndex = C_SpecializationInfo.GetSpecialization()
    elseif GetSpecialization then
        specIndex = GetSpecialization()
    end
    if specIndex and GetSpecializationInfo then
        local sID, sName = GetSpecializationInfo(specIndex)
        specID, specName = sID, sName
    end

    local snap = {
        time    = time(),
        stamp   = date("%Y-%m-%d %H:%M:%S"),
        count   = #all,
        map     = map,
        blob    = blob,
        blobLen = blob and #blob or 0,
        spec    = specName,
        specID  = specID,
        specTag = ctx.specTag,
        order   = ctx.order,
        class   = select(2, UnitClass("player")),
    }
    GetSnapshotStore()[SnapshotKey()] = snap
    return snap
end

-- Returns array of { id, name, from, to }
local function CompareToSnapshot()
    local snap = GetSnapshot()
    if not snap then return nil, "No snapshot saved yet." end

    local all, ctx = CollectAll()
    local diffs, seen = {}, {}
    for _, e in ipairs(all) do
        seen[e.id] = true
        local was = snap.map[e.id]
        if was == nil then
            diffs[#diffs + 1] = { id = e.id, name = e.name, from = nil, to = e.cat }
        elseif was ~= e.cat then
            diffs[#diffs + 1] = { id = e.id, name = e.name, from = was, to = e.cat }
        end
    end
    for id, was in pairs(snap.map) do
        if not seen[id] then
            diffs[#diffs + 1] = { id = id, name = "(gone from catalog)", from = was, to = nil }
        end
    end

    -- Icon order is stored separately from the categories.
    local orderChanged = false
    local a, b = snap.order, ctx.order
    if (a ~= nil) ~= (b ~= nil) then
        orderChanged = true
    elseif a and b then
        if #a ~= #b then
            orderChanged = true
        else
            for i = 1, #a do
                if a[i] ~= b[i] then orderChanged = true break end
            end
        end
    end

    return diffs, nil, orderChanged
end

-- Restore = hand the saved store back verbatim. It carries categories, order,
-- alerts and every layout of every spec of this character.
local function RestoreSnapshot()
    local snap = GetSnapshot()
    if not snap then return false, "No snapshot saved yet." end
    if not snap.blob then return false, "Snapshot has no layout store." end
    if not (C_CooldownViewer and C_CooldownViewer.SetLayoutData) then
        return false, "C_CooldownViewer.SetLayoutData missing on this client."
    end

    local ok, err = pcall(C_CooldownViewer.SetLayoutData, snap.blob)
    if not ok then return false, "SetLayoutData error: " .. tostring(err) end
    pendingReload = true
    return true, ("Store restored (%d chars) — /reload to apply."):format(snap.blobLen)
end

--[[ ============================================================================
    PUBLIC API — GeRODPS_Tools.CDM
    ============================================================================

    A thin, taint-free wrapper around Blizzard's Cooldown Manager, meant to be
    called from another addon (GeRODPS Rotation, etc.). It only ever touches C
    functions and its own tables, so it cannot taint Blizzard's viewer frames.

    ⚠ GOLDEN RULES
      1. READS are free and safe at any time, in or out of combat.
      2. Every WRITE edits the saved layout store. The game parses that store
         only at load, so a WRITE DOES NOT CHANGE THE BARS UNTIL /reload.
      3. After a write, reload BEFORE switching spec or opening Blizzard's own
         Cooldown Manager panel — the game still holds the pre-write copy in
         memory and will save it back over yours. GeRODPS_Tools.CDM.NeedsReload()
         tells you whether a write is pending.
      4. Writes need an existing layout for the current spec. A spec that has
         never been customised sits on Blizzard's starter layout, which is never
         written to the store; the write returns false with an explanatory
         message. Fix: change anything once in Blizzard's panel, then /reload.
      5. Categories are per class+spec. Nothing here crosses specs.

    ---------------------------------------------------------------- CATEGORIES
    CDM.CAT is the resolved category table — use it instead of
    Enum.CooldownViewerCategory, because 12.1 renamed two members and the two
    Hidden* values are not part of the C enum at all:

        CDM.CAT.Essential           on the Essential bar
        CDM.CAT.Utility             on the Utility bar
        CDM.CAT.TrackedBuff         on the Tracked Buffs bar (icons)
        CDM.CAT.TrackedBar          on the Tracked Bars bar
        CDM.CAT.EquipSlotEssential  ITEM parked in its own container = off the bars
        CDM.CAT.EquipSlotTracked    ITEM (tracked/passive) parked, off the bars
        CDM.CAT.SpecAgnosticEssential / .SpecAgnosticTracked   same, spec-agnostic
        CDM.CAT.HiddenActive        spell removed from the bars
        CDM.CAT.HiddenPassive       aura/bar removed from the bars

    Items never use Hidden*: their "off the bars" state is their own container.
    Use CDM.IsOnBarCategory(cat) instead of testing names.

    CDM.CAT resolves lazily through a metatable (so it survives Blizzard adding
    or renaming members), which means you can index it but not iterate it — use
    CDM.ListCategories() when you need the full set.

    ⚠ This API lives in the GeRODPS_Tools addon, which is separate from GeRODPS.
    Always guard: `local CDM = GeRODPS_Tools and GeRODPS_Tools.CDM`. If Rotation
    must work without the Tools addon installed, copy this file's read/write
    layer over rather than adding a hard dependency.

    -------------------------------------------------------------------- READ
    CDM.IsAvailable()                 -> ok, reason
    CDM.GetAll()                      -> entries, ctx        (see entry shape below)
    CDM.Get(cooldownID)               -> entry | nil
    CDM.FindBySpellID(spellID)        -> entry | nil         (matches base, override
                                                              and linked spell IDs)
    CDM.GetByCategory(cat)            -> array of entries
    CDM.GetOnBar()                    -> array of entries currently drawn
    CDM.IsOnBar(spellID)              -> bool, entry
    CDM.ListCategories()              -> array of { cat, name, hidden, itemContainer }
    CDM.CategoryName(cat)             -> string
    CDM.GetLayoutInfo()               -> ctx (specTag, layoutID, layoutName,
                                              hasLayout, hasStore, saveVersion,
                                              order, storeError)

    entry = {
        id          = cooldownID,        -- the CDM's own key
        spellID     = override or base spell ID (what you usually want)
        baseSpellID = the unmodified spell ID
        name, icon,
        isItem, itemID, equipSlot,       -- equipSlot 13/14 = trinkets
        isKnown,                         -- false = not learned by this character
        cat,                             -- EFFECTIVE category right now
        defCat,                          -- Blizzard's default for this entry
        override,                        -- true when the player moved it
        onBar,                           -- true when `cat` draws on a bar
        raw,                             -- the untouched CooldownViewerCooldown
    }

    ------------------------------------------------------------------- WRITE
    All of these return ok, message [, count] and all need a /reload.

    CDM.SetCategory(cooldownID, cat)
    CDM.SetCategoryBySpellID(spellID, cat)
    CDM.AddToBar(spellIDOrEntry [, cat])     -- cat nil = Essential / TrackedBuff
    CDM.RemoveFromBar(spellIDOrEntry)        -- picks Hidden* or the item container
    CDM.ApplyMany({ [cooldownID] = cat, ...})-- ONE store write, use this for bulk
    CDM.NeedsReload()                        -> bool
    CDM.Reload()                             -- C_UI.Reload(), for convenience

    ---------------------------------------------------------------- SNAPSHOT
    CDM.Snapshot()                    -> snap        (in memory, not persisted)
    CDM.SaveSnapshot()                -> snap, err   (persists per character)
    CDM.GetSavedSnapshot()            -> snap | nil
    CDM.RestoreSnapshot([snap])       -> ok, msg     (defaults to the saved one)
    CDM.Diff([snap])                  -> diffs, err, orderChanged

    A snapshot carries the whole layout store, so RestoreSnapshot brings back
    categories, icon order, alerts and every layout of every spec at once.

    ------------------------------------------------------------------- RAW
    CDM.ReadStore()                   -> data, blob, err   (decoded CBOR table)
    CDM.WriteStore(data)              -> ok, blobOrErr

    ------------------------------------------------------------------ DEBUG
    CDM.Dump()                        -- print the whole catalog to chat
    CDM.Open()                        -- open this tool's window

    ---------------------------------------------------------------- EXAMPLES

    -- Is my cooldown even on the bar? (safe in combat)
    local CDM = GeRODPS_Tools and GeRODPS_Tools.CDM
    if CDM and CDM.IsAvailable() then
        local onBar, entry = CDM.IsOnBar(31884)          -- Avenging Wrath
        if onBar then print(entry.name, CDM.CategoryName(entry.cat)) end
    end

    -- Every trinket the CDM knows about, and whether it is showing
    for _, e in ipairs(CDM.GetAll()) do
        if e.isItem and e.equipSlot then
            print(e.name, e.equipSlot, e.onBar and "on bar" or "parked")
        end
    end

    -- Bulk apply a rotation profile in one write, then reload
    local want = {}
    for _, e in ipairs(CDM.GetAll()) do
        if myProfile[e.spellID] then
            want[e.id] = CDM.CAT.Essential
        elseif e.onBar and not e.isItem then
            want[e.id] = CDM.CAT.HiddenActive
        end
    end
    local ok, msg = CDM.ApplyMany(want)
    if ok then CDM.Reload() else print(msg) end

    -- Snapshot / restore around an experiment
    CDM.SaveSnapshot()
    ... change things ...
    local diffs, _, orderChanged = CDM.Diff()
    CDM.RestoreSnapshot(); CDM.Reload()
============================================================================ ]]

local CDM = {}
TOOL.CDM = CDM

CDM.CAT = setmetatable({}, { __index = function(_, key)
    if key == "HiddenActive"  then return HiddenActiveCat()  end
    if key == "HiddenPassive" then return HiddenPassiveCat() end
    return EnumCat(key)
end })

function CDM.IsAvailable()
    if not CDMApiPresent() then return false, "C_CooldownViewer missing on this client" end
    if not EncodingReady() then return false, "C_EncodingUtil missing on this client" end
    return true
end

function CDM.NeedsReload() return pendingReload end
function CDM.Reload() C_UI.Reload() end

function CDM.CategoryName(cat) return CategoryEnumName(cat) end
function CDM.IsHiddenCategory(cat) return IsHiddenCategory(cat) end
function CDM.IsItemContainerCategory(cat) return IsItemContainerCategory(cat) end
function CDM.IsOnBarCategory(cat) return not IsOffBarCategory(cat) end

function CDM.ListCategories()
    local out = {}
    for _, d in ipairs(CategoryDefs()) do
        out[#out + 1] = {
            cat           = d.cat,
            name          = d.name,
            hidden        = d.hidden,
            itemContainer = IsItemContainerCategory(d.cat),
        }
    end
    return out
end

function CDM.GetAll() return CollectAll() end

function CDM.GetLayoutInfo()
    local _, ctx = CollectAll()
    return ctx
end

function CDM.Get(cooldownID)
    for _, e in ipairs(CollectAll()) do
        if e.id == cooldownID then return e end
    end
    return nil
end

-- Matches the base spell, the active override, and any linked spell the CDM
-- entry declares — an entry for a base spell is the right hit for its override.
function CDM.FindBySpellID(spellID)
    if type(spellID) ~= "number" then return nil end
    for _, e in ipairs(CollectAll()) do
        if e.spellID == spellID or e.baseSpellID == spellID then return e end
        local linked = e.raw and e.raw.linkedSpellIDs
        if type(linked) == "table" then
            for _, id in ipairs(linked) do
                if id == spellID then return e end
            end
        end
    end
    return nil
end

function CDM.GetByCategory(cat)
    local out = {}
    for _, e in ipairs(CollectAll()) do
        if e.cat == cat then out[#out + 1] = e end
    end
    return out
end

function CDM.GetOnBar()
    local out = {}
    for _, e in ipairs(CollectAll()) do
        if e.onBar then out[#out + 1] = e end
    end
    return out
end

function CDM.IsOnBar(spellID)
    local e = CDM.FindBySpellID(spellID)
    if not e then return false, nil end
    return e.onBar, e
end

-- Accepts a cooldownID, a spellID, or an entry table.
local function ResolveEntry(any)
    if type(any) == "table" and any.id then return any end
    if type(any) ~= "number" then return nil end
    for _, e in ipairs(CollectAll()) do
        if e.id == any then return e end
    end
    return CDM.FindBySpellID(any)
end

function CDM.SetCategory(cooldownID, cat) return SetEntryCategory(cooldownID, cat) end
function CDM.ApplyMany(map) return ApplyCategoryMap(map) end

function CDM.SetCategoryBySpellID(spellID, cat)
    local e = CDM.FindBySpellID(spellID)
    if not e then return false, "no Cooldown Manager entry for spellID " .. tostring(spellID) end
    return SetEntryCategory(e.id, cat)
end

function CDM.AddToBar(any, cat)
    local e = ResolveEntry(any)
    if not e then return false, "no Cooldown Manager entry for " .. tostring(any) end
    return SetEntryCategory(e.id, cat or OnBarCategoryFor(e))
end

function CDM.RemoveFromBar(any)
    local e = ResolveEntry(any)
    if not e then return false, "no Cooldown Manager entry for " .. tostring(any) end
    return SetEntryCategory(e.id, OffBarCategoryFor(e))
end

function CDM.Snapshot()
    local all, ctx = CollectAll()
    local map = {}
    for _, e in ipairs(all) do map[e.id] = e.cat end
    local blob
    if C_CooldownViewer and C_CooldownViewer.GetLayoutData then
        local ok, data = pcall(C_CooldownViewer.GetLayoutData)
        if ok and type(data) == "string" then blob = data end
    end
    return {
        time = time(), stamp = date("%Y-%m-%d %H:%M:%S"), count = #all,
        map = map, order = ctx.order, blob = blob, blobLen = blob and #blob or 0,
        specTag = ctx.specTag,
    }
end

function CDM.ReadStore() return ReadStore() end
function CDM.WriteStore(data) return WriteStore(data, 1) end

function CDM.SaveSnapshot() return CaptureSnapshot() end
function CDM.GetSavedSnapshot() return GetSnapshot() end

-- snap defaults to the persisted one.
function CDM.RestoreSnapshot(snap)
    if snap == nil then return RestoreSnapshot() end
    if type(snap) ~= "table" or type(snap.blob) ~= "string" then
        return false, "snapshot has no layout store"
    end
    if not (C_CooldownViewer and C_CooldownViewer.SetLayoutData) then
        return false, "C_CooldownViewer.SetLayoutData missing on this client"
    end
    local ok, err = pcall(C_CooldownViewer.SetLayoutData, snap.blob)
    if not ok then return false, "SetLayoutData error: " .. tostring(err) end
    pendingReload = true
    return true, ("Store restored (%d chars). %s"):format(#snap.blob, RELOAD_HINT)
end

-- diffs, err, orderChanged — snap defaults to the persisted one.
function CDM.Diff(snap)
    if snap == nil then return CompareToSnapshot() end
    if type(snap) ~= "table" or type(snap.map) ~= "table" then
        return nil, "snapshot has no category map"
    end
    local all = CollectAll()
    local diffs, seen = {}, {}
    for _, e in ipairs(all) do
        seen[e.id] = true
        local was = snap.map[e.id]
        if was == nil then
            diffs[#diffs + 1] = { id = e.id, name = e.name, from = nil, to = e.cat }
        elseif was ~= e.cat then
            diffs[#diffs + 1] = { id = e.id, name = e.name, from = was, to = e.cat }
        end
    end
    for id, was in pairs(snap.map) do
        if not seen[id] then
            diffs[#diffs + 1] = { id = id, name = "(gone from catalog)", from = was, to = nil }
        end
    end
    return diffs
end

-- ============================================================
-- UI helpers
-- ============================================================

local function SetStatus(text, colorHex)
    if not statusFS then return end
    if colorHex then
        statusFS:SetText("|c" .. colorHex .. text .. "|r")
    else
        statusFS:SetText(text)
    end
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff82c5ff[CDM Lab]|r " .. tostring(msg))
end

local function UpdateSnapshotLabel()
    if not snapFS then return end
    local snap = GetSnapshot()
    if not snap then
        snapFS:SetText("|cff999999Snapshot: (none)|r")
        return
    end
    snapFS:SetText(("|cffaaffaaSnapshot:|r %s  |cff999999(%d entries, %s, store %d chars)|r")
        :format(snap.stamp or "?", snap.count or 0, snap.spec or "?", snap.blobLen or 0))
end

local BAR_CATEGORY_NAMES = { "Essential", "Utility", "TrackedBuff", "TrackedBar" }

local function UpdateBarCounts(all)
    if not barsFS then return end
    local perCat = {}
    for _, e in ipairs(all) do
        if e.isKnown then
            perCat[e.cat] = (perCat[e.cat] or 0) + 1
        end
    end
    local parts = {}
    for _, n in ipairs(BAR_CATEGORY_NAMES) do
        local cat = EnumCat(n)
        if cat ~= nil then
            parts[#parts + 1] = n .. " |cffffffff" .. (perCat[cat] or 0) .. "|r"
        end
    end
    local prefix = pendingReload and "|cffffcc00on the bars after /reload:|r  "
                                  or "|cffaaaaaaon the bars:|r  "
    barsFS:SetText(prefix .. table.concat(parts, "   "))
end

-- ============================================================
-- List
-- ============================================================

local RefreshList   -- forward declaration (row handlers call it)

local function ShowCategoryMenu(rowFrame, entry)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        Print("MenuUtil unavailable — cannot open the category picker.")
        return
    end
    local allowIllegal = GetOpt().allowIllegal
    local legal = LegalTargetSet(entry.defCat)

    MenuUtil.CreateContextMenu(rowFrame, function(_owner, root)
        root:CreateTitle(entry.name .. "  (cooldownID " .. entry.id .. ")")
        for _, d in ipairs(CategoryDefs()) do
            local isCurrent = (d.cat == entry.cat)
            -- Identity (target == the entry's DEFAULT category) is legal but is
            -- deliberately absent from the matrix: Blizzard short-circuits it in
            -- CanCategoryBeTargetForSourceCategory. Without it every move would
            -- be one-way — nothing could ever go home.
            local isLegal = isCurrent or (d.cat == entry.defCat)
                            or (legal and legal[d.cat]) or false
            if allowIllegal or isLegal then
                local label = d.name
                if isCurrent then
                    label = "|cff00ff00" .. label .. "|r  (current)"
                elseif not isLegal then
                    label = "|cffff6b6b" .. label .. "|r  (illegal)"
                elseif d.hidden then
                    label = "|cffffcc00" .. label .. "|r  (removes from bars)"
                elseif IsItemContainerCategory(d.cat) then
                    label = "|cffffcc00" .. label .. "|r  (item container - off the bars)"
                end
                local target = d.cat
                root:CreateButton(label, function()
                    local ok, msg = SetEntryCategory(entry.id, target)
                    SetStatus(msg, ok and "FF88FF88" or "FFFF6B6B")
                    RefreshList()
                end)
            end
        end
    end)
end

local function AcquireRow(index)
    local row = rows[index]
    if row then return row end

    row = CreateFrame("Frame", nil, content)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT",  content, "TOPLEFT",  0, -(index - 1) * ROW_H)
    row:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -(index - 1) * ROW_H)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)
    row.bg:SetColorTexture(1, 1, 1, index % 2 == 0 and 0.03 or 0.07)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(ICON_SIZE, ICON_SIZE)
    row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)

    row.idFS = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.idFS:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
    row.idFS:SetWidth(COL_ID_W)
    row.idFS:SetJustifyH("LEFT")

    row.spellFS = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.spellFS:SetPoint("LEFT", row.idFS, "RIGHT", 2, 0)
    row.spellFS:SetWidth(COL_SPELL_W)
    row.spellFS:SetJustifyH("LEFT")

    row.kindFS = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.kindFS:SetPoint("LEFT", row.spellFS, "RIGHT", 2, 0)
    row.kindFS:SetWidth(COL_KIND_W)
    row.kindFS:SetJustifyH("LEFT")

    row.catBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.catBtn:SetSize(COL_CAT_W, ROW_H - 4)
    row.catBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.catBtn:SetScript("OnClick", function(self)
        if self.entry then ShowCategoryMenu(self, self.entry) end
    end)

    row.defFS = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.defFS:SetPoint("RIGHT", row.catBtn, "LEFT", -6, 0)
    row.defFS:SetWidth(COL_DEF_W)
    row.defFS:SetJustifyH("RIGHT")

    row.nameFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.nameFS:SetPoint("LEFT",  row.kindFS, "RIGHT", 4, 0)
    row.nameFS:SetPoint("RIGHT", row.defFS,  "LEFT", -6, 0)
    row.nameFS:SetJustifyH("LEFT")
    row.nameFS:SetWordWrap(false)

    rows[index] = row
    return row
end

local function PassesFilter(entry, text, knownOnly)
    if knownOnly and not entry.isKnown then return false end
    if text == "" then return true end
    if tostring(entry.id) == text then return true end
    if entry.spellID and tostring(entry.spellID) == text then return true end
    return string.find(entry.name:lower(), text, 1, true) ~= nil
end

function RefreshList()
    if not content then return end

    local all, ctx = CollectAll()
    local snap = GetSnapshot()
    local opt  = GetOpt()
    local text = filterBox and filterBox:GetText() or ""
    text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

    entries = {}
    local items, offBar = 0, 0
    for _, e in ipairs(all) do
        if e.isItem then items = items + 1 end
        if IsOffBarCategory(e.cat) then offBar = offBar + 1 end
        if PassesFilter(e, text, opt.knownOnly) then
            entries[#entries + 1] = e
        end
    end

    for i, e in ipairs(entries) do
        local row = AcquireRow(i)
        row.catBtn.entry = e
        row.icon:SetTexture(e.icon)
        row.idFS:SetText(tostring(e.id))
        row.spellFS:SetText(e.spellID and tostring(e.spellID) or "-")
        row.kindFS:SetText(e.isItem and "|cffffcc00item|r" or "spell")

        local drift = snap and snap.map[e.id] ~= nil and snap.map[e.id] ~= e.cat
        local nameText = e.name
        if not e.isKnown then
            nameText = "|cff808080" .. nameText .. " (unlearned)|r"
        end
        if drift then nameText = "|cffffcc00*|r " .. nameText end
        row.nameFS:SetText(nameText)

        row.defFS:SetText("|cff707070def: " .. CategoryEnumName(e.defCat) .. "|r")
        row.catBtn:SetText(CategoryLabel(e.cat))
        row:Show()
    end

    for i = #entries + 1, #rows do rows[i]:Hide() end

    -- OnSizeChanged normally drives this, but set it here too so the very first
    -- refresh (before any resize fires) has real row width.
    if scrollFrame then
        local w = scrollFrame:GetWidth()
        if w and w > 1 then content:SetWidth(w) end
    end
    content:SetHeight(math.max(#entries * ROW_H, 1))

    if countFS then
        countFS:SetText(("%d shown / %d total  |cff999999(%d items, %d off the bars)|r")
            :format(#entries, #all, items, offBar))
    end
    if reloadBtn then reloadBtn:SetShown(pendingReload) end
    UpdateSnapshotLabel()
    UpdateBarCounts(all)
    return ctx
end

-- ============================================================
-- Geometry persistence
-- ============================================================

local function SavePosition(self)
    local db = GetDB()
    local point, _, relPoint, x, y = self:GetPoint(1)
    db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

local function SaveSize(self)
    local db = GetDB()
    db.w, db.h = self:GetWidth(), self:GetHeight()
end

local function ApplySavedGeometry(self)
    local db = GetDB()
    local screenW, screenH = UIParent:GetWidth(), UIParent:GetHeight()
    local w = db.w or DEFAULT_W
    local h = db.h or DEFAULT_H
    if w > screenW - 2 * SCREEN_MARGIN then w = screenW - 2 * SCREEN_MARGIN end
    if h > screenH - 2 * SCREEN_MARGIN then h = screenH - 2 * SCREEN_MARGIN end
    if w < MIN_W then w = MIN_W end
    if h < MIN_H then h = MIN_H end
    self:ClearAllPoints()
    if db.point and db.relPoint and db.x and db.y then
        self:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
    else
        self:SetPoint("CENTER")
    end
    self:SetSize(w, h)
end

-- ============================================================
-- Button actions
-- ============================================================

local function DoSaveSnapshot()
    local snap, err = CaptureSnapshot()
    if not snap then
        SetStatus(err or "Snapshot failed.", "FFFF6B6B")
        return
    end
    SetStatus(("Snapshot saved: %d entries, store %d chars.")
        :format(snap.count, snap.blobLen), "FF88FF88")
    RefreshList()
end

local function DoCompare()
    local diffs, err, orderChanged = CompareToSnapshot()
    if not diffs then
        SetStatus(err or "Compare failed.", "FFFF6B6B")
        return
    end
    if #diffs == 0 then
        if orderChanged then
            SetStatus("Categories match the snapshot, but the icon ORDER differs. " ..
                      "Restore Snapshot brings the order back too.", "FFFFCC00")
        else
            SetStatus("Identical to snapshot — 0 differences.", "FF88FF88")
        end
    else
        SetStatus(("%d difference%s vs snapshot — details in chat.")
            :format(#diffs, #diffs == 1 and "" or "s"), "FFFFCC00")
        Print(("%d difference%s vs snapshot:"):format(#diffs, #diffs == 1 and "" or "s"))
        for _, d in ipairs(diffs) do
            Print(("  [%d] %s : %s -> %s"):format(
                d.id, d.name,
                d.from and CategoryEnumName(d.from) or "(absent)",
                d.to   and CategoryEnumName(d.to)   or "(absent)"))
        end
        if orderChanged then Print("  ...and the icon ORDER differs too.") end
    end
    RefreshList()
end

local function DoRestore()
    local ok, msg = RestoreSnapshot()
    SetStatus(msg, ok and "FF88FF88" or "FFFF6B6B")
    RefreshList()
end

local function DoDumpChat()
    local all, ctx = CollectAll()
    Print(("catalog: %d entries | specTag %s | store v%s | layout %s%s | order %s"):format(
        #all, tostring(ctx.specTag), tostring(ctx.saveVersion),
        ctx.hasLayout and tostring(ctx.layoutID) or "(starter, not stored)",
        ctx.layoutName and (" \"" .. ctx.layoutName .. "\"") or "",
        ctx.order and (#ctx.order .. " entries") or "(default)"))
    for _, e in ipairs(all) do
        Print(("  [%d] %s%s spell=%s cat=%s def=%s%s known=%s"):format(
            e.id, e.name, e.isItem and " (item)" or "",
            e.spellID and tostring(e.spellID) or "-",
            CategoryEnumName(e.cat), CategoryEnumName(e.defCat),
            e.override and " (override)" or "",
            tostring(e.isKnown)))
    end

    -- Group buffs are a separate track: that category is absent from the
    -- catalog above and is served by its own API.
    if C_CooldownViewer and C_CooldownViewer.GetGroupBuffItems then
        local ok, buffs = pcall(C_CooldownViewer.GetGroupBuffItems)
        if ok and type(buffs) == "table" then
            Print(("group buffs (separate API): %d"):format(#buffs))
            for _, b in ipairs(buffs) do
                Print(("  spell=%s %s known=%s"):format(
                    tostring(b.spellID), tostring(b.name), tostring(b.isKnown)))
            end
        end
    end
end

-- ============================================================
-- Frame build
-- ============================================================

local function MakeButton(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local function MakeCheck(parent, label, key, onChange)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetChecked(GetOpt()[key] and true or false)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    fs:SetText(label)
    cb.labelFS = fs
    cb:SetScript("OnClick", function(self)
        GetOpt()[key] = self:GetChecked() and true or false
        if onChange then onChange() end
    end)
    return cb
end

local function BuildToolbars()
    -- Row 1: actions
    local bar1 = CreateFrame("Frame", nil, frame)
    bar1:SetHeight(24)
    bar1:SetPoint("TOPLEFT",  frame, "TOPLEFT",   SIDE_PAD, -(TITLE_H + TOP_PAD))
    bar1:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + TOP_PAD))

    local bRefresh = MakeButton(bar1, "Refresh", 76, function() RefreshList() end)
    bRefresh:SetPoint("LEFT", bar1, "LEFT", 0, 0)

    local bSave = MakeButton(bar1, "Save Snapshot", 118, DoSaveSnapshot)
    bSave:SetPoint("LEFT", bRefresh, "RIGHT", 6, 0)

    local bRestore = MakeButton(bar1, "Restore Snapshot", 136, DoRestore)
    bRestore:SetPoint("LEFT", bSave, "RIGHT", 6, 0)

    local bCmp = MakeButton(bar1, "Compare", 86, DoCompare)
    bCmp:SetPoint("LEFT", bRestore, "RIGHT", 6, 0)

    local bDump = MakeButton(bar1, "Dump to chat", 108, DoDumpChat)
    bDump:SetPoint("LEFT", bCmp, "RIGHT", 6, 0)

    reloadBtn = MakeButton(bar1, "Reload UI", 92, function() C_UI.Reload() end)
    reloadBtn:SetPoint("LEFT", bDump, "RIGHT", 12, 0)
    reloadBtn:Hide()

    -- Row 2: snapshot / bars / status. Both edges of each FontString anchor at
    -- the SAME height — anchoring TOPLEFT and TOPRIGHT to different Y values is
    -- a layout conflict.
    local bar2 = CreateFrame("Frame", nil, frame)
    bar2:SetHeight(64)
    bar2:SetPoint("TOPLEFT",  bar1, "BOTTOMLEFT",  0, -6)
    bar2:SetPoint("TOPRIGHT", bar1, "BOTTOMRIGHT", 0, -6)

    snapFS = bar2:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    snapFS:SetPoint("TOPLEFT",  bar2, "TOPLEFT",   2, 0)
    snapFS:SetPoint("TOPRIGHT", bar2, "TOPRIGHT", -2, 0)
    snapFS:SetJustifyH("LEFT")
    snapFS:SetHeight(14)

    barsFS = bar2:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    barsFS:SetPoint("TOPLEFT",  snapFS, "BOTTOMLEFT",  0, -4)
    barsFS:SetPoint("TOPRIGHT", snapFS, "BOTTOMRIGHT", 0, -4)
    barsFS:SetJustifyH("LEFT")
    barsFS:SetHeight(14)

    statusFS = bar2:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusFS:SetPoint("TOPLEFT",  barsFS, "BOTTOMLEFT",  0, -4)
    statusFS:SetPoint("TOPRIGHT", barsFS, "BOTTOMRIGHT", 0, -4)
    statusFS:SetJustifyH("LEFT")
    statusFS:SetJustifyV("TOP")
    statusFS:SetHeight(28)

    -- Row 3: filter + options
    local bar3 = CreateFrame("Frame", nil, frame)
    bar3:SetHeight(24)
    bar3:SetPoint("TOPLEFT",  bar2, "BOTTOMLEFT",  0, -2)
    bar3:SetPoint("TOPRIGHT", bar2, "BOTTOMRIGHT", 0, -2)

    local filterLabel = bar3:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    filterLabel:SetPoint("LEFT", bar3, "LEFT", 2, 0)
    filterLabel:SetText("Filter:")

    filterBox = CreateFrame("EditBox", nil, bar3, "InputBoxTemplate")
    filterBox:SetSize(180, 20)
    filterBox:SetPoint("LEFT", filterLabel, "RIGHT", 8, 0)
    filterBox:SetAutoFocus(false)
    filterBox:SetScript("OnTextChanged", function() RefreshList() end)
    filterBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)

    local cbKnown = MakeCheck(bar3, "Known only", "knownOnly", function() RefreshList() end)
    cbKnown:SetPoint("LEFT", filterBox, "RIGHT", 14, 0)

    local cbIllegal = MakeCheck(bar3, "Allow illegal moves", "allowIllegal")
    cbIllegal:SetPoint("LEFT", cbKnown.labelFS, "RIGHT", 16, 0)

    countFS = bar3:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    countFS:SetPoint("RIGHT", bar3, "RIGHT", -4, 0)
    countFS:SetJustifyH("RIGHT")

    return bar3
end

local function CreateFrameOnce()
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
    end
    if frame.TitleText then
        frame.TitleText:SetText("GeRODPS Tools — Cooldown Manager Lab")
    end

    local bar3 = BuildToolbars()

    -- Column header
    local header = CreateFrame("Frame", nil, frame)
    header:SetHeight(16)
    header:SetPoint("TOPLEFT",  bar3, "BOTTOMLEFT",  0, -4)
    header:SetPoint("TOPRIGHT", bar3, "BOTTOMRIGHT", -22, -4)

    local hdrLeft = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrLeft:SetPoint("LEFT", header, "LEFT", 2, 0)
    hdrLeft:SetText("|cffffcc00icon  cdID   spellID  kind   name|r")

    local hdrRight = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrRight:SetPoint("RIGHT", header, "RIGHT", -4, 0)
    hdrRight:SetText("|cffffcc00default                  category (click to move)|r")

    -- Scrolling list
    scrollFrame = CreateFrame("ScrollFrame", "$parentList", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 14)

    content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(1, 1)
    scrollFrame:SetScrollChild(content)
    scrollFrame:SetScript("OnSizeChanged", function(_, w)
        if content then content:SetWidth(w) end
    end)

    -- Resize grabber
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

    table.insert(UISpecialFrames, FRAME_NAME)
    ApplySavedGeometry(frame)
    frame:Hide()
    return frame
end

-- ============================================================
-- Public API
-- ============================================================

local function OnShow()
    categoryDefs = nil        -- re-resolve enum names after a patch/spec change
    if not CDMApiPresent() then
        SetStatus("C_CooldownViewer is missing — this client has no Cooldown Manager.", "FFFF6B6B")
        RefreshList()
        return
    end

    local ctx = RefreshList()
    if pendingReload then
        SetStatus("Written to the layout store. |cffffcc00Reload now|r — the game " ..
                  "still holds the old copy in memory and will save it back over " ..
                  "this if you switch spec or edit Blizzard's own panel first.",
                  "FFFFCC00")
    elseif ctx and not ctx.hasStore then
        SetStatus(ctx.storeError and ("Layout store: " .. ctx.storeError .. ". " .. NO_LAYOUT_MSG)
                                  or NO_LAYOUT_MSG, "FFFFCC00")
    elseif ctx and not ctx.hasLayout then
        SetStatus(NO_LAYOUT_MSG, "FFFFCC00")
    else
        SetStatus("Ready. Click a category button to move an entry. " ..
                  "|cffff8080Hidden*|r = removed (spells/auras)  |  " ..
                  "|cffffcc00EquipSlot*/SpecAgnostic*|r = an item in its own container, " ..
                  "i.e. off the bars. Every change needs a /reload.")
    end
end

function TOOL.ShowCooldownManagerLab()
    local f = CreateFrameOnce()
    if not f:IsShown() then
        ApplySavedGeometry(f)
        f:Show()
    end
    OnShow()
end

function TOOL.HideCooldownManagerLab()
    if frame then frame:Hide() end
end

function TOOL.ToggleCooldownManagerLab()
    local f = CreateFrameOnce()
    if f:IsShown() then
        f:Hide()
    else
        TOOL.ShowCooldownManagerLab()
    end
end

-- Attached last because it wraps a UI-layer action.
CDM.Dump = DoDumpChat
CDM.Open = TOOL.ShowCooldownManagerLab

if TOOL.RegisterTool then
    TOOL.RegisterTool("Cooldown Manager Lab", TOOL.ToggleCooldownManagerLab)
end
