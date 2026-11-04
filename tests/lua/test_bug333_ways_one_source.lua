-- BUG-333 (Run 15d Drillchamber y377 spr d4): status named '3 ways in without door or bridge: 12,170,146 sapling,
-- 14,170,146 sapling, 11,169,146 sapling', `inspect what=entrances key=refresh` named 'opening 120,126,144 floor no door'
-- in its openings: status, SIEGE_UNREADY and seal at=last read seal.entrance_doors' open tiles, the inspect answer only
-- the openings' nearest tiles. Now the inspect answer carries `ways`, the open tiles as status names them.
local T = require('testlib')
local SW = require('seal_world')
local S = require('siege_world')

local Z = 5

-- test_lockdown.lua's fort: an open field on z 6, the fort on z 5 with a door behind the stair at 20,10 and a shaft
-- (up/down stair) at 30,13 without a door: one way in without door or bridge
local function fort()
  local W = SW.new{persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}}}}
  W.ms_per_frame = 100
  SW.fill(W, Z + 1, 0, 0, 40, 24, ',')
  SW.draw(W, Z + 1, {'>'}, 20, 10, {outside = true})
  SW.draw(W, Z + 1, {'X'}, 30, 13, {outside = true})
  SW.fill(W, Z, 0, 0, 40, 24, '#')
  SW.fill(W, Z, 2, 4, 12, 16, '.')
  SW.fill(W, Z, 13, 10, 18, 10, '.')
  SW.draw(W, Z, {'+<'}, 19, 10)
  SW.fill(W, Z, 13, 13, 29, 13, '.')
  SW.draw(W, Z, {'X'}, 30, 13)
  SW.regroup(W)
  for _, c in ipairs({{1, 5, 8}, {2, 6, 9}, {3, 7, 10}, {4, 8, 11}}) do
    W.add_unit{id = c[1], pos = {c[2], c[3], Z}, citizen = true, adult = true}
  end
  W.burrow('Kern+', {2, 4, Z, 12, 16, Z})
  W.paint_fn = W.act_results.burrow_tiles
  local snap = {name = 'snapshot', every = {ticks = 100}}
  snap.outside_near = require('dfllm.snapshot').outside_near
  function snap.far() return false end
  snap.units_at = require('dfllm.snapshot').units_at
  function snap.items_at() return {} end
  for _, n in ipairs({'reflex', 'seal'}) do package.loaded['dfllm.' .. n] = nil end
  S.load(W, {S.military(), snap, require('dfllm.reflex'), require('dfllm.seal')})
  W.run(3000, {skip = 9})
  return W
end

T.test('inspect entrances names the ways in as entrance_doors (status, seal at=last) does', function()
  local W = fort()
  local r = W.inbox('inspect', {what = 'entrances', key = 'refresh'})
  local _, x = W.K.call('seal', 'entrance_doors')
  local want = {}
  for _, o in ipairs(x.open) do want[#want + 1] = string.format('%d,%d,%d %s', o.pos[1], o.pos[2], o.pos[3], o.kind) end
  T.eq(want, {'30,13,5 stair_updown'})
  T.eq(r.data.ways, want, 'one source: the ways of the inspect answer are the open tiles of entrance_doors')
  T.ok(r.msg:find('ways in as status names them: 30,13,5 stair_updown', 1, true), r.msg)
end)

T.done()
