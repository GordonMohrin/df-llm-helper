-- WP1 speed: kernel cost with 5 dummy modules (+ arbiter, perf, selftest), perf.csv rows,
-- PERF_DEGRADED (tps vs baseline, freezes), frame-gap blame.
local T = require('testlib')
local H = require('kern_world')
local kern = require('dfllm.kern')
local arbiter = require('dfllm.arbiter')
local perf = require('dfllm.perf')
local selftest = require('dfllm.selftest')

local function dummy(name, ticks)
  local M = {name = name, every = {ticks = ticks}, n = 0, acc = 0}
  function M.step(K) M.n = M.n + 1; for i = 1, 50 do M.acc = M.acc + i end end
  function M.state(K) return nil end
  return M
end

T.test('budget: kernel overhead with 5 dummy modules at 250 frames/s stays far below 25 ms/s', function()
  local W = H.world{tag = 'budget', ms_per_frame = 4}
  local mods = {dummy('sense', 10), dummy('threat', 25), dummy('test_c', 100), dummy('test_d', 600),
                dummy('test_e', 1200), arbiter, perf, selftest}
  H.boot(W, {modules = mods})
  local frames = 20000                    -- 80 s of game at 250 frames/s, 9 ticks per frame
  local t0 = luahost.now_ms()
  for _ = 1, frames do H.frame(W, 9) end
  local real = luahost.now_ms() - t0
  local per_frame = real / frames
  local ms_per_s = per_frame * 250
  print(string.format('# kernel: %.4f ms/frame -> %.2f ms per real second at 250 frames/s (%d frames in %d ms)',
                      per_frame, ms_per_s, frames, real))
  T.ok(ms_per_s < 25, string.format('%.2f ms/s', ms_per_s))
  -- 9-tick frames: a 10-tick module runs every 2nd frame, a 1,200-tick one every 134th
  T.ok(mods[1].n == 10000 and mods[5].n >= 149, 'modules ran: ' .. mods[1].n .. ' / ' .. mods[5].n)
  local s = H.state(W)
  T.ok(s.k.ms_s <= 25 and s.t.tps > 2000, 'state k.ms_s ' .. s.k.ms_s .. ', tps ' .. s.t.tps)
  kern.stop()
end)

