-- BUG-583 (Run 16d i4 Trumpetrealms y411-y418): (1) the steel DECISION waited on flux for 14 orders and `trade.want flux` was ignored ('flux' is
-- no item type): `flux` is a trade token for a flux boulder (limestone, dolomite, marble, chalk, calcite), `flux:limestone` that stone only,
-- `stone:flux` / `boulder:flux` the same, and the decision names the command; (2) the refuge_levers question for a link job that waits
-- (link_stale) came 10 times a year with a growing counter and no cause: it is asked again after DEF.stuck_days only (at once when the
-- cause changes) and names the real cause (DF refuses the rock jobs, no stone, no Mechanics workshop).
local T = require('testlib')
local X = require('wp6_world')
local S = require('siege_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local L = fresh('trade').lib
local function info(t, mat, desc, flux) return {type = t, mat = (mat or ''):lower(), desc = (desc or ''):lower(), flux = flux} end

T.test('BUG-583: flux is a trade token: flux boulders match, other stone does not, a named stone narrows it', function()
  for _, s in ipairs({'flux', 'flux:limestone', 'stone:flux', 'boulder:flux'}) do T.ok(L.token(s) ~= nil, s .. ' is a token') end
  T.ok(L.valid('flux') and L.valid('stone:flux'))
  local lime = info('BOULDER', 'INORGANIC:LIMESTONE', 'limestone boulder')
  local flagged = info('BOULDER', 'INORGANIC:SOMETHING', 'odd boulder', true)
  local mud, ore = info('BOULDER', 'INORGANIC:MUDSTONE', 'mudstone boulder'), info('BOULDER', 'INORGANIC:HEMATITE', 'hematite boulder')
  for _, s in ipairs({'flux', 'stone:flux', 'boulder:flux'}) do
    T.ok(L.match(L.token(s), lime), s .. ' limestone')
    T.ok(L.match(L.token(s), flagged), s .. ' by its reaction class')
    T.ok(not L.match(L.token(s), mud), s .. ' not mudstone')
    T.ok(not L.match(L.token(s), ore), s .. ' not an ore')
  end
  T.ok(L.match(L.token('flux:limestone'), lime))
  T.ok(not L.match(L.token('flux:marble'), lime), 'flux:marble is marble only')
  T.ok(not L.match(L.token('flux'), info('BAR', 'INORGANIC:LIMESTONE', 'limestone bars')), 'boulders only')
  T.eq(L.token('stone:limestone').flux, nil, 'a plain stone token is no flux token')
  T.ok(L.match(L.token('stone:limestone'), lime))
end)

-- the refuge-lever question: a gate that says a link job waits (stale) for `age` ticks, an economy that says why no mechanism comes
local function world(o)
  local units = X.citizens(50, 1, {skills = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}})
  local W = X.world{units = units, persist = {}, manifest = (function()
    local m = S.manifest()
    for name, p in pairs({O1 = {70, 70, Z - 6}, B1 = {71, 70, Z - 6}, B2 = {72, 70, Z - 6}}) do table.insert(m.bridges[name].levers, p) end
    return m
  end)()}
  W.K.cfg.decisions['D-01'] = 'A'
  W.set_plan({v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
              policy = {option = 'A', pop_ceiling = 120, beauty = 'used_rooms'}})
  W.econ, W.snap, W.runner = X.economy(), X.snapshot(), X.runner('P5')
  W.state_of = o
  function W.econ.mech_state() return W.state_of.mech end
  X.load(W, {'military', 'readiness'}, {W.econ, W.snap, W.runner}, {'sense', 'threat', 'siege', 'gate'})
  X.mod('readiness').CAPS = {[0] = 120, [1] = 120, [2] = 120, [3] = 250}
  X.mod('gate').refuge_levers = function() return W.state_of.levers end
  X.mod('gate').refuge_gaps = function() return {'B1'} end
  return W
end
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end
local function asked(W)
  local q = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'refuge_levers' then q[#q + 1] = e end end
  return q
end

T.test('BUG-583: link_stale names the cause (no hard stone) and the command, and is asked once in DEF.stuck_days', function()
  local W = world{levers = {B1 = {job = 1, stale = true, age = 40000, site = 0, built = 1, none = 0}},
                  mech = {need = 2, free = 0, short = 2, route = 'no stone', hard = true}}
  day(W, 3)
  X.audit(W, {ok = true, fails = {}, min_traps = 35, bypass = false, refuge_sep = true, civ_sep = true, caverns = true})
  day(W, 2)
  local q = asked(W)
  T.eq(#q, 1, 'asked once')
  T.eq(q[1].d.cause, 'link_stale')
  T.ok(q[1].d.why and q[1].d.why:find('non-economic hard stone', 1, true), tostring(q[1].d.why))
  T.ok(q[1].d.cmds and q[1].d.cmds[1]:find('trade.want', 1, true), 'a command')
  day(W, 100)                                              -- 3 more ask_days passed: the same cause is not asked again
  T.eq(#asked(W), 1, 'not again within the year')
  W.state_of.levers = {B1 = {job = 0, stale = false, age = 0, site = 0, built = 1, none = 0}}      -- the cause changes: unlinked
  day(W, 31)
  T.eq(#asked(W), 2, 'a changed cause is asked at once')
  T.eq(asked(W)[2].d.cause, 'unlinked')
end)

T.test('BUG-583: the same cause is asked again after the year (stuck_days)', function()
  local W = world{levers = {B1 = {job = 1, stale = true, age = 40000, site = 0, built = 1, none = 0}},
                  mech = {need = 2, free = 0, short = 2, route = 'no Mechanics'}}
  day(W, 3)
  X.audit(W, {ok = true, fails = {}, min_traps = 35, bypass = false, refuge_sep = true, civ_sep = true, caverns = true})
  day(W, 2)
  T.eq(#asked(W), 1)
  T.ok(asked(W)[1].d.why:find('Mechanics workshop', 1, true))
  day(W, 365)
  T.eq(#asked(W), 2, 'once a year')
end)

T.done()
