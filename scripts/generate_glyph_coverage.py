#!/usr/bin/env python3
"""
Generate FontGlyphCoverage.lua — for each WoW font file, determine which
Unicode codepoints from FontGlyphCatalogData.lua are actually mapped to a
glyph (i.e., would render correctly vs render as tofu).

Reads:
  - D:\\World of Warcraft\\_retail_\\Fonts\\*.ttf            (4 fonts)
  - workflow JSON output (for catalog codepoints)

Writes:
  - FontGlyphCoverage.lua (Lua table consumed by FontGlyphViewer)
"""
import os, sys, io, json
from fontTools.ttLib import TTFont

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', newline='\n')

FONTS_DIR = r"D:\World of Warcraft\_retail_\Fonts"
FONT_FILES = ["FRIZQT__.ttf", "ARIALN.ttf", "MORPHEUS.ttf", "skurri.ttf"]
CATALOG_JSON = r'C:\Users\nuttin\AppData\Local\Temp\claude\d--World-of-Warcraft--retail--Interface-AddOns-GeRODPS\66e2175f-8d73-4bf4-a189-00e2c1d1bd41\tasks\wcopulhj1.output'

with open(CATALOG_JSON, encoding='utf-8') as f:
    catalog = json.load(f)['result']['catalog']['categories']

# Flatten catalog codepoints
all_catalog_cps = []
for cat in catalog:
    for e in cat['entries']:
        cp_int = int(e['codepoint'][2:], 16)  # "U+2580" -> 0x2580
        all_catalog_cps.append((cp_int, e['glyph'], e['name'], cat['title']))

# Inspect each font
font_reports = []
for font_name in FONT_FILES:
    path = os.path.join(FONTS_DIR, font_name)
    if not os.path.exists(path):
        print(f"-- MISSING FONT: {font_name}", file=sys.stderr)
        continue
    try:
        tt = TTFont(path, lazy=True)
        cmap = tt.getBestCmap() or {}
        total_glyphs = len(cmap)
        # Which catalog codepoints are supported
        supported_cps = sorted(cp for (cp, _, _, _) in all_catalog_cps if cp in cmap)
        # Per-category breakdown
        by_cat = {}
        for cat in catalog:
            cat_cps = [int(e['codepoint'][2:], 16) for e in cat['entries']]
            supp = [cp for cp in cat_cps if cp in cmap]
            by_cat[cat['title']] = (len(supp), len(cat_cps))
        font_reports.append({
            'name': font_name,
            'path': f'Fonts\\\\{font_name}',
            'totalGlyphsInFont': total_glyphs,
            'catalogSupported': supported_cps,
            'numCatalogSupported': len(supported_cps),
            'numCatalogTotal': len(all_catalog_cps),
            'byCategory': by_cat,
        })
        print(f"-- {font_name}: {total_glyphs} total glyphs in font, "
              f"{len(supported_cps)}/{len(all_catalog_cps)} from catalog supported",
              file=sys.stderr)
        for ct, (s, t) in by_cat.items():
            print(f"--     {ct:50s} {s:4d}/{t:4d}", file=sys.stderr)
        tt.close()
    except Exception as ex:
        print(f"-- ERROR reading {font_name}: {ex}", file=sys.stderr)

# -- Emit Lua --
print('-- ============================================================')
print('-- FontGlyphCoverage.lua')
print('-- Auto-generated per-font Unicode coverage for the 4 TTF fonts')
print('-- shipped with WoW Retail. For each font, lists which codepoints')
print('-- in GeRODPS_Tools.FontGlyphCatalog are mapped to a real glyph')
print('-- (cmap lookup via fontTools). Unmapped codepoints would render')
print('-- as tofu / .notdef box.')
print('--')
print('-- Source fonts: D:\\\\World of Warcraft\\\\_retail_\\\\Fonts\\\\*.ttf')
print('-- Regenerate via: scripts/generate_glyph_coverage.py')
print('-- ============================================================')
print()
print('GeRODPS_Tools = GeRODPS_Tools or {}')
print('GeRODPS_Tools.FontGlyphCoverage = {')

for r in font_reports:
    print('    {')
    print(f'        name                = "{r["name"]}",')
    print(f'        path                = "{r["path"]}",')
    print(f'        totalGlyphsInFont   = {r["totalGlyphsInFont"]},')
    print(f'        numCatalogSupported = {r["numCatalogSupported"]},')
    print(f'        numCatalogTotal     = {r["numCatalogTotal"]},')
    print(f'        -- Per-category counts (supported / total in catalog):')
    print(f'        byCategory = {{')
    for ct, (s, t) in r['byCategory'].items():
        # Escape category title for Lua key
        key = ct.replace('"', '\\"')
        print(f'            ["{key}"] = {{ {s}, {t} }},')
    print(f'        }},')
    print(f'        -- supported[codepoint] = true for catalog codepoints with a real glyph')
    print(f'        supported = {{')
    # Pack 8 codepoints per line for compactness
    cps = r['catalogSupported']
    for i in range(0, len(cps), 8):
        chunk = cps[i:i+8]
        entries = ', '.join(f'[0x{cp:04X}]=true' for cp in chunk)
        print(f'            {entries},')
    print(f'        }},')
    print('    },')

print('}')
