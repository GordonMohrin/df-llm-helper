-- Run 11 (Kilrudrabed site98, live after kernel a6c33a9): the explore c1a14676 stood at 'dig 98 % stalled' while its
-- shaft 136,73 z137-127 opened into a cavern lake (1146 water tiles on z127). Earlier it had ended BREACH_STOP damp;
-- after the reload it showed as stalled, and the daily recheck looked only at projects stopped as damp/water/cavern, so
-- no CAVERN_PLUG came and the shaft stayed open. Now every explore shaft (m.runner xs) is looked at once a day and at
-- the first run after a boot, in any state (running, stalled, blocked, stopped, done, cancelled while its shaft still
-- stands): a cavern lake or an open cavern beside it plugs the shaft at once, and each look logs one line.
-- k_mock + runner_world (fake quickfort, snapshot.tile/liquids).
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world(opts)
  W.load(runner)
  return W
end
local function cav_open(W) return (select(2, W.K.call('runner', 'cavern_open'))) end
local function checks(W)
  local r = {}
  for _, l in ipairs(W.logs) do if l.msg:find('^cavern check: ') then r[#r + 1] = l.msg end end
  return r
end
local function plug_proj(W)
  for _, P in ipairs(W.K.persist.get('projects').list) do if P.tpl == 'plug' then return P end end
end

-- an explore as bp/mine.py emits it (rot 0): the shaft at (ax, ay + 1) from z (j) down `depth` levels (u), side tunnels
-- of `arm` tiles W/E/S every `every` levels and at the bottom; one chunk per level
local function explore_doc(ax, ay, az, depth, arm, every)
  local tun = {}
  for k = every, depth, every do tun[-k] = true end
  tun[-depth] = true
  local chunks = {}
  for w = 0, -depth, -1 do
    local key = w == 0 and 'j' or (w == -depth and 'u' or 'i')
    local cells, x0 = {{0, 0, 0, key}}, ax
    if tun[w] and arm > 0 then
      x0 = ax - arm
      cells = {{0, 0, 0, string.format('d(%dx1)', arm)}, {arm, 0, 0, key}, {arm + 1, 0, 0, string.format('d(%dx1)', arm)},
               {arm, 1, 0, string.format('d(1x%d)', arm)}}
    end
    chunks[#chunks + 1] = {pos = {x0, ay + 1, az + w}, cells = cells}
  end
  return {v = 2, tpl = 'explore', site = 'S1', class = 'infra',
          params = {depth = depth, arm = arm, every = every, avoid = ''}, anchor = {ax, ay, az}, rot = 0,
          stages = {{label = 'dig', mode = 'dig', orders = 0, defense = 0, chunks = chunks}}, manifest = {v = 2},
          materials = {}}
end

-- the miners dug the column (ax, ay + 1) from z0 down to z1 (stairs, no designation left there)
local function dug(W, x, y, z0, z1)
  for z = z0, z1, -1 do
    local t = W.tile(x, y, z)
    t.c, t.dig = z == z0 and '>' or 'X', ''
  end
end

-- revealed water (7/7) on the box, cavern tiles (feature_global) unless cav == false
local function pool(W, x0, y0, x1, y1, z0, z1, cav)
  for z = z0, z1 do
    for y = y0, y1 do
      for x = x0, x1 do
        local t = W.tile(x, y, z)
        t.c, t.flow, t.cav = '~', 7, cav ~= false
      end
    end
  end
end

T.test('the live c1a14676: stalled at 98 % after a reload, its shaft into a cavern lake -> stopped and plugged at once',
       function()
  local W = fresh{tag = 'live98', map_size = {16, 16, 160}}   -- z up to 159: the live levels
  H.place(W, 'c1a14676', explore_doc(136, 72, 137, 10, 6, 3))   -- the shaft 136,73 z137-127
  H.runs(W, 1)
  H.dig(W)                                        -- the miners dug it all ...
  local t = W.tile(142, 73, 127)
  t.c, t.dig = '#', 'd'                           -- ... but the far end of the bottom's east arm
  H.runs(W, 16)                                   -- a week without progress
  local P = H.proj(W, 'c1a14676')
  T.eq({P.blocked, P.pct, P.done}, {'stalled', 98, 0}, 'dig 98 % stalled')
  -- the reload: a kernel before the shaft check (a6c33a9) wrote no shaft record, the breach record is gone
  local persist = H.reloaded(W)
  persist['m.runner'].xs, persist['m.runner'].br = nil, nil
  local W2 = H.world{tag = 'live98b', persist = persist, map_size = {16, 16, 160}}
  W2.map = W.map
  W2.load(runner)
  pool(W2, 125, 50, 160, 72, 126, 127)            -- the cavern lake north of the shaft bottom, revealed
  H.runs(W2, 1)                                   -- the first run after the boot looks at every shaft
  P = H.proj(W2, 'c1a14676')
  T.eq(P.blocked, 'breach:cavern_lake')
  local ev = W2.find_events('BREACH_STOP')
  T.eq(#ev, 1)
  T.eq(ev[1].d, {proj = 'c1a14676', why = 'cavern_lake', src = 'check', state = 'stalled', n = 576,
                 pos = {136, 73, 127}})
  T.eq(ev[1].msg, 'c1a14676: cavern lake (check, was stalled: 576 water tiles in reach), digging stopped')
  local cp = W2.find_events('CAVERN_PLUG')
  T.eq(#cp, 1)
  local d = cp[1].d
  T.eq({d.phase, d.proj, d.why, d.state, d.shaft, d.z1, d.walls, d.n},
       {'queued', 'c1a14676', 'cavern_lake', 'stalled', {136, 73, 137}, 127, {'136,73,136', '136,73,137'}, 576})
  T.ok(cp[1].msg:find('c1a14676 (stalled; shaft check): the shaft 136,73 z137-127 opens into a cavern lake at '
                      .. '136,73,127; plug ' .. d.plug, 1, true), cp[1].msg)
  T.eq(plug_proj(W2).id, d.plug)
  T.eq(select(3, W2.K.call('runner', 'cavern_open')), {{136, 73, 137, 127}}, 'readiness: R0 caverns')
  T.eq(W2.tile(142, 73, 127).dig, '', 'the pending arm tile is undone (nobody digs on into the lake)')
  local lines = checks(W2)
  T.eq(lines[1], 'cavern check: c1a14676 136,73 z137-127 stalled: cavern lake (576 water tiles) -> plug ' .. d.plug
                 .. ' queued')
  local xs = W2.K.persist.get('m.runner').xs['c1a14676']
  T.eq({xs.x, xs.y, xs.top, xs.low}, {136, 73, 137, 127}, 'the shaft record, made from the project document')
  H.runs(W2, 6)
  T.eq({#W2.find_events('CAVERN_PLUG'), #W2.find_events('BREACH_STOP')}, {1, 1}, 'once')
  T.eq(checks(W2)[2], 'cavern check: c1a14676 136,73 z137-127 breach:cavern_lake: plug ' .. d.plug .. ' under way')
  -- another reload that lost the plug record (m.runner is written later than the project list): the same plug again
  persist = H.reloaded(W2)
  persist['m.runner'].cav = {}
  local W3 = H.world{tag = 'live98c', persist = persist, map_size = {16, 16, 160}}
  W3.map = W.map
  W3.load(runner)
  H.runs(W3, 1)
  local again = W3.find_events('CAVERN_PLUG')
  T.eq({#again, again[1].d.phase, again[1].d.plug, again[1].d.state}, {1, 'queued', d.plug, 'breach:cavern_lake'})
  local n = 0
  for _, Q in ipairs(W3.K.persist.get('projects').list) do if Q.tpl == 'plug' then n = n + 1 end end
  T.eq(n, 1, 'no second plug project for the shaft')
  T.eq(W3.K.persist.get('m.runner').cav['c1a14676'].plug, d.plug)
end)

T.test('a running explore (no report: the lake showed while its lower levels were dug) is stopped within a day',
       function()
  local W = fresh{tag = 'xrun'}
  H.place(W, 'e1', explore_doc(40, 40, 100, 8, 2, 4))
  H.runs(W, 1)
  dug(W, 40, 41, 100, 95)                         -- z94-92 still designated
  pool(W, 41, 30, 60, 52, 94, 95)
  H.runs(W, 3)
  T.eq(H.proj(W, 'e1').blocked, 'breach:cavern_lake')
  local ev = W.find_events('BREACH_STOP')[1]
  T.eq({ev.d.src, ev.d.state, ev.d.why, ev.d.n, ev.d.pos}, {'check', 'running', 'cavern_lake', 552, {40, 41, 95}})
  local cp = W.find_events('CAVERN_PLUG')[1]
  T.eq({cp.d.phase, cp.d.state, cp.d.z1}, {'queued', 'running', 95})
  T.eq({W.tile(40, 41, 94).dig, W.tile(40, 41, 92).dig}, {'', ''}, 'the explore designations below are undone')
  T.eq(cav_open(W), 1)
end)

T.test('a done explore and a cancelled one: their shafts still stand; a lake beside the bottom plugs them', function()
  local W = fresh{tag = 'xdone'}
  runner.CFG.active = 4
  H.place(W, 'e1', explore_doc(40, 40, 100, 8, 2, 4))
  H.place(W, 'e2', explore_doc(120, 40, 100, 8, 2, 4))
  H.runs(W, 1)
  H.dig(W)
  H.runs(W, 2)
  T.eq(H.proj(W, 'e1').done, 1)
  T.eq(W.K.persist.get('m.runner').xs.e1.fin, 'done', 'the record outlives the document')
  T.eq(W.K.persist.get('bp.e1'), nil)
  -- e2: designated, dug to z95 by hand, then cancelled without undo (the shaft stands)
  H.place(W, 'e3', explore_doc(80, 40, 100, 8, 2, 4))
  H.runs(W, 1)
  dug(W, 80, 41, 100, 95)
  local r = W.inbox('bp.cancel', {proj = 'e3'}, {id = 'k1'})
  T.ok(r.ok, r.msg)
  T.eq(H.proj(W, 'e3'), nil)
  T.eq(W.K.persist.get('m.runner').xs.e3.fin, 'cancelled')
  local n0 = #checks(W)
  H.runs(W, 3)
  T.eq(#W.find_events('CAVERN_PLUG'), 0, 'dry shafts: nothing')
  local seen3 = false                             -- (BUG-033: each shaft daily; e3 keeps its own day phase)
  for i = n0 + 1, #checks(W) do seen3 = seen3 or checks(W)[i]:find('e3 80,41 z100-95 cancelled: no cavern', 1, true) end
  T.ok(seen3, table.concat(checks(W), ' || '))
  pool(W, 30, 30, 50, 40, 91, 92)                 -- north of e1's bottom (z92)
  pool(W, 81, 30, 100, 52, 94, 95)                -- east of e3's bottom (z95)
  H.runs(W, 3)
  local by = {}
  for _, e in ipairs(W.find_events('CAVERN_PLUG')) do by[e.d.proj] = e.d end
  T.eq({by.e1.phase, by.e1.state, by.e1.z1, by.e1.n}, {'queued', 'done', 92, 462})
  T.eq({by.e3.phase, by.e3.state, by.e3.z1, by.e3.walls}, {'queued', 'cancelled', 95, {'80,41,99', '80,41,100'}})
  T.eq(by.e2, nil, 'e2 is dry')
  T.eq(#W.find_events('BREACH_STOP'), 0, 'nothing is digging there: no stop')
  T.eq(cav_open(W), 2)
end)

T.test('the log line names every shaft looked at: no cavern, closed, not dug; daily; the first one after a boot',
       function()
  local W = fresh{tag = 'xlog'}
  H.runs(W, 1)
  T.eq(checks(W), {'cavern check: no explore shaft and no stopped dig to look at'})
  runner.CFG.active = 4
  H.place(W, 'e1', explore_doc(40, 40, 100, 8, 2, 4))
  H.place(W, 'e2', explore_doc(80, 40, 100, 8, 2, 4))
  H.place(W, 'e3', explore_doc(120, 40, 100, 8, 2, 4))
  H.runs(W, 1)
  dug(W, 40, 41, 100, 97)
  dug(W, 80, 41, 100, 99)
  W.tile(80, 41, 100).c = 'C'                     -- the player walled e2's top by hand
  W.tile(41, 41, 97).c, W.tile(41, 41, 97).flow = 'w', 2   -- a little seepage beside e1's bottom
  local n0 = #checks(W)
  for _ = 1, 3 do H.runs(W, 1) end
  local lines = checks(W)
  T.eq(#lines, n0 + 1, 'one line a day')
  T.ok(lines[#lines]:find('e1 40,41 z100-97 running: no cavern (1 water tiles in reach)', 1, true), lines[#lines])
  T.ok(lines[#lines]:find('e2 80,41 z100-99 running: closed (a constructed wall on its top)', 1, true), lines[#lines])
  -- BUG-039: a look that did not change since the last one is counted, not named again (e3 was named at its first look)
  T.ok(lines[#lines]:find('; 1 unchanged', 1, true), lines[#lines])
  T.ok(table.concat(lines, ' || '):find('e3 120,41 z100-92 running: not dug yet', 1, true), table.concat(lines, ' || '))
  T.eq(#W.find_events('CAVERN_PLUG'), 0)
  -- a reload: the first run after the boot looks at once
  local persist = H.reloaded(W)
  local W2 = H.world{tag = 'xlog2', persist = persist}
  W2.map = W.map
  W2.load(runner)
  H.runs(W2, 1)
  T.eq(#checks(W2), 1)
  T.ok(checks(W2)[1]:find('^cavern check: e1 40,41 z100%-97 running'), checks(W2)[1])
end)

T.test('a damp-stopped explore keeps its stop cadence; one stopped as warm is plugged without hiding the magma', function()
  local W = fresh{tag = 'xwarm'}
  H.place(W, 'e1', explore_doc(40, 40, 100, 8, 2, 4))
  H.runs(W, 1)
  dug(W, 40, 41, 100, 95)
  W.event('REPORT', {type = 'DIG_CANCEL_WARM', text = 'warm', pos = {x = 40, y = 41, z = 95}})
  W.frame(1)
  T.eq(H.proj(W, 'e1').blocked, 'breach:warm')
  pool(W, 41, 30, 60, 52, 94, 95)
  H.runs(W, 3)
  T.eq(H.proj(W, 'e1').blocked, 'breach:warm', 'never lowered or renamed')
  local cp = W.find_events('CAVERN_PLUG')
  T.eq({#cp, cp[1].d.phase, cp[1].d.state}, {1, 'queued', 'breach:warm'})
  T.eq(#W.find_events('BREACH_STOP'), 1)
end)

local function stages_of(W, id)
  local l = {}
  for _, st in ipairs(W.K.persist.get('bp.' .. id).stages) do l[#l + 1] = st.label end
  return l
end
local function building_at(W, x, y, z) return W.bld_at[x .. ',' .. y .. ',' .. z] end

T.test('a hatch on the shaft top is no plug: the wall below it closes the shaft (done), the hatch stays', function()
  local W = fresh{tag = 'xhatch'}
  runner.CFG.plug_wait = 4 * 1200
  H.place(W, 'e1', explore_doc(40, 40, 100, 8, 2, 4))
  H.runs(W, 1)
  dug(W, 40, 41, 100, 95)
  H.hatch(W, 40, 41, 100, '>')                    -- the player hatched the top (seal at=40,41,100)
  pool(W, 41, 30, 60, 52, 94, 95)
  H.runs(W, 3)
  local cp = W.find_events('CAVERN_PLUG')
  T.eq({#cp, cp[1].d.phase}, {1, 'queued'})
  local id = cp[1].d.plug
  T.eq(stages_of(W, id), {'p1.dig', 'p1.wall', 'p0.free', 'p0.dig', 'p0.wall'})
  T.ok(checks(W)[#checks(W)]:find('-> plug ' .. id .. ' queued (the hatch on its top is no plug)', 1, true),
       checks(W)[#checks(W)])
  T.eq(W.K.manifest().caverns, {{40, 41, 95}}, 'the breach level for the explore ranking')
  H.runs(W, 1)
  T.eq(W.tile(40, 41, 99).dig, 'h', 'the lower stair is channelled first (reached through the hatch)')
  H.dig(W)
  H.runs(W, 2)
  H.build(W)
  H.runs(W, 3)
  T.eq(W.tile(40, 41, 99).c, 'C')
  cp = W.find_events('CAVERN_PLUG')
  T.eq(cp[#cp].d.phase, 'done')
  T.ok(cp[#cp].msg:find('constructed wall on 40,41,99 below the Hatch on 40,41,100', 1, true), cp[#cp].msg)
  T.eq(H.proj(W, id).done, 1, 'the plug ends: the shaft is closed by a constructed wall')
  T.ok(building_at(W, 40, 41, 100) ~= nil, 'the hatch stays')
  T.eq(cav_open(W), 0)
end)

T.test('the wall below the hatch given up: the hatch is removed in PEACE only, then the top channelled and walled',
       function()
  local W = fresh{tag = 'xhatch2'}
  H.place(W, 'e1', explore_doc(40, 40, 100, 8, 2, 4))
  H.runs(W, 1)
  dug(W, 40, 41, 100, 95)
  H.hatch(W, 40, 41, 100, '>')
  pool(W, 41, 30, 60, 52, 94, 95)
  H.runs(W, 3)
  local id = W.find_events('CAVERN_PLUG')[1].d.plug
  W.set_mode('ALERT')
  H.runs(W, 8)                                    -- nobody channels the lower stair: given up after a day
  T.eq(H.proj(W, id).stage, 2, 'at p0.free')
  T.ok(building_at(W, 40, 41, 100) ~= nil, 'not removed outside PEACE')
  W.set_mode('PEACE')
  H.runs(W, 2)
  T.eq({building_at(W, 40, 41, 100), W.tile(40, 41, 100).c}, {nil, '>'}, 'the hatch removed (quickfort undo)')
  H.runs(W, 1)
  T.eq(W.tile(40, 41, 100).dig, 'h')
  H.dig(W)
  H.runs(W, 2)
  H.build(W)
  H.runs(W, 2)
  local cp = W.find_events('CAVERN_PLUG')
  T.eq({cp[#cp].d.phase, W.tile(40, 41, 100).c, cav_open(W)}, {'done', 'C', 0})
  -- a hatch DF never removes: failed after plug_wait (R0 stays), by hand
  local W2 = fresh{tag = 'xhatch3'}
  H.place(W2, 'e1', explore_doc(40, 40, 100, 8, 2, 4))
  H.runs(W2, 1)
  dug(W2, 40, 41, 100, 95)
  H.hatch(W2, 40, 41, 100, '>')
  pool(W2, 41, 30, 60, 52, 94, 95)
  H.runs(W2, 3)
  W2.qf_fail_cmd = 'undo'
  H.runs(W2, 10)
  local f = W2.find_events('CAVERN_PLUG')
  T.eq({f[#f].d.phase, f[#f].d.hint}, {'failed', 'the Hatch was not removed within 1 day'})
  T.ok(f[#f].msg:find('remove the hatch or door, channel the stair, wall it', 1, true), f[#f].msg)
  T.eq(cav_open(W2), 1)
end)

T.test('an explore cancelled before shaft records existed (c1a14676 under a6c33a9) is found in the bp folder', function()
  local W = fresh{tag = 'xgone'}
  local doc = explore_doc(40, 40, 100, 8, 2, 4)
  H.place(W, 'c1a14676', doc)
  H.runs(W, 1)
  dug(W, 40, 41, 100, 95)
  T.ok(W.inbox('bp.cancel', {proj = 'c1a14676'}, {id = 'k1'}).ok)
  local persist = H.reloaded(W)
  persist['m.runner'].xs = nil                    -- the older kernel kept no shaft record
  local W2 = H.world{tag = 'xgone2', persist = persist}
  W2.map = W.map
  H.put(W2, 'c1a14676', doc)                      -- its bp file stays in <save>/bp
  H.put(W2, 'r1', H.dig_doc(1, {x = 80}))         -- another template's file: read, no record
  W2.load(runner)
  H.hatch(W2, 40, 41, 100, '>')
  pool(W2, 41, 30, 60, 52, 94, 95)
  H.runs(W2, 1)
  local cp = W2.find_events('CAVERN_PLUG')
  T.eq({#cp, cp[1].d.phase, cp[1].d.state, cp[1].d.z1}, {1, 'queued', 'gone', 95})
  T.ok(cp[1].msg:find('c1a14676 (gone; shaft check): the shaft 40,41 z100-95', 1, true), cp[1].msg)
  T.eq(W2.K.persist.get('m.runner').xs.r1, nil)
  T.eq(W2.K.persist.get('m.runner').xs.c1a14676.fin, 'gone')
  T.eq(#W2.find_events('BREACH_STOP'), 0)
  -- the cavern level survives a reload that lost it from the manifest (rebuilt from the plug record)
  persist = H.reloaded(W2)
  persist.manifest.caverns, persist['m.runner'].cz = nil, nil
  local W3 = H.world{tag = 'xgone3', persist = persist}
  W3.map = W.map
  W3.load(runner)
  T.eq(W3.K.manifest().caverns, {{40, 41, 95}})
end)

T.done()
