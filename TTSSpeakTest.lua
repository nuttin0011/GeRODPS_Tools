--[[
    TTSSpeakTest.lua

    ทดสอบ WoW Text-to-Speech API แบบ interactive — ใช้หา combination ที่เสียงออกจริง
    ก่อนเอาไปใช้งานจริงใน GeRODPS (ปุ่ม Test ใน Edit Flag popup ของ Defensive TTS).

    2 เส้นทางพูด (เทียบกันได้):
        [Speak]        → C_VoiceChat.SpeakText(voiceID, text, dest, rate, vol) ตรงๆ
        [Speak Blizz]  → TextToSpeech_Speak(text, voice) — helper ของ Blizzard
                         (จัดการ init/enable ภายในให้ — ถ้าเส้นนี้ออกเสียงแต่เส้นแรกเงียบ
                          = ต้องใช้ helper ในงานจริง)

    Diagnostic panel: โชว์ type ของทุก API ที่เกี่ยว (nil = client 12.0 รื้อทิ้งแล้ว),
    ค่า C_TTSSettings, ค่าจริงของ Enum.VoiceTtsDestination, จำนวน voice.
    Event line: VOICE_CHAT_TTS_PLAYBACK_STARTED / _FAILED(+status code) / _FINISHED.

    Layout note: จุด (0,0) ของ frame คือมุมบนซ้าย "รวม title bar" — ทุก element แถวแรก
    ต้องเผื่อ TITLE_H ลงมา ไม่งั้นทับ title bar.

    Trigger: Minimap (GeRODPS Tools) → "TTS Speak Test"
]]

GeRODPS_Tools = GeRODPS_Tools or {}

-- ============================================================
-- Constants / state
-- ============================================================

local FRAME_W  = 620
local FRAME_H  = 430
local SIDE_PAD = 14
local TITLE_H  = 28    -- ความสูง title bar ของ BasicFrameTemplateWithInset — แถวแรกต้องเริ่มใต้เส้นนี้

local toolFrame
local textEB
local voiceDD, rateDD, volDD, destDD
local diagFS, statusFS, eventFS

local currentVoiceID   = nil
local currentVoiceName = "(เลือก voice)"
local currentRate      = 0
local currentVolume    = 100
local currentDestKey   = "QueuedLocalPlayback"

-- ============================================================
-- Helpers
-- ============================================================

local function EnumName(tbl, val)
    if type(tbl) ~= "table" then return tostring(val) end
    for k, v in pairs(tbl) do
        if v == val then return k end
    end
    return tostring(val)
end

local function TypeStr(v)
    if v == nil then return "|cFFFF5555nil|r" end
    return "|cFF55FF55" .. type(v) .. "|r"
end

local function GetVoices()
    if not (type(C_VoiceChat) == "table" and type(C_VoiceChat.GetTtsVoices) == "function") then
        return {}
    end
    local ok, voices = pcall(C_VoiceChat.GetTtsVoices)
    if ok and type(voices) == "table" then return voices end
    return {}
end

