-- BUG-742 (Run 16a i1 Basementflew y509-y524: 'defense_short 43' for 15 years beside traps 0 < 20 AND armor worn 28 %, no stone, no metal; the
-- ceiling flipped between 100 (R0) and 35 / 39 / 43 in the same year; open_perimeter 41 / 42 beside it; no migrants for 539 days; nobody was told
-- what would end it):
--   * the armor gap reads the MEDIAN worn % of 45 days (a refit's 76 -> 21 -> 76 % is no gap and no recovery)
--   * the hold clears only after DEF.clear_days without a gap (a dip does not lift it or move its population)
--   * a hold that stands DEF.relax_days with the fort at its ceiling is raised by one wave's room, whatever the gap (traps AND armor: i1), once
--     per number, never back down; bare soldiers (median worn < worn_floor %) get no step
--   * defense_short and open_perimeter within DEF.hold_band citizens are one number
--   * DECISION_NEEDED defense_gap (A) says what the hold IS now (read from the state, not assumed), what lifts it and the ways out
local T = require('testlib')
local X = require('wp6_world')

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}
local AUDIT_OK = {ok = true, fails = {}, min_traps = 35, bypass = false, refuge_sep = true, civ_sep = true, caverns = true}
local SEALED = {tick = 1, sealed = 1, routes = 0, doors = {{id = 9, pos = {74, 70, 117}}}, open = {}}
local function leaky(x, y) return {tick = 1, sealed = 0, routes = 1, doors = {}, open = {{pos = {x, y, 117}, kind = 'floor'}}} end

local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end
local function ready(W) return W.state().ready end
local function has(list, v) for _, x in ipairs(list or {}) do if x == v then return true end end return false end

local function audit(W, over)
  local _, ok, id = W.K.call('snapshot', 'export', {purpose = 'audit'})
  W.frame(0, true)
  local a = {}
  for k, v in pairs(AUDIT_OK) do a[k] = v end
  for k, v in pairs(over or {}) do a[k] = v end
  a.snap = id
  return W.inbox('audit', a, {by = 'follow'})
end

-- confirm: OPEN_CONFIRM as shipped (false) or 0; worn: the military KPI's worn % (nil: leave military as it is); armor_pct: DEF.worn_pct
local function world(o)
  o = o or {}
  local units = X.citizens(o.n or 50, 1, {skills = SKILLS})
  local persist = {}
  if o.hist then persist['m.siege'] = {hist = o.hist} end
  local W = X.world{units = units, persist = persist, manifest = o.manifest}
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.seal = {name = 'seal', every = {ticks = 600}, x = o.entrances or SEALED, rep = {}}
  function W.seal.entrance_doors(K) return W.seal.x end
  function W.seal.replaced(K) return W.seal.rep end
  W.econ, W.snap = X.economy(), X.snapshot()
  X.load(W, {'military', 'readiness'}, {W.econ, W.snap, runner, W.seal}, {'sense', 'threat', 'siege', 'gate'})
  local R = X.mod('readiness')
  R.CAPS = {[0] = o.cap or 120, [1] = o.cap or 120, [2] = o.cap or 120, [3] = 250}
  if not o.confirm then R.OPEN_CONFIRM = 0 end
  if not o.armor then R.DEF.worn_pct = 0 end
  R.DEF.relax_days = 60                       -- (shipped: 180; the runs are shorter, pytest gives a Lua file 60 s)
  if o.worn then
    local real = X.mod('military').kpi
    X.mod('military').kpi = function(K)
      local k = real(K) or {}
      k.soldiers, k.worn = o.soldiers or 12, W.worn
      return k
    end
    W.worn = o.worn
  end
  W.K.cfg.decisions['D-01'] = 'A'
  W.set_plan({v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = o.cap or 120, beauty = 'used_rooms'}})
  return W
end


local function events(W, id)
  local n, last = 0, nil
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == id then n, last = n + 1, e end end
  return n, last
end


local HIST = {peak = 50, n = 2, bd = 1}
local N, CAP = 44, 100                       -- Run 16a i1: 43 citizens

T.test('BUG-742: a one-day swing of worn (refit: 76 -> 21 -> 76 %) neither opens nor lifts the hold; a real recovery lifts it after clear_days', function()
  local W = world{n = N, cap = CAP, armor = true, worn = 30}
  day(W, 3)
  audit(W)
  day(W, 22)
  T.eq(W.state().pop.cap, N, 'held at the population')
  W.worn = 80
  day(W, 3)
  T.eq(W.state().pop.cap, N, 'worn 80 % for three days: the median of 45 days is still 30 %')
  W.worn = 30
  day(W, 3)
  T.eq(W.state().pop.cap, N, 'the gap is back: the same hold')
  W.worn = 80
  day(W, 70)
  T.eq(W.state().pop.cap, CAP, 'worn 80 % for most of the window and clear_days without a gap: lifted')
  T.eq(ready(W).dh, nil, 'no hold stands')
end)

