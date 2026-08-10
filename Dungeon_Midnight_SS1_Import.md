# Dungeon Midnight SS1 — GeRODPS Import (Defensive / Interrupt-Stun)

> สร้างจาก `Dungeon_Midnight_SS1_Triage.html` โดย skill `import-converter`  
> วางเนื้อในกล่องโค้ดแต่ละอันลงช่อง Import ในเกม (Defense Mechanism → Import/Export)

**⚠ Import = โหลดทับทั้ง list** — ถ้ามี list เดิมที่อยากเก็บ ให้ Export ในเกมออกมา merge ก่อน

**การจำแนก (heuristic — ปรับได้ในเกมผ่าน Edit Flag):**
- Interrupt array → **kick** · priority `high` → **hikick** (kick ด่วน/สำคัญ) · pri สูง=สำคัญกว่า (high 30 / med 20 / low 10)
- Defensive array → `source=casting`, priority high → `dmgLevel high` · med/low → `norm`, target/type/effect เดาจาก dtype+เหตุผล
- Frontal/Swirly (avoidable) → `dmgLevel low` (Avoidable) + TTS custom **"Frontal"** / **"Swirly"** (เตือนเสียง ไม่บังคับกด defensive)
- `sooth` (soothe/dispel/purge) **ไม่รวม** — คนละระบบ (ไม่ใช่ Defensive/Interrupt)

## สรุปจำนวน

| Dungeon | Defensive | Avoidable | Kick | HiKick |
|---|--:|--:|--:|--:|
| Algeth'ar Academy | 11 | 12 | 2 | 1 |
| Seat of the Triumvirate | 9 | 9 | 3 | 3 |
| Pit of Saron | 14 | 11 | 4 | 4 |
| Skyreach | 7 | 10 | 1 | 3 |
| Windrunner Spire | 13 | 20 | 6 | 1 |
| Magister's Terrace | 9 | 7 | 2 | 3 |
| Maisara Caverns | 9 | 21 | 6 | 3 |
| Nexus Point Xenas | 11 | 9 | 2 | 3 |
| **รวม** | **83** | **99** | **26** | **21** |

Defensive list = **182** entries (unavoidable 83 + avoidable 99) · Interrupt/Stun list = **47** entries

