-- economy (WP8): item census K.census.i (CONTRACTS §6.3), stock days with a 7-day moving average,
-- staged orders-library imports, dfllm-tagged supply orders, the PLUMP_HELMET kitchen exclusion,
-- the cancel-loop detector, labormanager starvation KPI and the idle rule D-03 (DESIGN §5.5, §5.9, §5.11).
-- Reads: items.other vectors (sliced), buildings.other vectors, manager orders, citizens by census id.
-- Writes only through K.act (orders_import, orders, workorder, order_suspend, kitchen_exclude, run).
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')

local M = {name = 'economy', every = {ticks = 1200}, on = {},
           reports = {MIGRANT_ARRIVAL = true, MIGRANT_ARRIVAL_NAMED = true, D_MIGRANTS_ARRIVAL = true,
                      CANCEL_JOB = true}}
local DAY = C.TICKS.DAY
local COAL = 7                       -- df.builtin_mats.COAL: charcoal and coke bars (fuel)

-- mirror of config/baseline.json "economy" (tests/lua/test_economy.lua checks they agree)
M.DEFAULTS = {
  per_slice = 200,
  seed_milli = {drink = 53, food = 24},          -- Run 6 rates per dwarf and day, x1000 (DESIGN §5.11)
  spike_x = 3,
  food_cats = {'FOOD', 'MEAT', 'FISH', 'CHEESE', 'EGG', 'PLANT', 'PLANT_GROWTH'},
  mood_keys = {'cloth', 'leather', 'bone', 'shell', 'gems', 'bars'},
  mood_from_phase = 'P3',
  -- the plant and its seeds: seedwatch never manages these plants (baseline), so its seeds need the ban
  kitchen = {{plant = 'MUSHROOM_HELMET_PLUMP', mat = 'STRUCTURAL', item = 'PLANT', what = 'Cook'},
             {plant = 'MUSHROOM_HELMET_PLUMP', mat = 'SEED', item = 'SEEDS', what = 'Cook'}},
  famine_days = 10,
  stages = {
    {lib = 'library/basic', any = {'migrants', 'cit>=10'}},
    {lib = 'library/rockstock', any = {'workshop:Masons'}},
    {lib = 'library/furnace', any = {'furnace:Smelter', 'furnace:WoodFurnace'}},
    {lib = 'library/smelting', all = {'furnace:Smelter', 'fuel'}},
    {lib = 'library/military', all = {'workshop:MetalsmithsForge'}},
  },
  signatures = {   -- an order only that library creates (hack/data/orders/*.json): already imported
    ['library/basic'] = {job = 'CustomReaction', reaction = 'BREW_DRINK_FROM_PLANT'},
    ['library/furnace'] = {job = 'MakeCharcoal'},
    ['library/smelting'] = {job = 'SmeltOre', mat = 'INORGANIC:GARNIERITE'},
    ['library/military'] = {job = 'MakeQuiver'},
    ['library/rockstock'] = {job = 'ConstructArmorStand', mat = 'INORGANIC'},
    ['library/glassstock'] = {job = 'ConstructArmorStand', mat = 'GLASS_GREEN'},
  },
  supply = {
    {tag = 'dfllm:drink', key = 'drink_d', per_job = 5, max_jobs = 30,
     spec = {job = 'CustomReaction', reaction = 'BREW_DRINK_FROM_PLANT', frequency = 'OneTime',
             item_conditions = {{condition = 'AtLeast', flags = {'unrotten'}, item_type = 'PLANT', reaction_product = 'DRINK_MAT', value = 2},
                                {condition = 'AtLeast', flags = {'empty', 'food_storage'}, value = 1}}}},
    {tag = 'dfllm:food', key = 'food_d', per_job = 4, max_jobs = 20,
     spec = {job = 'PrepareMeal', meal_ingredients = 2, frequency = 'OneTime',
             item_conditions = {{condition = 'AtLeast', flags = {'unrotten', 'cookable'}, value = 10}}}},
    {tag = 'dfllm:cloth', key = 'cloth', per_job = 1, max_jobs = 10, from_phase = 'P3',
     spec = {job = 'WeaveCloth', material_category = {'plant'}, frequency = 'OneTime',
             item_conditions = {{condition = 'AtLeast', flags = {'collected', 'plant'}, item_type = 'THREAD', value = 1}}}},
  },
  idle = {
    pct = 40, days = 3, boulders_min = 30, blocks_cap = 200, crafts_cap = 60, combine_every = 3600,
    craft_cats = {'FIGURINE', 'AMULET', 'RING', 'EARRING', 'BRACELET', 'SCEPTER', 'CROWN', 'TOTEM'},
    backlog = {
      {id = 'blocks', tag = 'dfllm:idle_blocks', amount = 10,
       spec = {job = 'ConstructBlocks', material = 'INORGANIC', frequency = 'OneTime'}},
      {id = 'crafts', tag = 'dfllm:idle_crafts', amount = 5,
       spec = {job = 'MakeCrafts', material = 'INORGANIC', frequency = 'OneTime'}},
      {id = 'combine'},
    },
  },
  cancel_loop = 5,
}

local st = {}

local function copy(t)
  if type(t) ~= 'table' then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = copy(v) end
  return setmetatable(r, getmetatable(t))
end

function M.conf(K)
  local c = type(K.cfg.baseline) == 'table' and K.cfg.baseline.economy
  if type(c) ~= 'table' then return M.DEFAULTS end
  local r = {}
  for k, v in pairs(M.DEFAULTS) do r[k] = v end
  for k, v in pairs(c) do r[k] = v end
  return r
end

local function decision(K, id) return tostring((K.cfg.decisions or {})[id] or C.DECISIONS[id] or '') end

-- persist m.economy; maps are re-tagged as objects (a decoded empty map is an array, json.lua:104)
local MAPS = {'imported', 'orders', 'low'}
local function pstate(K)
  local p = K.persist.get('m.economy')
  if type(p) ~= 'table' then
    p = {v = 2, hist = {drink = {}, food = {}}, prev = json.object{}, idle_days = 0, migrants = 0, cit = 0}
    K.persist.set('m.economy', p)
  end
  for _, k in ipairs(MAPS) do p[k] = json.object(type(p[k]) == 'table' and p[k] or {}) end
  if type(p.hist) ~= 'table' then p.hist = {} end
  p.hist.drink, p.hist.food = p.hist.drink or {}, p.hist.food or {}
  p.prev = json.object(type(p.prev) == 'table' and p.prev or {})
  return p
end

---------------------------------------------------------------- item census (sliced, items.other)
local CATS = {'DRINK', 'FOOD', 'MEAT', 'FISH', 'CHEESE', 'EGG', 'PLANT', 'PLANT_GROWTH', 'CLOTH', 'SKIN_TANNED',
              'CORPSEPIECE', 'SMALLGEM', 'ROUGH', 'BAR', 'AMMO', 'WOOD'}
local SKIP = {'trader', 'garbage_collect', 'removed', 'dump', 'hostile', 'in_building', 'construction', 'rotten'}

local mcache, bolt_sub = {}, {}
local function mat_flags(it)                    -- material flags, cached per census (Lua API.txt:808)
  local t, i = it.mat_type, it.mat_index
  local row = mcache[t]
  if not row then row = {}; mcache[t] = row end
  local f = row[i]
  if f == nil then
    local mi = dfhack.matinfo.decode(t, i)
    f = mi and mi.material and mi.material.flags or false
    row[i] = f
  end
  return f or nil
end

local function subtype(it)                      -- item:getSubtype() (virtual on every item), else the field
  local ok, s = pcall(function() return it:getSubtype() end)
  if ok and s ~= nil then return s end
  return it.subtype
end

local function is_bolt(it)                      -- items.getSubtypeDef (Lua API.txt:2015)
  local s = subtype(it)
  if bolt_sub[s] == nil then
    local def = dfhack.items.getSubtypeDef(df.item_type.AMMO, s)
    bolt_sub[s] = def ~= nil and def.id == 'ITEM_AMMO_BOLTS'
  end
  return bolt_sub[s]
end

local function classify(it, a, cat)
  local f = it.flags
  for _, k in ipairs(SKIP) do if f[k] then return end end
  local n = math.tointeger(it.stack_size) or 1
  if cat == 'DRINK' or cat == 'FOOD' then
    local cont = dfhack.items.getContainer(it)  -- Lua API.txt:2035
    if f.forbid or (cont and cont.flags.forbid) then
      if cat == 'DRINK' then a.drink_forb = a.drink_forb + n else a.food_forb = a.food_forb + n end
      return
    end
  elseif f.forbid then return end
  if cat == 'DRINK' then a.drink = a.drink + n
  elseif a.food_set[cat] then
    if cat == 'PLANT' or cat == 'PLANT_GROWTH' then
      local mf = mat_flags(it)
      if not (mf and (mf.EDIBLE_RAW or mf.EDIBLE_COOKED)) then return end
    end
    a.food = a.food + n
    if cat == 'FOOD' then a.meals = a.meals + n; a.kinds[subtype(it) or -1] = true end
  elseif cat == 'CLOTH' then a.cloth = a.cloth + n
  elseif cat == 'SKIN_TANNED' then a.leather = a.leather + n
  elseif cat == 'CORPSEPIECE' then
    local cf = it.corpse_flags
    if cf and not cf.unbutchered then
      if cf.bone then a.bone = a.bone + n elseif cf.shell then a.shell = a.shell + n end
    end
  elseif cat == 'SMALLGEM' or cat == 'ROUGH' then a.gems = a.gems + n
  elseif cat == 'BAR' then
    if it.mat_type == 0 then a.bars = a.bars + n elseif it.mat_type == COAL then a.fuel = a.fuel + n end
  elseif cat == 'AMMO' then if is_bolt(it) then a.bolts = a.bolts + n end
  elseif cat == 'WOOD' then a.wood = a.wood + n end
end

local function new_acc(c)
  local fs = {}
  for _, k in ipairs(c.food_cats or {}) do fs[k] = true end
  return {drink = 0, food = 0, meals = 0, cloth = 0, leather = 0, bone = 0, shell = 0, gems = 0, bars = 0,
          bolts = 0, wood = 0, fuel = 0, drink_forb = 0, food_forb = 0, kinds = {}, food_set = fs}
end

-- one slice: at most per_slice items; true when every category is done
local function census_slice(c)
  local cs = st.census
  local left = math.max(1, math.tointeger(c.per_slice) or 200)
  local other = df.global.world.items.other
  while left > 0 and cs.ci <= #CATS do
    local cat = CATS[cs.ci]
    local okv, vec = pcall(function() return other[cat] end)   -- unknown enum names raise in DFHack
    local n = okv and vec and #vec or 0
    while left > 0 and cs.idx < n do
      local it = vec[cs.idx]
      cs.idx, left = cs.idx + 1, left - 1
      if it then
        local ok, err = pcall(classify, it, cs.acc, cat)
        if not ok then cs.errs = cs.errs + 1; cs.err = cs.err or tostring(err) end
      end
    end
    if cs.idx >= n then cs.ci, cs.idx = cs.ci + 1, 0 end
  end
  return cs.ci > #CATS
end

local function vlen(cat)
  local ok, n = pcall(function() return #df.global.world.items.other[cat] end)
  return ok and n or 0
end

local function publish(K, c, a)
  local kinds = 0
  for _ in pairs(a.kinds) do kinds = kinds + 1 end
  local crafts = 0
  for _, cat in ipairs(c.idle.craft_cats or {}) do crafts = crafts + vlen(cat) end
  -- §6.3 fields plus WP8 extras (fuel, *_forb, boulders, blocks, crafts); replaced wholesale
  K.census.i = {tick = K.now().tick, drink = a.drink, food = a.food, meals = a.meals, meal_kinds = kinds,
                cloth = a.cloth, leather = a.leather, bone = a.bone, shell = a.shell, gems = a.gems,
                bars = a.bars, bolts = a.bolts, wood = a.wood, fuel = a.fuel, drink_forb = a.drink_forb,
                food_forb = a.food_forb, boulders = vlen('BOULDER'), blocks = vlen('BLOCKS'), crafts = crafts}
end

---------------------------------------------------------------- stock days (7-day moving average)
-- a day's consumption sample (milli-units): the observed net decrease, floored at the seeded
-- per-dwarf rate and capped at spike_x times it (trade sales, spoilage)
function M.sample(prev, now_n, base, spike)
  local dec = (prev and prev > now_n) and (prev - now_n) * 1000 or 0
  return math.max(base, math.min(dec, base * spike))
end

function M.days(stock, hist)
  local sum = 0
  for _, v in ipairs(hist) do sum = sum + v end
  if sum <= 0 then return 9999 end
  return math.min(9999, stock * 1000 * #hist // sum)
end

local function push(hist, v)
  hist[#hist + 1] = v
  while #hist > 7 do table.remove(hist, 1) end
end

---------------------------------------------------------------- orders
local function orders_all() return df.global.world.manager_orders.all end

local function order_by_id(id)
  if math.type(id) ~= 'integer' then return nil end
  for _, o in ipairs(orders_all()) do if o.id == id then return o end end
end

local function live(id)
  local o = order_by_id(id)
  return o ~= nil and (o.amount_left or 0) > 0
end

-- own: ids of our dfllm-tagged orders (a dfllm:drink order brews like library/basic does)
local function has_signature(sig, own)
  if type(sig) ~= 'table' then return false end
  for _, o in ipairs(orders_all()) do
    if not own[o.id] and df.job_type[o.job_type] == sig.job and (not sig.reaction or o.reaction_name == sig.reaction) then
      if not sig.mat then return true end
      local mi = dfhack.matinfo.decode(o.mat_type, o.mat_index)
      if mi and mi:getToken() == sig.mat then return true end
    end
  end
  return false
end

local function built(b)
  local ok, done = pcall(function() return b:getBuildStage() >= b:getMaxBuildStage() end)
  return not ok or done
end

local function facts(K, p)
  local f = {migrants = p.migrants == 1, fuel = ((K.census.i or {}).fuel or 0) > 0}
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.WORKSHOP_ANY) do
      local n = df.workshop_type[b.type]
      if n and built(b) then f['workshop:' .. n] = true end
    end
  end)
  pcall(function()
    for _, b in ipairs(df.global.world.buildings.other.FURNACE_ANY) do
      local n = df.furnace_type[b.type]
      if n and built(b) then f['furnace:' .. n] = true end
    end
  end)
  return f
end

local function holds(f, cit, cond)
  local n = tostring(cond):match('^cit>=([0-9]+)$')
  if n then return cit >= math.tointeger(tonumber(n)) end
  return f[cond] == true
end

function M.stage_ready(stage, f, cit)
  if stage.all then
    for _, cond in ipairs(stage.all) do if not holds(f, cit, cond) then return false end end
    return true
  end
  for _, cond in ipairs(stage.any or {}) do if holds(f, cit, cond) then return true end end
  return false
end

-- staged library imports (DESIGN §5.5) plus plan.orders / season orders; each library once
local function imports(K, c, p)
  local want, seen = {}, {}
  local function add(lib) if not p.imported[lib] and not seen[lib] then seen[lib] = true; want[#want + 1] = lib end end
  local f = facts(K, p)
  for _, s in ipairs(c.stages or {}) do if M.stage_ready(s, f, p.cit) then add(s.lib) end end
  for _, lib in ipairs((K.plan.orders or {}).import or {}) do add(lib) end
  local season = type(K.plan.seasons) == 'table' and K.plan.seasons[K.now().season + 1]
  for _, lib in ipairs(season and season.orders and season.orders.import or {}) do add(lib) end
  local n, own = 0, {}
  for _, id in pairs(p.orders) do own[id] = true end
  for _, lib in ipairs(want) do
    if has_signature((c.signatures or {})[lib], own) then
      p.imported[lib] = K.now().tick
      K.log('info', 'orders %s already present: not imported again', lib)
    elseif K.act.orders_import(lib) then
      p.imported[lib] = K.now().tick
      n = n + 1
    end
  end
  if n > 0 then K.act.orders('sort'); K.act.orders('recheck') end
  return n
end

-- dfllm-tagged supply orders (act strips the tag; ids are kept in persist to avoid duplicates)
local function supply(K, c, p, days, inv)
  local sup = K.plan.supply or {}
  local phase = (K.view() or {}).phase
  for _, e in ipairs(c.supply or {}) do
    if not e.from_phase or (type(phase) == 'string' and phase >= e.from_phase) then
      local jobs = 0
      if days[e.key] then
        local target, d = math.tointeger(sup[e.key]) or 0, days[e.key]
        if d < target then
          local units = (target - d) * (st.rate[e.key] or 0) // 1000
          jobs = (units + e.per_job - 1) // e.per_job
        end
      else
        local target, have = math.tointeger(sup.mood_stock) or 10, inv[e.key] or 0
        if have < target then jobs = (target - have + e.per_job - 1) // e.per_job end
      end
      jobs = math.min(jobs, e.max_jobs or 20)
      local now = K.now().tick
      if jobs > 0 and not live(p.orders[e.tag]) and now >= (st.backoff[e.tag] or 0) then
        local spec = copy(e.spec)
        spec.tag, spec.amount_total = e.tag, jobs
        local ok, id = K.act.workorder(spec)
        if ok then p.orders[e.tag] = id else st.backoff[e.tag] = now + 3 * DAY end   -- retry in 3 days
      end
    end
  end
end

-- Gordon's rule: plump helmets are never cooked (D-09 'yes' lifts it only during a famine)
local function kitchen(K, c, food_d)
  if decision(K, 'D-09') == 'yes' and food_d and food_d < (c.famine_days or 10) then return end
  for _, e in ipairs(c.kitchen or {}) do
    local mi = dfhack.matinfo.find(e.plant, e.mat)            -- as ban-cooking.lua:67
    local it = df.item_type[e.item]
    if mi and it and dfhack.kitchen.findExclusion({[e.what] = true}, it, -1, mi.type, mi.index) < 0 then
      K.act.kitchen_exclude(e.item, -1, mi.type, mi.index, e.what)    -- Lua API.txt:2648-2662
    end
  end
end

---------------------------------------------------------------- labor
-- labormanager status / monitor lines: "... N starving (> 1200 ticks ...)", "N starving postings (> ..."
function M.parse_starving(out)
  local s = tostring(out or '')
  local n = s:match('([0-9]+) starving') or s:match('starving=([0-9]+)')
  return n and math.tointeger(tonumber(n)) or nil
end

local function idle_pct(K)
  local cu = K.census.u
  if type(cu) ~= 'table' or type(cu.ids) ~= 'table' then return nil end
  local sold = {}
  for _, id in ipairs(cu.soldier_ids or {}) do sold[id] = true end
  local n, idle = 0, 0
  for _, id in ipairs(cu.ids) do
    local u = not sold[id] and df.unit.find(id)
    if u and not dfhack.units.isChild(u) and not dfhack.units.isBaby(u) then
      n = n + 1
      local j = u.job
      if j == nil or j.current_job == nil then idle = idle + 1 end
    end
  end
  return n > 0 and idle * 100 // n or 0
end

-- the useful backlog (D-03): never filler digging
local function backlog_pick(K, c, p, inv)
  local ic = c.idle
  for _, b in ipairs(ic.backlog or {}) do
    if b.id == 'blocks' then
      if (inv.boulders or 0) >= ic.boulders_min and (inv.blocks or 0) < ic.blocks_cap and not live(p.orders[b.tag]) then return b end
    elseif b.id == 'crafts' then
      if (inv.crafts or 0) < ic.crafts_cap and (inv.boulders or 0) >= 10 and not live(p.orders[b.tag]) then return b end
    elseif b.id == 'combine' then
      if p.last_combine == nil or K.now().tick - p.last_combine >= ic.combine_every then return b end
    end
  end
end

local function backlog_act(K, b, p)
  if b.id == 'combine' then
    local ok = K.act.run('combine', 'all', '-q')
    if ok then p.last_combine = K.now().tick end
    return ok
  end
  local spec = copy(b.spec)
  spec.tag, spec.amount_total = b.tag, b.amount
  local ok, id = K.act.workorder(spec)
  if ok then p.orders[b.tag] = id end
  return ok
end

local function idle_rule(K, c, p, inv)
  local rule = decision(K, 'D-03')
  if st.idle == nil then return end
  if st.idle > c.idle.pct then p.idle_days = (p.idle_days or 0) + 1 else p.idle_days = 0 end
  local need = rule == 'immediate' and 1 or c.idle.days
  if rule == 'off' or p.idle_days < need or K.mode() ~= 'PEACE' then return end
  local b = backlog_pick(K, c, p, inv)
  if not b then
    K.log('info', 'idle %d%% for %d days, useful backlog empty: no action', st.idle, p.idle_days)
    return
  end
  if backlog_act(K, b, p) then
    K.log('info', 'idle %d%% for %d days: backlog %s', st.idle, p.idle_days, b.id)
    p.idle_days = 0
  end
end

---------------------------------------------------------------- events
local function stock_low(K, p, key, value, min, as_days)
  local low = value < min
  if low and p.low[key] ~= 1 then
    p.low[key] = 1
    local d = {key = key, min = min}
    if as_days then d.days = value else d.n = value end
    K.emit('STOCK_LOW', 'B', string.format('%s %d < %d', key, value, min), d)
  elseif not low and p.low[key] == 1 and value * 100 >= min * 110 then
    p.low[key] = nil
  end
end

local function find_order_named(key)
  for _, o in ipairs(orders_all()) do
    local ok, name = pcall(function() return dfhack.job.getManagerOrderName(o) end)   -- Lua API.txt:1416
    name = ok and tostring(name or ''):lower() or ''
    if name ~= '' and (name:find(key, 1, true) or key:find(name, 1, true)) then return o.id end
  end
end

-- "<unit> cancels <job>: <reason>." (CANCEL_JOB report text)
function M.cancelled_job(text)
  local j = tostring(text or ''):match('cancels ([^:]+):')
  if not j then return nil end
  j = j:gsub('^[ ]+', ''):gsub('[ ]+$', '')
  return j ~= '' and j or nil
end

local function cancel(K, ev)
  local c = M.conf(K)
  local job = M.cancelled_job(ev.text)
  if not job then return end
  local day = (ev.tick or K.now().tick) // DAY
  if st.cday ~= day then st.cday, st.cancels, st.looped = day, {}, {} end
  local key = job:lower()
  st.cancels[key] = (st.cancels[key] or 0) + 1
  local n = st.cancels[key]
  if n < (c.cancel_loop or 5) or st.looped[key] then return end
  st.looped[key] = true
  local oid = find_order_named(key)
  K.emit('CANCEL_LOOP', 'B', string.format('%s cancelled %d times today', job, n), {order = oid or -1, job = job, n = n})
  if oid and st.can_suspend ~= false and not K.act.order_suspend(oid, true) then st.can_suspend = false end
  if st.rechecked ~= day then           -- orders.txt: recheck stops cancellation spam of stale conditions
    st.rechecked = day
    K.act.orders('recheck')
  end
end

M.on.REPORT = function(K, ev)
  if ev.type == 'CANCEL_JOB' then return cancel(K, ev) end
  if not st.mig then                    -- remember who was here; the census catches up later
    local known = {}
    for _, id in ipairs(K.census.u and K.census.u.ids or {}) do known[id] = true end
    st.mig = {tick = ev.tick or K.now().tick, known = known}
  end
end

---------------------------------------------------------------- the daily run
local function daily(K, c)
  local p = pstate(K)
  local now, inv = K.now(), K.census.i
  local cu = K.census.u
  local cit = (cu and math.tointeger(cu.cit)) or ((p.cit or 0) > 0 and p.cit) or 7
  p.cit = cit
  -- days of stock
  st.rate = {}
  local days = {}
  for key, stock in pairs({drink = inv.drink, food = inv.food}) do
    local base = (c.seed_milli[key] or 0) * cit
    push(p.hist[key], M.sample(p.prev[key], stock, base, c.spike_x or 3))
    p.prev[key] = stock
    local sum = 0
    for _, v in ipairs(p.hist[key]) do sum = sum + v end
    st.rate[key .. '_d'] = sum // #p.hist[key]
    days[key .. '_d'] = M.days(stock, p.hist[key])
  end
  local sup = K.plan.supply or {}
  stock_low(K, p, 'drink_d', days.drink_d, math.tointeger(sup.drink_d) or 170, true)
  stock_low(K, p, 'food_d', days.food_d, math.tointeger(sup.food_d) or 60, true)
  local phase = (K.view() or {}).phase
  if type(phase) == 'string' and phase >= (c.mood_from_phase or 'P3') then
    for _, key in ipairs(c.mood_keys or {}) do stock_low(K, p, key, inv[key] or 0, math.tointeger(sup.mood_stock) or 10) end
  end
  -- migrants (report seen; count the new citizens once the census caught up)
  if st.mig and now.tick - st.mig.tick >= 100 then
    local n = 0
    for _, id in ipairs(cu and cu.ids or {}) do if not st.mig.known[id] then n = n + 1 end end
    K.emit('MIGRANTS', 'B', string.format('%d migrants', n), {n = n})
    p.migrants, st.mig = 1, nil
  end
  pcall(kitchen, K, c, days.food_d)
  supply(K, c, p, days, inv)
  imports(K, c, p)
  -- labor KPIs; PEACE days feed baseline's labormanager A/B test
  local ok, out = K.act.run('labormanager', 'status')
  local starving = ok and M.parse_starving(out) or nil
  st.starving = starving or 0
  if starving and K.mode() == 'PEACE' and K.enabled('baseline') then K.call('baseline', 'labor_day', starving) end
  st.idle = idle_pct(K)
  idle_rule(K, c, p, inv)
  st.out = {drink_d = days.drink_d, food_d = days.food_d, meals = inv.meal_kinds,
            starving = st.starving, idle = st.idle or 0}
  K.persist.touch('m.economy')
end

---------------------------------------------------------------- module
function M.init(K)
  st = {census = nil, rate = {}, cancels = {}, looped = {}, backoff = {}}
  pstate(K)
  local ok, err = pcall(kitchen, K, M.conf(K), nil)
  if not ok then K.log('warn', 'kitchen exclusion: %s', tostring(err)) end
end

function M.step(K, budget, ctx)
  local c = M.conf(K)
  if not (ctx and ctx.cont) or not st.census then
    st.census = {acc = new_acc(c), ci = 1, idx = 0, errs = 0}
    mcache, bolt_sub = {}, {}
  end
  if not census_slice(c) then return 'more' end
  local cs = st.census
  st.census = nil
  if cs.errs > 0 then K.log('warn', 'census: %d unreadable items (%s)', cs.errs, cs.err) end
  publish(K, c, cs.acc)
  daily(K, c)
end

-- WP8-internal (baseline, right after its seedwatch task): re-add a cook exclusion seedwatch dropped
function M.kitchen_check(K)
  local ok, err = pcall(kitchen, K, M.conf(K), st.out and st.out.food_d)
  if not ok then K.log('warn', 'kitchen exclusion: %s', tostring(err)) end
  return ok
end

-- CONTRACTS §7: orders library already imported
function M.imported(K, lib)
  local p = K.persist.get('m.economy')
  return type(p) == 'table' and type(p.imported) == 'table' and p.imported[lib] ~= nil
end

function M.state(K)
  local o = st.out
  if not o then return {} end
  return {stock = {drink_d = o.drink_d, food_d = o.food_d, meals = o.meals},
          labor = {starving = o.starving, idle = math.max(0, math.min(100, o.idle))}}
end

return M