-- Destination: เฉพาะ key ที่เป็น Local ล้วน (กัน RemoteTransmission หลุดลง voice chat)
local function GetLocalDestChoices()
    local out = {}
    if type(Enum) == "table" and type(Enum.VoiceTtsDestination) == "table" then
        for k, v in pairs(Enum.VoiceTtsDestination) do
            if type(k) == "string" and not k:find("Remote") then
                out[#out + 1] = { key = k, val = v }
            end
        end
        table.sort(out, function(a, b) return a.val < b.val end)
    end
    return out
end

local function CurrentDestVal()
    local t = (type(Enum) == "table") and Enum.VoiceTtsDestination or nil
    if type(t) == "table" and t[currentDestKey] ~= nil then
        return t[currentDestKey]
    end
    return 1
end

-- ============================================================
-- Diagnostic panel — ตอบคำถาม "API ตัวไหนมีจริงบน client นี้"
-- ============================================================

local function RefreshDiag()
    local lines = {}

    -- L1: availability ของทุก function ที่เกี่ยว
    local vc = C_VoiceChat
    lines[#lines + 1] = string.format(
        "C_VoiceChat=%s  .SpeakText=%s  .StopSpeakingText=%s  .GetTtsVoices=%s (|cFFFFFF99%d|r ตัว)  TextToSpeech_Speak=%s",
        TypeStr(vc),
        TypeStr(type(vc) == "table" and vc.SpeakText or nil),
        TypeStr(type(vc) == "table" and vc.StopSpeakingText or nil),
        TypeStr(type(vc) == "table" and vc.GetTtsVoices or nil),
        #GetVoices(),
        TypeStr(TextToSpeech_Speak))

    -- L2: ค่าจาก C_TTSSettings (ที่โค้ดจริงเคยใช้)
    if type(C_TTSSettings) == "table" then
        local okO, optID = pcall(function()
            local vt = (type(Enum) == "table" and Enum.TtsVoiceType and Enum.TtsVoiceType.Standard) or 0
            if type(C_TTSSettings.GetVoiceOptionID) == "function" then
                return C_TTSSettings.GetVoiceOptionID(vt)
            end
            return "(no fn)"
        end)
        local okR, rate = pcall(function()
            if type(C_TTSSettings.GetSpeechRate) == "function" then
                return C_TTSSettings.GetSpeechRate()
            end
            return "(no fn)"
        end)
        local okV, vol = pcall(function()
            if type(C_TTSSettings.GetSpeechVolume) == "function" then
                return C_TTSSettings.GetSpeechVolume()
            end
            return "(no fn)"
        end)
        lines[#lines + 1] = string.format(
            "C_TTSSettings: optID(Standard)=|cFFFFFF99%s|r  rate=|cFFFFFF99%s|r  vol=|cFFFFFF99%s|r",
            okO and tostring(optID) or "ERR", okR and tostring(rate) or "ERR",
            okV and tostring(vol) or "ERR")
    else
        lines[#lines + 1] = "C_TTSSettings=|cFFFF5555nil|r"
    end

    -- L3: ค่าจริงของ Enum.VoiceTtsDestination บน client นี้
    if type(Enum) == "table" and type(Enum.VoiceTtsDestination) == "table" then
        local kv = {}
        for k, v in pairs(Enum.VoiceTtsDestination) do
            kv[#kv + 1] = { k = k, v = v }
        end
        table.sort(kv, function(a, b) return a.v < b.v end)
        local parts = {}
        for _, e in ipairs(kv) do
            parts[#parts + 1] = string.format("%s=%s", e.k, tostring(e.v))
        end
        lines[#lines + 1] = "VoiceTtsDestination: |cFF9FB3C8" .. table.concat(parts, "  ") .. "|r"
    else
        lines[#lines + 1] = "Enum.VoiceTtsDestination=|cFFFF5555nil|r"
    end

    diagFS:SetText(table.concat(lines, "\n"))
end

-- ============================================================
-- Speak / Stop
-- ============================================================

local function CurrentMsg()
    local msg = textEB and textEB:GetText() or ""
    if msg == "" then msg = "Hello Azeroth" end
    return msg
end

-- เส้นทาง 1: C_VoiceChat.SpeakText ตรงๆ
local function DoSpeak()
    local msg = CurrentMsg()
    local fn = (type(C_VoiceChat) == "table") and C_VoiceChat.SpeakText or nil
    if type(fn) ~= "function" then
        statusFS:SetText("|cFFFF5555C_VoiceChat.SpeakText ไม่มีบน client นี้ — ใช้ปุ่ม Speak Blizz เทียบ|r")
        return
    end
    if currentVoiceID == nil then
        statusFS:SetText("|cFFFF5555ยังไม่ได้เลือก Voice — เปิด dropdown Voice ก่อน (list ว่าง = เครื่องไม่มี TTS voice)|r")
        return
    end
    local destVal = CurrentDestVal()
    local ok, err = pcall(fn, currentVoiceID, msg, destVal, currentRate, currentVolume)
    statusFS:SetText(string.format(
        "SpeakText(voiceID=|cFFFFFF99%s|r, \"%s\", dest=|cFFFFFF99%s|r(%s), rate=|cFFFFFF99%d|r, vol=|cFFFFFF99%d|r) → %s",
        tostring(currentVoiceID), msg, tostring(destVal), currentDestKey,
        currentRate, currentVolume,
        ok and "|cFF55FF55เรียกสำเร็จ (รอ event)|r" or ("|cFFFF5555pcall FAIL: " .. tostring(err) .. "|r")))
    eventFS:SetText("|cFF888888(รอ event...)|r")
end

-- เส้นทาง 2: Blizzard helper (จัดการ enable/init ภายใน — เหมือนปุ่ม Play Sample ใน
-- Options > Accessibility > Text-to-Speech)
local function DoSpeakBlizz()
    local msg = CurrentMsg()
    local fn = TextToSpeech_Speak
    if type(fn) ~= "function" then
        statusFS:SetText("|cFFFF5555TextToSpeech_Speak (Blizzard helper) ไม่มีบน client นี้|r")
        return
    end
    if currentVoiceID == nil then
        statusFS:SetText("|cFFFF5555ยังไม่ได้เลือก Voice ก่อน|r")
        return
    end
    local ok, err = pcall(fn, msg, { voiceID = currentVoiceID })
    statusFS:SetText(string.format(
        "TextToSpeech_Speak(\"%s\", {voiceID=|cFFFFFF99%s|r}) → %s",
        msg, tostring(currentVoiceID),
        ok and "|cFF55FF55เรียกสำเร็จ (รอ event)|r" or ("|cFFFF5555pcall FAIL: " .. tostring(err) .. "|r")))
    eventFS:SetText("|cFF888888(รอ event...)|r")
end

local function DoStop()
    if type(C_VoiceChat) == "table" and type(C_VoiceChat.StopSpeakingText) == "function" then
        pcall(C_VoiceChat.StopSpeakingText)
        eventFS:SetText("|cFF888888เรียก StopSpeakingText แล้ว|r")
    end
end

-- ============================================================
-- Playback events — บอกสาเหตุจริงเวลาไม่มีเสียง
-- ============================================================

local eventFrame = CreateFrame("Frame")
local TTS_EVENTS = {
    "VOICE_CHAT_TTS_PLAYBACK_STARTED",
    "VOICE_CHAT_TTS_PLAYBACK_FAILED",
    "VOICE_CHAT_TTS_PLAYBACK_FINISHED",
    "VOICE_CHAT_TTS_VOICES_UPDATE",
}
for _, ev in ipairs(TTS_EVENTS) do
    -- pcall กัน event ที่ client บางเวอร์ชันไม่รู้จัก (RegisterEvent throw)
    local ok = pcall(eventFrame.RegisterEvent, eventFrame, ev)
    if not ok then
        print("|cFFFF8888[TTS Test]|r event ไม่รู้จักบน client นี้: " .. ev)
    end
end
eventFrame:SetScript("OnEvent", function(_, event, a1, a2, a3)
    if not (toolFrame and toolFrame:IsShown() and eventFS) then return end
    if event == "VOICE_CHAT_TTS_PLAYBACK_STARTED" then
        -- args: numConsumers, utteranceID, durationMS, destination
        eventFS:SetText(string.format(
            "|cFF55FF55STARTED|r  consumers=%s utterance=%s duration=%sms",
            tostring(a1), tostring(a2), tostring(a3)))
    elseif event == "VOICE_CHAT_TTS_PLAYBACK_FAILED" then
        -- args: status (Enum.VoiceTtsStatusCode), utteranceID, destination
        local statusName = EnumName(type(Enum) == "table" and Enum.VoiceTtsStatusCode or nil, a1)
        eventFS:SetText(string.format(
            "|cFFFF5555FAILED|r  status=|cFFFF9999%s|r (%s) utterance=%s dest=%s",
            statusName, tostring(a1), tostring(a2), tostring(a3)))
    elseif event == "VOICE_CHAT_TTS_PLAYBACK_FINISHED" then
        eventFS:SetText((eventFS:GetText() or "") .. "  |cFF888888→ FINISHED|r")
    elseif event == "VOICE_CHAT_TTS_VOICES_UPDATE" then
        if diagFS then RefreshDiag() end
    end
end)

-- ============================================================
-- Frame build
-- ============================================================
-- ⚠ ตำแหน่ง element: anchor จาก toolFrame TOPLEFT ซึ่ง (0,0) = มุมบนซ้าย "รวม title bar"
--   → แถวแรกต้อง y = -(TITLE_H + padding) เสมอ ไม่งั้น element ทับ title bar

local function BuildFrame()
    if toolFrame then return end

    toolFrame = CreateFrame("Frame", "GeRODPS_Tools_TTSSpeakTestFrame",
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
        toolFrame.TitleText:SetText("GeRODPS Tools — TTS Speak Test")
    end

    -- Row 1: text EditBox (แถวแรก — เผื่อ TITLE_H)
    local textLabel = toolFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    textLabel:SetPoint("TOPLEFT", toolFrame, "TOPLEFT", SIDE_PAD, -(TITLE_H + 14))
    textLabel:SetText("Text:")

    textEB = CreateFrame("EditBox", nil, toolFrame, "InputBoxTemplate")
    textEB:SetPoint("LEFT", textLabel, "RIGHT", 14, 0)
    textEB:SetSize(430, 20)
    textEB:SetAutoFocus(false)
    textEB:SetMaxLetters(100)
    textEB:SetText("Hello Azeroth")
    textEB:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    textEB:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Row 2: Voice dropdown
    local voiceLabel = toolFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    voiceLabel:SetPoint("TOPLEFT", textLabel, "BOTTOMLEFT", 0, -20)
    voiceLabel:SetText("Voice:")

    voiceDD = CreateFrame("DropdownButton", nil, toolFrame, "WowStyle1DropdownTemplate")
    voiceDD:SetPoint("LEFT", voiceLabel, "RIGHT", 8, -2)
    voiceDD:SetWidth(320)
    voiceDD:SetDefaultText(currentVoiceName)
    voiceDD:SetupMenu(function(_, rootDescription)
        local voices = GetVoices()
        if #voices == 0 then
            rootDescription:CreateTitle("(ไม่พบ TTS voice ในเครื่อง)")
            return
        end
        for _, v in ipairs(voices) do
            local vid, vname = v.voiceID, v.name or ("voice " .. tostring(v.voiceID))
            rootDescription:CreateRadio(
                string.format("[%s] %s", tostring(vid), vname),
                function() return currentVoiceID == vid end,
                function()
                    currentVoiceID   = vid
                    currentVoiceName = vname
                    voiceDD:SetDefaultText(string.format("[%s] %s", tostring(vid), vname))
                    return MenuResponse.CloseAll
                end)
        end
    end)

    -- Row 3: Speed / Volume / Destination
    local rateLabel = toolFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    rateLabel:SetPoint("TOPLEFT", voiceLabel, "BOTTOMLEFT", 0, -22)
    rateLabel:SetText("Speed:")

    rateDD = CreateFrame("DropdownButton", nil, toolFrame, "WowStyle1DropdownTemplate")
    rateDD:SetPoint("LEFT", rateLabel, "RIGHT", 8, -2)
    rateDD:SetWidth(80)
    rateDD:SetDefaultText(tostring(currentRate))
    rateDD:SetupMenu(function(_, rootDescription)
        for r = -10, 10 do
            rootDescription:CreateRadio(tostring(r),
                function() return currentRate == r end,
                function()
                    currentRate = r
                    rateDD:SetDefaultText(tostring(r))
                    return MenuResponse.CloseAll
                end)
        end
    end)

    local volLabel = toolFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    volLabel:SetPoint("LEFT", rateDD, "RIGHT", 14, 2)
    volLabel:SetText("Volume:")

    volDD = CreateFrame("DropdownButton", nil, toolFrame, "WowStyle1DropdownTemplate")
    volDD:SetPoint("LEFT", volLabel, "RIGHT", 8, -2)
    volDD:SetWidth(80)
    volDD:SetDefaultText(tostring(currentVolume))
    volDD:SetupMenu(function(_, rootDescription)
        for v = 0, 100, 10 do
            rootDescription:CreateRadio(tostring(v),
                function() return currentVolume == v end,
                function()
                    currentVolume = v
                    volDD:SetDefaultText(tostring(v))
                    return MenuResponse.CloseAll
                end)
        end
    end)

    local destLabel = toolFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    destLabel:SetPoint("LEFT", volDD, "RIGHT", 14, 2)
    destLabel:SetText("Dest:")

    destDD = CreateFrame("DropdownButton", nil, toolFrame, "WowStyle1DropdownTemplate")
    destDD:SetPoint("LEFT", destLabel, "RIGHT", 8, -2)
    destDD:SetWidth(190)
    destDD:SetDefaultText(currentDestKey)
    destDD:SetupMenu(function(_, rootDescription)
        local choices = GetLocalDestChoices()
        if #choices == 0 then
            rootDescription:CreateTitle("(Enum.VoiceTtsDestination ไม่มี)")
            return
        end
        for _, c in ipairs(choices) do
            rootDescription:CreateRadio(
                string.format("%s (%s)", c.key, tostring(c.val)),
                function() return currentDestKey == c.key end,
                function()
                    currentDestKey = c.key
                    destDD:SetDefaultText(c.key)
                    return MenuResponse.CloseAll
                end)
        end
    end)

    -- Row 4: Speak / Speak Blizz / Stop
    local speakBtn = CreateFrame("Button", nil, toolFrame, "UIPanelButtonTemplate")
    speakBtn:SetPoint("TOPLEFT", rateLabel, "BOTTOMLEFT", 0, -22)
    speakBtn:SetSize(110, 24)
    speakBtn:SetText("Speak")
    speakBtn:SetScript("OnClick", DoSpeak)

    local speakBlizzBtn = CreateFrame("Button", nil, toolFrame, "UIPanelButtonTemplate")
    speakBlizzBtn:SetPoint("LEFT", speakBtn, "RIGHT", 10, 0)
    speakBlizzBtn:SetSize(130, 24)
    speakBlizzBtn:SetText("Speak Blizz")
    speakBlizzBtn:SetScript("OnClick", DoSpeakBlizz)

    local stopBtn = CreateFrame("Button", nil, toolFrame, "UIPanelButtonTemplate")
    stopBtn:SetPoint("LEFT", speakBlizzBtn, "RIGHT", 10, 0)
    stopBtn:SetSize(80, 24)
    stopBtn:SetText("Stop")
    stopBtn:SetScript("OnClick", DoStop)

    -- Row 5: diagnostic panel (3 บรรทัด — API availability / C_TTSSettings / Dest enum)
    diagFS = toolFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    diagFS:SetPoint("TOPLEFT", speakBtn, "BOTTOMLEFT", 0, -14)
    diagFS:SetWidth(FRAME_W - SIDE_PAD * 2)
    diagFS:SetJustifyH("LEFT")
    diagFS:SetSpacing(3)
    diagFS:SetWordWrap(true)
    diagFS:SetText("")

    -- Row 6: last call args
    statusFS = toolFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusFS:SetPoint("TOPLEFT", diagFS, "BOTTOMLEFT", 0, -12)
    statusFS:SetWidth(FRAME_W - SIDE_PAD * 2)
    statusFS:SetJustifyH("LEFT")
    statusFS:SetWordWrap(true)
    statusFS:SetText("|cFF888888ยังไม่ได้เรียก SpeakText|r")

    -- Row 7: last playback event
    eventFS = toolFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    eventFS:SetPoint("TOPLEFT", statusFS, "BOTTOMLEFT", 0, -12)
    eventFS:SetWidth(FRAME_W - SIDE_PAD * 2)
    eventFS:SetJustifyH("LEFT")
    eventFS:SetWordWrap(true)
    eventFS:SetText("|cFF888888(ยังไม่มี event)|r")
end

-- ============================================================
-- Toggle + tool registration
-- ============================================================

local function Toggle()
    BuildFrame()
    if toolFrame:IsShown() then
        toolFrame:Hide()
        return
    end
    -- default voice = ตัวแรกใน list (ถ้ายังไม่เคยเลือก)
    if currentVoiceID == nil then
        local voices = GetVoices()
        if #voices > 0 then
            currentVoiceID   = voices[1].voiceID
            currentVoiceName = voices[1].name or ("voice " .. tostring(voices[1].voiceID))
            voiceDD:SetDefaultText(string.format("[%s] %s",
                tostring(currentVoiceID), currentVoiceName))
        end
    end
    RefreshDiag()
    toolFrame:Show()
end

GeRODPS_Tools.RegisterTool("TTS Speak Test", Toggle)
