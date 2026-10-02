-- L10 negativ: darf NICHT gemeldet werden
local x, y, z, u, it, item, job, id, sk = 1, 1, 1, {}, {}, {}, {}, 1, {}
if not dfhack.maps.getTileFlags(x, y, z).hidden then
  local tt = dfhack.maps.getTileType(x, y, z)
end
