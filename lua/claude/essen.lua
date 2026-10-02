-- claude/essen start|stop|once|status|gather [n|on|off] - food balance (scope "essen", run 3, created Y80 Granite, extended Y87 Obsidian)
-- 1. Plump helmet plants (PH) are the only brewing AND cooking raw material: cooking PH is blocked via the kitchen ban (Cook)
--    as long as drinks < DRINK_LOW; free from DRINK_HIGH (hysteresis). Thirst kills earlier than hunger.
-- 2. Gathering: if there are no open GatherPlants jobs left and fewer than PLANT_TARGET fresh PH exist, the nearest
--    living, visible PH shrubs in cavern 2 (around shaft foot D 136,169,z91) are marked for gathering.
--    (Do NOT gather dimple cup/quarry/sweet pod: not brewable, not edible raw.)
-- 3. Mark rotten food for dumping.
-- 4. (Y87) Fishery/kitchen pump: keeps up to FISH_JOBS 'prepare raw fish' jobs open per fishery as long as fresh raw fish
--    (FISH_RAW, not rotten) is lying around (fishers catch > cleaning; raw fish spoils on the shore), and up to MEAL_JOBS
--    'prepare easy meal' per kitchen as long as meals < MEAL_TARGET and enough ingredients are available.
-- 5. Gathering in cavern 2 only if `claude/essen gather on` (shaft D has been sealed since Y83 -> default OFF).
-- Only zones/designations/kitchen list as via the interface (fair play).
-- No argument (or `once`) = run ONE round now. This default is intended and stays: the orchestrator, the watchdog and
-- the scope agents call `claude/essen` without arguments. The read-only command is `status`; any other word prints usage and changes nothing (BUG-407).
local util = reqscript('claude/util')
if not util.require_fort() then return end
local repeatUtil = require('repeat-util')
local KEY = 'claude-essen'
local INTERVAL = 600
local cmd = ({ ... })[1] or 'once'
local arg2 = ({ ... })[2]

local DRINK_LOW, DRINK_HIGH = 80, 140   -- 42 citizens (Y87); before that 35/60 at 5-19 citizens
local PLANT_TARGET = 150
local MEAL_TARGET = 400                 -- Meals (stacks count by quantity; consumption 42 citizens ~7/week -> 400 ~ 1 year)
local FOOD_CAP = 500                    -- Meals + finished fish: above that no further cleaning jobs (raw fish stays lying)
local FISH_JOBS, MEAL_JOBS = 8, 10       -- open jobs per fishery / kitchen
local SAY_EVERY = 6                     -- Spectate short message every N runs
local STATE = reqscript('claude/util').home() .. '/state/essen.json'
local GATHER_BATCH = 150
local CX, CY, CZ = reqscript('claude/config').FORT_X, reqscript('claude/config').FORT_Y, reqscript('claude/config').SURFACE_Z   -- Run 4: gather around the fort center (run 3: shaft foot z91)

local function real(i) return i.pos.x >= 0 or i.flags.in_inventory or dfhack.items.getContainer(i) ~= nil end
local function free(f) return not (f.forbid or f.rotten or f.dump or f.trader or f.garbage_collect or f.removed) end

local function ph_raw()
  for _, p in ipairs(df.global.world.raws.plants.all) do
    if p.id == 'MUSHROOM_HELMET_PLUMP' then return p end
  end
end

local function measure()
  local m = { drinks = 0, ph = 0, meals = 0, rotten = 0, fish_raw = 0, fish_raw_rotten = 0, fish = 0, meat = 0, plants = 0 }
  local ph = ph_raw()
  local phmt = ph and ph.material_defs.type.basic_mat
  for _, it in ipairs(df.global.world.items.all) do
   if real(it) then
    local t = it:getType()
    local f = it.flags
    if t == df.item_type.PLANT and free(f) and it:getMaterial() == phmt and it:getMaterialIndex() == ph.material_defs.idx.basic_mat then
      m.ph = m.ph + it:getStackSize()
    elseif t == df.item_type.FOOD and free(f) then m.meals = m.meals + it:getStackSize()
    elseif t == df.item_type.FISH_RAW then
      if f.rotten then m.fish_raw_rotten = m.fish_raw_rotten + 1
      elseif free(f) and not f.in_inventory then m.fish_raw = m.fish_raw + 1 end
    elseif (t == df.item_type.MEAT or t == df.item_type.FOOD or t == df.item_type.FISH or t == df.item_type.PLANT) and f.rotten and not f.trader and not f.in_inventory then
      m.rotten = m.rotten + 1
    end
   end
  end
  for _, it in ipairs(df.global.world.items.other.FISH) do
    if free(it.flags) and not it.flags.in_inventory then m.fish = m.fish + it:getStackSize() end
  end
  for _, it in ipairs(df.global.world.items.other.MEAT) do
    if free(it.flags) and not it.flags.in_inventory then m.meat = m.meat + it:getStackSize() end
  end
  for _, it in ipairs(df.global.world.items.other.PLANT) do
    if real(it) and free(it.flags) and not it.flags.in_inventory and not (it:getMaterial() == phmt and it:getMaterialIndex() == ph.material_defs.idx.basic_mat) then m.plants = m.plants + it:getStackSize() end
  end
  for _, i in ipairs(df.global.world.items.other.DRINK) do if free(i.flags) then m.drinks = m.drinks + i:getStackSize() end end
  m.gatherjobs = 0
  local jl = df.global.world.jobs.list.next
  while jl do
    local j = jl.item
    if j and j.job_type == df.job_type.GatherPlants then m.gatherjobs = m.gatherjobs + 1 end
    jl = jl.next
  end
  return m
