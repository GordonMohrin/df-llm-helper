-- claude/pilot_care status | labors <unit_id> <LABOR,LABOR,...>     (dfpilot spec 04, NOT TESTED LIVE)
-- status: citizens with hunger/thirst/wounds (#wounds also counts healed scars -> hint only)/ability to stand/location (hospital zone?), squad, pickaxe, care labors,
--         care skills, idleness; hospital zones (rectangle, beds/traction benches), care jobs, meals.
-- labors: sets the given care labors (labor menu). Refuses soldiers and dwarves with a pickaxe.
local util = reqscript('claude/util')
local utils = require('utils')
if not util.require_fort() then return end

local a = { ... }
local cmd = a[1] or 'status'
local CARE = { 'DIAGNOSE', 'SURGERY', 'BONE_SETTING', 'SUTURING', 'DRESSING_WOUNDS', 'FEED_WATER_CIVILIANS',
               'RECOVER_WOUNDED' }
local CARE_JOBS = { GiveWater = true, GiveFood = true, GiveWater2 = true, GiveFood2 = true, DiagnosePatient = true, Surgery = true, SetBone = true,
                    Suture = true, DressWound = true, RecoverWounded = true, ApplyCast = true, CleanPatient = true }
local SKILLS = { 'DIAGNOSE', 'SURGERY', 'SET_BONE', 'SUTURE', 'DRESS_WOUNDS' }

local function safe(f, d) local ok, v = pcall(f) if ok and v ~= nil then return v end return d end

local function in_squad(u) return safe(function() return u.military.squad_id ~= -1 end, false) end

local function has_pick(u)
  for _, inv in ipairs(u.inventory) do
    local it = inv.item
    if it:getType() == df.item_type.WEAPON and safe(function() return it.subtype.skill_melee == df.job_skill.MINING end, false) then
      return true
    end
  end
  return false
end

-- Hospital = location of type HOSPITAL attached to a zone (live 01.10.: no zone type of its own 'Hospital';
-- zones are MeetingHall/Bedroom/... with location_id). Orphaned hospital locations (without zone) are reported too.
local function hospital_locations()
  local locs = {}
  local site = safe(function() return df.global.world.world_data.active_site[0] end, nil)
  if site then
    for _, ab in ipairs(site.buildings) do
      if safe(function() return ab:getType() == df.abstract_building_type.HOSPITAL end, false) then
        locs[ab.id] = { id = ab.id, zones = 0 }
      end
    end
  end
  return locs
end

local function hospitals(locs)
  local out = {}
  for _, z in ipairs(df.global.world.buildings.other.ACTIVITY_ZONE) do
    local loc = safe(function() return z.location_id end, -1)
    if locs[loc] then
      locs[loc].zones = locs[loc].zones + 1
      local h = { id = z.id, x1 = z.x1, y1 = z.y1, x2 = z.x2, y2 = z.y2, z = z.z, beds = 0, traction = 0, location = loc }
      for _, b in ipairs(df.global.world.buildings.all) do
        if b.z == z.z and b.centerx >= z.x1 and b.centerx <= z.x2 and b.centery >= z.y1 and b.centery <= z.y2 then
          local t = b:getType()
          if t == df.building_type.Bed then h.beds = h.beds + 1 end
          if t == df.building_type.TractionBench then h.traction = h.traction + 1 end
        end
      end
      out[#out + 1] = h
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
  local locs = hospital_locations()
  local hs = hospitals(locs)
  local cit = {}
  for _, u in ipairs(dfhack.units.getCitizens()) do
    local labors, skill = {}, 0
    for _, L in ipairs(CARE) do if u.status.labors[df.unit_labor[L]] then labors[#labors + 1] = L end end
    for _, s in ipairs(SKILLS) do skill = skill + safe(function() return dfhack.units.getEffectiveSkill(u, df.job_skill[s]) end, 0) end
    local j = u.job.current_job
    cit[#cit + 1] = {
      id = u.id, name = dfhack.units.getReadableName(u), hunger = u.counters2.hunger_timer,
      thirst = u.counters2.thirst_timer, wounds = safe(function() return #u.body.wounds end, 0),
      cant_stand = safe(function() return u.status2.limbs_stand_count == 0 end, false),
      hospital = inside(u.pos, hs), squad = in_squad(u), pick = has_pick(u), labors = labors, care_skill = skill,
      idle = j == nil, job = j and df.job_type[j.job_type] or nil, child = not dfhack.units.isAdult(u) }
  end
  local jobs = {}
  for _, job in utils.listpairs(df.global.world.jobs.list) do
    local n = df.job_type[job.job_type]
    if CARE_JOBS[n] then jobs[n] = (jobs[n] or 0) + 1 end
  end
  local meals = 0
  for _, it in ipairs(df.global.world.items.other.FOOD) do
    if not (it.flags.rotten or it.flags.forbid or it.flags.trader or it.flags.garbage_collect) then
      meals = meals + it:getStackSize()
    end
  end
  local loclist = {}
  for _, l in pairs(locs) do loclist[#loclist + 1] = l end
  util.emit({ ok = true, citizens = cit, hospitals = hs, hospital_locations = loclist, care_jobs = jobs, meals = meals })
elseif cmd == 'labors' then
  local u = df.unit.find(tonumber(a[2]) or -1)
  if not u or not dfhack.units.isCitizen(u) then util.emit({ ok = false, error = 'not a citizen' }) return end
  if in_squad(u) or has_pick(u) then util.emit({ ok = false, error = 'soldier or miner with pickaxe: refused' }) return end
  local set = {}
  for L in (a[3] or ''):gmatch('[%u_]+') do
    local ok = false
    for _, c in ipairs(CARE) do if c == L then ok = true end end
    if ok and df.unit_labor[L] then
      if not u.status.labors[df.unit_labor[L]] then u.status.labors[df.unit_labor[L]] = true; set[#set + 1] = L end
    end
  end
  util.emit({ ok = true, id = u.id, set = set })
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_care status | labors <id> <LABOR,...>' })
end
