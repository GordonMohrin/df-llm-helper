-- BUG-634 (Run 16d i4 Trumpetrealms y436-y437: R0 `levers:O1` stood for years beside a rebuilt O1, nothing named what its levers wait
-- for): gate.lever_why reads the last look at the manifest levers of a bridge (none / placed not built / built not linked / link job),
-- with the free mechanisms; readiness publishes it as state ready.lw while `levers:<B>` blocks, the status line `levers: ...` carries it.
local T = require('testlib')
local X = require('wp6_world')
local S = require('siege_world')
local kmock = require('dfllm.util.k_mock')
local kv = kmock.vec

local function built(b, on)
  b.getBuildStage = function() return on and 1 or 0 end
  b.getMaxBuildStage = function() return 1 end
end

local function world()
  local units = X.citizens(50, 1, {skills = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}})
  local W = X.world{units = units, manifest = S.manifest()}
  W.K.cfg.decisions['D-01'] = 'A'
  W.set_plan({v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = 120, beauty = 'used_rooms'}})
  local snap, runner = X.snapshot(), X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  df.job_type.LinkBuildingToTrigger = 146
  local eco = X.economy()
  eco.mech_free = function() return 1 end
  eco.mech_state = function() return {route = 'no stone'} end
  X.load(W, {'military', 'readiness'}, {eco, snap, runner}, {'sense', 'threat', 'siege', 'gate'})
  W.act_result('link_lever', function() return false, 'needs 2 free reachable mechanisms, 0 found' end)
  for _, b in pairs(W.bridges) do built(b, true) end
  for _, lv in ipairs(W.levers) do built(lv, true) end
  return W
end
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end

T.test('BUG-634: levers:O1 names what the levers wait for (one lever not linked, the other placed but not built)', function()
  local W = world()
  day(W, 3)
  T.eq(W.state().ready.lw, nil, 'all levers linked: no reason, no blocker')
  local o1 = {}
  for _, lv in ipairs(W.levers) do if lv.x1 == 55 or lv.x1 == 56 then if lv.y1 == 45 then o1[#o1 + 1] = lv end end end
  T.eq(#o1, 2)
  o1[1].linked_mechanisms = kv{}                                   -- built, not linked to the bridge
  built(o1[2], false)                                              -- placed, not built
  day(W, 3)
  local r = W.state().ready
  local has = false
  for _, f in ipairs(r.fail or {}) do if f == 'levers:O1' then has = true end end
  T.ok(has, 'levers:O1 blocks: ' .. T.show(r.fail))
  T.ok(type(r.lw) == 'string' and r.lw:find('O1: 0 of 2 levers linked', 1, true), tostring(r.lw))
  T.ok(r.lw:find('stands, not linked to this bridge', 1, true) and r.lw:find('is placed, not built', 1, true), r.lw)
  T.ok(r.lw:find('1 mechanisms free (no stone)', 1, true), r.lw)
  T.ok(#r.lw <= 200, 'fits the state field')
end)

T.test('BUG-634: a destroyed bridge says so; a bridge whose levers are all linked has no reason', function()
  local W = world()
  day(W, 2)
  local ok, w = W.K.call('gate', 'lever_why', 'O1')
  T.ok(ok and w == nil, T.show(w))
  ok, w = W.K.call('gate', 'lever_why', 'NOPE')
  T.ok(ok and w == nil)
end)

T.done()
