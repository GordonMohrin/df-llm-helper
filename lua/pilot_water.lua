-- claude/pilot_water scan x1 y1 z1 x2 y2 z2 | near x y z [r]      (dfpilot spec 08, NOT TESTED LIVE)
-- scan: count tiles with liquid (flow_size > 0) in the box: count per kind, per level, bounding box,
--       'front' = tile closest to the fort center (config FORT_X/FORT_Y). Only DISCOVERED tiles (fair play).
-- near: neighborhood (radius r, default 1, incl. z+-1, also diagonal) of a planned dig tile:
--       per tile dx/dy/dz, flow, magma, hidden, shape (wall/floor/ramp ...). Hidden tiles: hidden=true without flow info.
-- Read only. No liquid changes.
local util = reqscript('claude/util')
if not util.require_fort() then return end
local cfg = reqscript('claude/config')

local a = { ... }
local cmd = a[1] or 'scan'
local function n(i) return tonumber(a[i]) end

local function tile(x, y, z)
  local d = dfhack.maps.getTileFlags(x, y, z)
  if not d then return nil end
  if d.hidden then return { hidden = true } end
  local tt = dfhack.maps.getTileType(x, y, z)
  local shape = tt and df.tiletype_shape[df.tiletype.attrs[tt].shape] or '?'
  return { hidden = false, flow = d.flow_size, magma = d.liquid_type == df.tile_liquid.Magma, shape = shape }
end

if cmd == 'scan' then
  local x1, y1, z1, x2, y2, z2 = n(2), n(3), n(4), n(5), n(6), n(7)
  if not (x1 and y1 and z1 and x2 and y2 and z2) then util.emit({ ok = false, error = 'scan x1 y1 z1 x2 y2 z2' }) return end
  local CX, CY = cfg.FORT_X or (x1 + x2) // 2, cfg.FORT_Y or (y1 + y2) // 2
  local out = { ok = true, water = 0, magma = 0, units = 0, by_z = {}, bbox = nil, front = nil, hidden = 0 }
  local best
  for z = z1, z2 do
    for y = y1, y2 do
      for x = x1, x2 do
        local d = dfhack.maps.getTileFlags(x, y, z)
        if d then
          if d.hidden then
            out.hidden = out.hidden + 1
          elseif d.flow_size > 0 then
            if d.liquid_type == df.tile_liquid.Magma then out.magma = out.magma + 1 else out.water = out.water + 1 end
            out.units = out.units + d.flow_size
            out.by_z[tostring(z)] = (out.by_z[tostring(z)] or 0) + 1
            local b = out.bbox
            if not b then out.bbox = { x, y, z, x, y, z } else
              b[1] = math.min(b[1], x); b[2] = math.min(b[2], y); b[3] = math.min(b[3], z)
              b[4] = math.max(b[4], x); b[5] = math.max(b[5], y); b[6] = math.max(b[6], z)
            end
            local dist = math.max(math.abs(x - CX), math.abs(y - CY))
            if not best or dist < best then best = dist; out.front = { x, y, z } end
          end
        end
      end
    end
  end
  util.emit(out)
elseif cmd == 'near' then
  local x, y, z, r = n(2), n(3), n(4), n(5) or 1
  if not (x and y and z) then util.emit({ ok = false, error = 'near x y z [r]' }) return end
  local tiles = {}
  for dz = -1, 1 do
    for dy = -r, r do
      for dx = -r, r do
        if not (dx == 0 and dy == 0 and dz == 0) then
          local t = tile(x + dx, y + dy, z + dz)
          if t then t.dx, t.dy, t.dz = dx, dy, dz; tiles[#tiles + 1] = t end
        end
      end
    end
  end
  util.emit({ ok = true, x = x, y = y, z = z, r = r, self = tile(x, y, z), tiles = tiles })
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_water scan x1 y1 z1 x2 y2 z2 | near x y z [r]' })
end
