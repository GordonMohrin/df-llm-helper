-- L17 positiv: muss gemeldet werden
local x, y, z, u, it, item, job, id, sk = 1, 1, 1, {}, {}, {}, {}, 1, {}
dfhack.maps.getTileBlock(x, y, z).tiletype[1][1] = 0
setTileType(x, y, z, 1)
