-- claude/trinken start|stop|once|lager|status - brewing loop (scope "trinken"), owner: scope trinken. (run 3, v2)
-- Makes sure there are always empty containers (barrels, stone pots) for the brewery and the stills have orders:
--  1. Empty containers < target  -> barrel job directly at the carpenter ("make barrel", ONLY if wood > reserve) or
--     stone pot job at the craftsdwarf (UNTESTED, needs boulder); manager orders only if a MANAGER is appointed.
--  2. Brewing orders per still only as many as empty containers are free (otherwise abort loop
--     "Needs empty food storage item") and plants are available.
--  3. `lager`: check/enforce stockpile assignment: drink stockpile (DRINK only) may pull barrels (DRINK_BARRELS),
--     all other stockpiles with food get max_barrels = FOOD_BARRELS (0) -> empty barrels are not sucked away.
-- Workshop tasks only (fair play). Constants per map: up here (agreed with infra: later config.lua).
local util = reqscript('claude/util')
if not util.require_fort() then return end
local repeatUtil = require('repeat-util')
local json = require('json')
local KEY = 'claude-trinken'
local INTERVAL = 1200
local cmd = ({ ... })[1] or 'once'

local RESERVE_LOGS = 3      -- Hold back logs for workshop construction as long as no still stands
local EMPTY_TARGET = 6      -- empty containers permanently (KPI >= 6); with drinks < 100: EMPTY_TARGET_LOW
local EMPTY_TARGET_LOW = 8
local DRINK_TARGET_MIN = 100    -- Run 5: PH is scarce and so is food; brew only below 100 drinks (previously 250)
local DRINK_TARGET_OLD = 250    -- below this stock, brewing happens
local DRINK_BARRELS = 15    -- max_barrels of the drink stockpile (950 has 15 tiles)
local FOOD_BARRELS = 0      -- max_barrels of all other stockpiles with food

-- Ghost items (legacy, pos.x = -30000, neither container nor inventory) are ignored
local function real(i) return i.pos.x >= 0 or i.flags.in_inventory or dfhack.items.getContainer(i) ~= nil end
local function free(f) return not (f.forbid or f.rotten or f.dump or f.trader or f.garbage_collect or f.removed) end

-- brewable = plant material has reaction product DRINK_MAT (dimple cup/quarry bush/leaves do NOT have it: abort loop
-- "Needs unrotten fermentable plant"); fresh (not rotten), not forbidden, not in a job.
local function brewable(i)
  local mi = dfhack.matinfo.decode(i)
  if not mi or not mi.material then return false end
  for _, p in ipairs(mi.material.reaction_product.id) do
    if p.value == 'DRINK_MAT' then return true end
  end
  return false
end

local function pot_subtype()
  for i, d in ipairs(df.global.world.raws.itemdefs.tools) do
    if d.id == 'ITEM_TOOL_LARGE_POT' then return d.subtype end
  end
  return 12
end
local POT = pot_subtype()

local function has_manager()
  local ok, r = pcall(function()
    local e = df.global.plotinfo.main.fortress_entity
    for _, a in ipairs(e.positions.assignments) do
      for _, p in ipairs(e.positions.own) do
        if p.id == a.position_id and p.code == 'MANAGER' and a.histfig ~= -1 then return true end
      end
    end
    return false
  end)
  return ok and r
end

