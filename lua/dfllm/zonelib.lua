-- zonelib: the verb zone.place (FR-78, Run 14 note 65). A library, not a kernel module (like orderlib.lua): the runner's
-- verb calls Z.verb(K, args, cmd); the zone itself is drawn by act.zone_place (quickfort zone mode, our own one-cell
-- blueprint), the same action as "zones > add zone > <type>" and dragging a box on the map.
--
-- Run 14 Trussroads (note 65): a pen (taming) and a pit zone had to be built beside the barracks zone and `bp list` knows
-- fixed building templates only; the game session called dfhack.buildings.constructBuilding by hand (Pen/Pasture, Pit/Pond with
-- zone_settings.pond.flag.keep_filled = false for a pit). Pen is civzone 88 and Pond 86 in that DF version: the enum has no
-- separate Pit value, a pit is a Pond zone that is not kept filled.
--
-- Types (quickfort zone keys, dfpilot/bp/validate.py ZONE_KEYS, quickfort-user-guide #zone): pen n, pit p, pond p{pond=true},
-- sand s, clay c, fishing f, meeting m. One level per zone. Refused: a box that leaves the map or holds a tile that is not
-- revealed (a player cannot draw on an unexplored tile; fair play: never hidden tiles), a box over rock, open air or (for
-- everything but fishing) water, a box over more than zones.max_tiles tiles (config/baseline.json "zones", default 400), a
-- box that overlaps a conflicting zone (below), and any fight mode (kern: PEACE, ALERT, RECOVERY only).
-- Conflicts: a zone of the same type; any zone that is a location (hospital, temple, tavern, library, guildhall: it has a
-- location_id); a room zone (bedroom, dining hall, barracks, dormitory, office, archery range, tomb, dungeon) for a pen, a
-- pit or a pond; a pond or pit under a pen or a meeting area and the other way round. Sand, clay and fishing zones conflict
-- with the same type and with locations only (zones may overlap otherwise, as in the game).
local Z = {}

-- type -> quickfort key, properties, the df.civzone_type name (may differ between DF versions: looked up by name, a missing
-- name only switches the same-type check off), the pond setting the zone sheet gets (nil = untouched)
Z.TYPES = {
  pen     = {key = 'n', props = '', zt = 'Pen'},
  pit     = {key = 'p', props = '', zt = 'Pond', pond = false},          -- a pit: the zone is NOT kept filled with water
  pond    = {key = 'p', props = 'pond=true', zt = 'Pond', pond = true},
  sand    = {key = 's', props = '', zt = 'SandCollection'},
  clay    = {key = 'c', props = '', zt = 'ClayCollection'},
  fishing = {key = 'f', props = '', zt = 'FishingArea', water = true},
  meeting = {key = 'm', props = '', zt = 'MeetingHall'},
}
Z.ORDER = {'pen', 'pit', 'pond', 'sand', 'clay', 'fishing', 'meeting'}
Z.MAX_TILES = 400                                  -- zones.max_tiles
Z.ROOMS = {Bedroom = true, DiningHall = true, Barracks = true, Dormitory = true, Office = true, ArcheryRange = true,
           Tomb = true, Dungeon = true}
local ANIMAL = {pen = true, pit = true, pond = true}
local SOLID = {['#'] = true, S = true, C = true, F = true, T = true, ['_'] = true}
local WATER = {w = true, ['~'] = true}

local function int(v) return math.type(v) == 'integer' and v or math.tointeger(v) end

-- config/baseline.json "zones": {max_tiles}; a value of another type or out of 1..10000 keeps the default
function Z.max_tiles(K)
  local c = type(K.cfg.baseline) == 'table' and K.cfg.baseline.zones
  local n = type(c) == 'table' and int(c.max_tiles) or nil
  if n and n >= 1 and n <= 10000 then return n end
  return Z.MAX_TILES
end

-- the cell text and the anchor of a normalised box: 'p{pond=true name=dfllm-pit}(4x3)', {x, y, z}
function Z.cell(ty, box, name)
  local t = Z.TYPES[ty]
  local props = t.props
  if name and name ~= '' then props = (props ~= '' and (props .. ' ') or '') .. 'name=' .. name end
  return string.format('%s%s(%dx%d)', t.key, props ~= '' and ('{' .. props .. '}') or '', box.x1 - box.x0 + 1,
                       box.y1 - box.y0 + 1), {box.x0, box.y0, box.z}
end

-- {type, box = {x0, y0, x1, y1, z}, name} from the verb args {type, bbox = [x0,y0,z0,x1,y1,z1], name?}, or nil, why
function Z.spec(args, max)
  local ty = args.type
  if type(ty) ~= 'string' or not Z.TYPES[ty] then
    return nil, 'type must be one of ' .. table.concat(Z.ORDER, ', ')
  end
  local b = args.bbox
  if type(b) ~= 'table' or #b ~= 6 then return nil, 'bbox must be [x0,y0,z0,x1,y1,z1]' end
  local v = {}
  for i = 1, 6 do
    v[i] = int(b[i])
    if not v[i] then return nil, 'bbox must hold six integers' end
  end
  if v[1] > v[4] or v[2] > v[5] or v[3] > v[6] then return nil, 'bbox must be ordered: x0<=x1, y0<=y1, z0<=z1' end
  if v[3] ~= v[6] then return nil, 'one level per zone: call zone.place once per z level' end
  local tiles = (v[4] - v[1] + 1) * (v[5] - v[2] + 1)
  if tiles > max then return nil, string.format('%d tiles: a zone holds at most %d (zones.max_tiles)', tiles, max) end
  local name = args.name
  if name ~= nil and (type(name) ~= 'string' or not name:match('^[A-Za-z0-9_-]+$') or #name > 24) then
    return nil, 'name must be 1-24 letters, digits, _ or -'
  end
  return {type = ty, name = name, box = {x0 = v[1], y0 = v[2], x1 = v[4], y1 = v[5], z = v[3]}}
end

-- the tiles of the box: nil when all are revealed floor the zone may cover, else the first refusal text. `tile(x, y, z)`
-- is snapshot.tile (nil = hidden or off the map)
function Z.tiles_ok(ty, box, tile)
  local t = Z.TYPES[ty]
  for y = box.y0, box.y1 do
    for x = box.x0, box.x1 do
      local c = tile(x, y, box.z)
      if type(c) ~= 'table' then
        return string.format('tile %d,%d,%d is not revealed or off the map: a zone cannot be drawn there', x, y, box.z)
      end
      if SOLID[c.c] then
        return string.format('tile %d,%d,%d is %s', x, y, box.z, c.c == '_' and 'open air' or 'rock or a wall')
      end
      if WATER[c.c] and not t.water then
        return string.format('tile %d,%d,%d is water: only a fishing zone covers water', x, y, box.z)
      end
    end
  end
  return nil
end

-- conflicts with the zones listed ({id, tname, loc, name, x0, y0, x1, y1, z, has = function(x, y) | nil}); the first text
function Z.conflict(ty, box, zones)
  local t = Z.TYPES[ty]
  for _, zn in ipairs(zones) do
    if zn.z == box.z and zn.x0 <= box.x1 and zn.x1 >= box.x0 and zn.y0 <= box.y1 and zn.y1 >= box.y0 then
      local hit = false
      if zn.has then                               -- an irregular zone: a shared tile, not a shared rectangle
        for y = math.max(zn.y0, box.y0), math.min(zn.y1, box.y1) do
          for x = math.max(zn.x0, box.x0), math.min(zn.x1, box.x1) do
            if zn.has(x, y) then hit = true; break end
          end
          if hit then break end
        end
      else
        hit = true
      end
      if hit then
        local tn = zn.tname or '?'
        local why
        if zn.loc and zn.loc >= 0 then why = 'is a location (hospital, temple, tavern, library or guildhall)'
        elseif tn == t.zt then why = 'has the same type'
        elseif ANIMAL[ty] and Z.ROOMS[tn] then why = 'is a room zone'
        elseif (ty == 'pit' or ty == 'pond') and (tn == 'Pen' or tn == 'MeetingHall') then why = 'is a ' .. tn .. ' zone'
        elseif ty == 'pen' and tn == 'Pond' then why = 'is a pit/pond zone'
        elseif ty == 'meeting' and (tn == 'Pond' or tn == 'Pen') then why = 'is a ' .. tn .. ' zone'
        end
        if why then
          return string.format('overlaps zone %s (%s%s) at %d-%d,%d-%d z%d, which %s', tostring(zn.id), tn,
                               zn.name and zn.name ~= '' and (' "' .. zn.name .. '"') or '', zn.x0, zn.x1, zn.y0, zn.y1, zn.z,
                               why)
        end
      end
    end
  end
  return nil
end

-- the activity zones as plain tables (read-only); z limited to `z` when given
function Z.zones(z)
  local out = {}
  local ctype = df.civzone_type
  local ok = pcall(function()
    for _, zn in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
      if z == nil or zn.z == z then
        local loc = -1
        pcall(function() loc = zn.location_id end)
        local name = ''
        pcall(function() name = dfhack.df2utf(zn.name or '') end)
        local has
        if dfhack.buildings and dfhack.buildings.containsTile then
          has = function(x, y)
            local okc, yes = pcall(dfhack.buildings.containsTile, zn, x, y)
            return not okc or yes == true
          end
        end
        out[#out + 1] = {id = zn.id, tname = ctype and ctype[zn.type] or nil, loc = loc, name = name, x0 = zn.x1, y0 = zn.y1,
                         x1 = zn.x2, y1 = zn.y2, z = zn.z, has = has}
      end
    end
  end)
  return ok and out or {}
end

-- the inbox verb zone.place {type, bbox, name?} (runner; kern: PEACE, ALERT, RECOVERY): ok, msg, {zone, zones, type, bbox,
-- cell, pond?}
function Z.verb(K, args, cmd)
  local spec, why = Z.spec(args, Z.max_tiles(K))
  if not spec then return false, 'zone.place: ' .. why end
  local reader = true
  local function tile(x, y, z)
    local okc, t = K.call('snapshot', 'tile', x, y, z)
    if not okc then reader = false end
    return okc and t or nil
  end
  local bad = Z.tiles_ok(spec.type, spec.box, tile)
  if not reader then return false, 'zone.place: no tile reader (snapshot is not running): nothing is drawn on tiles nobody read' end
  if bad then return false, 'zone.place: ' .. bad end
  local clash = Z.conflict(spec.type, spec.box, Z.zones(spec.box.z))
  if clash then return false, 'zone.place: the box ' .. clash end
  local cell, pos = Z.cell(spec.type, spec.box, spec.name)
  local t = Z.TYPES[spec.type]
  local okz, res = K.act.zone_place({cell = cell, pos = pos, box = spec.box, pond = t.pond, ztype = t.zt})
  if not okz then return false, 'zone.place: ' .. tostring(res) end
  local ids = type(res) == 'table' and res.ids or {}
  K.log('info', 'zone.place %s %d,%d-%d,%d z%d: zone %s%s', spec.type, spec.box.x0, spec.box.y0, spec.box.x1, spec.box.y1,
        spec.box.z, tostring(ids[1]), res.pond ~= nil and (res.pond and ' (kept filled)' or ' (a pit: not kept filled)') or '')
  return true, string.format('%s zone %s at %d,%d-%d,%d z%d', spec.type, tostring(ids[1]), spec.box.x0, spec.box.y0, spec.box.x1,
                             spec.box.y1, spec.box.z),
         {zone = ids[1], zones = ids, type = spec.type, bbox = {spec.box.x0, spec.box.y0, spec.box.z, spec.box.x1, spec.box.y1,
          spec.box.z}, cell = cell, pond = res.pond}
end

return Z
