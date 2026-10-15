-- water (Run 9 FRs): the hospital gate (FR-31/34, HOSPITAL_DRY with a recipe), the water sources scan behind
-- inspect what=water_sources (FR-47: deep water per level, a reachable bank, the shortest dig), and the real
-- snapshot.liquids it reads (revealed, non-magma water only).
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local DEPTH = {['~'] = 7, w = 2}

-- opts: tiles {['x,y,z'] = char} (default '#'), unreach {['x,y,z'] = true}, patients, cfg (water overrides),
--       setup(W), no_liquids
local function world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, 4 do units[i] = {id = i, citizen = true, pos = {12, 12, 5}} end
  local persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {{0, 0, 0, 99, 99, 20}}}}}
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, persist = persist}
  df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  local ids = {}
  for i = 1, 4 do
    ids[i] = i
    W.unit(i).counters2 = {thirst_timer = 1000}
    W.unit(i).job = {current_job = nil}
  end
  for _, pt in ipairs(opts.patients or {}) do
    W.unit(pt.id).counters2.thirst_timer = pt.thirst
    W.unit(pt.id).health = {flags = {needs_healthcare = true}}
  end
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 0, 0, 99, 99, 20})
  W.cmap, W.unreach, W.tile_reads, W.liquid_calls = opts.tiles or {}, opts.unreach or {}, 0, 0
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile(K, x, y, z)
    W.tile_reads = W.tile_reads + 1
    local c = W.cmap[x .. ',' .. y .. ',' .. z] or '#'
    if c == '?' then return nil end
    return {c = c, dig = '', bld = '', flow = DEPTH[c] or 0}
  end
  if not opts.no_liquids then
    function snap.liquids(K, x0, y0, x1, y1, z, min)
      W.liquid_calls = W.liquid_calls + 1
      local out = {}
      for y = y0, y1 do
        for x = x0, x1 do
          local f = DEPTH[W.cmap[x .. ',' .. y .. ',' .. z] or ''] or 0
          if f >= (min or 1) then out[#out + 1] = {x, y, f} end
        end
      end
      return out
    end
  end
  function snap.reach(K, a, b) return not W.unreach[b.x .. ',' .. b.y .. ',' .. b.z] end
  W.load(snap)
  if opts.setup then opts.setup(W) end
  local M = fresh('water')
  if opts.cfg then
    local cfg = F.cfg()
    cfg.water = opts.cfg
    W.K.cfg.baseline = cfg
  end
  W.load(M)
  return W, M
end

-- a game day in 120 frames (the scan reads 1,500 tiles a frame; the game gives it many more frames a day)
local function day(W, n) for _ = 1, n or 1 do W.run(1200, {skip = 10}) end end
local function hospital(W) return F.hospital(W, {10, 10, 14, 14, 5}) end
local function sources(W)
  local r = W.inbox('inspect', {what = 'water_sources'})
  T.ok(r.ok, r.msg)
  return r.data, r.msg
end

T.test('HOSPITAL_DRY waits for the scan, then names the reachable bank of the nearest deep water', function()
  local W = world{tiles = {['20,12,5'] = '~', ['21,12,5'] = '~', ['19,12,5'] = '.', ['21,13,5'] = 'w'},
                  setup = hospital}
  day(W)
  local hd = W.find_events('HOSPITAL_DRY')
  T.eq(#hd, 1)
  T.ok(hd[1].d.recipe:find('zone the water at 20,12,5 (7/7) as Water Source, bank 19,12,5 is reachable', 1, true),
       hd[1].d.recipe)
  T.ok(hd[1].d.recipe:find('until then delete the hospital zone', 1, true))
  T.eq(hd[1].d.zone, W.find_events('HOSPITAL_DRY')[1].d.zone)
  local d = sources(W)
  T.eq(#d.bodies, 1)
  local b = d.bodies[1]
  T.eq({b.z, b.n, b.max, b.at, b.d, b.bank, b.reach, b.zone, b.well}, {5, 2, 7, {20, 12, 5}, 6, {19, 12, 5}, 1, -1, -1})
  T.eq(d.deep, 4)
  T.eq(d.levels, {{5, 2}}, 'the 2/7 tile is no deep water')
  T.ok(d.boxes[1][1] == 0 and d.boxes[1][4] == 44 and d.boxes[1][3] == 2 and d.boxes[1][6] == 8, json.encode(d.boxes))
end)

T.test('walled-in deep water (FR-47, Run 9 probe pool): the shortest dig through revealed rock to a reachable floor', function()
  local W = world{tiles = {['40,40,5'] = '~', ['43,40,5'] = '.', ['38,40,5'] = '.'}, unreach = {['38,40,5'] = true},
                  setup = function(W) F.hospital(W, {30, 30, 34, 34, 5}) end}
  day(W)
  local d = sources(W)
  local b = d.bodies[1]
  T.eq(b.bank, nil)
  T.eq(b.reach, 0)
  T.eq({b.dig.n, b.dig.from}, {2, {43, 40, 5}}, 'two walls between the pool and the reachable floor')
  T.ok(math.abs(b.dig.to[1] - 40) <= 1 and math.abs(b.dig.to[2] - 40) <= 1, json.encode(b.dig.to))
  local hd = W.find_events('HOSPITAL_DRY')
  T.ok(hd[1].d.recipe:find('dig 2 wall tile(s) from 43,40,5', 1, true), hd[1].d.recipe)
  T.ok(d.note:find('floods', 1, true))
end)

T.test('hidden tiles stop the dig plan; no deep water at all: the recipe is a cistern', function()
  local tiles = {['40,40,5'] = '~', ['43,40,5'] = '.'}
  for _, o in ipairs({{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}) do
    tiles[(40 + o[1]) .. ',' .. (40 + o[2]) .. ',5'] = '?'                -- unrevealed all around the pool
  end
  local W = world{tiles = tiles, setup = function(W) F.hospital(W, {30, 30, 34, 34, 5}) end}
  day(W)
  local b = sources(W).bodies[1]
  T.eq({b.n, b.bank, b.dig}, {1, nil, nil}, 'the pool is known, the way through hidden tiles is not planned')
  T.ok(W.find_events('HOSPITAL_DRY')[1].d.recipe:find('a cistern', 1, true))
  local W2 = world{tiles = {['20,12,5'] = 'w'}, setup = hospital}
  day(W2)
  local hd = W2.find_events('HOSPITAL_DRY')
  T.ok(hd[1].d.recipe:find('no reachable water >= 4/7 within 30 tiles: a cistern', 1, true), hd[1].d.recipe)
  T.eq(sources(W2).bodies, {})
end)

T.test('a deep Water Source zone near the hospital: served, no gate; the scan runs only on request', function()
  local W = world{tiles = {['20,12,5'] = '~', ['19,12,5'] = '.'}, setup = function(W)
    hospital(W)
    F.building(W, 'ZONE_WATER_SOURCE', {id = 70, type = df.civzone_type.WaterSource, x1 = 19, y1 = 12, x2 = 20,
                                        y2 = 12, z = 5, spec_sub_flag = {active = true}})
  end}
  day(W)
  T.eq(W.find_events('HOSPITAL_DRY'), {})
  T.eq(W.liquid_calls, 0, 'no gate, no request: no scan')
  local r = W.inbox('inspect', {what = 'water_sources'})
  T.ok(r.ok and r.msg:find('scan queued', 1, true), r.msg)
  T.eq(r.data.queued, 1)
  T.eq(r.data.sources, {{'zone', 70, 19, 12, 5, 1}})
  day(W)
  local d = sources(W)
  T.eq({d.bodies[1].zone, d.bodies[1].bank, d.queued}, {70, {19, 12, 5}, 0})
  T.ok(W.liquid_calls > 0)
end)

T.test('without a hospital the scan centres on the citizens; without snapshot.liquids it reports the gap', function()
  local W = world{tiles = {['30,20,6'] = '~', ['30,21,6'] = '.'}}
  W.inbox('inspect', {what = 'water_sources'})
  day(W)
  local d = sources(W)
  T.eq(d.boxes, {{0, 0, 2, 42, 42, 8}})
  T.eq({#d.bodies, d.bodies[1].z, d.bodies[1].bank}, {1, 6, {30, 21, 6}})
  local W2 = world{no_liquids = true, setup = hospital}
  day(W2)
  T.eq(#W2.find_events('HOSPITAL_DRY'), 1, 'no scan possible: the gate does not wait')
  W2.inbox('inspect', {what = 'water_sources'})
  day(W2)
  local d2 = sources(W2)
  T.ok(d2.err and d2.err:find('snapshot.liquids', 1, true), tostring(d2.err))
end)

T.test('a slow scan (ws_tiles small) never delays the patients\' run past its cadence', function()
  local W, M = world{tiles = {['20,12,5'] = '~', ['19,12,5'] = '.'}, setup = hospital, cfg = {ws_tiles = 45},
                     patients = {{id = 2, thirst = 1000}}}
  W.run(100, {skip = 100})                                     -- the run, then the scan starts
  W.unit(2).counters2.thirst_timer = 35000
  day(W)
  T.eq(#W.find_events('DECISION_NEEDED'), 1, 'patient_thirst on time while the scan is still running')
  W.run(2000, {skip = 1})
  T.ok(#sources(W).bodies == 1)
end)

T.test('inspect what=water_sources stays within 8 KB with many water bodies', function()
  local tiles = {}
  for i = 0, 40 do for j = 0, 40, 2 do tiles[(i * 3 % 60) .. ',' .. j .. ',' .. (4 + i % 3)] = '~' end end
  local W = world{tiles = tiles, setup = hospital}
  day(W)
  local d = sources(W)
  T.ok(#d.bodies <= 12, #d.bodies)
  T.ok(#json.encode(d) < 8192, #json.encode(d))
end)

---------------------------------------------------------------- the real snapshot.liquids
T.test('snapshot.liquids: revealed water only, magma never, depth filter, the rect limit', function()
  local W = kmock.new{}
  local S = fresh('snapshot')
  W.load(S)
  local function t(x, y, z, flow, hidden, magma)
    W.tiles = W.tiles or {}
    W.tiles[x .. ',' .. y .. ',' .. z] = {des = {hidden = hidden, flow_size = flow, liquid_type = magma}, occ = {}}
  end
  t(1, 1, 5, 7); t(2, 1, 5, 3); t(3, 1, 5, 6, true); t(1, 2, 5, 7, false, true); t(2, 2, 5, 0)
  T.eq(S.liquids(W.K, 0, 0, 4, 4, 5, 4), {{1, 1, 7}})
  T.eq(S.liquids(W.K, 0, 0, 4, 4, 5), {{1, 1, 7}, {2, 1, 3}})
  T.eq(S.liquids(W.K, 4, 4, 0, 0, 5), {}, 'an empty rect')
  T.eq({S.liquids(W.K, 0, 0, 99, 99, 5)}, {nil, 'rect too large'})
end)

T.done()
