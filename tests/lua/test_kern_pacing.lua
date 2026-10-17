-- BUG-039 (Run 11 Kilrudrabed site98, y451 winter, kernel e11d17a): ONE runner step took 68.6 s (kern.log
-- 'runner demoted x4 (68603 ms; ...)', 'frame gap 68640 ms (blame runner)'), right in 'work y451s3b0' (a stockroom plan
-- build). Its pacing debt (67760 ms, share 4 ms/s) drained at 2-4 ms per real second, so the runner's run in hand got
-- no further slice: 'runner: no run ended for 49 days (at task 1/3 work y451s3b0, 1 slices)', every project waited.
-- The real kernel: the debt is capped (PACE.debt_cap_s seconds of the module's share), a due module gets a slice after
-- PACE.floor_ms of waiting whatever its debt (the pacing floor, kern.log once per module per 10 min), and a step of
-- KERN.big_ms or more is named in kern.log with the module's M.doing() and its slowest act call.
local T = require('testlib')
local H = require('kern_world')
local kern = require('dfllm.kern')
local sched = require('dfllm.util.sched')

local SKIPS = {4, 5}           -- ~450 ticks/s at ~100 frames/s (10 ms frames)

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

-- a runner stand-in: a run of `n` slices; its first slice of the second run costs `big` ms (the live 68.6 s), the
-- others 1 ms. slices[i] = W.ms at slice i; it names what it does (M.doing) like the real runner
local function stand_in(W, big, n)
  local qf = W.scripts['quickfort'].apply_blueprint
  W.scripts['quickfort'].apply_blueprint = function(p) W.ms = W.ms + (W.qf_cost or 0); return qf(p) end
  local m = {name = 'runner', every = {ticks = 600}, slices = {}, runs = 0, cur = 'idle'}
  local left = 0
  function m.doing() return m.cur end
  function m.step(K, budget, ctx)
    if not (ctx and ctx.cont) then m.runs, left = m.runs + 1, n end
    m.slices[#m.slices + 1] = W.ms
    m.cur = string.format('work y451s3b0 place (task 1/3, slice %d)', n - left + 1)
    if m.runs == 2 and left == n then
      W.qf_cost = big                            -- the quickfort call of this slice takes the 68.6 s
      K.act.quickfort({mode = 'place', data = {[0] = {[0] = {[0] = 'f'}}}, pos = {1, 1, 1}})
      W.qf_cost = nil
    else W.ms = W.ms + 1 end
    left = left - 1
    if left > 0 then return 'more' end
  end
  return m
end

local function frames_until(W, pred, max)
  for f = 1, max do
    H.frame(W, SKIPS[f % 2 + 1], 10)
    if pred() then return f end
  end
end

T.test('BUG-039 live: one 68.6 s runner step no longer leaves its run without a slice for hours', function()
  no_inbox(function()
    local W = H.world{tag = 'starve', ms_per_frame = 10}
    local m = stand_in(W, 68600, 3)
    assert(H.boot(W, {modules = {m}}))
    T.ok(frames_until(W, function() return m.runs >= 2 end, 3000), 'the second run started')
    local at = #m.slices
    local t_big = m.slices[at]
    -- the old kernel: debt 68,600 ms drained at 4 ms/s -> no slice for ~17,000 s (4.8 h; at 450 ticks/s 15 game years)
    local f = frames_until(W, function() return #m.slices > at end, 3100)
    T.ok(f ~= nil, 'the run in hand got its next slice within 31 s (old kernel: after ~17,000 s)')
    if f then
      local wait_s = (m.slices[at + 1] - t_big - 68600) / 1000
      T.ok(wait_s <= sched.PACE.floor_ms / 1000 + 0.1, string.format('waited %.1f s', wait_s))
    end
    T.ok(frames_until(W, function() return m.runs >= 3 end, 6000), 'the runs go on')
    local info = module_info('runner')
    T.ok(info ~= nil)
    local log = H.read(W.sd .. '/kern.log') or ''
    -- the huge step is named: the module, what it did and its slowest act call
    T.ok(log:find('runner step took 68600 ms (work y451s3b0 place (task 1/3, slice 1); slowest act: quickfort place '
                  .. '68600 ms); debt capped at 120 ms (30 s of its share)', 1, true),
         'kern.log names the huge step: ' .. log:sub(-600))
    local big = info.big
    T.ok(big ~= nil and big.ms >= 68600 and big.what:find('step work y451s3b0', 1, true) ~= nil, 'status/inspect: big')
    kern.stop('test')
  end)
end)

T.test('BUG-039: the debt never exceeds debt_cap_s seconds of the share; a due module gets a slice after floor_ms', function()
  no_inbox(function()
    local saved = sched.PACE.debt_cap_s
    sched.PACE.debt_cap_s = 1e9                  -- the floor alone (as if the debt were uncapped)
    local ok, err = pcall(function()
      local W = H.world{tag = 'floor', ms_per_frame = 10}
      local m = stand_in(W, 68600, 40)
      assert(H.boot(W, {modules = {m}}))
      T.ok(frames_until(W, function() return m.runs >= 2 end, 3000))
      local at = #m.slices
      -- uncapped debt: each further slice comes after the floor (30 s), not after hours
      T.ok(frames_until(W, function() return #m.slices >= at + 2 end, 6200), 'two floor slices within 62 s')
      local gap = (m.slices[at + 2] - m.slices[at + 1]) / 1000
      T.ok(gap >= sched.PACE.floor_ms / 1000 - 0.05 and gap <= sched.PACE.floor_ms / 1000 + 0.1,
           string.format('one slice per floor: %.2f s', gap))
      local log = H.read(W.sd .. '/kern.log') or ''
      local _, n = log:gsub('pacing floor', '')
      T.eq(n, 1, 'the floor line once per 10 min: ' .. log:sub(-400))
      T.ok(log:find('runner waited 30 s for a slice with its run in hand (debt', 1, true), log:sub(-400))
      T.ok((module_info('runner') or {}).floor >= 2, 'inspect/status count the floor slices')
      kern.stop('test')
    end)
    sched.PACE.debt_cap_s = saved
    assert(ok, err)
  end)
  -- the cap itself (sched, shared with k_mock): spend never books more than debt_cap_s seconds of the share
  local e = sched.init{name = 'runner', M = {}, factor = 1, slow_ms = {}}
  sched.spend(e, 68600)
  T.eq(e.debt, sched.PACE.shares.runner * sched.PACE.debt_cap_s)
  local c = sched.init{name = 'sense', M = {}, factor = 1, slow_ms = {}, critical = true}
  sched.spend(c, 68600)
  T.eq(c.debt, 0, 'critical modules are never paced')
end)

T.test('BUG-039: KERNEL_SLOW and the demotion line name what the module did (M.doing)', function()
  no_inbox(function()
    local W = H.world{tag = 'slowtask', ms_per_frame = 10}
    local m = {name = 'runner', every = {ticks = 10}, share = 1000}
    function m.doing() return 'work y451s3b0 place' end
    function m.step() W.ms = W.ms + 30 end
    assert(H.boot(W, {modules = {m}}))
    for f = 1, 600 do H.frame(W, SKIPS[f % 2 + 1], 10) end
    local ev = H.find(H.events(W), 'KERNEL_SLOW')[1]
    T.ok(ev ~= nil, 'KERNEL_SLOW')
    if ev then
      T.ok(ev.msg:find('runner demoted x2 (30 ms in work y451s3b0 place)', 1, true), ev.msg)
      T.eq(ev.d.task, 'work y451s3b0 place')
    end
    kern.stop('test')
  end)
end)

T.done()
