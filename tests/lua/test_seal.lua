-- seal (FR-22/24/33/37/54/56/57): reach audit and CUTOFF with blame, stairs without counterpart, the entrance
-- check (walk groups, BFS, first leak, routes, SEAL_LEAK), the perimeter manifest and its post-siege repair, the
-- bridge truth of inspect defense, burrow audits, the interior burrow and the alert burrow choice (refuge swap),
-- plus the siege and sense hooks. k_mock (strict) + tests/lua/seal_world.lua (DF-like walk groups).
local T = require('testlib')
local SW = require('seal_world')
local S = require('siege_world')

local function seal()
  package.loaded['dfllm.seal'] = nil
  return require('dfllm.seal')
end
local function evs(W, t) return W.find_events(t) end
local function inspect(W, what, key)
  local r = W.inbox('inspect', {what = what, key = key})
  T.ok(r.ok, r.msg)
  return r.data, r.msg
end
local function has(list, pat)
  for _, s in ipairs(list or {}) do if tostring(s):find(pat, 1, true) then return true end end
  return false
end

---------------------------------------------------------------- the reach fort (z 5)
-- room A x2-8 y2-8 (beds, drink, food), corridor y5 x9-11, room B x12-18 y2-8 (seeds); citizens 1-2 in A, 3-5 in B
local Z = 5
local function fort(opts)
  opts = opts or {}
  local W = SW.new{persist = opts.persist}
  SW.fill(W, Z, 0, 0, 20, 10, '#')
  SW.fill(W, Z, 2, 2, 8, 8, '.')
  SW.fill(W, Z, 12, 2, 18, 8, '.')
  SW.fill(W, Z, 9, 5, 11, 5, '.')
  SW.draw(W, Z, {'bb'}, 3, 3)
  if opts.draw then opts.draw(W) end
  SW.regroup(W)
  SW.citizens(W, {{1, 4, 4, Z}, {2, 5, 5, Z}, {3, 14, 4, Z}, {4, 15, 5, Z}, {5, 16, 6, Z}})
  if opts.items ~= false then
    SW.item(W, 'DRINK', 6, 6, Z, 10)
    SW.item(W, 'PLANT', 7, 7, Z, 20)
    SW.item(W, 'SEEDS', 16, 7, Z, 5)
  end
  for _, m in ipairs(opts.mods or {}) do W.load(m) end
  local M = seal()
  W.load(M)
  return W, M
end

