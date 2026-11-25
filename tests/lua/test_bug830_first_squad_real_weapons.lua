-- BUG-830 (Run 17 i3 Orangering y375, 24.11.): 'first squad: 1 of 2 members hold a real weapon (need 3+, all armed)' beside mil.free weapon 12,
-- census melee weapons 5-15 and kit {n 6, weapon 2, wood 2, tr 2}. commands.log: position 0 of squad A flipped between a real weapon
-- (AXE_BATTLE / HAMMER_WAR) and a training weapon (SPEAR_TRAINING / AXE_TRAINING) every 1-3 game days, each flip to real with 'keep a real
-- weapon: the fort holds no free training weapon' (the one wooden weapon is shared with squad B); a soldier whose spec changes drops what he
-- holds and fetches the new weapon: empty hands in between. The first melee squad (the one the growth ladder reads) no longer takes the
-- training weapons while the fort owns real melee weapons for it; kern.log names per soldier what he holds while the squad is not armed.
local T = require('testlib')
local X = require('wp6_world')

local function world(o)
  local W = X.world{units = X.citizens(30, 1, {skills = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}}), training = true}
  W.K.cfg.decisions['D-01'] = 'A'
  W.set_plan({v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = 120, beauty = 'used_rooms'}})
  X.load(W, {'military', 'readiness'}, {X.economy(), X.snapshot(), X.runner('P5')}, {'sense', 'threat', 'siege', 'gate'})
  W.set_census('i', {tick = 0, g_weapon = o.g_weapon or 5, g_body = 2, g_shield = 14, w_axe = 4, w_pick = 4})
  W.K.cfg.reflex = {v = 2, growth = o.growth or {on = true}}
  for _ = 1, 12 do X.weapon(W, 'ITEM_WEAPON_SWORD_SHORT') end                    -- mil.free weapon 12
  X.weapon(W, 'ITEM_WEAPON_AXE_TRAINING')                                         -- the one wooden weapon of the fort
  return W
end

local function specs(s)
  local wood, real, none = 0, 0, 0
  for pos = 0, 9 do
    local p = s.positions[pos]
    if p.occupant >= 0 then
      local sub
      for _, sp in ipairs(p.equipment.uniform.weapon) do sub = sub or sp.item_subtype end
      if sub == nil then none = none + 1
      elseif sub >= 0 and X.WEAPONS[sub + 1][1]:find('TRAINING', 1, true) then wood = wood + 1
      else real = real + 1 end
    end
  end
  return wood, real, none
end

local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return true end end
  return false
end

T.test('BUG-830: i3 numbers (census 5 melee weapons, 12 free, one wooden axe): the first squad A holds real weapon specs and never flips', function()
  local W = world{}
  W.K.set_mode('PEACE', 'test')
  W.run(1200 * 6, {skip = 9})
  local A = X.squad_of(W, 'A')
  local wood, real = specs(A)
  T.ok(wood == 0 and real >= 3, 'A on real weapons, wood ' .. wood .. ' real ' .. real)
  local before = #X.acts(W, 'squad_uniform')
  W.run(1200 * 12, {skip = 9})
  local flips = 0
  for i = before + 1, #X.acts(W, 'squad_uniform') do
    local a = X.acts(W, 'squad_uniform')[i]
    for _, it in ipairs(a.args[2].items or {}) do
      if it.cat == 'weapon' and tostring(it.subtype):find('TRAINING', 1, true) and a.args[1] == A.id then flips = flips + 1 end
    end
  end
  T.eq(flips, 0, 'no spec change of A to a training weapon in 12 days')
  wood, real = specs(A)
  T.ok(wood == 0, 'still real, wood ' .. wood)
end)

T.test('BUG-830: the training policy stays for the other squads (B takes the wooden axe) and for A without real weapons in the fort', function()
  local W = world{g_weapon = 0}
  W.K.set_mode('PEACE', 'test')
  W.run(1200 * 6, {skip = 9})
  local A = X.squad_of(W, 'A')
  local wood = specs(A)
  T.ok(wood >= 1, 'no real melee weapon in the census: the old policy, A wood ' .. wood)
  local W2 = world{growth = {on = false}}
  W2.K.set_mode('PEACE', 'test')
  W2.run(1200 * 6, {skip = 9})
  T.ok(specs(X.squad_of(W2, 'A')) >= 1, 'growth off: the old policy')
end)

T.test('BUG-830: while the first squad is not armed kern.log names each soldier: position, weapon in hand, spec, backed', function()
  local W = world{}
  W.K.set_mode('PEACE', 'test')
  W.run(1200 * 6, {skip = 9}); W.state()
  W.run(1200 * 2, {skip = 9}); W.state()
  T.ok(logged(W, 'military: first squad A 0 of '), 'a trace line')
  T.ok(logged(W, 'pos 0 hand none spec'), 'per soldier')
  local s = W.state()
  T.ok(s.mil.kit.sqw < s.mil.kit.sq, 'not armed: fail closed ' .. T.show(s.mil.kit))
  T.eq(s.ready.gh.halt, 'squad')
end)

