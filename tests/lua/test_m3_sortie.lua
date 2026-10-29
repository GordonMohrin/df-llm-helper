-- M3 (BUG-113, Run 14 y707 note 96): squad.sortie to a position set a station order only; nothing said whether the soldiers
-- arrived, the BREACH posture took the squad back when the move order was spent, the kernel never killed the one goblin,
-- soldiers beside a unit DF does not treat as an enemy stood there for weeks, and "no killbox" refused a lone enemy.
local T = require('testlib')
local X = require('wp6_world')
local Z = X.Z

local lone_ids, ignored, group_of, lone_why
-- stand-ins: siege answers the sortie config, reflex the lone-harmless picture and the ignore list
local function stubs(conf)
  lone_ids, ignored, group_of, lone_why = nil, {}, nil, 'stale'
  local sg = {name = 'siege', every = {ticks = 25}}
  function sg.so_conf(K) return conf or {worn = 0, kill_near = 5, idle_ticks = 1200, hold_ticks = 4800} end
  local rf = {name = 'reflex', every = {ticks = 10}}
  function rf.lone_ids(K) if lone_ids then return lone_ids end return nil, lone_why end
  function rf.ignore(K, id, why) ignored[#ignored + 1] = {id, why}; return true end
  return {sg, rf}
end

local function setup(units, conf)
  local u = X.citizens(50)
  for _, x in ipairs(units or {}) do u[#u + 1] = x end
  local W = X.world{units = u}
  local mods = stubs(conf)
  local snap = X.snapshot()
  snap.groups = function(K, pts) local r = {}; for i, p in ipairs(pts) do r[i] = group_of and group_of(p) or 1 end; return r end
  mods[#mods + 1] = snap
  mods[#mods + 1] = X.runner('P5')
  X.load(W, {'military'}, mods, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  W.K.set_mode('SIEGE', 'test')
  W.K.set_mode('BREACH', 'test')
  W.run(30, {skip = 9})
  X.call(W, 'military', 'posture', 'B2_HOLD')            -- siege's BREACH posture
  return W
end
local function sorties(W, phase)
  local r = {}
  for _, e in ipairs(W.find_events('SORTIE')) do if phase == nil or e.d.phase == phase then r[#r + 1] = e end end
  return r
end
local function order(W, key) return X.squad_of(W, key).orders[0] end
local function consume(W, key) X.squad_of(W, key).orders = require('dfllm.util.k_mock').vec{} end   -- DF spends the order
local function members_to(W, key, x, y, z)
  for _, p in ipairs(X.squad_of(W, key).positions) do
    if p.occupant >= 0 then W.move(W.hfs[p.occupant].unit_id, x, y, z) end
  end
end

T.test('BUG-113: a position with a visible hostile within 5 tiles is a kill order; the SORTIE go event says so', function()
  local W = setup{X.S.inv(201, 100, 100, Z)}
  local r = W.inbox('squad.sortie', {squad = 'A', target = {102, 100, Z}, approve = true})
  T.ok(r.ok, r.msg)
  T.eq({order(W, 'A').kind, order(W, 'A').units}, {'kill', {201}}, 'old code: a station order at the position')
  T.ok(r.msg:find('kill order on 201', 1, true) and r.msg:find('within 5 tiles', 1, true), r.msg)
  local go = sorties(W, 'go')
  T.eq({#go, go[1].d.squad, go[1].d.why, go[1].d.units}, {1, 'A', 'kill', {201}})
  r = W.inbox('squad.sortie', {squad = 'B', target = {120, 100, Z}, approve = true})
  T.eq({order(W, 'B').kind, order(W, 'B').pos}, {'station', {x = 120, y = 100, z = Z}}, 'nobody near: a station order')
  T.ok(r.msg:find('no visible hostile within 5 tiles', 1, true), r.msg)
end)

T.test('BUG-113: a station sortie that arrives next to a hostile turns into a kill order; without one it ends: arrived',
       function()
  local W = setup{X.S.inv(201, 140, 100, Z)}
  W.inbox('squad.sortie', {squad = 'A', target = {120, 100, Z}, approve = true})
  T.eq(order(W, 'A').kind, 'station')
  W.run(200, {skip = 9})
  T.eq(#sorties(W, 'arrived'), 0, 'not there yet')
  members_to(W, 'A', 120, 100, Z)
  W.move(201, 123, 100, Z)                              -- it walked up to the squad
  W.run(300, {skip = 9})
  local a = sorties(W, 'arrived')
  T.eq({#a, a[1].d.squad}, {1, 'A'})
  T.eq({order(W, 'A').kind, order(W, 'A').units}, {'kill', {201}}, 'the squad is there and a hostile stands within 5 tiles')
  W.inbox('squad.sortie', {squad = 'B', target = {60, 100, Z}, approve = true})
  members_to(W, 'B', 60, 100, Z)
  W.run(300, {skip = 9})
  T.eq(#sorties(W, 'arrived'), 2)
  local e = sorties(W, 'done')
  T.eq({#e, e[1].d.squad, e[1].d.why}, {1, 'B', 'no_target'}, 'nobody to attack: the sortie ends and says so')
  T.eq(order(W, 'B').kind, 'station', 'the posture has the squad again')
end)

T.test('BUG-113: a sortie against a lone harmless intruder is kept against the posture; the dead target ends it: dead',
       function()
  local W = setup{X.S.inv(201, 100, 100, Z)}
  lone_ids = {201}
  W.inbox('squad.sortie', {squad = 'A', target = {101, 100, Z}, approve = true})
  T.eq(order(W, 'A').kind, 'kill')
  W.K.call('military', 'posture', 'B2_HOLD', true)       -- the BREACH posture, forced
  T.eq(order(W, 'A').kind, 'kill', 'old code: the posture takes the squad back')
  W.run(300, {skip = 9})
  T.eq(order(W, 'A').kind, 'kill', 'still')
  W.kill(201); W.event('UNIT_DEATH', {unit = 201})
  W.run(200, {skip = 9})
  local d = sorties(W, 'dead')
  T.eq({#d, d[1].d.why, d[1].d.units}, {1, 'killed', {201}})
  T.eq(order(W, 'A').kind, 'station', 'the posture has the squad again')
  T.eq(X.mod('military').sortie_of(W.K, 'A'), nil)
end)

T.test('BUG-113: a non-lone sortie is not kept: the posture change ends it as before', function()
  local W = setup{X.S.inv(201, 100, 100, Z), X.S.inv(202, 101, 100, Z), X.S.inv(203, 102, 100, Z)}
  lone_ids = nil
  W.inbox('squad.sortie', {squad = 'A', target = {101, 100, Z}, approve = true})
  T.eq(order(W, 'A').kind, 'kill')
  W.K.call('military', 'posture', 'READY_STATION', true)
  T.eq(order(W, 'A').kind, 'station')
end)

T.test('BUG-113: soldiers beside the target for idle_ticks without an attack: abort not_attackable, the unit is cleared',
       function()
  local W = setup({X.S.inv(201, 100, 100, Z)}, {worn = 0, kill_near = 5, idle_ticks = 600, hold_ticks = 4800})
  lone_ids = {201}
  W.inbox('squad.sortie', {squad = 'A', target = {101, 100, Z}, approve = true})
  members_to(W, 'A', 100, 101, Z)                       -- next to it
  W.run(400, {skip = 9})
  T.eq(#sorties(W, 'abort'), 0, 'not yet')
  W.run(500, {skip = 9})
  local ab = sorties(W, 'abort')
  T.eq({#ab, ab[1].d.why, ab[1].d.units}, {1, 'not_attackable', {201}})
  T.ok(ab[1].msg:find('DF does not treat it as an enemy', 1, true), ab[1].msg)
  T.eq(ignored, {{201, 'not_attackable'}})
  T.eq(order(W, 'A').kind, 'station')
end)

T.test('BUG-113: not_attackable clears the unit only for a lone harmless target (a real enemy is only reported)', function()
  local W = setup({X.S.inv(201, 100, 100, Z)}, {worn = 0, kill_near = 5, idle_ticks = 600, hold_ticks = 4800})
  lone_ids = nil                                         -- not a lone harmless picture
  W.inbox('squad.sortie', {squad = 'A', target = {101, 100, Z}, approve = true})
  members_to(W, 'A', 100, 101, Z)
  W.run(900, {skip = 9})
  local ab = sorties(W, 'abort')
  T.eq({#ab, ab[1].d.why}, {1, 'not_attackable'})
  T.eq(ignored, {})
  T.ok(not ab[1].msg:find('the unit is cleared', 1, true), ab[1].msg)
end)

T.test('BUG-113: a hit target is an attack: the idle clock restarts', function()
  local W = setup({X.S.inv(201, 100, 100, Z)}, {worn = 0, kill_near = 5, idle_ticks = 600, hold_ticks = 4800})
  W.unit(201).body = {wounds = {}}
  lone_ids = {201}
  W.inbox('squad.sortie', {squad = 'A', target = {101, 100, Z}, approve = true})
  members_to(W, 'A', 100, 101, Z)
  for i = 1, 5 do
    W.run(200, {skip = 9})
    W.unit(201).body.wounds[#W.unit(201).body.wounds + 1] = {}
  end
  T.eq(#sorties(W, 'abort'), 0, 'wounds keep coming: soldiers are fighting')
  T.eq(ignored, {})
end)

T.test('BUG-113: a kill order DF drops while the target lives is given again three times, then the sortie ends', function()
  local W = setup{X.S.inv(201, 100, 100, Z)}
  lone_ids = {201}
  W.inbox('squad.sortie', {squad = 'A', target = {101, 100, Z}, approve = true})
  for _ = 1, 6 do consume(W, 'A'); W.run(120, {skip = 9}) end
  local ab = sorties(W, 'abort')
  T.eq({#ab, ab[1].d.why}, {1, 'order_dropped'})
end)

T.test('BUG-113: the sortie ends by itself after hold_ticks and in PEACE; the squad is the posture\'s again', function()
  local W = setup({X.S.inv(201, 100, 100, Z)}, {worn = 0, kill_near = 5, idle_ticks = 1200, hold_ticks = 600})
  W.inbox('squad.sortie', {squad = 'A', target = {160, 100, Z}, approve = true})
  W.run(700, {skip = 9})
  local ab = sorties(W, 'abort')
  T.eq({#ab, ab[1].d.why}, {1, 'timeout'})
  local W2 = setup{X.S.inv(201, 100, 100, Z)}
  W2.inbox('squad.sortie', {squad = 'A', target = {160, 100, Z}, approve = true})
  W2.K.set_mode('RECOVERY', 'test'); W2.K.set_mode('PEACE', 'test')
  W2.run(200, {skip = 9})
  ab = sorties(W2, 'abort')
  T.eq({#ab, ab[1].d.why}, {1, 'mode'})
end)

T.test('BUG-113: a target on another walk group is refused with the groups named (snapshot.groups); no verdict without one', function()
  local W = setup{X.S.inv(201, 100, 100, Z)}
  group_of = function(p) return p.x >= 100 and 7 or 3 end
  local r = W.inbox('squad.sortie', {squad = 'A', target = {101, 100, Z}, approve = true})
  T.eq(r.ok, false)
  T.ok(r.msg:find('target unreachable', 1, true) and r.msg:find('walk group 7', 1, true)
       and r.msg:find('squad on 3', 1, true), r.msg)
  T.eq(X.squad_of(W, 'A').orders[0] == nil or X.squad_of(W, 'A').orders[0].kind ~= 'kill', true)
  group_of = function(p) return p.x >= 100 and 0 or 3 end          -- no group at the target (a wall, hidden): no verdict
  r = W.inbox('squad.sortie', {squad = 'A', target = {101, 100, Z}, approve = true})
  T.ok(r.ok, r.msg)
  group_of = function(p) return 5 end                               -- the same group everywhere
  r = W.inbox('squad.sortie', {squad = 'B', target = {101, 100, Z}, approve = true})
  T.ok(r.ok, r.msg)
end)

T.test('BUG-113: "no killbox": the one hostile in sight is the target; two or none are refused with the reason; "x,y,z" is a position',
       function()
  local W = setup{X.S.inv(201, 100, 100, Z)}
  local r = W.inbox('squad.sortie', {squad = 'A', target = 'K9', approve = true})
  T.ok(r.ok and r.msg:find('no killbox K9: kill order on the lone hostile 201', 1, true), r.msg)
  T.eq(order(W, 'A').units, {201})
  r = W.inbox('squad.sortie', {squad = 'B', target = '102,100,10', approve = true})
  T.ok(r.ok, r.msg)
  T.eq({order(W, 'B').kind, order(W, 'B').units}, {'kill', {201}}, 'a string "x,y,z" is a position')
  local W2 = setup{X.S.inv(201, 100, 100, Z), X.S.inv(202, 130, 100, Z)}
  r = W2.inbox('squad.sortie', {squad = 'A', target = 'K9', approve = true})
  T.eq(r.ok, false)
  T.ok(r.msg:find('no killbox K9 and 2 hostiles in sight', 1, true), r.msg)
  local W3 = setup{}
  r = W3.inbox('squad.sortie', {squad = 'A', target = 'K9', approve = true})
  T.ok(not r.ok and r.msg:find('no visible hostile', 1, true), r.msg)
end)

T.test('BUG-113: kill_lone (the kernel\'s own order): the best squad, only at worn >= sortie.worn, refused with the reason otherwise',
       function()
  local W = setup({X.S.inv(201, 100, 100, Z)}, {worn = 100, kill_near = 5, idle_ticks = 1200, hold_ticks = 4800})
  lone_ids = {201}
  local ok, msg = X.call(W, 'military', 'kill_lone', {201}, 'reflex')
  T.eq(ok, false)
  T.ok(msg:find('worn', 1, true) and msg:find('< 100%', 1, true), msg)
  local W2 = setup{X.S.inv(201, 78, 93, Z)}            -- BUG-169: the kernel's kill order is for a unit inside Kern+
  lone_ids = {201}
  ok, msg = X.call(W2, 'military', 'kill_lone', {201}, 'reflex')
  T.ok(ok and msg:find('kill order on 201', 1, true), msg)
  local key = X.mod('military').sortie_squad(W2.K)
  T.eq(order(W2, key).units, {201})
  local go = sorties(W2, 'go')
  T.ok(go[1].msg:find('lone harmless intruder', 1, true), go[1].msg)
  ok, msg = X.call(W2, 'military', 'kill_lone', {201}, 'reflex')
  T.ok(ok and msg:find('is running', 1, true), msg)
  ok, msg = X.call(W2, 'military', 'kill_lone', {999}, 'reflex')
  T.eq(ok, true, 'the running sortie answers first')
  local W3 = setup{X.S.inv(201, 100, 100, Z)}
  lone_ids = {201}
  ok, msg = X.call(W3, 'military', 'kill_lone', {999}, 'reflex')
  T.ok(not ok and msg:find('not in sight', 1, true), tostring(msg))
end)

T.test('BUG-113: a kept sortie ends (more_hostiles) at once when the census shows a dangerous or a second hostile, and after ' ..
       'two looks when the reflex scan only lags', function()
  local W = setup{X.S.inv(201, 100, 100, Z)}
  lone_ids = {201}
  W.inbox('squad.sortie', {squad = 'A', target = {101, 100, Z}, approve = true})
  W.run(150, {skip = 9})
  T.eq(#sorties(W, 'abort'), 0)
  lone_ids, lone_why = nil, 'stale'                      -- no verdict (the reflex scan lags)
  W.run(100, {skip = 9})
  T.eq(#sorties(W, 'abort'), 0, 'one look is not enough')
  W.run(250, {skip = 9})
  local ab = sorties(W, 'abort')
  T.eq({#ab, ab[1].d.why}, {1, 'more_hostiles'})
  T.eq(order(W, 'A').kind, 'station', 'the posture has the squad again')
  local W2 = setup{X.S.inv(201, 100, 100, Z)}
  lone_ids = {201}
  W2.inbox('squad.sortie', {squad = 'A', target = {101, 100, Z}, approve = true})
  W2.run(120, {skip = 9})
  lone_ids, lone_why = nil, 'dangerous'                  -- a second, dangerous hostile came: the verdict is definite
  W2.run(120, {skip = 9})
  ab = sorties(W2, 'abort')
  T.eq({#ab, ab[1].d.why}, {1, 'more_hostiles'})
end)


T.test('review M3: a kill sortie follows the target through the census only; out of sight for idle_ticks it ends: gone', function()
  local W = setup({X.S.inv(201, 100, 100, Z)}, {worn = 0, kill_near = 5, idle_ticks = 600, hold_ticks = 4800})
  lone_ids = {201}
  W.inbox('squad.sortie', {squad = 'A', target = {101, 100, Z}, approve = true})
  W.run(100, {skip = 9})
  W.unit(201)._m.hidden = true                           -- out of sight, alive
  W.move(201, 130, 100, Z)                               -- (a real player could not see where it walked)
  W.run(300, {skip = 9})
  T.eq(#sorties(W, 'abort'), 0, 'not yet')
  T.eq(X.mod('military').sortie_of(W.K, 'A').kind, 'kill')
  W.run(500, {skip = 9})
  local ab = sorties(W, 'abort')
  T.eq({#ab, ab[1].d.why}, {1, 'gone'}, 'old code read the hidden unit position and never gave up before hold_ticks')
  T.eq(ab[1].d.pos, {100, 100, Z}, 'the last position seen, not the hidden one')
end)

T.done()
