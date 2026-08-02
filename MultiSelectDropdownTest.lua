--[[
    MultiSelectDropdownTest.lua

    ตัวอย่าง **Multi-Select Dropdown (Persistent Menu)**

    ชื่อเรียก 2 คำนี้อธิบายคนละส่วน — ใช้คู่กันเสมอเวลาพูดถึงของแบบนี้:
      · multi-select = ติ๊กเลือกได้หลายอันพร้อมกัน (ไม่ใช่เลือกได้อันเดียว)
      · persistent   = กดเลือกแล้ว "เมนูไม่ปิด" ต้องสั่งปิดเอง (non-dismissing menu)
    ศัพท์อื่นที่หมายถึงอันเดียวกัน: checkbox dropdown · multi-select combo box
    ฝั่ง WoW native (MenuUtil): menu:CreateCheckbox(...) + return MenuResponse.Refresh
      (Refresh = วาดใหม่ไม่ปิด · Close = ปิด ซึ่งเป็น default ของปุ่มปกติ)

    ⚡ ข้อสรุป: **ไม่ต้องเขียนเอง** — AceGUI Dropdown มี `SetMultiselect(true)` อยู่แล้ว
       และพฤติกรรมตรงตามที่ต้องการทุกข้อ:
         · ติ๊กถูกหน้ารายการที่เลือก        (item เปลี่ยนเป็น Dropdown-Item-Toggle)
         · กดรายการเดิมซ้ำ = ถูกหายไป      (OnItemValueChanged ส่ง checked=false)
         · **เมนูไม่หดหลังกด**              (ไม่เรียก pullout:Close())
         · กดลูกศร v อีกครั้งถึงหด          (Dropdown_TogglePullout ผูกกับปุ่มลูกศร)
       อ้างอิง: Libs/AceGUI-3.0/widgets/AceGUIWidget-DropDown.lua
         SetMultiselect 625 · OnItemValueChanged 423 · Dropdown_TogglePullout 373

    ── callback ต่างจาก dropdown ปกติ ─────────────────────────────────────────
      ปกติ (single) : OnValueChanged(widget, event, key)
      multiselect   : OnValueChanged(widget, event, key, checked)   ← มี checked เพิ่ม
      ⇒ ห้าม copy handler จาก dropdown เดิมมาตรงๆ ต้องรับ arg ที่ 4 ด้วย
      widget:GetValue() ใช้กับ multiselect ไม่ได้ — เก็บ state เป็น table ของเราเอง

    ── ของแถมที่ AceGUI ใส่ให้เอง ──────────────────────────────────────────────
      · ข้อความบนหัว dropdown = ชื่อที่ติ๊กไว้ต่อกันด้วย ", " (ShowMultiText)
      · มีรายการ "Close" เพิ่มท้ายเมนูอัตโนมัติ (AddCloseButton) — เอาออกไม่ได้
        ถ้าไม่อยากได้ต้องเขียน dropdown เอง ซึ่งไม่คุ้ม (ลูกศร v ก็ปิดได้อยู่แล้ว)

    ── ตั้งค่าเริ่มต้นให้ติ๊กไว้ก่อน ────────────────────────────────────────────
      dd:SetItemValue(key, true)  ← ต้องเรียก **หลัง** SetList เท่านั้น
      (SetItemValue วน pullout:IterateItems ซึ่งยังว่างถ้ายังไม่ SetList)

    วิธีดู: Minimap → GeRODPS Tools → "Multi-Select Dropdown (Persistent Menu)"

    Public:
        GeRODPS_Tools.ToggleMultiSelectDropdownTest()
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

local TITLE_H  = 28      -- Rule 10: แถวแรกต้องเผื่อความสูง title bar
local SIDE_PAD = 16

-- ตัวเลือกตัวอย่าง — คีย์ที่เก็บใน state คือ key ของ list ไม่ใช่ข้อความที่โชว์
local ORDER = { "kick", "stun", "fear", "knockback", "silence" }
local LIST  = {
    kick      = "Interrupt (Kick)",
    stun      = "Stun",
    fear      = "Fear",
    knockback = "Knock Back",
    silence   = "Silence",
}
local COLOR = {
    kick      = { 0.85, 0.35, 0.55 },
    stun      = { 0.75, 0.55, 0.95 },
    fear      = { 0.95, 0.75, 0.35 },
    knockback = { 0.45, 0.70, 0.95 },
    silence   = { 0.55, 0.85, 0.65 },
}

-- state จริงของเรา — AceGUI ไม่เก็บให้ในโหมด multiselect
local selected = { kick = true }      -- ตั้ง kick ติ๊กไว้ตั้งแต่แรกเพื่อโชว์ SetItemValue

local frame, dropdown, logFS, swatches

-- ============================================================
-- "ทำงานตาม Check" — ส่วนที่สะท้อนผลจริงของ state
-- ============================================================
local function ApplySelection()
    -- แถบสีจะโผล่/หายตามที่ติ๊ก = พิสูจน์ว่า state ที่เก็บไว้ใช้งานได้จริง
    local x = 0
    for _, key in ipairs(ORDER) do
        local sw = swatches[key]
        if selected[key] then
            local c = COLOR[key]
            sw.tex:SetColorTexture(c[1], c[2], c[3], 1)
            sw:ClearAllPoints()
            sw:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD + x, -(TITLE_H + 96))
            sw:Show()
            x = x + 104
        else
            sw:Hide()
        end
    end

    local on = {}
    for _, key in ipairs(ORDER) do
        if selected[key] then on[#on + 1] = key end
    end
    logFS:SetText(
        "|cffffd100state ของเรา:|r  " ..
        (#on > 0 and table.concat(on, ", ") or "|cff888888(ไม่ได้เลือกอะไร)|r") ..
        "\n|cff888888เลือกแล้ว " .. #on .. " / " .. #ORDER .. " อัน" ..
        " — เมนูยังเปิดอยู่ กดลูกศร v เพื่อปิด|r"
    )
end

-- ============================================================
-- UI
-- ============================================================
local function Build()
    if frame then return frame end
    local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
    if not AceGUI then
        print("|cffff5555GeRODPS Tools:|r ไม่มี AceGUI-3.0 — ต้องเปิด addon GeRODPS ด้วย")
        return nil
    end

    frame = CreateFrame("Frame", "GeRODPS_ToolsMultiSelectDD", UIParent,
                        "BasicFrameTemplateWithInset")
    frame:SetSize(620, 300)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")
    frame.TitleText:SetText("Multi-Select Dropdown (Persistent Menu)")

    -- ⚠ anchor แถวแรกที่ frame (ตัวนอก) + เผื่อ TITLE_H — ห้ามพึ่ง frame.Inset (Rule 10)
    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 10))
    hint:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + 10))
    hint:SetJustifyH("LEFT")
    hint:SetSpacing(3)
    hint:SetText("|cffffd100multi-select|r = ติ๊กได้หลายอัน · " ..
                 "|cffffd100persistent|r = กดแล้วเมนูไม่ปิด" ..
                 "\nกดลูกศร v เปิดเมนู → เลือกได้หลายอัน (กดซ้ำ = ถูกหาย) → กด v อีกครั้งเพื่อปิด")

    -- AceGUI ต้องอยู่ในคอนเทนเนอร์ของมันเอง ถึงจะ layout ได้ (ห้ามผสมกับ native ใน tree เดียว)
    -- ⚠ พ่อเป็น native frame → ต้อง SetWidth **และ** SetHeight เอง ไม่งั้น Flow ยุบเป็น 0
    --   (pattern เดียวกับ ReorderAnimTest.lua ที่ฝัง AceGUI ในกรอบ native)
    local holder = AceGUI:Create("SimpleGroup")
    holder:SetLayout("Flow")
    holder.frame:SetParent(frame)
    holder.frame:ClearAllPoints()
    holder.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD - 8, -(TITLE_H + 46))
    holder.frame:SetWidth(300)
    holder.frame:SetHeight(50)
    holder.frame:Show()
    frame.holder = holder

    dropdown = AceGUI:Create("Dropdown")
    dropdown:SetLabel("เลือกได้หลายอัน")
    dropdown:SetWidth(260)
    -- ⚠ ลำดับสำคัญ: SetMultiselect → SetList → SetItemValue
    --   SetItemValue วนดู pullout:IterateItems ซึ่งยังว่างถ้ายังไม่ SetList
    dropdown:SetMultiselect(true)
    dropdown:SetList(LIST, ORDER)
    for key, on in pairs(selected) do
        dropdown:SetItemValue(key, on)
    end
    -- ⚠ multiselect ส่ง arg ที่ 4 (checked) มาด้วย — dropdown ปกติไม่มี
    dropdown:SetCallback("OnValueChanged", function(_, _, key, checked)
        selected[key] = checked or nil
        ApplySelection()
    end)
    holder:AddChild(dropdown)

    swatches = {}
    for _, key in ipairs(ORDER) do
        local sw = CreateFrame("Frame", nil, frame)
        sw:SetSize(96, 28)
        sw.tex = sw:CreateTexture(nil, "ARTWORK")
        sw.tex:SetAllPoints()
        local fs = sw:CreateFontString(nil, "OVERLAY", "GameFontBlackSmall")
        fs:SetPoint("CENTER")
        fs:SetText(LIST[key])
        sw:Hide()
        swatches[key] = sw
    end

    logFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    logFS:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 140))
    logFS:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + 140))
    logFS:SetJustifyH("LEFT")
    logFS:SetSpacing(4)

    local note = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", SIDE_PAD, 14)
    note:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -SIDE_PAD, 14)
    note:SetJustifyH("LEFT")
    note:SetSpacing(3)
    note:SetText("ทั้งหมดนี้เป็นของ AceGUI เอง: dd:SetMultiselect(true) แล้ว SetList" ..
                 "\ncallback = OnValueChanged(widget, event, key, checked) — state เก็บเอง (GetValue ใช้ไม่ได้)")

    ApplySelection()
    return frame
end

function TOOL.ToggleMultiSelectDropdownTest()
    local f = Build()
    if not f then return end
    if f:IsShown() then f:Hide() else f:Show() end
end

TOOL.RegisterTool("Multi-Select Dropdown (Persistent Menu)", TOOL.ToggleMultiSelectDropdownTest)
