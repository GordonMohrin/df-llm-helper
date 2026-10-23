-- Package A3 (military): BUG-050 the monthly uniform-unstick no longer strips the army, FR-71 militia windows per squad,
-- BUG-052 on_station (radius, breakdown, re-assert), early squads for a big fort that never left P0/P1 (BUG-051).
-- Fixtures mirror the live notes (bugs/RUN11-offene-bugs-und-FR.md 53, 64, 23).
local T = require('testlib')
local X = require('wp6_world')
local kmock_vec = require('dfllm.util.k_mock').vec
local Z = X.Z

local function mil() return X.mod('military') end
local function boot(opts, extra)
  local W = X.world(opts)
  local mods, own = {}, false
  for _, m in ipairs(extra or {}) do mods[#mods + 1] = m; if m.name == 'runner' then own = true end end
  if not own and not (opts and opts.phase == false) then mods[#mods + 1] = X.runner((opts and opts.phase) or 'P5') end
  X.load(W, {'military'}, mods, (opts and opts.wp5) or {'sense'})
  W.state()
  return W
end
local function setup(n, opts, extra)
  opts = opts or {}
  opts.n = n
  local W = boot(opts, extra)
  W.run(9, {skip = 9})
  return W
end
local function kpi(W) return X.call(W, 'military', 'kpi') end
local function unsticks(W)
  local r = {}
  for _, a in ipairs(X.acts(W, 'run')) do
    if a.args[1] == 'uniform-unstick' then r[#r + 1] = table.concat(a.args, ' ', 2) end
  end
  return r
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if l.msg:find(pat) then return l end end
end
local function leader_of(W, alias)
  local s = X.squad_of(W, alias)
  return W.hfs[s.positions[0].occupant].unit_id
end
-- the soldier keeps the helmet he wears but no head spec holds it: the conflict uniform-unstick exists for
local function conflict(W, uid)
  local u = W.unit(uid)
  local s = W.squads[u.military.squad_id]
  for _, p in ipairs(s.positions) do
    if p.occupant == u.hist_figure_id then
      for _, sp in ipairs(p.equipment.uniform.head) do sp.assigned = kmock_vec{} end
    end
  end
end

---------------------------------------------------------------- BUG-050
T.test('BUG-050: the monthly unstick drops nothing by default: uniform-unstick --all --free', function()
  local W = setup(50)
  W.run(3600 * 10, {skip = 9})
  local u = unsticks(W)
  T.ok(#u >= 1, 'nobody wears his kit: the unstick runs')
  for _, a in ipairs(u) do T.eq(a, '--all --free', 'never --drop') end
end)

T.test('BUG-050: an army with every uniform slot filled is left alone (nothing is stuck)', function()
  local W = setup(50)
  W.run(3600 * 2, {skip = 9})
  X.equip_all(W)
  W.run(100, {skip = 9})
  T.eq(kpi(W).worn, 100)
  local n = #unsticks(W)
  W.run(33600 * 4, {skip = 60})
  T.eq(#unsticks(W), n, 'no unstick while worn is 100 %')
end)

T.test('BUG-050: --drop is an opt-in, and only after plain runs left a proven conflict standing', function()
  local W = setup(50)
  W.K.cfg.baseline.military = {unstick = {drop = true}}
  W.run(3600 * 2, {skip = 9})                      -- the first run (nobody wears anything yet): plain, no conflict
  X.equip_all(W)
  conflict(W, leader_of(W, 'A'))
  W.run(100, {skip = 9})
  T.ok(kpi(W).worn < 100, 'one head slot is empty')
  T.eq(mil().conflicts(W.K), 1, 'one soldier wears a helmet no head spec holds')
  W.run(33600 * 6, {skip = 60})
  local u = unsticks(W)
  T.ok(#u >= 6, 'runs: ' .. #u)
  T.eq(u[1], '--all --free', 'the first run, before the gear')
  T.eq({u[2], u[3]}, {'--all --free', '--all --free'}, 'drop_after (2) plain runs with the conflict first')
  T.eq(u[4], '--all --drop --free', 'then --drop once')
  T.eq({u[5], u[6]}, {'--all --free', '--all --free'}, 'and plain again')
  T.ok(logged(W, 'uniform%-unstick %-%-drop: 1 soldiers keep an armor piece no spec holds after 2 plain runs'))
end)

T.test('BUG-050: drop = false (the default) never drops, even with a conflict standing for months', function()
  local W = setup(50)
  W.run(3600 * 2, {skip = 9})
  X.equip_all(W)
  conflict(W, leader_of(W, 'A'))
  W.run(33600 * 6, {skip = 60})
  local u = unsticks(W)
  T.ok(#u >= 5)
  for _, a in ipairs(u) do T.eq(a, '--all --free') end
end)

T.test('BUG-050: no unstick in a lockdown or with a hostile in sight', function()
  local W = setup(50)
  local K = W.K
  local call, lock = K.call, true
  K.call = function(mod, fn, ...)
    if mod == 'reflex' and fn == 'holding' and lock then return true, 'arrival' end
    return call(mod, fn, ...)
  end
  W.run(33600 * 3, {skip = 60})
  T.eq(unsticks(W), {}, 'a lockdown holds: no unstick')
  T.eq(mil().danger(K), 'lockdown')
  lock = false
  T.eq(mil().danger(K), nil)
  local h = K.census.h
  K.census.h = {vis = 2, tick = K.now().tick}
  T.eq(mil().danger(K), 'hostile')
  K.census.h = h
  W.run(3600 * 2, {skip = 60})
  T.ok(#unsticks(W) >= 1, 'quiet again: the unstick runs')
  K.set_mode('ALERT', 'test')
  T.eq(mil().danger(K), 'mode ALERT')
end)

T.test('BUG-050: the worn % a day and a week after a run is logged (what the command did)', function()
  local W = setup(50)
  W.run(3600 * 2, {skip = 9})
  X.equip_all(W)
  conflict(W, leader_of(W, 'A'))
  W.run(33600 * 2, {skip = 30})
  T.ok(logged(W, 'uniform%-unstick %d+ ticks ago %(%-%-all %-%-free%): worn %d+%% before, %d+%% now'),
       'kern.log names the worn % before and after')
end)

---------------------------------------------------------------- FR-71
local function routines_for(W, month, posture)
  df.global.cur_year_tick = month * 33600
  mil().posture(W.K, posture or 'TRAIN', true)
  local last = {}
  for _, a in ipairs(X.acts(W, 'squad_routine')) do last[a.args[1]] = a.args[2] end
  return {A = last[X.squad_of(W, 'A').id], B = last[X.squad_of(W, 'B').id], C = last[X.squad_of(W, 'C').id]}
end

T.test('FR-71: the default config keeps the old behaviour: B trains in months 9-11, A and C are free then', function()
  local W = setup(50)
  local c = mil().conf(W.K)
  T.eq(c.militia, {B = {[9] = true, [10] = true, [11] = true}}, 'M.MILITIA is a table squad key -> months')
  T.eq(c.free, {[9] = true, [10] = true, [11] = true})
  T.eq(routines_for(W, 10), {A = 'Off duty', B = 'Constant training', C = 'Off duty'})
  T.eq(routines_for(W, 2), {A = 'Constant training', B = 'Off duty', C = 'Constant training'})
end)

T.test('FR-71: two militia squads rotate in their own windows (B in months 9-11, C in months 3-5)', function()
  local W = setup(50)
  W.K.cfg.baseline.military = {militia = {B = {9, 10, 11}, C = {3, 4, 5}}, free_months = {9, 10, 11}}
  T.eq(routines_for(W, 10), {A = 'Off duty', B = 'Constant training', C = 'Off duty'}, 'window of B')
  T.eq(routines_for(W, 4), {A = 'Constant training', B = 'Off duty', C = 'Constant training'}, 'window of C')
  T.eq(routines_for(W, 1), {A = 'Constant training', B = 'Off duty', C = 'Off duty'}, 'nobody of the militia')
  T.eq(routines_for(W, 4, 'READY_STATION').B, 'Ready', 'an alert posture overrides the windows')
end)

T.test('FR-71: without free_months the elite is free in the union of the militia windows', function()
  local W = setup(50)
  W.K.cfg.baseline.military = {militia = {B = {9, 10, 11}, C = {3, 4, 5}}}
  T.eq(routines_for(W, 4), {A = 'Off duty', B = 'Off duty', C = 'Constant training'})
  T.eq(routines_for(W, 7), {A = 'Constant training', B = 'Off duty', C = 'Off duty'})
  T.eq(routines_for(W, 10), {A = 'Off duty', B = 'Constant training', C = 'Off duty'})
end)

T.test('FR-71: a bad militia table falls back to the default; an empty one makes every squad elite', function()
  local W = setup(50)
  W.K.cfg.baseline.military = {militia = {B = {9, 99}}, free_months = 'x'}
  T.eq(routines_for(W, 10), {A = 'Off duty', B = 'Constant training', C = 'Off duty'}, 'defaults')
  W.K.cfg.baseline.military = {militia = {}, free_months = {9, 10, 11}}
  T.eq(routines_for(W, 10), {A = 'Off duty', B = 'Off duty', C = 'Off duty'}, 'all elite: free in 9-11')
  T.eq(routines_for(W, 2), {A = 'Constant training', B = 'Constant training', C = 'Constant training'})
end)

T.test('FR-71: a window opening or closing is logged with the squad size and the citizens', function()
  local W = setup(50)
  df.global.cur_year_tick = 8 * 33600 + 20000
  W.run(3600 * 2, {skip = 9})
  T.eq(logged(W, 'militia squad B on duty'), nil, 'month 8: the window is shut')
  W.run(33600, {skip = 60})
  T.ok(logged(W, 'militia squad B on duty %(months 9%-11%): %d+ members, %d+ citizens'), 'the window of B opened')
end)

---------------------------------------------------------------- BUG-052
local function squad_units(W, alias)
  local s, r = X.squad_of(W, alias), {}
  for _, p in ipairs(s.positions) do if p.occupant >= 0 then r[#r + 1] = W.hfs[p.occupant].unit_id end end
  return r
end
-- three squads of 10, 10, 9 (150 citizens); the posture READY_STATION puts squad A at the melee station 51,44
local function station_world(opts)
  local W = setup(150, opts)
  W.run(3700, {skip = 9})
  X.equip_all(W)
  X.call(W, 'military', 'posture', 'READY_STATION', true)
  return W
end

T.test('BUG-052: the radius around the station grows with the squad: 10 soldiers stand up to 5 tiles away, not 6', function()
  local W = station_world()
  local A = squad_units(W, 'A')
  T.eq(#A, 10)
  T.eq(mil().station_radius(10, 3), 5)
  T.eq(mil().station_radius(4, 3), 3)
  T.eq(mil().station_radius(1, 3), 3)
  for _, id in ipairs(squad_units(W, 'B')) do W.move(id, 51, 44, Z - 1) end
  for _, id in ipairs(squad_units(W, 'C')) do W.move(id, 51, 44, Z - 1) end
  for i, id in ipairs(A) do W.move(id, i <= 8 and 56 or 57, 44, Z) end      -- 8 at distance 5, 2 at distance 6
  W.run(30, {skip = 9})
  T.eq(kpi(W).on_station, 8)
  W.K.cfg.baseline.military = {station_r = 1}                                 -- 1 + 2 = 3 tiles
  W.run(30, {skip = 9})
  T.eq(kpi(W).on_station, 0)
  W.K.cfg.baseline.military = {station_r = 4}                                 -- 4 + 2 = 6 tiles
  W.run(30, {skip = 9})
  T.eq(kpi(W).on_station, 10)
end)

T.test('BUG-052: kpi.off says why soldiers are off their station: equip, hurt, level, far', function()
  local W = station_world()
  df.job_type.PickupEquipment = 77
  local A, B, C = squad_units(W, 'A'), squad_units(W, 'B'), squad_units(W, 'C')
  for _, id in ipairs(B) do W.move(id, 51, 44, Z) end
  for _, id in ipairs(C) do W.move(id, 51, 28, Z + 1) end                     -- the crossbows stand in the gallery
  for _, id in ipairs(A) do W.move(id, 51, 44, Z) end
  W.unit(A[1]).job = {current_job = {job_type = 77}}                          -- picking up his kit
  W.unit(A[2]).body = {wounds = kmock_vec{{}}}                                -- wounded
  W.move(A[1], 80, 90, Z)
  W.move(A[2], 80, 90, Z)
  W.move(A[3], 51, 44, Z - 1)                                                 -- on another level
  W.move(A[4], 80, 90, Z)                                                     -- far away
  W.run(30, {skip = 9})
  local k = kpi(W)
  T.eq(k.off, {equip = 1, hurt = 1, level = 1, far = 1})
  T.eq(k.on_station, k.soldiers - 4)
end)

T.test('BUG-052: a posture that names a station nobody found counts every soldier off it (nost); TRAIN has no breakdown', function()
  local man = require('siege_world').manifest()
  man.stations = nil
  local W = setup(50, {manifest = man})
  X.call(W, 'military', 'posture', 'READY_STATION', true)
  W.run(30, {skip = 9})
  local k = kpi(W)
  T.eq(k.off, {nost = k.soldiers})
  T.eq(k.on_station, 0)
  X.call(W, 'military', 'posture', 'TRAIN', true)
  W.run(30, {skip = 9})
  T.eq(kpi(W).off, nil, 'no station wanted, no breakdown')
end)

T.done()
