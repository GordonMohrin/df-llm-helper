-- BUG-595 / BUG-596 / BUG-597 (Run 16b i2 Brotherarrow y414, Pop 86 -> 2: Blind Cave Ogres, 57 goblins; SIEGE_DEEP at 107 tiles 'the bridges are no
-- barrier, nor the refuge hatch 84,121,134', 23 civilians to Tiefe+; the plug round the stair foot was queued 119,000 ticks later, in the BREACH,
-- with an ogre on the stair; patients lay in a hospital outside Tiefe+ and 'Pflege+ not opened: no fresh hostile census' 14 times; 640 drinks and
-- 14 food stayed forbidden in the BREACH). The siege traffic tests of this round (the world of test_bug588_589_refuge_destroyers.lua: the
-- Kern+ hall, the civilians' stair at 6,6 from z9 down to Tiefe+ at z5, a hatch on its head, the citizens walking in over time):
--   (1) BUG-595: destroyers in sight 107 tiles out (SIEGE_DEEP), one patient lying outside Tiefe+ the whole siege: the plug used to wait for
--       ever ('wait:destroyers far'); now it waits PLUG.out_wait ticks for the walkers and then walls the foot (REFUGE_PLUG early, out=1),
--       before the destroyers are anywhere near; the destroyers announced by the popup only (nothing in sight) count too;
--   (2) BUG-595: the access is walled before the destroyers arrive: a queued but unfinished plug with a destroyer on the stair is no wall (the
--       separated Innen+ far from them holds the citizens), the finished plug is (Tiefe+ again);
--   (3) BUG-596: the care burrow (patient water in a long siege): a census that lists 40 of 57 hostiles used to give 'no fresh hostile census'
--       for ever; with the cut's lower bound (h.lo, h.o1) a patient and a well far from O1 open it, one near O1 stay closed; the repeated
--       patient_thirst line comes at ALERT_REPEAT times the interval while the alert alone keeps the carers away;
--   (4) BUG-597: a BREACH (or SIEGE) frees the forbidden food and drink inside the confinement burrow, not what lies outside it.
local T = require('testlib')
local SW = require('seal_world')

local Z = 9
local INSIDE = {{1, 8, 8, Z - 4}, {2, 8, 7, Z - 4}, {3, 8, 6, Z - 4}}
local function fort(o)
  o = o or {}
  local W = SW.new{persist = {['m.seal'] = nil, manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
                                            refuge = {anchor = {5, 5, Z - 4}, burrow = 'Tiefe+'},
                                            stairs = {civ = {{6, 6, Z - 4, Z}}}}}}
  SW.fill(W, Z + 1, 0, 0, 40, 30, ',')
  SW.draw(W, Z + 1, {'>'}, 20, 10, {outside = true})
  SW.fill(W, Z, 0, 0, 40, 30, '#')
  SW.fill(W, Z, 5, 5, 15, 15, '.')
  SW.fill(W, Z, 16, 10, 19, 10, '.')
  SW.draw(W, Z, {'<'}, 20, 10)
  SW.draw(W, Z, {'+'}, 19, 10)
  SW.draw(W, Z, {'bb'}, 12, 12)
  if o.room then
    SW.fill(W, Z, 16, 8, 24, 8, '.')
    SW.fill(W, Z, 25, 5, 35, 12, '.')
    SW.draw(W, Z, {'bb'}, 30, 8)
  end
  SW.draw(W, Z, {'>'}, 6, 6)
  for z = Z - 3, Z - 1 do
    SW.fill(W, z, 0, 0, 40, 30, '#')
    SW.draw(W, z, {'X'}, 6, 6)
  end
  SW.fill(W, Z - 4, 0, 0, 40, 30, '#')
  SW.fill(W, Z - 4, 5, 5, 8, 8, '.')
  SW.draw(W, Z - 4, {'<'}, 6, 6)
  SW.regroup(W)
  SW.citizens(W, o.cits or INSIDE)
  SW.item(W, 'DRINK', 9, 13, Z, 20)
  SW.item(W, 'PLANT', 9, 14, Z, 20)
  if o.stock then
    SW.item(W, 'DRINK', 7, 7, Z - 4, 20)
    SW.item(W, 'PLANT', 7, 8, Z - 4, 20)
  end
  W.burrow('Kern+', {5, 5, Z, 15, 15, Z})
  W.burrow('Tiefe+', {5, 5, Z - 4, 8, 8, Z - 4})
  if o.room then W.burrow('Innen+', {25, 5, Z, 35, 12, Z}) end
  local repairs = {}
  W.cancelled = {}
  W.pstate = function() return {done = false} end
  W.load(SW.fake('runner', {repair = function(K, cells, why) repairs[#repairs + 1] = {cells = cells, why = why}; return true, 'rp' .. #repairs end,
                            plug_proj = function(K, id) return W.pstate(id) end,
                            cancel_proj = function(K, id) W.cancelled[#W.cancelled + 1] = id; return true end}))
  package.loaded['dfllm.seal'] = nil
  local M = require('dfllm.seal')
  M.PLUG.every = 0
  W.load(M)
  W.run(2400, {skip = 9})
  return W, M, repairs
end

local function hatch(W)
  local h = SW.building(W, 'DOOR', 'Hatch', 6, 6, Z - 3)
  W.dyn[SW.key(6, 6, Z - 3)] = h
  W.tiles[SW.key(6, 6, Z - 3)].occ.building = df.tile_building_occ.Dynamic
end

local function census(W, list)
  local l, nbd = {}, 0
  for i, e in ipairs(list) do
    l[i] = {id = 500 + i, x = e[1], y = e[2], z = e[3], bd = e.bd or 0}
    nbd = nbd + (e.bd or 0)
  end
  W.set_census('h', {tick = W.K.now().tick, vis = #l, armed = 1, inside = 0, bd = nbd, list = l})
end

local function refresh(W)
  local r = W.inbox('inspect', {what = 'refuge', key = 'refresh'})
  T.ok(r.ok, r.msg)
  W.run(1200, {skip = 9})
end

local function ask(W, mode, want, cur)
  local ok, pick, note, short, flee = W.K.call('seal', 'alert_burrow', mode, want, false, cur)
  T.ok(ok, tostring(pick))
  return pick, flee, note
end

T.test('BUG-595 (1): destroyers in sight far away, a patient lying outside Tiefe+ all siege: the plug waits PLUG.out_wait ticks for the walkers, then ' ..
       'walls the foot (old: wait:destroyers far for ever); the destroyers of the popup alone (none in sight) count', function()
  local W, M, repairs = fort{cits = {{1, 8, 8, Z - 4}, {2, 8, 7, Z - 4}, {3, 10, 9, Z}}}   -- 3: the patient in the hall
  hatch(W)
  refresh(W)
  W.set_mode('SIEGE')
  census(W, {{6, 60, Z, bd = 1}})                      -- 54 tiles from the stair head
  T.eq(select(2, W.K.call('seal', 'plug', {bd = true})), 'wait:destroyers far', 'the walker is given its time')
  W.run(M.PLUG.out_wait // 2, {skip = 9})
  census(W, {{6, 60, Z, bd = 1}})
  T.eq(select(2, W.K.call('seal', 'plug', {bd = true})), 'wait:destroyers far', 'half of it')
  W.run(M.PLUG.out_wait // 2 + 100, {skip = 9})
  census(W, {{6, 60, Z, bd = 1}})
  local _, st = W.K.call('seal', 'plug', {bd = true})
  T.eq(st, 'queued', 'old: wait:destroyers far')
  T.eq(#repairs, 1)
  local ev = W.find_events('REFUGE_PLUG')
  T.eq({#ev, ev[1].d.early, ev[1].d.breach, ev[1].d.out}, {1, 1, 0, 1})
  -- the popup announced engineers, nothing in sight yet, everybody inside: walled at once
  local W2, _, repairs2 = fort()
  hatch(W2)
  refresh(W2)
  W2.set_mode('SIEGE')
  census(W2, {})
  T.eq(select(2, W2.K.call('seal', 'plug', {bd = true})), 'wait:destroyers far', 'old and without the announcement')
  local _, st2 = W2.K.call('seal', 'plug', {bd = true, announced = true})
  T.eq(st2, 'queued', 'announced')
  T.eq(#repairs2, 1)
end)

T.test('BUG-595 (2): the access is a wall before the destroyers come: a queued, unfinished plug with a destroyer on the stair is no wall ' ..
       '(Innen+ holds the citizens), the finished one is (Tiefe+)', function()
  local W, M, repairs = fort{room = true, stock = true}
  hatch(W)
  refresh(W)
  W.set_mode('SIEGE')
  census(W, {{6, 60, Z, bd = 1}})
  T.eq(select(2, W.K.call('seal', 'plug', {bd = true})), 'queued')
  T.eq(ask(W, 'BREACH', 'Tiefe+'), 'Tiefe+', 'the destroyers far: the refuge, its foot walled by the citizens inside')
  census(W, {{6, 6, Z - 2, bd = 1}})                  -- a destroyer on the stair column before the walls stand
  local pick, flee = ask(W, 'BREACH', 'Tiefe+')
  T.eq({pick, flee}, {'Innen+', false}, 'old: Tiefe+ (a queued plug counted as a wall)')
  W.pstate = function() return {done = true} end      -- the walls stand
  pick = ask(W, 'BREACH', 'Tiefe+')
  T.eq(pick, 'Tiefe+', 'built: a hatch broken, the wall stays')
end)

-- (3) BUG-596: census.h cut at 40 of 57 hostiles (the world of test_bug571_care_siege_out.lua)
local C = require('dfllm.util.contract')
local F = require('wp8_world')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'
local FEED = 40
local function owners()
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'work_detail', 'burrow_tiles'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn] or {}) do if o ~= 'water' then keep[#keep + 1] = o end end
    keep[#keep + 1] = 'water'
    C.ACT[fn] = keep
  end
end
-- o.lo / o.o1: the cut's bound; o.foe: the nearest listed hostile
local function care_world(o)
  owners()
  local units = {}
  for i = 1, 8 do units[i] = {id = i, citizen = true, pos = {50, 50, 2}} end
  local persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
                               zones = {Z4 = {{0, 0, 0, 99, 99, 20}}}}}
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, persist = persist}
  df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  df.job_type.GiveWater, df.job_type[78] = 78, 'GiveWater'
  df.unit_labor = {FEED_WATER_CIVILIANS = FEED, MINE = 41, CUTWOOD = 42, HUNT = 43}
  local ids = {}
  for i = 1, 8 do
    ids[i] = i
    local u = W.unit(i)
    u.counters2 = {thirst_timer = 1000}
    u.job = {current_job = nil}
    u.status = {labors = {[FEED] = i <= 4, [41] = false, [42] = false, [43] = false}}
  end
  local pu = W.unit(5)
  pu.counters2.thirst_timer = 58000
  pu.health = {flags = {needs_healthcare = true}}
  W.move(5, 30, 30, 5)
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 25, 0, 60, 60, 20})
  W.set_mode('SIEGE')
  W.burrow('Tiefe+', {40, 40, 2, 60, 60, 2})
  W.load({name = 'snapshot', every = {ticks = 100}, far = function() return false end,
          tile = function(K, x, y, z)
            return {c = (x == 20 and y == 12 and z == 4) and '_' or ((x == 20 and y == 12 and z == 3) and '~' or '#'), dig = '', bld = ''} end})
  W.load({name = 'seal', every = {ticks = 100000}, groups = function(K) return {sealed = true, stale = false} end})
  df.global.plotinfo.alerts.civ_alert_idx = 1
  W.load({name = 'siege', every = {ticks = 1000}, alert_names = function() return {'Tiefe+'} end})
  F.building(W, 'WELL', {x1 = 20, y1 = 12, x2 = 20, y2 = 12, z = 5})
  for i = 1, 3 do F.item(W, 'BUCKET', {_pos = {20, 13 + i, 5}}) end
  W.act_result('work_detail', function(name, id, on) W.unit(id).status.labors[FEED] = on; return true, 'added' end)
  df.global.world.jobs = {list = {next = {item = {job_type = 78, id = 501}}}}
  dfhack.job = dfhack.job or {}
  dfhack.job.getWorker = function(j) return nil end
  W.foe, W.cut = o.foe, o
  package.loaded['dfllm.water'] = nil
  local M = require('dfllm.water')
  W.load(M)
  return W, M
end
local function care_day(W, n)
  for _ = 1, (n or 1) * 12 do
    local list = {}
    if W.foe then list[1] = {id = 900, x = W.foe[1], y = W.foe[2], z = W.foe[3], k = 'inv', d_o1 = 50, dc = 50} end
    W.set_census('h', {tick = W.K.now().tick, vis = 57, inv = 57, inside = 0, list = list, lo = W.cut.lo, o1 = W.cut.o1})
    W.run(100, {skip = 100})
  end
end

T.test('BUG-596 (3): 57 hostiles in sight, 40 listed (old: no fresh hostile census for ever): the cut\'s bound opens the care burrow for a patient ' ..
       'and a well far from O1, not when the unlisted ones may be near; without the bound (an old census) it stays closed', function()
  -- O1 at 30,100,5: the well (20,12,5) lies 88 tiles from it, the patient (30,30,5) 70; the unlisted hostiles are 160+ tiles from O1
  local W, M = care_world{foe = {5, 95, 5}, lo = 160, o1 = {30, 100, 5}}
  care_day(W)
  T.eq(M.care_rooms(W.K), {'Pflege+'}, 'old: closed, no fresh hostile census')
  T.eq(M.foe_dist(W.K, 20, 12, 5), 72, 'the bound 160 - 88 (the listed goblin is 83 away)')
  local W2, M2 = care_world{foe = {5, 95, 5}, lo = 100, o1 = {30, 100, 5}}     -- 100 - 88 = 12 <= care_siege_near
  care_day(W2)
  T.eq(M2.care_rooms(W2.K), {}, 'the unlisted ones may be 12 tiles from the well')
  local W3, M3 = care_world{foe = {5, 95, 5}}
  care_day(W3)
  T.eq(M3.care_rooms(W3.K), {}, 'a census without the bound: unknown as before')
  T.eq(M3.foe_dist(W3.K, 74, 83, 5), nil)
end)

T.test('BUG-596: the patient_thirst reminder while the alert alone keeps the carers away comes at ALERT_REPEAT times the interval', function()
  local W = care_world{foe = {5, 95, 5}}       -- no bound: the care burrow stays closed
  W.K.cfg.baseline.water = W.K.cfg.baseline.water or {}
  W.K.cfg.baseline.water.wake_wall_s = 0       -- (the wall clock of the wake rule does not run in the test)
  care_day(W, 60)
  local n = 0
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'patient_thirst' then n = n + 1 end end
  T.ok(n >= 1 and n <= 3, 'patient_thirst in 60 days (old: weekly, 8): ' .. n)
end)

-- (4) BUG-597
local function eco_world(mode)
  local cfg = F.cfg()
  local units = {}
  for i = 1, 6 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}} end
  local W = F.world{cfg = {baseline = cfg}, units = units, mode = mode}
  local ids = {}
  for i = 1, 6 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  W.set_census('u', F.census_u(ids))
  W.burrow('Tiefe+', {0, 0, 100, 30, 30, 100})
  W.act_result('item_flag', function(id, flag, on) W.items_by_id[id].flags[flag] = on; return true end)
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, far = function() return false end,
          reach = function() return true end, plot_under = function() return false end})
  W.load({name = 'siege', every = {ticks = 100000}, alert_names = function() return {'Tiefe+'} end})
  df.global.plotinfo.alerts.civ_alert_idx = 1
  return W
end
T.test('BUG-597: a BREACH or SIEGE with the alert on frees the forbidden drink and food inside the confinement burrow, not outside it (old: ' ..
       'mode BREACH held it all back)', function()
  local function run(mode)
    local W = eco_world(mode)
    local inn, out = {}, {}
    for i = 1, 20 do inn[#inn + 1] = F.item(W, 'DRINK', {stack_size = 20, flags = {forbid = true}, _pos = {5 + i % 20, 5, 100}}) end
    for i = 1, 5 do out[#out + 1] = F.item(W, 'DRINK', {stack_size = 20, flags = {forbid = true}, _pos = {60 + i, 5, 100}}) end
    local food_in = F.item(W, 'FOOD', {stack_size = 2, subtype = 1, flags = {forbid = true}, _pos = {7, 6, 100}})
    F.item(W, 'FOOD', {stack_size = 500, subtype = 1, _pos = {1, 1, 100}})
    package.loaded['dfllm.economy'] = nil
    W.load(require('dfllm.economy'))
    for _ = 1, 3 do W.run(1200, {skip = 100}); for _ = 1, 80 do W.run(1) end end
    local function left(l) local n = 0; for _, it in ipairs(l) do if it.flags.forbid then n = n + 1 end end return n end
    return left(inn), left(out), food_in.flags.forbid
  end
  local a, b, c = run('BREACH')
  T.eq({a, b, c}, {0, 5, false}, 'BREACH: inside freed (drink and food), outside kept')
  a, b, c = run('SIEGE')
  T.eq({a, b, c}, {0, 5, false}, 'SIEGE: the same')
end)

T.done()
