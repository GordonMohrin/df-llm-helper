-- claude/pilot_refuge info [--name N] | add [--apply] [--name N] x,y,z|x1,y1,x2,y2,z ...     (df-llm-helper FEATURE-005, LIVE-UNTESTED)
-- info: the refuge burrow (default 'Zuflucht') for `python -m df_llm_helper refuge check|repair`:
--         tiles   = assigned tiles as runs "z,y,x1,x2" (max 40000 runs; truncated = true beyond)
--         targets = places the refuge needs, inside AND outside the burrow (only revealed tiles, fair play):
--                   drink/food: tiles with non-forbidden items (not carried, container not forbidden), n = items,
--                   rect = the stockpile at that tile; water: wells (rect, adjacent = true) and visible water tiles inside
--                   the burrow; hospital: hospital zones (rect). in_burrow per target. Max 300 tiles per category.
--         anchor  = config.ZUFLUCHT.probe; supply = the Lua-side check of claude/gefahr (refuge_supply)
-- add:  assign tiles to the burrow (UI: paint the burrow). Without --apply only the count (dry run). Unrevealed tiles are
--       skipped. Max 20000 tiles per call. The burrow is never created here (claude/mil refuge --apply does that).
-- Read only except `add --apply`: no items, units, designations or map changes.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local a = { ... }
local cmd = a[1] or 'info'
local opt, rest = { name = 'Zuflucht' }, {}
do
  local i = 2
  while i <= #a do
    if a[i] == '--name' then opt.name = a[i + 1] or opt.name i = i + 2
    elseif a[i] == '--apply' then opt.apply = true i = i + 1
    else rest[#rest + 1] = a[i] i = i + 1 end
  end
end
local MAXCAT, MAXRUNS, MAXADD = 300, 40000, 20000
local FOOD_CATS = { 'FOOD', 'MEAT', 'FISH', 'CHEESE', 'PLANT', 'EGG' }

local function hidden(p)
  local ok, v = pcall(util.is_hidden, p.x, p.y, p.z)
  return (not ok) or v
end
local function in_burrow(b, p)
  local ok, v = pcall(dfhack.burrows.isAssignedTile, b, p)
  return ok and v or false
end
local function usable(it)
  if it.flags.forbid or it.flags.dump or it.flags.garbage_collect or it.flags.rotten or it.flags.in_inventory then return false end
  local okc, c = pcall(dfhack.items.getContainer, it)
  if okc and c and c.flags.forbid then return false end
  return true
end
local function stockpile_rect(p)
  local ok, bl = pcall(dfhack.buildings.findAtTile, p.x, p.y, p.z)
  if not ok or not bl then return nil end
  local okt, t = pcall(function() return bl:getType() end)
  if okt and t == df.building_type.Stockpile then return { bl.x1, bl.y1, bl.x2, bl.y2, bl.z } end
  return nil
end

local b = dfhack.burrows.findByName(opt.name, true)
if not b then
  util.emit({ ok = false, error = 'burrow ' .. tostring(opt.name) .. ' not found (claude/mil refuge --apply creates Zuflucht)' })
  return
end

if cmd == 'info' then
  -- burrow tiles as runs per row
  local runs, count, truncated = {}, 0, false
  local x1, y1, z1, x2, y2, z2
  local okl, blocks = pcall(dfhack.burrows.listBlocks, b)
  for _, blk in ipairs((okl and blocks) or {}) do
    local bx, by, bz = blk.map_pos.x, blk.map_pos.y, blk.map_pos.z
    for y = 0, 15 do
      local start
      for x = 0, 16 do
        local on = x <= 15 and in_burrow(b, xyz2pos(bx + x, by + y, bz))
        if on then
          count = count + 1
          if not start then start = x end
          local px, py = bx + x, by + y
          x1, x2 = math.min(x1 or px, px), math.max(x2 or px, px)
          y1, y2 = math.min(y1 or py, py), math.max(y2 or py, py)
          z1, z2 = math.min(z1 or bz, bz), math.max(z2 or bz, bz)
        elseif start then
          if #runs < MAXRUNS then runs[#runs + 1] = string.format('%d,%d,%d,%d', bz, by + y, bx + start, bx + x - 1)
          else truncated = true end
          start = nil
        end
      end
    end
  end
  -- targets
  local targets, per = {}, {}
  local function add_target(t)
    per[t.cat] = (per[t.cat] or 0) + 1
    if per[t.cat] <= MAXCAT then targets[#targets + 1] = t end
  end
  local function items(cat, vecs)
    local seen = {}
    for _, v in ipairs(vecs) do
      local okv, vec = pcall(function() return df.global.world.items.other[v] end)
      for _, it in ipairs((okv and vec) or {}) do
        if usable(it) then
          local okp, p = pcall(dfhack.items.getPosition, it)
          if okp and p and p.x >= 0 then
            local k = p.x .. ',' .. p.y .. ',' .. p.z
            if seen[k] then seen[k].n = seen[k].n + 1
            elseif not hidden(p) then
              local t = { cat = cat, kind = 'item', x = p.x, y = p.y, z = p.z, n = 1, in_burrow = in_burrow(b, p) }
              local r = stockpile_rect(p)
              if r then t.rect, t.kind = r, 'stockpile' end
              seen[k] = t
              add_target(t)
            end
          end
        end
      end
    end
  end
  items('drink', { 'DRINK' })
  items('food', FOOD_CATS)
  local function blds(cat, kind, key, adjacent)
    local okv, vec = pcall(function() return df.global.world.buildings.other[key] end)
    for _, bl in ipairs((okv and vec) or {}) do
      local p = xyz2pos(bl.centerx, bl.centery, bl.z)
      if not hidden(p) then
        add_target({ cat = cat, kind = kind, x = p.x, y = p.y, z = p.z, rect = { bl.x1, bl.y1, bl.x2, bl.y2, bl.z },
                     adjacent = adjacent or nil, in_burrow = in_burrow(b, p), id = bl.id })
      end
    end
  end
  blds('water', 'well', 'WELL', true)
  blds('hospital', 'zone', 'ZONE_HOSPITAL', false)
  for _, blk in ipairs((okl and blocks) or {}) do      -- visible water inside the burrow (a whole-map scan is too slow)
    for x = 0, 15 do for y = 0, 15 do
      local d = blk.designation[x][y]
      if d.flow_size > 0 and not d.hidden and d.liquid_type == df.tile_liquid.Water then
        local p = xyz2pos(blk.map_pos.x + x, blk.map_pos.y + y, blk.map_pos.z)
        if in_burrow(b, p) then add_target({ cat = 'water', kind = 'water', x = p.x, y = p.y, z = p.z, adjacent = true, in_burrow = true }) end
      end
    end end
  end
  local cfg = reqscript('claude/config')
  local Z = cfg.ZUFLUCHT or {}
  local res = { ok = true, burrow = { id = b.id, name = opt.name }, tiles = runs, tile_count = count, truncated = truncated,
                bbox = x1 and { x1, y1, z1, x2, y2, z2 } or nil, targets = targets, counts = per,
                anchor = Z.probe and { Z.probe[1], Z.probe[2], Z.probe[3] } or nil, require_water = cfg.REFUGE_REQUIRE_WATER == true }
  local okg, G = pcall(reqscript, 'claude/gefahr')
  if okg and G and G.refuge_supply then
    local oks, sup = pcall(G.refuge_supply, b, true)
    if oks and sup then res.supply = { ok = sup.ok, water_ok = sup.water_ok, status = sup.status, where = sup.where, anchor = sup.anchor } end
  end
  util.emit(res)

elseif cmd == 'add' then
  local tiles, invalid = {}, {}
  for i, tok in ipairs(rest) do
    local n = {}
    for v in tostring(tok):gmatch('[^,]+') do n[#n + 1] = math.tointeger(tonumber(v)) end
    if #n == 3 and n[1] and n[2] and n[3] then tiles[#tiles + 1] = { n[1], n[2], n[1], n[2], n[3] }
    elseif #n == 5 and n[1] and n[2] and n[3] and n[4] and n[5] then tiles[#tiles + 1] = { n[1], n[2], n[3], n[4], n[5] }
    else invalid[#invalid + 1] = i - 1 end
  end
  local total = 0
  for _, r in ipairs(tiles) do total = total + (math.abs(r[3] - r[1]) + 1) * (math.abs(r[4] - r[2]) + 1) end
  if total > MAXADD then util.emit({ ok = false, error = 'too many tiles: ' .. total .. ' (max ' .. MAXADD .. ' per call)' }) return end
  local MAP = df.global.world.map
  local added, already, skipped = 0, 0, 0
  for _, r in ipairs(tiles) do
    for y = math.min(r[2], r[4]), math.max(r[2], r[4]) do
      for x = math.min(r[1], r[3]), math.max(r[1], r[3]) do
        local p = xyz2pos(x, y, r[5])
        if x < 0 or y < 0 or r[5] < 0 or x >= MAP.x_count or y >= MAP.y_count or r[5] >= MAP.z_count or hidden(p) then
          skipped = skipped + 1
        elseif in_burrow(b, p) then
          already = already + 1
        else
          if opt.apply then dfhack.burrows.setAssignedTile(b, p, true) end
          added = added + 1
        end
      end
    end
  end
  local out = { ok = true, dry = not opt.apply, burrow = b.id, requested = total, added = added, already = already, skipped = skipped }
  if #invalid > 0 then out.invalid = invalid end
  if not opt.apply then out.hint = 'dry run: --apply assigns the tiles' end
  util.emit(out)

else
  util.emit({ ok = false, error = 'usage: claude/pilot_refuge info [--name N] | add [--apply] [--name N] x,y,z|x1,y1,x2,y2,z ...' })
end
