#!/usr/bin/env python3
"""Print the 95 supported catalog glyphs grouped by category — markdown report."""
import os, sys, io, json
from fontTools.ttLib import TTFont

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', newline='\n')

FONT = r"D:\World of Warcraft\_retail_\Fonts\FRIZQT__.ttf"
CATALOG_JSON = r'C:\Users\nuttin\AppData\Local\Temp\claude\d--World-of-Warcraft--retail--Interface-AddOns-GeRODPS\66e2175f-8d73-4bf4-a189-00e2c1d1bd41\tasks\wcopulhj1.output'

with open(CATALOG_JSON, encoding='utf-8') as f:
    cats = json.load(f)['result']['catalog']['categories']

tt = TTFont(FONT, lazy=True)
cmap = tt.getBestCmap()
tt.close()

total_supp = 0
total_cat = 0

print("# WoW Retail font glyph coverage (FRIZQT__.ttf)")
print()
print(f"- Font file: `{FONT}`")
print(f"- All 4 .ttf files in WoW/Fonts are byte-identical (same md5)")
print(f"- Total cmap entries in font: {len(cmap)}")
print()

# Two-pass: count first
for cat in cats:
    cps = [(int(e['codepoint'][2:], 16), e['glyph'], e['name']) for e in cat['entries']]
    supp = [(cp, g, n) for (cp, g, n) in cps if cp in cmap]
    total_supp += len(supp)
    total_cat += len(cps)

print(f"## Summary: **{total_supp} / {total_cat} catalog glyphs supported** "
      f"({100*total_supp/total_cat:.1f}%)")
print()

# Per-category detail
for cat in cats:
    cps = [(int(e['codepoint'][2:], 16), e['glyph'], e['name']) for e in cat['entries']]
    supp = [(cp, g, n) for (cp, g, n) in cps if cp in cmap]
    print(f"### {cat['title']} ({cat['unicodeRange']}) — {len(supp)} / {len(cps)} supported")
    if not supp:
        print()
        print(f"_None of the {len(cps)} entries are supported._")
        print()
        continue
    print()
    print(f"| Glyph | Codepoint | Name |")
    print(f"|-------|-----------|------|")
    for cp, g, n in supp:
        print(f"| `{g}` | U+{cp:04X} | {n} |")
    print()