T.test('BUG-742: Run 16a i1 (traps 8 < 29 AND armor worn 28 %): the hold stands relax_days, then one wave of room (a number written once), ' ..
       'never back to the citizens, the ceiling does not flip', function()
  local W = world{n = N, cap = CAP, armor = true, worn = 28, hist = HIST}
  day(W, 3)
  audit(W, {min_traps = 8})
  day(W, 25)
  local r = ready(W)
  T.ok(r.ts and r.as, 'both gaps: ' .. T.show(r))
  T.eq(W.state().pop.cap, N, 'held at the population')
  T.eq(r.dh, N)
  local R = X.mod('readiness')
  local caps = {}
  for _ = 1, 20 do day(W, 5); caps[#caps + 1] = W.state().pop.cap end      -- 100 days (relax_days 60 here)
  T.eq(caps[1], N)
  T.eq(caps[#caps], N + R.growth_room(N), 'after relax_days: the citizens + growth_room, although the traps are short as well')
  local up = false
  for _, c in ipairs(caps) do
    if c == N + R.growth_room(N) then up = true elseif up then T.ok(false, 'the ceiling fell back: ' .. T.show(caps)) end
  end
  T.ok(ready(W).dage ~= nil and ready(W).dage < R.DEF.relax_days, 'the hold counts its age again from the step: ' .. T.show(ready(W).dage))
  local n = events(W, 'defense_gap')
  T.eq(n, 2, 'one question when the hold stood, one when it was raised')
end)

T.test('BUG-742: bare soldiers (median worn under worn_floor %) get no step: no room, and the question says so', function()
  local W = world{n = N, cap = CAP, armor = true, worn = 5, hist = HIST}
  day(W, 3)
  audit(W, {min_traps = 35})
  day(W, 25)
  for _ = 1, 20 do day(W, 5) end
  T.eq(W.state().pop.cap, N, 'no step for bare soldiers')
  local n, e = events(W, 'defense_gap')
  T.ok(n >= 1)
  T.eq(e.d.cause, 'armor')
  T.ok(e.d.q:find('nearly bare', 1, true), e.d.q)
  T.ok(not e.d.q:find('room for a wave is open', 1, true), e.d.q)
end)

T.test('BUG-742: DECISION_NEEDED defense_gap says what the hold is (no room), what lifts it, the ways out and the commands, once', function()
  local W = world{n = N, cap = CAP, armor = true, worn = 28, hist = HIST}
  day(W, 3)
  audit(W, {min_traps = 8})
  day(W, 60)
  local n, e = events(W, 'defense_gap')
  T.eq(n, 1, 'asked once in 60 days')
  T.eq(e.cls, 'A')
  T.eq(e.d.cause, 'both')
  T.ok(e.d.q:find('no room', 1, true), e.d.q)
  T.ok(e.d.q:find('armor worn 28', 1, true) and e.d.q:find('traps short', 1, true), e.d.q)
  T.ok(not e.d.q:find('room for a wave is open', 1, true), 'the old text claimed a room that was not there: ' .. e.d.q)
  local joined = table.concat(e.d.cmds, ' ')
  T.ok(joined:find('trade.want', 1, true) and joined:find('inspect', 1, true), T.show(e.d.cmds))
  day(W, 15)
  T.eq((events(W, 'defense_gap')), 1, 'not again while nothing changed')
end)

T.test('BUG-742: a hold persisted before the stamp existed (dt, dhold, no dht) is aged from its gap and relaxes after a reload', function()
  local W = world{n = N, cap = CAP, armor = true, worn = 28, hist = HIST}
  day(W, 3)
  audit(W, {min_traps = 8})
  day(W, 25)
  T.eq(W.state().pop.hold, 'defense_short ' .. N)
  local p = W.K.persist.get('m.readiness')
  T.ok(p.dhold == N and p.dht ~= nil, 'the hold is stamped: ' .. T.show(p))
  p.dht = nil                                       -- the record as an older kernel saved it
  W.K.persist.set('m.readiness', p)
  X.mod('readiness').init(W.K)
  day(W, 2)
  T.ok(W.K.persist.get('m.readiness').dht ~= nil, 'the stamp is backfilled')
  for _ = 1, 20 do day(W, 5) end
  T.eq(W.state().pop.cap, N + X.mod('readiness').growth_room(N), 'relax_days since the gap began')
end)

T.test('BUG-742: worn_best is the median of the window (a blip of one sample moves nothing), nil without a reading', function()
  local W = world{n = 20, cap = CAP}
  local R = X.mod('readiness')
  T.eq(R.worn_best(1000, nil), nil)
  local now = 100000
  for i = 1, 9 do R.worn_best(now + i * 600, 30) end
  T.eq(R.worn_best(now + 10 * 600, 90), 30, 'one high sample in ten')
  for i = 11, 40 do R.worn_best(now + i * 600, 90) end
  T.eq(R.worn_best(now + 41 * 600, 90), 90, 'a real change after half the window')
end)

T.done()
