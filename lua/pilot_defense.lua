-- claude/pilot_defense status      (dfpilot spec v3-08 defense designer; LIVE-UNTESTED, structure check + lint only)
-- Read-only: lists traps (kind, position, loaded/empty if detectable), open trap load jobs (raw job type names and
-- job names; Python matches case-insensitively on "stone trap"), trap parts in stock (mechanisms, trap components,
-- boulders). Changes nothing: no jobs, no buildings, no items.
-- 'loaded' heuristic (verify live): a boulder among the trap's contained items -> true; an open load job held by the
-- trap -> false; otherwise nil (unknown). Raw fields state/ready_timeout/contained are reported for calibration.
local util = reqscript('claude/util')
local utils = require('utils')
if not util.require_fort() then return end

local a = { ... }
local cmd = a[1] or 'status'

local function safe(f, d) local ok, v = pcall(f) if ok and v ~= nil then return v end return d end

local KIND = { StoneFallTrap = 'stone', WeaponTrap = 'weapon', CageTrap = 'cage', Lever = 'lever',
               PressurePlate = 'plate', TrackStop = 'trackstop' }

local function count_items(list)
  local n = 0
  for _, it in ipairs(list) do
    if not (it.flags.forbid or it.flags.trader or it.flags.garbage_collect or it.flags.in_building) then
      n = n + it:getStackSize()
    end
  end
  return n
end

if cmd == 'status' then
  local load_jobs, jobs = {}, {}
  for _, job in utils.listpairs(df.global.world.jobs.list) do
    local raw = df.job_type[job.job_type] or tostring(job.job_type)
    local name = safe(function() return dfhack.job.getName(job) end, raw)
    local key = tostring(raw) .. ' | ' .. tostring(name)
    if string.find(string.lower(key), 'trap', 1, true) then
      jobs[key] = (jobs[key] or 0) + 1
      local holder = safe(function() return dfhack.job.getHolder(job) end, nil)
      if holder and string.find(string.lower(key), 'load', 1, true) then load_jobs[holder.id] = true end
    end
  end
  local traps = {}
  for _, b in ipairs(df.global.world.buildings.other.TRAP) do
    local tt = safe(function() return df.trap_type[b.trap_type] end, '?')
    local contained, boulder = {}, false
    for _, ci in ipairs(b.contained_items) do
      local t = safe(function() return df.item_type[ci.item:getType()] end, '?')
      contained[#contained + 1] = t
      if t == 'BOULDER' then boulder = true end
    end
    local loaded = nil
    if boulder then loaded = true elseif load_jobs[b.id] then loaded = false end
    traps[#traps + 1] = { id = b.id, x = b.centerx, y = b.centery, z = b.z, trap_type = tt, kind = KIND[tt] or tt,
                          loaded = loaded, load_job = load_jobs[b.id] or false,
                          state = safe(function() return b.state end, -1),
                          ready_timeout = safe(function() return b.ready_timeout end, -1), contained = contained }
  end
  local other = df.global.world.items.other
  local stock = { mechanisms = safe(function() return count_items(other.TRAPPARTS) end, -1),
                  trap_components = safe(function() return count_items(other.TRAPCOMP) end, -1),
                  boulders = safe(function() return count_items(other.BOULDER) end, -1) }
  util.emit({ ok = true, traps = traps, jobs = jobs, stock = stock, live_tested = false })
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_defense status' })
end
