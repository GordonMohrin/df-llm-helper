-- BUG-478 (Run 16c i3 Castletongs y403: O1 'not up ... no worker: its levers lie outside the alert burrow Tiefe+', BREACH, the fort
-- fell) and BUG-481 (Castletongs: 9 traps against 34 goblins and 5 trolls; Syrupobeyed: 38 traps listed, no mechanism):
--   * gate.refuge_gaps: the managed bridges with no linked lever inside the refuge burrow; a refuge lever built beside its
--     manifest tile is found by the resolve scan (old: the scan ran only while NO linked lever was known);
--   * readiness: `ready.rg` in PEACE (no R0 blocker), DECISION_NEEDED refuge_levers with the retrofit command;
--   * readiness: R0 `traps_short` when the armed traps on the weakest attacker path (and in all) are fewer than the target for
--     the siege the fort expects (its largest army from siege.history, 0.35 x citizens), state ready.ts / ready.tt, a shortfall
--     older than DEF.grace_days holds max-pop where it stands, and it is lifted when the traps stand.
local T = require('testlib')
local X = require('wp6_world')
local S = require('siege_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

-- the siege_world manifest with a third lever per bridge inside Tiefe+ (x 70..72, y 70, z Z-6)
local REF = {O1 = {70, 70, Z - 6}, B1 = {71, 70, Z - 6}, B2 = {72, 70, Z - 6}}
local function manifest(refuge_levers)
  local m = S.manifest()
  if refuge_levers ~= false then
    for name, p in pairs(REF) do table.insert(m.bridges[name].levers, p) end
  end
  return m
end

local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end
local function has(list, v) for _, x in ipairs(list or {}) do if x == v then return true end end return false end

local AUDIT_OK = {ok = true, fails = {}, min_traps = 35, bypass = false, refuge_sep = true, civ_sep = true, caverns = true}
local function audit(W, over)
  local a = {}
  for k, v in pairs(AUDIT_OK) do a[k] = v end
  for k, v in pairs(over or {}) do a[k] = v end
  return X.audit(W, a)
end

local function world(o)
  o = o or {}
  local units = X.citizens(o.n or 50, 1, {skills = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}})
  local persist = {}
  if o.hist then persist['m.siege'] = {hist = o.hist} end
  local W = X.world{units = units, persist = persist, manifest = o.manifest or manifest(o.refuge_levers)}
  W.K.cfg.decisions['D-01'] = 'A'
  W.set_plan({v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = o.cap or 120, beauty = 'used_rooms'}})
  local snap = X.snapshot()
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.econ, W.snap, W.runner = X.economy(), snap, runner
  X.load(W, {'military', 'readiness'}, {W.econ, snap, runner}, {'sense', 'threat', 'siege', 'gate'})
  X.mod('readiness').CAPS = {[0] = o.cap or 120, [1] = o.cap or 120, [2] = o.cap or 120, [3] = 250}
  return W
end

