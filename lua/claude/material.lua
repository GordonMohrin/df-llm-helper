-- claude/material once|start|stop|status - scope material/metal (Run 5 Windrings, desert, NO wood): coal -> coke -> ore -> bars -> tools/weapons/armor.
-- Chain (v5, 01.10.2026): smelter 'make coke from bituminous coal' (coal boulder -> coke bar, NO wood furnace/wood needed)
--   -> smelter 'smelt hematite|magnetite' (iron), 'smelt tetrahedrite' (copper+silver), 'smelt cassiterite' (tin), 'make bronze bars (use ore)'
--   -> forge via manager order (workorder MakeWeapon/MakeArmor/..., material IRON).
-- Workshop tasks + workorder only (fair). No cancel loops: smelt jobs only if ore AND coke are reachable; manager only creates forge jobs if material exists.
-- Priority: tools (picks) before elite soldiers (player: ~10 % of dwarves, quality over quantity; first 3 soldiers = phase 1), then phase 2
-- (6 soldiers + rest), cages. Per entry t1/t2 = total target (stock INCL. carried pieces) after phase 1 / 2. ITEMS order = priority.
-- Mood reserve: mood_reserve bars per metal stay untouched (metalcrafter moods).
-- No argument (or `once`) = run ONE round now. This default is intended and stays: the orchestrator, the watchdog and
-- the scope agents call `claude/material` without arguments. The read-only command is `status`; any other word prints usage and changes nothing (BUG-407).
local util = reqscript('claude/util')
if not util.require_fort() then return end
local repeatUtil = require('repeat-util')
local workshops = require('dfhack.workshops')
local json = require('json')
local KEY = 'claude-material'
local INTERVAL = 900
local cmd = ({ ... })[1] or 'once'

-- Scalar targets (change here or via state/material.json, field 'targets' for item targets, see load_goals)
local GOALS = {
  coke_target = 24,        -- free coke bars (1 coal boulder yields several); coke/charcoal = fuel for smelter AND forge
  max_coke_jobs = 2,       -- open coke jobs
  max_smelt_jobs = 4,      -- open jobs per smelter (excluding coke)
  spare_fuel = 4, coal_reserve = 20,          -- coke buffer
  iron_target = 70,        -- free iron bars to smelt up to (window; grows with the plan)
  iron_min = 30,           -- iron first, until this many bars exist (picks/kit), then bronze/copper
  copper_target = 10,      -- free copper bars (crafts/reserve; tetrahedrite also yields silver)
  tin_target = 8,          -- free tin bars (only if no bronze order is possible)
  bronze_target = 24,      -- free bronze bars (from tin + copper ore)
  mood_reserve = 3,        -- per metal, bars NOT consumed for mood workshops
  window_bars = 30,        -- plan this many iron bars ahead for forge orders
  order_batch = 4,         -- max. pieces per item ordered per run
  bars_per_smelt = 4,      -- bars per smelt job (estimate; 'smelt hematite' gave 3-4 in Run 3, verify in game)
  steel_min_iron = 14,     -- steel only once this many free iron bars exist (pick/kit iron keeps priority)
  steel_target = 24,       -- free steel bars (elite armor); pig iron 1 + iron 1 + flux + 2 coke -> 2 steel
  bed_target = 40,         -- metal beds (desert, no wood): total beds (built + free) to order up to
  bed_bronze_keep = 10,    -- bronze bars never consumed for beds (mood/tin reserve)
  coke_reserve = 2,        -- fuel bars never planned for smelting/forging (starter for the coke jobs; 1 charcoal -> 9 coke)
  anvil_target = 3,
  bin_target = 12,         -- metal bins (bronze) for finished-goods storage
  coke_yield = 9,          -- coke per coke job (raws: 9; verify in game)
}

