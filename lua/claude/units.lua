-- claude/units - list of citizens: profession, mood, current job, best skills, work details.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local STRESS = { [0] = 'todungluecklich', 'sehr ungluecklich', 'ungluecklich', 'neutral',
                 'zufrieden', 'gluecklich', 'sehr gluecklich' }

-- Which work details does each dwarf have?
local details_of = {}
local wds = df.global.plotinfo.labor_info.work_details
for i = 0, #wds - 1 do
  local d = wds[i]
  for j = 0, #d.assigned_units - 1 do
    local id = d.assigned_units[j]
    details_of[id] = details_of[id] or {}
    table.insert(details_of[id], d.name)
  end
end

local out = {}
for _, u in ipairs(util.citizens()) do
  local skills = {}
  if u.status.current_soul then
    for _, s in ipairs(u.status.current_soul.skills) do
      skills[#skills + 1] = { skill = df.job_skill[s.id], rating = s.rating }
    end
  end
  table.sort(skills, function(a, b) return a.rating > b.rating end)
  local top = {}
  for i = 1, math.min(3, #skills) do top[i] = skills[i].skill .. ':' .. skills[i].rating end

  local job = u.job.current_job
  local injured = false
  pcall(function() injured = #u.body.wounds > 0 end)

  out[#out + 1] = {
    id = u.id,
    name = dfhack.units.getReadableName(u),
    profession = dfhack.units.getProfessionName(u),
    stress = STRESS[dfhack.units.getStressCategory(u)],
    child = dfhack.units.isChild(u) or dfhack.units.isBaby(u),
    job = job and dfhack.job.getName(job) or nil,
    skills = table.concat(top, ', '),
    work_details = table.concat(details_of[u.id] or {}, ', '),
    injured = injured or nil,
    pos = { u.pos.x, u.pos.y, u.pos.z },
  }
end

util.emit({ count = #out, units = out })
