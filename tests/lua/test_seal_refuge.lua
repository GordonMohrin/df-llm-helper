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
  if opts.well then SW.draw(W, Z - 4, {'W'}, 7, 7) end          -- BUG-040: a well in the dead end (a dry cistern's)
  for _, m in ipairs(opts.mods or {}) do W.load(m) end
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
  T.eq(W.state().alert, {want = 'Tiefe+', burrow = 'Tiefe+', tiles = 19, inside = 0, ok = 1, why = '',
                         ref = {ex = 1, sep = 1, beds = 0, need = 1, box = {5, 5, 5, 8, 8, 8}, wd = -1,   -- BUG-040
                                dr = 0, dn = 3, st = 0, tr = 1}})                                           -- FR-69, BUG-049
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
  T.eq({f[1].d.burrow, f[1].d.fallback, f[1].d.flee, f[1].d.open, f[1].d.fix},
       {'Kern+', '', 1, {'20,10,9 stair_up'}, '20,10,9 stair_up'})
  -- BUG-031: what closes the entrance comes first (a hatch on the stair: seal at=...), then why nobody is confined
  T.ok(f[1].msg:find('no confinement; close it: seal at=20,10,9 stair_up; no separated burrow: civ alert off, ' ..
       'citizens flee on their own', 1, true), f[1].msg)
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

T.test('Run 10 (Tiefe+ open to the entrance, beds 8<27): the state carries the refuge for dfllm plan check: exists, ' ..
       'separated, beds and the beds wanted (refuge.bed_pct)', function()
  -- old code: no alert.ref
  local W = fort{citizens = 9}                       -- the dead end Tiefe+, reached by the doorless entrance
  -- BUG-040: plus where it lies (box) and its nearest accepted water (wd -1: none known)
  -- FR-69: its drink, the drink it wants, its drink store's tiles
  T.eq(W.state().alert.ref, {ex = 1, sep = 0, beds = 0, need = 3, box = {5, 5, 5, 8, 8, 8}, wd = -1, dr = 0, dn = 9,
                             st = 0, tr = 0, trw = 'exposed: open to 1 entrance 20,10,9 stai'})   -- BUG-049
  local W2 = fort{door = true, citizens = 9}
  T.eq(W2.state().alert.ref, {ex = 1, sep = 1, beds = 0, need = 3, box = {5, 5, 5, 8, 8, 8}, wd = -1, dr = 0, dn = 9,
                              st = 0, tr = 1})
  local W3 = fort{shaft = false}                     -- no dead end: no refuge burrow at all
  T.eq(W3.state().alert.ref, {ex = 0, sep = -1, beds = 0, need = 1})
  local W4 = fort{door = true, citizens = 9, cfg = {bed_pct = 50}}
  T.eq(W4.state().alert.ref.need, 5)
  local C = require('dfllm.util.contract')
  local bad = {}
  for _, e in ipairs(C.check_state({alert = W.state().alert})) do
    if e:find('^%$%.alert') then bad[#bad + 1] = e end
  end
  T.eq(bad, {}, 'the alert block is contract-shaped')
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

---------------------------------------------------------------- BUG-031 (Run 11)
-- Run 11 (Kilrudrabed y429, pop 54): "REFUGE_FAIL Kern+: open to 1 entrance 127,121,143 Door (62 steps)" at every
-- invasion, "no confinement, citizens flee", although the fortcore refuge stood. The fort: z9 the hall x5-15 y5-15
-- (Kern+), a 3-wide corridor y9-11 x16-25 to the open sky at x26-40 (the field reaches the map edge); opts.doors: the
-- built doors on the mouth (x25), opts.planned: a door there nobody built; the shaft at 6,6 down to the dead end on z5
-- (painted as Tiefe+), or (opts.refuge) the stocked refuge room x10-14 y4-8 z5 behind a door at 7,6 (Tiefe+, with its
-- own drink, food and a bed); opts.innen: an Innen+ painted over the hall long ago
local function mouth_fort(opts)
  opts = opts or {}
  local burrows = {['Kern+'] = {role = 'kern'}}
  if opts.refuge then burrows['Tiefe+'] = {role = 'refuge'} end
  local W = SW.new{persist = {manifest = {v = 2, burrows = burrows}}}
  SW.fill(W, Z, 0, 0, 40, 30, '#')
  SW.fill(W, Z, 5, 5, 15, 15, '.')
  SW.fill(W, Z, 16, 9, 25, 11, '.')
  SW.fill(W, Z, 26, 0, 40, 30, ',')
  for _, y in ipairs(opts.doors or {}) do SW.draw(W, Z, {'+'}, 25, y) end
  if opts.planned then
    SW.draw(W, Z, {'+'}, 25, opts.planned)
    W.dyn[SW.key(25, opts.planned, Z)]._stage = 0                  -- placed, not built
  end
  SW.draw(W, Z, {'bb'}, 12, 12)
  SW.draw(W, Z, {'>'}, 6, 6)
  for z = Z - 3, Z - 1 do
    SW.fill(W, z, 0, 0, 40, 30, '#')
    SW.draw(W, z, {'X'}, 6, 6)
  end
  SW.fill(W, Z - 4, 0, 0, 40, 30, '#')
  if opts.refuge then
    SW.draw(W, Z - 4, {'<+..'}, 6, 6)
    SW.fill(W, Z - 4, 10, 4, 14, 8, '.')
    SW.draw(W, Z - 4, {'bb'}, 10, 8)
  else
    SW.fill(W, Z - 4, 5, 5, 8, 8, '.')
    SW.draw(W, Z - 4, {'<'}, 6, 6)
  end
  SW.regroup(W)
  local cits = {}
  for i = 1, opts.citizens or 3 do cits[i] = {i, 8 + i % 6, 9 + i // 6, Z} end
  SW.citizens(W, cits)
  SW.item(W, 'DRINK', 9, 13, Z, 20)
  SW.item(W, 'PLANT', 9, 14, Z, 20)
  if opts.refuge then
    SW.item(W, 'DRINK', 12, 5, Z - 4, 20)
    SW.item(W, 'PLANT', 13, 5, Z - 4, 20)
    W.burrow('Tiefe+', {10, 4, Z - 4, 14, 8, Z - 4})
  end
  W.burrow('Kern+', {5, 5, Z, 15, 15, Z})
  if opts.innen then W.burrow('Innen+', {5, 5, Z, 15, 15, Z}) end
  package.loaded['dfllm.seal'] = nil
  local M = require('dfllm.seal')
  W.load(M)
  W.run(opts.settle or 2400, {skip = 9})
  return W, M
end

T.test('BUG-031: a door on one tile of a 3-wide entrance leaves the other two open: REFUGE_FAIL names them (not the ' ..
       'door), with the seal that closes them; the lockdown and SIEGE_UNREADY list them as ways in without a door; ' ..
       'doors on them separate Kern+', function()
  -- old code: "open to 1 entrance 25,9,9 Door (10 steps)", open {'25,9,9 Door'}, entrance_doors open {} (the opening
  -- has a door): nothing ever named or closed the two doorless tiles
  local W = mouth_fort{doors = {9}}
  local d = inspect(W, 'refuge')
  local k = d.burrows['Kern+']
  T.eq({k.sep, k.ok, k.open, k.fix}, {0, 0, {'25,10,9 floor', '25,11,9 floor'}, '25,10,9 floor;25,11,9 floor'})
  T.ok(k.why:find('open to 1 entrance 25,10,9 floor +1 beside door 25,9,9 (10 steps)', 1, true), k.why)
  T.ok(d.hint:find('close the entrances into Kern+: dfllm cmd bp.place \'{"tpl":"seal","site":"S1","p":{"at":' ..
       '"25,10,9 floor;25,11,9 floor"}}\'', 1, true), d.hint)
  local _, x = W.K.call('seal', 'entrance_doors')
  T.eq(#x.doors, 1)
  T.eq(x.open, {{pos = {25, 10, Z}, kind = 'floor', door = 1}, {pos = {25, 11, Z}, kind = 'floor', door = 1}})
  local _, pick, note = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  T.eq(pick, 'Tiefe+')
  local f = evs(W, 'REFUGE_FAIL')
  T.eq(#f, 1)
  T.eq({f[1].d.open, f[1].d.fix}, {{'25,10,9 floor', '25,11,9 floor'}, '25,10,9 floor;25,11,9 floor'})
  T.ok(f[1].msg:find('confining to Tiefe+; close it: seal at=25,10,9 floor;25,11,9 floor', 1, true), f[1].msg)
  -- the seal is built (doors on both tiles): the next check finds Kern+ separated
  SW.draw(W, Z, {'+'}, 25, 10)
  SW.draw(W, Z, {'+'}, 25, 11)
  SW.regroup(W)
  inspect(W, 'entrances', 'refresh')
  d = inspect(W, 'refuge', 'refresh')
  T.eq({d.burrows['Kern+'].sep, d.burrows['Kern+'].ok, d.burrows['Kern+'].fix}, {1, 1, nil})
  T.eq(d.choice.SIEGE, {want = 'Kern+', burrow = 'Kern+', level = 'SIEGE'})
  T.eq(select(2, W.K.call('seal', 'entrance_doors')).open, {})
end)

T.test('BUG-031: a door the seal template placed and nobody built is no barrier: the entrance is named "(door not ' ..
       'built)" and takes no second seal piece', function()
  -- old code: "open to 1 entrance 25,10,9 Door" (the planned door read like a built one)
  local W = mouth_fort{doors = {9, 11}, planned = 10}
  local k = inspect(W, 'refuge').burrows['Kern+']
  T.eq({k.sep, k.open, k.fix}, {0, {'25,10,9 floor'}, nil})
  T.ok(k.why:find('open to 1 entrance 25,10,9 floor (door not built) beside door 25,9,9', 1, true), k.why)
  local _, x = W.K.call('seal', 'entrance_doors')
  T.eq(x.open, {{pos = {25, 10, Z}, kind = 'floor', door = 1, note = 'door not built'}})
end)

T.test('BUG-031: a lockdown in PEACE took the dead end and opened the breach days; they end with the lockdown, so ' ..
       'the next invasion takes the dead end again (old: "no confinement, citizens flee" at every invasion)', function()
  local W = fort()
  local _, pick = W.K.call('seal', 'alert_burrow', 'PEACE', 'Kern+', true)      -- an arrival or predator lockdown
  T.eq(pick, 'Tiefe+')
  T.ok(inspect(W, 'refuge').bsince ~= nil, 'the breach days run')
  W.run(1200, {skip = 9})                                                         -- the lockdown is over
  T.eq(inspect(W, 'refuge').bsince, nil)
  T.ok(logged(W, 'seal: episode over: breach days and thirst marks reset'), 'kern.log')
  W.run(12000, {skip = 9})                                                        -- ten days later: an invasion
  W.set_mode('SIEGE')
  local _, pick2, note, short, flee = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  T.eq({pick2, short, flee}, {'Tiefe+', 'REFUGE_FAIL Kern+, dead end Tiefe+', false}, note)
  -- within one episode the days still run out: then the refusal says why the refuge is no way out either
  W.run(9600, {skip = 9})
  local _, pick3, note3, _, flee3 = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  T.eq({pick3, flee3}, {nil, true})
  T.ok(note3:find('no separated burrow (Tiefe+: the 7 days without counts are spent', 1, true), note3)
end)

T.test('BUG-031: a refuge with its own drink, food and beds behind a door holds a siege at the SIEGE level when an ' ..
       'entrance reaches Kern+ (old: the BREACH level for 7 days, then the citizens fled)', function()
  local W = mouth_fort{refuge = true, innen = true}
  local d = inspect(W, 'refuge')
  T.eq({d.burrows['Kern+'].sep, d.burrows['Innen+'].sep, d.burrows['Tiefe+'].sep, d.burrows['Tiefe+'].counts},
       {0, 0, 1, 1})
  T.eq(d.choice.SIEGE, {want = 'Kern+', burrow = 'Tiefe+', level = 'SIEGE'})
  W.set_mode('SIEGE')
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')), 'Tiefe+')
  W.run(9600, {skip = 9})                                                        -- eight days of siege
  local _, pick, _, _, flee = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  T.eq({pick, flee}, {'Tiefe+', false})
  T.eq(inspect(W, 'refuge').bsince, nil, 'no breach days for a stocked refuge')
end)

T.test('BUG-031 (b): citizens confined to the dead end went thirsty there (siege tells seal): every level refuses ' ..
       'it while it holds no drink, the alert goes off even in a lockdown; the mark ends with the episode', function()
  local W = fort()
  W.set_mode('SIEGE')
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')), 'Tiefe+')
  local _, marked, why, fresh = W.K.call('seal', 'dry', 'Kern+', {drink = true}, 2)
  T.eq({marked, why}, {false, 'Kern+ holds drink 20, food 20 (audit tick ' .. inspect(W, 'refuge').tick .. ')'})
  _, marked, why, fresh = W.K.call('seal', 'dry', 'Tiefe+', {drink = true}, 2)
  T.eq({marked, why, fresh}, {true, 'Tiefe+ holds no drink', true})
  T.ok(logged(W, 'seal: Tiefe+ marked dry: 2 confined citizens without drink there'), 'kern.log')
  local d = inspect(W, 'refuge')
  T.eq({d.burrows['Tiefe+'].dry, d.dry['Tiefe+'].drink}, {'no drink for 2 thirsty citizens', true})
  local _, pick, note, short, flee = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  T.eq({pick, short, flee}, {nil, 'REFUGE_FAIL Kern+, citizens flee', true})
  T.ok(note:find('no separated burrow (Tiefe+: no drink for 2 thirsty citizens): civ alert off', 1, true), note)
  local f = evs(W, 'REFUGE_FAIL')
  T.eq({f[#f].d.dry, f[#f].d.flee}, {1, 1})
  -- a lockdown without danger: the dry burrow alone turns the alert off (BUG-011's "never off" yields)
  local _, pick2, note2, short2, flee2 = W.K.call('seal', 'alert_burrow', 'PEACE', 'Tiefe+', true)
  T.eq({pick2, flee2}, {nil, true}, note2)
  W.set_mode('PEACE')
  W.run(1200, {skip = 9})
  T.eq(inspect(W, 'refuge').dry, nil, 'the episode is over')
  W.set_mode('SIEGE')
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')), 'Tiefe+')
end)

---------------------------------------------------------------- Run 11, siege 8 (y441)
T.test('Run 11 (siege 8: Tiefe+ had no drink): the deep defense (siege asks at the BREACH level in SIEGE) keeps the ' ..
       'citizens in Kern+, separated and with its drink, instead of the dry dead end (old: Tiefe+ at the BREACH level ' ..
       'for 7 days); a refuge with its drink is taken (WET) and not bound to the window', function()
  local W = fort{door = true}
  W.set_mode('SIEGE')
  local d = inspect(W, 'refuge')
  T.eq({d.burrows['Tiefe+'].sep, d.burrows['Tiefe+'].drink, d.burrows['Kern+'].ok}, {1, 0, 1})
  local _, pick, note, short = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')
  T.eq({pick, short}, {'Kern+', 'REFUGE_FAIL Tiefe+'}, note)
  T.ok(note:find('REFUGE_FAIL Tiefe+: no drink (drink 0<3, no well)', 1, true), note)
  local f = evs(W, 'REFUGE_FAIL')
  T.ok(#f >= 1 and f[#f].d.burrow == 'Tiefe+' and f[#f].d.fallback == 'Kern+' and f[#f].d.level == 'SIEGE',
       f[#f] and f[#f].msg)
  T.eq(inspect(W, 'refuge').bsince, nil, 'no breach days')
  T.eq(select(2, W.K.call('seal', 'refuge_drink')),
       {name = 'Tiefe+', exists = true, drink = 0, need = 3, wells = 0, wet = false, box = {5, 5, 5, 8, 8, 8}},
       'what readiness reads (refuge_dry; BUG-040: where it lies)')
  -- drink in the dead end (a barrel carried down): the refuge with its drink, without the 7-day window
  SW.item(W, 'DRINK', 6, 7, Z - 4, 5)
  W.run(2400, {skip = 9})
  T.eq(select(2, W.K.call('seal', 'refuge_drink')).wet, true)
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')), 'Tiefe+')
  W.run(9600, {skip = 9})
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')), 'Tiefe+', 'eight days later: still')
  T.eq(inspect(W, 'refuge').bsince, nil, 'its drink: no breach days')
end)

T.test('Run 11 (siege 8: the alert switched between Tiefe+ and Kern+ during the fight): in SIEGE the dead end Tiefe+ ' ..
       'holds the citizens while Kern+ is open; a door closes the entrance (Kern+ separated, its drink): the alert stays ' ..
       'on Tiefe+ (old: back to Kern+, through the fort); a hostile in Tiefe+: the switch, REFUGE_SWITCH breached; ' ..
       'outside a fight the free pick holds', function()
  local W = fort()
  W.set_mode('SIEGE')
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')), 'Tiefe+', 'the dead end')
  SW.draw(W, Z, {'+'}, 19, 10)
  SW.regroup(W)
  inspect(W, 'entrances', 'refresh')
  W.run(1200, {skip = 9})
  T.eq(inspect(W, 'refuge').burrows['Kern+'].sep, 1, 'the door separates Kern+')
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')), 'Kern+', 'the free pick')
  local _, kept, note, short = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+', false, 'Tiefe+')
  T.eq({kept, short}, {'Tiefe+', 'Tiefe+ kept (SIEGE)'}, note)
  T.ok(note:find('Tiefe+ kept during the SIEGE: a switch to Kern+ would walk the citizens through the danger', 1, true),
       note)
  T.ok(logged(W, 'seal: the civ alert stays on Tiefe+ during the SIEGE: a switch to Kern+ would walk the citizens ' ..
       'through the danger, and Tiefe+ is neither breached nor open'), 'kern.log')
  T.eq(#evs(W, 'REFUGE_SWITCH'), 0)
  T.eq(W.state().alert.burrow, 'Tiefe+')
  -- a goblin in the dead end: Tiefe+ breached, the citizens go to Kern+
  W.set_census('h', {tick = W.K.now().tick, vis = 1, armed = 1, inside = 0, list = {{id = 300, x = 6, y = 7, z = Z - 4}}})
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+', false, 'Tiefe+')), 'Kern+')
  local sw = evs(W, 'REFUGE_SWITCH')
  T.eq({#sw, sw[1].d.from, sw[1].d.to, sw[1].d.why, sw[1].d.mode}, {1, 'Tiefe+', 'Kern+', 'breached', 'SIEGE'})
  T.ok(sw[1].msg:find('alert burrow Tiefe+ -> Kern+ during the SIEGE: Tiefe+ breached (hostile inside at 6,7,5)', 1, true),
       sw[1].msg)
  W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+', false, 'Tiefe+')
  T.eq(#evs(W, 'REFUGE_SWITCH'), 1, 'once per switch')
  -- a lockdown in PEACE is no fight: the free pick
  W.set_census('h', {tick = W.K.now().tick, vis = 0, armed = 0, inside = 0, list = {}})
  W.set_mode('PEACE')
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'PEACE', 'Kern+', true, 'Tiefe+')), 'Kern+')
  T.eq(#evs(W, 'REFUGE_SWITCH'), 1)
end)


---------------------------------------------------------------- BUG-040 (Run 11, y453)
T.test('BUG-040 (Run 11 y453: Tiefe+ drink 0, wells 1, the alert on the dry Tiefe+): refuge_drink and inspect say ' ..
       'how many of its wells the water module calls wet (BUG-073: the alert\'s rating counts the wet ones too), where ' ..
       'the refuge lies and how far its nearest ' ..
       'tile is from the nearest accepted water (state alert.ref box/wd/ws)', function()
  local wf
  wf = SW.fake('water', {
    wet_wells = function(K, name) if name == 'Tiefe+' then return wf.wet, 1 end end,
    state = function(K)
      return {water = {patients = 0, thirst_max = 0, hosp_ok = 0, refuge_ok = wf.wet, buckets_free = 0, hosp = 0,
                       src = {{12, 6, 9}}}}
    end})
  wf.wet = 0
  local W = fort{door = true, well = true, mods = {wf}}
  W.state()                                          -- the water state seal reads (K.view): one accepted source
  inspect(W, 'refuge', 'refresh')
  W.run(1200, {skip = 9})
  local d = inspect(W, 'refuge')
  local t = d.burrows['Tiefe+']
  T.eq({t.wells, t.wwet}, {1, 0})
  local rd = select(2, W.K.call('seal', 'refuge_drink'))
  -- BUG-073: the rating follows readiness (a dry well is no drink); it was {1, 0, true}, every built well counted
  T.eq({rd.wells, rd.wwet, rd.wet}, {1, 0, false}, 'old code: no wwet')
  T.eq(rd.box, {5, 5, 5, 8, 8, 8})
  T.eq({rd.near.d, rd.near.src}, {4, {12, 6, 9}})
  T.eq({t.box, t.near.d}, {{5, 5, 5, 8, 8, 8}, 4})
  local ref = W.state().alert.ref
  T.eq({ref.box, ref.wd, ref.ws}, {{5, 5, 5, 8, 8, 8}, 4, {12, 6, 9}})
  -- its well holds water
  wf.wet = 1
  W.state()
  inspect(W, 'refuge', 'refresh')
  W.run(1200, {skip = 9})
  T.eq(select(2, W.K.call('seal', 'refuge_drink')).wwet, 1)
  -- no water module (an older kernel, water backed off): not known
  local W2 = fort{door = true, well = true}
  rd = select(2, W2.K.call('seal', 'refuge_drink'))
  T.eq({rd.wells, rd.wwet, rd.wet, rd.near}, {1, nil, true, nil}, 'water silent: the built wells count, as before')
end)

---------------------------------------------------------------- BUG-073 (DECISIONS 6)
T.test('BUG-073 (DECISIONS 6; Run 11 y453: Tiefe+ with one dry well): the alert rates the refuge by its WET wells, as ' ..
       'readiness does: a dry well frees nobody from the breach_days window (old: wet = true, Tiefe+ taken at the WET ' ..
       'level for ever while readiness said refuge_dry), a wet one does; REFUGE_FAIL names the dry well', function()
  local wf
  wf = SW.fake('water', {
    wet_wells = function(K, name) if name == 'Tiefe+' then return wf.wet, 1 end end,
    state = function(K)
      return {water = {patients = 0, thirst_max = 0, hosp_ok = 0, refuge_ok = wf.wet, buckets_free = 0, hosp = 0, src = {}}}
    end})
  wf.wet = 0
  local W = fort{door = true, well = true, mods = {wf}}
  W.state()
  W.set_mode('SIEGE')
  inspect(W, 'refuge', 'refresh')
  W.run(1200, {skip = 9})
  local rd = select(2, W.K.call('seal', 'refuge_drink'))
  T.eq({rd.wells, rd.wwet, rd.wet}, {1, 0, false}, 'a dry well is no drink')
  local _, pick, note, short = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')
  T.eq({pick, short}, {'Kern+', 'REFUGE_FAIL Tiefe+'}, note)
  T.ok(note:find('REFUGE_FAIL Tiefe+: no drink (drink 0<3, 1 well, none wet)', 1, true), note)
  T.eq(inspect(W, 'refuge').bsince, nil, 'no breach days: the refuge is not taken')
  -- water calls the well wet: the refuge has its drink again
  wf.wet = 1
  W.state()
  inspect(W, 'refuge', 'refresh')
  W.run(1200, {skip = 9})
  rd = select(2, W.K.call('seal', 'refuge_drink'))
  T.eq({rd.wells, rd.wwet, rd.wet}, {1, 1, true})
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')), 'Tiefe+', 'a wet well is a drink')
  -- the window (an entrance open into Kern+, the BUG-031 episode): the days without counts end after breach_days; a
  -- dry well does not free the refuge from them (old: rwet kept Tiefe+ for ever), a wet one does
  local function episode(wet)
    local wf2
    wf2 = SW.fake('water', {
      wet_wells = function(K, name) if name == 'Tiefe+' then return wf2.wet, 1 end end,
      state = function(K)
        return {water = {patients = 0, thirst_max = 0, hosp_ok = 0, refuge_ok = wf2.wet, buckets_free = 0, hosp = 0, src = {}}}
      end})
    wf2.wet = wet
    local W2 = fort{well = true, mods = {wf2}}
    W2.state()
    T.eq(select(2, W2.K.call('seal', 'alert_burrow', 'PEACE', 'Kern+', true)), 'Tiefe+', 'a lockdown opens the window')
    W2.run(1200, {skip = 9})
    W2.run(12000, {skip = 9})
    W2.set_mode('SIEGE')
    T.eq(select(2, W2.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')), 'Tiefe+', 'a new episode, a new window')
    W2.run(9600, {skip = 9})                                                      -- eight days of siege
    local _, pick, note, _, flee = W2.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
    return pick, flee, note
  end
  local pick3, flee3, note3 = episode(0)
  T.eq({pick3, flee3}, {nil, true}, 'a dry well: the days are spent, the citizens flee on their own')
  T.ok(note3:find('no separated burrow (Tiefe+: the 7 days without counts are spent', 1, true), note3)
  local pick4, flee4 = episode(1)
  T.eq({pick4, flee4}, {'Tiefe+', false}, 'a wet well: the refuge holds past the days')
end)

---------------------------------------------------------------- FR-69 (Run 11, y477)
T.test('FR-69 (Run 11 y477: Tiefe+ drink 0 while 1199 of 1493 drinks lay in one Kern+ stockpile): the refuge drink ' ..
       'store (a stockpile dfllm-drink on Tiefe+ tiles, bp refuge_drink): refuge_drink and inspect refuge count the ' ..
       'barrels on it (store: piles, tiles, drink), the state carries alert.ref dr/dn/st; drink >= citizens on it: the ' ..
       'refuge is wet; a pile of that name in Kern+ is no store', function()
  local W = fort{door = true}
  -- the dead end Tiefe+ (x5-8 y5-8 z5 and the shaft): the store pile on 5-7,8 z5; a pile of the same name in Kern+
  local store = {id = 901, name = 'dfllm-drink', x1 = 5, y1 = 8, x2 = 7, y2 = 8, z = Z - 4, centerx = 6, centery = 8}
  local other = {id = 902, name = 'dfllm-drink', x1 = 12, y1 = 6, x2 = 13, y2 = 6, z = Z, centerx = 12, centery = 6}
  df.global.world.buildings.other.STOCKPILE:insert('#', store)
  df.global.world.buildings.other.STOCKPILE:insert('#', other)
  inspect(W, 'refuge', 'refresh')
  W.run(1200, {skip = 9})
  local rd = select(2, W.K.call('seal', 'refuge_drink'))
  T.eq({rd.drink, rd.need, rd.wet, rd.store}, {0, 3, false, {n = 1, tiles = 3, drink = 0, at = {5, 8, Z - 4}}},
       'old code: no store')
  T.eq(inspect(W, 'refuge').burrows['Tiefe+'].store, {n = 1, tiles = 3, drink = 0, at = {5, 8, Z - 4}})
  T.eq(inspect(W, 'refuge').burrows['Kern+'].store, nil)
  local ref = W.state().alert.ref
  T.eq({ref.dr, ref.dn, ref.st}, {0, 3, 3})
  -- two barrels of drink hauled onto the store (2 + 2 drinks: the citizens' 3)
  for _, x in ipairs({5, 6}) do
    local b = SW.container(W, 'BARREL', x, 8, Z - 4)
    SW.store(SW.item(W, 'DRINK', x, 8, Z - 4, 2), b)
  end
  inspect(W, 'refuge', 'refresh')                    -- the census and audit again (PEACE: else within 3-7 days)
  W.run(1200, {skip = 9})
  rd = select(2, W.K.call('seal', 'refuge_drink'))
  T.eq({rd.drink, rd.wet, rd.store.drink}, {4, true, 4})
  ref = W.state().alert.ref
  T.eq({ref.dr, ref.st}, {4, 3})
  T.eq(inspect(W, 'refuge').burrows['Tiefe+'].drink, 4)
end)

---------------------------------------------------------------- BUG-049 (Run 13 y525: the refuge was occupied)
-- Run 13 (Wheelsblows y525): B1, B2 and O1 lost and never rebuilt, the refuge Tiefe+ reachable for the enemy; at the
-- alarm the citizens found it occupied (REFUGE_FAIL "hostile inside"). The kernel trusts the refuge only while its
-- separation is fresh (audited), nothing in its way is open (the stair-head hatch stands) and no hostile is inside;
-- every hostile inside is reported with its position; sense counts the ones inside even behind a full hostile list.
local function refuge_h(W, list, extra)
  local h = {tick = W.K.now().tick, vis = #list, armed = 1, inside = 0, list = list}
  for k, v in pairs(extra or {}) do h[k] = v end
  W.set_census('h', h)
end

T.test('BUG-049: REFUGE_FAIL "hostile inside" names where (x,y,z, how many) and the choice moves at once: the refuge ' ..
       'with a goblin in it is refused in BREACH, Kern+ is taken (old: no position)', function()
  local W = fort{door = true}
  -- a goblin in the dead end behind the stair (room x5-8 y5-8 z5), another in the shaft
  refuge_h(W, {{id = 300, x = 7, y = 6, z = Z - 4}, {id = 301, x = 6, y = 6, z = Z - 2}})
  W.set_mode('BREACH')
  local ok, pick, note, short = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')
  T.eq({ok, pick}, {true, 'Kern+'})
  local f = evs(W, 'REFUGE_FAIL')
  T.eq(#f, 1)
  T.eq({f[1].d.burrow, f[1].d.fallback, f[1].d.hostile, f[1].d.at}, {'Tiefe+', 'Kern+', 2, {7, 6, Z - 4}})
  T.ok(f[1].msg:find('hostile inside at 7,6,5 (2 hostiles)', 1, true), f[1].msg)
  T.ok(note:find('hostile inside at 7,6,5', 1, true), note)
  -- a goblin in Kern+ instead: the refuge is the BREACH pick again at once
  refuge_h(W, {{id = 300, x = 10, y = 12, z = Z}}, {inside = 1})
  ok, pick = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')
  T.eq(pick, 'Tiefe+')
  -- the citizens are confined in it when a goblin gets in: they leave at once (REFUGE_SWITCH breached)
  refuge_h(W, {{id = 300, x = 7, y = 6, z = Z - 4}})
  ok, pick = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+', false, 'Tiefe+')
  T.eq(pick, 'Kern+')
  local sw = evs(W, 'REFUGE_SWITCH')
  T.ok(#sw == 1 and sw[1].d.why == 'breached' and sw[1].msg:find('hostile inside at 7,6,5', 1, true), T.show(sw))
end)

T.test('BUG-049: a hostile that walks about inside the refuge is no news for REFUGE_FAIL (cadence: one per episode, ' ..
       'the position is not a cause token)', function()
  local W = fort{door = true}
  W.set_mode('BREACH')
  for _, p in ipairs({{7, 6}, {7, 7}, {8, 7}, {8, 8}}) do
    refuge_h(W, {{id = 300, x = p[1], y = p[2], z = Z - 4}})
    W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')
    W.run(100, {skip = 9})
  end
  T.eq(#evs(W, 'REFUGE_FAIL'), 1, 'one REFUGE_FAIL for the whole stay')
  T.eq({evs(W, 'REFUGE_FAIL')[1].d.hostile, evs(W, 'REFUGE_FAIL')[1].d.at}, {1, {7, 6, Z - 4}}, 'with the first place')
  refuge_h(W, {{id = 300, x = 8, y = 8, z = Z - 4}, {id = 301, x = 7, y = 6, z = Z - 4}})
  W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')
  T.eq(#evs(W, 'REFUGE_FAIL'), 1, 'a second hostile is no new cause either')
end)

T.test('BUG-049: census.h.rin (sense counts the hostiles inside the refuge) refuses it even when the 40-entry list ' ..
       'does not hold them (a siege of 58 goblins: the list keeps the nearest to O1)', function()
  local W = fort{door = true}
  refuge_h(W, {}, {rin = 2, vis = 2})                  -- 2 inside the refuge, none of them in the list
  W.set_mode('BREACH')
  local ok, pick = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')
  T.eq(pick, 'Kern+')
  local f = evs(W, 'REFUGE_FAIL')
  T.eq(#f, 1)
  T.eq({f[1].d.hostile, f[1].d.at}, {2, nil})
  T.ok(f[1].msg:find('hostile inside (2 hostiles)', 1, true), f[1].msg)
end)

T.test('BUG-049: the refuge is trusted only while its separation is fresh, the hatch at its stair head stands and ' ..
       'nobody is inside: state alert.ref.tr / trw, seal.refuge_trust, inspect refuge', function()
  -- the manifest's refuge: the civilians' stair comes down from 6,6,9 to the dead end at z5 (Tiefe+); its head is
  -- 6,6,6, the tile above the refuge level (Z-4 = 5)
  local W, M = fort{door = true}
  local man = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
               refuge = {anchor = {5, 5, Z - 4}, burrow = 'Tiefe+'}, stairs = {civ = {{6, 6, Z - 4, Z}}}}
  W.K.persist.set('manifest', man)
  inspect(W, 'refuge', 'refresh')
  W.run(1200, {skip = 9})
  local ok, tr = W.K.call('seal', 'refuge_trust')
  T.ok(ok and tr.ok == false, T.show(tr))
  T.eq(tr.why, {'no hatch at 6,6,6'})
  T.eq(tr.hatch, {pos = {6, 6, Z - 3}, state = 'missing'})
  local ref = W.state().alert.ref
  T.eq({ref.tr, ref.trw}, {0, 'no hatch at 6,6,6'})
  T.ok(inspect(W, 'refuge').trust.why[1] == 'no hatch at 6,6,6')
  -- the hatch is built on the stair head: trusted
  local hatch = SW.building(W, 'DOOR', 'Hatch', 6, 6, Z - 3)
  W.dyn[SW.key(6, 6, Z - 3)] = hatch
  W.tiles[SW.key(6, 6, Z - 3)].occ.building = df.tile_building_occ.Dynamic
  inspect(W, 'refuge', 'refresh')
  W.run(1200, {skip = 9})
  ok, tr = W.K.call('seal', 'refuge_trust')
  T.ok(tr.ok, T.show(tr))
  T.eq(tr.hatch.state, 'ok')
  T.eq({W.state().alert.ref.tr, W.state().alert.ref.trw}, {1, nil})
  -- a hostile inside: not trusted, and where
  refuge_h(W, {{id = 300, x = 7, y = 6, z = Z - 4}})
  ok, tr = W.K.call('seal', 'refuge_trust')
  T.eq({tr.ok, tr.why, tr.hostile}, {false, {'hostile inside at 7,6,5'}, {n = 1, at = {7, 6, Z - 4}}})
  refuge_h(W, {})
  -- the separation answer is older than CFG.sep_fresh: stale (seal's own job stopped running)
  M.CFG.sep_fresh = 600
  W.run(1800, {skip = 9})
  ok, tr = W.K.call('seal', 'refuge_trust')
  T.ok(not tr.ok and tr.why[1]:find('separation not checked for', 1, true), T.show(tr))
  M.CFG.sep_fresh = 35 * 1200
  -- the last audit (readiness) says the refuge is not separated in the worst case (a hatch is no barrier there)
  local audit = {name = 'readiness', every = {ticks = 100000}}
  function audit.refuge_audit(K) return {sep = 0, age = 300} end
  W.load(audit)
  ok, tr = W.K.call('seal', 'refuge_trust')
  T.ok(not tr.ok and tr.why[1] == 'audit: refuge_sep failed 300 t ago', T.show(tr))
  T.eq(tr.audit, {sep = 0, age = 300})
  audit.refuge_audit = function(K) return {sep = 1, age = 300} end
  ok, tr = W.K.call('seal', 'refuge_trust')
  T.ok(tr.ok, T.show(tr))
end)

T.test('BUG-049: an opening that reaches the refuge (no door on the way) is untrusted "exposed"; a burrow the kernel ' ..
       'does not know yet is "unverified"', function()
  local W = fort()                                    -- no door: the entrance leads into the hall and down the shaft
  local ok, tr = W.K.call('seal', 'refuge_trust')
  T.ok(ok and not tr.ok and tr.why[1]:find('exposed: open to 1 entrance', 1, true), T.show(tr))
  T.eq(tr.sep, 0)
  local W2 = fort{door = true, settle = 1}
  local _, tr2 = W2.K.call('seal', 'refuge_trust')
  T.ok(tr2 == nil or tr2.ok == false, T.show(tr2))
end)

---------------------------------------------------------------- BUG-123/124 (Run 14 note 102, y710)
-- The manifest named a civilians' stair whose head 77,68,125 was undug, unrevealed rock; the kernel (like the plan check)
-- wanted a hatch there for ever ("no hatch at ...": R0 refuge_trust). The stair is read on revealed tiles only: no stair
-- (never dug) is flagged and asks for nothing; a real stair with an unrevealed head moves the hatch to the nearest
-- revealed tile of it; with none the player is asked once (DECISION_NEEDED refuge_hatch, util/cadence).
-- A stair column apart from the fort (x30 y20, z5-9: < X X X >) stands for "the manifest's stair"
local function stair_column(W, x, y, hide)
  SW.fill(W, Z - 4, x, y, x, y, '<')
  for z = Z - 3, Z - 1 do SW.fill(W, z, x, y, x, y, 'X') end
  SW.fill(W, Z, x, y, x, y, '>')
  for _, z in ipairs(hide or {}) do W.tiles[SW.key(x, y, z)].des.hidden = true end
  SW.regroup(W)
end

local function with_manifest(W, x, y)
  W.K.persist.set('manifest', {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
                               refuge = {anchor = {5, 5, Z - 4}, burrow = 'Tiefe+'}, stairs = {civ = {{x, y, Z - 4, Z}}}})
  inspect(W, 'refuge', 'refresh')
  W.run(1200, {skip = 9})
end

T.test('BUG-123: a manifest stair that is no stair on the map (head tile unrevealed rock, or revealed rock) is "nostair": ' ..
       'trusted without a hatch, the entry flagged in trust.hatch (old: "no hatch at 6,6,6" for ever, R0 refuge_trust)',
       function()
  for _, hidden in ipairs({true, false}) do
    local W = fort{door = true}
    if hidden then                                      -- undug AND unrevealed: the whole column is hidden rock
      for z = Z - 4, Z do W.tiles[SW.key(30, 20, z)].des.hidden = true end
    end
    with_manifest(W, 30, 20)
    local ok, tr = W.K.call('seal', 'refuge_trust')
    T.ok(ok and tr.ok, T.show(tr))
    T.eq(tr.hatch, {pos = {30, 20, Z - 3}, state = 'nostair'})
    local _, rs = W.K.call('seal', 'refuge_stair')
    T.eq({rs.state, rs.pos, rs.man}, {'nostair', nil, {30, 20, Z - 3}})
    T.eq({W.state().alert.ref.tr, W.state().alert.ref.trw}, {1, nil})
    T.eq(#evs(W, 'DECISION_NEEDED'), 0, 'no stair, nobody is asked')
    T.eq(inspect(W, 'refuge').trust.hatch.state, 'nostair')
  end
end)

T.test('BUG-124: a real stair whose head tile is not revealed: the hatch goes to the nearest revealed tile of the same ' ..
       'stair (refuge_stair moved, refuge_trust wants it there), trusted once it stands', function()
  local W = fort{door = true}
  stair_column(W, 30, 20, {Z - 3})                      -- head 30,20,6 hidden; 30,20,7 is the nearest revealed stair
  with_manifest(W, 30, 20)
  local _, rs = W.K.call('seal', 'refuge_stair')
  T.eq({rs.state, rs.pos, rs.man}, {'moved', {30, 20, Z - 2}, {30, 20, Z - 3}})
  local ok, tr = W.K.call('seal', 'refuge_trust')
  T.ok(ok and not tr.ok, T.show(tr))
  T.eq(tr.why, {'no hatch at 30,20,7'})
  T.eq(tr.hatch, {pos = {30, 20, Z - 2}, state = 'missing', man = {30, 20, Z - 3}})
  T.eq(#evs(W, 'DECISION_NEEDED'), 0)
  local hatch = SW.building(W, 'DOOR', 'Hatch', 30, 20, Z - 2)
  W.dyn[SW.key(30, 20, Z - 2)] = hatch
  W.tiles[SW.key(30, 20, Z - 2)].occ.building = df.tile_building_occ.Dynamic
  _, tr = W.K.call('seal', 'refuge_trust')
  T.ok(tr.ok and tr.hatch.state == 'ok', T.show(tr))
end)

T.test('BUG-124: a real stair with no revealed tile above its refuge level: not trusted ("hatch tile 30,20,6 not ' ..
       'revealed"), the player is asked once (DECISION_NEEDED refuge_hatch, cadence), no R0 blocker', function()
  local W = fort{door = true}
  stair_column(W, 30, 20, {Z - 3, Z - 2, Z - 1, Z})     -- only the refuge level 30,20,5 is revealed
  with_manifest(W, 30, 20)
  local _, rs = W.K.call('seal', 'refuge_stair')
  T.eq({rs.state, rs.pos, rs.real}, {'hidden', nil, {30, 20, Z - 4}})
  local _, tr = W.K.call('seal', 'refuge_trust')
  T.eq({tr.ok, tr.why, tr.hatch}, {false, {'hatch tile 30,20,6 not revealed'}, {pos = {30, 20, Z - 3}, state = 'hidden'}})
  T.eq(W.state().alert.ref.trw, 'hatch tile 30,20,6 not revealed')
  local d = evs(W, 'DECISION_NEEDED')
  T.eq(#d, 1, T.show(d))
  T.eq(d[1].d.id, 'refuge_hatch')
  T.ok(d[1].msg:find('30,20,6 is not revealed: look at it in the game', 1, true) and #d[1].msg <= 200, d[1].msg)
  W.run(3 * 1200, {skip = 9})                           -- unchanged, within the cadence: not again
  T.eq(#evs(W, 'DECISION_NEEDED'), 1, 'cadence: once')
  -- the player looks at the tile: it is revealed, the question ends and the hatch is wanted there
  W.tiles[SW.key(30, 20, Z - 3)].des.hidden = false
  W.run(1200, {skip = 9})
  _, rs = W.K.call('seal', 'refuge_stair')
  T.eq({rs.state, rs.pos}, {'ok', {30, 20, Z - 3}})
  _, tr = W.K.call('seal', 'refuge_trust')
  T.eq(tr.why, {'no hatch at 30,20,6'})
end)

T.test('BUG-123: the real fort stair keeps working: head revealed -> state ok, hatch missing is still the reason ' ..
       '(a real exposed refuge stays untrusted)', function()
  local W = fort{door = true}
  with_manifest(W, 6, 6)
  local _, rs = W.K.call('seal', 'refuge_stair')
  T.eq({rs.state, rs.pos}, {'ok', {6, 6, Z - 3}})
  local _, tr = W.K.call('seal', 'refuge_trust')
  T.eq(tr.why, {'no hatch at 6,6,6'})
end)

T.done()
