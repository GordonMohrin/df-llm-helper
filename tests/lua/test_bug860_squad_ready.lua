-- BUG-860 (Run 17 i3 Orangering 25.11., i4 'Trupp A 0 von 3' for 20 game years, i1 squad A empty): the growth cap halted at 30 '(squad)' on
-- every fort since the ladder exists, because the latch (military: 'first squad A fully armed (3 of 3, 2 backed by a waiting weapon)') and the
-- gate (readiness: 'first squad: 1 of 3 members hold a real weapon') counted differently, and the gate could never stay passed in PEACE (the
-- doctrine drills wooden). ONE rule now (military.squad_ready, kit_stats): >= growth.armed_min members that are fit AND have a real melee weapon
-- in hand, assigned and usable, or waiting on the training policy; a latch with a release. These tests rebuild the i3 state (3 members, 1 real in
-- hand, 2 wooden in hand, 2 real assigned and not picked up, 1 member wounded), the release, the alert swap, the tr = 0 wooden spec and the
-- i1 deadlock (squad A empty, the soldiers in B and C).
local T = require('testlib')
local X = require('wp6_world')

local function world(o)
  o = o or {}
  local W = X.world{units = X.citizens(30, 1, {skills = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}}), training = true}
  W.K.cfg.decisions['D-01'] = 'A'
  W.set_plan({v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = 120, beauty = 'used_rooms'}})
  X.load(W, {'military', 'readiness'}, {X.economy(), X.snapshot(), X.runner('P5')}, {'sense', 'threat', 'siege', 'gate'})
  W.set_census('i', {tick = 0, g_weapon = o.g_weapon or 8, g_body = 2, g_shield = 14, w_axe = 4, w_pick = 4})
  W.K.cfg.reflex = {v = 2, growth = {on = true}}
  for _ = 1, 12 do X.weapon(W, 'ITEM_WEAPON_SPEAR') end
  for _ = 1, 4 do X.weapon(W, 'ITEM_WEAPON_SPEAR_TRAINING') end
  local items = W.items_by_id
  df.item = df.item or {}
  df.item.find = function(id) return items[id] end
  return W
end

local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return true end end
  return false
end

-- squad A seated with exactly n soldiers; returns the squad and the positions {pos, uid}
local function seats(W, n)
  W.K.set_mode('PEACE', 'test')
  W.run(1200 * 3, {skip = 9})
  local A = X.squad_of(W, 'A')
  local out = {}
  for i = 0, 9 do
    local hf = A.positions[i].occupant
    if hf >= 0 then
      local uid = W.hfs[hf].unit_id
      if #out < n then out[#out + 1] = {pos = i, uid = uid} else X.unseat(W, A, uid) end
    end
  end
  return A, out
end

local function hold(W, uid, token, mode)
  local it = X.weapon(W, token)
  it.flags.in_inventory = true
  W.unit(uid).inventory:insert('#', {item = it, mode = df.inv_item_role_type.Weapon})
  return it
end

-- DF assigned a real weapon to the position's weapon spec and the soldier has not picked it up
local function assign(W, A, pos, flags)
  local it = X.weapon(W, 'ITEM_WEAPON_SPEAR', flags)
  if #A.positions[pos].equipment.uniform.weapon == 0 then
    X.set_uniform(A, {positions = {pos}, items = {{cat = 'weapon', type = 'WEAPON', subtype = 'ITEM_WEAPON_SPEAR', mat = 'any'}}})
  end
  for _, sp in ipairs(A.positions[pos].equipment.uniform.weapon) do sp.assigned:insert('#', it.id) end
  return it
end

local function kit(W)
  W.run(1300, {skip = 9})
  return W.state().mil.kit
end