**Defensive — ตัด duplicate spellID (เก็บตัวที่เจอก่อน):**
- `377004` Deafening Screech (Algeth'ar Academy/avoidable) — ซ้ำกับ Algeth'ar Academy / defensive
- `1276948` Ice Barrage (Pit of Saron/avoidable) — ซ้ำกับ Pit of Saron / defensive
- `154110` Fiery Smash (Skyreach/avoidable) — ซ้ำกับ Skyreach / defensive

## 1) Defensive List — วางลง Defensive sub-tab

```
# GeRODPS Defensive Damage List
# WARNING: Import จะลบ Defensive list เดิมทั้งหมด
# spellID; name; source; castRem; debuffRem; target; dmgLevel; deadlyHP; type; effect; ttsMode; ttsWord
=== Algeth'ar Academy
388544; Barkbreaker; casting; 1.0; 1.0; me; high; 35; physical; none; auto; 
1276752; Ruinous Winds; casting; 1.0; 1.0; aoe; high; 35; magic; none; auto; 
388822; Power Vacuum; casting; 1.0; 1.0; aoe; high; 50; magic; none; auto; 
388537; Arcane Fissure; casting; 1.0; 1.0; aoe; high; 35; magic; none; auto; 
376997; Savage Peck; casting; 1.0; 1.0; me; high; 35; physical; none; auto; 
388923; Burst Forth; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
396716; Splinterbark; casting; 1.0; 1.0; aoe; norm; 35; physical; none; auto; 
377004; Deafening Screech; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
386173; Mana Bombs; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
439488; Unleash Energy; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1282251; Astral Blast; casting; 1.0; 1.0; me; norm; 35; magic; none; auto; 
=== Algeth'ar Academy - Avoidable (Frontal/Swirly)
388976; Riftbreath; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
385958; Arcane Expulsion; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
386201; Corrupted Mana; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
387691; Arcane Orbs; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
378003; Deadly Winds; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
377383; Gust; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
377034; Overpowering Gust; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
390912; Detonation Seeds; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
388623; Branch Out; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
388796; Germinate; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1270349; Astral Whirlwind; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1279418; Arcane Rift; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
=== Seat of the Triumvirate
1266003; Symphony of the Eternal Night; casting; 1.0; 1.0; aoe; high; 50; magic; none; auto; 
1263440; Void Slash; casting; 1.0; 1.0; me; high; 35; physical; none; auto; 
1263297; Crashing Void; casting; 1.0; 1.0; aoe; high; 35; magic; kb; auto; 
1263523; Overload; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1263399; Oozing Slam; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1266001; Backlash; casting; 1.0; 1.0; aoe; norm; 35; magic; kb; auto; 
1265421; Dirge of Despair; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1263542; Mass Void Infusion; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
245742; Shadow Pounce; casting; 1.0; 1.0; me; norm; 35; physical; none; auto; 
=== Seat of the Triumvirate - Avoidable (Frontal/Swirly)
1262335; Void Cleave; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1268916; Null Palm; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1264196; Disintegrate; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1265463; Discordant Beam; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1269183; Void Burst; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1262429; Eruption; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1263282; Decimate; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1280065; Phase Dash; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1269468; Rupture; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
=== Pit of Saron
1258439; Frostbane Slash; casting; 1.0; 1.0; me; high; 35; physical; none; auto; 
1264287; Blight Smash; casting; 1.0; 1.0; me; high; 35; physical; none; auto; 
1261546; Orebreaker; casting; 1.0; 1.0; me; high; 35; physical; stun; auto; 
1262582; Scourgelord's Brand; casting; 1.0; 1.0; me; high; 35; physical; kb; auto; 
1263671; Scourgelord's Reckoning; casting; 1.0; 1.0; aoe; high; 50; magic; none; auto; 
1271678; Shade Bomb; casting; 1.0; 1.0; aoe; high; 35; magic; none; auto; 
1264027; Shade Shift; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1264336; Plague Expulsion; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1261847; Cryostomp; casting; 1.0; 1.0; aoe; norm; 35; physical; none; auto; 
1276648; Bone Infusion; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1276948; Ice Barrage; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1263000; Festering Pulse; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1259226; Focused Guard; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1261806; Siphoning Chill; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
=== Pit of Saron - Avoidable (Frontal/Swirly)
1278963; Dark Rupture; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1278986; Frost Breath; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1259188; Cryoburst; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1259205; Cryopatch; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1264299; Blight; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1264349; Plague Globs; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1261299; Throw Saronite; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1261799; Saronite Sludge; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1272433; Ore Chunks; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1263756; Death's Grasp; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1262745; Rime Blast; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
=== Skyreach
154110; Fiery Smash; casting; 1.0; 1.0; aoe; high; 50; magic; none; auto; 
154135; Supernova; casting; 1.0; 1.0; aoe; high; 35; magic; none; auto; 
1253519; Burning Claws; casting; 1.0; 1.0; me; high; 35; physical; none; auto; 
153757; Fan of Blades; casting; 1.0; 1.0; aoe; norm; 35; physical; none; auto; 
1253510; Sunbreak; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1254380; Shear; casting; 1.0; 1.0; me; norm; 35; magic; none; auto; 
1253538; Scorching Ray; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
=== Skyreach - Avoidable (Frontal/Swirly)
1255922; Wind Blast; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1258217; Solar Fire; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1253448; Solar Nova; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
156793; Chakram Vortex; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1255472; Dive; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1258152; Wind Chakram; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1281874; Heat Exhaustion; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1253416; Blaze of Glory; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1253840; Lens Flare; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
154043; Blazing Ground; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
=== Windrunner Spire
466064; Searing Beak; casting; 1.0; 1.0; me; high; 35; physical; none; auto; 
472888; Bone Hack; casting; 1.0; 1.0; me; high; 35; physical; none; auto; 
467620; Rampage; casting; 1.0; 1.0; me; high; 35; physical; none; auto; 
472662; Tempest Slash; casting; 1.0; 1.0; me; high; 35; physical; none; auto; 
1277799; Brutal Chop; casting; 1.0; 1.0; me; norm; 50; physical; none; auto; 
1216985; Puncturing Bite; casting; 1.0; 1.0; aoe; norm; 35; physical; none; auto; 
1216963; Spore Dispersal; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1270618; Flame Nova; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
472736; Debilitating Shriek; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1216042; Squall Leap; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
467040; Burning Gale; casting; 1.0; 1.0; aoe; norm; 35; magic; kb; auto; 
472043; Rallying Bellow; casting; 1.0; 1.0; aoe; norm; 35; physical; none; auto; 
471643; Interrupting Screech; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
=== Windrunner Spire - Avoidable (Frontal/Swirly)
473644; Phial Toss; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
473649; Shattered Phial; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
473776; Fetid Spew; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
473789; Fetid Bile; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1216834; Acidic Demise; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1216449; Arrow Rain; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
471648; Break Ranks; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1217763; Fire Breath; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
466556; Flaming Updraft; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1252548; Fiery Landing; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
472745; Splattering Spew; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
472777; Gunk Splatter; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
472053; Reckless Leap; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1283357; Falling Rubble; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
468429; Bullseye Windblast; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
468442; Billowing Wind; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
472556; Arrow Rain; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
474528; Bolt Gale; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1253978; Gust Shot; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
467120; Ignited Embers; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
=== Magister's Terrace
1280113; Hulking Fragment; casting; 1.0; 1.0; me; high; 50; magic; kb; auto; 
474496; Repulsing Slam; casting; 1.0; 1.0; me; high; 35; physical; kb; auto; 
1214081; Arcane Expulsion; casting; 1.0; 1.0; aoe; norm; 35; magic; kb; auto; 
1225193; Wave of Silence; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
473258; Crowd Dispersal; casting; 1.0; 1.0; aoe; norm; 35; magic; kb; auto; 
1264687; Devouring Strike; casting; 1.0; 1.0; me; norm; 35; magic; none; auto; 
1265977; Consuming Shadows; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1224299; Astral Grasp; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1254336; Ignition; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
=== Magister's Terrace - Avoidable (Frontal/Swirly)
1254301; Flamestrike; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1283901; Shield Slam; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1224903; Suppression Zone; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1284954; Cosmic Sting; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1215087; Unstable Void Essence; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1284633; Stygian Ichor; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1282050; Arcane Beam; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
=== Maisara Caverns
1266480; Flanking Spear; casting; 1.0; 1.0; me; high; 35; physical; kb; auto; 
1251023; Spiritbreaker; casting; 1.0; 1.0; me; high; 35; physical; kb; auto; 
1259810; Shattered Totem; casting; 1.0; 1.0; aoe; high; 35; magic; none; auto; 
1256047; Deafening Roar; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1259631; Staggering Blow; casting; 1.0; 1.0; me; norm; 35; physical; none; auto; 
1256059; Rending Gore; casting; 1.0; 1.0; me; norm; 35; physical; none; auto; 
1246666; Infected Pinions; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1248879; Deathgorged Vessel; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1256561; Crunch Armor; casting; 1.0; 1.0; me; norm; 35; physical; none; auto; 
=== Maisara Caverns - Avoidable (Frontal/Swirly)
1257780; Shredding Talons; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1258475; Magma Surge; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1260648; Barrage; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1249479; Carrion Swoop; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1252054; Unmake; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1257155; Rain of Toads; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1258806; Ritual Firebrand; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1263336; Shadow Burst; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1257895; Ancestral Crush; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1259651; Soulstorms; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1259677; Rend Souls; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1243752; Icy Slick; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1243900; Fetid Quillstorm; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1251833; Soulrot; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1252611; Coalesced Death; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1248980; Volatile Essence; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1252676; Crush Souls; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1253779; Spectral Decay; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1253909; Soul Expulsion; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1252816; Chill of Death; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1259772; Umbral Vortex; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
=== Nexus Point Xenas
1252883; Devour the Unworthy; casting; 1.0; 1.0; aoe; high; 50; magic; none; auto; 
1253950; Searing Rend; casting; 1.0; 1.0; me; high; 35; physical; none; auto; 
1271511; Core Exposure; casting; 1.0; 1.0; aoe; high; 35; magic; none; auto; 
1252062; Entropic Leech; casting; 1.0; 1.0; me; norm; 35; magic; none; auto; 
1252076; Dark Beckoning; casting; 1.0; 1.0; aoe; norm; 35; magic; kb; auto; 
1252406; Dreadbellow; casting; 1.0; 1.0; aoe; norm; 35; magic; kb; auto; 
1252414; Nullwark Blast; casting; 1.0; 1.0; me; norm; 35; magic; none; auto; 
1257701; Searing Rend; casting; 1.0; 1.0; me; norm; 35; physical; none; auto; 
1276485; Sparkburn; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
1247937; Umbral Lash; casting; 1.0; 1.0; me; norm; 35; magic; none; auto; 
1249014; Eclipsing Step; casting; 1.0; 1.0; aoe; norm; 35; magic; none; auto; 
=== Nexus Point Xenas - Avoidable (Frontal/Swirly)
1257105; Erratic Zap; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1252436; Void Lash; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1258684; Void Ritual; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1257746; Radiant Scar; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1264354; Luciferin Flare; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1251626; Leyline Array; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Frontal
1257509; Corespark Detonation; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1264042; Arcane Spill; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
1253855; Brilliant Dispersion; casting; 1.0; 1.0; aoe; low; 35; magic; none; custom; Swirly
```

## 2) Interrupt/Stun List — วางลง Interrupt/Stun sub-tab

```
# GeRODPS Interrupt/Stun — generated import
# WARNING: Import จะแทนที่ Spell List ทั้งหมด (list section เท่านั้น — triggers/timers/spec ไม่แตะ)
[list]  # spellID; name; flag; pri; onlyMe; dontTank; stunIfKickCD; ovTimerOn; ovTimer; ovTtsOn; ovTts
=== Algeth'ar Academy
388392; Monotonous Lecture; hikick; 30; 0; 0; 0; 0; 50; 0;
388862; Surge; kick; 20; 0; 0; 0; 0; 50; 0;
1279627; Arcane Bolt; kick; 20; 0; 0; 0; 0; 50; 0;
=== Seat of the Triumvirate
1277340; Shadowmend; hikick; 30; 0; 0; 0; 0; 50; 0;
1262523; Summon Voidcaller; hikick; 30; 0; 0; 0; 0; 50; 0;
248831; Dread Screech; hikick; 30; 0; 0; 0; 0; 50; 0;
244750; Mind Blast; kick; 20; 0; 0; 0; 0; 50; 0;
1262510; Umbral Bolt; kick; 20; 0; 0; 0; 0; 50; 0;
1262526; Abyssal Enhancement; kick; 20; 0; 0; 0; 0; 50; 0;
=== Pit of Saron
1271479; Netherburst; hikick; 30; 0; 0; 0; 0; 50; 0;
1271074; Icy Blast; hikick; 30; 0; 0; 0; 0; 50; 0;
1258997; Plungegrip; hikick; 30; 0; 0; 0; 0; 50; 0;
1278893; Death Bolt; hikick; 30; 0; 0; 0; 0; 50; 0;
1258431; Shadow Bolt; kick; 20; 0; 0; 0; 0; 50; 0;
1258436; Ice Bolt; kick; 20; 0; 0; 0; 0; 50; 0;
1262941; Plague Bolt; kick; 20; 0; 0; 0; 0; 50; 0;
1264186; Shadowbind; kick; 20; 0; 0; 0; 0; 50; 0;
=== Skyreach
1255377; Repel; hikick; 30; 0; 0; 0; 0; 50; 0;
152953; Blinding Light; hikick; 30; 0; 0; 0; 0; 50; 0;
154396; Solar Blast; hikick; 30; 0; 0; 0; 0; 50; 0;
1254669; Solar Bolt; kick; 20; 0; 0; 0; 0; 50; 0;
=== Windrunner Spire
473663; Pulsing Shriek; hikick; 30; 0; 0; 0; 0; 50; 0;
472724; Shadow Bolt; kick; 20; 0; 0; 0; 0; 50; 0;
1216592; Chain Lightning; kick; 20; 0; 0; 0; 0; 50; 0;
1216135; Spirit Bolt; kick; 20; 0; 0; 0; 0; 50; 0;
1216819; Fungal Bolt; kick; 20; 0; 0; 0; 0; 50; 0;
473794; Poison Blades; kick; 20; 0; 0; 0; 0; 50; 0;
473657; Shadow Bolt; kick; 10; 0; 0; 0; 0; 50; 0;
=== Magister's Terrace
468966; Polymorph; hikick; 30; 0; 0; 0; 0; 50; 0;
1254294; Pyroblast; hikick; 30; 0; 0; 0; 0; 50; 0;
1264693; Terror Wave; hikick; 30; 0; 0; 0; 0; 50; 0;
468962; Arcane Bolt; kick; 20; 0; 0; 0; 0; 50; 0;
1248327; Shadow Bolt; kick; 20; 0; 0; 0; 0; 50; 0;
=== Maisara Caverns
1256008; Hex; hikick; 30; 0; 0; 0; 0; 50; 0;
1257716; Reanimation; hikick; 30; 0; 0; 0; 0; 50; 0;
1250708; Necrotic Convergence; hikick; 30; 0; 0; 0; 0; 50; 0;
1266381; Hooked Snare; kick; 20; 0; 0; 0; 0; 50; 0;
1264327; Shadowfrost Blast; kick; 20; 0; 0; 0; 0; 50; 0;
1259182; Piercing Screech; kick; 20; 0; 0; 0; 0; 50; 0;
1263292; Shrink; kick; 20; 0; 0; 0; 0; 50; 0;
1256015; Shadow Bolt; kick; 10; 0; 0; 0; 0; 50; 0;
1259255; Spirit Rend; kick; 10; 0; 0; 0; 0; 50; 0;
=== Nexus Point Xenas
1285445; Arcane Explosion; hikick; 30; 0; 0; 0; 0; 50; 0;
1258681; Nullify; hikick; 30; 0; 0; 0; 0; 50; 0;
1257601; Divine Guile; hikick; 30; 0; 0; 0; 0; 50; 0;
1271094; Umbra Bolt; kick; 20; 0; 0; 0; 0; 50; 0;
1263892; Holy Bolt; kick; 20; 0; 0; 0; 0; 50; 0;
```

## วิธี Import ในเกม
1. เปิด Rotation MainFrame → tab **Defense Mechanism**
2. **Defensive** sub-tab → ปุ่ม Import/Export → วางบล็อก (1) → **Import (โหลดทับ list)**
3. **Interrupt/Stun** sub-tab → ปุ่ม Import/Export → วางบล็อก (2) → **Import (โหลดทับ)**
4. ปิด MainFrame → **Save & Reload** (ข้อมูลถึง AHK ตอน /reload)
