-- Run 15 round 2 (fix9-water-scan): the water scan. BUG-288 the scan never finished while the game ran (Inkintense: 'scan
-- queued' a season apart); BUG-289 its box missed the brook (Drillchamber: box 64,43,136-124,103,142, brook 141,67,143);
-- BUG-290 a flooded pit (open above the water, a floor beside it) is a well spot; BUG-291 a revealed aquifer tile beside
-- the water gives the aquifer level (cistern water=aquifer). Every test fails on 05dc764.
local T = require('testlib')
local F = require('wp8_world')
local C = require('dfllm.util.contract')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'

local DEPTH = {['~'] = 7, w = 2}

local function owners()
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'pond_remove'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn] or {}) do if o ~= 'water' then keep[#keep + 1] = o end end
    keep[#keep + 1] = 'water'
    C.ACT[fn] = keep
  end
end

-- opts: tiles {['x,y,z'] = c} (default '#', '?' hidden), aq {['x,y,z'] = true}, unreach, pos (unit positions), map
-- {X, Y, Z, surface} (snapshot.map_size / surface_z; nil: an older snapshot without them), water (config)
local function world(opts)
  opts = opts or {}
  owners()
  local units = {}
  for i = 1, 4 do units[i] = {id = i, citizen = true, pos = (opts.pos or {})[i] or {12, 12, 5}} end
  local man = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {{0, 0, 0, 199, 199, 20}}}}
  local cfg = F.cfg()
  cfg.water = opts.water
  local W = F.world{cfg = {baseline = cfg}, units = units, persist = {manifest = man}}
  df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
  df.civzone_type.Pond, df.civzone_type[11] = 11, 'Pond'
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  local ids = {}
  for i = 1, 4 do
    ids[i] = i
    W.unit(i).counters2 = {thirst_timer = 1000}
    W.unit(i).job = {current_job = nil}
  end
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 0, 0, 199, 199, 20})
  W.cmap, W.aq, W.unreach = opts.tiles or {}, opts.aq or {}, opts.unreach or {}
  W.reads = 0
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile(K, x, y, z)
    local k = x .. ',' .. y .. ',' .. z
    local c = W.cmap[k] or '#'
    if c == '?' then return nil end
    return {c = c, dig = '', bld = '', flow = DEPTH[c] or 0, aq = W.aq[k] == true}
  end
  function snap.liquids(K, x0, y0, x1, y1, z, min, ice, lat)
    local out = {}
    local area = (x1 - x0 + 1) * (y1 - y0 + 1)
    if (lat and (area + lat - 1) // lat or area) > 4096 then return nil, 'rect too large' end
    for y = y0, y1 do
      for x = x0, x1 do
        if not lat or (x + 2 * y) % lat == 0 then
          W.reads = W.reads + 1
          local f = DEPTH[W.cmap[x .. ',' .. y .. ',' .. z] or ''] or 0
          if f >= (min or 1) then out[#out + 1] = {x, y, f, 0} end
        end
      end
    end
    return out
  end
  function snap.reach(K, a, b) return not W.unreach[b.x .. ',' .. b.y .. ',' .. b.z] end
  if opts.map then
    function snap.map_size() return opts.map[1], opts.map[2], opts.map[3] end
    function snap.surface_z() return opts.map[4] end
  end
  W.load(snap)
  W.aq_seen = {}
  W.load({name = 'runner', every = {ticks = 600}, pending = function() return 0 end,
          kept_in = function() return nil end, bp_params = function() return {} end,
          aq_seen = function(K, z) W.aq_seen[#W.aq_seen + 1] = z; return true end})
  if opts.setup then opts.setup(W) end
  package.loaded['dfllm.water'] = nil
  local M = require('dfllm.water')
  W.load(M)
  return W, M
end

local function day(W, n) for _ = 1, n or 1 do W.run(1200, {skip = 10}) end end
local function hospital(W) return F.hospital(W, {10, 10, 14, 14, 5}) end
local function ws(W, M)
  local ok, msg, d = M.inspect(W.K, 'water_sources')
  T.ok(ok, msg)
  return msg, d
end

---------------------------------------------------------------- BUG-288
T.test('BUG-288 (Run 15 Inkintense: "scan queued" twice a season apart): with the slices 1500 ticks apart the scan ' ..
       'still finishes, within its bounded number of slices, and inspect says when it last finished', function()
  local W, M = world{setup = hospital}
  W.run(1500, {skip = 1500})
  local msg = ws(W, M)
  T.ok(msg:find('scan queued for the next water run; none finished yet', 1, true) or msg:find('scan running', 1, true), msg)
  W.run(1500 * 30, {skip = 1500})
  local c = M.conf(W.K)
  local m2, d = ws(W, M)
  T.ok(d.slices ~= nil, 'old code: no scan finished (every step began a new run): ' .. m2)
  T.ok(d.slices <= c.ws_slices + c.ws_body_slices + 2, 'bounded: ' .. tostring(d.slices))
  T.ok(m2:find('scan last finished at tick ' .. d.last.t, 1, true), m2)
  T.eq(d.last.t, d.tick)
  T.ok(W.state().water.wst == d.tick, 'state water.wst')
  T.ok(#W.logs > 0)
end)

T.test('BUG-288: a fort without a hospital zone and without accepted water scans by itself (old: only on an inspect); ' ..
       'nobody to scan around is said, not queued for good', function()
  local W, M = world{}
  day(W, 2)
  local msg, d = ws(W, M)
  T.ok(d.tick and d.slices, 'scanned without an inspect: ' .. msg)
  T.eq(d.err, nil)
end)

---------------------------------------------------------------- BUG-289
local function brook(tiles, y, x0, x1, z)
  for x = x0, x1 do
    tiles[x .. ',' .. y .. ',' .. z] = '~'
    tiles[x .. ',' .. (y - 1) .. ',' .. z] = '.'
  end
  return tiles
end

T.test('BUG-289 (Run 15 Drillchamber: the brook 141,67,143 outside the box 64,43,136-124,103,142): the surface survey of ' ..
       'the whole map finds the far brook, reads it whole and offers its bank; the next scan looks there again', function()
  local W, M = world{tiles = brook({}, 150, 120, 170, 7), map = {192, 192, 20, 7}, setup = hospital}
  day(W, 3)
  local msg, d = ws(W, M)
  local found
  for _, b in ipairs(d.bodies) do if b.z == 7 and b.n >= 40 then found = b end end
  T.ok(found, 'old code: the box round the hospital only: ' .. msg)
  T.eq(found.at, {120, 150, 7})
  T.eq(found.n, 51, 'read whole (seeds), not only the lattice tiles')
  T.ok(found.bank ~= nil, 'its bank is reachable')
  T.ok(d.survey and #d.survey >= 1 and d.seeds >= 1, 'survey levels and seed boxes')
  T.ok(d.reads <= M.conf(W.K).ws_read_max, 'within the read budget: ' .. d.reads)
  T.ok(d.way:find('water 120,150,7 (7/7, 51 tiles): bank', 1, true), d.way)
  T.eq(W.state().water.wsc, d.way)
  local hd = W.find_events('HOSPITAL_DRY')
  T.ok(#hd >= 1)
  local rc = hd[#hd].d.recipe
  T.ok(rc:find('is 106 tiles off (> 30): zone it as Water Source from the bank at', 1, true)
       or rc:find('tiles off (> 30): zone it as Water Source from the bank', 1, true), rc)
  -- remembered: an older snapshot without the survey still reads the brook's box
  local p = W.K.persist.get('m.water')
  T.ok(#p.wb >= 1, 'bodies kept for the next scan')
  T.eq(p.wb[1], {120, 150, 7})
end)

T.test('BUG-289: without a survey (an older snapshot) a citizen beside the water makes it seen (a box round every ' ..
       'citizen); the brook beyond them stays unseen (no survey, nothing remembered)', function()
  local tiles = brook({}, 70, 80, 85, 5)
  local W, M = world{tiles = tiles, pos = {[4] = {78, 72, 5}}, setup = hospital}
  day(W, 3)
  local _, d = ws(W, M)
  local found
  for _, b in ipairs(d.bodies) do if b.at[2] == 70 then found = b end end
  T.ok(found, 'old code: the box round the hospital only')
  T.eq(d.survey, {}, 'no map size: no survey')
end)

T.test('BUG-289: the box plan: merge_boxes joins boxes that cost no more together, keeps the order', function()
  local W, M = world{}
  local m = M.merge_boxes({{0, 0, 0, 9, 9, 0}, {50, 50, 0, 59, 59, 0}, {5, 0, 0, 14, 9, 0}})
  T.eq(m, {{0, 0, 0, 14, 9, 0}, {50, 50, 0, 59, 59, 0}})
  T.eq(M.box_n({0, 0, 0, 9, 9, 1}), 200)
  T.ok(W)
end)

---------------------------------------------------------------- BUG-290 / BUG-291
local function pit_tiles()
  return {['40,40,4'] = '~', ['40,40,5'] = '_', ['41,40,5'] = '.', ['39,40,5'] = '.'}
end

T.test('BUG-290 (Run 15 Inkintense: the flooded captives pit 77,57,130 >= 4/7 under the open pit tile, not considered): ' ..
       'open space right above the water beside a reachable floor is a well spot, and the recipe builds the well there',
       function()
  local W, M = world{tiles = pit_tiles(), setup = function(W) F.hospital(W, {30, 30, 34, 34, 5}) end}
  day(W, 2)
  local _, d = ws(W, M)
  local b = d.bodies[1]
  T.eq(b.at, {40, 40, 4})
  T.eq(b.pit, {40, 40, 5}, 'old code: no bank, no dig: "a cistern piped to it"')
  T.eq(b.stand, {39, 40, 5})
  local rc = W.find_events('HOSPITAL_DRY')[1].d.recipe
  T.ok(rc:find('build a well at 40,40,5 over the water at 40,40,4 (7/7, open above it, 39,40,5 reachable)', 1, true), rc)
  T.ok(W.state().water.wsc:find('a well at 40,40,5 over it', 1, true))
  -- the captives pit of Inkintense: a channel's ramp top ('v') over the ramp that holds the water
  local tv = pit_tiles()
  tv['40,40,5'] = 'v'
  local Wv, Mv = world{tiles = tv, setup = function(W) F.hospital(W, {30, 30, 34, 34, 5}) end}
  day(Wv, 2)
  local _, dv = ws(Wv, Mv)
  T.eq(dv.bodies[1].pit, {40, 40, 5})
  -- the floor beside it out of reach: no well spot
  local W2, M2 = world{tiles = pit_tiles(), unreach = {['41,40,5'] = true, ['39,40,5'] = true},
                       setup = function(W) F.hospital(W, {30, 30, 34, 34, 5}) end}
  day(W2, 2)
  local _, d2 = ws(W2, M2)
  T.eq(d2.bodies[1].pit, nil)
end)

T.test('BUG-291 (Run 15 Inkintense: water >= 4/7 seeping on z130, "no aquifer level known"): a revealed aquifer tile ' ..
       'beside the water gives the level: the runner adds it to the manifest, the recipe offers the aquifer well', function()
  local tiles = {['40,40,4'] = '~'}
  local W, M = world{tiles = tiles, aq = {['41,40,4'] = true}, setup = function(W) F.hospital(W, {30, 30, 34, 34, 5}) end}
  day(W, 2)
  T.eq(W.aq_seen[1], 4, 'old code: nothing learnt')
  T.eq(M.aq_level(W.K), 4)
  local _, d = ws(W, M)
  T.eq(d.aq, {4})
  local p = W.K.persist.get('m.water')
  T.eq(p.aqz, {4})
  local hd = W.find_events('HOSPITAL_DRY')
  T.ok(hd[#hd].d.recipe:find(', or an aquifer well (dfllm bp sites cistern water=', 1, true), hd[#hd].d.recipe)
  local rc = M.recipe(M.conf(W.K), nil, W.K)
  T.ok(rc:find('basin on aquifer level z4', 1, true), rc)
end)

T.test('BUG-289 review: the survey lattice (x + 2y) % ws_lattice meets a 1-tile brook in every direction (rows, columns, ' ..
       'both diagonals) within ws_lattice tiles; 3 never met the diagonal x = y + k', function()
  local lat = require('dfllm.water').DEFAULTS.ws_lattice
  local function met(n, dx, dy, x0, y0)
    for i = 0, n - 1 do if ((x0 + i * dx) + 2 * (y0 + i * dy)) % n == 0 then return true end end
    return false
  end
  for _, d in ipairs({{1, 0}, {0, 1}, {1, 1}, {1, -1}}) do
    for x0 = 0, lat - 1 do
      for y0 = 0, lat - 1 do T.ok(met(lat, d[1], d[2], x0 + 50, y0 + 50), d[1] .. ',' .. d[2] .. ' from ' .. x0 .. ',' .. y0) end
    end
  end
  T.ok(not met(3, 1, 1, 51, 50), 'the old lattice 3 misses x = y + 1')
end)

T.done()
