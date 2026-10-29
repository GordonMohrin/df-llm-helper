-- FR-89 (Run 14 note 82, Gordon 26.10.: "drills only with wooden weapons, build enough"): squad.uniform kind `training` sets
-- the matching TRAINING weapon per position (axe -> ITEM_WEAPON_AXE_TRAINING, sword -> SWORD_SHORT_TRAINING, spear ->
-- SPEAR_TRAINING) through the same act as the other kinds; hammer, mace, pick and the other classes stay unchanged with a
-- warning that lists them. The squad then keeps the policy (state mil.sq tr): bare positions (recruits, the militia rotation) get
-- the training weapon too, and economy orders the training weapons the positions lack at the carpenters, bounded.
local T = require('testlib')
local X = require('wp6_world')

-- the vanilla training raws (idx 6-8 in the fake world, wp6_world.lua X.WEAPONS since FR-100), skill = the class
for _, t in ipairs({'ITEM_WEAPON_AXE_TRAINING', 'ITEM_WEAPON_SWORD_SHORT_TRAINING', 'ITEM_WEAPON_SPEAR_TRAINING',
                    'ITEM_WEAPON_HAMMER_WAR'}) do
  assert(X.WIDX[t], 'wp6_world has ' .. t)
end

local function mil_world(opts)
  local W = X.world(opts)
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  return W
end

-- seats citizens 41.. in the squad's positions 0.. with their skills and weapon specs: {skills, spec token | nil}
local function arm(W, A, rows)
  for i, row in ipairs(rows) do
    local pos = i - 1
    local uid = 40 + i
    if A.positions[pos].occupant >= 0 then X.unseat(W, A, A.positions[pos].occupant - 50000) end
    X.seat(W, A, pos, uid)
    W.unit(uid)._m.skills = row.skills or {}
    A.positions[pos].equipment.uniform.weapon = require('dfllm.util.k_mock').vec{}
    if row.spec then X.set_uniform(A, {positions = {pos}, items = {{cat = 'weapon', type = 'WEAPON', subtype = row.spec}}}) end
  end
