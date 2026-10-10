-- WP6 drill: the DRILL FSM on the real WP5 reflex (sense, threat, siege, gate) with WP6 military and
-- readiness on k_mock (strict) and the lever/bridge simulator: real pulls, KPIs at T+1,200, PEACE
-- lowers again, pass/fail rules, DRILL_FAIL on the 2nd failure, refusals, aborts, automatic drills,
-- reload mid-drill. Invariants every run: one pending pull per bridge, 0 double toggles.
local T = require('testlib')
local X = require('wp6_world')
local json = require('dfllm.util.json')
local S = X.S
local Z = X.Z

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}

-- opts: n, units (extra specs), phase (fake runner, default P5), auto (automatic drills; default
-- off), lever_cfg, plan
local function world(opts)
  opts = opts or {}
  local units = X.citizens(opts.n or 30, 1, {skills = SKILLS})
  for _, u in ipairs(opts.units or {}) do units[#units + 1] = u end
  local W = X.world{units = units, lever_cfg = opts.lever_cfg, uniform_mode = opts.uniform_mode}
  if opts.plan then W.set_plan(opts.plan) end
  W.runner = X.runner(opts.phase or 'P5')
  X.load(W, nil, {X.economy(), X.snapshot(), W.runner})
  if not opts.auto then X.mod('drill').SETTLE = 1e9 end
  X.run(W, 1200)                               -- military sets up the squads
  if opts.equip ~= false then X.equip_all(W) end
  X.run(W, 50)
  return W
end
local function D() return X.mod('drill') end
local function start(W, why) return X.call(W, 'drill', 'start', why or 'test') end
local function results(W) return X.call(W, 'drill', 'results') end
local function invariants(W)
  T.eq(W.pending_violations, 0, 'never two pending pulls on one bridge')
  T.eq(X.call(W, 'gate', 'kpi').double_toggles, 0, 'no double toggle')
end
local function plan(ceiling)
  return {v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
          policy = {option = 'A', pop_ceiling = ceiling, beauty = 'used_rooms'}}
end

---------------------------------------------------------------- pass / fail
T.test('drill pass: DRILL, real pulls, READY_STATION, KPIs at T+1,200, PEACE lowers the bridges', function()
  local W = world()
  local ok, msg = start(W)
  T.ok(ok, msg)
  T.eq(W.K.mode(), 'DRILL')
  local t0 = W.K.now().tick
  T.eq(X.call(W, 'gate', 'kpi').since, t0, 'gate KPIs reset at T0')
  local A, Cq = X.squad_of(W, 'A'), X.squad_of(W, 'C')
  T.eq(A.cur_routine_idx, 3, 'Ready')
  T.eq(A.orders[0].kind, 'station')
  T.eq(Cq.orders[0].pos, {x = 51, y = 28, z = Z + 1}, 'crossbows in the gallery')
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 1, 'civ alert on (Kern+)')
  X.run(W, 1300)
  T.eq(W.K.mode(), 'PEACE')
  local r = W.find_events('DRILL_RESULT')
  T.eq(#r, 1)
  T.eq(r[1].d.pass, 1, r[1].msg)
  T.ok(r[1].d.raised >= 0 and r[1].d.raised <= 900, 'raised ' .. r[1].d.raised)
  T.eq({r[1].d.worn, r[1].d.outside, r[1].d.dbl}, {100, 0, 0})
  T.ok(r[1].tick - t0 >= 1200 and r[1].tick - t0 <= 1225)
  T.eq(#W.find_events('DRILL_FAIL'), 0)
  for _, b in ipairs({'O1', 'B1'}) do
    local f = S.flips(W, b)
    T.eq(#f, 2, b .. ': one raise, one lower')
    T.eq({f[1].to, f[2].to}, {'up', 'down'})
    T.ok(f[2].tick >= r[1].tick, 'lowered after the measurement')
  end
  T.eq(#S.flips(W, 'B2'), 0, 'the core seal stays down in a drill')
  X.run(W, 600)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {'down', 'down'}, 'lowered again')
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 0)
  T.eq(A.cur_routine_idx, 2, 'Constant training again')
  T.eq(#A.orders, 0)
  invariants(W)
  local p = json.decode(W.persist_raw['dfllm.drill'])
  T.eq(p.streak_fail, 0)
  T.eq(#p.last, 1)
  T.eq(p.last[1].fails, {})
  W.state()
  T.ok(W.state().ready.drill_age >= 0, 'readiness sees the pass')
  T.eq(W.state().ready.worn, 100)
  T.eq(#W.find_events('GATE_FAIL') + #W.find_events('BREACH'), 0)
end)

T.test('no gear: worn < 90 fails; the 2nd failure in a row emits DRILL_FAIL (A)', function()
  local W = world{equip = false}
  start(W)
  X.run(W, 1300)
  local r = W.find_events('DRILL_RESULT')
  T.eq(r[1].d.pass, 0)
  T.eq(r[1].d.worn, 0)
  T.eq(results(W).last[1].fails, {'worn<90'})
  T.eq(#W.find_events('DRILL_FAIL'), 0, 'first failure: digest only')
  X.run(W, 600)
  start(W)
  X.run(W, 1300)
  local f = W.find_events('DRILL_FAIL')
  T.eq(#f, 1)
  T.eq(f[1].cls, 'A')
  T.eq(f[1].d, {streak = 2, fails = {'worn<90'}})
  X.equip_all(W)
  X.run(W, 600)
  start(W)
  X.run(W, 1300)
  T.eq(results(W).streak_fail, 0, 'a pass resets the streak')
  invariants(W)
end)

T.test('a bridge that is not up by T+1,200 fails the drill; no GATE_FAIL or BREACH in a drill', function()
  local W = world{lever_cfg = {[11] = {}, [12] = {}}}      -- O1 levers never get a worker
  start(W)
  X.run(W, 1300)
  local e = results(W).last[1]
  T.eq(e.pass, 0)
  T.eq(e.raised, -1)
  T.ok(e.fails[1] == 'up:O1', T.show(e.fails))
  T.eq(#W.find_events('GATE_FAIL'), 0)
  T.eq(#W.find_events('BREACH'), 0)
  T.eq(W.K.mode(), 'PEACE')
  X.run(W, 300)
  local pending = 0
  for _, lv in ipairs(W.levers) do pending = pending + #lv.jobs end
  T.eq(pending, 0, 'our stale O1 pull was cancelled')
  invariants(W)
end)

T.test('a citizen outside Kern+ fails the drill (bridges still go up at T+600)', function()
  local W = world{units = {X.cit(99, {pos = {20, 20, Z}})}}
  start(W)
  X.run(W, 1300)
  local e = results(W).last[1]
  T.eq(e.pass, 0)
  T.eq(e.outside, 1)
  T.eq(e.fails, {'outside:1'})
  T.ok(e.raised >= 600 and e.raised <= 900, 'raised by the T+600 timer: ' .. e.raised)
  invariants(W)
end)

---------------------------------------------------------------- refusals, aborts, reload
T.test('refused outside PEACE, with merchants, while running; inbox drill only in PEACE', function()
  local W = world()
  W.K.set_mode('ALERT', 'test')
  local ok, msg = start(W)
  T.eq(ok, false)
  T.ok(msg:find('PEACE'))
  W.K.set_mode('PEACE', 'test')
  df.global.plotinfo.caravans:insert('#', {trade_state = df.caravan_state.T_trade_state.AtDepot})
  T.eq({start(W)}, {false, 'merchants on the map'})
  df.global.plotinfo.caravans = require('dfllm.util.k_mock').vec{}
  local r = W.inbox('drill', {why = 'llm check'}, {by = 'llm'})
  T.ok(r.ok, r.msg)
  T.eq(W.K.mode(), 'DRILL')
  T.eq(W.inbox('drill', {}).ok, false, 'kern: drill only in PEACE')
  T.eq({start(W)}, {false, 'a drill is running'})
  X.run(W, 1300)
  T.eq(results(W).last[1].pass, 1)
  T.eq(W.K.mode(), 'PEACE')
end)

T.test('a real hostile during the drill: ALERT, the drill is aborted without a result', function()
  local W = world{units = {S.danger(300, 150, 150, Z, {hidden = true})}}
  start(W)
  X.run(W, 300, {at = {{100, function(w) w.unit(300)._m.hidden = false end}}})
  T.eq(W.K.mode(), 'ALERT')
  T.eq(#W.find_events('DRILL_RESULT'), 0)
  T.eq(results(W).last, {})
  X.run(W, 1500)
  T.eq(#W.find_events('DRILL_RESULT'), 0, 'no late measurement')
  invariants(W)
end)

T.test('reload mid-drill: the drill continues from persist and measures at T+1,200', function()
  local W = world()
  start(W)
  local t0 = W.K.now().tick
  X.run(W, 600)
  -- reload only the drill module (mode DRILL and m.drill are persisted)
  for i, e in ipairs(W.entries) do if e.name == 'drill' then table.remove(W.entries, i) end end
  W.mods.drill = nil
  package.loaded['dfllm.drill'] = nil
  W.load(require('dfllm.drill'))
  X.run(W, 700)
  local r = W.find_events('DRILL_RESULT')
  T.eq(#r, 1)
  T.ok(r[1].tick - t0 >= 1200 and r[1].tick - t0 <= 1225)
  T.eq(W.K.mode(), 'PEACE')
end)

T.test('DRILL without a drill record (lost persist) is ended', function()
  local W = world()
  W.set_mode('DRILL')
  X.run(W, 700)
  T.eq(W.K.mode(), 'PEACE')
  local m = W.find_events('MODE')
  T.eq(m[#m].d.why, 'drill record lost')
end)

---------------------------------------------------------------- automatic drills
T.test('automatic drills: P5, settle, soldiers, bridges; first, yearly, keep R2, after a siege, retry', function()
  local W = world{auto = true}
  local M, K = D(), W.K
  local now = K.now().tick
  W.state()
  T.eq(M.due(K, now), nil, 'settling after boot')
  T.eq(M.due(K, now + 2400), 'first')
  W.runner.phase = 'P4'
  W.state()
  T.eq(M.due(K, now + 2400), nil, 'before P5')
  W.runner.phase = 'P5'
  W.state()
  -- the automatic first drill runs by itself (drill steps every 600 ticks: at boot + 2,400)
  X.run(W, 1200)
  T.eq(W.K.mode(), 'DRILL')
  T.ok(W.find_events('MODE')[#W.find_events('MODE')].d.why:find('auto: first'))
  X.run(W, 1300)
  T.eq(results(W).last[1].pass, 1)
  now = K.now().tick
  T.eq(M.due(K, now + 100000), nil, 'plan ceiling 55: yearly only')
  T.eq(M.due(K, now + 403200), 'yearly')
  W.set_plan(plan(75))
  T.eq(M.due(K, now + 94800), nil, 'R2 growth needs R1 first')
  X.audit(W, {ok = true, fails = {}, min_traps = 35, bypass = false, refuge_sep = true,
               civ_sep = true, caverns = true})
  T.eq(X.call(W, 'readiness', 'level') >= 1, true)
  T.eq(M.due(K, now + 94800), 'keep R2')
  T.eq(M.due(K, now + 90000), nil)
  W.K.set_mode('SIEGE', 'test')
  W.K.set_mode('RECOVERY', 'test')
  W.K.set_mode('PEACE', 'test')
  T.eq(M.due(K, K.now().tick + 6000), 'after siege')
  -- a failed drill is retried after a month
  X.unassign_all(W)
  X.run(W, 6100)
  local why = {}
  for _, e in ipairs(W.find_events('MODE')) do if e.d.to == 'DRILL' then why[#why + 1] = e.d.why end end
  T.eq(why, {'drill: auto: first', 'drill: auto: after siege'})
  local last = results(W).last
  T.eq(last[#last].pass, 0)
  T.eq(M.due(K, last[#last].tick + 30000), nil)
  T.eq(M.due(K, last[#last].tick + 33600), 'retry')
  invariants(W)
end)

-- automatic drill starts (tick, why) and results (tick, pass) in order
local function drills(W)
  local starts, res = {}, {}
  for _, e in ipairs(W.find_events('MODE')) do
    if e.d.to == 'DRILL' then starts[#starts + 1] = {tick = e.tick, why = e.d.why} end
  end
  for _, e in ipairs(W.find_events('DRILL_RESULT')) do res[#res + 1] = {tick = e.tick, pass = e.d.pass} end
  return starts, res
end

T.test('4 failed drills in a row: exactly one DRILL_FAIL; retries back off (month, x2, capped at a season)', function()
  local W = world{auto = true, equip = false}    -- uniform specs, nothing worn: worn 0 (not structural)
  X.run(W, 215000)
  local starts, res = drills(W)
  T.eq(#res, 4, 'four drills in 215,000 ticks')
  for _, r in ipairs(res) do T.eq(r.pass, 0) end
  local f = W.find_events('DRILL_FAIL')
  T.eq(#f, 1, 'only on the 2nd consecutive failure')
  T.eq(f[1].d.streak, 2)
  T.eq(f[1].tick, res[2].tick)
  T.eq(results(W).streak_fail, 4)
  local want = {33600, 67200, 100800}
  for i = 1, 3 do
    local gap = starts[i + 1].tick - res[i].tick
    T.ok(gap >= want[i] and gap <= want[i] + 600, string.format('gap %d: %d (want %d)', i, gap, want[i]))
    T.ok(starts[i + 1].why:find('auto: retry', 1, true), starts[i + 1].why)
  end
  T.eq(D().due(W.K, res[4].tick + 100799), nil)
  T.eq(D().due(W.K, res[4].tick + 100800), 'retry', 'capped at a season')
  invariants(W)
end)

T.test('structural failure (no uniform specs at all): no automatic retry until a uniform exists', function()
  local W = world{auto = true, uniform_mode = 'fail'}   -- act.squad_uniform refused [S2]
  X.run(W, 2500)
  local _, res = drills(W)
  T.eq(#res, 1)
  T.eq(results(W).last[1].fails, {'worn<90'})
  T.eq(X.call(W, 'military', 'kpi').specs, 0)
  X.run(W, 33600 * 3)
  _, res = drills(W)
  T.eq(#res, 1, 'not retried: no drill can reach 90 % without uniform specs')
  T.eq(D().due(W.K, W.K.now().tick), nil)
  T.eq(results(W).blocked, 'no_uniform')
  W.uniform_mode = 'ok'                          -- the uniform can be set now
  local t_uni
  for _ = 1, 200 do
    X.run(W, 600)
    if X.has_uniform(X.squad_of(W, 'A')) then t_uni = W.K.now().tick; break end
  end
  T.ok(t_uni, 'military set the uniform')
  X.run(W, 1900)
  local starts
  starts, res = drills(W)
  T.eq(#res, 2, 'retried once the uniform exists')
  T.ok(starts[2].tick >= t_uni - 600 and starts[2].tick <= t_uni + 600, 'retry right after the input changed')
  T.eq(#W.find_events('DRILL_FAIL'), 1, 'the 2nd failure (nothing worn yet)')
end)

T.test('no Kern+ burrow is structural: retried only once the burrow exists', function()
  local W = world{auto = true}
  local find = dfhack.burrows.findByName
  dfhack.burrows.findByName = function(n) if n == 'Kern+' then return nil end return find(n) end
  X.run(W, 2500)
  local e = results(W).last[1]
  T.eq(e.pass, 0)
  T.ok(table.concat(e.fails, ','):find('no_kern', 1, true), T.show(e.fails))
  X.run(W, 33600 * 2)
  T.eq(#results(W).last, 1, 'no retry without Kern+')
  T.eq(results(W).blocked, 'no_kern')
  dfhack.burrows.findByName = find
  X.run(W, 2000)
  local last = results(W).last
  T.eq(#last, 2)
  T.eq(last[2].pass, 1, T.show(last[2].fails))
  T.eq(results(W).streak_fail, 0)
  T.eq(results(W).blocked, nil)
  T.eq(#W.find_events('DRILL_FAIL'), 0)
end)

T.test('no automatic drill without soldiers or without outer/inner bridges', function()
  local nosq = plan(55)
  nosq.military = {pct = 15, squads = {melee = 0, xbow = 0}, cv_min = 12}
  local W = world{auto = true, plan = nosq}                  -- no squads wanted: no soldiers
  T.eq(X.call(W, 'military', 'kpi').soldiers, 0)
  T.eq(D().due(W.K, W.K.now().tick + 5000), nil)
  local W2 = X.world{units = X.citizens(30, 1, {skills = SKILLS}), manifest = {v = 2, burrows = S.manifest().burrows}}
  W2.runner = X.runner('P5')
  X.load(W2, nil, {X.economy(), X.snapshot(), W2.runner})
  X.run(W2, 1200)
  T.eq(D().due(W2.K, W2.K.now().tick + 5000), nil)
  X.run(W2, 3000)
  T.eq(#W2.find_events('DRILL_RESULT'), 0)
  T.eq(start(W2), true, 'a manual drill still runs')
  X.run(W2, 1300)
  T.eq(results(W2).last[1].fails[1], 'no_bridges')
end)

T.done()
