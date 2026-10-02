-- claude/felder list | set <plot_id|all> <PLANT_ID> [season|all]  (scope essen, run 4)
-- Sets the crop per season (farm plot menu, fair play). Example: claude/felder set all PLUMP_HELMET all
local args = {...}
local cmd = args[1] or 'list'
local function plant_index(id)
  for i, p in ipairs(df.global.world.raws.plants.all) do if p.id == id then return i end end
end
local function plots()
  local r = {}
  for _, b in ipairs(df.global.world.buildings.all) do
    if b:getType() == df.building_type.FarmPlot then table.insert(r, b) end
  end
  return r
end
if cmd == 'list' then
  for _, b in ipairs(plots()) do
    local t = {}
    for s = 0, 3 do
      local pid = b.plant_id[s]
      t[#t+1] = pid >= 0 and df.global.world.raws.plants.all[pid].id or '-'
    end
    print(b.id, b.z, b.x1, b.y1, b.x2, b.y2, table.concat(t, ','))
  end
elseif cmd == 'set' then
  local idx = plant_index(args[3])
  if not idx then print('unbekannte Pflanze ' .. tostring(args[3])) return end
  local seas = args[4] or 'all'
  for _, b in ipairs(plots()) do
    if args[2] == 'all' or tonumber(args[2]) == b.id then
      for s = 0, 3 do
        if seas == 'all' or tonumber(seas) == s then b.plant_id[s] = idx end
      end
      print('Feld ' .. b.id .. ' -> ' .. args[3])
    end
  end
end
