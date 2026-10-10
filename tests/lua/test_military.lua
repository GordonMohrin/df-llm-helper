-- WP6 military: squad sizing (D-12), phase gating, the read-only recruit filter, squad setup
-- (adopt/create, leaderless squads, uniform per bare position, routine by name), postures, kill
-- orders (killboxes only), sorties, KPIs (worn % per uniform spec, combat value, metal %, on station)
-- on k_mock (strict).
local T = require('testlib')
local X = require('wp6_world')
local json = require('dfllm.util.json')
local kmock_vec = require('dfllm.util.k_mock').vec
local Z = X.Z

local function mil() return X.mod('military') end
local function kpi(W) return X.call(W, 'military', 'kpi') end
local function names(acts, i)
  local r = {}
  for _, a in ipairs(acts) do r[#r + 1] = a.args[i or 1] end
  return r
end
local function boot(opts, extra)
  local W = X.world(opts)
  X.load(W, {'military'}, extra, (opts and opts.wp5) or {'sense'})
  return W
end
-- adults = n citizens; returns the world after the first upkeep (military runs on its first frame)
local function setup(n, opts, extra)
  opts = opts or {}
  opts.n = n
  local W = boot(opts, extra)
  W.run(9, {skip = 9})
  return W
end

---------------------------------------------------------------- sizing
T.test('share: D-12 15/20 by population, plan pct only raises it, other answers parsed', function()
  local W = boot{n = 5}
  local M, K = mil(), W.K
  T.eq(M.share(K, 52), 15)
  T.eq(M.share(K, 60), 20)
  K.cfg.decisions['D-12'] = '10/12'
  T.eq(M.share(K, 59), 15, 'the default plan pct 15 is a floor too')
  W.set_plan{v = 2, year = 3, phase_target = 'P5', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
             policy = {option = 'A', pop_ceiling = 55, beauty = 'none'}, military = {pct = 0, squads = {melee = 2, xbow = 1}, cv_min = 12}}
  T.eq(M.share(K, 59), 10)
  T.eq(M.share(K, 61), 12)
  K.cfg.decisions['D-12'] = 'garbage'
  T.eq(M.share(K, 30), 15)
  K.cfg.decisions['D-12'] = '15/20'
  W.set_plan{v = 2, year = 3, phase_target = 'P5', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
             policy = {option = 'A', pop_ceiling = 55, beauty = 'none'}, military = {pct = 25, squads = {melee = 2, xbow = 1}, cv_min = 12}}
  T.eq(M.share(K, 52), 25)
end)

T.test('targets: ceil(share x adults), >= 8 from 40 adults, crossbows ~30 %, melee split, <= 10 per squad', function()
  local W = boot{n = 5}
  local M, K = mil(), W.K
  local function t(adults, cit)
    W.set_census('u', {tick = 0, cit = cit or adults, adults = adults, ids = {}})
    local n, per = M.targets(K)
    return {n, per.A, per.B, per.C}
  end
  T.eq(t(20), {3, 2, 1, 0}, '< 4 soldiers: no crossbow squad yet')
  T.eq(t(30), {5, 2, 1, 2})
  T.eq(t(39), {6, 2, 2, 2})
  T.eq(t(40), {8, 3, 3, 2}, 'R2 floor of 8 from 40 adults')
  T.eq(t(44, 52), {8, 3, 3, 2})
  T.eq(t(50, 60), {10, 4, 3, 3}, '20 % from pop 60')
  T.eq(t(200), {30, 10, 10, 10}, 'three squads of at most 10')
  W.set_plan{v = 2, year = 3, phase_target = 'P5', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
             policy = {option = 'A', pop_ceiling = 55, beauty = 'none'}, military = {pct = 15, squads = {melee = 1, xbow = 0}, cv_min = 12}}
  T.eq(t(44), {8, 8, nil, nil}, 'plan: one melee squad only')
end)

T.test('phase gating: no squads before P2, only squad A in P2-P4, all from P5', function()
  local W = boot({n = 50}, {X.runner('P1')})
  local M, K = mil(), W.K
  local function per(phase)
    W.mods.runner.M.phase = phase
    W.state()
    W.set_census('u', {tick = 0, cit = 50, adults = 50, ids = {}})
    local n, p = M.targets(K)
    return {n, p.A, p.B, p.C}
  end
  T.eq(per('P1'), {0, nil, nil, nil})
  T.eq(per('P2'), {8, 8, nil, nil})
  T.eq(per('P4'), {8, 8, nil, nil})
  T.eq(per('P5'), {8, 3, 3, 2})
end)

---------------------------------------------------------------- recruits
T.test('recruits: read-only filter excludes tool details, tool labors, sole key labor, nobles, moods, children', function()
  local units = {
    X.cit(1, {skills = {AXE = 3, SHIELD = 2}}),                               -- best fighter
    X.cit(2, {attrs = {STRENGTH = 2000, TOUGHNESS = 1500}}),                  -- strong
    X.cit(3),                                                                 -- plain
    X.cit(4, {skills = {SWORD = 5}}),                                         -- builtin Miners member
    X.cit(5, {labors = {CUTWOOD = true}, skills = {AXE = 6}}),                -- woodcutter labor
    X.cit(6, {labors = {MASON = true}, skills = {MACE = 4}}),                 -- the only mason
    X.cit(7, {labors = {CARPENTER = true}}), X.cit(8, {labors = {CARPENTER = true}}),  -- two carpenters: fine
    X.cit(9, {noble = 'MANAGER', skills = {AXE = 9}}),                        -- noble
    X.cit(10, {noble = 'MILITIA_CAPTAIN'}),                                   -- squad positions may serve
    X.cit(11, {mood = 2}),                                                    -- strange mood
    X.cit(12, {adult = false}),                                               -- child
  }
  local wd = {{name = 'Miners', flags = {no_modify = true}, allowed_labors = {MINE = true}, assigned_units = kmock_vec{4}},
              {name = 'Haulers', flags = {no_modify = true}, allowed_labors = {HAUL_STONE = true}, assigned_units = kmock_vec{1, 2}}}
  local W = boot{units = units, work_details = wd}
  W.set_plan{v = 2, year = 3, phase_target = 'P5', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
             policy = {option = 'A', pop_ceiling = 55, beauty = 'none'}, military = {pct = 15, squads = {melee = 0, xbow = 0}, cv_min = 12}}
  W.run(9, {skip = 9})          -- sense publishes census.u; no squads wanted, so nobody is drafted
  local ids, why = mil().recruits(W.K)
  T.eq(ids, {1, 2, 3, 7, 8, 10})
  T.eq(why, {tool = 2, sole = 1, noble = 1, mood = 1, child = 1, squad = 0})
end)

---------------------------------------------------------------- setup
T.test('setup: squads A/B/C created with a leader, uniforms, Constant training by name, filled to target', function()
  local W = setup(50)
  local creates = X.acts(W, 'squad_create')
  T.eq(names(creates), {'A', 'B', 'C'})
  T.eq(creates[1].args[2].assignment_id, 10, 'the vacant MILITIA_COMMANDER assignment')
  T.ok(creates[1].args[2].leader ~= nil, 'leader passed to act')
  T.eq(creates[3].args[2].kind, 'xbow')
  local unis = X.acts(W, 'squad_uniform')
  T.eq(#unis, 3)
  T.eq(unis[1].args[2].mode, 'replace')
  T.eq(unis[1].args[2].items[6], {cat = 'shield', type = 'SHIELD'})
  T.eq(unis[3].args[2].items[6].subtype, 'ITEM_WEAPON_CROSSBOW')
  T.ok(unis[3].args[2].quiver and unis[3].args[2].ammo.subtype == 'ITEM_AMMO_BOLTS')
  T.eq(names(X.acts(W, 'squad_routine'), 2), {'Constant training', 'Constant training', 'Constant training'})
  T.eq(X.members(X.squad_of(W, 'A')), 3)
  T.eq(X.members(X.squad_of(W, 'B')), 3)
  T.eq(X.members(X.squad_of(W, 'C')), 2)
  for _, a in ipairs(W.acts) do
    T.ok(a.fn:match('^squad_') or a.fn == 'popcap' or a.fn == 'pull', 'unexpected act ' .. a.fn)
    if a.fn == 'squad_routine' then T.ok(a.args[2] ~= 'Off duty', 'never Off duty') end
  end
  T.eq(kpi(W).soldiers, 8)
  T.eq(kpi(W).squads, 3)
  local p = json.decode(W.persist_raw['dfllm.m.military'])
  T.eq(p.sq.A.uni, 1)
  T.eq(p.posture, 'TRAIN')
end)

T.test('setup is idempotent: a second upkeep changes nothing; reload keeps the squads', function()
  local W = setup(50)
  local n = #W.acts
  W.run(3600, {skip = 9})
  local new = {}
  for i = n + 1, #W.acts do
    if W.acts[i].by == 'military' and W.acts[i].fn ~= 'run' then new[#new + 1] = W.acts[i].fn end
  end
  T.eq(new, {}, 'no new squad acts (only the monthly uniform-unstick)')
  -- reload: same persist, same DF squads
  local raw = json.decode(W.persist_raw['dfllm.m.military'])
  package.loaded['dfllm.military'] = nil
  local M2 = require('dfllm.military')
  W.mods.military = nil
  for i, e in ipairs(W.entries) do if e.name == 'military' then table.remove(W.entries, i) end end
  W.persist_raw['dfllm.m.military'] = json.encode(raw)
  local before = #W.acts
  W.load(M2)
  W.run(3600, {skip = 9})
  for i = before + 1, #W.acts do T.ok(W.acts[i].fn ~= 'squad_create', 'no re-create after reload') end
end)

T.test('adopts a squad named A from the UI and keeps its uniform', function()
  local W = X.world{n = 50}
  local s = X.new_squad(W, 'a')
  X.seat(W, s, 0, 5)
  s.positions[0].equipment.uniform.body:insert('#', {item_type = 'ARMOR', item = -1, assigned = kmock_vec{}})
  X.load(W, {'military'}, nil, {'sense'})
  W.run(9, {skip = 9})
  T.eq(names(X.acts(W, 'squad_create')), {'B', 'C'})
  for _, a in ipairs(X.acts(W, 'squad_uniform')) do T.ok(a.args[1] ~= s.id, 'adopted uniform kept') end
  T.eq(mil().squads(W.K).A, s.id)
  T.eq(X.members(s), 3)
end)

T.test('S2: squad creation fails -> backoff, one DECISION_NEEDED, adopts squads made in the UI later', function()
  local W = X.world{n = 50, create_mode = 'fail'}
  X.load(W, {'military'}, nil, {'sense'})
  W.run(9, {skip = 9})
  T.eq(#X.acts(W, 'squad_create'), 3, 'A, B, C tried once')
  W.run(1200, {skip = 9})
  T.eq(#X.acts(W, 'squad_create'), 3, 'no retry before the backoff (and upkeep) is due')
  W.run(3600 * 3, {skip = 9})
  local dn = W.find_events('DECISION_NEEDED')
  T.eq(#dn, 1)
  T.eq(dn[1].d.id, 'squads')
  local n = #X.acts(W, 'squad_create')
  W.run(3600 * 4, {skip = 9})
  T.ok(#X.acts(W, 'squad_create') - n <= 6, 'backoff doubles')
  T.eq(#W.find_events('DECISION_NEEDED'), 1, 'once per boot')
  -- Gordon creates squad A in the UI
  local s = X.new_squad(W, 'A')
  X.seat(W, s, 0, 7)
  W.run(3600, {skip = 9})
  T.eq(mil().squads(W.K).A, s.id)
  T.ok(X.members(s) > 1, 'filled after adoption')
end)

T.test('uniform not implemented yet [S2]: retried with backoff until act accepts it', function()
  local W = X.world{n = 50, uniform_mode = 'fail'}
  X.load(W, {'military'}, nil, {'sense'})
  W.run(9, {skip = 9})
  T.eq(#X.acts(W, 'squad_uniform'), 3)
  T.eq(json.decode(W.persist_raw['dfllm.m.military']).sq.A.uni, 0)
  W.uniform_mode = 'ok'
  W.run(3600, {skip = 9})
  T.eq(#X.acts(W, 'squad_uniform'), 6)
  T.eq(json.decode(W.persist_raw['dfllm.m.military']).sq.A.uni, 1)
  W.run(3600, {skip = 9})
  T.eq(#X.acts(W, 'squad_uniform'), 6, 'set once')
end)

T.test('a created squad without a leader: not filled, no more creations, the UI action is named', function()
  local W = X.world{n = 50, create_mode = 'noleader'}
  X.load(W, {'military'}, nil, {'sense'})
  W.run(9, {skip = 9})
  T.eq(names(X.acts(W, 'squad_create')), {'A'}, 'B and C wait until A has a leader')
  T.eq(#X.acts(W, 'squad_add'), 0)
  W.run(3600 * 2, {skip = 9})
  T.eq(#X.acts(W, 'squad_create'), 1)
  local dn = W.find_events('DECISION_NEEDED')
  T.eq(#dn, 1, 'leaderless squads are reported once')
  T.eq(dn[1].d.id, 'squads')
  T.ok(dn[1].msg:find('commander', 1, true) and dn[1].msg:find('squad A', 1, true), dn[1].msg)
  T.ok(dn[1].d.q:find('B (melee), C (crossbows)', 1, true), dn[1].d.q)
  T.ok(#dn[1].msg <= 200, 'msg <= 200 bytes')
  -- Gordon appoints a leader for the squad dfllm made: it is filled, then B is created
  local A = X.squad_of(W, 'A')
  X.seat(W, A, 0, 40)
  W.run(3600, {skip = 9})
  T.eq(X.members(A), 3)
  T.eq(names(X.acts(W, 'squad_create')), {'A', 'B'})
end)

T.test('a UI squad A with a leader replaces the empty leaderless squad A dfllm created', function()
  local W = X.world{n = 50, create_mode = 'noleader'}
  X.load(W, {'military'}, nil, {'sense'})
  W.run(9, {skip = 9})
  local auto = X.squad_of(W, 'A')
  local ui = X.new_squad(W, 'A')                   -- made in the squad screen, leader seated
  X.seat(W, ui, 0, 33)
  W.run(3600, {skip = 9})
  T.eq(mil().squads(W.K).A, ui.id)
  T.eq(X.members(ui), 3, 'filled')
  T.eq(X.members(auto), 0)
  T.eq(json.decode(W.persist_raw['dfllm.m.military']).sq.A.id, ui.id)
  W.run(3600 * 3, {skip = 9})
  T.eq(mil().squads(W.K).A, ui.id, 'no switch back')
end)

T.test('fewer adults: extra soldiers are released one per upkeep in PEACE, never the leader', function()
  local W = setup(100)
  local A, B, Cq = X.squad_of(W, 'A'), X.squad_of(W, 'B'), X.squad_of(W, 'C')
  T.eq({X.members(A), X.members(B), X.members(Cq)}, {6, 6, 6}, 'leader + 5 adds per upkeep')
  W.run(3600, {skip = 9})
  T.eq({X.members(A), X.members(B), X.members(Cq)}, {7, 7, 6}, '20 % of 100: 7 + 7 + 6')
  local leaders = {}
  for _, s in ipairs({A, B, Cq}) do leaders[W.hfs[s.positions[0].occupant].unit_id] = true end
  -- 80 civilians die: 20 adults -> 3 soldiers wanted (A 2, B 1, C 0)
  local n = 0
  for _, u in ipairs(df.global.world.units.active) do
    if u.military.squad_id < 0 and n < 80 then W.kill(u.id); n = n + 1 end
  end
  W.run(3600, {skip = 9})
  T.eq(#X.acts(W, 'squad_remove'), 3, 'one per squad and upkeep')
  W.run(3600 * 4, {skip = 9})
  T.eq({X.members(A), X.members(B), X.members(Cq)}, {4, 3, 2}, 'down to target + 2')
  for _, r in ipairs(X.acts(W, 'squad_remove')) do T.ok(not leaders[r.args[2]], 'never a leader') end
  W.K.set_mode('ALERT', 'test')
  local before = #X.acts(W, 'squad_remove')
  W.run(3600, {skip = 9})
  T.eq(#X.acts(W, 'squad_remove'), before, 'never outside PEACE')
end)

---------------------------------------------------------------- postures
local function orders(s)
  local r = {}
  for _, o in ipairs(s.orders) do r[#r + 1] = o.kind .. (o.pos and string.format('@%d,%d,%d', o.pos.x, o.pos.y, o.pos.z) or '') end
  return table.concat(r, ';')
end

T.test('postures: READY_STATION, B2_HOLD, STATION_B1, TRAIN set routine and station orders', function()
  local W = setup(50)
  local A, B, Cq = X.squad_of(W, 'A'), X.squad_of(W, 'B'), X.squad_of(W, 'C')
  T.ok(X.call(W, 'military', 'posture', 'READY_STATION'))
  T.eq({A.cur_routine_idx, B.cur_routine_idx, Cq.cur_routine_idx}, {3, 3, 3}, 'Ready')
  T.eq({orders(A), orders(B), orders(Cq)}, {'station@51,44,10', 'station@51,44,10', 'station@51,28,11'})
  T.ok(X.call(W, 'military', 'posture', 'B2_HOLD'))
  T.eq({orders(A), orders(B), orders(Cq)}, {'station@51,62,10', 'station@51,62,10', 'station@51,62,10'})
  T.ok(X.call(W, 'military', 'posture', 'STATION_B1'))
  T.eq({A.cur_routine_idx, B.cur_routine_idx, Cq.cur_routine_idx}, {2, 2, 2}, 'training')
  T.eq({orders(A), orders(B), orders(Cq)}, {'station@51,44,10', '', ''})
  T.ok(X.call(W, 'military', 'posture', 'TRAIN'))
  T.eq({orders(A), orders(B), orders(Cq)}, {'', '', ''})
  local ok, err = X.call(W, 'military', 'posture', 'OFF_DUTY')
  T.eq(ok, false)
end)

T.test('posture is idempotent; upkeep repairs drift (lost order, routine changed in the UI)', function()
  local W = setup(50)
  local A = X.squad_of(W, 'A')
  X.call(W, 'military', 'posture', 'READY_STATION')
  local n = #W.acts
  X.call(W, 'military', 'posture', 'READY_STATION')
  T.eq(#W.acts, n, 'same posture: no acts')
  A.orders = kmock_vec{}
  A.cur_routine_idx = 0
  W.K.set_mode('SIEGE', 'test')
  W.run(700, {skip = 9})                      -- upkeep every 600 outside PEACE
  T.eq(A.cur_routine_idx, 3)
  T.eq(orders(A), 'station@51,44,10')
end)

T.test('no Ready routine: READY_STATION keeps Constant training (never Off duty)', function()
  local W = X.world{n = 50, routines = {'Off duty', 'Constant training'}}
  X.load(W, {'military'}, nil, {'sense'})
  W.run(9, {skip = 9})
  X.call(W, 'military', 'posture', 'READY_STATION')
  T.eq(X.squad_of(W, 'A').cur_routine_idx, 1)
  for _, a in ipairs(X.acts(W, 'squad_routine')) do T.eq(a.args[2], 'Constant training') end
end)

---------------------------------------------------------------- kill orders and sorties
T.test('kill: only visible hostiles in a killbox, not on a stair or shaft, ordered to the crossbow squad', function()
  local units = X.citizens(50)
  units[#units + 1] = X.S.inv(201, 50, 27, Z)      -- in K1
  units[#units + 1] = X.S.inv(202, 49, 26, Z)      -- K1, but on the military stair column
  units[#units + 1] = X.S.inv(203, 52, 29, Z)      -- K1, shaft tile
  units[#units + 1] = X.S.inv(204, 51, 5, Z)       -- outside every killbox
  local W = X.world{units = units}
  X.load(W, {'military'}, {X.snapshot({['52,29,10'] = '_'})}, {'sense'})
  W.K.set_mode('SIEGE', 'test')
  W.run(30, {skip = 9})
  local ok, n = X.call(W, 'military', 'kill', {201, 202, 203, 204, 999})
  T.eq({ok, n}, {true, 1})
  local Cq, A = X.squad_of(W, 'C'), X.squad_of(W, 'A')
  T.eq(Cq.orders[0].kind, 'kill')
  T.eq(Cq.orders[0].units, {201})
  T.eq(#X.acts(W, 'squad_order', function(a) return a.args[1] == A.id and a.args[2].kind == 'kill' end), 0, 'melee never')
  -- a re-asserted posture keeps the running kill order
  X.call(W, 'military', 'posture', 'TRAIN')
  X.call(W, 'military', 'posture', 'READY_STATION')
  local before = #W.acts
  X.call(W, 'military', 'kill', {201})
  X.call(W, 'military', 'posture', 'READY_STATION')
  T.eq(Cq.orders[0].kind, 'kill')
  T.eq({X.call(W, 'military', 'kill', {204})}, {false, 0})
  T.ok(#W.acts > before)
end)

T.test('squad.sortie needs approval, runs only in combat modes, kills in a killbox or moves to a pos', function()
  local units = X.citizens(50)
  units[#units + 1] = X.S.inv(201, 50, 27, Z)
  local W = X.world{units = units}
  X.load(W, {'military'}, {X.snapshot()}, {'sense'})
  W.run(9, {skip = 9})
  T.eq(W.inbox('squad.sortie', {squad = 'A', target = 'K1', approve = true}).ok, false, 'PEACE')
  W.K.set_mode('SIEGE', 'test')
  W.run(30, {skip = 9})
  T.eq(W.inbox('squad.sortie', {squad = 'A', target = 'K1'}).msg, 'approval required')
  local r = W.inbox('squad.sortie', {squad = 'A', target = 'K1', approve = true})
  T.ok(r.ok, r.msg)
  T.eq(X.squad_of(W, 'A').orders[0].units, {201})
  r = W.inbox('squad.sortie', {squad = 'B', target = {55, 30, Z}, approve = true})
  T.ok(r.ok, r.msg)
  T.eq(X.squad_of(W, 'B').orders[0].pos, {x = 55, y = 30, z = Z})
  T.eq(W.inbox('squad.sortie', {squad = 'B', target = 'K9', approve = true}).ok, false)
  T.eq(W.inbox('squad.sortie', {squad = 'Q', target = 'K1', approve = true}).ok, false)
  -- the next posture change ends the sortie
  X.call(W, 'military', 'posture', 'B2_HOLD')
  T.eq(X.squad_of(W, 'A').orders[0].kind, 'station')
end)

---------------------------------------------------------------- KPIs
T.test('worn %: worn assigned uniform items / uniform slots; assigned-only and unassigned do not count', function()
  local W = setup(50)
  local A = X.squad_of(W, 'A')
  local ids = {}
  for _, p in ipairs(A.positions) do if p.occupant >= 0 then ids[#ids + 1] = W.hfs[p.occupant].unit_id end end
  T.eq(#ids, 3)
  X.equip(W, ids[1])                               -- 7 of 7 worn
  X.equip(W, ids[2], {wear = false})               -- assigned, not worn: 0
  X.equip(W, ids[3], {assign = false})             -- worn, not assigned: 0
  W.run(30, {skip = 9})
  local k = kpi(W)
  T.eq(k.slots, 8 * 7 - 2, 'crossbows have no shield slot')
  T.eq(k.worn, (100 * 7 * 2 + k.slots) // (2 * k.slots))
  X.equip_all(W)
  W.run(30, {skip = 9})
  T.eq(kpi(W).worn, 100, 'extra worn items never push worn above the slots')
end)

T.test('worn % counts uniform specs: paired gloves/shoes and orphan assigned items do not inflate it', function()
  local W = setup(6)                               -- 15 % of 6 adults: one soldier, the leader of A
  T.eq(kpi(W).soldiers, 1)
  local A = X.squad_of(W, 'A')
  local lead = W.hfs[A.positions[0].occupant].unit_id
  -- body, pants, 2 gloves, 2 shoes, weapon; no helm, no shield; 2 orphan helms in assigned_items
  X.equip(W, lead, {pairs = true, skip = {head = true, shield = true}, orphans = 2})
  W.run(30, {skip = 9})
  local k = kpi(W)
  T.eq({k.slots, k.specs, k.worn}, {7, 7, 71}, '5 of 7 specs filled')
end)

T.test('worn %: an occupied position without uniform specs counts as missing; the uniform goes to bare positions', function()
  local W = X.world{n = 50}
  local s = X.new_squad(W, 'A')
  X.seat(W, s, 0, 5)
  X.load(W, {'military'}, nil, {'sense'})
  local M = mil()
  X.set_uniform(s, {positions = {0}, items = M.UNIFORM.melee.items})    -- chosen in the UI, leader only
  local ui_spec = s.positions[0].equipment.uniform.body[0]
  W.set_plan{v = 2, year = 3, phase_target = 'P5', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
             policy = {option = 'A', pop_ceiling = 55, beauty = 'none'}, military = {pct = 15, squads = {melee = 1, xbow = 0}, cv_min = 12}}
  W.run(9, {skip = 9})
  T.eq(X.members(s), 6, 'leader + 5')
  T.eq(#X.acts(W, 'squad_uniform'), 0, 'the leader had a uniform when it was checked')
  X.equip(W, 5)
  W.run(30, {skip = 9})
  local k = kpi(W)
  T.eq({k.slots, k.specs, k.worn}, {42, 7, 17}, '1 equipped leader + 5 soldiers without a uniform')
  W.run(3600, {skip = 9})
  local u = X.acts(W, 'squad_uniform')
  T.eq(#u, 1)
  T.eq(u[1].args[2].positions, {1, 2, 3, 4, 5}, 'only the bare occupied positions')
  T.eq(u[1].args[2].items, M.UNIFORM.melee.items)
  T.ok(s.positions[0].equipment.uniform.body[0] == ui_spec, 'the UI uniform of the leader is kept')
  T.eq(M.UNIFORM.melee.positions, nil, 'the template is not modified')
  T.eq(X.members(s), 8)
  W.run(3600, {skip = 9})
  u = X.acts(W, 'squad_uniform')
  T.eq(#u, 2)
  T.eq(u[2].args[2].positions, {6, 7}, 'the members added last upkeep')
  W.run(3600, {skip = 9})
  T.eq(#X.acts(W, 'squad_uniform'), 2, 'every occupied position has a uniform')
  T.eq(json.decode(W.persist_raw['dfllm.m.military']).sq.A.uni, 1)
end)

T.test('combat value per soldier, metal % (iron/steel body armor), soldiers on station', function()
  local units = {}
  for i = 1, 50 do units[i] = X.cit(i, {skills = {AXE = (i % 3) * 2, SHIELD = 2, ARMOR = 1, DODGING = 3, CROSSBOW = 1}}) end
  local W = X.world{units = units}
  X.load(W, {'military'}, nil, {'sense'})
  W.run(9, {skip = 9})
  T.eq(kpi(W).cv, 10, 'the 8 best fighters: axe 4 + shield 2 + armor 1 + dodging 3')
  local A = X.squad_of(W, 'A')
  local lead = W.hfs[A.positions[0].occupant].unit_id
  X.equip(W, lead, {mat = 'INORGANIC:STEEL'})
  local Cq = X.squad_of(W, 'C')
  X.equip(W, W.hfs[Cq.positions[0].occupant].unit_id, {mat = 'INORGANIC:BRONZE'})
  W.run(30, {skip = 9})
  T.eq(kpi(W).metal_pct, 13, '1 of 8 in steel (bronze does not count)')
  X.call(W, 'military', 'posture', 'READY_STATION')
  W.move(lead, 52, 45, Z)
  W.run(30, {skip = 9})
  T.eq(kpi(W).on_station, 1)
  W.run(3600, {skip = 9})
  local s = W.state().mil
  T.eq(s.soldiers, 8)
  T.eq(s.metal_pct, 13)
  for _, key in ipairs({'squads', 'soldiers', 'worn', 'cv', 'metal_pct', 'on_station'}) do
    T.ok(math.type(s[key]) == 'integer', key .. ' integer')
  end
  T.eq(s.slots, nil, 'state has exactly the contract keys')
end)

T.test('uniform-unstick monthly in PEACE with soldiers only (allowlisted args)', function()
  local W = setup(50)
  W.run(3600 * 10, {skip = 9})
  local runs = X.acts(W, 'run')
  T.ok(#runs >= 1 and #runs <= 2, 'monthly: ' .. #runs)
  T.eq({runs[1].args[1], runs[1].args[2], runs[1].args[3], runs[1].args[4]}, {'uniform-unstick', '--all', '--drop', '--free'})
  local n = #runs
  W.K.set_mode('SIEGE', 'test')
  W.run(33600 * 2, {skip = 9})
  T.eq(#X.acts(W, 'run'), n, 'not outside PEACE')
end)

T.done()
