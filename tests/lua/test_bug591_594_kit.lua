-- BUG-591..594 (round 38, Run 16c i3 Sealcertain y422 summer 61 -> 1, Run 16b i2 Brotherarrow, Run 16d i4 Trumpetrealms, military side):
--   591: free armor and weapons that the squads do not pick up (the stock counts clothes as armor, a weapon spec nothing fills stays for
--        ever, a slot the spec's material class does not fit stays empty, the text names no cause) and `inspect what=military`
--   592: the manager is taken out of his squad
--   593 (siege.lua: tests/lua/test_siege.lua): SIEGE_END names the soldiers that stood down
--   594 (economy.lua: tests/lua/test_economy_supply.lua): loose forbidden food after a fight
local T = require('testlib')
local X = require('wp6_world')
local KIT = require('dfllm.kit')
local vec = require('dfllm.util.k_mock').vec

local function boot(n, opts)
  opts = opts or {}
  opts.n = n or 50
  local W = X.world(opts)
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  return W
end
local function mil() return X.mod('military') end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return true end end
  return false
end
local function wspecs(s)
  local r = {}
  for i = 0, 9 do
    local p = s.positions[i]
    if p.occupant >= 0 then
      local w = p.equipment.uniform.weapon
      r[#r + 1] = #w > 0 and (w[0].subtype or 'choice') or 'none'
    end
  end
  return r
end
local function count(list, v) local n = 0; for _, x in ipairs(list) do if x == v then n = n + 1 end end return n end

---------------------------------------------------------------- 591: weapons
T.test('BUG-591: a weapon spec more positions claim than the fort holds weapons of is re-planned to the spare weapons of another kind ' ..
       '(guarded: explicit subtype)', function()
  local W = boot()
  local A = X.squad_of(W, 'A')
  W.set_census('i', {tick = 0, w_axe = 0, w_pick = 0})              -- the tools stay with the workers: guarded
  X.set_uniform(A, {positions = {0, 1, 2}, items = {{cat = 'weapon', type = 'WEAPON', subtype = 'ITEM_WEAPON_SPEAR'}}})
  X.weapon(W, 'ITEM_WEAPON_SPEAR')
  X.weapon(W, 'ITEM_WEAPON_SWORD_SHORT')
  X.weapon(W, 'ITEM_WEAPON_SWORD_SHORT')
  T.eq(wspecs(A), {'ITEM_WEAPON_SPEAR', 'ITEM_WEAPON_SPEAR', 'ITEM_WEAPON_SPEAR'}, 'three spear specs, one spear')
  W.run(3600 * 2, {skip = 9})
  local w = wspecs(A)
  T.eq({count(w, 'ITEM_WEAPON_SPEAR'), count(w, 'ITEM_WEAPON_SWORD_SHORT')}, {1, 2},
       'one spear spec stays, the two others go to the two swords (old code: three spear specs for ever)')
  T.ok(logged(W, 'squad A: 2 positions hold a weapon spec no free weapon fills'), 'kern.log says so')
end)

T.test('BUG-591: the same with the tools plentiful (unguarded): the stale specs become individual choice', function()
  local W = boot()
  local A = X.squad_of(W, 'A')
  W.set_census('i', {tick = 0, w_axe = 20, w_pick = 20})
  X.set_uniform(A, {positions = {0, 1, 2}, items = {{cat = 'weapon', type = 'WEAPON', subtype = 'ITEM_WEAPON_SPEAR'}}})
  X.weapon(W, 'ITEM_WEAPON_SPEAR')
  X.weapon(W, 'ITEM_WEAPON_SWORD_SHORT')
  X.weapon(W, 'ITEM_WEAPON_SWORD_SHORT')
  W.run(3600 * 2, {skip = 9})
  local w = wspecs(A)
  T.eq({count(w, 'ITEM_WEAPON_SPEAR'), count(w, 'choice')}, {1, 2}, 'one spear spec, two individual choices')
end)

T.test('BUG-591: no spare weapon of another kind: the specs stay as they are (nothing unequipped)', function()
  local W = boot()
  local A = X.squad_of(W, 'A')
  W.set_census('i', {tick = 0, w_axe = 0, w_pick = 0})
  X.set_uniform(A, {positions = {0, 1, 2}, items = {{cat = 'weapon', type = 'WEAPON', subtype = 'ITEM_WEAPON_SPEAR'}}})
  X.weapon(W, 'ITEM_WEAPON_SPEAR')
  W.run(3600 * 2, {skip = 9})
  local w = wspecs(A)
  T.eq(count(w, 'ITEM_WEAPON_SPEAR'), 3, 'no spare weapon: the three specs stay')
  T.ok(not logged(W, 'hold a weapon spec no free weapon fills'), 'and nothing is re-planned')
end)

---------------------------------------------------------------- 591: armor stock, the text, refit
local function armor_world()
  local W = boot()
  local other = df.global.world.items.other
  other.ARMOR = vec{}
  local real = dfhack.items.getSubtypeDef
  dfhack.items.getSubtypeDef = function(t, sub)
    if t == df.item_type.ARMOR then
      return {id = sub == 0 and 'ITEM_ARMOR_TUNIC' or 'ITEM_ARMOR_BREASTPLATE', armorlevel = sub == 0 and 0 or 1}
    end
    return real(t, sub)
  end
  local function piece(sub, flags)
    local it = X.item(W, 'ARMOR')
    it._sub, it.flags = sub, flags or {}
    it.getSubtype = function(self) return self._sub end
    other.ARMOR:insert('#', it)
    return it
  end
  return W, piece, function() dfhack.items.getSubtypeDef = real end
end

T.test('BUG-591: the stock counts true armor only (clothes are no uniform piece); stock_detail names clothes, forbidden and owned pieces; ' ..
       'the missing-text carries them and the other empty slots', function()
  local W, piece, restore = armor_world()
  local M = mil()
  for _ = 1, 54 do piece(0) end                       -- tunics: armorlevel 0
  piece(1); piece(1)                                  -- two free breastplates
  piece(1, {forbid = true})
  piece(1, {owned = true})
  local n = M.stock_mats('body')
  T.eq(n.any, 2, '2 true body armors (old code: 58)')
  local d = M.stock_detail('body')
  T.eq({d.free, d.soft, d.forbid, d.held}, {2, 54, 1, 1})
  W.K.set_mode('SIEGE', 'test')
  local txt = M.kit_missing(W.K, 'A')
  T.ok(txt:find(', 2 body armors', 1, true), txt)
  T.ok(txt:find('body armor 2 usable (54 clothes, 1 forbidden, 1 owned or carried)', 1, true), txt)
  T.ok(txt:find('slots empty: ', 1, true) and txt:find('helmet', 1, true), txt)
  restore()
end)

T.test('BUG-591: refit_plan: a slot empty at the last look too, with pieces free, goes to any material even where the stock of its own ' ..
       'material covers it; never back up to metal', function()
  local function pos(i, mat, empty)
    return {pos = i, p = {equipment = {uniform = {body = {{material_class = X.MAT_CLASS[mat] or -1}}, head = {}, pants = {}, gloves = {},
                                                  shoes = {}}}},
            kit = {empty = empty and {body = true} or {}, soft = {}}}
  end
  local stock = function() return {metal = 3, leather = 0, any = 3} end
  local a, b = pos(0, 'metal', true), pos(1, 'metal', true)
  local plan, empty = KIT.refit_plan({a, b}, stock)
  T.eq(plan, {}, 'first look: three metal pieces cover two slots')
  T.eq(empty, {body = {[0] = true, [1] = true}}, 'both are remembered as empty')
  local plan2, _, stuck = KIT.refit_plan({a, b}, stock, {prev = empty})
  T.eq(plan2, {{cat = 'body', mat = 'any', positions = {0, 1}}}, 'second look: both go to any material')
  T.eq(stuck, {body = {[0] = true, [1] = true}})
  -- pieces for one of the two only: one is freed
  local plan3 = KIT.refit_plan({a, b}, function() return {metal = 1, leather = 0, any = 1} end, {prev = empty})
  T.eq(plan3, {{cat = 'body', mat = 'any', positions = {0}}}, 'one piece free: one slot')
  -- no piece free at all: nothing to do
  T.eq(KIT.refit_plan({a, b}, function() return {metal = 0, leather = 0, any = 0} end, {prev = empty}), {})
  -- the held slots are not sent back to metal
  local soft = pos(2, 'any', false)
  soft.kit.soft = {body = true}
  T.eq(KIT.refit_plan({soft}, stock), {{cat = 'body', mat = 'metal', positions = {2}}}, 'a soft piece goes up to metal')
  T.eq(KIT.refit_plan({soft}, stock, {hold = {body = {[2] = true}}}), {}, 'unless the slot was freed for being stuck')
end)

T.test('BUG-591: inspect what=military: the squads, what each lacks, the free stock by cause, the manager', function()
  local W, piece, restore = armor_world()
  piece(0); piece(1)
  X.weapon(W, 'ITEM_WEAPON_SPEAR')
  X.weapon(W, 'ITEM_WEAPON_PICK')
  X.weapon(W, 'ITEM_WEAPON_SWORD_SHORT', {forbid = true})
  local r = W.inbox('inspect', {what = 'military'})
  T.eq(r.ok, true, tostring(r.msg))
  T.ok(tostring(r.msg):find('military: A ', 1, true), r.msg)
  local d = r.data
  T.eq({d.stock.body.free, d.stock.body.soft}, {1, 1})
  T.eq({d.weapons.melee, d.weapons.tools, d.weapons.forbid}, {1, 1, 1})
  T.ok(#d.squads >= 2)
  T.eq(d.manager_in_squad, false)
  T.eq(d.squads[1].fit, 0)
  restore()
end)

---------------------------------------------------------------- 592: the manager
T.test('BUG-592: the manager who sits in a squad is taken out of it (any mode); recruits never take him back', function()
  local W = boot()
  local A = X.squad_of(W, 'A')
  local uid
  for i = 1, 9 do
    if A.positions[i].occupant >= 0 then uid = W.hfs[A.positions[i].occupant].unit_id; break end
  end
  T.ok(uid, 'a soldier of A')
  local u = W.unit(uid)
  u._m.noble = 'MANAGER'
  df.global.plotinfo.main.fortress_entity.positions.assignments[1].histfig = u.hist_figure_id
  W.run(3600 * 2, {skip = 9})
  T.eq(u.military.squad_id, -1, 'out of the squad')
  T.ok(#X.acts(W, 'squad_remove') >= 1)
  T.ok(logged(W, 'the manager (unit ' .. uid .. ') was a member of squad'), 'kern.log says so')
  W.run(3600 * 3, {skip = 9})
  T.eq(u.military.squad_id, -1, 'and stays out (a noble is no recruit)')
  T.eq(mil().manager_pull(W.K, true), false, 'a manager in no squad: nothing to do')
end)

T.test('BUG-592: no manager appointed: nothing is removed', function()
  local W = boot()
  W.run(3600, {skip = 9})
  local before = #X.acts(W, 'squad_remove')
  T.eq(mil().manager_pull(W.K, true), nil, 'nobody holds the post')
  T.eq(#X.acts(W, 'squad_remove'), before)
end)

T.done()
