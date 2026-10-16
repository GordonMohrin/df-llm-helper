-- seal's refuge after the first real siege (docs/v2/POSTMORTEM-run9-test-siege-2026-10-15.md: 50 -> 1, the civ alert
-- held everybody in the halls the goblins walked into): BUG-018 a burrow an opening reaches without a door is refused
-- (REFUGE_FAIL names the entrance), BUG-019 the BREACH level (no drink/food/bed counts), FR-67 the dead end behind the
-- deepest stair painted as Tiefe+ and used last, no separated burrow -> no confinement (flee); the bed rule (a share of
-- the citizens, configurable, the formula in the text); BUG-021 a CUTOFF is confirmed on walk groups read in one go.
-- k_mock (strict) + tests/lua/seal_world.lua (DF-like walk groups, renumbered on every regroup).
local T = require('testlib')
local SW = require('seal_world')

local function evs(W, t) return W.find_events(t) end
local function inspect(W, what, key)
  local r = W.inbox('inspect', {what = what, key = key})
  T.ok(r.ok, r.msg)
  return r.data, r.msg
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l end end
end

---------------------------------------------------------------- the fort
-- surface z 10: a field x0-40 y0-30 (outside, it reaches the map edge) with a down stair at 20,10. Fort z 9: the hall
-- x5-15 y5-15 (Kern+: the citizens, 2 beds, drink, food), a corridor y10 x16-19 to the up stair 20,10 (the entrance;
-- opts.door: a door at 19,10 right behind it). opts.shaft (default): a down stair at 6,6 in the hall, a shaft z6-8 and a
-- room x5-8 y5-8 on z5: the dead end behind the stair (19 tiles)
local Z = 9
local function fort(opts)
  opts = opts or {}
  local W = SW.new{persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}}}}
  SW.fill(W, Z + 1, 0, 0, 40, 30, ',')
  SW.draw(W, Z + 1, {'>'}, 20, 10, {outside = true})
  SW.fill(W, Z, 0, 0, 40, 30, '#')
  SW.fill(W, Z, 5, 5, 15, 15, '.')
  SW.fill(W, Z, 16, 10, 19, 10, '.')
  SW.draw(W, Z, {'<'}, 20, 10)
  if opts.door then SW.draw(W, Z, {'+'}, 19, 10) end
  SW.draw(W, Z, {'bb'}, 12, 12)
  if opts.bed3 then SW.draw(W, Z, {'b'}, 17, 10) end           -- a third bed in the corridor (outside Kern+)
  if opts.shaft ~= false then
    SW.draw(W, Z, {'>'}, 6, 6)
    for z = Z - 3, Z - 1 do
      SW.fill(W, z, 0, 0, 40, 30, '#')
      SW.draw(W, z, {'X'}, 6, 6)
    end
    SW.fill(W, Z - 4, 0, 0, 40, 30, '#')
    SW.fill(W, Z - 4, 5, 5, 8, 8, '.')
    SW.draw(W, Z - 4, {'<'}, 6, 6)
  end
  SW.regroup(W)
  local cits = {}
  for i = 1, opts.citizens or 3 do cits[i] = {i, 8 + i % 6, 9 + i // 6, Z} end
  SW.citizens(W, cits)
  SW.item(W, 'DRINK', 9, 13, Z, 20)
  SW.item(W, 'PLANT', 9, 14, Z, 20)
  W.burrow('Kern+', {5, 5, Z, 15, 15, Z})
  if opts.cfg then W.K.cfg.reflex = {v = 2, refuge = opts.cfg} end
  package.loaded['dfllm.seal'] = nil
  local M = require('dfllm.seal')
  W.load(M)
  W.run(opts.settle or 2400, {skip = 9})
  return W, M
end

---------------------------------------------------------------- BUG-018
T.test('BUG-018: an entrance without a door leads into Kern+: Kern+ is refused although it has its counts, ' ..
       'REFUGE_FAIL names the entrance; FR-67: the dead end the kernel painted as Tiefe+ is chosen', function()
  local W = fort()
  local d, msg = inspect(W, 'refuge')
  local k = d.burrows['Kern+']
  -- old code: "Kern+ ok:1" (the counts only)
  T.eq({k.counts, k.sep, k.ok, k.open, k.steps}, {1, 0, 0, {'20,10,9 stair_up'}, 5}, k.why)
  T.ok(k.why:find('open to 1 entrance 20,10,9 stair_up (5 steps)', 1, true), k.why)
  -- FR-67: painted at boot (burrows screen), the shaft and the room below the hall, z5-8
  local t = d.burrows['Tiefe+']
  T.eq({t.exists, t.tiles, t.sep, t.reach, t.steps}, {1, 19, 0, 1, 15})
  T.eq({d.dead.n, d.dead.bottom, d.dead.mouth, d.dead.z}, {19, {5, 5, Z - 4}, {6, 6, Z}, {Z - 4, Z - 1}})
  T.ok(logged(W, 'seal: Tiefe+ painted with 19 tiles: the dead end behind the stair at 6,6,9 (z5-8)'), 'kern.log')
  T.eq(d.choice.SIEGE, {want = 'Kern+', burrow = 'Tiefe+', level = 'DEAD'})
  T.eq(d.choice.LOCKDOWN, {want = 'Kern+', burrow = 'Tiefe+', level = 'DEAD'})
  local ok, pick, note, short, flee = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  T.eq({ok, pick, short, flee}, {true, 'Tiefe+', 'REFUGE_FAIL Kern+, dead end Tiefe+', false})
  T.ok(note:find('Tiefe+ is the dead end: no drink, food or bed counts for 7 days', 1, true), note)
  local f = evs(W, 'REFUGE_FAIL')
  T.eq(#f, 1)
  T.eq({f[1].d.burrow, f[1].d.fallback, f[1].d.level, f[1].d.flee, f[1].d.open, f[1].d.mode},
       {'Kern+', 'Tiefe+', 'DEAD', 0, {'20,10,9 stair_up'}, 'SIEGE'})
  T.ok(f[1].msg:find('alert burrow Kern+ refused (Kern+: open to 1 entrance 20,10,9 stair_up (5 steps)): ' ..
       'confining to Tiefe+', 1, true), f[1].msg)
  T.ok(msg:find('alert PEACE: Tiefe+, 19 tiles, 0/3 inside', 1, true), msg)
  T.eq(W.hidden_wg, 0, 'no walk group of a hidden tile was read')
end)

T.test('BUG-018: a door right behind the entrance closes it (a porch exposes nothing): Kern+ holds', function()
  local W = fort{door = true}
  local d = inspect(W, 'refuge')
  T.eq({d.burrows['Kern+'].ok, d.burrows['Kern+'].sep, d.burrows['Tiefe+'].sep}, {1, 1, 1})
  T.eq(d.choice.SIEGE, {want = 'Kern+', burrow = 'Kern+', level = 'SIEGE'})
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')), 'Kern+')
  T.eq(#evs(W, 'REFUGE_FAIL'), 0)
  -- the door is gone (destroyed): the next check with a BFS finds the hall open again
  W.dyn[SW.key(19, 10, Z)] = nil
  SW.draw(W, Z, {'.'}, 19, 10)
  SW.regroup(W)
  inspect(W, 'entrances', 'refresh')
  d = inspect(W, 'refuge')
  T.eq({d.burrows['Kern+'].ok, d.burrows['Kern+'].sep}, {0, 0})
end)

T.test('BUG-018: a visible hostile standing in a burrow refuses it in every mode', function()
  local W = fort{door = true}
  W.set_census('h', {tick = W.K.now().tick, vis = 1, armed = 1, inside = 1, list = {{id = 300, x = 10, y = 12, z = Z}}})
  local d = inspect(W, 'refuge')
  T.eq(d.burrows['Kern+'].ok, 0)
  T.eq(d.choice.SIEGE, {want = 'Kern+', burrow = 'Tiefe+', level = 'BREACH'}, 'the separated refuge, without counts')
end)

---------------------------------------------------------------- BUG-019
T.test('BUG-019: in BREACH (a goblin inside Kern+) the dead end Tiefe+ is taken without drink, food or beds ' ..
       '(old: refused, "confining to Kern+")', function()
  local W = fort{door = true}
  local d = inspect(W, 'refuge')
  local t = d.burrows['Tiefe+']
  T.eq({t.counts, t.breach, t.sep}, {0, 1, 1}, t.why)
  T.ok(t.why:find('drink 0<3, food 0<3, beds 0<1 (25% of 3 citizens)', 1, true), t.why)
  W.set_census('h', {tick = W.K.now().tick, vis = 1, armed = 1, inside = 1, list = {{id = 300, x = 10, y = 12, z = Z}}})
  W.set_mode('BREACH')
  local ok, pick, note = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')
  T.eq({ok, pick, note}, {true, 'Tiefe+', nil})
  T.eq(#evs(W, 'REFUGE_FAIL'), 0)
  T.eq(W.state().alert, {want = 'Tiefe+', burrow = 'Tiefe+', tiles = 19, inside = 0, ok = 1, why = ''})
end)

T.test('BUG-019 live (Run 10 y419: "REFUGE_FAIL Tiefe+: 63 tiles<109, beds 8<28 -> confining to Kern+"): 30 ' ..
       'citizens, a 19-tile dead end, an entrance into Kern+: BREACH and SIEGE take Tiefe+, never Kern+', function()
  local W = fort{citizens = 30}
  local d = inspect(W, 'refuge')
  T.ok(d.burrows['Tiefe+'].why:find('19 tiles<30', 1, true), d.burrows['Tiefe+'].why)
  T.ok(d.hint:find('Tiefe+ holds without counts only in a breach (7 days): for a siege it needs 19 tiles<30', 1, true),
       d.hint)
  T.eq(d.choice.SIEGE, {want = 'Kern+', burrow = 'Tiefe+', level = 'DEAD'})
  W.set_census('h', {tick = W.K.now().tick, vis = 1, armed = 1, inside = 1, list = {{id = 300, x = 10, y = 12, z = Z}}})
  W.set_mode('BREACH')
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')), 'Tiefe+')
  for _, e in ipairs(evs(W, 'REFUGE_FAIL')) do T.ok(e.d.fallback ~= 'Kern+', e.msg) end
end)

---------------------------------------------------------------- FR-67: no dead end
T.test('FR-67: an entrance into Kern+ and no dead end: no confinement, the citizens flee; REFUGE_FAIL says so', function()
  local W = fort{shaft = false}
  local d = inspect(W, 'refuge')
  T.eq(d.dead.why, 'deepest level: citizens or beds')
  T.eq(d.burrows['Tiefe+'].exists, 0)
  T.eq(d.choice.SIEGE, {want = 'Kern+', burrow = '', flee = 1})
  local ok, pick, note, short, flee = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  T.eq({ok, pick == nil, short, flee}, {true, true, 'REFUGE_FAIL Kern+, citizens flee', true})
  T.ok(note:find('; no separated burrow: civ alert off, citizens flee on their own', 1, true), note)
  local f = evs(W, 'REFUGE_FAIL')
  T.eq(#f, 1)
  T.eq({f[1].d.burrow, f[1].d.fallback, f[1].d.flee, f[1].d.open}, {'Kern+', '', 1, {'20,10,9 stair_up'}})
  T.ok(f[1].msg:find('no confinement; no separated burrow: civ alert off, citizens flee on their own', 1, true),
       f[1].msg)
  local st = W.state().alert
  T.eq({st.burrow, st.ok}, {'', 0})
  T.ok(st.why:find('^flee: Kern%+: open to 1 entrance'), st.why)
end)

---------------------------------------------------------------- refuge beds
T.test('refuge beds: beds >= ceil(citizens x 25%); a shortfall only ranks (the burrow with enough beds first), the ' ..
       'formula is in REFUGE_FAIL; refuge.bed_pct in config/reflex.json', function()
  -- 9 citizens need ceil(9 x 25%) = 3 beds; Kern+ holds 2, the interior burrow (a third bed in the corridor) 3
  local W = fort{door = true, citizens = 9, bed3 = true}
  local d = inspect(W, 'refuge')
  T.eq(d.need.beds, 3)
  T.eq(d.need.beds_rule, 'ceil(9 citizens x 25%)')
  T.ok(d.burrows['Kern+'].why:find('beds 2<3 (25% of 9 citizens)', 1, true), d.burrows['Kern+'].why)
  T.eq({d.burrows['Innen+'].ok, d.burrows['Innen+'].beds}, {1, 3})
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')), 'Innen+')
  local f = evs(W, 'REFUGE_FAIL')
  T.ok(#f == 1 and f[1].msg:find('alert burrow Kern+ refused (Kern+: beds 2<3 (25% of 9 citizens)): confining to ' ..
       'Innen+', 1, true), f[1] and f[1].msg)
  -- no burrow has enough beds: Kern+ is still taken (old code: both refused, "no confinement, the whole fort")
  local W2 = fort{door = true, citizens = 9}
  T.eq(select(2, W2.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')), 'Kern+')
  T.eq(#evs(W2, 'REFUGE_FAIL'), 0)
  T.eq(inspect(W2, 'refuge').choice.SIEGE, {want = 'Kern+', burrow = 'Kern+', level = 'SOFT'})
  -- bed_pct 0: no bed count
  local W3 = fort{door = true, citizens = 9, cfg = {bed_pct = 0}}
  local d3 = inspect(W3, 'refuge')
  T.eq({d3.need.beds, d3.burrows['Kern+'].ok, d3.burrows['Kern+'].why}, {0, 1, ''})
end)

---------------------------------------------------------------- BUG-021
T.test('BUG-021: walk group ids renumbered while an audit runs: no CUTOFF ("cause not found" before)', function()
  local W, M = fort{door = true}
  M.CFG.work = 12                                  -- the audit takes many frames
  W.K.call('seal', 'closing', 'p1', 'walls', 'infra', {pos = {30, 20, Z}, cells = {{0, 0, 0, 'Cw'}}})
  local busy
  for _ = 1, 40 do
    W.frame(9)
    busy = inspect(W, 'reach').busy
    if busy[1] == 'audit' or busy[2] == 'audit' then break end
  end
  T.ok(busy[1] == 'audit' or busy[2] == 'audit', 'the audit runs: ' .. table.concat(busy, ','))
  SW.regroup(W)                                    -- DF renumbers every group; the map is the same
  W.run(3000, {skip = 9})
  T.eq(#evs(W, 'CUTOFF'), 0)
  local d = inspect(W, 'reach')
  T.ok((d.runs.cut_unconfirmed or 0) >= 1, require('dfllm.util.json').encode(d.runs))
  T.eq(d.cut, {food = 0, drink = 0, bed = 0})
  T.ok(logged(W, 'seal: CUTOFF not confirmed'), 'kern.log')
end)

T.test('BUG-021: a real cut is confirmed and says which citizen and which stock lie on which group', function()
  -- a wall line across the hall at x 13: citizens, stock and beds stay west of it (no CUTOFF) ...
  local W = fort{door = true}
  for y = 5, 15 do SW.build_wall(W, 13, y, Z) end
  W.run(1200, {skip = 9})
  T.eq(#evs(W, 'CUTOFF'), 0, 'the stock is on the citizens\' side')
  -- ... at y 11: the citizens (y 9) north of it, the drink (9,13), the food (9,14) and the beds (12,12) south
  local W2 = fort{door = true}
  for x = 5, 15 do SW.build_wall(W2, x, 11, Z) end
  W2.run(1200, {skip = 9})
  local ev = evs(W2, 'CUTOFF')
  T.eq(#ev, 1)
  local e = ev[1]
  T.ok(e.msg:find('3 citizens cut off from ', 1, true) and e.msg:find('; citizen 1 at 9,9,9 on group ', 1, true),
       e.msg)
  T.eq({e.d.unit, e.d.upos}, {1, {9, 9, Z}})
  T.ok(e.d.at ~= nil and e.d.at[2] > 11 and e.d.agrp ~= nil and e.d.agrp ~= e.d.grp, require('dfllm.util.json').encode(e.d))
  T.ok(e.msg:find(string.format(' at %d,%d,%d on group %d', e.d.at[1], e.d.at[2], e.d.at[3], e.d.agrp), 1, true), e.msg)
end)

T.done()
