-- BUG-116 (Run 14 note 89, y526-y586): `hospital_out` stood for 60 game years, the hospital was placed seven times and the last
-- placement stayed at "dig 0 %, slot yielded" while expansion projects held the slots. Care first, like seal first: while
-- hospital_out is set or patients lie in the fort (water state) the hospital project takes the first slot and the
-- housing/work projects pause (PEACE; not seals, tombs, the depot, repairs, defense, mood nooks and food/drink projects);
-- a hospital project that makes no progress for runner.care_first.stuck_days stops pausing them. Every test fails on 32994bb.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat) then return l end end
end
local function row(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end
end
local function why(W, id) local r = row(W, id); return r and r[4] end

-- o: tag, cfg (baseline runner), water (the water fake's state: patients, hosp_out)
local function world(o)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = o.tag, map_size = {16, 16, 160}, cfg = o.cfg and {baseline = {v = 2, runner = o.cfg}} or nil}
  W.ctl = {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10},
           water = o.water or {patients = 0, hosp_out = 0}}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = W.ctl.stock} end})
  W.load({name = 'water', every = {ticks = 1200}, state = function()
    local w = W.ctl.water
    return {water = {patients = w.patients, thirst_max = 0, hosp_ok = 1, refuge_ok = 1, buckets_free = 10, hosp = 1,
                     src = {}, hosp_out = w.hosp_out}}
  end})
  W.load(runner)
  W.state()
  return W
end

-- three older projects by prio/age, the hospital newest: with 3 slots it would queue 4th
local function fort(W)
  runner.CFG.active = 3
  H.place(W, 'bd1', H.dig_doc(2, {tpl = 'bedrooms', class = 'living', params = {n = 4}, x = 10, label = 'dig'}))
  H.place(W, 'ws1', H.doc{tpl = 'workshops', class = 'infra', x = 30, params = {}})
  H.place(W, 'hl1', H.dig_doc(2, {tpl = 'hall', class = 'living', params = {}, x = 50, label = 'dig'}))
  H.runs(W, 1)
  H.place(W, 'hos', H.dig_doc(2, {tpl = 'hospital', class = 'living', params = {beds = 4}, x = 70, label = 'dig'}))
  H.runs(W, 1)
end

T.test('no care need: the old scheduling, the hospital queues behind the older projects', function()
  local W = world{tag = 'none'}
  fort(W)
  T.eq(why(W, 'hos'), 'queued behind bd1 +2')
  T.eq(W.state().sched and W.state().sched.care, nil)
end)

T.test('hospital_out: the hospital takes the first slot, the work and housing projects pause, the state and the log say so',
       function()
  local W = world{tag = 'out', water = {patients = 0, hosp_out = 1}}
  fort(W)
  T.eq(why(W, 'hos'), '', 'the hospital runs')
  T.eq(W.state().proj[1][1], 'hos', 'and leads the rows')
  T.eq({why(W, 'bd1'), why(W, 'ws1'), why(W, 'hl1')}, {'paused: care hos', 'paused: care hos', 'paused: care hos'})
  T.eq(W.state().sched.care, {proj = 'hos', paused = 3, why = 'hospital_out 1'})
  local l = logged(W, 'info', '^care first:')
  T.eq(l and l.msg, 'care first: hos with hospital_out 1 runs first; paused: bd1 bedrooms, hl1 hall, ws1 workshops',
       'kern.log names the pause')
  -- the zone is back inside the burrow: the others run again
  W.ctl.water.hosp_out = 0
  W.state()
  H.runs(W, 1)
  T.eq({why(W, 'bd1'), why(W, 'ws1'), why(W, 'hos')}, {'', '', 'queued behind bd1 +2'}, 'the old order again')
  T.eq(W.state().sched and W.state().sched.care, nil)
  T.ok(logged(W, 'info', '^paused projects run again'))
end)

