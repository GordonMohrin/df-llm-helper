-- BUG-096 / BUG-097 / FR-80 (Run 14 note 70, y586: Kern+ shrank to about one tile, Tiefe+ vanished from plotinfo.burrows.list, the
-- hospital zone lay outside the alert burrow for the fourth time, and the kernel had never noticed): seal's burrow guard reads
-- Kern+ and the refuge once a game day and at a load, keeps the last good reading (tiles as runs) in the persist key `burrows`,
-- announces a loss once (BURROW_SHRUNK, A) and paints the lost tiles again in quiet modes (BURROW_REPAIRED, B).
-- k_mock (strict) + tests/lua/seal_world.lua; a burrow that "vanishes" is hidden from findByName (W.gone), the way
-- plotinfo.burrows.list lost it.
local T = require('testlib')
local SW = require('seal_world')
local json = require('dfllm.util.json')

local Z = 9
local MAN = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
             refuge = {anchor = {6, 6, Z - 4}, burrow = 'Tiefe+'}}

local function evs(W, t) return W.find_events(t) end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l end end
end
local function reloaded(W)
  local out = {}
  for dk, s in pairs(W.persist_raw) do
    out[dk == 'dfllm' and 'marker' or dk:gsub('^dfllm%.', '')] = json.decode(s)
  end
  return out
end
-- a game day (a little over) and the real minutes the guard waits between two readings (burrow.guard.every_s, 120 s)
local function day(W, n)
  for _ = 1, n or 1 do
    W.ms = W.ms + 130000
    W.run(1300, {skip = 9})
  end
  W.state()
