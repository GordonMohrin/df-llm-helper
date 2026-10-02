-- claude/pickfix [--apply] [--ensure id,id,...]     (also: claude/mil pickfix)
-- E18 fix (Run 5, 01.10.2026): have all free picks distributed to dwarves with labor MINE.
-- CAUSE (measured, ERFAHRUNGEN.md 'E18 Run 5 Ursache'):
--   The engine hands out work picks (plotinfo.equipment.work_weapons/work_units) only from UNRESERVED free picks. If a squad has a
--   uniform weapon 'pick' (squad_uniform_spec subtype ITEM_WEAPON_PICK), the assignment pass reserves free picks in POSITION
--   ORDER (0,1,2..) for the positions (spec.assigned + position.assigned_items, global items_assigned) - also for positions whose
--   holders already hold a work pick, and for empty positions. The reservation is tied to the position, not the dwarf.
--   Reserved picks are blocked for work-pick assignment ('assigned, never picked up'); whoever fetches them as a uniform weapon drops them
--   again shortly after with labor MINE (routine 0 = civilian). 'mil workmode' (uniform pick only) and repeated applying made it worse
--   (emptied assigned_items left picks stuck as 'assigned' in the global pool).
-- FIX (squad/equipment update only, no item/unit manipulation): hold NO pick uniform spec.
--   1. Release reservations of picks nobody holds (assigned_items/spec.assigned -> items_unassigned).
--   2. Remove pick specs from ALL squad positions (otherwise it re-reserves immediately).
--   3. plotinfo.equipment.update.weapon = true -> engine distributes the free picks as work picks to dwarves with labor MINE
--      (measured: 5 free picks -> work_weapons 6 -> 11 within 1 s, also to dwarves without mining skill, also outside a squad).
--   3b. For each MINE dwarf without a pick, its own update flag is set (unit.uniform.pickup_flags.update) - without it the engine
--      grants no work pick to non-squad dwarves (measurement J109). Only as many dwarves as free picks.
--   4. Optional --ensure id,..: make sure labor MINE + work group Miners for these dwarves.
-- Repeatable (e.g. after new picks); without --apply only a plan.
local util = reqscript('claude/util')
if not util.require_fort() then return end
local utils = require('utils')

local args = { ... }
local opt = {}
do
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == '--ensure' then opt.ensure = args[i + 1] i = i + 2
    elseif a:sub(1, 2) == '--' then opt[a:sub(3)] = true i = i + 1
    else i = i + 1 end
  end
end
local dry = not opt.apply
local eq = df.global.plotinfo.equipment
local LOG = reqscript('claude/util').home() .. '/tools/out/mil.log'
local function log(s) util.append_log(LOG, os.date('%H:%M:%S ') .. 'pickfix ' .. s) end

local function isPick(it)
  if not it or it:getType() ~= df.item_type.WEAPON then return false end
  local d = dfhack.items.getSubtypeDef(it:getType(), it:getSubtype())
  return d ~= nil and d.id == 'ITEM_WEAPON_PICK'
end
local PICK_SUB = 7
for i, d in ipairs(df.global.world.raws.itemdefs.weapons) do if d.id == 'ITEM_WEAPON_PICK' then PICK_SUB = d.subtype end end

local result = { dry = dry, released = {}, specs_removed = 0, picks = {} }
local function return_to_pool(id)
  utils.erase_sorted(eq.items_assigned.WEAPON, id)
  local un = eq.items_unassigned.WEAPON
  for j = 0, #un - 1 do if un[j] == id then return end end
  utils.insert_sorted(un, id)
end

