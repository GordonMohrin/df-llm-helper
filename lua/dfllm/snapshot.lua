-- snapshot (WP7; CONTRACTS §3.4, §7, §9.10): revealed-tile export for Python (bp.topo audit, bp.sites
-- ranking) and snapshot.tile, the one tile query of the other modules.
-- Fair play (§1.4, DESIGN §11.1): a tile counts only if revealed; designation.hidden -> '?' in an
-- export and nil from tile(). Marks: soil (quickfort's farm rule, build.lua:65-81) and cavern
-- (designation.feature_global of revealed tiles, tile-material.lua:255); never water_table or damp.
-- An export runs in slices of CFG.slice tiles per frame ('more'; the ms cadence also runs while
-- paused) and is written to <save>/snap/<id>.json through a .tmp file, then SNAPSHOT_READY (C).
-- BUG-026 (Run 10: an audit export of 58,608 tiles ran through a caravan visit that was then lost): an export waits
-- while another module holds a busy kernel boost (K.busy(): trade with the trade screen open) and resumes where it
-- stopped.
local json = require('dfllm.util.json')
local fio = require('dfllm.io')

local M = {name = 'snapshot', every = {ms = 250}, verbs = {}, on = {}}

M.CFG = {
  slice = 1000,                   -- tiles per frame (DESIGN §4: <= 2,000)
  max_tiles = 250000,             -- refuse bigger boxes (100 x 100 x 25)
  queue = 4,                      -- exports waiting behind the running one
  margin = {16, 16, 2},           -- default box: manifest geometry plus this
  sites = {w = 96, h = 96, below = 8, above = 3},   -- default box without a manifest
  marks_max = 500,
  trap_ttl = 1200,                -- ticks between trap index refreshes for tile()
  liquid_tiles = 4096,            -- tiles one liquids() call may read (FR-47)
  items_tiles = 400,              -- tiles one items_at() call may cover (BUG-009: a building footprint)
  items_max = 200,                -- items one items_at() call returns
  group_pts = 4000,               -- points one groups() call reads (inspect workload: citizens and open jobs)
}
local PURPOSES = {audit = true, sites = true, debug = true}
local ID_OK = '^[A-Za-z0-9_%-]+$'

local job, queue, n_auto    -- running export, waiting exports, generated ids
local yielding             -- BUG-026: the busy module the running export waits for (logged once per wait)
local tt_cache, occ, live_traps, live_jobs

local function int(v) return math.type(v) == 'integer' and v or math.tointeger(v) end

---------------------------------------------------------------- tile classes (§9.10 legend)
local SHAPE = {EMPTY = '_', ENDLESS_PIT = '_', TWIG = '_', FLOOR = '.', BOULDER = '.', PEBBLES = '.',
               SHRUB = '.', SAPLING = '.', BROOK_BED = '.', BROOK_TOP = '.', BRANCH = '.', TRUNK_BRANCH = '.',
               WALL = '#', FORTIFICATION = 'F', STAIR_UP = '<', STAIR_DOWN = '>', STAIR_UPDOWN = 'X',
               RAMP = 'r', RAMP_TOP = 'v'}
local SOIL_MAT = {SOIL = true, GRASS_LIGHT = true, GRASS_DARK = true, GRASS_DRY = true, GRASS_DEAD = true,
                  PLANT = true}
local SOIL_SHAPE = {FLOOR = true, SHRUB = true, SAPLING = true}
local SOLID = {['#'] = true, S = true, C = true, F = true, T = true}
local TRAP_CH = {WeaponTrap = 'W', StoneFallTrap = 'S', CageTrap = 'C', PressurePlate = 'P'}

-- {c, soil} of a tiletype from df.tiletype.attrs (dig.lua:39-90 reads the same attributes)
local function tt_info(tt)
  local r = tt_cache[tt]
  if r then return r end
  r = {c = '?', soil = false}
  pcall(function()
    local a = df.tiletype.attrs[tt]
    local shape = df.tiletype_shape[a.shape]
    local mat = df.tiletype_material[a.material]
    local c = SHAPE[shape] or '.'
    if c == '#' then
      if mat == 'CONSTRUCTION' then c = 'C'
      elseif mat == 'TREE' or mat == 'ROOT' or mat == 'MUSHROOM' then c = 'T'
      elseif df.tiletype_special[a.special] == 'SMOOTH' then c = 'S' end
    end
    r.c, r.soil = c, SOIL_MAT[mat] == true and SOIL_SHAPE[shape] == true
  end)
  tt_cache[tt] = r
  return r
end

local function occ_values()
  local e = df.tile_building_occ
  local function v(name, d)
    local ok, x = pcall(function() return e and e[name] end)
    return ok and int(x) or d
  end
  return {None = v('None', 0), Planned = v('Planned', 1), Passable = v('Passable', 2), Obstacle = v('Obstacle', 3),
          Well = v('Well', 4), Floored = v('Floored', 5), Impassable = v('Impassable', 6), Dynamic = v('Dynamic', 7)}
end

local function flag(t, k)
  local ok, v = pcall(function() return t[k] end)
  if ok then return v end
end

-- bridge gate_flags are raised/raising/lowering (lever.lua:39-41); doors/floodgates closed/...
local function raised(b)
  local gf = flag(b, 'gate_flags')
  if not gf then return nil end
  local v = flag(gf, 'raised')
  if v == nil then v = flag(gf, 'closed') end
  return v
end

local function btype(b)
  local ok, n = pcall(function() return df.building_type[b:getType()] end)
  return ok and n or nil
end

-- char and building name of a Dynamic tile (doors, hatches, bridges, floodgates, grates)
local function dynamic_char(x, y, z)
  local ok, b = pcall(dfhack.buildings.findAtTile, x, y, z)   -- Lua API.txt:2484 (linear scan)
  if not ok or not b then return 'B', '' end
  local t = btype(b) or ''
  if t == 'Door' or t == 'Hatch' then return '+', t end
  if t == 'Bridge' then return raised(b) and 'H' or '=', t end
  if t == 'Floodgate' or t == 'GrateWall' or t == 'BarsVertical' then
    local gf = flag(b, 'gate_flags')
    return (gf and flag(gf, 'closed')) and 'B' or '.', t
  end
  if t == 'GrateFloor' or t == 'BarsFloor' then return '.', t end
  -- live L2: built traps are Dynamic tiles (not Passable), so the trap hall read as walls ('B') and the
  -- audit found no attack path; traps are walked over (levers and other trap types stay 'B')
  if t == 'Trap' then
    local kind = TRAP_CH[df.trap_type[flag(b, 'trap_type') or -1] or '']
    if kind then return '^', t end
  end
  return 'B', t
end

-- traps by 'x,y,z' from buildings.other.TRAP (one pass; levers and track stops are no traps here)
local function trap_index(bbox)
  local idx = {}
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.TRAP) do
      local x, y, z = b.centerx, b.centery, b.z
      if not bbox or (x >= bbox[1] and x <= bbox[4] and y >= bbox[2] and y <= bbox[5] and z >= bbox[3] and z <= bbox[6]) then
        local kind = TRAP_CH[df.trap_type[b.trap_type]]
        if kind then
          local n = 0
          if kind == 'W' then
            for _, ci in ipairs(b.contained_items) do
              local it = ci.item
              if df.item_weaponst:is_instance(it) or df.item_trapcompst:is_instance(it) then n = n + 1 end
            end
          end
          local rt = flag(b, 'ready_timeout')
          idx[x .. ',' .. y .. ',' .. z] = {x, y, z, kind, n, (int(rt) or 0) > 0 and 0 or 1}
        end
      end
    end
  end)
  return idx