end
local function weapon_subs(A, pos)
  local r = {}
  for _, sp in ipairs(A.positions[pos].equipment.uniform.weapon) do r[#r + 1] = sp.item_subtype end
  return r
end

T.test('FR-89: kind training sets the training weapon of each position\'s class; hammer, mace and no skill stay, listed in a warning',
       function()
  local W = mil_world{n = 50}
  local A = X.squad_of(W, 'A')
  T.ok(A, 'military made squad A')
  arm(W, A, {{skills = {AXE = 8}, spec = 'ITEM_WEAPON_AXE_BATTLE'},          -- a battle axe in hand
             {skills = {SWORD = 5}, spec = 'ITEM_WEAPON_SWORD_SHORT'},
             {skills = {SPEAR = 4}},                                         -- individual choice: the best skill says spear
             {skills = {HAMMER = 6}, spec = 'ITEM_WEAPON_HAMMER_WAR'},       -- no training hammer exists
             {skills = {MACE = 3}, spec = 'ITEM_WEAPON_MACE'},
             {skills = {}}})                                                 -- no weapon skill at all
  local before = #X.acts(W, 'squad_uniform')
  local r = W.inbox('squad.uniform', {squad = 'A', kind = 'training'})
  T.ok(r.ok, r.msg)
  local calls = {}
  for i = before + 1, #X.acts(W, 'squad_uniform') do calls[#calls + 1] = X.acts(W, 'squad_uniform')[i] end
  T.eq(#calls, 3, 'one call per training weapon')
  local got = {}
  for _, c in ipairs(calls) do
    local spec = c.args[2]
    T.eq(spec.mode, 'replace')
    T.eq(#spec.items, 1, 'the weapon slot only: armor and shield stay')
    T.eq({spec.items[1].cat, spec.items[1].type}, {'weapon', 'WEAPON'})
    got[spec.items[1].subtype] = spec.positions
  end
  T.eq(got, {ITEM_WEAPON_AXE_TRAINING = {0}, ITEM_WEAPON_SWORD_SHORT_TRAINING = {1}, ITEM_WEAPON_SPEAR_TRAINING = {2}})
  T.eq({weapon_subs(A, 0), weapon_subs(A, 1), weapon_subs(A, 2)},
       {{X.WIDX.ITEM_WEAPON_AXE_TRAINING}, {X.WIDX.ITEM_WEAPON_SWORD_SHORT_TRAINING}, {X.WIDX.ITEM_WEAPON_SPEAR_TRAINING}})
  T.eq(weapon_subs(A, 3), {X.WIDX.ITEM_WEAPON_HAMMER_WAR}, 'the hammer stays')
  T.eq(weapon_subs(A, 4), {X.WIDX.ITEM_WEAPON_MACE}, 'the mace stays')
  T.ok(r.msg:find('training weapons on 3 positions (axe 1, sword 1, spear 1)', 1, true), r.msg)
  T.ok(r.msg:find('unchanged (no training variant): 3 HAMMER, 4 MACE, 5 none', 1, true), r.msg)
  T.eq({r.data.set, r.data.left}, {3, 3})
  local warned = false
  for _, l in ipairs(W.logs) do if l.level == 'warn' and l.msg:find('no training variant', 1, true) then warned = true end end
  T.ok(warned, 'kern.log warns once')
end)

T.test('FR-89: no position with a training variant -> refused with the list, no policy set', function()
  local W = mil_world{n = 50}
  local A = X.squad_of(W, 'A')
  arm(W, A, {{skills = {HAMMER = 6}, spec = 'ITEM_WEAPON_HAMMER_WAR'}, {skills = {MACE = 3}, spec = 'ITEM_WEAPON_MACE'}})
  local r = W.inbox('squad.uniform', {squad = 'A', kind = 'training'})
  T.ok(not r.ok and r.msg:find('no position has a training variant: 0 HAMMER, 1 MACE', 1, true), r.msg)
  T.eq(W.state().mil and W.state().mil.tr, nil, 'no policy set')
end)

T.test('FR-89: the squad keeps the policy: a recruit in a bare position gets the training weapon of his class', function()
  local W = mil_world{n = 50}
  local A = X.squad_of(W, 'A')
  arm(W, A, {{skills = {AXE = 8}, spec = 'ITEM_WEAPON_AXE_BATTLE'}})
  T.ok(W.inbox('squad.uniform', {squad = 'A', kind = 'training'}).ok)
  -- a new soldier takes the first free position; his position is bare
  local free
  for i = 0, 9 do if A.positions[i].occupant < 0 then free = i; break end end
  local uid = 47
  X.seat(W, A, free, uid)
  W.unit(uid)._m.skills = {SWORD = 6}
  local before = #X.acts(W, 'squad_uniform')
  W.run(3600 * 3, {skip = 9})
  local seen = false
  for i = before + 1, #X.acts(W, 'squad_uniform') do
    local sp = X.acts(W, 'squad_uniform')[i].args[2]
    if sp.items[1] and sp.items[1].subtype == 'ITEM_WEAPON_SWORD_SHORT_TRAINING' then seen = true end
  end
  T.ok(seen, 'the recruit\'s position got the short sword\'s training variant')
  -- a metal uniform kind ends the policy
  T.ok(W.inbox('squad.uniform', {squad = 'A', kind = 'melee'}).ok)
  local before2 = #X.acts(W, 'squad_uniform')
  X.seat(W, A, free + 1, 48)
  W.unit(48)._m.skills = {AXE = 3}
  W.run(3600 * 3, {skip = 9})
  for i = before2 + 1, #X.acts(W, 'squad_uniform') do
    local sp = X.acts(W, 'squad_uniform')[i].args[2]
    for _, it in ipairs(sp.items) do T.ok(not tostring(it.subtype):find('TRAINING', 1, true), 'no training weapon after melee') end
  end
end)

T.test('FR-89: a training weapon is no work tool: the tool guard does not count the training axe as an axe', function()
  local W = mil_world{n = 50}
  local mil = X.mod('military')
  T.eq(mil.weapon_kind(X.WIDX.ITEM_WEAPON_AXE_BATTLE).k, 'axe')
  T.eq(mil.weapon_kind(X.WIDX.ITEM_WEAPON_AXE_TRAINING).k, 'melee', 'a TRAINING raw is melee, whatever its skill')
  T.eq(mil.weapon_kind(X.WIDX.ITEM_WEAPON_PICK).k, 'pick')
end)

T.test('FR-89: a refusal of the act (no training raws in the world) comes back as the answer; no policy is set', function()
  local W = mil_world{n = 50}
  local A = X.squad_of(W, 'A')
  arm(W, A, {{skills = {AXE = 8}, spec = 'ITEM_WEAPON_AXE_BATTLE'}})
  W.uniform_mode = 'fail'
  local r = W.inbox('squad.uniform', {squad = 'A', kind = 'training'})
  T.ok(not r.ok and r.msg:find('squad.uniform: squad_uniform not implemented', 1, true), r.msg)
  T.eq(weapon_subs(A, 0), {X.WIDX.ITEM_WEAPON_AXE_BATTLE}, 'the battle axe stays')
  W.uniform_mode = 'ok'
  T.ok(W.inbox('squad.uniform', {squad = 'A', kind = 'training'}).ok, 'and works once the act does')
end)


T.test('FR-89: a crossbow squad is refused (no training crossbow exists), whatever the skills of its soldiers', function()
  local W = mil_world{n = 50}
  local C = X.squad_of(W, 'C')
  T.ok(C ~= nil, 'military made squad C')
  arm(W, C, {{skills = {SWORD = 8}, spec = 'ITEM_WEAPON_SWORD_SHORT'}})
  local r = W.inbox('squad.uniform', {squad = 'C', kind = 'training'})
  T.ok(not r.ok and r.msg:find('crossbow squad', 1, true), r.msg)
end)


T.test('review: the training policy yields in a fight: a SIEGE gives the positions their real weapons back, PEACE the wooden ones again',
       function()
  local W = mil_world{n = 50}
  local A = X.squad_of(W, 'A')
  arm(W, A, {{skills = {AXE = 8}, spec = 'ITEM_WEAPON_AXE_BATTLE'}, {skills = {SWORD = 5}, spec = 'ITEM_WEAPON_SWORD_SHORT'}})
  T.ok(W.inbox('squad.uniform', {squad = 'A', kind = 'training'}).ok)
  T.eq(weapon_subs(A, 0), {X.WIDX.ITEM_WEAPON_AXE_TRAINING})
  W.set_mode('SIEGE')
  W.run(3600 * 3, {skip = 9})
  for pos = 0, 1 do
    for _, sub in ipairs(weapon_subs(A, pos)) do
      T.ok(sub < 0 or X.WEAPONS[sub + 1][1]:find('TRAINING', 1, true) == nil, 'no wooden weapon in a siege, pos ' .. pos)
    end
    T.ok(#weapon_subs(A, pos) > 0, 'the position keeps a weapon spec (individual choice)')
  end
  W.set_mode('PEACE')
  W.run(3600 * 3, {skip = 9})
  T.eq(weapon_subs(A, 0), {X.WIDX.ITEM_WEAPON_AXE_TRAINING}, 'back in PEACE the policy puts the wooden weapons on again')
end)


T.done()
