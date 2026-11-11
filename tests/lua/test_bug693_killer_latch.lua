-- BUG-693 (Run 16d i4 Trumpetrealms y461 winter: one goblin killed 27 citizens in a day in the refuge shaft, left the census for ~1,200 ticks,
-- seal.RLATCH ran out and 'Innen+ -> Tiefe+ (WET)' walked the survivors back into it; Kern+ and Innen+ had no latch at all): a hostile that
-- KILLED is latched in every burrow it stood in for seal.KLATCH ticks after its last sighting, in a SIEGE / BREACH. The world of
-- test_bug588_589_refuge_destroyers.lua (Kern+ hall, the stair at 6,6 down to the dead end Tiefe+, Innen+ behind a corridor).
local T = require('testlib')
local SW = require('seal_world')

local Z = 9
local INSIDE = {{1, 8, 8, Z - 4}, {2, 8, 7, Z - 4}, {3, 8, 6, Z - 4}}
local function fort()
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
  SW.draw(W, Z, {'>'}, 6, 6)
  for z = Z - 3, Z - 1 do
    SW.fill(W, z, 0, 0, 40, 30, '#')
    SW.draw(W, z, {'X'}, 6, 6)
  end
  SW.fill(W, Z - 4, 0, 0, 40, 30, '#')
  SW.fill(W, Z - 4, 5, 5, 8, 8, '.')
  SW.draw(W, Z - 4, {'<'}, 6, 6)
  SW.regroup(W)
  SW.citizens(W, INSIDE)
  SW.item(W, 'DRINK', 9, 13, Z, 20)
  SW.item(W, 'PLANT', 9, 14, Z, 20)
  SW.item(W, 'DRINK', 7, 7, Z - 4, 20)
  SW.item(W, 'PLANT', 7, 8, Z - 4, 20)
  W.burrow('Kern+', {5, 5, Z, 15, 15, Z})
  W.burrow('Tiefe+', {5, 5, Z - 4, 8, 8, Z - 4})
  W.cancelled = {}
  W.pstate = function() return {done = false} end
  W.load(SW.fake('runner', {repair = function(K, cells, why) return true, 'rp1' end,
                            plug_proj = function(K, id) return W.pstate(id) end,
                            cancel_proj = function(K, id) return true end}))
  package.loaded['dfllm.seal'] = nil
  local M = require('dfllm.seal')
  M.PLUG.every = 0
  M.PLUG.pre = false
  W.load(M)
  W.run(2400, {skip = 9})
  return W, M
end
local function census(W, list)
  local l = {}
  for i, e in ipairs(list) do l[i] = {id = 500 + i, x = e[1], y = e[2], z = e[3], bd = 0, kl = e.kl} end
  W.set_census('h', {tick = W.K.now().tick, vis = #l, armed = 1, inside = 0, bd = 0, list = l})
end
local function ask(W, mode, want, cur)
  local ok, pick, note, short, flee = W.K.call('seal', 'alert_burrow', mode, want, false, cur)
  T.ok(ok, tostring(pick))
  return pick, flee, note
end
local AT_FOOT = {6, 6, Z - 4}
local function hatch(W)
  local h = SW.building(W, 'DOOR', 'Hatch', 6, 6, Z - 3)
  W.dyn[SW.key(6, 6, Z - 3)] = h
  W.tiles[SW.key(6, 6, Z - 3)].occ.building = df.tile_building_occ.Dynamic
end

T.test('BUG-693: a hostile that killed and stood in the refuge keeps it refused for KLATCH ticks (old: RLATCH, 1,200, then the citizens were walked back); one that never killed keeps RLATCH', function()
  local W, M = fort()
  hatch(W)
  local h = W.inbox('inspect', {what = 'refuge', key = 'refresh'})
  T.ok(h.ok, h.msg)
  W.run(1200, {skip = 9})
  W.set_mode('BREACH')
  census(W, {})
  T.eq(ask(W, 'BREACH', 'Tiefe+'), 'Tiefe+', 'no hostile: the refuge')
  census(W, {{AT_FOOT[1], AT_FOOT[2], AT_FOOT[3], kl = 1}})
  local pick = ask(W, 'BREACH', 'Tiefe+')
  T.ok(pick ~= 'Tiefe+', 'the killer inside: not the refuge: ' .. tostring(pick))
  census(W, {})                                    -- out of sight
  W.run(M.RLATCH + 50, {skip = 9})
  census(W, {})
  pick = ask(W, 'BREACH', 'Tiefe+', pick)
  T.ok(pick ~= 'Tiefe+', 'RLATCH ticks later the killer still holds it (old: Tiefe+ again): ' .. tostring(pick))
  T.ok(M.rlatched(W.K, 'Tiefe+') ~= nil)
  W.run(M.KLATCH, {skip = 9})
  census(W, {})
  pick = ask(W, 'BREACH', 'Tiefe+', pick)
  T.eq(pick, 'Tiefe+', 'KLATCH ticks without a sighting: the refuge again')
  -- in PEACE no rule
  W.set_mode('PEACE')
  T.eq(M.rlatched(W.K, 'Tiefe+'), nil)
end)

T.test('BUG-693: a killer seen in Kern+ latches Kern+ too (old: only the refuge was latched); a hostile that never killed latches the refuge only', function()
  local W, M = fort()
  hatch(W)
  local h = W.inbox('inspect', {what = 'refuge', key = 'refresh'})
  T.ok(h.ok, h.msg)
  W.run(1200, {skip = 9})
  W.set_mode('BREACH')
  census(W, {{10, 10, Z, kl = 1}})
  ask(W, 'BREACH', 'Tiefe+')                       -- (the pick passes at Tiefe+: Kern+ is not rated, the latch still forms)
  census(W, {})
  W.run(100, {skip = 9})
  T.ok(M.rlatched(W.K, 'Kern+') ~= nil, 'Kern+ is latched after the killer stood in it')
  local W2, M2 = fort()
  hatch(W2)
  W2.inbox('inspect', {what = 'refuge', key = 'refresh'})
  W2.run(1200, {skip = 9})
  W2.set_mode('BREACH')
  census(W2, {{10, 10, Z}})
  ask(W2, 'BREACH', 'Tiefe+')
  census(W2, {})
  W2.run(100, {skip = 9})
  T.eq(M2.rlatched(W2.K, 'Kern+'), nil, 'no kill, no Kern+ latch')
end)

T.done()
