-- L13 positiv: muss gemeldet werden
local x, y, z, u, it, item, job, id, sk = 1, 1, 1, {}, {}, {}, {}, 1, {}
for _, it in ipairs(trader_items) do it.flags.forbid = true end
