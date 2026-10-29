-- BUG-282..285 (Run 15: four strange moods failed in three forts within ~3 game years; Drillchamber's fey glassmaker 26535
-- went insane 54,481 ticks after he claimed the Glass Furnace, which came 30 days late, and the Possessed carpenter 26396
-- went berserk for silk and plant cloth; neither got a MOOD_CRITICAL, the bar was thirst 50,000 / hunger 60,000 alone).
-- Every test here fails on 64df679.
local T = require('testlib')
local CW = require('care_world')
local F = CW.F
local H = require('runner_world')
local runner = require('dfllm.runner')
local MD = require('dfllm.mood')

local DAY = 1200

local function filter(t, spec)
  local f = {item_type = t and df.item_type[t] or -1, mat_type = -1, mat_index = -1, quantity = 1, flags2 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end

local function shops_fake(W, missing)
  W.missing = missing
  return {name = 'economy', every = {ticks = 1200},
          mood_shops = function(K) return {missing = W.missing, queued = {}} end}
end

-- the wall clock a minute on (util/cadence: a repeat waits mood_crit_wall_s real seconds too)
local function later(W) W.ms = W.ms + 60000 end

local function crits(W, why)
  local r = {}
  for _, e in ipairs(W.find_events('MOOD_CRITICAL')) do if why == nil or e.d.why == why then r[#r + 1] = e end end
  return r
end

local function mood_reqs(W)
  local r = {}
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do
    if e.d.tpl == 'workshops' and e.d.why == 'mood' then r[#r + 1] = e end
  end
  return r
end

-- the glassmaker: a fey mood whose job wants two iron bars (none in the fort), no workshop claimed, his shop missing
local function glassmaker(o)
  o = o or {}
  return CW.world{cit = 6, census_i = o.census_i, setup = function(W)
    W.load(shops_fake(W, o.missing or {'GlassFurnace', 'Loom'}))
    F.mat(W, 0, 9, {token = 'INORGANIC:IRON'})
    local u = W.unit(2)
    u.mood = df.mood_type.Fey
    u._m.skills = {GLASSMAKER = 6}
    u.counters2 = {thirst_timer = 2000, hunger_timer = 1000}
    u.job.current_job = CW.mood_job(W, 902, nil, {filter('BAR', {mat_type = 0, mat_index = 9, quantity = 300})})
    if o.setup then o.setup(W, u) end
  end}
end

T.test('BUG-282: a mood without a workshop and with a material none in the fort is MOOD_CRITICAL at thirst 2,000', function()
  local W = glassmaker()
  CW.day(W, 1)
  later(W)
  CW.day(W, 1)
  local c = crits(W)
  T.ok(#c >= 1, 'old code: no MOOD_CRITICAL below thirst 50,000 / hunger 60,000')
  local d = c[1].d
  T.eq(c[1].cls, 'A')
  T.eq({d.unit, d.kind, d.need}, {2, 'Fey', 'GlassFurnace'})
  T.ok(d.reasons[1] == 'workshop' or d.reasons[1] == 'material', table.concat(d.reasons, ','))
  local all = table.concat(c[#c].d.reasons, ',')
  T.ok(all:find('workshop', 1, true) and all:find('material', 1, true), all)
  T.eq(d.left, -1, 'no claim yet: DF has not started the clock')
  T.ok(c[1].msg:find('MOOD ', 1, true) and c[1].msg:find('no GlassFurnace', 1, true), c[1].msg)
  T.ok(c[1].msg:find('time unknown', 1, true), c[1].msg)
  T.ok(#c[1].msg <= 200)
  T.eq(W.bad_vectors, {})
end)

T.test('BUG-283: the kernel asks for only the missing shop (types, why=mood) at once, not a plain workshops placement',
       function()
  local W = glassmaker()
  CW.day(W, 1)
  local r = mood_reqs(W)
  T.ok(#r >= 1, 'old code: a plain {tpl=workshops, why=mood} without types after a day')
  T.eq(r[1].d.types, {'GlassFurnace'})
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do
    T.ok(not (e.d.tpl == 'workshops' and e.d.types == nil), 'no untyped workshops request: ' .. e.msg)
  end
  -- the same set is not asked again within mood_act_every
  local n = #mood_reqs(W)
  W.run(600, {skip = 100})
  T.eq(#mood_reqs(W), n)
  -- the shop stands now: no more request, the critical line drops the shop
  W.missing = {}
  CW.day(W, 3)
  T.eq(#mood_reqs(W), n)
end)

T.test('BUG-282: DF\'s own mood timer: MOOD_CRITICAL timer within 10 days, again at 5 and 2 days, not in between', function()
  local W = CW.world{cit = 6, setup = function(W)
    W.load(shops_fake(W, {}))
    local u = W.unit(3)
    u.mood = df.mood_type.Possessed
    u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
    u.job.current_job = CW.mood_job(W, 903, F.workshop(W, 'Carpenters'), {})
    u.job.mood_timeout = 30 * DAY
  end}
  CW.day(W, 1)
  T.eq(crits(W), {}, 'nothing missing, 30 days left: quiet')
  W.unit(3).job.mood_timeout = 9 * DAY
  later(W)
  W.run(600, {skip = 100})
  local c = crits(W)
  T.eq(#c, 1)
  T.eq({c[1].d.why, c[1].d.left, c[1].d.lsrc, c[1].d.unit}, {'timer', 9, 'timer', 3})
  T.ok(c[1].msg:find('9 d left', 1, true), c[1].msg)
  W.unit(3).job.mood_timeout = 8 * DAY
  later(W)
  W.run(600, {skip = 100})
  T.eq(#crits(W), 1, 'the same step (10 days) is no news')
  W.unit(3).job.mood_timeout = 4 * DAY
  later(W)
  W.run(600, {skip = 100})
  T.eq(#crits(W), 2, 'the 5-day step says it again')
  W.unit(3).job.mood_timeout = 1 * DAY
  later(W)
  W.run(600, {skip = 100})
  T.eq(#crits(W), 3)
  T.eq(crits(W)[3].d.left, 1)
end)

T.test('BUG-282: no readable timer: the estimate counts mood_timer ticks from the claim and says so', function()
  local W = CW.world{cit = 6, setup = function(W)
    W.load(shops_fake(W, {}))
    local u = W.unit(4)
    u.mood = df.mood_type.Fey
    u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
    u.job.current_job = CW.mood_job(W, 904, F.workshop(W, 'Craftsdwarfs'), {})
  end}
  W.run(1)
  local claim = W.K.persist.get('m.care').moods['4'].claim
  T.ok(claim ~= nil, 'the claim tick is kept')
  W.K.persist.get('m.care').moods['4'].claim = claim - 42 * DAY        -- the claim 42 days ago: ~0 days left
  W.run(600, {skip = 100})
  local c = crits(W, 'timer')
  T.eq(#c, 1)
  T.eq(c[1].d.lsrc, 'est')
  T.ok(c[1].msg:find('est. from the claim', 1, true), c[1].msg)
end)

T.test('BUG-284: a silk slot with webs near and a Loom: one CollectWebs task at the Loom; buy tokens and the line in state',
       function()
  local loom
  local W = CW.world{cit = 6, census_i = {webs = 40, webs_near = 12}, setup = function(W)
    W.load(shops_fake(W, {}))
    loom = F.workshop(W, 'Loom')
    W.act_result('mood_task', function(id, job) return true, 4711 end)
    local u = W.unit(5)
    u.mood = df.mood_type.Possessed
    u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
    u.job.current_job = CW.mood_job(W, 905, F.workshop(W, 'Carpenters'),
                                    {filter('CLOTH', {quantity = 10000, flags2 = {silk = true}})})
  end}
  CW.day(W, 1)
  local a = W.find_acts('mood_task')
  T.eq(#a, 1, 'old code: no act for webs')
  T.eq({a[1].args[1], a[1].args[2]}, {loom.id, 'CollectWebs'})
  CW.day(W, 1)
  T.eq(#W.find_acts('mood_task'), 1, 'not again within mood_act_every')
  local s = W.state().mood
  T.ok(type(s) == 'table' and #s == 1, 'state mood')
  T.eq(s[1].u, 5)
  T.ok(s[1].t:find('^MOOD ') and s[1].t:find('Possessed needs cloth(silk) x1', 1, true), s[1].t)
  T.ok(s[1].t:find('have 0/1', 1, true) and s[1].t:find('none in the fort', 1, true), s[1].t)
  T.eq(s[1].buy, {'cloth:silk'})
  local c = crits(W, 'material')
  T.ok(#c >= 1)
  T.ok(c[1].d.webs ~= nil and c[1].d.webs:find('collect webs queued at Loom', 1, true), tostring(c[1].d.webs))
  -- the mood ends: the line goes
  W.unit(5).mood = -1
  CW.day(W, 1)
  T.eq(W.state().mood, nil)
end)

T.test('BUG-284: a missing cloth or leather chain names its shops in the typed request (Loom; Tanners, Butchers)', function()
  local W = CW.world{cit = 6, setup = function(W)
    W.load(shops_fake(W, {'Loom', 'Tanners', 'Jewelers'}))
    local u = W.unit(2)
    u.mood = df.mood_type.Secretive
    u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
    u.job.current_job = CW.mood_job(W, 906, F.workshop(W, 'Masons'),
                                    {filter('SKIN_TANNED'), filter('CLOTH', {quantity = 10000, flags2 = {plant = true}})})
  end}
  CW.day(W, 1)
  local r = mood_reqs(W)
  T.ok(#r >= 1)
  local set = {}
  for _, t in ipairs(r[#r].d.types) do set[t] = true end
  T.ok(set.Loom and set.Tanners and set.Butchers and not set.Jewelers, table.concat(r[#r].d.types, ','))
  -- review fix: the Butchers is no moodable type (economy.mood_shops never lists it): asked while none is built, not after
  local W2 = CW.world{cit = 6, setup = function(W)
    W.load(shops_fake(W, {'Tanners'}))
    F.workshop(W, 'Butchers')
    local u = W.unit(2)
    u.mood = df.mood_type.Secretive
    u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
    u.job.current_job = CW.mood_job(W, 907, F.workshop(W, 'Masons'), {filter('SKIN_TANNED')})
  end}
  CW.day(W2, 1)
  local r2 = mood_reqs(W2)
  T.ok(#r2 >= 1)
  T.eq(r2[#r2].d.types, {'Tanners'})
end)

T.test('dfllm.mood: steps, the line, short names', function()
  T.eq({MD.step(nil), MD.step(30), MD.step(20), MD.step(11), MD.step(10), MD.step(3), MD.step(0)},
       {nil, 'far', 'd20', 'd20', 'd10', 'd5', 'd2'})
  T.eq(MD.short_name('Udil Monangasob "Drilledboard", Brewer'), 'Udil Monangasob')
  local line = MD.line{name = 'Nomal', kind = 'Fey', sl = {{t = 'glass x2: none in the fort [0/0/0 of 11]'},
                                                         {t = 'blocks x1: enough exist'}}, shop = 'GlassFurnace',
                       left = 34 * DAY, src = 'timer'}
  T.eq(line, 'MOOD Nomal Fey needs glass x2, blocks x1: have 1/2; missing glass x2 (none in the fort); no GlassFurnace, 34 d left')
  T.eq(MD.chain({'cloth', 'leather', 'gems'}, {Loom = true, Butchers = true, GlassFurnace = true}, true),
       {'Loom', 'Butchers', 'GlassFurnace'})
end)

---------------------------------------------------------------- runner side
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

T.test('BUG-283: a workshops project with a shop a mood waits for runs in the rebuild policy; mood_types names what ' ..
       'no mood-only project builds', function()
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = 'moodws', map_size = {16, 16, 160}, census = {u = {cit = 2, adults = 2}}}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.K.persist.set('phase', {v = 2, phase = 'P4', since = 0, done = {}})
  W.load(runner)
  W.state()
  runner.CFG.active = 10
  local all = {}
  for _, t in ipairs(runner.MOODABLE) do all[#all + 1] = {type = t, pos = {0, 0, 0}} end
  H.place(W, 'ws', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {}, x = 10, label = 'dig',
                                 manifest = {v = 2, workshops = all}}))
  H.place(W, 'mj', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {skip = 'GlassFurnace'}, x = 40,
                                 label = 'dig', manifest = {v = 2, workshops = {{type = 'Masons', pos = {0, 0, 0}}}}}))
  local _, left = W.K.call('runner', 'mood_types', '26535', {'GlassFurnace'})
  T.eq(left, {'GlassFurnace'}, 'the 12-shop project builds it, but not as a mood project: ask for it alone')
  H.place(W, 'gf', H.dig_doc(1, {tpl = 'workshops', class = 'infra', params = {}, x = 70, label = 'dig',
                                 manifest = {v = 2, workshops = {{type = 'GlassFurnace', pos = {0, 0, 0}}}}}))
  _, left = W.K.call('runner', 'mood_types', '26535', {'GlassFurnace'})
  T.eq(left, {}, 'the furnace-only project covers it')
  H.runs(W, 1)
  local function why(id)
    for _, r in ipairs(W.state().proj) do if r[1] == id then return r[4] end end
  end
  T.eq({why('gf'), why('ws'), why('mj')}, {'', '', 'paused: rebuild pop 2<10'},
       'old code: every workshops project paused by the rebuild policy')
  W.K.call('runner', 'mood_types', '26535', {})
  H.runs(W, 1)
  T.eq(why('gf'), 'paused: rebuild pop 2<10', 'the mood ended: the shop waits like any work')
end)

T.done()
