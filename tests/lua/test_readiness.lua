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
  local runner = X.runner('P5')            -- live L6: military creates squads only in a known phase
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.econ, W.snap, W.runner = X.economy(opts.stock), snap, runner
  local extra = {W.econ, snap, runner}
  if opts.seal then extra[#extra + 1] = opts.seal end
  X.load(W, {'military', 'readiness'}, extra, {'sense', 'gate'})
  return W
end

-- FR-65: a fake seal with the last entrance check (CONTRACTS §7 seal.entrance_doors)
local function seal_fake(x)
  local M = {name = 'seal', every = {ticks = 600}, x = x}
  function M.entrance_doors(K) return M.x end
  return M
end
local LEAKY = {tick = 1, sealed = 0, routes = 3, doors = {{id = 9, pos = {74, 70, 117}}},
               open = {{pos = {55, 62, 117}, kind = 'stair_updown'}, {pos = {61, 55, 117}, kind = 'floor'}}}
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

T.test('Run 11: an explore shaft open to a cavern (runner.cavern_open) is R0 caverns until its plug wall stands', function()
  local W = world()
  local open = 1
  W.runner.cavern_open = function(K) return open, open > 0 and {{60, 61, 117, 107}} or {} end
  day(W)
  audit(W)                                         -- the audit itself is clean (the shaft lies outside its box)
  T.eq(lvl(W), 0)
  T.ok(has(ready(W).fail, 'caverns'), T.show(ready(W).fail))
  T.eq(ready(W).audit.ok, 1, 'the audit stays the audit')
  open = 0
  X.call(W, 'runner', 'emit', 'CAVERN_PLUG', {phase = 'done', proj = 'e1'})   -- the plug stands: looked at once
  W.frame(1)
  T.eq(lvl(W), 1)
  T.ok(not has(ready(W).fail, 'caverns'))
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
  T.eq(W.snap.exports[1].opts, {purpose = 'audit', bbox = {40, 0, 3, 78, 86, 12}})
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
  -- live L2: a project still digging past the manifest box widens the box (no cut-off corridor = bypass)
  function W.runner.bboxes(K) return {{60, 70, 5, 66, 95, 5}} end
  X.call(W, 'runner', 'emit', 'PROJECT_STAGE', {proj = 'p2', stage = 's2.build', pct = 50, defense = 1})
  day(W, 2)
  T.eq(W.snap.exports[#W.snap.exports].opts.bbox, {40, 0, 3, 78, 111, 12})
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

---------------------------------------------------------------- FR-65 siege readiness gate
local function unready(W) return W.find_events('SIEGE_UNREADY') end

T.test('FR-65 SIEGE_UNREADY (A): R0 in PEACE names blockers, ways in without door or bridge, traps; monthly', function()
  local man = X.S.manifest()
  man.bridges.O1 = nil
  local W = world{manifest = man, seal = seal_fake(LEAKY)}
  day(W)
  T.eq(#unready(W), 0, 'not in the first 2 days after a load')
  day(W, 2)
  local u = unready(W)
  T.eq(#u, 1)
  T.eq(u[1].cls, 'A')
  T.eq(u[1].d, {fails = {'audit', 'no_outer'}, afails = {}, routes = 3, open = 2,
                ents = {'55,62,117 stair_updown', '61,55,117 floor'}, traps = -1, age = -1})
  T.eq(u[1].msg, 'siege unready (R0: audit, no_outer); 2 of 3 ways in without door or bridge: '
                 .. '55,62,117 stair_updown, 61,55,117 floor; traps ? (no audit)')
  local r = ready(W)
  T.eq({r.open, r.ents}, {2, {'55,62,117 stair_updown', '61,55,117 floor'}})
  -- unchanged: again only after a game month AND 30 real minutes (a month is 75 s at timestream speed)
  day(W, 29)
  T.eq(#unready(W), 1, 'a month, but not 30 real minutes')
  W.ms = W.ms + 1800 * 1000
  day(W)
  T.eq(#unready(W), 2, 'monthly while R0 fails')
  -- a reload keeps the cadence record (persist m.readiness): no repeat at boot
  for i, e in ipairs(W.entries) do if e.name == 'readiness' then table.remove(W.entries, i) end end
  W.mods.readiness = nil
  package.loaded['dfllm.readiness'] = nil
  W.load(require('dfllm.readiness'))
  day(W, 3)
  T.eq(#unready(W), 2, 'no repeat after a reload')
  -- worse (a failed audit: new blockers): after a month and only 10 real minutes
  audit(W, {ok = false, bypass = true, min_traps = 0, fails = {'bypass: edge->Z3/Z4 avoids the trap hall'}})
  T.eq(#unready(W), 2, 'news waits for the month too')
  day(W, 27)
  W.ms = W.ms + 600 * 1000
  day(W)
  u = unready(W)
  T.eq(#u, 3)
  T.eq({u[3].d.fails, u[3].d.traps, u[3].d.afails}, {{'audit_fail', 'bypass', 'no_outer'}, 0,
                                                      {'bypass: edge->Z3/Z4 avoids the trap hall'}})
  T.ok(u[3].msg:find('; traps 0$') ~= nil, u[3].msg)
  -- PEACE only; due again at once when PEACE returns
  W.K.set_mode('ALERT', 'test')
  W.ms = W.ms + 3600 * 1000
  day(W, 30)
  T.eq(#unready(W), 3, 'not outside PEACE')
  W.K.set_mode('PEACE', 'test')
  T.eq(#unready(W), 4)
  -- no entrance check yet (seal missing or not run): said so
  local W3 = world()
  day(W3, 3)
  u = unready(W3)
  T.eq({#u, u[1].d.routes, u[1].d.open, u[1].d.fails}, {1, -1, -1, {'audit'}})
  T.ok(u[1].msg:find('entrances not checked yet', 1, true), u[1].msg)
  T.eq(ready(W3).open, -1)
  T.eq(ready(W3).ents, nil)
end)

T.test('FR-65: no SIEGE_UNREADY at R1; R0 again (audit_old) is a new episode; a sealed fort says so', function()
  local W = world{seal = seal_fake(LEAKY)}
  day(W)
  audit(W)
  T.eq(lvl(W), 1)
  W.ms = W.ms + 3600 * 1000
  day(W, 40)
  T.eq(#unready(W), 0, 'R1: quiet')
  T.eq(ready(W).open, 2, 'the open ways in are still published')
  W.ms = W.ms + 3600 * 1000
  day(W, 60)
  local u = unready(W)
  T.eq(#u, 1)
  T.eq(u[1].d.fails, {'audit_old'})
  T.ok(u[1].d.age > 100800, 'audit age ' .. u[1].d.age)
  local W2 = world{seal = seal_fake{tick = 1, sealed = 1, routes = 0, doors = {}, open = {}}}
  day(W2, 3)
  T.ok(unready(W2)[1].msg:find('0 ways in, all with a door or bridge', 1, true), unready(W2)[1].msg)
end)

T.test('Run 10: the last audit names a bypass with its wall: R0, SIEGE_UNREADY and ready.route name it and the fix ' ..
       '(seal at=audit); a finding without a wall tile says so; a passed audit clears the route', function()
  local W = world{seal = seal_fake{tick = 1, sealed = 1, routes = 1, doors = {}, open = {}}}
  day(W)
  local fails = {'bypass: wall 100,127,122 floor -> 139,128,117', 'refuge: on the attack path, wall 100,127,122 floor',
                 'stairs: the civilian stair is on the attack path to Z3'}
  audit(W, {ok = false, bypass = true, refuge_sep = false, min_traps = 35, fails = fails})
  day(W, 3)
  T.eq(lvl(W), 0)
  local r = ready(W)
  T.ok(has(r.fail, 'bypass') and has(r.fail, 'refuge_sep'), table.concat(r.fail, ','))
  -- old code: no route in the state, SIEGE_UNREADY said only 'bypass'
  T.eq(r.route, 'bypass: wall 100,127,122 floor -> 139,128,117')
  local u = unready(W)
  T.eq(#u, 1)
  T.ok(u[1].msg:find('; bypass: wall 100,127,122 floor -> 139,128,117 (fix: seal at=audit); ', 1, true), u[1].msg)
  T.ok(u[1].msg:find('; traps 35$') ~= nil, u[1].msg)
  T.ok(#u[1].msg <= 200, #u[1].msg)
  T.eq(u[1].d.afails, {fails[1], fails[2], fails[3]})
  -- the refuge finding alone
  audit(W, {ok = false, bypass = false, refuge_sep = false, min_traps = 35, fails = {fails[2]}})
  T.eq(ready(W).route, 'refuge: on the attack path, wall 100,127,122 floor')
  -- no wall tile on the route (stairs, doors): the finding and where to look
  audit(W, {ok = false, bypass = true, min_traps = 0, fails = {'bypass: edge->Z3/Z4 avoids the trap hall (reaches 1,2,3)'}})
  W.ms = W.ms + 3600 * 1000
  day(W, 31)
  u = unready(W)
  T.ok(u[#u].msg:find('bypass: edge->Z3/Z4 avoids the trap hall (reaches 1,2,3) (no wall tile: inspect entrances)', 1,
                      true), u[#u].msg)
  -- a passed audit: R1, no route
  audit(W)
  T.eq(lvl(W), 1)
  T.eq(ready(W).route, nil)
end)

T.done()
