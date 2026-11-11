-- BUG-766 (Run 16a i1 Basementflew y509-y540: readiness said refuge_dry in 47 events (SIEGE_UNREADY, status) for 30 game years and never asked; at the y540
-- surprise siege the deep defense wanted Tiefe+, REFUGE_FAIL 'no drink (drink 0<50, no well)' sent the civilians to Kern+, where a cave dragon and goblins
-- killed 11 of them; the refuge drink store could not be placed, the manifest has no refuge room): DECISION_NEEDED refuge_dry (A) in PEACE once the
-- refuge has stood dry RDRY_GRACE ticks, again every DEF.ask_days days; it names what the fight does without it and the fix that applies (the store
-- template, the store that waits for barrels, the project under way, or no refuge room in the manifest); nothing while the refuge has drink or in a fight.
local T = require('testlib')
local X = require('wp6_world')
local S = require('siege_world')

local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end

local function world(o)
  o = o or {}
  local units = X.citizens(50, 1, {skills = SKILLS})
  local W = X.world{units = units, persist = {}, manifest = o.manifest}
  W.K.cfg.decisions['D-01'] = 'A'
  local sf = {name = 'seal', every = {ticks = 600}, x = {tick = 1, sealed = 1, routes = 0, doors = {}, open = {}}}
  function sf.entrance_doors(K) return sf.x end
  sf.rd = {name = 'Tiefe+', exists = true, drink = 0, need = 50, wells = 0, wet = false, store = o.store}
  function sf.refuge_drink(K) return sf.rd end
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  runner.pending = function(K, tpl) return o.pending or 0 end
  W.econ, W.snap, W.sf = X.economy(), X.snapshot(), sf
  X.load(W, {'military', 'readiness'}, {W.econ, W.snap, runner, sf}, {'sense', 'gate'})
  X.mod('readiness').CAPS = {[0] = 55, [1] = 55, [2] = 75, [3] = 250}
  X.mod('readiness').OPEN_CONFIRM, X.mod('readiness').DEF.worn_pct = 0, 0
  return W
end

local function asks(W)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'refuge_dry' then r[#r + 1] = e end end
  return r
end

T.test('BUG-766: a dry refuge in PEACE is asked once after the grace, with the store command; again only after ask_days', function()
  local W = world()
  day(W, 1)
  T.eq(#asks(W), 0, 'not yet: the settle and the grace period')
  day(W, 6)
  local a = asks(W)
  T.eq(#a, 1, 'asked (old: never, only SIEGE_UNREADY / status said refuge_dry)')
  T.eq(a[1].cls, 'A')
  T.eq(a[1].d.cause, 'store')
  T.eq({a[1].d.n, a[1].d.nd}, {0, 50})
  T.ok(a[1].d.q:find('REFUGE_FAIL', 1, true) and a[1].d.q:find('Kern+', 1, true), a[1].d.q)
  T.eq(a[1].d.cmds, {[[dfllm cmd bp.place '{"tpl":"refuge_drink","site":"S1"}']]})
  day(W, 20)
  T.eq(#asks(W), 1, 'not again within ask_days (30)')
  day(W, 12)
  T.eq(#asks(W), 2, 'again after ask_days while it stays dry')
end)

T.test('BUG-766: the cause shows what applies: a store that waits for barrels, a project under way, no refuge room in the manifest', function()
  local W = world{store = {n = 1, tiles = 12, drink = 0}}
  day(W, 7)
  local a = asks(W)
  T.eq(a[1].d.cause, 'barrels')
  T.ok(a[1].d.q:find('waits for barrels', 1, true), a[1].d.q)
  local W2 = world{pending = 1}
  day(W2, 7)
  a = asks(W2)
  T.eq(a[1].d.cause, 'pending')
  T.eq(a[1].d.cmds, nil, 'a project is under way: no second command')
  local man = S.manifest()
  man.refuge = nil                                   -- Run 16a i1: the manifest has no refuge room (fortcore stage 3 is impossible)
  local W3 = world{manifest = man}
  day(W3, 7)
  a = asks(W3)
  T.eq(a[1].d.cause, 'no_room')
  T.ok(a[1].d.q:find('no refuge room', 1, true), a[1].d.q)
  T.ok(a[1].d.cmds[1]:find('inspect', 1, true), 'no bp.place for a refuge that is not in the manifest: ' .. T.show(a[1].d.cmds))
end)

T.test('BUG-766: no question while the refuge has drink or a wet well, none in a fight; drink arriving ends it', function()
  local W = world()
  W.sf.rd = {name = 'Tiefe+', exists = true, drink = 80, need = 50, wells = 0, wet = true}
  day(W, 6)
  T.eq(#asks(W), 0, 'drink 80 >= 50')
  local W2 = world()
  W2.K.set_mode('SIEGE', 'test')
  day(W2, 6)
  T.eq(#asks(W2), 0, 'not in a SIEGE')
  local W3 = world()
  day(W3, 1)
  W3.sf.rd = {name = 'Tiefe+', exists = true, drink = 60, need = 50, wells = 0, wet = true}
  day(W3, 6)
  T.eq(#asks(W3), 0, 'it filled before the grace ended')
end)

T.done()