end

-- legend char of a revealed tile; traps: index from trap_index; bridges: {'x,y,z' = char} overrides
local function classify(x, y, z, des, oc, traps, bridges)
  if des.hidden then return '?', '' end            -- callers check too; never classify a hidden tile
  local key
  if bridges then
    key = x .. ',' .. y .. ',' .. z
    local bc = bridges[key]
    if bc then return bc, 'Bridge' end
  end
  local info = tt_info(dfhack.maps.getTileType(x, y, z))
  local c, bld = info.c, ''
  local b = oc and int(oc.building) or occ.None
  if b ~= occ.None and b ~= occ.Planned then
    if b == occ.Dynamic then c, bld = dynamic_char(x, y, z)
    elseif b == occ.Passable or b == occ.Floored then
      key = key or (x .. ',' .. y .. ',' .. z)
      if traps and traps[key] then c, bld = '^', 'Trap' elseif not SOLID[c] then c, bld = '.', 'passable' end
    else c, bld = 'B', b == occ.Well and 'Well' or 'impassable' end
  end
  if not SOLID[c] and c ~= 'B' and c ~= 'H' then
    local f = int(des.flow_size) or 0
    if f > 0 then
      local lt = des.liquid_type
      if lt == true or (lt ~= false and lt ~= nil and lt ~= 0) then c = '%'     -- magma (build.lua:41)
      else c = f >= 4 and '~' or 'w' end
    end
  end
  return c, bld, info.soil
