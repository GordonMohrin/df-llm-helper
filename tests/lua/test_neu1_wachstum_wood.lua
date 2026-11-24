-- NEU1 P4, verifier round: the growth ladder under the SHIPPED training policy (FR-89/FR-100: wooden training weapons in every melee hand
-- in PEACE/DRILL, the real ones back in an alert). The real military.kit_stats (no stub): a soldier on the policy holding a wooden weapon
-- counts as armed while a real melee weapon of the fort (census.i g_weapon minus the real ones in hand) waits for him. The cap rises
-- 30 -> 50 -> 80 in PEACE and stays after drop_days; with no real weapon in the fort it stays at 30 (fail closed)
local T = require('testlib')
local X = require('wp6_world')
local S = require('siege_world')
local Z = X.Z

local AUDIT_OK = {ok = true, fails = {}, min_traps = 35, bypass = false, refuge_sep = true, civ_sep = true, caverns = true}
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end

-- o.g_weapon: the census' real melee weapons; o.n citizens
local function world(o)
  local W = X.world{units = X.citizens(o.n or 40, 1, {skills = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}}), training = true}
  W.K.cfg.decisions['D-01'] = 'A'
  W.set_plan({v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = 120, beauty = 'used_rooms'}})
  W.seal = {name = 'seal', every = {ticks = 600}, x = {tick = 1, sealed = 1, routes = 0, doors = {{id = 9, pos = {74, 70, 117}}}, open = {}}}
  function W.seal.entrance_doors(K) return W.seal.x end
  function W.seal.replaced(K) return {} end
  function W.seal.state(K)
    return W.core_d and {alert = {want = 'Kern+', burrow = 'Kern+', tiles = 50, inside = 10, ok = 1, core_d = W.core_d}} or {}
  end
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  X.load(W, {'military', 'readiness'}, {X.economy(), X.snapshot(), runner, W.seal}, {'sense', 'threat', 'siege', 'gate'})
  local R = X.mod('readiness')
  R.CAPS = {[0] = 120, [1] = 120, [2] = 120, [3] = 250}
  R.OPEN_CONFIRM, R.DEF.worn_pct = 0, 0
  W.lever = false
  X.mod('gate').core_lever = function(K) return W.lever end           -- (package P5 builds the lever; its answer is read)
  -- the wooden training weapons the policy hands out, and the census' real ones
  for _ = 1, 30 do X.weapon(W, 'ITEM_WEAPON_AXE_TRAINING') end
  W.set_census('i', {tick = 0, g_weapon = o.g_weapon, g_body = 30, g_shield = 30, w_axe = 4, w_pick = 4})
  W.K.cfg.reflex = {v = 2, growth = {on = true}}
  -- metal by the material token (the world's matinfo has no flags)
  local dec = dfhack.matinfo.decode
  dfhack.matinfo.decode = function(it)
    local m = dec(it)
    if m then m.material = {flags = {IS_METAL = tostring(it._mat):find('IRON', 1, true) ~= nil}} end
    return m
  end
  W.undecode = function() dfhack.matinfo.decode = dec end
  day(W, 2)
  return W
end

-- every soldier: all armour in iron; the melee soldiers a wooden training weapon in hand (the policy's PEACE kit), no real weapon; the
-- crossbow squad (C) its crossbows (real weapons in hand: they take from the census' real ones)
local function kit_up(W)
  local n = 0
  for _, s in pairs(W.squads) do
    for _, p in ipairs(s.positions) do
      if p.occupant >= 0 then
        local uid = W.hfs[p.occupant].unit_id
        X.equip(W, uid, {skip = {weapon = true}, mat = 'INORGANIC:IRON'})
        local tok = s.alias == 'C' and 'ITEM_WEAPON_CROSSBOW' or 'ITEM_WEAPON_AXE_TRAINING'
        W.unit(uid).inventory:insert('#', {item = X.weapon(W, tok), mode = df.inv_item_role_type.Weapon})
        n = n + 1
      end
    end
  end
  X.mod('military').KIT_TTL = 0
  return n
end

local function kit(W) return X.call(W, 'military', 'kit_stats') end

T.test('NEU1 P4: shipped training policy, PEACE, wooden weapons in hand, real ones in stock: the cap rises 30 -> 50 -> 80 and stays', function()
  local W = world{g_weapon = 20}
  T.eq(W.K.mode(), 'PEACE')
  local n = kit_up(W)
  local k = kit(W)
  T.ok(k.tr >= 1, 'the squads are on the training policy: ' .. T.show(k))
  local xb = n - k.wood
  T.eq({k.n, k.weapon - k.wood}, {n, xb}, 'every melee soldier holds a wooden weapon, the crossbows theirs')
  T.ok(k.wood >= 6 and n < 10, 'soldiers ' .. n .. ', wooden ' .. k.wood)
  T.eq({k.wb, k.fullr, k.metal, k.sq_w}, {k.wood, n, n, k.sq_n}, 'every wooden weapon has a real one waiting: ' .. T.show(k))
  -- no drink in the core yet: cap 30
  day(W, 2)
  local s = W.state()
  T.eq({s.ready.gh.cap, s.ready.gh.halt}, {30, 'drink'}, T.show(s.ready.gh))
  T.eq(s.pop.gate_cap, 30)
  W.core_d = 45
  day(W, 2)
  X.audit(W, AUDIT_OK)
  day(W, 2)
  s = W.state()
  T.eq(s.ready.lvl, 1, 'R0 passed')
  T.eq({s.ready.gh.cap, s.ready.gh.halt}, {50, 'lever'}, T.show(s.ready.gh))
  T.eq(s.pop.cap, 50, 'PEACE: max-pop rises to 50')
  W.lever = true
  day(W, 2)
  s = W.state()
  T.eq({s.ready.gh.cap, s.ready.gh.halt}, {80, 'metal'}, n .. ' soldiers in metal < 10: ' .. T.show(s.ready.gh))
  T.eq(s.pop.cap, 80, 'PEACE: max-pop rises to 80')
  day(W, 8)                                             -- longer than drop_days (5)
  s = W.state()
  T.eq({W.K.mode(), s.ready.gh.cap, s.pop.cap}, {'PEACE', 80, 80}, 'it does not fall back')
  -- an alert longer than drop_days: ensure_weapons gives the positions their real weapons back, the soldiers still hold the wooden ones
  -- (the swap pending): the step holds, and max-pop is where it was when PEACE returns
  local seen = {}
  for _ = 1, 7 do                                       -- (threat ends an alert without hostiles: set again each day)
    W.K.set_mode('ALERT', 'test')
    W.run(600, {skip = 9})
    seen[#seen + 1] = W.K.mode() .. ':' .. tostring(W.state().ready.gh.cap)
    W.run(600, {skip = 9})
  end
  T.eq(seen[#seen], 'ALERT:80', 'the 7th day of the alert: ' .. table.concat(seen, ' '))
  W.K.set_mode('PEACE', 'test')
  day(W)
  s = W.state()
  T.eq({s.ready.gh.cap, s.pop.cap}, {80, 80}, 'after the alert: ' .. table.concat(seen, ' '))
  local caps = {}
  for _, e in ipairs(W.find_events('GROWTH_HALT')) do caps[#caps + 1] = e.d.cap end
  for i = 2, #caps do T.ok(caps[i] >= caps[i - 1], 'never down: ' .. table.concat(caps, ' ')) end
  T.eq({caps[1], caps[#caps]}, {30, 80}, table.concat(caps, ' '))
  W.undecode()
end)

T.test('NEU1 P4: the same fort with no real melee weapon (census g_weapon 0, or no census reading): the cap stays at 30 (fail closed)', function()
  local W = world{g_weapon = 0}
  local n = kit_up(W)
  W.core_d, W.lever = 45, true
  X.audit(W, AUDIT_OK)
  day(W, 8)
  local k = kit(W)
  T.eq({k.wb, k.fullr, k.sq_w}, {0, k.weapon - k.wood, 0}, 'only the crossbows count: ' .. T.show(k))
  T.ok(k.wood >= 3 and k.sq_n >= 3, T.show(k))
  local s = W.state()
  T.eq({s.ready.gh.cap, s.ready.gh.halt}, {30, 'squad'}, T.show(s.ready.gh))
  T.eq(s.pop.gate_cap, 30)
  -- 3 real weapons: only 3 wooden hands are backed (the first squad first)
  W.set_census('i', {tick = 0, g_weapon = 3, g_body = 30, g_shield = 30, w_axe = 4, w_pick = 4})
  k = kit(W)
  T.eq(k.wb, 3, T.show(k))
  -- no census reading at all
  W.set_census('i', nil)
  k = kit(W)
  T.eq({k.wb, k.sq_w}, {0, 0}, 'no census: nobody armed by a wooden weapon')
  -- growth.wood = false: real weapons in hand only (the first round's rule)
  W.set_census('i', {tick = 0, g_weapon = 20, g_body = 30, g_shield = 30, w_axe = 4, w_pick = 4})
  W.K.cfg.reflex.growth.wood = false
  k = kit(W)
  T.eq(k.wb, 0, 'growth.wood off')
  W.undecode()
end)

T.done()
