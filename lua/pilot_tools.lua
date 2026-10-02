-- claude/pilot_tools status     (dfpilot spec v3-05 tool/pick manager, LIVE-UNTESTED)
-- Read-only measurement for `dfpilot tools`: picks (total, free with location, holders), number of granted work picks,
-- citizens (MINE labor, pick held, idle, hunger/thirst, squad, child, wounds, hospital zone, mining skill),
-- open dig jobs and current diggers. All actions go through existing scripts:
--   claude/pickfix --apply                       (frees reservations, sets equipment update flags; FP08 register entry)
--   claude/workdetail assign <id> Miners true    (work detail menu)
-- This script never writes anything.
local util = reqscript('claude/util')
local utils = require('utils')
if not util.require_fort() then return end

local a = { ... }
local cmd = a[1] or 'status'

local function safe(f, d) local ok, v = pcall(f) if ok and v ~= nil then return v end return d end

local DIG = { Dig = true, DigChannel = true, CarveUpwardStaircase = true, CarveDownwardStaircase = true,
              CarveUpDownStaircase = true, CarveRamp = true }

local function is_pick(it)
  if not it or it:getType() ~= df.item_type.WEAPON then return false end
  local d = dfhack.items.getSubtypeDef(it:getType(), it:getSubtype())
  return d ~= nil and d.id == 'ITEM_WEAPON_PICK'
end

local function in_squad(u) return safe(function() return u.military.squad_id ~= -1 end, false) end

local function holds_pick(u)
  for _, inv in ipairs(u.inventory) do if is_pick(inv.item) then return true end end
  return false
end

-- hospital zones (location of type HOSPITAL attached to a zone; same approach as pilot_care.lua)
local function hospital_zones()
  local locs, out = {}, {}
  local site = safe(function() return df.global.world.world_data.active_site[0] end, nil)
  if site then
    for _, ab in ipairs(site.buildings) do
      if safe(function() return ab:getType() == df.abstract_building_type.HOSPITAL end, false) then locs[ab.id] = true end
    end
  end
  for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
    if locs[safe(function() return z.location_id end, -1)] then
      out[#out + 1] = { id = z.id, x1 = z.x1, y1 = z.y1, x2 = z.x2, y2 = z.y2, z = z.z }
    end
  end
  return out
end

local function inside(p, hs)
  for _, h in ipairs(hs) do
    if p.z == h.z and p.x >= h.x1 and p.x <= h.x2 and p.y >= h.y1 and p.y <= h.y2 then return h.id end
  end
  return nil
end

if cmd == 'status' then
  local total, free, where = 0, 0, {}
  for _, it in ipairs(df.global.world.items.other.WEAPON) do
    if is_pick(it) then
      total = total + 1
      local holder = safe(function() return dfhack.items.getHolderUnit(it) end, nil)
      if not holder and not it.flags.forbid and not it.flags.dump and not it.flags.trader then
        free = free + 1
        local ok, x, y, z = pcall(dfhack.items.getPosition, it)
        local c = safe(function() return dfhack.items.getContainer(it) end, nil)
        local kind = c and safe(function() return df.item_type[c:getType()] end, 'CONTAINER') or 'loose'
        local key = ok and x and string.format('%s (%d,%d,%d)', kind, x, y, z) or kind
        where[key] = (where[key] or 0) + 1
      end
    end
  end
  local wl = {}
  for k, n in pairs(where) do wl[#wl + 1] = { where = k, n = n } end
  table.sort(wl, function(p, q) return p.n > q.n end)
  local dig_open, diggers = 0, 0
  for _, job in utils.listpairs(df.global.world.jobs.list) do
    if DIG[df.job_type[job.job_type]] then dig_open = dig_open + 1 end
  end
  local hs = hospital_zones()
  local cit = {}
  for _, u in ipairs(dfhack.units.getCitizens()) do
    local j = u.job.current_job
    local jn = j and df.job_type[j.job_type] or nil
    if jn and DIG[jn] then diggers = diggers + 1 end
    cit[#cit + 1] = {
      id = u.id, name = dfhack.units.getReadableName(u), mine = u.status.labors[df.unit_labor.MINE] and true or false,
      pick = holds_pick(u), idle = j == nil, job = jn, hunger = u.counters2.hunger_timer, thirst = u.counters2.thirst_timer,
      squad = in_squad(u), child = not dfhack.units.isAdult(u), wounds = safe(function() return #u.body.wounds end, 0),
      cant_stand = safe(function() return u.status2.limbs_stand_count == 0 end, false), hospital = inside(u.pos, hs),
      mining_skill = safe(function() return dfhack.units.getEffectiveSkill(u, df.job_skill.MINING) end, 0) }
  end
  -- 'work_picks' = number of granted work picks (read only; the engine list is never written here)
  local eq = df.global.plotinfo.equipment
  util.emit({ ok = true, picks_total = total, picks_free = free, free_where = wl, work_picks = #eq.work_weapons,
              dig_jobs = dig_open, diggers_now = diggers, citizens = cit })
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_tools status' })
end
