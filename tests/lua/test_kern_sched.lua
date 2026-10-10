-- WP1 kernel: boot/opt-in, §3.3 scheduling, K interface, events, modes (real kern on k_mock globals).
local T = require('testlib')
local H = require('kern_world')
local json = require('dfllm.util.json')
local kern = require('dfllm.kern')

T.test('unmarked save: boot is a no-op (no files, no callback, no persist, no commands)', function()
  local W = H.world{marker = false, tag = 'nomark'}
  local ok, msg = H.boot(W, {modules = {H.counter('test_a', {ticks = 10})}})
  T.eq(ok, false)
  T.ok(msg:find('marker'), msg)
  T.eq(luahost.isdir(W.rt), false, 'runtime folder must not exist')
  T.eq(W.repeats, nil)
  T.eq(package.loaded['plugins.eventful'].onReport.dfllm, nil)
  T.eq(next(W.persist_raw), nil)
  T.eq(#W.commands, 0)
  T.eq(kern.running(), false)
end)

T.test('boot writes ACTIVE, state, heartbeat, BOOT event; marker boots counted', function()
  local W = H.world{tag = 'boot'}
  local ok, msg = H.boot(W, {modules = {H.counter('test_a', {ticks = 10})}})
  T.ok(ok, msg)
  T.eq(H.read(W.rt .. '/ACTIVE'), 'region1')
  local s = H.state(W)
  T.eq({s.v, s.seq, s.mode, s.save}, {2, 1, 'PEACE', 'region1'})
  local hb = H.json(W.sd .. '/heartbeat')
  T.eq({hb.v, hb.mode, hb.seq}, {2, 'PEACE', 1})
  local boot = H.find(H.events(W), 'BOOT')[1]
  T.eq({boot.cls, boot.d.save, boot.d.boots}, {'C', 'region1', 1})
  T.eq(json.decode(W.persist_raw['dfllm']).boots, 2) -- k_mock's default marker starts at 1
  T.ok(W.repeats.dfllm, 'repeat-util callback scheduled')
  T.eq(W.repeats.dfllm[2], 'frames')
  kern.stop()
end)

T.test('tick cadence survives 9-tick skips; ctx.dt is the start-to-start delta', function()
  local W = H.world{tag = 'skip'}
  local m = H.counter('test_a', {ticks = 25})
  H.boot(W, {modules = {m}})
  H.run(W, 100, {skip = 9})
  T.eq(#m.runs, 4)
  T.eq(m.runs[1].ctx.dt, 0)
  for i = 2, #m.runs do
    local d = m.runs[i].tick - m.runs[i - 1].tick
    T.ok(d >= 25 and d < 34, 'gap ' .. d)
    T.eq(m.runs[i].ctx.dt, d)
  end
  -- irregular skips (timestream varies 1..9 per frame)
  local m2 = H.counter('test_b', {ticks = 10})
  W = H.world{tag = 'skip2'}
  H.boot(W, {modules = {m2}})
  local done, skips, i = 0, {1, 9, 3, 7, 9, 2, 9, 9, 5}, 0
  while done < 300 do
    i = i + 1
    local s = skips[(i - 1) % #skips + 1]
    H.frame(W, s)
    done = done + s
  end
  for k = 2, #m2.runs do T.ok(m2.runs[k].tick - m2.runs[k - 1].tick >= 10) end
  T.ok(#m2.runs >= 20 and #m2.runs <= 30, 'runs ' .. #m2.runs)
  kern.stop()
end)

T.test('paused: tick modules wait, ms modules run', function()
  local W = H.world{tag = 'pause', ms_per_frame = 100}
  local tm, mm = H.counter('test_t', {ticks = 10}), H.counter('test_m', {ms = 500})
  H.boot(W, {modules = {tm, mm}})
  df.global.pause_state = true
  H.run(W, 20, {paused = true})
  T.eq(#tm.runs, 0)
  T.eq(#mm.runs, 4)   -- 2,000 ms of 100 ms frames: at +100, +600, +1100, +1600
  T.ok(kern.K().now().paused)
  df.global.pause_state = false
  H.run(W, 10)
  T.eq(#tm.runs, 1)
  kern.stop()
end)

T.test("'more' slices continue next frame regardless of cadence", function()
  local W = H.world{tag = 'more'}
  local M = {name = 'test_slice', every = {ticks = 600}, slices = {}}
  function M.step(K, b, ctx)
    M.slices[#M.slices + 1] = {ctx.slice, ctx.cont, ctx.dt}
    if ctx.slice < 3 then return 'more' end
  end
  H.boot(W, {modules = {M}})
  H.run(W, 5)
  T.eq(M.slices, {{1, false, 0}, {2, true, 0}, {3, true, 0}})
  H.run(W, 600)
  T.eq(#M.slices, 6)
  T.eq(M.slices[4][3], 600, 'cadence is start-to-start')
  kern.stop()
end)

T.test('demotion: non-critical slow 3x -> period doubled + KERNEL_SLOW; critical -> KERN_FAULT', function()
  local W = H.world{tag = 'slow'}
  local eco = H.counter('economy', {ticks = 10})
  local base_step = eco.step
  eco.step = function(K, b, ctx) base_step(K, b, ctx); W.ms = W.ms + 7 end
  local sense = {name = 'sense', every = {ticks = 10}, n = 0}
  function sense.step() sense.n = sense.n + 1; W.ms = W.ms + 9 end
  H.boot(W, {modules = {sense, eco}})
  H.run(W, 40)
  local ev = H.events(W)
  T.eq(#H.find(ev, 'KERNEL_SLOW'), 1)
  T.eq(H.find(ev, 'KERNEL_SLOW')[1].d, {module = 'economy', ms = 7, factor = 2})
  local before = #eco.runs
  H.run(W, 40)
  T.ok(#eco.runs - before <= 2, 'economy runs every 20 ticks after demotion')
  local kf = H.find(H.events(W), 'KERN_FAULT')
  T.ok(#kf >= 1 and kf[1].d.module == 'sense' and kf[1].d.err == 'slow', 'critical module faults instead')
  T.ok(sense.n >= 8, 'critical module keeps its cadence')
  T.eq(H.state(W).k.slow, {'economy'})
  kern.stop()
end)

T.test('fault isolation: 3 faults disable the module, others keep running', function()
  local W = H.world{tag = 'fault'}
  local bad = {name = 'test_bad', every = {ticks = 1}}
  function bad.step() error('boom') end
  function bad.ping() return 'pong' end
  local good = H.counter('test_good', {ticks = 1})
  H.boot(W, {modules = {bad, good}, strict = false})
  H.run(W, 6)
  T.eq(#good.runs, 6)
  local kf = H.find(H.events(W), 'KERN_FAULT')
  T.eq(#kf, 1)
  T.eq({kf[1].cls, kf[1].d.module, kf[1].d.n}, {'A', 'test_bad', 3})
  T.ok(kf[1].d.err:find('boom'))
  local K = kern.K()
  T.eq({K.call('test_bad', 'ping')}, {false, 'disabled'})
  T.eq(K.enabled('test_bad'), false)
  T.eq(H.state(W).k.disabled, {'test_bad'})
  T.ok(H.read(W.sd .. '/kern.log'):find('boom'), 'fault logged to kern.log')
  T.eq(json.decode(W.persist_raw['dfllm.kern']).disabled, {'test_bad'})
  kern.stop()
end)

T.test('K.call: true + results, no module, no function, callee errors count against the callee', function()
  local W = H.world{tag = 'call'}
  local g = {name = 'gate', every = {ticks = 25}}
  function g.state_of(K, b) return 'up', 17 end
  function g.boom() error('x') end
  H.boot(W, {modules = {g}, strict = false})
  local K = kern.K()
  T.eq({K.call('gate', 'state_of', 'B1')}, {true, 'up', 17})
  T.eq({K.call('nobody', 'x')}, {false, 'no module'})
  T.eq({K.call('gate', 'nope')}, {false, 'no function nope'})
  local ok = K.call('gate', 'boom')
  T.eq(ok, false)
  T.eq(K.enabled('gate'), true, 'one fault does not disable')
  kern.stop()
end)

T.test('set_mode: setters, transitions, synchronous on.MODE, persisted, flushed in the same frame', function()
  local W = H.world{tag = 'mode'}
  local order = {}
  local siege = {name = 'siege', every = {ticks = 25}, on = {MODE = function(K, ev) order[#order + 1] = 'siege:' .. ev.to end}}
  function siege.step(K) if K.census.h and K.census.h.inv >= 6 then K.set_mode('SIEGE', 'army') end end
  local other = {name = 'test_other', every = {ms = 500}, on = {MODE = function(K, ev)
    order[#order + 1] = 'other:' .. ev.from .. '>' .. ev.to
    local ok, err = K.set_mode('BREACH', 'nested')
    order[#order + 1] = tostring(err)
  end}}
  local drill = {name = 'drill', every = {ticks = 600}}
  function drill.go(K, m) return K.set_mode(m, 'drill test') end
  H.boot(W, {modules = {siege, drill, other}})
  local K = kern.K()
  K.census.h = {inv = 8, vis = 8}
  H.frame(W, 1)
  T.eq(K.mode(), 'SIEGE')
  T.eq(order, {'siege:SIEGE', 'other:PEACE>SIEGE', 'reentrant'})
  T.eq(json.decode(W.persist_raw['dfllm.mode']).mode, 'SIEGE', 'persisted in the same frame')
  T.eq(H.state(W).mode, 'SIEGE', 'state flushed in the same frame')
  T.eq(H.find(H.events(W), 'MODE')[1].d, {from = 'PEACE', to = 'SIEGE', why = 'army'})
  T.raises(function() K.set_mode('PEACE', 'skip recovery') end, 'not allowed')
  T.raises(function() K.call('drill', 'go', 'RECOVERY') end, 'drill may not set mode')
  T.eq({K.set_mode('SIEGE')}, {true, 'unchanged'})
  kern.stop()
  -- the mode survives a reload
  H.boot(W, {modules = {siege, drill}})
  T.eq(kern.K().mode(), 'SIEGE')
  kern.stop()
end)

T.test('emit: registry owner, class override, msg and d limits, A flushed in the same frame', function()
  local W = H.world{tag = 'emit'}
  local runner = {name = 'runner', every = {ticks = 600}}
  function runner.bad(K) return K.emit('GATE_FAIL', 'A', 'not mine', {bridge = 'O1'}) end
  function runner.big(K) return K.emit('PROJECT_STAGE', 'C', string.rep('ä', 150), {proj = 'p1', blob = string.rep('x', 2000)}) end
  function runner.wrongcls(K) return K.emit('PLAN_EXHAUSTED', 'C', 'empty', {phase = 'P1'}) end
  function runner.arr(K) return K.emit('PROJECT_DONE', 'B', 'x', {1, 2}) end
  H.boot(W, {modules = {runner}, strict = false})
  local K = kern.K()
  local ok, n = K.call('runner', 'bad')
  T.eq({ok, n}, {true, nil})
  T.ok(H.read(W.sd .. '/kern.log') == nil or true)
  local _, n2 = K.call('runner', 'big')
  T.ok(n2 > 0)
  local _, n3 = K.call('runner', 'wrongcls')
  T.eq(select(2, K.call('runner', 'arr')), nil, 'array d rejected')
  H.frame(W, 1)  -- PLAN_EXHAUSTED is class A: on disk after this frame
  local ev = H.events(W)
  T.eq(#H.find(ev, 'GATE_FAIL'), 0)
  local big = H.find(ev, 'PROJECT_STAGE')[1]
  T.ok(#big.msg <= 200 and utf8.len(big.msg), 'msg truncated at a UTF-8 boundary')
  T.eq(big.d, {trunc = 1})
  local pe = H.find(ev, 'PLAN_EXHAUSTED')[1]
  T.eq({pe.cls, pe.n}, {'A', n3})
  local log = H.read(W.sd .. '/kern.log')
  T.ok(log:find('GATE_FAIL must be emitted by gate'), 'violation logged')
  kern.stop()
end)

T.test('eventful events are queued and delivered next frame; REPORT filter; EV:<TYPE> next frame', function()
  local W = H.world{tag = 'evq'}
  local got = {}
  local trade = {name = 'trade', every = {ticks = 1000}, reports = {CARAVAN_ARRIVAL = true}, on = {
    REPORT = function(K, ev) got[#got + 1] = 'R:' .. ev.type .. ':' .. ev.text .. ':' .. tostring(ev.pos and ev.pos.z) end,
  }}
  local threat = {name = 'threat', every = {ticks = 25}, on = {
    INVASION = function(K, ev) got[#got + 1] = 'I:' .. ev.id; K.emit('DECISION_NEEDED', 'A', 'q', {id = 'D-07'}) end,
    UNIT_DEATH = function(K, ev) got[#got + 1] = 'D:' .. ev.unit end,
    ['EV:DECISION_NEEDED'] = function(K, ev) got[#got + 1] = 'E:' .. ev.d.id end,
  }}
  H.boot(W, {modules = {threat, trade}})
  local ev = package.loaded['plugins.eventful']
  local reports = df.global.world.status.reports
  reports:insert('#', {id = 501, type = df.announcement_type.CARAVAN_ARRIVAL, text = 'Händler', pos = {x = 1, y = 2, z = 3}})
  reports:insert('#', {id = 502, type = df.announcement_type.CANCEL_JOB, text = 'filtered', pos = {x = -30000, y = 0, z = 0}})
  ev.onReport.dfllm(501)
  ev.onReport.dfllm(502)
  ev.onInvasion.dfllm(7)
  ev.onUnitDeath.dfllm(42)
  T.eq(got, {})
  H.frame(W, 1)
  T.eq(got, {'R:CARAVAN_ARRIVAL:Händler:3', 'I:7', 'D:42'})  -- queue order; CANCEL_JOB filtered
  H.frame(W, 1)
  T.eq(got[4], 'E:D-07')
  T.eq(#got, 4)
  kern.stop()
end)

T.test('eventful registration only for handled events', function()
  local W = H.world{tag = 'evreg'}
  H.boot(W, {modules = {H.counter('test_a', {ticks = 10})}})
  local ev = package.loaded['plugins.eventful']
  T.eq({ev.onReport.dfllm, ev.onInvasion.dfllm, ev.onUnitDeath.dfllm}, {nil, nil, nil})
  kern.stop()
end)

T.test('calendar: SEASON and YEAR_REVIEW, absolute ticks over the year boundary', function()
  local W = H.world{tag = 'cal', year = 3, ytick = 403200 - 5}
  H.boot(W, {modules = {H.counter('test_a', {ticks = 1})}})
  local before = kern.K().now().tick
  H.run(W, 10, {skip = 9})
  local now = kern.K().now()
  T.eq({now.year, now.tick}, {4, before + 10})
  local ev = H.events(W)
  T.eq(H.find(ev, 'YEAR_REVIEW')[1].d, {year = 3})
  T.eq(H.find(ev, 'SEASON')[1].d, {year = 4, season = 0})
  kern.stop()
end)

T.test('persist: dirty keys flushed every 10 s, owner checks, mode change flushes at once', function()
  local W = H.world{tag = 'persist', ms_per_frame = 1000}
  local r = {name = 'runner', every = {ticks = 600}}
  function r.save(K) local p = K.persist.get('m.runner') or {v = 2, n = 0}; p.n = p.n + 1; K.persist.touch('m.runner'); K.persist.set('m.runner', p) end
  function r.steal(K) K.persist.set('drill', {v = 2}) end
  H.boot(W, {modules = {r}, strict = false})
  local K = kern.K()
  K.call('runner', 'save')
  T.eq(W.persist_raw['dfllm.m.runner'], nil, 'not written yet')
  H.run(W, 5)
  T.eq(W.persist_raw['dfllm.m.runner'], nil, 'still within 10 s')
  H.run(W, 6)
  T.eq(json.decode(W.persist_raw['dfllm.m.runner']).n, 1)
  K.call('runner', 'steal')
  H.run(W, 12)
  T.eq(W.persist_raw['dfllm.drill'], nil, 'runner may not write drill')
  T.ok(H.read(W.sd .. '/kern.log'):find('may not write persist drill'))
  kern.stop()
end)

T.test('seq and event numbers continue across boots (from disk and persist)', function()
  local W = H.world{tag = 'seq', ms_per_frame = 500}
  H.boot(W, {modules = {H.counter('test_a', {ticks = 10})}})
  H.run(W, 20)
  kern.stop()
  local s1, ev1 = H.state(W).seq, H.events(W)
  local last_n = ev1[#ev1].n
  -- simulate loading an older save: persist forgets the kernel record, the files remain
  W.persist_raw['dfllm.kern'] = nil
  H.boot(W, {modules = {H.counter('test_a', {ticks = 10})}})
  T.ok(H.state(W).seq > s1, 'seq continues from the state slots')
  local ev2 = H.events(W)
  T.eq(ev2[#ev1 + 1].n, last_n + 1, 'event numbers continue from events.jsonl')
  for i = 2, #ev2 do T.ok(ev2[i].n > ev2[i - 1].n, 'strictly increasing') end
  kern.stop()
end)

T.test('SC_MAP_UNLOADED stops the kernel: UNLOAD event, ACTIVE removed, callback cancelled', function()
  local W = H.world{tag = 'unload'}
  local unloaded = false
  local m = H.counter('test_a', {ticks = 10}, {on = {UNLOAD = function() unloaded = true end}})
  H.boot(W, {modules = {m}})
  dfhack.onStateChange.dfllm(SC_MAP_UNLOADED)
  T.eq(kern.running(), false)
  T.ok(unloaded)
  T.eq(luahost.isfile(W.rt .. '/ACTIVE'), false)
  T.eq(W.repeats.dfllm, nil)
  local ev = H.events(W)
  T.eq(ev[#ev].type, 'UNLOAD')
  T.eq(dfhack.onStateChange.dfllm, nil)
end)

T.test('frame errors never stop the callback (repeat-util has no pcall)', function()
  local W = H.world{tag = 'framefault'}
  H.boot(W, {modules = {H.counter('test_a', {ticks = 1})}, strict = false})
  local saved = df.global.cur_year_tick
  df.global.cur_year_tick = nil              -- breaks the frame itself
  W.repeats.dfllm[3]()
  df.global.cur_year_tick = saved
  T.ok(kern.running())
  H.frame(W, 1)
  local kf = H.find(H.events(W), 'KERN_FAULT')
  T.eq(kf[1].d.module, 'kern')
  kern.stop()
end)

T.done()
