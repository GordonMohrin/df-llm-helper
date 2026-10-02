-- claude/buildings [z] - buildings, workshops, stockpiles and zones with coordinates and construction status.
local util = reqscript('claude/util')
if not util.require_fort() then return end

local only_z = tonumber(({ ... })[1])
local BT = df.building_type
local SKIP = { Construction = true }

local counts, list = {}, {}
for _, b in ipairs(df.global.world.buildings.all) do
  local tname = BT[b:getType()] or tostring(b:getType())
  if not SKIP[tname] and (not only_z or b.z == only_z) then
    local kind = tname
    if tname == 'Workshop' then kind = df.workshop_type[b:getSubtype()] or kind
    elseif tname == 'Furnace' then kind = df.furnace_type[b:getSubtype()] or kind
    elseif tname == 'Civzone' then
      local ok, zt = pcall(function() return df.civzone_type[b.type] end)
      kind = 'Zone:' .. ((ok and zt) or '?')
    end
    local built = true
    pcall(function() built = b:getBuildStage() >= b:getMaxBuildStage() end)
    counts[kind] = (counts[kind] or 0) + 1
    list[#list + 1] = {
      id = b.id,
      kind = kind,
      name = (b.name ~= '' and b.name) or nil,
      x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, z = b.z,
      built = built or nil,
      planned = (not built) or nil,
      jobs = (#b.jobs > 0) and #b.jobs or nil,
    }
  end
end

-- Truncate large lists, the overview stays complete.
local truncated = false
if #list > 150 then
  truncated = true
  while #list > 150 do table.remove(list) end
end

util.emit({ counts = counts, buildings = list, truncated = truncated })
