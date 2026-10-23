-- BUG-096 (Run 14 note 70): readiness R0 blocker `burrow_lost`. seal's burrow guard (seal.burrow_guard) lists the open episodes
-- with what the lost tiles held; a lost well or the refuge keeps R0 (SIEGE_UNREADY names it and what the kernel does), the
-- hospital is hospital_out's (not counted twice), an episode over other tiles is no blocker. Fake seal and water modules.
local T = require('testlib')
local X = require('wp6_world')

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}
local function world(opts)
  opts = opts or {}
  local units = X.citizens(opts.n or 50, 1, {skills = SKILLS})
  local W = X.world{units = units, persist = {}}
  W.set_plan{v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
             policy = {option = 'A', pop_ceiling = 55, beauty = 'used_rooms'}}
  local snap, runner = X.snapshot(), X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.econ, W.snap, W.runner = X.economy(), snap, runner
  local extra = {W.econ, snap, runner, opts.seal}
  for _, m in ipairs(opts.extra or {}) do extra[#extra + 1] = m end
  X.load(W, {'military', 'readiness'}, extra, {'sense', 'gate'})
  return W
end
local function seal_fake()
  local M = {name = 'seal', every = {ticks = 600}, eps = {}}
  function M.entrance_doors(K) return {tick = 1, sealed = 1, routes = 0, doors = {}, open = {}} end
  function M.burrow_guard(K) return M.eps end
  return M
end
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end
local function ready(W) return W.state().ready end
local function lvl(W) return X.call(W, 'readiness', 'level') end
local function audit(W)
  return X.audit(W, {ok = true, fails = {}, min_traps = 35, bypass = false, refuge_sep = true, civ_sep = true, caverns = true})
end

T.test('BUG-096: an open episode whose lost tiles held a well or the refuge is the R0 blocker burrow_lost; SIEGE_UNREADY names ' ..
       'the burrow, the tiles and what the kernel does; the blocker goes with the episode (old code: R1 with a refuge of one tile)',
       function()
  local sf = seal_fake()
  local W = world{seal = sf}
  day(W)
  audit(W)
  T.eq(lvl(W), 1, 'no episode: R1')
  sf.eps = {{name = 'Tiefe+', was = 412, now = 0, gone = true, cause = 'runtime', crit = {'refuge'}, fx = 0, since = 5000,
             st = 'repairing'}}
  day(W)
  T.eq({lvl(W), ready(W).fail}, {0, {'burrow_lost'}})
  day(W, 2)
  local u = W.find_events('SIEGE_UNREADY')
  T.eq(#u, 1)
  local want = 'Tiefe+ is gone (412 -> 0 tiles) and held the refuge: repairing'
  T.ok(tostring(u[1].d.blost):find(want, 1, true), tostring(u[1].d.blost))
  T.ok(u[1].msg:find('siege unready (R0: burrow_lost); ' .. want, 1, true), u[1].msg)
  T.ok(#u[1].msg <= 200)
  sf.eps = {}
  day(W)
  T.eq(lvl(W), 1, 'repaired: the blocker goes')
end)

T.test('BUG-096: a well among the lost tiles blocks, the hospital alone does not (hospital_out is its blocker: one blocker, not two), ' ..
       'other tiles do not', function()
  local sf = seal_fake()
  local W = world{seal = sf}
  day(W)
  audit(W)
  sf.eps = {{name = 'Kern+', was = 3120, now = 12, gone = false, cause = 'load', crit = {'hospital'}, fx = 0, since = 5000,
             st = 'repairing'}}
  day(W)
  T.eq(lvl(W), 1, 'the hospital is hospital_out\'s')
  sf.eps = {{name = 'Kern+', was = 3120, now = 12, gone = false, cause = 'load', crit = {}, fx = 0, since = 5000, st = 'repairing'}}
  day(W)
  T.eq(lvl(W), 1, 'tiles that held nothing vital')
  sf.eps = {{name = 'Kern+', was = 3120, now = 12, gone = false, cause = 'load', crit = {'well', 'hospital'}, fx = 0,
             since = 5000, st = 'waits for peace'}}
  day(W)
  T.eq({lvl(W), ready(W).fail}, {0, {'burrow_lost'}}, 'one blocker')
  day(W, 2)
  local u = W.find_events('SIEGE_UNREADY')
  T.ok(tostring(u[1].d.blost):find('Kern+ lost its tiles (3120 -> 12 tiles) and held a well: waits for peace', 1, true),
       tostring(u[1].d.blost))
end)

T.test('BUG-096: a seal without burrow_guard (an older kernel, a module that is off) is no blocker: fail-open; the same seal with ' ..
       'an episode is', function()
  local sf = {name = 'seal', every = {ticks = 600}}
  function sf.entrance_doors(K) return {tick = 1, sealed = 1, routes = 0, doors = {}, open = {}} end
  local W = world{seal = sf}
  day(W)
  audit(W)
  T.eq(lvl(W), 1)
  function sf.burrow_guard(K)
    return {{name = 'Kern+', was = 100, now = 3, gone = false, cause = 'runtime', crit = {'well'}, fx = 0, since = 1, st = 'repairing'}}
  end
  day(W)
  T.eq({lvl(W), ready(W).fail}, {0, {'burrow_lost'}})
end)

T.done()
