-- dfllm.stations (BUG-032): library (not a kernel module) for military: a squad station never lies on a bridge
-- footprint or next to it. Run 11 (Kilrudrabed, site98, y432 spring, BREACH): `GATE_FAIL B2 not up after 908 ticks
-- (blocked: soldier 27836 ... squad 104 stationed on the bridge at 115,116,142)`. BREACH's posture B2_HOLD stands every
-- squad at the manifest's `stations.b2`, which fortcore stage 3 put one tile behind B2's footprint (local 1,44; B2 on
-- v 43), inside gate's MARGIN ring; gate never raises a bridge onto a unit on or next to its footprint (BUG-027), so
-- the squad at its station held the core seal down.
-- Rules (military applies them wherever it picks a station: postures, siege's sortie gathering point, the re-station
-- of a squad that holds a raise):
--   clearance   a station lies more than `clear` tiles (Chebyshev, same z) from every manifest bridge footprint:
--               clear = gate.MARGIN (1) + stations.spread (config/reflex.json, default 1: DF stands a squad's soldiers
--               on the tiles around its station point, so a station two tiles from a footprint still puts soldiers
--               into the ring). A footprint on another z never holds a station.
--   inner side  a replacement lies on the inner side of every footprint that held the station: the side with the
--               deepest manifest zone around the footprint (Z1 1, Z2 and killboxes 2, Z3 3, Z4 4: O1 -> the bailey,
--               B1 -> the gatehouse, B2 -> the core), else the side the station lay on, else farther from the map
--               edge (manifest `edge`), else any side
--   tile        the nearest (Chebyshev ring, then Euclid, then y, x) revealed plain floor (snapshot.tile: '.', no
--               building) on the station's z within SEARCH_R tiles, off the manifest stairs. Fair play: the caller's
--               tile reader answers nil for a hidden tile (snapshot.tile), which never counts; this file reads nothing
--               itself.
local S = {}

S.SEARCH_R = 8
S.ZRANK = {Z1 = 1, Z2 = 2, Z3 = 3, Z4 = 4}
S.KILLBOX_RANK = 2

local function int(v) return type(v) == 'number' and math.tointeger(v) or nil end

-- {x, y, z} of a position table ({x, y, z} or {x =, y =, z =}); nil if it is not one
function S.pos(p)
  if type(p) ~= 'table' then return nil end
  local x, y, z = int(p.x or p[1]), int(p.y or p[2]), int(p.z or p[3])
  if x and y and z then return {x = x, y = y, z = z} end
end

-- a footprint {x0, y0, z0, x1, y1, z1} of integers, else nil
function S.fp(fp)
  if type(fp) ~= 'table' or #fp ~= 6 then return nil end
  local r = {}
  for i = 1, 6 do
    r[i] = int(fp[i])
    if not r[i] then return nil end
  end
  return r
end