end

-- pending designation of a revealed tile (quickfort dig.lua:95-101 has_designation)
local function designation(des, oc)
  local d = des.dig
  if d ~= nil and d ~= false and d ~= 0 then
    local ok, n = pcall(function() return df.tile_dig_designation[d] end)
    if not ok or n ~= 'No' then return ok and type(n) == 'string' and n:lower() or 'dig' end
  end
  local s = int(des.smooth) or 0
  if s == 1 then return 'smooth' elseif s > 1 then return 'engrave' end
  if oc then
    for _, k in ipairs({'carve_track_north', 'carve_track_east', 'carve_track_south', 'carve_track_west'}) do
      local v = flag(oc, k)
      if v and v ~= 0 then return 'track' end
    end
  end
  return ''
end

-- tiles that carry a designation job (dig, channel, ramp, stairs, smooth, engrave, track). DF clears
-- `designation.dig` when it posts the job for a dig designation, so a wall a miner is working on reads as
-- an undesignated wall (live L1: that read was taken for a damp cancel and stopped fortcore twice).
-- quickfort looks these jobs up the same way (internal/quickfort/dig.lua:770 get_dig_job_map).
-- Built once per game tick: world.jobs.list is a linked list of every job.
local function designation_jobs(now)
  if live_jobs and live_jobs.tick == now then return live_jobs.map end
  local map = {}
  pcall(function()
    local attrs = df.job_type.attrs
    local link = df.global.world.jobs.list.next
    local n = 0
    while link and n < 100000 do
      local j = link.item
      if j and attrs[j.job_type].is_designation then
        map[string.format('%d,%d,%d', j.pos.x, j.pos.y, j.pos.z)] = true
      end
      link, n = link.next, n + 1
    end
  end)
  live_jobs = {tick = now, map = map}
  return map
end

---------------------------------------------------------------- public tile query (§7)
-- nil (hidden or invalid) or {c = legend char, dig = pending designation or '', bld = building type
-- (Door, Bridge, Trap, Well, ...), 'passable'/'impassable' (other buildings) or ''}
function M.tile(K, x, y, z)
  x, y, z = int(x), int(y), int(z)
  if not (x and y and z) then return nil end
  local des, oc = dfhack.maps.getTileFlags(x, y, z)
  if not des or des.hidden then return nil end
  local now = K.now().tick
  if not live_traps or now - live_traps.tick >= M.CFG.trap_ttl or now < live_traps.tick then
    live_traps = {tick = now, idx = trap_index(nil)}
  end
  local c, bld = classify(x, y, z, des, oc, live_traps.idx, nil)
  local dig = designation(des, oc)
  if dig == '' and designation_jobs(now)[string.format('%d,%d,%d', x, y, z)] then dig = 'job' end
  -- flow: liquid depth 0..7 of this revealed tile, magma: true for magma (runner: light-aquifer seepage)
  return {c = c, dig = dig, bld = bld, flow = des.flow_size or 0, magma = des.liquid_type == true}
