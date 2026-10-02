-- claude/area [z [x0 y0 [w h]]] - map section as a character grid with coordinates.
-- Without arguments: 60x40 around the center of mass of the dwarves. Maximum 100x100.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local a = { ... }
local mx, my, mz = dfhack.maps.getTileSize()

-- Default center: where most dwarves are
local zc, sx, sy = {}, {}, {}
for _, u in ipairs(util.citizens()) do
  local p = u.pos
  if p.x >= 0 then
    zc[p.z] = (zc[p.z] or 0) + 1; sx[p.z] = (sx[p.z] or 0) + p.x; sy[p.z] = (sy[p.z] or 0) + p.y
  end
end
local cz, best = mz // 2, -1
for z, n in pairs(zc) do if n > best then best, cz = n, z end end

local z = tonumber(a[1]) or cz
local w = math.min(tonumber(a[4]) or 60, 100)
local h = math.min(tonumber(a[5]) or 40, 100)
local x0, y0 = tonumber(a[2]), tonumber(a[3])
if not x0 then
  local cx = zc[z] and sx[z] // zc[z] or (zc[cz] and sx[cz] // zc[cz]) or mx // 2
  local cy = zc[z] and sy[z] // zc[z] or (zc[cz] and sy[cz] // zc[cz]) or my // 2
  x0, y0 = cx - w // 2, cy - h // 2
end
w, h = math.min(w, mx), math.min(h, my)
x0 = math.max(0, math.min(mx - w, x0))
y0 = math.max(0, math.min(my - h, y0))
z = math.max(0, math.min(mz - 1, z))

local SH, MT = df.tiletype_shape, df.tiletype_material
local GRASS = { GRASS_LIGHT = true, GRASS_DARK = true, GRASS_DRY = true, GRASS_DEAD = true }
local TREE = { TREE = true, ROOT = true, MUSHROOM = true }

local function terrain(tt)
  local at = df.tiletype.attrs[tt]
  local shape, mat = SH[at.shape], MT[at.material]
  if shape == 'WALL' then
    if TREE[mat] then return 'T' end
    if mat == 'SOIL' then return ',' end
    if mat == 'MINERAL' then return '*' end
    if mat == 'CONSTRUCTION' then return 'C' end
    if mat == 'FROZEN_LIQUID' then return 'I' end
    return '#'
  end
  if shape == 'FORTIFICATION' then return 'F' end
  if shape == 'STAIR_UP' then return '<' end
  if shape == 'STAIR_DOWN' then return '>' end
  if shape == 'STAIR_UPDOWN' then return 'X' end
  if shape == 'RAMP' then return '^' end
  if shape == 'RAMP_TOP' then return 'v' end
  if shape == 'EMPTY' or shape == 'NONE' then return ' ' end
  if shape == 'TRUNK_BRANCH' or shape == 'BRANCH' or shape == 'TWIG' then return 'T' end
  if shape == 'SAPLING' then return 't' end
  if shape == 'BOULDER' then return 'o' end
  if shape == 'SHRUB' then return '"' end
  if TREE[mat] then return 'T' end
  if mat == 'CONSTRUCTION' then return '+' end
  if GRASS[mat] then return '"' end
  return '.'
end

local grid = {}
for yy = 0, h - 1 do
  local row = {}
  for xx = 0, w - 1 do
    local x, y = x0 + xx, y0 + yy
    local blk = dfhack.maps.getTileBlock(x, y, z)
    local ch = ' '
    if blk then
      local des = blk.designation[x % 16][y % 16]
      if des.hidden then
        ch = '?'
      elseif des.flow_size > 0 then
        local magma = des.liquid_type == true or des.liquid_type == df.tile_liquid.Magma
        ch = magma and '%' or '~'
      else
        ch = terrain(blk.tiletype[x % 16][y % 16])
        if des.dig ~= df.tile_dig_designation.No then ch = 'd' end
      end
    end
    row[xx + 1] = ch
  end
  grid[yy + 1] = row
end

-- Overlay buildings
local BT = df.building_type
local BCH = { Workshop = 'W', Furnace = 'W', Stockpile = 'S', Bed = 'b', Door = 'D',
              Table = 'n', Chair = 'n', Wagon = 'w', FarmPlot = 'f' }
for _, b in ipairs(df.global.world.buildings.all) do
  local tname = BT[b:getType()]
  if b.z == z and tname ~= 'Construction' and tname ~= 'Civzone' then
    local ch = BCH[tname] or 'B'
    for y = math.max(b.y1, y0), math.min(b.y2, y0 + h - 1) do
      for x = math.max(b.x1, x0), math.min(b.x2, x0 + w - 1) do
        if grid[y - y0 + 1][x - x0 + 1] ~= '?' then grid[y - y0 + 1][x - x0 + 1] = ch end
      end
    end
  end
end

-- Overlay units
for _, u in ipairs(df.global.world.units.active) do
  local p = u.pos
  if p.z == z and p.x >= x0 and p.x < x0 + w and p.y >= y0 and p.y < y0 + h
     and dfhack.units.isActive(u) and not dfhack.units.isDead(u) and not util.unit_hidden(u) then
    local ch = 'a'
    if dfhack.units.isCitizen(u) then ch = '@'
    elseif dfhack.units.isDanger(u) then ch = '!' end
    grid[p.y - y0 + 1][p.x - x0 + 1] = ch
  end
end

-- Output with coordinate axes: tens and ones row at the top, y value on the left
local tens, ones = {}, {}
for xx = 0, w - 1 do
  local x = x0 + xx
  tens[xx + 1] = (x % 10 == 0) and tostring((x // 10) % 10) or ' '
  ones[xx + 1] = tostring(x % 10)
end
local lines = { '     ' .. table.concat(tens), '     ' .. table.concat(ones) }
for yy = 1, h do
  lines[#lines + 1] = string.format('%4d ', y0 + yy - 1) .. table.concat(grid[yy])
end

print(string.format('z=%d  x=%d..%d  y=%d..%d  (Karte %dx%dx%d)', z, x0, x0 + w - 1, y0, y0 + h - 1, mx, my, mz))
print(table.concat(lines, '\n'))
print('Legende: #Fels ,Erde *Erz/Edelstein-Ader TBaum tSetzling "Gras/Busch .Boden oFelsbrocken ' ..
      '(Leerzeichen)=offen/Luft ?unentdeckt ~Wasser %Magma <>X Treppen ^Rampe vRampenoberseite ' ..
      '+gebauter Boden CKonstruktion FSchiessscharte dGrab-Auftrag W Werkstatt S Lager b Bett D Tuer ' ..
      'n Moebel f Feld w Wagen B sonst. Gebaeude @Zwerg !Feind a Tier')
