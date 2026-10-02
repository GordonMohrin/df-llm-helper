-- claude/pilot_remote status [LABOR,LABOR,...] | cancel <unit_id> | labor <unit_id> <LABOR> off|on [WD,WD,...]
-- (dfpilot spec v3-06 remote-worker protection, LIVE-UNTESTED)
-- status: citizens with position, hunger/thirst, current job, squad/child/hospital, the requested labors and the work
--         details granting them; supply points (food stockpiles, wells); raw fish count; work details in mode
--         EverybodyDoesThis that grant a requested labor (labor removal cannot stick there).
-- cancel: cancels the unit's current job (like "cancel job" in the UI).
-- labor off: removes the labor (labor menu) and takes the unit out of selective work details granting it (work detail
--            menu); returns the names of those work details so dfpilot can give them back later.
-- labor on:  sets the labor again and re-adds the unit to the given work details.
-- Refused for: non-citizens, soldiers (squad), children, dwarves inside a hospital zone.
local util = reqscript('claude/util')
local utils = require('utils')
if not util.require_fort() then return end

local a = { ... }
local cmd = a[1] or 'status'
local ALLOWED = { FISH = true, HERBALISM = true, PLANT = true, MINE = true, HUNT = true, CUTWOOD = true }

local function safe(f, d) local ok, v = pcall(f) if ok and v ~= nil then return v end return d end
local function in_squad(u) return safe(function() return u.military.squad_id ~= -1 end, false) end

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

local function wds() return df.global.plotinfo.labor_info.work_details end
local M = df.work_detail_mode

local function member_index(d, uid)
  for j = 0, #d.assigned_units - 1 do if d.assigned_units[j] == uid then return j end end
  return nil
end

local function split(s)
  local t = {}
  for w in (s or ''):gmatch('[^,]+') do t[#t + 1] = w end
  return t
end

-- common refusal checks for actions; returns unit or nil (after emitting the error)
local function target(id)
  local u = df.unit.find(tonumber(id) or -1)
  if not u or not dfhack.units.isCitizen(u) then util.emit({ ok = false, error = 'not a citizen' }) return nil end
  if in_squad(u) then util.emit({ ok = false, id = u.id, error = 'soldier: refused' }) return nil end
  if not dfhack.units.isAdult(u) then util.emit({ ok = false, id = u.id, error = 'child: refused' }) return nil end
  if inside(u.pos, hospital_zones()) then util.emit({ ok = false, id = u.id, error = 'in hospital: refused' }) return nil end
  return u
end

if cmd == 'status' then
  local want = {}
  for _, L in ipairs(split(a[2] or 'FISH')) do if df.unit_labor[L] then want[#want + 1] = L end end
  local hs = hospital_zones()
  local cit = {}
  for _, u in ipairs(dfhack.units.getCitizens()) do
    local labs = {}
    for _, L in ipairs(want) do if u.status.labors[df.unit_labor[L]] then labs[#labs + 1] = L end end
    local j = u.job.current_job
    cit[#cit + 1] = { id = u.id, name = dfhack.units.getReadableName(u), x = u.pos.x, y = u.pos.y, z = u.pos.z,
                      hunger = u.counters2.hunger_timer, thirst = u.counters2.thirst_timer,
                      job = j and df.job_type[j.job_type] or nil, squad = in_squad(u), child = not dfhack.units.isAdult(u),
                      hospital = inside(u.pos, hs), labors = labs }
  end
  local sup = {}
  for _, b in ipairs(df.global.world.buildings.other.STOCKPILE) do
    if safe(function() return b.settings.flags.food end, false) then
      sup[#sup + 1] = { kind = 'food', id = b.id, x = b.centerx, y = b.centery, z = b.z }
    end
  end
  for _, b in ipairs(df.global.world.buildings.all) do
    if safe(function() return b:getType() == df.building_type.Well end, false) then
      sup[#sup + 1] = { kind = 'well', id = b.id, x = b.centerx, y = b.centery, z = b.z }
    end
  end
  local fish = 0
  for _, key in ipairs({ 'FISH_RAW', 'FISH' }) do
    for _, it in ipairs(safe(function() return df.global.world.items.other[key] end, {})) do
      if not (it.flags.rotten or it.flags.trader or it.flags.garbage_collect) then fish = fish + it:getStackSize() end
    end
  end
  local everybody = {}
  for i = 0, #wds() - 1 do
    local d = wds()[i]
    if d.flags.mode == M.EverybodyDoesThis then
      for _, L in ipairs(want) do
        if safe(function() return d.allowed_labors[df.unit_labor[L]] end, false) then everybody[#everybody + 1] = d.name .. ':' .. L end
      end
    end
  end
  util.emit({ ok = true, citizens = cit, supplies = sup, fish = fish, wd_everybody = everybody })
elseif cmd == 'cancel' then
  local u = target(a[2])
  if not u then return end
  local j = u.job.current_job
  if not j then util.emit({ ok = true, id = u.id, cancelled = false }) return end
  local name = df.job_type[j.job_type]
  local ok = pcall(dfhack.job.removeJob, j)
  if not ok then ok = pcall(dfhack.job.removeWorker, j, 0) end
  util.emit({ ok = ok, id = u.id, cancelled = ok, job = name })
elseif cmd == 'labor' then
  local L, mode = a[3], a[4]
  if not L or not ALLOWED[L] or not df.unit_labor[L] or (mode ~= 'on' and mode ~= 'off') then
    util.emit({ ok = false, error = 'Usage: labor <id> <FISH|HERBALISM|PLANT|MINE|HUNT|CUTWOOD> on|off [WD,...]' })
    return
  end
  local u = target(a[2])
  if not u then return end
  local li = df.unit_labor[L]
  local before = u.status.labors[li] and true or false
  local changed = {}
  if mode == 'off' then
    u.status.labors[li] = false
    for i = 0, #wds() - 1 do
      local d = wds()[i]
      local k = member_index(d, u.id)
      if k and d.flags.mode ~= M.EverybodyDoesThis and safe(function() return d.allowed_labors[li] end, false) then
        d.assigned_units:erase(k)
        changed[#changed + 1] = d.name
      end
    end
  else
    u.status.labors[li] = true
    for _, name in ipairs(split(a[5])) do
      for i = 0, #wds() - 1 do
        local d = wds()[i]
        if d.name == name and not member_index(d, u.id) then
          d.assigned_units:insert('#', u.id)
          changed[#changed + 1] = d.name
        end
      end
    end
  end
  util.emit({ ok = true, id = u.id, labor = L, mode = mode, before = before, work_details = changed })
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_remote status [LABORS] | cancel <id> | labor <id> <LABOR> on|off [WD,...]' })
end
