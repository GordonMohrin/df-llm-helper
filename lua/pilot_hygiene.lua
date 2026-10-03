-- claude/pilot_hygiene status <start> <n> [<since_id>] | report | forbid | piles | caps
--                      | mark <n> <TYPE,TYPE,...> [--rotten] [--unforbid] [--apply]
--                      | bins_order <n> [--reserve <logs>] [--apply] | max_bins <stockpile_id> <n> [--apply]
-- (df-llm-helper spec v3-07 item hygiene + FEATURE-002 item flow, LIVE-UNTESTED)
-- status: READ ONLY. Counts loose items (on the ground, outside stockpiles/containers/buildings) in the index block
--         [start, start+n) of world.items.all, so a large world never freezes the game in one call.
--         Per type, per z (boulders), per area (fort = reachable from the fort reference, surface = outside,
--         cavern = inside but not reachable), dwarf/other corpses, already dump-marked items (pending, unreachable,
--         position sums for the centroid). Hidden tiles are only counted as 'hidden' (fair play: fog of war).
--         FEATURE-002: stock per type (stack sum of every own item not built in/removed), reachable loose stacks per
--         type, unreachable loose stacks (cavern/surface/webs), forbidden reachable corpses (other/bone/dwarf), items
--         created since <since_id> per type (inflow) and next_id (the since_id of the next snapshot).
-- report: READ ONLY. Dump zones (rectangle, overlaps a stockpile?), DumpItem jobs, idle citizens (possible haulers),
--         garbage bridges (a bridge under a dump zone: raised/lowered, items on it, linked levers) and the standing
--         orders forbid_* (FEATURE-002).
-- forbid: READ ONLY. Own forbidden items by class (container/drink/food/material/other) and drinks/food blocked by a
--         forbidden container (BUG-125: 1043 forbidden items, nobody could drink, hygiene stayed silent).
-- piles:  READ ONLY. Stockpiles (categories, tiles, free tiles, max_bins/max_barrels, bins inside), all bins (empty /
--         in a stockpile / outside), free logs, open ConstructBin orders (FEATURE-002 bin planner).
-- caps:   READ ONLY. Manager orders with their item conditions and the real stock of each condition's item type
--         (total, inside containers, loose) for the cap audit (FEATURE-002).
-- mark:   sets the UI garbage flag (item.flags.dump, exactly what the player does with 'dump' in the item menu)
--         on at most min(n, 300) loose, reachable, unforbidden items of the given types. Without --apply: dry run.
--         --unforbid (FEATURE-002): instead takes FORBIDDEN loose reachable corpses/parts/remains of the given types
--         (legacy piles) and sets forbid off + dump on (the item menu's 'forbid' toggle and 'dump').
--         Never marked (hard-coded, independent of the arguments): boulders, dwarf corpses and named corpses,
--         bones/skulls/shells/skins/leather/hair, trade goods (goblets, crafts, thread, cloth), weapons/armor,
--         bars, foreign/trader/owned items. Only ever sets flags.dump/flags.forbid (no item is moved, removed or
--         created; autodump is NOT used - item teleport is forbidden).
-- bins_order: ONE one-off manager order 'ConstructBin' (wood) of n bins (n <= 50), like the manager screen; refused
--         while a ConstructBin order is still open or when free logs < n + reserve. Without --apply: dry run.
-- max_bins: the stockpile's container setting 'max bins' (UI stockpile settings). Without --apply: dry run.
--         bins_order/max_bins --apply need the player's exception-register entry FP14 (df-llm-helper refuses
--         the command otherwise).
local util = reqscript('claude/util')
if not util.require_fort() then return end

local a = { ... }
local cmd = a[1] or 'status'
local IT = df.item_type
local HARD_CAP = 300

local function safe(f, d) local ok, v = pcall(f) if ok and v ~= nil then return v end return d end

