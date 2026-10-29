-- M3 (BUG-112, Run 14 y640 note 77, y707 notes 94 and 96): a lone harmless intruder held the fort for weeks in SIEGE (48
-- days, threat's quiet clock counts every invader on the map and the confinement limit ran in PEACE/ALERT only) and in
-- BREACH (26 days, one unit inside Kern+). Fixtures on the siege world: the real sense, threat, siege, gate, reflex and
-- arbiter, the fake military of siege_world (kpi: 8 soldiers, 7 on station) with a kill_lone/sortie_squad stand-in.
local T = require('testlib')
local S = require('siege_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local Z = S.Z

local GOB = 89
local kills, kill_answer, sol
local function setup(opts)
  opts = opts or {}
  local dir = H.tmpdir(opts.tag or 'm3')
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local W = S.world{units = opts.units or S.fort_units(), dfpath = dir, cfg = opts.cfg}
  W.dir = dir
  df.building_type.Door = 23
  df.global.world.status.popups = kmock.vec{}
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  package.loaded['plugins.overlay'] = nil
  W.act_result('door_forbid', function(id, on)
    local b = W.buildings[id]
    if not b or b._kind ~= 'door' then return false, 'not a door' end
    local old = b.door_flags.forbidden
    b.door_flags.forbidden = on and true or false
    return true, old
  end)
  W.tiles = {}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  for _, n in ipairs({'reflex', 'arbiter'}) do package.loaded['dfllm.' .. n] = nil end
  kills, kill_answer = {}, {true, 'kill order on 300'}
  sol = {soldiers = 8, on_station = 7}
  local mil = S.military()
  mil.sortie_squad = function() return 'A', 6 end
  mil.kpi = function() return {squads = 3, soldiers = sol.soldiers, worn = 95, cv = 13, metal_pct = 0, on_station = sol.on_station,
                                off = sol.off, in_kern = sol.in_kern} end
  mil.kill_lone = function(K, ids, by) kills[#kills + 1] = {ids = ids, by = by, tick = K.now().tick}; return kill_answer[1], kill_answer[2] end
  W.mil = mil
  S.load(W, {mil, snap, require('dfllm.reflex'), require('dfllm.arbiter')})
  return W
end
local function raws()
  local gob = {flags = {CAN_LEARN = true, CAN_SPEAK = true}}
  df.creature_raw = {find = function(r) if r == GOB then return {caste = {[0] = gob}} end end}
end
local function goblin(W, id, x, y, z, size)
  local u = W.add_unit(S.inv(id, x, y, z or Z))
  u.race, u.caste = GOB, 0
  u.body = {size_info = {size_cur = size or 6486}}
  return u
end
local function events(W, t)
  local r = {}
  for _, e in ipairs(W.events) do if e.type == t then r[#r + 1] = e end end
  return r
end
local function decisions(W, id)
  local r = {}
  for _, e in ipairs(events(W, 'DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end
local function cap(W) return W.settings.fps_cap end
local CF = {reflex = {v = 2, confine = {max_days = 3, ask_days = 1, kill_hours = 12}}}

T.test('BUG-112 (note 94): a lone harmless intruder inside Kern+ in BREACH: the kernel orders the kill after kill_hours, ' ..
       'asks once with the ready command at ask_days, releases at max_days: LOCKDOWN_END limit, BREACH ends', function()
  local W = setup{tag = 'breach', cfg = CF}
  raws()
  goblin(W, 300, 61, 70, Z)                              -- a goblin child (size 6486) walks into Kern+
  S.run(W, 400)
  T.eq(W.K.mode(), 'BREACH')
  local a = W.state().alarm
  T.eq({a.ln.n, a.by.hl}, {1, 1})
  T.eq(kills, {}, 'not before kill_hours (12 h = 600 ticks)')
  S.run(W, 600)
  T.eq(#kills, 1, 'old code: never')
  T.eq({kills[1].ids, kills[1].by}, {{300}, 'reflex'})
  S.run(W, 1300)
  local d = decisions(W, 'kill_lone_intruder')
  T.eq(#d, 1, 'asked once at ask_days')
  T.eq({d[1].cls, d[1].d.unit, d[1].d.squad, d[1].d.hl, d[1].d.mode, d[1].d.inside}, {'A', 300, 'A', 1, 'BREACH', 1})
  T.ok(d[1].d.cmd:find('"target":[61,70,10]', 1, true) and d[1].d.cmd:find('squad.sortie', 1, true), d[1].d.cmd)
  T.ok(#d[1].d.q <= 200 and d[1].d.q:find('BREACH', 1, true), d[1].d.q)
  T.eq(C.check_state(W.state()), {})
  S.run(W, 1200)
  T.eq(#decisions(W, 'kill_lone_intruder'), 1, 'no repeat while nothing changed')
  T.eq(W.K.mode(), 'BREACH', 'inside the limit it holds')
  S.run(W, 2400)                                         -- max_days 3 = 3,600 ticks of the picture
  local e = events(W, 'LOCKDOWN_END')
  T.eq(#e, 1)
  T.eq(e[1].d.cause, 'limit')
  S.run(W, 2600)                                         -- the quiet clock: 2,400 ticks
  T.ok(table.concat(S.modes(W), ' '):find('BREACH>RECOVERY', 1, true), table.concat(S.modes(W), ' '))
  S.run(W, 9000)
  T.eq(W.K.mode(), 'PEACE', 'the fort is back to peace; old code: BREACH for ever')
  T.eq({cap(W), df.global.plotinfo.alerts.civ_alert_idx}, {250, 0})
  local p = json.decode(W.persist_raw['dfllm.m.reflex'])
  T.eq(p.far.ig, {300}, 'cleared inside Kern+ too, and it survives a reload')
end)

T.test('BUG-112 (note 77): SIEGE with one harmless goblin left far away: released after max_days of the picture; the ' ..
       'old quiet clock counted it for ever', function()
  local W = setup{tag = 'siege', cfg = CF, units = S.fort_units()}
  raws()
  for i = 1, 6 do local u = goblin(W, 300 + i, 150 + i, 150, Z, 60000) end
  S.run(W, 300)
  T.eq(W.K.mode(), 'SIEGE')
  for i = 2, 6 do W.kill(300 + i); W.event('UNIT_DEATH', {unit = 300 + i}) end
  W.unit(301)._m.x, W.unit(301)._m.y = 150, 150
  W.unit(301).body = {size_info = {size_cur = 6486}}
  S.run(W, 3000)
  T.eq(W.K.mode(), 'SIEGE', 'inside the limit')
  T.eq(#events(W, 'LOCKDOWN_END'), 0)
  S.run(W, 1500)
  T.eq(#events(W, 'LOCKDOWN_END'), 1)
  S.run(W, 14000)
  local ms = S.modes(W)
  T.ok(ms[#ms] == 'RECOVERY>PEACE', table.concat(ms, ' '))
  T.eq(#kills, 0, 'outside the fort the kernel orders nothing: the question only')
  T.ok(#decisions(W, 'kill_lone_intruder') >= 1)
end)

T.test('BUG-112 regression: a real invasion is untouched: 20 goblins, or one adult-sized goblin keep the SIEGE for the whole ' ..
       'time (passes on the base commit too)', function()
  local W = setup{tag = 'army', cfg = CF}
  raws()
  for i = 1, 20 do goblin(W, 300 + i, 150 + i % 5, 150 + i // 5, Z, 6486) end
  S.run(W, 8000)
  T.eq(W.K.mode(), 'SIEGE')
  T.eq({#decisions(W, 'kill_lone_intruder'), #events(W, 'LOCKDOWN_END'), #kills}, {0, 0, 0})
  local W2 = setup{tag = 'adult', cfg = CF}
  raws()
  goblin(W2, 300, 150, 150, Z, 60000)
  for i = 1, 5 do goblin(W2, 310 + i, 150 + i, 150, Z, 60000) end
  S.run(W2, 400)
  for i = 1, 5 do W2.kill(310 + i); W2.event('UNIT_DEATH', {unit = 310 + i}) end
  S.run(W2, 8000)
  T.eq(W2.K.mode(), 'SIEGE', 'a goblin of adult size is not harmless')
  T.eq(#decisions(W2, 'kill_lone_intruder'), 0)
end)

T.test('BUG-112: soldiers off their stations: no release (the question still comes)', function()
  local W3 = setup{tag = 'offstation', cfg = CF}
  raws()
  sol.on_station = 2
  goblin(W3, 300, 61, 70, Z)
  S.run(W3, 9000)
  T.eq(W3.K.mode(), 'BREACH', 'the soldiers are not at their stations: no release')
  T.eq(#events(W3, 'LOCKDOWN_END'), 0)
  T.ok(#decisions(W3, 'kill_lone_intruder') >= 1, 'the question still comes')
end)

-- BUG-215 (live t4: a wild gorlak about 70 tiles out held the BREACH 23,000+ ticks against max_days 10; on_station 0 of
-- 8, kpi off {nost 8}: the squads had no station order, so the release waited for ever)
T.test('BUG-215: no station order for the soldiers (off nost) and the soldiers in Kern+: released at max_days, the ' ..
       'log line says so; standing outside Kern+ they are not', function()
  local W = setup{tag = 'nost', cfg = CF}
  raws()
  sol.on_station, sol.off, sol.in_kern = 0, {nost = 8}, 8
  goblin(W, 300, 61, 70, Z)
  S.run(W, 9000)
  T.eq(#events(W, 'LOCKDOWN_END'), 1, 'old code: never (0 of 8 at their stations)')
  T.eq(events(W, 'LOCKDOWN_END')[1].d.cause, 'limit')
  local hit, seen = false, {}
  for _, l in ipairs(W.logs) do
    local m = tostring(l.msg)
    if m:find('cleared after', 1, true) then seen[#seen + 1] = m end
    if m:find('in BREACH with the soldiers placed: no station order for 8 of 8, 8 in Kern+', 1, true) then hit = true end
  end
  T.ok(hit, 'the log names why: ' .. table.concat(seen, ' | '))
  local W2 = setup{tag = 'nost_out', cfg = CF}
  raws()
  sol.on_station, sol.off, sol.in_kern = 0, {nost = 8}, 2
  goblin(W2, 300, 61, 70, Z)
  S.run(W2, 9000)
  T.eq(#events(W2, 'LOCKDOWN_END'), 0, 'only 2 of 8 in Kern+: no release')
  sol.off, sol.in_kern = nil, nil
end)

T.test('BUG-112: a fort without soldiers is never released by the rule; the question says no squad', function()
  local W = setup{tag = 'nosol', cfg = CF, units = {S.cit(1, 60, 70), S.cit(2, 61, 70)}}
  raws()
  sol.soldiers, sol.on_station = 0, 0
  W.mil.sortie_squad = function() return nil end
  goblin(W, 300, 61, 71, Z)
  S.run(W, 9000)
  T.eq(W.K.mode(), 'BREACH')
  local d = decisions(W, 'kill_lone_intruder')
  T.ok(#d >= 1 and d[1].d.q:find('no squad to send', 1, true) and d[1].d.cmd == nil, d[1] and d[1].d.q)
end)

T.test('BUG-112: the kernel\'s kill order refused: the question names why; running: it says so; the clock restarts when ' ..
       'a dangerous second hostile comes', function()
  local W = setup{tag = 'refused', cfg = CF}
  raws()
  kill_answer = {false, 'squad A worn 40% < 80%'}
  goblin(W, 300, 61, 70, Z)
  S.run(W, 3000)
  local d = decisions(W, 'kill_lone_intruder')
  T.ok(#d >= 1 and d[1].d.q:find('refused: squad A worn 40%', 1, true) and d[1].d.kill == 'squad A worn 40% < 80%', d[1] and d[1].d.q)
  T.ok(#kills >= 2, 'retried every 600 ticks')
  local age = W.state().alarm.ln.age
  goblin(W, 301, 150, 150, Z, 60000)                     -- a dangerous one appears: not a lone harmless picture
  S.run(W, 100)
  T.eq(W.state().alarm.ln, nil)
  W.kill(301); W.event('UNIT_DEATH', {unit = 301})
  S.run(W, 200)
  T.ok(W.state().alarm.ln.age < age, 'the clock started again')
end)

T.test('BUG-112: max_days 0, kill_hours 0, ask_days 0 and siege_release false switch the parts off (config)', function()
  local cf = {reflex = {v = 2, confine = {max_days = 3, ask_days = 0, kill_hours = 0, siege_release = false}}}
  local W = setup{tag = 'off', cfg = cf}
  raws()
  goblin(W, 300, 61, 70, Z)
  S.run(W, 9000)
  T.eq(W.K.mode(), 'BREACH')
  T.eq({#kills, #decisions(W, 'kill_lone_intruder'), #events(W, 'LOCKDOWN_END')}, {0, 0, 0})
end)

T.test('BUG-112: a unit that walks in and out of sight keeps its clock for a while; the cleared list reloads', function()
  local W = setup{tag = 'gap', cfg = CF}
  raws()
  goblin(W, 300, 61, 70, Z)
  S.run(W, 800)
  local age = W.state().alarm.ln.age
  W.unit(300)._m.hidden = true
  S.run(W, 300)
  W.unit(300)._m.hidden = false
  S.run(W, 100)
  T.ok(W.state().alarm.ln.age >= age + 300, 'a short gap does not restart the clock')
end)

T.test('BUG-112: the kernel starts its own kill order at most once a game day and five times per picture', function()
  local W = setup{tag = 'killcap', cfg = {reflex = {v = 2, confine = {max_days = 30, ask_days = 0, kill_hours = 12}}}}
  raws()
  goblin(W, 300, 61, 70, Z)
  S.run(W, 9000)
  T.ok(#kills >= 4 and #kills <= 5, 'started ' .. #kills)
  for i = 2, #kills do T.ok(kills[i].tick - kills[i - 1].tick >= 1200, 'a game day apart') end
  S.run(W, 6000)
  T.eq(#kills, 5, 'then only the question and the limit are left')
end)

T.test('BUG-111: a goblin child inside Kern+ is no hostile: no lockdown, no BREACH (old code: BREACH for weeks)', function()
  local W = setup{tag = 'child'}
  raws()
  local u = W.add_unit(S.inv(300, 61, 70, Z, {adult = false}))
  u.race, u.caste = GOB, 0
  S.run(W, 3000)
  T.eq(W.K.mode(), 'PEACE')
  T.eq({#events(W, 'ARRIVAL'), #events(W, 'BREACH'), W.state().alarm.lock}, {0, 0, 0})
  T.eq(W.state().alarm.ben, {'300:child'}, 'status names the unit and why')
end)

T.done()
