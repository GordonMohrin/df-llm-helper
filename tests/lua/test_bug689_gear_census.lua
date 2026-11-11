-- BUG-689 (Run 16d i4 Trumpetrealms y447-y456: 'gear: body 28/10 ok' beside 24 pieces made by another race and 'metal 0 %' with 32 bars; Run 16a
-- i1 Basementflew: every slot 'ok', 'metal: no ore, 3 bars; 0 forge jobs'): the gear count took every piece a soldier holds or nobody owns, wearable
-- or not, and a leather piece for a piece, so a fort whose soldiers wore leather or loot never forged the metal set while the bars lay there.
--   * economy.wearable: a piece made by another race (armor is sized for its maker) or on another walk group is no piece of the fort's gear
--   * economy.gear_metal_topup: the bars left after the slots' own needs make metal pieces for the armor slots that hold fewer metal pieces than
--     soldiers (one order a slot, never while the slot's order is open, needs a forge and bars of gear.metals)
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

F.ITEM_TYPES[#F.ITEM_TYPES + 1] = 'QUIVER'

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local METALS = {[50] = 'COPPER', [51] = 'IRON', [53] = 'BRONZE', [54] = 'BISMUTH_BRONZE'}

local function world(o)
  o = o or {}
  local units, ids = {}, {}
  for i = 1, 10 do units[i] = {id = i, citizen = true}; ids[i] = i end
  local cfg = F.cfg()
  cfg.economy.orders_per_day = 20
  local W = F.world{cfg = {baseline = cfg}, units = units}
  for i = 1, 10 do W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  for i, name in pairs(METALS) do F.mat(W, 0, i, {token = 'INORGANIC:' .. name, flags = {IS_METAL = true}}) end
  F.mat(W, 19, 5, {token = 'CREATURE:COW:LEATHER', flags = {LEATHER = true}})
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
  df.global.plotinfo.race_id = 1
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
  if o.forge ~= false then F.workshop(W, 'MetalsmithsForge') end
  for _ = 1, 40 do F.item(W, 'BAR', {mat_type = 7}) end                     -- fuel
  for _ = 1, (o.bars or 12) do F.item(W, 'BAR', {mat_type = 0, mat_index = 51}) end     -- iron bars
  if o.setup then o.setup(W) end
  W.load(fresh('economy'))
  return W
end

local function gear_orders(W, tag)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == tag then r[#r + 1] = a.args[1] end end
  return r
end
local function leather_armor(W, n)
  for _ = 1, n do F.item(W, 'ARMOR', {mat_type = 19, mat_index = 5}) end
end

T.test('BUG-689: leather armor for every soldier and iron bars in the fort: the metal body order is placed (before: gear ok, nothing forged)',
       function()
  local W = world{bars = 40, setup = function(W) leather_armor(W, 4) end}   -- (the slots' own needs first: 14 bars)
  days(W, 1)
  local o = gear_orders(W, 'dfllm:gear_body')
  T.ok(#o >= 1, 'a body order was placed')
  T.eq(o[1].material, 'INORGANIC:IRON', 'in iron')
  T.eq(o[1].job, 'MakeArmor')
  local sup = W.K.persist.get('m.economy')
  local gr = sup and sup.gear
  T.ok(gr == nil or gr.cats == nil or (gr.cats.body and gr.cats.body.have == 4), 'the 4 leather pieces count as pieces')
  local told = false
  for _, l in ipairs(W.logs) do if l.module == 'economy' and tostring(l.msg):find('slots hold a metal piece', 1, true) then told = true end end
  T.ok(told, 'kern.log says why')
end)

T.test('BUG-689: the top-up never runs without a forge, without bars, or when the metal pieces cover the soldiers', function()
  local W = world{forge = false, setup = function(W) leather_armor(W, 4) end}
  days(W, 2)
  T.eq(#gear_orders(W, 'dfllm:gear_body'), 0, 'no forge: no metal order, leather covers the slot')
  W = world{bars = 0, setup = function(W) leather_armor(W, 4) end}
  days(W, 2)
  T.eq(#gear_orders(W, 'dfllm:gear_body'), 0, 'no bars: nothing to forge')
  W = world{bars = 40, setup = function(W)
    for _ = 1, 2 do F.item(W, 'ARMOR', {mat_type = 0, mat_index = 51}) end          -- two iron breastplates for the 2 soldiers
  end}
  days(W, 2)
  T.eq(#gear_orders(W, 'dfllm:gear_body'), 0, 'two metal pieces for two soldiers: no top-up')
end)

T.test('BUG-689: armor made by another race is no piece of the fort\'s gear: the slot is missing it and the forge makes one', function()
  local W = world{bars = 40, setup = function(W)
    for _ = 1, 4 do F.item(W, 'ARMOR', {mat_type = 0, mat_index = 51, maker_race = 7}) end   -- goblin loot: iron, sized for goblins
  end}
  days(W, 1)
  T.ok(#gear_orders(W, 'dfllm:gear_body') >= 1, 'four goblin breastplates do not cover two dwarves: a body order')
  local W2 = world{bars = 40, setup = function(W)
    for _ = 1, 2 do F.item(W, 'ARMOR', {mat_type = 0, mat_index = 51, maker_race = 1}) end   -- the fortress race
  end}
  days(W2, 2)
  T.eq(#gear_orders(W2, 'dfllm:gear_body'), 0, 'dwarf-made pieces count')
  local E = W2.mods.economy and W2.mods.economy.M or require('dfllm.economy')
  T.eq(E.wearable({}, {flags = {in_inventory = true}, maker_race = 7}), true, 'a piece a soldier wears always counts')
  T.eq(E.wearable({}, {flags = {}, maker_race = 7}), false)
  T.eq(E.wearable({}, {flags = {}, maker_race = -1}), true, 'no maker: counts')
  T.eq(E.wearable({far = function() return true end}, {flags = {}, maker_race = 1}), false, 'another walk group')
  -- BUG-743: a piece military wrote off (released twice and still lying, or reserved out of its soldiers' reach) is no gear either
  T.eq(E.wearable({stuck = {[77] = true}}, {id = 77, flags = {}, maker_race = 1}), false, 'stuck: counted missing, a fresh one is ordered')
  T.eq(E.wearable({stuck = {[77] = true}}, {id = 78, flags = {}, maker_race = 1}), true, 'another piece')
  T.eq(E.wearable({stuck = {[77] = true}}, {id = 77, flags = {in_inventory = true}}), true, 'worn: always counts')
end)

T.done()
