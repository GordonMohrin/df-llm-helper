-- Test world for lua/dfllm/seal.lua: k_mock plus an ASCII map with DF-like walk groups (flood fill over
-- walkable tiles: 8 on a level, stairs with their counterpart, ramps), designations (hidden, outside), buildings
-- (doors, bridges, beds, wells, depot, levers), items and burrows with tile sets.
--   local SW = require('seal_world'); local W = SW.new(); SW.draw(W, z, {'...'}, x0, y0); SW.regroup(W)
-- map chars: # rough wall, C constructed wall, F constructed fortification, . floor, , floor outside, X up/down
-- stair, < up stair, > down stair, r ramp, ^ ramp top (open above a ramp), _ open space, ? hidden floor,
-- + door, = lowered bridge, H raised bridge, b bed, W well, D depot, ' ' no tile. draw(..., {outside = true})
-- makes every tile of the call outside (',' is always outside, '.' never).
local kmock = require('dfllm.util.k_mock')
local SNW = require('snapshot_world')

local SW = {}
local EXTRA = {   -- tiletype ids appended to snapshot_world's
  {11, 'STAIR_UP', 'STONE', 'NORMAL'}, {12, 'STAIR_DOWN', 'STONE', 'NORMAL'}, {13, 'RAMP_TOP', 'AIR', 'NONE'},
  {14, 'FORTIFICATION', 'CONSTRUCTION', 'NONE'},
}
local T = {floor = 1, wall = 2, cwall = 4, open = 5, stair = 6, ramp = 10, up = 11, down = 12, top = 13, cfort = 14}
SW.T = T
local WALK = {FLOOR = true, STAIR_UP = true, STAIR_DOWN = true, STAIR_UPDOWN = true, RAMP = true}
local UP = {STAIR_UP = true, STAIR_UPDOWN = true}
local DOWN = {STAIR_DOWN = true, STAIR_UPDOWN = true}

local function key(x, y, z) return x .. ',' .. y .. ',' .. z end
SW.key = key