for _, sid in ipairs(df.global.plotinfo.main.fortress_entity.squads) do
  local s = df.squad.find(sid)
  if s then
    for pi = 0, #s.positions - 1 do
      local p = s.positions[pi]
      -- 1. Reservations (picks not held)
      for k = #p.equipment.assigned_items - 1, 0, -1 do
        local id = p.equipment.assigned_items[k]
        local it = df.item.find(id)
        if it and isPick(it) and not dfhack.items.getHolderUnit(it) then
          result.released[#result.released + 1] = { squad = s.id, pos = pi, item = id }
          if not dry then p.equipment.assigned_items:erase(k) return_to_pool(id) end
        end
      end
      -- 2. Pick specs
      for k = #p.equipment.uniform.weapon - 1, 0, -1 do
        local sp = p.equipment.uniform.weapon[k]
        if sp.item_type == df.item_type.WEAPON and sp.item_subtype == PICK_SUB then
          result.specs_removed = result.specs_removed + 1
          if not dry then
            for j = #sp.assigned - 1, 0, -1 do
              local id = sp.assigned[j]
              local it = df.item.find(id)
              if it and isPick(it) and not dfhack.items.getHolderUnit(it) then return_to_pool(id) end
            end
            p.equipment.uniform.weapon:erase(k) pcall(function() sp:delete() end)
          end
        end
      end
    end
  end
end

-- return stranded picks ('assigned' in the global pool, but entered in no position)
do
  local referenced = {}
  for _, s in ipairs(df.global.world.squads.all) do
    for i = 0, #s.positions - 1 do
      local v = s.positions[i].equipment.assigned_items
      for k = 0, #v - 1 do referenced[v[k]] = true end
    end
  end
  local vA = eq.items_assigned.WEAPON
  for k = #vA - 1, 0, -1 do
    local id = vA[k]
    local it = df.item.find(id)
    if it and isPick(it) and not referenced[id] and not dfhack.items.getHolderUnit(it) then
      result.released[#result.released + 1] = { stranded = id }
      if not dry then return_to_pool(id) end
    end
  end
end

if not dry then
  if opt.ensure then
    for id in opt.ensure:gmatch('%d+') do
      local u = df.unit.find(tonumber(id))
      if u then
        u.status.labors[df.unit_labor.MINE] = true
        pcall(dfhack.run_command, 'claude/workdetail', 'assign', id, 'Miners', 'true')
      end
    end
  end
  -- 4. Work-pick assignment only runs for dwarves with their own update flag (unit.uniform.pickup_flags.update, as with an
  --    'update equipment' for this dwarf). Non-squad dwarves are never flagged on their own (measured J109: 19 picks free,
  --    19 MINE dwarves without pick, no grant; after flag + update.weapon immediately 2/2 grants). Flag only for MINE dwarves without pick,
  --    only as many as there are free picks.
  local wu = {}
  for i = 0, #eq.work_units - 1 do wu[eq.work_units[i]] = true end
  local nfree = 0
  for _, it in ipairs(df.global.world.items.other.WEAPON) do
    if isPick(it) and not dfhack.items.getHolderUnit(it) and not it.flags.forbid and not it.flags.dump then nfree = nfree + 1 end
  end
  local cands = {}
  for _, u in ipairs(dfhack.units.getCitizens(true)) do
    if u.status.labors[df.unit_labor.MINE] and not wu[u.id] and dfhack.units.isAdult(u) and not dfhack.units.isDead(u) then
      local has = false
      for _, ii in ipairs(u.inventory) do if isPick(ii.item) then has = true break end end
      if not has then cands[#cands + 1] = u end
    end
  end
  result.mine_without_pick = #cands
  result.flagged = 0
  for _, u in ipairs(cands) do
    if result.flagged < nfree then u.uniform.pickup_flags.update = true result.flagged = result.flagged + 1 end
  end
  eq.update.weapon = true
end
for _, it in ipairs(df.global.world.items.other.WEAPON) do
  if false then end
end
for _, it in ipairs(df.global.world.items.other.WEAPON) do
  if isPick(it) then
    local h = dfhack.items.getHolderUnit(it)
    result.picks[#result.picks + 1] = { item = it.id, holder = h and h.id or nil }
  end
end
result.work_weapons = #eq.work_weapons
log(string.format('dry=%s released=%d specs=%d work_weapons=%d', tostring(dry), #result.released, result.specs_removed, #eq.work_weapons))
util.emit(result)
