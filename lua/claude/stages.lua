--@ module = true
-- Raster stages for claude/raster: {name, z, x1,y1,x2,y2}. Shipped EMPTY: add your own stages after exploring your map
-- (erkundung), e.g. add('N1_North', 121, 69, 80, 131, 80). Names with a leading number set the order.
-- Check every stage first: `python -m df_llm_helper digcheck --stages lua/claude/stages.lua --stage <name>`.
-- Fair play: dig orders only (wall tiles), reveal nothing; raster.lua filters aquifer/barrier/layout tiles itself.
-- Real example (Run 5, Windrings): examples/windrings/stages.lua.
stages = {}
local function add(name, z, x1, y1, x2, y2) stages[#stages + 1] = { name, z, x1, y1, x2, y2 } end
