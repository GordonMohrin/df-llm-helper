-- NEU1 P7 (decision E5, docs/v2/NEU1-notausgang.md): lua/dfllm/player.lua (the emergency exit, the player's verbs, the holds),
-- util/hold.lua, the hold gate of kern's act env (mirrored in k_mock) and gate's lever verb outside PEACE. k_mock with stand-ins
-- for water, care, economy and military.
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local player = require('dfllm.player')
local HOLD = require('dfllm.util.hold')
local C = require('dfllm.util.contract')

local DAY = C.TICKS.DAY

local function water_part(patients, thirst)
  return {patients = patients, thirst_max = thirst, hosp_ok = 1, refuge_ok = 1, buckets_free = 3, hosp = 1, src = {}}
end

-- a world with the player module and stand-ins; o.water = {patients, thirst}, o.died = {cause = n}, o.cfg = player config
local function world(o)
  o = o or {}
  local W = kmock.new{mode = o.mode, units = o.units, ms_per_frame = 2000, cfg = {baseline = {v = 2, player = o.cfg}}}   -- a fresh view every frame
  W.read = {water = o.water, died = o.died}
  local water = {name = 'water', every = {ticks = 1200}}
  function water.state()
    local w = W.read.water
    return w and {water = water_part(w[1], w[2])} or {}
  end
  local care = {name = 'care', every = {ticks = 1200}}
  function care.state()
    if not W.read.died then return {} end
    return {care = {stressed_pct = 0, naked = 0, ghosts = 0, corpses_old = 0, tombs_free = 0, moods = 0, died_y = W.read.died}}
  end
  W.mil = {orders = {}, released = {}}
  local mil = {name = 'military', every = {ticks = 3600}}
  function mil.hold_order(K, key, order, tag) W.mil.orders[#W.mil.orders + 1] = {key = key, pos = order.pos, tag = tag}; return true, 'ordered' end
  function mil.release(K, key, tag) W.mil.released[#W.mil.released + 1] = {key = key, tag = tag}; return true end
  -- the kernel's own loop: economy switches labors and draws zones as its rules say (W.eco = the calls to make in its step)
  W.eco = {}
  local eco = {name = 'economy', every = {ticks = 1200}}
  function eco.step(K)
    W.eco_res = {}
    for _, c in ipairs(W.eco) do W.eco_res[#W.eco_res + 1] = {K.act[c[1]](table.unpack(c, 2))} end
  end
  W.load(water); W.load(care); W.load(mil); W.load(eco)
  W.load(player)
  return W
end

local function last_reply(W) return W.replies[#W.replies] end

T.test('a thirsty patient for a day opens the exit (EMERGENCY A, state emg, clock clamp), the tactical verbs work, and it closes after the grace', function()
  local W = world{water = {1, 61000}}
  W.inbox('door.lock', {door = 77, on = true})
  T.eq(last_reply(W).ok, false)
  T.ok(last_reply(W).msg:find('only while the emergency exit is open', 1, true), last_reply(W).msg)
  W.run(DAY, {skip = 100})
  T.eq(#W.find_events('EMERGENCY'), 0, 'one day is not enough to open it yet (first reading)')
  W.run(2 * DAY, {skip = 100})
  local ev = W.find_events('EMERGENCY')
  T.eq(#ev, 1)
  T.eq(ev[1].cls, 'A')
  T.eq(ev[1].d.why, 'thirst')
  T.ok(ev[1].msg:find('squad.station', 1, true), ev[1].msg)
  local s = W.state()
  T.eq(s.emg.o, 1)
  T.eq(s.emg.why, 'thirst')
  T.eq(player.clock(nil), 'emergency')
  W.inbox('door.lock', {door = 77, on = true})
  T.eq(last_reply(W).ok, true, last_reply(W).msg)
  local a = W.find_acts('door_forbid')
  T.eq(#a, 1)
  T.eq({a[1].args[1], a[1].args[2], a[1].by}, {77, true, 'player'})
  W.inbox('squad.station', {squad = 'A', pos = {10, 11, 12}})
  T.eq(last_reply(W).ok, true, last_reply(W).msg)
  T.eq(W.mil.orders[1], {key = 'A', pos = {10, 11, 12}, tag = 'player'})
  -- the patient drinks: three quiet days, then the exit closes, the squad goes back, door.lock is refused again
  W.read.water = {1, 1000}
  W.run(4 * DAY, {skip = 100})
  T.eq(#W.find_events('EMERGENCY_END'), 1)
  T.eq(W.mil.released[1], {key = 'A', tag = 'player'})
  T.eq(W.state().emg, nil)
  T.eq(player.clock(nil), nil)
  W.inbox('door.lock', {door = 77, on = false})
  T.eq(last_reply(W).ok, false)
end)

T.test('two deaths of one cause within the window open the exit at once; old age and the first reading open nothing', function()
  local W = world{died = {dehydrated = 3, old_age = 1}}
  W.run(2 * DAY, {skip = 100})
  T.eq(#W.find_events('EMERGENCY'), 0, 'deaths from before the first reading are the baseline')
  W.read.died = {dehydrated = 4, old_age = 5}
  W.run(2 * DAY, {skip = 100})
  T.eq(#W.find_events('EMERGENCY'), 0, 'one new death and old age do not open it')
  W.read.died = {dehydrated = 5, old_age = 5}
  W.run(2 * DAY, {skip = 100})
  local ev = W.find_events('EMERGENCY')
  T.eq(#ev, 1)
  T.eq(ev[1].d.why, 'deaths:dehydrated')
end)

T.test('a missing reading opens nothing (fail closed), and player.exit=false keeps the exit shut', function()
  local W = world{}
  W.run(5 * DAY, {skip = 100})
  T.eq(#W.find_events('EMERGENCY'), 0)
  local W2 = world{water = {2, 90000}, cfg = {exit = false}}
  W2.run(5 * DAY, {skip = 100})
  T.eq(#W2.find_events('EMERGENCY'), 0)
  W2.inbox('burrow.unit', {burrow = 'Kern+', unit = 5, on = true})
  T.ok(last_reply(W2).msg:find('config player.exit is off', 1, true), last_reply(W2).msg)
end)

T.test('labor.set holds the unit\'s labor: the kernel loop that switches it back is refused (no ACT_FAIL) until hold_days; ' ..
       'BUG-813: another labor, a work detail (water\'s Orderlies), a medic and another unit are not held', function()
  local W = world{}
  W.inbox('labor.set', {unit = 41, labor = 'farm', on = true})
  T.eq(last_reply(W).ok, true, last_reply(W).msg)
  local a = W.find_acts('labor_set')
  T.eq({a[1].args[1], a[1].args[2], a[1].args[3], a[1].args[4], a[1].by}, {41, 'farm', true, true, 'player'})
  W.eco = {{'labor_set', 41, 'farm', false}, {'labor_set', 42, 'farm', false}, {'work_detail', 'Orderlies', 41, true},
           {'labor_set', 41, 'hunt', false}}
  W.run(DAY, {skip = 100})
  T.eq(W.eco_res[1], {false, 'held by the player (labor.set)'})
  T.eq(W.eco_res[2], {true, nil})
  T.eq(W.eco_res[3], {true, nil}, 'water\'s Orderlies on the unit')
  T.eq(W.eco_res[4], {true, nil}, 'another labor of the unit (care medic: test_neu1_acts.lua, real kern)')
  -- workdetail.set holds that detail of that unit only
  W.inbox('workdetail.set', {detail = 'Orderlies', unit = 43, on = false})
  T.eq(last_reply(W).ok, true, last_reply(W).msg)
  W.eco = {{'work_detail', 'Orderlies', 43, true}, {'work_detail', 'Miners', 43, true}, {'labor_set', 43, 'farm', false}}
  W.run(DAY, {skip = 100})
  T.eq(W.eco_res[1], {false, 'held by the player (workdetail.set)'})
  T.eq(W.eco_res[2], {true, nil})
  T.eq(W.eco_res[3], {true, nil})
  W.eco = {{'labor_set', 41, 'farm', false}}
  T.eq(#W.find_events('ACT_FAIL'), 0)
  W.run(28 * DAY, {skip = 600})
  T.eq(W.eco_res[1], {true, nil}, 'the hold ends after player.hold_days')
end)

T.test('zone.remove holds its footprint: a kernel zone drawn inside it is refused, outside it is drawn; building.remove guards a bridge', function()
  local W = world{}
  W.act_result('building_remove', function(id, kind, force)
    if id == 9 and force ~= true then return false, 'Bridge 9 is part of the defence or the trade: approve:true removes it' end
    return true, {how = 'gone', rect = {10, 10, 12, 12, 5}, type = kind == 'zone' and 'Civzone' or 'Workshop'}
  end)
  W.inbox('zone.remove', {id = 300})
  T.eq(last_reply(W).ok, true, last_reply(W).msg)
  T.ok(last_reply(W).msg:find('held 28 days', 1, true), last_reply(W).msg)
  W.eco = {{'sand_zone', {11, 12, 5}}, {'sand_zone', {20, 20, 5}}, {'sand_zone', {11, 12, 6}}}
  W.run(DAY, {skip = 100})
  T.eq(W.eco_res[1][1], false)
  T.eq(W.eco_res[2][1], true)
  T.eq(W.eco_res[3][1], true, 'another z level is not the footprint')
  W.inbox('building.remove', {id = 9})
  T.eq(last_reply(W).ok, false)
  W.inbox('building.remove', {id = 9, approve = true})
  T.eq(last_reply(W).ok, true, last_reply(W).msg)
end)

T.test('player.verbs=false refuses the stage-1 verbs; player.hold=false holds nothing', function()
  local W = world{cfg = {verbs = false}}
  W.inbox('room.assign', {zone = 5, unit = 6})
  T.eq(last_reply(W).ok, false)
  T.ok(last_reply(W).msg:find('config player.verbs', 1, true))
  local W2 = world{cfg = {hold = false}}
  W2.inbox('labor.set', {unit = 41, labor = 'farm', on = true})
  T.eq(last_reply(W2).ok, true)
  W2.eco = {{'labor_set', 41, 'farm', false}}
  W2.run(DAY, {skip = 100})
  T.eq(W2.eco_res[1], {true, nil})
end)

T.test('furniture.place designates one quickfort build cell of the piece; nothing placed is a refusal', function()
  local W = world{}
  W.act_result('quickfort', function(p) return true, {build_designated = 1} end)
  W.inbox('furniture.place', {kind = 'table', pos = {5, 6, 7}})
  T.eq(last_reply(W).ok, true, last_reply(W).msg)
  local a = W.find_acts('quickfort')[1]
  T.eq({a.args[1].mode, a.args[1].data[0][0][0], a.args[1].pos}, {'build', 't', {5, 6, 7}})
  W.act_result('quickfort', function(p) return true, {build_designated = 0} end)
  W.inbox('furniture.place', {kind = 'bed', pos = {5, 6, 7}})
  T.eq(last_reply(W).ok, false)
end)

T.test('burrow.unit adds and drops one member while the exit is open; BUG-814: no hold (gate\'s pullers win), the old ' ..
       'membership comes back when the exit closes', function()
  local W = world{water = {1, 61000}, cfg = {exit_days = 0},
                  units = {{id = 5, citizen = true}, {id = 6, citizen = true}, {id = 7, citizen = true}, {id = 8, citizen = true, dead = true}}}
  local b = W.burrow('Kern+', {0, 0, 0, 10, 10, 10})
  b.units = kmock.vec{5, 6, 8}
  W.run(2 * DAY, {skip = 100})
  T.eq(#W.find_events('EMERGENCY'), 1)
  W.inbox('burrow.unit', {burrow = 'Kern+', unit = 7, on = true})
  T.eq(last_reply(W).ok, true, last_reply(W).msg)
  T.eq(W.find_acts('burrow_units')[1].args[2], {5, 6, 7}, 'the dead member is left out, the new one joins')
  W.inbox('burrow.unit', {burrow = 'Kern+', unit = 5, on = false})
  T.eq(W.find_acts('burrow_units')[2].args[2], {6})
  -- the kernel (gate's lever-room pullers, here test code outside a verb) is never refused on a burrow
  T.eq(W.K.act.burrow_units('LeverRoom', {6}), true)
  W.inbox('burrow.unit', {burrow = 'Kern+', unit = 7, on = true})          -- a second change of unit 7 keeps its first old state
  W.inbox('burrow.unit', {burrow = 'Kern+', unit = 7, on = false})
  local n0 = #W.find_acts('burrow_units')
  -- what DF holds now: 6 (the player's list) plus 8 (a member the kernel added meanwhile)
  b.units = kmock.vec{6, 8}
  W.read.water = {0, 0}
  W.run(5 * DAY, {skip = 100})
  local ev = W.find_events('EMERGENCY_END')
  T.eq(#ev, 1)
  T.eq(ev[1].d.burrows, 1)
  local acts = W.find_acts('burrow_units')
  T.eq(#acts, n0 + 1, 'one restore call on close')
  T.eq({acts[#acts].args[1], acts[#acts].args[2], acts[#acts].by}, {'Kern+', {5, 6}, 'player'},
       'unit 5 back in, 7 out again (it was out), 6 kept, the dead 8 left out')
end)

T.test('gate lever outside PEACE: refused without the exit, only up while it is open, PEACE unchanged', function()
  local W = world{mode = 'BREACH', water = {1, 61000}, cfg = {exit_days = 0}}
  W.load(require('dfllm.gate'))
  W.inbox('lever', {bridge = 'B1', want = 'up'})
  T.eq(last_reply(W).ok, false)
  T.ok(last_reply(W).msg:find('lever not allowed in BREACH', 1, true), last_reply(W).msg)
  W.run(2 * DAY, {skip = 100})
  T.ok(#W.find_events('EMERGENCY') >= 1)
  W.inbox('lever', {bridge = 'B1', want = 'down'})
  T.eq(last_reply(W).ok, false)
  T.ok(last_reply(W).msg:find('lever down not allowed in BREACH', 1, true), last_reply(W).msg)
  W.inbox('lever', {bridge = 'B1', want = 'up'})
  T.ok(not last_reply(W).msg:find('not allowed', 1, true), 'the mode gate lets an up through: ' .. last_reply(W).msg)
  local W2 = world{mode = 'PEACE'}
  W2.load(require('dfllm.gate'))
  W2.inbox('lever', {bridge = 'B1', want = 'down'})
  T.ok(not last_reply(W2).msg:find('not allowed', 1, true), last_reply(W2).msg)
end)

T.test('util/hold: keys, recorded keys, an area covers its tiles only, an expired hold covers nothing', function()
  T.eq(HOLD.keys('labor_set', table.pack(41, 'farm', true)), {'labor:41:farm'})
  T.eq(HOLD.keys('work_detail', table.pack('Miners', 7, true)), {'wd:7:Miners'})
  T.eq(HOLD.keys('medic', table.pack(7, true)), {'labor:7:medic'})
  T.eq(HOLD.keys('burrow_units', table.pack('Kern+', {5})), {}, 'BUG-814: no burrow hold')
  T.eq(HOLD.keys('door_forbid', table.pack(77, false)), {'bld:77'}, 'a player unlock is recorded')
  T.eq(HOLD.query('door_forbid', table.pack(77, false)), {}, 'BUG-812: a kernel unlock is never refused')
  T.eq(HOLD.query('door_forbid', table.pack(77, true)), {'bld:77'})
  T.eq(HOLD.keys('building_remove', table.pack(3), {rect = {1, 2, 3, 4, 5}, type = 'Door'}), {'bld:3'},
       'BUG-815: a removed door leaves no area hold')
  T.eq(HOLD.keys('building_remove', table.pack(3), {rect = {1, 2, 3, 4, 5}}), {'bld:3', 'area:5:1:2:3:4'})
  T.eq(HOLD.keys('quickfort', table.pack({pos = {1, 2, 3}})), {'tile:1,2,3'})
  T.eq(HOLD.keys('pull', table.pack(5)), {}, 'gate keeps its own lever hold')
  T.eq(HOLD.recorded({'bld:3', 'tile:1,2,3'}), {'bld:3'})
  local holds = {{k = 'area:5:1:2:3:4', u = 100, v = 'zone.remove'}, {k = 'labor:7:farm', u = 50, v = 'labor.set'}}
  T.eq(HOLD.match(holds, {'tile:2,3,5'}, 10).v, 'zone.remove')
  T.eq(HOLD.match(holds, {'tile:4,3,5'}, 10), nil)
  T.eq(HOLD.match(holds, {'labor:7:farm'}, 10).v, 'labor.set')
  T.eq(HOLD.match(holds, {'labor:7:medic'}, 10), nil)
  T.eq(HOLD.match(holds, {'labor:7:farm'}, 60), nil)
end)

T.test('config: player.conf keeps the defaults for bad values', function()
  local c = player.conf({player = {exit_days = 99, thirst = 'x', slow = false, hold_days = 5}})
  T.eq({c.exit_days, c.thirst, c.slow, c.hold_days, c.exit}, {1, 50000, false, 5, true})
end)

T.done()
