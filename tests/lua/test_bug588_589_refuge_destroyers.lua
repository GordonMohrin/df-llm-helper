-- BUG-588 / BUG-589, the seal half (Run 16c i3 Sealcertain y422 summer: two cave dragons toppled B2, one sat at the refuge's stair foot
-- 62,127,136 on and off; REFUGE_SWITCH Tiefe+ -> Innen+ ('breached') and Innen+ -> Tiefe+ ('deeper') ten times in a row, each walk met the
-- dragon; the plug was queued with the BREACH, when a dragon stood on the stair; the run ended with 'no confinement, citizens flee').
-- The world of test_bug479_refuge_plug.lua (Kern+ hall, the civilians' stair at 6,6 from z9 down to the dead end Tiefe+ at z5, the hatch on
-- the head, a runner stand-in), plus a second separated room Innen+ far from the stair in the siege traffic tests:
--   (1) a hostile seen in the refuge keeps it refused for seal.RLATCH ticks after the last sighting (old: the next census without it sent the
--       citizens back, ten REFUGE_SWITCH 'deeper' in a row); then the refuge is the BREACH pick again;
--   (2) the plug: destroyers in sight far away and every citizen already inside Tiefe+ -> the foot is walled at once (REFUGE_PLUG early=1;
--       old: 'wait:destroyers far' until a BREACH); one citizen still outside -> it still waits;
--   (3) destroyers at the stair head, only a hatch on it, no wall yet: Innen+ (separated, hostile-free, 19 tiles farther from them than the
--       stair head) is the confinement, not the refuge; with the wall plug standing the refuge is chosen again;
--   (4) BREACH, the refuge latched, Kern+ separated but without drink: Kern+ holds them (level AREA), no 'citizens flee' (old: nil, flee);
--       a burrow the citizens went thirsty in is not used for it; a quiet SIEGE with no drink anywhere is still 'no confinement' (BUG-031);
--   (5) refuge_closure: a bridge on the head is 'soft' like a hatch.
local T = require('testlib')
local SW = require('seal_world')

