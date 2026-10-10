-- WP1 kernel files: state a/b slots, events rotation, inbox -> outbox, heartbeat, logs, plan.reload.
local T = require('testlib')
local H = require('kern_world')
local json = require('dfllm.util.json')
local fio = require('dfllm.io')
local kern = require('dfllm.kern')

local function gate_with_verbs(extra)
  local g = {name = 'gate', every = {ticks = 25}, verbs = {}}
  g.verbs.lever = function(K, args, cmd) return true, 'queued ' .. args.bridge .. ' by ' .. cmd.by, {job = 7} end
  for k, v in pairs(extra or {}) do g[k] = v end
  return g
end

T.test('state a/b: slot by seq parity, written in place, both valid, reader takes the higher seq', function()
  local W = H.world{tag = 'ab', ms_per_frame = 500}
  H.boot(W, {modules = {H.counter('test_a', {ticks = 10})}})
  local a = H.json(W.sd .. '/state.a.json')
  T.eq(a.seq, 1)
  H.run(W, 4)   -- 2 s -> seq 2 into slot b
  local b = H.json(W.sd .. '/state.b.json')
  T.eq(b.seq, 2)
  T.eq(H.state(W).seq, 2)
  H.run(W, 4)
  T.eq(H.json(W.sd .. '/state.a.json').seq, 3)
  -- a torn slot: the reader falls back to the other one
  H.write(W.sd .. '/state.a.json', '{"v":2,"seq":')
  T.eq(H.state(W).seq, 2)
  T.eq(luahost.isfile(W.sd .. '/state.a.json.tmp'), false)
  kern.stop()
end)

T.test('state document: kern keys, module parts merged with owner checks, k metrics', function()
  local W = H.world{tag = 'compose'}
  local sense = {name = 'sense', every = {ticks = 10}, state = function() return {pop = {cit = 7, adults = 5, soldiers = 1}} end}
  local rd = {name = 'readiness', every = {ticks = 33600}, state = function() return {pop = {cap = 55, gate_cap = 55},
    ready = {lvl = 0, worn = 0, cv = 0, drill_age = -1, audit = {ok = 0, age = -1, min_traps = 0}, fail = json.array{}}} end}
  local care = {name = 'care', every = {ticks = 1200}, state = function() return {pop = {cit = 1}, care = {
    stressed_pct = 4, naked = 0, ghosts = 0, corpses_old = 0, tombs_free = 9, moods = 0}} end}
  H.boot(W, {modules = {sense, rd, care}, strict = false})
  local s = H.state(W)
  T.eq(s.pop, {cit = 7, adults = 5, soldiers = 1, cap = 55, gate_cap = 55})
  T.eq(s.care.tombs_free, 9)
  T.eq(s.ready.fail, {})
  T.eq({s.t.y, s.t.season, s.t.paused, s.save, s.ev >= 1}, {3, 0, false, 'region1', true})
  T.ok(s.k.ms_s >= 0 and s.k.gap_max_ms >= 0 and s.k.faults == 0)
  T.ok(H.read(W.sd .. '/kern.log'):find('does not own state pop.cit'))
  T.eq(kern.K().view().seq, s.seq)
  kern.stop()
end)

