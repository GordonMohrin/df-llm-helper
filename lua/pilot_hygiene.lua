-- claude/pilot_hygiene status <start> <n> | report | mark <n> <TYPE,TYPE,...> [--rotten] [--apply]
-- (df-llm-helper spec v3-07 item hygiene, LIVE-UNTESTED)
-- status: READ ONLY. Counts loose items (on the ground, outside stockpiles/containers/buildings) in the index block
--         [start, start+n) of world.items.all, so a large world never freezes the game in one call.
--         Per type, per z (boulders), per area (fort = reachable from the fort reference, surface = outside,
--         cavern = inside but not reachable), dwarf/other corpses, already dump-marked items (pending, unreachable,
--         position sums for the centroid). Hidden tiles are only counted as 'hidden' (fair play: fog of war).
-- report: READ ONLY. Dump zones (rectangle, overlaps a stockpile?), DumpItem jobs, idle citizens (possible haulers).
-- mark:   sets the UI garbage flag (item.flags.dump, exactly what the player does with 'dump' in the item menu)
--         on at most min(n, 300) loose, reachable, unforbidden items of the given types. Without --apply: dry run.
--         Never marked (hard-coded, independent of the arguments): boulders, dwarf corpses and named corpses,
--         bones/skulls/shells/skins/leather/hair, trade goods (goblets, crafts, thread, cloth), weapons/armor,
--         bars, foreign/trader/owned items. Only ever sets flags.dump (no item is moved, removed or created;
--         autodump is NOT used - item teleport is forbidden).
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

-- reference tile inside the fort for reachability: config FORT_REFS[1], otherwise the first citizen
local function fort_ref()
  local cfg = safe(function() return reqscript('claude/config') end, nil)
  local r = cfg and cfg.FORT_REFS and cfg.FORT_REFS[1]
  if r then return xyz2pos(r[1], r[2], r[3]) end
  for _, u in ipairs(dfhack.units.getCitizens(true)) do
    if u.pos.x >= 0 then return xyz2pos(u.pos.x, u.pos.y, u.pos.z) end
  end
  return nil
end

local REF = fort_ref()
local function reachable(x, y, z)
  if not REF then return true end
  return safe(function() return dfhack.maps.canWalkBetween(REF, xyz2pos(x, y, z)) end, false)
end

local function area_of(x, y, z)
  local fl = dfhack.maps.getTileFlags(x, y, z)
  if not fl or fl.hidden then return 'hidden' end
  if fl.outside then return 'surface' end
  if reachable(x, y, z) then return 'fort' end
  return 'cavern'
end

local function inc(t, k, n) t[k] = (t[k] or 0) + (n or 1) end

if cmd == 'status' then
  local all = df.global.world.items.all
  local total = #all
  local start = math.max(0, tonumber(a[2]) or 0)
  local n = math.max(1, math.min(50000, tonumber(a[3]) or 20000))
  local stop = math.min(total, start + n)
  local out = { ok = true, start = start, next = stop, total = total, done = stop >= total, scanned = stop - start,
                loose = 0, by_type = {}, boulder_z = {}, area = {}, corpses = { dwarf = 0, other = 0, other_fort = 0 },
                marked = { pending = 0, unreachable = 0, sx = 0, sy = 0, sz = 0 }, rotten = 0, ref = REF and { REF.x, REF.y, REF.z } or nil }
  for i = start, stop - 1 do
    local it = all[i]
    local ok, x, y, z = loose(it)
    if ok then
      local ar = area_of(x, y, z)
      if ar == 'hidden' then
        inc(out.area, 'hidden')
      else
        local t = tname(it)
        out.loose = out.loose + 1
        inc(out.by_type, t)
        inc(out.area, ar)
        if t == 'BOULDER' then inc(out.boulder_z, tostring(z)) end
        if CORPSE_T[t] then
          if is_dwarf_corpse(it, t) then out.corpses.dwarf = out.corpses.dwarf + 1
          else
            out.corpses.other = out.corpses.other + 1
            if ar == 'fort' then out.corpses.other_fort = out.corpses.other_fort + 1 end
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
  util.emit({ ok = true, dump_zones = zones, dump_jobs = jobs, idle = idle, citizens = cits,
              ref = REF and { REF.x, REF.y, REF.z } or nil })
elseif cmd == 'mark' then
  local want = math.max(0, math.min(HARD_CAP, tonumber(a[2]) or 0))
  local types, rotten, apply = {}, false, false
  for i = 3, #a do
    if a[i] == '--apply' then apply = true
    elseif a[i] == '--rotten' then rotten = true
    elseif a[i] ~= '--dry' then
      for t in tostring(a[i]):gmatch('[%w_]+') do
        if MARKABLE[t] and not NEVER[t] then types[t] = true end
      end
    end
  end
  local out = { ok = true, applied = apply, marked = 0, candidates = 0, cap = want,
                refused = { boulder = 0, dwarf = 0, bone = 0, unreachable = 0 } }
  for _, it in ipairs(df.global.world.items.all) do
    if out.marked >= want then break end
    local ok, x, y, z = loose(it)
    if ok and not it.flags.dump and not it.flags.forbid and not safe(function() return it.flags.artifact end, false) then
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
        if apply then it.flags.dump = true end
        out.marked = out.marked + 1
      end
    end
  end
  if not apply then out.marked = 0 end
  util.emit(out)
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_hygiene status <start> <n> | report | mark <n> <TYPES> [--rotten] [--apply]' })
end
