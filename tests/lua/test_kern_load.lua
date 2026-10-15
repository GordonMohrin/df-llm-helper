-- FR-62 kernel cost on a big fort: cost owners (k.* parts, persist by owner, `repeat` as a cross-check), the
-- fort-size load (cadence stretch, budget), pacing with the PEACE pool, demotion hysteresis, the 1-min budget
-- self-test, and the per-unit/per-item paths of sense and economy. The Run 9 model (load_world) runs the real
-- kernel on 402 units and 18.7k items with stand-ins that cost what the live profile measured (STATUS §0h).
local T = require('testlib')
local H = require('kern_world')
local L = require('load_world')
local F = require('wp8_world')
local kern = require('dfllm.kern')
local sched = require('dfllm.util.sched')
local json = require('dfllm.util.json')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local SKIPS = {4, 5}           -- ~450 ticks/s at ~100 frames/s (10 ms frames)
local function frames(W, n) for i = 1, n do H.frame(W, SKIPS[i % 2 + 1]) end end

-- ms per real second per owner between two kern.costs() samples
local function rates(c0, c1)
  local dt = (c1.at - c0.at) / 1000
  local r = {total = (c1.ms - c0.ms) / dt}
  for k, v in pairs(c1.mods) do r[k] = (v - (c0.mods[k] or 0)) / dt end
  return r
end

-- long runs without inbox traffic: no inbox listdir (a process spawn per call in the Linux test host)
local function no_inbox(f, ...)
  local saved = kern.CAD.inbox_ms
  kern.CAD.inbox_ms = 1e12
  local r = table.pack(pcall(f, ...))
  kern.CAD.inbox_ms = saved
  assert(r[1], r[2])
  return table.unpack(r, 2, r.n)
end

local function module_info(name)
  for _, m in ipairs(kern.status().modules) do if m.name == name then return m end end
end

-- the Run 9 model for `secs` simulated seconds; measured over the last 2 minutes. variant: 'pre' (no pacing,
-- no stretch, no pool: the scheduling before FR-62), 'fr62' (the new scheduling, old sense/kern costs),
-- 'post' (the new scheduling with the sense and housekeeping savings)
local function run9_(variant, secs)
  local W = L.world{tag = 'run9-' .. variant}
  local m = L.model(W, {post = variant == 'post'})
  local saved = sched.PACE.pool_min
  if variant == 'pre' then
    sched.PACE.pool_min = 1e9
    for _, x in pairs(m) do x.share, x.scale = 1e9, false end
  end
  local ok, msg = H.boot(W, {modules = {m.sense, m.reflex, m.seal, m.economy, m.care, m.baseline, m.house}})
  assert(ok, msg)
  frames(W, (secs - 120) * 100)
  local c0 = kern.costs()
  local scans0 = m.sense.scans
  frames(W, 120 * 100)
  local r = rates(c0, kern.costs())
  r.scans, r.load, r.budget = m.sense.scans - scans0, kern.load(), kern.budget()
  kern.stop('test')
  sched.PACE.pool_min = saved
  return r, m
end

local function run9(variant, secs) return no_inbox(run9_, variant, secs) end

