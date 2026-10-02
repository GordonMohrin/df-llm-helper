-- claude/probe z x1 y1 [x2 y2 [x,y,z ...]]  - SAFETY PROBE before an exploration tunnel (run 4, erkundung): is the tile (or every tile of the line) surrounded
-- entirely by wall? Goal: never accidentally break into a cavern/water/magma (rule RUN4-START.md).
-- Checks the 26 neighbors (3x3x3) of each target tile: allowed are (a) wall (shape WALL) or (b) tiles of the line itself / its predecessors (already open tunnel).
-- Returns ONLY safe/unsafe + direction, NOT material/ore (no ore sight). Fair-play note: reads the shape of hidden neighbor tiles (like claude/dig
-- when validating 'wall?'); used by the erkundung agent only for cavern/water safety (z <= SICHER_AB) and named in the report.
-- Additionally: water_table flag (discovered tiles only) and flow_size>0 (water) nearby -> unsafe.
local util = reqscript('claude/util')
if not util.require_fort() then return end
local a = { ... }
local z, x1, y1 = tonumber(a[1]), tonumber(a[2]), tonumber(a[3])
local x2, y2 = tonumber(a[4]) or x1, tonumber(a[5]) or y1
if not (z and x1 and y1) then util.emit({ error = 'usage: claude/probe z x1 y1 [x2 y2]' }) return end

local line = {}
local function key(x, y, zz) return x .. ',' .. y .. ',' .. zz end
local n = math.max(math.abs(x2 - x1), math.abs(y2 - y1))
for i = 0, n do
  local t = n == 0 and 0 or i / n
  local x = math.floor(x1 + (x2 - x1) * t + 0.5)
  local y = math.floor(y1 + (y2 - y1) * t + 0.5)
  line[#line + 1] = { x, y }
end
local inline = {}
for _, p in ipairs(line) do inline[key(p[1], p[2], z)] = true end
-- further allowed tiles (own, already open): arguments 6.. as 'x,y,z' (e.g. shaft tile + predecessor)
for i = 6, #a do
  local ax, ay, az = tostring(a[i]):match('^(-?%d+),(-?%d+),(-?%d+)$')
  if ax then inline[key(tonumber(ax), tonumber(ay), tonumber(az))] = true end
end

local function shape(x, y, zz)
  local tt = dfhack.maps.getTileType(x, y, zz)
  if not tt then return nil end
  return df.tiletype_shape[df.tiletype.attrs[tt].shape]
end

local bad, ok = {}, 0
for _, p in ipairs(line) do
  local x, y = p[1], p[2]
  local issue
  for dz = -1, 1 do for dx = -1, 1 do for dy = -1, 1 do
    if not (dx == 0 and dy == 0 and dz == 0) then
      local nx, ny, nz = x + dx, y + dy, z + dz
      if not inline[key(nx, ny, nz)] then
        local sh = shape(nx, ny, nz)
        if sh == nil then issue = issue or 'ausserhalb' -- map edge/ceiling
        elseif sh ~= 'WALL' then
          -- An already known open tile of our own tunnel (predecessor on the level) is ok: only neighbors OUTSIDE the line count
          issue = issue or ('offen dx%+d dy%+d dz%+d'):format(dx, dy, dz)
        end
        local b = dfhack.maps.getTileBlock(nx, ny, nz)
        if b then
          local d = b.designation[nx % 16][ny % 16]
          if not d.hidden and (d.water_table or d.flow_size > 0) then issue = issue or 'Wasser/Aquifer sichtbar' end
        end
      end
    end
  end end end
  if issue then bad[#bad + 1] = ('(%d,%d,z%d): %s'):format(x, y, z, issue) else ok = ok + 1 end
end
util.emit({ z = z, kacheln = #line, sicher = ok, unsicher = bad, freigabe = (#bad == 0) })
