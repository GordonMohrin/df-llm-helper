-- NEU1 P4 (decision E1, growth follows safety; docs/v2/NEU1-wachstum.md):
--   (a) the growth ladder (readiness.growth_ladder): cap 30 until the first squad is armed and drink lies in the core, 50 until 6 fully
--       equipped + 70 % share + R0 passed + a linked lever in the core, 80 until 10 in metal, then no ladder limit; the halt is named
--       (POPCAP halt, GROWTH_HALT, ready.gh, pop.hold); nobody is evicted (the freeze keeps max-pop at the citizens); a step is given up only
--       after drop_days; no config section = the old rule
--   (b) the armour share and the first squad from fake units (military.kit_stats: fullr, metal, sq_n, sq_w)
--   (c) a sortie against up to 3 non-siege hostiles is never refused for armour while the squad has armed members (squad.sortie,
--       kill_lone, sortie_advice, the kept sortie); more hostiles, a great danger or no armed members: refused as before
local T = require('testlib')
local X = require('wp6_world')
local Z = X.Z

local ON = {on = true, base = 30, armed_cap = 50, ready_cap = 80, top_cap = 100, armed_min = 3, full_ready = 6, full_top = 10, share = 70,
            drink_d = 30, drop_days = 5}

---------------------------------------------------------------- (a) the ladder, pure
T.test('NEU1 P4: growth_ladder steps and halts in the documented order (fail closed on missing data)', function()
  X.world{n = 3}
  local R = require('dfllm.readiness')
  local function L(x) return R.growth_ladder(x, ON) end
  local g = L({})
  T.eq({g.tier, g.cap, g.next, g.halt}, {0, 30, 50, 'squad'}, 'nothing known: cap 30, the squad holds it')
  g = L({sq_n = 2, sq_w = 2, drink_d = 99})
  T.eq(g.halt, 'squad', 'two members are no squad (armed_min 3)')
  g = L({sq_n = 4, sq_w = 3, drink_d = 99})
  T.eq(g.halt, 'squad', 'one member without a weapon')
  T.ok(g.need:find('3 of 4', 1, true), g.need)
  g = L({sq_n = 4, sq_w = 4})
  T.eq({g.cap, g.halt}, {30, 'drink'}, 'no drink reading: fail closed')
  g = L({sq_n = 4, sq_w = 4, drink_d = 29})
  T.eq(g.halt, 'drink')
  g = L({sq_n = 4, sq_w = 4, drink_d = 30, n = 10, fullr = 5, lvl = 1, lever = true})
  T.eq({g.tier, g.cap, g.next, g.halt}, {1, 50, 80, 'full'})
  g = L({sq_n = 4, sq_w = 4, drink_d = 30, n = 10, fullr = 6, lvl = 1, lever = true})
  T.eq(g.halt, 'share', '6 of 10 = 60 % < 70 %')
  T.ok(g.need:find('6 of 10', 1, true), g.need)
  g = L({sq_n = 4, sq_w = 4, drink_d = 30, n = 8, fullr = 6, lvl = 0, lever = true})
  T.eq(g.halt, 'r0', '6 of 8 = 75 %: R0 not passed')
  g = L({sq_n = 4, sq_w = 4, drink_d = 30, n = 8, fullr = 6, lvl = 1})
  T.eq(g.halt, 'lever', 'no lever reading: fail closed')
  g = L({sq_n = 4, sq_w = 4, drink_d = 30, n = 8, fullr = 6, lvl = 1, lever = true, metal = 9})
  T.eq({g.tier, g.cap, g.next, g.halt}, {2, 80, 100, 'metal'})
  g = L({sq_n = 4, sq_w = 4, drink_d = 30, n = 12, fullr = 10, lvl = 2, lever = true, metal = 10})
  T.eq({g.tier, g.cap, g.halt}, {3, nil, nil}, 'every step passed: no ladder limit')
  g = L({sq_n = 4, sq_w = 4, drink_d = 30, n = 20, fullr = 10, lvl = 2, lever = true, metal = 10})
  T.eq({g.tier, g.halt}, {1, 'share'}, '10 of 20 soldiers = 50 %: back to cap 50 (the share counts all soldiers)')
end)

