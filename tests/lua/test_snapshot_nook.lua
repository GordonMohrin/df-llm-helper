-- snapshot, package L1 (BUG-102): what care's drink-nook search needs to judge a tile the way quickfort's place mode
-- does (scripts/internal/quickfort/place.lua:29-43): the tile shape, the building occupancy (Planned counts), a plant
-- on the tile, and the items lying on the floor of a box (one pass over the map blocks). Fails on 3045b94.
local T = require('testlib')
local kmock = require('dfllm.util.k_mock')
local SW = require('snapshot_world')

local Z = 10

local function world(rows)
  local dir = (os.getenv('TEMP') or '.'):gsub('\\', '/') .. '/dfllm-lua-tests/test_snapshot_nook'
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock/snap')
  local W = kmock.new{persist = {manifest = {v = 2}}, ms_per_frame = 100, dfpath = dir}
  SW.install(W)
  SW.draw(W, Z, rows, 0, 0)
  local gate = {name = 'gate', every = {ticks = 600}}
  function gate.state(K, b) if b == nil then return {} end return 'up' end
  W.load(gate)
  package.loaded['dfllm.snapshot'] = nil
  W.load(require('dfllm.snapshot'))
  return W
end

T.test('BUG-102: tile() names the shape, the plant and the building occupancy of a floor tile', function()
  local W = world{'...hg.r#'}
  df.tiletype.attrs[40] = {shape = df.tiletype_shape.BRANCH, material = df.tiletype_material.TREE,
                           special = df.tiletype_special.NONE}
  W.tiles['5,0,' .. Z].tt = 40
  W.tiles['2,0,' .. Z].occ.building = df.tile_building_occ.Planned
  local function t(x) local _, r = W.K.call('snapshot', 'tile', x, 0, Z); return r end
  T.eq({t(0).c, t(0).shape, t(0).plant, t(0).occ}, {'.', 'FLOOR', false, 0})
  T.eq({t(3).c, t(3).shape, t(3).plant}, {'.', 'SHRUB', 'shrub'})
  T.eq({t(4).shape, t(4).plant}, {'SAPLING', 'sapling'})
  T.eq({t(5).c, t(5).shape}, {'.', 'BRANCH'}, 'snapshot draws a branch as floor; quickfort place refuses it')
  T.eq({t(2).c, t(2).bld, t(2).occ}, {'.', '', 1}, 'a Planned building reads as free floor in the legend, but occ says 1')
  T.eq(t(6).shape, 'RAMP')
  T.eq(t(7).shape, 'WALL')
end)

T.test('BUG-102: item_tiles() lists the floor items of a box once, by "x,y"; hidden tiles, other levels and held items stay out', function()
  local W = world{'.....', '..?..'}
  local function item(id, x, y, on_ground, z)
    W.items_by_id = W.items_by_id or {}
    W.items_by_id[id] = {id = id, flags = {on_ground = on_ground ~= false}, pos = {x = x, y = y, z = z or Z}}
  end
  item(11, 1, 0); item(12, 1, 0); item(13, 3, 0); item(14, 2, 1); item(15, 4, 0, false); item(16, 0, 0, true, Z + 1)
  local blocks = {['0,0'] = {items = kmock.vec{11, 12, 13, 14, 15, 16}}}
  dfhack.maps.getTileBlock = function(x, y, z) return blocks[(x // 16) .. ',' .. (y // 16)] end
  local _, r = W.K.call('snapshot', 'item_tiles', 0, 0, 4, 1, Z)
  T.eq(r, {['1,0'] = 2, ['3,0'] = 1}, 'two items on 1,0; the hidden 2,1, the held item and the other level are left out')
  local _, r2 = W.K.call('snapshot', 'item_tiles', 2, 0, 4, 1, Z)
  T.eq(r2, {['3,0'] = 1}, 'only the box')
  local _, r3, e3 = W.K.call('snapshot', 'item_tiles', 0, 0, 99, 99, Z)
  T.eq({r3, e3}, {nil, 'rect too large'})
  dfhack.maps.getTileBlock = nil
end)

T.done()
