-- Run 15c Inkintense famine (fix10-famine): the player's pop ceiling survives a plan reload and holds until he lifts it
-- or the food it was set for is back, the kernel's own famine hold, popcap.raise / popcap.set (BUG-293); no automatic
-- drill while food or drink is low (BUG-294). k_mock (strict) with the WP5/WP6 modules (wp6_world). Every test fails
-- on 05dc764.
local T = require('testlib')
local X = require('wp6_world')

local NOW0 = 3 * 403200 + 1000
local SKILLS = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}

local function plan(ceiling)
  return {v = 2, year = 3, phase_target = 'P7', seasons = {{build = {}}, {build = {}}, {build = {}}, {build = {}}},
          policy = {option = 'A', pop_ceiling = ceiling or 55, beauty = 'used_rooms'}}
end

-- readiness world as tests/lua/test_readiness.lua (fixture caps 55/55/75/250), n citizens, the fake economy's stock
local function world(opts)
  opts = opts or {}
  local units = X.citizens(opts.n or 50, 1, {skills = SKILLS})
  local W = X.world{units = units, persist = {}}
  W.K.cfg.decisions['D-01'] = 'A'
  if opts.plan then W.set_plan(opts.plan) end
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.econ = X.economy(opts.stock or {drink_d = 200, food_d = 90, meals = 5})
  X.load(W, {'military', 'readiness'}, {W.econ, X.snapshot(), runner}, {'sense', 'gate'})
  X.mod('readiness').CAPS = {[0] = 55, [1] = 55, [2] = 75, [3] = 250}
  return W
