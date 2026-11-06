-- BUG-556 (Run 16c i3 Sealcertain y395-y401: a metal gear order that made nothing for days, a manual leather order.add raised worn
-- 11 -> 87 %): an open metal order of a slot that made no piece for gear.stale_days (12) days gives way to leather when leather and a
-- Leatherworks are at hand; the slot then plans leather first for gear.leather_days (30).
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
  for _ = 1, 12 do F.item(W, 'BAR', {mat_type = 0, mat_index = 51}) end     -- iron bars
  F.workshop(W, 'Leatherworks')
  for _ = 1, 12 do F.item(W, 'SKIN_TANNED', {}) end
  W.load(fresh('economy'))
  return W
end


local function gear_orders(W, tag)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == tag then r[#r + 1] = a.args[1] end end
  return r
end
local function body_oid()
  for _, o in ipairs(df.global.world.manager_orders.all) do
    if o._spec and o._spec.tag == 'dfllm:gear_body' then o.mat_type, o.mat_index = 0, 51; return o.id end   -- the order stands in iron
  end
end
local function removed(W, oid)
  for _, a in ipairs(W.find_acts('order_remove')) do if a.args[1] == oid then return true end end
  return false
end

T.test('BUG-556: a metal body order that made nothing for 12 days is replaced by a leather one; before that it stands', function()
  local W = world()
  days(W, 1)
  local first = gear_orders(W, 'dfllm:gear_body')
  T.eq(#first >= 1 and first[1].material, 'INORGANIC:IRON', 'iron bars at hand: the metal order comes first')
  local oid = body_oid()
  T.ok(oid, 'the order stands')
  days(W, 8)
  T.eq(removed(W, oid), false, 'not stale yet')
  days(W, 6)
  T.eq(removed(W, oid), true, 'the metal order made nothing in 12 days: removed')
  local after = gear_orders(W, 'dfllm:gear_body')
  local last = after[#after]
  T.ok(last.material_category and last.material_category[1] == 'leather', 'and entered again in leather')
  local warned = false
  for _, l in ipairs(W.logs) do
    if l.module == 'economy' and tostring(l.msg):find('gear body: metal order', 1, true) then warned = true end
  end
  T.ok(warned, 'kern.log says why')
end)

T.test('BUG-556: no Leatherworks or no leather: the metal order stays', function()
  local W = world()
  days(W, 1)
  local oid = body_oid()
  local v = df.global.world.items.other.SKIN_TANNED
  for i = #v - 1, 0, -1 do v:erase(i) end
  days(W, 20)
  T.eq(removed(W, oid), false, 'no leather: nothing better')
end)

T.done()
