-- claude/geo [geo_index]  - geo calibration from DISCOVERED tiles (fair play: hidden=false only, no ore/cavern sight).
-- Per rock layer (geolayer_index) of the world geology (geo_biomes[GEO].layers): observed z range, count, water_table tiles,
-- and the resulting estimated offset OFF (z = OFF - depth d, depths from top_height/bottom_height, d = -height).
-- Run 4 (Canyonsyrups): whole map GEO 110 (world tile 4,10). Output JSON; 'vorhersage' = expected z ranges per layer at the estimated OFF.
-- Extra: open tiles below z<=ceil (cavern contact? = discovered EMPTY/FLOOR/RAMP tiles that do NOT belong to our buildings) -> field 'offen_tief'.
-- HEAVY: runs in the game's main thread over every map block (BUG-415). One pass from the top down (layer statistics
-- and cavern hint together); after --budget milliseconds (default 3000) it stops after the current level and the
-- answer has unvollstaendig=true and gescannt_bis_z (lower levels are missing). Not for polling.
-- Arguments: claude/geo [geo_index [off [ceil]]] [--budget ms]
local util = reqscript('claude/util')
if not util.require_fort() then return end
local a, budget = {}, 3000
do
  local raw = { ... }
  local i = 1
  while i <= #raw do
    if raw[i] == '--budget' then budget = tonumber(raw[i + 1]) or budget i = i + 2
    else a[#a + 1] = raw[i] i = i + 1 end
  end
end
local function now_ms()
  local ok, t = pcall(dfhack.getTickCount)
  if ok and type(t) == 'number' then return t end
  return os.clock() * 1000
end
local mx, my, mz = dfhack.maps.getTileSize()
local rx, ry = dfhack.maps.getTileBiomeRgn(mx // 2, my // 2, mz - 19)
local rb = dfhack.maps.getRegionBiome(rx, ry)
local GEO = tonumber(a[1]) or (rb and rb.geo_index) or 110
local gb = df.global.world.world_data.geo_biomes[GEO]
local inorg = df.global.world.raws.inorganics.all

local obs = {}   -- idx -> {zmin,zmax,n,wt}
-- Cavern hint: discovered open tiles below the build level (bau tunnels/stairs also produce FLOOR)
local ceil = tonumber(a[3]) or 97
local OPEN = { FLOOR = true, EMPTY = true, RAMP = true, BOULDER = true, PEBBLES = true, SHRUB = true }
local offen = {}
local t0, stopped_at = now_ms(), nil
for bz = mz - 1, 0, -1 do
  for bx = 0, mx // 16 - 1 do
    for by = 0, my // 16 - 1 do
      local b = dfhack.maps.getBlock(bx, by, bz)
      if b then
        for i = 0, 15 do for j = 0, 15 do
          local d = b.designation[i][j]
          if not d.hidden then
            local at = df.tiletype.attrs[b.tiletype[i][j]]
            local m = df.tiletype_material[at.material]
            if m == 'SOIL' or m == 'STONE' or m == 'MINERAL' then
              local o = obs[d.geolayer_index] or { zmin = 999, zmax = -1, n = 0, wt = 0 }
              o.zmin = math.min(o.zmin, bz) o.zmax = math.max(o.zmax, bz) o.n = o.n + 1
              if d.water_table then o.wt = o.wt + 1 end
              obs[d.geolayer_index] = o
            end
            if bz <= ceil and OPEN[df.tiletype_shape[at.shape]] then offen[bz] = (offen[bz] or 0) + 1 end
          end
        end end
      end
    end
  end
  if bz > 0 and now_ms() - t0 > budget then stopped_at = bz break end
end

local layers, offs = {}, {}
for i = 0, #gb.layers - 1 do
  local l = gb.layers[i]
  local o = obs[i]
  local row = { idx = i, gestein = inorg[l.mat_index].id, tiefe = (-l.top_height) .. '..' .. (-l.bottom_height) }
  if o then
    row.z_beobachtet = o.zmin .. '..' .. o.zmax
    row.kacheln = o.n
    row.water_table = o.wt
    -- Offset from the top edge (zmax corresponds to depth -top_height, if the layer is not cut off at the top) and bottom edge
    row.off_top = o.zmax + (-l.top_height)
    row.off_bot = o.zmin + (-l.bottom_height)
    offs[#offs + 1] = row.off_top
  end
  local veins = {}
  for k = 0, #l.vein_mat - 1 do veins[#veins + 1] = inorg[l.vein_mat[k]].id .. '/t' .. l.vein_type[k] end
  row.adern = table.concat(veins, ' ')
  layers[#layers + 1] = row
end

table.sort(offs)
local off = a[2] and tonumber(a[2]) or (offs[1] and offs[math.ceil(#offs / 2)]) or (mz - 19 - 1)
local pred = {}
for i = 0, #gb.layers - 1 do
  local l = gb.layers[i]
  pred[#pred + 1] = ('%s d%d..%d -> z%d..%d'):format(inorg[l.mat_index].id, -l.top_height, -l.bottom_height, off + l.top_height, off + l.bottom_height)
end

local of = {}
for z, n in pairs(offen) do of[#of + 1] = 'z' .. z .. '=' .. n end
table.sort(of)

util.emit({ geo = GEO, weltkachel = rx .. ',' .. ry, off_geschaetzt = off, regel = 'z = OFF - d (OFF aus beobachteten Schichten; Bodenschichten d0-3 mitgezaehlt)',
  schichten = layers, vorhersage = pred, offen_tief_ab_z = ceil, offen_tief = of, ms = math.floor(now_ms() - t0),
  unvollstaendig = stopped_at and true or nil, gescannt_bis_z = stopped_at or 0 })
