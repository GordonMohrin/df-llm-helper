-- WP6 readiness: levels R0-R3 (DESIGN §5.4), the audit verb, the pop cap through act.popcap only
-- (freeze on demotion, frozen outside PEACE, inbox lowering), audit snapshot requests, state shape.
-- k_mock (strict) with sense + gate (WP5), military (WP6) and fake economy/snapshot/runner modules.
local T = require('testlib')
local X = require('wp6_world')
local json = require('dfllm.util.json')

local NOW0 = 3 * 403200 + 1000                       -- siege_world starts at year 3, ytick 1000
local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}   -- cv 13 per soldier

local function plan(ceiling, extra)
  local p = {v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
             policy = {option = 'A', pop_ceiling = ceiling or 55, beauty = 'used_rooms'}}
  for k, v in pairs(extra or {}) do p[k] = v end
  return p
end

local function drill_rec(tick, pass)
  return {v = 2, streak_fail = pass == 0 and 1 or 0,
          last = {{tick = tick, pass = pass or 1, raised = 300, worn = 95, outside = 0, dbl = 0, fails = {}}}}
end

local AUDIT_OK = {ok = true, fails = {}, min_traps = 35, bypass = false, refuge_sep = true,
                  civ_sep = true, caverns = true}
-- an audit for a fresh snapshot exported this boot (CONTRACTS §13 R6: readiness refuses others)
local function audit(W, over)
  local a = {}
  for k, v in pairs(AUDIT_OK) do a[k] = v end
  for k, v in pairs(over or {}) do a[k] = v end
  return X.audit(W, a)
end

-- opts: n citizens, drill = tick (passed drill) | false, plan, stock, decisions, mods (extra), skills
local function world(opts)
  opts = opts or {}
  local units = X.citizens(opts.n or 50, 1, {skills = opts.skills or SKILLS})
  local persist = {}
  if opts.drill then persist.drill = drill_rec(opts.drill, opts.drill_pass) end
  local W = X.world{units = units, persist = persist, manifest = opts.manifest, tiefe = opts.tiefe}
  for k, v in pairs(opts.decisions or {}) do W.K.cfg.decisions[k] = v end
  if opts.plan then W.set_plan(opts.plan) end
  local snap = X.snapshot()
  local runner = X.runner(nil)
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.econ, W.snap, W.runner = X.economy(opts.stock), snap, runner
  X.load(W, {'military', 'readiness'}, {W.econ, snap, runner}, {'sense', 'gate'})
  return W