end
-- tiles of `name` inside a box (the mock's bbox + painted tiles)
local function count(name, z, x0, y0, x1, y1)
  local b = dfhack.burrows.findByName(name)
  if not b then return nil end
  local n = 0
  for y = y0, y1 do
    for x = x0, x1 do
      if dfhack.burrows.isAssignedTile(b, {x = x, y = y, z = z}) then n = n + 1 end
    end
  end
  return n
end
local function kern_n(W) return count('Kern+', Z, 0, 0, 40, 30) end
local function repaints(W, name)
  local r = {}
  for _, a in ipairs(W.find_acts('burrow_tiles')) do
    if a.args[1] == name then r[#r + 1] = a end
  end
  return r
end

-- a fort: surface z10 (a field), the hall x5-15 y5-15 on z9 (Kern+: 121 tiles), a corridor y20 x25-35 (11 tiles), the refuge
-- room x5-10 y5-10 on z5 (Tiefe+: 36 tiles). o.persist: a reload; o.cfg: config/baseline.json burrow.guard; o.kern: the bbox of
-- Kern+; o.citizens: how many; o.mods: extra modules; o.mode
local function fort(o)
  o = o or {}
  local W = SW.new{persist = o.persist or {manifest = MAN}}
  SW.fill(W, Z + 1, 0, 0, 40, 30, ',')
  SW.draw(W, Z + 1, {'>'}, 20, 10, {outside = true})
  SW.fill(W, Z, 0, 0, 40, 30, '#')
  SW.fill(W, Z, 5, 5, 15, 15, '.')
  SW.fill(W, Z, 25, 20, 35, 20, '.')
  SW.fill(W, Z, 16, 10, 19, 10, '.')
  SW.draw(W, Z, {'<'}, 20, 10)
  SW.draw(W, Z, {'+'}, 19, 10)
  SW.fill(W, Z - 4, 0, 0, 40, 30, '#')
  SW.fill(W, Z - 4, 5, 5, 10, 10, '.')
  SW.regroup(W)
  local cits = {}
  for i = 1, o.citizens or 3 do cits[i] = {i, 8 + i % 6, 9 + i // 6, Z} end
  SW.citizens(W, cits)
  SW.item(W, 'DRINK', 9, 13, Z, 20)
  SW.item(W, 'PLANT', 9, 14, Z, 20)
  W.burrow('Kern+', o.kern or {5, 5, Z, 15, 15, Z})
  W.burrow('Tiefe+', {5, 5, Z - 4, 10, 10, Z - 4})
  if o.cfg then W.K.cfg.baseline = {v = 2, burrow = {guard = o.cfg}} end
  W.gone = {}
  for _, n in ipairs(o.gone or {}) do W.gone[n] = true end          -- gone before the kernel boots (a load)
  local find = dfhack.burrows.findByName
  dfhack.burrows.findByName = function(n)
    if W.gone[n] then return nil end
    return find(n)
  end
  local base = W.act_results.burrow_tiles
  W.act_result('burrow_tiles', function(name, tiles, create)
    if W.gone[name] then
      if not create then return false, 'no burrow ' .. name end
      W.gone[name] = nil                               -- made again: a new id, no tiles but the ones painted
      local b = find(name)
      b._tiles, b._bbox, b.id = {}, nil, b.id + 100
    end
    return base(name, tiles, create)
  end)
  for _, m in ipairs(o.mods or {}) do W.load(m) end
  package.loaded['dfllm.seal'] = nil
  local M = require('dfllm.seal')
  W.load(M)
  if o.mode then W.set_mode(o.mode) end
  W.run(o.settle or 1500, {skip = 9})
  W.state()
  return W, M
end

---------------------------------------------------------------- the record
T.test('FR-80: a reading of Kern+ and the refuge is kept in the persist key `burrows` (tiles, blocks, id, runs) and nothing is ' ..
       'announced while they do not shrink; a burrow the kernel does not manage is not read', function()
  local W = fort()
  local rec = W.K.persist.get('burrows')
  T.ok(rec, 'the record exists after the first reading')
  T.eq({rec.v, rec.ad}, {2, 0})
  local k, t = rec.b['Kern+'], rec.b['Tiefe+']
  T.eq({k.base, t.base}, {121, 36})
  -- runs {z, y, x0, x1}: Kern+ is 11 rows of x5-15 on z9
  T.eq(#k.k, 44)
  T.eq({k.k[1], k.k[2], k.k[3], k.k[4]}, {Z, 5, 5, 15})
  T.eq({k.k[41], k.k[42], k.k[43], k.k[44]}, {Z, 15, 5, 15})
  T.eq(#evs(W, 'BURROW_SHRUNK'), 0)
  T.eq(#evs(W, 'BURROW_REPAIRED'), 0)
  T.eq(W.state().alert.bg, nil, 'no episode: no key')
  W.burrow('Farmers', {1, 1, Z, 3, 3, Z})                 -- the player's burrow: never read, never kept
  day(W)
  T.eq(W.K.persist.get('burrows').b.Farmers, nil)
  -- a burrow that grows moves the baseline on; it is no news
  W.burrow('Kern+', {5, 5, Z, 20, 15, Z})
  day(W)
  T.eq(W.K.persist.get('burrows').b['Kern+'].base, 176)
  T.eq(#evs(W, 'BURROW_SHRUNK'), 0)
end)

---------------------------------------------------------------- a shrink between two daily readings
T.test('BUG-096 (note 70: Kern+ shrank to about one tile): Kern+ falls from 121 tiles to 9 between two daily readings: ' ..
       'BURROW_SHRUNK (A, runtime) once, the 112 lost tiles painted again in PEACE (BURROW_REPAIRED), the state carries no ' ..
       'episode afterwards (old code: nothing at all)', function()
  local W = fort()
  W.burrow('Kern+', {7, 7, Z, 9, 9, Z})
  T.eq(kern_n(W), 9)
  day(W)
  local e = evs(W, 'BURROW_SHRUNK')
  T.eq(#e, 1)
  T.eq({e[1].cls, e[1].d.burrow, e[1].d.was, e[1].d.now, e[1].d.cause, e[1].d.fix, e[1].d.gone, e[1].d.pct},
       {'A', 'Kern+', 121, 9, 'runtime', 'repair', 0, 92})
  T.ok(e[1].msg:find('Kern+ lost 112 of 121 tiles (92%; 1 -> 1 blocks, runtime); repairing, 2000 tiles a day', 1, true), e[1].msg)
  T.ok(e[1].d.nl >= 2 and e[1].d.nx == 50 and e[1].d.id == e[1].d.rid, 'the read-only data that tells how a burrow is lost')
  T.ok(#e[1].msg <= 200)
  local rp = evs(W, 'BURROW_REPAIRED')
  T.eq(#rp, 1)
  T.eq({rp[1].cls, rp[1].d.burrow, rp[1].d.n, rp[1].d.done, rp[1].d.left, rp[1].d.was}, {'B', 'Kern+', 112, 1, 0, 121})
  T.eq(kern_n(W), 121, 'every tile of the last good reading is back')
  T.eq(W.state().alert.bg, nil, 'the episode is over')
  T.eq(W.K.persist.get('burrows').b['Kern+'].ep, nil)
  local acts = repaints(W, 'Kern+')
  T.eq(#acts, 1)
  T.eq(#acts[1].args[2], 112, 'one call, the lost tiles only')
  T.eq(acts[1].args[3], false, 'the burrow exists: no create')
  T.ok(logged(W, 'seal: Kern+ lost 112 of 121 tiles'), 'kern.log')
  T.ok(logged(W, 'seal: burrow Kern+: episode over (repaired)'), 'kern.log')
  -- the next day is quiet
  day(W)
  T.eq(#evs(W, 'BURROW_SHRUNK'), 1)
  T.eq(#evs(W, 'BURROW_REPAIRED'), 1)
end)

T.test('BUG-096: a slow drop (each day under shrink_pct) is no shrink; a burrow under 20 tiles is too small to judge by a share ' ..
       'but is judged when it is emptied', function()
  local W = fort()
  W.burrow('Kern+', {5, 5, Z, 15, 12, Z})              -- 88 tiles: -27 %
  day(W)
  T.eq(#evs(W, 'BURROW_SHRUNK'), 0)
  W.burrow('Kern+', {5, 5, Z, 15, 9, Z})               -- 55 tiles: -37 % of 88
  day(W)
  T.eq(#evs(W, 'BURROW_SHRUNK'), 1, 'the second drop is over 30 %')
  -- a small one
  local W2 = fort{kern = {5, 5, Z, 8, 8, Z}}           -- 16 tiles
  W2.burrow('Kern+', {5, 5, Z, 6, 6, Z})
  day(W2)
  T.eq(#evs(W2, 'BURROW_SHRUNK'), 0, '16 -> 4 tiles: too small a baseline')
  W2.burrow('Kern+', {40, 30, Z, 40, 30, Z})           -- one tile somewhere else
  day(W2)
  T.eq(#evs(W2, 'BURROW_SHRUNK'), 0)
  local W3 = fort{kern = {5, 5, Z, 8, 8, Z}}
  local b = dfhack.burrows.findByName('Kern+')
  b._bbox = nil                                        -- emptied
  day(W3)
  T.eq(#evs(W3, 'BURROW_SHRUNK'), 1, 'a burrow with tiles before and none now is judged whatever its size')
end)

---------------------------------------------------------------- a burrow that vanishes
T.test('BUG-096 (note 70: Tiefe+ was gone from plotinfo.burrows.list): the refuge vanishes: BURROW_SHRUNK gone with ' ..
       'crit refuge, it is made again under its name with the 36 tiles of the last reading (a new id), BURROW_REPAIRED', function()
  local W = fort()
  local id0 = dfhack.burrows.findByName('Tiefe+').id
  W.gone['Tiefe+'] = true
  day(W)
  local e = evs(W, 'BURROW_SHRUNK')
  T.eq(#e, 1)
  T.eq({e[1].d.burrow, e[1].d.was, e[1].d.now, e[1].d.gone, e[1].d.id, e[1].d.rid, e[1].d.crit, e[1].d.fix},
       {'Tiefe+', 36, 0, 1, -1, id0, {'refuge'}, 'repair'})
  T.ok(e[1].msg:find('Tiefe+ is gone (was 36 tiles in 1 blocks, runtime): it held the refuge; repairing', 1, true), e[1].msg)
  local a = repaints(W, 'Tiefe+')
  T.eq(#a, 1)
  T.eq({#a[1].args[2], a[1].args[3]}, {36, true}, 'created again with its tiles')
  T.eq(count('Tiefe+', Z - 4, 0, 0, 40, 30), 36)
  T.eq(dfhack.burrows.findByName('Tiefe+').id, id0 + 100)
  local rp = evs(W, 'BURROW_REPAIRED')
  T.eq({#rp, rp[1].d.n, rp[1].d.done}, {1, 36, 1})
  T.eq(W.state().alert.bg, nil)
  T.eq(#evs(W, 'DECISION_NEEDED'), 0)
  day(W)
  T.eq(W.K.persist.get('burrows').b['Tiefe+'].id, id0 + 100, 'the next reading keeps the new id as baseline')
  T.eq(#evs(W, 'BURROW_SHRUNK'), 1)
end)

T.test('BUG-097: a gone burrow whose tile set is not known (an older record without runs) is not guessed: DECISION_NEEDED ' ..
       'burrow_gone once, the state says so, nothing is painted', function()
  local W = fort()
  local rec = W.K.persist.get('burrows')
  rec.b['Tiefe+'].k = nil                                -- a record without runs
  W.K.persist.set('burrows', rec)
  W.gone['Tiefe+'] = true
  day(W, 2)
  local e = evs(W, 'BURROW_SHRUNK')
  T.eq(#e, 1)
  T.eq(e[1].d.fix, 'ask')
  T.ok(e[1].msg:find('its tile set is not known', 1, true), e[1].msg)
  local q = evs(W, 'DECISION_NEEDED')
  T.eq(#q, 1)
  T.eq({q[1].cls, q[1].d.id, q[1].d.burrow}, {'A', 'burrow_gone', 'Tiefe+'})
  T.ok(#q[1].d.q <= 200 and q[1].d.q:find('Tiefe+ is gone', 1, true), q[1].d.q)
  T.eq(#repaints(W, 'Tiefe+'), 0)
  local bg = W.state().alert.bg
  T.eq({bg.n, bg.b, bg.was, bg.now, bg.st, bg.crit}, {1, 'Tiefe+', 36, 0, 'tiles unknown', 'refuge'})
end)

---------------------------------------------------------------- after a load
T.test('FR-80: a burrow that is smaller after a load than at the last reading before it is announced with cause `load` ' ..
       '(the first reading of a boot); later losses are `runtime`', function()
  local W1 = fort()
  local saved = reloaded(W1)
  T.ok(saved.burrows, 'the record is persisted')
  local W2 = fort{persist = saved, kern = {7, 7, Z, 9, 9, Z}}
  local e = evs(W2, 'BURROW_SHRUNK')
  T.eq(#e, 1)
  T.eq({e[1].d.burrow, e[1].d.cause, e[1].d.was, e[1].d.now}, {'Kern+', 'load', 121, 9})
  T.eq(kern_n(W2), 121, 'repaired after the load')
  W2.ms = W2.ms + 700000
  W2.burrow('Kern+', {7, 7, Z, 9, 9, Z})
  dfhack.burrows.findByName('Kern+')._tiles = {}         -- the tiles painted again go as well
  day(W2)
  e = evs(W2, 'BURROW_SHRUNK')
  T.eq(#e, 2)
  T.eq(e[2].d.cause, 'runtime')
  -- the refuge missing after the load: gone, `load`, made again from the record
  local W3 = fort{persist = saved, gone = {'Tiefe+'}}
  local e3 = evs(W3, 'BURROW_SHRUNK')
  T.eq({#e3, e3[1].d.burrow, e3[1].d.gone, e3[1].d.cause, e3[1].d.crit}, {1, 'Tiefe+', 1, 'load', {'refuge'}})
  T.eq(count('Tiefe+', Z - 4, 0, 0, 40, 30), 36, 'made again at the load')
end)

T.test('FR-80: an old kernel state after a reload: no record, a record of another adoption (a reclaimed or re-adopted fort), ' ..
       'a malformed record: all start from the reading, none announces a shrink or raises', function()
  local W1 = fort()
  local saved = reloaded(W1)
  -- no record at all (an older kernel)
  local p0 = reloaded(W1)
  p0.burrows = nil
  local W0 = fort{persist = p0, kern = {7, 7, Z, 9, 9, Z}}
  T.eq(#evs(W0, 'BURROW_SHRUNK'), 0)
  T.eq(W0.K.persist.get('burrows').b['Kern+'].base, 9)
  -- another adoption
  local pa = reloaded(W1)
  pa.burrows.ad = 777
  local Wa = fort{persist = pa, kern = {7, 7, Z, 9, 9, Z}}
  T.eq(#evs(Wa, 'BURROW_SHRUNK'), 0, 'the old fort\'s tiles are not painted into the new one')
  T.eq(#repaints(Wa, 'Kern+'), 0)
  T.eq(Wa.K.persist.get('burrows').ad, 0)
  -- malformed
  local pm = reloaded(W1)
  pm.burrows.b['Kern+'].k = {1, 2, 3}
  pm.burrows.b['Tiefe+'] = 'junk'
  pm.burrows.b[''] = {base = 5}
  local Wm = fort{persist = pm}
  T.eq(#evs(Wm, 'BURROW_SHRUNK'), 0)
  T.eq(#Wm.faults, 0)
  T.eq(Wm.K.persist.get('burrows').b['Tiefe+'].base, 36)
end)

T.test('FR-80: a reclaimed or retired fort starts with no burrow at all: when plotinfo.burrows.list is empty and the record ' ..
       'survived, the kernel asks (DECISION_NEEDED burrow_gone) instead of painting an old layout', function()
  local W = fort()
  local list = df.global.plotinfo.burrows.list
  local keep = {}
  for i = 0, #list - 1 do keep[#keep + 1] = list[i] end
  W.gone['Kern+'], W.gone['Tiefe+'] = true, true
  -- the list itself is empty (as a fresh plotinfo)
  df.global.plotinfo.burrows.list = require('dfllm.util.k_mock').vec{}
  day(W)
  local e = evs(W, 'BURROW_SHRUNK')
  T.ok(#e >= 1 and e[1].d.fix == 'ask', T.show(e[1] and e[1].d))
  local q = evs(W, 'DECISION_NEEDED')
  T.ok(#q >= 1 and q[1].d.q:find('a reclaimed fort?', 1, true), q[1] and q[1].d.q)
  T.eq(#repaints(W, 'Kern+') + #repaints(W, 'Tiefe+'), 0, 'nothing painted')
  T.eq(W.state().alert.bg.st, 'list empty')
end)

---------------------------------------------------------------- the daily cap
T.test('BUG-097: the repair stops at burrow.guard.repair_per_day: 40 tiles a game day, the 112 lost tiles are back on the third ' ..
       'day, one BURROW_SHRUNK, three BURROW_REPAIRED (the last done)', function()
  local W = fort{cfg = {repair_per_day = 40}}
  W.burrow('Kern+', {7, 7, Z, 9, 9, Z})
  day(W)
  T.eq(kern_n(W), 49)
  local bg = W.state().alert.bg
  T.eq({bg.n, bg.b, bg.was, bg.now, bg.fx, bg.st}, {1, 'Kern+', 121, 9, 40, 'repairing'})
  day(W)
  T.eq(kern_n(W), 89)
  day(W)
  T.eq(kern_n(W), 121)
  local rp = evs(W, 'BURROW_REPAIRED')
  T.eq({#rp, rp[1].d.n, rp[2].d.n, rp[3].d.n, rp[1].d.done, rp[3].d.done}, {3, 40, 40, 32, 0, 1})
  T.eq(#evs(W, 'BURROW_SHRUNK'), 1, 'once per episode')
  for _, a in ipairs(repaints(W, 'Kern+')) do T.ok(#a.args[2] <= 40) end
  T.eq(W.state().alert.bg, nil)
end)

T.test('BUG-097: repair_per_day 0 is a sensor only: the loss is announced (fix off), nothing is painted, the episode shows in ' ..
       'the state and ends when the burrow is back above the line', function()
  local W = fort{cfg = {repair_per_day = 0}}
  W.burrow('Kern+', {7, 7, Z, 9, 9, Z})
  day(W, 2)
  local e = evs(W, 'BURROW_SHRUNK')
  T.eq({#e, e[1].d.fix}, {1, 'off'})
  T.eq(#repaints(W, 'Kern+'), 0)
  T.eq(#evs(W, 'DECISION_NEEDED'), 0, 'switched off by the player: no question')
  T.eq(W.state().alert.bg.st, 'repair off')
  W.burrow('Kern+', {5, 5, Z, 15, 15, Z})               -- the player paints it back
  day(W)
  T.eq(W.state().alert.bg, nil)
  T.eq(W.K.persist.get('burrows').b['Kern+'].base, 121)
end)

T.test('FR-80: burrow.guard.on false switches the guard off: no reading, no record; shrink_pct is the knob (50 %: a drop of 40 % ' ..
       'is no shrink); a bad value keeps the default', function()
  local W = fort{cfg = {on = false}}
  W.burrow('Kern+', {7, 7, Z, 9, 9, Z})
  day(W)
  T.eq({#evs(W, 'BURROW_SHRUNK'), W.K.persist.get('burrows')}, {0, nil})
  local W2 = fort{cfg = {shrink_pct = 50}}
  W2.burrow('Kern+', {5, 5, Z, 15, 11, Z})              -- 77 of 121 (-36 %)
  day(W2)
  T.eq(#evs(W2, 'BURROW_SHRUNK'), 0)
  local W3 = fort{cfg = {shrink_pct = 'lots', repair_per_day = -5}}
  W3.burrow('Kern+', {5, 5, Z, 15, 11, Z})
  day(W3)
  T.eq(#evs(W3, 'BURROW_SHRUNK'), 1, 'default 30 %')
  T.eq(evs(W3, 'BURROW_SHRUNK')[1].d.rep, 2000)
end)

---------------------------------------------------------------- what the kernel does not touch
T.test('FR-80: a burrow of the player (not Kern+, not the refuge) that shrinks or vanishes is neither announced nor painted; ' ..
       'Kern+ in the same fort is', function()
  local W = fort()
  W.burrow('Farmers', {1, 1, Z, 9, 9, Z})
  day(W)
  W.burrow('Farmers', {1, 1, Z, 1, 1, Z})
  day(W)
  W.gone.Farmers = true
  day(W)
  T.eq(#evs(W, 'BURROW_SHRUNK'), 0)
  T.eq(#repaints(W, 'Farmers'), 0)
  W.burrow('Kern+', {7, 7, Z, 9, 9, Z})
  day(W)
  local e = evs(W, 'BURROW_SHRUNK')
  T.eq({#e, e[1].d.burrow}, {1, 'Kern+'})
  T.eq(#repaints(W, 'Farmers'), 0)
end)

T.test('BUG-097: a hidden tile of the last reading is never painted (fair play: no tile the screen could not paint); what is ' ..
       'left out is said', function()
  local W = fort()
  SW.draw(W, Z, {'?'}, 10, 10)                           -- hidden floor inside the hall
  W.burrow('Kern+', {7, 7, Z, 9, 9, Z})
  day(W)
  local a = repaints(W, 'Kern+')
  T.eq(#a, 1)
  T.eq(#a[1].args[2], 111)
  for _, p in ipairs(a[1].args[2]) do T.ok(not (p[1] == 10 and p[2] == 10), 'the hidden tile stays out') end
  T.ok(logged(W, '1 hidden left out'), 'kern.log')
  T.eq(W.state().alert.bg, nil, 'the episode ends: nothing else to paint')
  T.ok(logged(W, 'episode over (partial)'), 'accepted as the new baseline')
end)

---------------------------------------------------------------- modes
T.test('BUG-097: in SIEGE the loss is announced (fix wait) and nothing is painted; once the fort is quiet the next daily pass ' ..
       'repairs it (a tile added in a fight may lie outside the walls)', function()
  local W = fort()
  W.set_mode('SIEGE')
  W.burrow('Kern+', {7, 7, Z, 9, 9, Z})
  day(W, 2)
  local e = evs(W, 'BURROW_SHRUNK')
  T.eq({#e, e[1].d.fix}, {1, 'wait'})
  T.ok(e[1].msg:find('repair waits for peace (SIEGE)', 1, true), e[1].msg)
  T.eq(#repaints(W, 'Kern+'), 0, 'no repaint in a siege')
  T.eq(W.state().alert.bg.st, 'waits for peace')
  W.set_mode('BREACH')
  day(W)
  T.eq(#repaints(W, 'Kern+'), 0, 'none in a breach either')
  W.set_mode('PEACE')
  day(W)
  T.eq(kern_n(W), 121)
  T.eq(#evs(W, 'BURROW_SHRUNK'), 1, 'still one announcement')
  T.eq(repaints(W, 'Kern+')[1].mode, 'PEACE')
  -- ALERT and RECOVERY: ALERT waits (a hostile is about), RECOVERY paints
  local W2 = fort()
  W2.set_mode('ALERT')
  W2.burrow('Kern+', {7, 7, Z, 9, 9, Z})
  day(W2)
  T.eq(#repaints(W2, 'Kern+'), 0)
  W2.set_mode('RECOVERY')
  day(W2)
  T.eq(kern_n(W2), 121)
end)

T.test('BUG-097: a fight longer than settle_days (14) does not run the settle clock out: the loss is not accepted as the new ' ..
       'baseline while the repair only waits for peace; a repair that cannot progress for settle_days is accepted (repair off)',
       function()
  local W = fort()
  W.set_mode('SIEGE')
  W.burrow('Kern+', {7, 7, Z, 9, 9, Z})
  day(W, 17)
  T.eq(W.state().alert.bg.st, 'waits for peace')
  T.eq(W.K.persist.get('burrows').b['Kern+'].base, 121, 'the baseline stands')
  W.set_mode('PEACE')
  day(W)
  T.eq(kern_n(W), 121)
  -- repair off: nothing can progress; after settle_days the loss is the new baseline and the episode ends
  local W2 = fort{cfg = {repair_per_day = 0, settle_days = 3}}
  W2.burrow('Kern+', {7, 7, Z, 9, 9, Z})
  day(W2, 2)
  T.ok(W2.state().alert.bg, 'still open')
  day(W2, 3)
  T.eq(W2.state().alert.bg, nil)
  T.eq(W2.K.persist.get('burrows').b['Kern+'].base, 9)
  T.ok(logged(W2, 'episode over (settled)'), 'kern.log')
  T.eq(#evs(W2, 'BURROW_SHRUNK'), 1, 'and not announced again')
end)

---------------------------------------------------------------- a small fort
T.test('FR-80: a fort of 7 citizens: Kern+ of 60 tiles loses 48: announced and repaired like any other; the cap, the shares and the ' ..
       'runs hold at that size', function()
  local W = fort{citizens = 7, kern = {5, 5, Z, 10, 14, Z}}          -- 6 x 10 = 60
  T.eq(W.K.persist.get('burrows').b['Kern+'].base, 60)
  W.burrow('Kern+', {5, 5, Z, 7, 8, Z})                              -- 12 left
  day(W)
  local e = evs(W, 'BURROW_SHRUNK')
  T.eq({#e, e[1].d.was, e[1].d.now, e[1].d.pct, e[1].d.fix}, {1, 60, 12, 80, 'repair'})
  T.eq(count('Kern+', Z, 0, 0, 40, 30), 60)
  T.eq(#W.faults, 0)
  -- readiness is not loaded here; the public view of the guard is empty afterwards
  local ok, bg = W.K.call('seal', 'burrow_guard')
  T.eq({ok, #bg}, {true, 0})
end)

---------------------------------------------------------------- the announcement
T.test('BUG-008 cadence (BURROW_SHRUNK): the first announcement of an episode goes out at once; the same episode is not repeated ' ..
       'on the next days; news (the lost tiles held a well) is a second one', function()
  local water = {name = 'water', every = {ticks = 100000}}
  water.src = {}
  function water.state(K) return {water = {patients = 0, thirst_max = 0, hosp_ok = 1, refuge_ok = 1, buckets_free = 0, hosp = 0,
                                           src = water.src, hosp_out = 0}} end
  function water.hospital_out(K) return {n = 0, total = 0, zones = {}} end
  local W = fort{cfg = {repair_per_day = 0}, mods = {water}}
  W.burrow('Kern+', {7, 7, Z, 9, 9, Z})
  day(W, 3)
  T.eq(#evs(W, 'BURROW_SHRUNK'), 1)
  -- a well at 12,12 lay on the burrow at the last good reading: the news
  water.src[1] = {12, 12, Z}
  W.ms = W.ms + 700000
  day(W, 2)
  local e = evs(W, 'BURROW_SHRUNK')
  T.eq(#e, 2)
  T.eq(e[2].d.crit, {'well'})
  T.ok(e[2].msg:find('it held a well', 1, true), e[2].msg)
  W.ms = W.ms + 700000
  day(W, 2)
  T.eq(#evs(W, 'BURROW_SHRUNK'), 2, 'nothing new: no third')
  -- the guard's public view for readiness
  local ok, bg = W.K.call('seal', 'burrow_guard')
  T.eq({ok, #bg, bg[1].name, bg[1].was, bg[1].now, bg[1].crit}, {true, 1, 'Kern+', 121, 9, {'well'}})
end)

---------------------------------------------------------------- the order of the repair
T.test('BUG-097: the repair starts with the runs next to the hospital that lies outside the burrow and the wells (water): with a ' ..
       'cap of 11 tiles the corridor around the hospital comes before the hall; crit lists the hospital and the well', function()
  local water = {name = 'water', every = {ticks = 100000}}
  function water.state(K)
    return {water = {patients = 0, thirst_max = 0, hosp_ok = 1, refuge_ok = 1, buckets_free = 0, hosp = 1,
                     src = {{30, 20, Z}}, hosp_out = 1}}
  end
  function water.hospital_out(K)
    return {n = 1, total = 1, zones = {{id = 5, loc = 1, x = 30, y = 20, z = Z, tiles = 11, of = 11}}}
  end
  local W = fort{cfg = {repair_per_day = 11}, mods = {water}}
  local b = dfhack.burrows.findByName('Kern+')
  b._tiles = {}
  for x = 25, 35 do b._tiles[SW.key(x, 20, Z)] = true end     -- the corridor to the hospital is Kern+ too
  day(W)                                                      -- baseline 132
  T.eq(W.K.persist.get('burrows').b['Kern+'].base, 132)
  b._bbox, b._tiles = {5, 5, Z, 5, 5, Z}, {}                  -- 1 tile left
  W.state()
  day(W)
  local e = evs(W, 'BURROW_SHRUNK')
  T.eq(#e, 1)
  T.eq(e[1].d.crit, {'well', 'hospital'})
  local a = repaints(W, 'Kern+')
  T.eq(#a, 1)
  local tiles = a[1].args[2]
  T.eq(#tiles, 11)
  for _, p in ipairs(tiles) do T.eq({p[2], p[3]}, {20, Z}, 'the corridor first') end
end)

---------------------------------------------------------------- cost and size
T.test('FR-80: the cost is bounded in real time: at most one reading a game day and one every burrow.guard.every_s (120) real ' ..
       'seconds, whichever is later (a game day lasts 2-12 s at the speeds of the runs); a quiet burrow writes no log line; ' ..
       'the record of a big fort stays within the persist budget (some thousand runs, about 14 bytes each)', function()
  local W = fort()
  local t0 = W.K.persist.get('burrows').b['Kern+'].t
  for _ = 1, 10 do W.run(1300, {skip = 9}) end                 -- ten game days, 23 s of wall clock: no second reading
  T.eq(W.K.persist.get('burrows').b['Kern+'].t, t0)
  W.ms = W.ms + 130000
  W.run(1300, {skip = 9})
  T.ok(W.K.persist.get('burrows').b['Kern+'].t > t0, 'a game day and 120 s later: read again')
  -- every_s is the knob, and the game day is the other gate
  local W2 = fort{cfg = {every_s = 10}}
  local u0 = W2.K.persist.get('burrows').b['Kern+'].t
  W2.ms = W2.ms + 11000
  W2.run(400, {skip = 9})
  local u1 = W2.K.persist.get('burrows').b['Kern+'].t
  T.ok(u1 > u0, 'ten seconds are enough when the game day has passed')
  W2.ms = W2.ms + 11000
  W2.run(300, {skip = 9})
  T.eq(W2.K.persist.get('burrows').b['Kern+'].t, u1, 'the seconds have passed, the game day (1,200 ticks) has not')
  W2.run(1100, {skip = 9})
  T.ok(W2.K.persist.get('burrows').b['Kern+'].t > u1, 'and now it has')
  local n = 0
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('burrow', 1, true) then n = n + 1 end end
  T.eq(n, 0, 'a quiet burrow writes no log line')
  T.ok(W.mods.seal.M.CFG.bg_runs == 8000 and W.mods.seal.M.CFG.bg_block == 256)
  -- 4,000 one-tile rows (a worst case: nothing merges) encode to about 56 KB
  local BK = require('dfllm.burrowkeep')
  local rows = {}
  for i = 0, 3999 do rows[#rows + 1] = {100 + i % 40, 20 + (i // 40) * 2, 10 + (i % 7) * 3, 10 + (i % 7) * 3} end
  local flat, tiles, runs, part = BK.pack(rows, 8000)
  T.eq({tiles, runs, part}, {4000, 4000, false})
  local bytes = #json.encode({k = flat})
  T.ok(bytes < 70000, bytes)
  local flat2, _, runs2, part2 = BK.pack(rows, 100)
  T.eq({#flat2, runs2, part2}, {400, 4000, true}, 'more than the cap: the first runs, flagged')
end)

T.done()