end

local function cook_banned()
  local ph = ph_raw()
  local k = df.global.plotinfo.kitchen
  for i = 0, #k.exc_types - 1 do
    if k.item_types[i] == df.item_type.PLANT and k.mat_types[i] == ph.material_defs.type.basic_mat
      and k.mat_indices[i] == ph.material_defs.idx.basic_mat and k.exc_types[i].Cook then return true end
  end
  return false
end

local function set_ban(on)
  local ph = ph_raw()
  local mt, mi = ph.material_defs.type.basic_mat, ph.material_defs.idx.basic_mat
  if on then dfhack.kitchen.addExclusion({ Cook = true }, df.item_type.PLANT, -1, mt, mi)
  else dfhack.kitchen.removeExclusion({ Cook = true }, df.item_type.PLANT, -1, mt, mi) end
end

local function gather(n)
  local list = {}
  for _, p in ipairs(df.global.world.plants.shrub_dry) do
    local z = p.pos.z
    local GZ = reqscript('claude/config').GATHER_Z   -- Run 4: { zmin, zmax } or nil (run 3: cavern 2 z89..93); nil = no gathering
    if GZ and z >= GZ[1] and z <= GZ[2] then
      local raw = df.plant_raw.find(p.material)
      if raw and raw.id == 'MUSHROOM_HELMET_PLUMP' and df.tiletype[dfhack.maps.getTileType(p.pos)] == 'Shrub' then
        local b = dfhack.maps.getTileBlock(p.pos)
        if b then
          local dd = b.designation[p.pos.x % 16][p.pos.y % 16]
          if not dd.hidden and dd.dig == df.tile_dig_designation.No then
            table.insert(list, { d = math.max(math.abs(p.pos.x - CX), math.abs(p.pos.y - CY)) + math.abs(z - CZ) * 3, b = b, dd = dd })
          end
        end
      end
    end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  local k = 0
  for _, e in ipairs(list) do
    if k >= n then break end
    e.dd.dig = df.tile_dig_designation.Default
    e.b.flags.designated = true
    k = k + 1
  end
  return k, #list
end

local function dump_rotten()
  local n = 0
  -- Dimple cup plants are inedible (dye only) and clog the food stockpile -> dump them
  for _, it in ipairs(df.global.world.items.other.PLANT) do
    if not it.flags.dump and not it.flags.in_job and not it.flags.in_inventory and not it.flags.rotten then
      local raw = df.plant_raw.find(it.mat_index)
      if raw and raw.id == 'MUSHROOM_CUP_DIMPLE' then it.flags.dump = true n = n + 1 end
    end
  end
  for _, it in ipairs(df.global.world.items.all) do
    local t = it:getType()
    -- rotten raw fish only inside the fort (below the surface, blocks the food stockpile); shore piles on the surface stay outside
    local fortfish = (t == df.item_type.FISH_RAW and it.pos.z <= reqscript('claude/config').SURFACE_Z - 1 and it.pos.z > 0)
    if (fortfish or t == df.item_type.MEAT or t == df.item_type.FOOD or t == df.item_type.FISH or t == df.item_type.PLANT or t == df.item_type.EGG or t == df.item_type.CHEESE)
      and it.flags.rotten and not it.flags.trader and not it.flags.in_building and not it.flags.dump and not it.flags.garbage_collect and not it.flags.in_inventory then
      it.flags.dump = true
      n = n + 1
    end
  end
  return n
end


-- ---- State (state/essen.json): { gather = false }
local function load_state()
  local f = io.open(STATE, 'r')
  local t = {}
  if f then
    local ok, j = pcall(function() return require('json').decode(f:read('*a')) end)
    f:close()
    if ok and type(j) == 'table' then t = j end
  end
  return t
end
local function save_state(t)
  local f = io.open(STATE, 'w')
  if f then f:write(require('json').encode(t)) f:close() end
end

-- ---- Workshop jobs (like claude/task add, but with counting)
local workshops = require('dfhack.workshops')
local function shops(wtype)
  local r = {}
  for _, b in ipairs(df.global.world.buildings.all) do
    if b:getType() == df.building_type.Workshop and b:getSubtype() == wtype and b:getBuildStage() >= b:getMaxBuildStage() then
      table.insert(r, b)
    end
  end
  return r
