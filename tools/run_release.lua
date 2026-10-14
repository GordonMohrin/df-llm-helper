-- Workaround FR-16: resume suspended ConstructBuilding jobs (buildingplan/suspendmanager keep pausing them).
local l = df.global.world.jobs.list.next
local r, n = 0, 0
while l do
  local j = l.item
  if j and j.job_type == df.job_type.ConstructBuilding then
    n = n + 1
    if j.flags.suspend then j.flags.suspend = false; r = r + 1 end
  end
  l = l.next
end
print('released=' .. r)
print('construct_jobs=' .. n)