local Z = 9
local INSIDE = {{1, 8, 8, Z - 4}, {2, 8, 7, Z - 4}, {3, 8, 6, Z - 4}}   -- the citizens already in the refuge room
local function fort(o)
  o = o or {}
  local W = SW.new{persist = {['m.seal'] = nil, manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
                                            refuge = {anchor = {5, 5, Z - 4}, burrow = 'Tiefe+'},
                                            stairs = {civ = {{6, 6, Z - 4, Z}}}}}}
  SW.fill(W, Z + 1, 0, 0, 40, 30, ',')
  SW.draw(W, Z + 1, {'>'}, 20, 10, {outside = true})
  SW.fill(W, Z, 0, 0, 40, 30, '#')
  SW.fill(W, Z, 5, 5, 15, 15, '.')
  SW.fill(W, Z, 16, 10, 19, 10, '.')
  SW.draw(W, Z, {'<'}, 20, 10)
  SW.draw(W, Z, {'+'}, 19, 10)
  SW.draw(W, Z, {'bb'}, 12, 12)
  if o.room then                                   -- Innen+: a room x25-35 y5-12 behind a corridor from the hall (y 8)
    SW.fill(W, Z, 16, 8, 24, 8, '.')
    SW.fill(W, Z, 25, 5, 35, 12, '.')
    SW.draw(W, Z, {'bb'}, 30, 8)
  end
  SW.draw(W, Z, {'>'}, 6, 6)
  for z = Z - 3, Z - 1 do
    SW.fill(W, z, 0, 0, 40, 30, '#')
    SW.draw(W, z, {'X'}, 6, 6)
  end
  SW.fill(W, Z - 4, 0, 0, 40, 30, '#')
  SW.fill(W, Z - 4, 5, 5, 8, 8, '.')
  SW.draw(W, Z - 4, {'<'}, 6, 6)
  SW.regroup(W)
  SW.citizens(W, o.cits or INSIDE)
  SW.item(W, 'DRINK', 9, 13, Z, 20)
  SW.item(W, 'PLANT', 9, 14, Z, 20)
  if o.stock then                                  -- the refuge holds its own drink and food (the WET level of a BREACH)
    SW.item(W, 'DRINK', 7, 7, Z - 4, 20)
    SW.item(W, 'PLANT', 7, 8, Z - 4, 20)
  end
  W.burrow('Kern+', {5, 5, Z, 15, 15, Z})
  W.burrow('Tiefe+', {5, 5, Z - 4, 8, 8, Z - 4})
  if o.room then W.burrow('Innen+', {25, 5, Z, 35, 12, Z}) end
  local repairs = {}
  W.cancelled = {}
  W.pstate = function() return {done = false} end
  W.load(SW.fake('runner', {repair = function(K, cells, why) repairs[#repairs + 1] = {cells = cells, why = why}; return true, 'rp' .. #repairs end,
                            plug_proj = function(K, id) return W.pstate(id) end,
                            cancel_proj = function(K, id) W.cancelled[#W.cancelled + 1] = id; return true end}))
  package.loaded['dfllm.seal'] = nil
  local M = require('dfllm.seal')
  M.PLUG.every = 0
  M.PLUG.pre = false                              -- BUG-651: the round-39 fallback of a fort without a pre-plug
  W.load(M)
  W.run(2400, {skip = 9})
  return W, M, repairs
end

local function hatch(W)
  local h = SW.building(W, 'DOOR', 'Hatch', 6, 6, Z - 3)
  W.dyn[SW.key(6, 6, Z - 3)] = h
  W.tiles[SW.key(6, 6, Z - 3)].occ.building = df.tile_building_occ.Dynamic
end

-- census: list entries {x, y, z, bd = 1}; bd counts the building destroyers as sense does (census.h.bd)
local function census(W, list)
  local l, nbd = {}, 0
  for i, e in ipairs(list) do
    l[i] = {id = 500 + i, x = e[1], y = e[2], z = e[3], bd = e.bd or 0}
    nbd = nbd + (e.bd or 0)
  end
  W.set_census('h', {tick = W.K.now().tick, vis = #l, armed = 1, inside = 0, bd = nbd, list = l})
end

local function refresh(W)
  local r = W.inbox('inspect', {what = 'refuge', key = 'refresh'})
  T.ok(r.ok, r.msg)
  W.run(1200, {skip = 9})
end

local function ask(W, mode, want, cur)
  local ok, pick, note, short, flee = W.K.call('seal', 'alert_burrow', mode, want, false, cur)
  T.ok(ok, tostring(pick))
  return pick, flee, note
end

local function switches(W, why)
  local n = 0
  for _, e in ipairs(W.find_events('REFUGE_SWITCH')) do if e.d.why == why then n = n + 1 end end
  return n
end

local AT_FOOT = {6, 6, Z - 4}                          -- the dragon on the stair foot

T.test('BUG-588 (1): a hostile seen in the refuge keeps it refused for RLATCH ticks: the census without it sends nobody back (old: REFUGE_SWITCH ' ..
       "'deeper' to Tiefe+ at once, ten times in a row), after RLATCH ticks it is the BREACH pick again", function()
  local W, M = fort{stock = true}
  hatch(W)
  refresh(W)
  W.set_mode('BREACH')
  census(W, {})
  local pick, _, note0 = ask(W, 'BREACH', 'Tiefe+')
  T.eq(pick, 'Tiefe+', 'no hostile: the refuge ' .. tostring(note0) .. T.show(W.inbox('inspect', {what = 'refuge'}).data.choice))
  census(W, {AT_FOOT})
  pick = ask(W, 'BREACH', 'Tiefe+')
  T.eq(pick, 'Kern+', 'the hostile inside: Kern+')
  for _ = 1, 8 do                                  -- the dragon walks out of sight and back, the alert asks every few ticks
    census(W, {})
    W.run(100, {skip = 9})
    pick = ask(W, 'BREACH', 'Tiefe+', 'Kern+')
    T.eq(pick, 'Kern+', 'out of sight is not gone')
    census(W, {AT_FOOT})
    W.run(30, {skip = 9})
    ask(W, 'BREACH', 'Tiefe+', 'Kern+')
  end
  T.eq(switches(W, 'deeper'), 0, 'no walk back to the refuge')
  census(W, {})                                    -- (the dragon is gone from the census for good)
  W.run(M.RLATCH + 50, {skip = 9})
  census(W, {})
  local note1
  pick, _, note1 = ask(W, 'BREACH', 'Tiefe+', 'Kern+')
  T.eq(pick, 'Tiefe+', 'RLATCH ticks without a sighting: the refuge again ' .. tostring(note1) .. tostring(M.rlatched(W.K) and M.rlatched(W.K).t) .. ' now ' .. W.K.now().tick)
  T.eq(switches(W, 'deeper'), 1)
  -- in PEACE the latch is no rule
  W.set_mode('PEACE')
  census(W, {AT_FOOT})
  ask(W, 'ALERT', 'Kern+')
  census(W, {})
  T.eq(M.rlatched(W.K), nil, 'the latch is a fight rule only')
end)

T.test('BUG-589 (2): destroyers in sight far away and every citizen already inside Tiefe+: the foot is walled at once (REFUGE_PLUG early; old: wait:destroyers far ' ..
       'until the BREACH); a citizen still outside: it waits', function()
  local W, M, repairs = fort()
  hatch(W)
  refresh(W)
  W.set_mode('SIEGE')
  census(W, {{6, 60, Z, bd = 1}})                  -- 54 tiles from the stair head
  local _, st = W.K.call('seal', 'plug', {bd = true})
  T.eq(st, 'queued', 'walled at once')
  T.eq(#repairs, 1)
  local ev = W.find_events('REFUGE_PLUG')
  T.eq({#ev, ev[1].d.early, ev[1].d.breach}, {1, 1, 0})
  -- one citizen in the hall: not yet
  local W2, _, repairs2 = fort{cits = {{1, 8, 8, Z - 4}, {2, 8, 7, Z - 4}, {3, 10, 9, Z}}}
  hatch(W2)
  refresh(W2)
  W2.set_mode('SIEGE')
  census(W2, {{6, 60, Z, bd = 1}})
  T.eq(select(2, W2.K.call('seal', 'plug', {bd = true})), 'wait:destroyers far')
  T.eq(#repairs2, 0)
  -- the same fort, no destroyer in sight: nothing
  local W3, _, repairs3 = fort()
  hatch(W3)
  refresh(W3)
  W3.set_mode('SIEGE')
  census(W3, {{6, 60, Z, bd = 0}})
  T.eq(select(2, W3.K.call('seal', 'plug', {bd = true})), 'wait:destroyers far')
  T.eq(#repairs3, 0)
end)

T.test('BUG-589 (3): destroyers at the refuge stair head, only a hatch on it, no wall yet: the separated room Innen+ far from them is the confinement ' ..
       '(old: the refuge at the BREACH level, the dragons broke the hatch); once the wall plug stands the refuge is chosen again', function()
  local W, M, repairs = fort{room = true, stock = true}
  hatch(W)
  refresh(W)
  W.set_mode('BREACH')
  census(W, {})
  T.eq(ask(W, 'BREACH', 'Tiefe+'), 'Tiefe+', 'no destroyer: the refuge')
  census(W, {{6, 6, Z - 2, bd = 1}})               -- on the stair column, 2 tiles above the foot
  local pick, flee, note = ask(W, 'BREACH', 'Tiefe+')
  T.eq({pick, flee}, {'Innen+', false}, 'old: Tiefe+')
  T.ok(tostring(note):find('Innen+ lies 19 tiles from them', 1, true), tostring(note))
  -- the wall plug is queued (a BREACH is the last responsible moment): the refuge is the pick again
  local _, st = W.K.call('seal', 'plug', {bd = true})
  T.eq(st, 'queued')
  W.pstate = function() return {done = true} end      -- BUG-595: a queued plug is no wall yet, the finished one is
  pick = ask(W, 'BREACH', 'Tiefe+')
  T.eq(pick, 'Tiefe+', 'the foot is walled: a hatch broken, the wall stays')
end)

local function kern_dry(W)
  local v = df.global.world.items.other.DRINK
  for i = 0, #v - 1 do v[i]._pos = {2, 2, Z + 1} end     -- the drink onto the surface, outside every burrow
  refresh(W)
end

T.test('BUG-588 (4): BREACH, the refuge latched (a dragon at the stair foot), Kern+ separated and hostile-free but without drink: Kern+ holds them whatever ' ..
       'it lacks (old: no confinement, the citizens flee through the fort); a quiet SIEGE with no drink anywhere is still no confinement (BUG-031)', function()
  local W, M = fort{cits = {{1, 9, 9, Z}, {2, 10, 9, Z}, {3, 11, 9, Z}}}
  hatch(W)
  kern_dry(W)
  W.set_mode('BREACH')
  census(W, {AT_FOOT})
  local pick, flee, note = ask(W, 'BREACH', 'Tiefe+')
  T.eq({pick, flee}, {'Kern+', false}, 'old: ' .. tostring(note))
  T.ok(tostring(note):find('Kern+', 1, true), tostring(note))
  -- a quiet SIEGE, no hostile, no drink in Kern+ and none in the refuge: the citizens fetch it (the old rule stays)
  local W2 = fort{cits = {{1, 9, 9, Z}, {2, 10, 9, Z}, {3, 11, 9, Z}}}
  hatch(W2)
  kern_dry(W2)
  W2.set_mode('SIEGE')
  census(W2, {})
  local p2, f2 = ask(W2, 'SIEGE', 'Kern+')
  T.ok(p2 == nil or p2 == 'Tiefe+', 'no AREA pick in a quiet siege: ' .. tostring(p2))
end)

T.test('BUG-589 (5): a raised bridge on the refuge stair head is a building the destroyers break: refuge_closure soft, like a hatch', function()
  local W = fort()
  hatch(W)
  refresh(W)
  census(W, {{30, 20, Z + 1, bd = 1}})
  local _, kind = W.K.call('seal', 'refuge_closure')
  T.eq(kind, 'soft')
  SW.draw(W, Z - 3, {'H'}, 6, 6)
  refresh(W)
  census(W, {{30, 20, Z + 1, bd = 1}})
  _, kind = W.K.call('seal', 'refuge_closure')
  T.eq(kind, 'soft', 'old: hard')
  T.eq(W.state().alert.ref.sf, 1)
end)

T.done()
