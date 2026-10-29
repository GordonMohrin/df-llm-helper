-- BUG-033 (Run 11, Kilrudrabed site98 y438, kernel e3a62ab): for months `dfllm audit` got 'snapshot refused: export
-- queue full', `bp sites --fresh --timeout 150` 'no snapshot within 150s', readiness audit_old 4.5 years.
-- 1. The real kernel: the other modules' snapshot queries (tile, liquids, far) were booked to snapshot's pacing debt,
--    so its export slices waited for good. A K.call is now the caller's cost (booked, paced), with an edge record.
-- 2. The queue: who asked, dedup by purpose and box, inbox requests first (boosted), a full queue names who holds it,
--    stale/stalled/faulting exports dropped, a capped busy wait, state `snap`, readiness and economy ask less.
local T = require('testlib')
local H = require('kern_world')
local SW = require('snapshot_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local kern = require('dfllm.kern')
local sched = require('dfllm.util.sched')
local C = require('dfllm.util.contract')

local Z = 10
local function fresh_snapshot() package.loaded['dfllm.snapshot'] = nil; return require('dfllm.snapshot') end
local function esc(x) return (tostring(x):gsub('%p', '%%%0')) end

---------------------------------------------------------------- the real kernel (cost clock = W.ms)
-- a 64 x 64 x 20 revealed floor map; every getTileFlags costs `tile_us` on the cost clock
local function kworld(tag, tile_us)
  local W = H.world{tag = tag, ms_per_frame = 10}
  SW.install(W, {map_size = {4, 4, 20}})
  local rows = {}
  for y = 1, 64 do rows[y] = string.rep('.', 64) end
  for z = 0, 19 do SW.draw(W, z, rows, 0, 0) end
  local gtf = dfhack.maps.getTileFlags
  dfhack.maps.getTileFlags = function(...) W.ms = W.ms + (tile_us or 5) / 1000; return gtf(...) end
  return W
end

local function ready(W, id)
  for _, e in ipairs(H.find(H.events(W), 'SNAPSHOT_READY')) do if e.d.id == id then return e end end
end

-- frames of ~4.5 ticks at 100 frames/s until the snapshot `id` is written (or secs pass): the frame or nil
local function until_ready(W, id, secs)
  for f = 1, secs * 100 do
    H.frame(W, f % 2 == 0 and 4 or 5)
    if f % 50 == 0 and ready(W, id) then return f end
  end
end

local function rates(c0, c1)
  local dt = (c1.at - c0.at) / 1000
  local r = {}
  for k, v in pairs(c1.mods) do r[k] = (v - (c0.mods[k] or 0)) / dt end
  for k, v in pairs(c1.via or {}) do r[k] = (v - ((c0.via or {})[k] or 0)) / dt end
  return r
end

local function no_inbox(f, ...)
  local saved = kern.CAD.inbox_ms
  kern.CAD.inbox_ms = 1e12
  local r = table.pack(pcall(f, ...))
  kern.CAD.inbox_ms = saved
  assert(r[1], r[2])
  return table.unpack(r, 2, r.n)
end

-- a runner stand-in that reads `n` tiles through snapshot.tile each run (the probes, the shaft check, ...)
local function querier(n)
  local m = {name = 'runner', every = {ticks = 600}, runs = 0}
  function m.step(K)
    m.runs = m.runs + 1
    for i = 1, n do K.call('snapshot', 'tile', i % 64, (i // 64) % 64, 5) end
  end
  return m
end

T.test('BUG-033 live: 1500 snapshot.tile reads per runner run no longer keep an 81,920-tile export waiting', function()
  no_inbox(function()
    local W = kworld('starve')
    local q = querier(1500)                       -- 7.5 ms of queries per run (5 us a tile), every 600 ticks
    local snap = fresh_snapshot()
    assert(H.boot(W, {modules = {q, snap}}))
    local K = kern.K()
    local _, ok, id = K.call('snapshot', 'export', {purpose = 'audit', bbox = {0, 0, 0, 63, 63, 19}, by = 'readiness'})
    T.eq(ok, true)
    local c0 = kern.costs()
    local f = until_ready(W, id, 300)
    T.ok(f, 'the export finishes (the old kernel: never, the queries kept snapshot over its share)')
    T.ok(f / 100 <= 120, 'within 2 min at snapshot\'s own share: ' .. (f / 100) .. ' s')
    local r = rates(c0, kern.costs())
    T.ok((r.runner or 0) <= sched.PACE.shares.runner + 0.5, 'the caller pays for its queries, paced: ' .. T.show(r))
    T.ok((r['runner>snapshot'] or 0) >= 0.9 * (r.runner or 0) and (r.runner or 0) > 0.3,
         'the edge names whose queries (all of the runner\'s time here): ' .. T.show(r))
    T.ok((r.snapshot or 0) <= sched.PACE.shares.snapshot + 0.5, 'snapshot: only its export ' .. T.show(r))
    T.ok(q.runs >= 10, 'the querier keeps running (paced and demoted for its 7.5 ms runs): ' .. q.runs)
    kern.stop('test')
  end)
end)

T.test('BUG-033: a K.call is booked to and paced for the caller, demotes nobody; the edge goes to perf.csv and inspect', function()
  no_inbox(function()
    local W = H.world{tag = 'via', ms_per_frame = 20}
    local svc = {name = 'snapshot', every = {ms = 100000}}
    function svc.tile() W.ms = W.ms + 2 end                -- 2 ms per query
    function svc.step() end
    local caller = {name = 'economy', every = {ticks = 10}, share = 1e6}
    function caller.step(K) K.call('snapshot', 'tile', 1, 1, 1) end
    local crit = {name = 'reflex', every = {ticks = 10}, critical = true}
    function crit.step(K) K.call('snapshot', 'tile', 1, 1, 1) end
    H.boot(W, {modules = {crit, caller, svc, require('dfllm.perf')}})
    H.run(W, 1600 * 9, {skip = 9})                       -- 32 s: one perf.csv row
    local c = kern.costs()
    T.ok(c.mods.economy >= 1500 and c.mods.reflex >= 1500, 'callers: ' .. T.show(c.mods))
    T.ok((c.mods.snapshot or 0) < 1, 'nothing booked to the service: ' .. tostring(c.mods.snapshot))
    T.ok(c.via['economy>snapshot'] >= 1500 and c.via['reflex>snapshot'] >= 1500, T.show(c.via))
    local st = kern.status()
    for _, m in ipairs(st.modules) do
      if m.name == 'snapshot' then T.ok(m.ms < 1, 'snapshot ms ' .. m.ms) end
    end
    local row = H.lines(W.sd .. '/perf.csv')[2]
    T.ok(row:find('economy>snapshot=%d+') and row:find('reflex>snapshot=%d+') and row:find('economy=%d+'), row)
    local ms_s = tonumber(row:match('^[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,([^,]*),'))
    T.ok(ms_s >= 80 and ms_s <= 110, 'the edges are not added to the total (2 x 2 ms every 2nd frame): ' .. ms_s)
    H.inbox(W, 'im', 'inspect', {what = 'modules'}, 'cli')
    kern.CAD.inbox_ms = 500
    H.run(W, 30, {skip = 9})
    kern.CAD.inbox_ms = 1e12
    for _, m in ipairs(H.outbox(W, 'im').data.modules) do
      if m.name == 'snapshot' then T.ok((m.svc or 0) >= 3000, 'svc ' .. tostring(m.svc)) end
    end
    -- 6-ms queries demote nobody: the service did not choose them, and a slow call is judged on the caller's own code
    -- (the queries are paced as its cost); a caller whose own code is slow is demoted, the message names its calls
    function svc.tile() W.ms = W.ms + 6 end
    H.run(W, 60, {skip = 9})
    for _, m in ipairs(kern.status().modules) do
      if m.name == 'snapshot' or m.name == 'economy' then T.eq(m.factor, 1, m.name .. ' not demoted') end
    end
    T.eq(#H.find(H.events(W), 'KERNEL_SLOW'), 0)
    T.eq(#H.find(H.events(W), 'KERN_FAULT'), 0, 'no KERN_FAULT slow for reflex\'s slow queries')
    function caller.step(K) K.call('snapshot', 'tile', 1, 1, 1); W.ms = W.ms + 7 end
    H.run(W, 900, {skip = 9})                             -- 2 s: the B event is flushed
    local ks = H.find(H.events(W), 'KERNEL_SLOW')
    T.ok(#ks == 1 and ks[1].msg:find('^economy demoted x2 %(%+6 ms in snapshot calls%)'), T.show(ks))
    local s = H.state(W)
    T.ok(s.k.top and (s.k.top:find('^economy %d+ %(snapshot %d+%)') or s.k.top:find('^reflex %d+ %(snapshot %d+%)')),
         'state k.top: ' .. tostring(s.k.top))
    kern.stop('test')
  end)
end)

T.test('BUG-033: a fault in a service call still counts against the service', function()
  local W = H.world{tag = 'viafault', ms_per_frame = 20}
  local svc = {name = 'snapshot', every = {ms = 100000}}
  function svc.tile() error('boom') end
  function svc.step() end
  local caller = {name = 'economy', every = {ticks = 10}}
  function caller.step(K) caller.r = {K.call('snapshot', 'tile', 1, 1, 1)} end
  H.boot(W, {modules = {caller, svc}, strict = false})
  H.run(W, 40, {skip = 9})
  T.eq(caller.r[1], false)
  for _, m in ipairs(kern.status().modules) do
    if m.name == 'snapshot' then T.eq(m.disabled, true, 'backed off after 3 faults') end
    if m.name == 'economy' then T.eq(m.faults, 0) end
  end
  kern.stop('test')
end)

T.test('BUG-033: an inbox export runs boosted (12 ms/s) ahead of a running kernel export, which resumes after', function()
  no_inbox(function()
    local W = kworld('boost', 8)
    local snap = fresh_snapshot()
    assert(H.boot(W, {modules = {snap}}))
    local K = kern.K()
    local _, ok, bg = K.call('snapshot', 'export', {purpose = 'audit', bbox = {0, 0, 0, 63, 63, 19}, by = 'readiness'})
    T.eq(ok, true)
    for f = 1, 500 do H.frame(W, f % 2 == 0 and 4 or 5) end          -- 5 s: the kernel export is under way
    kern.CAD.inbox_ms = 500
    H.inbox(W, 'aud1', 'snapshot', {purpose = 'audit', bbox = {0, 0, 0, 63, 63, 9}}, 'cli')
    for f = 1, 300 do H.frame(W, f % 2 == 0 and 4 or 5) end
    kern.CAD.inbox_ms = 1e12
    local rep = H.outbox(W, 'aud1')
    T.eq(rep.ok, true)
    T.ok(rep.msg:find('^queued snapshot aud1 %(next behind ' .. esc(bg) .. ' audit by readiness %d+%% for 5 s%)$'), rep.msg)
    local m
    for _, x in ipairs(kern.status().modules) do if x.name == 'snapshot' then m = x end end
    T.eq(m.boost, 'export aud1 for inbox:cli')
    local s = H.state(W)
    T.eq({s.snap.run, s.snap.p, s.snap.by, s.snap.q}, {'aud1', 'audit', 'inbox:cli', 2})
    local c0 = kern.costs()
    local f = until_ready(W, 'aud1', 120)
    T.ok(f and f / 100 <= 40, 'the 40,960 tiles at 8 us within 40 s (boost share 12 ms/s): ' .. tostring(f))
    local r = rates(c0, kern.costs())
    T.ok(r.snapshot >= 9 and r.snapshot <= 12.5, 'boosted: ' .. r.snapshot)
    T.eq(ready(W, bg), nil, 'the kernel export waits')
    f = until_ready(W, bg, 300)
    T.ok(f, 'and resumes where it stopped')
    T.eq(#H.find(H.events(W), 'SNAPSHOT_READY'), 2)
    for _, x in ipairs(kern.status().modules) do if x.name == 'snapshot' then T.eq(x.boost, nil, 'unboosted') end end
    local log = H.read(W.sd .. '/kern.log')
    T.ok(log:find('snapshot: ' .. esc(bg) .. ' %(audit by readiness%) waits at %d+%% for aud1 %(audit by inbox:cli%)'), log)
    T.ok(log:find('snapshot boosted: export aud1 for inbox:cli', 1, true), 'boost logged')
    T.ok(log:find('snapshot: aud1 (audit, 40960 tiles, by inbox:cli) written', 1, true), 'written logged')
    kern.stop('test')
  end)
end)

T.test('BUG-033: a site-data record of 64 KB or more is named once in kern.log; inspect persist lists the sizes', function()
  no_inbox(function()
    local W = H.world{tag = 'bigkey', ms_per_frame = 100}
    local eco = {name = 'economy', every = {ticks = 10}, share = 1e6}
    local blob = string.rep('x', 70000)
    function eco.step(K) K.persist.set('m.economy', {v = 2, blob = blob, t = K.now().tick}) end
    H.boot(W, {modules = {eco}})
    H.run(W, 2000, {skip = 10})                     -- 20 s: written more than once
    kern.CAD.inbox_ms = 500
    H.inbox(W, 'ip', 'inspect', {what = 'persist'}, 'cli')
    H.run(W, 20, {skip = 10})
    kern.CAD.inbox_ms = 1e12
    local log = H.read(W.sd .. '/kern.log')
    local n = select(2, log:gsub('persist m%.economy: 68 KB encoded %(its owner pays each write, at most every 60 s%)', ''))
    T.eq(n, 1, log)
    local d = H.outbox(W, 'ip').data
    T.ok(d.bytes['m.economy'] >= 70000, T.show(d.bytes))
    kern.stop('test')
  end)
end)

---------------------------------------------------------------- the queue (k_mock, as test_snapshot.lua)
local function tmpdir()
  local dir = (os.getenv('TEMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests/test_snapshot_queue'
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock/snap')
  for _, n in ipairs(luahost.listdir(dir .. '/dfllm-runtime/mock/snap')) do os.remove(dir .. '/dfllm-runtime/mock/snap/' .. n) end
  return dir
end

local function world(strict)
  local dir = tmpdir()
  local W = kmock.new{ms_per_frame = 100, dfpath = dir, strict = strict}
  W.dir = dir
  SW.install(W)
  local rows = {}
  for y = 1, 8 do rows[y] = '#.........' end
  SW.draw(W, Z, rows, 0, 0)
  local S = fresh_snapshot()
  W.load(S)
  return W, S
end

local function written(W, id)
  for _, e in ipairs(W.find_events('SNAPSHOT_READY')) do if e.d.id == id then return e end end
end
local function file(W, id)
  local f = io.open(W.dir .. '/dfllm-runtime/mock/snap/' .. id .. '.json', 'rb')
  if not f then return nil end
  local d = json.decode(f:read('a'))
  f:close()
  return d
end
local function warns(W, pat)
  local r = {}
  for _, l in ipairs(W.logs) do if l.msg:find(pat) then r[#r + 1] = l.msg end end
  return r
end
local function frames(W, n) for _ = 1, n do W.frame(0, true) end end

T.test('BUG-033: the same purpose and box (or one inside a waiting one) is one scan with a file per request', function()
  local W, S = world()
  local K = W.K
  local _, ok0, run = K.call('snapshot', 'export', {purpose = 'debug', bbox = {0, 0, Z, 9, 0, Z}, by = 'economy'})
  T.eq(ok0, true)
  local r1 = W.inbox('snapshot', {purpose = 'audit', bbox = {0, 0, Z, 9, 3, Z}}, {id = 'aud1', by = 'cli'})
  T.ok(r1.ok and r1.msg:find('next behind ' .. run .. ' debug by economy', 1, true), r1.msg)
  local _, ok2, id2, note2 = K.call('snapshot', 'export', {purpose = 'audit', bbox = {0, 0, Z, 9, 3, Z}, by = 'readiness'})
  T.eq({ok2, note2}, {true, 'joins aud1 (audit by inbox:cli, 40 tiles)'})
  local _, ok3, id3, note3 = K.call('snapshot', 'export', {purpose = 'audit', bbox = {0, 0, Z, 9, 7, Z}, by = 'readiness'})
  T.eq({ok3, note3}, {true, 'joins aud1 (audit by inbox:cli, 80 tiles)'}, 'a bigger box grows the waiting one')
  local r4 = W.inbox('snapshot', {purpose = 'sites', bbox = {0, 0, Z, 9, 3, Z}}, {id = 'st4', by = 'cli'})
  T.ok(r4.ok and r4.msg:find('in line 2', 1, true), 'another purpose is its own export: ' .. r4.msg)
  local scans = 0
  local scan = S.is_sand
  S.is_sand = function(...) return scan(...) end
  local gtf = dfhack.maps.getTileFlags
  dfhack.maps.getTileFlags = function(...) scans = scans + 1; return gtf(...) end
  frames(W, 20)
  dfhack.maps.getTileFlags = gtf
  for _, id in ipairs({run, 'aud1', id2, id3, 'st4'}) do T.ok(written(W, id), 'written: ' .. id) end
  T.eq(scans, 10 + 80 + 40, 'three scans (debug, the joined audit box, sites), not five')
  local a, b = file(W, 'aud1'), file(W, id3)
  T.eq({a.id, b.id, a.purpose, b.purpose}, {'aud1', id3, 'audit', 'audit'}, 'each file carries its own id')
  T.eq({a.bbox, b.bbox}, {{0, 0, Z, 9, 7, Z}, {0, 0, Z, 9, 7, Z}})
  T.eq(a.rows, b.rows)
  T.ok(written(W, id2).msg:find('by readiness', 1, true), written(W, id2).msg)
end)

T.test('BUG-033: a full queue: an inbox request pushes the newest kernel request out; else the refusal names it', function()
  local W, S = world()
  local K = W.K
  local ids = {}
  for i = 0, S.CFG.queue do
    local _, ok, id = K.call('snapshot', 'export', {purpose = 'debug', bbox = {i, 0, Z, i, 0, Z}, by = 'readiness'})
    T.eq(ok, true)
    ids[#ids + 1] = id
  end
  local r = W.inbox('snapshot', {purpose = 'audit', bbox = {0, 5, Z, 9, 5, Z}}, {id = 'aud1', by = 'cli'})
  T.ok(r.ok and r.msg:find('(next behind ' .. ids[1] .. ' debug by readiness 0% for 0 s', 1, true), r.msg)
  local w = warns(W, '^snapshot: dropped ')
  T.eq(#w, 1)
  T.ok(w[1]:find('^snapshot: dropped ' .. esc(ids[#ids]) .. ' %(debug, 1 tiles, by readiness, asked 0 s ago%): the queue was '
                 .. 'full and aud1 %(audit by inbox:cli%) goes first'), w[1])
  for i = 1, 3 do T.eq(W.inbox('snapshot', {purpose = 'audit', bbox = {0, i, Z, 9, i, Z}}, {id = 'a' .. i, by = 'cli'}).ok, true) end
  local full = W.inbox('snapshot', {purpose = 'sites', bbox = {0, 6, Z, 9, 6, Z}}, {id = 'st9', by = 'cli'})
  T.eq(full.ok, false)
  T.ok(full.msg:find('^export queue full: running ' .. esc(ids[1]) .. ' debug by readiness 0%% for 0 s; '
                     .. 'queued 4: aud1 audit by inbox:cli 0 s, a1 audit by inbox:cli 0 s, a2 audit by inbox:cli 0 s, %.%.%.'),
       full.msg)
  T.ok(#full.msg <= 300)
  T.eq(full.data, {queue = 5})
  local _, okk, why = K.call('snapshot', 'export', {purpose = 'debug', bbox = {0, 7, Z, 9, 7, Z}, by = 'economy'})
  T.eq(okk, false, 'a kernel request never pushes an inbox one out')
  T.ok(why:find('^export queue full: '), why)
  frames(W, 30)
  T.ok(written(W, 'aud1') and written(W, 'a3'), 'the inbox requests are written')
end)

T.test('BUG-033: stale requests, a stalled export and a slice that keeps failing are dropped; busy waits are capped',
       function()
  local W, S = world(false)
  local K = W.K
  -- trade holds a busy boost (the trade screen): the export waits, at most busy_max_ms
  local trade = {name = 'trade', every = {ms = 100}, busy = true}
  function trade.step(K2) if trade.busy then K2.boost('trade screen', true) else K2.unboost() end end
  W.load(trade)
  W.ms_per_frame = 1000
  frames(W, 1)
  local _, _, run = K.call('snapshot', 'export', {purpose = 'debug', bbox = {0, 0, Z, 9, 0, Z}, by = 'readiness'})
  local _, _, old = K.call('snapshot', 'export', {purpose = 'audit', bbox = {0, 1, Z, 9, 1, Z}, by = 'readiness'})
  frames(W, 60)                                         -- a minute of trade's busy boost: the export waits
  T.eq(written(W, run), nil)
  local s = W.state()
  T.eq({s.snap.run, s.snap.wait, s.snap.q}, {run, 'busy trade', 2})
  frames(W, 150)                                        -- busy_max_ms (3 min) passed: it goes on
  T.ok(written(W, run), 'goes on after the capped busy wait')
  T.eq(#warns(W, '^snapshot: export ' .. esc(run) .. ' goes on although trade is busy %(trade screen%): it waited 3 min'), 1)
  trade.busy = false
  frames(W, 5)
  T.ok(written(W, old), 'the next one ran after it')
  -- requests nobody started within max_age_ms are dropped at the next look (a step or a new request)
  local _, _, a1 = K.call('snapshot', 'export', {purpose = 'audit', bbox = {0, 2, Z, 9, 2, Z}, by = 'readiness'})
  local _, _, a2 = K.call('snapshot', 'export', {purpose = 'sites', bbox = {0, 3, Z, 9, 3, Z}, by = 'readiness'})
  W.ms = W.ms + S.CFG.max_age_ms.bg - W.ms_per_frame
  frames(W, 1)                                          -- the kernel's clock moves on with the frame
  local _, okn, a3 = K.call('snapshot', 'export', {purpose = 'debug', bbox = {0, 4, Z, 9, 4, Z}, by = 'economy'})
  T.eq(okn, true)
  T.eq(#warns(W, '^snapshot: dropped ' .. esc(a1) .. ' %(audit, 10 tiles, by readiness, asked 30 min ago%): not started '
              .. 'within 30 min'), 1)
  T.eq(#warns(W, '^snapshot: dropped ' .. esc(a2) .. ' %(sites, 10 tiles, by readiness, asked 30 min ago%): waited longer '
              .. 'than 30 min'), 1)
  frames(W, 3)
  T.ok(written(W, a3) and not written(W, a1) and not written(W, a2), 'only the fresh one is exported')
  -- a slice that fails: kept twice, then the export is dropped and the next one runs
  frames(W, 20)
  local _, _, bad = K.call('snapshot', 'export', {purpose = 'debug', bbox = {0, 3, Z, 9, 3, Z}, by = 'readiness'})
  local _, _, nxt = K.call('snapshot', 'export', {purpose = 'debug', bbox = {0, 4, Z, 9, 4, Z}, by = 'readiness'})
  local gtf = dfhack.maps.getTileFlags
  dfhack.maps.getTileFlags = function(x, y, z) if y == 3 then error('bad tile') end return gtf(x, y, z) end
  frames(W, 6)
  dfhack.maps.getTileFlags = gtf
  T.eq(written(W, bad), nil)
  T.eq(#warns(W, '^snapshot: dropped ' .. esc(bad) .. ' %(debug, 10 tiles, by readiness, asked %d+ s ago%): its slice failed '
              .. '2 times at z10 y3'), 1)
  T.ok(written(W, nxt), 'the queue goes on')
  T.ok(W.state().snap.drop >= 2, 'drops counted')
  -- a running export that gets no slice for stall_ms (the module backed off, held back): dropped at the next look
  local _, _, st = K.call('snapshot', 'export', {purpose = 'debug', bbox = {0, 5, Z, 9, 5, Z}, by = 'readiness'})
  W.ms = W.ms + S.CFG.stall_ms + 1000
  frames(W, 1)
  T.eq(#warns(W, '^snapshot: dropped ' .. esc(st)), 0, 'not started yet: its age counts, not a stall')
  S.CFG.slice = 10
  local _, _, st2 = K.call('snapshot', 'export', {purpose = 'debug', bbox = {0, 0, Z, 9, 7, Z}, by = 'economy'})
  frames(W, 3)                                          -- st2 runs a few rows
  W.ms = W.ms + S.CFG.stall_ms + 1000
  frames(W, 1)
  S.CFG.slice = 1000
  T.ok(written(W, st2) or #warns(W, '^snapshot: dropped ' .. esc(st2) .. '.-no slice for') == 1, 'stalled: dropped')
end)

T.test('BUG-033: economy\'s sand request is satisfied by any export; snapshot.pending; state snap is schema-shaped',
       function()
  local W = world()
  local K = W.K
  local _, ok, id = K.call('snapshot', 'export', {purpose = 'audit', bbox = {0, 0, Z, 9, 7, Z}, by = 'readiness'})
  T.eq(ok, true)
  local _, oka, ida, note = K.call('snapshot', 'export', {purpose = 'debug', by = 'economy', any = true})
  T.eq({oka, ida, note}, {true, id, 'an export runs already: ' .. id})
  T.eq(select(2, K.call('snapshot', 'pending', id)), true)
  T.eq(select(2, K.call('snapshot', 'pending', 'nope')), false)
  local s = W.state()
  T.eq({s.snap.q, s.snap.run, s.snap.p, s.snap.by, s.snap.done, s.snap.drop}, {1, id, 'audit', 'readiness', 0, 0})
  T.eq(C.check_state(s), {}, 'state valid')
  frames(W, 5)
  T.ok(written(W, id))
  T.eq(select(2, K.call('snapshot', 'pending', id)), false)
  s = W.state()
  T.eq({s.snap.q, s.snap.done, s.snap.run}, {0, 1, nil})
  local _, okb, idb = K.call('snapshot', 'export', {purpose = 'debug', by = 'economy', any = true})
  T.ok(okb and idb ~= id, 'nothing runs: a new export')
end)

T.test('BUG-033: readiness\' monthly audit waits while its last audit snapshot is still queued or exporting', function()
  local R = require('dfllm.readiness')
  T.ok(type(R) == 'table')
  local W = world()
  local S = package.loaded['dfllm.snapshot']
  local asked = {}
  local export = S.export
  S.export = function(K, opts) asked[#asked + 1] = opts.by; return export(K, opts) end
  local held = true
  local pending = S.pending
  S.pending = function(K, id) if held then return true end return pending(K, id) end
  W.K.persist.set('manifest', {v = 2, bridges = {O1 = {role = 'outer', fp = {4, 1, Z, 5, 1, Z}, levers = {{8, 3, Z}}}}})
  package.loaded['dfllm.readiness'] = nil
  W.load(require('dfllm.readiness'))
  W.run(2, {skip = 1})
  T.eq(asked, {'readiness'}, 'the first audit request')
  W.run(33600 + 10, {skip = 300})
  T.eq(asked, {'readiness'}, 'a month later: its snapshot still waits, no second request')
  T.ok(#warns(W, '^readiness: monthly audit waits for snapshot ') >= 1)
  held = false
  W.run(33600 + 10, {skip = 300})
  T.eq(#asked, 2, 'asked again once it was exported')
  S.export, S.pending = export, pending
end)

T.test('BUG-227 (live i3: "monthly audit waits for snapshot s153212559-1" 18 times in 50 s): the wait is logged once per ' ..
       'snapshot id', function()
  local W = world()
  local S = package.loaded['dfllm.snapshot']
  local export, pending = S.export, S.pending
  local held = true
  S.pending = function(K, id) if held then return true end return pending(K, id) end
  W.K.persist.set('manifest', {v = 2, bridges = {O1 = {role = 'outer', fp = {4, 1, Z, 5, 1, Z}, levers = {{8, 3, Z}}}}})
  package.loaded['dfllm.readiness'] = nil
  W.load(require('dfllm.readiness'))
  W.run(2, {skip = 1})
  W.run(2 * 33600 + 10, {skip = 300})
  T.eq(#warns(W, '^readiness: monthly audit waits for snapshot '), 1, 'live: one line every readiness run')
  held = false
  W.run(33600 + 10, {skip = 300})
  held = true
  W.run(2 * 33600 + 10, {skip = 300})
  T.eq(#warns(W, '^readiness: monthly audit waits for snapshot '), 2, 'a new snapshot: one more line')
  S.export, S.pending = export, pending
end)

T.done()