-- key = ITEMTYPE:SUBTYPE-ID; job = manager job type; bars = bars per piece (estimate); t1/t2 = total target (iron)
-- (01.10. guard of 9 soldiers: kit t1=t2=9, 2 gloves/2 boots per soldier = 18)
-- Phase 1: picks first (3 embark picks + 4 new = 7), then kit for 3 elite soldiers; phase 2: 6 soldiers.
local ITEMS = {
  { key = 'WEAPON:ITEM_WEAPON_PICK',         job = 'MakeWeapon', bars = 1, t1 = 30, t2 = 32 },   -- Run 5: have counts ALL picks (also carried); ~15 miners -> target 15-17
  { key = 'ARMOR:ITEM_ARMOR_BREASTPLATE',    job = 'MakeArmor',  bars = 3, t1 = 9, t2 = 9 },
  { key = 'HELM:ITEM_HELM_HELM',             job = 'MakeHelm',   bars = 1, t1 = 9, t2 = 9 },
  { key = 'WEAPON:ITEM_WEAPON_AXE_BATTLE',   job = 'MakeWeapon', bars = 1, t1 = 9, t2 = 9 },     -- elite weapon (no woodcutter needed)
  { key = 'SHIELD:ITEM_SHIELD_SHIELD',       job = 'MakeShield', bars = 2, t1 = 9, t2 = 9 },
  { key = 'PANTS:ITEM_PANTS_GREAVES',        job = 'MakePants',  bars = 2, t1 = 9, t2 = 9 },
  { key = 'SHOES:ITEM_SHOES_BOOTS',          job = 'MakeShoes',  bars = 1, t1 = 18, t2 = 18 },   -- 2 boots per soldier
  { key = 'GLOVES:ITEM_GLOVES_GAUNTLETS',    job = 'MakeGloves', bars = 1, t1 = 18, t2 = 18 },   -- 2 gloves per soldier
  { key = 'WEAPON:ITEM_WEAPON_SWORD_SHORT',  job = 'MakeWeapon', bars = 1, t1 = 0, t2 = 3 },
  { key = 'WEAPON:ITEM_WEAPON_HAMMER_WAR',   job = 'MakeWeapon', bars = 1, t1 = 0, t2 = 3 },
  { key = 'CAGE',                            job = 'MakeCage',   bars = 1, t1 = 2, t2 = 6 },
}
local BYKEY = {}
for _, it in ipairs(ITEMS) do BYKEY[it.key] = it end

local function load_goals()
  local p = reqscript('claude/util').home() .. '/state/material.json'
  local f = io.open(p, 'r')
  if not f then return end
  local ok, d = pcall(json.decode, f:read('*a'))
  f:close()
  if ok and type(d) == 'table' then
    for k, v in pairs(d) do
      if k == 'targets' and type(v) == 'table' then
        for key, t in pairs(v) do
          if BYKEY[key] and type(t) == 'table' then
            for kk, vv in pairs(t) do BYKEY[key][kk] = vv end
          end
        end
      else GOALS[k] = v end
    end
  end
end

local function mat_id(it)
  local mi = dfhack.matinfo.decode(it)
  if not mi then return '?' end
  if mi.inorganic then return mi.inorganic.id end
  return mi:toString()
end

-- ore boulder -> { metal, smelter job name }
local ORE = {
  HEMATITE     = { 'IRON',   'smelt hematite' },
  MAGNETITE    = { 'IRON',   'smelt magnetite' },
  LIMONITE     = { 'IRON',   'smelt limonite' },
  TETRAHEDRITE = { 'COPPER', 'smelt tetrahedrite' },
  MALACHITE    = { 'COPPER', 'smelt malachite' },
  NATIVE_COPPER = { 'COPPER', 'smelt native copper' },
  CASSITERITE  = { 'TIN',    'smelt cassiterite' },
}
local COAL_ORE = { COAL_BITUMINOUS = true, LIGNITE = true }
local FLUX = { DOLOMITE = true, LIMESTONE = true, MARBLE = true, CALCITE = true, CHALK = true }   -- REACTION_CLASS:FLUX (steel)
local COUNTED = { WEAPON = true, ARMOR = true, HELM = true, PANTS = true, SHOES = true, GLOVES = true, SHIELD = true }