end
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end
local function ready(W) return W.state().ready end
local function lvl(W) return X.call(W, 'readiness', 'level') end
local function caps(W)
  local r = {}
  for _, a in ipairs(X.acts(W, 'popcap')) do r[#r + 1] = a.args[1] end
  return r
end
local function has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end

---------------------------------------------------------------- R0 / R1
T.test('R0 at boot: max-pop 55 through act.popcap once, POPCAP event, audit is the first blocker', function()
  local W = world()
  day(W, 2)
  T.eq(lvl(W), 0)
  T.eq(caps(W), {55})
  local pc = W.find_events('POPCAP')
  T.eq(#pc, 1)
  T.eq(pc[1].d, {cap = 55, why = 'R0'})
  T.eq(ready(W).fail[1], 'audit')
  T.eq(W.state().pop.cap, 55)
  T.eq(W.state().pop.gate_cap, 55)
  for _, a in ipairs(W.acts) do T.ok(a.by ~= 'readiness' or a.fn == 'popcap', 'readiness writes only popcap') end
  T.eq(#W.commands, 0, 'no direct commands')
end)

T.test('R1: a passed audit, Kern+ and Tiefe+, outer+inner bridges with 2 linked levers each', function()
  local W = world()
  day(W)
  local r = audit(W)
  T.ok(r.ok, r.msg)
  T.eq(r.data, {lvl = 1})
  T.eq(lvl(W), 1)
  local rc = W.find_events('READY_CHANGE')
  T.eq(#rc, 1)
  T.eq({rc[1].d.from, rc[1].d.to}, {0, 1})
  local au = W.find_events('AUDIT')
  T.eq(au[1].d, {ok = 1, fails = {}, min_traps = 35})
  T.eq(caps(W), {55}, 'R1 keeps 55')
  day(W)
  local s = ready(W)
  T.eq(s.audit, {ok = 1, age = s.audit.age, min_traps = 35})
  T.ok(s.audit.age >= 1200 and s.audit.age <= 1300)
  T.ok(has(s.fail, 'drill'), 'R2 blockers listed')
end)

T.test('R1 blockers: audit flags, stale audit, missing Tiefe+, unlinked lever, no outer bridge', function()
  local W = world()
  day(W)
  audit(W, {ok = false, bypass = true, civ_sep = false, fails = {'bypass: 5-tile path'}})
  T.eq(lvl(W), 0)
  local f = X.call(W, 'readiness', 'level') == 0 and ready(W).fail
  day(W)
  f = ready(W).fail
  T.ok(has(f, 'audit_fail') and has(f, 'bypass') and has(f, 'civ_sep'), T.show(f))
  audit(W)
  T.eq(lvl(W), 1)
  W.run(100800 + 1200, {skip = 9})
  W.state()
  T.eq(lvl(W), 0, 'an audit counts for one season')
  T.ok(has(ready(W).fail, 'audit_old'))
  -- no Tiefe+ burrow
  local W2 = world{tiefe = false}
  day(W2)
  audit(W2)
  T.eq(lvl(W2), 0)
  T.ok(has(ready(W2).fail, 'no_refuge'))
  -- an unlinked B1 lever
  local W3 = world()
  W3.buildings[21].linked_mechanisms = require('dfllm.util.k_mock').vec{}
  day(W3)
  audit(W3)
  T.eq(ready(W3).fail, {'levers:B1'})
  -- no outer bridge in the manifest
  local man = X.S.manifest()
  man.bridges.O1 = nil
  local W4 = world{manifest = man}
  day(W4)
  audit(W4)
  T.eq(ready(W4).fail, {'no_outer'})
end)

---------------------------------------------------------------- R2 / R3 and caps
T.test('R2: drill, army share, >= 8 soldiers, cv, traps, stock; cap 75 only if the plan ceiling allows', function()
  local W = world{drill = NOW0 - 500}
  day(W)
  audit(W)
  day(W)
  T.eq(lvl(W), 2, T.show(ready(W).fail))
  T.eq(caps(W), {55}, 'plan ceiling 55 keeps the cap')
  T.eq(W.state().pop.gate_cap, 55)
  W.set_plan(plan(75))
  day(W)
  T.eq(caps(W), {55, 75})
  T.eq(W.find_events('POPCAP')[2].d, {cap = 75, why = 'R2'})
  T.eq(ready(W).fail, {'option_a', 'metal<20%'})
  T.ok(ready(W).drill_age >= 0)
  T.eq(X.call(W, 'readiness', 'cap'), 75)
end)

T.test('R2 blockers are reported one by one', function()
  local W = world{drill = NOW0 - 500, n = 30, skills = {AXE = 2}, stock = {drink_d = 100, food_d = 30, meals = 2}}
  day(W)
  audit(W, {min_traps = 22})
  day(W)
  T.eq(lvl(W), 1)
  T.eq(ready(W).fail, {'soldiers<8', 'cv<12', 'traps<30', 'food<60', 'drink<170'})
  local W2 = world{n = 50}
  day(W2)
  audit(W2)
  W2.econ.stock = nil
  day(W2, 2)                                         -- K.view() lags one compose
  T.eq(ready(W2).fail, {'drill', 'food?', 'drink?'})
end)

T.test('demotion: max-pop frozen at the current population, never cut below it', function()
  local W = world{drill = NOW0 - 500, n = 60, plan = plan(75)}
  day(W)
  audit(W)
  day(W)
  T.eq(lvl(W), 2, T.show(ready(W).fail))
  T.eq(caps(W)[#caps(W)], 75)
  local d = W.K.persist.get('drill')                 -- the drill gets old
  d.last[1].tick = NOW0 - 200000
  day(W)
  T.eq(lvl(W), 1)
  T.ok(has(ready(W).fail, 'drill_old'))
  T.eq(caps(W)[#caps(W)], 60, 'frozen at 60 citizens')
  local pc = W.find_events('POPCAP')
  T.eq(pc[#pc].d, {cap = 60, why = 'freeze'})
  for i = 1, 5 do W.kill(i + 20) end                 -- 55 citizens left: the cap follows down to 55
  day(W, 2)
  T.eq(caps(W)[#caps(W)], 55)
end)

T.test('growth frozen outside PEACE; raised when PEACE returns', function()
  local W = world{plan = plan(75)}
  day(W)
  audit(W)
  day(W)
  W.K.persist.set('drill', drill_rec(W.K.now().tick - 100))
  W.K.set_mode('ALERT', 'test')
  T.eq(lvl(W), 2)
  T.eq(caps(W), {55}, 'no raise in ALERT')
  W.K.set_mode('PEACE', 'test')
  T.eq(caps(W), {55, 75})
end)

T.test('after a siege R2 needs a new drill (frozen until re-drill)', function()
  local W = world{drill = NOW0 - 500, plan = plan(75)}
  day(W)
  audit(W)
  day(W)
  T.eq(lvl(W), 2)
  W.K.set_mode('SIEGE', 'test')
  W.K.set_mode('RECOVERY', 'test')
  W.K.set_mode('PEACE', 'test')
  T.eq(lvl(W), 1)
  T.ok(has(ready(W).fail, 'redrill'))
  T.eq(caps(W)[#caps(W)], 55, 'frozen at the population (50 < 55): back to 55')
  W.K.persist.set('drill', drill_rec(W.K.now().tick))
  audit(W)
  T.eq(lvl(W), 2)
  T.eq(caps(W)[#caps(W)], 75)
end)

T.test('popcap.lower: lowers the ceiling only; a new plan clears the inbox ceiling', function()
  local W = world{drill = NOW0 - 500, plan = plan(75)}
  day(W)
  audit(W)
  day(W)
  T.eq(caps(W)[#caps(W)], 75)
  local r = W.inbox('popcap.lower', {cap = 60})
  T.ok(r.ok, r.msg)
  T.eq(r.data, {cap = 60})
  T.eq(W.state().pop.gate_cap, 60)
  r = W.inbox('popcap.lower', {cap = 70})
  T.ok(r.ok)
  T.eq(r.data, {cap = 60}, 'cannot raise')
  T.eq(W.inbox('popcap.lower', {cap = 300}).ok, false)
  T.eq(W.inbox('popcap.lower', {cap = 0}).data, {cap = 50}, 'frozen at the population, never 0')
  W.K.persist.get('plan')
  W.plan_file = plan(75)
  W.run(9, {skip = 9})
  W.inbox('plan.reload', {})
  day(W)
  T.eq(W.state().pop.gate_cap, 75)
  T.eq(caps(W)[#caps(W)], 75)
  local whys = {}
  for _, e in ipairs(W.find_events('POPCAP')) do whys[#whys + 1] = e.d.why end
  T.eq(whys, {'R0', 'R2', 'inbox', 'freeze', 'R2'})
end)

T.test('R3: D-01 = B and >= 20 % of soldiers in iron or steel; cap up to the plan ceiling', function()
  local W = world{drill = NOW0 - 500, plan = plan(90), decisions = {['D-01'] = 'B'}}
  day(W)
  audit(W)
  day(W)
  T.eq(lvl(W), 2)
  T.eq(ready(W).fail, {'metal<20%'})
  X.equip_all(W, {mat = 'INORGANIC:IRON'})
  day(W, 2)
  T.eq(lvl(W), 3)
  T.eq(ready(W).fail, {})
  T.eq(caps(W)[#caps(W)], 90)
  local W2 = world{drill = NOW0 - 500, plan = plan(90)}
  day(W2)
  audit(W2)
  X.equip_all(W2, {mat = 'INORGANIC:STEEL'})
  day(W2, 2)
  T.eq(lvl(W2), 2)
  T.eq(ready(W2).fail, {'option_a'})
  T.eq(caps(W2)[#caps(W2)], 75, 'option A: R2 ceiling = siege trigger 80 - 5')
end)

T.test('stock hysteresis: R2 holds down to 90 % of the minimum', function()
  local W = world{drill = NOW0 - 500, stock = {drink_d = 175, food_d = 65, meals = 5}}
  day(W)
  audit(W)
  day(W)
  T.eq(lvl(W), 2)
  W.econ.stock = {drink_d = 160, food_d = 55, meals = 5}
  day(W, 2)
  T.eq(lvl(W), 2, 'within 90 %')
  W.econ.stock = {drink_d = 150, food_d = 55, meals = 5}
  day(W, 2)
  T.eq(lvl(W), 1)
  W.econ.stock = {drink_d = 165, food_d = 61, meals = 5}
  day(W, 2)
  T.eq(lvl(W), 1, 'R2 again only at the full minimum')
end)

---------------------------------------------------------------- audit requests
T.test('audit snapshots: manifest bbox, monthly, after defense stages (1 day gap), deferred in SIEGE', function()
  local W = world()
  day(W)
  T.eq(#W.snap.exports, 1)
  T.eq(W.snap.exports[1].opts, {purpose = 'audit', bbox = {40, 2, 3, 78, 78, 12}})
  day(W, 27)
  T.eq(#W.snap.exports, 1, 'monthly')
  day(W, 2)
  T.eq(#W.snap.exports, 2)
  X.call(W, 'runner', 'emit', 'PROJECT_STAGE', {proj = 'p1', stage = 's2.build', pct = 50, defense = 1})
  W.run(18, {skip = 9})
  T.eq(#W.snap.exports, 3, 'defense stage: re-audit')
  X.call(W, 'runner', 'emit', 'PROJECT_STAGE', {proj = 'p1', stage = 's3.build', pct = 60, defense = 1})
  X.call(W, 'runner', 'emit', 'PROJECT_STAGE', {proj = 'p1', stage = 's3.zone', pct = 70, defense = 0})
  W.run(18, {skip = 9})
  T.eq(#W.snap.exports, 3, 'not twice a day')
  day(W, 2)
  T.eq(#W.snap.exports, 4, 'the deferred request lands a day later')
  W.K.set_mode('SIEGE', 'test')
  X.call(W, 'runner', 'emit', 'PROJECT_DONE', {proj = 'p1', tpl = 'fortcore'})
  day(W, 2)
  T.eq(#W.snap.exports, 4, 'no audit snapshot in SIEGE')
  W.K.set_mode('RECOVERY', 'test')
  day(W)
  T.eq(#W.snap.exports, 5, 'requested once the fort is quiet')
end)

T.test('audit verb rejects bad args; ready state is schema-shaped', function()
  local W = world()
  day(W)
  T.eq(W.inbox('audit', {snap = 's', ok = 'yes'}).ok, false)
  T.eq(W.inbox('audit', {snap = 's', ok = true, fails = {}, min_traps = 1.5, bypass = false, refuge_sep = true,
                         civ_sep = true, caverns = true}).ok, false)
  local long = {}
  for i = 1, 20 do long[i] = string.rep('x', 100) .. i end
  T.ok(audit(W, {ok = false, fails = long}).ok)
  local s = W.state()
  local r = s.ready
  for _, k in ipairs({'lvl', 'worn', 'cv', 'drill_age'}) do T.ok(math.type(r[k]) == 'integer', k) end
  T.ok(#r.fail <= 8)
  for _, f in ipairs(r.fail) do T.ok(#f <= 24, f) end
  T.eq(r.drill_age, -1)
  T.ok(json.encode(s):len() < 4096)
  local p = json.decode(W.persist_raw['dfllm.m.readiness'])
  T.eq(p.v, 2)
  T.ok(#p.audit.fails <= 8 and #p.audit.fails[1] <= 60)
  local ev = W.find_events('AUDIT')
  T.ok(#ev[#ev].d.fails <= 8)
end)

T.done()
