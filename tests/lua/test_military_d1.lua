-- Package D1 (military): FR-79 the kernel rotates the citizens through the militia by itself (Gordon 2026-10-23, note 67 of
-- bugs/RUN11-offene-bugs-und-FR.md, the open part of note 64) and BUG-076 (squad refill: the backoff never reset, one refused
-- unit blocked the whole refill). Fixtures: a fort of 60 with squads A (melee), B (melee, the militia in months 9-11)
-- and C (crossbows) over four game years; default config unless a test sets W.K.cfg.baseline.military.
local T = require('testlib')
local X = require('wp6_world')
local json = require('dfllm.util.json')
local kmock = require('dfllm.util.k_mock')
local kmock_vec = kmock.vec
local Z = X.Z

local YEAR, MONTH, DAY = 403200, 33600, 1200
local function mil() return X.mod('military') end
local function abs(W) return df.global.cur_year * YEAR + df.global.cur_year_tick end
-- run to year y, month m, day d (0-based)
local function run_to(W, y, m, d)
  local dt = y * YEAR + m * MONTH + (d or 0) * DAY - abs(W)
  assert(dt >= 0, 'run_to goes back in time')
  W.run(dt, {skip = 600})
end
local function boot(n, opts, extra)
  opts = opts or {}
  opts.n = n
  local W = X.world(opts)
  local mods = {}
  for _, m in ipairs(extra or {}) do mods[#mods + 1] = m end
  mods[#mods + 1] = X.runner('P5')
  X.load(W, {'military'}, mods, {'sense'})
  W.state()
  return W
end
-- 60 citizens, month 5 of year 3 (outside the window 9-11), the squads staffed
local function fort(n, opts, extra)
  opts = opts or {}
  opts.ytick = opts.ytick or (5 * MONTH + 100)
  local W = boot(n or 60, opts, extra)
  W.run(9, {skip = 9})
  W.run(3600 * 4, {skip = 600})
  return W
end
local function seats(W, alias)                    -- unit ids of the squad: leader first, then the members
  local s, r = X.squad_of(W, alias), {}
  for i = 0, 9 do
    local hf = s.positions[i].occupant
    if hf >= 0 then r[#r + 1] = W.hfs[hf].unit_id end
  end
  return r
end
local function members_of(W, alias)               -- without the leader, sorted
  local r = seats(W, alias)
  table.remove(r, 1)
  table.sort(r)
  return r
end
local function leader_of(W, alias) return seats(W, alias)[1] end
local function overlap(a, b)
  local set, n = {}, 0
  for _, x in ipairs(a) do set[x] = true end
  for _, x in ipairs(b) do if set[x] then n = n + 1 end end
  return n
end
local function persisted(W) return json.decode(W.persist_raw['dfllm.m.military']) end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat) then return l end end
end
local function rotated(W) return W.find_events('MILITIA_ROTATED') end
local function info(W, key)
  local m = X.call(W, 'military', 'state')
  return m.mil and m.mil.rot and m.mil.rot[key]
end
-- acts of one kind since index n
local function acts_since(W, n, pred)
  local r = {}
  for i = n + 1, #W.acts do if not pred or pred(W.acts[i]) then r[#r + 1] = W.acts[i] end end
  return r
end

---------------------------------------------------------------- the cohort changes at the close of the window
T.test('FR-79: squad B keeps its members through the window 9-11 and swaps them at the close (month 0)', function()
  local W = fort()
  local B0 = members_of(W, 'B')
  T.eq(#B0, 3, 'squad B: leader + 3 members at 60 citizens')
  local lead = leader_of(W, 'B')
  run_to(W, 3, 11, 27)                                     -- the whole window passes
  T.eq(members_of(W, 'B'), B0, 'nobody leaves during the window')
  T.eq(#rotated(W), 0)
  run_to(W, 4, 0, 10)                                      -- the window closed in month 0
  local B1 = members_of(W, 'B')
  T.eq(#B1, 3)
  T.eq(overlap(B0, B1), 0, 'the next cohort is three other citizens')
  T.eq(leader_of(W, 'B'), lead, 'the leader (the militia captain) stays')
  local ev = rotated(W)
  T.eq(#ev, 1)
  T.eq({ev[1].d.squad, ev[1].d.out, ev[1].d.into, ev[1].d.win, ev[1].d.edge}, {'B', 3, 3, '9-11', 0})
  T.ok(logged(W, 'militia squad B rotated: 3 out, 3 in'), 'kern.log names the turnover')
  local p = persisted(W)
  for _, id in ipairs(B0) do T.eq(p.served[tostring(id)], 1, 'the old members served one window') end
  for _, id in ipairs(B1) do T.eq(p.served[tostring(id)], nil, 'the new ones have not served yet') end
end)

T.test('FR-79: elite squads A and C never take part: their members stay in the year of the turnover', function()
  local W = fort()
  local A0, C0 = seats(W, 'A'), seats(W, 'C')
  local B0 = members_of(W, 'B')
  run_to(W, 4, 1, 0)
  T.eq(overlap(B0, members_of(W, 'B')), 0, 'while squad B was turned over')
  T.eq(seats(W, 'A'), A0)
  T.eq(seats(W, 'C'), C0)
  for _, id in ipairs(members_of(W, 'B')) do
    T.eq(overlap({id}, A0), 0, 'nobody of A joined B')
    T.eq(overlap({id}, C0), 0, 'nobody of C joined B')
  end
end)

T.test('FR-79: the turnover touches no item: only squad_remove, squad_add and the squad uniform for bare positions', function()
  local W = fort()
  W.K.cfg.baseline.military = {unstick = {on = false}}      -- (the monthly uniform-unstick of BUG-050 is not the turnover)
  X.equip_all(W)
  W.run(100, {skip = 9})
  run_to(W, 3, 11, 27)
  local n = #W.acts
  run_to(W, 4, 0, 10)
  T.ok(#rotated(W) == 1, 'the turnover ran')
  local fns = {}
  for _, a in ipairs(acts_since(W, n, function(a) return a.by == 'military' end)) do fns[a.fn] = (fns[a.fn] or 0) + 1 end
  T.eq(fns.squad_remove, 3)
  T.eq(fns.squad_add, 3)
  for fn in pairs(fns) do
    T.ok(fn == 'squad_remove' or fn == 'squad_add' or fn == 'squad_uniform' or fn == 'squad_order' or fn == 'squad_routine',
         'unexpected act ' .. fn)
  end
  T.eq(fns.run, nil, 'no uniform-unstick, no --drop')
  T.eq(fns.squad_unequip, nil, 'no unequip')
  T.eq(fns.item_flag, nil, 'no item touched')
end)

---------------------------------------------------------------- no turnover: siege, lockdown, hostile, drill
local function waits(case, setup, teardown)
  T.test('FR-79: no turnover ' .. case .. '; it runs once that is over (the off months give it time)', function()
    local W = fort()
    local B0 = members_of(W, 'B')
    run_to(W, 3, 11, 20)
    local undo = setup(W)
    run_to(W, 4, 0, 25)
    T.eq(members_of(W, 'B'), B0, 'nothing changed ' .. case)
    T.eq(#rotated(W), 0)
    T.ok(logged(W, 'the turnover at the close of month 0 waits'), 'kern.log says it waits')
    local i = info(W, 'B')
    T.ok(i and i.why and i.why:find('held:', 1, true), 'state says why: ' .. tostring(i and i.why))
    teardown(W, undo)
    run_to(W, 4, 2, 0)
    T.eq(overlap(B0, members_of(W, 'B')), 0, 'rotated after it')
    T.eq(#rotated(W), 1)
  end)
end

waits('in a SIEGE', function(W) W.set_mode('SIEGE') end, function(W) W.set_mode('PEACE') end)
waits('in a BREACH', function(W) W.set_mode('BREACH') end, function(W) W.set_mode('PEACE') end)
waits('in a DRILL', function(W) W.set_mode('DRILL') end, function(W) W.set_mode('PEACE') end)
waits('in an ALERT', function(W) W.set_mode('ALERT') end, function(W) W.set_mode('PEACE') end)
waits('in a lockdown', function(W)
  local K = W.K
  local call = K.call
  K.call = function(mod, fn, ...)
    if mod == 'reflex' and fn == 'holding' and not W.lock_off then return true, 'arrival' end
    return call(mod, fn, ...)
  end
  return call
end, function(W) W.lock_off = true end)
waits('with a hostile in sight', function(W)       -- sense rewrites census.h every scan: a proxy keeps the invader in sight
  local real, on = W.K.census, true
  W.K.census = setmetatable({}, {
    __index = function(_, k) if k == 'h' and on then return {vis = 2, tick = W.K.now().tick} end return real[k] end,
    __newindex = function(_, k, v) real[k] = v end})
  return function() on = false end
end, function(W, off) off() end)

T.test('FR-79: a turnover that cannot run before the window reopens lapses: the same members serve again', function()
  local W = fort()
  local B0 = members_of(W, 'B')
  run_to(W, 3, 11, 20)
  W.set_mode('ALERT')
  run_to(W, 4, 9, 0)                                       -- the window 9-11 of year 4 is open again
  T.eq(members_of(W, 'B'), B0)
  W.set_mode('PEACE')
  run_to(W, 4, 10, 0)
  T.eq(members_of(W, 'B'), B0, 'not in the middle of the window')
  T.eq(#rotated(W), 0)
  T.ok(logged(W, 'did not run before the window reopened'), 'kern.log says the turnover lapsed')
  local p = persisted(W)
  T.eq(p.rot.B.ms, 1)
  for _, id in ipairs(B0) do T.eq(p.served[tostring(id)], 1, 'credited for the first window only') end
  run_to(W, 5, 1, 0)                                       -- the next close works as usual
  T.eq(overlap(B0, members_of(W, 'B')), 0)
  p = persisted(W)
  for _, id in ipairs(B0) do T.eq(p.served[tostring(id)], 2, 'the second window is credited at its close') end
end)


---------------------------------------------------------------- who is eligible
-- the citizens in no squad, sorted by id: the ranking at 0 windows served is by id, so civilians[1..3] enter first
local function civilians(W)
  local r = {}
  for _, u in ipairs(df.global.world.units.active) do
    if u.military.squad_id < 0 and u._m.citizen then r[#r + 1] = u.id end
  end
  table.sort(r)
  return r
end

T.test('FR-79: not chosen: a noble, a unit in a mood, a patient, a wounded one, a tool labor, a child, the only holder of a ' ..
       'key labor; of two cooks only one may serve in the same cohort', function()
  local W = fort()
  local civ = civilians(W)
  W.unit(civ[1])._m.noble = 'MAYOR'
  W.unit(civ[2]).mood = 1
  W.unit(civ[3]).health = {flags = {needs_healthcare = true}}
  W.unit(civ[4]).body = {wounds = kmock_vec{{id = 1}}}
  W.unit(civ[5]).status.labors.MINE = true
  W.unit(civ[6])._m.adult = false
  W.unit(civ[7]).status.labors.COOK = true                  -- two cooks: the first may go, then the other is the only one
  W.unit(civ[8]).status.labors.COOK = true
  W.unit(civ[9]).status.labors.MILLER = true                -- the only miller never goes
  local B0 = members_of(W, 'B')
  run_to(W, 4, 1, 0)
  local B1 = members_of(W, 'B')
  table.sort(B1)
  T.eq(overlap(B0, B1), 0)
  T.eq(B1, {civ[7], civ[10], civ[11]}, 'civ[1-6] excluded, civ[7] the first cook, civ[8] the only cook left, civ[9] the only miller')
end)

T.test('FR-79: nobody of the leader\'s squad B is taken for another reason: the soldiers of A and C are never candidates', function()
  local W = fort()
  local others = {}
  for _, id in ipairs(seats(W, 'A')) do others[id] = true end
  for _, id in ipairs(seats(W, 'C')) do others[id] = true end
  local B0 = members_of(W, 'B')
  run_to(W, 4, 1, 0)
  T.eq(overlap(B0, members_of(W, 'B')), 0, 'squad B was turned over')
  for _, id in ipairs(seats(W, 'B')) do T.ok(not others[id], 'unit ' .. id .. ' of A or C sits in B') end
end)

T.test('FR-79: fewer eligible citizens than seats: the squad stays as it is and the state says why', function()
  local W = fort()
  local B0 = members_of(W, 'B')
  local civ = civilians(W)
  for i = 3, #civ do W.unit(civ[i])._m.noble = 'MAYOR' end    -- two civilians left ...
  for _, id in ipairs(B0) do W.unit(id).mood = 1 end          -- ... and the members are in a mood: 2 eligible for 3 seats
  run_to(W, 4, 1, 0)
  T.eq(members_of(W, 'B'), B0)
  T.eq(#rotated(W), 0)
  local i = info(W, 'B')
  T.ok(i.why:find('fewer eligible than seats: 2 for 3', 1, true), i.why)
  T.ok(logged(W, 'no turnover at the close of month 0: fewer eligible than seats'))
  T.eq(i.e, 2)
end)

T.test('FR-79: the same cohort again (all eligible are members): no churn, the state says so', function()
  local W = fort()
  local B0 = members_of(W, 'B')
  local civ = civilians(W)
  for _, id in ipairs(civ) do W.unit(id)._m.noble = 'MAYOR' end   -- nobody else is eligible: the three members stay
  run_to(W, 4, 1, 0)
  T.eq(members_of(W, 'B'), B0)
  T.eq(#rotated(W), 0)
  T.ok(info(W, 'B').why:find('same cohort: 3 eligible for 3 seats', 1, true), info(W, 'B').why)
end)

---------------------------------------------------------------- fairness over four years
-- the militia of squad B (months 9-11) with 15 candidates: five cohorts of three are fifteen different citizens
local function small_pool(extra_opts)
  local units = X.citizens(24)
  for i = 25, 60 do units[i] = X.cit(i, {noble = 'MAYOR'}) end    -- 36 nobles never serve or fight
  local opts = extra_opts or {}
  opts.units = units
  return fort(60, opts)
end

T.test('FR-79: everybody serves once before anybody serves twice (15 candidates, cohorts of 3, five windows)', function()
  local W = small_pool()
  local cohorts = {members_of(W, 'B')}
  T.eq(#cohorts[1], 3)
  for y = 4, 7 do
    run_to(W, y, 1, 0)
    cohorts[#cohorts + 1] = members_of(W, 'B')
  end
  local all = {}
  for i, c in ipairs(cohorts) do
    T.eq(#c, 3, 'cohort ' .. i)
    for _, id in ipairs(c) do T.eq(all[id], nil, 'unit ' .. id .. ' sits in two of the first five cohorts'); all[id] = i end
  end
  local n = 0
  for _ in pairs(all) do n = n + 1 end
  T.eq(n, 15, 'the five cohorts are the 15 candidates')
  run_to(W, 8, 1, 0)                                        -- the sixth cohort begins the second round
  local p = persisted(W)
  local lo, hi = 99, 0
  for id in pairs(all) do
    local c = p.served[tostring(id)] or 0
    if c < lo then lo = c end
    if c > hi then hi = c end
  end
  T.ok(hi - lo <= 1, 'served counts differ by at most one: ' .. lo .. '..' .. hi)
  T.eq(#rotated(W), 5)
  local i = info(W, 'B')
  T.ok(i.hi - i.lo <= 1)
end)

T.test('FR-79: two militia squads (B in 9-11, C in 3-5) over four years: six new citizens a year, no repeat', function()
  local W = fort()
  W.K.cfg.baseline.military = {militia = {B = {9, 10, 11}, C = {3, 4, 5}}, free_months = {9, 10, 11, 3, 4, 5}}
  local seen, rosters = {}, {}
  local function note(y, m)
    run_to(W, y, m, y == 3 and 13 or 3)
    for _, k in ipairs({'B', 'C'}) do
      local r = members_of(W, k)
      local key = table.concat(r, ',')
      if rosters[k] ~= key then
        rosters[k] = key
        for _, id in ipairs(r) do
          T.eq(seen[id], nil, 'unit ' .. id .. ' sits in a second cohort (squad ' .. k .. ', year ' .. y .. ', month ' .. m .. ')')
          seen[id] = k
        end
      end
    end
  end
  note(3, 5)
  for y = 4, 7 do note(y, 0); note(y, 7) end                 -- B closes in month 0, C in month 6
  local n = 0
  for _ in pairs(seen) do n = n + 1 end
  T.ok(n >= 6 * 4, 'at least 24 different citizens served: ' .. n)
  T.eq(#rotated(W) >= 7, true, 'turnovers: ' .. #rotated(W))
end)

---------------------------------------------------------------- bounds: per day, worn
T.test('FR-79: at most per_day members change on a game day: per_day = 1 swaps one a day, three days in a row', function()
  local W = fort()
  W.K.cfg.baseline.military = {rotation = {per_day = 1}}
  local B0 = members_of(W, 'B')
  run_to(W, 3, 11, 27)
  local history = {}
  local prev = members_of(W, 'B')
  for _ = 1, 40 do                                           -- step by step through the first weeks of month 0
    W.run(1200, {skip = 600})
    local now = members_of(W, 'B')
    local changed = #now - overlap(prev, now)
    T.ok(changed <= 1, 'at most one member changed in a day')
    if changed > 0 then history[#history + 1] = abs(W) end
    prev = now
  end
  T.eq(#history, 3, 'three swaps')
  for i = 2, 3 do T.ok(history[i] - history[i - 1] >= 1200, 'a day apart') end
  T.eq(overlap(B0, members_of(W, 'B')), 0, 'finished')
  local ev = rotated(W)
  T.eq(#ev, 3)
  T.eq({ev[1].d.out, ev[1].d.left, ev[2].d.left, ev[3].d.left}, {1, 2, 1, 0})
  T.eq(persisted(W).rot.B.n, 1, 'one turnover')
  T.eq(persisted(W).rot.B.mv, 3)
end)

T.test('FR-79: the army\'s worn % under worn_min holds the turnover of members who wear kit; bare members leave anyway', function()
  local W = fort()
  for _, id in ipairs(members_of(W, 'B')) do X.equip(W, id) end   -- B wears its kit, A and C nothing: worn about a third
  W.run(100, {skip = 9})
  T.ok(X.call(W, 'military', 'kpi').worn < 40, 'worn ' .. X.call(W, 'military', 'kpi').worn)
  local B0 = members_of(W, 'B')
  run_to(W, 4, 2, 0)
  T.eq(members_of(W, 'B'), B0, 'held')
  T.eq(#rotated(W), 0)
  T.ok(info(W, 'B').why:find('held: worn', 1, true), info(W, 'B').why)
  X.equip_all(W)                                              -- the whole army wears its kit: worn 100 %
  W.run(100, {skip = 9})
  run_to(W, 4, 3, 0)                                          -- the off months (0-8) give the turnover time
  T.eq(overlap(B0, members_of(W, 'B')), 0, 'rotated once worn rose')
  T.eq(#rotated(W), 1)
end)

T.test('FR-79: worn under worn_min does not hold members without kit; worn_min = 0 never holds', function()
  local W = fort()
  local B0 = members_of(W, 'B')
  run_to(W, 4, 1, 0)
  T.eq(overlap(B0, members_of(W, 'B')), 0, 'nobody wears anything: worn 0 % and the turnover runs')
  local W2 = fort()
  W2.K.cfg.baseline.military = {rotation = {worn_min = 0}}
  for _, id in ipairs(members_of(W2, 'B')) do X.equip(W2, id) end
  local B2 = members_of(W2, 'B')
  run_to(W2, 4, 1, 0)
  T.eq(overlap(B2, members_of(W2, 'B')), 0, 'worn_min 0 never holds')
end)

---------------------------------------------------------------- the rotation owns the militia squad
T.test('FR-79: between two closes the members do not change (fill and rotation do not fight)', function()
  local W = fort()
  local B0 = members_of(W, 'B')
  local n = #W.acts
  run_to(W, 3, 11, 27)
  T.eq(members_of(W, 'B'), B0)
  T.eq(#acts_since(W, n, function(a) return a.fn == 'squad_add' or a.fn == 'squad_remove' end), 0, 'no add, no remove')
  T.eq(info(W, 'B').rt, 0, 'no turnover yet')
  run_to(W, 4, 1, 0)
  T.eq(info(W, 'B').rt, 1, 'the rotation owns the squad: one turnover at the close')
end)

T.test('FR-79: a death inside the window is refilled with the least served citizen, not the best fighter', function()
  local W = fort(62)                                         -- (62 citizens: one death keeps the squad targets)
  local civ = civilians(W)
  W.unit(civ[20])._m.skills = {AXE = 15, SHIELD = 10}        -- the best fighter of the fort, 20th in the ranking
  local B0 = members_of(W, 'B')
  local victim = B0[1]
  W.kill(victim)
  X.unseat(W, X.squad_of(W, 'B'), victim)                    -- DF frees a dead soldier's position
  run_to(W, 3, 7, 0)
  local B1 = members_of(W, 'B')
  T.eq(#B1, 3)
  local fresh
  for _, id in ipairs(B1) do if overlap({id}, B0) == 0 then fresh = id end end
  T.ok(fresh ~= nil and fresh ~= civ[20], 'the replacement is not the best fighter')
  T.eq(fresh, civ[1], 'the least served by id among the civilians')
end)

T.test('FR-79: in a SIEGE the existing refill rules stay: the best healthy citizens of the core, whatever they served', function()
  local W = fort(62)
  local civ = civilians(W)
  W.unit(civ[20])._m.skills = {AXE = 15, SHIELD = 10}
  local s = X.squad_of(W, 'B')
  for _, id in ipairs(members_of(W, 'B')) do W.kill(id); X.unseat(W, s, id) end
  W.K.set_mode('SIEGE', 'test')
  W.run(1300, {skip = 9})
  local B1 = members_of(W, 'B')
  T.ok(#B1 >= 2, 'refilled in the siege')
  T.ok(overlap(B1, {civ[20]}) == 1, 'the best fighter came first (cv order), as before')
  T.ok(info(W, 'B') ~= nil, 'the rotation still keeps the squad\'s numbers in a siege')
end)

---------------------------------------------------------------- reload, old state
local function reload(W)
  local raw = W.persist_raw['dfllm.m.military']
  package.loaded['dfllm.military'] = nil
  local M2 = require('dfllm.military')
  W.mods.military = nil
  for i, e in ipairs(W.entries) do if e.name == 'military' then table.remove(W.entries, i); break end end
  W.persist_raw['dfllm.m.military'] = raw
  W.load(M2)
  return M2
end

T.test('FR-79: a reload in the middle of a window keeps the counts and the cohort; the next close still rotates', function()
  local W = fort()
  local B0 = members_of(W, 'B')
  run_to(W, 4, 1, 0)
  local B1 = members_of(W, 'B')
  T.eq(overlap(B0, B1), 0)
  run_to(W, 4, 10, 0)                                         -- in the window of year 4
  local served = persisted(W).served
  reload(W)
  W.run(3600 * 3, {skip = 600})
  T.eq(members_of(W, 'B'), B1, 'the reload changed nothing')
  T.eq(persisted(W).served, served, 'the counts survived')
  T.eq(#rotated(W), 1)
  run_to(W, 5, 1, 0)
  local B2 = members_of(W, 'B')
  T.eq(overlap(B1, B2), 0)
  T.eq(overlap(B0, B2), 0, 'the old cohort is still behind the new ones')
  local p = persisted(W)
  for _, id in ipairs(B1) do T.eq(p.served[tostring(id)], 1, 'credited once') end
end)

T.test('FR-79: a reload between two batches of one turnover finishes it without crediting twice', function()
  local W = fort()
  W.K.cfg.baseline.military = {rotation = {per_day = 1}}
  local B0 = members_of(W, 'B')
  run_to(W, 3, 11, 27)
  local n
  for _ = 1, 40 do
    W.run(1200, {skip = 600})
    if #rotated(W) == 1 then n = true; break end
  end
  T.ok(n, 'the first batch ran')
  local mid = members_of(W, 'B')
  T.eq(overlap(B0, mid), 2)
  reload(W)
  W.K.cfg.baseline.military = {rotation = {per_day = 1}}
  run_to(W, 4, 2, 0)
  T.eq(overlap(B0, members_of(W, 'B')), 0, 'the turnover was finished after the reload')
  local p = persisted(W)
  for _, id in ipairs(B0) do T.eq(p.served[tostring(id)], 1, 'credited once') end
  T.eq(p.rot.B.n, 1)
  T.eq(p.rot.B.mv, 3)
  T.eq(#rotated(W), 3)
end)

T.test('FR-79: an old kernel state without rotation keys boots quietly; the first close after it rotates', function()
  local W = X.world{n = 60, ytick = 5 * MONTH + 100}
  local s = X.new_squad(W, 'B')                              -- (an old state knows the squads only)
  W.persist_raw['dfllm.m.military'] = json.encode({v = 2, posture = 'TRAIN', sq = {B = {id = s.id, uni = 0}}})
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  W.run(3600 * 4, {skip = 600})
  T.ok(logged(W, 'militia squad B: rotation on'), 'first sight only records')
  local B0 = members_of(W, 'B')
  T.eq(#B0 >= 1, true)
  run_to(W, 3, 11, 27)
  T.eq(members_of(W, 'B'), B0)
  run_to(W, 4, 1, 0)
  T.eq(overlap(B0, members_of(W, 'B')), 0)
end)

T.test('FR-79: a clock that went back (an older save) starts the squad over instead of waiting for ever', function()
  local W = fort()
  run_to(W, 4, 1, 0)
  local p = persisted(W)
  p.rot.B.c, p.rot.B.e = 99 * 12, 99 * 12                    -- a future close: the save was loaded from before
  W.persist_raw['dfllm.m.military'] = json.encode(p)
  reload(W)
  W.run(3600 * 3, {skip = 600})
  T.ok(logged(W, 'militia squad B: rotation on'))
  local B1 = members_of(W, 'B')
  run_to(W, 5, 1, 0)
  T.eq(overlap(B1, members_of(W, 'B')), 0)
end)

---------------------------------------------------------------- forts of other sizes, adopted squads
T.test('FR-79: a fort of 7 has no seats beside the leader: no turnover, no fault, the state says so', function()
  local W = fort(7)
  T.eq(#members_of(W, 'B'), 0, 'squad B is the leader alone')
  run_to(W, 4, 1, 0)
  T.eq(#rotated(W), 0)
  T.eq(#W.find_events('KERN_FAULT'), 0)
  T.eq(info(W, 'B').why, 'last: no seats beside the leader')
  T.eq(logged(W, 'waits'), nil, 'no log noise')
end)

T.test('FR-79: a fort of 80: four seats beside the leader, two batches of 3 and 1 on two days', function()
  local W = fort(80)
  T.eq(#members_of(W, 'B'), 4)
  local B0 = members_of(W, 'B')
  run_to(W, 3, 11, 27)
  run_to(W, 4, 2, 0)
  T.eq(overlap(B0, members_of(W, 'B')), 0)
  local ev = rotated(W)
  T.eq(#ev, 2)
  T.eq({ev[1].d.out, ev[1].d.left, ev[2].d.out, ev[2].d.left}, {3, 1, 1, 0})
  T.ok(ev[2].tick - ev[1].tick >= 1200, 'a day apart')
end)

T.test('FR-79: before the squads exist (a young fort at P0) the state names why there is no rotation', function()
  local W = X.world{n = 30, ytick = 5 * MONTH + 100}
  X.load(W, {'military'}, {X.runner('P0')}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  W.run(3600 * 3, {skip = 600})
  T.eq(info(W, 'B'), {w = '9-11', why = 'no squad'})
  T.eq(info(W, 'A'), nil)
end)

T.test('FR-79: a squad B made by hand (a reclaimed fort, the squads screen) is adopted; its members stay until the close, ' ..
       'then every one who is not in the next cohort leaves', function()
  local W = X.world{n = 60, ytick = 5 * MONTH + 100}
  local s = X.new_squad(W, 'B')
  X.seat(W, s, 0, 40)
  X.seat(W, s, 1, 41)
  X.seat(W, s, 2, 42)
  W.unit(42)._m.noble = 'MAYOR'                              -- a noble among them (the old owner's choice)
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  W.run(3600 * 4, {skip = 600})
  T.eq(X.squad_of(W, 'B').id, s.id, 'adopted')
  local B0 = members_of(W, 'B')
  T.eq(overlap(B0, {41, 42}), 2, 'the hand-made members stay (the squad is topped up around them)')
  T.eq(#B0, 3)
  run_to(W, 3, 11, 27)
  T.eq(members_of(W, 'B'), B0, 'through the window')
  run_to(W, 4, 1, 0)
  local B1 = members_of(W, 'B')
  T.eq(overlap(B1, {41, 42}), 0, 'none of the old members is in the next cohort (the noble least of all)')
  T.eq(#B1, 3)
  T.eq(leader_of(W, 'B'), 40, 'the leader stays')
end)

---------------------------------------------------------------- configuration
T.test('FR-79: rotation.on = false keeps the members as before (and publishes no rotation state)', function()
  local W = fort()
  local W1 = fort()                                          -- (the control: the default config turns the squad over)
  local C0 = members_of(W1, 'B')
  run_to(W1, 4, 1, 0)
  T.eq(overlap(C0, members_of(W1, 'B')), 0)
  W.K.cfg.baseline.military = {rotation = {on = false}}
  local B0 = members_of(W, 'B')
  run_to(W, 5, 5, 0)
  T.eq(members_of(W, 'B'), B0)
  T.eq(#rotated(W), 0)
  T.eq(info(W, 'B'), nil)
end)

T.test('FR-79: a fort without a militia table (every squad elite) rotates nobody', function()
  local W = fort()
  local W1 = fort()                                          -- (the control: with the default militia table B is turned over)
  local D0 = members_of(W1, 'B')
  run_to(W1, 4, 1, 0)
  T.eq(overlap(D0, members_of(W1, 'B')), 0)
  W.K.cfg.baseline.military = {militia = {}, free_months = {9, 10, 11}}
  local B0, C0 = members_of(W, 'B'), members_of(W, 'C')
  run_to(W, 5, 5, 0)
  T.eq(members_of(W, 'B'), B0)
  T.eq(members_of(W, 'C'), C0)
  T.eq(#rotated(W), 0)
end)

T.test('FR-79: a bad rotation config falls back to the defaults (3 a day, worn 40, on)', function()
  local W = fort()
  W.K.cfg.baseline.military = {rotation = {on = 'yes', per_day = 99, worn_min = -1, x = 1}}
  local c = mil().conf(W.K)
  T.eq(c.rot, {on = true, per_day = 3, worn_min = 40})
  W.K.cfg.baseline.military = {rotation = {on = false, per_day = 7, worn_min = 0}}
  T.eq(mil().conf(W.K).rot, {on = false, per_day = 7, worn_min = 0})
  W.K.cfg.baseline.military = nil
  T.eq(mil().conf(W.K).rot, {on = true, per_day = 3, worn_min = 40})
end)

---------------------------------------------------------------- state
T.test('FR-79: the state names the window, the cohort, the eligible, the served spread, the days to the next close', function()
  local W = fort()
  run_to(W, 3, 8, 14)                                         -- month 8, day 14: the window opens in 14 days
  local i = info(W, 'B')
  T.eq({i.w, i.on, i.n, i.z}, {'9-11', 0, 4, 4})
  T.ok(i.e >= 40, 'eligible ' .. i.e)
  T.eq({i.lo, i.hi}, {0, 0})
  local days = (4 * 12 - 3 * 12 - 8) * 28 - 14                 -- to month 0 of year 4: 4 months less 14 days
  T.ok(i.nx >= days and i.nx <= days + 3, 'nx ' .. i.nx .. ' (the upkeep ran up to 3 days ago)')
  run_to(W, 3, 10, 0)
  T.eq(info(W, 'B').on, 1)
  T.eq(info(W, 'A'), nil, 'an elite squad has no rotation line')
  T.eq(info(W, 'C'), nil)
  run_to(W, 4, 1, 0)
  i = info(W, 'B')
  T.eq({i.rt, i.mv}, {1, 3})
  T.ok(i.why == 'last: rotated', tostring(i.why))
  T.eq({i.lo, i.hi}, {0, 1})
end)

T.test('FR-79: the served counts forget citizens who are gone', function()
  local W = fort()
  local B0 = members_of(W, 'B')
  run_to(W, 4, 1, 0)
  local gone = B0[1]
  local u = W.unit(gone)
  u._m.citizen = false
  W.kill(gone)
  W.run(3600 * 2, {skip = 600})
  run_to(W, 5, 1, 0)
  T.eq(persisted(W).served[tostring(gone)], nil)
end)

---------------------------------------------------------------- BUG-076
-- the refill of a squad: addToSquad refuses a unit (DF knows why) and the squad backed off for good
local function refuse(W, pred)
  W.act_result('squad_add', function(sid, uid)
    local s = W.squads[sid]
    if pred(uid, W) then return false, 'addToSquad refused' end
    if not s or s.positions[0].occupant < 0 then return false, 'addToSquad refused' end
    if W.unit(uid).military.squad_id >= 0 then return false, 'already in a squad' end
    for i = 1, 9 do
      if s.positions[i].occupant < 0 then X.seat(W, s, i, uid); return true, sid end
    end
    return false, 'squad full'
  end)
end

T.test('BUG-076: one unit that addToSquad refuses does not block the refill of the squad', function()
  local W = X.world{n = 60, ytick = 5 * MONTH + 100}
  W.unit(7)._m.skills = {AXE = 15, SHIELD = 10}              -- the best recruit leads squad A ...
  W.unit(8)._m.skills = {AXE = 14, SHIELD = 10}              -- ... the next one is first in line for its members
  refuse(W, function(uid) return uid == 8 end)
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  W.run(3600 * 4, {skip = 600})
  T.eq(#members_of(W, 'A'), 3, 'squad A is full beside its leader')
  T.eq(#members_of(W, 'B'), 3)
  T.eq(#members_of(W, 'C'), 3)
  T.ok(logged(W, 'unit 8 was not taken in %(addToSquad refused%)'), 'kern.log names the refusal')
end)

T.test('BUG-076: a successful refill clears the backoff: the next series of refusals waits 1,200 ticks again, not twice as long',
       function()
  local W = X.world{n = 64, ytick = 5 * MONTH + 100}                -- (64: three deaths keep the population target)
  X.load(W, {'military'}, {X.runner('P5')}, {'sense'})
  W.state()
  W.run(9, {skip = 9})
  W.run(3600 * 3, {skip = 600})
  W.K.set_mode('ALERT', 'test')                              -- the upkeep runs every 600 ticks outside PEACE
  W.run(1200, {skip = 100})
  local s = X.squad_of(W, 'B')
  local refusing = false
  W.act_result('squad_add', function(sid, uid)
    if refusing then return false, 'addToSquad refused' end
    for i = 1, 9 do
      if s.positions[i].occupant < 0 then X.seat(W, s, i, uid); return true, sid end
    end
    return false, 'squad full'
  end)
  local function lose_one(refuse_ticks, then_wait)
    local ids = members_of(W, 'B')
    W.kill(ids[1]); X.unseat(W, s, ids[1])
    refusing = true
    W.run(refuse_ticks, {skip = 100})                        -- the upkeep (every 600) tries and is refused
    T.eq(#members_of(W, 'B'), 2, 'refused: the squad stays short')
    refusing = false
    W.run(then_wait, {skip = 100})
    return #members_of(W, 'B')
  end
  T.eq(lose_one(700, 3000), 3, 'first series: refilled after one backoff')
  T.eq(lose_one(700, 1500), 3, 'second series: retried 1,200 ticks after the refusal (old code: 2,400)')
  T.eq(lose_one(700, 1500), 3, 'third series: again (old code: 4,800)')
end)

T.done()
