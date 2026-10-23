-- WP7 runner: projects, stages, chunks, progress, BREACH_STOP, cancel/undo, plan builds, phases,
-- capacity keepers, manifest merge (CONTRACTS §7, §9.8-§9.9, §10-§13), on k_mock with a fake quickfort.
local T = require('testlib')
local H = require('runner_world')
local kmock = require('dfllm.util.k_mock')
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
  T.eq(row(W, 'p3')[4], 'queued behind p5 +2')       -- BUG-037: the rows name the first slot holder
  T.eq(row(W, 'p5')[4], '')
end)

T.test('bboxes: running projects, and a finished cistern stays in (its pipe leaves the audit box, live L4)', function()
  local W = fresh{tag = 'bboxes'}
  local r1 = H.place(W, 'b1', H.dig_doc(1, {tpl = 'bedrooms', params = {}, class = 'living', label = 'dig'}))
  T.ok(r1.ok, r1.msg)
  local r2 = H.place(W, 'c1', H.dig_doc(1, {tpl = 'cistern', params = {}, class = 'infra', label = 'dig', x = 40}))
  T.ok(r2.ok, r2.msg)
  H.settle(W)
  T.eq(#select(2, W.K.call('runner', 'bboxes')), 2)
  W.frame(1); H.settle(W)
  H.runs(W, 1)
  H.dig(W)
  H.runs(W, 4)
  T.eq(H.proj(W, 'b1').done, 1)
  T.eq(H.proj(W, 'c1').done, 1)
  local boxes = select(2, W.K.call('runner', 'bboxes'))
  T.eq(#boxes, 2, 'the finished bedrooms and the cistern stay (live L7: a bedrooms block at the box edge read as a bypass)')
  local wide = false
  for _, b in ipairs(boxes) do if b[1] <= 40 and b[4] >= 44 then wide = true end end
  T.ok(wide, 'the cistern box')
  local rt = W.K.persist.get('m.runner')
  for k in pairs(rt.keep) do rt.keep[k] = nil end           -- finished before L4: rebuilt from its bp file
  local again = select(2, W.K.call('runner', 'bboxes'))
  T.eq(again, boxes)
end)

-- BUG-043 (Run 11 y479): snapshot's default audit box is made of runner.boxes; an explore is a column part of it, and
-- the audit must keep the entrances (finished seals) and the shafts (finished explores) after they are done
T.test('BUG-043: boxes names each project; finished seals and explores stay in, a kept explore stays an explore', function()
  local W = fresh{tag = 'boxes'}
  T.ok(H.place(W, 'b1', H.dig_doc(1, {tpl = 'bedrooms', params = {}, class = 'living', label = 'dig'})).ok)
  T.ok(H.place(W, 'e1', H.dig_doc(1, {tpl = 'explore', params = {depth = 2}, class = 'infra', label = 'dig', x = 40})).ok)
  T.ok(H.place(W, 's1', H.dig_doc(1, {tpl = 'seal', params = {}, class = 'defense', label = 'dig', x = 70})).ok)
  H.settle(W)
  local function named(W2)
    local r = {}
    for _, e in ipairs(select(2, W2.K.call('runner', 'boxes'))) do r[e.id] = e.tpl end
    return r
  end
  T.eq(named(W), {b1 = 'bedrooms', e1 = 'explore', s1 = 'seal'})
  W.frame(1); H.settle(W)
  for _ = 1, 6 do H.runs(W, 1); H.dig(W) end
  H.runs(W, 4)
  T.eq({H.proj(W, 'e1').done, H.proj(W, 's1').done}, {1, 1})
  T.eq(named(W), {b1 = 'bedrooms', e1 = 'explore', s1 = 'seal'}, 'finished: their boxes kept')
  T.eq(W.K.persist.get('m.runner').kk, {e1 = 'explore', s1 = 'seal'})
  local eb = select(2, W.K.call('runner', 'boxes'))
  for _, e in ipairs(eb) do
    if e.id ~= 'b1' then T.eq(select(2, W.K.call('runner', 'kept_in', e.b)), nil, 'a kept ' .. e.tpl .. ' is no room') end
  end
  local pd = W.K.persist.get('projects')              -- the done projects pruned from the list (done_keep)
  local keep = {}
  for _, P in ipairs(pd.list) do if P.done ~= 1 then keep[#keep + 1] = P end end
  pd.list = keep
  T.eq(named(W), {b1 = 'done', e1 = 'explore', s1 = 'seal'}, 'a kept shaft stays a column after the list forgets it')
  T.eq(#select(2, W.K.call('runner', 'bboxes')), 3)
end)

T.test('dig_backlog: tiles left in the running dig stages (economy sizes the Miners detail from it)', function()
  local W = fresh{tag = 'backlog'}
  H.place(W, 'b1', H.dig_doc(2))                         -- 2 chunks x 5 tiles of rock
  H.settle(W)
  T.eq(select(2, W.K.call('runner', 'dig_backlog')), 10)
  W.frame(1); H.settle(W)
  H.runs(W, 1)
  H.dig(W, 4)
  H.runs(W, 1)
  T.eq(select(2, W.K.call('runner', 'dig_backlog')), 6)
  H.dig(W)
  H.runs(W, 2)
  T.eq(select(2, W.K.call('runner', 'dig_backlog')), 0)
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
  T.eq(H.proj(W, 'a').blocked, 'breach:cavern_lake')         -- Run 11: DF's discovery of water is a cavern lake
  T.eq(H.proj(W, 'b').blocked, 'breach:cavern_lake')
  H.runs(W, 2)
  T.eq(#W.find_events('CAVERN_PLUG'), 0, 'no tile, no explore shaft: no plug and no false alarm')
end)

T.test('tile checks: revealed water stops the dig; a lost designation without a damp report is re-marked once', function()
  local W = fresh{tag = 'tiles'}
  H.place(W, 'c1', H.dig_doc(2))
  H.place(W, 'c2', H.dig_doc(2, {x = 40}))
  H.runs(W, 2)                                   -- applied, then measured: designations seen
  T.eq(#W.find_events('BREACH_STOP'), 0)
  W.tile(11, 10, 100).dig = ''                   -- still '#', no designation, no damp report (live L1)
  W.tile(41, 11, 100).c = '~'
  local n = #H.qf_calls(W, 'dig', 'run')
  H.runs(W, 1)
  local ev = W.find_events('BREACH_STOP')
  T.eq(#ev, 1)
  T.eq(ev[1].d, {proj = 'c2', why = 'water', pos = {41, 11, 100}, src = 'tile'})
  T.eq(#H.qf_calls(W, 'dig', 'run'), n + 1, 'the chunk is designated again')
  T.eq(W.tile(11, 10, 100).dig, 'd')
  T.eq(H.proj(W, 'c1').blocked, '')
  T.ok(logged(W, 'warn', '^c1 s1.dig chunk 0: designation at 11,10,100 lost without a damp report'))
  W.tile(11, 10, 100).dig = ''                   -- lost again: blocked, nothing undone
  local u = #H.qf_calls(W, 'dig', 'undo')
  H.runs(W, 1)
  T.eq(H.proj(W, 'c1').blocked, 'dig_lost')
  T.eq(#H.qf_calls(W, 'dig', 'undo'), u)
  T.eq(#W.find_events('BREACH_STOP'), 1)
end)

T.test('tile checks: a lost designation with a damp report in the announcement log is a damp breach', function()
  local W = fresh{tag = 'tileslog'}
  H.place(W, 'c1', H.dig_doc(2))
  H.runs(W, 2)
  -- the report reached the log but not the runner (e.g. the kernel was stopped when DF announced it)
  df.global.world.status.reports:insert('#', {id = 9001, type = df.announcement_type.DIG_CANCEL_DAMP, text = 'damp',
                                              pos = {x = 12, y = 10, z = 100}})
  W.tile(11, 10, 100).dig = ''
  H.runs(W, 1)
  local ev = W.find_events('BREACH_STOP')
  T.eq(#ev, 1)
  T.eq(ev[1].d, {proj = 'c1', why = 'damp', pos = {11, 10, 100}, src = 'cancel'})
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
  W.tile(10, 12, 100).c = '~'                    -- water revealed in the last chunk
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

T.test('probe: a hidden tile under a mine key is designated; revealed without designation: report decides', function()
  local W = fresh{tag = 'hidden'}
  W.tile(12, 10, 100).hidden = true
  H.place(W, 'c1', H.dig_doc(1))
  H.runs(W, 2)
  T.eq(#W.find_events('BREACH_STOP'), 0)
  T.eq(W.K.persist.get('m.runner').p.c1.sp['1'], '11111')  -- tile 3 (hidden: snapshot nil) marked too
  local t = W.tile(12, 10, 100)
  t.hidden, t.dig = nil, ''                      -- revealed, designation gone, no report: marked again
  H.runs(W, 1)
  T.eq(#W.find_events('BREACH_STOP'), 0)
  T.eq(W.tile(12, 10, 100).dig, 'd')
  T.eq(W.K.persist.get('m.runner').p.c1.rl['1'], 1)
  df.global.world.status.reports:insert('#', {id = 9002, type = df.announcement_type.DIG_CANCEL_WARM, text = 'warm',
                                              pos = {x = 12, y = 10, z = 100}})
  W.tile(12, 10, 100).dig = ''                   -- now DF announced it in the log: a breach, never re-marked
  H.runs(W, 1)
  local ev = W.find_events('BREACH_STOP')
  T.eq(#ev, 1)
  T.eq(ev[1].d, {proj = 'c1', why = 'warm', pos = {12, 10, 100}, src = 'cancel'})
end)

T.test('probe: a dig stage whose only pending tiles are hidden completes after hidden_wait (live L1)', function()
  local W = fresh{tag = 'hiddenwait'}
  H.place(W, 'c1', H.dig_doc(1))
  W.tile(12, 10, 100).hidden = true
  H.runs(W, 2)
  local t = W.tile(12, 10, 100)
  local keep = t.dig
  t.dig = ''                                     -- H.dig skips it: nothing reaches it (a 'j' over a 'u')
  H.dig(W)
  t.dig = keep
  H.runs(W, 1)
  T.eq(H.proj(W, 'c1').done, 0, 'waits for the hidden tile first')
  H.runs(W, runner.CFG.hidden_wait // 600 + 2)
  T.eq(H.proj(W, 'c1').done, 1)
  T.ok(logged(W, 'warn', '^c1 s1.dig: 1 hidden tiles never reached'))
  T.eq(#W.find_events('BREACH_STOP'), 0)
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

T.test('orders: sliced to orders_cells per call (S6: 60 ms for one 19-cell stage), grouped by key', function()
  local W = fresh{tag = 'orders3'}
  H.floor(W, 10, 10, 100, 40, 12)
  local cells = {}
  for i = 0, 18 do cells[#cells + 1] = {i, i % 2, 0, i % 2 == 0 and 'b' or 'd'} end   -- 10 beds, 9 doors
  H.place(W, 'h', build_doc(cells))
  H.settle(W)
  for _ = 1, 6 do W.frame(1); H.settle(W) end
  T.eq(#W.orders, 3, '19 cells: 8 + 8 + 3')
  local function keys(o)
    local r = {}
    for _, g in pairs(o.data) do for _, row in pairs(g) do for _, t in pairs(row) do r[#r + 1] = t end end end
    table.sort(r)
    return table.concat(r)
  end
  T.eq({keys(W.orders[1]), keys(W.orders[2]), keys(W.orders[3])}, {'bbbbbbbb', 'bbdddddd', 'ddd'})
  T.eq(H.proj(W, 'h').orders_done, 1)
  T.ok(logged(W, 'info', '^h build: 4 manager orders, 19 items'))
  local R = W.K.persist.get('m.runner').p.h
  T.eq({R.oc, R.on, R.ord}, {20, 4, 19})
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

T.test('stall: a dig stage waiting while another project digs is not stalled (shared miners, live L1b)', function()
  local W = fresh{tag = 'stall2'}
  local week = runner.CFG.stall // 600
  H.place(W, 'a1', H.dig_doc(4, {x = 10}))
  H.place(W, 'b1', H.dig_doc(1, {x = 30}))
  H.runs(W, 1)
  local function dig_a(n)                          -- miners only work on a1
    local keys = {}
    for k, t in pairs(W.map) do
      local x = tonumber(k:match('^(%d+),'))
      if t.dig ~= '' and x and x < 20 then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for i = 1, math.min(n, #keys) do local t = W.map[keys[i]]; t.c, t.dig = '.', '' end
  end
  for _ = 1, week + 2 do dig_a(1); H.runs(W, 1) end
  T.eq(H.proj(W, 'b1').blocked, '', 'b1 waits for the miners, it does not stall')
  for _ = 1, week + 2 do H.runs(W, 1) end
  T.eq(H.proj(W, 'b1').blocked, 'stalled', 'nobody digs anywhere: stalled')
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

-- Run 11 (Kilrudrabed y432): `seal at=last` ended build_lost (missing d) while ConstructDoor was cancelled for rock and
-- logs could have made the door. A seal with one door on a floor tile; DF removes the planned door each time (`lose`).
local function seal_doc()
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = '10,10,100 floor'}, anchor = {10, 10, 100},
          rot = 0, stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                              chunks = {{pos = {10, 10, 100}, cells = {{0, 0, 0, 'd'}}}}}},
          manifest = {v = 2}, materials = {}}
end
local function lose(W)                              -- the planned door at 10,10,100 vanishes
  local id = W.bld_at['10,10,100']
  if id then W.buildings[id], W.bld_at['10,10,100'] = nil, nil end
end
local function seal_world(tag, ctl)
  local W = fresh{tag = tag}
  H.floor(W, 10, 10, 100, 10, 10)
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function(K, kind, n)
    ctl.asked[#ctl.asked + 1] = kind .. ' x' .. n
    return ctl.via, ctl.why
  end})
  H.place(W, 'y432s0b0', seal_doc())
  H.settle(W); W.frame(1); H.settle(W)
  return W
end

T.test('Run 11: a seal whose door was lost is placed again while economy can make the door, not build_lost', function()
  local ctl = {asked = {}, via = 'wood'}
  local W = seal_world('sealmat', ctl)
  T.eq(#H.qf_calls(W, 'build', 'run'), 1)
  lose(W); H.runs(W, 1); H.settle(W); W.frame(1); H.settle(W)
  T.eq(#H.qf_calls(W, 'build', 'run'), 2, 'the one re-apply of every build stage')
  lose(W); H.runs(W, 1); H.settle(W); W.frame(1); H.settle(W)
  T.eq(H.proj(W, 'y432s0b0').blocked, '', 'old code: build_lost (missing d) after the one re-apply')
  T.eq(#H.qf_calls(W, 'build', 'run'), 3)
  T.eq(ctl.asked[1], 'door x1')
  T.ok(logged(W, 'info', '^y432s0b0 seal.build: lost pieces placed again %(1/4%): economy can make them'))
  H.build(W); H.runs(W, 2)
  T.eq(H.proj(W, 'y432s0b0').done, 1, 'the door stands')
  -- bounded: a door lost again and again ends build_lost after remake_max more placements
  local W2 = seal_world('sealmax', ctl)
  for _ = 1, runner.CFG.remake_max + 2 do lose(W2); H.runs(W2, 1); H.settle(W2); W2.frame(1); H.settle(W2) end
  T.eq(H.proj(W2, 'y432s0b0').blocked, 'build_lost')
  T.eq(#H.qf_calls(W2, 'build', 'run'), 2 + runner.CFG.remake_max)
end)

T.test('Run 11: no material for the seal\'s door: build_lost, PROJECT_BLOCKED names economy\'s reason; retried once ' ..
       'the door can be made', function()
  local ctl = {asked = {}, via = nil, why = 'no material for door: no rock, no logs'}
  local W = seal_world('sealnomat', ctl)
  lose(W); H.runs(W, 1); H.settle(W); W.frame(1); H.settle(W)
  lose(W); H.runs(W, 1)
  T.eq(H.proj(W, 'y432s0b0').blocked, 'build_lost')
  H.runs(W, 5)                                     -- blocked > 2 days
  local pb = W.find_events('PROJECT_BLOCKED')
  T.eq(#pb, 1)
  T.ok(pb[1].msg:find('blocked: build_lost at seal.build, missing d (no material for door: no rock, no logs)', 1, true),
       pb[1].msg)
  T.eq(pb[1].d.mat, 'no material for door: no rock, no logs')
  H.runs(W, 4)
  T.eq(H.proj(W, 'y432s0b0').blocked, 'build_lost', 'nothing changed: no retry')
  ctl.via, ctl.why = 'wood', nil                   -- logs came in
  H.runs(W, 3)
  local P = H.proj(W, 'y432s0b0')
  T.eq({P.stage, P.blocked}, {0, ''})
  T.ok(logged(W, 'info', '^y432s0b0: build_lost at seal.build, retry 1/8 from seal.build %(its pieces can be made now%)'))
  -- a seal an older kernel blocked (its retry record knows nothing of material): tried once the door can be made
  local c2 = {asked = {}, via = nil, why = 'no material for door: no rock, no logs'}
  local W2 = seal_world('sealold', c2)
  lose(W2); H.runs(W2, 1); H.settle(W2); W2.frame(1); H.settle(W2)
  lose(W2); H.runs(W2, 3)
  local q = W2.K.persist.get('m.runner').rty.y432s0b0
  T.eq(q.cant, true)
  q.cant = nil
  c2.via = 'rock'
  H.runs(W2, 3)
  T.eq(H.proj(W2, 'y432s0b0').blocked, '')
end)

-- BUG-022 (Run 10 Handlelock y364: fortcore stage 2 "s2.dig: 61 hidden tiles never reached; stage completes
-- without them", then s2.build blocked build_lost for two game years: B1 and its levers never built; the live
-- workaround cancelled it and placed stage 2 again at site=same). A fortcore-like stage 2: the dig reaches row 10
-- and four hidden tiles of row 11 never; the build puts B1 (manifest footprint 12-14,11) and a trap (11,11) on them.
local function stage2_doc()
  return {v = 2, tpl = 'fortcore', site = 'S1', class = 'defense', params = {stage = 2}, anchor = {10, 10, 100}, rot = 0,
          stages = {
            {label = 's2.dig', mode = 'dig', orders = 0, defense = 1,
             chunks = {{pos = {10, 10, 100}, cells = {{0, 0, 0, 'd(5x1)'}}},
                       {pos = {10, 11, 100}, cells = {{0, 0, 0, 'd(5x1)'}, {0, 1, 0, 's(3x1)'}}}}},
            {label = 's2.build', mode = 'build', orders = 1, defense = 1,
             chunks = {{pos = {10, 10, 100}, cells = {{0, 0, 0, 'Tl'}, {2, 1, 0, 'gw(3x1)'}, {4, 0, 0, 'Tl'},
                                                      {1, 1, 0, 'Ts'}}}}},
            {label = 's2.zone', mode = 'zone', orders = 0, defense = 0,
             chunks = {{pos = {10, 10, 100}, cells = {{0, 0, 0, 'B(5x1)'}}}}},
          },
          manifest = {v = 2, bridges = {B1 = {role = 'inner', fp = {12, 11, 100, 14, 11, 100},
                                              levers = {{10, 10, 100}, {14, 10, 100}}}}},
          materials = {}}
end

-- the hidden tiles of row 11 (x 11-14) and the smoothing row 12 under them: designated or not, nobody reaches them
local HID = {{11, 11}, {12, 11}, {13, 11}, {14, 11}, {10, 12}, {11, 12}, {12, 12}}
local function hide(W)
  for _, t in ipairs(HID) do W.tile(t[1], t[2], 100).hidden = true end
end
local function dig_reachable(W)               -- the miners dig every designated tile that is not hidden
  local keep = {}
  for _, t in ipairs(HID) do
    local tl = W.tile(t[1], t[2], 100)
    if tl.hidden then keep[#keep + 1] = {tl, tl.dig}; tl.dig = '' end
  end
  H.dig(W)
  for _, k in ipairs(keep) do k[1].dig = k[2] end
end

local function to_build_lost(W)
  dfhack.buildings = {findAtTile = function(x, y, z)  -- DF's building lookup (a stage placed again, live L2)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end}
  hide(W)
  H.place(W, 'y364s2b0', stage2_doc())
  H.runs(W, 1)
  dig_reachable(W)
  H.runs(W, runner.CFG.hidden_wait // 600 + 2)   -- the dig completes without the hidden tiles
  H.runs(W, 1); H.settle(W); W.frame(1); H.settle(W)
  H.build(W)                                       -- the two levers stand
  H.runs(W, 3); H.settle(W); W.frame(1); H.settle(W)
  H.build(W)
  H.runs(W, 2)
end

T.test('BUG-022: a build_lost stage names its missing pieces and runs again from its dig stage once the skipped ' ..
       'tiles are revealed; PROJECT_BLOCKED once', function()
  local W = fresh{tag = 'blretry'}
  to_build_lost(W)
  local P = H.proj(W, 'y364s2b0')
  T.eq({P.stage, P.blocked}, {1, 'build_lost'})
  T.ok(logged(W, 'warn', '^y364s2b0 s2.dig: 4 hidden tiles never reached'))
  -- the hidden tiles the dig stage completed without are kept per chunk (revealed ones are never kept)
  local sk = W.K.persist.get('m.runner').skip.y364s2b0
  T.eq({sk.si, sk.n, sk.c['1']}, {0, 7, {{10, 12, 100}, {11, 12, 100}, {12, 12, 100}, {11, 11, 100}, {12, 11, 100},
                                          {13, 11, 100}, {14, 11, 100}}})
  H.runs(W, 4)                                     -- blocked > 2 days
  local pb = W.find_events('PROJECT_BLOCKED')
  T.eq(#pb, 1)
  T.eq({pb[1].d.why, pb[1].d.stage, pb[1].d.missing, pb[1].d.retry}, {'build_lost', 's2.build', {'B1', 'trap'}, 0})
  T.ok(pb[1].msg:find('blocked: build_lost at s2.build, missing B1, trap; retry 1/8 once the skipped tiles are ' ..
       'revealed, at the latest next season', 1, true), pb[1].msg)
  local nqf = #W.qf
  H.runs(W, 20)                                    -- nothing changed: no retry, no repeat
  T.eq({H.proj(W, 'y364s2b0').blocked, #W.qf, #W.find_events('PROJECT_BLOCKED')}, {'build_lost', nqf, 1})
  -- years later the gatehouse is reached: the tiles are revealed (still rock)
  for _, t in ipairs(HID) do W.tile(t[1], t[2], 100).hidden = nil end
  H.runs(W, 3)
  P = H.proj(W, 'y364s2b0')
  T.eq({P.stage, P.blocked}, {0, ''}, 'back at s2.dig')
  T.ok(logged(W, 'info', '^y364s2b0: build_lost at s2.build, retry 1/8 from s2.dig %(7 more tiles revealed or open%)'))
  T.eq(W.tile(13, 11, 100).dig, 'd', 'the revealed tiles are designated now')
  H.dig(W)
  H.runs(W, 2); H.settle(W); W.frame(1); H.settle(W)
  H.runs(W, 1); H.settle(W)
  H.build(W)
  H.runs(W, 3)
  P = H.proj(W, 'y364s2b0')
  T.eq(P.done, 1, 'B1 and the trap stand: the project finished')
  T.eq(#W.find_events('PROJECT_BLOCKED'), 1)
  T.eq(W.K.persist.get('m.runner').rty.y364s2b0, nil, 'the records go with the project')
  dfhack.buildings = nil
end)

T.test('BUG-022: without news a build_lost stage is retried each retry_every, retry_max times; then one final ' ..
       'PROJECT_BLOCKED (cadence)', function()
  local W = fresh{tag = 'blbudget'}
  runner.CFG.retry_every, runner.CFG.retry_max = 12 * 600, 2
  to_build_lost(W)
  H.runs(W, 4)
  T.eq(#W.find_events('PROJECT_BLOCKED'), 1)
  local retries = function()
    local n = 0
    for _, l in ipairs(W.logs) do if l.msg:find('^y364s2b0: build_lost at s2.build, retry') then n = n + 1 end end
    return n
  end
  for _ = 1, 4 do
    H.runs(W, 14)
    dig_reachable(W)
    H.runs(W, runner.CFG.hidden_wait // 600 + 2); H.settle(W); W.frame(1); H.settle(W)
    H.build(W)
    H.runs(W, 3); H.settle(W); W.frame(1); H.settle(W)
    W.ms = W.ms + 600000                            -- ten wall minutes: only the cadence's news gate is left
  end
  T.eq(retries(), 2, 'retry_max')
  T.ok(logged(W, 'info', 'retry 2/2 from s2.dig %(a season passed%)'))
  H.runs(W, 20)
  local pb, park = {}, {}
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do       -- BUG-037: parked 30 days later, its own announcement
    if e.d.park then park[#park + 1] = e else pb[#pb + 1] = e end
  end
  T.eq(H.proj(W, 'y364s2b0').blocked, 'build_lost')
  T.eq(#pb, 2, 'the first block and the spent budget, nothing in between')
  T.ok(#park <= 1 and (#park == 0 or park[1].d.park >= 29), 'parked once, after queue.park_days')
  T.ok(pb[2].msg:find('; 2 retries spent: bp.cancel and place it again', 1, true), pb[2].msg)
  T.eq(pb[2].d.retry, 2)
  dfhack.buildings = nil
end)

T.test('BUG-022: a stall that clears and comes back at the same stage is announced once (cadence)', function()
  local W = fresh{tag = 'stallcad'}
  local week = runner.CFG.stall // 600
  H.place(W, 'c1', H.dig_doc(2))
  H.runs(W, week + 2)
  H.runs(W, 5)
  T.eq(#W.find_events('PROJECT_BLOCKED'), 1)
  for _ = 1, 3 do                                   -- dig a little, stall again, blocked > 2 days again
    H.dig(W, 1)
    H.runs(W, 1)
    T.eq(H.proj(W, 'c1').blocked, '')
    H.runs(W, week + 7)
    W.ms = W.ms + 600000
    T.eq(H.proj(W, 'c1').blocked, 'stalled')
  end
  T.eq(#W.find_events('PROJECT_BLOCKED'), 1, 'old code: one per episode, every stall again')
end)

T.test('build: a stage placed again over its own buildings tracks them instead of build_lost (live L2)', function()
  local W = fresh{tag = 'replace'}
  H.floor(W, 10, 10, 100, 20, 10)
  dfhack.buildings = {findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end}
  H.place(W, 'h', build_doc({{0, 0, 0, 'b'}, {2, 0, 0, 'b'}}))
  H.settle(W); W.frame(1); H.settle(W)
  T.eq(df.global.building_next_id, 3)
  H.build(W)
  W.buildings[2]._st = 0                           -- the second bed is still a plan
  local n_orders = #W.orders
  H.place(W, 'h2', build_doc({{0, 0, 0, 'b'}, {2, 0, 0, 'b'}, {4, 0, 0, 'b'}}))
  H.runs(W, 1); H.settle(W); W.frame(1); H.settle(W)
  T.eq(df.global.building_next_id, 4, 'only the missing bed is placed')
  local cells = 0
  for i = n_orders + 1, #W.orders do H.cells(W.orders[i], function() cells = cells + 1 end) end
  T.eq(cells, 1, 'manager orders only for the cell without a building')
  H.runs(W, 2)
  T.eq(H.proj(W, 'h2').blocked, '', 'not build_lost')
  T.eq(H.proj(W, 'h2').done, 0, 'the planned bed keeps the stage pending')
  H.build(W)
  H.runs(W, 2)
  T.eq(H.proj(W, 'h2').done, 1)
  dfhack.buildings = nil
end)

-- BUG-042 (Run 11, y471: 110 ConstructDoor among 446 manager orders, most of them rock doors waiting for stone): a seal
-- placed again, retried or remade ordered a door for every door cell without a building while the older door orders
-- still waited. A door or hatch cell gets no manager order while the open one-time orders of its job hold orders_cap.
T.test('BUG-042: door/hatch cells get no quickfort order while open door orders hold orders_cap; others do', function()
  local W = fresh{tag = 'dcap'}
  H.floor(W, 10, 10, 100, 20, 10)
  local jt, ft, mo = df.job_type, df.workquota_frequency_type, df.global.world.manager_orders
  df.job_type = {ConstructDoor = 10, ConstructHatchCover = 21, ConstructBed = 16, [10] = 'ConstructDoor',
                 [21] = 'ConstructHatchCover', [16] = 'ConstructBed'}
  df.workquota_frequency_type = {OneTime = 0, Daily = 1, [0] = 'OneTime', [1] = 'Daily'}
  local list = {}
  for i = 1, 110 do list[i] = {id = i, job_type = 10, frequency = 0, amount_left = 1, mat_type = 0} end
  df.global.world.manager_orders = {all = kmock.vec(list), manager_order_next_id = 111}
  H.place(W, 'h', build_doc({{0, 0, 0, 'd'}, {2, 0, 0, 'b'}, {4, 0, 0, 'H'}}))
  H.settle(W); W.frame(1); H.settle(W)
  local keys = {}
  for _, o in ipairs(W.orders) do H.cells(o, function(_, _, _, k) keys[#keys + 1] = k end) end
  table.sort(keys)
  T.eq(keys, {'H', 'b'}, 'the door cell is left out (110 open door orders >= 10), bed and hatch ordered')
  T.ok(logged(W, 'info', '^h build: 1 door cells get no manager order: 110 open ConstructDoor orders %(cap 10%)'))
  -- below the cap the door is ordered as before
  local W2 = fresh{tag = 'dcap2'}
  H.floor(W2, 10, 10, 100, 20, 10)
  df.global.world.manager_orders = {all = kmock.vec({list[1], list[2]}), manager_order_next_id = 111}
  H.place(W2, 'h', build_doc({{0, 0, 0, 'd'}}))
  H.settle(W2); W2.frame(1); H.settle(W2)
  local k2 = {}
  for _, o in ipairs(W2.orders) do H.cells(o, function(_, _, _, k) k2[#k2 + 1] = k end) end
  T.eq(k2, {'d'})
  df.job_type, df.workquota_frequency_type, df.global.world.manager_orders = jt, ft, mo
end)

T.test('zone: one-owner zone cells already zoned (tomb over a tombed coffin) are left out (live L3)', function()
  local W = fresh{tag = 'zdup'}
  local czt, bld = df.civzone_type, dfhack.buildings
  df.civzone_type = {Tomb = 9, Bedroom = 2, Office = 3, [9] = 'Tomb', [2] = 'Bedroom', [3] = 'Office'}
  local zoned = {['10,10,100'] = {{type = 9}}, ['12,10,100'] = {{type = 2}}}
  dfhack.buildings = {findCivzonesAt = function(pos) return zoned[pos.x .. ',' .. pos.y .. ',' .. pos.z] or {} end}
  local d = build_doc({})
  d.stages = {{label = 'zone', mode = 'zone', orders = 0, defense = 0,
               chunks = {{pos = {10, 10, 100}, cells = {{0, 0, 0, 'T'}, {2, 0, 0, 'T'}, {4, 0, 0, 'm(2x2)'}}},
                         {pos = {10, 10, 100}, cells = {{0, 0, 0, 'T'}}}}}}
  H.place(W, 'tz', d)
  H.runs(W, 2)
  local calls = H.qf_calls(W, 'zone')
  T.eq(#calls, 1, 'the all-duplicate second chunk makes no call')
  local keys = {}
  H.cells(calls[1], function(x, y, z, key) keys[#keys + 1] = x .. ':' .. key end)
  table.sort(keys)
  T.eq(keys, {'12:T', '14:m'}, 'a tomb over a bedroom zone and the meeting area stay; the tombed coffin is skipped')
  T.eq(H.proj(W, 'tz').done, 1)
  T.ok(logged(W, 'info', 'cells already zoned, left out'))
  dfhack.buildings, df.civzone_type = bld, czt
end)

-- FR-27: a tombs document whose zone stage has 1x1 tomb cells at x = 10, 12, 14 and a 2x1 one at 16..17 (z 100)
local function tomb_doc()
  return {v = 2, tpl = 'tombs', site = 'S1', class = 'living', params = {n = 4}, anchor = {10, 10, 100}, rot = 0,
          stages = {{label = 'build', mode = 'build', orders = 0, defense = 0,
                     chunks = {{pos = {10, 10, 100}, cells = {{0, 0, 0, 'n'}, {2, 0, 0, 'n'}, {4, 0, 0, 'n'}}}}},
                    {label = 'zone', mode = 'zone', orders = 0, defense = 0,
                     chunks = {{pos = {10, 10, 100}, cells = {{0, 0, 0, 'T(1x1)'}, {2, 0, 0, 'T(1x1)'}, {4, 0, 0, 'T(1x1)'},
                                                             {6, 0, 0, 'T(2x1)'}}}}}},
          manifest = {v = 2}, materials = {}}
end

T.test('FR-27: bp.place cuts tomb cells over a tile that has a tomb zone, refuses a document with no other', function()
  local W = fresh{tag = 'tdup'}
  local czt, bld = df.civzone_type, dfhack.buildings
  df.civzone_type = {Tomb = 9, Bedroom = 2, [9] = 'Tomb', [2] = 'Bedroom'}
  local zoned = {['10,10,100'] = {{type = 9}}, ['17,10,100'] = {{type = 9}}, ['12,10,100'] = {{type = 2}}}
  dfhack.buildings = {findCivzonesAt = function(pos) return zoned[pos.x .. ',' .. pos.y .. ',' .. pos.z] or {} end}
  local r = H.place(W, 't1', tomb_doc())
  T.ok(r.ok and r.msg:find('2 of 4 tomb cells left out', 1, true) and r.msg:find('10,10,100', 1, true), r.msg)
  local z = W.K.persist.get('bp.t1').stages[2].chunks[1].cells
  T.eq(z, {{2, 0, 0, 'T(1x1)'}, {4, 0, 0, 'T(1x1)'}}, 'a tomb over a bedroom zone stays; one tile of the 2x1 is zoned')
  T.eq(#W.K.persist.get('bp.t1').stages[1].chunks[1].cells, 3, 'the coffins stay')
  T.ok(logged(W, 'info', 'tomb cells already zoned, left out'))
  for _, k in ipairs({'12,10,100', '14,10,100', '16,10,100'}) do zoned[k] = {{type = 9}} end
  r = H.place(W, 't2', tomb_doc())
  T.ok(not r.ok and r.msg:find('refused: a tomb zone already stands on all 4 tomb cells', 1, true), r.msg)
  T.eq(H.proj(W, 't2'), nil)
  -- apply time: a tomb cell is left out as soon as any of its tiles has a tomb zone
  T.ok(W.inbox('bp.cancel', {proj = 't1'}).ok)
  for k in pairs(zoned) do zoned[k] = nil end
  H.place(W, 't3', tomb_doc())
  zoned['17,10,100'] = {{type = 9}}
  H.floor(W, 10, 10, 100, 17, 10)
  H.runs(W, 1)
  H.build(W)
  H.runs(W, 3)
  local keys = {}
  for _, c in ipairs(H.qf_calls(W, 'zone')) do H.cells(c, function(x, y, zz, key) keys[#keys + 1] = x .. ':' .. key end) end
  table.sort(keys)
  T.eq(keys, {'10:T', '12:T', '14:T'}, 'the 2x1 tomb over a zoned tile is not drawn')
  dfhack.buildings, df.civzone_type = bld, czt
end)

T.test('FR-61: runner.coffins queues a tombs project: coffins (no orders), then 1x1 tomb zones; bad input refused', function()
  local W = fresh{tag = 'coffins'}
  H.floor(W, 40, 40, 100, 50, 50)
  local okc, ok, id = W.K.call('runner', 'coffins', {{44, 41, 100}, {40, 40, 100}, {42, 41, 100}}, 'care: 3 short', 3)
  T.ok(okc and ok, tostring(id))
  T.ok(type(id) == 'string' and id:match('^cof%d+$'), tostring(id))
  local d = W.K.persist.get('bp.' .. id)
  T.eq({d.tpl, d.class, d.site, #d.stages, d.stages[1].mode, d.stages[1].orders, d.stages[2].mode, d.params.n},
       {'tombs', 'living', 'care', 2, 'build', 0, 'zone', 3})
  T.eq(d.stages[1].chunks, {{pos = {40, 40, 100}, cells = {{0, 0, 0, 'n'}, {2, 1, 0, 'n'}, {4, 1, 0, 'n'}}}})
  T.eq(d.stages[2].chunks, {{pos = {40, 40, 100}, cells = {{0, 0, 0, 'T(1x1)'}, {2, 1, 0, 'T(1x1)'},
                                                         {4, 1, 0, 'T(1x1)'}}}})
  T.eq({H.proj(W, id).tpl, H.proj(W, id).prio}, {'tombs', 3})
  T.eq({W.K.call('runner', 'pending', 'tombs')}, {true, 1})
  H.runs(W, 1)
  T.eq(#H.qf_calls(W, 'build', 'orders'), 0, 'care orders the coffins in a usable material')
  T.eq(#H.qf_calls(W, 'build', 'run'), 1)
  local many = {}
  for i = 1, 61 do many[i] = {i, 1, 100} end
  T.eq({W.K.call('runner', 'coffins', many, 'x')}, {true, false, 'need 1-60 tiles'})
  T.eq({W.K.call('runner', 'coffins', nil, 'x')}, {true, false, 'need 1-60 tiles'})
  T.eq({W.K.call('runner', 'coffins', {{1, 2, 'x'}}, 'x')}, {true, false, 'bad tile 1'})
  T.eq({W.K.call('runner', 'coffins', {{1, 2, 3}, {1, 2, 3}}, 'x')}, {true, false, 'tile 2 twice'})
  T.eq({W.K.call('runner', 'coffins', {{1, 2, 3}}, 'x', 9)}, {true, false, 'prio must be 1..7'})
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

T.test('PLAN_EXHAUSTED fires again after each finished project (follow starts the next deliverable)', function()
  local ph = {{id = 'P0', title = 'a', approve = false,
               deliver = {{k = 'proj', tpl = 'dining'}, {k = 'proj', tpl = 'office'}}},
              {id = 'P1', title = 'b', approve = false, deliver = {}}}
  local W = fresh{tag = 'exh', phases = ph}
  H.runs(W, 2)
  T.eq(#W.find_events('PLAN_EXHAUSTED'), 1)
  H.place(W, 'd1', H.dig_doc(1, {tpl = 'dining', class = 'living', params = {}}))
  H.runs(W, 1); H.dig(W); H.runs(W, 2)
  T.eq(H.proj(W, 'd1').done, 1)
  T.eq(#W.find_events('PLAN_EXHAUSTED'), 2, 'dining done, office missing: once more')
  H.runs(W, 3)
  T.eq(#W.find_events('PLAN_EXHAUSTED'), 2, 'still once per finished project')
end)

T.test('phases: workshops pass through the manifest or a built workshop of the type (live L1b)', function()
  local ph = {{id = 'P0', title = 'a', approve = false, deliver = {{k = 'workshops', types = {'Masons', 'Jewelers'}}}},
              {id = 'P1', title = 'b', approve = false, deliver = {}}}
  local W = fresh{tag = 'wsph', phases = ph, persist = {manifest = {v = 2, workshops = {{type = 'Masons', pos = {1, 2, 3}}}}}}
  df.workshop_type = {Masons = 2, Jewelers = 4, [2] = 'Masons', [4] = 'Jewelers'}
  df.furnace_type = {}
  H.runs(W, 1)
  T.eq(W.state().phase, 'P0')
  local other = df.global.world.buildings.other
  other.WORKSHOP_ANY:insert('#', {type = 4, getBuildStage = function() return 0 end, getMaxBuildStage = function() return 1 end})
  H.runs(W, 1)
  T.eq(W.state().phase, 'P0', 'an unbuilt jeweler does not count')
  other.WORKSHOP_ANY:insert('#', {type = 4, getBuildStage = function() return 1 end, getMaxBuildStage = function() return 1 end})
  H.runs(W, 1)
  T.eq(W.state().phase, 'P1', 'a built jeweler (made by hand) counts')
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

T.test('live L6: food < 30 days (not in winter) -> one temporary gather zone near the fort, removed above 120', function()
  local function world(tag, ytick)
    local W = fresh{tag = tag, ytick = ytick, persist = {manifest = {v = 2, depot = {100, 100, 60}}}}
    W.fd = 20
    W.load{name = 'economy', every = {ticks = 1200}, state = function() return {stock = {food_d = W.fd}} end}
    for x = 80, 120 do for y = 80, 120 do W.map[x .. ',' .. y .. ',62'] = {c = '.', dig = ''} end end   -- surface
    for x = 95, 105 do for y = 95, 105 do W.map[x .. ',' .. y .. ',63'] = {c = '.', dig = ''} end end  -- a hilltop
    W.state()
    return W
  end
  local function zones(W)
    local r = {}
    for _, a in ipairs(W.find_acts('quickfort')) do
      local p = a.args[1]
      if p.mode == 'zone' then r[#r + 1] = {p.data[0][0][0], p.pos[1], p.pos[2], p.pos[3]} end
    end
    return r
  end
  local W = world('gath1', 0)
  H.runs(W, 1)
  T.eq(zones(W), {{'g{name=dfllm-gather}(28x28)', 86, 86, 62}}, 'one level (the hilltop has < 1/3 of the open tiles)')
  T.ok(logged(W, 'warn', 'gather zone 28x28'), 'logged')
  H.runs(W, 12)
  T.eq(#zones(W), 1, 'drawn once')
  T.eq(#W.find_acts('zone_remove'), 0)
  W.fd = 150
  W.state()
  H.runs(W, 7)
  local rm = W.find_acts('zone_remove')
  T.eq(#rm, 1)
  T.eq(rm[1].args[1], 'dfllm-gather', 'the zones screen remove, our zone only')
  T.eq(W.K.persist.get('m.runner').gather, nil)
  W.fd = 20
  W.state()
  H.runs(W, 7)
  T.eq(#zones(W), 2, 'food short again: drawn again')
  -- winter: no zone; two strong levels share the 800-tile cap
  local W2 = world('gath2', 3 * 100800 + 10)
  H.runs(W2, 2)
  T.eq(zones(W2), {}, 'winter: nothing to gather')
  local W3 = world('gath3', 100800)
  for x = 80, 120 do for y = 80, 120 do W3.map[x .. ',' .. y .. ',63'] = {c = 'T', dig = ''} end end
  H.runs(W3, 1)
  T.eq(zones(W3), {{'g{name=dfllm-gather}(20x20)', 90, 90, 63}, {'g{name=dfllm-gather}(20x20)', 90, 90, 62}},
       'two levels of 20x20 = 800 tiles')
  -- DECISIONS 10: the zone covers the citizens' walk group only. Open tiles snapshot.far puts on another group shrink the
  -- square (by 6 a step, not below 10); right at the anchor: no zone, said once
  local W4 = world('gath4', 0)
  W4.snap.far = function(K, x, y, z) return x >= 107 end
  H.runs(W4, 1)
  T.eq(zones(W4), {{'g{name=dfllm-gather}(10x10)', 95, 95, 62}}, 'shrunk from 28 until x 107 lies outside')
  T.ok(logged(W4, 'warn', 'shrunk from 28'), 'logged')
  local W5 = world('gath5', 0)
  W5.snap.far = function(K, x, y, z) return x >= 103 end
  H.runs(W5, 6)
  T.eq(zones(W5), {}, 'off the walk group right beside the anchor: no zone')
  T.ok(logged(W5, 'warn', 'lie off the citizens'), 'said')
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
  T.eq(#W.K.manifest().workshops, 8, 'carpenter, mason, craftsdwarf, still, kitchen, mechanics (live L1), butcher (live L6), ' ..
       'fishery (Run 11)')
end)

T.test('FR-22: every build chunk tells seal its cells before quickfort runs (the reach baseline and blame)', function()
  local W = fresh{tag = 'closing'}
  local calls = {}
  W.load{name = 'seal', every = {ticks = 100000}, closing = function(K, proj, tpl, class, ch)
    calls[#calls + 1] = {proj, tpl, class, ch.pos, #ch.cells, #W.qf}
    return 1
  end}
  H.place(W, 'c1', H.doc{class = 'defense'})
  H.settle(W); W.frame(1); H.settle(W)
  H.dig(W)
  H.runs(W, 2)
  T.eq(#calls, 1, 'one build chunk')
  T.eq({calls[1][1], calls[1][2], calls[1][3], calls[1][4], calls[1][5]}, {'c1', 'bedrooms', 'defense', {10, 10, 100}, 3})
  local runs = 0
  for i = 1, calls[1][6] do if W.qf[i].mode == 'build' and W.qf[i].command ~= 'orders' then runs = runs + 1 end end
  T.eq(runs, 0, 'before the build run')
end)

T.test('FR-56: runner.repair queues a defense project of the lost cells (min-corner chunks, no orders)', function()
  local W = fresh{tag = 'repair'}
  H.floor(W, 40, 40, 100, 45, 45)
  local okc, ok, id = W.K.call('runner', 'repair', {{44, 41, 100, 'Cw'}, {40, 40, 100, 'd'}, {42, 45, 100, 'gw(3x1)'}},
                               'perimeter after the siege')
  T.ok(okc and ok)
  T.ok(type(id) == 'string' and id:match('^rp%d+$'), tostring(id))
  local d = W.K.persist.get('bp.' .. id)
  T.eq({d.tpl, d.class, d.site, #d.stages, d.stages[1].mode, d.stages[1].orders, d.stages[1].defense},
       {'repair', 'defense', 'repair', 1, 'build', 0, 1})
  T.eq(d.stages[1].chunks, {{pos = {40, 40, 100}, cells = {{0, 0, 0, 'd'}, {4, 1, 0, 'Cw'}, {2, 5, 0, 'gw(3x1)'}}}})
  T.eq({H.proj(W, id).tpl, H.proj(W, id).prio}, {'repair', 2})
  H.runs(W, 1)
  local runs = H.qf_calls(W, 'build', 'run')
  T.eq(#runs, 1)
  T.eq(runs[1].pos, {40, 40, 100})
  local _, ok2, again = W.K.call('runner', 'repair', {{44, 41, 100, 'Cw'}}, 'x')
  T.ok(ok2 and again ~= id, 'a second repair gets its own id')
  T.eq({W.K.call('runner', 'repair', {}, 'x')}, {true, false, 'need 1-500 cells'})
  T.eq({W.K.call('runner', 'repair', {{1, 2, 'x', 'Cw'}}, 'x')}, {true, false, 'bad cell 1'})
end)

T.test('BUG-030 rebuild policy: a lost bridge\'s repair (opts.peace) is frozen in ALERT, RECOVERY, SIEGE and during ' ..
       'a lockdown and built only in quiet PEACE; a plain repair still runs in ALERT', function()
  -- old code: opts ignored, params {}: the bridge repair ran in ALERT and RECOVERY like every defense project
  local W = fresh{tag = 'repair_peace', mode = 'ALERT'}
  local lock
  W.load{name = 'reflex', every = {ticks = 100000}, holding = function() return lock end}
  H.floor(W, 40, 40, 100, 45, 45)
  local _, ok, id = W.K.call('runner', 'repair', {{42, 45, 100, 'gw(3x1)'}}, 'bridge O1 after the fight', {peace = true})
  T.ok(ok)
  T.eq(W.K.persist.get('bp.' .. id).params, {peace = 1})
  local _, ok2, wall = W.K.call('runner', 'repair', {{44, 41, 100, 'Cw'}}, 'perimeter after the siege')
  T.ok(ok2)
  T.eq(W.K.persist.get('bp.' .. wall).params, {})
  H.runs(W, 2)
  local function built(pos)
    for _, c in ipairs(H.qf_calls(W, 'build', 'run')) do if c.pos[1] == pos then return true end end
    return false
  end
  T.ok(built(44) and not built(42), 'ALERT: the wall, not the bridge')
  T.eq(row(W, id)[4], 'frozen')
  for _, m in ipairs({'RECOVERY', 'SIEGE'}) do
    W.set_mode(m)
    H.runs(W, 2)
    T.ok(not built(42), m)
  end
  W.set_mode('PEACE')
  lock = 'arrival:siege'
  H.runs(W, 2)
  T.ok(not built(42), 'a lockdown in PEACE')
  T.eq(row(W, id)[4], 'frozen')
  T.eq(H.proj(W, id).blocked, '', 'frozen time is no stall')
  lock = nil
  H.runs(W, 1)
  T.ok(built(42), 'quiet PEACE')
end)

T.done()
