#Requires AutoHotkey v2.0
; ============================================================
; ColorAtCursor.ahk — โชว์สี pixel ใต้ cursor ใน ToolTip ที่ (200,200)
;
; ใช้คู่กับ GeRODPS_Tools > Color Half-Step Viewer:
; ชี้ cursor กลางสี่เหลี่ยมสี แล้วอ่านค่า R G B เทียบ label floor/round
;
; Hotkeys:
;   F9  = pause / resume การอ่านสี
;   F11 = copy ค่าที่อ่านอยู่ลง clipboard (รูปแบบ "R G B  0xRRGGBB")
;   F10 = ออกจาก script
; ============================================================

CoordMode "Mouse", "Screen"
CoordMode "Pixel", "Screen"
CoordMode "ToolTip", "Screen"

global lastText := ""

SetTimer Update, 50

Update() {
    global lastText
    MouseGetPos &mx, &my
    c := PixelGetColor(mx, my)          ; v2 คืนค่า RGB integer
    r := (c >> 16) & 0xFF
    g := (c >> 8) & 0xFF
    b := c & 0xFF
    lastText := Format("{} {} {}  0x{:06X}", r, g, b, c)
    ToolTip Format("cursor x{} y{}`nR {}  G {}  B {}`n0x{:06X}",
        mx, my, r, g, b, c), 200, 200
}

F9:: {
    static on := true
    on := !on
    SetTimer Update, on ? 50 : 0
    if !on
        ToolTip
}

F11:: {
    global lastText
    A_Clipboard := lastText
    ToolTip "copied: " lastText, 200, 240
    SetTimer () => ToolTip(, 200, 240), -800
}

F10::ExitApp
