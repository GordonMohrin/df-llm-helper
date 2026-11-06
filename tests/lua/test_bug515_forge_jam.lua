-- BUG-515 (Run 16c i3 Sealcertain y385-y386: 'JAM forges slots full of cancelling jobs (MakeWeapon x3: no bars:INORGANIC:BRONZE)'; the
-- hospital well's chain (order 576, 7 bismuth bronze bars) waited 99 days behind the bronze weapons that never had bars; the prune
-- (BUG-315) only took duplicates and orders above the cap). The orders whose jobs fill a jammed shop's slots and cannot run
-- (economy.jam_scan -> oq.jamc) are removed by order_prune: one-time orders only, the keep rules of the prune unchanged. The well's
-- chain order (water.chain) is entered first in the work orders (spec.top; asserted in test_bug262_266_water.lua).
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 60 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end
local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

local ONE = 0
local BRONZE = 7

local function world(setup)
  local cfg = F.cfg()
  cfg.economy.slabs = {max_orders = 3, restock_cap = 5, drop_per_day = 0, trigger_ticks = 600, scan_max = 2000, jam_min = 3}
  local units, ids = {}, {}
  for i = 1, 8 do units[i] = {id = i, citizen = true}; ids[i] = i end
  local W = F.world{cfg = {baseline = cfg}, units = units}
  add_jobs({'MakeWeapon', 'MakeChain', 'MakeArmor'})
  df.workquota_frequency_type = {OneTime = ONE, Daily = 1, [0] = 'OneTime', [1] = 'Daily'}
  df.unit_labor = {FORGE_WEAPON = 1, FORGE_ARMOR = 2, FORGE_FURNITURE = 3, [1] = 'FORGE_WEAPON', [2] = 'FORGE_ARMOR',
                   [3] = 'FORGE_FURNITURE'}
  for i = 1, 8 do
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors = {[1] = true, [2] = true, [3] = true}
    u.mood = -1
  end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          pending = function() return 0 end, req_types = function() return nil end, state = function() return {phase = 'P3'} end})
  W.load({name = 'care', every = {ticks = 1200}, state = function()
    return {care = {stressed_pct = 0, naked = 0, ghosts = 0, corpses_old = 0, tombs_free = 0, moods = 0}}
  end})
  F.mat(W, 0, BRONZE, {token = 'INORGANIC:BRONZE', flags = {IS_METAL = true}})
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  local forge = F.workshop(W, 'MetalsmithsForge')
  W.act_result('order_remove', function(id)
    local all = df.global.world.manager_orders.all
    for i = #all - 1, 0, -1 do if all[i].id == id then all:erase(i); return true, 'removed' end end
    return false, 'no order'
  end)
  if setup then setup(W, forge) end
  W.load(fresh('economy'))
  return W, forge
end

local function order(W, job, extra)
  local o = {job_type = df.job_type[job], mat_type = 0, mat_index = BRONZE, item_subtype = 3, amount_left = 1,
             frequency = ONE, status = {validated = true}, item_conditions = kmock.vec{}, material_category = {},
             reaction_name = ''}
  for k, v in pairs(extra or {}) do o[k] = v end
  return F.order(W, o)
end
local function open_ids()
  local r = {}
  for _, o in ipairs(df.global.world.manager_orders.all) do r[#r + 1] = o.id end
  return r
end

local function has(id)
  for _, o in ipairs(df.global.world.manager_orders.all) do if o.id == id then return true end end
  return false
end

T.test('BUG-515: bronze weapon orders that fill the forge (no bars) are removed after stuck_days, a standing one stays, ' ..
       'the chain order (MakeChain) never goes', function()
  local o = {}
  local W, forge = world(function(W, forge)
    for i = 1, 3 do o[i] = order(W, 'MakeWeapon', {item_subtype = 10 + i}) end   -- the culprits (one-time, no duplicates)
    o[4] = order(W, 'MakeWeapon', {frequency = 1, item_subtype = 4})  -- a standing order of the same kind
    o[5] = order(W, 'MakeChain', {mat_index = BRONZE})              -- the well's chain, a victim
    o[6] = order(W, 'MakeArmor', {item_subtype = 5})                -- a victim
  end)
  local jobs = {}
  for i = 1, 4 do jobs[i] = {job_type = df.job_type.MakeWeapon, order_id = o[i].id, flags = {working = false}} end
  forge.jobs = kmock.vec(jobs)
  days(W, 5)
  T.eq({has(o[1].id), has(o[2].id), has(o[3].id)}, {false, false, false}, 'old code: all stay (nothing removes the culprits)')
  T.eq({has(o[4].id), has(o[5].id), has(o[6].id)}, {true, true, true}, 'the standing order and the victims stay')
  local jamev
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do if e.d.kind == 'prune' then jamev = e end end
  T.ok(jamev, 'one ORDER_STUCK kind prune')
  T.eq({jamev.d.dropped, jamev.d.n}, {1, 3})
  T.ok(jamev.msg:find('jam: MetalsmithsForge 3', 1, true), jamev.msg)
end)

T.test('BUG-515: no jam, no removal: three stuck bronze weapon orders alone (the forge holds other jobs) stay', function()
  local o = {}
  local W, forge = world(function(W)
    for i = 1, 3 do o[i] = order(W, 'MakeWeapon', {item_subtype = 10 + i}) end
  end)
  forge.jobs = kmock.vec{}
  days(W, 5)
  T.eq({has(o[1].id), has(o[2].id), has(o[3].id)}, {true, true, true})
end)

T.done()
