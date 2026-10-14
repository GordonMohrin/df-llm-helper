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

-- Workaround FR-16b: the kernel keeps only 2-4 miners; with a big visible dig backlog make sure >= 6 adults mine
-- (idle non-military adults, with a pick available is up to the game's own job assignment).
local backlog = 0
for z = 108, 117 do
  for y = 20, 110 do for x = 20, 110 do
    local d = dfhack.maps.getTileFlags(x, y, z)
    if d and not d.hidden and d.dig ~= 0 then backlog = backlog + 1 end
  end end
end
print('dig_backlog=' .. backlog)
if backlog > 50 then
  local det
  for _, w in ipairs(df.global.plotinfo.labor_info.work_details) do if w.name == 'Miners' then det = w end end
  if det then
    local have = #det.assigned_units
    local added = 0
    for _, u in ipairs(dfhack.units.getCitizens(true)) do
      if have + added >= 6 then break end
      if dfhack.units.isAdult(u) and u.military.squad_id < 0 and not u.status.labors[df.unit_labor.MINE] then
        det.assigned_units:insert('#', u.id); u.status.labors[df.unit_labor.MINE] = true; added = added + 1
      end
    end
    print('miners=' .. (have + added) .. ' (added ' .. added .. ')')
  end
end