end

-- water tiles of one level rect (FR-47, water's water_sources scan): {{x, y, flow}} of revealed, non-magma
-- tiles with flow >= min (default 1), at most M.CFG.liquid_tiles tiles read and 512 returned per call (the
-- caller slices the box). Hidden tiles are skipped: no water_table, no unrevealed water.
function M.liquids(K, x0, y0, x1, y1, z, min)
  x0, y0, x1, y1, z, min = int(x0), int(y0), int(x1), int(y1), int(z), int(min) or 1
  local out = {}
  if not (x0 and y0 and x1 and y1 and z) or x1 < x0 or y1 < y0 then return out end
  if (x1 - x0 + 1) * (y1 - y0 + 1) > M.CFG.liquid_tiles then return nil, 'rect too large' end
  local getTileFlags = dfhack.maps.getTileFlags
  for y = y0, y1 do
    for x = x0, x1 do
      local des = getTileFlags(x, y, z)
      if des and not des.hidden then
        local f = int(des.flow_size) or 0
        local lt = des.liquid_type
        if f >= min and not (lt == true or (lt ~= false and lt ~= nil and lt ~= 0)) then
          out[#out + 1] = {x, y, f}
          if #out >= 512 then return out end
        end
      end
    end
  end
  return out
end

-- items lying on the revealed tiles of a level rect (BUG-009, Run 9: forbidden items on the footprint of a planned
-- building make the builder cancel "Item blocking site", and nobody hauls a forbidden item away): {{id, x, y}} of
-- the items on the ground there (not in a building, a container or a unit's hands), read from the map blocks' item
-- lists; at most M.CFG.items_tiles tiles per call and M.CFG.items_max items returned. Hidden tiles are skipped.
function M.items_at(K, x0, y0, x1, y1, z)
  x0, y0, x1, y1, z = int(x0), int(y0), int(x1), int(y1), int(z)
  local out = {}
  if not (x0 and y0 and x1 and y1 and z) or x1 < x0 or y1 < y0 then return out end
  if (x1 - x0 + 1) * (y1 - y0 + 1) > M.CFG.items_tiles then return nil, 'rect too large' end
  local getTileFlags, seen = dfhack.maps.getTileFlags, {}
  for by = y0 // 16, y1 // 16 do
    for bx = x0 // 16, x1 // 16 do
      local blk = dfhack.maps.getTileBlock(math.max(x0, bx * 16), math.max(y0, by * 16), z)
      for _, id in ipairs(blk and blk.items or {}) do
        local it = not seen[id] and df.item.find(id)
        seen[id] = true
        local p = it and it.flags.on_ground and it.pos
        if p and p.z == z and p.x >= x0 and p.x <= x1 and p.y >= y0 and p.y <= y1 then
          local des = getTileFlags(p.x, p.y, p.z)
          if des and not des.hidden then
            out[#out + 1] = {id, p.x, p.y}
            if #out >= M.CFG.items_max then return out end
          end
        end
      end
    end
  end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  return out
end

-- units standing on the revealed tiles of a level rect (BUG-015: what stands on and next to a door the lockdown cannot
-- keep forbidden): {{id, x, y}} of the visible living units there, sorted by id; at most M.CFG.items_tiles tiles per
-- call. Hidden units (ambushers) and hidden tiles never count.
function M.units_at(K, x0, y0, x1, y1, z)
  x0, y0, x1, y1, z = int(x0), int(y0), int(x1), int(y1), int(z)
  local out = {}
  if not (x0 and y0 and x1 and y1 and z) or x1 < x0 or y1 < y0 then return out end
  if (x1 - x0 + 1) * (y1 - y0 + 1) > M.CFG.items_tiles then return nil, 'rect too large' end
  local getTileFlags = dfhack.maps.getTileFlags
  for _, u in ipairs(df.global.world.units.active) do
    local p = u.pos
    if p.z == z and p.x >= x0 and p.x <= x1 and p.y >= y0 and p.y <= y1 and not dfhack.units.isDead(u)
       and not dfhack.units.isHidden(u) then
      local des = getTileFlags(p.x, p.y, p.z)
      if des and not des.hidden then out[#out + 1] = {u.id, p.x, p.y} end
    end
  end
  table.sort(out, function(a, b) return a[1] < b[1] end)
  return out
end

-- walk-group query (iter2, care's mood reach): may a walker standing at a reach b? Both are revealed
-- positions {x, y, z} the caller already knows (the moody dwarf, an item on a revealed tile). It is DF's own
-- job-feasibility test (dfhack.maps.canWalkBetween, Lua API.txt; the same question act.link_lever asks for
-- mechanisms). Unknown (bad args, a fault) answers true, so a caller never under-counts on an error.
function M.reach(K, a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' then return true end
  local ax, ay, az, bx, by, bz = int(a.x), int(a.y), int(a.z), int(b.x), int(b.y), int(b.z)
  if not (ax and ay and az and bx and by and bz) then return true end
  local ok, yes = pcall(dfhack.maps.canWalkBetween, xyz2pos(ax, ay, az), xyz2pos(bx, by, bz))
  return not ok or yes == true
end

-- far(K, x, y, z): does a revealed tile lie on another walkable group than the citizens stand on? Food or drink
-- there feeds nobody (live L7: 117 of 137 fruit in cut-off caves, 101 "food days", 35 of 42 starving). The
-- citizens' group is read once per tick; unknown answers false so nothing is under-counted on a fault.
local home_grp
function M.far(K, x, y, z)
  x, y, z = int(x), int(y), int(z)
  if not (x and y and z) then return false end
  local now = K.now().tick
  if not home_grp or home_grp.tick ~= now then
    local g = false
    local ok = pcall(function()
      for _, c in ipairs(dfhack.units.getCitizens(true)) do
        local cg = dfhack.maps.isValidTilePos(c.pos) and dfhack.maps.getWalkableGroup(c.pos)
        if cg and cg ~= 0 then g = cg; break end
      end
    end)
    home_grp = {tick = now, g = ok and g or false}
  end
  if not home_grp.g then return false end
  local ok, grp = pcall(function()
    local pos = xyz2pos(x, y, z)
    return dfhack.maps.isValidTilePos(pos) and dfhack.maps.getWalkableGroup(pos) or 0
  end)
  return ok and grp ~= 0 and grp ~= home_grp.g
end

-- groups(K, pts, near): the walkable group of each point {x, y, z} (economy's inspect workload: which open jobs and idle
-- citizens share a group). With `near`, a tile without a group (the wall a dig job cuts, the trunk a FellTree job fells)
-- answers the first group of its 8 neighbours on the level, then of the tiles above and below. 0 = no walkable group,
-- -1 = hidden, invalid or a fault (callers count -1 as reachable); hidden neighbours are never read. At most
-- M.CFG.group_pts points a call (the rest answer -1).
local NEAR = {{-1, -1, 0}, {0, -1, 0}, {1, -1, 0}, {-1, 0, 0}, {1, 0, 0}, {-1, 1, 0}, {0, 1, 0}, {1, 1, 0},
              {0, 0, 1}, {0, 0, -1}}
local function grp_at(x, y, z)
  if not dfhack.maps.isValidTilePos(x, y, z) then return -1 end
  local des = dfhack.maps.getTileFlags(x, y, z)
  if not des or des.hidden then return -1 end
  return int(dfhack.maps.getWalkableGroup(xyz2pos(x, y, z))) or -1
end
local function grp_near(x, y, z, near)
  local own = grp_at(x, y, z)
  if own ~= 0 or not near then return own end
  for _, d in ipairs(NEAR) do
    local g = grp_at(x + d[1], y + d[2], z + d[3])
    if g > 0 then return g end
  end
  return 0
end
function M.groups(K, pts, near)
  local out, lim = {}, M.CFG.group_pts or 4000
  for i, p in ipairs(type(pts) == 'table' and pts or {}) do
    local g = -1
    if i <= lim and type(p) == 'table' then
      local x, y, z = int(p.x or p[1]), int(p.y or p[2]), int(p.z or p[3])
      if x and y and z then
        local ok, v = pcall(grp_near, x, y, z, near)
        g = ok and v or -1
      end
    end
    out[i] = g
  end
  return out
end

-- outside_near(K, pts, r): open-sky test for the reflex module (FR-49/52: the fort's entrance doors, a predator on a
-- roofed tile). pts = array of {x, y, z}; per point 1 when a revealed tile within r (Chebyshev xy, same z; r 0 = the
-- tile itself) is under the open sky (designation.outside), 0 when none is, -1 for a bad point. Hidden tiles never
-- count (fair play), so an unexplored edge reads 0. One call per batch.
function M.outside_near(K, pts, r)
  r = math.max(0, math.min(int(r) or 1, 3))
  local out = {}
  for i, p in ipairs(type(pts) == 'table' and pts or {}) do
    local x, y, z
    if type(p) == 'table' then x, y, z = int(p.x or p[1]), int(p.y or p[2]), int(p.z or p[3]) end
    local res = -1
    if x and y and z then
      res = 0
      for dy = -r, r do
        for dx = -r, r do
          local des = dfhack.maps.getTileFlags(x + dx, y + dy, z)
          if des and not des.hidden and des.outside then res = 1; break end
        end
        if res == 1 then break end
      end
    end
    out[i] = res
  end
  return out
end

---------------------------------------------------------------- export
local function map_size()
  local ok, x, y, z = pcall(dfhack.maps.getTileSize)        -- dfhack.lua:742
  if ok and x then return x, y, z end
  local bx, by, bz = dfhack.maps.getSize()                    -- Lua API.txt:2217 (blocks)
  return bx * 16, by * 16, bz
end

local function clamp_bbox(b)
  local X, Y, Z = map_size()
  local r = {math.max(0, b[1]), math.max(0, b[2]), math.max(0, b[3]),
             math.min(X - 1, b[4]), math.min(Y - 1, b[5]), math.min(Z - 1, b[6])}
  if r[1] > r[4] or r[2] > r[5] or r[3] > r[6] then return nil end
  return r
end

local function grow(bb, p)
  if type(p) ~= 'table' or #p < 3 then return bb end
  local q = {int(p[1]), int(p[2]), int(p[3]), int(p[4] or p[1]), int(p[5] or p[2]), int(p[6] or p[3])}
  for i = 1, 6 do if not q[i] then return bb end end
  if not bb then return q end
  return {math.min(bb[1], q[1]), math.min(bb[2], q[2]), math.min(bb[3], q[3]),
          math.max(bb[4], q[4]), math.max(bb[5], q[5]), math.max(bb[6], q[6])}
end

-- the manifest geometry (bridges, levers, zones, rooms, killboxes, stations, stairs, refuge, pit, depot)
local function manifest_bbox(man)
  local bb
  for _, b in pairs(type(man.bridges) == 'table' and man.bridges or {}) do
    bb = grow(bb, b.fp)
    for _, l in ipairs(type(b.levers) == 'table' and b.levers or {}) do bb = grow(bb, l) end
  end
  for _, list in pairs(type(man.zones) == 'table' and man.zones or {}) do
    for _, z in ipairs(type(list) == 'table' and list or {}) do bb = grow(bb, z) end
  end
  for _, key in ipairs({'killboxes', 'rooms'}) do
    for _, e in ipairs(type(man[key]) == 'table' and man[key] or {}) do bb = grow(bb, type(e) == 'table' and e.bbox) end
  end
  for _, p in pairs(type(man.stations) == 'table' and man.stations or {}) do bb = grow(bb, p) end
  for _, kind in ipairs({'civ', 'mil'}) do
    local s = type(man.stairs) == 'table' and man.stairs[kind]
    for _, c in ipairs(type(s) == 'table' and s or {}) do bb = grow(bb, {c[1], c[2], c[3], c[1], c[2], c[4]}) end
  end
  if type(man.refuge) == 'table' then bb = grow(bb, man.refuge.anchor) end
  return grow(grow(bb, man.pit), man.depot)
end

-- top revealed non-open tile of the map's centre column (z of the surface around the embark)
local function surface_z(cx, cy, zmax)
  for z = zmax - 1, 0, -1 do
    local des = dfhack.maps.getTileFlags(cx, cy, z)
    if des and not des.hidden then
      local c = tt_info(dfhack.maps.getTileType(cx, cy, z)).c
      if c ~= '_' and c ~= '?' then return z end
    end
  end
end

local function default_bbox(K)
  local bb = manifest_bbox(K.manifest())
  if bb then
    local m = M.CFG.margin
    return clamp_bbox({bb[1] - m[1], bb[2] - m[2], bb[3] - m[3], bb[4] + m[1], bb[5] + m[2], bb[6] + m[3]})
  end
  local X, Y, Z = map_size()
  local s = M.CFG.sites
  local cx, cy = X // 2, Y // 2
  local sz = surface_z(cx, cy, Z) or (Z - 1)
  return clamp_bbox({cx - s.w // 2, cy - s.h // 2, sz - s.below, cx + s.w // 2 - 1, cy + s.h // 2 - 1, sz + s.above})
end

local function new_id(K)
  n_auto = n_auto + 1
  return string.format('s%d-%d', K.now().tick, n_auto)
end

-- public (§7): queue an export -> ok, id (sliced; SNAPSHOT_READY when the file is written)
function M.export(K, opts)
  opts = type(opts) == 'table' and opts or {}
  local purpose = opts.purpose or 'debug'
  if not PURPOSES[purpose] then return false, 'purpose must be audit, sites or debug' end
  local id = opts.id or new_id(K)
  if type(id) ~= 'string' or #id > 40 or not id:match(ID_OK) then return false, 'bad snapshot id' end
  local bbox
  if opts.bbox ~= nil then
    local b = opts.bbox
    if type(b) ~= 'table' or #b ~= 6 then return false, 'bbox must be [x0,y0,z0,x1,y1,z1]' end
    for i = 1, 6 do if not int(b[i]) then return false, 'bbox must hold integers' end end
    if b[1] > b[4] or b[2] > b[5] or b[3] > b[6] then return false, 'bbox corners out of order' end
    bbox = clamp_bbox({int(b[1]), int(b[2]), int(b[3]), int(b[4]), int(b[5]), int(b[6])})
  else
    bbox = default_bbox(K)
  end
  if not bbox then return false, 'bbox outside the map' end
  local n = (bbox[4] - bbox[1] + 1) * (bbox[5] - bbox[2] + 1) * (bbox[6] - bbox[3] + 1)
  if n > M.CFG.max_tiles then return false, string.format('bbox has %d tiles > %d', n, M.CFG.max_tiles) end
  if job and #queue >= M.CFG.queue then return false, 'export queue full' end
  local j = {id = id, purpose = purpose, bbox = bbox, tiles = n}
  if job then queue[#queue + 1] = j else job = j end
  return true, id
end

local function start(K, j)
  local man = K.manifest()
  j.z, j.y, j.rows, j.cur = j.bbox[3], j.bbox[2], {}, {}
  j.traps = trap_index(j.bbox)
  j.marks = {soil = {}, cavern = {}}
  j.bridges, j.bstate = {}, {}
  for name, spec in pairs(type(man.bridges) == 'table' and man.bridges or {}) do
    local ok, s = K.call('gate', 'state', name)
    s = ok and type(s) == 'string' and s or 'unknown'
    j.bstate[name] = s
    local fp = type(spec) == 'table' and spec.fp
    if type(fp) == 'table' and #fp == 6 then
      local ch = (s == 'up') and 'H' or '='
      for x = fp[1], fp[4] do for y = fp[2], fp[5] do for z = fp[3], fp[6] do
        j.bridges[x .. ',' .. y .. ',' .. z] = ch
      end end end
    end
  end
  j.t0 = K.now().ms
end

local function add_mark(list, x, y, z)
  if #list < M.CFG.marks_max then list[#list + 1] = {x, y, z} end
end

-- one row (x0..x1) of level z
local function scan_row(j, y, z)
  local b = j.bbox
  local out, getTileFlags = {}, dfhack.maps.getTileFlags
  for x = b[1], b[4] do
    local des, oc = getTileFlags(x, y, z)
    local c
    if not des or des.hidden then c = '?'
    else
      local ch, _bld, soil = classify(x, y, z, des, oc, j.traps, j.bridges)
      c = ch
      if soil and c == '.' then add_mark(j.marks.soil, x, y, z) end
      if des.feature_global == true then add_mark(j.marks.cavern, x, y, z) end
    end
    out[#out + 1] = c
  end
  return table.concat(out)
end

local function encode(j)
  local parts = {}
  for z = j.bbox[3], j.bbox[6] do
    local rows = j.rows[z]
    parts[#parts + 1] = string.format('"z%d":["%s"]', z, table.concat(rows, '","'))
  end
  local traps = {}
  for _, t in pairs(j.traps) do traps[#traps + 1] = t end
  table.sort(traps, function(a, b)
    if a[3] ~= b[3] then return a[3] < b[3] end
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
  local marks = {}
  for k, list in pairs(j.marks) do if #list > 0 then marks[k] = list end end
  local head = {v = 2, id = j.id, tick = j.tick, purpose = j.purpose, bbox = j.bbox,
                bridges = json.object(j.bstate), traps = json.array(traps)}
  if next(marks) then head.marks = marks end
  local h = json.encode(head)
  return h:sub(1, -2) .. ',"rows":{' .. table.concat(parts, ',') .. '}}'
end

local function finish(K, j)
  j.tick = K.now().tick
  local dir = K.cfg.paths.save and (K.cfg.paths.save .. '/snap')
  if not dir then return end
  local path, err = fio.write_new(dir, j.id .. '.json', encode(j))
  if not path then
    K.log('error', 'snapshot %s: %s', j.id, tostring(err))
    return
  end
  local rel = 'snap/' .. fio.basename(path)
  K.emit('SNAPSHOT_READY', 'C', string.format('snapshot %s (%s, %d tiles)', j.id, j.purpose, j.tiles),
         {id = j.id, path = rel, purpose = j.purpose})
end

---------------------------------------------------------------- module
function M.init(K)
  job, queue, n_auto, tt_cache, live_traps, live_jobs, yielding = nil, {}, 0, {}, nil, nil, nil
  occ = occ_values()
end

function M.step(K, budget, ctx)
  if not job and #queue == 0 then return end
  local by, why
  if type(K.busy) == 'function' then by, why = K.busy() end
  if by then
    if yielding ~= by then
      yielding = by
      K.log('info', 'snapshot: export %s waits while %s is busy (%s)', tostring((job or queue[1]).id), by, tostring(why))
    end
    return
  end
  yielding = nil
  if not job then job = table.remove(queue, 1) end
  local j = job
  if not j.rows then start(K, j) end
  local b, w, left = j.bbox, j.bbox[4] - j.bbox[1] + 1, M.CFG.slice
  while left > 0 and j.z <= b[6] do
    j.rows[j.z] = j.rows[j.z] or {}
    local r = j.rows[j.z]
    r[#r + 1] = scan_row(j, j.y, j.z)
    left = left - w
    j.y = j.y + 1
    if j.y > b[5] then j.y, j.z = b[2], j.z + 1 end
  end
  if j.z <= b[6] then return 'more' end
  finish(K, j)
  job = nil
  if #queue > 0 then return 'more' end
end

M.on.UNLOAD = function(K) job, queue = nil, {} end

-- inbox snapshot {bbox?, purpose?}: snap id = command id (CONTRACTS §13)
M.verbs.snapshot = function(K, args, cmd)
  local ok, id = M.export(K, {id = cmd and cmd.id, bbox = args.bbox, purpose = args.purpose or 'debug'})
  if not ok then return false, id end
  return true, 'queued snapshot ' .. id, {id = id}
end

return M
