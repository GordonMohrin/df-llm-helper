-- BUG-671 (Run 16a i1 Basementflew y460: a PREDATOR offer of squad.sortie was 'unit 31428 is not in sight' by the time it was sent, three
-- times in a row): an offer is good for reflex.OFFER_TTL ticks. A unit seen that recently and alive is followed from where it was last
-- seen (the sortie's own unseen clock ends it); an older offer is refused with the reason and the way on.
local T = require('testlib')
local X = require('wp6_world')
local Z = X.Z

local LS = {}                                       -- unit id -> what reflex.last_seen answers
local function setup(units)
  local u = X.citizens(50)
  for _, x in ipairs(units or {}) do u[#u + 1] = x end
  local W = X.world{units = u}
  local sg = {name = 'siege', every = {ticks = 25}}
  function sg.so_conf(K) return {worn = 0, kill_near = 5, idle_ticks = 1200, hold_ticks = 4800, track_near = 25} end
  local rf = {name = 'reflex', every = {ticks = 10}}
  function rf.lone_ids(K) return nil, 'stale' end
  function rf.ignore(K, id, why) return true end
  function rf.last_seen(K, id) return LS[id] end
  local snap = X.snapshot()
  snap.groups = function(K, pts) local r = {}; for i = 1, #pts do r[i] = 1 end; return r end
  X.load(W, {'military'}, {sg, rf, snap, X.runner('P5')}, {'sense'})
  X.mod('military').UNFIT_PCT = 0
  W.state()
  W.run(9, {skip = 9})
  W.K.set_mode('SIEGE', 'test')
  W.K.set_mode('BREACH', 'test')
  W.run(30, {skip = 9})
  X.call(W, 'military', 'posture', 'B2_HOLD')
  return W
end
local function order(W, key) return X.squad_of(W, key).orders[0] end
local function sorties(W, phase)
  local r = {}
  for _, e in ipairs(W.find_events('SORTIE')) do if phase == nil or e.d.phase == phase then r[#r + 1] = e end end
  return r
end

T.test('BUG-671: an offer for a unit that left sight a moment ago is taken: kill order from the last place, ends by itself unseen', function()
  LS = {}
  local W = setup{X.S.inv(201, 100, 100, Z)}
  W.unit(201)._m.hidden = true                       -- it walked out of sight after the offer
  W.run(300, {skip = 9})                             -- the census sees it
  LS[201] = {x = 70, y = 51, z = Z, age = 300, fresh = true, ttl = 1200}
  local r = W.inbox('squad.sortie', {squad = 'A', target = {60, 51, Z}, unit = 201, approve = true})
  T.ok(r.ok, r.msg)
  T.eq({order(W, 'A').kind, order(W, 'A').units}, {'kill', {201}})
  T.ok(r.msg:find('out of sight for 300 ticks', 1, true) and r.msg:find('70,51', 1, true), r.msg)
  T.eq(#sorties(W, 'go'), 1)
  W.run(1800, {skip = 9})
  local ab = sorties(W, 'abort')
  T.eq({#ab, ab[1] and ab[1].d.why}, {1, 'gone'}, 'the sortie ends by itself after sortie.idle_ticks unseen')
end)

T.test('BUG-671: an offer older than OFFER_TTL is refused as stale with the way on; a dead unit is refused', function()
  LS = {}
  local W = setup{X.S.inv(201, 100, 100, Z)}
  W.unit(201)._m.hidden = true
  W.run(300, {skip = 9})
  LS[201] = {x = 70, y = 51, z = Z, age = 3000, fresh = false, ttl = 1200}
  local r = W.inbox('squad.sortie', {squad = 'A', target = {60, 51, Z}, unit = 201, approve = true})
  T.ok(not r.ok and r.msg:find('unit 201 is not in sight', 1, true) and r.msg:find('the offer is stale', 1, true)
       and r.msg:find('3000 ticks ago', 1, true) and r.msg:find('fresh command', 1, true), r.msg)
  T.eq(#sorties(W, 'go'), 0, 'nothing is sent to an empty place')
  LS[201] = {x = 70, y = 51, z = Z, age = 100, fresh = true, ttl = 1200}
  W.unit(201)._m.dead = true
  r = W.inbox('squad.sortie', {squad = 'A', target = {60, 51, Z}, unit = 201, approve = true})
  T.ok(not r.ok and r.msg:find('is not in sight', 1, true), r.msg)
  T.eq(#sorties(W, 'go'), 0)
  LS = {}
  r = W.inbox('squad.sortie', {squad = 'A', target = {60, 51, Z}, unit = 999, approve = true})
  T.ok(not r.ok and r.msg:find('unit 999 is not in sight', 1, true) and not r.msg:find('stale', 1, true), 'a unit never seen: the old refusal ' .. r.msg)
end)

T.done()
