-- claude/pilot_reach check sx sy sz x,y,z[+] [x,y,z ...] | dump x1 y1 z1 x2 y2 z2     (df-llm-helper spec v3-11, LIVE-UNTESTED)
-- check: dfhack.maps.canWalkBetween(start, point) for every point in ONE call (walk groups, cheap)
--        -> {"ok":true,"start":[x,y,z],"results":[true,false,...],"via":[false,true,...]} (same order as the arguments).
--        A point on a building tile that blocks walking (well, statue, ...) is not walkable itself (walk group 0):
--        it counts as reachable when a tile around the building (its footprint + 1) is (via = true). An argument
--        'x,y,z+' forces that neighbour test (data/reach.yaml: adjacent: true), also for a tile without a building.
-- dump:  one character per tile for a box (encoding in df_llm_helper/features/_grid.py; 'W' = building tile that blocks walking:
--        occupancy Well/Obstacle); df-llm-helper does the path logic
--        (cause search with/without constructions, what-if walls). Unrevealed tiles are emitted as '?' and nothing
--        else is read about them (fair play). Max 200000 tiles per call.
--        check: results/via have one entry per point argument; unparsable points are false and listed in 'invalid'
--        (0-based indices).
-- Read only: no designations, no buildings, no map changes.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local a = { ... }
local cmd = a[1] or 'check'
-- integer argument; fractions and text -> nil (getTileFlags rejects non-integers with a traceback, BUG-409)
local function n(i)
  local v = tonumber(a[i])
  return v and math.tointeger(v) or nil
end
local MAP = df.global.world.map
local XM, YM, ZM = MAP.x_count, MAP.y_count, MAP.z_count
local SHAPE = df.tiletype_shape
local FLOORISH = {}
for _, nm in ipairs({ 'FLOOR', 'BOULDER', 'PEBBLES', 'SHRUB', 'SAPLING', 'TWIG', 'BROOK_BED', 'BROOK_TOP',
                      'TRUNK_BRANCH' }) do
  if SHAPE[nm] then FLOORISH[SHAPE[nm]] = true end
end

-- walkable buildings that matter for paths: doors/hatches ('D'), traps ('T'); furniture stays floor
local function bchar(x, y, z)
  if not (dfhack.buildings and dfhack.buildings.findAtTile) then return nil end
  local b = dfhack.buildings.findAtTile(x, y, z)
  if not b then return nil end
  local t = b:getType()
  local BT = df.building_type
  if t == BT.Door or t == BT.Hatch then return 'D' end
  if t == BT.Trap then return 'T' end
  return nil
end

-- building tile that blocks walking (well, statue ...): block occupancy Well/Obstacle (= walk group 0 in DF 53)
local OCC = df.tile_building_occ
local function blocked_by_building(x, y, z)
  if not OCC then return false end
  local blk = dfhack.maps.getTileBlock(x, y, z)
  if not blk then return false end
  local o = blk.occupancy[x % 16][y % 16].building
  return o == OCC.Obstacle or o == OCC.Well
end

local function tch(x, y, z)
  if x < 0 or y < 0 or z < 0 or x >= XM or y >= YM or z >= ZM then return '#' end
  local d = dfhack.maps.getTileFlags(x, y, z)
  if not d then return '#' end
  if d.hidden then return '?' end                       -- unrevealed: not judged, nothing more is read
  local tt = dfhack.maps.getTileType(x, y, z)
  local at = tt and df.tiletype.attrs[tt]
  if not at then return '#' end
  local sh = at.shape
  if d.flow_size > 0 then return d.liquid_type == df.tile_liquid.Magma and 'M' or '~' end
  if blocked_by_building(x, y, z) then return 'W' end   -- (a well tile is open space (EMPTY) in DF, so test first)
  local out = d.outside
  if sh == SHAPE.WALL or sh == SHAPE.FORTIFICATION then
    if at.material == df.tiletype_material.CONSTRUCTION then return 'C' end
    if d.water_table then return 'A' end
    return '#'
  end
  if sh == SHAPE.EMPTY or sh == SHAPE.RAMP_TOP or sh == SHAPE.ENDLESS_PIT then
    if out then return "'" end
    return d.subterranean and 'V' or '_'
  end
  if sh == SHAPE.RAMP then return out and '/' or '^' end
  if sh == SHAPE.STAIR_UPDOWN then return out and 'x' or 'X' end
  if sh == SHAPE.STAIR_UP then return '<' end
  if sh == SHAPE.STAIR_DOWN then return '>' end
  if FLOORISH[sh] then
    return bchar(x, y, z) or (out and ',' or '.')
  end
  return '#'