end
local function day(W, n) W.run(1200 * (n or 1), {skip = 9}); W.state() end
local function food(W, d) W.econ.stock.food_d = d; W.state() end      -- K.view() reads the last state
local function pop(W) return W.state().pop end
local function whys(W)
  local r = {}
  for _, e in ipairs(W.find_events('POPCAP')) do r[#r + 1] = e.d.why end
  return r
end

---------------------------------------------------------------- BUG-293 the player's ceiling
T.test('BUG-293 (Inkintense #1264/#1312/#1375: popcap.lower 25 lost, max-pop 100 again, migrants 26 -> 50 in a famine): ' ..
       'a plan reload keeps the player ceiling; set at low food it is lifted once food is back at 60 days', function()
  local W = world{n = 20, stock = {drink_d = 200, food_d = 5, meals = 1}, plan = plan(55)}
  day(W)
  T.eq(pop(W).gate_cap, 55)
  local r = W.inbox('popcap.lower', {cap = 15})
  T.ok(r.ok, r.msg)
  T.ok(r.msg:find('held until food 60 d or popcap.raise', 1, true), r.msg)
  T.eq(pop(W).hold, 'player 15 until food 60 d')
  W.plan_file = plan(55)
  W.run(9, {skip = 9})
  W.inbox('plan.reload', {})
  day(W, 2)
  T.eq(pop(W).gate_cap, 15, 'old code: the reload dropped the player ceiling (R0 55 again)')
  food(W, 59)
  day(W)
  T.eq(pop(W).gate_cap, 15, 'below 60 days it holds')
  food(W, 60)
  day(W)
  T.eq(pop(W).gate_cap, 55, 'food back: lifted')
  T.eq(pop(W).hold, nil)
end)

T.test('BUG-293: until=raise holds through good food; popcap.raise lifts it; popcap.set raises or lowers it exactly', function()
  local W = world{n = 20, plan = plan(55)}
  day(W)
  local r = W.inbox('popcap.lower', {cap = 30})
  T.ok(r.ok and r.msg:find('held until popcap.raise', 1, true), r.msg)
  T.eq(pop(W).hold, 'player 30 until popcap.raise', 'food 90 d: held until the player lifts it')
  T.eq(W.inbox('popcap.lower', {cap = 20, ['until'] = 'later'}).ok, false, 'until: food or raise')
  day(W, 3)
  T.eq(pop(W).gate_cap, 30)
  r = W.inbox('popcap.raise', {})
  T.ok(r.ok, r.msg)
  T.ok(r.msg:find('lifted player 30', 1, true), r.msg)
  T.eq(pop(W).gate_cap, 55)
  r = W.inbox('popcap.set', {cap = 25})
  T.ok(r.ok, r.msg)
  T.eq(pop(W).gate_cap, 25)
  r = W.inbox('popcap.set', {cap = 40})
  T.ok(r.ok, r.msg)
  T.eq(pop(W).gate_cap, 40, 'popcap.set raises the player ceiling')
  r = W.inbox('popcap.set', {cap = 90})
  T.ok(r.msg:find('binding: 55 R0', 1, true), r.msg)
  T.eq(pop(W).gate_cap, 55, 'never above the level cap')
  T.eq(W.inbox('popcap.set', {cap = 0}).ok, false)
  T.eq(W.inbox('popcap.raise', {}).msg:sub(1, 7), 'lifted ')
  T.eq(W.inbox('popcap.raise', {}).msg:sub(1, 22), 'no player ceiling held')
end)

---------------------------------------------------------------- BUG-293 the kernel's famine hold
T.test('BUG-293: food below 15 days and falling holds max-pop at the population (POPCAP why famine) until food is back ' ..
       'at 30 days; popcap.raise lifts it for the episode', function()
  local W = world{n = 40, stock = {drink_d = 200, food_d = 20, meals = 1}, plan = plan(55)}
  day(W, 2)
  T.eq(pop(W).gate_cap, 55)
  food(W, 14)
  day(W)
  T.eq(pop(W).gate_cap, 40, 'old code: no famine hold (55)')
  T.eq(pop(W).hold, 'famine 40 (food 14 d)')
  T.eq(whys(W)[#whys(W)], 'famine')
  T.eq(W.K.census.u.cit, 40)
  food(W, 29)
  day(W, 2)
  T.eq(pop(W).gate_cap, 40, 'held below 30 days')
  food(W, 30)
  day(W)
  T.eq(pop(W).gate_cap, 55, 'recovered')
  T.eq(pop(W).hold, nil)
  -- steady low food is no onset; falling again is; the player's raise lifts the hold until food recovers
  food(W, 10)
  day(W)
  food(W, 10)
  day(W)
  T.eq(pop(W).hold, 'famine 40 (food 10 d)', 'falling from 30 to 10')
  T.ok(W.inbox('popcap.raise', {}).msg:find('famine 40', 1, true))
  food(W, 5)
  day(W, 2)
  T.eq(pop(W).hold, nil, 'lifted by the player for this episode')
  T.eq(pop(W).gate_cap, 55)
  food(W, 40)
  day(W)
  food(W, 12)
  day(W)
  T.eq(pop(W).hold, 'famine 40 (food 12 d)', 'a new episode after the recovery')
end)

T.test('BUG-293 review: a player ceiling between the famine hold and the plan is kept for after the famine', function()
  local W = world{n = 40, stock = {drink_d = 200, food_d = 20, meals = 1}, plan = plan(55)}
  day(W, 2)
  food(W, 14)
  day(W)
  T.eq(pop(W).gate_cap, 40, 'famine hold')
  local r = W.inbox('popcap.lower', {cap = 45})
  T.ok(r.ok and r.msg:find('held until food 60 d', 1, true), 'old fix: "ceiling already 40", 45 dropped: ' .. r.msg)
  food(W, 30)
  day(W)
  T.eq(pop(W).gate_cap, 45, 'famine over: the player ceiling binds, not the plan 55')
end)

T.test('BUG-293: the hold and the player ceiling survive a reload (persist m.readiness)', function()
  local W = world{n = 30, stock = {drink_d = 200, food_d = 20, meals = 1}, plan = plan(55)}
  day(W)
  W.inbox('popcap.lower', {cap = 12, ['until'] = 'raise'})
  food(W, 3)
  day(W)
  local p = W.K.persist.get('m.readiness')
  T.eq(p.inbox.cap, 12)
  T.eq(p.inbox.u, 'raise')
  T.eq(p.fam.cap, 30)
  local R = X.mod('readiness')
  R.init(W.K)
  T.eq(R.hold_text(W.K), 'player 12, famine 30 (food 3 d)')
  T.eq((R.ceiling(W.K, 0)), 12)
end)

---------------------------------------------------------------- BUG-294 no automatic drill in a famine
local function dworld(stock)
  local units = X.citizens(30, 1, {skills = SKILLS})
  local W = X.world{units = units}
  W.runner = X.runner('P5')
  W.econ = X.economy(stock)
  X.load(W, nil, {W.econ, X.snapshot(), W.runner})
  X.run(W, 1200)
  X.equip_all(W)
  X.run(W, 50)
  return W
end

T.test('BUG-294 (Inkintense #1403 food 9 d, #1488 food 1 d: automatic drills in a famine): no automatic drill below 30 ' ..
       'food or drink days or with the supply alarm; ready.dhold names it; the player\'s drill still runs', function()
  local W = dworld({drink_d = 200, food_d = 9, meals = 1})
  X.run(W, 3600)
  T.eq(W.K.mode(), 'PEACE', 'old code: auto: first at food 9 d')
  T.eq(X.call(W, 'drill', 'hold'), 'supply: food 9 d')
  X.run(W, 1200)
  T.eq(W.state().ready.dhold, 'supply: food 9 d')
  W.econ.stock.food_d, W.econ.stock.drink_d = 90, 20
  W.state()
  T.eq(X.call(W, 'drill', 'hold'), 'supply: drink 20 d')
  W.econ.stock.drink_d = 200
  W.state()
  function W.econ.alarm() return 'hunger 3' end
  T.eq(X.call(W, 'drill', 'hold'), 'supply: hunger 3')
  W.econ.alarm = nil
  X.run(W, 1300)
  T.eq(W.K.mode(), 'DRILL', 'supply fine: the automatic drill runs')
  local W2 = dworld({drink_d = 200, food_d = 2, meals = 1})
  local ok = X.call(W2, 'drill', 'start', 'inbox:llm')
  T.eq(ok, true, 'the player\'s drill is his choice')
end)

T.done()