T.test('patients lie in the fort: the same, with the patients named', function()
  local W = world{tag = 'pat', water = {patients = 3, hosp_out = 0}}
  fort(W)
  T.eq(why(W, 'hos'), '')
  T.eq(why(W, 'bd1'), 'paused: care hos')
  T.ok(logged(W, 'info', 'care first: hos with 3 patients runs first'))
end)

T.test('exceptions: tombs, the depot, defense and food/drink projects run while the hospital leads',
       function()
  local W = world{tag = 'exc', water = {patients = 0, hosp_out = 1}}
  runner.CFG.active = 10
  H.place(W, 'tb', H.doc{tpl = 'tombs', x = 10})
  H.place(W, 'dp', H.dig_doc(1, {tpl = 'depot', class = 'infra', params = {}, x = 30, label = 'depot.dig'}))
  H.place(W, 'fc2', H.dig_doc(1, {tpl = 'fortcore', class = 'defense', params = {stage = 2}, x = 50}))
  H.place(W, 'fm', H.dig_doc(1, {tpl = 'farms', class = 'infra', params = {plots = 2}, x = 70, label = 'dig'}))
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 90})
  H.place(W, 'hos', H.dig_doc(1, {tpl = 'hospital', class = 'living', params = {beds = 4}, x = 110, label = 'dig'}))
  H.runs(W, 1)
  T.eq({why(W, 'tb'), why(W, 'dp'), why(W, 'fc2'), why(W, 'fm'), why(W, 'hos')}, {'', '', '', '', ''})
  T.eq(why(W, 'bd'), 'paused: care hos')
  T.eq(W.state().sched.care.paused, 1)
end)

T.test('care_first.on false and an outside-PEACE mode keep the old scheduling', function()
  local W = world{tag = 'off', water = {patients = 2, hosp_out = 1}, cfg = {care_first = {on = false}}}
  fort(W)
  T.eq({why(W, 'hos'), why(W, 'bd1')}, {'queued behind bd1 +2', ''})
  T.eq(W.state().sched and W.state().sched.care, nil)
end)

T.test('a hospital that makes no progress for stuck_days stops pausing the others; progress brings the pause back', function()
  local W = world{tag = 'stuck', water = {patients = 0, hosp_out = 1}, cfg = {care_first = {stuck_days = 3}}}
  fort(W)
  T.eq(why(W, 'bd1'), 'paused: care hos')
  for _ = 1, 4 do W.run(1200, {skip = 9}); H.settle(W) end      -- 4 days: nobody digs, the hospital builds nothing
  T.eq(why(W, 'bd1'), '', 'the others run again')
  local care = W.state().sched.care
  T.eq({care.proj, care.paused, care.stuck}, {'hos', 0, 1}, 'the state says it is stuck')
  T.ok(logged(W, 'warn', 'care first: hos made no progress for 3 days'), 'kern.log says why it stopped')
end)

T.test('a halted hospital project (blocked for good) pauses nobody', function()
  local W = world{tag = 'halt', water = {patients = 0, hosp_out = 1}}
  fort(W)
  H.proj(W, 'hos').blocked = 'apply_fail'
  H.runs(W, 1)
  T.eq(why(W, 'bd1'), '')
end)

T.test('a seal is ahead of the hospital: it takes the first slot and pauses the hospital like every work project', function()
  local W = world{tag = 'seal', water = {patients = 0, hosp_out = 1}}
  runner.CFG.active = 1
  H.place(W, 'hos', H.dig_doc(2, {tpl = 'hospital', class = 'living', params = {beds = 4}, x = 70, label = 'dig'}))
  H.floor(W, 5, 5, 100, 5, 5)
  H.place(W, 'sl1', {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = '5,5,100 floor'}, anchor = {5, 5, 100},
                     rot = 0, stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                                         chunks = {{pos = {5, 5, 100}, cells = {{0, 0, 0, 'd'}}}}}},
                     manifest = {v = 2}, materials = {door = 1}})
  H.runs(W, 1)
  T.eq(W.state().proj[1][1], 'sl1', 'the seal leads the rows')
  T.eq(why(W, 'hos'), 'paused: seal sl1')
end)


T.done()
