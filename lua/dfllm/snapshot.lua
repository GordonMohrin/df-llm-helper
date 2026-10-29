-- snapshot (WP7; CONTRACTS §3.4, §7, §9.10): revealed-tile export for Python (bp.topo audit, bp.sites
-- ranking) and snapshot.tile, the one tile query of the other modules.
-- Fair play (§1.4, DESIGN §11.1): a tile counts only if revealed; designation.hidden -> '?' in an
-- export and nil from tile(). Marks: soil (quickfort's farm rule, build.lua:65-81), cavern
-- (designation.feature_global of revealed tiles, tile-material.lua:255) and sand (Run 11: a revealed soil floor of a
-- sand layer, see M.is_sand; economy's sand collection zone); never damp, and the aquifer flag only of a revealed tile
-- (FR-95: M.revealed_aquifer, tile() `aq`). Run 11: shrub and sapling
-- marks (a seal piece cannot stand on a plant: the CLI gathers a shrub first and closes a sapling's route on a
-- neighbour), the roofed ones first (the ways in of seal's entrance check are roofed tiles), then the open-sky ones up
-- to marks_max; both lists are always written, so an empty list means none.
-- An export runs in slices of CFG.slice tiles per frame ('more'; the ms cadence also runs while
-- paused) and is written to <save>/snap/<id>.json through a .tmp file, then SNAPSHOT_READY (C).
-- BUG-026 (Run 10: an audit export of 58,608 tiles ran through a caravan visit that was then lost): an export waits
-- while another module holds a busy kernel boost (K.busy(): trade with the trade screen open) and resumes where it
-- stopped; BUG-033: at most CFG.busy_max_ms per export.
-- BUG-033 (Run 11, site98: `export queue full` for months, `bp sites --fresh` never got its file, audit_old 4.5 years):
-- the other modules' tile/water queries were charged to this module's pacing debt, so its export slices waited for
-- good (kern now books a K.call to the caller). The queue itself: every request names who asked (`by`); an inbox
-- request (dfllm audit, bp sites --fresh, follow; a CLI waits for its file) goes ahead of the kernel's own ones (a
-- running kernel export is put back behind it), may push the newest kernel request out of a full queue and runs
-- boosted (sched.BOOST.shares.snapshot); a request for the same purpose whose box equals or contains (or lies in) a
-- waiting one joins it (one scan, one file and one SNAPSHOT_READY per request id); `any` (economy's sand) is
-- satisfied by any export already queued or running; a waiting request older than CFG.max_age_ms, a running export
-- without a slice for CFG.stall_ms and one whose slice failed CFG.fail_max times are dropped (kern.log warn); a
-- refusal names the running export, who asked, its progress and why it waits, and the queued ones. state `snap`.
-- BUG-043 (Run 11 y479: 'bbox has 252108 tiles > 250000'): the default box is made of the fort's pieces, an audit's
-- explore shafts are column parts of a union export (' ' = not exported), the margin shrinks before a refusal, and a
-- refusal names the box per axis and the piece that stretches it (the block 'the default box' below).
local json = require('dfllm.util.json')
local fio = require('dfllm.io')

local M = {name = 'snapshot', every = {ms = 250}, verbs = {}, on = {}}

M.CFG = {
  slice = 1000,                   -- tiles per frame (DESIGN §4: <= 2,000)
  -- BUG-043 (Run 11 y479: 'bbox has 252108 tiles > 250000'): tiles one export reads at most (400 slices; config/
  -- baseline.json snapshot.max_tiles within M.CAP_LIM), and the file box of a union export at most
  max_tiles = 400000, grid_max = 1500000,
  queue = 4,                      -- exports waiting behind the running one
  -- BUG-033: a waiting request is dropped after this long (an inbox one: its CLI gave up long before; a kernel one:
  -- its module asks again), a running export after stall_ms without a slice or fail_max failed slices; an export
  -- waits for another module's busy boost at most busy_max_ms; slices of an inbox export run boosted
  max_age_ms = {user = 900000, bg = 1800000}, stall_ms = 600000, fail_max = 2, busy_max_ms = 180000,
  paced_ms = 2000,                -- state/refusal: an export without a slice for this long is 'paced'
  -- BUG-043: default box: the fort's pieces plus the first margin that keeps it within max_tiles (x, y, z); an
  -- explore shaft's column part: its box plus col_margin; at most parts_max parts (more columns share the last one)
  margin_steps = {{16, 16, 2}, {8, 8, 1}, {4, 4, 1}, {0, 0, 0}}, col_margin = {2, 2, 1}, parts_max = 24,
  sites = {w = 96, h = 96, below = 8, above = 3},   -- default box without a manifest
  marks_max = 500,
  -- BUG-297 (Run 15c Inkintense: the 500 soil marks were all spent on the fort's own soil floors on z130-z132, so the
  -- ~5,900 revealed surface floors on z133 had none and `bp sites farms p.surface=1` saw no soil): soil keeps its own cap
  soil_max = 8000,
  trap_ttl = 1200,                -- ticks between trap index refreshes for tile()
  liquid_tiles = 4096,            -- tiles one liquids() call may read (FR-47)
  items_tiles = 400,              -- tiles one items_at() call may cover (BUG-009: a building footprint)
  items_max = 200,                -- items one items_at() call returns
  group_pts = 4000,               -- points one groups() call reads (inspect workload: citizens and open jobs)
}
local PURPOSES = {audit = true, sites = true, debug = true}
local ID_OK = '^[A-Za-z0-9_%-]+$'

local job, queue, n_auto    -- running export, waiting exports, generated ids
local margin_used           -- BUG-043: the margin each purpose's default box used last (logged on a change)
local stats, boosted       -- BUG-033: {done, drop} this boot; snapshot holds a kernel boost (inbox export)
local tilemat, sand_cache, sand_known   -- Run 11: DFHack's tile-material module, sand per block layer, found floors
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
local PLANT_SHAPE = {SHRUB = 'shrub', SAPLING = 'sapling'}      -- Run 11: snapshot marks (seal pieces)
local SOLID = {['#'] = true, S = true, C = true, F = true, T = true}
local TRAP_CH = {WeaponTrap = 'W', StoneFallTrap = 'S', CageTrap = 'C', PressurePlate = 'P'}

-- {c, soil, plant} of a tiletype from df.tiletype.attrs (dig.lua:39-90 reads the same attributes)
local function tt_info(tt)
  local r = tt_cache[tt]
  if r then return r end
  r = {c = '?', soil = false, plant = false, ice = false, shape = ''}
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
    r.c, r.soil, r.plant = c, SOIL_MAT[mat] == true and SOIL_SHAPE[shape] == true, PLANT_SHAPE[shape] or false
    r.ice = mat == 'FROZEN_LIQUID'               -- Run 11: frozen water (winter ice) is no water to fish or fill from
    r.shape = shape                              -- BUG-102: the tiletype shape name (care's nook judges it like place.lua)
    r.soilmat = SOIL_MAT[mat] == true            -- FR-95: soil of any shape (a soil wall cannot be smoothed)
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
  return c, bld, info.soil, info.plant
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

-- FR-95 (DECISIONS, decided by the orchestrator for Gordon 2026-10-28): the aquifer flag of a REVEALED tile, what the
-- vanilla drip icon (and DFHack's warmdamp overlay) shows the player. A hidden tile, or flags without a hidden field,
-- answer nil and the flag is never read; this is the kernel's only read of it (lint: hidden-read allows it only here,
-- after the hidden check).
function M.revealed_aquifer(des)
  if des == nil or des.hidden ~= false then return nil end
  return des.water_table == true
end

---------------------------------------------------------------- public tile query (§7)
-- nil (hidden or invalid) or {c = legend char, dig = pending designation or '', bld = building type
-- (Door, Bridge, Trap, Well, ...), 'passable'/'impassable' (other buildings) or '', flow, magma, cav, ice, aq, soilmat}
function M.tile(K, x, y, z)
  x, y, z = int(x), int(y), int(z)
  if not (x and y and z) then return nil end
  local des, oc = dfhack.maps.getTileFlags(x, y, z)
  if not des or des.hidden then return nil end
  local now = K.now().tick
  if not live_traps or now - live_traps.tick >= M.CFG.trap_ttl or now < live_traps.tick then
    live_traps = {tick = now, idx = trap_index(nil)}
  end
  local c, bld, _, plant = classify(x, y, z, des, oc, live_traps.idx, nil)
  local info = tt_info(dfhack.maps.getTileType(x, y, z))
  local dig = designation(des, oc)
  if dig == '' and designation_jobs(now)[string.format('%d,%d,%d', x, y, z)] then dig = 'job' end
  -- flow: liquid depth 0..7 of this revealed tile, magma: true for magma (runner: light-aquifer seepage); cav: the
  -- revealed tile belongs to a cavern (designation.feature_global, the export's cavern mark; runner: Run 11 cavern lake);
  -- ice: frozen water (tiletype material FROZEN_LIQUID; Run 11, economy's fishing zone). BUG-102 (care's drink nook judges a
  -- tile the way quickfort's place mode does, place.lua:29-43): shape = the tiletype shape name ('FLOOR', 'BRANCH', ...),
  -- plant = 'shrub' | 'sapling' | false, occ = the building occupancy value (tile_building_occ: 1 Planned counts there)
  -- FR-95: aq = the aquifer flag of this revealed tile (M.revealed_aquifer), soilmat = a soil tile of any shape
  return {c = c, dig = dig, bld = bld, flow = des.flow_size or 0, magma = des.liquid_type == true,
          cav = des.feature_global == true, ice = info.ice == true, shape = info.shape, plant = plant or false,
          occ = oc and int(oc.building) or 0, aq = M.revealed_aquifer(des) == true, soilmat = info.soilmat == true}
end

-- BUG-058 (economy's farm plots; Run 13 y513: surface crops on a plot on z149 made no PlantSeeds job): does the plot tile
-- lie underground (true: `subterranean`, the sheet lists the underground crops), on the surface (false: under the open
-- sky) or is that unknown (hidden; a roofed tile that is not subterranean may or may not offer underground crops: nil)?
-- Read-only, one tile.
function M.plot_under(K, x, y, z)
  x, y, z = int(x), int(y), int(z)
  if not (x and y and z) then return nil end
  local des = dfhack.maps.getTileFlags(x, y, z)
  if not des or des.hidden then return nil end
  if des.outside then return false end
  if des.subterranean == true then return true end
  return nil
end

-- water tiles of one level rect (FR-47, water's water_sources scan): {{x, y, flow, cavern}} of revealed, non-magma
-- tiles with flow >= min (default 1), at most M.CFG.liquid_tiles tiles read and 512 returned per call (the
-- caller slices the box). Hidden tiles are skipped: no water_table, no unrevealed water. cavern = 1 on a revealed
-- cavern tile (designation.feature_global, the export's cavern mark; BUG-031: cavern water is never a hospital's
-- source), else 0. Run 11 (economy's fishing zone): a frozen tile (tiletype material FROZEN_LIQUID, the ice the tile
-- sheet shows) is no water and is left out; with `ice` true every revealed ice tile of the rect is listed too, with
-- a fifth field 1 (0 on water) and its flow as read
function M.liquids(K, x0, y0, x1, y1, z, min, ice)
  x0, y0, x1, y1, z, min = int(x0), int(y0), int(x1), int(y1), int(z), int(min) or 1
  local out = {}
  if not (x0 and y0 and x1 and y1 and z) or x1 < x0 or y1 < y0 then return out end
  if (x1 - x0 + 1) * (y1 - y0 + 1) > M.CFG.liquid_tiles then return nil, 'rect too large' end
  local getTileFlags, getTileType = dfhack.maps.getTileFlags, dfhack.maps.getTileType
  ice = ice == true
  for y = y0, y1 do
    for x = x0, x1 do
      local des = getTileFlags(x, y, z)
      if des and not des.hidden then
        local f = int(des.flow_size) or 0
        local lt = des.liquid_type
        local tt = (ice or f >= min) and getTileType and getTileType(x, y, z) or nil
        if tt ~= nil and tt_info(tt).ice == true then
          if ice then out[#out + 1] = {x, y, f, des.feature_global == true and 1 or 0, 1} end
        elseif f >= min and not (lt == true or (lt ~= false and lt ~= nil and lt ~= 0)) then
          out[#out + 1] = {x, y, f, des.feature_global == true and 1 or 0, ice and 0 or nil}
        end
        if #out >= 512 then return out end
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

-- floor items by tile (BUG-102, care's drink nook: quickfort's place mode ignores items, a barrel pile on a tile with
-- loose items beside the workshop is still no nook): {['x,y'] = count} of the items on the ground of the revealed tiles
-- of a level rect, one pass over the map blocks it touches; at most M.CFG.nook_tiles tiles per call. Items in a building,
-- a container or a unit's hands, hidden tiles and other levels stay out.
M.CFG.nook_tiles = 1024
function M.item_tiles(K, x0, y0, x1, y1, z)
  x0, y0, x1, y1, z = int(x0), int(y0), int(x1), int(y1), int(z)
  local out = {}
  if not (x0 and y0 and x1 and y1 and z) or x1 < x0 or y1 < y0 then return out end
  if (x1 - x0 + 1) * (y1 - y0 + 1) > M.CFG.nook_tiles then return nil, 'rect too large' end
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
            local k = p.x .. ',' .. p.y
            out[k] = (out[k] or 0) + 1
          end
        end
      end
    end
  end
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

-- FR-88 (the verb view): the visible living units whose name contains `query` (case-insensitive, plain text; the name as the
-- unit sheet shows it, profession included), at most `max` (default 4) in the first return, the count of all matches in the
-- second: {{id, name, x, y, z}} sorted by id. Hidden units and units on hidden tiles never count (the player cannot see them
-- either). One pass over the active units, at the verb's call only.
function M.find_units(K, query, max)
  local q = tostring(query or ''):lower()
  max = int(max) or 4
  local out, total = {}, 0
  if q == '' then return out, 0 end
  local getTileFlags = dfhack.maps.getTileFlags
  for _, u in ipairs(df.global.world.units.active) do
    if not dfhack.units.isDead(u) and not dfhack.units.isHidden(u) then
      local ok, name = pcall(dfhack.units.getReadableName, u)
      name = ok and tostring(dfhack.df2utf and dfhack.df2utf(name) or name) or ''
      if name:lower():find(q, 1, true) then
        local p = u.pos
        local des = getTileFlags(p.x, p.y, p.z)
        if des and not des.hidden then
          total = total + 1
          out[#out + 1] = {id = u.id, name = name, x = p.x, y = p.y, z = p.z}
        end
      end
    end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  while #out > max do out[#out] = nil end
  return out, total
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

-- occupied(K, pts): FR-90 (trash view: which loose items lie on a building or stockpile tile). pts = array of {x, y, z}; per
-- point the tile's building occupancy value (tile_building_occ, 0 = none; a stockpile, workshop or planned building is > 0),
-- -1 for a hidden or invalid tile or a fault (callers count -1 as open floor). At most M.CFG.group_pts points a call (the rest
-- answer -1); hidden tiles are never read further.
function M.occupied(K, pts)
  local out, lim = {}, M.CFG.group_pts or 4000
  for i, p in ipairs(type(pts) == 'table' and pts or {}) do
    local v = -1
    if i <= lim and type(p) == 'table' then
      local x, y, z = int(p.x or p[1]), int(p.y or p[2]), int(p.z or p[3])
      if x and y and z then
        local ok, des, oc = pcall(dfhack.maps.getTileFlags, x, y, z)
        if ok and des and not des.hidden and oc then v = int(oc.building) or -1 end
      end
    end
    out[i] = v
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

-- the box without a manifest: the surface around the map centre
local function surface_bbox()
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

local function contains(a, b)            -- box a holds box b
  return a[1] <= b[1] and a[2] <= b[2] and a[3] <= b[3] and a[4] >= b[4] and a[5] >= b[5] and a[6] >= b[6]
end
local function ntiles(b) return (b[4] - b[1] + 1) * (b[5] - b[2] + 1) * (b[6] - b[3] + 1) end

---------------------------------------------------------------- BUG-043: the default box (the fort's pieces)
-- Run 11 (site98 y479, kernel 2eea070): `dfllm audit` and `bp sites --fresh` refused 'bbox has 252108 tiles > 250000',
-- readiness' own audit box (manifest + running projects) 308,132 and then 370,414 tiles: the fort spans its whole
-- 192-tile map width, and every explore shaft 12 levels below the core added whole x-y planes of the fort (149 x 113
-- tiles a level) although it is a few tiles wide. Now one composition serves every default box: the fort's pieces
-- (the manifest geometry; for an audit also the runner's boxes: running projects, finished rooms, seals, plugs,
-- repairs and explores it keeps) make the main box plus a margin; an explore shaft is a column part of its own (its box
-- plus col_margin); tiles of the file's bounding box outside every part are ' ' (not exported; bp.topo counts a
-- walkable tile beside one as the outside, like the box border). Over the cap the margin shrinks stepwise
-- (margin_steps) before the request is refused, and a refusal names the box per axis and the piece that stretches it.
M.NOSCAN = ' '                     -- the legend char of a tile no part of the export covers (CONTRACTS §9.10)
M.CAP_LIM = {10000, 1000000}       -- config/baseline.json snapshot.max_tiles (dfpilot/fairplay.py SNAPSHOT_LIM)

local function box6(p)
  if type(p) ~= 'table' or p[1] == nil or p[2] == nil or p[3] == nil then return nil end
  local q = {int(p[1]), int(p[2]), int(p[3]), int(p[4] or p[1]), int(p[5] or p[2]), int(p[6] or p[3])}
  for i = 1, 6 do if not q[i] then return nil end end
  for i = 1, 3 do if q[i] > q[i + 3] then q[i], q[i + 3] = q[i + 3], q[i] end end
  return q
end

local function union(a, b)
  return {math.min(a[1], b[1]), math.min(a[2], b[2]), math.min(a[3], b[3]),
          math.max(a[4], b[4]), math.max(a[5], b[5]), math.max(a[6], b[6])}
end

local function bbox_of(list, field)
  local bb
  for _, e in ipairs(list) do
    local b = field and e[field] or e
    bb = bb and union(bb, b) or {b[1], b[2], b[3], b[4], b[5], b[6]}
  end
  return bb
end

local function grown(b, m) return {b[1] - m[1], b[2] - m[2], b[3] - m[3], b[4] + m[1], b[5] + m[2], b[6] + m[3]} end

local function sorted_keys(t)
  local r = {}
  for k in pairs(type(t) == 'table' and t or {}) do r[#r + 1] = k end
  table.sort(r, function(a, b) return tostring(a) < tostring(b) end)
  return r
end

-- the fort's pieces {b, what, col, proj}: the manifest geometry (bridges and levers, zones, killboxes, rooms,
-- stations, the edge, stairs, refuge, pit, depot); for an audit also runner.boxes (col: an explore's shaft)
local function pieces(K, purpose)
  local out, man = {}, K.manifest()
  local function add(what, p, col, proj, e)
    local b = box6(p)
    if not b then return end
    local q = {b = b, what = what, col = col == true, proj = proj}
    if e then                                       -- BUG-129: a runner piece: its tile clusters, done (kept)
      q.done = e.done == true
      for _, c in ipairs(type(e.parts) == 'table' and e.parts or {}) do
        local cb = box6(c)
        if cb then q.parts = q.parts or {}; q.parts[#q.parts + 1] = cb end
      end
    end
    out[#out + 1] = q
  end
  local br = type(man.bridges) == 'table' and man.bridges or {}
  for _, name in ipairs(sorted_keys(br)) do
    local b = br[name]
    if type(b) == 'table' then
      add('bridge ' .. tostring(name), b.fp)
      for _, l in ipairs(type(b.levers) == 'table' and b.levers or {}) do add('lever ' .. tostring(name), l) end
    end
  end
  local zs = type(man.zones) == 'table' and man.zones or {}
  for _, k in ipairs(sorted_keys(zs)) do
    for _, z in ipairs(type(zs[k]) == 'table' and zs[k] or {}) do add('zone ' .. tostring(k), z) end
  end
  for _, key in ipairs({'killboxes', 'rooms'}) do
    for i, e in ipairs(type(man[key]) == 'table' and man[key] or {}) do
      if type(e) == 'table' then add((key == 'rooms' and 'room ' or 'killbox ') .. tostring(e.id or i), e.bbox) end
    end
  end
  local stn = type(man.stations) == 'table' and man.stations or {}
  for _, k in ipairs(sorted_keys(stn)) do add('station ' .. tostring(k), stn[k]) end
  for _, p in ipairs(type(man.edge) == 'table' and man.edge or {}) do add('edge', p) end
  for _, kind in ipairs({'civ', 'mil'}) do
    local s = type(man.stairs) == 'table' and man.stairs[kind]
    for _, c in ipairs(type(s) == 'table' and s or {}) do
      if type(c) == 'table' then add('stair ' .. kind, {c[1], c[2], c[3], c[1], c[2], c[4] or c[3]}) end
    end
  end
  if type(man.refuge) == 'table' then add('refuge', man.refuge.anchor) end
  add('pit', man.pit)
  add('depot', man.depot)
  if purpose == 'audit' then
    local ok, list = K.call('runner', 'boxes')
    for _, e in ipairs(ok and type(list) == 'table' and list or {}) do
      if type(e) == 'table' then
        add(tostring(e.tpl or 'project') .. ' ' .. tostring(e.id or '?'), e.b, e.tpl == 'explore', tostring(e.id or ''),
            e)
      end
    end
  end
  return out
end

-- the x spans of the parts covering row (y, z), merged and ascending: {{x0, x1}, ...}
local function row_spans(parts, y, z, upto)
  local iv = {}
  for k = 1, upto or #parts do
    local p = parts[k]
    if y >= p[2] and y <= p[5] and z >= p[3] and z <= p[6] then iv[#iv + 1] = {p[1], p[4]} end
  end
  if #iv < 2 then return iv end
  table.sort(iv, function(a, b) return a[1] < b[1] end)
  local out = {{iv[1][1], iv[1][2]}}
  for i = 2, #iv do
    local last, s = out[#out], iv[i]
    if s[1] <= last[2] + 1 then last[2] = math.max(last[2], s[2]) else out[#out + 1] = {s[1], s[2]} end
  end
  return out
end

-- the tiles of the union of the parts: the first whole, every other one where no earlier part covers it
local function union_tiles(parts)
  local n = ntiles(parts[1])
  for k = 2, #parts do
    local p = parts[k]
    for z = p[3], p[6] do
      for y = p[2], p[5] do
        local w = p[4] - p[1] + 1
        for _, s in ipairs(row_spans(parts, y, z, k - 1)) do
          local a, b = math.max(s[1], p[1]), math.min(s[2], p[4])
          if a <= b then w = w - (b - a + 1) end
        end
        n = n + w
      end
    end
  end
  return n
end

local function cap_of(K)
  local c = type(K.cfg) == 'table' and type(K.cfg.baseline) == 'table' and K.cfg.baseline.snapshot
  local v = type(c) == 'table' and c.max_tiles
  local L = M.CAP_LIM
  return (math.type(v) == 'integer' and v >= L[1] and v <= L[2]) and v or M.CFG.max_tiles
end

local function mstr(m) return string.format('%d,%d,%d', m[1], m[2], m[3]) end
local function dims(b) return string.format('%dx%dx%d', b[4] - b[1] + 1, b[5] - b[2] + 1, b[6] - b[3] + 1) end
local function span(b) return string.format('x %d-%d y %d-%d z %d-%d', b[1], b[4], b[2], b[5], b[3], b[6]) end

-- the main box at margin m first, then each column part outside it (clamped to the map); columns past parts_max
-- share the last part
local function parts_at(mb, cols, m)
  local main = clamp_bbox(grown(mb, m))
  if not main then return nil end
  local parts = {main}
  for _, c in ipairs(cols) do
    local b = clamp_bbox(grown(c.b, M.CFG.col_margin))
    if b and not contains(main, b) then
      if #parts < M.CFG.parts_max then parts[#parts + 1] = b else parts[#parts] = union(parts[#parts], b) end
    end
  end
  return parts
end

-- the face of the main box whose pieces stretch it the most at margin m: the tiles it would lose if that face moved in
-- to the next piece along its axis (the other faces kept): {p (its first piece), n (pieces on it), f (1-6: x0 y0 z0 x1
-- y1 z1), v (the coordinate), saved (tiles)}
local AXIS = {'x', 'y', 'z', 'x', 'y', 'z'}
local function stretcher(main, m)
  local bb = bbox_of(main, 'b')
  local full = clamp_bbox(grown(bb, m))
  local best
  for f = 1, 6 do
    local at, nv = {}, nil
    for _, p in ipairs(main) do
      if p.b[f] == bb[f] then at[#at + 1] = p
      elseif f <= 3 then nv = math.min(nv or p.b[f], p.b[f])
      else nv = math.max(nv or p.b[f], p.b[f]) end
    end
    if nv then
      local nb = {bb[1], bb[2], bb[3], bb[4], bb[5], bb[6]}
      nb[f] = nv
      local q = clamp_bbox(grown(nb, m))
      local saved = ntiles(full) - (q and ntiles(q) or 0)
      if not best or saved > best.saved then best = {p = at[1], n = #at, f = f, v = bb[f], saved = saved} end
    end
  end
  return best
end

-- 'bbox 117x62x14 = 101556 tiles > 100000 at margin 0,0,0 (x 59-175 y 52-113 z 132-145; stretched most by room
-- cistern118_88_132r0 at z132: 29016 tiles less without it); way out: ...' (<= 300 bytes)
local function refusal(c, main, cap, label)
  local b = c.parts[1]
  local s = string.format('%s %s%s = %d tiles > %d at margin %s (%s', label or 'bbox', dims(b),
                          c.cols > 0 and string.format(' + %d shaft column%s', c.cols, c.cols == 1 and '' or 's') or '',
                          c.tiles, cap, mstr(c.margin), span(b))
  local st = stretcher(main, c.margin)
  if st then
    s = s .. string.format('; stretched most by %s%s at %s%d: %d tiles less without %s', st.p.what:sub(1, 40),
                           st.n > 1 and string.format(' (+%d more)', st.n - 1) or '', AXIS[st.f], st.v, st.saved,
                           st.n > 1 and 'them' or 'it')
  end
  s = s .. ')'
  if ntiles(c.bbox) > M.CFG.grid_max then s = s .. string.format('; file box %s > %d', dims(c.bbox), M.CFG.grid_max) end
  -- BUG-129: a finished (kept) piece cannot be cancelled
  local out = st and st.p.proj and st.p.proj ~= '' and not st.p.done and
              string.format('bp.cancel %s if it can go, or ', st.p.proj) or ''
  return (s .. '; way out: ' .. out .. 'raise snapshot.max_tiles in config/baseline.json (<= ' .. M.CAP_LIM[2] ..
          '), dfhack-run dfllm reload'):sub(1, 300)
end

---------------------------------------------------------------- BUG-129: an audit box as regions
-- Run 14 (region2-site90, up to y717): 'audit snapshot refused: bbox 190x192x45 = 1641600 tiles > 400000 at margin
-- 0,0,0 (x 0-189 y 0-191 z 90-134; stretched most by seal c1a14d660b9fb1de01 (+2 more) at z90 ...); file box 190x192x45
-- > 1500000', so audit_old/audit_fail held R0 for ~190 game years. The manifest geometry (the fort core) fitted at 8,8,1;
-- finished seals 26 levels below, seals whose walls lie far apart and an old kept box over the whole map stretched the
-- one box. An audit box that does not fit as one box is now made of regions: the fort core (the manifest geometry at
-- the first margin step that fits) plus every runner piece outside it as parts of its own (its tile clusters, else its
-- box, each + col_margin), nearest to the core first (past parts_max a part joins a far part); a piece whose parts do
-- not fit (the cap, grid_max) is dropped and named. The verdict stays as strict as one box: a tile no part read is the
-- outside (bp.topo: a walkable tile beside one, or a stair or ramp over or under one, starts attackers), so a dropped
-- piece can only add fails.
-- BUG-043: parts a covers parts b (every part of b lies in one of a)
local function covers(a, b)
  for _, q in ipairs(b) do
    local inside = false
    for _, p in ipairs(a) do if contains(p, q) then inside = true; break end end
    if not inside then return false end
  end
  return true
end

M.CFG.drop_note = 40                -- bytes of the first dropped piece's label in the reply and SNAPSHOT_READY

-- the tiles of box q no part of `parts` covers
local function fresh_tiles(parts, q)
  local n = 0
  for z = q[3], q[6] do
    for y = q[2], q[5] do
      local w = q[4] - q[1] + 1
      for _, sp in ipairs(row_spans(parts, y, z)) do
        local a, b = math.max(sp[1], q[1]), math.min(sp[2], q[4])
        if a <= b then w = w - (b - a + 1) end
      end
      n = n + w
    end
  end
  return n
end

-- the tiles between box b and box c along each axis, summed (0: they touch or overlap)
local function gap_of(b, c)
  local n = 0
  for i = 1, 3 do n = n + math.max(0, b[i] - c[i + 3], c[i] - b[i + 3]) end
  return n
end

-- the region parts at margin m: {parts, bbox, tiles, margin, cols = 0, out = 0, regions, drop, dropped, dway} or nil
-- (the core over the cap or the map)
local function regions_at(core, far, m, cap)
  local main = clamp_bbox(grown(core, m))
  if not main or ntiles(main) > cap then return nil end
  local parts, tiles, drops = {main}, ntiles(main), {}
  for _, p in ipairs(far) do
    local add, n, fb = {}, tiles, bbox_of(parts)
    for _, b in ipairs(p.parts or {p.b}) do
      local q = clamp_bbox(grown(b, M.CFG.col_margin))
      if q and not covers(parts, {q}) and not covers(add, {q}) then
        local all = {table.unpack(parts)}
        for _, a in ipairs(add) do all[#all + 1] = a end
        n = n + fresh_tiles(all, q)
        add[#add + 1], fb = q, union(fb, q)
      end
    end
    if #add > 0 then
      if n <= cap and ntiles(fb) <= M.CFG.grid_max and #parts + #add <= M.CFG.parts_max then
        for _, q in ipairs(add) do parts[#parts + 1] = q end
        tiles = n
      else
        -- review: past parts_max a part joins the far part it grows least (as BUG-043 columns share the last part)
        local np = {table.unpack(parts)}
        for _, q in ipairs(add) do
          if #np < M.CFG.parts_max then np[#np + 1] = q
          else
            local bk, bc
            for k = 2, #np do
              local cost = ntiles(union(np[k], q)) - ntiles(np[k])
              if not bc or cost < bc then bk, bc = k, cost end
            end
            if bk then np[bk] = union(np[bk], q) else np = nil; break end
          end
        end
        local nt = np and union_tiles(np)
        if np and nt <= cap and ntiles(bbox_of(np)) <= M.CFG.grid_max then parts, tiles = np, nt
        else drops[#drops + 1] = p end
      end
    end
  end
  local d1 = drops[1]
  return {parts = parts, bbox = bbox_of(parts), tiles = tiles, margin = m, cols = 0, out = 0, regions = #parts - 1,
          drop = #drops, dropped = d1 and d1.what:sub(1, M.CFG.drop_note) or nil,
          dway = d1 and (d1.done and 'done; its tiles count as outside' or
                         (d1.proj and d1.proj ~= '' and string.format('bp.cancel %s if it can go', d1.proj))) or nil}
end

-- an audit box as regions -> c, or nil, why (the fort core alone over the cap: its refusal). The first margin step
-- that drops nothing wins, else the one that drops the fewest pieces
function M.regions(K, pcs, cap)
  local core, far = {}, {}
  for _, p in ipairs(pcs) do if p.proj then far[#far + 1] = p else core[#core + 1] = p end end
  if #core == 0 or #far == 0 then return nil end
  local cb = bbox_of(core, 'b')
  for _, p in ipairs(far) do p.gap, p.n = gap_of(p.b, cb), ntiles(p.b) end
  table.sort(far, function(a, b)
    if a.gap ~= b.gap then return a.gap < b.gap end
    if a.n ~= b.n then return a.n < b.n end
    return a.what < b.what
  end)
  local best
  for _, m in ipairs(M.CFG.margin_steps) do
    local c = regions_at(cb, far, m, cap)
    if c and c.drop == 0 then return c end
    if c and (not best or c.drop < best.drop) then best = c end
  end
  if best then return best end
  local b0 = clamp_bbox(cb)
  if not b0 then return nil, 'bbox outside the map' end
  local m0 = M.CFG.margin_steps[#M.CFG.margin_steps]
  local last = {parts = {clamp_bbox(grown(cb, m0)) or b0}, cols = 0, margin = m0}
  last.tiles, last.bbox = ntiles(last.parts[1]), last.parts[1]
  return nil, refusal(last, core, cap, 'fort core')
end

-- the default box of a purpose: {parts, bbox, tiles, margin?, cols, out = 0} or nil, why. The first margin step whose
-- union fits the cap wins; without fort pieces the surface around the map centre (no margin, no columns). BUG-129: an
-- audit box over the cap as one box: as regions (M.regions)
local function compose(K, purpose)
  local pcs = pieces(K, purpose)
  local main, cols = {}, {}
  for _, p in ipairs(pcs) do if p.col then cols[#cols + 1] = p else main[#main + 1] = p end end
  if #main == 0 then
    local b = surface_bbox()
    if not b then return nil, 'bbox outside the map' end
    return {parts = {b}, bbox = b, tiles = ntiles(b), cols = 0, out = 0}
  end
  local mb, cap, last = bbox_of(main, 'b'), cap_of(K), nil
  for _, m in ipairs(M.CFG.margin_steps) do
    local parts = parts_at(mb, cols, m)
    if parts then
      last = {parts = parts, bbox = bbox_of(parts), tiles = union_tiles(parts), margin = m, cols = #parts - 1, out = 0}
      if last.tiles <= cap and ntiles(last.bbox) <= M.CFG.grid_max then return last end
    end
  end
  if not last then return nil, 'bbox outside the map' end
  if purpose == 'audit' then
    local c, why = M.regions(K, pcs, cap)
    if c or why then return c, why end
  end
  return nil, refusal(last, main, cap)
end

-- an explicit audit box: the fort pieces it leaves out (n, the first one's label)
local function left_out(K, b)
  local n, first = 0, nil
  for _, p in ipairs(pieces(K, 'audit')) do
    local q = clamp_bbox(p.b)
    if q and not contains(b, q) then
      n = n + 1
      first = first or p.what
    end
  end
  return n, first
end

local function mins(ms) return ms >= 60000 and string.format('%d min', ms // 60000) or string.format('%d s', ms // 1000) end

-- the requests a job answers: its own id first, then the ones that joined it
local function ids_of(j)
  local r = {j.id}
  for _, a in ipairs(j.alias or {}) do r[#r + 1] = a.id end
  return r
end

-- the share of the box a running export has scanned (0-99)
local function pct(j)
  if not j.rows then return 0 end
  local b = j.bbox
  local rows = (b[6] - b[3] + 1) * (b[5] - b[2] + 1)
  local done = (j.z - b[3]) * (b[5] - b[2] + 1) + (j.y - b[2])
  return math.max(0, math.min(99, done * 100 // math.max(1, rows)))
end

-- why the running export waits now: '' (it ran a slice lately), 'busy <module>', 'paced' (no slice for paced_ms:
-- the kernel holds the module back, it faults or it is backed off), 'queued' (not started)
local function waits(j, now)
  if j.busy_by then return 'busy ' .. j.busy_by end
  local last = j.last_ms or j.t
  if now - last >= M.CFG.paced_ms then return string.format('%s %s', j.rows and 'paced' or 'not started', mins(now - last)) end
  return ''
end

local function short(j, now, running)
  local s = string.format('%s %s by %s', j.id, j.purpose, j.by)
  if running then
    local w = waits(j, now)
    s = s .. string.format(' %d%% for %s', pct(j), mins(now - j.t)) .. (w ~= '' and (' (' .. w .. ')') or '')
  else s = s .. ' ' .. mins(now - j.t) end
  return s
end

-- 'running s1-2 audit by readiness 40% for 9 min (paced 8 min); queued 4: aud1 audit by cli:cli 3 min, ...'
local function describe(now)
  local parts = {}
  if job then parts[#parts + 1] = 'running ' .. short(job, now, true) end
  if #queue > 0 then
    local q = {}
    for i, j in ipairs(queue) do if i <= 3 then q[#q + 1] = short(j, now, j.rows ~= nil) end end
    parts[#parts + 1] = string.format('queued %d: %s%s', #queue, table.concat(q, ', '), #queue > 3 and ', ...' or '')
  end
  return table.concat(parts, '; ')
end

local function drop(K, j, why)
  stats.drop = stats.drop + 1
  K.log('warn', 'snapshot: dropped %s (%s, %d tiles, by %s, asked %s ago): %s', table.concat(ids_of(j), '+'),
        j.purpose, j.tiles, j.by, mins(K.now().ms - j.t), why)
end

-- BUG-033: waiting requests past their age (a kernel export put back behind an inbox one: since its last slice), a
-- running export that made no progress for stall_ms
local function expire(K, now)
  local keep = {}
  for _, j in ipairs(queue) do
    local max = j.user and M.CFG.max_age_ms.user or M.CFG.max_age_ms.bg
    if now - (j.last_ms or j.t) >= max then drop(K, j, 'waited longer than ' .. mins(max))
    else keep[#keep + 1] = j end
  end
  queue = keep
  if job and job.rows and now - (job.last_ms or job.t) >= M.CFG.stall_ms then
    drop(K, job, string.format('no slice for %s at %d%%', mins(now - (job.last_ms or job.t)), pct(job)))
    job = nil
  elseif job and not job.rows and now - job.t >= (job.user and M.CFG.max_age_ms.user or M.CFG.max_age_ms.bg) then
    drop(K, job, 'not started within ' .. mins(now - job.t))
    job = nil
  end
end

-- an inbox request goes ahead of the kernel's own ones (stable within each class)
local function enqueue(j)
  local at = #queue + 1
  if j.user then
    at = 1
    while queue[at] and queue[at].user do at = at + 1 end
  end
  table.insert(queue, at, j)
  return at
end


-- BUG-043: what the reply and SNAPSHOT_READY say about a job's box ('margin 8,8,1', shaft columns, pieces left out)
local function cov_note(j)
  local t = {}
  if j.margin and j.step and j.step > 1 then t[#t + 1] = 'margin ' .. mstr(j.margin) end
  if (j.cols or 0) > 0 then t[#t + 1] = string.format('%d shaft column%s', j.cols, j.cols == 1 and '' or 's') end
  if (j.regions or 0) > 0 then t[#t + 1] = string.format('%d region%s', j.regions, j.regions == 1 and '' or 's') end
  if (j.drop or 0) > 0 then                      -- BUG-129: the far pieces a region box dropped, the first one's way out
    t[#t + 1] = string.format('drops %d far piece%s: %s%s', j.drop, j.drop == 1 and '' or 's', tostring(j.dropped),
                              j.dway and (' (' .. j.dway .. ')') or '')
  end
  if (j.out or 0) > 0 then
    t[#t + 1] = string.format('leaves out %d fort piece%s: %s', j.out, j.out == 1 and '' or 's', tostring(j.first))
  end
  return table.concat(t, ', ')
end

-- public (§7): queue an export -> ok, id (sliced; SNAPSHOT_READY when the file is written), a note (joined,
-- position; BUG-043: the margin, shaft columns, fort pieces an explicit audit box leaves out) and the box {tiles,
-- margin?, cols?, out?, first?}. opts = {id?, bbox?, purpose, by? (who asks: a module name, 'inbox:<by>'), user? (an
-- inbox request), any? (BUG-033: any export queued or running will do; its id is returned)}. Without bbox the box is
-- the default of the purpose (BUG-043: the fort's pieces plus a margin, shrunk stepwise over the cap; an audit's
-- explore shafts as column parts)
function M.export(K, opts)
  opts = type(opts) == 'table' and opts or {}
  local purpose = opts.purpose or 'debug'
  if not PURPOSES[purpose] then return false, 'purpose must be audit, sites or debug' end
  local now = K.now().ms
  expire(K, now)
  if opts.any and (job or #queue > 0) then
    local j = job or queue[1]
    return true, j.id, 'an export runs already: ' .. j.id
  end
  local id = opts.id or new_id(K)
  if type(id) ~= 'string' or #id > 40 or not id:match(ID_OK) then return false, 'bad snapshot id' end
  local c
  if opts.bbox ~= nil then
    local b = opts.bbox
    if type(b) ~= 'table' or #b ~= 6 then return false, 'bbox must be [x0,y0,z0,x1,y1,z1]' end
    for i = 1, 6 do if not int(b[i]) then return false, 'bbox must hold integers' end end
    if b[1] > b[4] or b[2] > b[5] or b[3] > b[6] then return false, 'bbox corners out of order' end
    local bbox = clamp_bbox({int(b[1]), int(b[2]), int(b[3]), int(b[4]), int(b[5]), int(b[6])})
    if not bbox then return false, 'bbox outside the map' end
    local n, cap = ntiles(bbox), cap_of(K)
    if n > cap then
      return false, string.format('bbox %s = %d tiles > %d (%s); way out: a smaller bbox, or none (the fort\'s own '
                                  .. 'box)', dims(bbox), n, cap, span(bbox))
    end
    c = {parts = {bbox}, bbox = bbox, tiles = n, cols = 0, out = 0}
    if purpose == 'audit' then c.out, c.first = left_out(K, bbox) end
  else
    local why
    c, why = compose(K, purpose)
    if not c then return false, why end
    if c.margin then                              -- BUG-043: log once per purpose which margin was used
      local ms = mstr(c.margin)
      local first = mstr(M.CFG.margin_steps[1])
      if margin_used[purpose] ~= ms then
        if ms ~= first then
          K.log('warn', 'snapshot: the %s box is over %d tiles at margin %s: margin %s used (%d tiles, %s%s)', purpose,
                cap_of(K), first, ms, c.tiles, span(c.parts[1]),
                c.cols > 0 and string.format(', %d shaft columns', c.cols) or '')
        elseif margin_used[purpose] then
          K.log('info', 'snapshot: the %s box fits at margin %s again (%d tiles)', purpose, ms, c.tiles)
        end
        margin_used[purpose] = ms
      end
      for i, m in ipairs(M.CFG.margin_steps) do if mstr(m) == ms then c.step = i; break end end
    end
    if c.regions then                              -- BUG-129: log once per shape which region box was used
      local key = string.format('%s/%d/%d', mstr(c.margin), c.regions, c.drop)
      if margin_used['reg:' .. purpose] ~= key then
        K.log('warn', 'snapshot: the %s box is over %d tiles as one box: %d tiles as the fort core (margin %s) and %d '
              .. 'region%s%s', purpose, cap_of(K), c.tiles, mstr(c.margin), c.regions, c.regions == 1 and '' or 's',
              c.drop > 0 and string.format(', drops %d far piece%s: %s', c.drop, c.drop == 1 and '' or 's',
                                           tostring(c.dropped)) or '')
        margin_used['reg:' .. purpose] = key
      end
    end
  end
  local n, bbox = c.tiles, c.bbox
  local user, by = opts.user == true, tostring(opts.by or 'kernel'):sub(1, 24)
  local info = {tiles = n, margin = c.margin and mstr(c.margin) or nil, cols = c.cols > 0 and c.cols or nil,
                out = c.out > 0 and c.out or nil, first = c.out > 0 and c.first or nil,
                regions = (c.regions or 0) > 0 and c.regions or nil, drop = (c.drop or 0) > 0 and c.drop or nil,
                dropped = (c.drop or 0) > 0 and c.dropped or nil}
  -- BUG-033: the same purpose, one box holding the other: one scan answers both (a waiting job only)
  for _, q in ipairs(queue) do
    if not q.rows and q.purpose == purpose and (covers(q.parts, c.parts) or covers(c.parts, q.parts)) then
      if not covers(q.parts, c.parts) then
        q.parts, q.bbox, q.tiles, q.margin, q.step, q.cols = c.parts, bbox, n, c.margin, c.step, c.cols
        q.regions, q.drop, q.dropped, q.dway = c.regions, c.drop, c.dropped, c.dway      -- BUG-129
      end
      if (c.out or 0) < (q.out or 0) then q.out, q.first = c.out, c.first end
      q.alias = q.alias or {}
      q.alias[#q.alias + 1] = {id = id, by = by}
      if user and not q.user then
        q.user = true
        for i, x in ipairs(queue) do if x == q then table.remove(queue, i); break end end
        enqueue(q)
      end
      local note = cov_note(q)
      return true, id, string.format('joins %s (%s by %s, %d tiles%s)', q.id, q.purpose, q.by, q.tiles,
                                     note ~= '' and ('; ' .. note) or ''),
             {tiles = q.tiles, margin = q.margin and mstr(q.margin) or nil, cols = (q.cols or 0) > 0 and q.cols or nil,
              out = (q.out or 0) > 0 and q.out or nil, first = (q.out or 0) > 0 and q.first or nil,
              regions = (q.regions or 0) > 0 and q.regions or nil, drop = (q.drop or 0) > 0 and q.drop or nil,
              dropped = (q.drop or 0) > 0 and q.dropped or nil}
    end
  end
  if #queue >= M.CFG.queue then
    local victim
    if user then for i = #queue, 1, -1 do if not queue[i].user and not queue[i].rows then victim = i; break end end end
    if not victim then return false, 'export queue full: ' .. describe(now) end
    local v = table.remove(queue, victim)
    drop(K, v, string.format('the queue was full and %s (%s by %s) goes first', id, purpose, by))
  end
  local j = {id = id, purpose = purpose, bbox = bbox, parts = c.parts, tiles = n, margin = c.margin, step = c.step,
             cols = c.cols, out = c.out, first = c.first, by = by, user = user, t = now,
             regions = c.regions, drop = c.drop, dropped = c.dropped, dway = c.dway}
  local note = cov_note(j)
  note = note ~= '' and ('; ' .. note) or ''
  if not job and #queue == 0 then job = j; return true, id, 'next' .. note, info end    -- it starts at the next step
  local pos = enqueue(j)
  local ahead = job and (' behind ' .. short(job, now, true)) or ''
  return true, id, (pos > 1 and string.format('in line %d%s', pos, ahead) or (job and ('next' .. ahead) or 'next')) ..
         note, info
end

-- public (BUG-033, readiness): is the snapshot `id` still queued or being exported?
function M.pending(K, id)
  for _, j in ipairs(job and {job} or {}) do for _, x in ipairs(ids_of(j)) do if x == id then return true end end end
  for _, j in ipairs(queue) do for _, x in ipairs(ids_of(j)) do if x == id then return true end end end
  return false
end

local function start(K, j)
  local man = K.manifest()
  j.z, j.y, j.rows, j.cur = j.bbox[3], j.bbox[2], {}, {}
  j.traps = trap_index(j.bbox)
  j.marks = {soil = {}, cavern = {}, sand = {}, shrub = {}, sapling = {}}
  j.sky_plants = {shrub = {}, sapling = {}}       -- open-sky plants, appended after the roofed ones
  j.bridges, j.bstate = {}, {}
  for name, spec in pairs(type(man.bridges) == 'table' and man.bridges or {}) do
    local ok, s, _, gone = K.call('gate', 'state', name)
    s = ok and type(s) == 'string' and s or 'unknown'
    if ok and gone then s = 'destroyed' end      -- BUG-030: its footprint shows the tiles as they are now
    -- BUG-048: seal replaced it by a wall and a door: the audit takes it for what it is, a door entrance
    local okr, rep = K.call('seal', 'replaced')
    if s == 'destroyed' and okr and type(rep) == 'table' and rep[name] ~= nil then s = 'replaced' end
    j.bstate[name] = s
    local fp = type(spec) == 'table' and spec.fp
    if type(fp) == 'table' and #fp == 6 and s ~= 'destroyed' and s ~= 'replaced' then
      local ch = (s == 'up') and 'H' or '='
      for x = fp[1], fp[4] do for y = fp[2], fp[5] do for z = fp[3], fp[6] do
        j.bridges[x .. ',' .. y .. ',' .. z] = ch
      end end end
    end
  end
  j.t0 = K.now().ms
end

local function add_mark(list, x, y, z, max)
  if #list < (max or M.CFG.marks_max) then list[#list + 1] = {x, y, z} end
end

-- Run 11 (Kilrudrabed, site98: no gem vein, every year the first mood that wanted gems died): is the revealed soil
-- floor at x, y, z (designation des, already checked not hidden) of a sand layer? The tile sheet names its material
-- ("yellow sand"); the layer material is DFHack's tile-material GetLayerMat (geology layer of the tile's biome),
-- sand = inorganic flag SOIL_SAND. Cached per map block column, biome index and layer index. A field: tests replace it.
M.SAND_MAX = 32                   -- sand floors kept (newest export first) and probed per export
function M.is_sand(x, y, z, des)
  if not tilemat then return false end
  local key = string.format('%d,%d,%s,%s', x // 16, y // 16, tostring(des.biome), tostring(des.geolayer_index))
  local v = sand_cache[key]
  if v == nil then
    local ok, yes = pcall(function()
      local mi = tilemat.GetLayerMat(x, y, z)
      return mi ~= nil and mi.inorganic ~= nil and mi.inorganic.flags.SOIL_SAND == true
    end)
    v = ok and yes == true
    sand_cache[key] = v
  end
  return v
end

-- public (Run 11, economy's glass chain): the revealed sand floors the exports of this boot found, newest export
-- first: {tick = the last export that looked (-1 none yet), tiles = {{x, y, z}} (<= M.SAND_MAX)}
function M.sand(K)
  local out = {}
  for i, t in ipairs(sand_known.tiles) do out[i] = {t[1], t[2], t[3]} end
  return {tick = sand_known.tick, tiles = out}
end

local function remember_sand(j)
  local list, seen = {}, {}
  for _, src in ipairs({j.marks.sand, sand_known.tiles}) do
    for _, t in ipairs(src) do
      local k = t[1] .. ',' .. t[2] .. ',' .. t[3]
      if not seen[k] and #list < M.SAND_MAX then seen[k] = true; list[#list + 1] = {t[1], t[2], t[3]} end
    end
  end
  sand_known = {tick = j.tick, tiles = list}
end

-- the tiles x0..x1 of row y, level z
local function scan_span(j, y, z, x0, x1)
  local out, getTileFlags = {}, dfhack.maps.getTileFlags
  for x = x0, x1 do
    local des, oc = getTileFlags(x, y, z)
    local c
    if not des or des.hidden then c = '?'
    else
      local ch, _bld, soil, plant = classify(x, y, z, des, oc, j.traps, j.bridges)
      c = ch
      if soil and c == '.' then
        add_mark(j.marks.soil, x, y, z, M.CFG.soil_max)                 -- BUG-297
        if #j.marks.sand < M.SAND_MAX and M.is_sand(x, y, z, des) then add_mark(j.marks.sand, x, y, z) end
      end
      if plant and c == '.' then add_mark(des.outside and j.sky_plants[plant] or j.marks[plant], x, y, z) end
      if des.feature_global == true then add_mark(j.marks.cavern, x, y, z) end
    end
    out[#out + 1] = c
  end
  return table.concat(out)
end

-- one row (x0..x1) of level z -> its text and the tiles read; BUG-043: only inside the job's parts, ' ' elsewhere
local function scan_row(j, y, z)
  local b = j.bbox
  if #j.parts > 1 or not contains(j.parts[1], b) then
    local out, x, n = {}, b[1], 0
    for _, s in ipairs(row_spans(j.parts, y, z)) do
      local a, e = math.max(s[1], b[1]), math.min(s[2], b[4])
      if a <= e then
        if a > x then out[#out + 1] = string.rep(M.NOSCAN, a - x) end
        out[#out + 1] = (scan_span(j, y, z, a, e))
        n, x = n + e - a + 1, e + 1
      end
    end
    if x <= b[4] then out[#out + 1] = string.rep(M.NOSCAN, b[4] - x + 1) end
    return table.concat(out), n
  end
  return scan_span(j, y, z, b[1], b[4]), b[4] - b[1] + 1
end

-- the file text of request `id` (the job's own or one that joined it): the head per id, the rows once (j.body)
local function encode(j, id)
  if j.body then return j.head(id) .. j.body end
  local parts = {}
  for z = j.bbox[3], j.bbox[6] do
    local rows = j.rows[z]
    parts[#parts + 1] = string.format('"z%d":["%s"]', z, table.concat(rows, '","'))
  end
  local traps = {}
  for _, t in pairs(j.traps) do
    if covers(j.parts, {{t[1], t[2], t[3], t[1], t[2], t[3]}}) then
      traps[#traps + 1] = t                       -- BUG-043: only traps on exported tiles
    end
  end
  table.sort(traps, function(a, b)
    if a[3] ~= b[3] then return a[3] < b[3] end
    if a[2] ~= b[2] then return a[2] < b[2] end
    return a[1] < b[1]
  end)
  local marks = {}
  for k, list in pairs(j.sky_plants) do
    local m = j.marks[k]
    for _, p in ipairs(list) do
      if #m >= M.CFG.marks_max then break end
      m[#m + 1] = p
    end
  end
  for k, list in pairs(j.marks) do
    if #list > 0 then marks[k] = list elseif j.sky_plants[k] then marks[k] = json.array({}) end
  end
  local head = {v = 2, id = j.id, tick = j.tick, purpose = j.purpose, bbox = j.bbox,
                bridges = json.object(j.bstate), traps = json.array(traps)}
  if next(marks) then head.marks = marks end
  if #j.parts > 1 or not contains(j.parts[1], j.bbox) then head.parts = j.parts end      -- BUG-043: a union export
  if j.margin then head.margin = {j.margin[1], j.margin[2], j.margin[3]} end           -- the default box's margin
  j.head = function(x)
    head.id = x
    return json.encode(head):sub(1, -2)
  end
  j.body = ',"rows":{' .. table.concat(parts, ',') .. '}}'
  return j.head(id) .. j.body
end

-- one file and one SNAPSHOT_READY per request id (BUG-033: requests that joined the job get their own)
local function finish(K, j)
  j.tick = K.now().tick
  remember_sand(j)
  stats.done = stats.done + 1
  local dir = K.cfg.paths.save and (K.cfg.paths.save .. '/snap')
  if not dir then return end
  for i, id in ipairs(ids_of(j)) do
    local path, err = fio.write_new(dir, id .. '.json', encode(j, id))
    if not path then
      K.log('error', 'snapshot %s: %s', id, tostring(err))
    else
      local rel = 'snap/' .. fio.basename(path)
      local who = i == 1 and j.by or j.alias[i - 1].by
      -- BUG-043: a default box's margin when it shrank, its shaft columns, the pieces an explicit audit box left out
      local note = cov_note(j)
      K.emit('SNAPSHOT_READY', 'C', string.format('snapshot %s (%s, %d tiles, by %s%s)', id, j.purpose, j.tiles, who,
                                                  note ~= '' and ('; ' .. note) or ''),
             {id = id, path = rel, purpose = j.purpose, margin = (j.step or 1) > 1 and mstr(j.margin) or nil,
              cols = (j.cols or 0) > 0 and j.cols or nil, out = (j.out or 0) > 0 and j.out or nil,
              first = (j.out or 0) > 0 and tostring(j.first):sub(1, 60) or nil,
              regions = (j.regions or 0) > 0 and j.regions or nil, drop = (j.drop or 0) > 0 and j.drop or nil,
              dropped = (j.drop or 0) > 0 and tostring(j.dropped):sub(1, 60) or nil})
    end
  end
  local now = K.now().ms
  K.log('info', 'snapshot: %s (%s, %d tiles, by %s) written %s after the request (%s scanning)',
        table.concat(ids_of(j), '+'), j.purpose, j.tiles, j.by, mins(now - j.t), mins(now - (j.t0 or now)))
  j.head, j.body = nil, nil
end

-- public (siege, intake waves, Gordon 2026-10-16): the built traps inside `boxes` ({{x0,y0,z0,x1,y1,z1}}; levers, track
-- stops and pressure plates excluded): n and armed (not in their re-arm timeout, ready_timeout 0, the trap sheet's
-- state); nil on a read fault. One pass over buildings.other.TRAP.
function M.traps(K, boxes)
  local n, armed = 0, 0
  local ok = pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.TRAP) do
      local kind = TRAP_CH[df.trap_type[b.trap_type] or '']
      if kind and kind ~= 'P' then
        local x, y, z = b.centerx, b.centery, b.z
        for _, bb in ipairs(type(boxes) == 'table' and boxes or {}) do
          if x >= bb[1] and x <= bb[4] and y >= bb[2] and y <= bb[5] and z >= bb[3] and z <= bb[6] then
            n = n + 1
            if (int(flag(b, 'ready_timeout')) or 0) <= 0 then armed = armed + 1 end
            break
          end
        end
      end
    end
  end)
  if not ok then return nil end
  return n, armed
end

---------------------------------------------------------------- module
function M.init(K)
  job, queue, n_auto, tt_cache, live_traps, live_jobs, yielding = nil, {}, 0, {}, nil, nil, nil
  stats, boosted, margin_used = {done = 0, drop = 0}, false, {}
  occ = occ_values()
  sand_cache, sand_known = {}, {tick = -1, tiles = {}}
  local ok, tm = pcall(require, 'tile-material')       -- DFHack library/lua/tile-material.lua
  tilemat = ok and type(tm) == 'table' and tm or nil
end

-- BUG-033: the boost while an export someone waits for (an inbox request) runs; never busy
local function sync_boost(K, j)
  if type(K.boost) ~= 'function' then return end
  if j and j.user then
    K.boost('export ' .. j.id .. ' for ' .. j.by, false)
    boosted = true
  elseif boosted then
    K.unboost()
    boosted = false
  end
end

function M.step(K, budget, ctx)
  local now = K.now().ms
  expire(K, now)
  if not job and #queue == 0 then sync_boost(K, nil); return end
  -- BUG-033: an inbox request goes ahead of a running kernel export, which keeps its rows and resumes after it
  if job and not job.user and queue[1] and queue[1].user then
    K.log('info', 'snapshot: %s (%s by %s) waits at %d%% for %s (%s by %s)', job.id, job.purpose, job.by, pct(job),
          queue[1].id, queue[1].purpose, queue[1].by)
    job.busy_by, job.busy_at = nil, nil
    enqueue(job)
    job = nil
  end
  if not job then job = table.remove(queue, 1) end
  local j = job
  sync_boost(K, j)
  local by, why
  if type(K.busy) == 'function' then by, why = K.busy() end
  if by and by ~= M.name then
    j.busy_ms = (j.busy_ms or 0) + (j.busy_at and math.max(0, now - j.busy_at) or 0)
    j.busy_at = now
    if j.busy_ms < M.CFG.busy_max_ms then
      if yielding ~= by then
        yielding = by
        K.log('info', 'snapshot: export %s waits while %s is busy (%s)', tostring(j.id), by, tostring(why))
      end
      j.busy_by = by
      return
    end
    if j.busy_by then
      K.log('warn', 'snapshot: export %s goes on although %s is busy (%s): it waited %s', j.id, by, tostring(why),
            mins(j.busy_ms))
    end
    j.busy_by = nil
  else
    j.busy_at, j.busy_by = nil, nil
  end
  yielding = nil
  -- BUG-033: a slice that failed (a fault leaves inflight set) is counted; fail_max of them drop the export, so one
  -- bad tile cannot hold the queue (and back the module off) for good
  if j.inflight then
    j.fails = (j.fails or 0) + 1
    if j.fails >= M.CFG.fail_max then
      drop(K, j, string.format('its slice failed %d times at z%s y%s', j.fails, tostring(j.z), tostring(j.y)))
      job, j.inflight = nil, nil
      return #queue > 0 and 'more' or nil
    end
  end
  j.inflight = true
  if not j.rows then start(K, j) end
  local b, w, left = j.bbox, j.bbox[4] - j.bbox[1] + 1, M.CFG.slice
  while left > 0 and j.z <= b[6] do
    j.rows[j.z] = j.rows[j.z] or {}
    local r = j.rows[j.z]
    local text, n = scan_row(j, j.y, j.z)
    r[#r + 1] = text
    left = left - math.max(1, n + (w - n) // 16)  -- BUG-043: a tile not exported costs a char, not a read
    j.y = j.y + 1
    if j.y > b[5] then j.y, j.z = b[2], j.z + 1 end
  end
  j.inflight, j.last_ms = nil, now
  if j.z <= b[6] then return 'more' end
  finish(K, j)
  job = nil
  if #queue > 0 then return 'more' end
  sync_boost(K, nil)
end

M.on.UNLOAD = function(K) job, queue = nil, {} end

-- BUG-033: state `snap` (doctor, status): requests waiting (the running one included), the oldest one's age in s,
-- exports written and requests dropped this boot; with an export running or waiting: its id, purpose, who asked, its
-- progress and why it waits ('busy trade', 'paced 3 min', 'not started 2 min', '')
function M.state(K)
  local now = K.now().ms
  local q, old = #queue + (job and 1 or 0), 0
  for _, j in ipairs(queue) do old = math.max(old, now - j.t) end
  if job then old = math.max(old, now - job.t) end
  local d = {q = q, old_s = old // 1000, done = stats and stats.done or 0, drop = stats and stats.drop or 0}
  local j = job or queue[1]
  if j then
    d.run, d.p, d.by, d.pct = j.id, j.purpose, j.by, pct(j)
    d.wait = (job and waits(j, now) or ('not started ' .. mins(now - j.t))):sub(1, 24)
  end
  return {snap = d}
end

-- inbox snapshot {bbox?, purpose?}: snap id = command id (CONTRACTS §13)
-- BUG-033: an inbox request (a CLI or follow waits for its file) goes first and runs boosted; a refusal names the queue
M.verbs.snapshot = function(K, args, cmd)
  local by = 'inbox:' .. tostring(cmd and cmd.by or '?')
  local ok, id, note, info = M.export(K, {id = cmd and cmd.id, bbox = args.bbox, purpose = args.purpose or 'debug',
                                          by = by, user = true})
  if not ok then return false, id, {queue = #queue + (job and 1 or 0)} end
  local d = {id = id}                       -- BUG-043: the box's tiles, margin, shaft columns, pieces left out
  for k, v in pairs(type(info) == 'table' and info or {}) do d[k] = v end
  return true, 'queued snapshot ' .. id .. (note and (' (' .. note .. ')') or ''), d
end

-- FR-98 (cavern.lua, the cavern sweep): the wild dangers the player sees inside box {x0, y0, z0, x1, y1, z1}: {{id, x, y,
-- z}, ...} by id, and how many of them are great dangers (megabeast, forgotten beast, titan, demon) or building destroyers.
-- census.h leaves out the units of a sealed cavern (another walk group), so the sweep asks here. Fair play: isVisible and
-- not hidden only; caged, chained, citizens, residents, tame and fort animals, merchants, visitors and diplomats are no target.
function M.cave_units(K, box)
  if type(box) ~= 'table' or #box ~= 6 then return {}, 0 end
  local U = dfhack.units
  local function caste_flag(u, f)
    local ok, v = pcall(function() return df.creature_raw.find(u.race).caste[u.caste].flags[f] == true end)
    return ok and v == true
  end
  local out, great = {}, 0
  for _, u in ipairs(df.global.world.units.active) do
    local ok, hit, g = pcall(function()
      if not U.isActive(u) or U.isDead(u) or not U.isVisible(u) or U.isHidden(u) then return false end
      if u.flags1.caged or u.flags1.chained then return false end
      if U.isCitizen(u, true) or U.isResident(u, true) or U.isTame(u) or U.isFortControlled(u) then return false end
      if (U.isMerchant and U.isMerchant(u)) or (U.isVisitor and U.isVisitor(u)) or (U.isDiplomat and U.isDiplomat(u)) then
        return false
      end
      local x, y, z = U.getPosition(u)
      if not x or x < box[1] or x > box[4] or y < box[2] or y > box[5] or z < box[3] or z > box[6] then return false end
      local gd = U.isGreatDanger(u) or caste_flag(u, 'BUILDINGDESTROYER')
      if not (gd or U.isDanger(u) or U.isUndead(u) or caste_flag(u, 'LARGE_PREDATOR')) then return false end
      return {id = u.id, x = x, y = y, z = z}, gd
    end)
    if ok and hit then
      out[#out + 1] = hit
      if g then great = great + 1 end
    end
  end
  table.sort(out, function(p, q) return p.id < q.id end)
  return out, great
end

-- FR-98 review (cavern.lua's recall): the living citizens inside box {x0, y0, z0, x1, y1, z1} or in the shaft column
-- col {x, y, z_top} below its top (from z0 on): their ids, sorted. The player always sees his own citizens (units screen).
function M.cave_citizens(K, box, col)
  if type(box) ~= 'table' or #box ~= 6 or type(col) ~= 'table' then return {} end
  local U, out = dfhack.units, {}
  for _, u in ipairs(df.global.world.units.active) do
    local ok, hit = pcall(function()
      if not U.isCitizen(u) or U.isDead(u) then return false end
      local x, y, z = U.getPosition(u)
      if not x or z >= col[3] or z < box[3] then return false end
      return (x == col[1] and y == col[2]) or (x >= box[1] and x <= box[4] and y >= box[2] and y <= box[5] and z <= box[6])
    end)
    if ok and hit then out[#out + 1] = u.id end
  end
  table.sort(out)
  return out
end

return M
