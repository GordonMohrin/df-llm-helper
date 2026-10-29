-- Live test round 2, instance i4 (region2-site90, y723-y726): BUG-179 the tomb repair freed the same 20 zones every run
-- ('freed 20, assigned 0, entomb 0'; the dead owner's remains lay in a coffin under ANOTHER unit's tomb zone, DF gave each
-- zone back to the same owner within 18 ticks), BUG-180 a memorial slab without a site within 16 tiles of the seeds
-- waited (no wider search, no request). Every test here fails on main (b805745).
local T = require('testlib')
local CW = require('care_world')
local F = CW.F

F.ITEM_TYPES[#F.ITEM_TYPES + 1] = 'SLAB'

local function key(x, y, z) return x .. ',' .. y .. ',' .. z end

local function dead(W, id, ghost)
  W.kill(id)
  if ghost then W.unit(id)._m.ghost = true end
  W.event('UNIT_DEATH', {unit = id})
end

local function corpse(W, uid, pos, extra)
  local spec = {unit_id = uid, _pos = pos or {5, 5, 5}}
  for k, v in pairs(extra or {}) do spec[k] = v end
  return F.item(W, 'ANY_CORPSE', spec)
end

local function zones_by_id()
  local by = {}
  for _, z in ipairs(df.global.world.buildings.other.ZONE_TOMB) do by[z.id] = z end
  return by
end

local function inspect(W)
  local r = W.inbox('inspect', {what = 'tombs'})
  T.ok(r.ok, r.msg)
  return r.data, r.msg
end

local function tworld(setup)
  return CW.world{cit = 8, setup = function(W)
    df.civzone_type.Bedroom, df.civzone_type[20] = 20, 'Bedroom'
    df.job_type.PlaceItemInTomb, df.job_type[90] = 90, 'PlaceItemInTomb'
    CW.tomb_acts(W)
    setup(W)
  end}
end

---------------------------------------------------------------- BUG-179: the tomb repair
T.test('BUG-179: remains in a coffin under ANOTHER dead unit\'s tomb zone: the owner\'s own zone is kept (shared), ' ..
       'not freed as "elsewhere"; under an unowned zone it is freed as before', function()
  local zA
  local W = tworld(function(W)
    local _, za = CW.tomb(W, 30, 10, 5, {unit = 3})              -- unit 3's own zone, its coffin empty
    zA = za
    local cofB = CW.tomb(W, 32, 10, 5, {unit = 5})               -- unit 5's zone: the coffin holds 3 and 5
    dead(W, 3); dead(W, 5)
    corpse(W, 3, {32, 10, 5}, {flags = {in_building = true}, _holder = cofB})
    corpse(W, 5, {32, 10, 5}, {flags = {in_building = true}, _holder = cofB})
  end)
  W.run(2)
  CW.day(W)
  T.eq(CW.tacts(W, 'free'), {}, 'old code: zone of 3 freed as elsewhere every run, DF gave it straight back')
  T.eq(zA.assigned_unit_id, 3)
  T.eq(inspect(W).acts.kept_shared, 1, 'the kept zone is counted')
  -- control: the holding coffin's zone has no owner: buried in no one else's tomb, the zone is freed
  local W2 = tworld(function(W)
    CW.tomb(W, 30, 10, 5, {unit = 3})
    local cofB = CW.tomb(W, 32, 10, 5)
    dead(W, 3)
    corpse(W, 3, {32, 10, 5}, {flags = {in_building = true}, _holder = cofB})
  end)
  W2.run(2)
  CW.day(W2)
  T.eq(#CW.tacts(W2, 'free'), 1, 'freed as elsewhere')
end)

T.test('BUG-179: a zone DF gives back to the same dead owner after care\'s free is not freed again (lock churn memo)',
       function()
  local W = tworld(function(W)
    CW.tomb(W, 30, 10, 5, {unit = 3})                            -- zone 2: unit 3, buried in coffin 3 (zone unowned)
    local cofB = CW.tomb(W, 32, 10, 5)
    dead(W, 3)
    corpse(W, 3, {32, 10, 5}, {flags = {in_building = true}, _holder = cofB})
  end)
  W.run(2)
  CW.day(W)
  local frees = CW.tacts(W, 'free')
  T.eq(#frees, 1)
  local zid = frees[1][2]
  for _ = 1, 3 do
    zones_by_id()[zid].assigned_unit_id = 3                      -- DF hands the freed zone back to the same owner
    W.ms = W.ms + 600000
    CW.day(W, 1)
  end
  T.eq(#CW.tacts(W, 'free'), 1, 'old code: freed again every run (live i4: churn 20 per run, 562 since boot)')
  T.eq(zones_by_id()[zid].assigned_unit_id, 3)
  T.ok((inspect(W).acts.kept_regive or 0) >= 1, 'the kept re-given zone is counted')
end)

---------------------------------------------------------------- BUG-180: the memorial site search
local function memorial(W, hf, pos)
  return F.item(W, 'SLAB', {engraving_type = 0, topic = hf, _pos = pos or {12, 12, 5}, flags = {}})
end

local function mworld(o)
  local floor = {}
  for _, r in ipairs(o.floor or {}) do
    for y = r[2], r[4] do for x = r[1], r[3] do floor[key(x, y, r[5])] = true end end
  end
  local W = CW.world{
    cit = 8, census_i = {rock = 50, wood = 40}, pending = {},
    tile = function(x, y, z) return {c = floor[key(x, y, z)] and '.' or '#', dig = '', bld = ''} end,
    snap = {outside_near = function(K, pts) local out = {}; for i = 1, #pts do out[i] = 0 end; return out end,
            far = function() return false end},
    setup = function(W)
      df.civzone_type.Bedroom, df.civzone_type[20] = 20, 'Bedroom'
      df.job_type.PlaceItemInTomb, df.job_type[90] = 90, 'PlaceItemInTomb'
      df.job_type.EngraveSlab, df.job_type[91] = 91, 'EngraveSlab'
      df.slab_engraving_type = {Slab = -1, Memorial = 0, [-1] = 'Slab', [0] = 'Memorial'}
      df.building_type.Slab, df.building_type[40] = 40, 'Slab'
      CW.tomb_acts(W)
      W.placed = {}
      W.act_result('slab_place', function(id, x, y, z) W.placed[#W.placed + 1] = {id, x, y, z}; return true, 99 end)
      W.unit(7).hist_figure_id = 7007
      dead(W, 7, true)
      W.slab = memorial(W, 7007)
      df.global.building_next_id = #df.global.world.buildings.all + 1
    end}
  W.K.cfg.baseline.care = o.care
  return W
end

local function mem_requests(W)
  local r = {}
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.why == 'memorial' then r[#r + 1] = e end end
  return r
end

T.test('BUG-180: no free 3x3 within coffin_scan_r (16) of the seeds: the search widens (32, 48) and places the slab',
       function()
  local W = mworld{floor = {{50, 20, 56, 26, 5}}}             -- a hall 25-31 tiles east of the core seed 25,25,5
  CW.day(W)
  T.eq(#W.placed, 1, 'old code: "no free 3x3 floor ... within 16" and the slab waited')
  T.eq(W.placed[1][4], 5)
  T.ok(W.placed[1][2] >= 51 and W.placed[1][2] <= 55, 'inside the hall: ' .. tostring(W.placed[1][2]))
end)

T.test('BUG-180: no site at all for mem_req_days (3): PROJECT_REQUEST tombs why=memorial (follow digs a crypt room); ' ..
       'mem_req_days 0 asks nothing', function()
  local W = mworld{floor = {}, care = {tomb_margin = 0}}
  CW.day(W)
  T.eq(#W.placed, 0)
  T.eq(#mem_requests(W), 0, 'not on the first day')
  for _ = 1, 5 do CW.day(W) end
  local ev = mem_requests(W)
  T.eq(#ev, 1, 'old code: no request ever')
  T.eq({ev[1].d.tpl, ev[1].d.n}, {'tombs', 1})
  T.ok(ev[1].msg:find('memorial', 1, true), ev[1].msg)
  local W2 = mworld{floor = {}, care = {tomb_margin = 0, mem_req_days = 0}}
  for _ = 1, 6 do CW.day(W2) end
  T.eq(#mem_requests(W2), 0)
end)

-- BUG-217 (live 4: the searches for slab 2991783 came 30771 and 28366 ticks apart under care's pacing; each one began
-- a new episode, so no request in 49 game days): the clock jumps 24 days between the care runs
local function far_day(W)
  local g = df.global
  g.cur_year_tick = g.cur_year_tick + 24 * 1200
  CW.day(W)
end

T.test('BUG-217: memorial searches far apart (> 2 x coffin_retry) for the same slab keep one episode: the request comes',
       function()
  local W = mworld{floor = {}, care = {tomb_margin = 0}}
  CW.day(W)
  local since = W.K.persist.get('m.care').mem_nosite.since
  for _ = 1, 3 do far_day(W) end
  local ns = W.K.persist.get('m.care').mem_nosite
  T.eq(ns.since, since, 'old code: since = now on every search')
  T.eq(ns.sid, tostring(W.slab.id))
  T.ok(#mem_requests(W) >= 1, 'old code: no request ever (live: 0 in 59000 ticks)')
end)

T.test('BUG-217: no loose memorial slab left: the episode ends, a later slab starts afresh', function()
  local W = mworld{floor = {}, care = {tomb_margin = 0}}
  CW.day(W)
  local s1 = W.K.persist.get('m.care').mem_nosite.since
  W.slab.topic = 9999                                         -- no longer the ghost's memorial
  far_day(W)
  T.eq(W.K.persist.get('m.care').mem_nosite, nil, 'old code: the stale episode stayed')
  local s2 = memorial(W, 7007)
  far_day(W)
  local ns = W.K.persist.get('m.care').mem_nosite
  T.eq(ns.sid, tostring(s2.id))
  T.ok(ns.since >= s1 + 48 * 1200, 'a new episode: ' .. tostring(ns.since))
  T.eq(#mem_requests(W), 0, 'not on the new slab\'s first day')
end)

T.done()
