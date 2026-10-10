-- Test world for lua/dfllm/snapshot.lua: k_mock (or the real kernel through kern_world) plus fake
-- DF tile types, tile flags, buildings and traps. Tiles are drawn from ASCII maps:
--   local SW = require('snapshot_world'); SW.install(W); SW.draw(W, z, {'#..', '#.+'}, x0, y0)
-- map chars: # rough wall, S smooth wall, C constructed wall, F fortification, T tree, . floor,
-- s soil floor, _ open space, X up/down stair, r ramp, ? hidden floor, w water 2/7, ~ water 6/7,
-- % magma, + door (Dynamic), = bridge (Dynamic), ^ weapon trap (Passable), B statue (Impassable),
-- d floor with a pending dig designation, m smoothing designation; a space = no tile (off the map).
local kmock = require('dfllm.util.k_mock')

local SW = {}

local TT = {   -- tiletype id -> {shape, material, special}
  {'FLOOR', 'STONE', 'NORMAL'}, {'WALL', 'STONE', 'NORMAL'}, {'WALL', 'STONE', 'SMOOTH'},
  {'WALL', 'CONSTRUCTION', 'NORMAL'}, {'EMPTY', 'AIR', 'NONE'}, {'STAIR_UPDOWN', 'STONE', 'NORMAL'},
  {'FLOOR', 'SOIL', 'NORMAL'}, {'FORTIFICATION', 'STONE', 'NORMAL'}, {'WALL', 'TREE', 'NONE'},
  {'RAMP', 'STONE', 'NORMAL'},
}
SW.TT = {floor = 1, wall = 2, smooth = 3, cwall = 4, open = 5, stair = 6, soil = 7, fort = 8, tree = 9, ramp = 10}

local function enum(names) return kmock.enum(names) end

function SW.install(W, opts)
  opts = opts or {}
  local shapes = enum({'NONE', 'EMPTY', 'FLOOR', 'BOULDER', 'PEBBLES', 'WALL', 'FORTIFICATION', 'STAIR_UP',
                       'STAIR_DOWN', 'STAIR_UPDOWN', 'RAMP', 'RAMP_TOP', 'BROOK_BED', 'BROOK_TOP', 'BRANCH',
                       'TRUNK_BRANCH', 'TWIG', 'SAPLING', 'SHRUB', 'ENDLESS_PIT'})
  local mats = enum({'NONE', 'AIR', 'SOIL', 'STONE', 'FEATURE', 'LAVA_STONE', 'MINERAL', 'FROZEN_LIQUID',
                     'CONSTRUCTION', 'GRASS_LIGHT', 'GRASS_DARK', 'GRASS_DRY', 'GRASS_DEAD', 'PLANT', 'HFS',
                     'CAMPFIRE', 'FIRE', 'ASHES', 'MAGMA', 'DRIFTWOOD', 'POOL', 'BROOK', 'RIVER', 'ROOT',
                     'TREE', 'MUSHROOM', 'UNDERWORLD_GATE'})
  local specials = enum({'NONE', 'NORMAL', 'RIVER_SOURCE', 'WATERFALL', 'SMOOTH', 'FURROWED', 'WET', 'DEAD',
                         'WORN_1', 'WORN_2', 'WORN_3', 'TRACK', 'SMOOTH_DEAD'})
  df.tiletype_shape, df.tiletype_material, df.tiletype_special = shapes, mats, specials
  local attrs = {}
  for id, t in ipairs(TT) do attrs[id] = {shape = shapes[t[1]], material = mats[t[2]], special = specials[t[3]]} end
  df.tiletype = {attrs = attrs}
  df.tile_building_occ = enum({'None', 'Planned', 'Passable', 'Obstacle', 'Well', 'Floored', 'Impassable', 'Dynamic'})
  df.tile_dig_designation = enum({'No', 'Default', 'UpDownStair', 'Channel', 'Ramp', 'DownStair', 'UpStair'})
  df.building_type = enum({'Chair', 'Bed', 'Table', 'Coffin', 'FarmPlot', 'Furnace', 'TradeDepot', 'Shop', 'Door',
                           'Floodgate', 'Box', 'Weaponrack', 'Armorstand', 'Workshop', 'Cabinet', 'Statue',
                           'WindowGlass', 'WindowGem', 'Well', 'Bridge', 'RoadDirt', 'RoadPaved', 'SiegeEngine',
                           'Trap', 'AnimalTrap', 'Support', 'ArcheryTarget', 'Chain', 'Cage', 'Stockpile',
                           'Civzone', 'Weapon', 'Wagon', 'ScrewPump', 'Construction', 'Hatch', 'GrateWall',
                           'GrateFloor', 'BarsVertical', 'BarsFloor'})
  df.trap_type = enum({'Lever', 'PressurePlate', 'CageTrap', 'StoneFallTrap', 'WeaponTrap', 'TrackStop'})
  df.item_weaponst = {is_instance = function(_, it) return type(it) == 'table' and it._k == 'weapon' end}
  df.item_trapcompst = {is_instance = function(_, it) return type(it) == 'table' and it._k == 'trapcomp' end}
  W.map_size = opts.map_size or {4, 4, 20}           -- blocks: 64 x 64 x 20 tiles
  dfhack.maps.getTileSize = function() local s = W.map_size; return s[1] * 16, s[2] * 16, s[3] end
  W.tiles = W.tiles or {}
  W.dyn = {}                                          -- 'x,y,z' -> building (findAtTile)
  W.find_calls = 0
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    if type(x) == 'table' then x, y, z = x.x, x.y, x.z end
    W.find_calls = W.find_calls + 1
    return W.dyn[x .. ',' .. y .. ',' .. z]
  end
  return W
