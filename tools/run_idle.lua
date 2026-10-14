-- One-line workload diagnosis for tools/run_idle.py (Run 9, Gordon 14.10.2026: "monitor the utilisation, whenever it is low work on a goal").
-- Read-only: counts adults without a job, unclaimed jobs by type and the most frequent job cancellations since the last call.
local cit = dfhack.units.getCitizens(true)
local adults, none, mil = 0, 0, 0
for _, u in ipairs(cit) do
  if dfhack.units.isAdult(u) then
    adults = adults + 1
    if u.military.squad_id >= 0 then mil = mil + 1 end
    if not u.job.current_job then none = none + 1 end
  end
end
local unc, claimed = {}, 0
local l = df.global.world.jobs.list.next
while l do
  local j = l.item
  if j then
    local taken = false
    for _, r in ipairs(j.general_refs) do if r:getType() == df.general_ref_type.UNIT_WORKER then taken = true end end
    if taken then claimed = claimed + 1 else
      local k = df.job_type[j.job_type]
      unc[k] = (unc[k] or 0) + 1
    end
  end
  l = l.next
end
local ut = {}
for k, v in pairs(unc) do ut[#ut + 1] = {k, v} end
table.sort(ut, function(a, b) return a[2] > b[2] end)
local top = {}
for i = 1, math.min(5, #ut) do top[#top + 1] = ut[i][1] .. '=' .. ut[i][2] end
-- cancellations in the newest announcements
local a = df.global.world.status.announcements
local why = {}
for i = math.max(0, #a - 60), #a - 1 do
  local t = dfhack.df2utf(a[i].text)
  local reason = t:match('cancels [^:]+: (.+)$')
  if reason then why[reason] = (why[reason] or 0) + 1 end
end
local wt = {}
for k, v in pairs(why) do wt[#wt + 1] = {k, v} end
table.sort(wt, function(x, y) return x[2] > y[2] end)
local ct = {}
for i = 1, math.min(3, #wt) do ct[#ct + 1] = wt[i][1]:sub(1, 40) .. 'x' .. wt[i][2] end
local civ = adults - mil
local civ_none = 0
for _, u in ipairs(cit) do
  if dfhack.units.isAdult(u) and u.military.squad_id < 0 and not u.job.current_job then civ_none = civ_none + 1 end
end
local civ_idle = civ > 0 and (civ_none * 100 // civ) or 0
print(string.format('civ_idle=%d%% adults=%d jobless=%d soldiers=%d claimed=%d unclaimed_top=[%s] cancels=[%s]', civ_idle, adults, none, mil, claimed, table.concat(top, ' '), table.concat(ct, '; ')))
