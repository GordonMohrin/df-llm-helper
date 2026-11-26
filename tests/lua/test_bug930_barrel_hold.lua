-- NEU17c BUG-930 (i4 Girderroots y501-y504): the lowered pile barrel limits are HELD. Replays the i4 timeline of DIAGNOSE-i4-fass-17c (lowering, d7 'DF kept the registration',
-- the old give-back moments at 7 / 14 days, the cure going OFF, the registration coming back), then the stepwise give-back (cont_free >= 20 for 28 days, +3 per pile per week),
-- the re-lowering when DF's cancels return, the persistence over a reload and 'nothing without DF's reason'.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200
local BREWER = 6
local function log_has(W, s)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(s, 1, true) then return l.msg end end
  return nil
end
local function api_new()
  local actlib = require('dfllm.act')
  return actlib.new{who = function() return 'economy' end, allowlist = function() return actlib.BUILTIN_ALLOWLIST end, log_cmd = function() end, fail = function() end}
end
local function pile(id, name, x1, o)
  o = o or {}
  return {id = id, name = name, x1 = x1, y1 = 0, x2 = x1 + 2, y2 = 2, z = 5, max_barrels = o.max or 40,
          storage = {container_item_id = kmock.vec(o.reg or {})},
          settings = {flags = {food = o.food ~= false}, food = {drink_plant = kmock.vec{o.drink == true}, drink_animal = kmock.vec{false}}}}
end

local function brew_world(cond_n)
  local units, ids = {}, {}
  for i = 1, 6 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}}; ids[i] = i end
  local base = F.cfg()
  base.economy.diag = {cx_cure = true, mgr_chores = true, still_pin = true, stall_line = true}
  local W = F.world{cfg = {baseline = base}, units = units}
  df.unit_labor = {BREWER = BREWER, [BREWER] = 'BREWER'}
  df.job_skill = df.job_skill or {}
  dfhack.job.getWorker = function(j) return j._worker end
  for i = 1, 6 do
    local u = W.unit(i)
    u.job, u.mood = {current_job = nil}, -1
    u.status.labors = {}
    u.military = {squad_id = -1}
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  W.unit(1).status.labors[BREWER] = true
  W.set_census('u', F.census_u(ids))
  F.item(W, 'DRINK', {stack_size = 20000})
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, plot_under = function() return true end})
  W.load(fresh('economy'))
  W.mods.economy.disabled = true                        -- only the calls below drive it
  local b = F.workshop(W, 'Still')
  b.x1, b.y1, b.x2, b.y2, b.z = 20, 20, 22, 22, 100
  b.getBuildStage = function() return 1 end
  b.getMaxBuildStage = function() return 1 end
  b.jobs = kmock.vec{}
  b.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  local conds = {}
  if cond_n then conds[1] = {compare_type = 0, compare_val = cond_n, flags1 = {empty = true}, flags3 = {food_storage = true}, item_type = -1} end
  local ord = F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = 20, amount_total = 20,
                          mat_type = -1, mat_index = -1, workshop_id = -1, item_conditions = kmock.vec(conds)})
  return W, b, ord
end
local function feed(econ, K, n, tick)
  for _ = 1, n do
    econ.on.REPORT(K, {type = 'CANCEL_JOB', tick = tick, text = 'Urist McBrew cancels Brew drink from plant: Needs empty food storage item.'})
  end
end

