-- claude/task list <building_id>                    - tasks the workshop offers (workshop menu).
-- claude/task destroy <building_id>                 - have the building deconstructed.
-- claude/task add <building_id> <task> [count]      - add a task directly at the workshop
--                                                     (as in the game: workshop -> add task).
-- No manager needed; the task is worked by dwarves as soon as material is available.
local util = reqscript('claude/util')
if not util.require_fort() then return end
local workshops = require('dfhack.workshops')

local a = { ... }
local b = df.building.find(tonumber(a[2]) or -1)
if not b then util.emit({ error = 'keine Werkstatt mit id ' .. tostring(a[2]) }) return end

-- claude/task destroy <building_id> - deconstruction order (like "Remove building" in the game).
if a[1] == 'destroy' then
  if dfhack.buildings.markedForRemoval(b) then util.emit({ ok = true, note = 'schon markiert' }) return end
  local job = df.job:new()
  job.job_type = df.job_type.DestroyBuilding
  job.pos = { x = b.centerx, y = b.centery, z = b.z }
  local ref = df.general_ref_building_holderst:new()
  ref.building_id = b.id
  job.general_refs:insert('#', ref)
  b.jobs:insert('#', job)
  dfhack.job.linkIntoWorld(job, true)
  util.emit({ ok = true, destroy = b.id, kind = df.building_type[b:getType()] })
  return
end
local defs = workshops.getJobs(b:getType(), b:getSubtype(), b:getCustomType())
if not defs then util.emit({ error = 'dieses Gebaeude hat keine Werkstattaufgaben' }) return end

local names = {}
for _, d in pairs(defs) do names[#names + 1] = d.name:lower() end
table.sort(names)

if a[1] == 'list' then util.emit({ building = b.id, tasks = names }) return end

if a[1] == 'add' then
  local want = (a[3] or ''):lower()
  local def
  for _, d in pairs(defs) do if d.name:lower() == want then def = d end end
  if not def then util.emit({ error = 'unbekannte Aufgabe: ' .. want, tasks = names }) return end
  local count = math.max(1, math.min(tonumber(a[4]) or 1, 10))
  for _ = 1, count do
    local job = df.job:new()
    job.pos = { x = b.centerx, y = b.centery, z = b.z }
    if def.job_fields then job:assign(def.job_fields) end
    for _, filter in ipairs(def.items or {}) do
      local f = copyall(filter)
      f.new = true
      job.job_items.elements:insert('#', f)
    end
    local ref = df.general_ref_building_holderst:new()
    ref.building_id = b.id
    job.general_refs:insert('#', ref)
    b.jobs:insert('#', job)
    dfhack.job.linkIntoWorld(job, true)
  end
  dfhack.job.checkBuildingsNow()
  util.emit({ ok = true, building = b.id, task = want, count = count, jobs_now = #b.jobs })
  return
end

util.emit({ error = 'unbekannter Unterbefehl' })