-- the fakes on a k_mock world (SW.new) or on the real-kernel harness (tests/lua/kern_world.lua)
function SW.install(W, opts)
  opts = opts or {}
  SNW.install(W, {map_size = opts.map_size or {4, 4, 20}})
  local A = df.tiletype.attrs
  for _, e in ipairs(EXTRA) do
    A[e[1]] = {shape = df.tiletype_shape[e[2]], material = df.tiletype_material[e[3]],
               special = df.tiletype_special[e[4]]}
  end
  df.trap_type = kmock.enum({'Lever', 'PressurePlate', 'CageTrap', 'StoneFallTrap', 'WeaponTrap', 'TrackStop'})
  df.job_type = {PullLever = 223}
  df.general_ref_type = {BUILDING_HOLDER = 6}
  df.global.world.constructions = kmock.vec{}
  W.wg, W.hidden_wg, W.bseq = {}, 0, 500
  dfhack.maps.getWalkableGroup = function(p)
    local t = W.tiles[key(p.x, p.y, p.z)]
    if t and t.des.hidden then W.hidden_wg = W.hidden_wg + 1 end
    return W.wg[key(p.x, p.y, p.z)] or 0
  end
  dfhack.items = {
    getPosition = function(it) local p = it._pos; if p then return p[1], p[2], p[3] end end,
    getContainer = function(it) return it._cont end,
    getGeneralRef = function(m) return m._ref end,
  }
  -- burrows: a bbox (k_mock W.burrow) and/or a painted tile set
  local function assigned(b, p)
    if not b then return false end
    local bb = b._bbox
    if bb and p.x >= bb[1] and p.x <= bb[4] and p.y >= bb[2] and p.y <= bb[5] and p.z >= bb[3] and p.z <= bb[6] then
      return true
    end
    return b._tiles ~= nil and b._tiles[key(p.x, p.y, p.z)] == true
  end
  dfhack.burrows.isAssignedTile = assigned
  -- the real act.burrow_tiles (kernel scenarios): burrows screen add + paint
  local bl = df.global.plotinfo.burrows
  bl.next_id = bl.next_id or 50
  df.burrow = {new = function() return {} end}
  local find = dfhack.burrows.findByName
  dfhack.burrows.findByName = function(name)
    local b = find(name)
    if b then return b end
    for _, x in ipairs(bl.list) do if x.name == name then return x end end
  end
  dfhack.burrows.setAssignedTile = function(b, p, on)
    b._tiles = b._tiles or {}
    b._tiles[key(p.x, p.y, p.z)] = on or nil
    return true
  end
  dfhack.burrows.listBlocks = function(b)
    local blocks, seen = {}, {}
    local function add(x, y, z)
      local k = (x // 16) .. ',' .. (y // 16) .. ',' .. z
      if not seen[k] then seen[k] = true; blocks[#blocks + 1] = {map_pos = {x = (x // 16) * 16, y = (y // 16) * 16, z = z}} end
    end
    local bb = b._bbox
    if bb and bb[1] >= 0 then
      for z = bb[3], bb[6] do for y = bb[2], bb[5] do for x = bb[1], bb[4] do add(x, y, z) end end end
    end
    for k in pairs(b._tiles or {}) do
      local x, y, z = k:match('^(%-?%d+),(%-?%d+),(%-?%d+)$')
      add(tonumber(x), tonumber(y), tonumber(z))
    end
    return blocks
  end
  dfhack.burrows.isAssignedBlockTile = function(b, blk, x, y)
    return assigned(b, {x = blk.map_pos.x + x, y = blk.map_pos.y + y, z = blk.map_pos.z})
  end
  W.act_result('burrow_tiles', function(name, tiles, create)
    local b = dfhack.burrows.findByName(name)
    if not b then
      if not create then return false, 'no burrow ' .. name end
      b = W.burrow(name, {-1, -1, -1, -1, -1, -1})
    end
    b._tiles = b._tiles or {}
    local n = 0
    for _, p in ipairs(tiles) do
      local k = key(p[1], p[2], p[3])
      if not b._tiles[k] then b._tiles[k] = true; n = n + 1 end
    end
    return true, n
  end)
  return W
end

function SW.new(opts)
  opts = opts or {}
  local W = kmock.new{units = opts.units, mode = opts.mode, persist = opts.persist, ms_per_frame = 16,
                      year = 3, ytick = opts.ytick or 1000, strict = opts.strict ~= false}
  return SW.install(W, opts)
end

---------------------------------------------------------------- buildings
local function building(W, cat, tname, x, y, z, extra)
  W.bseq = W.bseq + 1
  local b = {id = W.bseq, x1 = x, y1 = y, x2 = x, y2 = y, z = z, centerx = x, centery = y, _stage = 1,
             jobs = kmock.vec{}}
  for k, v in pairs(extra or {}) do b[k] = v end
  local ty = df.building_type[tname]
  b.getType = function() return ty end
  b.getBuildStage = function() return b._stage end
  b.getMaxBuildStage = function() return 1 end
  W.buildings[b.id] = b
  if cat then df.global.world.buildings.other[cat]:insert('#', b) end
  return b
end
SW.building = building

function SW.lever(W, x, y, z, target)
  local lv = building(W, 'TRAP', 'Trap', x, y, z, {trap_type = df.trap_type.Lever})
  lv.linked_mechanisms = kmock.vec{}
  if target then lv.linked_mechanisms:insert('#', {_ref = {getBuilding = function() return target end}}) end
  W.dyn[key(x, y, z)] = lv
  W.tiles[key(x, y, z)].occ.building = df.tile_building_occ.Dynamic
  return lv
end

function SW.bridge(W, fp, raised, name)
  local b = building(W, 'BRIDGE', 'Bridge', fp[1], fp[2], fp[3],
                     {x2 = fp[4], y2 = fp[5], centerx = (fp[1] + fp[4]) // 2, centery = (fp[2] + fp[5]) // 2,
                      gate_flags = {raised = raised == true, raising = false, lowering = false}, name = name})
  for x = fp[1], fp[4] do
    for y = fp[2], fp[5] do
      W.dyn[key(x, y, fp[3])] = b
      local t = W.tiles[key(x, y, fp[3])]
      if t then t.occ.building = df.tile_building_occ.Dynamic end
    end
  end
  return b
end

---------------------------------------------------------------- map
function SW.draw(W, z, rows, x0, y0, opts)
  x0, y0, opts = x0 or 0, y0 or 0, opts or {}
  local O = df.tile_building_occ
  for dy, row in ipairs(rows) do
    for dx = 1, #row do
      local ch = row:sub(dx, dx)
      local x, y = x0 + dx - 1, y0 + dy - 1
      local k = key(x, y, z)
      W.dyn[k] = nil
      if ch == ' ' then W.tiles[k] = nil
      else
        local tt = ({['#'] = T.wall, C = T.cwall, F = T.cfort, X = T.stair, ['<'] = T.up, ['>'] = T.down, r = T.ramp,
                     ['^'] = T.top, _ = T.open})[ch] or T.floor
        local outside = opts.outside == true
        if ch == ',' then outside = true elseif ch == '.' then outside = false end
        local des = {hidden = ch == '?', outside = outside, flow_size = 0, liquid_type = false, dig = 0, smooth = 0}
        local t = {des = des, occ = {building = O.None}, tt = tt}
        W.tiles[k] = t
        if ch == '+' then
          t.occ.building = O.Dynamic
          W.dyn[k] = building(W, 'DOOR', 'Door', x, y, z, {door_flags = {closed = true, forbidden = false}})
        elseif ch == '=' or ch == 'H' then
          SW.bridge(W, {x, y, z, x, y, z}, ch == 'H')
        elseif ch == 'b' then
          t.occ.building = O.Passable
          W.dyn[k] = building(W, 'BED', 'Bed', x, y, z)
        elseif ch == 'W' then
          t.occ.building = O.Well
          W.dyn[k] = building(W, 'WELL', 'Well', x, y, z)
        elseif ch == 'D' then
          t.occ.building = O.Passable
          W.dyn[k] = building(W, 'TRADE_DEPOT', 'TradeDepot', x, y, z)
        end
      end
    end
  end
end

-- a rectangle of one char
function SW.fill(W, z, x0, y0, x1, y1, ch, opts)
  local rows = {}
  for _ = y0, y1 do rows[#rows + 1] = string.rep(ch, x1 - x0 + 1) end
  SW.draw(W, z, rows, x0, y0, opts)
end

local function shape_at(W, x, y, z)
  local t = W.tiles[key(x, y, z)]
  if not t then return nil end
  return df.tiletype_shape[df.tiletype.attrs[t.tt].shape]
end

local function walkable(W, x, y, z)
  local s = shape_at(W, x, y, z)
  if not s or not WALK[s] then return false end
  local b = W.dyn[key(x, y, z)]
  if b then
    local ty = df.building_type[b.getType()]
    if ty == 'Bridge' and b.gate_flags.raised then return false end
    if ty == 'Well' then return false end
  end
  if W.tiles[key(x, y, z)].occ.building == df.tile_building_occ.Well then return false end
  return true
end
SW.walkable = walkable

-- DF's walk groups by flood fill (ids from 100 so no test can rely on a constant)
function SW.regroup(W)
  W.wg = {}
  local next_g = W.next_group or 100
  local function nbrs(x, y, z)
    local r = {}
    for dy = -1, 1 do for dx = -1, 1 do
      if dx ~= 0 or dy ~= 0 then
        r[#r + 1] = {x + dx, y + dy, z}
        if shape_at(W, x + dx, y + dy, z) == 'RAMP_TOP' then r[#r + 1] = {x + dx, y + dy, z - 1} end
      end
    end end
    local s = shape_at(W, x, y, z)
    if UP[s] and DOWN[shape_at(W, x, y, z + 1) or ''] then r[#r + 1] = {x, y, z + 1} end
    if DOWN[s] and UP[shape_at(W, x, y, z - 1) or ''] then r[#r + 1] = {x, y, z - 1} end
    if s == 'RAMP' and shape_at(W, x, y, z + 1) == 'RAMP_TOP' then
      for dy = -1, 1 do for dx = -1, 1 do if dx ~= 0 or dy ~= 0 then r[#r + 1] = {x + dx, y + dy, z + 1} end end end
    end
    return r
  end
  local keys = {}
  for k in pairs(W.tiles) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local x, y, z = k:match('^(%-?%d+),(%-?%d+),(%-?%d+)$')
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not W.wg[k] and walkable(W, x, y, z) then
      local g = next_g
      next_g = next_g + 1
      W.wg[k] = g
      local q, h = {{x, y, z}}, 1
      while h <= #q do
        local p = q[h]
        h = h + 1
        for _, n in ipairs(nbrs(p[1], p[2], p[3])) do
          local nk = key(n[1], n[2], n[3])
          if not W.wg[nk] and walkable(W, n[1], n[2], n[3]) then W.wg[nk] = g; q[#q + 1] = n end
        end
      end
    end
  end
  W.next_group = next_g + 7      -- new ids after every change (DF's ids change too)
end

-- a constructed wall finished at x,y,z (the construction vector grows: seal's watcher sees the change)
function SW.build_wall(W, x, y, z)
  SW.draw(W, z, {'C'}, x, y)
  df.global.world.constructions:insert('#', {pos = {x = x, y = y, z = z}})
  SW.regroup(W)
end

---------------------------------------------------------------- units, items
function SW.citizens(W, list)
  local ids = {}
  for _, c in ipairs(list) do
    W.add_unit{id = c[1], pos = {c[2], c[3], c[4]}, citizen = true}
    ids[#ids + 1] = c[1]
  end
  table.sort(ids)
  W.set_census('u', {tick = 0, cit = #ids, adults = #ids, children = 0, soldiers = 0, ids = ids, soldier_ids = {},
                     outside = 0, outside_ids = {}, on_bridge = {}, stressed = 0, caged = {}})
end

function SW.item(W, cat, x, y, z, n, flags)
  W.iseq = (W.iseq or 0) + 1
  local it = {id = W.iseq, flags = flags or {}, stack_size = n or 1, _pos = {x, y, z}}
  df.global.world.items.other[cat]:insert('#', it)
  return it
end

-- a fake module named like a contract module (gate, runner) with the given public functions
function SW.fake(name, fns)
  local m = {name = name, every = {ticks = 100000}}
  for k, f in pairs(fns or {}) do m[k] = f end
  return m
end

return SW
