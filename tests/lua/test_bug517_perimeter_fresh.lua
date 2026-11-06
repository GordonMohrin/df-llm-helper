-- BUG-517 (Run 16b i2 Roadvises y381/y383/y384, Run 16d i4 Trumpetrealms y383-y393; offline, live-untested): status showed
-- 'PERIMETER OPEN 11-16 days' beside a seal wall or door that stood (only `inspect entrances key=refresh` showed it closed): in PEACE the
-- entrance check re-uses its answer for bfs_every days, a finished seal did not ask for a new one. And 'levers lost: O1' kept the
-- perimeter open for 3279 days after a wall was built in front of the bridge O1 (84,72,139): a bridge without its levers is not a way in
-- once a wall or door ends the route over it.
--   seal: PROJECT_DONE of a seal project queues a fresh entrance check (`sealdone` is a BFS reason), `seal.bridge_way(fp)` says whether an
--   opening of the last check runs over the bridge (nil = not proven); readiness drops 'levers lost: X' when bridge_way is false.
local T = require('testlib')
local SW = require('seal_world')
local X = require('wp6_world')

local G = 9
local FP = {20, 25, G, 20, 25, G}
local MAN = {v = 2, bridges = {O1 = {role = 'outer', fp = FP, levers = {{25, 22, G}, {26, 22, G}}}},
             burrows = {['Kern+'] = {role = 'kern'}}}

local function gatehouse()
  local W = SW.new{persist = {manifest = MAN}}
  SW.fill(W, G, 0, 0, 63, 63, ',')
  SW.fill(W, G, 20, 20, 40, 30, '#')
  SW.fill(W, G, 21, 21, 39, 29, '.')
  SW.draw(W, G, {'='}, 20, 25)                            -- O1 lowered: the way in, no door, no lever
  SW.draw(W, G, {'.'}, 35, 20)                            -- and a plain gap that stays open (the fort leaks by design)
  W.o1 = W.dyn[SW.key(20, 25, G)]
  SW.regroup(W)
  SW.citizens(W, {{1, 30, 25, G}, {2, 35, 27, G}})
  W.gate = SW.fake('gate', {state = function(K, b) if b == nil then return {} end return 'down' end, fire = function(K, s) end})
  W.load(W.gate)
  W.load(SW.fake('runner', {repair = function() return true, 'rp1' end}))
  package.loaded['dfllm.seal'] = nil
  W.load(require('dfllm.seal'))
  return W
end

local function way(W) local ok, r = W.K.call('seal', 'bridge_way', FP); T.ok(ok, 'seal.bridge_way is called'); return r end
-- the walls in front of O1 (outside its footprint), one construction at a time
local function wall(W, y) SW.build_wall(W, 19, y, G) end

T.test('bridge_way: nil before the first check, true while O1 is the route in', function()
  local W = gatehouse()
  T.eq(way(W), nil, 'no entrance check yet: not proven')
  W.run(400, {skip = 9})
  T.eq(way(W), true, 'the lowered bridge without a door is the way in')
end)

local function walled(W, tpl)
  W.run(400, {skip = 9})
  T.eq(way(W), true)
  wall(W, 24)                                              -- the first construction: the watcher asks for a check (daily)
  W.run(200, {skip = 9})
  wall(W, 25)                                              -- the next ones inside the day: the watcher asks for none
  wall(W, 26)
  if tpl then W.K.emit('PROJECT_DONE', 'B', 'y1s0b0 (' .. tpl .. ') done', {proj = 'y1s0b0', tpl = tpl}) end
  W.run(300, {skip = 9})
end

T.test('constructions inside a day ask for no check (the answer lags); the finished seal project asks for a fresh one', function()
  local W = gatehouse()
  walled(W)
  T.eq(way(W), true, 'old: the check of the first wall tile still stands')
  local Wd = gatehouse()
  walled(Wd, 'seal')
  T.eq(way(Wd), false, 'no opening runs over O1 any more')
  local _, x = Wd.K.call('seal', 'entrance_doors')
  local open = {}
  for _, o in ipairs(x.open) do open[#open + 1] = o.pos[1] .. ',' .. o.pos[2] end
  T.eq(open, {'35,20'}, 'only the plain gap is left open')
end)

T.test('another project does not force a check', function()
  local W = gatehouse()
  walled(W, 'hospital')
  T.eq(way(W), true, 'a hospital is no seal: the last answer stands')
end)

---------------------------------------------------------------- readiness: 'levers lost' needs a way over the bridge
local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}
local SEALED = {tick = 1, sealed = 1, routes = 1, doors = {{id = 9, pos = {74, 70, 117}}}, open = {}}
local function rworld()
  local W = X.world{units = X.citizens(50, 1, {skills = SKILLS}), persist = {}}
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.seal = {name = 'seal', every = {ticks = 600}, x = SEALED, rep = {}, way = nil}
  function W.seal.entrance_doors(K) return W.seal.x end
  function W.seal.replaced(K) return W.seal.rep end
  function W.seal.bridge_way(K, fp) return W.seal.way end
  X.load(W, {'military', 'readiness'}, {X.economy(), X.snapshot(), runner, W.seal}, {'sense', 'gate'})
  return W
end
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end

T.test('levers lost: a bridge no opening runs over (wall in front) is no open perimeter; unproven or a way keeps it', function()
  local W = rworld()
  day(W)                                              -- the lever check runs: B1 whole, remembered
  W.buildings[21].linked_mechanisms = require('dfllm.util.k_mock').vec{}      -- B1's lever loses its link
  W.seal.way = true
  day(W, 2)
  T.ok(W.state().ready.pw and W.state().ready.pw:find('levers lost: B1', 1, true), tostring(W.state().ready.pw))
  W.seal.way = nil
  day(W, 2)
  T.ok(W.state().ready.pw and W.state().ready.pw:find('levers lost: B1', 1, true), 'not proven: stays ' .. tostring(W.state().ready.pw))
  W.seal.way = false                                  -- a wall stands in front of B1
  day(W, 2)
  T.eq({W.state().ready.pd, W.state().ready.pw}, {nil, nil}, 'closed: no PERIMETER OPEN')
  for _, f in ipairs(W.state().ready.fail or {}) do T.ok(f ~= 'open_perimeter', T.show(W.state().ready.fail)) end
end)

T.done()
