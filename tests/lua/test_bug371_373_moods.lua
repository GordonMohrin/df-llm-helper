-- BUG-371..373 (Run 16d, i4 Plankscale y375-377: two strange-mood deaths by thirst and cloth/gems 'missed'). Every test here
-- fails on 2fcd6e0.
--   BUG-371: the drink nook of a moody dwarf stood frozen in a DRILL, behind the mood slots, and care queued none in ALERT/DRILL;
--            the runner stayed paced; MOOD_RISK said 'queued' after the nook stood
--   BUG-372: the cloth/thread chain asked the Loom only (no Farmers for the spun thread); a material none in the fort asked the
--            caravan without saying so with the days left
--   BUG-373: readiness' 'mood shops missing' cut the shops a mood waits for (Loom, Clothiers are the last of twelve)
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')
local MD = require('dfllm.mood')

local Z = 100
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function row(W, id)
  for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end
end
local function why(W, id) local r = row(W, id); return r and r[4] end

local function world(tag, mode)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160}}
  W.ctl = {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = W.ctl.stock} end})
  W.load(runner)
  if mode then W.set_mode(mode) end
  W.state()
  H.floor(W, 60, 60, Z, 64, 60)
  return W
end

T.test('BUG-371: in a DRILL the nook is placed (life support), a bedroom stays frozen', function()
  local W = world('drill', 'DRILL')
  H.place(W, 'bd1', H.dig_doc(2, {tpl = 'bedrooms', class = 'living', params = {n = 4}, x = 10, label = 'dig'}))
  local _, ok, id = W.K.call('runner', 'mooddrink', {61, 60, Z}, '', 'test')
  T.ok(ok)
  H.runs(W, 2)
  T.eq(H.proj(W, id).done, 1, 'old code: frozen in the DRILL')
  T.eq(why(W, 'bd1'), 'frozen', 'the bedroom stays frozen')
end)

T.test('BUG-371: the nook needs no slot of mood_slots: seals first take the slots, the mood slots are taken, it still runs', function()
  local W = world('cap')
  runner.CFG.active = 2
  runner.CFG.mood_slots = 0                    -- every mood slot taken
  for i, x in ipairs({10, 30}) do
    H.place(W, 's' .. i, H.dig_doc(2, {tpl = 'seal', class = 'defense', params = {}, x = x, label = 'dig'}))
  end
  H.runs(W, 1)
  local _, ok, id = W.K.call('runner', 'mooddrink', {61, 60, Z}, '', 'test')
  T.ok(ok)
  H.runs(W, 1)
  T.eq(H.proj(W, id).done, 1, 'old code: queued behind the two seals')
end)

T.test('BUG-371: a pending nook says it starts next run, not "queued behind <holder>"', function()
  local W = world('row')
  runner.CFG.active = 1
  H.place(W, 'w1', H.dig_doc(2, {tpl = 'hall', class = 'living', params = {}, x = 10, label = 'dig'}))
  H.runs(W, 1)
  local _, ok, id = W.K.call('runner', 'mooddrink', {61, 60, Z}, '', 'test')
  T.ok(ok)
  local w = why(W, id)
  T.ok(w == nil or w == '' or w == 'mood: starts next run', 'old code: ' .. tostring(w))
  T.ok(not (w or ''):find('queued behind', 1, true))
end)

T.test('BUG-371: a pending nook asks kern for the boost, and drops it once the nook stands', function()
  local W = world('boost')
  local boosts, unboosts = 0, 0
  W.K.boost = function(why) boosts = boosts + 1; return true end
  W.K.unboost = function() unboosts = unboosts + 1 end
  local _, ok, id = W.K.call('runner', 'mooddrink', {61, 60, Z}, '', 'test')
  T.ok(ok)
  H.runs(W, 1)
  T.ok(boosts >= 1, 'old code: runner never boosted')
  H.runs(W, 2)
  T.eq(H.proj(W, id).done, 1)
  T.ok(unboosts >= 1, 'dropped when done')
end)

T.test('BUG-373: runner.mood_wanted lists the shops the open moods wait for, sorted', function()
  local W = world('wanted')
  W.K.call('runner', 'mood_types', '5', {'Loom', 'Clothiers'})
  W.K.call('runner', 'mood_types', '6', {'Farmers'})
  local _, l = W.K.call('runner', 'mood_wanted')
  T.eq(l, {'Clothiers', 'Farmers', 'Loom'})
  W.K.call('runner', 'mood_types', '5', {})
  local _, l2 = W.K.call('runner', 'mood_wanted')
  T.eq(l2, {'Farmers'})
end)

