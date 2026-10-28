-- BUG-140 (live test i3, Trussroads y717): squad A killed the target of an approved squad.sortie (incident STRUCK_DOWN), but
-- the sortie ended as `abort more_hostiles` ("the picture is no lone harmless intruder any more", ticks=1201), not `dead`.
-- sortie_pass tested the lone-harmless picture before the dead check: the dead target left the census, reflex.lone_ids
-- answered 'stale' (the census scan lags one pass) or 'group' (another lone harmless unit stayed in sight), and with
-- military demoted one pass covered 1,201 ticks, so 'stale' passed the 2 x SO_EVERY tick allowance at the first look.
-- Fixture of test_m3_sortie (wp6_world, stand-ins for siege and reflex).
local T = require('testlib')
local X = require('wp6_world')
local Z = X.Z

local lone_ids, lone_why
local function stubs()
  lone_ids, lone_why = nil, 'stale'
  local sg = {name = 'siege', every = {ticks = 25}}
  function sg.so_conf(K) return {worn = 0, kill_near = 5, idle_ticks = 1200, hold_ticks = 4800} end
  local rf = {name = 'reflex', every = {ticks = 10}}
  function rf.lone_ids(K) if lone_ids then return lone_ids end return nil, lone_why end
  function rf.ignore(K, id, why) return true end
  return {sg, rf}
end

local function setup(units)
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

T.test('BUG-140: the target of a kept sortie dies while another lone harmless unit stays in sight: SORTIE dead, not ' ..
       'abort more_hostiles', function()
  local W = setup{X.S.inv(201, 100, 100, Z), X.S.inv(202, 140, 140, Z)}
  lone_ids = {201}
  W.inbox('squad.sortie', {squad = 'A', target = {101, 100, Z}, approve = true})
  W.run(150, {skip = 9})
  T.eq(#sorties(W, 'abort'), 0)
  W.kill(201); W.event('UNIT_DEATH', {unit = 201})
  lone_ids = {202}                                       -- the picture now: the other one (lone_of says 'group')
  W.run(150, {skip = 9})
  T.eq(#sorties(W, 'abort'), 0, 'old code: abort more_hostiles')
  local d = sorties(W, 'dead')
  T.eq({#d, d[1] and d[1].d.why, d[1] and d[1].d.units}, {1, 'killed', {201}})
end)

T.test('BUG-140: one military pass over many ticks (demoted) right after the death: SORTIE dead, not more_hostiles', function()
  local W = setup{X.S.inv(201, 100, 100, Z)}
  lone_ids = {201}
  W.inbox('squad.sortie', {squad = 'A', target = {101, 100, Z}, approve = true})
  W.run(150, {skip = 9})
  W.kill(201); W.event('UNIT_DEATH', {unit = 201})
  lone_ids, lone_why = nil, 'stale'                      -- reflex's census scan lags behind the death
  W.run(1200, {skip = 300})                              -- a demoted module: one look covers hundreds of ticks
  T.eq(#sorties(W, 'abort'), 0, 'old code: abort more_hostiles after the first long look')
  T.eq(#sorties(W, 'dead'), 1)
end)

T.test('BUG-140: the lag allowance counts looks, not ticks: one long stale look does not end a sortie whose target lives',
       function()
  local W = setup{X.S.inv(201, 100, 100, Z)}
  lone_ids = {201}
  W.inbox('squad.sortie', {squad = 'A', target = {101, 100, Z}, approve = true})
  W.run(150, {skip = 9})
  lone_ids, lone_why = nil, 'stale'
  W.run(300, {skip = 300})                               -- one look of 300 ticks
  T.eq(#sorties(W, 'abort'), 0, 'old code: 300 ticks >= 2 x SO_EVERY at the first stale look')
  lone_ids = {201}
  W.run(300, {skip = 9})
  T.eq(#sorties(W, 'abort'), 0, 'the picture is back: the sortie goes on')
end)

T.done()
