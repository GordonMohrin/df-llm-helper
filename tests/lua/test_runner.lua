-- WP7 runner: projects, stages, chunks, progress, BREACH_STOP, cancel/undo, plan builds, phases,
-- capacity keepers, manifest merge (CONTRACTS §7, §9.8-§9.9, §10-§13), on k_mock with a fake quickfort.
local T = require('testlib')
local H = require('runner_world')
local json = require('dfllm.util.json')
local runner = require('dfllm.runner')

local DAY = 1200
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world(opts)
  W.load(runner)
  return W
end
local function rows(W) return W.state().proj end
local function row(W, id)
  for _, r in ipairs(rows(W)) do if r[1] == id then return r end end
end
local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat) then return l end end
end
local function stage_ev(W, id)
  for _, ev in ipairs(W.find_events('PROJECT_STAGE')) do if ev.d.proj == id then return ev.d end end
end

T.test('bp.place reads bp/<id>.json, registers the project and replies {proj}', function()
  local W = fresh{tag = 'place'}
  local r = H.place(W, 'c1', H.doc{})
  T.ok(r.ok, r.msg)
  T.eq(r.data, {proj = 'c1'})
  local P = H.proj(W, 'c1')
  T.eq({P.tpl, P.class, P.prio, P.stage, P.chunk, P.pct, P.blocked, P.done, P.orders_done},
       {'bedrooms', 'living', 4, 0, 0, 0, '', 0, 0})
  T.eq(W.K.persist.get('bp.c1').id, 'c1')
  T.ok(H.place(W, 'c1', H.doc{}).msg:find('already queued'))
  T.eq(#W.K.persist.get('projects').list, 1)
end)

T.test('bp.place refuses a missing file, a template mismatch, a bad document and a bad prio', function()
  local W = fresh{tag = 'refuse'}
  local r = W.inbox('bp.place', {tpl = 'bedrooms', site = 'S1'}, {id = 'nofile'})
  T.ok(not r.ok and r.msg:find('missing'), r.msg)
  r = H.place(W, 'c2', H.doc{}, {tpl = 'tombs', site = 'S1'})
  T.ok(not r.ok and r.msg:find('does not match'), r.msg)
  local bad = H.doc{}
  bad.stages[1].mode = 'carve'
  r = H.place(W, 'c3', bad)
  T.ok(not r.ok and r.msg:find('bad stage'), r.msg)
  r = H.place(W, 'c4', H.doc{}, {tpl = 'bedrooms', site = 'S1', prio = 9})
  T.ok(not r.ok and r.msg:find('prio'), r.msg)
  T.eq(#W.K.persist.get('projects').list, 0)
end)

T.test('lifecycle: dig -> build (orders first) -> zone -> burrow -> manifest merge and deregistration', function()
  local W = fresh{tag = 'life'}
  H.place(W, 'c1', H.doc{})
  H.settle(W); W.frame(1); H.settle(W)
  local digs = H.qf_calls(W, 'dig', 'run')
  T.eq(#digs, 2)
  T.ok(digs[1].frame ~= digs[2].frame, 'one quickfort call per slice')
  T.eq(digs[1].priority, 4)
  T.eq(digs[1].data, {[0] = {[0] = {[0] = 'd(5x1)'}}})
  T.eq(digs[2].pos, {10, 11, 100})
  T.eq(W.tile(12, 11, 100).dig, 'd')
  H.runs(W, 1)
  T.eq(H.proj(W, 'c1').stage, 0)
  T.eq(row(W, 'c1'), {'c1', 'dig', 0, ''})
  H.dig(W, 5)
  H.runs(W, 1)
  T.eq(H.proj(W, 'c1').pct, 12)                  -- 5 of 10 tiles in stage 1 of 4
  H.dig(W)
  H.runs(W, 1)
  local P = H.proj(W, 'c1')
  T.eq({P.stage, P.orders_done}, {1, 1})
  T.eq(#W.orders, 1)
  T.eq(W.orders[1].command, 'orders')
  T.eq(W.orders[1].data[100][10][14], 'b')       -- absolute coordinates, one call for the stage
  local builds = H.qf_calls(W, 'build')
  T.eq({#builds, builds[1].command, builds[2].command}, {2, 'orders', 'run'})
  T.ok(builds[2].frame > builds[1].frame, 'orders in its own slice, before run')
  H.runs(W, 1)
  T.eq(H.proj(W, 'c1').stage, 1)                 -- buildings pending
  H.build(W)
  H.runs(W, 1)
  P = H.proj(W, 'c1')
  T.eq({P.done, P.pct, P.stage}, {1, 100, 4})
  T.eq(#W.applied, 2)
  T.eq({W.applied[1].mode, W.applied[2].mode}, {'zone', 'burrow'})
  local stages = {}
  for _, ev in ipairs(W.find_events('PROJECT_STAGE')) do stages[#stages + 1] = ev.d.stage end
  T.eq(stages, {'dig', 'build', 'zone', 'burrow'})
  T.eq(#W.find_events('PROJECT_DONE'), 1)
  T.eq(W.find_events('PROJECT_DONE')[1].d, {proj = 'c1', tpl = 'bedrooms'})
  T.eq(W.K.persist.get('bp.c1'), nil)
  T.eq(W.K.manifest().rooms[1].id, 'r10')
  T.eq(rows(W), {})
  -- no more quickfort work afterwards
  local n = #W.qf
  H.runs(W, 2)
  T.eq(#W.qf, n)
end)

T.test('at most 3 projects are worked at once; the rest are queued by prio', function()
  local W = fresh{tag = 'slots'}
  for i = 1, 5 do
    H.place(W, 'p' .. i, H.doc{x = 10 * i}, {tpl = 'bedrooms', site = 'S1', prio = i == 5 and 1 or 4})
  end
  H.settle(W); W.frame(1); H.settle(W)
  local started = {}
  for _, c in ipairs(H.qf_calls(W, 'dig', 'run')) do started[c.pos[1]] = true end
  T.ok(started[50] and started[10] and started[20], 'prio 1 first, then the oldest')
  T.ok(not started[30] and not started[40])
  T.eq(row(W, 'p3')[4], 'queued')
  T.eq(row(W, 'p5')[4], '')
end)

T.test('mode gating: ALERT runs defense/infra only, SIEGE defense inside Z3/Z4, DRILL nothing', function()
  local W = fresh{tag = 'gate', mode = 'ALERT'}
  H.place(W, 'liv', H.doc{x = 10, class = 'living'})
  H.place(W, 'inf', H.doc{x = 30, class = 'infra'})
  H.settle(W); W.frame(1); H.settle(W)
  local xs = {}
  for _, c in ipairs(H.qf_calls(W, 'dig')) do xs[c.pos[1]] = true end
  T.ok(xs[30] and not xs[10])
  T.eq(row(W, 'liv')[4], 'frozen')
  -- SIEGE: a defense project inside Z4 runs, one outside does not
  local W2 = fresh{tag = 'gate2', mode = 'SIEGE',
                   persist = {manifest = {v = 2, zones = {Z4 = {{0, 0, 90, 40, 40, 110}}}}}}
  H.place(W2, 'in', H.doc{x = 10, class = 'defense'})
  H.place(W2, 'out', H.doc{x = 60, class = 'defense'})
  H.place(W2, 'inf', H.doc{x = 20, class = 'infra'})
  H.settle(W2); W2.frame(1); H.settle(W2)
  xs = {}
  for _, c in ipairs(H.qf_calls(W2, 'dig')) do xs[c.pos[1]] = true end
  T.ok(xs[10] and not xs[60] and not xs[20])
  -- DRILL: frozen; frozen time is not a stall
  local W3 = fresh{tag = 'gate3', mode = 'DRILL'}
  H.place(W3, 'd', H.doc{class = 'defense'})
  H.runs(W3, 10)
  T.eq(#W3.qf, 0)
  T.eq(H.proj(W3, 'd').blocked, '')
  W3.set_mode('PEACE')
  H.runs(W3, 1)
  T.eq(#H.qf_calls(W3, 'dig'), 2)
end)

T.test('a mode change mid-run stops the work at the next slice (SIEGE/BREACH freeze the runner)', function()
  local W = fresh{tag = 'midrun'}
  H.place(W, 'c1', H.dig_doc(10, {class = 'living'}))
  W.frame(1)
  T.eq(#H.qf_calls(W, 'dig', 'run'), 1)          -- the run is in progress: 9 chunks to go
  W.set_mode('SIEGE')
  H.settle(W)
  T.eq(#H.qf_calls(W, 'dig', 'run'), 1)
  T.eq(row(W, 'c1')[4], 'frozen')
  H.runs(W, 3)
  T.eq(#H.qf_calls(W, 'dig'), 1)
  W.set_mode('PEACE')
  H.runs(W, 1)
  T.eq(#H.qf_calls(W, 'dig', 'run'), 10)
  T.eq(H.proj(W, 'c1').blocked, '')              -- frozen time is no stall
  -- BREACH stops even a defense project inside the core that SIEGE allows
  local W2 = fresh{tag = 'midrun2', mode = 'SIEGE',
                   persist = {manifest = {v = 2, zones = {Z4 = {{0, 0, 90, 60, 60, 110}}}}}}
  H.place(W2, 'd', H.dig_doc(10, {class = 'defense'}))
  W2.frame(1)
  T.eq(#H.qf_calls(W2, 'dig', 'run'), 1)
  W2.set_mode('BREACH')
  H.settle(W2)
  H.runs(W2, 2)
  T.eq(#H.qf_calls(W2, 'dig'), 1)
end)

T.test('beauty runs only in PEACE with readiness >= 1 and policy beauty ~= none', function()
  local W = fresh{tag = 'beauty'}
  H.place(W, 'b', H.doc{class = 'beauty'})
  H.runs(W, 1)
  T.eq(#W.qf, 0)
  local lvl = 1
  W.load{name = 'readiness', every = {ticks = 33600}, level = function() return lvl end}
  H.runs(W, 1)
  T.eq(#H.qf_calls(W, 'dig'), 2)
end)

T.test('BREACH_STOP: a damp cancel report near a digging project stops it and undoes its designations', function()
  local W = fresh{tag = 'damp'}
  H.place(W, 'c1', H.dig_doc(5))
  H.place(W, 'far', H.dig_doc(2, {x = 80}))
  H.runs(W, 1)
  T.eq(#H.qf_calls(W, 'dig', 'run'), 7)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'Damp stone located', pos = {x = 12, y = 14, z = 100}})
  W.frame(1)
  local P = H.proj(W, 'c1')
  T.eq(P.blocked, 'breach:damp')
  T.eq(H.proj(W, 'far').blocked, '')
  local ev = W.find_events('BREACH_STOP')
  T.eq(#ev, 1)
  T.eq(ev[1].d, {proj = 'c1', why = 'damp', pos = {12, 14, 100}, src = 'report'})
  local undos = H.qf_calls(W, 'dig', 'undo')
  T.eq(#undos, 2)                                -- nearest chunks at once (rows 14, 13)
  T.eq({undos[1].pos[2], undos[2].pos[2]}, {14, 13})
  H.runs(W, 1)
  T.eq(#H.qf_calls(W, 'dig', 'undo'), 5)
  T.eq(W.tile(10, 10, 100).dig, '')
  T.eq(W.tile(80, 10, 100).dig, 'd')
  -- no further digging, blocked > 2 days -> one PROJECT_BLOCKED (A)
  local n = #H.qf_calls(W, 'dig', 'run')
  H.runs(W, 6)
  T.eq(#H.qf_calls(W, 'dig', 'run'), n)
  local pb = W.find_events('PROJECT_BLOCKED')
  T.eq(#pb, 1)
  T.eq({pb[1].cls, pb[1].d.proj, pb[1].d.why, pb[1].d.stage}, {'A', 'c1', 'breach:damp', 's1.dig'})
  T.eq(row(W, 'c1')[4], 'breach:damp')
end)

T.test('reports: far ones are ignored, no pos stops every digger, cave collapse needs a pos', function()
  local W = fresh{tag = 'reports'}
  H.place(W, 'a', H.dig_doc(2))
  H.place(W, 'b', H.dig_doc(2, {x = 80}))
  H.runs(W, 1)
  W.event('REPORT', {type = 'DIG_CANCEL_WARM', text = 'x', pos = {x = 40, y = 10, z = 100}})
  W.event('REPORT', {type = 'CAVE_COLLAPSE', text = 'x'})
  W.frame(1)
  T.eq(#W.find_events('BREACH_STOP'), 0)
  W.event('REPORT', {type = 'FEATURE_DISCOVERY', text = 'You have discovered an underground river'})
  W.frame(1)
  T.eq(H.proj(W, 'a').blocked, 'breach:water')
  T.eq(H.proj(W, 'b').blocked, 'breach:water')
end)

T.test('tile checks: a cancelled designation (wall left) and revealed water stop the dig', function()
  local W = fresh{tag = 'tiles'}
  H.place(W, 'c1', H.dig_doc(2))
  H.place(W, 'c2', H.dig_doc(2, {x = 40}))
  H.runs(W, 2)                                   -- applied, then measured: designations seen
  T.eq(#W.find_events('BREACH_STOP'), 0)
  W.tile(11, 10, 100).dig = ''                   -- DF cancelled it: still '#', no designation
  W.tile(41, 11, 100).c = '~'
  H.runs(W, 1)
  local ev = W.find_events('BREACH_STOP')
  T.eq(#ev, 2)
  T.eq(ev[1].d, {proj = 'c1', why = 'damp', pos = {11, 10, 100}, src = 'cancel'})
  T.eq(ev[2].d, {proj = 'c2', why = 'water', pos = {41, 11, 100}, src = 'tile'})
end)

T.test('stall: no progress for a week -> stalled, cleared by progress; PROJECT_BLOCKED once', function()
  local W = fresh{tag = 'stall'}
  local week = runner.CFG.stall // 600
  T.eq(runner.CFG.stall, 7 * DAY)
  H.place(W, 'c1', H.dig_doc(2))
  H.runs(W, 1)
  H.runs(W, week - 1)
  T.eq(H.proj(W, 'c1').blocked, '')
  H.runs(W, 2)
  T.eq(H.proj(W, 'c1').blocked, 'stalled')
  H.dig(W, 1)
  H.runs(W, 1)
  T.eq(H.proj(W, 'c1').blocked, '')
  H.runs(W, week + 1)
  T.eq(H.proj(W, 'c1').blocked, 'stalled')
  T.eq(#W.find_events('PROJECT_BLOCKED'), 0)
  H.runs(W, 5)                                   -- blocked > 2 days
  T.eq(#W.find_events('PROJECT_BLOCKED'), 1)
  T.eq(W.find_events('PROJECT_BLOCKED')[1].d.why, 'stalled')
  H.runs(W, 6)
  T.eq(#W.find_events('PROJECT_BLOCKED'), 1)
end)

T.test('a probe breach undoes in the same run; a plain cancel waits for that undo', function()
  local W = fresh{tag = 'probeundo'}
  H.place(W, 'c1', H.dig_doc(3))
  H.runs(W, 2)
  W.tile(10, 12, 100).dig = ''                   -- cancelled designation in the last chunk
  H.runs(W, 1)
  T.eq(#W.find_events('BREACH_STOP'), 1)
  T.eq(#H.qf_calls(W, 'dig', 'undo'), 3)
  T.eq(H.qf_calls(W, 'dig', 'undo')[1].pos[2], 12)
  -- a second project: breach by report, then a plain cancel before its undo has finished
  H.place(W, 'c2', H.dig_doc(4, {x = 40}))
  H.runs(W, 1)
  W.event('REPORT', {type = 'DIG_CANCEL_DAMP', text = 'damp', pos = {x = 40, y = 10, z = 100}})
  W.frame(1)
  T.eq(#H.qf_calls(W, 'dig', 'undo'), 5)
  local r = W.inbox('bp.cancel', {proj = 'c2'})
  T.ok(r.ok, r.msg)
  T.ok(H.proj(W, 'c2'), 'kept until its designations are undone')
  H.runs(W, 1)
  T.eq(#H.qf_calls(W, 'dig', 'undo'), 7)
  T.eq(H.proj(W, 'c2'), nil)
  for y = 10, 13 do T.eq(W.tile(42, y, 100).dig, '') end
end)

T.test('probe: tiles quickfort never designated (soil, map edge, off map, F on rough) are skipped', function()
  local W = fresh{tag = 'skip'}
  runner.CFG.active = 4
  W.soil['11,10,100'], W.soil['13,10,100'] = true, true
  H.place(W, 's1', H.dig_doc(1, {key = 's', label = 'smooth'}))            -- 2 of 5 walls are soil
  H.place(W, 'e1', H.dig_doc(1, {x = 0, y = 40}))                         -- x = 0 is the map edge
  H.place(W, 'o1', H.dig_doc(1, {x = 253, y = 60}))                       -- 255 edge, 256-257 off map
  H.place(W, 'f1', H.dig_doc(1, {x = 30, y = 80, key = 'F', label = 'fort'}))  -- rough walls: never
  H.runs(W, 1)
  T.ok(logged(W, 'info', '^o1 s1.dig chunk 0: quickfort skipped 2 off map, 1 invalid, 0 engraved'))
  H.runs(W, 1)
  T.eq(H.proj(W, 'f1').done, 1)                  -- nothing to wait for
  for _, id in ipairs({'s1', 'e1', 'o1'}) do T.eq(H.proj(W, id).done, 0, id .. ' waits for its dwarves') end
  H.dig(W)
  H.runs(W, 1)
  T.eq(#W.find_events('BREACH_STOP'), 0)
  local lost = {}
  for _, id in ipairs({'s1', 'e1', 'o1', 'f1'}) do
    local P = H.proj(W, id)
    T.eq({P.done, P.blocked}, {1, ''}, id)
    local d = stage_ev(W, id)
    lost[#lost + 1] = {d.lost, d.qskip}
  end
  T.eq(lost, {{2, 2}, {1, 1}, {3, 3}, {5, 5}})
  T.ok(logged(W, 'info', '^e1 s1.dig chunk 0: 1 tiles never designated, skipped'))
end)

T.test('probe: a hidden tile under a mine key is designated; revealed without designation = cancel', function()
  local W = fresh{tag = 'hidden'}
  W.tile(12, 10, 100).hidden = true
  H.place(W, 'c1', H.dig_doc(1))
  H.runs(W, 2)
  T.eq(#W.find_events('BREACH_STOP'), 0)
  T.eq(W.K.persist.get('m.runner').p.c1.sp['1'], '11111')  -- tile 3 (hidden: snapshot nil) marked too
  local t = W.tile(12, 10, 100)
  t.hidden, t.dig = nil, ''                      -- revealed as damp stone: DF dropped the designation
  H.runs(W, 1)
  local ev = W.find_events('BREACH_STOP')
  T.eq(#ev, 1)
  T.eq(ev[1].d, {proj = 'c1', why = 'damp', pos = {12, 10, 100}, src = 'cancel'})
end)

local function build_doc(cells, x)
  x = x or 10
  return {v = 2, tpl = 'hospital', site = 'S1', class = 'living', params = {}, anchor = {x, 10, 100}, rot = 0,
          stages = {{label = 'build', mode = 'build', orders = 1, defense = 0,
                     chunks = {{pos = {x, 10, 100}, cells = cells}}}},
          manifest = {v = 2}, materials = {}}
end

T.test('orders: one call per stage before run, the created orders are counted and logged', function()
  local W = fresh{tag = 'orders'}
  H.floor(W, 10, 10, 100, 20, 10)
  H.place(W, 'h', build_doc({{0, 0, 0, 'b'}, {2, 0, 0, 'b'}, {4, 0, 0, 'Cw(3x1)'}}))
  H.settle(W); W.frame(1); H.settle(W)
  T.eq({#W.orders, H.proj(W, 'h').orders_done}, {1, 1})
  T.ok(logged(W, 'info', '^h build: 2 manager orders, 3 items'))
  T.eq(W.K.persist.get('m.runner').p.h.ord, 3)
  -- act.quickfort without orders.create_orders returns no order entries: warned, not retried
  local W2 = fresh{tag = 'orders2'}
  W2.orders_unfixed = true
  H.floor(W2, 10, 10, 100, 20, 10)
  H.place(W2, 'h', build_doc({{0, 0, 0, 'b'}}))
  H.settle(W2); W2.frame(1); H.settle(W2)
  T.ok(logged(W2, 'warn', 'created no manager orders'))
  H.runs(W2, 2)
  T.eq(#W2.orders, 1)
end)

T.test('orders: a failed call is retried next run (no build before it), given up after fail_max', function()
  local W = fresh{tag = 'ordfail', strict = false}
  W.qf_fail_cmd = 'orders'
  H.floor(W, 10, 10, 100, 20, 10)
  H.place(W, 'h', build_doc({{0, 0, 0, 'b'}}))
  H.settle(W); W.frame(1); H.settle(W)
  T.eq({H.proj(W, 'h').orders_done, #H.qf_calls(W, 'build', 'orders'), #H.qf_calls(W, 'build', 'run')}, {0, 1, 0})
  H.runs(W, 1)
  T.eq({H.proj(W, 'h').orders_done, #H.qf_calls(W, 'build', 'orders'), #H.qf_calls(W, 'build', 'run')}, {0, 2, 0})
  H.runs(W, 1)                                   -- third failure = fail_max: build without orders
  T.eq({H.proj(W, 'h').orders_done, #H.qf_calls(W, 'build', 'orders'), #H.qf_calls(W, 'build', 'run')}, {1, 3, 1})
  T.ok(logged(W, 'error', 'building without orders'))
  H.build(W); H.runs(W, 1)
  T.eq(H.proj(W, 'h').done, 1)
end)

T.test('stalled projects leave their slots to others and are re-measured outside the slots', function()
  local W = fresh{tag = 'stallslot'}
  H.floor(W, 10, 10, 100, 40, 10)
  for i = 1, 3 do H.place(W, 'b' .. i, build_doc({{0, 0, 0, 'b'}}, 10 * i)) end
  H.runs(W, 16)                                  -- no builders for over a week
  for i = 1, 3 do T.eq(H.proj(W, 'b' .. i).blocked, 'stalled', 'b' .. i) end
  local dig = function(id, x)
    return H.place(W, id, H.dig_doc(2, {x = x, y = 30, class = 'living', tpl = 'tombs'}),
                   {tpl = 'tombs', site = 'S1', prio = 5})
  end
  dig('d1', 60)
  H.runs(W, 1)
  T.eq(#H.qf_calls(W, 'dig', 'run'), 2)          -- prio 5 behind three stalled prio 4 builds
  dig('d2', 80); dig('d3', 100)
  H.runs(W, 1)
  T.eq(#H.qf_calls(W, 'dig', 'run'), 6)
  T.eq({row(W, 'd2')[4], row(W, 'b1')[4]}, {'', 'stalled'})
  H.build(W)                                     -- materials arrived, the beds got built
  H.runs(W, 5)
  for i = 1, 3 do T.eq(H.proj(W, 'b' .. i).done, 1, 'b' .. i .. ' measured without a slot') end
  T.eq(#H.qf_calls(W, 'build', 'run'), 3)        -- measure-only passes apply nothing
end)

T.test('build: a vanished building is re-placed once, then the stage passes', function()
  local W = fresh{tag = 'relost'}
  H.floor(W, 10, 10, 100, 20, 10)
  H.place(W, 'h', build_doc({{0, 0, 0, 'b'}, {2, 0, 0, 'b'}, {4, 0, 0, 'Cw(3x1)'}}))
  H.settle(W); W.frame(1); H.settle(W)
  T.eq(#W.orders, 1)
  T.eq(df.global.building_next_id, 6)            -- 2 beds + 3 wall constructions
  W.buildings[1] = nil
  W.bld_at['10,10,100'] = nil
  H.build(W)
  H.runs(W, 1); H.settle(W); W.frame(1); H.settle(W)
  T.eq(#H.qf_calls(W, 'build', 'run'), 2)        -- the re-apply placed the missing bed
  T.eq(#W.orders, 1)                             -- orders stay once per stage
  T.eq(H.proj(W, 'h').done, 0)
  H.build(W)
  H.runs(W, 1)
  T.eq(H.proj(W, 'h').done, 1)
end)

T.test('build: too many unsuitable tiles block the project with build_lost', function()
  local W = fresh{tag = 'blost'}
  H.floor(W, 10, 10, 100, 20, 10)
  W.unsuitable['12,10,100'] = true
  W.unsuitable['14,10,100'] = true
  H.place(W, 'h', build_doc({{0, 0, 0, 'b'}, {2, 0, 0, 'b'}, {4, 0, 0, 'b'}}))
  H.runs(W, 1); H.build(W); H.runs(W, 1); H.settle(W); W.frame(1); H.settle(W)
  H.build(W); H.runs(W, 1)
  T.eq(H.proj(W, 'h').blocked, 'build_lost')
  T.eq(#H.qf_calls(W, 'build', 'run'), 2)
end)

T.test('bp.cancel: plain removal, and undo walks the applied stages backwards', function()
  local W = fresh{tag = 'cancel'}
  H.place(W, 'a', H.doc{x = 10})
  H.place(W, 'b', H.doc{x = 40})
  H.runs(W, 1); H.dig(W); H.runs(W, 1); H.settle(W); W.frame(1); H.settle(W)
  T.eq(H.proj(W, 'b').stage, 1)
  local r = W.inbox('bp.cancel', {proj = 'a'})
  T.ok(r.ok and r.msg == 'cancelled a', r.msg)
  T.eq(H.proj(W, 'a'), nil)
  T.eq(W.K.persist.get('bp.a'), nil)
  r = W.inbox('bp.cancel', {proj = 'b', undo = true})
  T.ok(r.ok and r.msg:find('undo queued'), r.msg)
  T.eq(row(W, 'b')[4], 'cancel')
  H.runs(W, 1)
  local undo = H.qf_calls(W, nil, 'undo')
  T.eq(#undo, 3)                                 -- build chunk, then the 2 dig chunks
  T.eq({undo[1].mode, undo[2].mode, undo[3].mode}, {'build', 'dig', 'dig'})
  T.eq(W.undone, 3)
  T.eq(H.proj(W, 'b'), nil)
  T.ok(not W.inbox('bp.cancel', {proj = 'zz'}).ok)
end)

T.test('plan builds: y<Y>s<S>b<I> due per season, never twice, a missing file is reported once', function()
  local plan = {v = 2, year = 3, phase_target = 'P0', policy = {option = 'A', pop_ceiling = 55, beauty = 'none'},
                seasons = {{build = {{tpl = 'bedrooms', site = 'S1'}, {tpl = 'tombs', site = 'S2'}}},
                           {build = {{tpl = 'fortcore', site = 'S1', prio = 2}}}, {build = {}}, {build = {}}}}
  local W = fresh{tag = 'plan', plan = plan}
  H.put(W, 'y3s0b0', H.doc{x = 10})
  H.put(W, 'y3s1b0', H.dig_doc(1, {x = 40}))
  H.runs(W, 2)                                   -- one bp file per run (CONTRACTS R7: <= 1 decode per frame)
  T.ok(H.proj(W, 'y3s0b0') and not H.proj(W, 'y3s1b0'))
  local pb = W.find_events('PROJECT_BLOCKED')
  T.eq(#pb, 1)
  T.eq({pb[1].d.proj, pb[1].d.why}, {'y3s0b1', 'bp: missing'})
  W.df.global.cur_year_tick = 100800              -- summer
  H.runs(W, 1)
  T.eq(H.proj(W, 'y3s1b0').prio, 2)
  W.inbox('bp.cancel', {proj = 'y3s1b0'})
  W.set_plan(plan)                               -- plan.reload of the same year
  H.runs(W, 2)
  T.eq(H.proj(W, 'y3s1b0'), nil)
  T.eq(#W.find_events('PROJECT_BLOCKED'), 1)
end)

local PHASES = {
  {id = 'P0', title = 'p0', approve = false, deliver = {{k = 'baseline'}, {k = 'proj', tpl = 'fortcore', stage = 1}}},
  {id = 'P1', title = 'p1', approve = false, deliver = {{k = 'trade', n = 1}}},
  {id = 'P2', title = 'p2', approve = true, deliver = {{k = 'squads', n = 1}}},
}

T.test('phases: deliverables advance P0 -> P1 -> (approval) and PLAN_EXHAUSTED fires once', function()
  local W = fresh{tag = 'phase', phases = {v = 2, kind = 'phases', phases = PHASES}}
  W.load{name = 'baseline', every = {ticks = 33600}}       -- present, so 'baseline' is really checked
  H.runs(W, 1)
  T.eq(W.state().phase, 'P0')
  T.eq(#W.find_events('PLAN_EXHAUSTED'), 1)      -- nothing queued, P0 needs a project
  H.place(W, 'f1', H.dig_doc(1, {params = {stage = 1}}))
  H.runs(W, 1); H.dig(W); H.runs(W, 1)
  T.eq(H.proj(W, 'f1').done, 1)
  T.eq(W.state().phase, 'P0')                    -- baseline not done yet
  local m = W.K.persist.get('marker'); m.baseline = 1
  H.runs(W, 1)
  T.eq(W.state().phase, 'P1')                    -- trade module absent: skipped, but P2 needs approval
  local ph = W.K.persist.get('phase')
  T.eq({ph.phase, ph.done}, {'P1', {'P0'}})
  T.eq(W.find_events('PHASE')[1].d, {from = 'P0', to = 'P1'})
  T.eq(#W.find_events('PLAN_EXHAUSTED'), 2)
  H.runs(W, 3)
  T.eq(#W.find_events('PLAN_EXHAUSTED'), 2)
  W.set_plan{v = 2, year = 3, phase_target = 'P2', policy = {option = 'A', pop_ceiling = 55, beauty = 'none'},
             seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}}}
  W.K.plan.phases = PHASES
  W.load{name = 'military', every = {ticks = 3600}}       -- present: squads is checked (K.view().mil)
  H.runs(W, 1)
  T.eq(W.state().phase, 'P2')
  T.eq(#W.find_events('PLAN_EXHAUSTED'), 2)      -- P2 waits for squads, which no project delivers
end)

T.test('phases: a present module is asked; fortcore stage N passes through sN.* labels too', function()
  local W = fresh{tag = 'phase2', phases = PHASES, persist = {
    marker = {v = 2, adopted = 0, save = 'mock', fort = 'F', acceptance = 0, baseline = 1, boots = 1}}}
  local done = 0
  W.load{name = 'trade', every = {ticks = 100}, done = function() return done end}
  local d = H.dig_doc(1, {label = 's1.dig'})
  d.stages[2] = {label = 's2.dig', mode = 'dig', orders = 0, defense = 1,
                 chunks = {{pos = {10, 20, 100}, cells = {{0, 0, 0, 'd(5x1)'}}}}}
  d.params = {}
  H.place(W, 'fc', d)
  H.runs(W, 1); H.dig(W); H.runs(W, 1)
  T.eq(H.proj(W, 'fc').stage, 1)
  T.eq(W.state().phase, 'P1')                    -- s1.* done while the project still runs
  H.runs(W, 1)
  T.eq(W.state().phase, 'P1')                    -- trade.done() = 0 < 1
  done = 1
  H.runs(W, 1)
  T.eq(W.state().phase, 'P1')                    -- P2 needs phase_target >= P2
  local st = W.find_events('PROJECT_STAGE')
  T.eq({st[1].d.stage, st[1].d.defense}, {'s1.dig', 0})
end)

T.test('keepers: bedrooms once the phase is reached; cooldown; care owns tombs', function()
  local ph = {{id = 'P0', title = 'a', approve = false, deliver = {}},
              {id = 'P1', title = 'b', approve = false, deliver = {{k = 'proj', tpl = 'bedrooms'},
                                                                   {k = 'proj', tpl = 'tombs'}}}}
  local W = fresh{tag = 'keep', phases = ph, census = {u = {adults = 10}}}
  local zb = W.df.global.world.buildings.other.ZONE_BEDROOM
  zb:insert('#', {assigned_unit_id = 5, spec_sub_flag = {active = true}})
  zb:insert('#', {assigned_unit_id = -1, spec_sub_flag = {active = true}})
  zb:insert('#', {assigned_unit_id = -1, spec_sub_flag = {active = false}})
  H.runs(W, 1)
  local rq = W.find_events('PROJECT_REQUEST')
  T.eq(#rq, 2)                                   -- P0 passes at once -> P1; bedrooms and tombs (no care)
  T.eq(rq[1].d, {tpl = 'bedrooms', n = 12, why = 'free 1 < homeless 9 + 4'})
  T.eq(rq[2].d, {tpl = 'tombs', n = 6, why = 'free 0 < corpses 0 + 6'})
  H.runs(W, 12)
  T.eq(#W.find_events('PROJECT_REQUEST'), 2)     -- 7-day cooldown
  -- with care loaded the runner leaves tombs alone; another module's request also cools down
  local W2 = fresh{tag = 'keep2', phases = ph, census = {u = {adults = 2}}}
  local asked = false
  W2.load{name = 'care', every = {ticks = 1200}, step = function(K)
    if not asked then asked = true; K.emit('PROJECT_REQUEST', 'B', 'tombs', {tpl = 'tombs', n = 6}) end end}
  H.runs(W2, 6)
  local got = {}
  for _, e in ipairs(W2.find_events('PROJECT_REQUEST')) do got[#got + 1] = e.d.tpl end
  T.eq(got, {'bedrooms', 'tombs'})              -- runner: bedrooms only; tombs came from care
  T.ok(W2.K.persist.get('m.runner').req.tombs, 'care request cools the runner keeper down')
end)

T.test('keepers stay quiet while a bedrooms project is active', function()
  local ph = {{id = 'P0', title = 'a', approve = false, deliver = {{k = 'proj', tpl = 'bedrooms'}}}}
  local W = fresh{tag = 'keep3', phases = ph, census = {u = {adults = 30}}}
  W.load{name = 'care', every = {ticks = 1200}}
  H.place(W, 'bd', H.doc{})
  H.runs(W, 4)
  T.eq(#W.find_events('PROJECT_REQUEST'), 0)
end)

T.test('merge_manifest: maps per key, id/pos lists per entry, plain lists appended once', function()
  local m = {v = 2, bridges = {O1 = {role = 'outer', fp = {1, 1, 1, 3, 1, 1}, levers = {{5, 5, 1}}}},
             rooms = {{id = 'a', tpl = 'dining', use = 'used', bbox = {0, 0, 0, 1, 1, 0}, tier = 1}},
             zones = {Z2 = {{1, 1, 1, 2, 2, 1}}}, edge = {{0, 0, 1}}, stairs = {civ = {{1, 1, 0, 5}}},
             workshops = {{type = 'Masons', pos = {1, 2, 3}}}}
  runner.merge_manifest(m, {v = 2, bridges = {B1 = {role = 'inner', fp = {4, 4, 1, 6, 4, 1}, levers = {{7, 7, 1}}}},
                            rooms = {{id = 'a', tpl = 'dining', use = 'used', bbox = {0, 0, 0, 1, 1, 0}, tier = 2},
                                     {id = 'b', tpl = 'temple', use = 'used', bbox = {5, 5, 0, 6, 6, 0}, tier = 3}},
                            zones = {Z2 = {{1, 1, 1, 2, 2, 1}, {3, 3, 1, 4, 4, 1}}, Z3 = {{9, 9, 1, 9, 9, 1}}},
                            edge = {{0, 0, 1}, {1, 0, 1}}, stairs = {civ = {{1, 1, 0, 5}}, mil = {{2, 2, 0, 5}}},
                            workshops = {{type = 'Carpenters', pos = {1, 2, 3}}}, depot = {9, 9, 9},
                            refuge = {anchor = {1, 1, 1}, burrow = 'Tiefe+'}})
  T.eq(m.bridges.O1.role, 'outer')
  T.eq(m.bridges.B1.role, 'inner')
  T.eq({#m.rooms, m.rooms[1].tier, m.rooms[2].id}, {2, 2, 'b'})
  T.eq(#m.zones.Z2, 2)
  T.eq(#m.zones.Z3, 1)
  T.eq(m.edge, {{0, 0, 1}, {1, 0, 1}})
  T.eq(m.stairs, {civ = {{1, 1, 0, 5}}, mil = {{2, 2, 0, 5}}})
  T.eq(m.workshops, {{type = 'Carpenters', pos = {1, 2, 3}}})
  T.eq({m.depot, m.refuge.burrow, m.v}, {{9, 9, 9}, 'Tiefe+', 2})
  local again = json.encode(m)
  runner.merge_manifest(m, json.decode(again))    -- idempotent
  T.eq(json.encode(m), again)
end)

T.test('no snapshot module: dig progress from quickfort dry runs, at most every 2 days', function()
  local W = fresh{tag = 'dry', snapshot = false}
  H.place(W, 'c1', H.dig_doc(2))
  H.runs(W, 1)
  H.dig(W, 5)
  H.runs(W, 1)
  local dry = 0
  for _, c in ipairs(W.qf) do if c.dry then dry = dry + 1 end end
  T.eq(dry, 2)
  T.eq(H.proj(W, 'c1').pct, 50)
  H.dig(W)
  H.runs(W, 1)
  T.eq(H.proj(W, 'c1').done, 0)                  -- next dry run waits for 2 days
  H.runs(W, 3)
  T.eq(H.proj(W, 'c1').done, 1)
end)

T.test('a broken snapshot module falls back to dry runs for the rest of the run', function()
  local W = fresh{tag = 'snapfail', strict = false}
  H.place(W, 'c1', H.dig_doc(1))
  H.runs(W, 1)
  H.dig(W)
  W.snap_fail = true
  H.runs(W, 1)
  T.eq(H.proj(W, 'c1').done, 1)
  T.ok(#W.faults >= 1 and W.faults[1].module == 'snapshot')
end)

T.test('persist round trip: a reload mid-project continues; maps stay objects', function()
  local W = fresh{tag = 'reload'}
  H.place(W, 'c1', H.doc{})
  H.runs(W, 1); H.dig(W); H.runs(W, 1); H.settle(W); W.frame(1); H.settle(W)
  T.eq(H.proj(W, 'c1').stage, 1)
  local raw = W.persist_raw['dfllm.m.runner']
  T.ok(raw:find('"hist":{}') and raw:find('"planned":{}') and raw:find('"req":{}'), raw)
  local persist, map, bld, nid = H.reloaded(W), W.map, W.buildings, df.global.building_next_id
  local W2 = H.world{tag = 'reload2', persist = persist}
  W2.map = map
  for id, b in pairs(bld) do W2.add_building(b) end
  df.global.building_next_id = nid
  W2.load(runner)
  H.build(W2)
  H.runs(W2, 1)
  T.eq(H.proj(W2, 'c1').done, 1)
  T.eq(W2.K.manifest().rooms[1].id, 'r10')
end)

T.test('golden fortcore stage 1: every chunk applied once, probes per slice bounded', function()
  local dir = (arg and arg[0] or ''):gsub('\\', '/'):match('^(.*)/[^/]*$') or '.'
  local f = io.open(dir .. '/../bp/golden/fortcore.json', 'rb')
  T.ok(f, 'golden fortcore.json')
  local docs = json.decode(f:read('a')); f:close()
  local d = docs[1]
  local W = fresh{tag = 'golden'}
  runner.CFG.probe = 40                          -- small slices, so the 99-cell dig needs several
  local r = H.place(W, 'fc1', d)
  T.ok(r.ok, r.msg)
  H.runs(W, 1)
  T.eq(#H.qf_calls(W, 'dig', 'run'), #d.stages[1].chunks)
  local frames = {}
  for _, c in ipairs(W.qf) do
    T.ok(not frames[c.frame], 'two quickfort calls in one frame')
    frames[c.frame] = true
  end
  local per, tile = {}, W.snap.tile
  W.snap.tile = function(K, ...) per[W.frame_n] = (per[W.frame_n] or 0) + 1; return tile(K, ...) end
  H.runs(W, 1)
  local frames, most = 0, 0
  for _, n in pairs(per) do frames, most = frames + 1, math.max(most, n) end
  T.ok(frames > 1 and most <= 40, 'measurement is sliced: ' .. frames .. ' frames, max ' .. most)
  H.dig(W)
  for _ = 1, 3 do H.runs(W, 1); H.build(W) end
  H.runs(W, 3)
  local P = H.proj(W, 'fc1')
  T.eq(P.done, 1, 'fortcore stage 1 finished: ' .. tostring(P.blocked) .. ' stage ' .. P.stage)
  T.eq(W.K.manifest().burrows['Kern+'].role, 'kern')
  T.ok(#W.K.manifest().workshops == 5)
end)

T.done()