T.test('perf.csv: header + one row per 30 s with tps, ms_s and the per-module field', function()
  local W = H.world{tag = 'csv', ms_per_frame = 20}
  local m = dummy('test_c', 10)
  m.step = function(K) m.n = m.n + 1; W.ms = W.ms + 1 end    -- 1 ms per call
  H.boot(W, {modules = {m, perf}})
  H.run(W, 1600 * 9, {skip = 9})          -- 1,600 frames = 32 s
  local lines = H.lines(W.sd .. '/perf.csv')
  T.eq(lines[1], 'wall,tick,mode,tps,pop,units,items,ms_s,gap_max_ms,gaps3,mods')
  T.eq(#lines, 2)
  local f = {}
  for x in (lines[2] .. ','):gmatch('([^,]*),') do f[#f + 1] = x end
  T.eq(f[3], 'PEACE')
  local tps = math.tointeger(tonumber(f[4]))
  T.ok(tps >= 425 and tps <= 450, 'tps ' .. f[4])   -- 9 ticks per 20 ms frame + 1 ms every 2nd frame
  T.ok(f[11]:find('^test_c=%d+'), f[11])
  local ms_s = tonumber(f[8])   -- 1 ms every 2nd frame of ~20.5 ms = ~24 ms per second
  T.ok(ms_s >= 20 and ms_s <= 28, 'ms_s counts module time: ' .. f[8])
  kern.stop()
end)

T.test('PERF_DEGRADED when rolling ticks/s < 60 % of the baseline of the same mode; once', function()
  local W = H.world{tag = 'degr', ms_per_frame = 18}
  local saved = perf.ROW_MS
  perf.ROW_MS = 3000
  H.boot(W, {modules = {perf}})
  H.run(W, 11 * 3000 // 18 * 9, {skip = 9})          -- 11 rows at 500 ticks/s: baseline
  W.ms_per_frame = 45                                  -- 200 ticks/s
  H.run(W, 25 * 3000 // 45 * 9, {skip = 9})
  perf.ROW_MS = saved
  kern.stop()
  local pd = H.find(H.events(W), 'PERF_DEGRADED')
  T.eq(#pd, 1)
  T.eq(pd[1].d.why, 'tps')
  T.ok(pd[1].d.base >= 490 and pd[1].d.pct < 60, 'base ' .. pd[1].d.base .. ' pct ' .. pd[1].d.pct)
end)

-- 100 ms frames whose tick advance follows the live timestream fps (fps / 10 ticks per frame)
local function run_ts(W, secs, ms)
  for _ = 1, secs * 1000 // (ms or 100) do H.frame(W, math.max(1, W.ts_fps * (ms or 100) // 1000), ms or 100) end
end

local function csv_tps(W)
  local r = {}
  for i, l in ipairs(H.lines(W.sd .. '/perf.csv')) do
    if i > 1 then r[#r + 1] = math.tointeger(tonumber(l:match('^[^,]*,[^,]*,[^,]*,([^,]*),'))) end
  end
  return r
end

T.test('a 10-minute inbox tempo.lower is not PERF_DEGRADED (baseline per mode and target)', function()
  local W = H.world{tag = 'tlower'}
  H.boot(W, {modules = {arbiter, perf}})
  T.eq(W.ts_fps, 500)
  run_ts(W, 330)                                  -- 11 rows at 500 ticks/s: baseline PEACE:500
  H.inbox(W, 'tl', 'tempo.lower', {fps = 100, ttl_s = 600})
  run_ts(W, 2)
  T.eq(W.ts_fps, 100)
  run_ts(W, 600)                                  -- 10 min at 100 ticks/s
  T.eq(W.ts_fps, 500, 'TTL over')
  run_ts(W, 120)
  kern.stop()
  T.eq(H.outbox(W, 'tl').ok, true)
  T.eq(#H.find(H.events(W), 'PERF_DEGRADED'), 0)
  local slow = 0
  for _, v in ipairs(csv_tps(W)) do if v >= 90 and v <= 110 then slow = slow + 1 end end
  T.ok(slow >= 19, 'csv still shows the lowered rows: ' .. slow)
end)

T.test('real slowness at a lowered target is still PERF_DEGRADED against that target', function()
  local W = H.world{tag = 'tlower2'}
  local saved = perf.ROW_MS
  perf.ROW_MS = 3000
  H.boot(W, {modules = {arbiter, perf}})
  H.inbox(W, 'tl', 'tempo.lower', {fps = 100, ttl_s = 600})
  run_ts(W, 40)                                   -- baseline PEACE:100 (first row mixed, skipped)
  for _ = 1, 300 do H.frame(W, 10, 250) end       -- 40 ticks/s for 75 s
  perf.ROW_MS = saved
  kern.stop()
  local pd = H.find(H.events(W), 'PERF_DEGRADED')
  T.eq(#pd, 1)
  T.ok(pd[1].d.base >= 95 and pd[1].d.base <= 105 and pd[1].msg:find('(target 100)', 1, true), pd[1].msg)
end)

T.test('a fort paused half the time is not PERF_DEGRADED; csv tps counts unpaused time only', function()
  local W = H.world{tag = 'halfpause', ms_per_frame = 100}
  local saved = perf.ROW_MS
  perf.ROW_MS = 3000
  H.boot(W, {modules = {perf}})
  H.run(W, 11 * 30 * 50, {skip = 50})             -- 11 rows at 500 ticks/s: baseline
  for _ = 1, 25 do                                -- 25 rows: 1.5 s paused, 1.5 s running
    df.global.pause_state = true
    for _ = 1, 15 do H.frame(W, 0) end
    df.global.pause_state = false
    for _ = 1, 15 do H.frame(W, 50) end
  end
  perf.ROW_MS = saved
  kern.stop()
  T.eq(#H.find(H.events(W), 'PERF_DEGRADED'), 0)
  local tps = csv_tps(W)
  T.ok(#tps >= 34, 'rows ' .. #tps)
  for i = #tps - 20, #tps do T.ok(tps[i] >= 450 and tps[i] <= 560, 'row ' .. i .. ' tps ' .. tps[i]) end
end)

T.test('freezes: a 25 s frame gap is PERF_DEGRADED (freeze), logged with blame external', function()
  local W = H.world{tag = 'freeze'}
  H.boot(W, {modules = {perf}})
  H.run(W, 10)
  H.frame(W, 1, 25000)
  H.run(W, 70)
  kern.stop()
  local pd = H.find(H.events(W), 'PERF_DEGRADED')
  T.eq(#pd, 1)
  T.eq(pd[1].d.why, 'freeze')
  T.ok(H.read(W.sd .. '/kern.log'):find('frame gap 25000 ms (blame external)', 1, true))
end)

T.test('frame gap caused by our own module is blamed on it', function()
  local W = H.world{tag = 'blame'}
  local slow = {name = 'economy', every = {ticks = 1000}}
  function slow.step() W.ms = W.ms + 4000 end
  H.boot(W, {modules = {slow}, strict = false})
  H.run(W, 5)
  kern.stop()
  T.ok(H.read(W.sd .. '/kern.log'):find('frame gap 40%d%d ms %(blame economy%)'), 'blamed on economy')
end)

T.done()
