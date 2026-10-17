-- BUG-037 (Run 11, Kilrudrabed site98, y449 spring d46, kernel 784399f, PEACE, ~39 citizens): bedrooms, a stockroom, a
-- tavern, tombs and a prio-2 trade depot stood 'queued' at 0 % for months while 15 of 27 adults had no job and
-- `inspect workload` said '0 unclaimed jobs'. The runner works three projects at once; what held the slots never
-- yielded them: an open seal or plug took a pass-1 slot even when stalled and stuck, a dig stage never stalled while
-- another project dug (the shared-miners rule), a fault in the seal-first count left every row 'queued' with nothing
-- applied, and nothing showed who held the slots or that no run had ended. Projects blocked for good (build_lost with
-- the retries spent since y426, an explore stopped at a cavern lake since y432) kept PLAN_EXHAUSTED and the keepers
-- waiting for ever. Every test fails on 784399f.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local DAY = 1200
local SX, SY, Z = 114, 73, 143
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat) then return l end end
end
local function row(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end
end
local function why(W, id) local r = row(W, id); return r and r[4] end
local function now(W) return W.K.now().tick end

local function world(o)
  o = o or {}
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = o.tag, map_size = {16, 16, 160}, strict = o.strict,
                    cfg = o.cfg and {baseline = {v = 2, runner = o.cfg}} or nil}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  W.state()
  return W
end

-- a seal with one door at x (rock beside it: quickfort places the door, nobody builds it)
local function seal_at(W, x)
  H.floor(W, x, SY, Z, x, SY)
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = x .. ',' .. SY .. ',' .. Z .. ' floor'},
          anchor = {x, SY, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {x, SY, Z}, cells = {{0, 0, 0, 'd'}}}}}},
          manifest = {v = 2}, materials = {door = 1}}
end

