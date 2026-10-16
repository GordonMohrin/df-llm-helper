-- Intake waves, the sortie through O1 and the inner station (Gordon 2026-10-16, BUG-029). Run 10 y419 (Handlelock):
-- 47 goblins waited for weeks in front of the raised O1, the trap hall and the killing field were never used, nothing
-- could send soldiers out, and recruits whose stations lay between O1 and B2 were cut off from drink.
-- The real sense, threat, siege, gate, military and reflex on the siege world (k_mock, strict) with the WP6 squad
-- fakes (tests/lua/wp6_world.lua) and zones: O1 y=10, Z1 bailey y11-15, Z2 trap hall x51 y16-24 and the passage
-- y32-39, K1 y25-31 (the gallery above it at z+1, reached from the gatehouse as in fortcore), B1 y=40, Z3 gatehouse
-- (Kern+, the melee station 51,44), B2 y=60, Z4 core (the b2 station 51,62). Soldiers walk to their squad's station
-- order (teleport) only where no bridge between is up; goblins step into the field one per frame while O1 is down.
local T = require('testlib')
local S = require('siege_world')
local X = require('wp6_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local function manifest()
  local m = S.manifest()
  m.zones = {Z1 = {{48, 11, Z, 54, 15, Z}}, Z2 = {{51, 16, Z, 51, 24, Z}, {51, 32, Z, 51, 39, Z}},
             Z3 = {{44, 41, Z, 58, 59, Z}}, Z4 = {{40, 61, Z, 80, 95, Z}}}
  return m
end

-- opts: reflex (config/reflex.json table), units (extra), skills (every citizen's), equip (false: no gear),
-- army (n goblins at the gate), traps ({n, armed} for the snapshot fake), manifest
local function world(o)
  o = o or {}
  local dir = H.tmpdir(o.tag or 'ik')
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local units = X.citizens(50, 1, o.skills and {skills = o.skills} or nil)
  for _, u in ipairs(S.army(o.army or 12, 51, 0)) do units[#units + 1] = u end
  for _, u in ipairs(o.units or {}) do units[#units + 1] = u end
  local W = S.world{units = units, manifest = o.manifest or manifest(), dfpath = dir, kern = o.kern,
                    cfg = {reflex = o.reflex or {v = 2}}}
  X.install(W, {})
  df.global.world.status.popups = kmock.vec{}
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  -- the citizens' walk group (the first citizen's, snapshot.far): the field and everything behind it
  function snap.far(K, x, y, z) return y < 25 end
  if o.traps then function snap.traps(K, boxes) return o.traps[1], o.traps[2] end end
  package.loaded['dfllm.reflex'] = nil
  X.load(W, {'military'}, {X.runner('P5'), snap, require('dfllm.reflex')})
  W.run(9, {skip = 9})                                 -- military: squads A, B (melee) and C (crossbows), 8 soldiers
  if o.equip ~= false then X.equip_all(W) end
  W.goblins = {}
  for _, u in ipairs(units) do if u.invader then W.goblins[#W.goblins + 1] = u.id end end
  W.both_down = 0
  return W
end

---------------------------------------------------------------- the simulated world
local BR = {O1 = 10, B1 = 40, B2 = 60}
local function open_way(W, y0, z0, y1, z1)
  if z0 ~= Z then y0 = 41 end                          -- the gallery hangs over the field, reached from the gatehouse
  if z1 ~= Z then y1 = 41 end
  for name, y in pairs(BR) do
    if ((y0 < y and y1 > y) or (y0 > y and y1 < y)) and S.bstate(W, name) ~= 'down' then return false end
  end
  return true
end

local function walk(W)
  for _, s in pairs(W.squads) do
    local o = s.orders[0]
    local i = 0
    for _, p in ipairs(s.positions) do
      local u = p.occupant >= 0 and W.unit(W.hfs[p.occupant].unit_id)
      if u and not u._m.dead then
        local tx, ty, tz
        if o and o.kind == 'station' and o.pos then
          tx, ty, tz = o.pos.x + i % 3 - 1, o.pos.y + (i // 3) % 3 - 1, o.pos.z
        elseif o and o.kind == 'kill' and o.units and o.units[1] then
          local t = W.unit(o.units[1])
          if t then tx, ty, tz = t.pos.x + 1, t.pos.y, t.pos.z end
        end
        i = i + 1
        if tx and open_way(W, u.pos.y, u.pos.z, ty, tz) then W.move(u.id, tx, ty, tz) end
      end
    end
  end
end

-- while O1 is down one goblin every third frame steps from the gate into `into` (a list of tiles, default the field)
local function inflow(W)
  if not W.sealed or S.bstate(W, 'O1') ~= 'down' then return end         -- only O1 lowered in the siege
  W.fr = (W.fr or 0) + 1
  if W.fr % 3 ~= 0 then return end
  local into = W.into or {}
  W.n_in = W.n_in or 0
  for _, id in ipairs(W.goblins) do
    local u = W.unit(id)
    if u and not u._m.dead and u.pos.y < 10 then
      W.n_in = W.n_in + 1
      local p = into[W.n_in] or {48 + W.n_in % 7, 25 + (W.n_in // 7) % 7, Z}
      W.move(id, p[1], p[2], p[3])
      return
    end
  end
end

local function run(W, ticks, each)
  local done = 0
  while done < ticks do
    W.frame(9)
    S.sim(W)
    walk(W)
    if W.flow ~= false then inflow(W) end
    -- the airlock, once the siege has sealed the fort (PEACE starts with every bridge down)
    if W.K.mode() == 'SIEGE' and S.bstate(W, 'O1') == 'up' and S.bstate(W, 'B1') == 'up' then W.sealed = true end
    if W.sealed and W.K.mode() == 'SIEGE' and S.bstate(W, 'O1') ~= 'up' and S.bstate(W, 'B1') ~= 'up' then
      W.both_down = W.both_down + 1
    end
    if each then each(W) end
    done = done + 9
  end
end

-- run until fn(W) or ticks; returns whether it happened
local function until_(W, ticks, fn)
  local n = 0
  while n < ticks do
    if fn(W) then return true end
    run(W, 25)
    n = n + 25
  end
  return fn(W)
end

local function evs(W, t, phase)
  local r = {}
  for _, e in ipairs(W.find_events(t)) do if phase == nil or e.d.phase == phase then r[#r + 1] = e end end
  return r
end
local function phases(W, t)
  local r = {}
  for _, e in ipairs(W.find_events(t or 'INTAKE')) do r[#r + 1] = e.d.phase end
  return table.concat(r, ',')
end
local function in_area(W)
  local r = {}
  for _, id in ipairs(W.goblins) do
    local u = W.unit(id)
    if u and not u._m.dead and u.pos.y >= 11 and u.pos.y <= 39 then r[#r + 1] = id end
  end
  return r
end
local function kill(W, ids)
  for _, id in ipairs(ids) do W.kill(id); W.event('UNIT_DEATH', {unit = id}) end
end
local function down_pulls(W, bridge)
  local n = 0
  for _, f in ipairs(S.flips(W, bridge)) do if f.to == 'down' then n = n + 1 end end
  return n
end
local function orders_of(W, alias)
  local o = X.squad_of(W, alias).orders[0]
  return o and (o.kind .. (o.pos and string.format('@%d,%d,%d', o.pos.x, o.pos.y, o.pos.z) or '')) or ''
end

---------------------------------------------------------------- intake waves
T.test('intake: a wave opens (B1 down, squads to the field, B1 up, O1 down), closes at the wave size, clears, the ' ..
       'squads go back inside, cool down, and the next wave opens', function()
  -- old code: O1 and B1 stay up for the whole siege; no INTAKE events
  local W = world{army = 20}
  T.ok(until_(W, 600, function() return W.K.mode() == 'SIEGE' end), 'SIEGE')
  T.ok(until_(W, 1200, function() return #evs(W, 'INTAKE', 'muster') > 0 end), 'muster: ' .. phases(W))
  local m = evs(W, 'INTAKE', 'muster')[1]
  T.ok(m.msg:find('wave 1: 8 soldiers to the killing field, B1 down', 1, true), m.msg)
  T.ok(m.msg:find('traps ?', 1, true), 'traps unreadable: said so')
  T.ok(until_(W, 1500, function() return #evs(W, 'INTAKE', 'open') > 0 end), 'open: ' .. phases(W))
  T.eq({orders_of(W, 'A'), orders_of(W, 'C')}, {'station@51,28,10', 'station@51,28,11'}, 'melee field, xbows gallery')
  local op = evs(W, 'INTAKE', 'open')[1]
  T.eq({op.d.size, op.d.on_station, op.d.worn}, {6, 8, 100})
  T.eq(S.bstate(W, 'B1'), 'up', 'B1 up again before O1 opens (the airlock)')
  T.ok(until_(W, 900, function() return #evs(W, 'INTAKE', 'close') > 0 end), 'close: ' .. phases(W))
  local cl = evs(W, 'INTAKE', 'close')[1]
  T.ok(cl.msg:find('hostiles inside (wave 6)', 1, true), cl.msg)
  T.ok(until_(W, 600, function() return S.bstate(W, 'O1') == 'up' end), 'O1 up again')
  local inside = in_area(W)
  T.ok(#inside >= 6 and #inside <= 10, 'the wave (a few more while the lever is pulled): ' .. #inside)
  -- the fight: kill orders on the field to the crossbows and the melee squads
  run(W, 150)
  local A = X.squad_of(W, 'A').orders[0]
  T.ok(A and A.kind == 'kill', 'melee in the field get the kill order: ' .. orders_of(W, 'A'))
  T.eq(#evs(W, 'BREACH') + #evs(W, 'INTRUDER') + #evs(W, 'WAVE_FAIL'), 0, 'expected hostiles: no BREACH, no INTRUDER')
  T.eq(W.K.mode(), 'SIEGE')
  kill(W, inside)
  T.ok(until_(W, 600, function() return #evs(W, 'INTAKE', 'clear') > 0 end), 'clear: ' .. phases(W))
  T.ok(evs(W, 'INTAKE', 'clear')[1].msg:find('killed', 1, true))
  T.ok(until_(W, 1500, function() return #evs(W, 'INTAKE', 'back') > 0 end), 'back: ' .. phases(W))
  T.eq({orders_of(W, 'A'), orders_of(W, 'C')}, {'station@51,44,10', 'station@51,44,10'}, 'inside B1 (BUG-029)')
  T.eq(S.bstate(W, 'B1'), 'up')
  local t_back = evs(W, 'INTAKE', 'back')[1].tick
  -- the cooldown, then the next wave with the rest of the army
  T.ok(until_(W, 3000, function() return #evs(W, 'INTAKE', 'muster') > 1 end), 'second muster: ' .. phases(W))
  T.ok(evs(W, 'INTAKE', 'muster')[2].tick - t_back >= 1200, 'not before the cooldown')
  T.ok(until_(W, 1500, function() return #evs(W, 'INTAKE', 'open') > 1 end), 'second open: ' .. phases(W))
  T.eq(evs(W, 'INTAKE', 'open')[2].d.wave, 2)
  T.eq(W.both_down, 0, 'never O1 and B1 down at once')
  T.eq(W.pending_violations, 0)
  T.eq(W.state().wave.ph, 'open')
end)

T.test('intake refused: a megabeast in sight, worn too low, a civilian in the bailey, Kern+ over the field (O1 never ' ..
       'lowered)', function()
  -- old code: no INTAKE events at all
  local cases = {
    {'kern', {kern = {40, 20, Z - 2, 80, 95, Z}}},
    {'danger', {units = {S.danger(400, 120, 100, Z, {megabeast = true})}}},
    {'worn', {equip = false}},
    {'civ', {units = {S.cit(401, 51, 13)}}},
  }
  for _, c in ipairs(cases) do
    local W = world(c[2])
    run(W, 3000)
    local r = evs(W, 'INTAKE', 'refused')
    T.ok(#r >= 1 and r[#r].d.why == c[1], c[1] .. ': ' .. phases(W) .. ' ' .. (r[1] and r[1].msg or ''))
    T.eq(#evs(W, 'INTAKE', 'muster'), 0, c[1])
    T.eq(down_pulls(W, 'O1'), 0, c[1] .. ': O1 stays up')
    T.ok(W.state().wave.why ~= nil, c[1] .. ': state wave.why')
  end
end)

T.test('intake: config off -> no wave; traps re-arming -> refused until they are armed', function()
  local W = world{reflex = {v = 2, intake = {on = false}}}
  run(W, 3000)
  T.eq(#evs(W, 'INTAKE'), 0)
  T.eq(W.state().wave.why, 'off')
  W = world{traps = {41, 30}}
  run(W, 2000)
  local r = evs(W, 'INTAKE', 'refused')
  T.ok(#r == 1 and r[1].d.why == 'traps' and r[1].msg:find('30 of 41 armed', 1, true), phases(W))
end)

T.test('intake: hostiles in the trap hall are no BREACH and no INTRUDER; a hostile past B1 is BREACH and WAVE_FAIL',
       function()
  local W = world{}
  W.into = {}
  for i = 1, 7 do W.into[i] = {51, 16 + i, Z} end        -- they stop in the trap hall
  T.ok(until_(W, 4000, function() return #evs(W, 'INTAKE', 'close') > 0 end), 'close: ' .. phases(W))
  run(W, 600)
  T.ok(#in_area(W) >= 6)
  T.eq(W.K.census.h.zin >= 6, true)
  T.eq({W.K.mode(), #evs(W, 'BREACH'), #evs(W, 'INTRUDER')}, {'SIEGE', 0, 0}, 'the trap hall is the attack path')
  T.eq(W.state().wave.ph, 'fight', 'B1 stays up while hostiles are in the area')
  W.move(in_area(W)[1], 51, 45, Z)                       -- one got past B1 (the gatehouse, Kern+)
  run(W, 100)
  T.eq(W.K.mode(), 'BREACH')
  local wf = evs(W, 'WAVE_FAIL')
  T.ok(#wf == 1 and wf[1].d.kind == 'intake' and wf[1].d.why == 'past_b1' and wf[1].cls == 'A', wf[1] and wf[1].msg)
  T.eq(#evs(W, 'INTRUDER'), 1, 'past B1 counts again')
  T.eq(evs(W, 'INTAKE', 'abort')[1].d.why, 'mode')
  T.eq(W.both_down, 0)
end)

T.test('intake: losses in a wave close O1 at once: WAVE_FAIL losses (A)', function()
  local W = world{}
  W.flow = false
  T.ok(until_(W, 4000, function() return #evs(W, 'INTAKE', 'open') > 0 and S.bstate(W, 'O1') == 'down' end),
       'O1 down: ' .. phases(W))
  local sid = W.hfs[X.squad_of(W, 'A').positions[1].occupant].unit_id
  kill(W, {sid})                                          -- a soldier dies in the field
  run(W, 100)
  local wf = evs(W, 'WAVE_FAIL')
  T.ok(#wf == 1 and wf[1].d.why == 'losses' and wf[1].d.lost == 1, phases(W))
  T.ok(evs(W, 'INTAKE', 'close')[1].msg:find('1 lost', 1, true))
  T.ok(until_(W, 600, function() return S.bstate(W, 'O1') == 'up' end))
end)

---------------------------------------------------------------- BUG-029: the inner station
T.test('BUG-029: between waves every squad, the crossbows too, stands inside B1 (stations.melee); with B2 up at ' ..
       'stations.b2; the gallery only during a wave', function()
  -- old code: SIEGE sent the crossbows to the gallery (outside B1, 51,28,11) for the whole siege
  local W = world{reflex = {v = 2, intake = {on = false}}}
  T.ok(until_(W, 600, function() return W.K.mode() == 'SIEGE' end))
  run(W, 1200)
  T.eq({orders_of(W, 'A'), orders_of(W, 'B'), orders_of(W, 'C')},
       {'station@51,44,10', 'station@51,44,10', 'station@51,44,10'})
  T.eq(X.squad_of(W, 'C').cur_routine_idx, 3, 'Ready')
  -- the core seal rises (BREACH -> SIEGE leaves it up): the inner station moves behind it at once
  W.bridges.B2.gate_flags.closed = true
  run(W, 100)
  T.eq({orders_of(W, 'A'), orders_of(W, 'C')}, {'station@51,62,10', 'station@51,62,10'}, 'behind B2 with the drink')
  W.bridges.B2.gate_flags.closed = false
  run(W, 100)
  T.eq(orders_of(W, 'C'), 'station@51,44,10')
  -- READY_STATION (the drill) keeps the gallery
  X.call(W, 'military', 'posture', 'READY_STATION')
  T.eq(orders_of(W, 'C'), 'station@51,28,11')
end)

T.test('BUG-029: soldiers caught outside B1 between waves come in through the airlock (B1 down with O1 up, then ' ..
       'up); soldiers between B1 and a raised core seal get it lowered', function()
  -- old code: B1 stays up, the soldiers stay outside without drink until thirst 30000 (BUG-028's rescue)
  local W = world{reflex = {v = 2, intake = {on = false}}}
  T.ok(until_(W, 600, function() return W.K.mode() == 'SIEGE' end))
  run(W, 600)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {'up', 'up'})
  local C = X.squad_of(W, 'C')
  local ids = {}
  for _, p in ipairs(C.positions) do if p.occupant >= 0 then ids[#ids + 1] = W.hfs[p.occupant].unit_id end end
  for i, id in ipairs(ids) do W.move(id, 49 + i, 28, Z) end         -- in the killing field (e.g. after a restart)
  T.ok(until_(W, 600, function() return #evs(W, 'INTAKE', 'stray') > 0 end), phases(W))
  T.ok(evs(W, 'INTAKE', 'stray')[1].msg:find('2 soldiers outside B1 between waves: B1 down', 1, true))
  T.ok(until_(W, 1200, function() return #evs(W, 'INTAKE', 'back') > 0 end), 'back: ' .. phases(W))
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {'up', 'up'})
  for _, id in ipairs(ids) do T.ok(W.unit(id).pos.y > 40, 'inside: ' .. id) end
  T.eq(W.both_down, 0)
  -- the core seal is up (a BREACH -> SIEGE) and a squad stands between B1 and B2: B2 comes down (the SIEGE state)
  W.bridges.B2.gate_flags.closed = true
  for _, p in ipairs(X.squad_of(W, 'A').positions) do
    if p.occupant >= 0 then W.move(W.hfs[p.occupant].unit_id, 52, 50, Z) end
  end
  T.ok(until_(W, 600, function() return #evs(W, 'INTAKE', 'unseal') > 0 end), phases(W))
  T.ok(until_(W, 600, function() return S.bstate(W, 'B2') == 'down' end))
  run(W, 600)
  T.eq(S.bstate(W, 'B2'), 'down', 'it stays down')
  T.eq(orders_of(W, 'A'), 'station@51,44,10')
end)

---------------------------------------------------------------- the sortie through O1
T.test('sortie through O1: refused below the thresholds, then gather in the bailey (B1 down, up), O1 down, out, ' ..
       'recall when the target is dead, O1 up, back inside, done; never O1 and B1 down at once', function()
  local W = world{skills = {AXE = 5, SHIELD = 3, ARMOR = 2},
                  units = {S.inv(450, 70, 3, Z), S.inv(451, 71, 3, Z)}}
  W.flow = false
  local reflex = {v = 2, intake = {on = false}}
  W.K.cfg.reflex = reflex
  T.ok(until_(W, 600, function() return W.K.mode() == 'SIEGE' end))
  run(W, 300)
  -- the army of 12 at the gate: cv 30 vs ~12 hostiles x 10
  local r = W.inbox('squad.sortie', {squad = 'A', target = {52, 2, Z}, approve = true, gate = 'O1'})
  T.ok(not r.ok and r.msg:find('too weak: cv 30 vs ~12 hostiles x 10 = 120', 1, true), r.msg)
  r = W.inbox('squad.sortie', {squad = 'A', target = {70, 3, Z}, approve = true, gate = 'B1'})
  T.ok(not r.ok and r.msg:find('B1 is no outer manifest bridge', 1, true), r.msg)
  r = W.inbox('squad.sortie', {squad = 'A', target = {51, 28, Z}, approve = true, gate = 'O1'})
  T.ok(not r.ok and r.msg:find('inside the fort', 1, true), r.msg)
  r = W.inbox('squad.sortie', {squad = 'A', target = {70, 3, Z}, approve = true, gate = 'O1'})
  T.ok(r.ok and r.msg:find('cv 30 vs ~2 hostiles x 10 = 20, worn 100%', 1, true), r.msg)
  T.ok(r.msg:find('gathering in the bailey at 51,13,10', 1, true), r.msg)
  T.eq(orders_of(W, 'A'), 'station@51,13,10')
  T.ok(until_(W, 1200, function() return #evs(W, 'SORTIE', 'open') > 0 end), 'open: ' .. phases(W, 'SORTIE'))
  T.eq(S.bstate(W, 'B1'), 'up', 'the airlock: B1 up behind them')
  T.ok(until_(W, 600, function() return #evs(W, 'SORTIE', 'out') > 0 end), 'out: ' .. phases(W, 'SORTIE'))
  run(W, 150)
  local A = X.squad_of(W, 'A').orders[0]
  T.ok(A.kind == 'kill' and A.units[1] == 450, 'kill order on the target outside')
  T.eq(orders_of(W, 'B'), 'station@51,44,10', 'the other squads stay inside')
  T.eq(#evs(W, 'INTRUDER'), 0, 'the sortie: hostiles outside are expected')
  kill(W, {450, 451})
  T.ok(until_(W, 600, function() return #evs(W, 'SORTIE', 'recall') > 0 end), 'recall: ' .. phases(W, 'SORTIE'))
  T.ok(evs(W, 'SORTIE', 'recall')[1].msg:find('no target left', 1, true))
  T.ok(until_(W, 1200, function() return #evs(W, 'SORTIE', 'close') > 0 end), 'close: ' .. phases(W, 'SORTIE'))
  T.eq(S.bstate(W, 'O1'), 'up')
  T.ok(until_(W, 1500, function() return #evs(W, 'SORTIE', 'done') > 0 end), 'done: ' .. phases(W, 'SORTIE'))
  T.eq(orders_of(W, 'A'), 'station@51,44,10', 'released: back at the inner station')
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {'up', 'up'})
  T.eq(#evs(W, 'WAVE_FAIL'), 0)
  T.eq(W.both_down, 0, 'never O1 and B1 down at once')
  T.eq(phases(W, 'SORTIE'), 'gather,open,out,recall,close,done')
  T.eq(W.inbox('squad.sortie', {squad = 'A', target = {70, 3, Z}, approve = true, gate = 'O1'}).ok, true, 'again')
end)

T.test('sortie through O1: a hostile at the gate raises O1 with a member outside: WAVE_FAIL left_outside', function()
  local W = world{skills = {AXE = 5, SHIELD = 3, ARMOR = 2}, army = 0, units = {S.inv(450, 70, 3, Z)}}
  W.goblins = {450}
  W.flow = false
  W.K.cfg.reflex = {v = 2, intake = {on = false}}
  for i = 1, 6 do W.add_unit(S.inv(460 + i, 80 + i, 2, Z)) end   -- the siege: in sight, far from the gate
  T.ok(until_(W, 600, function() return W.K.mode() == 'SIEGE' end))
  run(W, 300)
  local r = W.inbox('squad.sortie', {squad = 'A', target = {70, 3, Z}, approve = true, gate = 'O1'})
  T.ok(r.ok, r.msg)
  T.ok(until_(W, 2000, function() return #evs(W, 'SORTIE', 'out') > 0 end), phases(W, 'SORTIE'))
  run(W, 150)
  -- one member is pinned down out there; the target dies, the rest come back, a goblin reaches the gate
  local pinned = W.hfs[X.squad_of(W, 'A').positions[1].occupant].unit_id
  local each = function(W2) W2.move(pinned, 75, 5, Z) end
  kill(W, {450})
  run(W, 300, each)
  T.eq(evs(W, 'SORTIE', 'recall')[1] ~= nil, true)
  W.move(461, 51, 8, Z)
  run(W, 400, each)
  local wf = evs(W, 'WAVE_FAIL')
  T.ok(#wf == 1 and wf[1].d.why == 'left_outside' and wf[1].d.units[1] == pinned, phases(W, 'SORTIE'))
  T.ok(wf[1].msg:find('a hostile 2 tiles from O1', 1, true), wf[1].msg)
  T.ok(until_(W, 600, function() return S.bstate(W, 'O1') == 'up' end))
  T.eq(W.both_down, 0)
end)

T.test('gate airlock: an intake/sortie down of O1 is refused while B1 is not up; another reason in SIEGE refused',
       function()
  local W = world{}
  T.ok(until_(W, 2000, function() return W.state().wave and W.state().wave.ph == 'muster'
                                       and S.bstate(W, 'B1') == 'down' end), 'muster with B1 down: ' .. phases(W))
  T.eq(S.bstate(W, 'O1'), 'up')
  local _, ok, msg = W.K.call('gate', 'want', 'O1', 'down', 'intake')
  T.ok(ok == false and msg:find('B1 is not up (airlock)', 1, true), msg)
  _, ok, msg = W.K.call('gate', 'want', 'O1', 'down', 'siege')
  T.ok(ok == false and msg:find('down refused in SIEGE', 1, true), msg)
  T.eq(W.both_down, 0)
end)

T.done()