-- types that may be marked at all (everything else is refused even if requested)
local MARKABLE = { CORPSE = true, CORPSEPIECE = true, REMAINS = true }
local FOOD_ROT = { FOOD = true, MEAT = true, FISH = true, FISH_RAW = true, PLANT = true, PLANT_GROWTH = true, EGG = true,
                   CHEESE = true, GLOB = true }
-- never marked (player rules: boulders are building material; trade goods; barracks gear)
local NEVER = { BOULDER = true, BAR = true, WEAPON = true, ARMOR = true, SHIELD = true, HELM = true, GLOVES = true,
                SHOES = true, PANTS = true, AMMO = true, SIEGEAMMO = true, TRAPCOMP = true, GOBLET = true,
                FIGURINE = true, AMULET = true, BRACELET = true, EARRING = true, CROWN = true, RING = true,
                SCEPTER = true, TOTEM = true, INSTRUMENT = true, TOY = true, THREAD = true, CLOTH = true,
                SKIN_TANNED = true, GEM = true, SMALLGEM = true, ROUGH = true, BLOCKS = true, WOOD = true, TOOL = true }
local CORPSE_T = { CORPSE = true, CORPSEPIECE = true, REMAINS = true }
local BONE_FLAGS = { 'bone', 'skull', 'shell', 'skin', 'leather', 'hair_wool', 'yarn', 'horn', 'tooth', 'pearl', 'ivory',
                     'silk' }
local BONE_MATS = { 'BONE', 'SHELL', 'LEATHER', 'HORN', 'TOOTH', 'PEARL', 'SILK', 'YARN' }

local FORT_RACE = safe(function() return df.global.plotinfo.race_id end, -1)

local function tname(it) return IT[it:getType()] or '?' end

-- loose = on the ground, not in a container/building/inventory/job, not in a stockpile, not trader/foreign/owned
local function loose(it)
  local f = it.flags
  if f.removed or f.in_inventory or f.in_building or f.in_job or f.garbage_collect or f.trader or f.hostile
    or f.foreign or f.owned then return false end
  if not f.on_ground then return false end
  if dfhack.items.getGeneralRef(it, df.general_ref_type.CONTAINED_IN_ITEM) then return false end
  local x, y, z = dfhack.items.getPosition(it)
  if not x then return false end
  local b = dfhack.buildings.findAtTile(xyz2pos(x, y, z))
  if b and b:getType() == df.building_type.Stockpile then return false end
  return true, x, y, z
end

-- dwarf corpse (fort race), corpse of a known unit of the fort race, or a named (historical) corpse: never marked.
-- Any read error counts as 'dwarf' (fail safe).
local function is_dwarf_corpse(it, t)
  if not CORPSE_T[t] then return false end
  local ok, r = pcall(function()
    if it.race == FORT_RACE then return true end
    local uid = safe(function() return it.unit_id end, -1)
    if uid >= 0 then
      local u = df.unit.find(uid)
      if u and u.race == FORT_RACE then return true end
    end
    if safe(function() return it.hist_figure_id end, -1) >= 0 then return true end
    return false
  end)
  return (not ok) or r
end

-- bones/skulls/shells/skins/leather/hair (crafting material): corpse flags or material flags; each read is protected
local function is_bone_or_skin(it)
  local cf = safe(function() return it.corpse_flags end, nil)
  if cf then
    for _, k in ipairs(BONE_FLAGS) do
      if safe(function() return cf[k] end, false) == true then return true end
    end
  end
  local fl = safe(function() local mi = dfhack.matinfo.decode(it) return mi and mi.material and mi.material.flags end, nil)
  if fl then
    for _, k in ipairs(BONE_MATS) do
      if safe(function() return fl[k] end, false) == true then return true end
    end
  end
  return false
end

