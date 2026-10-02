--@ module = true
-- Raster stages for claude/raster: {name, z, x1,y1,x2,y2}. Run 5 (Windrings), scope auslastung 01.10. J104:
-- tin/coal exploration z121 + z124 (chert, cassiterite/coal/gems) NORTH and SOUTH of the existing raster (x69..131, y83..107).
-- Raster spacing 3 (every 3rd row, exposes the neighboring rows). Connection: columns x=75/99/123 (existing north-south corridors end at y83 and y107).
-- Names with a leading number -> order (raster sorts by the first number in the name). ~250-300 tiles per stage.
-- Fair play: dig orders only (wall tiles), reveal nothing; raster.lua filters aquifer/barrier/layout tiles itself.
stages = {}
local function add(name, z, x1, y1, x2, y2) stages[#stages + 1] = { name, z, x1, y1, x2, y2 } end
local ZS = { 121, 124 }
local COLS = { 75, 99, 123 }
-- Stage 1: north columns (y59..82)
for _, z in ipairs(ZS) do for _, x in ipairs(COLS) do add('N1_Nordspalten', z, x, 59, x, 82) end end
-- Stages 2..5: north rows y=80,77 | 74,71 | 68,65 | 62,59
local nrows = { { 80, 77 }, { 74, 71 }, { 68, 65 }, { 62, 59 } }
for i, rows in ipairs(nrows) do
  for _, z in ipairs(ZS) do for _, y in ipairs(rows) do add('N' .. (i + 1) .. '_NordReihen', z, 69, y, 131, y) end end
end
-- Stage 6: south columns (y108..131)
for _, z in ipairs(ZS) do for _, x in ipairs(COLS) do add('N6_Suedspalten', z, x, 108, x, 131) end end
-- Stages 7..10: south rows y=110,113 | 116,119 | 122,125 | 128,131
local srows = { { 110, 113 }, { 116, 119 }, { 122, 125 }, { 128, 131 } }
for i, rows in ipairs(srows) do
  for _, z in ipairs(ZS) do for _, y in ipairs(rows) do add('N' .. (i + 6) .. '_SuedReihen', z, 69, y, 131, y) end end
end

-- ===== erkundung 01.10. (orchestrator: queue never < 100): residence/training/storage/temple halls in ore-free claystone z115-z119 (bau coordinates the room layout).
-- Everything >= z104, above the ore levels, far above the cavern; water tunnel (x>=127,y=99,z128 / x=180) untouched. Connection: shaft column (99,95) + link corridors x=99.
add('N11_Wohn1', 116, 80, 85, 118, 94)
add('N11_Wohn1', 116, 99, 102, 99, 106)
add('N12_Wohn2', 116, 80, 107, 118, 114)
add('N13_Uebung', 117, 99, 96, 99, 96)
add('N13_Uebung', 117, 80, 97, 118, 105)
add('N14_Lager2', 119, 80, 97, 118, 104)
add('N14_Lager2', 119, 80, 111, 118, 118)
add('N15_Tempel', 115, 99, 96, 99, 99)
add('N15_Tempel', 115, 84, 100, 114, 110)
add('N16_Wohn3', 116, 60, 85, 79, 114)
add('N17_Wohn4', 116, 119, 85, 126, 114)

-- ===== erkundung 01.10. follow-up stages N18..N25 (orchestrator: queue >= 120). Only z >= 104 (here z105..z121), no aquifer, water barrier boxes (x>=127,y97..101,z127..129; x=180; emergency wall (128,99,z128)) never touched.
-- N18 dolomite/flux z110 y107..131 (columns x=75/99/123 + rows, raster 3)
for _, x in ipairs({ 75, 99, 123 }) do add('N18_Dolomit', 110, x, 107, x, 131) end
for _, y in ipairs({ 107, 113, 119, 122, 125, 128, 131 }) do add('N18_Dolomit', 110, 70, y, 130, y) end
-- N19/N20 copper/iron z105 (siltstone: tetrahedrite, hematite) south y144..170 and north y20..47
for _, x in ipairs({ 75, 99, 123 }) do add('N19_ErzSued105', 105, x, 144, x, 170) end
for y = 146, 170, 3 do add('N19_ErzSued105', 105, 60, y, 140, y) end
for _, x in ipairs({ 75, 99, 123 }) do add('N20_ErzNord105', 105, x, 20, x, 47) end
for y = 23, 44, 3 do add('N20_ErzNord105', 105, 60, y, 140, y) end
-- N21 magnetite/iron z112 (dolomite) south/north, row spacing 6
for _, x in ipairs({ 75, 99, 123 }) do add('N21_Erz112', 112, x, 141, x, 170) add('N21_Erz112', 112, x, 20, x, 48) end
for y = 146, 170, 6 do add('N21_Erz112', 112, 60, y, 140, y) end
for y = 23, 47, 6 do add('N21_Erz112', 112, 60, y, 140, y) end
-- N22/N23 tin z121+z124 (chert, cassiterite) north y32..58 and south y132..158
for _, z in ipairs({ 121, 124 }) do
  for _, x in ipairs({ 75, 99, 123 }) do add('N22_ZinnNord', z, x, 32, x, 58) add('N23_ZinnSued', z, x, 132, x, 158) end
  for y = 35, 56, 3 do add('N22_ZinnNord', z, 69, y, 131, y) end
  for y = 134, 155, 3 do add('N23_ZinnSued', z, 69, y, 131, y) end
end
-- N24 hall extension west/east (claystone/chert-free): workshop/storage/training halls for pop 200+
add('N24_HallenWO', 118, 60, 85, 79, 114)
add('N24_HallenWO', 118, 119, 85, 126, 114)
add('N24_HallenWO', 119, 60, 97, 79, 118)
add('N24_HallenWO', 119, 119, 97, 126, 118)
add('N24_HallenWO', 117, 60, 97, 79, 105)
add('N24_HallenWO', 117, 119, 97, 126, 105)
-- N25 large breeding/storage hall z120 (claystone) and z115 extension
add('N25_Zuchthalle', 120, 80, 85, 118, 114)
add('N25_Zuchthalle', 115, 60, 100, 83, 110)
add('N25_Zuchthalle', 115, 115, 100, 126, 110)

-- ===== erkundung N26..N35 (orchestrator J109: queue empty, idle 75 %). Only z >= 104, no aquifer/cavern; taboo: water tunnel (x>=127,y97..101,z127..129; x=180; emergency wall (128,99,z128)).
-- N26 farm halls in sand z131 (plateau z133 x66..101; roof z132 + surface): link corridor y=94 to stairs T1 (99,94,z131)
add('N26_FarmSand', 131, 66, 94, 98, 94)
add('N26_FarmSand', 131, 66, 70, 95, 93)
-- N27 residence hall south z116 (connects to Wohn2/3/4 y114)
add('N27_WohnSued', 116, 60, 115, 126, 131)
-- N28 storage hall south z119 (connects at y118)
add('N28_LagerSued', 119, 60, 119, 126, 135)
-- N29 temple/guilds/library north z115 (connects shaft column (99,95) and y100)
add('N29_TempelNord', 115, 60, 86, 126, 99)
-- N30 copper/iron reserve z105 (siltstone) west/east: row filling + outer lines
for _, y in ipairs({ 86, 92, 98, 104 }) do add('N30_Cu105', 105, 50, y, 89, y) add('N30_Cu105', 105, 109, y, 135, y) end
for _, y in ipairs({ 89, 95, 101 }) do add('N30_Cu105', 105, 20, y, 49, y) add('N30_Cu105', 105, 136, y, 170, y) end
-- N31 tin reserve z121/z124 west/east
for _, z in ipairs({ 121, 124 }) do
  for y = 83, 107, 3 do add('N31_ZinnWO', z, 40, y, 69, y) add('N31_ZinnWO', z, 131, y, 170, y) end
end
-- N32/N33/N34/N35 halls north and south, dolomite north
add('N32_HallenNord', 118, 99, 85, 99, 94)
add('N32_HallenNord', 118, 80, 70, 118, 84)
add('N33_HallenNord2', 119, 80, 75, 118, 96)
for _, x in ipairs({ 99 }) do add('N34_DolomitNord', 110, x, 60, x, 82) end
for y = 62, 80, 3 do add('N34_DolomitNord', 110, 70, y, 130, y) end
add('N35_UebungSued', 117, 80, 106, 118, 120)

-- ===== erkundung N36..N60 (orchestrator J109: LARGE standing program, >= 15 000 tiles, 34 diggers several hours). raster.lua refills INCREMENTALLY (queue 300..600).
-- Only z >= 104 (here z105..z121), no aquifer/cavern; taboo: water tunnel (x>=127,y97..101,z127..129; x=180; emergency wall (128,99,z128)) -> nothing in z127..z129 from x>=127.
-- Claystone hall levels z115..z120 (ore-free) in north/south/west/east, then dolomite/siltstone halls z107..z114 (yield ore/flux as by-product), ore edges.
add('N36_Z115Sued', 115, 60, 111, 126, 131)
add('N37_Z117Sued', 117, 60, 121, 126, 135)
add('N38_Z118Sued', 118, 60, 115, 126, 135)
add('N39_Z120WO', 120, 60, 85, 79, 114)
add('N39_Z120WO', 120, 119, 85, 126, 114)
add('N40_Z120Nord', 120, 60, 60, 126, 84)
add('N41_Z120Sued', 120, 60, 115, 126, 135)
add('N42_Z119Nord', 119, 60, 75, 79, 96)
add('N42_Z119Nord', 119, 119, 75, 126, 96)
add('N42_Z119Nord', 119, 60, 60, 126, 74)
add('N43_Z118Nord', 118, 60, 70, 79, 84)
add('N43_Z118Nord', 118, 119, 70, 126, 84)
add('N43_Z118Nord', 118, 60, 55, 126, 69)
add('N44_Z117Nord', 117, 60, 75, 126, 96)
add('N45_Z116Nord', 116, 60, 60, 126, 84)
add('N46_Z115Nord', 115, 60, 60, 126, 85)
add('N47_Z108Mitte', 108, 60, 85, 126, 114)
add('N48_Z108NordSued', 108, 60, 115, 126, 131)
add('N48_Z108NordSued', 108, 60, 60, 126, 84)
add('N49_Z114Mitte', 114, 60, 85, 126, 114)
for y = 23, 44, 3 do add('N50_ErzRand105', 105, 20, y, 59, y) add('N50_ErzRand105', 105, 141, y, 170, y) end
for y = 146, 170, 3 do add('N50_ErzRand105', 105, 20, y, 59, y) add('N50_ErzRand105', 105, 141, y, 170, y) end
for _, z in ipairs({ 121, 124 }) do
  for y = 35, 56, 3 do add('N51_ZinnRand', z, 40, y, 68, y) add('N51_ZinnRand', z, 132, y, 170, y) end
  for y = 134, 155, 3 do add('N51_ZinnRand', z, 40, y, 68, y) add('N51_ZinnRand', z, 132, y, 170, y) end
end
add('N52_Z107Mitte', 107, 60, 85, 126, 114)
add('N53_Z111Mitte', 111, 60, 85, 126, 114)
add('N54_Z113Mitte', 113, 60, 85, 126, 114)
add('N55_Z109Mitte', 109, 60, 85, 126, 114)
add('N56_Z107NordSued', 107, 60, 60, 126, 84)
add('N56_Z107NordSued', 107, 60, 115, 126, 131)
add('N57_Z111NordSued', 111, 60, 60, 126, 84)
add('N57_Z111NordSued', 111, 60, 115, 126, 131)
add('N58_Z113NordSued', 113, 60, 60, 126, 84)
add('N58_Z113NordSued', 113, 60, 115, 126, 131)
add('N59_Z109NordSued', 109, 60, 60, 126, 84)
add('N59_Z109NordSued', 109, 60, 115, 126, 131)
add('N60_Z114NordSued', 114, 60, 60, 126, 84)
add('N60_Z114NordSued', 114, 60, 115, 126, 131)

-- Tiles the raster must never designate (Run 3: exploration stairs); Run 4: none.
function reserved(x, y, z) return false end
