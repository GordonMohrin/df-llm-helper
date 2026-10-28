-- Integration audit I4: what only breaks in the combination of the first-pass packages.
--  * A4 squad.add x fair play: the squads screen lists living adult citizens only
--  * A4 office blocker x A2 perimeter.hold_pop: hold_pop 0 ("the perimeter never holds max-pop") must not switch the
--    small-fort guard of the office blocker off
local T = require('testlib')
local X = require('wp6_world')

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end
local function ready(W) return W.state().ready end
local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end

---------------------------------------------------------------- squad.add
T.test('I4: squad.add takes living adult citizens only (a visitor, a child, a dead figure are refused before the game)', function()
  local units = X.citizens(50)
  units[#units + 1] = X.cit(900, {citizen = false})                  -- a visitor with a figure
  units[#units + 1] = X.cit(901, {adult = false})                    -- a child citizen
  units[#units + 1] = X.cit(902, {dead = true})                      -- a dead citizen
  local W = X.world{units = units}
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  local r = W.inbox('squad.create', {name = 'Q', leader = 41})
  T.ok(r.ok, r.msg)
  local sid = r.data.squad
  local before = #X.acts(W, 'squad_add')
  for _, id in ipairs({900, 901, 902}) do
    r = W.inbox('squad.add', {squad = sid, unit = id})
    T.eq({r.ok, r.msg}, {false, 'unit ' .. id .. ' is not an adult living citizen'})
  end
  r = W.inbox('squad.add', {squad = sid, unit = 9999})
  T.eq({r.ok, r.msg}, {false, 'unit 9999 is not an adult living citizen'})
  T.eq(#X.acts(W, 'squad_add'), before, 'the act was never called for them')
  r = W.inbox('squad.add', {squad = sid, unit = 42})
  T.ok(r.ok, 'a citizen joins: ' .. tostring(r.msg))
  T.eq(#X.acts(W, 'squad_add'), before + 1)
end)

---------------------------------------------------------------- office blocker x hold_pop
local function world(n)
  local W = X.world{units = X.citizens(n, 1, {skills = SKILLS})}
  local snap = X.snapshot()
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.econ, W.snap, W.runner = X.economy(), snap, runner
  X.load(W, {'military', 'readiness'}, {W.econ, snap, runner}, {'sense', 'gate'})
  W.econ.offices = function(K) return {{code = 'CHIEF_MEDICAL_DWARF', n = 1, days = 9, cand = 7}} end
  return W
end

T.test('I4: perimeter.hold_pop 0 (never hold max-pop for an open perimeter) keeps the small-fort guard of the office ' ..
       'blocker: a fort of 7 is not stopped by a vacant office, a fort of 40 is', function()
  local W = world(7)
  W.K.cfg.reflex = {v = 2, perimeter = {hold_pop = 0}}
  day(W)
  T.ok(not has(ready(W).fail, 'office'), '7 citizens, hold_pop 0: no office blocker')
  local W40 = world(40)
  W40.K.cfg.reflex = {v = 2, perimeter = {hold_pop = 0}}
  day(W40)
  T.ok(has(ready(W40).fail, 'office'), '40 citizens: the office still blocks')
  local W7 = world(7)                                              -- the default config, as before
  day(W7)
  T.ok(not has(ready(W7).fail, 'office'), 'default: 7 citizens, no office blocker')
end)

---------------------------------------------------------------- the config files carry the defaults of the code
local F = require('wp8_world')
local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

T.test('I4: config/reflex.json carries every key the first pass reads, with the default the code uses', function()
  X.world{n = 3}                                                    -- the df / dfhack globals the modules load against
  local R = F.read_json('config/reflex.json')
  local gate, ready, seal, refl, arb = fresh('gate'), fresh('readiness'), fresh('seal'), fresh('reflex'), fresh('arbiter')
  T.eq({R.gate.noeffect_max, R.gate.noeffect_wait}, {gate.NE_MAX, gate.NE_WAIT}, 'BUG-068')
  for k, v in pairs(ready.PERIM) do T.eq(R.perimeter[k], v, 'FR-70 perimeter.' .. k) end
  T.eq({R.perimeter.stop_after, R.perimeter.vanish_after}, {seal.CFG.stop_after, seal.CFG.vanish_after}, 'BUG-048')
  for k, v in pairs(refl.CFG.confine) do T.eq(R.confine[k], v, 'BUG-065 confine.' .. k) end
  T.eq(R.confine.harmless_races, {}, 'no race is harmless by default')
  for k, v in pairs(arb.POPUP_CFG) do T.eq(R.popups[k], v, 'FR-75 popups.' .. k) end
end)

T.test('I4: config/baseline.json carries every key the first pass reads, with the default the code uses', function()
  X.world{n = 3}
  local B = F.read_json('config/baseline.json')
  local mil, ready, zl, kern, water, runner = fresh('military'), fresh('readiness'), fresh('zonelib'), fresh('kern'),
                                              fresh('water'), fresh('runner')
  for k, v in pairs(mil.UNSTICK_DEF) do T.eq(B.military.unstick[k], v, 'BUG-050 unstick.' .. k) end
  T.eq({B.military.early_pop, B.military.station_r}, {mil.EARLY_POP, mil.STATION_R}, 'BUG-051/052')
  local function months(set) local l = {} for m in pairs(set) do l[#l + 1] = m end table.sort(l) return l end
  T.eq(months(mil.conf({cfg = {}}).militia.B), B.military.militia.B, 'FR-71 militia B')
  T.eq(months(mil.conf({cfg = {}}).free), B.military.free_months, 'FR-71 free_months')
  T.eq(B.offices.blocker_days, ready.OFFICES.days, 'BUG-055')
  T.eq({B.offices.mood_ws_days, B.offices.mood_ws_pop}, {ready.MWS.days, ready.MWS.pop}, 'BUG-117')
  T.eq(B.zones.max_tiles, zl.MAX_TILES, 'FR-78')
  for k, lim in pairs(kern.PERF) do T.eq(B.perf[k], lim[1], 'BUG-070/071 perf.' .. k) end
  for k, v in pairs(water.DEFAULTS) do
    if k:find('^carers_') or k:find('^dying_') then T.eq(B.water[k], v, 'BUG-054 water.' .. k) end
  end
  T.eq({B.runner.seal_first.wall, B.runner.seal_first.wall_days}, {runner.CFG.seal_wall, runner.CFG.seal_wall_days}, 'BUG-044')
  T.eq({B.runner.reclaim.gone_scans, B.runner.reclaim.min_ws, B.runner.reclaim.ask_days},
       {runner.CFG.rec_scans, runner.CFG.rec_min, runner.CFG.rec_ask}, 'BUG-066/FR-76')
end)

T.done()
