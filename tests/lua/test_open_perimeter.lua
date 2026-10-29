-- FR-70 (Run 11 y483-y497, Run 13 y507-y525): a door open for 14 years, O1/B1/B2 and their levers lost for 18, 60 citizens
-- lost in two sieges, a fort fallen over an open O1: an audit FAIL with open entrances, or lost bridges and levers, in
-- PEACE is a stop signal. Checked here with the real readiness, sense and gate (tests/lua/wp6_world.lua, a fake seal
-- with the entrance check): R0 `open_perimeter` at once, the days counted (ready.pd / ready.pw), the SIEGE_UNREADY wake
-- repeating every perimeter.escalate_every days (and 5 real minutes) from perimeter.escalate_days days on, max-pop held
-- where it stands from perimeter.hold_pop citizens (a fort of 7 keeps growing), everything released when the perimeter
-- closes, a lost bridge and a lost lever count, a bridge seal replaced by wall + door does not.
local T = require('testlib')
local X = require('wp6_world')

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}
local AUDIT_OK = {ok = true, fails = {}, min_traps = 35, bypass = false, refuge_sep = true, civ_sep = true,
                  caverns = true}

local function world(opts)
  opts = opts or {}
  local units = X.citizens(opts.n or 50, 1, {skills = SKILLS})
  local W = X.world{units = units, persist = {}, manifest = opts.manifest}
  if opts.reflex then W.K.cfg.reflex = opts.reflex end
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.seal = {name = 'seal', every = {ticks = 600}, x = opts.entrances, rep = {}}
  function W.seal.entrance_doors(K) return W.seal.x end
  function W.seal.replaced(K) return W.seal.rep end
  W.econ, W.snap = X.economy(), X.snapshot()
  X.load(W, {'military', 'readiness'}, {W.econ, W.snap, runner, W.seal}, {'sense', 'gate'})
  X.mod('readiness').CAPS = {[0] = 55, [1] = 55, [2] = 75, [3] = 250}     -- fixtures use the pre-2026-10-24 caps (shipped: 100, see test_readiness)
  return W
end

local SEALED = {tick = 1, sealed = 1, routes = 1, doors = {{id = 9, pos = {74, 70, 117}}}, open = {}}
local LEAKY = {tick = 1, sealed = 0, routes = 3, doors = {}, open = {{pos = {55, 62, 117}, kind = 'floor'},
                                                                  {pos = {61, 55, 117}, kind = 'floor'}}}
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end
local function ready(W) return W.state().ready end
local function lvl(W) return X.call(W, 'readiness', 'level') end
local function unready(W) return W.find_events('SIEGE_UNREADY') end
local function pops(W) return W.state().pop end

local function audit(W)
  local _, ok, id = W.K.call('snapshot', 'export', {purpose = 'audit'})
  W.frame(0, true)
  local a = {}
  for k, v in pairs(AUDIT_OK) do a[k] = v end
  a.snap = id
  return W.inbox('audit', a, {by = 'follow'})
end