T.test('BUG-372: cloth asks the Loom and the Farmers workshop, thread the Farmers workshop', function()
  T.eq(MD.chain({'cloth'}, {Loom = true, Farmers = true}), {'Loom', 'Farmers'})
  T.eq(MD.chain({'thread'}, {Loom = true, Farmers = true}), {'Farmers'})
  T.eq(MD.chain({'cloth', 'leather'}, {Loom = true, Farmers = true, Tanners = true, Butchers = true}),
       {'Loom', 'Farmers', 'Tanners', 'Butchers'})
  T.eq(MD.chain({'cloth'}, {Farmers = true}), {'Farmers'}, 'a Loom that stands is not asked again')
  T.ok(MD.EXTRA[2] == 'Farmers' or MD.EXTRA[1] == 'Farmers')
end)

-- care / mood emergency / readiness (the same file keeps the three bugs together) --------------------------------------------
local CW = require('care_world')
local F = CW.F

local function filter(item, spec)
  local f = {item_type = df.item_type[item], mat_type = -1, mat_index = -1, quantity = 1, flags2 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end

local function shops_fake(W, missing)
  return {name = 'economy', every = {ticks = 1200}, mood_shops = function(K) return {missing = missing, queued = {}} end}
end

local function mood_reqs(W)
  local r = {}
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do
    if e.d.tpl == 'workshops' and e.d.why == 'mood' then r[#r + 1] = e end
  end
  return r
end

local function cloth_world(farmers)
  return CW.world{cit = 6, setup = function(W)
    W.load(shops_fake(W, {'Loom'}))
    if farmers then F.workshop(W, 'Farmers') end
    local u = W.unit(2)
    u.mood = df.mood_type.Secretive
    u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
    u.job.current_job = CW.mood_job(W, 906, F.workshop(W, 'Masons'), {filter('CLOTH', {quantity = 10000, flags2 = {silk = true}})})
  end}
end

T.test('BUG-372: a mood without cloth asks the Loom and a Farmers workshop (thread) at prio 1; a standing Farmers is not asked', function()
  local W = cloth_world(false)
  CW.day(W, 1)
  local r = mood_reqs(W)
  T.ok(#r >= 1)
  local set = {}
  for _, t in ipairs(r[#r].d.types) do set[t] = true end
  T.ok(set.Loom and set.Farmers, table.concat(r[#r].d.types, ','))
  local W2 = cloth_world(true)
  CW.day(W2, 1)
  local r2 = mood_reqs(W2)
  T.eq(r2[#r2].d.types, {'Loom'})
end)

T.test('BUG-372: a material none in the fort asks the caravan at once, MOOD_CRITICAL says so after the line with the days left', function()
  local W = cloth_world(true)
  CW.day(W, 1)
  local c = {}
  for _, e in ipairs(W.find_events('MOOD_CRITICAL')) do c[#c + 1] = e end
  T.ok(#c >= 1)
  T.ok(c[1].msg:find(' d left', 1, true) and c[1].msg:find('caravans asked: cloth:silk', 1, true), c[1].msg)
  T.ok(#c[1].msg <= 200)
end)

T.test('BUG-373: readiness names the shops a mood waits for first and counts them at once', function()
  local X = require('wp6_world')
  local W = X.world{units = X.citizens(50, 1, {skills = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}})}
  local econ, runner_fake = X.economy(), X.runner('P5')
  local miss = {'Carpenters', 'Masons', 'Craftsdwarfs', 'Jewelers', 'Bowyers', 'Clothiers', 'Tanners', 'Loom'}
  econ.mood_shops = function(K) return {missing = miss, queued = {}} end
  runner_fake.mood_wanted = function(K) return {'Loom'} end
  X.load(W, {'military', 'readiness'}, {econ, X.snapshot(), runner_fake}, {'sense', 'gate'})
  W.run(1200, {skip = 9}); W.state()
  local m = W.state().ready.mws
  T.ok(m ~= nil and m:find('mood shops missing 0 days: Loom (1 a mood waits for)', 1, true), 'at once, alone: ' .. tostring(m))
  W.run(1200 * 8, {skip = 9}); W.state()
  m = W.state().ready.mws
  T.ok(m:find('Loom,Carpenters,Masons +5 (1 a mood waits for)', 1, true), 'first of eight: ' .. tostring(m))
  T.ok(m:find('"only":"Loom,Carpenters,Masons"', 1, true), m)
  T.ok(#m <= 200)
end)

T.done()