T.test('reach: every vital class on the citizens\' group, no CUTOFF; inspect lists groups (never a constant id)', function()
  local W = fort()
  W.run(300, {skip = 9})
  T.eq(#evs(W, 'CUTOFF'), 0)
  local d, msg = inspect(W, 'reach')
  T.eq(d.flags, {"exit: no map edge on the citizens' group (sealed)"}, msg)   -- an enclosed fort has no exit
  T.eq(d.cit.n, 5)
  T.eq(d.cut, {food = 0, drink = 0, bed = 0})
  T.eq({d.classes.food.n, d.classes.food.off, d.classes.drink.n, d.classes.bed.n, d.classes.seeds.off}, {20, 0, 10, 2, 0})
  T.ok(d.main >= 100, 'a group id from the map, not a constant')
  T.eq(W.hidden_wg, 0, 'no walk group of a hidden tile was read')
end)

T.test('CUTOFF (A): a wall queued by the runner and built later cuts room B from food, drink and beds', function()
  local W, M = fort()
  W.run(300, {skip = 9})
  local ok, n = W.K.call('seal', 'closing', 'p1', 'walls', 'infra', {pos = {10, 5, Z}, cells = {{0, 0, 0, 'Cw'}}})
  T.ok(ok); T.eq(n, 1)
  W.run(200, {skip = 9})                        -- the 'before' baseline
  T.eq(#evs(W, 'CUTOFF'), 0)
  SW.build_wall(W, 10, 5, Z)
  W.run(600, {skip = 9})
  local ev = evs(W, 'CUTOFF')
  T.eq(#ev, 1)
  T.eq(ev[1].cls, 'A')
  T.eq({ev[1].d.cls, ev[1].d.n, ev[1].d.pos, ev[1].d.why}, {'food', 3, {10, 5, Z}, 'wall'})
  T.ok(ev[1].msg:find('3 citizens cut off from food: wall at 10,5,5 (p1)', 1, true), ev[1].msg)
  local d = inspect(W, 'reach')
  T.eq(d.cut, {food = 3, drink = 3, bed = 3})
  -- the main group is now room B (3 citizens): room A's 2 citizens are off it, and so is every vital class
  T.ok(has(d.flags, 'citizens: 2 of 5 off the main group') and has(d.flags, "food: none on the citizens' group"),
       table.concat(d.flags, '|'))
  W.run(3000, {skip = 9})
  T.eq(#evs(W, 'CUTOFF'), 1, 'emitted on change only')
  local r = evs(W, 'REACH')
  T.eq(#r, 2, 'flags changed twice: the enclosed fort at boot, then the cut')
  T.ok(r[2].msg:find('citizens: 2 of 5 off the main group', 1, true), r[2].msg)
end)

T.test('CUTOFF: a hand-built wall (no runner) is found by the bounded walk over the cut group', function()
  local W = fort()
  W.run(300, {skip = 9})
  SW.build_wall(W, 9, 5, Z)
  W.run(600, {skip = 9})
  local ev = evs(W, 'CUTOFF')
  T.eq(#ev, 1)
  T.eq({ev[1].d.pos, ev[1].d.why}, {{9, 5, Z}, 'wall'})
end)

T.test('a raised bridge: CUTOFF in PEACE, a SEAL (B) "shut out" in the modes that raise it (ALERT, SIEGE)', function()
  for _, mode in ipairs({'PEACE', 'SIEGE', 'ALERT'}) do
    local W = fort{draw = function(W) SW.draw(W, Z, {'='}, 10, 5) end}
    W.set_mode(mode)
    W.run(300, {skip = 9})
    W.dyn[SW.key(10, 5, Z)].gate_flags.raised = true
    SW.regroup(W)
    W.run(600, {skip = 9})
    if mode == 'PEACE' then
      T.eq(#evs(W, 'CUTOFF'), 1)
      T.eq({evs(W, 'CUTOFF')[1].d.why, evs(W, 'CUTOFF')[1].d.pos}, {'bridge', {10, 5, Z}})
    else
      T.eq(#evs(W, 'CUTOFF'), 0)
      local shut = {}
      for _, e in ipairs(evs(W, 'SEAL')) do
        if e.msg:find('shut out from food by a raised bridge at 10,5,5', 1, true) then shut[#shut + 1] = e end
      end
      T.eq(#shut, 1)
      T.eq(shut[1].d.why, 'shut_out')
    end
  end
end)

T.test('stairs without counterpart (Run 9 entrance stair): flagged by the scan, hidden counterparts never read', function()
  local W = fort{draw = function(W)
    SW.draw(W, Z, {'<'}, 8, 8)                 -- up stair, a floor above
    SW.draw(W, Z + 1, {'.'}, 8, 8)
    SW.draw(W, Z, {'>'}, 2, 8)                 -- down stair, hidden below
    SW.draw(W, Z - 1, {'?'}, 2, 8)
    SW.draw(W, Z, {'X'}, 5, 8)                 -- a good pair
    SW.draw(W, Z + 1, {'X'}, 5, 8)
  end}
  W.run(400, {skip = 9})
  local d = inspect(W, 'reach')
  local got = {}
  for _, s in ipairs(d.stairs) do got[#got + 1] = table.concat({s[1], s[2], s[3], s[4], s[5]}, ' ') end
  table.sort(got)
  T.eq(got, {'2 8 5 down stair below unrevealed', '8 8 5 up stair no stair above'})
  T.eq(W.hidden_wg, 0)
end)

---------------------------------------------------------------- the gatehouse (z 9): a field to the map edge
-- field ',' x0-63 y0-63 (outside); fort walls x20-40 y20-30, hall '.' x21-39 y21-29 (inside); O1 bridge at
-- 20,25 in the west wall; optional door 30,30 in the south wall (a bypass to the field)
local G = 9
local MAN = {v = 2, bridges = {O1 = {role = 'outer', fp = {20, 25, G, 20, 25, G}, levers = {{25, 22, G}, {26, 22, G}}}},
             burrows = {['Kern+'] = {role = 'kern'}}}
local function gatehouse(opts)
  opts = opts or {}
  local W = SW.new{persist = {manifest = MAN}}
  SW.fill(W, G, 0, 0, 63, 63, ',')
  SW.fill(W, G, 20, 20, 40, 30, '#')
  SW.fill(W, G, 21, 21, 39, 29, '.')
  SW.draw(W, G, {opts.raised and 'H' or '='}, 20, 25)
  if opts.door then SW.draw(W, G, {'+'}, 30, 30) end
  W.o1 = W.dyn[SW.key(20, 25, G)]
  if opts.lever then SW.lever(W, 25, 22, G, W.o1) end
  SW.regroup(W)
  SW.citizens(W, {{1, 30, 25, G}, {2, 35, 27, G}})
  W.gate_state = opts.raised and 'up' or 'down'
  W.gate = SW.fake('gate', {state = function(K, b) if b == nil then return {} end return W.gate_state end,
                            fire = function(K, s) K.emit('GATE', 'C', 'O1 ' .. s, {bridge = 'O1', state = s}) end})
  W.runner = {cells = {}}
  W.load(W.gate)
  W.load(SW.fake('runner', {repair = function(K, cells, why)
    W.runner.cells[#W.runner.cells + 1] = cells
    return true, 'rp1'
  end}))
  local M = seal()
  W.load(M)
  return W, M
end

T.test('entrances: a lowered O1 is the first leak (one route); raised: seal verified by walk groups', function()
  local W = gatehouse()
  W.run(400, {skip = 9})
  local d, msg = inspect(W, 'entrances')
  T.eq({d.sealed, d.routes}, {false, 1})
  T.eq(d.first.pos, {20, 25, G})
  T.eq({d.first.bld, d.first.state}, {'Bridge', 'down'})
  T.ok(msg:find('LEAK at 20,25,9 (Bridge down); 1 independent route', 1, true), msg)
  T.ok(d.edge[1] == 0 or d.edge[2] == 0 or d.edge[1] == 63 or d.edge[2] == 63, 'the route ends on the map edge')
  W.o1.gate_flags.raised = true
  W.gate_state = 'up'
  SW.regroup(W)
  d, msg = inspect(W, 'entrances', 'refresh')
  T.eq({d.sealed, d.routes, msg}, {true, 0, 'seal verified: no route'})
  T.eq(W.hidden_wg, 0)
end)

T.test('after a lever pull: sealed -> SEAL (B); a bypass door with O1 up -> SEAL_LEAK (A) naming the door', function()
  local W = gatehouse{raised = true}
  W.run(400, {skip = 9})
  W.K.call('gate', 'fire', 'up')
  W.run(200, {skip = 9})
  local s = evs(W, 'SEAL')
  T.ok(#s >= 1 and s[#s].msg == 'seal verified: no route' and s[#s].d.why == 'lever', s[#s] and s[#s].msg)
  T.eq(#evs(W, 'SEAL_LEAK'), 0)
  -- the serpentine bypass: a door in the south wall to the field
  SW.draw(W, G, {'+'}, 30, 30)
  SW.regroup(W)
  W.K.call('gate', 'fire', 'up')
  W.run(200, {skip = 9})
  local l = evs(W, 'SEAL_LEAK')
  T.eq(#l, 1)
  T.eq({l[1].d.pos, l[1].d.bld, l[1].d.state, l[1].d.routes, l[1].d.why}, {{30, 30, G}, 'Door', 'closed', 1, 'lever'})
  T.ok(l[1].msg:find('LEAK at 30,30,9 (Door closed)', 1, true), l[1].msg)
  -- BUG-008: the same leak is not announced again on the next checks (it was every lever pull and every audit)
  for _ = 1, 3 do
    W.K.call('gate', 'fire', 'up')
    W.run(200, {skip = 9})
  end
  T.eq(#evs(W, 'SEAL_LEAK'), 1, 'same leak, same state: once per episode')
end)

T.test('entrances: two openings are two independent routes; the doors on them are learned as perimeter', function()
  local W = gatehouse{door = true}
  W.run(400, {skip = 9})
  local d = inspect(W, 'entrances')
  T.eq(d.routes, 2)
  local p = inspect(W, 'perimeter')
  T.eq(p.by.door, 1, 'the bypass door on an opening')
  T.ok((p.by.bridge or 0) >= 1, 'the manifest bridge')
end)

T.test('defense: gate_flags, the walk groups on both sides and the levers per bridge (FR-24)', function()
  local W = gatehouse{lever = true}
  W.run(100, {skip = 9})
  local d, msg = inspect(W, 'defense')
  local b = d.bridges[1]
  T.eq({b.name, b.state, b.gate_flags.raised, b.walk.through}, {'O1', 'down', 0, 'open'})
  T.eq(#b.walk.sides, 1)
  T.eq(#b.levers, 2)
  T.eq({b.levers[1].pos, b.levers[1].linked}, {{25, 22, G}, 1})
  T.eq({b.levers[2].pos, b.levers[2].linked, b.levers[2].why}, {{26, 22, G}, 0, 'no lever built'})
  T.ok(msg:find('O1 down/open 1lev', 1, true), msg)
  W.o1.gate_flags.raised = true
  SW.regroup(W)
  b = inspect(W, 'defense').bridges[1]
  T.eq({b.state, b.walk.through, #b.walk.sides, b.walk.footprint}, {'up', 'cut', 2, {0}})
  SW.draw(W, G, {'+'}, 30, 30)                -- raised, yet a door joins both sides
  SW.regroup(W)
  b = inspect(W, 'defense').bridges[1]
  T.eq({b.state, b.walk.through}, {'up', 'bypass'})
end)

---------------------------------------------------------------- perimeter (FR-56)
T.test('perimeter: a defense wall is recorded once built; lost in a siege -> re-queued + PERIMETER_BROKEN (A)', function()
  local W = gatehouse()
  W.run(300, {skip = 9})
  W.K.call('seal', 'closing', 'fc2', 'fortcore', 'defense', {pos = {40, 26, G}, cells = {{0, 0, 0, 'Cw'}}})
  SW.build_wall(W, 40, 26, G)
  W.run(300, {skip = 9})
  local p = inspect(W, 'perimeter')
  T.ok(has(p.pieces[1], '') and p.by.wall == 1, 'the wall is a perimeter piece')
  W.K.set_mode('SIEGE', 'test')
  W.run(200, {skip = 9})
  SW.draw(W, G, {'.'}, 40, 26)                -- destroyed during the siege
  SW.regroup(W)
  W.K.set_mode('RECOVERY', 'test')
  W.run(200, {skip = 9})
  local ev = evs(W, 'PERIMETER_BROKEN')
  T.eq(#ev, 1)
  T.eq({ev[1].cls, ev[1].d.n, ev[1].d.pos, ev[1].d.kinds, ev[1].d.requeued}, {'A', 1, {40, 26, G}, {'wall'}, 1})
  T.eq(W.runner.cells, {{{40, 26, G, 'Cw'}}})
  T.ok(ev[1].msg:find('re-queued as rp1', 1, true), ev[1].msg)
  W.K.set_mode('PEACE', 'test')
  W.run(100, {skip = 9})
  T.eq(#evs(W, 'PERIMETER_BROKEN'), 1, 'reported once per cool-down (RECOVERY and SIEGE_END both diff)')
end)

T.test('perimeter: a piece already gone when a siege begins is retired, never rebuilt', function()
  local W = gatehouse()
  W.run(300, {skip = 9})
  W.K.call('seal', 'closing', 'fc2', 'fortcore', 'defense', {pos = {40, 26, G}, cells = {{0, 0, 0, 'Cw'}}})
  SW.build_wall(W, 40, 26, G)
  W.run(300, {skip = 9})
  SW.draw(W, G, {'.'}, 40, 26)                -- the player removed it in peace
  SW.regroup(W)
  W.K.set_mode('SIEGE', 'test')
  W.run(200, {skip = 9})
  W.K.set_mode('RECOVERY', 'test')
  W.run(200, {skip = 9})
  T.eq(#evs(W, 'PERIMETER_BROKEN'), 0)
  T.eq(W.runner.cells, {})
end)

T.test('perimeter after an ambush: a wall lost in ALERT or in a lockdown that never became a siege is re-queued + ' ..
       'PERIMETER_BROKEN once it is quiet again; one gone before the episode is retired', function()
  -- ALERT (a small ambush): no SIEGE, no RECOVERY, no SIEGE_END
  local W = gatehouse()
  W.run(300, {skip = 9})
  W.K.call('seal', 'closing', 'fc2', 'fortcore', 'defense', {pos = {40, 26, G}, cells = {{0, 0, 0, 'Cw'}}})
  SW.build_wall(W, 40, 26, G)
  W.run(300, {skip = 9})
  W.K.set_mode('ALERT', 'test')
  W.run(200, {skip = 9})
  SW.draw(W, G, {'.'}, 40, 26)                -- broken by the ambushers
  SW.regroup(W)
  W.run(200, {skip = 9})
  T.eq(#evs(W, 'PERIMETER_BROKEN'), 0, 'not while the episode runs')
  W.K.set_mode('PEACE', 'test')
  W.run(200, {skip = 9})
  local ev = evs(W, 'PERIMETER_BROKEN')
  T.eq(#ev, 1)
  T.eq({ev[1].d.pos, ev[1].d.kinds, ev[1].d.requeued, ev[1].d.why}, {{40, 26, G}, {'wall'}, 1, 'post'})
  T.eq(W.runner.cells, {{{40, 26, G, 'Cw'}}})
  -- a reflex lockdown in PEACE (an arrival; the army never came into sight): the same at LOCKDOWN_END
  local W2 = gatehouse()
  W2.lock = nil
  W2.load(SW.fake('reflex', {holding = function() return W2.lock end}))
  W2.run(300, {skip = 9})
  for _, x in ipairs({40, 20}) do
    W2.K.call('seal', 'closing', 'fc2', 'fortcore', 'defense', {pos = {x, 22, G}, cells = {{0, 0, 0, 'Cw'}}})
    SW.build_wall(W2, x, 22, G)
  end
  W2.run(300, {skip = 9})
  SW.draw(W2, G, {'.'}, 20, 22)               -- the player removed this one in peace: retired when the lockdown begins
  SW.regroup(W2)
  W2.lock = 'arrival:siege'
  W2.run(200, {skip = 9})
  SW.draw(W2, G, {'.'}, 40, 22)               -- lost during the lockdown
  SW.regroup(W2)
  W2.run(200, {skip = 9})
  T.eq(#evs(W2, 'PERIMETER_BROKEN'), 0)
  W2.lock = nil                                -- LOCKDOWN_END
  W2.run(200, {skip = 9})
  ev = evs(W2, 'PERIMETER_BROKEN')
  T.eq(#ev, 1)
  T.eq({ev[1].d.pos, ev[1].d.n, ev[1].d.requeued}, {{40, 22, G}, 1, 1})
  T.eq(W2.runner.cells, {{{40, 22, G, 'Cw'}}}, 'the wall the player removed is never rebuilt')
  W2.run(1200, {skip = 9})
  T.eq(#evs(W2, 'PERIMETER_BROKEN'), 1, 'once')
end)

---------------------------------------------------------------- refuge and alert burrow (FR-33/37/57)
-- Kern+ = 4 tiles in room A without supplies; Tiefe+ = room B with drink, food and beds
local function refuge_fort(opts)
  opts = opts or {}
  local man = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
               refuge = {anchor = {15, 5, Z}, burrow = 'Tiefe+'}}
  local W, M = fort{persist = {manifest = man}, items = opts.items, draw = function(W)
    SW.draw(W, Z, {'bb'}, 13, 7)
  end}
  W.burrow('Kern+', opts.kern or {4, 4, Z, 5, 5, Z})
  W.burrow('Tiefe+', {12, 2, Z, 18, 8, Z})
  if opts.items ~= false then
    SW.item(W, 'DRINK', 17, 3, Z, 10)
    SW.item(W, 'PLANT', 17, 4, Z, 10)
  end
  return W, M
end

T.test('refuge: Kern+ without drink is refused; the interior burrow Innen+ is painted and chosen; REFUGE_FAIL', function()
  local W = refuge_fort()
  W.run(1200, {skip = 9})
  local paints = W.find_acts('burrow_tiles')
  T.ok(#paints >= 1 and paints[1].args[1] == 'Innen+' and paints[1].args[3] == true, 'Innen+ painted')
  local d, msg = inspect(W, 'refuge')
  T.eq(d.burrows['Kern+'].ok, 0)
  T.ok(d.burrows['Kern+'].why:find('4 tiles<20', 1, true) and d.burrows['Kern+'].why:find('drink 0<5', 1, true),
       d.burrows['Kern+'].why)
  T.eq({d.burrows['Tiefe+'].ok, d.burrows['Innen+'].ok, d.burrows['Innen+'].tiles}, {1, 1, 101})
  T.eq(d.choice.ALERT, {want = 'Kern+', burrow = 'Innen+', level = 'SIEGE'})
  T.ok(msg:find('alert PEACE: Innen+, 101 tiles, 5/5 inside', 1, true), msg)
  local ok, pick = W.K.call('seal', 'alert_burrow', 'ALERT', 'Kern+')
  T.eq({ok, pick}, {true, 'Innen+'})
  local f = evs(W, 'REFUGE_FAIL')
  T.eq(#f, 1)
  T.eq({f[1].cls, f[1].d.burrow, f[1].d.fallback, f[1].d.mode}, {'A', 'Kern+', 'Innen+', 'ALERT'})
  W.K.call('seal', 'alert_burrow', 'ALERT', 'Kern+')
  T.eq(#evs(W, 'REFUGE_FAIL'), 1, 'once per change and day')
  -- BUG-008: an unchanged refusal is not repeated after a game day (3 s at timestream speed) nor after 10 min
  W.run(1300, {skip = 9})
  W.ms = W.ms + 700 * 1000
  W.K.call('seal', 'alert_burrow', 'ALERT', 'Kern+')
  T.eq(#evs(W, 'REFUGE_FAIL'), 1, 'unchanged condition: never repeated')
  local st = W.state().alert
  T.eq({st.want, st.burrow, st.tiles, st.inside, st.ok}, {'Kern+', 'Innen+', 101, 5, 0})
end)

T.test('refuge: no drink anywhere -> no confinement (nil), said by REFUGE_FAIL; state shows it', function()
  local W = refuge_fort{items = false}
  W.run(1200, {skip = 9})
  local ok, pick = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  T.eq({ok, pick}, {true, nil})
  local f = evs(W, 'REFUGE_FAIL')
  T.ok(#f == 1 and f[1].d.fallback == '' and f[1].msg:find('no confinement, the whole fort', 1, true), f[1] and f[1].msg)
  T.eq(W.state().alert.burrow, '')
end)

T.test('refuge swap: BREACH confines to Tiefe+; held until 3 quiet days, then back to Kern+', function()
  local W = refuge_fort{kern = {2, 2, Z, 8, 8, Z}}             -- a good Kern+: room A with its supplies
  SW.item(W, 'PLANT', 6, 3, Z, 10)
  W.run(300, {skip = 9})
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'ALERT', 'Kern+')), 'Kern+')
  W.set_census('h', {tick = W.K.now().tick, vis = 3, armed = 0, list = {}})
  W.set_mode('BREACH')
  W.run(100, {skip = 9})
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')), 'Tiefe+')
  W.set_mode('RECOVERY')
  W.set_census('h', {tick = W.K.now().tick, vis = 0, armed = 0, list = {}})
  W.run(1200, {skip = 9})
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'RECOVERY', 'Kern+')), 'Tiefe+', 'held: 1 quiet day')
  T.eq(W.state().alert.want, 'Tiefe+')
  W.run(2600, {skip = 9})
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'RECOVERY', 'Kern+')), 'Kern+', '3 quiet days: back')
  T.eq(#evs(W, 'REFUGE_FAIL'), 0)
end)

T.test('BUG-019: in BREACH the refuge needs no drink, food or beds (BREACH level) for breach_days; then the counts ' ..
       'again (Kern+)', function()
  -- old code: "REFUGE_FAIL alert burrow Tiefe+ refused (Tiefe+: drink 0<5, food 0<5, ...): confining to Kern+"
  local W = refuge_fort{kern = {2, 2, Z, 8, 8, Z}, items = false}
  SW.item(W, 'DRINK', 6, 6, Z, 10)
  SW.item(W, 'PLANT', 6, 3, Z, 10)
  W.run(300, {skip = 9})
  local d = inspect(W, 'refuge')
  T.eq({d.burrows['Tiefe+'].ok, d.burrows['Tiefe+'].counts, d.burrows['Tiefe+'].breach, d.burrows['Tiefe+'].sep},
       {0, 0, 1, 1}, d.burrows['Tiefe+'].why)
  T.eq(d.choice.BREACH, {want = 'Tiefe+', burrow = 'Tiefe+', level = 'BREACH'})
  W.set_mode('BREACH')
  local ok, pick = W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')
  T.eq({ok, pick}, {true, 'Tiefe+'})
  T.eq(#evs(W, 'REFUGE_FAIL'), 0, 'the pick is the refuge: no refusal')
  T.ok(W.logs[#W.logs].msg:find('Tiefe+ holds the citizens without drink, food or bed counts (BREACH level) for 7 days',
       1, true), W.logs[#W.logs].msg)
  W.run(6 * 1200, {skip = 9})
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')), 'Tiefe+', 'day 6: still')
  W.run(1300, {skip = 9})
  T.eq(select(2, W.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')), 'Kern+', 'after 7 days the counts count')
  local f = evs(W, 'REFUGE_FAIL')
  T.ok(#f == 1 and f[1].d.burrow == 'Tiefe+' and f[1].d.why:find('drink 0<5', 1, true), f[1] and f[1].d.why)
  -- config/reflex.json refuge.breach_days
  local W2 = refuge_fort{kern = {2, 2, Z, 8, 8, Z}, items = false}
  W2.K.cfg.reflex = {v = 2, refuge = {breach_days = 1}}
  SW.item(W2, 'DRINK', 6, 6, Z, 10)
  SW.item(W2, 'PLANT', 6, 3, Z, 10)
  W2.run(300, {skip = 9})
  W2.set_mode('BREACH')
  T.eq(select(2, W2.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')), 'Tiefe+')
  W2.run(1300, {skip = 9})
  T.eq(select(2, W2.K.call('seal', 'alert_burrow', 'BREACH', 'Tiefe+')), 'Kern+', 'breach_days 1')
end)

---------------------------------------------------------------- siege and sense hooks
T.test('siege asks seal for the alert burrow: Innen+ is confined to; nil keeps the alert off', function()
  for _, pick in ipairs({'Innen+', false}) do
    local W = S.world{units = {S.cit(1, 60, 70), S.cit(6, 100, 100), S.danger(300, 120, 100)}}
    W.burrow('Innen+', {40, 41, S.Z - 2, 130, 130, S.Z})
    local asked = {}
    W.mil = S.military()
    S.load(W, {W.mil, SW.fake('seal', {alert_burrow = function(K, mode, default)
      asked[#asked + 1] = mode .. ':' .. tostring(default)
      return pick or nil
    end})})
    S.run(W, 1500)
    T.eq(W.K.mode(), 'ALERT')
    T.ok(#asked > 0 and asked[1] == 'ALERT:Kern+', table.concat(asked, ' '))
    local on = S.acts(W, 'civ_alert', function(a) return a.args[1] == true end)
    if pick then
      T.eq(#on, 1)
      T.eq(W.alert_burrows[1], 'Innen+')
    else
      T.eq(#on, 0, 'no confinement: the civ alert stays off')
    end
  end
end)

T.test('sense (FR-33): a wild large predator outside counts only near an entrance', function()
  local function run(px, py, with_seal)
    local W = S.world{units = {S.cit(1, 60, 70), {id = 300, pos = {px, py, S.Z}, animal = true}}}
    df.creature_raw = {find = function() return {caste = {[0] = {flags = {LARGE_PREDATOR = true}}}} end}
    W.unit(300).race, W.unit(300).caste = 1, 0
    dfhack.maps.getWalkableGroup = function() return 7 end
    local extra = {S.military()}
    if with_seal then
      extra[#extra + 1] = SW.fake('seal', {entrances = function() return {{51, 10, S.Z}}, 25 end})
    end
    S.load(W, extra)
    S.run(W, 600)
    return W.K.mode(), W.K.census.h.vis
  end
  T.eq({run(120, 100, true)}, {'PEACE', 0}, 'far from the entrance: wildlife')
  T.eq({run(60, 25, true)}, {'ALERT', 1}, 'within 25 tiles of O1')
  T.eq({run(120, 100, false)}, {'ALERT', 1}, 'no entrance known: as before')
end)

T.test('BUG-026: background jobs wait while another module holds a busy boost (trade screen); urgent ones run', function()
  local busy = false
  local trade = {name = 'trade', every = {ticks = 10}}
  function trade.step(K) if busy then K.boost('trade screen', true) else K.unboost() end end
  local W = fort{mods = {trade}}
  W.run(2400, {skip = 9})
  local runs0 = inspect(W, 'reach').runs
  T.ok((runs0.audit or 0) >= 1, 'the boot audit ran')
  busy = true
  W.run(20, {skip = 9})
  T.eq(W.K.busy(), 'trade')
  W.run(3 * 1200 + 600, {skip = 9})                       -- past audit_every: the periodic audit is due
  T.eq(inspect(W, 'reach').runs.audit, runs0.audit, 'no background audit while trade is busy')
  busy = false
  W.run(200, {skip = 9})
  T.ok(inspect(W, 'reach').runs.audit > runs0.audit, 'the periodic audit runs once the boost ends')
end)

T.done()
