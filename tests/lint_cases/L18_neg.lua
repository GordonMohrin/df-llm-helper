-- L18 negativ: darf NICHT gemeldet werden
local x, y, z, u, it, item, job, id, sk = 1, 1, 1, {}, {}, {}, {}, 1, {}
if dfhack.maps.getTileFlags(x, y, z).flow_size > 0 then return end
