--[[
    InstanceNameProbe.lua

    ถามชื่อ instance จาก WoW เอง แทนที่จะเดาจากไฟล์ที่ดึงมาจากเว็บ

    ที่มาของปัญหา: GeRODPS/InstanceNames.txt สร้างจาก wago.tools (db2/Map/csv) ซึ่งเป็น
    ข้อมูล enUS ของ build หนึ่ง ไม่มีอะไรรับประกันว่าจะตรงกับชื่อที่ client ของเราเห็นจริง
    (ต่างภาษา · Blizzard เปลี่ยนชื่อ · build ต่างกัน)

    วิธีแก้: ฝาก client คำนวณให้ — `GetRealZoneText(instanceID)` รับ instanceID (= Map.db2 ID
    ตัวเดียวกับที่ GetInstanceInfo() คืนเป็นค่าที่ 8) แล้วคืนชื่อโซนตามภาษาของ client
    ไม่ต้องเข้า instance นั้นจริง (DBM ใช้ท่านี้อยู่แล้ว — DBM-Core.lua, DevTools.lua)

    ── วิธีใช้ ─────────────────────────────────────────────────────────────
      1. เข้าเกม แล้ว /reload  (ครั้งที่ 1 — โมดูลโหลด + คำนวณ เก็บลง DB ในหน่วยความจำ)
      2. /reload อีกครั้ง      (ครั้งที่ 2 — SavedVariables ถูก flush ลงไฟล์จริง)
      3. อ่าน GeRODPS_ToolsDB.instanceNames จาก
         WTF/Account/<id>/SavedVariables/GeRODPS_Tools.lua แล้วเอาไปแก้ InstanceNames.txt
      (เปิดจากเมนู minimap ก็ได้ถ้าอยากดูสรุป / สั่งคำนวณใหม่โดยไม่ reload)

    ── สิ่งที่เก็บลง DB ────────────────────────────────────────────────────
      GeRODPS_ToolsDB.instanceNames        = { [instanceID] = "ชื่อจาก client" }
      GeRODPS_ToolsDB.instanceNamesMeta    = { locale, build, version, when, total, named }
      id ที่ client ตอบว่างหรือ nil → **ไม่ใส่ลง table** (ฝั่งนอกจะได้รู้ว่าควรตัดทิ้ง)

    ⚠ ไฟล์นี้ generate จาก InstanceNames.txt (scratchpad/gen_probe.py) — เลข ID ในนี้
      คือ "โจทย์" ไม่ใช่คำตอบ. ถ้าเพิ่ม ID ใหม่ใน .txt แล้วอยากให้ probe ถามด้วย ให้ gen ใหม่

    Public:
        GeRODPS_Tools.RunInstanceNameProbe()      -- คำนวณใหม่ทันที (คืน total, named)
        GeRODPS_Tools.ShowInstanceNameProbe()     -- หน้าต่างสรุป + ปุ่ม Run
]]

GeRODPS_Tools = GeRODPS_Tools or {}
local TOOL = GeRODPS_Tools