-- miners: dig up to n designated tiles with x0 <= x <= x1 (the others are out of their reach)
local function dig_x(W, x0, x1, n)
  local keys = {}
  for k, t in pairs(W.map) do
    local x = tonumber(k:match('^(%-?%d+),'))
    if t.dig ~= '' and x >= x0 and x <= x1 then keys[#keys + 1] = k end
  end
  table.sort(keys)
  for i = 1, math.min(n, #keys) do
    local t = W.map[keys[i]]
    t.c, t.dig, t.hidden = H.RESULT[t.dig] or '.', '', nil
  end
end

local function queued_behind(W, holder, more) return 'queued behind ' .. holder .. (more and (' +' .. more) or '') end

T.test('BUG-037 replay: three stuck seals held every slot (old: bedrooms, stockroom and tavern queued for good); a ' ..
       'stuck seal now competes like a stalled project and the rows name who holds the slots', function()
  local W = world{tag = 'seals3'}
  for i = 1, 3 do H.place(W, 'sl' .. i, seal_at(W, SX + 3 * i)) end
  H.place(W, 'bd1', H.doc{tpl = 'bedrooms', x = 10})
  H.place(W, 'st1', H.doc{tpl = 'stockroom', class = 'infra', x = 30, params = {}})
  H.place(W, 'tv1', H.doc{tpl = 'tavern', x = 50, params = {}})
  H.place(W, 'tb1', H.doc{tpl = 'tombs', x = 70, params = {}})
  H.runs(W, 1)
  -- seal first: the three seals run, housing and work pause, the tombs (never paused) wait for a slot
  T.eq({why(W, 'bd1'), why(W, 'st1'), why(W, 'tv1')}, {'paused: seal sl1', 'paused: seal sl1', 'paused: seal sl1'})
  T.eq(why(W, 'tb1'), queued_behind(W, 'sl1', 2), 'old: plain "queued"')
  T.eq(W.state().sched.q, {n = 1, by = {{'sl1', 'seal', 0}, {'sl2', 'seal', 0}, {'sl3', 'seal', 0}}})
  local _, msg, data = W.K.call('runner', 'queue')
  T.eq(msg, 'runner: 1 project queued behind 3 slot holders (sl1 seal, sl2 seal, sl3 seal)')
  T.eq(data.n, 1)
  -- nobody builds the doors (no material): stuck after 3 days, the slots go to the others
  H.runs(W, 8)
  T.eq(#W.find_events('SEAL_STUCK'), 3)
  T.eq({why(W, 'bd1'), why(W, 'st1'), why(W, 'tb1')}, {'', '', ''}, 'old: queued behind the stuck seals')
  T.eq(why(W, 'tv1'), queued_behind(W, 'bd1', 2))
  T.eq(W.state().sched.q.by[1], {'bd1', 'bedrooms', 0})
  -- a month on: the miners dig what the three projects designated (old: nothing designated, 0 % for good)
  for _ = 1, 30 do H.dig(W); H.runs(W, 2) end
  for _, id in ipairs({'bd1', 'st1', 'tv1'}) do T.ok(H.proj(W, id).stage >= 1, id .. ' digs and builds') end
  T.eq(H.proj(W, 'sl1').blocked, 'stalled')
  -- the stuck seals are still measured: once the doors stand they finish
  H.build(W)
  for _ = 1, 12 do H.runs(W, 1) end
  for i = 1, 3 do T.eq(H.proj(W, 'sl' .. i).done, 1, 'sl' .. i .. ' done') end
end)

T.test('BUG-037: a dig whose tiles nobody digs yields its slot after queue.yield_days while another project digs ' ..
       '(the shared-miners rule never let it stall); it gets a slot back once it moves', function()
  local W = world{tag = 'dig'}
  local function fc(n, x) return H.dig_doc(n, {tpl = 'fortcore', class = 'defense', params = {stage = 2}, x = x,
                                              label = 's2.dig'}) end
  H.place(W, 'a', fc(30, 10))
  H.place(W, 'b', fc(2, 40))
  H.place(W, 'c', fc(2, 70))
  H.place(W, 'd', H.doc{tpl = 'bedrooms', x = 100})
  H.runs(W, 1)
  T.eq(why(W, 'd'), queued_behind(W, 'a', 2))
  for _ = 1, 6 do dig_x(W, 10, 14, 5); H.runs(W, 2) end       -- six days: a digs, b and c are out of reach
  T.eq({why(W, 'b'), why(W, 'c'), why(W, 'd')}, {'', '', queued_behind(W, 'a', 2)}, 'not yet')
  local q = W.state().sched.q
  T.eq({q.n, q.by[1], q.by[2][1], q.by[3][1]}, {1, {'a', 'fortcore', 0}, 'b', 'c'})
  T.ok(q.by[2][3] >= 5 and q.by[3][3] >= 5, 'b and c: days without progress')
  for _ = 1, 3 do dig_x(W, 10, 14, 5); H.runs(W, 2) end
  T.eq(H.proj(W, 'b').blocked, '', 'not stalled: a digs')
  T.ok(H.proj(W, 'd').chunk > 0, 'old: d stays queued until a is done (30 days)')
  T.eq(why(W, 'b'), '', 'b takes the slot left over')
  T.ok(why(W, 'c'):find('^no progress %d+ d: slot yielded$'), why(W, 'c'))
  T.eq((W.state().sched or {}).q, nil, 'nobody waits')
  -- the miners reach c: measured outside the slots, it is back in pass 1
  dig_x(W, 70, 74, 10)
  for _ = 1, 6 do dig_x(W, 10, 14, 5); H.runs(W, 1) end
  T.eq(H.proj(W, 'c').done, 1)
  T.ok(H.proj(W, 'a').done ~= 1)
  -- queue.yield_days from config/baseline.json
  local W2 = world{tag = 'digcfg', cfg = {queue = {yield_days = 2}}}
  H.place(W2, 'a', fc(30, 10))
  H.place(W2, 'b', fc(2, 40))
  H.place(W2, 'c', fc(2, 70))
  H.place(W2, 'd', H.doc{tpl = 'bedrooms', x = 100})
  H.runs(W2, 1)
  for _ = 1, 3 do dig_x(W2, 10, 14, 5); H.runs(W2, 2) end
  T.ok(H.proj(W2, 'd').chunk > 0, 'after 2 days')
end)

local function build_lost(W, id, n)
  local P = H.proj(W, id)
  P.blocked, P.since = 'build_lost', now(W)
  W.K.persist.get('m.runner').rty[id] = {n = n, t = now(W), c = now(W), sig = 0}
end

T.test('BUG-037: projects blocked for good are parked after queue.park_days: last in the rows, announced once with the ' ..
       'cancel command, never cancelled; they no longer hold PLAN_EXHAUSTED, the keepers or a seal pause', function()
  local W = world{tag = 'park'}
  H.place(W, 'fm', H.doc{tpl = 'farms', class = 'infra', x = 10, params = {plots = 2}}, {tpl = 'farms', site = 'S1',
                                                                                         prio = 1})
  H.place(W, 'ex', H.dig_doc(2, {tpl = 'explore', class = 'infra', params = {}, x = 40, label = 'x.dig'}))
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 70})
  H.runs(W, 1)
  build_lost(W, 'fm', runner.CFG.retry_max)            -- the live farms: retries spent (y426)
  H.proj(W, 'fm').stage = 1
  local ex = H.proj(W, 'ex')
  ex.blocked, ex.since = 'breach:cavern_lake', now(W)    -- the live explore (y432)
  H.runs(W, 2)
  T.eq(why(W, 'fm'), 'build_lost')
  T.eq(W.K.call('runner', 'pending', 'farms'), true)
  local _, n = W.K.call('runner', 'pending', 'farms')
  T.eq(n, 1, 'not parked yet')
  H.dig(W); H.runs(W, 2); H.build(W)
  for _ = 1, 60 do H.runs(W, 1) end                      -- 31 days
  T.eq(H.proj(W, 'bd').done, 1)
  local proj = W.state().proj
  T.eq({proj[#proj - 1][1], proj[#proj - 1][4], proj[#proj][1], proj[#proj][4]},
       {'fm', 'parked: build_lost', 'ex', 'parked: breach:cavern_lake'})
  local parked = {}
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do if e.d.park then parked[#parked + 1] = e end end
  T.eq(#parked, 2, 'once each')
  local pf = parked[1].d.proj == 'fm' and parked[1] or parked[2]
  T.eq(pf.msg, 'fm (farms) blocked 30 d: build_lost at build; parked; cancel: dfllm cmd bp.cancel \'{"proj":"fm"}\' ' ..
               '(no undo: what it built stays)')
  T.eq({pf.cls, pf.d.park, pf.d.why}, {'A', 30, 'build_lost'})
  local px = parked[1].d.proj == 'ex' and parked[1] or parked[2]
  T.ok(px.msg:find("bp.cancel '{\"proj\":\"ex\"}' (no undo: its shaft stays watched)", 1, true), px.msg)
  T.eq(W.state().sched.pk, 2)
  T.ok(H.proj(W, 'fm') and H.proj(W, 'ex'), 'never cancelled by the kernel')
  -- PLAN_EXHAUSTED (old: never while the two stood), M.pending, no repeat
  T.eq(#W.find_events('PLAN_EXHAUSTED'), 1)
  _, n = W.K.call('runner', 'pending', 'farms')
  T.eq(n, 0)
  for _ = 1, 20 do H.runs(W, 1) end
  local again = 0
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do if e.d.park then again = again + 1 end end
  T.eq(again, 2)
  -- bp.cancel (no undo) removes it; the park record goes with it
  T.ok(W.inbox('bp.cancel', {proj = 'fm'}).ok)
  H.runs(W, 1)
  T.eq(W.K.persist.get('m.runner').park.fm, nil)
  -- a seal blocked for good: stuck, then parked: no seal-first entry, nothing paused (old: SEAL_STUCK state for good)
  local W2 = world{tag = 'parkseal', cfg = {queue = {park_days = 5}}}
  H.place(W2, 'sl', seal_at(W2, SX))
  H.place(W2, 'bd', H.doc{tpl = 'bedrooms', x = 10})
  H.runs(W2, 1)
  build_lost(W2, 'sl', runner.CFG.retry_max)
  H.runs(W2, 8)
  T.eq(W2.state().sched.seal.stuck, 1)
  H.runs(W2, 4)
  T.eq(W2.state().sched.seal, nil, 'parked after 5 days')
  T.eq(why(W2, 'sl'), 'parked: build_lost')
  T.eq(why(W2, 'bd'), '')
end)

T.test('BUG-037: a fault in the seal-first count no longer stops every project (old: every row queued, the prio-2 ' ..
       'depot too, nothing applied, no sched)', function()
  local W = world{tag = 'fault', strict = false}
  H.place(W, 'sl', seal_at(W, SX))
  -- a later stage the seal-first count reads and chokes on (the seal's own build stage is fine)
  local d = W.K.persist.get('bp.sl')
  d.stages[2] = {label = 'seal.x', mode = 'dig', orders = 0, defense = 1, chunks = {{pos = {SX, SY, Z}, cells = {{0, 0, 0, 7}}}}}
  H.place(W, 'dp', H.dig_doc(1, {tpl = 'depot', class = 'infra', params = {}, x = 30, label = 'depot.dig'}),
          {tpl = 'depot', site = 'S1', prio = 2})
  H.place(W, 'bd', H.doc{tpl = 'bedrooms', x = 50})
  H.runs(W, 2)
  T.eq(#W.faults, 0, 'old: runner step faults every run')
  T.ok(logged(W, 'error', '^seal first/rebuild failed, this run without them: '), 'named in kern.log')
  T.eq({why(W, 'dp'), why(W, 'bd')}, {'', ''})
  local digs = {}
  for _, c in ipairs(H.qf_calls(W, 'dig', 'run')) do digs[c.pos[1]] = true end
  T.ok(digs[30] and digs[50], 'the depot and the bedrooms are designated')
  local n = 0
  for _, l in ipairs(W.logs) do if l.msg:find('^seal first/rebuild failed') then n = n + 1 end end
  T.eq(n, 1, 'once per message')
end)

T.test('BUG-037 watchdog: a task that yields task_slices slices in a row is skipped this run, the next run goes on',
       function()
  local W = world{tag = 'wd'}
  runner.CFG.task_slices = 2
  H.place(W, 'w1', H.dig_doc(5, {tpl = 'fortcore', class = 'defense', params = {stage = 2}, x = 10, label = 's2.dig'}))
  H.runs(W, 1)
  T.ok(logged(W, 'warn', '^runner watchdog: task 1/3 %(work w1%) yielded 2 slices in a row: skipped this run$'))
  T.eq(H.proj(W, 'w1').chunk, 2)
  H.runs(W, 3)
  T.eq(H.proj(W, 'w1').chunk, 5, 'every chunk applied over the next runs')
end)

T.test('BUG-037: no run ended for run_idle_d days: state sched.run names the run in hand (task, slices, age); ' ..
       'inspect workload\'s clause says so', function()
  local W = world{tag = 'idle'}
  W.cost.runner = 40                                    -- a slow runner: paced, its slices wait
  H.place(W, 'w1', H.dig_doc(4, {tpl = 'fortcore', class = 'defense', params = {stage = 2}, x = 10, label = 's2.dig'}))
  local seen
  for _ = 1, 400 do
    W.frame(20)
    local r = W.state().sched and W.state().sched.run
    if r and r.task then seen = r; break end
  end
  T.ok(seen, 'old: no sched.run')
  T.ok(seen.d >= 3 and seen.task == 'work w1' and seen.i == 1 and seen.n == 3 and seen.sl >= 1, T.show(seen))
  local _, msg = W.K.call('runner', 'queue')
  T.ok(msg:find('^runner: no run ended for %d+ days %(at task 1/3 work w1, %d+ slices%), 0 projects wait$'), msg)
  W.cost.runner = 0
  for _ = 1, 3000 do W.frame(20); if H.proj(W, 'w1').chunk == 4 and not W.mods.runner.cont then break end end
  W.run(1200, {skip = 20})
  H.settle(W)
  T.eq(W.state().sched, nil, 'gone once a run ended')
end)

T.done()