T.test('BUG-830: the live i3 picture (one holds a wooden axe, the others have empty hands; census 15 melee weapons, 12 free): ' ..
       'the wooden one is backed, the empty one is not, the trace names the empty one, and both get real specs', function()
  local W = X.world{units = X.citizens(30, 1, {skills = {AXE = 6}}), training = true}
  W.K.cfg.decisions['D-01'] = 'A'
  X.load(W, {'military', 'readiness'}, {X.economy(), X.snapshot(), X.runner('P5')}, {'sense', 'threat', 'siege', 'gate'})
  W.set_census('i', {tick = 0, g_weapon = 15, g_body = 2, g_shield = 14, w_axe = 4, w_pick = 4})
  W.K.cfg.reflex = {v = 2, growth = {on = true}}
  for _ = 1, 12 do X.weapon(W, 'ITEM_WEAPON_SWORD_SHORT') end
  W.K.set_mode('PEACE', 'test')
  W.run(1200 * 3, {skip = 9})
  local A = X.squad_of(W, 'A')
  local uids = {}
  for i = 0, 9 do
    if A.positions[i].occupant >= 0 then
      local uid = W.hfs[A.positions[i].occupant].unit_id
      if #uids < 2 then uids[#uids + 1] = uid else X.unseat(W, A, uid) end
    end
  end
  T.eq(#uids, 2, 'squad A has two soldiers')
  local wood = X.weapon(W, 'ITEM_WEAPON_AXE_TRAINING')
  wood.flags.in_inventory = true
  W.unit(uids[1]).inventory:insert('#', {item = wood, mode = df.inv_item_role_type.Weapon})
  W.K.set_mode('PEACE', 'test')
  W.run(1200 * 3, {skip = 9})
  local st = W.state()
  T.eq({st.mil.kit.sq, st.mil.kit.sqw, st.mil.kit.wb}, {3, 1, 1}, T.show(st.mil.kit))
  T.ok(st.ready.gh.need:find('first squad: 3 of 3 fit; a real weapon usable for 1 of 3', 1, true), st.ready.gh.need)
  T.ok(logged(W, 'first squad A 1 of 3 ready (census melee weapons 15)'), 'trace header')
  T.ok(logged(W, 'pos 0 hand wood:AXE_TRAINING spec') and logged(W, '(backed)'), 'the wooden one is named backed')
  T.ok(logged(W, 'pos 1 hand none spec') and logged(W, '(not armed)'), 'the empty-handed one is named')
  local w, r, none = specs(A)
  T.ok(w == 0 and r >= 2 and r + none == 3, 'no wooden spec: wood ' .. w .. ' real ' .. r .. ' none ' .. none)
end)

T.test('BUG-830 / Z5: once the ladder squad step is passed first_real ends: A goes back to the wooden training weapons (drill stays wooden)', function()
  local W = X.world{units = X.citizens(30, 1, {skills = {AXE = 6}}), training = true}
  W.K.cfg.decisions['D-01'] = 'A'
  X.load(W, {'military', 'readiness'}, {X.economy(), X.snapshot(), X.runner('P5')}, {'sense', 'threat', 'siege', 'gate'})
  W.set_census('i', {tick = 0, g_weapon = 15, g_body = 2, g_shield = 14, w_axe = 4, w_pick = 4})
  W.K.cfg.reflex = {v = 2, growth = {on = true, armed_min = 2}}
  for _ = 1, 12 do X.weapon(W, 'ITEM_WEAPON_SWORD_SHORT') end
  for _ = 1, 4 do X.weapon(W, 'ITEM_WEAPON_AXE_TRAINING') end                     -- wooden weapons for everybody
  W.K.set_mode('PEACE', 'test')
  W.run(1200 * 3, {skip = 9})
  local A = X.squad_of(W, 'A')
  local uids = {}
  for i = 0, 9 do
    if A.positions[i].occupant >= 0 then
      local uid = W.hfs[A.positions[i].occupant].unit_id
      if #uids < 2 then uids[#uids + 1] = uid else X.unseat(W, A, uid) end
    end
  end
  T.eq(#uids, 2, 'squad A has two soldiers')
  W.run(1200 * 2, {skip = 9})
  local wood0, real0 = specs(A)
  T.ok(wood0 == 0 and real0 == 2, 'step open (nobody holds a weapon): A on real specs, wood ' .. wood0 .. ' real ' .. real0)
  for _, uid in ipairs(uids) do                                                    -- both hold a real weapon: the step is passed
    local w = X.weapon(W, 'ITEM_WEAPON_SWORD_SHORT')
    w.flags.in_inventory = true
    W.unit(uid).inventory:insert('#', {item = w, mode = df.inv_item_role_type.Weapon})
  end
  W.run(1200 * 3, {skip = 9}); W.state()
  W.run(1200 * 6, {skip = 9})
  local st = W.state()
  T.eq({st.mil.kit.sq, st.mil.kit.sqw}, {2, 2}, T.show(st.mil.kit))
  T.ok(logged(W, 'first squad A ready: 2 of 2 fit'), 'the latch is logged')
  local wood, real = specs(A)
  T.ok(wood == 2 and real == 0, 'back on the training policy: wood ' .. wood .. ' real ' .. real)
end)

T.done()
