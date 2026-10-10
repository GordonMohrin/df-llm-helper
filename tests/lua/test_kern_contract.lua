-- Integration: the kernel follows the review-round-1 contract changes (CONTRACTS §19 R1, R2, R5, R6, R8).
local T = require('testlib')
local H = require('kern_world')
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local kern = require('dfllm.kern')

T.test('R8 backoff: 3 faults back a module off, it is re-enabled when the backoff ends, doubling', function()
  local W = H.world{tag = 'backoff', ms_per_frame = 1000}
  local bad = {name = 'test_bad', every = {ticks = 1}, n = 0, fail = true}
  function bad.step() bad.n = bad.n + 1; if bad.fail then error('boom') end end
  H.boot(W, {modules = {bad}, strict = false})
  H.run(W, 3)
  local kf = H.find(H.events(W), 'KERN_FAULT')
  T.eq(#kf, 1)
  T.eq({kf[1].d.module, kf[1].d.n, kf[1].d.backoff_s}, {'test_bad', 3, 600})
  T.eq(kern.K().enabled('test_bad'), false)
  H.run(W, 590)                                     -- 590 s: still backed off
  T.eq(bad.n, 3)
  H.run(W, 15)                                      -- past 600 s: re-enabled, faults again
  T.ok(bad.n > 3, 're-enabled after the backoff')
  T.ok(H.read(W.sd .. '/kern.log'):find('test_bad re-enabled (backoff over)', 1, true))
  H.run(W, 5)
  kf = H.find(H.events(W), 'KERN_FAULT')
  T.eq(#kf, 2)
  T.eq(kf[2].d.backoff_s, 1200, 'second backoff in the same boot doubles')
  kern.stop()
end)

T.test('R8 critical modules back off for 30 s; module.enable re-enables at once and resets the doubling', function()
  local W = H.world{tag = 'crit', ms_per_frame = 1000}
  local sense = {name = 'sense', every = {ticks = 1}, n = 0, fail = true}
  function sense.step() sense.n = sense.n + 1; if sense.fail then error('x') end end
  H.boot(W, {modules = {sense}, strict = false})
  H.run(W, 3)
  local kf = H.find(H.events(W), 'KERN_FAULT')
  T.eq(kf[1].d.backoff_s, 30)
  sense.fail = false
  H.inbox(W, 'me1', 'module.enable', {module = 'sense'}, 'cli')
  H.run(W, 2)
  local r = H.outbox(W, 'me1')
  T.eq({r.ok, r.data.module}, {true, 'sense'})
  T.ok(r.msg:find('re%-enabled'), r.msg)
  T.eq(kern.K().enabled('sense'), true)
  local n = sense.n
  H.run(W, 3)
  T.ok(sense.n > n, 'runs again')
  H.inbox(W, 'me2', 'module.enable', {module = 'nosuch'}, 'cli')
  H.run(W, 2)
  T.eq(H.outbox(W, 'me2').ok, false)
  kern.stop()
end)

T.test('R6 VERB_BY: audit only from follow/test; other origins refused without calling the handler', function()
  local W = H.world{tag = 'verbby'}
  local calls = 0
  local rd = {name = 'readiness', every = {ticks = 1200}, verbs = {audit = function() calls = calls + 1; return true, 'ok' end}}
  H.boot(W, {modules = {rd}})
  local args = {snap = 'c1', ok = true, fails = json.array{}, min_traps = 0, bypass = false, refuge_sep = true,
                civ_sep = true, caverns = true}
  H.inbox(W, 'a1', 'audit', args, 'llm')
  H.inbox(W, 'a2', 'audit', args, 'gordon')
  H.inbox(W, 'a3', 'audit', args, 'follow')
  H.run(W, 40)
  T.eq(H.outbox(W, 'a1').ok, false)
  T.ok(H.outbox(W, 'a1').msg:find('not accepted from llm'), H.outbox(W, 'a1').msg)
  T.eq(H.outbox(W, 'a2').ok, false)
  T.eq(H.outbox(W, 'a3').ok, true)
  T.eq(calls, 1)
  kern.stop()
end)

T.test('R1 prune: an invalid optional state key is dropped and logged; the rest is written', function()
  local W = H.world{tag = 'prune'}
  local gate = {name = 'gate', every = {ticks = 25}}
  function gate.state() return {bridges = {O1 = 'sideways'}} end
  local threat = {name = 'threat', every = {ticks = 25}}
  function threat.state() return {threat = {vis = 2, armed = 0}} end
  H.boot(W, {modules = {gate, threat}})
  H.run(W, 200)
  local s = H.state(W)
  T.eq(s.bridges, nil, 'invalid bridges dropped')
  T.eq(s.threat, {vis = 2, armed = 0})
  T.eq(C.check_state(s), {})
  T.ok(H.read(W.sd .. '/kern.log'):find('state.bridges dropped'), 'logged')
  kern.stop()
end)

T.test('R2 slow calls decay and demoted modules are promoted after 10 quiet minutes', function()
  local W = H.world{tag = 'promote', ms_per_frame = 1000}
  local eco = {name = 'economy', every = {ticks = 1}, slow = true, n = 0}
  function eco.step() eco.n = eco.n + 1; if eco.slow then W.ms = W.ms + 6 end end
  H.boot(W, {modules = {eco}})
  H.run(W, 4)
  T.eq(#H.find(H.events(W), 'KERNEL_SLOW'), 1)
  T.eq(H.state(W).k.slow, {'economy'})
  eco.slow = false
  H.run(W, 620)
  T.eq(H.state(W).k.slow, {}, 'promoted back to x1')
  T.ok(H.read(W.sd .. '/kern.log'):find('economy promoted to x1'))
  -- two slow calls 11 minutes apart do not add up to a demotion
  eco.slow = true
  H.run(W, 2)
  eco.slow = false
  H.run(W, 660)
  eco.slow = true
  H.run(W, 1)
  eco.slow = false
  H.run(W, 2)
  T.eq(#H.find(H.events(W), 'KERNEL_SLOW'), 1, 'old slow calls expired')
  kern.stop()
end)

T.test('dfllm adopt on an unmarked save: marker, year1 phases, all 16 real modules, status, selftest', function()
  local REPO = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/'):gsub('/tests/lua/[^/]+$', '')
  local S = require('siege_world')
  local W = H.world{tag = 'adopt', marker = false, units = S.fort_units()}
  S.install(W)
  dfhack.findScript = function(name) return REPO .. '/lua/' .. name .. '.lua' end
  dfhack.world = {getCurrentSite = function() return {name = 'Testfort'} end}
  dfhack.translation = {translateName = function(n) return n end}
  local out = {}
  local saved_print = print
  print = function(...) out[#out + 1] = table.concat({...}, '\t') end
  local chunk = assert(loadfile(REPO .. '/lua/dfllm.lua'))
  chunk('adopt')
  for _ = 1, 300 do H.frame(W, 9) end
  chunk('status')
  chunk('selftest', 'quick')
  print = saved_print
  T.ok(out[1]:find('^dfllm: booted region1 %(16 modules'), out[1])
  local marker = json.decode(W.persist_raw['dfllm'])
  T.eq({marker.v, marker.boots, marker.acceptance}, {2, 1, 0})
  local plan = json.decode(W.persist_raw['dfllm.plan'])
  T.eq(plan.phases.phases[1].id, 'P0')
  local text = table.concat(out, '\n')
  T.ok(text:find('kernel %d+ ms/s'), text)
  T.ok(not text:find('DISABLED'), text)
  T.ok(text:find('dfllm selftest: %d+ pass'), text)
  T.eq(C.check_state(kern.K().view()), {})          -- the composed doc (a decoded file drops nulls)
  T.eq(#H.find(H.events(W), 'KERN_FAULT'), 0)
  kern.stop()
end)

T.test('R5 kern reads decisions.yaml with contract.parse_decisions (BOM, indentation)', function()
  T.eq(kern.parse_decisions, C.parse_decisions)
  local d = kern.parse_decisions('\239\187\191D-01: B\n   D-07: visitor30  # x\n#D-09: yes\n')
  T.eq(d, {['D-01'] = 'B', ['D-07'] = 'visitor30'})
end)

T.done()