end
local function add_jobs(b, name, n)
  local defs = workshops.getJobs(b:getType(), b:getSubtype(), b:getCustomType())
  local def
  for _, d in pairs(defs or {}) do if d.name:lower() == name then def = d end end
  if not def then return 0 end
  for _ = 1, n do
    local job = df.job:new()
    job.pos = { x = b.centerx, y = b.centery, z = b.z }
    if def.job_fields then job:assign(def.job_fields) end
    for _, filter in ipairs(def.items or {}) do
      local f = copyall(filter)
      f.new = true
      job.job_items.elements:insert('#', f)
    end
    local ref = df.general_ref_building_holderst:new()
    ref.building_id = b.id
    job.general_refs:insert('#', ref)
    b.jobs:insert('#', job)
    dfhack.job.linkIntoWorld(job, true)
  end
  return n
end
local function count_jobs(b, jt)
  local n = 0
  for _, j in ipairs(b.jobs) do if j.job_type == jt then n = n + 1 end end
  return n
end

-- Fishery pump: fresh raw fish should be cleaned immediately (fish stack of 4-6 fish, shore pile spoils)
local function pump_fishery(m)
  local added = 0
  if m.fish_raw <= 0 or (m.meals + m.fish) >= FOOD_CAP then return 0 end
  local list = shops(df.workshop_type.Fishery)
  for _, b in ipairs(list) do
    local have = count_jobs(b, df.job_type.PrepareRawFish)
    local want = math.min(FISH_JOBS, math.ceil(m.fish_raw / math.max(#list, 1)))
    if have < want then added = added + add_jobs(b, 'prepare raw fish', want - have) end
  end
  return added
end

-- Kitchen pump: meals up to MEAL_TARGET, only with enough ingredients (2 per meal job); PH does not count while banned
local function pump_kitchen(m, banned)
  local added = 0
  if m.meals >= MEAL_TARGET then return 0 end
  local ing = m.fish + m.meat + m.plants -- m.plants does not count PH
  local list = shops(df.workshop_type.Kitchen)
  local pool = math.floor(ing / 2)
  for _, b in ipairs(list) do
    local have = count_jobs(b, df.job_type.PrepareMeal)
    local n = math.min(MEAL_JOBS - have, pool)
    if n > 0 then added = added + add_jobs(b, 'prepare easy meal', n) pool = pool - n end
  end
  return added
end

local run_count = 0
local function run()
  local m = measure()
  local acts = {}
  local banned = cook_banned() and true or false
  -- Run 5 (01.10.): PH is eaten raw (1 item per meal instead of >=2 ingredients per cooking job) -> PH cooking permanently banned
  -- Player rule 01.10.: plump helmet NEVER as food, only alcohol -> ban permanent, never lifted
  if not banned then set_ban(true) banned = true table.insert(acts, 'ban PH-Kochen (player rule)') end
  local st = load_state()
  if st.gather and m.gatherjobs < 12 and m.ph < PLANT_TARGET then
    local k, avail = gather(GATHER_BATCH)
    table.insert(acts, 'sammeln +' .. k .. ' (Rest ' .. (avail - k) .. ')')
  end
  local nf = pump_fishery(m)
  if nf > 0 then table.insert(acts, 'Fischerei +' .. nf .. ' Jobs (frisch ' .. m.fish_raw .. ')') end
  local nk = pump_kitchen(m, banned)
  if nk > 0 then table.insert(acts, 'Kueche +' .. nk .. ' Mahlzeit-Jobs') end
  local d = dump_rotten()
  if d > 0 then table.insert(acts, 'dump verfault ' .. d) end
  m.banned = cook_banned() and true or false
  m.actions = acts
  run_count = run_count + 1
  if run_count % SAY_EVERY == 1 then
    local prio = (m.meals < 40 or m.drinks < 40) and 4 or 1
    pcall(dfhack.run_command_silent, { 'claude/schau', 'say',
      ('Essen: %d Mahlzeiten, %d Fisch (+%d roh), Getraenke %d, PH %d'):format(m.meals, m.fish, m.fish_raw, m.drinks, m.ph), tostring(prio) })
  end
  return m
end

if cmd == 'start' then
  repeatUtil.scheduleEvery(KEY, INTERVAL, 'ticks', function() pcall(run) end)
  print('claude/essen laeuft alle ' .. INTERVAL .. ' Ticks')
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
  print('gestoppt')
elseif cmd == 'gather' and (arg2 == 'on' or arg2 == 'off') then
  local st = load_state()
  st.gather = (arg2 == 'on')
  save_state(st)
  print('Sammeln in Kaverne 2: ' .. arg2)
elseif cmd == 'gather' then
  local k, avail = gather(tonumber(arg2) or GATHER_BATCH)
  print(('markiert %d PH (verfuegbar %d)'):format(k, avail))
elseif cmd == 'status' or cmd == 'once' then
  local m = (cmd == 'status') and measure() or run()
  if cmd == 'status' then m.banned = cook_banned() and true or false end
  util.emit(m)
else
  -- unknown sub-command (typo, --help, 'status' of a script without one): usage only, no work round (BUG-407)
  util.emit({ error = 'unbekannter Befehl: ' .. tostring(cmd), usage = 'claude/essen start|stop|once|status|gather [n|on|off]' })
end
