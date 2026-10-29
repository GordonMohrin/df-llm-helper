-- BUG-169 (live i3, M3-killorder / NEW2 / NEW7-kill-sortie-end-text): trog 42713 stood inside Kern+ (zn 2), rat 42739
-- 149 tiles outside (zn 0). The kernel's own kill order after kill_hours read 'kill on the harmless intruders
-- 42713,42739 inside the fort' and DF's kill list held both: after 42713 died the squad marched out during the BREACH.
-- reflex passed every id of the lone picture (pic.inside = any entry inside), military.kill_lone took every visible id,
-- and the sortie closed with 'target 42739 dead' only (so.ids keeps the living targets).
local T = require('testlib')
local X = require('wp6_world')
local S = require('siege_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local Z = X.Z

---------------------------------------------------------------- military (wp6 world, stand-ins for siege and reflex)
local lone_ids
local function stubs()
  lone_ids = nil
  local sg = {name = 'siege', every = {ticks = 25}}
  function sg.so_conf(K) return {worn = 0, kill_near = 5, idle_ticks = 1200, hold_ticks = 4800} end
  local rf = {name = 'reflex', every = {ticks = 10}}
  function rf.lone_ids(K) if lone_ids then return lone_ids end return nil, 'stale' end
  function rf.ignore(K, id, why) return true end
  return {sg, rf}
end
local function msetup(units)
  local u = X.citizens(50)
  for _, x in ipairs(units or {}) do u[#u + 1] = x end
  local W = X.world{units = u}
  local mods = stubs()
  local snap = X.snapshot()
  snap.groups = function(K, pts) local r = {}; for i in ipairs(pts) do r[i] = 1 end; return r end
  mods[#mods + 1] = snap
  mods[#mods + 1] = X.runner('P5')
  X.load(W, {'military'}, mods, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  W.K.set_mode('SIEGE', 'test')
  W.K.set_mode('BREACH', 'test')
  W.run(30, {skip = 9})
  X.call(W, 'military', 'posture', 'B2_HOLD')
  return W
end
local function sorties(W, phase)
  local r = {}
  for _, e in ipairs(W.find_events('SORTIE')) do if phase == nil or e.d.phase == phase then r[#r + 1] = e end end
  return r
end
local function order(W, key) return X.squad_of(W, key).orders[0] end

T.test('BUG-169: kill_lone takes only the targets the census shows inside (zn 2); a far one alone is refused', function()
  local W = msetup{X.S.inv(201, 78, 93, Z), X.S.inv(150, 150, 150, Z)}       -- 150: far outside, the lower id
  lone_ids = {150, 201}
  local ok, msg = X.call(W, 'military', 'kill_lone', {150, 201}, 'reflex')
  T.ok(ok and msg:find('kill order on 201', 1, true), tostring(msg))
  local key = X.mod('military').sortie_squad(W.K)
  T.eq(order(W, key).units, {201}, 'old code: {150, 201}, the squad marched out to 150')
  local go = sorties(W, 'go')
  T.eq({go[1].d.units, go[1].d.pos}, {{201}, {78, 93, Z}}, 'the sortie position is the inside target')
  local W2 = msetup{X.S.inv(150, 150, 150, Z)}
  ok, msg = X.call(W2, 'military', 'kill_lone', {150}, 'reflex')
  T.eq(ok, false)
  T.eq(msg, 'the target is not inside the fort')
end)

T.test('BUG-169: a kill sortie on two targets names both when it ends dead; an abort names the one that died before', function()
  local W = msetup{X.S.inv(201, 78, 93, Z), X.S.inv(202, 76, 93, Z)}
  lone_ids = {201, 202}
  local ok, msg = X.call(W, 'military', 'kill_lone', {201, 202}, 'reflex')
  T.ok(ok, tostring(msg))
  W.run(150, {skip = 9})
  W.kill(201); W.event('UNIT_DEATH', {unit = 201})
  lone_ids = {202}
  W.run(150, {skip = 9})
  T.eq(#sorties(W, 'dead'), 0, 'one target still lives')
  W.kill(202); W.event('UNIT_DEATH', {unit = 202})
  lone_ids = nil
  W.run(150, {skip = 9})
  local d = sorties(W, 'dead')
  T.eq(#d, 1)
  T.eq(d[1].d.units, {201, 202}, 'old code: {202}')
  T.ok(d[1].msg:find('targets 201,202 dead after', 1, true), d[1].msg)
  -- an abort (PEACE) after one of two died: d.dead and the text name it
  local W2 = msetup{X.S.inv(201, 78, 93, Z), X.S.inv(202, 76, 93, Z)}
  lone_ids = {201, 202}
  X.call(W2, 'military', 'kill_lone', {201, 202}, 'reflex')
  W2.run(150, {skip = 9})
  W2.kill(201); W2.event('UNIT_DEATH', {unit = 201})
  lone_ids = {202}
  W2.run(150, {skip = 9})
  W2.K.set_mode('RECOVERY', 'test')
  W2.K.set_mode('PEACE', 'test')
  W2.run(150, {skip = 9})
  local a = sorties(W2, 'abort')
  T.eq(#a, 1)
  T.eq({a[1].d.why, a[1].d.dead}, {'mode', {201}})
  T.ok(a[1].msg:find('; dead: 201', 1, true), a[1].msg)
end)

---------------------------------------------------------------- reflex (siege world, the real sense/threat/siege/reflex)
local GOB = 89
local kills
local function rsetup(tag, cfg)
  local dir = H.tmpdir(tag)
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local W = S.world{units = S.fort_units(), dfpath = dir, cfg = cfg}
  W.dir = dir
  df.building_type.Door = 23
  df.global.world.status.popups = kmock.vec{}
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  package.loaded['plugins.overlay'] = nil
  W.act_result('door_forbid', function(id, on) return true, false end)
  W.tiles = {}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  for _, n in ipairs({'reflex', 'arbiter'}) do package.loaded['dfllm.' .. n] = nil end
  kills = {}
  local mil = S.military()
  mil.sortie_squad = function() return 'A', 6 end
  mil.kpi = function() return {squads = 3, soldiers = 8, worn = 95, cv = 13, metal_pct = 0, on_station = 7} end
  mil.kill_lone = function(K, ids, by) kills[#kills + 1] = {ids = ids, by = by}; return true, 'kill order' end
  S.load(W, {mil, snap, require('dfllm.reflex'), require('dfllm.arbiter')})
  return W
end
local function goblin(W, id, x, y)
  local u = W.add_unit(S.inv(id, x, y, Z))
  u.race, u.caste = GOB, 0
  u.body = {size_info = {size_cur = 6486}}
  return u
end

T.test('BUG-169: the lone picture with one unit inside Kern+ and one far out: the kernel orders the kill on the inside one ' ..
       'only', function()
  local W = rsetup('bug169', {reflex = {v = 2, confine = {max_days = 30, ask_days = 10, kill_hours = 12}}})
  local gob = {flags = {CAN_LEARN = true, CAN_SPEAK = true}}
  df.creature_raw = {find = function(r) if r == GOB then return {caste = {[0] = gob}} end end}
  goblin(W, 300, 61, 70)                                -- inside Kern+
  goblin(W, 299, 150, 150)                              -- far outside, the lower id
  S.run(W, 1200)
  T.eq(W.K.mode(), 'BREACH')
  T.ok(#kills >= 1, 'the kill order comes after kill_hours')
  T.eq(kills[1].ids, {300}, 'old code: {299, 300}')
end)

T.done()
