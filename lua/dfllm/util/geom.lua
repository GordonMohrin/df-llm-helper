-- Geometry helpers (CONTRACTS §1.3, §2.3). Pure Lua, no DFHack.
-- Positions are {x=,y=,z=} tables (array form {x,y,z} is accepted everywhere);
-- a bbox is {x0,y0,z0,x1,y1,z1}, inclusive.
local G = {}

local function xyz(p)
  if p.x ~= nil then return p.x, p.y, p.z end
  return p[1], p[2], p[3]
end
G.xyz = xyz

function G.pos(x, y, z) return {x = x, y = y, z = z} end

function G.arr(p)
  local x, y, z = xyz(p)
  return {x, y, z}
end

-- 3D Chebyshev distance
function G.dist(a, b)
  local ax, ay, az = xyz(a)
  local bx, by, bz = xyz(b)
  return math.max(math.abs(ax - bx), math.abs(ay - by), math.abs(az - bz))
end

function G.in_bbox(p, b)
  local x, y, z = xyz(p)
  return x >= b[1] and x <= b[4] and y >= b[2] and y <= b[5] and z >= b[3] and z <= b[6]
end

function G.bbox_center(b)
  return {x = (b[1] + b[4]) // 2, y = (b[2] + b[5]) // 2, z = (b[3] + b[6]) // 2}
end

function G.bbox_union(a, b)
  return {math.min(a[1], b[1]), math.min(a[2], b[2]), math.min(a[3], b[3]),
          math.max(a[4], b[4]), math.max(a[5], b[5]), math.max(a[6], b[6])}
end

-- width, height, depth (tile counts)
function G.bbox_size(b)
  return b[4] - b[1] + 1, b[5] - b[2] + 1, b[6] - b[3] + 1
end

function G.near_any(p, list, r)
  for _, q in ipairs(list or {}) do
    if G.dist(p, q) <= r then return true end
  end
  return false
end

return G
