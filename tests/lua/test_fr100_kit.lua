-- FR-100/FR-101 (Gordon's goal G18: "every soldier armor + weapon; sparring always with wooden training weapons"):
-- the training policy of FR-89 is the default for every melee squad military makes or adopts (military.training.on, the
-- plan's military.training wins), a class without a training raw takes a relative's or the fallback's (FR-101), a player's
-- squad.uniform kind=melee turns it off for good, a withdrawn default gives the wooden positions their real weapons back;
-- the per-soldier kit KPI (state mil.kit) and the armor's material refit (dfllm.kit).
local T = require('testlib')
local X = require('wp6_world')
local KIT = require('dfllm.kit')
local vec = require('dfllm.util.k_mock').vec

local function mil() return X.mod('military') end
local function world(opts)
  opts = opts or {}
  opts.n = opts.n or 50
  if opts.training == nil then opts.training = true end     -- the shipped defaults (on, fallback SPEAR, refit 7 days)
  local W = X.world(opts)
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  return W
end
local function rec(W, k) return (W.K.persist.get('m.military') or {sq = {}}).sq[k] end
-- seats citizens 41.. in positions 0.. with skills (and a weapon spec token)
local function arm(W, s, rows)
  for i, row in ipairs(rows) do
    local pos, uid = i - 1, 40 + i
    if s.positions[pos].occupant >= 0 then X.unseat(W, s, W.hfs[s.positions[pos].occupant].unit_id) end
    X.seat(W, s, pos, uid)
    W.unit(uid)._m.skills = row.skills or {}
    s.positions[pos].equipment.uniform.weapon = vec{}
    if row.spec then X.set_uniform(s, {positions = {pos}, items = {{cat = 'weapon', type = 'WEAPON', subtype = row.spec}}}) end
  end
end
local function subs(s, pos)
  local r = {}
  for _, sp in ipairs(s.positions[pos].equipment.uniform.weapon) do r[#r + 1] = sp.item_subtype end
  return r
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return true end end
  return false
end
local DAY = 1200

T.test('FR-100: a melee squad goes on wooden training weapons by default; FR-101: hammer/none -> spear, pike -> spear, '
       .. 'dagger -> sword; the crossbow squad stays', function()
  local W = world()
  local A, C = X.squad_of(W, 'A'), X.squad_of(W, 'C')
  T.ok(A and C, 'military made A and C')
  T.eq({rec(W, 'A').tr, rec(W, 'A').td}, {1, 1}, 'policy on, set by the default')
  T.eq(rec(W, 'C').tr, nil, 'no training crossbow: the crossbow squad has no policy')
  T.ok(logged(W, 'squad A: training policy on by default'), 'kern.log names it')
  arm(W, A, {{skills = {AXE = 8}, spec = 'ITEM_WEAPON_AXE_BATTLE'}, {skills = {HAMMER = 6}, spec = 'ITEM_WEAPON_HAMMER_WAR'},
             {skills = {PIKE = 4}}, {skills = {DAGGER = 3}}, {skills = {}}, {skills = {SWORD = 2}}})
  W.run(3600 * 2, {skip = 9})
  local w = X.WIDX
  T.eq({subs(A, 0), subs(A, 1), subs(A, 2), subs(A, 3), subs(A, 4), subs(A, 5)},
       {{w.ITEM_WEAPON_AXE_TRAINING}, {w.ITEM_WEAPON_SPEAR_TRAINING}, {w.ITEM_WEAPON_SPEAR_TRAINING},
        {w.ITEM_WEAPON_SWORD_SHORT_TRAINING}, {w.ITEM_WEAPON_SPEAR_TRAINING}, {w.ITEM_WEAPON_SWORD_SHORT_TRAINING}})
  for i = 0, 9 do
    for _, sub in ipairs(subs(C, i)) do T.ok(not X.WEAPONS[sub + 1][1]:find('TRAINING', 1, true), 'C keeps its crossbows') end
  end
  -- the carpenters' orders (economy.plan_training) follow the fallback too
  local need = X.call(W, 'military', 'training_need')
  -- (B's recruits have no weapon skill: spears too)
  T.ok((need.ITEM_WEAPON_SPEAR_TRAINING or 0) >= 3, 'hammer, pike and no skill want training spears')
  T.eq(need.ITEM_WEAPON_SWORD_SHORT_TRAINING, 2)
  T.eq(need.ITEM_WEAPON_AXE_TRAINING, 1)
end)

T.test('FR-100: an alert gives every wooden position its real weapon back (the hammer too), PEACE the wooden ones again',
       function()
  local W = world()
  local A = X.squad_of(W, 'A')
  arm(W, A, {{skills = {AXE = 8}, spec = 'ITEM_WEAPON_AXE_BATTLE'}, {skills = {HAMMER = 6}, spec = 'ITEM_WEAPON_HAMMER_WAR'}})
  W.run(3600 * 2, {skip = 9})
  T.eq(subs(A, 1), {X.WIDX.ITEM_WEAPON_SPEAR_TRAINING}, 'the hammerdwarf spars with a training spear')
  for _, mode in ipairs({'ALERT', 'SIEGE'}) do
    W.set_mode(mode)
    W.run(3600 * 2, {skip = 9})
    for pos = 0, 1 do
      T.ok(#subs(A, pos) > 0, mode .. ': a weapon spec stays')
      for _, sub in ipairs(subs(A, pos)) do
        T.ok(sub < 0 or not X.WEAPONS[sub + 1][1]:find('TRAINING', 1, true), mode .. ': no wooden weapon, pos ' .. pos)
      end
    end
    W.set_mode('PEACE')
    W.run(3600 * 2, {skip = 9})
    T.eq(subs(A, 1), {X.WIDX.ITEM_WEAPON_SPEAR_TRAINING}, 'back in PEACE: wooden again after ' .. mode)
  end
end)

T.test('FR-100: squad.uniform kind=melee turns the policy off for good (tr 0, kept over a reload); kind=training on again',
       function()
  local W = world()
  local A = X.squad_of(W, 'A')
  arm(W, A, {{skills = {AXE = 8}, spec = 'ITEM_WEAPON_AXE_BATTLE'}})
  W.run(3600, {skip = 9})
  T.ok(W.inbox('squad.uniform', {squad = 'A', kind = 'melee'}).ok)
  T.eq({rec(W, 'A').tr, rec(W, 'A').td}, {0, nil})
  mil().init(W.K)                                        -- a reload: the persisted record decides
  local before = #X.acts(W, 'squad_uniform')
  W.run(3600 * 3, {skip = 9})
  for i = before + 1, #X.acts(W, 'squad_uniform') do
    for _, it in ipairs(X.acts(W, 'squad_uniform')[i].args[2].items) do
      T.ok(not tostring(it.subtype):find('TRAINING', 1, true), 'no training weapon after the player chose metal')
    end
  end
  T.eq(rec(W, 'A').tr, 0, 'the default does not turn it on again')
  T.ok(W.inbox('squad.uniform', {squad = 'A', kind = 'training'}).ok)
  T.eq({rec(W, 'A').tr, rec(W, 'A').td}, {1, nil}, 'on by the player: no default to withdraw')
end)

T.test('FR-100: military.training.on false keeps the old way; the plan\'s military.training wins; a withdrawn default '
       .. 'gives the wooden positions their real weapons back', function()
  local W0 = world{training = {on = false}}
  T.eq(rec(W0, 'A').tr, nil, 'config off: no policy')
  local W = world()
  local A = X.squad_of(W, 'A')
  arm(W, A, {{skills = {AXE = 8}, spec = 'ITEM_WEAPON_AXE_BATTLE'}})
  W.run(3600 * 2, {skip = 9})
  T.eq(subs(A, 0), {X.WIDX.ITEM_WEAPON_AXE_TRAINING})
  W.set_plan{v = 2, year = 3, phase_target = 'P5', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
             policy = {option = 'A', pop_ceiling = 55, beauty = 'none'},
             military = {pct = 15, squads = {melee = 2, xbow = 1}, cv_min = 12, training = false}}
  W.run(3600 * 3, {skip = 9})
  T.eq(rec(W, 'A').tr, nil, 'the plan switched the default off')
  T.eq(rec(W, 'A').un, nil, 'and the withdrawal finished')
  T.eq(#subs(A, 0), 1)
  T.ok(subs(A, 0)[1] < 0, 'individual choice again (a real weapon), not the training axe')
  local W2 = world{training = {on = false}}
  W2.set_plan{v = 2, year = 3, phase_target = 'P5', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = 55, beauty = 'none'},
              military = {pct = 15, squads = {melee = 2, xbow = 1}, cv_min = 12, training = true}}
  W2.run(3600 * 2, {skip = 9})
  T.eq(rec(W2, 'A').tr, 1, 'plan training true over config off')
end)

T.test('FR-100: state mil.kit counts soldiers fully equipped (every armor slot worn + a weapon in hand) and the wooden '
       .. 'weapons', function()
  local W = world()
  local A = X.squad_of(W, 'A')
  W.run(3600, {skip = 9})                                  -- the recruits of the first upkeep get their weapon spec
  local ids = {}
  for i = 0, 9 do
    local o = A.positions[i].occupant
    if o >= 0 then ids[#ids + 1] = W.hfs[o].unit_id end
  end
  T.ok(#ids >= 3, 'squad A has soldiers')
  X.equip(W, ids[1])                                       -- everything (the weapon slot: an item, no training raw)
  X.equip(W, ids[2], {skip = {body = true}})               -- no body armor
  X.equip(W, ids[3], {skip = {weapon = true}})             -- armor, but a training axe in hand instead
  local wood = X.weapon(W, 'ITEM_WEAPON_AXE_TRAINING')
  W.unit(ids[3]).inventory:insert('#', {item = wood, mode = df.inv_item_role_type.Weapon})
  W.run(3600, {skip = 9})
  local k = W.state().mil.kit
  T.ok(k, 'state mil.kit')
  T.eq({k.full, k.armor, k.weapon, k.wood, k.tr}, {2, 2, 3, 1, 2}, 'A and B on the policy, C not')
  T.eq(k.n, W.state().mil.soldiers)
end)

T.test('FR-100: the refit: a metal slot that stays empty while other pieces lie free goes to any material after '
       .. 'refit_days, never in an alert, never for the positions the free metal covers', function()
  local W = world()
  local M = mil()
  local A = X.squad_of(W, 'A')
  -- every position of A wants metal body armor (the squads screen's metal template)
  X.set_uniform(A, {items = {{cat = 'body', type = 'ARMOR', mat = 'metal'}}})
  local stock = {body = {metal = 1, leather = 4, any = 5}}
  local real = M.stock_mats
  M.stock_mats = function(cat) return stock[cat] or {metal = 0, leather = 0, any = 0} end
  local function body_mats()
    local r = {}
    for i = 0, 9 do
      if A.positions[i].occupant >= 0 then r[#r + 1] = A.positions[i].equipment.uniform.body[0].mat or 'any' end
    end
    return r
  end
  local n = 0
  for i = 0, 9 do if A.positions[i].occupant >= 0 then n = n + 1 end end
  T.ok(n >= 3, 'A has at least 3 soldiers')
  W.run(3 * DAY, {skip = 9})
  T.eq(body_mats()[1], 'metal', 'not before refit_days')
  W.set_mode('ALERT')
  W.run(5 * DAY, {skip = 9})
  T.eq(body_mats()[1], 'metal', 'never in an alert')
  W.set_mode('PEACE')
  W.run(4 * DAY, {skip = 9})
  local m = body_mats()
  T.eq(m[1], 'metal', 'the first position: the one free metal breastplate is his')
  for i = 2, math.min(#m, 5) do T.eq(m[i], 'any', 'position ' .. i .. ': any material') end
  T.ok(logged(W, 'squad A: body of'), 'kern.log names the refit')
  M.stock_mats = real
end)

T.test('FR-100 kit library: conf limits and the plan; refit_plan upgrades soft slots back to metal when it covers them',
       function()
  T.eq(KIT.conf(nil, nil), {on = true, fallback = 'SPEAR', refit_days = 7})
  T.eq(KIT.conf({on = false, fallback = 'MACE', refit_days = 99}, nil), {on = false, fallback = 'SPEAR', refit_days = 7})
  T.eq(KIT.conf({on = false, fallback = 'none', refit_days = 0}, {training = true}), {on = true, fallback = 'none',
                                                                                        refit_days = 0})
  T.eq(KIT.conf({on = true}, {training = false}).on, false)
  local function pos(mat, empty, soft)
    return {pos = 0, p = {equipment = {uniform = {body = {{material_class = X.MAT_CLASS[mat] or -1}}, head = {},
                                                  pants = {}, gloves = {}, shoes = {}}}},
            kit = {empty = empty and {body = true} or {}, soft = soft and {body = true} or {}}}
  end
  local a, b = pos('any', false, true), pos('any', false, true)
  b.pos = 1
  local plan = KIT.refit_plan({a, b}, function() return {metal = 2, leather = 0, any = 2} end)
  T.eq(plan, {{cat = 'body', mat = 'metal', positions = {0, 1}}})
  T.eq(KIT.refit_plan({a, b}, function() return {metal = 1, leather = 0, any = 1} end), {}, 'one piece for two: stay')
  local c = pos('leather', true, false)
  T.eq(KIT.refit_plan({c}, function() return {metal = 3, leather = 0, any = 3} end),
       {{cat = 'body', mat = 'any', positions = {0}}}, 'an empty leather slot takes the free metal')
end)

T.done()