end

-- walkable from the start? -> reached, via_neighbour. A building tile that blocks walking (well, statue, workshop
-- centre ...) never has a walk group itself: test the tiles around the building's footprint (same level) instead.
local function can_reach(start, x, y, z, force_adjacent)
  if dfhack.maps.canWalkBetween(start, xyz2pos(x, y, z)) then return true, false end
  local x1, y1, x2, y2 = x, y, x, y
  local ok, b = pcall(function() return dfhack.buildings.findAtTile(x, y, z) end)
  if ok and b then
    x1, y1, x2, y2 = b.x1 or x, b.y1 or y, b.x2 or x, b.y2 or y
  elseif not force_adjacent then
    return false, false
  end
  for yy = y1 - 1, y2 + 1 do
    for xx = x1 - 1, x2 + 1 do
      if (xx < x1 or xx > x2 or yy < y1 or yy > y2) and xx >= 0 and yy >= 0 and xx < XM and yy < YM
        and dfhack.maps.canWalkBetween(start, xyz2pos(xx, yy, z)) then
        return true, true
      end
    end
  end
  return false, false
end

if cmd == 'check' then
  local sx, sy, sz = n(2), n(3), n(4)
  if not (sx and sy and sz) then util.emit({ ok = false, error = 'check sx sy sz x,y,z[+] ...' }) return end
  local res, via, invalid = {}, {}, {}
  local start = xyz2pos(sx, sy, sz)
  for i = 5, #a do
    local x, y, z, plus = a[i]:match('^(-?%d+),(-?%d+),(-?%d+)(%+?)$')
    if x then
      local r, v = can_reach(start, tonumber(x), tonumber(y), tonumber(z), plus == '+')
      res[#res + 1] = r and true or false
      via[#via + 1] = v and true or false
    else
      -- unparsable point: false in place (results stay aligned 1:1 with the arguments) + listed in 'invalid' (0-based)
      res[#res + 1] = false
      via[#via + 1] = false
      invalid[#invalid + 1] = #res - 1
    end
  end
  local out = { ok = true, start = { sx, sy, sz }, results = res, via = via }
  if #invalid > 0 then out.invalid = invalid end
  if sx < 0 or sy < 0 or sz < 0 or sx >= XM or sy >= YM or sz >= ZM then out.ok, out.error = false, 'start outside the map' end
  util.emit(out)
elseif cmd == 'dump' then
  local x1, y1, z1, x2, y2, z2 = n(2), n(3), n(4), n(5), n(6), n(7)
  if not (x1 and y1 and z1 and x2 and y2 and z2) then util.emit({ ok = false, error = 'dump x1 y1 z1 x2 y2 z2' }) return end
  x1, x2 = math.max(0, math.min(x1, x2)), math.min(XM - 1, math.max(x1, x2))
  y1, y2 = math.max(0, math.min(y1, y2)), math.min(YM - 1, math.max(y1, y2))
  z1, z2 = math.max(0, math.min(z1, z2)), math.min(ZM - 1, math.max(z1, z2))
  if x1 > x2 or y1 > y2 or z1 > z2 then util.emit({ ok = false, error = 'box outside the map' }) return end
  local cells = (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1)
  if cells > 200000 then util.emit({ ok = false, error = 'box too large: ' .. cells .. ' tiles (max 200000)' }) return end
  local levels = {}
  for z = z1, z2 do
    local rows = {}
    for y = y1, y2 do
      local r = {}
      for x = x1, x2 do r[#r + 1] = tch(x, y, z) end
      rows[#rows + 1] = table.concat(r)
    end
    levels[tostring(z)] = rows
  end
  util.emit({ ok = true, origin = { x1, y1 }, box = { x1, y1, z1, x2, y2, z2 }, levels = levels })
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_reach check sx sy sz x,y,z ... | dump x1 y1 z1 x2 y2 z2' })
end