-- reference tiles inside the fort for reachability: EVERY config FORT_REFS entry plus up to 5 citizens standing on an
-- inside tile (BUG-210: FORT_REFS[1] alone was a surface point outside the closed gatehouse -> no item counted 'fort')
local function fort_refs()
  local refs = {}
  local cfg = safe(function() return reqscript('claude/config') end, nil)
  for _, r in ipairs(cfg and cfg.FORT_REFS or {}) do
    if type(r) == 'table' and r[3] then refs[#refs + 1] = xyz2pos(r[1], r[2], r[3]) end
  end
  local cit = 0
  for _, u in ipairs(safe(function() return dfhack.units.getCitizens(true) end, {})) do
    if cit >= 5 then break end
    if u.pos.x >= 0 then
      local fl = dfhack.maps.getTileFlags(u.pos.x, u.pos.y, u.pos.z)
      if fl and not fl.outside then
        refs[#refs + 1] = xyz2pos(u.pos.x, u.pos.y, u.pos.z)
        cit = cit + 1
      end
    end
  end
  return refs
end

local REFS = fort_refs()
local REF = REFS[1]
local function reachable(x, y, z)
  if #REFS == 0 then return true end
  local p = xyz2pos(x, y, z)
  for _, r in ipairs(REFS) do
    if safe(function() return dfhack.maps.canWalkBetween(r, p) end, false) then return true end
  end
  return false
end

-- for COUNTING only (status): corpse of the fort race (item race or its unit). Named invaders (hist figure) are
-- 'other' here (BUG-210); the mark filter keeps the fail-safe is_dwarf_corpse.
local function fort_race_corpse(it, t)
  if not CORPSE_T[t] then return false end
  if safe(function() return it.race end, -1) == FORT_RACE then return true end
  local uid = safe(function() return it.unit_id end, -1)
  if uid >= 0 then
    local u = safe(function() return df.unit.find(uid) end, nil)
    if u and u.race == FORT_RACE then return true end
  end
  return false
end

local function area_of(x, y, z)
  local fl = dfhack.maps.getTileFlags(x, y, z)
  if not fl or fl.hidden then return 'hidden' end
  if fl.outside then return 'surface' end
  if reachable(x, y, z) then return 'fort' end
  return 'cavern'
end

local function inc(t, k, n) t[k] = (t[k] or 0) + (n or 1) end

-- FEATURE-002: an item that belongs to the fort's stock (not built in, not removed, not a trader's/foreign/hostile one)
local function stock_item(it)
  local f = it.flags
  return not (f.removed or f.trader or f.foreign or f.hostile or f.construction or f.in_building or f.garbage_collect)
end

local function stack(it) return safe(function() return it:getStackSize() end, 1) end

if cmd == 'status' then
  local all = df.global.world.items.all
  local total = #all
  local start = math.max(0, tonumber(a[2]) or 0)
  local n = math.max(1, math.min(50000, tonumber(a[3]) or 20000))
  local since = tonumber(a[4])                   -- next_id of the previous flow snapshot (nil: no inflow count)
  local stop = math.min(total, start + n)
  local out = { ok = true, start = start, next = stop, total = total, done = stop >= total, scanned = stop - start,
                loose = 0, by_type = {}, boulder_z = {}, area = {}, corpses = { dwarf = 0, other = 0, other_fort = 0 },
                marked = { pending = 0, unreachable = 0, sx = 0, sy = 0, sz = 0 }, rotten = 0, ref = REF and { REF.x, REF.y, REF.z } or nil,
                refs = #REFS, stock = {}, new = {}, reach_type = {}, unreach = { cavern = 0, surface = 0, thread = 0 },
                forb_corpses = { other = 0, bone = 0, dwarf = 0 }, since = since,
                next_id = safe(function() return df.global.item_next_id end, nil) }
  for i = start, stop - 1 do
    local it = all[i]
    local t = tname(it)
    if stock_item(it) then
      local k = stack(it)
      inc(out.stock, t, k)
      if since and safe(function() return it.id end, -1) >= since then inc(out.new, t, k) end
    end
    local ok, x, y, z = loose(it)
    if ok then
      local ar = area_of(x, y, z)
      if ar == 'hidden' then
        inc(out.area, 'hidden')
      else
        out.loose = out.loose + 1
        inc(out.by_type, t)
        inc(out.area, ar)
        if t == 'BOULDER' then inc(out.boulder_z, tostring(z)) end
        local reach = ar == 'fort' or (ar == 'surface' and reachable(x, y, z))
        if reach then
          inc(out.reach_type, t)
        else
          local u = out.unreach
          if ar == 'cavern' then u.cavern = u.cavern + 1 else u.surface = u.surface + 1 end
          if t == 'THREAD' then u.thread = u.thread + 1 end
        end
        if CORPSE_T[t] then
          if fort_race_corpse(it, t) then out.corpses.dwarf = out.corpses.dwarf + 1
          else
            out.corpses.other = out.corpses.other + 1
            if ar == 'fort' then out.corpses.other_fort = out.corpses.other_fort + 1 end
          end
          if reach and it.flags.forbid and not safe(function() return it.flags.artifact end, false) then
            local fc = out.forb_corpses           -- FEATURE-002: legacy forbidden piles (same filter as mark --unforbid)
            if is_dwarf_corpse(it, t) then fc.dwarf = fc.dwarf + 1
            elseif is_bone_or_skin(it) then fc.bone = fc.bone + 1
            else fc.other = fc.other + 1 end
          end
        end
        if FOOD_ROT[t] and safe(function() return it.flags.rotten end, false) then out.rotten = out.rotten + 1 end
        if it.flags.dump then
          local m = out.marked
          m.pending = m.pending + 1
          m.sx, m.sy, m.sz = m.sx + x, m.sy + y, m.sz + z
          if ar ~= 'fort' and ar ~= 'surface' then m.unreachable = m.unreachable + 1 end
        end
      end
    end
  end
  util.emit(out)
elseif cmd == 'report' then
  local zones, piles = {}, {}
  for _, b in ipairs(df.global.world.buildings.all) do
    local bt = b:getType()
    if bt == df.building_type.Stockpile then piles[#piles + 1] = b end
    if bt == df.building_type.Civzone and safe(function() return df.civzone_type[b.type] end, '') == 'Dump' then
      zones[#zones + 1] = { id = b.id, x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, z = b.z, under_stockpile = false }
    end
  end
  for _, zn in ipairs(zones) do
    for _, p in ipairs(piles) do
      if p.z == zn.z and p.x1 <= zn.x2 and zn.x1 <= p.x2 and p.y1 <= zn.y2 and zn.y1 <= p.y2 then zn.under_stockpile = true end
    end
  end
  local jobs = 0
  local l = df.global.world.jobs.list.next
  while l do
    local j = l.item
    if j and df.job_type[j.job_type] == 'DumpItem' then jobs = jobs + 1 end
    l = l.next
  end
  local idle, cits = 0, 0
  for _, u in ipairs(dfhack.units.getCitizens(true)) do
    cits = cits + 1
    if not u.job.current_job then idle = idle + 1 end
  end
  -- FEATURE-002: garbage bridges = bridges under a dump zone. State from the bridge itself (gate_flags), items lying on
  -- its tiles by type, levers linked to it (mechanism -> BUILDING_TRIGGER). Pulling the lever stays a player action.
  local bridges = {}
  for _, b in ipairs(df.global.world.buildings.all) do
    if safe(function() return df.building_type[b:getType()] end, '') == 'Bridge' then
      for _, zn in ipairs(zones) do
        if b.z == zn.z and b.x1 <= zn.x2 and zn.x1 <= b.x2 and b.y1 <= zn.y2 and zn.y1 <= b.y2 then
          local gf = safe(function() return b.gate_flags end, nil)
          local st = '?'
          if gf then
            local r = safe(function() return gf.raised end, nil)
            if r == nil then r = safe(function() return gf.closed end, nil) end
            if safe(function() return gf.raising or gf.lowering end, false) then st = 'moving'
            elseif r ~= nil then st = r and 'raised' or 'lowered' end
          end
          local levers = {}
          for _, m in ipairs(safe(function() return b.linked_mechanisms end, {})) do
            local ref = safe(function() return dfhack.items.getGeneralRef(m, df.general_ref_type.BUILDING_TRIGGER) end, nil)
            local id = ref and safe(function() return ref.building_id end, nil)
            if id then levers[#levers + 1] = id end
          end
          bridges[#bridges + 1] = { id = b.id, x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, z = b.z, state = st,
                                    zone = zn.id, levers = levers, items = 0, by_type = {} }
          break
        end
      end
    end
  end
  if #bridges > 0 then
    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
      if it.flags.on_ground and not it.flags.removed then
        local x, y, z = dfhack.items.getPosition(it)
        if x then
          for _, br in ipairs(bridges) do
            if z == br.z and x >= br.x1 and x <= br.x2 and y >= br.y1 and y <= br.y2 then
              br.items = br.items + 1
              inc(br.by_type, tname(it))
              break
            end
          end
        end
      end
    end
  end
  -- standing orders that forbid items on their own (read only; never changed by df-llm-helper)
  local standing = {}
  for _, k in ipairs({ 'forbid_other_dead_items', 'forbid_own_dead_items', 'forbid_used_ammo', 'forbid_other_nohunt',
                       'forbid_own_dead' }) do
    local v = safe(function() return df.global['standing_orders_' .. k] end, nil)
    if v == nil then v = safe(function() return df.global.plotinfo['standing_orders_' .. k] end, nil) end
    if v ~= nil then standing[k] = (v == true or v == 1) end
  end
  util.emit({ ok = true, dump_zones = zones, dump_jobs = jobs, idle = idle, citizens = cits,
              ref = REF and { REF.x, REF.y, REF.z } or nil, bridges = bridges, standing = standing })
elseif cmd == 'mark' then
  local want = math.max(0, math.min(HARD_CAP, tonumber(a[2]) or 0))
  local types, rotten, apply, unforbid = {}, false, false, false
  for i = 3, #a do
    if a[i] == '--apply' then apply = true
    elseif a[i] == '--rotten' then rotten = true
    elseif a[i] == '--unforbid' then unforbid = true
    elseif a[i] ~= '--dry' then
      for t in tostring(a[i]):gmatch('[%w_]+') do
        if MARKABLE[t] and not NEVER[t] then types[t] = true end
      end
    end
  end
  if unforbid then rotten = false end             -- --unforbid: only corpses/parts/remains of the given types
  local out = { ok = true, applied = apply, marked = 0, candidates = 0, cap = want, unforbid = unforbid, ids = {},
                refused = { boulder = 0, dwarf = 0, bone = 0, unreachable = 0 } }
  for _, it in ipairs(df.global.world.items.all) do
    if out.candidates >= want then break end
    local ok, x, y, z = loose(it)
    -- normal mode: unforbidden items only; --unforbid: forbidden items only (legacy piles)
    if ok and not it.flags.dump and (it.flags.forbid == unforbid)
      and not safe(function() return it.flags.artifact end, false) then
      local t = tname(it)
      local fl = dfhack.maps.getTileFlags(x, y, z)
      local visible = fl and not fl.hidden
      local hit = visible and (types[t] or (rotten and FOOD_ROT[t] and safe(function() return it.flags.rotten end, false)))
      if t == 'BOULDER' or NEVER[t] then
        if t == 'BOULDER' then out.refused.boulder = out.refused.boulder + 1 end
        hit = false
      elseif hit and is_dwarf_corpse(it, t) then
        out.refused.dwarf = out.refused.dwarf + 1
        hit = false
      elseif hit and CORPSE_T[t] and is_bone_or_skin(it) then
        out.refused.bone = out.refused.bone + 1
        hit = false
      elseif hit and not (fl.outside or reachable(x, y, z)) then
        out.refused.unreachable = out.refused.unreachable + 1
        hit = false
      end
      if hit then
        out.candidates = out.candidates + 1
        out.ids[#out.ids + 1] = safe(function() return it.id end, -1)
        if apply then
          if unforbid then it.flags.forbid = false end   -- the item menu's forbid toggle (own legacy pile only)
          it.flags.dump = true
        end
        out.marked = out.marked + 1
      end
    end
  end
  if not apply then out.marked = 0 end
  util.emit(out)
elseif cmd == 'forbid' then
  -- BUG-125: own items with the forbid flag by class, plus drinks/food that are not forbidden themselves but sit in a
  -- forbidden container (dwarves cannot take them either). READ ONLY; trader/foreign/hostile/removed items and
  -- constructions/installed furniture are not counted (not the fort's stock).
  local CONT = { BARREL = true, BIN = true, BOX = true, BUCKET = true, FLASK = true }
  local MAT = { BLOCKS = true, WOOD = true, BAR = true, BOULDER = true }
  local out = { ok = true, total = 0, classes = { container = 0, drink = 0, food = 0, material = 0, other = 0 },
                drink = { total = 0, blocked = 0, in_forbidden_container = 0 },
                food = { total = 0, blocked = 0, in_forbidden_container = 0 } }
  local function forbidden_container(it)
    local c, d = safe(function() return dfhack.items.getContainer(it) end, nil), 0
    while c and d < 5 do
      if c.flags.forbid then return true end
      c, d = safe(function() return dfhack.items.getContainer(c) end, nil), d + 1
    end
    return false
  end
  for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
    local f = it.flags
    if not (f.removed or f.trader or f.foreign or f.hostile or f.construction or f.in_building or f.garbage_collect) then
      local t = tname(it)
      local n = safe(function() return it:getStackSize() end, 1)
      local edible = FOOD_ROT[t] and not f.rotten
      local cls = (t == 'DRINK' and 'drink') or (edible and 'food') or nil
      local in_forb = (cls ~= nil) and not f.forbid and forbidden_container(it)
      if cls then
        local c = out[cls]
        c.total = c.total + n
        if f.forbid or in_forb then c.blocked = c.blocked + n end
        if in_forb then c.in_forbidden_container = c.in_forbidden_container + n end
      end
      if f.forbid then
        local k = cls or (CONT[t] and 'container') or (MAT[t] and 'material') or 'other'
        if t == 'TOOL' and safe(function() return #dfhack.items.getContainedItems(it) > 0 end, false) then k = 'container' end
        out.classes[k] = out.classes[k] + 1
        out.total = out.total + 1
      end
    end
  end
  util.emit(out)
elseif cmd == 'piles' then
  -- FEATURE-002 bin planner, READ ONLY: stockpiles with categories, tiles, free tiles (no item on the tile), container
  -- settings and the bins inside; all bins; free logs; open ConstructBin orders.
  local CATS = { 'animals', 'food', 'furniture', 'corpses', 'refuse', 'stone', 'ammo', 'coins', 'bars_blocks', 'gems',
                 'finished_goods', 'leather', 'cloth', 'wood', 'weapons', 'armor', 'sheet' }
  local function has_item(x, y, z)
    return safe(function() return dfhack.maps.getTileBlock(x, y, z).occupancy[x % 16][y % 16].item end, false) == true
  end
  local function in_extents(p, x, y)
    local ok, v = pcall(function()
      local r = p.room
      if not r.extents or r.width <= 0 then return true end
      return r.extents[(y - r.y) * r.width + (x - r.x)] ~= 0
    end)
    return (not ok) or v
  end
  local list = safe(function() return df.global.world.buildings.other.STOCKPILE end, nil)
  if not list then
    list = {}
    for _, b in ipairs(df.global.world.buildings.all) do
      if b:getType() == df.building_type.Stockpile then list[#list + 1] = b end
    end
  end
  local piles, by_id = {}, {}
  for _, p in ipairs(list) do
    local cats = {}
    for _, c in ipairs(CATS) do
      if safe(function() return p.settings.flags[c] end, false) == true then cats[#cats + 1] = c end
    end
    local tiles, free = 0, 0
    for x = p.x1, p.x2 do
      for y = p.y1, p.y2 do
        if in_extents(p, x, y) then
          tiles = tiles + 1
          if not has_item(x, y, p.z) then free = free + 1 end
        end
      end
    end
    local e = { id = p.id, name = safe(function() return p.name end, ''), z = p.z, x1 = p.x1, y1 = p.y1, x2 = p.x2,
                y2 = p.y2, cats = cats, tiles = tiles, free = free, bins = 0, bins_empty = 0,
                max_bins = safe(function() return p.storage.max_bins end, nil),
                max_barrels = safe(function() return p.storage.max_barrels end, nil) }
    piles[#piles + 1] = e
    by_id[p.id] = e
  end
  local bins = { total = 0, empty = 0, in_pile = 0, outside = 0, in_job = 0 }
  for _, it in ipairs(safe(function() return df.global.world.items.other.BIN end, {})) do
    local f = it.flags
    if not (f.removed or f.trader or f.foreign or f.hostile or f.garbage_collect) then
      bins.total = bins.total + 1
      local empty = safe(function() return #dfhack.items.getContainedItems(it) == 0 end, false)
      if empty then bins.empty = bins.empty + 1 end
      if f.in_job then bins.in_job = bins.in_job + 1 end
      local x, y, z = dfhack.items.getPosition(it)
      local b = x and dfhack.buildings.findAtTile(xyz2pos(x, y, z)) or nil
      local e = b and b:getType() == df.building_type.Stockpile and by_id[b.id] or nil
      if e then
        bins.in_pile = bins.in_pile + 1
        e.bins = e.bins + 1
        if empty then e.bins_empty = e.bins_empty + 1 end
      else
        bins.outside = bins.outside + 1
      end
    end
  end
  local wood = 0
  for _, it in ipairs(safe(function() return df.global.world.items.other.WOOD end, {})) do
    local f = it.flags
    if not (f.removed or f.trader or f.foreign or f.hostile or f.forbid or f.dump or f.in_job or f.in_building
            or f.construction or f.garbage_collect) then wood = wood + stack(it) end
  end
  local orders = {}
  for _, o in ipairs(safe(function() return df.global.world.manager_orders.all end, {})) do
    if safe(function() return df.job_type[o.job_type] end, '') == 'ConstructBin' then
      orders[#orders + 1] = { id = o.id, left = o.amount_left, total = o.amount_total }
    end
  end
  util.emit({ ok = true, piles = piles, bins = bins, wood = wood, bin_orders = orders })
elseif cmd == 'caps' then
  -- FEATURE-002 cap audit, READ ONLY: every manager order with item conditions + the real stock of those item types
  local function flaglist(f)
    local t = {}
    pcall(function() for k, v in pairs(f) do if v == true then t[#t + 1] = tostring(k) end end end)
    table.sort(t)
    return table.concat(t, '+')
  end
  local rows, want = {}, {}
  for _, o in ipairs(safe(function() return df.global.world.manager_orders.all end, {})) do
    local conds = {}
    for _, c in ipairs(safe(function() return o.item_conditions end, {})) do
      local ty = safe(function() return df.item_type[c.item_type] end, nil) or '*'
      local fl = {}
      for _, f in ipairs({ flaglist(safe(function() return c.flags1 end, {})), flaglist(safe(function() return c.flags2 end, {})),
                           flaglist(safe(function() return c.flags3 end, {})) }) do
        if f ~= '' then fl[#fl + 1] = f end
      end
      conds[#conds + 1] = { cmp = safe(function() return df.logic_condition_type[c.compare_type] end, '?'),
                            value = safe(function() return c.compare_val end, 0), type = ty,
                            subtype = safe(function() return c.item_subtype end, -1), flags = table.concat(fl, '+') }
      if ty ~= '*' then want[ty] = true end
    end
    if #conds > 0 then
      rows[#rows + 1] = { id = o.id, job = safe(function() return df.job_type[o.job_type] end, '?'),
                          freq = safe(function() return df.workquota_frequency_type[o.frequency] end, '?'),
                          left = safe(function() return o.amount_left end, 0),
                          total = safe(function() return o.amount_total end, 0), conds = conds }
    end
  end
  local stock = {}
  for t in pairs(want) do stock[t] = { stock = 0, in_container = 0, loose = 0 } end
  if next(want) then
    for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
      local e = stock[tname(it)]
      if e and stock_item(it) then
        local k = stack(it)
        e.stock = e.stock + k
        if safe(function() return dfhack.items.getContainer(it) end, nil) then e.in_container = e.in_container + k
        elseif loose(it) then e.loose = e.loose + k end
      end
    end
  end
  util.emit({ ok = true, orders = rows, stock = stock })
elseif cmd == 'bins_order' then
  -- ONE one-off ConstructBin order (manager screen); refused while one is open or without enough free logs
  local n = math.max(1, math.min(50, tonumber(a[2]) or 1))
  local reserve, apply = 0, false
  for i = 3, #a do
    if a[i] == '--apply' then apply = true
    elseif a[i] == '--reserve' then reserve = math.max(0, tonumber(a[i + 1]) or 0) end
  end
  for _, o in ipairs(safe(function() return df.global.world.manager_orders.all end, {})) do
    if safe(function() return df.job_type[o.job_type] end, '') == 'ConstructBin' and safe(function() return o.amount_left end, 0) > 0 then
      util.emit({ ok = false, applied = false, reason = 'a ConstructBin order is still open (#' .. o.id .. ', ' ..
                  o.amount_left .. ' left)' })
      return
    end
  end
  local wood = 0
  for _, it in ipairs(safe(function() return df.global.world.items.other.WOOD end, {})) do
    local f = it.flags
    if not (f.removed or f.trader or f.foreign or f.hostile or f.forbid or f.dump or f.in_job or f.in_building
            or f.construction or f.garbage_collect) then wood = wood + stack(it) end
  end
  if wood < n + reserve then
    util.emit({ ok = false, applied = false, wood = wood, reason = 'not enough free logs: ' .. wood .. ' < ' .. n ..
                ' bins + ' .. reserve .. ' reserve' })
    return
  end
  local out = { ok = true, applied = apply, n = n, wood = wood }
  if apply then
    local ok, err = pcall(function()
      local wo = reqscript('workorder')
      local list = wo.preprocess_orders({ job = 'ConstructBin', amount_total = n, frequency = 'OneTime',
                                          material_category = { 'wood' } })
      wo.fillin_defaults(list)
      local mo = df.global.world.manager_orders.all
      local before = #mo
      wo.create_orders(list, true)
      if #mo > before then out.order_id = mo[#mo - 1].id end
    end)
    if not ok then out.ok, out.applied, out.reason = false, false, tostring(err) end
  end
  util.emit(out)
elseif cmd == 'max_bins' then
  -- the stockpile's container setting 'max bins' (UI stockpile settings)
  local id, n = tonumber(a[2]), math.max(0, math.min(1000, tonumber(a[3]) or 0))
  local apply = false
  for i = 4, #a do if a[i] == '--apply' then apply = true end end
  local p = id and safe(function() return df.building.find(id) end, nil)
  if not p or p:getType() ~= df.building_type.Stockpile then
    util.emit({ ok = false, applied = false, reason = 'no stockpile #' .. tostring(a[2]) })
    return
  end
  local before = safe(function() return p.storage.max_bins end, nil)
  if apply then p.storage.max_bins = n end
  util.emit({ ok = true, applied = apply, id = id, before = before, after = apply and n or before, want = n })
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_hygiene status <start> <n> [<since_id>] | report | forbid | piles | caps | ' ..
              'mark <n> <TYPES> [--rotten] [--unforbid] [--apply] | bins_order <n> [--reserve <logs>] [--apply] | ' ..
              'max_bins <stockpile_id> <n> [--apply]' })
end