T.test('BUG-860: the i3 state (1 real in hand, 2 wooden in hand with a real weapon assigned, 1 wounded): ready only with the wounded one healed; PEACE wood keeps it', function()
  local W = world()
  local A, m = seats(W, 3)
  T.eq(#m, 3, 'three members')
  hold(W, m[1].uid, 'ITEM_WEAPON_SPEAR')
  hold(W, m[2].uid, 'ITEM_WEAPON_SPEAR_TRAINING')
  hold(W, m[3].uid, 'ITEM_WEAPON_SPEAR_TRAINING')
  assign(W, A, m[2].pos); assign(W, A, m[3].pos)
  W.unit(m[3].uid)._m.unconscious = 500                                      -- the third one is badly wounded
  local k = kit(W)
  T.eq({k.sq, k.sqf, k.sqa, k.sqw, k.sqok}, {3, 2, 3, 2, 0}, 'fit 2 of 3, a real weapon usable for 3, ready 2: ' .. T.show(k))
  local s = W.state()
  T.eq(s.ready.gh.halt, 'squad')
  T.ok(s.ready.gh.need:find('first squad: 2 of 3 fit; a real weapon usable for 3 of 3 (need 3+ ready)', 1, true), s.ready.gh.need)
  T.eq(s.ready.gh.inj, 1)
  W.unit(m[3].uid)._m.unconscious = 0                                        -- healed
  k = kit(W)
  T.eq({k.sqf, k.sqw, k.sqok}, {3, 3, 1}, 'all three ready: ' .. T.show(k))
  T.ok(logged(W, 'military: first squad A ready: 3 of 3 fit, a real weapon usable for 3 of 3 (2 assigned, 0 waiting)'), 'the pass is logged: ' .. (function() for _, l in ipairs(W.logs) do if tostring(l.msg):find('first squad A ready', 1, true) then return l.msg end end return 'none' end)())
  T.ok(s.ready.gh.halt ~= nil, 'state read before')
  s = W.state()
  T.ok(s.ready.gh == nil or s.ready.gh.halt ~= 'squad', 'the halt leaves squad: ' .. T.show(s.ready.gh))
end)

T.test('BUG-860: the latch holds while the real weapon in hand is swapped for a wooden one in PEACE (census still owns real weapons)', function()
  local W = world()
  local A, m = seats(W, 3)
  for i = 1, 3 do hold(W, m[i].uid, 'ITEM_WEAPON_SPEAR') end
  local k = kit(W)
  T.eq({k.sqw, k.sqok}, {3, 1}, T.show(k))
  -- PEACE drill: every soldier now holds a wooden weapon, no real one assigned: the policy backs them with the census weapons
  for i = 1, 3 do
    local inv = W.unit(m[i].uid).inventory
    for j = #inv - 1, 0, -1 do if inv[j].mode == df.inv_item_role_type.Weapon then inv:erase(j) end end
    hold(W, m[i].uid, 'ITEM_WEAPON_SPEAR_TRAINING')
  end
  k = kit(W)
  T.eq(k.sqok, 1, 'a wooden drill weapon in PEACE does not un-pass it: ' .. T.show(k))
  T.ok(k.sqw >= 3, 'backed by the census weapons: ' .. T.show(k))
end)

T.test('BUG-860: release: usable real weapons below armed_min for 5 game days, or fewer members than armed_min; fail closed without a reading', function()
  local W = world()
  local A, m = seats(W, 3)
  for i = 1, 3 do hold(W, m[i].uid, 'ITEM_WEAPON_SPEAR') end
  T.eq(kit(W).sqok, 1)
  -- the weapons are gone (census 0, hands empty): not released at once, released after the days
  for i = 1, 3 do
    local inv = W.unit(m[i].uid).inventory
    for j = #inv - 1, 0, -1 do if inv[j].mode == df.inv_item_role_type.Weapon then inv:erase(j) end end
  end
  W.set_census('i', {tick = 0, g_weapon = 0, g_body = 2, g_shield = 14, w_axe = 4, w_pick = 4})
  local k = kit(W)
  T.eq(k.sqok, 1, 'still passed the first day: ' .. T.show(k))
  W.run(1200 * 3, {skip = 9})
  T.eq(W.state().mil.kit.sqok, 1, 'still passed after 3 days')
  W.run(1200 * 4, {skip = 9})
  k = W.state().mil.kit
  T.eq({k.sqok, k.sqa}, {0, 0}, 'released after 5 days of no usable real weapon: ' .. T.show(k))
  T.ok(logged(W, 'ready latch released: a real weapon usable for only 0 of 3 members'), 'the release is logged')
  T.eq(W.state().ready.gh.halt, 'squad')
  local M = X.mod('military')
  T.ok(M.squad_ready(3, 3) and not M.squad_ready(2, 3) and not M.squad_ready(nil, 3) and not M.squad_ready(3, nil), 'the rule: fail closed on a missing number')
end)

T.test('BUG-860: fewer members than armed_min releases at once', function()
  local W = world()
  local A, m = seats(W, 3)
  for i = 1, 3 do hold(W, m[i].uid, 'ITEM_WEAPON_SPEAR') end
  T.eq(kit(W).sqok, 1)
  X.unseat(W, A, m[3].uid)
  local k = kit(W)
  T.eq({k.sq, k.sqok}, {2, 0}, T.show(k))
  T.ok(logged(W, 'ready latch released: 2 members (need 3+)'), 'logged')
end)

T.test('BUG-860: an assigned weapon that is forbidden, marked for melting or a training weapon is no usable weapon', function()
  local W = world()
  local A, m = seats(W, 3)
  W.set_census('i', {tick = 0, g_weapon = 0, g_body = 2, g_shield = 14, w_axe = 4, w_pick = 4})     -- no census weapon waits: nothing is backed
  assign(W, A, m[1].pos, {forbid = true})
  assign(W, A, m[2].pos, {melt = true})
  hold(W, m[3].uid, 'ITEM_WEAPON_SPEAR_TRAINING')
  local k = kit(W)
  T.eq({k.sqa, k.sqw}, {0, 0}, 'nothing usable: ' .. T.show(k))
  assign(W, A, m[1].pos)
  k = kit(W)
  T.eq(k.sqa, 1, 'a clean one counts: ' .. T.show(k))
end)

T.test('BUG-860: ALERT swaps the wooden specs of the ready squad for real weapons through the alert path; PEACE puts the wooden ones back', function()
  local W = world()
  local A, m = seats(W, 3)
  for i = 1, 3 do hold(W, m[i].uid, 'ITEM_WEAPON_SPEAR') end
  W.run(1200 * 6, {skip = 9})
  T.eq(W.state().mil.kit.sqok, 1)
  local function wood()
    local n = 0
    for _, pp in ipairs(m) do
      for _, sp in ipairs(A.positions[pp.pos].equipment.uniform.weapon) do
        if sp.item_subtype and sp.item_subtype >= 0 and X.WEAPONS[sp.item_subtype + 1][1]:find('TRAINING', 1, true) then n = n + 1 end
      end
    end
    return n
  end
  T.eq(wood(), 3, 'PEACE and ready: the squad drills on wooden weapon specs (Z5)')
  W.K.set_mode('ALERT', 'test')
  W.run(1200 * 3, {skip = 9})
  T.eq(wood(), 0, 'ALERT: every wooden spec went back to a real weapon')
  T.eq(W.state().mil.kit.sqok, 1, 'the pass holds')
  W.K.set_mode('SIEGE', 'test')
  W.run(1200 * 3, {skip = 9})
  T.eq(wood(), 0, 'SIEGE: real')
  W.K.set_mode('PEACE', 'test')
  W.run(1200 * 6, {skip = 9})
  T.ok(wood() >= 1, 'PEACE again: wooden specs')
end)

T.test('BUG-861: a squad the player took off the training policy (tr = 0, squad.uniform melee) loses its kept wooden spec while the fort owns real weapons', function()
  local W = world()
  local A, m = seats(W, 3)
  W.run(1200 * 3, {skip = 9})
  local r = W.inbox('squad.uniform', {squad = 'A', kind = 'melee'})
  T.ok(r.ok, r.msg)
  -- the player's uniform kept a worn wooden spec on position 2 (squad.uniform never takes off what a soldier wears)
  X.set_uniform(A, {positions = {m[3].pos}, items = {{cat = 'weapon', type = 'WEAPON', subtype = 'ITEM_WEAPON_SPEAR_TRAINING', mat = 'any'}}})
  local function spec(pos)
    local sp = A.positions[pos].equipment.uniform.weapon
    for _, x in ipairs(sp) do return x.item_subtype end
  end
  T.ok(X.WEAPONS[spec(m[3].pos) + 1][1]:find('TRAINING', 1, true), 'precondition: wooden spec')
  W.run(1200 * 6, {skip = 9})
  local sub = spec(m[3].pos)
  T.ok(sub == nil or sub < 0 or not X.WEAPONS[sub + 1][1]:find('TRAINING', 1, true), 'the wooden spec is gone, tr 0: ' .. tostring(sub))
end)

-- A emptied into the crossbow squad C (every other citizen is in a mood: no recruit is left)
local function deadlock(W)
  local A = seats(W, 3)
  local C = X.squad_of(W, 'C')
  local gone = {}
  for i = 0, 9 do
    local hf = A.positions[i].occupant
    if hf >= 0 then gone[#gone + 1] = W.hfs[hf].unit_id end
  end
  for _, uid in ipairs(gone) do X.unseat(W, A, uid) end
  for _, uid in ipairs(gone) do
    for i = 1, 9 do if C.positions[i].occupant < 0 then X.seat(W, C, i, uid); break end end
  end
  for _, u in ipairs(df.global.world.units.active) do
    if u.military.squad_id < 0 then u.mood = 2 end
  end
  return A, C
end

T.test('BUG-862 i1: squad A empty, the soldiers sit in C, no recruit left: the kernel takes a leader and armed_min members from C first', function()
  local W = world()
  local A, C = deadlock(W)
  local cn = X.members(C)
  T.eq(X.members(A), 0, 'A empty')
  W.run(1200 * 6, {skip = 9})
  T.ok(A.positions[0].occupant >= 0, 'A has a leader')
  T.ok(X.members(A) >= 3, 'A holds armed_min members: ' .. X.members(A))
  T.ok(C.positions[0].occupant >= 0, 'the leader of C stays')
  T.eq(X.members(A) + X.members(C), cn, 'nobody lost')
  T.ok(logged(W, 'unit ') and logged(W, 'the first squad is filled first'), 'logged')
end)

T.test('BUG-862 i1: squad.add into the leaderless empty A seats the unit as leader (no squad.leader first), squad.leader takes a member of C out of C; a leader of another squad stays', function()
  local W = world()
  local A, C = deadlock(W)
  local bm, cl = nil, W.hfs[C.positions[0].occupant].unit_id
  for i = 1, 9 do
    if C.positions[i].occupant >= 0 then bm = W.hfs[C.positions[i].occupant].unit_id; break end
  end
  local before = X.members(C)
  local r = W.inbox('squad.add', {squad = A.id, unit = bm})
  T.ok(r.ok and r.data.leader == true and r.msg:find('as its leader', 1, true), tostring(r.msg))
  T.eq(X.members(C), before - 1, 'left C')
  T.eq(A.positions[0].occupant, W.unit(bm).hist_figure_id, 'leader of A')
  r = W.inbox('squad.add', {squad = A.id, unit = cl})
  T.ok(not r.ok and tostring(r.msg):find('leads squad', 1, true), 'the leader of C stays: ' .. tostring(r.msg))
  -- squad.leader for a unit of C while A has no leader: the same way
  X.unseat(W, A, bm)
  local b2
  for i = 1, 9 do
    if C.positions[i].occupant >= 0 then b2 = W.hfs[C.positions[i].occupant].unit_id; break end
  end
  r = W.inbox('squad.leader', {squad = A.id, unit = b2})
  T.ok(r.ok, tostring(r.msg))
  T.eq(A.positions[0].occupant, W.unit(b2).hist_figure_id, 'leads A')
end)

T.done()