end

local function bld(W, kind, x, y, z, extra)
  local b = {_kind = kind, x1 = x, y1 = y, x2 = x, y2 = y, z = z, centerx = x, centery = y}
  for k, v in pairs(extra or {}) do b[k] = v end
  local t = df.building_type[kind == 'trap' and 'Trap' or kind]
  b.getType = function() return t end
  return b
end

-- draw rows (y0, y0+1, ...) of level z starting at x0
function SW.draw(W, z, rows, x0, y0)
  x0, y0 = x0 or 0, y0 or 0
  local O = df.tile_building_occ
  for dy, row in ipairs(rows) do
    for dx = 1, #row do
      local ch = row:sub(dx, dx)
      local x, y = x0 + dx - 1, y0 + dy - 1
      local key = x .. ',' .. y .. ',' .. z
      if ch ~= ' ' then
        local T = SW.TT
        local des = {hidden = false, flow_size = 0, liquid_type = false, dig = 0, smooth = 0, feature_global = false}
        local occ = {building = O.None}
        local tt = ({['#'] = T.wall, S = T.smooth, C = T.cwall, F = T.fort, T = T.tree, ['.'] = T.floor,
                     s = T.soil, _ = T.open, X = T.stair, r = T.ramp, ['?'] = T.floor, w = T.floor, ['~'] = T.floor,
                     ['%'] = T.open, ['+'] = T.floor, ['='] = T.floor, ['^'] = T.floor, B = T.floor,
                     d = T.wall, m = T.wall, c = T.floor})[ch] or T.floor
        if ch == '?' then des.hidden = true end
        if ch == 'w' then des.flow_size = 2 end
        if ch == '~' then des.flow_size = 6 end
        if ch == '%' then des.flow_size, des.liquid_type = 7, true end
        if ch == 'd' then des.dig = df.tile_dig_designation.Default end
        if ch == 'm' then des.smooth = 1 end
        if ch == 'c' then des.feature_global = true end
        if ch == '+' then occ.building = O.Dynamic; W.dyn[key] = bld(W, 'Door', x, y, z) end
        if ch == '=' then
          occ.building = O.Dynamic
          W.dyn[key] = bld(W, 'Bridge', x, y, z, {gate_flags = setmetatable({raised = false, raising = false, lowering = false},
            {__index = function(_, k) error('no field ' .. tostring(k) .. ' in building_bridgest.gate_flags') end})})
        end
        if ch == '^' then
          occ.building = O.Passable
          local tr = bld(W, 'trap', x, y, z, {trap_type = df.trap_type.WeaponTrap, ready_timeout = 0,
                                              contained_items = kmock.vec{{item = {_k = 'mech'}}, {item = {_k = 'weapon'}},
                                                                          {item = {_k = 'trapcomp'}}}})
          df.global.world.buildings.other.TRAP:insert('#', tr)
        end
        if ch == 'B' then occ.building = O.Impassable end
        W.tiles[key] = {des = des, occ = occ, tt = tt}
      else
        W.tiles[key] = nil
      end
    end
  end
end

return SW