-- DF removes a destroyed bridge (O1 is siege_world's building 1) and the levers of it lose their link
local function destroy_o1(W)
  W.buildings[1] = nil
  local v = df.global.world.buildings.other.BRIDGE
  for i = #v - 1, 0, -1 do if v[i].id == 1 then v:erase(i) end end
end

T.test('an open way in is R0 open_perimeter at once (an audit that passes does not hide it), the days are counted, ' ..
       'the wake repeats every 5 days and 5 real minutes from day 2 (old: monthly, no days), the R1 fort falls to R0',
       function()
  -- old code: the open ways were only listed; R1 held, the wake came once a month
  local W = world{entrances = SEALED}
  day(W)
  audit(W)
  T.eq(lvl(W), 1)
  T.eq(ready(W).pd, nil, 'closed: no days')
  W.seal.x = LEAKY
  day(W)
  T.eq(lvl(W), 0, 'R1 -> R0')
  T.eq({ready(W).fail[1], ready(W).open, ready(W).pw}, {'open_perimeter', 2, '2 ways in'})
  T.ok(ready(W).pd == 0 or ready(W).pd == 1, 'pd ' .. tostring(ready(W).pd))
  T.eq(#unready(W), 0, 'not in the first 2 days after a load')
  day(W, 3)
  T.ok(ready(W).pd >= 3, 'the days are counted: ' .. tostring(ready(W).pd))
  local u = unready(W)
  T.eq(#u, 1, 'the first wake')
  T.ok(u[1].d.pw == '2 ways in' and u[1].msg:find('perimeter OPEN', 1, true), T.show(u[1].d) .. u[1].msg)
  W.ms = W.ms + 301 * 1000
  day(W)
  u = unready(W)
  T.eq(#u, 2, 'from day 2 the escalation follows after 5 real minutes (not after a month)')
  local last = u[#u]
  T.ok(last.d.pd >= 2 and last.d.pw == '2 ways in', T.show(last.d))
  T.ok(last.msg:find('perimeter OPEN', 1, true) and last.msg:find('2 ways in', 1, true), last.msg)
  local n1 = #u
  day(W, 6)
  T.eq(#unready(W), n1, 'five real minutes have not passed')
  W.ms = W.ms + 301 * 1000
  day(W)
  T.eq(#unready(W), n1 + 1, 'then it repeats (5 days, 5 real minutes)')
  W.ms = W.ms + 301 * 1000
  day(W, 2)
  T.eq(#unready(W), n1 + 1, 'but not before 5 days')
  day(W, 4)
  T.eq(#unready(W), n1 + 2)
  -- closed again: the days are gone, R1 back
  W.seal.x = SEALED
  day(W)
  T.eq({lvl(W), ready(W).pd}, {1, nil})
end)

T.test('the freeze: from escalate_days a fort of hold_pop (30) citizens or more holds max-pop where it stands (POPCAP ' ..
       'open_perimeter), a fort of 7 keeps its cap; released when the perimeter closes', function()
  local W = world{entrances = SEALED, n = 50}
  day(W)
  audit(W)
  T.eq(pops(W).cap, 55)
  W.set_plan({v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = 75, beauty = 'used_rooms'}})
  W.seal.x = LEAKY
  day(W)
  T.eq(pops(W).cap, 55, 'before escalate_days: the cap stays')
  day(W, 3)
  T.eq(pops(W).cap, 50, 'max-pop held at the 50 citizens')
  local pc = W.find_events('POPCAP')
  T.ok(pc[#pc].d.cap == 50, T.show(pc[#pc].d))
  W.seal.x = SEALED
  day(W)
  T.eq(pops(W).cap, 55, 'released')
  -- a fort of 7: the perimeter is open, nothing is frozen (it needs the migrants to build the seal)
  local W7 = world{entrances = LEAKY, n = 7}
  day(W7, 5)
  T.eq(lvl(W7), 0)
  T.eq(ready(W7).fail[1], 'open_perimeter')
  T.eq(pops(W7).cap, 55)
  -- the knobs: hold_pop 0 = never freeze; hold_pop 60 = a fort of 50 is below it
  local W0 = world{entrances = LEAKY, reflex = {v = 2, perimeter = {hold_pop = 0}}}
  day(W0, 5)
  T.eq(pops(W0).cap, 55)
  local W60 = world{entrances = LEAKY, reflex = {v = 2, perimeter = {hold_pop = 60}}}
  day(W60, 5)
  T.eq(pops(W60).cap, 55)
  -- escalate_days 0 freezes at once
  local Wn = world{entrances = LEAKY, reflex = {v = 2, perimeter = {escalate_days = 0}}}
  day(Wn, 2)
  T.eq(pops(Wn).cap, 50)
end)

T.test('a lost bridge in PEACE (gate found it destroyed) is the stop signal too; a bridge seal replaced by wall + door ' ..
       'is not; nothing is counted outside PEACE (the lockdown is no news)', function()
  local W = world{entrances = SEALED}
  day(W)                                          -- gate sees O1 whole
  audit(W)
  T.eq(lvl(W), 1)
  destroy_o1(W)
  day(W, 2)
  T.eq(lvl(W), 0)
  T.eq(ready(W).fail[1], 'open_perimeter')
  T.ok(ready(W).pw:find('bridges lost: O1', 1, true), ready(W).pw)
  T.ok(ready(W).pd >= 1)
  -- seal made it a wall + door: no signal (no_outer remains: the doctrine wants a gate there)
  W.seal.rep = {O1 = {t = 5, n = 2, how = 'wall + door'}}
  day(W)
  T.eq(ready(W).pd, nil)
  T.ok(not (function() for _, f in ipairs(ready(W).fail) do if f == 'open_perimeter' then return true end end end)())
  local has_no_outer, has_bridge = false, false
  for _, f in ipairs(ready(W).fail) do
    if f == 'no_outer' then has_no_outer = true end
    if f == 'bridge:O1' or f == 'levers:O1' then has_bridge = true end
  end
  T.ok(has_no_outer and not has_bridge, T.show(ready(W).fail))
end)

T.test('a lost lever of a bridge seen whole counts; a bridge that never had its levers (a fort in the making) does not',
       function()
  local W = world{entrances = SEALED}
  day(W)                                          -- the lever check runs: B1 whole, remembered
  audit(W)
  T.eq(ready(W).pd, nil)
  W.buildings[21].linked_mechanisms = require('dfllm.util.k_mock').vec{}      -- B1's lever loses its link
  day(W, 2)
  T.eq(ready(W).fail[1], 'open_perimeter')
  T.ok(ready(W).pw:find('levers lost: B1', 1, true), ready(W).pw)
  local Wn = world{entrances = SEALED}
  Wn.buildings[21].linked_mechanisms = require('dfllm.util.k_mock').vec{}     -- never whole
  day(Wn, 2)
  T.eq(ready(Wn).pd, nil, 'no history, no signal')
  T.ok(ready(Wn).fail[1] ~= 'open_perimeter', T.show(ready(Wn).fail))
end)

T.test('the signal survives a reload (the days keep counting) and outside PEACE it is not started anew; its ways in ' ..
       'follow the entrance check (BUG-322)', function()
  local W = world{entrances = LEAKY}
  day(W, 4)
  local pd = ready(W).pd
  T.ok(pd >= 3)
  W.K.set_mode('ALERT', 'test')                   -- gates are up: the ways in stay as the entrance check reads them
  day(W, 3)
  T.ok(ready(W).pd >= pd + 2, 'still counted in ALERT: ' .. tostring(ready(W).pd))
  -- a reload (persist m.readiness) keeps the days
  local pd2 = ready(W).pd
  for i, e in ipairs(W.entries) do if e.name == 'readiness' then table.remove(W.entries, i) end end
  W.mods.readiness = nil
  package.loaded['dfllm.readiness'] = nil
  W.load(require('dfllm.readiness'))
  day(W)
  T.ok(ready(W).pd >= pd2, 'the days survive a reload: ' .. tostring(ready(W).pd) .. ' vs ' .. pd2)
  W.seal.x = SEALED
  day(W)
  T.eq(ready(W).pd, nil, 'closed in ALERT: gone (BUG-322)')
  W.K.set_mode('PEACE', 'test')
  day(W)
  T.eq(ready(W).pd, nil, 'closed in PEACE: gone')
end)

T.done()
