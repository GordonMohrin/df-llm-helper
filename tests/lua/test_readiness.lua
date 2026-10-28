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
  for _, m in ipairs(opts.extra or {}) do extra[#extra + 1] = m end
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
  -- Run 11 (c1a14676): the daily shaft check finds a stalled explore open to a cavern lake: R0 at once, not next day
  open = 1
  X.call(W, 'runner', 'emit', 'CAVERN_PLUG', {phase = 'queued', proj = 'c1a14676', state = 'stalled'})
  W.frame(1)
  T.eq(lvl(W), 0)
  T.ok(has(ready(W).fail, 'caverns'), T.show(ready(W).fail))
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

T.test('BUG-030 rebuild policy: a bridge the perimeter keeper no longer rebuilds (seal.lost_gates) is the R0 blocker ' ..
       'lost:<B> in place of bridge:<B> and levers:<B> (the fix is the player\'s answer, not a fortcore piece)', function()
  -- old code: bridge:O1, levers:O1 (brief: "build the missing fortcore pieces") while O1 is held for the player
  local function gone(W)
    W.buildings[1] = nil                                        -- O1 (siege_world S.BRIDGE_ID) is not on the map
    local v = df.global.world.buildings.other.BRIDGE
    for i = #v - 1, 0, -1 do if v[i].id == 1 then v:erase(i) end end
    for _, id in ipairs({11, 12}) do W.buildings[id].linked_mechanisms = require('dfllm.util.k_mock').vec{} end
  end
  local s = seal_fake({tick = 1, sealed = 1, routes = 1, doors = {}, open = {}})
  s.lost = {}
  function s.lost_gates(K) return s.lost end
  local W = world{seal = s}
  gone(W)
  day(W)
  audit(W)
  T.eq(ready(W).fail, {'bridge:O1', 'levers:O1'})
  s.lost = {O1 = {n = 2, bd = 2, since = 5, asked = 2}}
  day(W)
  T.eq(lvl(W), 0)
  T.eq(ready(W).fail, {'lost:O1'})
end)

T.test('BUG-049 (Run 13 y525: the refuge was reachable and occupied): seal.refuge_trust keeps R0 refuge_trust while ' ..
       'the refuge is exposed, has no hatch on its stair head or its separation answer is stale; hostiles inside and ' ..
       'the audit have their own handling; readiness.refuge_audit tells seal what the last audit said', function()
  -- old code: no such blocker (only the audit's refuge_sep)
  local s = seal_fake({tick = 1, sealed = 1, routes = 1, doors = {}, open = {}})
  s.trust = {ok = false, sep = 0, why = {'exposed: open to 1 entrance 20,10,9 stair_up (5 steps)'}}
  function s.refuge_trust(K) return s.trust end
  local W = world{seal = s}
  day(W)
  audit(W)
  T.eq(lvl(W), 0)
  T.eq(ready(W).fail, {'refuge_trust'})
  s.trust = {ok = false, sep = 1, hatch = {pos = {6, 6, 6}, state = 'missing'}, why = {'no hatch at 6,6,6'}}
  day(W)
  T.eq(ready(W).fail, {'refuge_trust'})
  s.trust = {ok = false, sep = 1, why = {'separation not checked for 40 days'}}
  day(W)
  T.eq(ready(W).fail, {'refuge_trust'})
  for _, why in ipairs({'hostile inside at 7,6,5', 'audit: refuge_sep failed 300 t ago',
                        'unverified: its separation is not checked yet'}) do
    s.trust = {ok = false, sep = 1, why = {why}}
    day(W)
    T.eq(lvl(W), 1, why)
  end
  s.trust = {ok = true, sep = 1, why = {}}
  day(W)
  T.eq(lvl(W), 1)
  -- the audit's own word for seal
  local ra = X.call(W, 'readiness', 'refuge_audit')
  T.eq(ra.sep, 1)
  T.ok(ra.age >= 0)
  audit(W, {ok = false, refuge_sep = false, fails = {'refuge: reachable'}})
  T.eq(X.call(W, 'readiness', 'refuge_audit').sep, 0)
  local W0 = world()
  T.eq(X.call(W0, 'readiness', 'refuge_audit'), nil, 'no audit yet')
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
T.test('audit snapshots: the default audit box, monthly, after defense stages (1 day gap), deferred in SIEGE', function()
  local W = world()
  day(W)
  T.eq(#W.snap.exports, 1)
  -- BUG-043: no box of readiness' own (it grew to 370,414 tiles with the explores): snapshot's default audit box
  -- (tests/lua/test_snapshot_box.lua: the manifest geometry, runner.boxes, explore shafts as columns)
  T.eq(W.snap.exports[1].opts, {purpose = 'audit', by = 'readiness'})
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

-- BUG-043 (Run 11 y479: 'readiness: audit snapshot not exported: bbox has 308132 tiles > 250000' in kern.log only):
-- the refusal stays in the state for status/brief until an audit is stored again
T.test('BUG-043: a refused audit request stays in ready.audit.why until an audit is stored', function()
  local W = world()
  local why = 'bbox 149x113x20 = 336740 tiles > 300000 at margin 0,0,0 (x 43-191 y 36-148 z 128-147; stretched ...'
  local real = W.snap.export
  function W.snap.export(K, o) return false, why end
  day(W)
  T.eq(ready(W).audit.why, why:sub(1, 80))
  T.ok(#W.find_events('AUDIT') == 0)
  W.snap.export = real
  audit(W)
  W.state()
  T.eq(ready(W).audit.why, nil, 'cleared by the stored audit')
end)

-- BUG-043: an audit proves nothing about what its snapshot did not cover: an explicit box that left fort pieces out
-- (SNAPSHOT_READY out/first) makes the audit a fail with a coverage line; the default box's margin and shafts are named
T.test('BUG-043: an audit of a snapshot that left fort pieces out fails (coverage); ready.audit.cov', function()
  local W = world()
  day(W)
  local n = 0
  function W.snap.export(K, o)
    n = n + 1
    local id = 'cov' .. n
    local d = {id = id, path = 'snap/' .. id .. '.json', purpose = 'audit'}
    if n == 1 then d.out, d.first = 2, 'explore c1a14b1a6cc8ca4801' else d.margin, d.cols = '8,8,1', 2 end
    K.emit('SNAPSHOT_READY', 'C', 'snapshot ' .. id, d)
    return true, id
  end
  local r = audit(W)
  T.eq(r.ok, true, r.msg)
  local ev = W.find_events('AUDIT')
  T.eq(ev[#ev].d.ok, 0, 'not ok although bp.topo.audit said ok')
  T.eq(ev[#ev].d.fails[1], 'coverage: 2 pieces left out (explore c1a14b1a6cc8ca4801)')
  W.state()
  T.eq(ready(W).audit.cov, 'out 2: explore c1a14b1a6cc8ca4801')
  T.ok(has(ready(W).fail, 'audit_fail'), T.show(ready(W).fail))
  audit(W)
  W.state()
  T.eq(ready(W).audit.cov, 'margin 8,8,1, 2 shafts')
  T.ok(not has(ready(W).fail, 'audit_fail'), 'a full default box: the audit counts')
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

local SEALED = {tick = 1, sealed = 1, routes = 1, doors = {{id = 9, pos = {74, 70, 117}}}, open = {}}

T.test('FR-65 SIEGE_UNREADY (A): R0 in PEACE names blockers, ways in without door or bridge, traps; monthly while ' ..
       'the fort is closed (an open perimeter repeats faster: FR-70, tests/lua/test_open_perimeter.lua)', function()
  local man = X.S.manifest()
  man.bridges.O1 = nil
  local W = world{manifest = man, seal = seal_fake(SEALED)}
  day(W)
  T.eq(#unready(W), 0, 'not in the first 2 days after a load')
  day(W, 2)
  local u = unready(W)
  T.eq(#u, 1)
  T.eq(u[1].cls, 'A')
  T.eq(u[1].d, {fails = {'audit', 'no_outer'}, afails = {}, routes = 1, open = 0, ents = {}, traps = -1, age = -1})
  T.eq(u[1].msg, 'siege unready (R0: audit, no_outer); 1 way in, all with a door or bridge; traps ? (no audit)')
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
  -- the ways in without door or bridge are listed (FR-70: and R0 by themselves, see test_open_perimeter.lua)
  local W4 = world{manifest = man, seal = seal_fake(LEAKY)}
  day(W4, 3)
  u = unready(W4)
  T.eq(#u, 1)
  T.eq({u[1].d.open, u[1].d.ents, u[1].d.routes}, {2, {'55,62,117 stair_updown', '61,55,117 floor'}, 3})
  T.eq(u[1].msg, 'siege unready (R0: open_perimeter, audit, no_outer); perimeter OPEN 2 d (2 ways in); 2 of 3 ways in '
                 .. 'without door or bridge: 55,62,117 stair_updown, 61,55,117 floor; traps ? (no audit)')
  T.eq({u[1].d.pd, u[1].d.pw, u[1].d.fails}, {2, '2 ways in', {'open_perimeter', 'audit', 'no_outer'}})
  local r = ready(W4)
  T.eq({r.open, r.ents}, {2, {'55,62,117 stair_updown', '61,55,117 floor'}})
end)

T.test('FR-65: no SIEGE_UNREADY at R1; R0 again (audit_old) is a new episode; a sealed fort says so', function()
  local W = world{seal = seal_fake(SEALED)}
  day(W)
  audit(W)
  T.eq(lvl(W), 1)
  W.ms = W.ms + 3600 * 1000
  day(W, 40)
  T.eq(#unready(W), 0, 'R1: quiet')
  T.eq(ready(W).open, 0, 'the entrance check is still published')
  W.ms = W.ms + 3600 * 1000
  day(W, 60)
  local u = unready(W)
  T.eq(#u, 1)
  T.eq(u[1].d.fails, {'audit_old'})
  T.ok(u[1].d.age > 100800, 'audit age ' .. u[1].d.age)
  local W2 = world{seal = seal_fake{tick = 1, sealed = 1, routes = 0, doors = {}, open = {}}}
  day(W2, 3)
  T.ok(unready(W2)[1].msg:find('0 ways in, all with a door or bridge', 1, true), unready(W2)[1].msg)
  -- FR-70: ways in without door or bridge are not R1 (they were "published" only): R0, open_perimeter
  local W3 = world{seal = seal_fake(LEAKY)}
  day(W3)
  audit(W3)
  T.eq(lvl(W3), 0)
  T.eq(ready(W3).fail[1], 'open_perimeter')
end)

T.test('Run 11 (siege 8: Tiefe+ had no drink): a refuge without drink is the R0 blocker refuge_dry; SIEGE_UNREADY says ' ..
       'what to build; a well counts unless water says it is dry; a drink stock clears it', function()
  local sf = seal_fake{tick = 1, sealed = 1, routes = 0, doors = {}, open = {}}
  sf.rd = {name = 'Tiefe+', exists = true, drink = 0, need = 50, wells = 0, wet = false}
  function sf.refuge_drink(K) return sf.rd end
  -- water's state (refuge_ok: a wet well on a Tiefe+ tile); nil = the water module publishes nothing
  local wf = {name = 'water', every = {ticks = 1200}}
  function wf.state(K)
    if wf.ok == nil then return {} end
    return {water = {patients = 0, thirst_max = 0, hosp_ok = 1, refuge_ok = wf.ok, buckets_free = 0, hosp = 0, src = {}}}
  end
  local W = world{seal = sf, extra = {wf}}
  day(W)
  audit(W)
  T.eq(lvl(W), 0, 'old code: R1 (the refuge only had to exist)')
  T.eq(ready(W).fail, {'refuge_dry'})
  day(W, 2)
  local u = unready(W)
  T.eq(#u, 1)
  -- BUG-035 (Run 11: 13 wells, none in Tiefe+): the text says the refuge has no well of its own
  -- FR-69: the fix is the refuge drink store (was 'build a well/cistern or stock drink there')
  T.eq({u[1].d.fails, u[1].d.rdry}, {{'refuge_dry'},
       'Tiefe+ has no drink (drink 0<50, no well in Tiefe+): plan its drink store (bp sites refuge_drink)'})
  T.ok(u[1].msg:find('siege unready (R0: refuge_dry); Tiefe+ has no drink (drink 0<50, no well in Tiefe+): plan its ' ..
       'drink store (bp sites refuge_drink); 0 ways in, all with a door or bridge; traps 35', 1, true), u[1].msg)
  -- a well: counts, unless water's state says the refuge has no wet well
  sf.rd = {name = 'Tiefe+', exists = true, drink = 0, need = 50, wells = 1, wet = true}
  day(W)
  T.eq(lvl(W), 1, 'a well in the refuge')
  wf.ok = 0
  W.state()                                       -- the state readiness reads (K.view)
  day(W)
  T.eq({lvl(W), ready(W).fail}, {0, {'refuge_dry'}})
  T.eq(#unready(W) >= 1 and unready(W)[#unready(W)].d.rdry ~= nil, true)
  local R = W.mods.readiness.M
  local function rdry() return R.refuge_dry and tostring(R.refuge_dry(W.K)) or 'no readiness.refuge_dry' end
  T.ok(rdry():find('Tiefe+ has no drink (drink 0<50, its 1 well is dry)', 1, true), rdry())
  sf.rd = {name = 'Tiefe+', exists = true, drink = 0, need = 50, wells = 2, wet = true}
  day(W)
  T.ok(rdry():find('Tiefe+ has no drink (drink 0<50, its 2 wells are dry)', 1, true), rdry())
  wf.ok = 1
  W.state()                                       -- the state readiness reads (K.view)
  day(W)
  T.eq(lvl(W), 1, 'its well has water')
  -- a drink stock for every citizen clears it too
  wf.ok = 0
  sf.rd = {name = 'Tiefe+', exists = true, drink = 60, need = 50, wells = 1, wet = true}
  day(W)
  T.eq(lvl(W), 1)
  -- no answer from seal (missing, backed off, no audit yet): no blocker (fail-open)
  sf.rd = nil
  day(W)
  T.eq(lvl(W), 1)
end)

T.test('BUG-036 (Run 11 siege 9: 7 patients killed in their hospital beds outside the refuge): a hospital outside ' ..
       'Kern+ and Tiefe+ is the R0 blocker hospital_out; SIEGE_UNREADY names it and the fix; none outside or no water ' ..
       'state: no blocker', function()
  local sf = seal_fake{tick = 1, sealed = 1, routes = 0, doors = {}, open = {}}
  local wf = {name = 'water', every = {ticks = 1200}}
  function wf.state(K)
    if wf.out == nil then return {} end
    return {water = {patients = 0, thirst_max = 0, hosp_ok = 1, refuge_ok = 1, buckets_free = 0, hosp = 2, src = {},
                     hosp_out = wf.out}}
  end
  function wf.hospital_out(K)
    return {n = wf.out or 0, total = 2, kern = 'Kern+', refuge = 'Tiefe+',
            zones = {{id = 34, loc = 6, x = 115, y = 77, z = 144, tiles = 15, of = 15}}}
  end
  local W = world{seal = sf, extra = {wf}}
  day(W)
  audit(W)
  T.eq(lvl(W), 1, 'no water state: no blocker (fail-open)')
  wf.out = 1
  W.state()
  day(W)
  T.eq({lvl(W), ready(W).fail}, {0, {'hospital_out'}}, 'old code: R1')
  day(W, 2)
  local u = unready(W)
  T.eq(#u, 1)
  local want = 'the hospital lies outside Kern+/Tiefe+ (1 of 2 zones; zone 34 at 115,77,144): its patients cannot ' ..
               'walk to the refuge; move it into Tiefe+ next to accepted water'
  T.ok(tostring(u[1].d.hout):find(want, 1, true), tostring(u[1].d.hout))
  T.ok(u[1].msg:find('siege unready (R0: hospital_out); ' .. want, 1, true), u[1].msg)
  T.ok(#u[1].msg <= 200)
  wf.out = 0
  W.state()
  day(W)
  T.eq(lvl(W), 1, 'moved inside: the blocker goes')
end)

T.test('BUG-040 (Run 11 y453: "Tiefe+ has no drink" for months, nobody knew where Tiefe+ lies; the one wet well stood ' ..
       'in Kern+): refuge_dry names the refuge\'s bbox and z-levels and its nearest accepted water; hospital_out sends ' ..
       'the hospital into Kern+ next to that water when Tiefe+ has none of its own', function()
  local sf = seal_fake{tick = 1, sealed = 1, routes = 0, doors = {}, open = {}}
  sf.rd = {name = 'Tiefe+', exists = true, drink = 0, need = 31, wells = 1, wet = false, wwet = 0,
           box = {126, 56, 129, 128, 77, 136}, near = {d = 9, at = {128, 77, 136}, src = {137, 77, 143}}}
  function sf.refuge_drink(K) return sf.rd end
  local wf = {name = 'water', every = {ticks = 1200}}
  function wf.state(K)
    return {water = {patients = 0, thirst_max = 0, hosp_ok = 0, refuge_ok = 0, buckets_free = 0, hosp = 2,
                     src = {{137, 77, 143}}, hosp_out = wf.out or 0}}
  end
  function wf.label(K, x, y, z) return string.format('well 19098 at %d,%d,%d in Kern+', x, y, z) end
  function wf.hospital_out(K)
    return {n = wf.out or 0, total = 2, kern = 'Kern+', refuge = 'Tiefe+',
            zones = {{id = 34, loc = 6, x = 115, y = 77, z = 144, tiles = 15, of = 15}}}
  end
  local W = world{seal = sf, extra = {wf}}
  W.state()
  day(W)
  audit(W)
  T.eq(ready(W).fail, {'refuge_dry'})
  local R = W.mods.readiness.M
  T.eq(R.refuge_dry(W.K), 'Tiefe+ has no drink (drink 0<31, its 1 well is dry; Tiefe+ 126-128,56-77 z129-136, nearest ' ..
       'accepted water: well 19098 at 137,77,143 in Kern+, 9 tiles): plan its drink store (bp sites refuge_drink)',
       'old code: no place, no water')
  T.ok(#R.refuge_dry(W.K) <= 200)
  wf.out = 1
  W.state()
  day(W, 3)
  local u = unready(W)
  local hout = tostring(u[#u].d.hout)
  T.eq(hout, 'the hospital lies outside Kern+/Tiefe+ (1 of 2 zones; zone 34 at 115,77,144): its patients cannot walk ' ..
       'to the refuge; no accepted water in Tiefe+: move it next to well 19098 at 137,77,143 in Kern+',
       'old code: "move it into Tiefe+ next to accepted water"')
  T.ok(#u[#u].msg <= 200)
  -- no accepted water at all
  sf.rd.near = nil
  day(W)
  T.ok(R.refuge_dry(W.K):find('Tiefe+ 126-128,56-77 z129-136, no accepted water in the fort', 1, true),
       R.refuge_dry(W.K))
end)

T.test('FR-69 (Run 11 y477: Tiefe+ drink 0 while 1199 drinks lay in one Kern+ stockpile): refuge_dry names the ' ..
       'refuge drink store: none -> plan it (bp sites refuge_drink); one that stands but is short -> it waits for ' ..
       'barrels; drink >= citizens on it clears refuge_dry', function()
  local sf = seal_fake{tick = 1, sealed = 1, routes = 0, doors = {}, open = {}}
  sf.rd = {name = 'Tiefe+', exists = true, drink = 0, need = 52, wells = 1, wet = true, wwet = 0,
           box = {126, 56, 129, 128, 77, 136}, near = {d = 9, at = {128, 77, 136}, src = {137, 77, 143}}}
  function sf.refuge_drink(K) return sf.rd end
  local wf = {name = 'water', every = {ticks = 1200}}
  function wf.state(K)
    return {water = {patients = 0, thirst_max = 0, hosp_ok = 1, refuge_ok = 0, buckets_free = 0, hosp = 0,
                     src = {{137, 77, 143}}}}
  end
  function wf.label(K, x, y, z) return string.format('well 19098 at %d,%d,%d in Kern+', x, y, z) end
  local W = world{seal = sf, extra = {wf}}
  W.state()
  day(W)
  audit(W)
  T.eq(ready(W).fail, {'refuge_dry'})
  local R = W.mods.readiness.M
  local where = '; Tiefe+ 126-128,56-77 z129-136, nearest accepted water: well 19098 at 137,77,143 in Kern+, 9 tiles'
  T.eq(R.refuge_dry(W.K), 'Tiefe+ has no drink (drink 0<52, its 1 well is dry' .. where .. '): plan its drink store ' ..
       '(bp sites refuge_drink)', 'old code: build a well/cistern or stock drink there')
  T.ok(#R.refuge_dry(W.K) <= 200)
  -- the store stands (seal sees the dfllm-drink pile on Tiefe+) and holds 8 so far
  sf.rd.drink, sf.rd.store = 8, {n = 1, tiles = 12, drink = 8, at = {127, 60, 136}}
  day(W)
  T.eq(R.refuge_dry(W.K), 'Tiefe+ has no drink (drink 8<52, its 1 well is dry' .. where .. '): its drink store (12 ' ..
       'tiles) waits for barrels')
  day(W, 2)
  local u = unready(W)
  T.ok(#u >= 1 and tostring(u[#u].d.rdry):find('its drink store (12 tiles) waits for barrels', 1, true),
       u[#u] and u[#u].d.rdry)
  -- enough drink on it: refuge_dry goes (the well stays dry)
  sf.rd.drink, sf.rd.store.drink = 52, 52
  day(W)
  T.eq({lvl(W), has(ready(W).fail, 'refuge_dry'), R.refuge_dry(W.K)}, {1, false, nil})
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

T.test('BUG-055 x FR-70: a fort below perimeter.hold_pop (30) citizens is not stopped by a vacant office (it cannot always ' ..
       'fill it), one at or above is', function()
  local W = world{n = 7}
  W.econ.offices = function(K) return {{code = 'CHIEF_MEDICAL_DWARF', n = 1, days = 9, cand = 7}} end
  day(W)
  T.ok(not has(ready(W).fail, 'office'), '7 citizens: no office blocker')
  local W2 = world{n = 40}
  W2.econ.offices = function(K) return {{code = 'CHIEF_MEDICAL_DWARF', n = 1, days = 9, cand = 7}} end
  day(W2)
  T.ok(has(ready(W2).fail, 'office'), '40 citizens: the office blocks')
end)

T.test('BUG-055 (Run 14 y577: the chief medical dwarf office stood vacant for good): a vacant manager or chief medical ' ..
       'dwarf the kernel could not fill for offices.blocker_days (7) is the R0 blocker office with the appoint command; ' ..
       'squads without a leader too; other offices, fewer days and blocker_days 0 are none', function()
  local W = world()
  local offs = {}
  W.econ.offices = function(K) return offs end
  day(W)
  T.ok(not has(ready(W).fail, 'office'), 'nothing vacant')
  offs = {{code = 'CHIEF_MEDICAL_DWARF', n = 1, days = 3, cand = 7}}
  day(W)
  T.ok(not has(ready(W).fail, 'office'), '3 days: the kernel is still trying')
  offs = {{code = 'BOOKKEEPER', n = 1, days = 30, cand = 3}}
  day(W)
  T.ok(not has(ready(W).fail, 'office'), 'a bookkeeper is no blocker')
  offs = {{code = 'CHIEF_MEDICAL_DWARF', n = 1, days = 9, cand = 7}}
  day(W)
  local r = ready(W)
  T.ok(has(r.fail, 'office'), 'office is an R0 blocker')
  T.eq(r.office, 'CHIEF_MEDICAL_DWARF vacant 9 days (ACTIVE): dfllm cmd appoint {"code":"CHIEF_MEDICAL_DWARF","unit":7}')
  W.ms = W.ms + 600000                         -- a new blocker wakes after a game month and UNREADY_NEWS_S
  day(W, 28)
  W.ms = W.ms + 600000
  day(W, 2)
  local u = unready(W)
  T.ok(#u >= 1)
  T.eq(u[#u].d.office, r.office)
  T.ok(u[#u].msg:find('CHIEF_MEDICAL_DWARF vacant 9 days', 1, true), u[#u].msg)
  T.ok(#u[#u].msg <= 200)
  offs = {{code = 'MANAGER', n = 1, days = 8, why = 'no adult citizen outside the squads'}}
  day(W)
  T.eq(ready(W).office, 'MANAGER vacant 8 days (ACTIVE, no adult citizen outside the squads): no adult citizen outside the squads')
  W.K.cfg.baseline.offices = {blocker_days = 0}
  day(W)
  T.ok(not has(ready(W).fail, 'office'), 'blocker_days 0: never')
  W.K.cfg.baseline.offices = {blocker_days = 'x'}
  day(W)
  T.ok(has(ready(W).fail, 'office'), 'a bad value keeps the default 7')
  W.K.cfg.baseline.offices = nil
  offs = {}
  day(W)
  T.ok(not has(ready(W).fail, 'office'), 'filled: the blocker goes')
  -- squads that cannot get a leader (military.leader_state)
  local since = W.K.now().tick - 8 * 1200
  W.mods.military.M.leader_state = function(K)
    return {why = 'squad creation refused 3 time(s): no militia assignment for a new squad (ACTIVE militia posts: none; ' ..
                  'vacant assignments without a squad: 0)', since = since, fails = 3, active = {}, free = 0, squads = 0}
  end
  day(W)
  r = ready(W)
  T.ok(has(r.fail, 'office'))
  T.ok(r.office:find('no militia assignment for a new squad', 1, true) and r.office:find('fix: dfllm cmd squad.create', 1, true),
       r.office)
  T.ok(#r.office <= 200)
  since = W.K.now().tick - 2 * 1200
  day(W)
  T.ok(not has(ready(W).fail, 'office') or since == nil, 'the squad trouble is old enough only after 7 days')
end)


---------------------------------------------------------------- BUG-117: R0 mood_ws
T.test('BUG-117 (Run 14 note 92, 151 of 453 citizen deaths were failed moods): a moodable workshop type missing for ' ..
       'offices.mood_ws_days (7) game days in a fort of mood_ws_pop (20) citizens is the R0 blocker mood_ws with the ' ..
       'ready bp.place command; a shop that stands, fewer days, 19 citizens, 0 days and economy without an answer are none',
       function()
  local W = world{n = 50}
  local miss, queued = {'Loom'}, {}
  W.econ.mood_shops = function(K) return {missing = miss, queued = queued} end
  day(W)
  T.ok(not has(ready(W).fail, 'mood_ws'), 'the first look only starts the clock')
  day(W, 5)
  T.ok(not has(ready(W).fail, 'mood_ws'), '5 days: the plan is still building the shops')
  day(W, 3)
  local r = ready(W)
  T.ok(has(r.fail, 'mood_ws'), 'mood_ws is an R0 blocker after 7 days')
  T.eq(r.mws:gsub('missing %d+ days', 'missing N days'),
       'mood shops missing N days: Loom; ' ..
       'dfllm cmd bp.place {"tpl":"workshops","site":"S1","p":{"only":"Loom"}}')
  T.ok(#r.mws <= 200)
  W.ms = W.ms + 600000                         -- a new blocker wakes after a game month and UNREADY_NEWS_S
  day(W, 28)
  W.ms = W.ms + 600000
  day(W, 2)
  local u = unready(W)
  T.ok(#u >= 1, 'SIEGE_UNREADY names it')
  T.ok(u[#u].d.mws and u[#u].d.mws:find('missing', 1, true), 'the event carries d.mws')
  T.ok(has(u[#u].d.fails, 'mood_ws') and u[#u].msg:find('"only":"Loom"', 1, true), u[#u].msg)
  -- several types: the command takes the first three, a queued project is named instead of asked again
  miss = {'Loom', 'Jewelers', 'Tanners', 'Mechanics', 'Bowyers'}
  queued = {Jewelers = {id = 'c1a147c261d9', pct = 40}}
  day(W, 8)
  r = ready(W)
  T.ok(r.mws:find('Loom,Jewelers,Tanners +2', 1, true) and r.mws:find('"only":"Loom,Tanners,Mechanics"', 1, true)
       and r.mws:find('queued Jewelers c1a147c261d9 40%', 1, true), r.mws)
  T.ok(#r.mws <= 200)
  -- a shop built: its clock goes; the others keep theirs
  miss, queued = {'Loom'}, {}
  day(W)
  T.ok(has(ready(W).fail, 'mood_ws'))
  miss = {}
  day(W)
  T.ok(not has(ready(W).fail, 'mood_ws') and ready(W).mws == nil, 'built: the blocker goes')
  miss = {'Loom'}
  day(W, 2)
  T.ok(not has(ready(W).fail, 'mood_ws'), 'lost again: the 7 days start again')
  -- the knobs
  day(W, 7)
  T.ok(has(ready(W).fail, 'mood_ws'))
  W.K.cfg.baseline.offices = {mood_ws_days = 0}
  day(W)
  T.ok(not has(ready(W).fail, 'mood_ws'), 'mood_ws_days 0: never')
  W.K.cfg.baseline.offices = {mood_ws_days = 'x', mood_ws_pop = 'y'}
  day(W, 8)
  T.ok(has(ready(W).fail, 'mood_ws'), 'bad values keep the defaults (7 days, 20 citizens)')
  W.K.cfg.baseline.offices = {mood_ws_pop = 60}
  day(W)
  T.ok(not has(ready(W).fail, 'mood_ws'), '50 citizens < mood_ws_pop 60')
  W.K.cfg.baseline.offices = nil
  W.econ.mood_shops = function(K) return nil end                  -- before mood_from_phase, or the buildings unreadable
  day(W, 10)
  T.ok(not has(ready(W).fail, 'mood_ws'), 'economy answers nil: no blocker')
end)

T.test('BUG-117: a fort without a dwarf that can have a mood (0 or 19 citizens) never gets mood_ws; 20 do', function()
  for _, n in ipairs({0, 7, 19}) do
    local W = world{n = n}
    W.econ.mood_shops = function(K) return {missing = {'Loom', 'Jewelers'}, queued = {}} end
    day(W, 20)
    T.ok(not has(ready(W).fail, 'mood_ws'), n .. ' citizens: no blocker')
  end
  local W = world{n = 20}
  W.econ.mood_shops = function(K) return {missing = {'Loom'}, queued = {}} end
  day(W, 10)
  T.ok(has(ready(W).fail, 'mood_ws'), '20 citizens: the blocker')
  -- an old kernel state (no mws record) and a reload keep the clock of the saved record
  local persisted = W.K.persist.get('m.readiness')
  T.ok(type(persisted.mws) == 'table' and persisted.mws.Loom ~= nil, 'the first-missed tick is persisted')
end)


T.done()
