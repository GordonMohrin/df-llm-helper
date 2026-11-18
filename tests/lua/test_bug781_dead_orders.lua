-- BUG-781 (Run 16b i2 Whirledrampart y451: '60 Orders stuck no rock / no bars STEEL' for 24-43 days): orders stuck on an input the fort cannot
-- get at all (no iron bars and no iron ore, no usable rock) are removed after orders.dead_days, reported once per material; orders whose
-- material exists, tagged (kernel-owned keep) orders and orders stuck for other reasons stay.
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
local IRON, COPPER = 7, 8

local function world(setup)
  local cfg = F.cfg()
  local units, ids = {}, {}
  for i = 1, 8 do units[i] = {id = i, citizen = true}; ids[i] = i end
  local W = F.world{cfg = {baseline = cfg}, units = units}
  add_jobs({'MakeAmmo', 'MakeWeapon'})
  df.workquota_frequency_type = {OneTime = ONE, Daily = 1, [0] = 'OneTime', [1] = 'Daily'}
  df.unit_labor = {FORGE_WEAPON = 1, [1] = 'FORGE_WEAPON'}
  for i = 1, 8 do
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors = {[1] = true}
    u.mood = -1
  end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          pending = function() return 0 end, req_types = function() return nil end, state = function() return {phase = 'P3'} end})
  W.load({name = 'care', every = {ticks = 1200}, state = function()
    return {care = {stressed_pct = 0, naked = 0, ghosts = 0, corpses_old = 0, tombs_free = 0, moods = 0}}
  end})
  F.mat(W, 0, IRON, {token = 'INORGANIC:IRON', flags = {IS_METAL = true}})
  F.mat(W, 0, COPPER, {token = 'INORGANIC:COPPER', flags = {IS_METAL = true}})
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  F.workshop(W, 'MetalsmithsForge')
  W.act_result('order_remove', function(id)
    local all = df.global.world.manager_orders.all
    for i = #all - 1, 0, -1 do if all[i].id == id then all:erase(i); return true, 'removed' end end
    return false, 'no order'
  end)
  if setup then setup(W) end
  W.load(fresh('economy'))
  return W
end

local function order(W, job, mat, extra)
  local o = {job_type = df.job_type[job], mat_type = 0, mat_index = mat, item_subtype = 3, amount_left = 1,
             frequency = ONE, status = {validated = true}, item_conditions = kmock.vec{}, material_category = {},
             reaction_name = ''}
  for k, v in pairs(extra or {}) do o[k] = v end
  return F.order(W, o)
end
local function has(id)
  for _, o in ipairs(df.global.world.manager_orders.all) do if o.id == id then return true end end
  return false
end

T.test('BUG-781: orders for iron bars with no iron bar and no iron ore are removed after dead_days, one report; copper (a bar stands) stays', function()
  local o = {}
  local W = world(function(W)
    for i = 1, 3 do o[i] = order(W, 'MakeAmmo', IRON, {item_subtype = 10 + i}) end      -- no iron anywhere
    o[4] = order(W, 'MakeWeapon', IRON, {frequency = 1, item_subtype = 4})              -- standing order of the same dead material
    o[5] = order(W, 'MakeWeapon', COPPER, {item_subtype = 6})                           -- copper bars exist
    F.item(W, 'BAR', {mat_type = 0, mat_index = COPPER})
  end)
  days(W, 8)
  T.eq({has(o[1].id), has(o[2].id), has(o[3].id), has(o[4].id), has(o[5].id)}, {true, true, true, true, true}, 'before dead_days: all stay')
  days(W, 12)
  T.eq({has(o[1].id), has(o[2].id), has(o[3].id), has(o[4].id)}, {false, false, false, false}, 'dead material: removed, standing one too')
  T.ok(has(o[5].id), 'copper order stays (a copper bar exists)')
  local n, ev = 0, nil
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do if e.d.kind == 'dead_material' then n = n + 1; ev = e end end
  T.eq(n, 1, 'one ORDER_STUCK kind dead_material for the material')
  T.ok(ev.msg:find('bars:INORGANIC:IRON', 1, true), ev.msg)
  T.ok(ev.msg:find('trade.want', 1, true), ev.msg)
end)

T.test('BUG-781: M.mat_dead: no usable rock is dead, an alloy (bronze) and steel without plan_steel facts are never judged', function()
  local W = world()
  local E = require('dfllm.economy')
  local r = {inv = {}, now = 0}
  local dead, why = E.mat_dead({}, r, 'rock')
  T.eq(dead, true, 'rock: nothing usable')
  T.ok(why:find('no usable rock', 1, true), why)
  T.eq((E.mat_dead({}, r, 'bars:INORGANIC:BRONZE')), false, 'alloys are not judged')
  T.eq((E.mat_dead({}, r, 'bars:INORGANIC:STEEL')), false, 'steel: no missing-input facts, not judged')
  T.eq((E.mat_dead({}, r, 'wood')), false, 'other keys never')
  local d, w = E.mat_dead({}, r, 'bars:INORGANIC:IRON')
  T.eq(d, true, 'iron: no bars, no ore')
  T.ok(w:find('no iron', 1, true), w)
end)

T.test('BUG-781: the config keys exist (dead_days 14, dead_backoff_days 30)', function()
  local c = require('dfllm.economy').DEFAULTS.orders
  T.eq({c.dead_days, c.dead_backoff_days, c.dead_report_days}, {14, 30, 30})
end)

T.done()
