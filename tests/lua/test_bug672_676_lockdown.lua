-- BUG-672 to BUG-676 (Run 16b i2 Whirledrampart: four woolly mammoths inside Kern+ held BREACH and a PREDATOR lockdown for 380 days; Run 16d
-- i4 Trumpetrealms: goblins on a cave level no citizen can walk to held a lockdown 50 days, a giant bat killed two patients while the
-- squad.sortie said 'not allowed in PEACE'): the passive plant eater and the unreachable hostile are cleared after a bound, the operator can
-- release them, the squads screen works in an animals-only BREACH, a PEACE sortie is allowed against one wild animal; and the siege
-- traffic test: a real siege (goblins, building destroyers) is exactly what it was.
local T = require('testlib')
local S = require('siege_world')
local H = require('kern_world')
local X = require('wp6_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local Z = S.Z

local function door(W, id, x, y, forbidden)
  local b = W.add_building{id = id, _kind = 'door', x1 = x, y1 = y, x2 = x, y2 = y, z = Z, centerx = x, centery = y,
                           door_flags = {forbidden = forbidden == true}}
  b.getType = function() return df.building_type.Door end
  df.global.world.buildings.other.DOOR:insert('#', b)
  return b
end

-- the siege world plus doors, open-sky tiles north of O1, a snapshot stand-in (real outside_near), the reflex module
-- and the arbiter. opts.manifest = false: the bridges and levers exist, the fort has no manifest (Run 9).
local function setup(opts)
  opts = opts or {}
  local dir = H.tmpdir(opts.tag or 'r')
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local W = S.world{manifest = opts.manifest, units = opts.units or S.fort_units(), dfpath = dir, cfg = opts.cfg,
                    ms_per_frame = opts.ms_per_frame, tiefe = opts.tiefe, kern = opts.kern, mode = opts.mode,
                    persist = opts.persist}
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
  W.act_result('dismiss_popup', function(kind)        -- act.lua: close the front popup
    local p = df.global.world.status.popups
    if #p == 0 then return false, 'no popup' end
    p:erase(0)
    return true, kind
  end)
  W.tiles = {}
  for x = 40, 70 do W.tiles[x .. ',7,' .. Z] = {des = {outside = true}} end
  W.doors = {entrance = door(W, 501, 51, 8), inner = door(W, 502, 60, 70), own = door(W, 503, 52, 8, true)}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far(K, x, y, z) return W.far_fn ~= nil and W.far_fn(x, y, z) or false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  snap.outer_groups, snap.group_at = require('dfllm.snapshot').outer_groups, require('dfllm.snapshot').group_at      -- BUG-673
  for _, n in ipairs({'reflex', 'arbiter'}) do package.loaded['dfllm.' .. n] = nil end
  local mods = {S.military(), snap}
  if opts.sortie then mods[1].sortie_squad = function() return opts.sortie, 5 end end      -- BUG-495
  if opts.reflex ~= false then mods[#mods + 1] = require('dfllm.reflex') end
  mods[#mods + 1] = require('dfllm.arbiter')
  for _, m in ipairs(opts.extra or {}) do mods[#mods + 1] = m end
  S.load(W, mods)
  return W
end

local function events(W, t)
  local r = {}
  for _, e in ipairs(W.events) do if e.type == t then r[#r + 1] = e end end
  return r
end
local function cap(W) return W.settings.fps_cap end
local function alarm_txt(W) return H.read(W.dir .. '/dfllm-runtime/mock/alarm.txt') end
local function popup(W, text) df.global.world.status.popups:insert('#', {text = text}) end

local MAM, GOB = 77, 89
local function raws()
  local gob = {flags = {CAN_LEARN = true, CAN_SPEAK = true}}
  local mam = {flags = {CAN_LEARN = false, CAN_SPEAK = false}}         -- an animal: no LARGE_PREDATOR, no CARNIVORE
  df.creature_raw = {find = function(r)
    if r == GOB then return {caste = {[0] = gob}} elseif r == MAM then return {caste = {[0] = mam}} end
  end}
end
local function mammoth(W, id, x, y, z)
  z = z or Z
  local u = W.add_unit({id = id, pos = {x, y, z}, animal = true})
  u.race, u.caste = MAM, 0
  u.body = {size_info = {size_cur = 600000}}
  u.flags1 = {}
  W.tiles[x .. ',' .. y .. ',' .. z] = {des = {outside = false, hidden = false}}
  return u
end
local function goblin(W, id, x, y, z, size)
  local u = W.add_unit(S.inv(id, x, y, z or Z))
  u.race, u.caste = GOB, 0
  u.body = {size_info = {size_cur = size or 6795}}
  return u
end
local CF = {reflex = {v = 2, ack_timeout_s = 10}}
local function herd(tag, cfg)
  local W = setup{tag = tag, manifest = false, ms_per_frame = 500, cfg = cfg or CF}
  raws()
  dfhack.maps.getWalkableGroup = function() return 7 end
  for i, p in ipairs({{62, 72}, {63, 72}, {64, 72}, {61, 73}}) do mammoth(W, 300 + i, p[1], p[2]) end
  return W
end

T.test('BUG-672: four woolly mammoths inside Kern+ hold BREACH and the PREDATOR lockdown only for passive_days; then they are cleared, the mode and the lockdown end', function()
  local W = herd('mam1')
  S.run(W, 200)
  local h = W.K.census.h
  T.eq({h.vis, h.inside, h.list[1].hb, h.list[1].k}, {4, 4, 1, 'danger'}, 'four plant eaters inside')
  T.eq(W.K.mode(), 'BREACH')
  S.run(W, 9 * 30)
  T.eq({W.state().alarm.lock, cap(W)}, {1, 30}, 'the PREDATOR default: the lockdown, the clock at 30 t/s')
  local days = require('dfllm.reflex').cfg(W.K).confine.passive_days
  T.eq(days, 3)
  S.run(W, days * 1200 - 900)
  T.eq({W.K.mode(), #events(W, 'HOSTILE_RELEASED')}, {'BREACH', 0}, 'held while the days are not over')
  S.run(W, 1500)
  local r = events(W, 'HOSTILE_RELEASED')
  T.eq(#r, 1, 'said once')
  T.eq({r[1].cls, r[1].d.n, r[1].d.why, r[1].d.inside, r[1].d.mode}, {'B', 4, 'passive', 4, 'BREACH'})
  T.ok(r[1].msg:find('4 hostiles cleared (passive', 1, true), r[1].msg)
  S.run(W, 3000)
  T.ok(W.K.mode() ~= 'BREACH', 'the BREACH ends by its own quiet clock: ' .. W.K.mode())
  S.run(W, 8400 + 2400 + 2000)
  T.eq(W.K.mode(), 'PEACE')
  T.eq(#events(W, 'LOCKDOWN_END'), 1)
  T.eq({W.state().alarm.lock, cap(W)}, {0, 250}, 'the lockdown is over, the clock is free')
  T.eq(W.state().alarm.far, 4, 'the four stay cleared')
  -- the list survives a reload
  local p = json.decode(W.persist_raw['dfllm.m.reflex'])
  T.eq({#p.far.pv, #p.far.ig}, {4, 4})
end)

T.test('BUG-672: a cleared plant eater that kills counts again at once (BREACH again); the other three stay cleared; a second hostile does not bring them back', function()
  local W = herd('mam2')
  S.run(W, 200 + 9 * 30 + 3 * 1200 + 1500)
  T.eq(#events(W, 'HOSTILE_RELEASED'), 1)
  S.run(W, 3000)
  T.ok(W.K.mode() ~= 'BREACH')
  -- a goblin walks up: a newcomer in sight brings BUG-065's cleared ones back, but not the passive ones
  goblin(W, 500, 60, 20)
  S.run(W, 120)
  T.eq(W.K.census.h.inv, 1, 'the goblin is in sight')
  T.eq(W.state().alarm.far, 4, 'the mammoths stay cleared beside another hostile in sight (old rule: all count again)')
  -- one of them kills a citizen: the killer mark takes hb away, it is a danger again
  T.eq({W.K.call('sense', 'mark_killer', 302)}, {true, true})
  S.run(W, 400)
  T.eq(W.K.mode(), 'BREACH', 'the killer inside Kern+ counts')
  T.eq(W.state().alarm.far, 3, 'only the other three stay cleared')
  T.eq(W.K.census.h.inside, 4)
  local ok, a = W.K.call('threat', 'assess')
  T.eq(a.inside, 1, 'threat counts the killer only')
end)

T.test('BUG-676: ack clears the plant eaters of a PREDATOR lockdown at once (it did nothing); lockdown.release names one unit; an invader or a killer is refused', function()
  local W = herd('mam3')
  S.run(W, 200 + 9 * 30)
  T.eq({W.K.mode(), W.state().alarm.lock}, {'BREACH', 1})
  local r = W.inbox('ack', {})
  T.ok(r.ok and r.msg:find('4 wild animals cleared', 1, true), r.msg)
  local ev = events(W, 'HOSTILE_RELEASED')
  T.eq({#ev, ev[1].d.why, ev[1].d.n}, {1, 'operator', 4})
  S.run(W, 3000)
  T.ok(W.K.mode() ~= 'BREACH', 'the BREACH ends: ' .. W.K.mode())
  -- lockdown.release needs approve and a unit of the census that is a wild animal
  local W2 = herd('mam4')
  goblin(W2, 500, 150, 30)
  S.run(W2, 200)
  local r2 = W2.inbox('lockdown.release', {unit = 500})
  T.ok(not r2.ok, 'no approve: ' .. tostring(r2.msg))
  r2 = W2.inbox('lockdown.release', {unit = 500, approve = true})
  T.ok(not r2.ok and r2.msg:find('is a inv', 1, true) or (not r2.ok and r2.msg:find('invader', 1, true)), tostring(r2.msg))
  T.eq({W2.K.call('sense', 'mark_killer', 301)}, {true, true})
  S.run(W2, 60)
  r2 = W2.inbox('lockdown.release', {unit = 301, approve = true})
  T.ok(not r2.ok and r2.msg:find('killed a citizen', 1, true), tostring(r2.msg))
  r2 = W2.inbox('lockdown.release', {unit = 302, approve = true})
  T.ok(r2.ok and r2.msg:find('1 wild animal cleared', 1, true), tostring(r2.msg))
  r2 = W2.inbox('lockdown.release', {unit = 999, approve = true})
  T.ok(not r2.ok and r2.msg:find('not in the census', 1, true), tostring(r2.msg))
end)

T.test('BUG-676: lockdown_long past the limit carries the release command when only wild animals are counted, none beside invaders', function()
  local W = herd('mam6', {reflex = {v = 2, ack_timeout_s = 10, confine = {passive_days = 0, max_days = 2}}})
  S.run(W, 200 + 9 * 30 + 3 * 1200)
  local dn = {}
  for _, e in ipairs(events(W, 'DECISION_NEEDED')) do if e.d.id == 'lockdown_long' then dn[#dn + 1] = e end end
  T.eq(#dn, 1)
  T.ok(dn[1].d.rel and dn[1].d.rel:find('lockdown.release', 1, true) and dn[1].d.rel:find('"unit":' .. dn[1].d.unit, 1, true), tostring(dn[1].d.rel))
  local W2 = herd('mam7', {reflex = {v = 2, ack_timeout_s = 10, confine = {passive_days = 0, max_days = 2}}})
  goblin(W2, 500, 150, 30)
  S.run(W2, 200 + 9 * 30 + 3 * 1200)
  for _, e in ipairs(events(W2, 'DECISION_NEEDED')) do
    if e.d.id == 'lockdown_long' then T.eq(e.d.rel, nil, 'an invader in sight: the sortie is the way') end
  end
end)

T.test('BUG-672: passive_days 0 keeps the old rule (BREACH for as long as they stand there)', function()
  local W = herd('mam5', {reflex = {v = 2, ack_timeout_s = 10, confine = {passive_days = 0}}})
  S.run(W, 200 + 9 * 30 + 6 * 1200)
  T.eq({W.K.mode(), #events(W, 'HOSTILE_RELEASED'), W.state().alarm.lock}, {'BREACH', 0, 1})
end)

---------------------------------------------------------------- BUG-673: hostiles no walk group reaches
-- a group of n goblins at x 60.., y 20, level z; getWalkableGroup: the citizens' 7 everywhere except `other(q)`
local function band(tag, n, z, other, cfg)
  local W = setup{tag = tag, manifest = false, ms_per_frame = 500, cfg = cfg or CF}
  raws()
  W.group_of = function(q) return other(q) or 7 end
  dfhack.maps.getWalkableGroup = function(q) return W.group_of(q) end
  for i = 1, n do goblin(W, 600 + i, 60 + (i - 1) % 3, 20 + (i - 1) // 3, z) end
  return W
end
local CAVE = function(q) if q.z >= Z + 3 then return 9 end end                      -- a cave level of its own
local OUTSIDE = function(q) if q.y < 8 then return 8 end end                         -- the far side of the entrance door at y 8

T.test('BUG-673: five goblins on a cave level no citizen can walk to hold the ALERT lockdown only for unreach_days; then they are cleared, ALERT and the lockdown end', function()
  local W = band('unr1', 5, Z + 5, CAVE)
  S.run(W, 200)
  local h = W.K.census.h
  T.eq({W.K.mode(), h.inv, h.list[1].rc, h.list[1].dz}, {'ALERT', 5, 0, 0}, 'five invaders, out of reach (rc 0)')
  S.run(W, 9 * 30)
  T.eq({W.state().alarm.lock, cap(W)}, {1, 30})
  local days = require('dfllm.reflex').cfg(W.K).confine.unreach_days
  T.eq(days, 5)
  S.run(W, days * 1200 - 900)
  T.eq({W.K.mode(), #events(W, 'HOSTILE_RELEASED')}, {'ALERT', 0}, 'held while the days are not over')
  S.run(W, 1500)
  local r = events(W, 'HOSTILE_RELEASED')
  T.eq(#r, 1)
  T.eq({r[1].d.n, r[1].d.why, r[1].d.mode, r[1].d.inside}, {5, 'unreachable', 'ALERT', 0})
  S.run(W, 1500)
  T.eq(W.K.mode(), 'PEACE', 'threat counts them for nothing: ALERT ends')
  S.run(W, 2400 + 2400 + 600)
  T.eq(#events(W, 'LOCKDOWN_END'), 1, 'old code: never (five invaders near)')
  T.eq({W.state().alarm.lock, cap(W)}, {0, 250})
  -- the same fort with unreach_days 0 (the old rule): still locked down after the same time
  local W0 = band('unr0', 5, Z + 5, CAVE, {reflex = {v = 2, ack_timeout_s = 10, confine = {unreach_days = 0}}})
  S.run(W0, 200 + 9 * 30 + 5 * 1200 + 9000)
  T.eq({W0.K.mode(), #events(W0, 'HOSTILE_RELEASED'), W0.state().alarm.lock}, {'ALERT', 0, 1})
end)

T.test('BUG-673: an invader that can be reached again (a walk group of the citizens) counts at once', function()
  local W = band('unr2', 5, Z + 5, CAVE)
  S.run(W, 200 + 9 * 30 + 6000 + 1500)
  T.eq(#events(W, 'HOSTILE_RELEASED'), 1)
  S.run(W, 1500)
  T.eq({W.K.mode(), W.state().alarm.far}, {'PEACE', 5})
  W.group_of = function() return 7 end                    -- a way is open: the cave joins the citizens' group
  S.run(W, 200)
  T.eq({W.state().alarm.far, W.K.mode()}, {nil, 'ALERT'}, 'all five count again')
end)

T.test('BUG-673: goblins at the far side of the entrance (a raised bridge cuts the citizens off) are no unreachable ones: nothing is cleared, the lockdown stays', function()
  local W = band('unr3', 5, Z, OUTSIDE)
  for i = 1, 5 do W.move(600 + i, 50 + i, 3, Z) end
  S.run(W, 200 + 9 * 30 + 6000 + 4000)
  T.eq(W.K.census.h.list[1].rc, 0, 'rc 0: the citizens cannot walk to them')
  T.eq({W.K.mode(), #events(W, 'HOSTILE_RELEASED'), W.state().alarm.lock}, {'ALERT', 0, 1}, 'a siege at the door is no cave group')
end)

T.test('BUG-673: seven unreachable goblins are a SIEGE: never cleared there (only PEACE / ALERT / RECOVERY clear)', function()
  local W = band('unr4', 7, Z + 5, CAVE)
  S.run(W, 200 + 9 * 30 + 6000 + 4000)
  T.eq({W.K.mode(), #events(W, 'HOSTILE_RELEASED'), W.state().alarm.lock}, {'SIEGE', 0, 1})
end)

---------------------------------------------------------------- BUG-674 / BUG-675: the squads screen in an animals-only BREACH, a sortie in PEACE
local function mil_world(thr, foe_cv)
  local W = X.world{n = 50}
  local th = {name = 'threat', every = {ticks = 100000}}
  function th.assess(K) return thr end
  local sg = {name = 'siege', every = {ticks = 100000}}
  function sg.so_conf(K) return {worn = 0, kill_near = 5, idle_ticks = 1200, hold_ticks = 4800, track_near = 25, foe_cv = foe_cv or 0} end
  local rf = {name = 'reflex', every = {ticks = 100000}}
  function rf.lone_ids(K) return nil, 'stale' end
  function rf.ignore(K, id, why) return true end
  function rf.far_ids(K) return {} end
  local snap = X.snapshot()
  snap.groups = function(K, pts) local r = {}; for i = 1, #pts do r[i] = 1 end; return r end
  X.load(W, {'military'}, {th, sg, rf, snap, X.runner('P5')}, {'sense'})
  X.mod('military').UNFIT_PCT = 0
  W.state()
  W.run(9, {skip = 9})
  return W
end
local function sorties(W, phase)
  local r = {}
  for _, e in ipairs(W.find_events('SORTIE')) do if phase == nil or e.d.phase == phase then r[#r + 1] = e end end
  return r
end

T.test('BUG-674: the squads-screen verbs work in a SIEGE / BREACH with wild animals only; with an invader, an undead or a great danger counted the old answer stands', function()
  local thr = {fresh = true, inv = 0, great = 0, undead = 0, bd = 0}
  local W = mil_world(thr)
  W.set_mode('SIEGE')
  W.set_mode('BREACH')
  local r = W.inbox('squad.uniform', {squad = 'A', kind = 'melee'})
  T.ok(r.ok, 'an animals-only BREACH: ' .. tostring(r.msg))
  r = W.inbox('squad.create', {name = 'Q', leader = 41})
  T.ok(r.ok, tostring(r.msg))
  T.ok(W.inbox('squad.add', {squad = r.data.squad, unit = 42}).ok)
  local rl = W.inbox('squad.leader', {squad = r.data.squad, unit = 43})
  T.ok(not tostring(rl.msg):find('not allowed', 1, true), 'squad.leader reaches its handler: ' .. tostring(rl.msg))
  for _, set in ipairs({{inv = 6}, {great = 1}, {undead = 2}, {bd = 1}, {siege = 'invasion'}}) do
    for k in pairs({inv = 0, great = 0, undead = 0, bd = 0}) do thr[k] = 0 end
    thr.siege = nil
    for k, v in pairs(set) do thr[k] = v end
    local r2 = W.inbox('squad.uniform', {squad = 'A', kind = 'melee'})
    T.eq({r2.ok, r2.msg}, {false, 'squad.uniform not allowed in BREACH'}, 'a real fight: the answer of old')
    r2 = W.inbox('squad.create', {name = 'T'})
    T.eq({r2.ok, r2.msg}, {false, 'squad.create not allowed in BREACH'})
  end
  thr.inv, thr.great, thr.undead, thr.bd, thr.siege = 0, 0, 0, 0, nil
  thr.fresh = false
  T.eq(W.inbox('squad.uniform', {squad = 'A', kind = 'melee'}).msg, 'squad.uniform not allowed in BREACH', 'no fresh reading: the old answer')
end)

local function one_animal(foe_cv, extra)
  local u = {X.S.danger(201, 100, 100, Z)}
  for _, x in ipairs(extra or {}) do u[#u + 1] = x end
  local W = mil_world({fresh = true, inv = 0, great = 0, undead = 0, bd = 0}, foe_cv)
  for _, x in ipairs(u) do X.add(W, x) end
  W.run(300, {skip = 9})
  return W
end
local CMD = {squad = 'A', target = {100, 100, Z}, unit = 201, approve = true}

T.test('BUG-675: in PEACE a sortie goes against ONE wild animal on the citizens\' ground when the squad can win, and keeps running (the mode is no reason to end it)', function()
  local W = one_animal(0)
  T.eq(W.K.mode(), 'PEACE')
  local r = W.inbox('squad.sortie', CMD)
  T.ok(r.ok, tostring(r.msg))
  T.eq({X.squad_of(W, 'A').orders[0].kind, X.squad_of(W, 'A').orders[0].units}, {'kill', {201}})
  W.run(600, {skip = 9})
  T.eq(#sorties(W, 'abort'), 0, 'old code: ended at once, the mode is PEACE')
  T.eq(X.squad_of(W, 'A').orders[0].units, {201}, 'still on it')
end)

T.test('BUG-675: PEACE still refuses a group, an invader, a unit not in sight, a weak squad and a gate sortie, naming the reason', function()
  local W = one_animal(0, {X.S.danger(202, 90, 100, Z)})
  local r = W.inbox('squad.sortie', CMD)
  T.ok(not r.ok and r.msg:find('not allowed in PEACE', 1, true) and r.msg:find('more than one hostile', 1, true), tostring(r.msg))
  local W2 = one_animal(0, {X.S.inv(202, 90, 100, Z)})
  r = W2.inbox('squad.sortie', {squad = 'A', target = {90, 100, Z}, unit = 202, approve = true})
  T.ok(not r.ok and r.msg:find('not allowed in PEACE', 1, true), tostring(r.msg))
  local W3 = one_animal(0)
  r = W3.inbox('squad.sortie', {squad = 'A', target = {100, 100, Z}, unit = 999, approve = true})
  T.ok(not r.ok and r.msg:find('not in sight', 1, true), tostring(r.msg))
  r = W3.inbox('squad.sortie', {squad = 'A', target = {100, 100, Z}, approve = true})
  T.ok(not r.ok and r.msg:find('needs unit', 1, true), tostring(r.msg))
  r = W3.inbox('squad.sortie', {squad = 'A', target = {100, 100, Z}, unit = 201, approve = true, gate = 'O1'})
  T.eq({r.ok, r.msg}, {false, 'squad.sortie not allowed in PEACE'})
  local W4 = one_animal(1000)                          -- a squad that cannot win (odds hopeless)
  r = W4.inbox('squad.sortie', CMD)
  T.ok(not r.ok and r.msg:find('not allowed in PEACE', 1, true) and r.msg:find('NOT recommended', 1, true), tostring(r.msg))
  T.eq(#sorties(W4, 'go'), 0)
end)

---------------------------------------------------------------- the siege traffic test (a bridge / gate / refuge / lockdown behaviour was touched)
-- Real sieges are what they were: each scenario runs twice on the same fort, once with the new defaults (passive_days 3, unreach_days 5)
-- and once with both bounds off (the old rule); the event trace (mode, arrival, siege, lockdown, recall, refuge, gates) must be the same
-- tick for tick, the bridges must be up, the citizens who stood outside must be inside, nobody stands on a footprint that moves.
local TRACE = {MODE = true, ARRIVAL = true, INTRUDER = true, SIEGE_START = true, SIEGE_END = true, LOCKDOWN = true, LOCKDOWN_END = true,
               RECALL = true, REFUGE_SWITCH = true, REFUGE_FAIL = true, BREACH = true, ALERT_START = true, ALERT_END = true,
               GATE = true, GATE_FAIL = true, LEVER = true, SIEGE_DEEP = true, PREDATOR = true, PREDATOR_FAR = true}
local function trace(W)
  local r = {}
  for _, e in ipairs(W.events) do
    if TRACE[e.type] then r[#r + 1] = string.format('%d %s %s', e.tick, e.type, e.msg:sub(1, 120)) end
  end
  return r
end
local OLD = {reflex = {v = 2, ack_timeout_s = 10, confine = {passive_days = 0, unreach_days = 0}}}
local DRAGON = 91
local function fort_raws()
  local gob = {flags = {CAN_LEARN = true, CAN_SPEAK = true}}
  local mam = {flags = {CAN_LEARN = false, CAN_SPEAK = false}}
  local drg = {flags = {CAN_LEARN = false, CAN_SPEAK = false, BUILDINGDESTROYER = true}}
  df.creature_raw = {find = function(r)
    if r == GOB then return {caste = {[0] = gob}} elseif r == MAM then return {caste = {[0] = mam}} elseif r == DRAGON then return {caste = {[0] = drg}} end
  end}
end
-- the manifest fort with 3 citizens outside Kern+ (80,20: the killing field) who walk in 300 ticks after the news; `build` adds the foes
local function siege_fort(tag, cfg, build)
  local units = S.fort_units()
  for i = 1, 3 do units[#units + 1] = S.cit(10 + i, 78 + i, 20) end
  local W = setup{tag = tag, units = units, ms_per_frame = 500, cfg = cfg}
  fort_raws()
  W.group_of = function(q) if q.y < 8 or q.y > 100 then return 8 end return 7 end    -- the army stands on the far side of O1
  dfhack.maps.getWalkableGroup = function(q) return W.group_of(q) end
  build(W)
  return W
end
local function walk_in(W, ids)
  return {{360, function(w) for _, id in ipairs(ids) do w.move(id, 60 + id % 5, 70, Z) end end}}
end
local function inside(W, id) local u = W.unit(id); return u._m.y >= 41 end
local function same(a, b, what)
  T.eq(#a, #b, what .. ': the same number of events')
  for i = 1, math.max(#a, #b) do
    if a[i] ~= b[i] then T.eq(a[i], b[i], what .. ' event ' .. i) end
  end
end

T.test('siege traffic (BUG-672/673/676): eight goblins outside O1 (rc 0 behind the raised bridge) with three citizens in the killing field: lockdown, recall, ' ..
       'SIEGE, O1 and B1 up, nobody left outside - tick for tick the same with and without the new bounds', function()
  local function run(cfg)
    local W = siege_fort('tr1', cfg, function(W) for i = 1, 8 do goblin(W, 700 + i, 50 + i % 3, 150 + i // 3) end end)
    S.run(W, 3600 + 6 * 1200 + 600, {at = walk_in(W, {11, 12, 13})})
    return W
  end
  local W, W0 = run(CF), run(OLD)
  T.eq(W.K.mode(), 'SIEGE')
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {'up', 'up'}, 'the fort closed')
  T.eq({W.state().alarm.lock, #events(W, 'HOSTILE_RELEASED'), #events(W, 'SIEGE_START'), #events(W, 'LOCKDOWN')}, {1, 0, 1, 1})
  for _, id in ipairs({11, 12, 13}) do T.ok(inside(W, id), 'citizen ' .. id .. ' is inside') end
  T.ok(#events(W, 'RECALL') >= 1, 'the recall ran')
  T.eq(W.pending_violations, 0)
  same(trace(W), trace(W0), 'goblin siege')
end)

T.test('siege traffic (BUG-673): five goblins and a building destroyer at the door (ALERT): the destroyer is never cleared, the goblins of the cave beside it are; ' ..
       'the lockdown, the recall and the doors stay for the destroyer', function()
  local function run(cfg)
    local W = siege_fort('tr2', cfg, function(W)
      for i = 1, 4 do goblin(W, 700 + i, 60 + i % 3, 20 + i // 3, Z + 5) end       -- a cave level of its own (z 15 is group 9)
      local d = W.add_unit(S.inv(710, 51, 3, Z))                                    -- the destroyer at the door, outside O1
      d.race, d.caste = DRAGON, 0
      d.body = {size_info = {size_cur = 4000000}}
      W.group_of = function(q) if q.z >= Z + 3 then return 9 end if q.y < 8 then return 8 end return 7 end
    end)
    S.run(W, 3600 + 6 * 1200 + 1200, {at = walk_in(W, {11, 12, 13})})
    return W
  end
  local W, W0 = run(CF), run(OLD)
  local h = W.K.census.h
  T.eq({h.inv, h.bd}, {5, 1}, 'five invaders, one a building destroyer')
  T.ok(W.K.mode() ~= 'PEACE', 'the destroyer holds the fort: ' .. W.K.mode())
  T.eq(W.state().alarm.lock, 1, 'the lockdown stands for the destroyer')
  local r = events(W, 'HOSTILE_RELEASED')
  T.eq({#r, r[1] and r[1].d.n, r[1] and r[1].d.why}, {1, 4, 'unreachable'}, 'the four cave goblins only, never the destroyer')
  T.ok(W.state().alarm.far == 4, 'four cleared: ' .. tostring(W.state().alarm.far))
  for _, id in ipairs({11, 12, 13}) do T.ok(inside(W, id), 'citizen ' .. id .. ' is inside') end
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {S.bstate(W0, 'O1'), S.bstate(W0, 'B1')}, 'the bridges as before')
  T.eq(W0.K.mode(), W.K.mode(), 'the mode as before')
end)

T.test('siege traffic (BUG-672): four mammoths inside Kern+ in the middle of a goblin siege are cleared, the siege goes on: invaders counted, no hostile inside, lockdown, ' ..
       'bridges up, nobody outside', function()
  local function run(cfg)
    local W = siege_fort('tr3', cfg, function(W)
      for i = 1, 8 do goblin(W, 700 + i, 50 + i % 3, 150 + i // 3) end
      for i, p in ipairs({{62, 72}, {63, 72}, {64, 72}, {61, 73}}) do mammoth(W, 300 + i, p[1], p[2]) end
    end)
    S.run(W, 3600 + 4000, {at = walk_in(W, {11, 12, 13})})
    return W
  end
  local W, W0 = run(CF), run(OLD)
  T.eq(W0.K.mode(), 'BREACH', 'old rule: the mammoths inside make a BREACH of the siege')
  T.eq(#events(W, 'HOSTILE_RELEASED'), 1)
  local ok, a = W.K.call('threat', 'assess')
  T.eq({a.inside, a.siege, a.inv}, {0, 'invaders', 8}, 'the goblins count, the mammoths do not: no hostile inside, a siege of invaders')
  T.eq(W.state().alarm.lock, 1, 'the lockdown stands for the goblins')
  T.ok(W.K.mode() == 'SIEGE' or W.K.mode() == 'BREACH', W.K.mode())
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {'up', 'up'})
  for _, id in ipairs({11, 12, 13}) do T.ok(inside(W, id), 'citizen ' .. id .. ' is inside') end
  T.eq(W.pending_violations, 0)
end)

T.done()