-- i4 numbers: 115 registered empties (stock piles 9 / 9 / 9 / 27 with 0-1 full barrels, one dfllm-drink pile, one player pile), cont_free 0
local function i4_world(drink)
  local W, still, ord = brew_world()
  local function barrels(x, empties, fulls)
    local ids = {}
    for _ = 1, empties do ids[#ids + 1] = F.item(W, 'BARREL', {pos = {x = x, y = 1, z = 5}}).id end
    for _ = 1, fulls do ids[#ids + 1] = F.item(W, 'BARREL', {pos = {x = x, y = 1, z = 5}, _contents = {{id = 1}}}).id end
    return ids
  end
  local all = {
    pile(61, 'dfllm-stock', 0, {max = 9, drink = drink, reg = barrels(0, 28, 0)}),
    pile(62, 'dfllm-stock', 10, {max = 9, drink = drink, reg = barrels(10, 28, 0)}),
    pile(63, 'dfllm-stock', 20, {max = 9, drink = drink, reg = barrels(20, 29, 0)}),
    pile(64, 'dfllm-stock', 30, {max = 27, drink = drink, reg = barrels(30, 27, 1)}),
    pile(65, 'dfllm-drink', 40, {max = 3, drink = true, reg = barrels(40, 1, 2)}),
    pile(66, 'my stocks', 50, {max = 15, drink = drink, reg = barrels(50, 1, 0)}),
  }
  df.global.world.buildings.other.STOCKPILE = kmock.vec(all)
  df.building.find = function(id) for _, sp in ipairs(all) do if sp.id == id then return sp end end end
  local api = api_new()
  W.act_result('pile_barrels', function(mode, arg) return api.pile_barrels(mode, arg) end)
  W.K.census.i = {brew_p = 6978, barrels = 121, barrels_empty = 121, cont_free = 0, barrels_reg = 115, wood = 0}
  return W, ord, all, W.K.cfg.baseline.economy
end
local function limits(P) local o = {}; for i, sp in ipairs(P) do o[i] = sp.max_barrels end; return o end
local function ev_of(W, phase)
  local o = {}
  for _, e in ipairs(W.find_events('PILE_BARREL_RELEASE')) do if e.d.phase == phase then o[#o + 1] = e end end
  return o
end
local function day(W, econ, c, n, feedn)
  for _ = 1, n do
    W.run(DAYT, {skip = 100})
    if feedn then feed(econ, W.K, feedn, W.K.now().tick) end
    econ.release_watch(W.K, c)
  end
end


local HELD = {0, 0, 0, 1, 3, 15}          -- dfllm-stock 9/9/9/27 lowered to their full-barrel count (0/0/0/1), dfllm-drink 3 and the player pile 15 untouched
local OLD = {9, 9, 9, 27, 3, 15}

-- gate-off day of the world: feed cancels once, then none; the cure's hysteresis (7 d window + 14 d) ends it
local function lower_and_wait(W, econ, c, P)
  feed(econ, W.K, 12, W.K.now().tick)
  econ.release_watch(W.K, c)
  T.eq(limits(P), HELD, 'lowered')
end
local function ev_count(W, phase) return #ev_of(W, phase) end

T.test('BUG-930 E1 (i4 timeline): the lowered limits are NOT given back at d7 (DF kept the registration), not at 14 days, not when the cure goes OFF, and the release never switches itself off', function()
  local W, ord, P, c = i4_world(true)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  local p = W.K.persist.get('m.economy')
  lower_and_wait(W, econ, c, P)
  day(W, econ, c, 7, 12)                                       -- DF keeps the registration, cont_free 0 -> 0: the old build gave all limits back here
  T.eq(#ev_of(W, 'd7'), 4)
  T.ok(ev_of(W, 'd7')[1].d.verdict:find('stays lowered', 1, true), ev_of(W, 'd7')[1].d.verdict)
  T.eq(limits(P), HELD, 'd7: held')
  day(W, econ, c, 8, 12)                                       -- day 15: the old time bound of 14 days is past
  T.eq(limits(P), HELD, 'd15: held')
  T.ok(p.relstop == nil, 'no relstop')
  -- the cancels stop (the cure goes OFF by its hysteresis); cont_free stays 0: still held for 120 more days
  local off
  for d = 1, 120 do
    W.run(DAYT, {skip = 100})
    econ.release_watch(W.K, c)
    if not off and not econ.cx_gate(W.K, c, W.K.now().tick) then off = d end
    if d % 10 == 0 then T.eq(limits(P), HELD, 'day +' .. d .. ': held') end
  end
  T.ok(off ~= nil, 'the cure did go OFF (hold does not depend on it)')
  T.eq(limits(P), HELD)
  T.eq(ev_count(W, 'giveback'), 0, 'no give-back while cont_free is 0')
  -- the registration comes back (haulers re-fill the piles): the limits are still low, nothing is written
  local n = #W.find_events('PILE_BARREL_RELEASE')
  for i = 1, 3 do P[i].storage.container_item_id = kmock.vec(P[i].storage.container_item_id) end
  day(W, econ, c, 10, 0)
  T.eq(limits(P), HELD)
  T.eq(#W.find_events('PILE_BARREL_RELEASE'), n, 'no new event')
end)

T.test('BUG-930 E1/E5: stepwise give-back only after cont_free >= 20 stayed for 28 days with no DF reason; +3 per pile per week, never above the old limit; drink and player piles untouched', function()
  local W, ord, P, c = i4_world(true)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  local p = W.K.persist.get('m.economy')
  lower_and_wait(W, econ, c, P)
  W.K.census.i.cont_free = 25                                   -- 25 usable empties from day 1 on
  local gate_off, first_change, log = nil, nil, {}
  local prev = limits(P)
  for d = 1, 140 do
    W.run(DAYT, {skip = 100})
    econ.release_watch(W.K, c)
    if not gate_off and not econ.cx_gate(W.K, c, W.K.now().tick) then gate_off = d end
    local now = limits(P)
    if table.concat(now, ',') ~= table.concat(prev, ',') then
      first_change = first_change or d
      log[#log + 1] = d .. ':' .. table.concat(now, ',')
      prev = now
    end
  end
  T.ok(gate_off and first_change, 'gate went off and the give-back started')
  T.ok(first_change - gate_off >= 28, 'not before 28 days of plenty with the gate off: gate off day ' .. tostring(gate_off) .. ', first step day ' .. tostring(first_change))
  T.eq(log[1]:match(':(.*)'), '3,3,3,4,3,15', 'first step: +3 per pile (0 -> 3, 1 -> 4), drink 3 and player 15 untouched: ' .. table.concat(log, ' | '))
  T.eq(log[2]:match(':(.*)'), '6,6,6,7,3,15', 'a week later +3 again')
  local d1, d2 = tonumber(log[1]:match('^(%d+)')), tonumber(log[2]:match('^(%d+)'))
  T.eq(d2 - d1, 7, 'one step per week')
  T.eq(limits(P), OLD, 'finally every pile is at its old limit, never above')
  T.eq(p.relpiles, nil, 'nothing held any more')
  T.eq(p.hold, nil)
  T.ok(ev_count(W, 'giveback') >= 12, 'measured: one giveback event per pile and step')
  local e = ev_of(W, 'giveback')[1]
  T.ok(e.d.before ~= nil and e.d.after ~= nil and e.d.free0 == 25, 'giveback event carries before / after / free0')
end)

T.test('BUG-930 E1: plenty that is interrupted restarts the 28 days (cont_free falls under the target)', function()
  local W, ord, P, c = i4_world(true)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  lower_and_wait(W, econ, c, P)
  for d = 1, 60 do
    W.K.census.i.cont_free = (d % 20 == 0) and 3 or 25         -- never 28 days in a row
    W.run(DAYT, {skip = 100})
    econ.release_watch(W.K, c)
  end
  T.eq(limits(P), HELD, 'no span of 28 days: held')
end)

T.test('BUG-930 E1: DF cancels return during the steps: the piles are lowered again at once, the 28 days start anew; d0 event again', function()
  local W, ord, P, c = i4_world(true)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  local p = W.K.persist.get('m.economy')
  lower_and_wait(W, econ, c, P)
  W.K.census.i.cont_free = 25
  local d = 0
  while limits(P)[1] == 0 and d < 120 do d = d + 1; W.run(DAYT, {skip = 100}); econ.release_watch(W.K, c) end
  T.eq(limits(P), {3, 3, 3, 4, 3, 15}, 'the first step was made')
  local lo = ev_count(W, 'lowered')
  feed(econ, W.K, 12, W.K.now().tick)                           -- DF cancels again
  W.K.census.i.cont_free = 0
  W.run(DAYT, {skip = 100})
  feed(econ, W.K, 12, W.K.now().tick)
  econ.release_watch(W.K, c)
  T.eq(limits(P), HELD, 'lowered again the same day')
  T.eq(ev_count(W, 'lowered'), lo + 4, 'measured again (d0 events)')
  T.eq(p.relpiles['61'].old, 9, 'the old limit is still the original one')
  T.ok(p.hold.ok == nil and not p.hold.stepping, 'timer reset')
  W.K.census.i.cont_free = 25
  for _ = 1, 21 do W.run(DAYT, {skip = 100}); econ.release_watch(W.K, c) end     -- cancels aged out of the window, gate still held by hysteresis
  T.eq(limits(P), HELD, 'no step inside the new 28 days')
end)

T.test('BUG-930 E3: a reload keeps the hold, the hysteresis latch and the plenty timer', function()
  local W, ord, P, c = i4_world(true)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  local p = W.K.persist.get('m.economy')
  lower_and_wait(W, econ, c, P)
  T.ok(type(p.cxh) == 'table', 'the latch is in the persisted state')
  W.run(DAYT * 10, {skip = 100})                                -- the window is empty now
  T.ok(econ.cx_gate(W.K, c, W.K.now().tick), 'held by the hysteresis latch')
  local econ2 = fresh('economy')                                -- reload: session tables gone
  T.ok(econ2.cx_gate(W.K, c, W.K.now().tick), 'after the reload the latch still holds (it was session-only before)')
  econ2.cx_expire(W.K, c, p, W.K.now().tick)
  econ2.cx_end(W.K, p, true)
  T.eq(limits(P), HELD, 'neither cx_expire nor cx_end gives a held limit back')
  W.K.census.i.cont_free = 25
  for _ = 1, 40 do W.run(DAYT, {skip = 100}); econ2.release_watch(W.K, c); if limits(P)[1] ~= 0 then break end end
  T.eq(limits(P)[1], 0, 'inside the 28 days of plenty (gate off since ~day 24)')
  local t0 = p.hold.ok
  T.ok(t0 ~= nil, 'plenty timer persisted in p.hold')
  local econ3 = fresh('economy')                                -- a second reload in the middle of the plenty
  for _ = 1, 40 do W.run(DAYT, {skip = 100}); econ3.release_watch(W.K, c); if limits(P)[1] ~= 0 then break end end
  T.ok(limits(P)[1] == 3, 'the step comes 28 days after the FIRST plenty day, not after the reload: ' .. table.concat(limits(P), ','))
  T.ok(W.K.now().tick - t0 >= 28 * DAYT and W.K.now().tick - t0 < 30 * DAYT, 'timer counted over the reload')
end)

T.test('BUG-930 E5: nothing happens without DF reason (no cancel, no unmet order condition): no lowering, no give-back, no events', function()
  local W, ord, P, c = i4_world(true)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  W.K.census.i.cont_free = 40
  for _ = 1, 40 do W.run(DAYT, {skip = 100}); econ.release_watch(W.K, c) end
  T.eq(limits(P), OLD)
  T.eq(#W.find_events('PILE_BARREL_RELEASE'), 0)
  T.eq(W.K.persist.get('m.economy').relpiles, nil)
end)

T.test('BUG-930: the switch cancel.release=false gives the held limits back at once', function()
  local W, ord, P, c = i4_world(true)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  lower_and_wait(W, econ, c, P)
  c.cancel.release = false
  W.run(DAYT, {skip = 100})
  econ.release_watch(W.K, c)
  T.eq(limits(P), OLD)
  T.eq(W.K.persist.get('m.economy').relpiles, nil)
end)

T.test('BUG-930 E2: one counter (cont_free) in the release events and the none-line', function()
  local W, ord, P, c = i4_world(true)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  lower_and_wait(W, econ, c, P)
  T.ok(log_has(W, 'usable empties (cont_free, registered ones not counted)'), 'the release line names the counter')
end)

T.done()