T.test('state > 4 KB drops optional keys instead of writing an oversized file', function()
  local W = H.world{tag = 'big'}
  local r = {name = 'runner', every = {ticks = 600}, state = function()
    local p = {}
    for i = 1, 200 do p[i] = {'proj' .. i, 's1.dig', 1, string.rep('x', 30)} end
    return {proj = p, phase = 'P1'}
  end}
  H.boot(W, {modules = {r}})
  local raw = H.read(W.sd .. '/state.a.json')
  T.ok(#raw <= 4096, 'size ' .. #raw)
  local s = json.decode(raw)
  T.eq(s.proj, nil)
  T.eq(s.phase, 'P1')
  kern.stop()
end)

T.test('events.jsonl append + rotation to events.1.jsonl, numbering continues', function()
  local W = H.world{tag = 'rot', ms_per_frame = 1100}
  local saved = fio.EVENTS_MAX
  fio.EVENTS_MAX = 600
  local r = {name = 'runner', every = {ticks = 1}}
  function r.step(K) K.emit('PROJECT_STAGE', 'C', 'stage', {proj = 'p1', stage = 's1', pct = 5}) end
  H.boot(W, {modules = {r}})
  H.run(W, 12)
  fio.EVENTS_MAX = saved
  T.ok(luahost.isfile(W.sd .. '/events.1.jsonl'), 'rotated')
  local old, cur = H.events(W, 'events.1.jsonl'), H.events(W)
  T.ok(#old > 0 and #cur > 0)
  T.eq(cur[1].n, old[#old].n + 1)
  for _, line in ipairs(H.lines(W.sd .. '/events.jsonl')) do T.ok(#line > 0 and line:sub(-1) == '}') end
  T.eq(H.read(W.sd .. '/events.jsonl'):find('\r', 1, true), nil, 'no CRLF')
  kern.stop()
end)

-- every PROJECT_STAGE n from 1..: no gaps, no duplicates across events.1.jsonl + events.jsonl
local function stage_ns(W)
  local ns = {}
  for _, f in ipairs({'events.1.jsonl', 'events.jsonl'}) do
    for _, e in ipairs(H.events(W, f)) do if e.type == 'PROJECT_STAGE' then ns[#ns + 1] = e.n end end
  end
  table.sort(ns)
  return ns
end

local function contiguous(ns)
  for i = 2, #ns do if ns[i] ~= ns[i - 1] + 1 then return false, ns[i - 1] .. '->' .. ns[i] end end
  return true
end

T.test('events: a failing rotation (file locked by a reader) loses nothing; warned once; retried', function()
  local W = H.world{tag = 'rotlock', ms_per_frame = 1100}
  local saved_max, real_rename = fio.EVENTS_MAX, os.rename
  fio.EVENTS_MAX = 600
  local locked, tries = true, 0
  os.rename = function(a, b)
    if locked and tostring(a):find('events%.jsonl$') then tries = tries + 1; return nil, a .. ': Permission denied' end
    return real_rename(a, b)
  end
  local r = {name = 'runner', every = {ticks = 1}, n = 0}
  function r.step(K) r.n = r.n + 1; K.emit('PROJECT_STAGE', 'C', 'stage', {proj = 'p1', stage = 's1', pct = 5}) end
  local ok, err = pcall(function()
    H.boot(W, {modules = {r}})
    H.run(W, 12)
    T.ok(tries >= 2, 'rotation retried at each flush: ' .. tries)
    T.eq(luahost.isfile(W.sd .. '/events.1.jsonl'), false)
    locked = false
    H.run(W, 1)                                   -- one flush: a single rotation (a 2nd would drop .1 by design)
    T.ok(luahost.isfile(W.sd .. '/events.1.jsonl'), 'rotated once the lock is gone')
    kern.stop()
  end)
  os.rename, fio.EVENTS_MAX = real_rename, saved_max
  assert(ok, err)
  local ns = stage_ns(W)
  T.eq(#ns, r.n, 'every emitted event is on disk')
  T.ok(contiguous(ns))
  local warns = 0
  for _, l in ipairs(H.lines(W.sd .. '/kern.log')) do if l:find('rotation of events.jsonl failed', 1, true) then warns = warns + 1 end end
  T.eq(warns, 1, 'warned once per outage')
end)

T.test('events: a failing open keeps the buffer (capped, counted in dropped) and retries', function()
  local W = H.world{tag = 'openfail', ms_per_frame = 1100}
  local real_open, saved_cap = io.open, kern.CAD.evbuf_max
  local blocked = true
  io.open = function(p, m)
    if blocked and tostring(p):find('events%.jsonl$') and m == 'ab' then return nil, p .. ': Permission denied' end
    return real_open(p, m)
  end
  local r = {name = 'runner', every = {ticks = 1}, n = 0}
  function r.step(K) r.n = r.n + 1; K.emit('PROJECT_STAGE', 'C', 'stage', {proj = 'p1', stage = 's1', pct = 5}) end
  local ok, err = pcall(function()
    H.boot(W, {modules = {r}})
    H.run(W, 5)
    T.eq(#H.events(W), 0, 'nothing written while blocked')
    blocked = false
    H.run(W, 3)
    T.eq(#stage_ns(W), r.n, 'buffer flushed after the outage')
    T.ok(contiguous(stage_ns(W)))
    -- a long outage: only the newest evbuf_max lines are kept
    kern.CAD.evbuf_max = 4
    blocked = true
    H.run(W, 10)                                  -- one event per frame, every flush fails
    blocked = false
    H.run(W, 2)
    T.eq(kern.status().dropped, 10 - 4, 'the 10 outage lines minus the 4 newest kept')
    T.eq(#stage_ns(W), r.n - 6)
    T.eq(contiguous(stage_ns(W)), false, 'one gap where the oldest outage lines were')
    kern.stop()
  end)
  io.open, kern.CAD.evbuf_max = real_open, saved_cap
  assert(ok, err)
end)

T.test('inbox: valid verb -> outbox reply, CMD event, commands.log; file deleted', function()
  local W = H.world{tag = 'inbox'}
  H.boot(W, {modules = {gate_with_verbs()}})
  local name = H.inbox(W, 'c1', 'lever', {bridge = 'O1', want = 'up'}, 'llm')
  H.run(W, 40)
  local r = H.outbox(W, 'c1')
  T.eq({r.id, r.ok, r.msg, r.verb, r.data.job}, {'c1', true, 'queued O1 by llm', 'lever', 7})
  T.eq(luahost.isfile(W.sd .. '/inbox/' .. name), false)
  kern.stop()   -- flushes events and logs
  T.eq(H.find(H.events(W), 'CMD')[1].d, {id = 'c1', verb = 'lever', ok = 1})
  local log = H.read(W.sd .. '/commands.log')
  T.ok(log:find('inbox:c1:llm\tverb:lever\t{"bridge":"O1","want":"up"}\tok', 1, true), log)
end)

T.test('inbox rejections: modes, approval, unknown verb, id mismatch, missing/disabled module, handler error', function()
  local W = H.world{tag = 'rej'}
  local g = gate_with_verbs()
  g.verbs.lever = function(K, args) if args.bridge == 'X' then error('kaputt') end return true, 'ok' end
  H.boot(W, {modules = {g}, strict = false})
  local K = kern.K()
  K.set_mode('SIEGE', 'test')
  H.inbox(W, 'm1', 'lever', {bridge = 'O1', want = 'up'})
  H.inbox(W, 'a1', 'squad.sortie', {squad = 'A', target = 'K1'})
  H.inbox(W, 'u1', 'rm-rf', {})
  H.inbox(W, 'x1', 'lever', nil, nil, json.encode({id = 'other', verb = 'lever', args = {}, by = 'test'}))
  H.inbox(W, 't1', 'trade.want', {want = {'anvil'}})
  H.inbox(W, 'b1', 'lever', {}, 'nobody')
  H.inbox(W, 'r1', 'drill', json.array{})
  H.run(W, 40)
  T.eq(H.outbox(W, 'm1').msg, 'lever not allowed in SIEGE')
  T.eq(H.outbox(W, 'a1').msg, 'approval required')
  T.eq(H.outbox(W, 'u1').msg, 'unknown verb')
  T.eq(H.outbox(W, 'x1').msg, 'id does not match file name')
  T.eq(H.outbox(W, 't1').msg, 'no module trade')
  T.eq(H.outbox(W, 'b1').msg, 'bad by')
  T.eq(H.outbox(W, 'r1').msg, 'args must be an object')
  -- handler error, then disabled
  kern.stop()
  W = H.world{tag = 'rej2'}
  H.boot(W, {modules = {g}, strict = false})
  for i = 1, 3 do H.inbox(W, 'e' .. i, 'lever', {bridge = 'X', want = 'up'}) end
  H.run(W, 40)
  H.inbox(W, 'e4', 'lever', {bridge = 'O1', want = 'up'})
  H.run(W, 40)
  T.eq(H.outbox(W, 'e1').msg, 'handler error')
  T.eq(H.outbox(W, 'e4').msg, 'module disabled')
  for _, id in ipairs({'e1', 'e2', 'e3', 'e4'}) do T.eq(H.outbox(W, id).ok, false) end
  kern.stop()
end)

T.test('inbox: bad json gets one retry, then a bad-json reply; ignored names; <= 4 per frame', function()
  local W = H.world{tag = 'badjson', ms_per_frame = 100}
  H.boot(W, {modules = {gate_with_verbs()}})
  local name = H.inbox(W, 'j1', nil, nil, nil, '{"id":"j1","verb":')
  H.write(W.sd .. '/inbox/.c9.json.tmp', 'partial')
  H.write(W.sd .. '/inbox/notes.txt', 'x')
  H.frame(W, 1)
  T.ok(luahost.isfile(W.sd .. '/inbox/' .. name), 'kept for one retry')
  T.eq(H.outbox(W, 'j1'), nil)
  H.run(W, 6)
  T.eq(H.outbox(W, 'j1'), {id = 'j1', ok = false, msg = 'bad json', verb = '?', tick = H.outbox(W, 'j1').tick})
  T.ok(luahost.isfile(W.sd .. '/inbox/.c9.json.tmp') and luahost.isfile(W.sd .. '/inbox/notes.txt'))
  for i = 1, 6 do H.inbox(W, 'n' .. i, 'lever', {bridge = 'O1', want = 'up'}) end
  local function count()
    local n = 0
    for i = 1, 6 do if H.outbox(W, 'n' .. i) then n = n + 1 end end
    return n
  end
  local frames = 0
  while count() == 0 and frames < 20 do H.frame(W, 1); frames = frames + 1 end
  T.eq(count(), 4, 'four per frame')
  H.frame(W, 1)
  T.eq(count(), 6)
  kern.stop()
end)

T.test('outbox never renames onto an existing reply', function()
  local W = H.world{tag = 'dupe'}
  H.boot(W, {modules = {gate_with_verbs()}})
  H.inbox(W, 'd1', 'lever', {bridge = 'O1', want = 'up'})
  H.run(W, 40)
  H.inbox(W, 'd1', 'lever', {bridge = 'B1', want = 'up'})
  H.run(W, 40)
  T.eq(H.outbox(W, 'd1').msg, 'queued O1 by test')
  T.eq(H.json(W.sd .. '/outbox/d1-1.json').msg, 'queued B1 by test')
  kern.stop()
end)

T.test('kern verbs: plan.reload and inspect', function()
  local W = H.world{tag = 'plan'}
  H.boot(W, {modules = {gate_with_verbs()}})
  H.inbox(W, 'p0', 'plan.reload', {})
  H.run(W, 5)
  H.write(W.sd .. '/plan.json', json.encode({v = 2, year = 3, phase_target = 'P1',
    policy = {option = 'A', pop_ceiling = 55, beauty = 'none'},
    seasons = {{build = {{tpl = 'dining', site = 'S1'}, {tpl = 'tombs', site = 'S2'}}}, {build = {}}, {build = {}}, {build = {}}}}))
  H.inbox(W, 'p1', 'plan.reload', {})
  H.inbox(W, 'i1', 'inspect', {what = 'modules'})
  H.inbox(W, 'i2', 'inspect', {what = 'mode'})
  H.inbox(W, 'i3', 'inspect', {what = 'persist', key = 'plan'})
  H.inbox(W, 'i4', 'inspect', {what = 'nope'})
  H.run(W, 60)
  local p0 = H.outbox(W, 'p0')
  T.eq(p0.ok, false, 'no plan.json yet: ' .. p0.msg)
  local p1 = H.outbox(W, 'p1')
  T.eq({p1.ok, p1.data.year, p1.data.builds}, {true, 3, 2})
  local K = kern.K()
  T.eq({K.plan.phase_target, K.plan.military.cv_min, K.plan.supply.drink_d}, {'P1', 12, 170})
  T.eq(H.outbox(W, 'i1').data.modules[1].name, 'gate')
  T.eq(H.outbox(W, 'i2').data.mode, 'PEACE')
  T.eq(H.outbox(W, 'i3').data.plan.year, 3)
  T.eq(H.outbox(W, 'i4').ok, false)
  kern.stop()
end)

T.test('heartbeat every 5 s, also while paused', function()
  local W = H.world{tag = 'hb', ms_per_frame = 1000}
  H.boot(W, {modules = {H.counter('test_a', {ticks = 10})}})
  local hb0 = H.json(W.sd .. '/heartbeat')
  df.global.pause_state = true
  H.run(W, 6, {paused = true})
  local hb1 = H.json(W.sd .. '/heartbeat')
  T.ok(hb1.frame > hb0.frame, 'rewritten while paused')
  T.eq(hb1.paused, true)
  T.eq(hb1.tick, hb0.tick)
  df.global.pause_state = false
  kern.stop()
end)

T.test('kern.log and commands.log are tab-separated lines', function()
  local W = H.world{tag = 'logs'}
  local g = {name = 'gate', every = {ticks = 25}}
  function g.step(K) K.log('info', 'hello %d', 5); K.act.pull(4711) end
  H.boot(W, {modules = {g}})
  H.run(W, 80)
  local kl = H.lines(W.sd .. '/kern.log')
  local found
  for _, l in ipairs(kl) do if l:find('hello 5', 1, true) then found = l end end
  T.ok(found, 'kern.log line')
  local f = {}
  for x in (found .. '\t'):gmatch('([^\t]*)\t') do f[#f + 1] = x end
  T.eq({f[3], f[4], f[5]}, {'info', 'gate', 'hello 5'})
  local cl = H.lines(W.sd .. '/commands.log')
  local c = {}
  for x in (cl[1] .. '\t'):gmatch('([^\t]*)\t') do c[#c + 1] = x end
  T.eq({c[3], c[4], c[5]}, {'gate', 'act.pull', '[4711]'})
  T.ok(c[6]:find('^ERR'), 'no such lever: ' .. c[6])
  local af = H.find(H.events(W), 'ACT_FAIL')
  T.eq(#af, 1, 'ACT_FAIL rate-limited per fn+err')
  T.eq(af[1].d.fn, 'pull')
  kern.stop()
end)

T.done()