T.test('NEU1 P4: the success criterion: no input with fewer than 70 % fully equipped soldiers gets a cap above 50', function()
  X.world{n = 3}
  local R = require('dfllm.readiness')
  for n = 1, 30 do
    for fullr = 0, n do
      local g = R.growth_ladder({sq_n = 5, sq_w = 5, drink_d = 300, n = n, fullr = fullr, metal = fullr, lvl = 3, lever = true}, ON)
      if fullr * 100 < 70 * n then T.ok(g.cap ~= nil and g.cap <= 50, string.format('%d of %d -> %s', fullr, n, tostring(g.cap))) end
    end
  end
end)

---------------------------------------------------------------- (b) kit counts from fake units
T.test('NEU1 P4: military.kit_stats counts fullr (all armour + a real weapon), metal (metal body armour) and the first squad', function()
  local W = X.world{n = 50, training = false}
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  W.state()
  W.run(3600, {skip = 9})
  -- metal by the material token (the world's matinfo has no flags)
  local dec = dfhack.matinfo.decode
  dfhack.matinfo.decode = function(it)
    local m = dec(it)
    if m then m.material = {flags = {IS_METAL = tostring(it._mat):find('IRON', 1, true) ~= nil}} end
    return m
  end
  local A = X.squad_of(W, 'A')
  local ids = {}
  for i = 0, 9 do
    local o = A.positions[i].occupant
    if o >= 0 then ids[#ids + 1] = W.hfs[o].unit_id end
  end
  T.ok(#ids >= 3, 'squad A has 3+ soldiers: ' .. #ids)
  X.equip(W, ids[1], {mat = 'INORGANIC:IRON'})                                -- everything, iron
  X.equip(W, ids[2], {mat = 'CREATURE:COW:LEATHER'})                          -- everything, leather
  local wood = X.weapon(W, 'ITEM_WEAPON_AXE_TRAINING')
  X.equip(W, ids[3], {skip = {weapon = true}, mat = 'INORGANIC:IRON'})       -- armour + a training axe
  W.unit(ids[3]).inventory:insert('#', {item = wood, mode = df.inv_item_role_type.Weapon})
  local M = X.mod('military')
  M.KIT_TTL = 0
  local k = X.call(W, 'military', 'kit_stats')
  dfhack.matinfo.decode = dec
  T.eq({k.fullr, k.metal}, {2, 1}, 'fully equipped with a real weapon: 1 and 2; in metal: 1 (' .. T.show(k) .. ')')
  T.eq(k.full, 3, 'the old count takes the training axe as a weapon')
  T.eq(k.sq_n, #ids, 'every member of A')
  T.eq(k.sq_w, 2, 'members of A with a real weapon')
end)

---------------------------------------------------------------- (a) the ladder in the kernel
local AUDIT_OK = {ok = true, fails = {}, min_traps = 35, bypass = false, refuge_sep = true, civ_sep = true, caverns = true}
local SEALED = {tick = 1, sealed = 1, routes = 0, doors = {{id = 9, pos = {74, 70, 117}}}, open = {}}
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end

local function rworld(o)
  o = o or {}
  local W = X.world{units = X.citizens(o.n or 40, 1, {skills = {AXE = 6, SHIELD = 3}})}
  W.seal = {name = 'seal', every = {ticks = 600}, x = SEALED, rep = {}}
  function W.seal.entrance_doors(K) return W.seal.x end
  function W.seal.replaced(K) return W.seal.rep end
  function W.seal.state(K)
    return W.core_d and {alert = {want = 'Kern+', burrow = 'Kern+', tiles = 50, inside = 10, ok = 1, core_d = W.core_d}} or {}
  end
  W.econ, W.snap = X.economy(), X.snapshot()
  X.load(W, {'military', 'readiness'}, {W.econ, W.snap, X.runner('P5'), W.seal}, {'sense', 'threat', 'siege', 'gate'})
  local R = X.mod('readiness')
  R.CAPS = {[0] = 120, [1] = 120, [2] = 120, [3] = 250}
  R.DEF.worn_pct = 0
  W.K.cfg.decisions['D-01'] = 'A'
  W.set_plan({v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = 120, beauty = 'used_rooms'}})
  W.kit = o.kit or {n = 0, fullr = 0, metal = 0, sq_n = 0, sq_w = 0}
  X.mod('military').kit_stats = function(K)      -- (the state's mil.kit wants the old counts too)
    local k = {full = 0, armor = 0, weapon = 0, wood = 0, tr = 0}
    for key, v in pairs(W.kit) do k[key] = v end
    return k
  end
  W.lever = o.lever
  X.mod('gate').core_lever = function(K) return W.lever end
  W.core_d = o.core_d
  day(W)                                          -- the old ceiling is written first (an older fort)
  if o.growth ~= false then W.K.cfg.reflex = {v = 2, growth = o.growth or {on = true}} end
  day(W, 2)
  return W
end

local function popcaps(W)
  local r = {}
  for _, e in ipairs(W.find_events('POPCAP')) do r[#r + 1] = e end
  return r
end

T.test('NEU1 P4: an unarmed fort of 40 is held at its citizens (never evicted), the halt is named in POPCAP, GROWTH_HALT, ready.gh and pop.hold',
       function()
  local W = rworld{n = 40}
  local s = W.state()
  T.eq(s.ready.gh, {cap = 30, next = 50, halt = 'squad', need = s.ready.gh.need}, T.show(s.ready.gh))
  T.eq(s.pop.cap, 40, 'max-pop never under the citizens: the freeze holds it at 40, not 30')
  T.eq(s.pop.gate_cap, 30)
  T.ok(tostring(s.pop.hold):find('growth 30 (squad)', 1, true), tostring(s.pop.hold))
  local pc = popcaps(W)
  T.eq(pc[#pc].d.halt, 'squad', 'POPCAP carries the halt: ' .. T.show(pc[#pc].d))
  T.ok(pc[#pc].msg:find('held by squad', 1, true), pc[#pc].msg)
  local gh = W.find_events('GROWTH_HALT')
  T.ok(#gh >= 1 and gh[#gh].d.halt == 'squad' and gh[#gh].d.cap == 30, T.show(gh[#gh] and gh[#gh].d))
  -- armed squad, no drink in the core yet: the halt moves to drink, the cap stays
  W.kit = {n = 4, fullr = 0, metal = 0, sq_n = 4, sq_w = 4}
  day(W)
  T.eq(W.state().ready.gh.halt, 'drink')
  W.core_d = 45
  day(W, 2)                                       -- (the mock's view follows the state one day late)
  s = W.state()
  T.eq({s.ready.gh.cap, s.ready.gh.halt}, {50, 'full'}, T.show(s.ready.gh))
  T.eq(s.pop.cap, 50, 'max-pop rises to the step in PEACE')
  gh = W.find_events('GROWTH_HALT')
  T.eq(gh[#gh].d.cap, 50)
end)

T.test('NEU1 P4: a step is given up only after drop_days lower; a small fort grows to the step, not further', function()
  local W = rworld{n = 20, kit = {n = 4, fullr = 0, metal = 0, sq_n = 4, sq_w = 4}, core_d = 45}
  T.eq(W.state().pop.cap, 50)
  W.kit = {n = 4, fullr = 0, metal = 0, sq_n = 4, sq_w = 3}              -- one soldier lost his weapon
  day(W, 2)
  local s = W.state()
  T.eq({s.pop.gate_cap, s.ready.gh.halt}, {50, 'squad'}, 'two days lower: the step holds, the halt is named')
  day(W, 5)
  s = W.state()
  T.eq(s.pop.gate_cap, 30, 'after drop_days: back to 30')
  T.eq(s.pop.cap, 30, '20 citizens: max-pop 30 (above the citizens)')
end)

T.test('NEU1 P4: the lever comes from gate.core_lever; no growth section (or on=false) = the old rule', function()
  local W = rworld{n = 40, kit = {n = 8, fullr = 8, metal = 0, sq_n = 4, sq_w = 4}, core_d = 45}
  local R = X.mod('readiness')
  local lvl = R.level(W.K)
  local h = W.state().ready.gh.halt
  T.eq(h, lvl >= 1 and 'lever' or 'r0', 'the 50 step holds on r0 or lever (level ' .. lvl .. ')')
  local real = R.level
  R.level = function() return 1 end
  local g = R.growth_ladder({sq_n = 4, sq_w = 4, drink_d = 45, n = 8, fullr = 8, lvl = 1, lever = X.call(W, 'gate', 'core_lever')}, R.growth_conf(W.K))
  T.eq(g.halt, 'lever', 'gate says no lever')
  W.lever = true
  g = R.growth_ladder({sq_n = 4, sq_w = 4, drink_d = 45, n = 8, fullr = 8, lvl = 1, lever = X.call(W, 'gate', 'core_lever')}, R.growth_conf(W.K))
  T.eq(g.halt, 'metal', 'gate says a lever: the 80 step')
  R.level = real
  local W2 = rworld{n = 40, growth = false}
  local s = W2.state()
  T.eq(s.ready.gh, nil, 'no ladder without the config section')
  T.eq(s.pop.cap, 120, 'the old ceiling')
  local W3 = rworld{n = 40, growth = {on = false}}
  T.eq(W3.state().pop.cap, 120)
end)

---------------------------------------------------------------- (c) small fights
local function stubs()
  local sg = {name = 'siege', every = {ticks = 25}}
  function sg.so_conf(K) return {worn = 80, kill_near = 5, idle_ticks = 1200, hold_ticks = 4800, foe_cv = 10} end
  local rf = {name = 'reflex', every = {ticks = 10}}
  function rf.lone_ids(K) return nil, 'stale' end
  function rf.ignore(K, id, why) return true end
  local ca = {name = 'care', every = {ticks = 10}}
  function ca.deaths_recent(K) return 0 end
  return {sg, rf, ca}
end
-- units: the hostiles; armed: members of A that get a real weapon (no armour); small: the small_fight config (nil = on)
local function msetup(units, o)
  o = o or {}
  local u = X.citizens(50)
  for _, x in ipairs(units or {}) do u[#u + 1] = x end
  local W = X.world{units = u}
  local mods = stubs()
  local snap = X.snapshot()
  snap.groups = function(K, pts) local r = {}; for i in ipairs(pts) do r[i] = 1 end; return r end
  mods[#mods + 1] = snap
  mods[#mods + 1] = X.runner('P5')
  X.load(W, {'military'}, mods, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  if o.small ~= false then W.K.cfg.reflex = {v = 2, small_fight = o.small or {on = true}} end
  local A = X.squad_of(W, 'A')
  local n = 0
  for i = 0, 9 do
    local oc = A.positions[i].occupant
    if oc >= 0 and n < (o.armed or 3) then
      n = n + 1
      local it = X.item(W, 'WEAPON')
      W.unit(W.hfs[oc].unit_id).inventory:insert('#', {item = it, mode = df.inv_item_role_type.Weapon})
    end
  end
  W.K.set_mode('SIEGE', 'test')
  if o.mode ~= 'SIEGE' then W.K.set_mode('BREACH', 'test') end
  W.run(60, {skip = 9})
  return W
end
local function order(W, key) return X.squad_of(W, key).orders[0] end

T.test('NEU1 P4: BREACH, one goblin outside Kern+, squad A armed but without armour: squad.sortie goes (old: "not equipped")', function()
  local W = msetup{X.S.inv(150, 150, 150, Z)}
  local fit = X.call(W, 'military', 'unfit_text', 'A')
  T.ok(tostring(fit):find('is not equipped', 1, true), 'A is unfit by BUG-510: ' .. tostring(fit))
  local r = W.inbox('squad.sortie', {squad = 'A', target = {150, 150, 150}, unit = 150, approve = true})
  T.ok(r.ok, tostring(r.msg))
  T.eq(order(W, 'A').kind, 'kill')
  T.eq(order(W, 'A').units, {150})
  -- Run 16c i3 y379: a lone snatcher made a SIEGE; the same answer there
  local WS = msetup({X.S.inv(150, 150, 150, Z)}, {mode = 'SIEGE'})
  r = WS.inbox('squad.sortie', {squad = 'A', target = {150, 150, 150}, unit = 150, approve = true})
  T.ok(r.ok, 'SIEGE: ' .. tostring(r.msg))
  -- control: small_fight off -> the old refusal word for word
  local W2 = msetup({X.S.inv(150, 150, 150, Z)}, {small = {on = false}})
  r = W2.inbox('squad.sortie', {squad = 'A', target = {150, 150, 150}, unit = 150, approve = true})
  T.eq(r.ok, false)
  T.ok(tostring(r.msg):find('sortie refused: squad A is not equipped', 1, true), tostring(r.msg))
end)

T.test('NEU1 P4: refused as before with 4 hostiles in sight, a great danger, or fewer than 2 armed members', function()
  local W = msetup{X.S.inv(150, 150, 150, Z), X.S.inv(151, 151, 150, Z), X.S.inv(152, 152, 150, Z), X.S.inv(153, 153, 150, Z)}
  local r = W.inbox('squad.sortie', {squad = 'A', target = {150, 150, 150}, unit = 150, approve = true})
  T.eq(r.ok, false, '4 hostiles: a siege picture')
  local sm, why = X.call(W, 'military', 'small_fight', 'A')
  T.eq(sm, nil)
  T.ok(tostring(why):find('4 hostiles in sight', 1, true), tostring(why))
  local W2 = msetup({X.S.inv(150, 150, 150, Z)}, {armed = 1})
  r = W2.inbox('squad.sortie', {squad = 'A', target = {150, 150, 150}, unit = 150, approve = true})
  T.eq(r.ok, false, 'one armed member is no squad with weapons')
  local W3 = msetup{X.S.inv(150, 150, 150, Z)}
  W3.K.census.h.great = 1
  sm, why = X.call(W3, 'military', 'small_fight', 'A')
  T.eq(sm, nil)
  T.ok(tostring(why):find('great danger', 1, true), tostring(why))
end)

T.test('NEU1 P4: kill_lone starts with worn 0 %; sortie_advice recommends the small fight; a kept small sortie is not ended for worn', function()
  local W = msetup{X.S.inv(150, 78, 93, Z)}
  local M = X.mod('military')
  local adv = X.call(W, 'military', 'sortie_advice', 'A', {150})
  T.ok(adv.rec == true and adv.small == true, T.show(adv))
  T.ok(adv.txt:find('armour not required', 1, true), adv.txt)
  -- kill_lone: the census must show it inside (zone 2); the old answer was 'worn 0% < 80%'
  for _, e in ipairs(W.K.census.h.list) do e.zn = 2 end
  local lone = M.lone_of
  M.lone_of = function(K, ids) return ids end
  M.INSIDE_RATIO = 100                            -- (not the BUG-692 exception: the small fight alone)
  local ok, msg = X.call(W, 'military', 'kill_lone', {150}, 'reflex')
  T.ok(ok == true, tostring(msg))
  local so = M.sortie_of(W.K, 'A')
  T.ok(so and so.keep, 'kept against the posture: ' .. T.show(so))
  W.run(300, {skip = 9})
  T.ok(M.sortie_of(W.K, 'A') ~= nil, 'not ended for worn 0 %')
  for _, e in ipairs(W.find_events('SORTIE')) do T.ok(e.d.why ~= 'worn', 'no abort worn: ' .. e.msg) end
  M.lone_of, M.INSIDE_RATIO = lone, 3
  -- control: off -> refused for worn
  local W2 = msetup({X.S.inv(150, 78, 93, Z)}, {small = {on = false}})
  for _, e in ipairs(W2.K.census.h.list) do e.zn = 2 end
  M = X.mod('military')                           -- (the new world loaded a fresh module)
  M.INSIDE_RATIO = 100
  ok, msg = X.call(W2, 'military', 'kill_lone', {150}, 'reflex')
  M.INSIDE_RATIO = 3
  T.eq(ok, false, tostring(msg))
  T.ok(tostring(msg):find('worn', 1, true), tostring(msg))
end)

T.done()
