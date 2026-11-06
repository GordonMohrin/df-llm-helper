-- BUG-526 (Run 16c i3 Sealcertain: 36 stuck orders and a jammed forge, the player had no verb to take an order off the list): the verb
-- orders.cancel removes one manager order by id, or with stuck=true the orders the kernel's ledger calls stuck; the supply orders
-- (brewing, meals, barrels, raw fish) need force=true; a kernel-owned order is not entered again for backoff_days.
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


local function has(W, id)
  for _, o in ipairs(df.global.world.manager_orders.all) do if o.id == id then return true end end
  return false
end
local function persist(W) return require('dfllm.util.json').decode(W.persist_raw['dfllm.m.economy']) end

T.test('BUG-526: orders.cancel id removes that order through act.order_remove and says so', function()
  local o
  local W = world{setup = function(W)
    o = F.order(W, {job_type = df.job_type.MakeHelm, amount_left = 3, item_subtype = 2, mat_type = 0, mat_index = 5,
                    status = {validated = true}})
  end}
  settle(W)
  local r = W.inbox('orders.cancel', {id = o.id})
  T.ok(r.ok, r.msg)
  T.ok(r.msg:find('1 order removed', 1, true), r.msg)
  T.eq(r.data.removed, 1)
  T.ok(not has(W, o.id), 'the order is gone')
  local bad = W.inbox('orders.cancel', {id = o.id})
  T.ok(not bad.ok and bad.msg:find('no order', 1, true), bad.msg)
end)

T.test('BUG-526: orders.cancel wants exactly one of id and stuck', function()
  local W = world{}
  settle(W)
  T.ok(not W.inbox('orders.cancel', {}).ok)
  T.ok(not W.inbox('orders.cancel', {id = 3, stuck = true}).ok)
  T.ok(not W.inbox('orders.cancel', {id = 'x'}).ok)
  local none = W.inbox('orders.cancel', {stuck = true})
  T.ok(none.ok and none.data.removed == 0, 'no order is stuck: nothing to do')
end)

T.test('BUG-526: a supply order (brewing) is refused without force', function()
  local brew
  local W = world{setup = function(W)
    brew = F.order(W, {job_type = df.job_type.BrewDrink, amount_left = 5, status = {validated = true}})
  end}
  settle(W)
  local r = W.inbox('orders.cancel', {id = brew.id})
  T.ok(not r.ok and r.msg:find('force=true', 1, true), r.msg)
  T.ok(has(W, brew.id))
  local f = W.inbox('orders.cancel', {id = brew.id, force = true})
  T.ok(f.ok, f.msg)
  T.ok(not has(W, brew.id))
end)

T.test('BUG-526: stuck=true removes the orders the ledger calls stuck, not the others', function()
  local stuck, fine
  local W = world{masons = false, setup = function(W)
    stuck = F.order(W, {job_type = df.job_type.ConstructTable, mat_type = 0, mat_index = -1, amount_left = 4,
                        material_category = {}, _name = 'Construct rock table'})
    fine = F.order(W, {job_type = df.job_type.ConstructDoor, mat_type = -1, mat_index = -1, amount_left = 2,
                       material_category = {wood = true}, _name = 'Construct wooden door'})
    F.workshop(W, 'Carpenters')
    for _ = 1, 5 do F.item(W, 'WOOD', {}) end
  end}
  days(W, 4)
  T.eq(W.state().orders.stuck, 1, 'the table order is stuck')
  local r = W.inbox('orders.cancel', {stuck = true})
  T.ok(r.ok, r.msg)
  T.eq(r.data.removed, 1)
  T.ok(not has(W, stuck.id) and has(W, fine.id), 'only the stuck one went')
  T.eq(persist(W).ostuck[tostring(stuck.id)], nil, 'its stuck record is gone')
end)

T.test('BUG-526: a kernel-owned order is not entered again at once', function()
  local W = world{}
  settle(W)
  local ok, id = W.K.act.workorder({job = 'MakeBarrel', amount_total = 2, tag = 'dfllm:cancel_probe', frequency = 'OneTime'})
  T.ok(ok)
  local p = W.K.persist.get('m.economy')
  p.orders['dfllm:cancel_probe'] = id
  local r = W.inbox('orders.cancel', {id = id, force = true})
  T.ok(r.ok, r.msg)
  T.eq(W.K.persist.get('m.economy').orders['dfllm:cancel_probe'], nil, 'the tag is free')
end)

T.done()
