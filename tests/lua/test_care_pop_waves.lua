-- BUG-279 (Run 15 Earthboat y374): brief 'migrants in 365 d: 0 waves, 0 people (last 673 d ago)' while the fort grew from
-- 7 to 21 citizens without a birth; one MIGRANTS (n=6) for three or more waves. care counted waves only from economy's
-- MIGRANTS, which needs DF's arrival report. Now the census counts them too: new non-baby citizen ids, clustered.
local T = require('testlib')
local CW = require('care_world')
local F = CW.F

local function world()
  local W, care = CW.world{cit = 7}
  W.run(2)                                                     -- the first read learns the 7 founders
  return W, care
end

-- n new citizens (ids from `first`) join the census; baby = born here
local function arrive(W, first, n, baby)
  local ids = {}
  for _, id in ipairs(W.K.census.u.ids) do ids[#ids + 1] = id end
  for i = 0, n - 1 do
    W.add_unit{id = first + i, citizen = true, pos = {5, 5, 5}, baby = baby or nil}
    ids[#ids + 1] = first + i
  end
  W.set_census('u', F.census_u(ids))
end

local function pop(W) return W.state().care.pop end

T.test('BUG-279: two waves the census saw (6 and 8) without any MIGRANTS: 2 waves, 14 people', function()
  -- old code: 0 waves, 0 people
  local W = world()
  T.eq({pop(W).waves, pop(W).mig}, {0, 0}, 'the founders are no wave')
  arrive(W, 100, 4)
  W.run(400, {skip = 100})
  arrive(W, 104, 2)                                           -- the same wave, a few hours later
  CW.day(W, 30)
  arrive(W, 200, 8)
  CW.day(W, 5)
  T.eq({pop(W).waves, pop(W).mig}, {2, 14})
  T.ok(pop(W).lastw >= 3 and pop(W).lastw <= 5, tostring(pop(W).lastw))
end)

T.test('BUG-279: a census wave and its MIGRANTS are one wave (the bigger n); a baby born here is no migrant', function()
  local W, care = world()
  arrive(W, 100, 6)
  care.on['EV:MIGRANTS'](W.K, {d = {n = 0}, tick = W.K.now().tick})   -- the report came, the census caught up later
  CW.day(W, 4)
  T.eq({pop(W).waves, pop(W).mig}, {1, 6})
  arrive(W, 300, 1, true)                                     -- a birth
  CW.day(W, 4)
  T.eq({pop(W).waves, pop(W).mig}, {1, 6}, 'no wave for a baby')
end)

T.done()