-- instanceID ที่จะถาม — ชุดเดียวกับที่มีใน GeRODPS/InstanceNames.txt
local IDS = {
    30, 33, 34, 36, 43, 47, 48, 70, 90, 109, 129, 169,
    189, 209, 229, 230, 249, 269, 289, 309, 329, 349, 389, 409,
    429, 469, 489, 509, 529, 531, 532, 533, 534, 540, 542, 543,
    544, 545, 546, 547, 548, 550, 552, 553, 554, 555, 556, 557,
    558, 559, 560, 562, 564, 565, 566, 568, 572, 574, 575, 576,
    578, 580, 585, 595, 599, 600, 601, 602, 603, 604, 607, 608,
    615, 616, 617, 619, 624, 627, 628, 631, 632, 637, 643, 644,
    645, 649, 650, 657, 658, 668, 669, 670, 671, 720, 721, 724,
    725, 726, 727, 734, 754, 755, 757, 761, 859, 930, 938, 939,
    940, 951, 959, 960, 961, 962, 967, 968, 977, 980, 994, 995,
    996, 998, 999, 1000, 1001, 1004, 1005, 1007, 1008, 1009, 1011, 1014,
    1024, 1028, 1029, 1030, 1031, 1032, 1035, 1048, 1049, 1050, 1051, 1095,
    1098, 1099, 1102, 1103, 1104, 1105, 1112, 1122, 1123, 1124, 1125, 1126,
    1127, 1130, 1131, 1134, 1135, 1136, 1144, 1148, 1152, 1153, 1154, 1155,
    1157, 1158, 1159, 1160, 1161, 1168, 1170, 1175, 1176, 1182, 1187, 1188,
    1189, 1191, 1195, 1200, 1203, 1205, 1207, 1208, 1209, 1228, 1232, 1233,
    1234, 1235, 1236, 1237, 1238, 1239, 1240, 1241, 1242, 1243, 1244, 1245,
    1266, 1268, 1277, 1279, 1280, 1329, 1330, 1331, 1358, 1374, 1402, 1431,
    1448, 1451, 1453, 1454, 1455, 1456, 1458, 1460, 1461, 1466, 1475, 1477,
    1478, 1480, 1489, 1492, 1493, 1494, 1495, 1498, 1500, 1501, 1503, 1504,
    1505, 1511, 1516, 1520, 1522, 1523, 1526, 1528, 1529, 1530, 1533, 1534,
    1535, 1536, 1539, 1541, 1544, 1545, 1552, 1553, 1554, 1557, 1571, 1572,
    1579, 1580, 1582, 1583, 1592, 1594, 1599, 1600, 1603, 1607, 1609, 1610,
    1611, 1612, 1616, 1617, 1620, 1621, 1622, 1623, 1624, 1625, 1626, 1629,
    1630, 1632, 1646, 1648, 1651, 1653, 1662, 1666, 1667, 1668, 1672, 1673,
    1676, 1677, 1681, 1683, 1684, 1687, 1688, 1689, 1691, 1693, 1694, 1695,
    1698, 1702, 1703, 1704, 1705, 1706, 1707, 1708, 1710, 1712, 1714, 1719,
    1723, 1728, 1729, 1730, 1731, 1732, 1733, 1734, 1735, 1736, 1737, 1738,
    1744, 1746, 1753, 1754, 1756, 1760, 1762, 1763, 1764, 1771, 1774, 1803,
    1812, 1813, 1814, 1818, 1822, 1825, 1840, 1841, 1861, 1862, 1864, 1876,
    1877, 1879, 1882, 1883, 1884, 1892, 1893, 1897, 1898, 1904, 1906, 1907,
    1911, 1917, 1932, 1943, 1944, 1949, 1950, 1955, 2070, 2076, 2096, 2097,
    2105, 2106, 2107, 2111, 2115, 2118, 2124, 2125, 2134, 2155, 2161, 2162,
    2163, 2164, 2167, 2169, 2170, 2174, 2177, 2178, 2179, 2180, 2187, 2193,
    2197, 2207, 2208, 2209, 2210, 2211, 2212, 2213, 2214, 2217, 2223, 2232,
    2233, 2235, 2236, 2245, 2247, 2257, 2258, 2264, 2266, 2278, 2282, 2284,
    2285, 2286, 2287, 2289, 2290, 2291, 2293, 2294, 2296, 2299, 2300, 2303,
    2304, 2305, 2308, 2354, 2356, 2360, 2362, 2363, 2371, 2373, 2375, 2441,
    2450, 2451, 2464, 2465, 2471, 2481, 2504, 2509, 2515, 2516, 2519, 2520,
    2521, 2522, 2526, 2527, 2547, 2549, 2556, 2559, 2563, 2569, 2574, 2579,
    2582, 2583, 2586, 2587, 2590, 2593, 2594, 2595, 2597, 2598, 2599, 2600,
    2614, 2625, 2634, 2635, 2639, 2644, 2645, 2648, 2649, 2651, 2652, 2653,
    2654, 2656, 2657, 2660, 2661, 2662, 2664, 2669, 2679, 2680, 2681, 2682,
    2683, 2684, 2685, 2686, 2687, 2688, 2689, 2690, 2692, 2695, 2699, 2710,
    2713, 2716, 2735, 2736, 2759, 2767, 2768, 2769, 2773, 2774, 2776, 2779,
    2783, 2792, 2799, 2803, 2805, 2810, 2811, 2813, 2815, 2819, 2825, 2826,
    2827, 2828, 2830, 2831, 2836, 2849, 2859, 2874, 2907, 2912, 2913, 2915,
    2923, 2928, 2930, 2933, 2939, 2950, 2951, 2952, 2953, 2961, 2962, 2963,
    2964, 2965, 2966, 2972, 2979, 2987, 2993, 3003, 3004, 3009, 3014, 3022,
    3029, 3038, 3074, 3077, 3079, 3081, 3105,
}

