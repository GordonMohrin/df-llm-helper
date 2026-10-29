-- FR-98/FR-99 (Gordon's goal G16, the military clears the caverns of beasts): lua/dfllm/cavern.lua, the cavern sweep.
-- From P6 with plan caverns.sweep, R1, squad A >= 3 and worn >= 80 %, a plugged shaft and a cavern beast in sight, one
-- shaft is opened under a hatch (runner.sweep_open), squad A musters beside it (hatch forbidden), kills (hatch open), is
-- called back and the shaft walled again (runner.sweep_close); CAVERN_SWEEP_END (A) names the result. SIEGE/BREACH/
-- RECOVERY/DRILL hand the squad to the kernel's own defense at once. k_mock with stand-ins for runner, military, snapshot
-- and reflex.
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local cavern = require('dfllm.cavern')

local S0 = {10, 10, 100}            -- the plugged shaft's top; its bottom z95 opens into the cavern
local SOL = {101, 102, 103, 104}

local function world(o)
  o = o or {}
  local W = kmock.new{}
  df.building_type = {Hatch = 9}
  dfhack.buildings = {findAtTile = function(x, y, z)
    if W.hatch_built and x == S0[1] and y == S0[2] and z == S0[3] then
      return {id = 77, getType = function() return df.building_type.Hatch end}
    end
  end}
  for i, id in ipairs(SOL) do W.add_unit{id = id, citizen = true, squad = 1, pos = {20 + i, 20, 100}} end
  for _, b in ipairs(o.beasts or {{id = 201, pos = {14, 12, 93}}, {id = 202, pos = {30, 30, 90}}}) do
    W.add_unit{id = b.id, danger = b.danger ~= false, great = b.great, pos = b.pos, hidden = b.hidden, tame = b.tame}
  end
  W.rec = {orders = {}, release = 0, open = 0, close = 0}
  W.acc = o.acc or {{id = 'e1', s0 = S0, s1 = {10, 10, 99}, bot = 95, why = 'cavern', st = 'done'}}
  W.proj = {done = 0, blocked = ''}
  W.cav = 'open'
  W.worn = o.worn or 90
  local runner = {name = 'runner', every = {ticks = 600}}
  function runner.cav_sealed()             -- as runner: only the plugged ones (done) and those a sweep opened
    local r = {}
    for _, a in ipairs(W.acc) do if a.st == 'done' or a.st == 'sweep' then r[#r + 1] = a end end
    return r
  end
  function runner.sweep_open(K, id) W.rec.open = W.rec.open + 1; W.acc[1].st = 'sweep'; return true, 'us1' end
  function runner.proj_state(K, id) return W.proj end
  function runner.sweep_close(K, id) W.rec.close = W.rec.close + 1; W.acc[1].st = 'open'; return true, 'pl1' end
  function runner.cav_state(K, id) return W.cav, 'pl1' end
  local mil = {name = 'military', every = {ticks = 3600}}
  function mil.squad_info(K, key)
    local ids = {}
    for _, id in ipairs(SOL) do if not W.unit(id)._m.dead then ids[#ids + 1] = id end end
    return {n = #ids, cv = 40, worn = W.worn, ids = ids}
  end
  function mil.hold_order(K, key, order, tag)
    W.rec.orders[#W.rec.orders + 1] = {key = key, kind = order.kind, units = order.units, pos = order.pos, tag = tag}
    return true, 'ordered'
  end
  function mil.release(K, key) W.rec.release = W.rec.release + 1; return true end
  local snap = {name = 'snapshot', every = {ticks = 100}}
  snap.cave_units = require('dfllm.snapshot').cave_units      -- the real reader (visible units only)
  snap.cave_citizens = require('dfllm.snapshot').cave_citizens  -- the real reader (review fix: nobody walled in)
  function snap.tile(K, x, y, z) if x == S0[1] + 1 and y == S0[2] and z == S0[3] then return {c = '.'} end return {c = '#'} end
  local rf = {name = 'reflex', every = {ticks = 10}}
  function rf.holding() return '' end
  W.load(runner); W.load(mil); W.load(snap); W.load(rf)
  W.view = {phase = o.phase or 'P6', ready = {lvl = o.lvl or 1}, threat = {vis = 0}}
  W.K.view = function() return W.view end
  W.set_plan{v = 2, year = 3, phase_target = 'P6', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
             policy = {option = 'B', pop_ceiling = 100, beauty = 'used_rooms'}, caverns = {sweep = o.sweep ~= false}}
  for k in pairs(package.loaded) do if k == 'dfllm.cavern' then package.loaded[k] = nil end end
  W.mod = W.load(require('dfllm.cavern'))
  return W
end

local function cav(W) return W.state().cav end
local function last(W, kind)
  for i = #W.rec.orders, 1, -1 do if kind == nil or W.rec.orders[i].kind == kind then return W.rec.orders[i] end end
end
local function forbids(W)
  local r = {}
  for _, a in ipairs(W.find_acts('door_forbid')) do r[#r + 1] = {a.args[1], a.args[2]} end
  return r
end
local function steps(W)
  local r = {}
  for _, e in ipairs(W.find_events('CAVERN_SWEEP_STEP')) do r[#r + 1] = e.d.phase end
  return r
end
local function to_station(W) for _, id in ipairs(SOL) do W.move(id, S0[1] + 1, S0[2], S0[3]) end end

-- the sweep from the start to the kill: open done, hatch built, the squad at the station
local function to_kill(W)
  W.run(1300, {skip = 50})
  T.eq(W.rec.open, 1, 'the shaft is opened')
  W.proj.done, W.hatch_built = 1, true
  W.run(200, {skip = 50})
  to_station(W)
  W.run(200, {skip = 50})
  T.eq(W.mod.running(W.K, 'e1'), true)
end

T.test('FR-98: the whole sweep: open, muster (hatch forbidden), kill (hatch open), recall, walled, END done', function()
  local W = world()
  W.run(1300, {skip = 50})
  local s = W.find_events('CAVERN_SWEEP_START')
  T.eq(#s, 1)
  T.eq({s[1].cls, s[1].d.acc, s[1].d.n, s[1].d.sol, s[1].d.worn, s[1].d.pos}, {'B', 'e1', 2, 4, 90, {10, 10, 100}})
  T.eq(cav(W).st, 'open')
  W.run(600, {skip = 50})
  T.eq(cav(W).st, 'open', 'the unplug project is not done yet')
  W.proj.done, W.hatch_built = 1, true
  W.run(200, {skip = 50})
  T.eq(cav(W).st, 'muster')
  T.eq(forbids(W), {{77, true}}, 'the hatch is forbidden before the squad comes')
  T.eq({last(W).kind, last(W).pos, last(W).tag}, {'station', {11, 10, 100}, 'cavern'}, 'a revealed floor beside the top')
  to_station(W)
  W.run(200, {skip = 50})
  T.eq(cav(W).st, 'kill')
  T.eq(forbids(W)[2], {77, false}, 'the hatch opens for the squad')
  T.eq(last(W, 'kill').units, {201, 202})
  W.kill(201)
  W.run(400, {skip = 50})
  T.eq(last(W, 'kill').units, {202}, 'the kill order follows the beasts in sight')
  W.kill(202)
  W.run(1000, {skip = 50})
  T.eq(W.rec.close, 1, 'nobody below the top: the shaft is walled again')
  T.eq(forbids(W)[#forbids(W)], {77, true})
  T.eq(cav(W).st, 'close')
  T.ok(W.rec.release >= 1, 'the squad is back with its posture')
  W.cav = 'done'
  W.run(200, {skip = 50})
  local e = W.find_events('CAVERN_SWEEP_END')
  T.eq(#e, 1)
  T.eq({e[1].cls, e[1].d.why, e[1].d.killed, e[1].d.lost, e[1].d.left, e[1].d.sealed},
       {'A', 'done', 2, 0, 0, 1})
  T.ok(e[1].msg:find('2 beasts killed, 0 soldiers lost', 1, true), e[1].msg)
  T.eq(steps(W), {'open', 'muster', 'kill', 'recall', 'close'})
  T.eq(W.mod.running(W.K, 'e1'), false)
  W.acc[1].st = 'done'
  W.run(1300, {skip = 50})
  T.eq(W.mod.cleared(W.K), true, 'P6 deliverable: no beast in sight at the plugged shaft')
  T.eq({cav(W).st, cav(W).k, cav(W).clr}, {'wait', 2, 1})
  T.ok(cav(W).why:find('rest'), tostring(cav(W).why))
  T.eq(W.rec.open, 1, 'a season of rest before the next sweep')
end)

T.test('FR-98: a lost soldier ends the kill (losses); the shaft waits until nobody stands below its top', function()
  local W = world()
  to_kill(W)
  W.move(101, 10, 10, 95); W.move(102, 11, 11, 94)    -- down in the cavern
  W.kill(101)
  W.run(200, {skip = 50})
  T.eq(cav(W).st, 'recall')
  T.eq(last(W).kind, 'station')
  W.run(600, {skip = 50})
  T.eq(W.rec.close, 0, 'a soldier is still below: no wall yet')
  W.move(102, 11, 10, 100)
  W.run(200, {skip = 50})
  T.eq(W.rec.close, 1)
  W.cav = 'done'
  W.run(200, {skip = 50})
  local e = W.find_events('CAVERN_SWEEP_END')[1]
  T.eq({e.d.why, e.d.lost, e.d.sealed}, {'losses', 1, 1})
end)

T.test('FR-98: SIEGE wins: the squad is released at once, the shaft closes once the soldiers are up, END siege', function()
  local W = world()
  to_kill(W)
  local rel = W.rec.release
  W.move(103, 10, 10, 96)
  W.K.set_mode('SIEGE', 'test')
  W.run(100, {skip = 50})
  T.eq(W.rec.release, rel + 1, 'released to the posture')
  T.eq(cav(W).st, 'recall')
  local n = #W.rec.orders
  W.run(300, {skip = 50})
  T.eq(#W.rec.orders, n, 'no own order in a siege: the kernel\'s defense has the squad')
  W.move(103, 11, 10, 100)
  W.run(200, {skip = 50})
  T.eq(W.rec.close, 1)
  W.cav = 'done'
  W.run(200, {skip = 50})
  T.eq(W.find_events('CAVERN_SWEEP_END')[1].d.why, 'siege')
end)

T.test('FR-98: a siege while the shaft is being opened walls it again at once', function()
  local W = world()
  W.run(1300, {skip = 50})
  T.eq(cav(W).st, 'open')
  W.K.set_mode('SIEGE', 'test')
  W.run(100, {skip = 50})
  T.eq({W.rec.close, cav(W).st}, {1, 'close'})
  W.cav = 'done'
  W.run(100, {skip = 50})
  local e = W.find_events('CAVERN_SWEEP_END')[1]
  T.eq({e.d.why, e.d.sealed, e.d.killed}, {'siege', 1, 0})
end)

T.test('FR-98: a blocked unplug project ends as blocked; a failed plug says seal_failed (wall it by hand)', function()
  local W = world()
  W.run(1300, {skip = 50})
  W.proj.blocked = 'build_lost'
  W.run(100, {skip = 50})
  T.eq({W.rec.close, cav(W).st}, {1, 'close'})
  W.cav = 'failed'
  W.run(100, {skip = 50})
  local e = W.find_events('CAVERN_SWEEP_END')[1]
  T.eq({e.d.why, e.d.sealed}, {'seal_failed', 0})
  T.ok(e.msg:find('NOT walled: wall 10,10,100 by hand', 1, true), e.msg)
end)

T.test('FR-98: the gates: plan off, phase, R0, worn, soldiers, great danger, hidden and tame units', function()
  local function why(o, f)
    local W = world(o)
    if f then f(W) end
    W.run(1300, {skip = 50})
    return cav(W), W
  end
  local c = why{sweep = false}
  T.eq({c.st, c.why}, {'off', 'plan caverns.sweep is off'})
  T.eq(why{phase = 'P5'}.why, 'phase P5 < P6')
  T.eq(why{lvl = 0}.why, 'R0 < R1')
  T.eq(why{worn = 70}.why, 'squad A worn 70% < 80%')
  T.eq(why({}, function(W) W.kill(101); W.kill(102) end).why, 'squad A 2 < 3 soldiers')
  local g, Wg = why{beasts = {{id = 201, pos = {14, 12, 93}, great = true}}}
  T.eq({g.why, Wg.rec.open}, {'a great danger in the cavern: Gordon decides', 0})
  local h = why{beasts = {{id = 201, pos = {14, 12, 93}, hidden = true}, {id = 202, pos = {15, 12, 93}, tame = true},
                          {id = 203, pos = {14, 12, 100}}, {id = 204, pos = {90, 90, 93}}}}
  T.eq({h.why, h.n, h.clr}, {'no cavern beast in sight', 0, 1}, 'fair play: only seen units; the fort level and far ones are no target')
  T.eq(why({}, function(W) W.view.threat.vis = 2 end).why, 'hostiles in sight')
  T.eq(why({}, function(W) W.set_mode('ALERT') end).why, 'mode ALERT')
  T.eq(why{acc = {}}.why, 'no plugged cavern shaft')
end)

T.test('FR-98: a shaft left open by a lost sweep (m.cavern gone) is walled at once', function()
  local W = world{acc = {{id = 'e1', s0 = S0, s1 = {10, 10, 99}, bot = 95, why = 'cavern', st = 'sweep'}}}
  W.run(1300, {skip = 50})
  T.eq({W.rec.close, W.rec.open}, {1, 0})
end)

T.test('FR-98: state cav validates and stays small; inspect what=cavern names the shafts and the gates', function()
  local W = world()
  W.run(1300, {skip = 50})
  local c = cav(W)
  T.eq({c.st, c.n, c.acc, c.k, c.l}, {'open', 2, 1, 0, 0})
  local r = W.inbox('inspect', {what = 'cavern'})
  T.ok(r.ok, r.msg)
  T.eq({r.data.ph, r.data.shafts[1].beasts, r.data.shafts[1].ids}, {'open', 2, {201, 202}})
end)

T.test('FR-98 review: a citizen in the cavern box keeps the shaft open; soldiers far away on a level above the top do not',
       function()
  local W = world()
  W.add_unit{id = 301, citizen = true, pos = {12, 14, 94}}       -- a hauler went down after the corpses
  W.add_unit{id = 302, citizen = true, pos = {80, 80, 90}}       -- a deep fort room far off: not in the cavern box
  to_kill(W)
  W.kill(201); W.kill(202)
  W.run(1000, {skip = 50})
  T.eq({cav(W).st, W.rec.close}, {'recall', 0}, 'a citizen below: nobody is walled in')
  W.run(2400, {skip = 50})
  local st = steps(W)
  T.eq(st[#st], 'recall')
  local ev = W.find_events('CAVERN_SWEEP_STEP')
  T.ok(ev[#ev].msg:find('0 soldiers, 1 other citizen still below', 1, true), ev[#ev].msg)
  W.move(301, 12, 12, 100)
  W.run(200, {skip = 50})
  T.eq(W.rec.close, 1, 'everybody up: walled')
end)

T.test('FR-98 review: a siege after the hatch stands but before the muster forbids it before the plug', function()
  local W = world()
  W.run(1300, {skip = 50})
  W.hatch_built = true                 -- the hatch stands, the lower wall goes: the unplug is not done yet
  W.K.set_mode('SIEGE', 'test')
  W.run(100, {skip = 50})
  T.eq({W.rec.close, forbids(W)}, {1, {{77, true}}})
end)

T.test('FR-99 review: a clean sweep keeps the P6 deliverable met when new beasts come later', function()
  local W = world()
  to_kill(W)
  W.kill(201); W.kill(202)
  W.run(1000, {skip = 50})
  W.cav = 'done'
  W.run(200, {skip = 50})
  W.acc[1].st = 'done'
  W.add_unit{id = 203, danger = true, pos = {15, 12, 93}}
  W.run(1300, {skip = 50})
  T.eq({cav(W).clr, cav(W).n}, {0, 1})
  T.eq(W.mod.cleared(W.K), true)
end)

T.test('FR-98 review: the phase gate compares numbers (P10 is past P6)', function()
  local W = world{phase = 'P10'}
  W.run(1300, {skip = 50})
  T.eq(W.rec.open, 1)
end)

T.done()