local function fmt(r)
  local list = {}
  for k, v in pairs(r) do if type(v) == 'number' and k ~= 'total' and k ~= 'scans' and k ~= 'budget' and v >= 0.05 then list[#list + 1] = {k, v} end end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  local parts = {}
  for _, x in ipairs(list) do parts[#parts + 1] = string.format('%s %.1f', x[1], x[2]) end
  return string.format('%.1f ms/s (%s)', r.total, table.concat(parts, ', '))
end

---------------------------------------------------------------- the Run 9 model
local pre
T.test('Run 9 model: 402 units and 18.7k items; the old scheduling costs what the live fort measured', function()
  local r = run9('pre', 150)
  pre = r
  print('# before FR-62: ' .. fmt(r))
  T.eq({r.load.units, r.load.items}, {402, 18743})
  T.ok(r.total >= 75 and r.total <= 95, 'live: 82-90 ms/s, got ' .. fmt(r))
  T.ok(r.seal >= 30 and r.sense >= 13 and r.economy >= 10 and r.test_house >= 9, fmt(r))
end)

T.test('Run 9 model: pacing, the PEACE pool and the load stretch hold the paced modules; sense keeps its cadence', function()
  pre = pre or run9('pre', 150)
  local r = run9('fr62', 150)
  print('# FR-62 scheduling, old sense and housekeeping costs: ' .. fmt(r) .. ', budget ' .. r.budget)
  T.eq(r.budget, 35, 'budget for 402 units')
  T.eq(r.scans, pre.scans, 'the hostile scan keeps its 45-tick period')
  T.ok(r.seal <= 4.2 and r.seal >= 1, 'seal ' .. r.seal)
  T.ok(r.seal + r.economy + r.care + r.baseline <= 6.5, 'paced modules share the pool: ' .. fmt(r))
  T.ok(r.economy > 0.5 and r.care > 0.3 and r.baseline > 0.3, 'nobody starves: ' .. fmt(r))
  T.ok(r.total <= r.budget, 'within the fort-size budget: ' .. fmt(r))
end)

T.test('Run 9 model: with the sense and housekeeping savings the kernel stays below 25 ms/s', function()
  local r, m = run9('post', 150)
  print('# FR-62 with the measured sense/housekeeping savings: ' .. fmt(r))
  T.ok(r.total < 25, fmt(r))
  T.ok(m.economy.runs >= 6 and m.care.runs >= 12, 'economy ' .. m.economy.runs .. ', care ' .. m.care.runs .. ' runs')
end)

---------------------------------------------------------------- load
T.test('load: K.load from the census and items.all; economy and care stretched (at most x3), ctx.load', function()
  local W = L.world{tag = 'load'}
  local sense = {name = 'sense', every = {ticks = 9}, critical = true}
  function sense.step(K) K.census.u = {units = 402, cit = 5} end
  local eco = H.counter('economy', {ticks = 1200})
  local care = H.counter('care', {ticks = 1200})
  local water = H.counter('water', {ticks = 1200})
  local trade = H.counter('trade', {ticks = 1200}, {scale = true})
  H.boot(W, {modules = {sense, eco, care, water, trade}})
  local K = kern.K()
  frames(W, 600)                                  -- 6 s: the load is refreshed with sense's unit count
  local l = K.load()
  T.eq({l.units, l.items}, {402, 18743})
  T.ok(math.abs(l.f - 3.12) < 0.01, 'f ' .. l.f)
  T.eq(kern.budget(), 35)
  local n0 = {#eco.runs, #care.runs, #water.runs, #trade.runs}
  H.run(W, 7200, {skip = 9})
  T.eq(#eco.runs - n0[1], 2, 'economy every 3,600 ticks (x3, capped)')
  T.eq(#care.runs - n0[2], 2)
  T.eq(#water.runs - n0[3], 6, 'water is not scaled')
  T.eq(#trade.runs - n0[4], 2, 'module field scale = true')
  T.ok(math.abs(eco.runs[#eco.runs].ctx.load - 3.12) < 0.01, 'ctx.load')
  T.ok(H.read(W.sd .. '/kern.log'):find('economy cadence x3.0 for the fort size', 1, true))
  H.inbox(W, 'im', 'inspect', {what = 'modules'}, 'cli')
  frames(W, 60)
  local data = H.outbox(W, 'im').data
  T.eq(data.budget, 35)
  T.eq(data.load, {units = 402, items = 18743, f_pct = 312})
  for _, m in ipairs(data.modules) do
    if m.name == 'economy' then T.eq({m.stretch_pct, m.share}, {300, 3}) end
    if m.name == 'sense' then T.eq({m.stretch_pct, m.share}, {100, nil}) end
  end
  kern.stop('test')
  T.eq(sched.budget(sched.load(150, 100)), 25)
  T.eq(sched.budget(sched.load(2000, 100)), 40, 'capped')
  T.eq(sched.load(-1, 0).f, 1)
end)

---------------------------------------------------------------- pacing
T.test('pacing: a sliced hog stays within its share (x4 outside PEACE); cheap and critical modules never wait', function()
  local W = H.world{tag = 'pace', ms_per_frame = 10}
  local hog = {name = 'seal', every = {ticks = 50}, n = 0}
  function hog.step() hog.n = hog.n + 1; W.ms = W.ms + 1; return 'more' end
  local cheap = H.counter('drill', {ticks = 100})
  local crit = H.counter('sense', {ticks = 9})
  H.boot(W, {modules = {crit, cheap, hog}})
  frames(W, 1000)
  local c0 = kern.costs()
  frames(W, 6000)
  local r = rates(c0, kern.costs())
  T.ok(r.seal <= 4.2 and r.seal >= 3.5, 'seal ' .. r.seal .. ' ms/s (share 4)')
  T.ok(module_info('seal').paced > 4000, 'its slices waited')
  T.eq(module_info('drill').paced, 0)
  T.eq(module_info('sense').paced, 0)
  T.ok(#crit.runs >= 3300, 'sense every 9 ticks: ' .. #crit.runs)
  T.ok(H.read(W.sd .. '/kern.log'):find('seal paced: over its share of 4 ms/s', 1, true))
  kern.K().set_mode('ALERT', 'test')
  frames(W, 200)
  c0 = kern.costs()
  frames(W, 3000)
  r = rates(c0, kern.costs())
  T.ok(r.seal > 12 and r.seal <= 16.5, 'ALERT: share x4, got ' .. r.seal)
  kern.stop('test')
end)

T.test('pacing: the PEACE pool scales the shares of the saturated modules to what the critical ones leave', function()
  local W = H.world{tag = 'pool', ms_per_frame = 10}
  local seal = {name = 'seal', every = {ticks = 50}}
  function seal.step() W.ms = W.ms + 1; return 'more' end
  local eco = {name = 'economy', every = {ticks = 50}}
  function eco.step() W.ms = W.ms + 1; return 'more' end
  local crit = {name = 'reflex', every = {ticks = 1}}   -- 0.17 ms per 10 ms frame: ~17 ms/s nobody may pace
  function crit.step() W.ms = W.ms + 0.17 end
  H.boot(W, {modules = {crit, seal, eco}})
  frames(W, 2000)
  local c0 = kern.costs()
  frames(W, 6000)
  local r = rates(c0, kern.costs())
  T.ok(r.reflex > 15 and r.reflex < 18, 'reflex ' .. r.reflex)
  -- pool = 25 - 16.7 = 8.3 >= shares 4 + 3: no scaling yet
  T.ok(r.seal > 3.5 and r.economy > 2.5 and r.total <= 25.5, fmt(r))
  function crit.step() W.ms = W.ms + 0.23 end           -- ~23 ms/s: the pool falls to its minimum, 4
  frames(W, 2000)
  c0 = kern.costs()
  frames(W, 6000)
  r = rates(c0, kern.costs())
  T.ok(r.seal + r.economy <= 4.5 and r.seal >= 1.5 and r.economy >= 1.2, 'scaled to the pool: ' .. fmt(r))
  H.inbox(W, 'ip', 'inspect', {what = 'perf'}, 'cli')
  frames(W, 60)
  local d = H.outbox(W, 'ip').data
  T.eq(d.pool_ms_s, 4)
  T.ok(d.pool_pct >= 50 and d.pool_pct <= 60, 'g ' .. d.pool_pct)
  kern.stop('test')
end)

---------------------------------------------------------------- hysteresis
-- 10 s frames of 1 tick: a slow call per frame
T.test('hysteresis: KERNEL_SLOW once per module; a flip doubles the quiet time the next promotion needs', function()
  local W = H.world{tag = 'flip', ms_per_frame = 10000}
  local eco = {name = 'economy', every = {ticks = 1}, slow = true, share = 1e6}
  function eco.step() if eco.slow then W.ms = W.ms + 6 end end
  H.boot(W, {modules = {eco}})
  local function factor() return module_info('economy').factor end
  H.run(W, 4)
  T.eq(factor(), 2)
  T.eq(#H.find(H.events(W), 'KERNEL_SLOW'), 1)
  eco.slow = false
  H.run(W, 61)                                   -- 10 quiet minutes
  T.eq(factor(), 1, 'promoted')
  eco.slow = true                                -- slow again within the hour: a flip
  H.run(W, 4)
  T.eq(factor(), 2)
  T.eq(#H.find(H.events(W), 'KERNEL_SLOW'), 1, 'not reported again')
  T.ok(H.read(W.sd .. '/kern.log'):find('economy demoted x2 %(6 ms; already reported; promotion after 20 quiet min%)'))
  eco.slow = false
  H.run(W, 90)                                   -- 15 quiet minutes are not enough now
  T.eq(factor(), 2)
  H.run(W, 40)
  T.eq(factor(), 1, 'promoted after 20 quiet minutes')
  kern.stop('test')
end)

T.test('hysteresis: quiet time only counts while the module could run (a paused game does not promote a tick module)', function()
  local W = H.world{tag = 'flip2', ms_per_frame = 10000}
  local eco = {name = 'economy', every = {ticks = 1}, slow = true, share = 1e6}
  function eco.step() if eco.slow then W.ms = W.ms + 6 end end
  H.boot(W, {modules = {eco}})
  H.run(W, 4)
  eco.slow = false
  df.global.pause_state = true
  H.run(W, 90, {paused = true})
  df.global.pause_state = false
  T.eq(module_info('economy').factor, 2, 'paused 15 min: still demoted')
  H.run(W, 61)
  T.eq(module_info('economy').factor, 1)
  kern.stop('test')
end)

---------------------------------------------------------------- cost owners
T.test('cost owners: k.state, k.io, persist by owner; big keys wait 60 s; a mode change flushes all', function()
  local W = H.world{tag = 'owners', ms_per_frame = 100}
  local fio = require('dfllm.io')
  local write, append = fio.write, fio.append
  fio.write = function(p, s)
    if p:find('state%.[ab]%.json$') then W.ms = W.ms + 2 elseif p:find('heartbeat$') then W.ms = W.ms + 1 end
    return write(p, s)
  end
  fio.append = function(p, s, m) W.ms = W.ms + 1; return append(p, s, m) end
  local saves = {}
  local save = dfhack.persistent.saveSiteDataString
  dfhack.persistent.saveSiteDataString = function(k, v)
    saves[k] = (saves[k] or 0) + 1
    if k == 'dfllm.m.economy' then W.ms = W.ms + 3 end
    return save(k, v)
  end
  local big = string.rep('x', 9000)
  local eco = {name = 'economy', every = {ticks = 1}, share = 1e6}
  function eco.step(K) K.persist.set('m.economy', {v = 2, blob = big, t = K.now().tick}) end
  local run = {name = 'runner', every = {ticks = 1}}
  function run.step(K) K.persist.set('m.runner', {v = 2, t = K.now().tick}) end
  local ok, err = pcall(function()
    H.boot(W, {modules = {eco, run, require('dfllm.perf')}})
    local c0 = kern.costs()
    saves = {}
    H.run(W, 1000)                                -- 100 s
    local c1 = kern.costs()
    T.ok(saves['dfllm.m.runner'] >= 9 and saves['dfllm.m.runner'] <= 11, 'small key every 10 s: ' .. saves['dfllm.m.runner'])
    T.ok(saves['dfllm.m.economy'] >= 1 and saves['dfllm.m.economy'] <= 2, 'big key at most every 60 s: ' .. saves['dfllm.m.economy'])
    T.ok(c1.mods.economy - (c0.mods.economy or 0) >= 3 * saves['dfllm.m.economy'], 'the write is booked to economy')
    T.ok((c1.mods['k.state'] or 0) - (c0.mods['k.state'] or 0) >= 90, 'state writes: k.state')
    T.ok((c1.mods['k.io'] or 0) - (c0.mods['k.io'] or 0) >= 19, 'heartbeat every 5 s: k.io')
    local n = saves['dfllm.m.economy']
    kern.K().set_mode('ALERT', 'test')
    H.run(W, 1)
    T.eq(saves['dfllm.m.economy'], n + 1, 'a mode change writes every dirty key')
    local row = H.lines(W.sd .. '/perf.csv')[2]
    T.ok(row:find('k%.state=%d+') and row:find('economy=%d+'), row)
    kern.stop('test')
  end)
  fio.write, fio.append, dfhack.persistent.saveSiteDataString = write, append, save
  assert(ok, err)
end)

T.test("repeat: DFHack's counter for the whole frame callback is a cross-check column, not added to ms_s", function()
  local W = H.world{tag = 'repeat', ms_per_frame = 20}
  local n = 0
  dfhack.internal.getPerfCounters = function()
    n = n + 1
    return {}, {}, {}, {}, {}, {dfllm = 700 * n}
  end
  local m = H.counter('test_c', {ticks = 10}, {share = 1e6})
  local base = m.step
  m.step = function(K, b, ctx) base(K, b, ctx); W.ms = W.ms + 1 end
  H.boot(W, {modules = {m, require('dfllm.perf')}})
  H.run(W, 1600 * 9, {skip = 9})
  kern.stop('test')
  dfhack.internal.getPerfCounters = function() return {} end
  local f = {}
  for x in (H.lines(W.sd .. '/perf.csv')[2] .. ','):gmatch('([^,]*),') do f[#f + 1] = x end
  T.ok(f[11]:find('repeat=700'), f[11])
  local ms_s = tonumber(f[8])
  T.ok(ms_s >= 20 and ms_s <= 28, 'ms_s is the kernel total only: ' .. f[8])
end)

---------------------------------------------------------------- selftest
-- 1 s frames; n critical test modules of cost_ms each (under the 5 ms slow mark): ~n * cost_ms ms/s
local function selftest_run_(tag, n, cost_ms, minutes)
  local W = H.world{tag = tag, ms_per_frame = 1000}
  local mods = {}
  for i = 1, n do
    local m = {name = 'test_c' .. i, every = {ticks = 1}, critical = true}
    function m.step(K) K.census.u = {units = 402, cit = 5}; W.ms = W.ms + cost_ms end
    mods[i] = m
  end
  local st = fresh('selftest')
  mods[#mods + 1] = st
  H.boot(W, {modules = mods})
  H.run(W, minutes * 60)
  local r = st.run(kern.K(), 'quick')
  local log = H.read(W.sd .. '/kern.log') or ''
  kern.stop('test')
  return r, log, st
end

local function selftest_run(...) return no_inbox(selftest_run_, ...) end

T.test('selftest budget: a healthy large fort passes against its budget; a real overrun names the owner', function()
  local r, log = selftest_run('st-ok', 6, 4.8, 4)          -- ~29 ms/s on 402 units: over 25, under 35
  T.eq(r.failed, {}, 'healthy large fort')
  T.ok(not log:find('selftest quick failed', 1, true), log)
  local r2, log2, st = selftest_run('st-bad', 10, 4.7, 12) -- ~45 ms/s: a real overrun
  T.eq(r2.failed, {'budget'})
  T.ok(r2.detail.budget:find('^4%d ms/s > 35 for 402 units over %d+ s %(top test_c%d+ 5, test_c%d+ 5, test_c%d+ 5%)'),
       r2.detail.budget)
  local n = select(2, log2:gsub('selftest quick failed: budget', ''))
  T.eq(n, 2, 'logged when it starts and again after 10 min, not every minute')
  T.ok(st.describe(r2):find('^budget %(4%d ms/s'), st.describe(r2))
end)

---------------------------------------------------------------- sense and economy paths
T.test('sense: an inactive unit costs one call per scan; raws read once per race/caste; entrances on demand', function()
  local W = L.world{tag = 'sense', mix = {citizens = 1, tame = 0, wild = 0, visitors = 0, dead = 100}}
  local sense = fresh('sense')
  local seal = {name = 'seal', every = {ticks = 600000}, asked = 0}
  function seal.entrances() seal.asked = seal.asked + 1; return {{1, 1, 100}}, 25 end
  H.boot(W, {modules = {sense, seal}})
  H.run(W, 45, {skip = 9})                       -- the first scan (also the unit count)
  L.count_unit_calls(W)
  H.run(W, 45, {skip = 9})                       -- one ordinary scan, no citizen scan
  T.eq(W.unit_calls, 100 + 6, '100 dead units: 1 call each; the citizen: isActive, isUndead, isDanger (+2), isTame')
  T.eq(seal.asked, 0, 'no predator candidate: entrances never fetched')
  kern.stop('test')
  -- wild animals of 4 race/caste pairs (race 21 a large predator) and the citizen: raws read once per pair,
  -- the entrances once per scan with a candidate
  W = L.world{tag = 'sense2', mix = {citizens = 1, tame = 0, wild = 60, visitors = 0, dead = 0}}
  W.map_size = {20, 20, 200}
  dfhack.maps.getWalkableGroup = function() return 7 end
  for race = 20, 23 do
    local r = df.creature_raw.find(race)
    r.caste[0].flags.LARGE_PREDATOR, r.caste[1].flags.LARGE_PREDATOR = race == 21, race == 21
  end
  W.raw_finds = 0
  sense, seal.asked = fresh('sense'), 0
  H.boot(W, {modules = {sense, seal}})
  H.run(W, 45 * 20, {skip = 9})
  T.eq(W.raw_finds, 5, 'raws read once per race/caste pair')
  T.ok(seal.asked >= 18 and seal.asked <= 21, 'entrances once per scan: ' .. seal.asked)
  kern.stop('test')
end)

T.test('economy: one flag-word read per item instead of eight; a disagreeing mask falls back to flag reads', function()
  local BITS = {trader = 1, garbage_collect = 2, removed = 3, dump = 4, hostile = 5, in_building = 6,
                construction = 7, rotten = 8, forbid = 9, in_inventory = 10}
  local function census(liar)
    local W = F.world{cfg = {baseline = F.cfg()}, units = {{id = 1, citizen = true}}}
    W.set_census('u', F.census_u({1}))
    df.item_flags = BITS
    local reads = 0
    for i = 1, 200 do
      local set = {rotten = i % 10 == 0, in_inventory = i % 3 == 0}
      local whole = 0
      for k, on in pairs(set) do if on then whole = whole | (1 << BITS[k]) end end
      if liar then whole = whole | (1 << BITS.trader) end
      F.item(W, 'BOULDER', {flags = setmetatable({}, {__index = function(_, k)
        reads = reads + 1
        if k == 'whole' then return whole end
        return set[k] == true
      end})})
    end
    local E = fresh('economy')
    E.MASK_CHECK = 20
    W.load(E)
    W.run(1)
    for _ = 1, 40 do W.run(1) end
    df.item_flags = nil
    return W, reads
  end
  local W, reads = census(false)
  local W2, slow = census(true)
  T.eq(W.K.census.i.boulders, 200)
  T.eq(W.K.census.i.rock, W2.K.census.i.rock, 'same census with and without the mask')
  print(string.format('# flag reads for 200 boulders: %d with the mask, %d with per-flag reads', reads, slow))
  T.ok(reads <= 200 * 3 + 20 * 8, 'flag reads with the mask: ' .. reads)
  T.ok(slow >= 200 * 8, 'per-flag reads after a disagreement: ' .. slow)
  local warned = false
  for _, l in ipairs(W2.logs) do if tostring(l.msg):find('flag mask disagreed', 1, true) then warned = true end end
  T.ok(warned, 'logged')
end)

T.done()
