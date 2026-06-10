#!/usr/bin/env python3
"""Convert workflow JSON catalog -> Lua data file."""
import json, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', newline='\n')

SRC = r'C:\Users\nuttin\AppData\Local\Temp\claude\d--World-of-Warcraft--retail--Interface-AddOns-GeRODPS\66e2175f-8d73-4bf4-a189-00e2c1d1bd41\tasks\wcopulhj1.output'

with open(SRC, encoding='utf-8') as f:
    data = json.load(f)

cats = data['result']['catalog']['categories']

def lua_str(s):
    if s is None:
        return '""'
    escaped = s.replace('\\', '\\\\').replace('"', '\\"')
    return '"' + escaped + '"'

print('-- ============================================================')
print('-- FontGlyphCatalogData.lua')
print('-- Auto-generated Unicode glyph catalog. Used by FontGlyphViewer')
print('-- to show all glyphs with their English names so user can')
print('-- visually verify which ones render in WoW fonts vs render as')
print('-- tofu / blank squares.')
print('--')
print(f'-- {len(cats)} categories, {sum(len(c["entries"]) for c in cats)} total glyphs.')
print('-- See wow-coding skill Rule 5 for which glyph classes are unsafe')
print('-- in rendered text.')
print('-- ============================================================')
print('')
print('GeRODPS_Tools = GeRODPS_Tools or {}')
print('GeRODPS_Tools.FontGlyphCatalog = {')

for cat in cats:
    print('    {')
    print(f'        title        = {lua_str(cat["title"])},')
    print(f'        unicodeRange = {lua_str(cat["unicodeRange"])},')
    if cat.get('notes'):
        print(f'        notes        = {lua_str(cat["notes"])},')
    print('        entries = {')
    for e in cat['entries']:
        gl = e['glyph']
        nm = e['name']
        cp = e['codepoint']
        print(f'            {{ {lua_str(gl)}, {lua_str(cp)}, {lua_str(nm)} }},')
    print('        },')
    print('    },')
print('}')