-- ============================================================
-- คำนวณ
-- ============================================================
-- GetRealZoneText(instanceID) คืนชื่อโซนของ instance นั้นตามภาษา client
-- คืน nil / "" ได้ถ้า client ไม่รู้จัก id นั้น → ข้าม ไม่บันทึก
function TOOL.RunInstanceNameProbe()
    GeRODPS_ToolsDB = GeRODPS_ToolsDB or {}
    local out, named = {}, 0
    for _, id in ipairs(IDS) do
        local ok, name = pcall(GetRealZoneText, id)
        if ok and type(name) == "string" then
            name = name:gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" then
                out[id] = name
                named = named + 1
            end
        end
    end
    GeRODPS_ToolsDB.instanceNames = out

    local version, build = GetBuildInfo()
    GeRODPS_ToolsDB.instanceNamesMeta = {
        locale  = GetLocale(),
        version = version,
        build   = build,
        when    = date("%Y-%m-%d %H:%M:%S"),
        total   = #IDS,
        named   = named,
    }
    return #IDS, named
end

-- ============================================================
-- หน้าต่างสรุป (ไม่จำเป็นต่อ flow — มีไว้ดูว่าได้ครบไหมก่อน reload)
-- ============================================================
local TITLE_H  = 28      -- Rule 10: แถวแรกต้องเริ่มใต้ title bar
local SIDE_PAD = 14
local frame

local function BuildFrame()
    if frame then return frame end
    frame = CreateFrame("Frame", "GeRODPS_ToolsInstanceProbe", UIParent,
                        "BasicFrameTemplateWithInset")
    frame:SetSize(560, 260)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")
    frame.TitleText:SetText("Instance Name Probe")

    -- แถวแรก anchor ที่ frame (ตัวนอก) + เผื่อ TITLE_H — ห้ามพึ่ง frame.Inset (Rule 10)
    local info = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    info:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 10))
    info:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -SIDE_PAD, -(TITLE_H + 10))
    info:SetJustifyH("LEFT")
    info:SetSpacing(4)
    frame.info = info

    local btn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    btn:SetSize(170, 24)
    btn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", SIDE_PAD, 14)
    btn:SetText("คำนวณใหม่")
    btn:SetScript("OnClick", function()
        TOOL.RunInstanceNameProbe()
        if frame.Refresh then frame:Refresh() end
    end)

    function frame:Refresh()
        local m = GeRODPS_ToolsDB and GeRODPS_ToolsDB.instanceNamesMeta
        if not m then
            self.info:SetText("ยังไม่ได้คำนวณ")
            return
        end
        local sample = {}
        for _, id in ipairs({ 2660, 2649, 2769, 960 }) do
            local n = GeRODPS_ToolsDB.instanceNames and GeRODPS_ToolsDB.instanceNames[id]
            sample[#sample + 1] = ("    %d = %s"):format(id, n or "|cffff5555(ไม่มีชื่อ)|r")
        end
        self.info:SetText(table.concat({
            ("ถามไป %d id · client ตอบชื่อได้ %d · ไม่รู้จัก %d")
                :format(m.total, m.named, m.total - m.named),
            ("locale %s · %s (%s) · %s"):format(m.locale, m.version, m.build, m.when),
            "",
            "ตัวอย่าง:",
            table.concat(sample, "\n"),
            "",
            "|cffaaaaaaเก็บลง GeRODPS_ToolsDB.instanceNames แล้ว — /reload อีก 1 ครั้ง",
            "เพื่อ flush ลงไฟล์ WTF/Account/<id>/SavedVariables/GeRODPS_Tools.lua|r",
        }, "\n"))
    end
    return frame
end

function TOOL.ShowInstanceNameProbe()
    local f = BuildFrame()
    f:Refresh()
    if f:IsShown() then f:Hide() else f:Show() end
end

TOOL.RegisterTool("Instance Name Probe (ถามชื่อ instance จาก client)", TOOL.ShowInstanceNameProbe)

-- ============================================================
-- คำนวณอัตโนมัติทุก login — flow ของ user คือ "/reload 2 ครั้งแล้วไปอ่านไฟล์"
-- ไม่ต้องกดอะไรเลย
-- ============================================================
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self)
    -- หน่วงเล็กน้อยให้ระบบโซนของ client พร้อมก่อน (GetRealZoneText อ่านจากตารางของ client)
    C_Timer.After(2, function()
        local total, named = TOOL.RunInstanceNameProbe()
        print(("|cff00ff00GeRODPS Tools:|r Instance Name Probe — ถาม %d id ได้ชื่อ %d"):format(total, named))
        print("|cffaaaaaa  /reload อีก 1 ครั้งเพื่อเขียนลงไฟล์ SavedVariables|r")
    end)
    self:UnregisterAllEvents()
end)