local function built(b) return b:getBuildStage() >= b:getMaxBuildStage() end
local function workshops(kind)
  local out = {}
  for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
    if b:getSubtype() == kind and built(b) then out[#out + 1] = b end
  end
  return out
end

local function measure()
  local s = { drinks = 0, plants = 0, barrels = 0, barrels_empty = 0, pots_empty = 0, pots = 0, logs = 0, boulders = 0,
              brew_jobs = 0, barrel_jobs = 0, pot_jobs = 0 }
  local items = df.global.world.items.other
  for _, i in ipairs(items.DRINK) do if real(i) and free(i.flags) then s.drinks = s.drinks + i:getStackSize() end end
  s.plants_all = 0
  for _, i in ipairs(items.PLANT) do
    if real(i) and free(i.flags) and not i.flags.in_job then
      s.plants_all = s.plants_all + i:getStackSize()
      if brewable(i) then s.plants = s.plants + i:getStackSize() end
    end
  end
  s.fruit = 0
  for _, i in ipairs(items.PLANT_GROWTH) do
    if real(i) and free(i.flags) and not i.flags.in_job and brewable(i) then s.fruit = s.fruit + i:getStackSize() end
  end
  s.fruit_jobs = 0
  for _, b in ipairs(items.BARREL) do
   if real(b) then
    s.barrels = s.barrels + 1
    if free(b.flags) and not b.flags.in_job and not b.flags.in_building and #dfhack.items.getContainedItems(b) == 0 then s.barrels_empty = s.barrels_empty + 1 end
   end
  end
  for _, t in ipairs(items.TOOL) do
    if real(t) and t:getSubtype() == POT then
      s.pots = s.pots + 1
      if free(t.flags) and not t.flags.in_job and not t.flags.in_building and #dfhack.items.getContainedItems(t) == 0 then
        s.pots_empty = s.pots_empty + 1
      end
    end
  end
  for _, w in ipairs(items.WOOD) do
    local f = w.flags
    if real(w) and free(f) and not f.in_job and not f.in_building then s.logs = s.logs + w:getStackSize() end
  end
  for _, b in ipairs(items.BOULDER) do
    if real(b) and free(b.flags) and not b.flags.in_job then s.boulders = s.boulders + 1 end
  end
  for _, w in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
    for _, j in ipairs(w.jobs) do
      if j.job_type == df.job_type.MakeBarrel then s.barrel_jobs = s.barrel_jobs + 1
      elseif j.job_type == df.job_type.MakeTool and j.item_subtype == POT then s.pot_jobs = s.pot_jobs + 1
      elseif j.job_type == df.job_type.CustomReaction and j.reaction_name == 'BREW_DRINK_FROM_PLANT' then s.brew_jobs = s.brew_jobs + 1
      elseif j.job_type == df.job_type.CustomReaction and j.reaction_name == 'BREW_DRINK_FROM_PLANT_GROWTH' then s.fruit_jobs = s.fruit_jobs + 1 end
    end
  end
  s.barrel_orders, s.pot_orders = 0, 0
  for _, o in ipairs(df.global.world.manager_orders.all) do
    if o.job_type == df.job_type.MakeBarrel then s.barrel_orders = s.barrel_orders + o.amount_left
    elseif o.job_type == df.job_type.MakeTool and o.item_subtype == POT then s.pot_orders = s.pot_orders + o.amount_left end
  end
  return s
end

local function order(job, n, extra)
  local j = { job = job, amount_total = n, amount_left = n }
  for k, v in pairs(extra or {}) do j[k] = v end
  dfhack.run_command_silent{ 'workorder', json.encode(j) }
end

-- Create a stone pot directly at the craftsdwarf workshop (UNTESTED: first check whether the job is accepted).
local function pot_job(ws, n)
  for _ = 1, n do
    local job = df.job:new()
    job.job_type = df.job_type.MakeTool
    job.item_subtype = POT
    job.mat_type = 0
    job.mat_index = -1
    job.pos = { x = ws.centerx, y = ws.centery, z = ws.z }
    local f = df.job_item:new()
    f.item_type = df.item_type.BOULDER
    f.quantity = 1
    f.mat_type = -1; f.mat_index = -1
    f.flags3.hard = true
    job.job_items.elements:insert('#', f)
    local ref = df.general_ref_building_holderst:new()
    ref.building_id = ws.id
    job.general_refs:insert('#', ref)
    ws.jobs:insert('#', job)
    dfhack.job.linkIntoWorld(job, true)
  end
  dfhack.job.checkBuildingsNow()
end

-- Stockpile assignment
local function lager(apply)
  local rep = {}
  local ok, err = pcall(function()
    for _, p in ipairs(df.global.world.buildings.other.STOCKPILE) do
      local st = p.settings
      local food = st.flags.food
      local drinkOn, otherFood = false, false
      if food then
        for _, v in ipairs(st.food.drink_plant) do if v ~= 0 then drinkOn = true end end
        for _, v in ipairs(st.food.drink_animal) do if v ~= 0 then drinkOn = true end end
        for _, k in ipairs{ 'meat', 'fish', 'unprepared_fish', 'egg', 'plants', 'seeds', 'prepared_meals', 'leaves',
                            'cheese_plant', 'cheese_animal', 'powder_plant', 'powder_creature', 'glob', 'glob_paste',
                            'glob_pressed', 'liquid_plant', 'liquid_animal', 'liquid_misc' } do
          local vec = st.food[k]
          if type(vec) == 'boolean' then
            if vec then otherFood = true end
          else
            for _, v in ipairs(vec) do if v ~= 0 then otherFood = true break end end
          end
          if otherFood then break end
        end
      end
      local role = (food and drinkOn and not otherFood) and 'getraenke' or ((food and otherFood) and 'essen' or 'sonst')
      local want
      if role == 'getraenke' then want = DRINK_BARRELS elseif role == 'essen' then want = FOOD_BARRELS end
      if want and apply and p.storage.max_barrels ~= want then p.storage.max_barrels = want end
      rep[#rep + 1] = { id = p.id, role = role, max_barrels = p.storage.max_barrels, name = p.name }
    end
  end)
  if not ok then rep.error = tostring(err) end
  return rep
end

local function run()
  local s = measure()
  local act = {}
  local stills, carps, crafts = workshops(df.workshop_type.Still), workshops(df.workshop_type.Carpenters),
                                workshops(df.workshop_type.Craftsdwarfs)
  s.stills, s.carpenters, s.craftsdwarfs = #stills, #carps, #crafts
  local mgr = has_manager()
  local target = (s.drinks < 100) and EMPTY_TARGET_LOW or EMPTY_TARGET
  local reserve = (#stills == 0) and RESERVE_LOGS or 0
  local have = s.barrels_empty + s.pots_empty + s.barrel_jobs + s.pot_jobs + (mgr and (s.barrel_orders + s.pot_orders) or 0)
  local need = target - have
  if need > 0 then
    local avail_logs = math.max(0, s.logs - reserve - s.barrel_jobs - (mgr and s.barrel_orders or 0))
    local nb = math.min(need, 3, avail_logs)
    if nb > 0 then
      if #carps > 0 then
        dfhack.run_script('claude/task', 'add', tostring(carps[1].id), 'make barrel', tostring(nb))
        act[#act + 1] = 'barrel-job x' .. nb
      elseif mgr then
        order('MakeBarrel', nb); act[#act + 1] = 'barrel-order x' .. nb
      else
        nb = 0
        act[#act + 1] = 'kein Tischler'
      end
    end
    local np = math.min(need - math.max(nb, 0), 3)
    if np > 0 and s.pots < 20 and s.boulders >= 3 and s.pot_jobs < 3 then
      if #crafts > 0 then
        local ok, e = pcall(pot_job, crafts[1], np)
        act[#act + 1] = ok and ('pot-job x' .. np) or ('pot-job FEHLER ' .. tostring(e))
      elseif mgr then
        order('MakeTool', np, { item_subtype = 'ITEM_TOOL_LARGE_POT', material = 'INORGANIC' })
        act[#act + 1] = 'pot-order x' .. np
      end
    end
  end
  -- Brewing: as many jobs as free empty containers, max 3 per still, only with plants
  local free_cont = s.barrels_empty + s.pots_empty - s.brew_jobs
  local DRINK_TARGET = DRINK_TARGET_MIN
  do local n = 0 for _, u in ipairs(df.global.world.units.active) do if dfhack.units.isCitizen(u) and dfhack.units.isAlive(u) and dfhack.units.isAdult(u) then n = n + 1 end end DRINK_TARGET = math.max(DRINK_TARGET_MIN, n * 5) end  -- Run 5 pass 6: 5 drinks per adult (~8 days)
  if s.drinks < DRINK_TARGET and (s.plants - s.brew_jobs) >= 1 and s.plants >= 2 and free_cont > 0 and #stills > 0 then
    table.sort(stills, function(a, b) return #a.jobs < #b.jobs end)
    local left = math.min(free_cont, s.plants - s.brew_jobs)
    for _, b in ipairs(stills) do
      if left <= 0 then break end
      local n = math.min(left, ((s.plants >= 20) and 8 or ((s.drinks < 50) and 4 or 3)) - #b.jobs)
      if n > 0 then
        dfhack.run_script('claude/task', 'add', tostring(b.id), 'brew drink from plant', tostring(n))
        left = left - n
        act[#act + 1] = 'brew@' .. b.id .. ' x' .. n
      end
    end
  end
  -- Fruits (grapes, plums ...): own brewing order, only if fruits are available and empty containers remain
  local free2 = s.barrels_empty + s.pots_empty - s.brew_jobs - s.fruit_jobs
  if s.drinks < DRINK_TARGET and s.fruit - s.fruit_jobs >= 1 and free2 > 0 and #stills > 0 then
    local n = math.min(free2, s.fruit - s.fruit_jobs, 3)
    dfhack.run_script('claude/task', 'add', tostring(stills[1].id), 'brew drink from fruit', tostring(n))
    act[#act + 1] = 'fruit@' .. stills[1].id .. ' x' .. n
  end
  local l = lager(true)
  state = state or {}
  state.last = { s = s, act = act, lager = l, tick = df.global.cur_year_tick }
  return s, act, l
end

if cmd == 'start' then
  repeatUtil.scheduleEvery(KEY, INTERVAL, 'ticks', function() pcall(run) end)
  local s, act, l = run()
  util.emit({ running = true, interval = INTERVAL, stats = s, actions = act, lager = l })
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
  util.emit({ running = false })
elseif cmd == 'lager' then
  util.emit({ lager = lager(true) })
elseif cmd == 'status' then
  util.emit({ stats = measure(), lager = lager(false), manager = has_manager() })
else
  local s, act, l = run()
  util.emit({ stats = s, actions = act, lager = l })
end