-- the manifest bridges with a valid footprint, sorted by name: {{name, fp}}
function S.bridges(man)
  local r = {}
  for name, b in pairs(type(man) == 'table' and type(man.bridges) == 'table' and man.bridges or {}) do
    local fp = type(b) == 'table' and S.fp(b.fp)
    if type(name) == 'string' and fp then r[#r + 1] = {name = name, fp = fp} end
  end
  table.sort(r, function(a, b) return a.name < b.name end)
  return r
end

-- Chebyshev distance (x, y) of a tile to a footprint on its level; nil on another level
function S.dist(fp, x, y, z)
  if z < fp[3] or z > fp[6] then return nil end
  local dx = x < fp[1] and fp[1] - x or (x > fp[4] and x - fp[4] or 0)
  local dy = y < fp[2] and fp[2] - y or (y > fp[5] and y - fp[5] or 0)
  return math.max(dx, dy)
end

-- the bridges that hold p: {{name, fp, d, need}} with d <= need (need = need_by[name], else clear)
function S.blockers(brs, p, clear, need_by)
  local r = {}
  for _, b in ipairs(brs) do
    local need = need_by and need_by[b.name] or clear
    local d = S.dist(b.fp, p.x, p.y, p.z)
    if d and d <= need then r[#r + 1] = {name = b.name, fp = b.fp, d = d, need = need} end
  end
  return r
end

local function in6(b, x, y, z)
  return type(b) == 'table' and #b == 6 and x >= b[1] and x <= b[4] and y >= b[2] and y <= b[5] and z >= b[3]
         and z <= b[6]
end

-- the zone rank of a tile: Z1 1, Z2 and the killboxes 2, Z3 3, Z4 4 (how deep inside the fort it lies), 0 none
function S.rank(man, x, y, z)
  local best = 0
  local zones = type(man.zones) == 'table' and man.zones or {}
  for zn, rk in pairs(S.ZRANK) do
    if rk > best then
      for _, b in ipairs(type(zones[zn]) == 'table' and zones[zn] or {}) do
        if in6(b, x, y, z) then best = rk; break end
      end
    end
  end
  if best < S.KILLBOX_RANK then
    for _, kb in ipairs(type(man.killboxes) == 'table' and man.killboxes or {}) do
      if type(kb) == 'table' and in6(kb.bbox, x, y, z) then best = S.KILLBOX_RANK; break end
    end
  end
  return best
end

-- the inner side's zone rank of a footprint: the deepest zone among the tiles within ring + 1 of it (same z); nil
-- when no zone lies there
function S.inner_rank(man, fp, ring)
  local best
  local z = fp[3]
  for y = fp[2] - ring - 1, fp[5] + ring + 1 do
    for x = fp[1] - ring - 1, fp[4] + ring + 1 do
      if not (x >= fp[1] and x <= fp[4] and y >= fp[2] and y <= fp[5]) then
        local r = S.rank(man, x, y, z)
        if r > 0 and (best == nil or r > best) then best = r end
      end
    end
  end
  return best
end

local function edge_dist(edge, x, y)
  local best
  for _, e in ipairs(edge) do
    local ex, ey = int(e[1] or e.x), int(e[2] or e.y)
    if ex and ey then
      local d = math.max(math.abs(x - ex), math.abs(y - ey))
      if not best or d < best then best = d end
    end
  end
  return best
end

-- the inner side of footprint fp for a station at p: fn(x, y, z) -> true on it, and a short text
function S.side(man, fp, p, ring)
  local r = S.inner_rank(man, fp, ring)
  if r then
    return function(x, y, z) return S.rank(man, x, y, z) >= r end, string.format('zone rank %d', r)
  end
  local ox = p.x < fp[1] and p.x - fp[1] or (p.x > fp[4] and p.x - fp[4] or 0)
  local oy = p.y < fp[2] and p.y - fp[2] or (p.y > fp[5] and p.y - fp[5] or 0)
  if oy ~= 0 and math.abs(oy) >= math.abs(ox) then
    return function(_, y) return (oy < 0 and y < fp[2]) or (oy > 0 and y > fp[5]) end, 'its side'
  elseif ox ~= 0 then
    return function(x) return (ox < 0 and x < fp[1]) or (ox > 0 and x > fp[4]) end, 'its side'
  end
  local edge = type(man.edge) == 'table' and man.edge or {}
  local dc = edge_dist(edge, (fp[1] + fp[4]) // 2, (fp[2] + fp[5]) // 2)
  if dc then
    return function(x, y) return (edge_dist(edge, x, y) or 0) > dc end, 'away from the edge'
  end
  return function() return true end, 'any side'
end

-- a revealed plain floor: snapshot.tile's '.', no building on it (a lever, a bed, a door frame)
function S.floor(t)
  return type(t) == 'table' and t.c == '.' and (t.bld == nil or t.bld == '')
end

local function stair_cols(man)
  local r = {}
  local stairs = type(man.stairs) == 'table' and man.stairs or {}
  for _, kind in ipairs({'civ', 'mil'}) do
    for _, c in ipairs(type(stairs[kind]) == 'table' and stairs[kind] or {}) do
      if type(c) == 'table' and int(c[1]) and int(c[2]) and int(c[3]) and int(c[4]) then r[#r + 1] = c end
    end
  end
  return r
end

local function on_stair(cols, x, y, z)
  for _, c in ipairs(cols) do
    if x == c[1] and y == c[2] and z >= math.min(c[3], c[4]) and z <= math.max(c[3], c[4]) then return true end
  end
  return false
end

-- the tile nearest to p (same z; Chebyshev rings 0..R, inside a ring by Euclid, then y, then x) for which
-- ok(x, y, z) holds; nil none. ok is asked in that order, so the first answer wins.
function S.nearest(p, R, ok)
  for r = 0, R do
    local ring = {}
    for y = p.y - r, p.y + r do
      for x = p.x - r, p.x + r do
        if math.max(math.abs(x - p.x), math.abs(y - p.y)) == r then
          ring[#ring + 1] = {x = x, y = y, d = (x - p.x) * (x - p.x) + (y - p.y) * (y - p.y)}
        end
      end
    end
    table.sort(ring, function(a, b)
      if a.d ~= b.d then return a.d < b.d end
      if a.y ~= b.y then return a.y < b.y end
      return a.x < b.x
    end)
    for _, t in ipairs(ring) do
      if ok(t.x, t.y, p.z) then return {x = t.x, y = t.y, z = p.z} end
    end
  end
  return nil
end

-- the nearest revealed plain floor to p that lies clear of every bridge (o.clear, o.need_by) and on the inner side of
-- each footprint in blk (and of o.side when given); nil none. o.tile(x, y, z) -> snapshot.tile's answer (nil hidden),
-- o.ring = the inner side's search ring, o.R = the search radius (SEARCH_R); BUG-170: with o.group and
-- o.group_of(x, y, z) -> walk group (-1 unknown) only a tile on that walk group counts
function S.relocate(man, brs, p, blk, o)
  local sides = {}
  for _, b in ipairs(blk) do sides[#sides + 1] = (S.side(man, b.fp, p, o.ring or o.clear)) end
  if o.side then sides[#sides + 1] = o.side end
  local cols = stair_cols(man)
  local function ok(x, y, z)
    for _, b in ipairs(brs) do
      local need = o.need_by and o.need_by[b.name] or o.clear
      local d = S.dist(b.fp, x, y, z)
      if d and d <= need then return false end
    end
    for _, f in ipairs(sides) do if not f(x, y, z) then return false end end
    if on_stair(cols, x, y, z) then return false end
    if not S.floor(o.tile(x, y, z)) then return false end
    -- BUG-170: on the walk group of the squad that goes there (o.group; o.group_of -> -1 unknown never refuses)
    if o.group and o.group_of then
      local g = o.group_of(x, y, z)
      if type(g) == 'number' and g >= 0 and g ~= o.group then return false end
    end
    return true
  end
  return S.nearest(p, o.R or S.SEARCH_R, ok)
end

-- BUG-214 (live t4: b2 a wall, core on walk group 0, melee on group 1507 behind the raised B2, the soldiers on 1: no
-- station order at all): the nearest tile inside box {x0, y0, z0, x1, y1, z1} that S.relocate accepts (o as there;
-- o.inside(x, y, z), when given, must hold too: the Kern+ burrow), the levels nearest to p.z first (ties: the lower
-- one), on each level from p clamped into the box with a radius that covers it; at most o.cap (4000) probes. nil none
function S.relocate_box(man, brs, box, p, o)
  local b = S.fp(box)
  if not b then return nil end
  local zs = {}
  for z = math.min(b[3], b[6]), math.max(b[3], b[6]) do zs[#zs + 1] = z end
  table.sort(zs, function(a, c)
    local da, dc = math.abs(a - p.z), math.abs(c - p.z)
    if da ~= dc then return da < dc end
    return a < c
  end)
  local x0, x1, y0, y1 = math.min(b[1], b[4]), math.max(b[1], b[4]), math.min(b[2], b[5]), math.max(b[2], b[5])
  local cap, n = o.cap or 4000, 0
  local q = {}
  for k, v in pairs(o) do q[k] = v end
  local side = o.side
  q.side = function(x, y, z)
    if x < x0 or x > x1 or y < y0 or y > y1 or n >= cap then return false end
    n = n + 1
    if side and not side(x, y, z) then return false end
    return not o.inside or o.inside(x, y, z) == true
  end
  for _, z in ipairs(zs) do
    local c = {x = math.max(x0, math.min(x1, p.x)), y = math.max(y0, math.min(y1, p.y)), z = z}
    q.R = math.max(c.x - x0, x1 - c.x, c.y - y0, y1 - c.y)
    local r = S.relocate(man, brs, c, {}, q)
    if r then return r end
    if n >= cap then return nil end
  end
  return nil
end

-- BUG-215 (live t4: a far harmless gorlak held the BREACH 23,000+ ticks, on_station 0 of 8 with off {nost 8}, so
-- reflex's siege_release and siege's breach_stuck never came): are the soldiers where the posture wants them, by
-- military.kpi k? true, why when half of the soldiers who have a reachable station stand on it ('at their stations'),
-- or when none of them has one (off nost/unreach: 'no station order ...') and half of all soldiers stand in Kern+
-- (k.in_kern; no march out: with no station the core is where they defend); false, why otherwise
function S.stationed(k)
  k = type(k) == 'table' and k or {}
  local sol, on = int(k.soldiers) or 0, int(k.on_station) or 0
  if sol <= 0 then return false, 'no soldiers' end
  local off = type(k.off) == 'table' and k.off or {}
  local none = math.min(sol, (int(off.nost) or 0) + (int(off.unreach) or 0))
  if on * 2 >= sol then return true, 'at their stations' end
  if none == 0 or on * 2 < sol - none then
    return false, string.format('%d of %d at their stations%s', on, sol,
                                none > 0 and string.format(' (%d without a reachable one)', none) or '')
  end
  local ink = int(k.in_kern)
  if ink and ink * 2 < sol then
    return false, string.format('no station order for %d of %d, only %d in Kern+', none, sol, ink)
  end
  return true, string.format('no station order for %d of %d%s', none, sol,
                             ink and string.format(', %d in Kern+', ink) or '')
end

-- the centre of the biggest Z4 box (by its x/y area; the core level of a fortcore manifest), nil without one
function S.z4_centre(man)
  local best, area
  local zones = type(man.zones) == 'table' and man.zones or {}
  for _, b in ipairs(type(zones.Z4) == 'table' and zones.Z4 or {}) do
    local f = S.fp(b)
    if f then
      local a = (f[4] - f[1] + 1) * (f[5] - f[2] + 1)
      if not area or a > area then best, area = f, a end
    end
  end
  if best then return {x = (best[1] + best[4]) // 2, y = (best[2] + best[5]) // 2, z = best[3]} end
end

return S
