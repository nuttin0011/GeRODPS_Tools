#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sendtostring_9layer_list.py
===========================
List ทุก condition ที่ 9-layer SendToString stack (ชุดที่ implement จริง)
สามารถ Encode + Decode ได้ — 512 combinations, บรรทัดละ 1 condition

แต่ละบรรทัด: mask (bit ต่อ layer) | layer ไหนเปิดบ้าง | สี RGB ที่อ่านได้
ใช้ blend model ที่วัดจริง: out = round((src*128 + dst*127)/255)

Output: sendtostring_9layer_decode_table.txt (ข้างไฟล์นี้)
"""

import sys

from sendtostring_layer_stack_calc import composite, unpack, selftest

# ชุดที่ implement จริง (sync กับ PixelAndBarSetup.lua LAYER_BUILD)
# R<->B swapped variant — top-first: L1=R2 ... L9=B255 (bottom, alpha 1)
CH = "RGB"
LAYERS_TOPFIRST = [
    (0, 2),    # L1 (top)    R2
    (1, 38),   # L2          G38
    (1, 4),    # L3          G4
    (2, 46),   # L4          B46
    (2, 222),  # L5          B222
    (2, 62),   # L6          B62
    (0, 124),  # L7          R124
    (1, 252),  # L8          G252
    (2, 255),  # L9 (bottom) B255 alpha 1
]
OUT_FILE = "sendtostring_9layer_decode_table.txt"


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    selftest()
    n = len(LAYERS_TOPFIRST)

    lines = []
    lines.append("9-Layer SendToString — Encode/Decode table (implemented set)")
    lines.append("blend model: out = round((src*128 + dst*127)/255); bottom alpha 1")
    lines.append("")
    lines.append("Layer legend (top -> bottom):")
    for i, (ch, C) in enumerate(LAYERS_TOPFIRST):
        tag = " (top)" if i == 0 else (" (bottom, alpha 1)" if i == n - 1 else "")
        lines.append(f"  L{i+1} = {CH[ch]}{C}{tag}")
    lines.append("")
    lines.append("mask bits เรียง L9..L1 (ซ้าย = ชั้นล่างสุด); 1 = layer เปิด")
    lines.append("")
    lines.append(f"{'mask(L9..L1)':<14} {'layers ON':<34} {'R':>3} {'G':>3} {'B':>3}   hex")
    lines.append("-" * 72)

    seen = {}
    for mask in range(1 << n):
        r, g, b = unpack(composite(LAYERS_TOPFIRST, mask))
        key = (r, g, b)
        if key in seen:
            print(f"DUPLICATE!! mask {mask} กับ {seen[key]} ได้ {key} ซ้ำกัน")
            sys.exit(2)
        seen[key] = mask

        bits = "".join("1" if (mask >> (n - 1 - i)) & 1 else "0"
                       for i in range(n))  # L9 ซ้าย -> L1 ขวา
        shown = [f"L{i+1}" for i in range(n) if (mask >> i) & 1]
        label = "+".join(shown) if shown else "(none)"
        lines.append(f"{bits:<14} {label:<34} {r:>3} {g:>3} {b:>3}   "
                     f"0x{r:02X}{g:02X}{b:02X}")

    lines.append("-" * 72)
    lines.append(f"total: {1 << n} combinations — RGB ไม่ซ้ำกันเลย 100%")

    with open(OUT_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    print(f"เขียน {1 << n} conditions ลง {OUT_FILE} แล้ว (ตรวจซ้ำ: ไม่มี RGB ชนกัน)")
    print()
    print("ตัวอย่าง 12 บรรทัดแรก:")
    for s in lines[:24]:
        print("  " + s)


if __name__ == "__main__":
    main()
