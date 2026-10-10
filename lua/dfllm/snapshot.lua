-- snapshot (WP7; CONTRACTS §3.4, §7, §9.10): revealed-tile export for Python (bp.topo audit, bp.sites
-- ranking) and snapshot.tile, the one tile query of the other modules.
-- Fair play (§1.4, DESIGN §11.1): a tile counts only if revealed; designation.hidden -> '?' in an
-- export and nil from tile(). Marks: soil (quickfort's farm rule, build.lua:65-81) and cavern
-- (designation.feature_global of revealed tiles, tile-material.lua:255); never water_table or damp.
-- An export runs in slices of CFG.slice tiles per frame ('more'; the ms cadence also runs while
-- paused) and is written to <save>/snap/<id>.json through a .tmp file, then SNAPSHOT_READY (C).
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
}
local PURPOSES = {audit = true, sites = true, debug = true}
local ID_OK = '^[A-Za-z0-9_%-]+$'

local job, queue, n_auto    -- running export, waiting exports, generated ids
local tt_cache, occ, live_traps

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
  return {c = c, dig = designation(des, oc), bld = bld}
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
  job, queue, n_auto, tt_cache, live_traps = nil, {}, 0, {}, nil
  occ = occ_values()
end

function M.step(K, budget, ctx)
  if not job then
    if #queue == 0 then return end
    job = table.remove(queue, 1)
  end
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