-- a lever of bridge `name` where the manifest does not say (linked to it), as siege_world builds one
local function extra_lever(W, name, x, y, z, id)
  local lv = W.add_building{id = id, _kind = 'trap', trap_type = df.trap_type.Lever, x1 = x, y1 = y, x2 = x, y2 = y, z = z,
                            centerx = x, centery = y, state = 0, bridge = name}
  lv.jobs = kmock.vec{}
  local target = W.bridges[name]
  lv.linked_mechanisms = kmock.vec{{_ref = {getBuilding = function() return target end}}}
  W.levers[#W.levers + 1] = lv
  df.global.world.buildings.other.TRAP:insert('#', lv)
  return lv
end

local function gaps(W)
  local ok, g = W.K.call('gate', 'refuge_gaps')
  T.ok(ok, tostring(g))
  return g
end

---------------------------------------------------------------- BUG-478
T.test('BUG-478: gate.refuge_gaps names the bridges without a linked lever inside Tiefe+ (none when each has one)', function()
  local W = world{refuge_levers = false}
  day(W)
  T.eq(gaps(W), {'B1', 'B2', 'O1'})
  local W2 = world()
  day(W2)
  T.eq(gaps(W2), {})
end)

T.test('BUG-478: a refuge lever built BESIDE its manifest tile (and linked) is found by the resolve scan although the bridge ' ..
       'has other linked levers (old: the scan ran only while none was known -> the bridge stayed leverless in Tiefe+)', function()
  local W = world{refuge_levers = false}
  day(W)
  T.eq(gaps(W), {'B1', 'B2', 'O1'})
  extra_lever(W, 'O1', 71, 71, Z - 6, 9001)                  -- inside Tiefe+ (60..80, 60..80, z 3..5)
  W.run(7000, {skip = 9})                                    -- M.RESOLVE (a complete resolution is kept 6000 ticks)
  W.state()
  T.eq(gaps(W), {'B1', 'B2'}, 'O1 now has its refuge lever')
end)

T.test('BUG-478: in PEACE ready.rg names the bridges (no R0 blocker: R0 stops the drills), DECISION_NEEDED refuge_levers (once per ' ..
       'ask_days) with the retrofit command', function()
  local W = world{refuge_levers = false}
  day(W, 3)
  audit(W)
  day(W, 2)
  local r = W.state().ready
  T.eq(r.rg, {'B1', 'B2', 'O1'})
  T.eq(r.lvl, 1, 'no R0 blocker: the audit passed')
  local q = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'refuge_levers' then q[#q + 1] = e end end
  T.eq(#q, 1, 'asked once')
  T.eq(q[1].cls, 'A')
  T.eq(q[1].d.cmds, {'bp.place tpl=fortcore site=same stage=3 retrofit=2'})
  T.ok(q[1].d.q:find('nobody can pull them', 1, true), q[1].d.q)
  day(W, 10)
  local n = 0
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'refuge_levers' then n = n + 1 end end
  T.eq(n, 1, 'not again within ask_days')
  -- the levers stand: no blocker, no more gaps
  local W2 = world()
  day(W2, 3)
  audit(W2)
  day(W2, 2)
  T.eq(W2.state().ready.rg, nil)
end)

---------------------------------------------------------------- BUG-481
T.test('BUG-481: traps_short: 8 armed traps on the weakest path against the siege the fort expects (largest army 50 -> target 29): ' ..
       'R0 blocker, state ready.ts/tt, SIEGE_UNREADY text, max-pop held after the grace days; 40 traps lift it', function()
  local W = world{n = 100, hist = {peak = 50, n = 2, bd = 1}, cap = 120}
  day(W, 3)
  audit(W, {min_traps = 8})
  day(W, 2)
  local r = W.state().ready
  T.ok(has(r.fail, 'traps_short'), T.show(r.fail))
  T.eq(r.tt, 29, 'ceil(50 / 2) + 4')
  T.ok(r.ts:find('8 armed on the weakest path < 29', 1, true), r.ts)
  T.ok(r.ts:find('largest army 50', 1, true), r.ts)
  T.eq(W.state().pop.cap, 120, 'not held yet')
  day(W, 22)
  T.eq(W.state().pop.cap, 100, 'held at the population after the grace days')
  audit(W, {min_traps = 40})                               -- the hall is built
  day(W, 2)
  T.ok(not has(W.state().ready.fail, 'traps_short'), T.show(W.state().ready.fail))
  T.eq(W.state().pop.cap, 120, 'the hold is lifted')
end)

T.test('BUG-481: no history: 0.35 x citizens is the expected army (100 citizens -> 35 -> target 22); a small fort (30) asks nothing; ' ..
       'the target is clamped to 20..40', function()
  local W = world{n = 100, cap = 120}
  local R = X.mod('readiness')
  local K = W.K
  local t, expected = R.trap_target(K, 100)
  T.eq({t, expected}, {22, 35})
  T.eq((R.trap_target(K, 30)), 20, 'floor 20')
  W.K.persist.set('m.siege', {hist = {peak = 200, n = 1, bd = 0}})
  local W2 = world{n = 100, hist = {peak = 200, n = 1, bd = 0}}
  T.eq((X.mod('readiness').trap_target(W2.K, 100)), 40, 'cap 40')
  local W3 = world{n = 30, cap = 120}
  day(W3, 3)
  audit(W3, {min_traps = 2})
  day(W3, 2)
  T.ok(not has(W3.state().ready.fail, 'traps_short'), 'under trap_pop citizens: no ask')
end)

T.test('BUG-481: siege.history records the largest army and building destroyers of the sieges (persisted)', function()
  local units = X.citizens(60, 1)
  for i = 1, 25 do units[#units + 1] = S.inv(500 + i, 50 + i % 3, -90 - (i // 3), Z) end
  local W = X.world{units = units, persist = {}, manifest = manifest()}
  X.load(W, {'military', 'readiness'}, {X.economy(), X.snapshot(), X.runner('P5')}, {'sense', 'threat', 'siege', 'gate'})
  W.set_mode('SIEGE')
  W.run(900, {skip = 9})
  local ok, h = W.K.call('siege', 'history')
  T.ok(ok and h.peak == 25 and h.n == 1, T.show(h))
  local p = W.K.persist.get('m.siege')
  T.ok(p.hist and p.hist.peak == 25, T.show(p.hist))
end)

T.done()
