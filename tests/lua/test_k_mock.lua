-- k_mock: the reference semantics of CONTRACTS §3.3/§4 (scheduling, events, modes, act, persist, inbox).
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')

local function counter(name, every, extra)
  local M = {name = name, every = every, runs = {}, seen = {}}
  function M.step(K, budget, ctx) M.runs[#M.runs + 1] = {tick = K.now().tick, ctx = ctx} end
  for k, v in pairs(extra or {}) do M[k] = v end
  return M
end

T.test('DF-like vectors are 0-based', function()
  local v = kmock.vec{'a', 'b', 'c'}
  T.eq(#v, 3)
  T.eq(v[0], 'a')
  local seen = {}
  for i, x in ipairs(v) do seen[#seen + 1] = i .. x end
  T.eq(seen, {'0a', '1b', '2c'})
  v:insert('#', 'd'); v:erase(0)
  T.eq({#v, v[0], v[2]}, {3, 'b', 'd'})
end)

T.test('tick cadence survives 9-tick skips', function()
  local W = kmock.new{}
  local m = W.load(counter('test_a', {ticks = 25}))
  W.run(100, {skip = 9})
  -- runs at the first frame, then whenever >= 25 ticks passed since the previous start
  T.eq(#m.runs, 4)
  for i = 2, #m.runs do
    local d = m.runs[i].tick - m.runs[i - 1].tick
    T.ok(d >= 25 and d < 34, 'gap ' .. d)
    T.eq(m.runs[i].ctx.dt, d)
  end
  T.eq(m.runs[1].ctx.dt, 0)
end)

T.test('paused: tick modules wait, ms modules run', function()
  local W = kmock.new{ms_per_frame = 100}
  local tm = W.load(counter('test_t', {ticks = 10}))
  local mm = W.load(counter('test_m', {ms = 500}))
  W.run(20, {paused = true})
  T.eq(#tm.runs, 0)
  T.eq(#mm.runs, 4) -- 2,000 ms of frames: at 100, 600, 1100, 1600
  T.ok(W.K.now().paused)
  W.run(10)
  T.eq(#tm.runs, 1)
end)

T.test("'more' continues next frame with ctx.cont", function()
  local W = kmock.new{}
  local M = {name = 'test_slice', every = {ticks = 600}, slices = {}}
  function M.step(K, b, ctx)
    M.slices[#M.slices + 1] = ctx.slice
    if ctx.slice < 3 then return 'more' end
  end
  W.load(M)
  W.run(5)
  T.eq(M.slices, {1, 2, 3})
  W.run(600)
  T.eq(#M.slices, 6)
end)

T.test('eventful events and emitted events arrive next frame', function()
  local W = kmock.new{}
  local got = {}
  local M = {name = 'test_ev', every = {ticks = 1000}, reports = {CARAVAN_ARRIVAL = true}, on = {
    REPORT = function(K, ev) got[#got + 1] = 'R:' .. ev.type end,
    INVASION = function(K, ev) got[#got + 1] = 'I:' .. ev.id; K.emit('DECISION_NEEDED', 'A', 'q', {id = 'D-07'}) end,
    ['EV:DECISION_NEEDED'] = function(K, ev) got[#got + 1] = 'E:' .. ev.d.id end,
  }}
  W.load(M)
  W.event('REPORT', {type = 'CARAVAN_ARRIVAL', text = 'Händler'})
  W.event('REPORT', {type = 'CANCEL_JOB', text = 'filtered'})
  W.event('INVASION', {id = 7})
  T.eq(got, {})
  W.frame()
  T.eq(got, {'R:CARAVAN_ARRIVAL', 'I:7'})
  W.frame()
  T.eq(got, {'R:CARAVAN_ARRIVAL', 'I:7', 'E:D-07'})
end)

T.test('event registry is enforced', function()
  local W = kmock.new{}
  local M = {name = 'gate', every = {ticks = 25}}
  W.load(M)
  T.raises(function() W.K.emit('NOPE', 'B', 'x') end, 'unknown event type')
  local m = W.load({name = 'runner', every = {ticks = 600}, step = function(K)
    K.emit('GATE_FAIL', 'A', 'not mine', {bridge = 'O1'}) end})
  T.raises(function() W.frame() end, 'must be emitted by gate')
  local n = W.K.emit('SIEGE_END', 'B', string.rep('ä', 150))
  local ev = W.find_events('SIEGE_END')[1]
  T.eq(ev.cls, 'A')
  T.ok(#ev.msg <= 200 and utf8.len(ev.msg), 'msg truncated at a UTF-8 boundary')
  T.eq(json.encode(ev.d), '{}')
  T.eq(ev.n, n)
end)

T.test('set_mode: setters, transitions, synchronous on.MODE, persisted', function()
  local W = kmock.new{}
  local order = {}
  local siege = {name = 'siege', every = {ticks = 25}, on = {MODE = function(K, ev) order[#order + 1] = 'siege:' .. ev.to end}}
  function siege.step(K) if K.census.h and K.census.h.inv >= 6 then K.set_mode('SIEGE', 'army') end end
  local arb = {name = 'arbiter', every = {ms = 500}, on = {MODE = function(K, ev)
    order[#order + 1] = 'arbiter:' .. ev.to
    local ok, err = K.set_mode('BREACH', 'nested')
    order[#order + 1] = tostring(err)
  end}}
  W.load(siege); W.load(arb)
  W.set_census('h', {inv = 8, vis = 8})
  W.frame()
  T.eq(W.K.mode(), 'SIEGE')
  T.eq(order, {'siege:SIEGE', 'arbiter:SIEGE', 'reentrant'})
  T.eq(W.K.persist.get('mode').mode, 'SIEGE')
  T.eq(W.find_events('MODE')[1].d.to, 'SIEGE')
  T.raises(function() W.K.set_mode('PEACE', 'skip recovery') end, 'not allowed')
  local drill = {name = 'drill', every = {ticks = 600}}
  W.load(drill)
  W.set_mode('PEACE')
  T.eq({W.K.call('drill', 'go')}, {false, 'no function go'})
  T.eq({W.K.call('nobody', 'x')}, {false, 'no module'})
end)

T.test('drill may only toggle PEACE<->DRILL', function()
  local W = kmock.new{}
  local d = {name = 'drill', every = {ticks = 600}}
  function d.go(K, m) return K.set_mode(m, 'test') end
  W.load(d)
  T.eq({W.K.call('drill', 'go', 'DRILL')}, {true, true})
  T.raises(function() W.K.call('drill', 'go', 'SIEGE') end, 'drill may not set mode')
end)

T.test('act: recorder, owners, overrides, unknown functions', function()
  local W = kmock.new{}
  local gate = {name = 'gate', every = {ticks = 25}}
  function gate.raise(K) return K.act.pull(4711) end
  function gate.cheat(K) return K.act.popcap(80) end
  W.load(gate)
  local ok, ok2, job = W.K.call('gate', 'raise')
  T.ok(ok and ok2 and type(job) == 'number')
  T.eq(W.find_acts('pull')[1].args[1], 4711)
  T.eq(W.find_acts('pull')[1].by, 'gate')
  T.raises(function() W.K.call('gate', 'cheat') end, 'not owned by gate')
  T.raises(function() return W.K.act.make_items end, 'does not exist')
  W.act_result('pull', function() return false, 'no lever' end)
  T.eq({W.K.call('gate', 'raise')}, {true, false, 'no lever'})
  W.K.act.civ_alert(true)
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 1)
end)

T.test('state composition: ownership and size', function()
  local W = kmock.new{}
  W.load({name = 'sense', every = {ticks = 10}, state = function() return {pop = {cit = 7, adults = 5, soldiers = 1}} end})
  W.load({name = 'readiness', every = {ticks = 33600}, state = function() return {pop = {cap = 55, gate_cap = 55},
    ready = {lvl = 0, worn = 0, cv = 0, drill_age = -1, audit = {ok = 0, age = -1, min_traps = 0}, fail = {}}} end})
  local doc = W.state()
  T.eq(doc.pop, {cit = 7, adults = 5, soldiers = 1, cap = 55, gate_cap = 55})
  T.eq(doc.ready.lvl, 0)
  T.eq(W.K.view().seq, doc.seq)
  W.load({name = 'care', every = {ticks = 1200}, state = function() return {pop = {cit = 1}} end})
  T.raises(function() W.state() end, 'care does not own state pop.cit')
end)

T.test('state too big is a contract violation', function()
  local W = kmock.new{}
  W.load({name = 'gate', every = {ticks = 25}, state = function()
    local b = {}
    for i = 1, 400 do b['B' .. i] = 'down' end
    return {bridges = b}
  end})
  T.raises(function() W.state() end, '> 4096')
end)

-- review F1: every slip below passed ownership and size, but makes Python drop the state slot
local function bad_state(parts)
  local W = kmock.new{}
  for name, part in pairs(parts) do
    W.load({name = name, every = name == 'arbiter' and {ms = 500} or {ticks = 600}, state = function() return part end})
  end
  return W
end

T.test('state schema: strict mode raises on any error', function()
  local cases = {
    {{arbiter = {owners = {tempo = 'mode'}}}, 'owners.pause: missing'},     -- a nil pause drops the key
    {{gate = {bridges = {}}}, 'bridges: expected object, got arr'},          -- empty plain table -> []
    {{readiness = {pop = {cap = -1}}}, 'pop.cap: %-1 < 0'},
    {{readiness = {ready = {lvl = 1, bogus = 2}}}, 'ready.audit: missing'},
    {{readiness = {ready = {lvl = 1, bogus = 2}}}, 'ready.bogus: unknown key'},
    {{threat = {threat = {vis = 1}}}, 'threat.armed: missing'},
    {{gate = {bridges = {o1 = 'up'}}}, 'key o1 is not a bridge'},
    {{runner = {phase = 'P9'}}, 'phase: P9 is not a phase'},
    {{economy = {labor = {starving = 0, idle = 140}}}, 'labor.idle: 140 > 100'},
    {{military = {mil = {squads = 1, soldiers = 2, worn = 50, cv = 3, metal_pct = 0, on_station = '1'}}},
     'mil.on_station: expected int, got str'},
  }
  for _, c in ipairs(cases) do T.raises(function() bad_state(c[1]).state() end, c[2]) end
  local W = bad_state{arbiter = {owners = {pause = json.null, tempo = 'mode'}}, gate = {bridges = json.object{}},
                      threat = {threat = {vis = 1.4, armed = 0}}}
  local doc = W.state()
  T.eq(doc.threat.vis, 1.4) -- floats are written rounded by util/json, so they pass
  T.eq(C.check_state(doc), {})
  T.ok(json.encode(doc):find('"pause":null', 1, true), 'json.null is written as null')
end)

T.test('state schema: non-strict drops only the bad optional keys and logs', function()
  local W = kmock.new{strict = false}
  W.load({name = 'gate', every = {ticks = 25}, state = function() return {bridges = {}} end})
  W.load({name = 'threat', every = {ticks = 25}, state = function() return {threat = {vis = 2, armed = 1}} end})
  local doc = W.state()
  T.eq(doc.bridges, nil)
  T.eq(doc.threat, {vis = 2, armed = 1})
  T.eq(C.check_state(doc), {})
  local logged = false
  for _, l in ipairs(W.logs) do if l.msg:find('dropped bridges', 1, true) then logged = true end end
  T.ok(logged, 'drop is logged')
  local d2 = {v = 2, seq = 1, mode = 'PEACE', ev = 0, k = {ms_s = 0, gap_max_ms = 0, slow = {}, faults = 0},
              t = {y = 1, tick = 5, season = 0, tps = 0, paused = false}, extra = 1}
  local dropped, errs = C.prune_state(d2)
  T.eq({dropped, #errs, d2.extra}, {{'extra'}, 1, nil})
  d2.seq = -1
  dropped, errs = C.prune_state(d2)
  T.eq({#dropped, d2.seq}, {0, -1}) -- required keys are never dropped
end)

T.test('persist: round trip through JSON strings, owner checks', function()
  local W = kmock.new{persist = {manifest = {v = 2, bridges = {O1 = {role = 'outer', fp = {1, 1, 1, 3, 1, 1}, levers = {{5, 5, 1}}}}}}}
  T.eq(W.K.manifest().bridges.O1.role, 'outer')
  T.ok(W.persist_raw['dfllm.manifest']:find('"outer"'))
  T.ok(W.persist_raw['dfllm'], 'marker present by default')
  local r = {name = 'runner', every = {ticks = 600}}
  function r.save(K) local p = K.persist.get('m.runner') or {v = 2, n = 0}; p.n = p.n + 1; K.persist.set('m.runner', p) end
  function r.steal(K) K.persist.set('drill', {v = 2}) end
  W.load(r)
  W.K.call('runner', 'save'); W.K.call('runner', 'save')
  T.eq(json.decode(W.persist_raw['dfllm.m.runner']).n, 2)
  T.raises(function() W.K.call('runner', 'steal') end, 'may not write persist drill')
  T.raises(function() W.K.persist.get('nonsense') end, 'unknown persist key')
  T.eq(dfhack.persistent.getSiteData('dfllm.m.runner').n, 2)
end)

T.test('inbox routing, modes, approval', function()
  local W = kmock.new{}
  local gate = {name = 'gate', every = {ticks = 25}, verbs = {}}
  gate.verbs.lever = function(K, args, cmd) return true, 'queued ' .. args.bridge, {job = 1} end
  W.load(gate)
  local r = W.inbox('lever', {bridge = 'O1', want = 'up'}, {id = 'c1', by = 'llm'})
  T.eq({r.id, r.ok, r.msg, r.data.job}, {'c1', true, 'queued O1', 1})
  W.set_mode('SIEGE')
  T.eq(W.inbox('lever', {bridge = 'O1', want = 'up'}).ok, false)
  T.eq(W.inbox('squad.sortie', {squad = 'A', target = 'K1'}).msg, 'approval required')
  T.eq(W.inbox('rm -rf', {}).msg, 'unknown verb')
  T.eq(W.inbox('drill', {}).ok, false)
  W.plan_file = {v = 2, year = 3, policy = {option = 'A', pop_ceiling = 55, beauty = 'none'}, phase_target = 'P1',
                 seasons = {{build = {{tpl = 'dining', site = 'S1'}}}, {build = {}}, {build = {}}, {build = {}}}}
  local pr = W.inbox('plan.reload', {})
  T.eq({pr.ok, pr.data.builds}, {true, 1})
  T.eq(W.K.plan.military.cv_min, 12)
  T.eq(W.inbox('inspect', {what = 'mode'}).data.mode, 'SIEGE')
  T.eq(#W.find_events('CMD'), 7) -- one CMD event per inbox command, also for rejected ones
end)

T.test('fault isolation (strict=false): 3 faults back the module off', function()
  local W = kmock.new{strict = false}
  W.load({name = 'test_bad', every = {ticks = 1}, step = function() error('boom') end})
  local ok = W.load(counter('test_good', {ticks = 1}))
  W.run(5)
  T.eq(#W.faults, 3)
  local kf = W.find_events('KERN_FAULT')[1]
  T.eq({kf.d.module, kf.d.backoff_s}, {'test_bad', 600})
  T.eq(#ok.runs, 5)
  T.eq({W.K.call('test_bad', 'step')}, {false, 'disabled'})
  T.eq(W.K.enabled('test_bad'), false)
  T.eq(W.state().k.disabled, {'test_bad'})
end)

-- review F8: a transient bug must not switch the defence reflex off until the next load
T.test('backoff: critical 30 s doubling, others 10 min, module.enable resets', function()
  local W = kmock.new{strict = false, ms_per_frame = 1000}
  local boom = true
  local gate = {name = 'gate', every = {ticks = 1}, n = 0}
  function gate.step() gate.n = gate.n + 1; if boom then error('transient') end end
  W.load(gate)
  W.load({name = 'economy', every = {ticks = 1}, step = function() error('econ') end})
  W.run(3)
  T.eq(#W.find_events('KERN_FAULT'), 2)
  T.eq(W.K.enabled('gate'), false)
  W.run(29)
  T.eq(W.K.enabled('gate'), false)
  W.run(1)                                   -- 30 s later: retried
  T.eq(W.K.enabled('gate'), true)
  W.run(3)                                   -- still broken: the second backoff doubles
  local kf = W.find_events('KERN_FAULT')
  T.eq({kf[#kf].d.module, kf[#kf].d.backoff_s}, {'gate', 60})
  boom = false
  W.run(60)
  T.eq(W.K.enabled('gate'), true)
  local n = gate.n
  W.run(10)
  T.eq(gate.n, n + 10)
  T.eq(W.K.enabled('economy'), false)        -- non-critical: 600 s
  local r = W.inbox('module.enable', {module = 'economy'})
  T.eq({r.ok, r.data.module, W.K.enabled('economy')}, {true, 'economy', true})
  T.eq(W.inbox('module.enable', {module = 'nope'}).ok, false)
  W.run(3)
  kf = W.find_events('KERN_FAULT')
  T.eq(kf[#kf].d.backoff_s, 600)              -- the verb reset the doubling
  W.run(600)
  T.eq(W.K.enabled('economy'), true)         -- re-enabled after the cooldown
end)

T.test('demotion via simulated cost', function()
  local W = kmock.new{}
  local m = W.load(counter('economy', {ticks = 10}))
  W.cost.economy = 7
  W.run(40)
  T.eq(#W.find_events('KERNEL_SLOW'), 1)
  local before = #m.runs
  W.run(40)
  T.ok(#m.runs - before <= 2, 'runs every 20 ticks after demotion')
  W.load(counter('sense', {ticks = 10}))
  W.cost.sense = 9
  W.run(40)
  T.eq(#W.find_events('KERN_FAULT'), 1, 'critical modules are not demoted but fault')
  W.run(200)
  T.eq(#W.find_events('KERN_FAULT'), 1, 'at most once per 10 min')
end)

-- review F2: slow calls expire after 10 min, and a quiet module is promoted back
T.test('demotion: strikes decay after 10 min, promotion after a quiet 10 min', function()
  local W = kmock.new{ms_per_frame = 100000}
  local m = W.load(counter('runner', {ticks = 1}))
  W.cost.runner = 6
  W.run(2)                                   -- two slow calls ...
  W.cost.runner = 0
  W.run(7)                                   -- ... 700 s pass ...
  W.cost.runner = 6
  W.run(1)                                   -- ... a third one: the first two expired
  T.eq(#W.find_events('KERNEL_SLOW'), 0)
  W.run(2)
  T.eq(#W.find_events('KERNEL_SLOW'), 1)
  T.eq(W.state().k.slow, {'runner'})
  W.cost.runner = 0
  W.run(20)                                  -- 2,000 s quiet: x2 -> x1
  T.eq(W.state().k.slow, {})
  local n = #m.runs
  W.run(5)
  T.eq(#m.runs, n + 5)
end)

-- review F3: an insane citizen is not a hostile once include_insane is passed
T.test('insane citizens: isCitizen(u, true), isDanger, getCitizens', function()
  local W = kmock.new{units = {{id = 1, citizen = true, pos = {5, 5, 100}},
                               {id = 2, citizen = true, insane = true, pos = {6, 5, 100}},
                               {id = 3, resident = true, pos = {7, 5, 100}}}}
  local U = dfhack.units
  local mad = W.unit(2)
  T.eq({U.isCitizen(mad), U.isCitizen(mad, true), U.isDanger(mad), U.isSane(mad), U.isCrazed(mad)},
       {false, true, true, false, true})
  T.eq({U.isResident(W.unit(3)), U.isCitizen(W.unit(3))}, {true, false})
  T.eq(#U.getCitizens(), 2)
  T.eq(#U.getCitizens(true), 1)
  T.eq(#U.getCitizens(false, true), 3)
  local hostile = 0
  for _, u in ipairs(df.global.world.units.active) do
    if U.isDanger(u) and not U.isCitizen(u, true) and not U.isResident(u, true) then hostile = hostile + 1 end
  end
  T.eq(hostile, 0)
end)

T.test('inbox: audit only from follow/test; squad_leader belongs to military', function()
  local W = kmock.new{}
  W.load({name = 'readiness', every = {ticks = 33600}, verbs = {audit = function() return true, 'ok' end}})
  local args = {snap = 'c1', ok = true, fails = {}, min_traps = 30, bypass = false, refuge_sep = true,
                civ_sep = true, caverns = true}
  T.eq(W.inbox('audit', args, {by = 'llm'}).ok, false)
  T.eq(W.inbox('audit', args, {by = 'follow'}).ok, true)
  local mil = {name = 'military', every = {ticks = 3600}}
  function mil.lead(K) return K.act.squad_leader(1, 42) end
  W.load(mil)
  T.eq({W.K.call('military', 'lead')}, {true, true})
  T.eq(W.find_acts('squad_leader')[1].args[2], 42)
end)

T.test('calendar: season and year events, absolute ticks', function()
  local W = kmock.new{year = 3, ytick = 403200 - 5}
  local before = W.K.now().tick
  W.run(10, {skip = 9})
  T.eq(W.K.now().year, 4)
  T.eq(W.K.now().tick, before + 10)
  T.eq(W.find_events('YEAR_REVIEW')[1].d.year, 3)
  T.eq(W.find_events('SEASON')[1].d.season, 0)
end)

T.test('fake units and burrows', function()
  local W = kmock.new{units = {{id = 1, citizen = true, pos = {5, 5, 100}},
                               {id = 2, invader = true, pos = {40, 5, 100}},
                               {id = 3, invader = true, hidden = true, pos = {41, 5, 100}},
                               {id = 4, fb = true, pos = {1, 1, 90}}}}
  T.eq(#dfhack.units.getCitizens(), 1)
  local vis = 0
  for _, u in ipairs(df.global.world.units.active) do
    if dfhack.units.isDanger(u) and dfhack.units.isVisible(u) and not dfhack.units.isHidden(u) then vis = vis + 1 end
  end
  T.eq(vis, 2)
  T.ok(dfhack.units.isGreatDanger(W.unit(4)))
  local b = W.burrow('Kern+', {0, 0, 95, 20, 20, 105})
  T.ok(dfhack.burrows.isAssignedTile(dfhack.burrows.findByName('Kern+'), W.unit(1).pos))
  T.ok(not dfhack.burrows.isAssignedTile(b, W.unit(2).pos))
  W.kill(1)
  T.eq(#dfhack.units.getCitizens(), 0)
  T.eq(W.unit(1).flags2.killed, true)
  T.eq(W.unit(2).flags1.caged, false)
  W.move(2, 7, 8, 9)
  T.eq({dfhack.units.getPosition(W.unit(2))}, {7, 8, 9})
  local view = W.unit(2).flags1
  T.raises(function() view['caged'] = true end, 'read%-only')
  T.eq(df.unit.find(2).id, 2)
end)

T.done()
