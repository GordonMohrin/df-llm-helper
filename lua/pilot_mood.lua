-- claude/pilot_mood need <unit_id> | release-cutgems [--apply]     (dfpilot spec 03, NOT TESTED LIVE)
-- need: real job elements of the mood (item_type, material, quantity, set flags1/2/3) + free/bound stock per type
--       (free = not forbidden/trader/foreign/in job/rotten; reachable = canWalkBetween to the unit) + nearest distance.
-- release-cutgems: remove CutGems jobs (UI action like 'cancel job') so rough gems become free for the mood.
local util = reqscript('claude/util')
local utils = require('utils')
if not util.require_fort() then return end

local a = { ... }
local cmd = a[1]

local function flagnames(f)
  local out = {}
  if not f then return out end
  for k, v in pairs(f) do
    if type(k) == 'string' and v == true then out[#out + 1] = k end
  end
  table.sort(out)
  return out
end

local function free_item(it)
  local f = it.flags
  return not (f.forbid or f.trader or f.foreign or f.in_job or f.rotten or f.dump or f.garbage_collect)
end

-- mine: set of item ids already attached to the mood job itself. They carry in_job, so they would count as 'bound'
-- (never 'free'); the job holds them already, so they are reported separately (held) and are not demand that is missing.
local function stock_for(itype, u, mine)
  local free, bound, nearest = 0, 0, nil
  for _, it in ipairs(df.global.world.items.other.IN_PLAY) do
    if it:getType() == itype and not (mine and mine[it.id]) then
      if free_item(it) then
        local p = xyz2pos(dfhack.items.getPosition(it))
        if p and u and dfhack.maps.canWalkBetween(u.pos, p) then
          free = free + it:getStackSize()
          local d = math.max(math.abs(p.x - u.pos.x), math.abs(p.y - u.pos.y), math.abs(p.z - u.pos.z))
          if not nearest or d < nearest then nearest = d end
        end
      elseif it.flags.in_job then
        bound = bound + it:getStackSize()
      end
    end
  end
  return free, bound, nearest
end

if cmd == 'need' then
  local u = df.unit.find(tonumber(a[2]) or -1)
  if not u then util.emit({ ok = false, error = 'unit unknown' }) return end
  local j = u.job.current_job
  local out = { ok = true, id = u.id, mood = df.mood_type[u.mood] or tostring(u.mood), timeout = u.job.mood_timeout,
                thirst = u.counters2.thirst_timer, elements = {} }
  if j then
    local mine, held = {}, {}
    for _, ref in ipairs(j.items) do                    -- items attached to the job; job_item_idx = index into job_items.elements
      if ref.item then
        mine[ref.item.id] = true
        held[ref.job_item_idx] = (held[ref.job_item_idx] or 0) + ref.item:getStackSize()
      end
    end
    for idx, el in ipairs(j.job_items.elements) do
      local free, bound, nearest = stock_for(el.item_type, u, mine)
      out.elements[#out.elements + 1] = {
        item_type = df.item_type[el.item_type] or tostring(el.item_type), mat_type = el.mat_type, mat_index = el.mat_index,
        quantity = el.quantity, flags1 = flagnames(el.flags1), flags2 = flagnames(el.flags2), flags3 = flagnames(el.flags3),
        free = free, bound = bound, nearest = nearest, held = held[idx] or 0 }
    end
  end
  util.emit(out)
elseif cmd == 'release-cutgems' then
  local apply = a[2] == '--apply'
  local jobs = {}
  for _, job in utils.listpairs(df.global.world.jobs.list) do
    if job.job_type == df.job_type.CutGems then jobs[#jobs + 1] = job end
  end
  local n = 0
  if apply then
    for _, job in ipairs(jobs) do if dfhack.job.removeJob(job) then n = n + 1 end end
  end
  util.emit({ ok = true, found = #jobs, removed = n, dry = not apply })
else
  util.emit({ ok = false, error = 'Usage: claude/pilot_mood need <id> | release-cutgems [--apply]' })
end
