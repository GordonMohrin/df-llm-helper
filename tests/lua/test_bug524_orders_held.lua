-- BUG-524 (Run 16c i3 Sealcertain: phase P3 'waits for orders_rockstock' for 8+ years, no word of why): the plan's library/rockstock is
-- held by the config stage (Masons + 60 free furniture-grade boulders) and the phase deliverable `orders` only checks 'imported'.
-- economy.held_why names what the stage lacks; the runner's status line (phw.wait) carries it ('orders_rockstock stone 3/60').
local T = require('testlib')
local F = require('wp8_world')
local OL = require('dfllm.orderlib')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

-- job types the fakes of wp8_world do not name: appended so the existing indices stay
local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end
local JOBS = {'MakeArmor', 'MakePants', 'MakeShoes', 'MakeGloves', 'MakeHelm', 'MakeWeapon', 'MakeAmmo', 'MakeShield',
              'BrewDrink', 'ConstructBuilding', 'MakeBarrel', 'Rest'}

local function world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, opts.cit or 6 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, mode = opts.mode}
  add_jobs(JOBS)
  df.unit_labor = {MASON = 1, CARPENTER = 2, BREWER = 3, COOK = 4, FORGE_ARMOR = 5, CLOTHESMAKER = 6, [1] = 'MASON',
                   [2] = 'CARPENTER', [3] = 'BREWER', [4] = 'COOK', [5] = 'FORGE_ARMOR', [6] = 'CLOTHESMAKER'}
  local ids = {}
  for i = 1, opts.cit or 6 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors = {[1] = opts.masons ~= false, [2] = true, [3] = true, [4] = true}
    u.mood = -1
  end
  W.set_census('u', F.census_u(ids))
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 500})
  F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  -- the real workorder tool stores the item def index (0 here) when the spec names one, -1 otherwise
  W.act_result('workorder', function(spec)
    local mo = df.global.world.manager_orders
    local id = mo.manager_order_next_id
    mo.manager_order_next_id = id + 1
    mo.all:insert('#', {id = id, job_type = df.job_type[spec.job], reaction_name = spec.reaction or '',
                        amount_left = spec.amount_total, amount_total = spec.amount_total, _spec = spec,
                        item_subtype = spec.item_subtype and 0 or -1, mat_type = -1, mat_index = -1,
                        status = {validated = false}})
    return true, id
  end)
  W.act_result('order_remove', function(id)
    local all = df.global.world.manager_orders.all
    for i = #all - 1, 0, -1 do if all[i].id == id then all:erase(i); return true, 'removed' end end
    return false, 'no order'
  end)
  if opts.setup then opts.setup(W) end
  local E = fresh('economy')
  W.load(E)
  return W, E
end

local function settle(W) for _ = 1, 60 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end
local function ids_of(W)
  local r = {}
  for _, o in ipairs(df.global.world.manager_orders.all) do r[#r + 1] = o.id end
  return r
end


T.test('BUG-524: economy.held_why names the missing workshop and the stone of the rockstock stage', function()
  local W = world{}
  settle(W)
  local ok, why = W.K.call('economy', 'held_why', 'library/rockstock')
  T.ok(ok, 'the function answers')
  T.eq(why, 'no Masons,stone 0/60')
  F.workshop(W, 'Masons')
  for _ = 1, 7 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 1}) end
  days(W, 1)
  local _, again = W.K.call('economy', 'held_why', 'library/rockstock')
  T.eq(again, 'stone 7/60', 'the workshop stands, the stone is short')
  T.eq(select(2, W.K.call('economy', 'held_why', 'library/nothing')), nil, 'a library without a stage is not held')
end)

T.test('BUG-524: a library that is imported is not held', function()
  local W = world{}
  settle(W)
  local p = W.K.persist.get('m.economy')
  p.imported['library/rockstock'] = 5
  T.eq(select(2, W.K.call('economy', 'held_why', 'library/rockstock')), nil)
end)

T.done()
