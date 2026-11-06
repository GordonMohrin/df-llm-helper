-- BUG-525 (Run 16c i3 Sealcertain y395-y397: 'body 0/5+1 ordered, head 0/5+2 ordered' for years, 37 x 'cancels Forge bismuth bronze
-- breastplate: Needs 3 bismuth bronze bars' while iron bars lay in the stores): the open gear order keeps the metal it was entered in,
-- plan_gear saw 'ordered' and never looked at the bars again. When the bars of that metal are gone and another metal of gear.metals
-- has them, the order is removed and the slot is planned again in the same pass (iron first).
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

F.ITEM_TYPES[#F.ITEM_TYPES + 1] = 'QUIVER'

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local METALS = {[50] = 'COPPER', [51] = 'IRON', [53] = 'BRONZE', [54] = 'BISMUTH_BRONZE'}

local function world()
  local units, ids = {}, {}
  for i = 1, 10 do units[i] = {id = i, citizen = true}; ids[i] = i end
  local cfg = F.cfg()
  cfg.economy.orders_per_day = 20
  local W = F.world{cfg = {baseline = cfg}, units = units}
  for i = 1, 10 do W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  for i, name in pairs(METALS) do F.mat(W, 0, i, {token = 'INORGANIC:' .. name, flags = {IS_METAL = true}}) end
  local decode = dfhack.matinfo.decode
  dfhack.matinfo.decode = function(t, i)
    if type(t) == 'table' then t, i = t.mat_type, t.mat_index end
    local m = decode(t, i)
    if m and t == 0 then
      m.inorganic = {metal_ore = {mat_index = kmock.vec{}}}
      m.material.reaction_class = kmock.vec{}
    end
    return m
  end
  W.subdefs[1] = {id = 'ITEM_WEAPON_PICK', skill_melee = df.job_skill.MINING, skill_ranged = -1}
  W.subdefs[2] = {id = 'ITEM_WEAPON_AXE_BATTLE', skill_melee = df.job_skill.AXE, skill_ranged = -1}
  W.subdefs[3] = {id = 'ITEM_WEAPON_CROSSBOW', skill_melee = df.job_skill.CROSSBOW, skill_ranged = df.job_skill.CROSSBOW}
  W.subdefs[4] = {id = 'ITEM_AMMO_BOLTS'}
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P5'} end})
  W.load({name = 'military', every = {ticks = 3600},
          targets = function() return 2, {A = 2} end, kpi = function() return {worn = 15, slots = 20, specs = 20} end})
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  F.workshop(W, 'MetalsmithsForge')
  for _ = 1, 10 do F.item(W, 'BAR', {mat_type = 7}) end                     -- fuel
  for _ = 1, 3 do F.item(W, 'BAR', {mat_type = 0, mat_index = 54}) end      -- bismuth bronze: one breastplate
  W.load(fresh('economy'))
  return W
end

local function gear_orders(W, tag)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == tag then r[#r + 1] = a.args[1] end end
  return r
end
local function bars_gone(W, mat_index)
  local v = df.global.world.items.other.BAR
  for i = #v - 1, 0, -1 do if v[i].mat_type == 0 and v[i].mat_index == mat_index then v:erase(i) end end
end

T.test('BUG-525: a gear order in a metal whose bars are gone is replaced by one in the metal the fort has', function()
  local W = world()
  days(W, 1)
  local first = gear_orders(W, 'dfllm:gear_body')
  T.eq(#first >= 1 and first[1].material, 'INORGANIC:BISMUTH_BRONZE', 'the only bars are bismuth bronze: that order is right')
  -- the order stands in the manager list with its material; the bars are used up, iron arrives
  local oid
  for _, o in ipairs(df.global.world.manager_orders.all) do
    if o._spec and o._spec.tag == 'dfllm:gear_body' then o.mat_type, o.mat_index, oid = 0, 54, o.id end
  end
  T.ok(oid, 'the gear order stands')
  bars_gone(W, 54)
  for _ = 1, 10 do F.item(W, 'BAR', {mat_type = 0, mat_index = 51}) end
  days(W, 1)
  local gone = false
  for _, a in ipairs(W.find_acts('order_remove')) do if a.args[1] == oid then gone = true end end
  T.ok(gone, 'the bismuth bronze order was removed')
  local after = gear_orders(W, 'dfllm:gear_body')
  T.eq(after[#after].material, 'INORGANIC:IRON', 'and entered again in iron')
  local warned = false
  for _, l in ipairs(W.logs) do
    if l.module == 'economy' and tostring(l.msg):find('gear body: order', 1, true) then warned = true end
  end
  T.ok(warned, 'kern.log says why')
end)

T.test('BUG-525: an order whose bars are still there, or with no other metal at hand, is left alone', function()
  local W = world()
  days(W, 1)
  local oid
  for _, o in ipairs(df.global.world.manager_orders.all) do
    if o._spec and o._spec.tag == 'dfllm:gear_body' then o.mat_type, o.mat_index, oid = 0, 54, o.id end
  end
  days(W, 1)                                     -- the bismuth bars are still in the stores
  for _, a in ipairs(W.find_acts('order_remove')) do T.ok(a.args[1] ~= oid, 'removed an order that can run') end
  bars_gone(W, 54)                               -- no bars of any metal: nothing better to plan
  days(W, 1)
  for _, a in ipairs(W.find_acts('order_remove')) do T.ok(a.args[1] ~= oid, 'removed an order with no replacement') end
end)

T.done()