local function furnaces(kind)
  local res = {}
  for _, b in ipairs(df.global.world.buildings.all) do
    local t = b:getType()
    local name
    if t == df.building_type.Workshop then name = df.workshop_type[b:getSubtype()]
    elseif t == df.building_type.Furnace then name = df.furnace_type[b:getSubtype()] end
    if name == kind and b:getBuildStage() >= b:getMaxBuildStage() then res[#res + 1] = b end
  end
  return res
end

local function stock(sm)
  local s = { coal = 0, coke = 0, wood = 0, flux = 0, ore = {}, bars = {}, have = {} }
  local origin = sm and xyz2pos(sm.centerx, sm.centery, sm.z)
  local function reach(it)
    if not origin then return true end
    local x, y, z = dfhack.items.getPosition(it)
    if not x then return false end
    local ok, v = pcall(dfhack.maps.canWalkBetween, origin, xyz2pos(x, y, z))
    return ok and v
  end
  for _, it in ipairs(df.global.world.items.all) do
    local f = it.flags
    if it.pos.x >= 0 and not (f.trader or f.garbage_collect or f.removed or f.rotten or f.dump or f.construction) then
      local t = df.item_type[it:getType()]
      local free = not (f.forbid or f.in_building or f.in_job)
      if t == 'BAR' then
        if free then
          local m = mat_id(it)
          local ml = m:lower()   -- fuel bars are called 'coal'/'coke'/'charcoal' (material name lowercase)
          if ml:find('coke') or ml:find('charcoal') or ml == 'coal' then s.coke = s.coke + it.stack_size
          elseif not ml:find('^coal') then s.bars[m] = (s.bars[m] or 0) + it.stack_size end
        end
      elseif t == 'WOOD' then
        if free and not f.in_inventory and reach(it) then s.wood = s.wood + it.stack_size end
      elseif t == 'BOULDER' then
        if free and not f.in_inventory then
          local m = mat_id(it)
          if ORE[m] then
            if reach(it) then s.ore[m] = (s.ore[m] or 0) + 1 end
          elseif COAL_ORE[m] then
            if reach(it) then s.coal = s.coal + 1 end
          elseif FLUX[m] then
            if reach(it) then s.flux = s.flux + 1 end
          end
        end
      elseif COUNTED[t] then
        -- stock incl. carried/stored pieces (not: marked for melting)
        if not f.melt and (mat_id(it) == 'IRON' or mat_id(it) == 'STEEL') then
          local sid = it.subtype and it.subtype.id
          if sid then
            local key = t .. ':' .. sid
            s.have[key] = (s.have[key] or 0) + 1
          end
        end
      elseif t == 'CAGE' then
        -- only free cages (those built into traps do not count)
        if not f.in_building and not f.in_job and mat_id(it) == 'IRON' then s.have.CAGE = (s.have.CAGE or 0) + 1 end
      end
    end
  end
  return s
end

local function addjob(b, name)
  local defs = workshops.getJobs(b:getType(), b:getSubtype(), b:getCustomType()) or {}
  local def
  for _, d in pairs(defs) do if type(d) == 'table' and d.name and d.name:lower() == name then def = d end end
  if not def then return false end
  local job = df.job:new()
  job.pos = { x = b.centerx, y = b.centery, z = b.z }
  if def.job_fields then job:assign(def.job_fields) end
  for _, filter in ipairs(def.items or {}) do
    local f = copyall(filter); f.new = true
    job.job_items.elements:insert('#', f)
  end
  local ref = df.general_ref_building_holderst:new()
  ref.building_id = b.id
  job.general_refs:insert('#', ref)
  b.jobs:insert('#', job)
  dfhack.job.linkIntoWorld(job, true)
  return true
end

-- Classify smelter jobs: coke / bronze / ore:<ID> / other
local function classify_jobs(sm)
  local c = { coke = 0, bronze = 0, pig = 0, steel = 0, other = 0, ore = {} }
  for _, j in ipairs(sm.jobs) do
    local jt = df.job_type[j.job_type]
    if jt == 'CustomReaction' then
      local r = j.reaction_name or ''
      if r:find('COKE') then c.coke = c.coke + 1
      elseif r:find('BRONZE') then c.bronze = c.bronze + 1
      elseif r:find('PIG_IRON') then c.pig = c.pig + 1
      elseif r:find('STEEL') then c.steel = c.steel + 1
      else c.other = c.other + 1 end
    elseif jt == 'SmeltOre' then
      local ino = df.global.world.raws.inorganics.all[j.mat_index]
      local id = ino and ino.id or '?'
      c.ore[id] = (c.ore[id] or 0) + 1
    else c.other = c.other + 1 end
  end
  return c
end

-- Subtype tables per item type (name -> index), for counting open manager orders
local SUBIDX = {
  WEAPON = df.global.world.raws.itemdefs.weapons, ARMOR = df.global.world.raws.itemdefs.armor,
  HELM = df.global.world.raws.itemdefs.helms, PANTS = df.global.world.raws.itemdefs.pants,
  SHOES = df.global.world.raws.itemdefs.shoes, GLOVES = df.global.world.raws.itemdefs.gloves,
  SHIELD = df.global.world.raws.itemdefs.shields,
}
local function subtype_of(key)
  local t, sid = key:match('^(%w+):(.+)$')
  if not t then return nil end
  for _, d in ipairs(SUBIDX[t] or {}) do if d.id == sid then return d.subtype end end
end

-- open manager orders per item key (iron or cage orders only)
local function orders_open()
  local res = {}
  for _, mo in ipairs(df.global.world.manager_orders.all) do
    if mo.amount_left > 0 then
      local jt = df.job_type[mo.job_type]
      for _, it in ipairs(ITEMS) do
        if it.job == jt then
          if it.key == 'CAGE' then res.CAGE = (res.CAGE or 0) + mo.amount_left
          elseif mo.item_subtype == it.sub then res[it.key] = (res[it.key] or 0) + mo.amount_left end
        end
      end
    end
  end
  return res
end

local function place_order(it, amt, mat)
  local j = { job = it.job, material = 'INORGANIC:' .. (mat or 'IRON'), amount_total = amt, amount_left = amt }
  if it.key ~= 'CAGE' then j.item_subtype = it.key:match(':(.+)$') end
  dfhack.run_command_silent{ 'workorder', json.encode(j) }
end

-- Quality over quantity (player): forge labors only for fixed smiths, so XP is concentrated (masterworks/high quality
-- for the elite armor). SMELT also for furnace operators. New migrants get default labors -> re-apply on every run.
local function smith_lock()
  local smiths = {}
  for _, id in ipairs(GOALS.smiths or { 4078, 4155 }) do smiths[id] = true end
  local smelters = {}
  for _, id in ipairs(GOALS.smelters or { 4078, 4155, 4161 }) do smelters[id] = true end
  local alive = 0
  for _, u in ipairs(dfhack.units.getCitizens()) do if smiths[u.id] then alive = alive + 1 end end
  if alive == 0 then return 0 end
  local n = 0
  local L = df.unit_labor
  for _, u in ipairs(dfhack.units.getCitizens()) do
    if dfhack.units.isAdult(u) then
      for _, name in ipairs({ 'FORGE_WEAPON', 'FORGE_ARMOR', 'FORGE_FURNITURE' }) do
        local want = smiths[u.id] or false
        if u.status.labors[L[name]] ~= want then u.status.labors[L[name]] = want; n = n + 1 end
      end
      local ws = (smiths[u.id] or smelters[u.id]) or false
      if u.status.labors[L.SMELT] ~= ws then u.status.labors[L.SMELT] = ws; n = n + 1 end
    end
  end
  return n
end

local function run()
  load_goals()
  pcall(smith_lock)
  for _, it in ipairs(ITEMS) do it.sub = it.sub or subtype_of(it.key) end
  local sms = furnaces('Smelter')
  local s = stock(sms[1])
  local log = {}
  local oo = orders_open()
  local iron = s.bars.IRON or 0
  local pending_items, pending_bars = 0, 0
  for key, n in pairs(oo) do pending_items = pending_items + n; pending_bars = pending_bars + n * BYKEY[key].bars end
  -- Plan: missing pieces in priority order (phase 1 complete, then phase 2)
  local plan, planned = {}, {}
  for _, ph in ipairs({ 't1', 't2' }) do
    for _, it in ipairs(ITEMS) do
      local have = (s.have[it.key] or 0) + (oo[it.key] or 0) + (planned[it.key] or 0)
      local miss = (it[ph] or 0) - have
      if miss > 0 then
        plan[#plan + 1] = { it = it, miss = miss, phase = ph }
        planned[it.key] = (planned[it.key] or 0) + miss
      end
    end
  end
  -- Window: plan this many iron bars ahead
  local win_bars, win_items = pending_bars, pending_items
  for _, p in ipairs(plan) do
    if win_bars >= GOALS.window_bars then break end
    local take = math.min(p.miss, math.ceil((GOALS.window_bars - win_bars) / p.it.bars))
    win_bars = win_bars + take * p.it.bars
    win_items = win_items + take
  end
  local sm = sms[1]
  local jc = sm and classify_jobs(sm) or { coke = 0, bronze = 0, pig = 0, steel = 0, other = 0, ore = {} }
  local smelt_open = 0
  for _, n in pairs(jc.ore) do smelt_open = smelt_open + n end
  smelt_open = smelt_open + jc.bronze + jc.other + jc.pig + jc.steel
  local bps = GOALS.bars_per_smelt
  local ns, nc = 0, 0
  if sm then
    -- 1) Coke (coal boulder -> coke bar): fuel demand = forge pieces + smelt jobs + buffer
    local fuel_need = math.min(GOALS.coke_target, win_items + smelt_open + GOALS.spare_fuel + 8)
    local coal_free = s.coal - jc.coke - (GOALS.coal_reserve or 0)   -- player 01.10.: keep ~20 coal boulders as reserve in case coke runs out
    -- [FUEL] reaction: each coke job needs 1 fuel bar (coke/charcoal) at start -> only create if a starter exists
    -- (otherwise cancel loop 'Needs refined coal'); starter = charcoal from the wood furnace (see below)
    while s.coke + jc.coke * GOALS.coke_yield + nc * GOALS.coke_yield < fuel_need and coal_free > 0
          and jc.coke + nc < GOALS.max_coke_jobs and (#sm.jobs) < 12 and s.coke > jc.coke + nc do
      if addjob(sm, 'make coke from bituminous coal') then nc = nc + 1; coal_free = coal_free - 1 else break end
    end
    if nc > 0 then log[#log + 1] = 'coke +' .. nc end
    -- Starter: no fuel bar in the fort -> charcoal from logs (wood furnace), as long as no coke/no coal job runs
    if s.coke < 1 and s.coal > 0 then   -- also if a coke job is stuck (waiting for exactly this starter); save wood: 1 job at a time
      local wf = furnaces('WoodFurnace')[1]
      if wf and s.wood > 12 then   -- wood reserve 12 for carpenter moods (Run 5: 3 moods failed due to wood 0)
        local open = 0
        for _, j in ipairs(wf.jobs) do open = open + 1 end
        if open == 0 and (addjob(wf, 'make charcoal') or addjob(wf, 'make charcoal from wood')) then log[#log + 1] = 'charcoal start' end
      else
        log[#log + 1] = 'KEIN BRENNSTOFF-ANLASSER: ' .. (wf and 'kein Holz' or 'kein Holzofen')
      end
    end
    -- 2) Smelt ore (coke needed; coke for already ordered pieces stays reserved)
    local fuel_free = s.coke - GOALS.coke_reserve - pending_items - smelt_open
    local function ore_left(id) return (s.ore[id] or 0) - (jc.ore[id] or 0) end
    local function try_smelt(id, maxn)
      local n = 0
      while n < maxn and fuel_free > 0 and ore_left(id) > 0 and smelt_open + ns < GOALS.max_smelt_jobs do
        if addjob(sm, ORE[id][2]) then
          n = n + 1; ns = ns + 1; fuel_free = fuel_free - 1
          jc.ore[id] = (jc.ore[id] or 0) + 1
        else break end
      end
      return n
    end
    local iron_pipe = iron + (((jc.ore.HEMATITE or 0) + (jc.ore.MAGNETITE or 0) + (jc.ore.LIMONITE or 0)) * bps)
    local function smelt_iron(limit)
      for _, id in ipairs({ 'HEMATITE', 'MAGNETITE', 'LIMONITE' }) do
        while iron_pipe < limit and try_smelt(id, 1) > 0 do iron_pipe = iron_pipe + bps end
      end
    end
    -- a) Iron up to iron_min (picks/kit first)
    smelt_iron(GOALS.iron_min)
    -- b) Bronze (tin + copper ore) / copper
    local bronze = s.bars.BRONZE or 0
    local copper_pipe = (s.bars.COPPER or 0) + ((jc.ore.TETRAHEDRITE or 0) + (jc.ore.MALACHITE or 0) + (jc.ore.NATIVE_COPPER or 0)) * bps
    local cass_left = ore_left('CASSITERITE')
    local cu_left = ore_left('TETRAHEDRITE') + ore_left('MALACHITE') + ore_left('NATIVE_COPPER')
    local nb = 0
    while bronze + (jc.bronze + nb) * 8 < GOALS.bronze_target and cass_left > 0 and cu_left > 0 and fuel_free > 0
          and smelt_open + ns + nb < GOALS.max_smelt_jobs do
      if addjob(sm, 'make bronze bars (use ore)') then
        nb = nb + 1; cass_left = cass_left - 1; cu_left = cu_left - 1; fuel_free = fuel_free - 1
        jc.ore.CASSITERITE = (jc.ore.CASSITERITE or 0) + 1   -- reserved (count; copper ore type imprecise)
        jc.ore.TETRAHEDRITE = (jc.ore.TETRAHEDRITE or 0) + 1
      else break end
    end
    if nb > 0 then log[#log + 1] = 'bronze +' .. nb; ns = ns + nb end
    local cu_reserve = math.max(0, ore_left('CASSITERITE'))   -- hold back copper ore for later bronze
    for _, id in ipairs({ 'TETRAHEDRITE', 'MALACHITE', 'NATIVE_COPPER' }) do
      while copper_pipe < GOALS.copper_target and ore_left(id) > cu_reserve and try_smelt(id, 1) > 0 do copper_pipe = copper_pipe + bps end
    end
    -- Tin only if no copper ore is available for bronze
    if cu_left <= 0 then
      local tin_pipe = (s.bars.TIN or 0) + (jc.ore.CASSITERITE or 0) * bps
      while tin_pipe < GOALS.tin_target and try_smelt('CASSITERITE', 1) > 0 do tin_pipe = tin_pipe + bps end
    end
    -- c) Iron up to the plan window
    smelt_iron(math.max(GOALS.iron_min, math.min(GOALS.iron_target, win_bars + GOALS.mood_reserve)))
    -- d) Steel (elite armor): pig iron (iron + flux + coke) -> steel (iron + pig iron + flux + coke) -> 2 steel; flux = dolomite/limestone boulder
    do
      local steel, pig = s.bars.STEEL or 0, s.bars.PIG_IRON or 0
      local flux_left = s.flux
      if iron >= GOALS.steel_min_iron and steel + jc.steel * 2 < GOALS.steel_target then
        while pig + jc.pig < 1 and flux_left > 0 and fuel_free > 0 and smelt_open + ns < GOALS.max_smelt_jobs do
          if addjob(sm, 'make pig iron bars') then jc.pig = jc.pig + 1; ns = ns + 1; flux_left = flux_left - 1; fuel_free = fuel_free - 1; log[#log + 1] = 'pig iron +1' else break end
        end
        if pig >= 1 and jc.steel < 1 and flux_left > 0 and fuel_free > 0 and smelt_open + ns < GOALS.max_smelt_jobs then
          if addjob(sm, 'make steel bars') then jc.steel = jc.steel + 1; ns = ns + 1; log[#log + 1] = 'steel +1' end
        end
      end
    end
    if ns > 0 then log[#log + 1] = 'smelt +' .. ns end
    s.fuel_free = fuel_free
  end
  -- 3) Forge orders (priority; stops at the first unaffordable entry so priority is not overtaken)
  local free_bars = iron - pending_bars - GOALS.mood_reserve
  local free_steel = math.max(0, (s.bars.STEEL or 0) - 0)
  local fuel_o = s.coke - GOALS.coke_reserve - pending_items - smelt_open
  for _, p in ipairs(plan) do
    local it = p.it
    local cap = math.min(p.miss, GOALS.order_batch)
    local n = math.min(cap, math.floor(free_bars / it.bars), math.max(0, fuel_o))
    -- Elite kit (not pick/cage): prefer steel once enough steel bars are free
    local ns_ = (it.key ~= 'WEAPON:ITEM_WEAPON_PICK' and it.key ~= 'CAGE') and math.min(cap, math.floor(free_steel / it.bars), math.max(0, fuel_o)) or 0
    if ns_ > 0 then
      place_order(it, ns_, 'STEEL')
      log[#log + 1] = 'order STEEL ' .. it.key .. ' x' .. ns_
      free_steel = free_steel - ns_ * it.bars
      fuel_o = fuel_o - ns_
      n = ns_
    elseif n > 0 then
      place_order(it, n)
      log[#log + 1] = 'order ' .. it.key .. ' x' .. n
      free_bars = free_bars - n * it.bars
      fuel_o = fuel_o - n
    end
    if n < cap then break end
  end
  -- 4) Metal beds from surplus bronze (iron stays for armor/steel); anvils for forges 2/3 (iron)
  do
    local beds, bed_open, anv_open = 0, 0, 0
    for _, it in ipairs(df.global.world.items.other.BED) do if not (it.flags.removed or it.flags.garbage_collect) then beds = beds + 1 end end
    for _, mo in ipairs(df.global.world.manager_orders.all) do
      if mo.amount_left > 0 then
        local jt = df.job_type[mo.job_type]
        if jt == 'ConstructBed' then bed_open = bed_open + mo.amount_left
        elseif jt == 'ForgeAnvil' then anv_open = anv_open + mo.amount_left end
      end
    end
    local bronze = (s.bars.BRONZE or 0) - GOALS.bed_bronze_keep
    local nb = math.min(4, GOALS.bed_target - beds - bed_open, bronze - bed_open, math.max(0, s.coke - pending_items))
    if nb > 0 and bed_open < 4 then
      dfhack.run_command_silent{ 'workorder', json.encode({ job = 'ConstructBed', material = 'INORGANIC:BRONZE', amount_total = nb, amount_left = nb }) }
      log[#log + 1] = 'order BED bronze x' .. nb
    end
    -- Container for finished goods: bins only possible from metal (no wood; forge accepts ConstructBin, tested 01.10.)
    local bins, bin_open = 0, 0
    for _, it in ipairs(df.global.world.items.other.BIN) do if not (it.flags.removed or it.flags.garbage_collect) then bins = bins + 1 end end
    for _, mo in ipairs(df.global.world.manager_orders.all) do
      if mo.amount_left > 0 and df.job_type[mo.job_type] == 'ConstructBin' then bin_open = bin_open + mo.amount_left end
    end
    local bn = math.min(3, GOALS.bin_target - bins - bin_open, bronze - nb - bin_open)
    if bn > 0 and bin_open < 3 then
      dfhack.run_command_silent{ 'workorder', json.encode({ job = 'ConstructBin', material = 'INORGANIC:BRONZE', amount_total = bn, amount_left = bn }) }
      log[#log + 1] = 'order BIN bronze x' .. bn
    end
    local anv = #df.global.world.items.other.ANVIL
    local forges_wo_anvil = 0
    for _, b in ipairs(df.global.world.buildings.all) do
      if b:getType() == df.building_type.Workshop and df.workshop_type[b:getSubtype()] == 'MetalsmithsForge' then forges_wo_anvil = forges_wo_anvil + 1 end
    end
    if anv + anv_open < math.min(GOALS.anvil_target, forges_wo_anvil) and iron - pending_bars > 3 then
      dfhack.run_command_silent{ 'workorder', json.encode({ job = 'ForgeAnvil', material = 'INORGANIC:IRON', amount_total = 1, amount_left = 1 }) }
      log[#log + 1] = 'order ANVIL x1'
    end
  end
  local summary = {}
  for _, p in ipairs(plan) do summary[#summary + 1] = p.phase .. ' ' .. p.it.key .. ' -' .. p.miss end
  return s, log, { plan = summary, pending_items = pending_items, pending_bars = pending_bars, win_bars = win_bars,
    smelt_jobs = smelt_open + ns, coke_jobs = jc.coke + nc, smelters = #sms, ore_jobs = jc.ore }
end

if cmd == 'start' then
  repeatUtil.scheduleEvery(KEY, INTERVAL, 'ticks', function() pcall(run) end)
  local s, log = run()
  util.emit({ running = true, interval = INTERVAL, stock = s, log = log })
elseif cmd == 'stop' then
  repeatUtil.cancel(KEY)
  util.emit({ running = false })
elseif cmd == 'status' then
  load_goals()
  local s = stock(furnaces('Smelter')[1])
  util.emit({ goals = GOALS, items = ITEMS, stock = s })
elseif cmd == 'once' then
  local s, log, d = run()
  util.emit({ stock = s, log = log, detail = d })
else
  -- unknown sub-command (typo, --help, 'status' of a script without one): usage only, no work round (BUG-407)
  util.emit({ error = 'unbekannter Befehl: ' .. tostring(cmd), usage = 'claude/material once|start|stop|status' })
end
