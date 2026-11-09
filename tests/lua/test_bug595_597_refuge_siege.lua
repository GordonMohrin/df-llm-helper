-- BUG-595 / BUG-596 / BUG-597 (Run 16b i2 Brotherarrow y414, Pop 86 -> 2: Blind Cave Ogres, 57 goblins; SIEGE_DEEP at 107 tiles 'the bridges are no
-- barrier, nor the refuge hatch 84,121,134', 23 civilians to Tiefe+; the plug round the stair foot was queued 119,000 ticks later, in the BREACH,
-- with an ogre on the stair; patients lay in a hospital outside Tiefe+ and 'Pflege+ not opened: no fresh hostile census' 14 times; 640 drinks and
-- 14 food stayed forbidden in the BREACH). The siege traffic tests of this round (the world of test_bug588_589_refuge_destroyers.lua: the
-- Kern+ hall, the civilians' stair at 6,6 from z9 down to Tiefe+ at z5, a hatch on its head, the citizens walking in over time):
--   (1) BUG-595 (with walking units: citizens stream to the stair while a destroyer walks in from 100 tiles): a bedridden patient outside
--       Tiefe+ does not hold the plug (old: wait:destroyers far for ever), walkers do until the last is in (nobody walled out, nobody on the
--       stair when the walls are ordered), a walker who never comes holds it out_wait + out_each ticks from the last arrival and is then
--       walled out while the destroyer is still far; the destroyers announced by the popup only (nothing in sight) count too;
--   (2) BUG-595 (same traffic): the access is walled before the destroyers arrive: every pick on the way is Tiefe+ when the walls stand; a
--       queued but unfinished plug with the destroyer on the stair is no wall (the separated Innen+ holds the citizens);
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

-- one walker's route into Tiefe+: diagonally over the hall to the stair head, down the stair, one step into the burrow
local function route(x, y)
  local r = {{x, y, Z}}
  while x ~= 6 or y ~= 6 do
    if x > 6 then x = x - 1 elseif x < 6 then x = x + 1 end
    if y > 6 then y = y - 1 elseif y < 6 then y = y + 1 end
    r[#r + 1] = {x, y, Z}
  end
  for z = Z - 1, Z - 4, -1 do r[#r + 1] = {6, 6, z} end
  r[#r + 1] = {7, 6, Z - 4}
  r[#r + 1] = {8, 6, Z - 4}               -- (out of the foot ring: 2 tiles from the stair)
  return r
end
local function in_refuge(p) return p[3] == Z - 4 and p[1] >= 5 and p[1] <= 8 and p[2] >= 5 and p[2] <= 8 end

-- The siege traffic world. o.walkers = {{id, x, y, start, stuck = true}} walk to the stair one tile per 9 ticks from `start` (stuck: never);
-- o.patient lies bedridden (needs_healthcare) in the hall; the destroyer walks in from 100 tiles out (y = 106) toward the stair head, one tile
-- per o.per ticks, then down the stair. After every step the plug is asked (bd = true); o.ask: the alert is asked too once the plug is queued;
-- o.finish: the builders need that many ticks after the order; o.unfinished: never. Returns the log:
-- queued = {rel, dist, outside, stair} at the tick the plug was ordered, picks, arrive = the tick the destroyer is on the stair.
local function traffic(o)
  local cits, walkers = {{1, 8, 8, Z - 4}, {2, 8, 7, Z - 4}}, {}
  for _, w in ipairs(o.walkers) do
    cits[#cits + 1] = {w.id, w.x, w.y, Z}
    walkers[#walkers + 1] = {id = w.id, route = route(w.x, w.y), i = 1, start = w.start, stuck = w.stuck}
  end
  if o.patient then cits[#cits + 1] = {o.patient, 10, 9, Z} end
  local W, M, repairs = fort{cits = cits, room = o.room, stock = o.room}
  hatch(W)
  refresh(W)
  W.set_mode('SIEGE')
  if o.patient then W.unit(o.patient).health = {flags = {needs_healthcare = true}} end
  local log = {picks = {}, repairs = repairs, walkers = walkers}
  local rel, finish_at = 0, nil
  while rel < o.ticks do
    W.run(9, {skip = 9})
    rel = rel + 9
    for _, w in ipairs(walkers) do
      if rel >= w.start and not w.stuck and w.i < #w.route then
        w.i = w.i + 1
        local p = w.route[w.i]
        W.move(w.id, p[1], p[2], p[3])
      end
    end
    local steps = rel // o.per
    local dy, dz = 106 - steps, Z
    if dy < 6 then dy, dz = 6, math.max(Z - 2, Z - (steps - 100)) end
    census(W, {{6, dy, dz, bd = 1}})
    local _, s = W.K.call('seal', 'plug', {bd = true})
    if s == 'queued' and not log.queued then
      local out, stair = 0, 0
      for _, w in ipairs(walkers) do
        local p = w.route[w.i]
        if not in_refuge(p) then out = out + 1 end
        if p[1] == 6 and p[2] == 6 and p[3] < Z and p[3] > Z - 4 then stair = stair + 1 end
      end
      log.queued = {rel = rel, dist = (dy - 6) + (Z - dz), outside = out, stair = stair}
      if o.finish then finish_at = rel + o.finish end
    end
    if finish_at and rel >= finish_at then W.pstate = function() return {done = true} end end
    if log.queued and o.ask then
      local pick = ask(W, 'BREACH', 'Tiefe+')
      log.picks[#log.picks + 1] = {rel = rel, pick = pick, on_stair = dz < Z}
    end
    if dz < Z and not log.arrive then log.arrive = rel end
  end
  return log, W, M
end

T.test('BUG-595 (1): traffic: four citizens stream toward the stair while a destroyer walks in from 100 tiles; a bedridden patient lies in the hall ' ..
       '(old: the plug waited for every walker AND the patient to be inside, then came with the BREACH): nobody is walled out, nobody is on the ' ..
       'stair when the walls are ordered, the plug is queued long before the destroyer is within PLUG.close', function()
  local log, W, M = traffic{ticks = 1900, per = 20, patient = 20,
                            walkers = {{id = 11, x = 12, y = 12, start = 0}, {id = 12, x = 11, y = 12, start = 200},
                                       {id = 13, x = 12, y = 11, start = 400}, {id = 14, x = 10, y = 12, start = 600}}}
  T.ok(log.queued, 'the plug was queued')
  T.eq({log.queued.outside, log.queued.stair}, {0, 0}, 'every walker inside the burrow, nobody on the stair when the walls were ordered')
  T.ok(log.queued.dist > M.PLUG.close + 20, 'queued with the destroyer ' .. log.queued.dist .. ' tiles out (old: never before the BREACH)')
  T.ok(log.queued.rel >= 600, 'not before the last walker was in: ' .. log.queued.rel)
  T.eq(#log.repairs, 1)
  for _, w in ipairs(log.walkers) do T.ok(in_refuge(w.route[w.i]), 'walker ' .. w.id .. ' ended inside') end
  local ev = W.find_events('REFUGE_PLUG')
  T.eq({#ev, ev[1].d.early, ev[1].d.breach, ev[1].d.out}, {1, 1, 0, nil}, 'early; the patient is no walker on his way')
end)

T.test('BUG-595 (1b): traffic: a walker who stops for good (stuck in the hall) holds the plug out_wait + out_each ticks from the last one that got ' ..
       'in, then it is walled anyway while the destroyer is still far; the walkers of the stream are not cut off', function()
  local log, W, M = traffic{ticks = 4400, per = 60, patient = 20,
                            walkers = {{id = 11, x = 12, y = 12, start = 0}, {id = 12, x = 11, y = 12, start = 300},
                                       {id = 15, x = 10, y = 10, start = 0, stuck = true}}}
  T.ok(log.queued, 'the plug was queued')
  T.ok(log.queued.rel >= M.PLUG.out_wait + M.PLUG.out_each, 'not before the clock ran (' .. log.queued.rel .. ')')
  T.ok(log.queued.dist > M.PLUG.near, 'queued with the destroyer ' .. log.queued.dist .. ' tiles out (old: at the BREACH)')
  T.eq(log.queued.stair, 0)
  for i = 1, 2 do T.ok(in_refuge(log.walkers[i].route[log.walkers[i].i]), 'the streaming walker ' .. i .. ' was not cut off') end
  local ev = W.find_events('REFUGE_PLUG')
  T.eq({#ev, ev[1].d.early, ev[1].d.out}, {1, 1, 1}, 'one straggler counted, the patient not')
end)

T.test('BUG-595 (1c): a bedridden patient outside Tiefe+ does not hold the plug; a walker who does not come holds it out_wait + out_each; the ' ..
       'destroyers announced by the popup alone (none in sight) count', function()
  local W, M, repairs = fort{cits = {{1, 8, 8, Z - 4}, {2, 8, 7, Z - 4}, {3, 10, 9, Z}}}   -- 3: the patient in the hall
  hatch(W)
  refresh(W)
  W.set_mode('SIEGE')
  W.unit(3).health = {flags = {needs_healthcare = true}}
  census(W, {{6, 60, Z, bd = 1}})                      -- 54 tiles from the stair head
  T.eq(select(2, W.K.call('seal', 'plug', {bd = true})), 'queued', 'old: wait:destroyers far (for the patient)')
  T.eq(#repairs, 1)
  local W1, M1 = fort{cits = {{1, 8, 8, Z - 4}, {2, 8, 7, Z - 4}, {3, 10, 9, Z}}}   -- 3: a walker who does not come
  hatch(W1)
  refresh(W1)
  W1.set_mode('SIEGE')
  census(W1, {{6, 60, Z, bd = 1}})
  T.eq(select(2, W1.K.call('seal', 'plug', {bd = true})), 'wait:destroyers far', 'the walker is given its time')
  W1.run(M1.PLUG.out_wait, {skip = 9})
  census(W1, {{6, 60, Z, bd = 1}})
  T.eq(select(2, W1.K.call('seal', 'plug', {bd = true})), 'wait:destroyers far', 'out_wait alone is not enough: out_each per walker')
  W1.run(M1.PLUG.out_each + 100, {skip = 9})
  census(W1, {{6, 60, Z, bd = 1}})
  T.eq(select(2, W1.K.call('seal', 'plug', {bd = true})), 'queued')
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

T.test('BUG-595 (2): traffic: the walls (builders inside, 600 ticks) stand long before the destroyer reaches the stair: every pick while it ' ..
       'approaches is Tiefe+; built, a hatch broken on top is no way in', function()
  local log = traffic{ticks = 2300, per = 20, room = true, ask = true, finish = 600,
                      walkers = {{id = 11, x = 12, y = 12, start = 0}, {id = 12, x = 11, y = 12, start = 200}}}
  T.ok(log.queued and log.queued.dist > 50, 'queued with the destroyer far')
  T.ok(log.arrive, 'the destroyer came down the stair')
  T.ok(#log.picks > 50, 'asked all along: ' .. #log.picks)
  for _, p in ipairs(log.picks) do T.eq(p.pick, 'Tiefe+', 'at +' .. p.rel .. (p.on_stair and ' (destroyer on the stair, walls built)' or '')) end
end)

T.test('BUG-595 (2b): traffic: the walls are not finished when the destroyer is on the stair (no builders in time): the citizens hold the ' ..
       'separated area, not a refuge it can walk into (old: a queued plug counted as a wall)', function()
  local log = traffic{ticks = 2300, per = 20, room = true, ask = true,
                      walkers = {{id = 11, x = 12, y = 12, start = 0}}}
  T.ok(log.queued and log.arrive, 'queued, and it arrived')
  local far, near = {}, {}
  for _, p in ipairs(log.picks) do
    if p.on_stair then near[p.pick] = true else far[p.pick] = true end
  end
  T.ok(far['Tiefe+'], 'Tiefe+ while it was far')
  T.ok(near['Innen+'] and not near['Tiefe+'], 'the separated area with it on the stair and no walls')
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
