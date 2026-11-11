-- BUG-712 / 713 / 714 (round 46b, lever). Run 16b i2 Whirledrampart y430: B2 and O1 without a linked lever for 1672 days (GATE_FAIL
-- 'no_lever' at every siege, SIEGE / BREACH flickering 'bridge_stuck'), nobody asked for them (the refuge_levers question named only B1);
-- the retrofit seemed to remove the levers that stood. Run 16d i4 Trumpetrealms: B1 'not up at T+900' (the safety hold for citizens on the footprint).
--   BUG-712 gate.lever_states / readiness: DECISION_NEEDED bridge_levers for a bridge with no linked lever at all (R0 `levers:<B>`), state
--           ready.ll; lever 'none' -> `bp.place ... retrofit=3` (main + refuge levers)
--   BUG-713 runner.merge_manifest keeps the levers a bridge already lists when a fragment re-merges its entry
--   BUG-714 no gate change (the log shows a deliberate hold, see the bug file): siege traffic test of the unchanged raise pipeline
local T = require('testlib')
local X = require('wp6_world')
local S = require('siege_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local runner = require('dfllm.runner')
local Z = S.Z
local kv = kmock.vec

local REF = {O1 = {70, 70, Z - 6}, B1 = {71, 70, Z - 6}, B2 = {72, 70, Z - 6}}
local function manifest()
  local m = S.manifest()
  for name, p in pairs(REF) do table.insert(m.bridges[name].levers, p) end
  return m
end
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end
local function built(b, on)
  b.getBuildStage = function() return on and 1 or 0 end
  b.getMaxBuildStage = function() return 1 end
end

local function world()
  local units = X.citizens(50, 1, {skills = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}})
  local W = X.world{units = units, manifest = manifest()}
  W.K.cfg.decisions['D-01'] = 'A'
  W.set_plan({v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = 120, beauty = 'used_rooms'}})
  local snap, runner_m = X.snapshot(), X.runner('P5')
  function runner_m.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  df.job_type.LinkBuildingToTrigger = 146
  X.load(W, {'military', 'readiness'}, {X.economy(), snap, runner_m}, {'sense', 'threat', 'siege', 'gate'})
  X.mod('readiness').CAPS = {[0] = 120, [1] = 120, [2] = 120, [3] = 250}
  W.calls = {}
  W.act_result('link_lever', function(lid, bid)
    W.calls[#W.calls + 1] = {lid, bid}
    return false, 'needs 2 free reachable mechanisms, 0 found'
  end)
  for _, b in pairs(W.bridges) do built(b, true) end
  for _, lv in ipairs(W.levers) do built(lv, true) end
  return W
end
-- no lever of this bridge stands at its manifest tile (toppled by a tantrum, never built)
local function away(W, bridge)
  for _, lv in ipairs(W.levers) do
    if lv.bridge == bridge then lv.x1, lv.x2, lv.y1, lv.y2 = lv.x1 + 20, lv.x2 + 20, lv.y1 + 20, lv.y2 + 20 end
  end
end
local function unlink(W, bridge)
  for _, lv in ipairs(W.levers) do if lv.bridge == bridge then lv.linked_mechanisms = kv{} end end
end
local function questions(W)
  local q = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'bridge_levers' then q[#q + 1] = e end end
  return q
end
local function ready(W)
  local st = W.state()
  return type(st) == 'table' and type(st.ready) == 'table' and st.ready or {}
end

T.test('BUG-712: a bridge no lever of which stands -> gate.lever_states says none for all, ready.ll names it, the question asks for ' ..
       'retrofit=3 (the main levers too), the refuge question does not cover it', function()
  local W = world()
  away(W, 'O1')
  day(W, 5)
  local ok, r = W.K.call('gate', 'lever_states')
  T.ok(ok, tostring(r))
  T.eq({r.O1.n, r.O1.none, r.O1.linked}, {3, 3, 0}, T.show(r.O1))
  T.eq({r.B1.n, r.B1.linked, r.B2.linked}, {3, 3, 3}, T.show(r))
  local rd = ready(W)
  T.eq(rd.ll, {'O1'}, T.show(rd))
  local q = questions(W)
  T.ok(#q >= 1, 'asked')
  T.eq(q[1].d.cause, 'none')
  T.eq(q[1].d.bridge, 'O1')
  T.eq(q[1].d.cmds, {'bp.place tpl=fortcore site=same stage=3 retrofit=3'})
  T.ok(q[1].d.q:find('no lever stands', 1, true) and q[1].d.q:find('GATE_FAIL no_lever', 1, true), q[1].d.q)
end)

T.test('BUG-712: the levers stand but none is linked (no mechanisms) -> the question says unlinked, names the free mechanisms and the ' ..
       'last refusal, no retrofit command', function()
  local W = world()
  unlink(W, 'B2')
  day(W, 5)
  T.eq(ready(W).ll, {'B2'}, T.show(ready(W)))
  local q = questions(W)
  T.ok(#q >= 1, 'asked')
  T.eq(q[1].d.cause, 'unlinked')
  T.eq(q[1].d.cmds, nil)
  T.ok(q[1].d.q:find('not linked: a link takes 2 free mechanisms', 1, true), q[1].d.q)
  T.ok(q[1].d.q:find('last refusal', 1, true), q[1].d.q)
end)

T.test('BUG-712: every bridge has a linked lever -> no ready.ll, no bridge_levers question (control)', function()
  local W = world()
  day(W, 5)
  T.eq(ready(W).ll, nil)
  T.eq(#questions(W), 0)
end)

T.test('BUG-713: merge_manifest keeps the levers a bridge lists when a fragment re-merges its entry (same footprint); a moved bridge ' ..
       'takes the fragment as before', function()
  local m = {v = 2, bridges = {B2 = {role = 'core', fp = {1, 1, 1, 3, 1, 1}, levers = {{5, 5, 1}, {6, 5, 1}}}}}
  runner.merge_manifest(m, {v = 2, bridges = {B2 = {role = 'core', fp = {1, 1, 1, 3, 1, 1}, levers = {{6, 5, 1}, {9, 9, 0}}}}})
  T.eq(m.bridges.B2.levers, {{5, 5, 1}, {6, 5, 1}, {9, 9, 0}}, T.show(m.bridges.B2))
  local again = json.encode(m)
  runner.merge_manifest(m, json.decode(again))
  T.eq(json.encode(m), again, 'idempotent')
  runner.merge_manifest(m, {v = 2, bridges = {B2 = {role = 'core', fp = {2, 2, 1, 4, 2, 1}, levers = {{7, 7, 1}}}}})
  T.eq(m.bridges.B2.levers, {{7, 7, 1}}, 'another footprint: the fragment replaces the entry')
end)

---------------------------------------------------------------- BUG-714 siege traffic test
-- the world: each bridge has a Kern+ lever (siege_world's first lever of it) and a refuge lever in Tiefe+, both work; citizens and a squad walk over the bridges while the real sense /
-- threat / siege / gate run (a raised bridge cannot be walked, a unit on a moving bridge is crushed)
local FPY = {O1 = 10, B1 = 40, B2 = 60}
local function route(x, y0, y1)
  local r, step = {}, y1 >= y0 and 1 or -1
  for y = y0, y1, step do r[#r + 1] = {x, y} end
  return r
end
local function on_fp(name, x, y) return y == FPY[name] and x >= 50 and x <= 52 end
local function tworld(o)
  local m = S.manifest()
  for n in pairs(S.LEVERS) do m.bridges[n].levers = o.one and {m.bridges[n].levers[1]} or {m.bridges[n].levers[1], REF[n]} end
  local cfg = {}
  for _, ids in pairs(S.LEVERS) do cfg[ids[1]] = {worker = 30, pull = 40} end
  local units = S.fort_units()
  local walkers = {}
  for _, w in ipairs(o.walkers or {}) do
    units[#units + 1] = S.cit(w.id, w.route[1][1], w.route[1][2], Z, w.kind == 'soldier' and {squad = 1} or nil)
    walkers[#walkers + 1] = {id = w.id, route = w.route, start = w.start or 0, i = 1, kind = w.kind}
  end
  for i = 1, 3 do units[#units + 1] = S.inv(500 + i, 50 + i % 3, -20, Z) end
  local W = S.world{units = units, manifest = m, lever_cfg = cfg, lever_default = {worker = 30, pull = 40}, move = 100}
  W.mil = S.military()
  S.load(W, {W.mil})
  W.walkers, W.crushed, W.t0 = walkers, {}, nil
  return W
end
local function step(W, t)
  W.t0 = W.t0 or t
  local rel = t - W.t0
  for _, w in ipairs(W.walkers) do
    if rel >= w.start and w.i < #w.route then
      local nx, blocked = w.route[w.i + 1], false
      for name in pairs(FPY) do
        if on_fp(name, nx[1], nx[2]) and S.bstate(W, name) == 'up' then blocked = true end
      end
      if not blocked then w.i = w.i + 1; W.move(w.id, w.route[w.i][1], w.route[w.i][2], Z) end
    end
    local xs, ys, zs = {}, {}, {}
    for k = w.i + 1, math.min(#w.route, w.i + 25) do xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = w.route[k][1], w.route[k][2], Z end
    W.unit(w.id).path = (rel >= w.start and #xs > 0) and {path = {x = kmock.vec(xs), y = kmock.vec(ys), z = kmock.vec(zs)}} or nil
  end
  for _, w in ipairs(W.walkers) do
    if not w.dead then
      local u = W.unit(w.id)
      for name in pairs(FPY) do
        if S.bstate(W, name) == 'moving' and on_fp(name, u._m.x, u._m.y) then
          w.dead = true
          W.crushed[#W.crushed + 1] = string.format('%d on %s at +%d', w.id, name, rel)
        end
      end
    end
  end
end
local function trun(W, ticks)
  local at = {}
  for t = 0, ticks, 9 do at[#at + 1] = {t, step} end
  W.event('INVASION', {id = 1})
  S.run(W, ticks, {at = at})
end
local function walkers()
  local ws = {}
  for i = 1, 5 do ws[#ws + 1] = {id = 300 + i, kind = 'soldier', route = route(51, 30, 44), start = (i - 1) * 18} end
  for k = 0, 3 do
    local north = k % 2 == 0
    ws[#ws + 1] = {id = 320 + k, kind = 'citizen', route = north and route(50, 61, 28) or route(52, 19, 62), start = 100 + 170 * k - 189}
  end
  return ws
end
local function up_at(W, b)
  local r = {}
  for _, f in ipairs(S.flips(W, b)) do if f.to == 'up' then r[#r + 1] = f.tick - W.t_start end end
  return r
end
T.test('BUG-714 traffic (unchanged raise pipeline): SIEGE, a stream of citizens and soldiers over the bridges -> B1 and O1 raised before ' ..
       'T+900, soldiers through, nobody crushed or shut out, no GATE_FAIL / BREACH', function()
  local W = tworld{walkers = walkers()}
  trun(W, 1500)
  T.eq(W.crushed, {}, 'crushed')
  for _, w in ipairs(W.walkers) do if w.kind == 'soldier' then T.eq(w.i, #w.route, 'soldier ' .. w.id .. ' got through') end end
  local t0 = S.mode_tick(W, 'PEACE>SIEGE') - W.t_start
  for _, b in ipairs({'O1', 'B1'}) do
    local up = up_at(W, b)
    T.eq(#up, 1, b .. ' rose once')
    T.ok(up[1] and up[1] - t0 < 900, b .. ' raised before T+900: ' .. tostring(up[1] and (up[1] - t0)))
    T.eq(S.bstate(W, b), 'up')
  end
  T.eq(#W.find_events('GATE_FAIL') + #W.find_events('BREACH'), 0, 'no GATE_FAIL / BREACH')
end)

T.done()
