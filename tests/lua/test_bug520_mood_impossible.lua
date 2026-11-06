-- BUG-520 (Run 16a y375/y376 and 16d i4 y383: moods died for bone, glass and metal bars the fort could not make: `butcher.mark` 'no
-- animal to mark', a Secretive mood 'glass x1' in a soil fort without furnace or sand, 'bars(metal) x1' without ore): the kernel says
-- early what is impossible (economy.mood_hint, route, care's MOOD_RISK route and the mood_deadline `imp`), asks the caravans for bone
-- (reserve R.BUY), and never judges a pet or a war animal slaughterable.
local T = require('testlib')
local F = require('wp8_world')
local CW = require('care_world')
local R = require('dfllm.reserve')

local function fresh_mod(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local function econ(animals, inv)
  local W = F.world{cfg = {baseline = F.cfg()}, units = {{id = 1, citizen = true}}}
  W.set_census('u', F.census_u({1}))
  W.set_census('a', animals and {tick = 0, n = #animals, list = animals} or nil)
  W.set_census('i', inv or {})
  local E = fresh_mod('economy')
  W.load(E)
  return W, E
end

T.test('BUG-520: a bone mood with only pets and war animals: nothing can be slaughtered, no hunter: impossible, exact words', function()
  local W, E = econ({{id = 1, race = 5, adult = true, pet = true}, {id = 2, race = 7, adult = true, war = true},
                     {id = 3, race = 8, adult = true, pet = true}})
  local txt, imp = E.mood_hint(W.K, 'bone')
  T.eq(imp, true)
  T.ok(txt:find('no animal can be slaughtered (3 tame: pets, war and hunting animals stay)', 1, true), txt)
  T.ok(txt:find('no hunter can shoot', 1, true), txt)
  T.ok(E.route(W.K, 'bone'):find('trade.want bone', 1, true), E.route(W.K, 'bone'))
end)

T.test('BUG-520: with a crossbow a bone is not impossible (hunting), with a surplus adult it names butcher.mark; pets stay out of the count', function()
  local W, E = econ({{id = 1, race = 5, adult = true, pet = true}}, {w_xbow = 1})
  local txt, imp = E.mood_hint(W.K, 'bone')
  T.eq(imp, false)
  T.ok(txt:find('hunting is the way', 1, true), txt)
  local W2, E2 = econ({{id = 1, race = 5, adult = true, pet = true}, {id = 2, race = 6, adult = true, female = true},
                       {id = 3, race = 6, adult = true, war = true}})
  txt, imp = E2.mood_hint(W2.K, 'bone')
  T.eq(imp, false)
  T.ok(txt:find('1 tame animal can be slaughtered (butcher.mark)', 1, true), txt)
  T.eq(E2.slaughter_pick(W2.K.census.a.list, {keep_f = 0, keep_m = 0, max = 10, adult_first = true}), {2}, 'the pet and the war animal never')
end)

T.test('BUG-520: bars without ore, melt or smelter and glass without a furnace are named; metal marked for melting is a source', function()
  local W, E = econ({}, {ore = 0, melt = 0})
  local txt, imp = E.mood_hint(W.K, 'bars')
  T.ok(txt:find('no ore and no metal marked for melting', 1, true) and txt:find('no smelter', 1, true) and txt:find('bar:iron', 1, true), txt)
  T.ok(E.route(W.K, 'bars'):find('melt metal items', 1, true), E.route(W.K, 'bars'))
  W.K.census.i = {ore = 0, melt = 4}
  T.eq(E.mood_hint(W.K, 'bars'), nil, 'marked metal: a smelter melts it, no verdict')
  txt = E.mood_hint(W.K, 'glass')
  T.ok(txt:find('no glass furnace', 1, true), txt)
end)

T.test('BUG-520: a bone need is a trade token now (the caravans are asked, not only the butcher)', function()
  T.eq(R.token({cls = 'bone'}), 'bone')
  T.eq(R.token({cls = 'shell'}), nil, 'shell has no trade kind')
  T.eq(R.token({cls = 'leather'}), 'leather')
end)

T.test('BUG-520: mood_deadline says what is impossible first (d.imp) and keeps the ready trade.want for bone', function()
  local W, Cm = CW.world{cit = 4, setup = function(W)
    local u = W.unit(1)
    u.mood = df.mood_type.Fey
    u.counters2 = {thirst_timer = 2000, hunger_timer = 1000}
    u.job.mood_timeout = 8 * 1200
  end}
  W.load({name = 'economy', every = {ticks = 1200},
          mood_hint = function(K, cls) if cls == 'bone' then return 'no animal can be slaughtered (3 tame: pets, war and hunting animals stay)', true end end})
  local u = W.unit(1)
  local rec = {sl = {}, nosrc = {'bone'}, buy = {'bone'}}
  Cm.mood_deadline(W.K, Cm.DEFAULTS, u, rec, 'Fey', 'Udil', 8, {'material'}, {'bone'}, {}, nil)
  local ds = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'mood_deadline' then ds[#ds + 1] = e end end
  T.eq(#ds, 1)
  local d = ds[1].d
  T.ok(d.q:find('IMPOSSIBLE here: bone: no animal can be slaughtered', 1, true), d.q)
  T.eq(#d.imp, 1)
  T.ok(d.cmds[1]:find('"bone"', 1, true), d.cmds[1])
end)

T.done()
