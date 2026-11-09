-- BUG-573..575 (Run 16 round 14, i3 Sealcertain y416, i1 Basementflew y429, i4 Trumpetrealms y377): moods that died or came close for
-- want of a material the fort could have had.
--   * BUG-573: the reserve class `gems` is the CUT form (a rough gem is no reserve stock); the glass plan counts cut gems (cut glass and
--     care's held ones too), cuts the rough gems beyond glass.rough_keep with a CutGems order and makes glass only where none is spare;
--     care tells economy a new mood want at once (economy.need)
--   * BUG-574: a silk mood (cloth or thread): no silk thread -> a CollectWebs work order at the Loom, silk thread -> a WeaveCloth silk
--     order whatever the cloth stock of the other kinds
--   * BUG-575: a slot the fort cannot fill itself (a rough gem, hard stone without a dig, silk without webs) gets DECISION_NEEDED
--     mood_deadline (early 1) with the commands the first time care sees it
local T = require('testlib')
local F = require('wp8_world')
local CW = require('care_world')
local kmock = require('dfllm.util.k_mock')
local R = require('dfllm.reserve')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

---------------------------------------------------------------- economy: cut gems and the silk chain
local function world(opts)
  opts = opts or {}
  local ctl = {wants = opts.wants, sand = {tick = 100, tiles = {}}, phase = opts.phase or 'P3'}
  local units = {}
  for i = 1, 6 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local ids = {}
  for i = 1, 6 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  F.mat(W, 0, 31, {token = 'INORGANIC:AMETHYST', flags = {}})
  F.mat(W, 0, 32, {token = 'INORGANIC:SPIDER_SILK', flags = {SILK = true}})
  F.mat(W, 419, 71, {token = 'PLANT:GRASS_TAIL_PIG:THREAD', flags = {THREAD_PLANT = true}})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = ctl.phase} end, pending = function() return 0 end})
  W.load({name = 'care', every = {ticks = 1200}, reserved = function() return ctl.held or {} end,
          mood_wants = function() return ctl.wants end,
          state = function() return {care = {stressed_pct = 0, naked = 0, ghosts = 0, corpses_old = 0, tombs_free = 0,
                                             moods = 0}} end})
  W.load({name = 'snapshot', every = {ticks = 100}, sand = function() return ctl.sand end,
          tile = function() return nil end, far = function() return false end,
          outside_near = function(K, pts) local o = {} for i = 1, #pts do o[i] = 0 end return o end,
          export = function() return true, 'e1' end})
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  for _, ws in ipairs(opts.shops or {}) do F.workshop(W, ws) end
  for _, ws in ipairs(opts.furnaces or {}) do F.workshop(W, ws, true) end
  if opts.setup then opts.setup(W, ctl) end
  W.load(fresh('economy'))
  return W, ctl
end

local function orders(W, tag)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == tag then r[#r + 1] = a.args[1] end end
  return r
end

T.test('BUG-573: the census counts cut and rough gems apart (raw glass is neither; cut glass is cut)', function()
  local W = world{setup = function(W)
    F.item(W, 'ROUGH', {mat_type = 3, stack_size = 2})
    for _ = 1, 4 do F.item(W, 'ROUGH', {mat_type = 0, mat_index = 31}) end
    F.item(W, 'SMALLGEM', {mat_type = 3})
    F.item(W, 'SMALLGEM', {mat_type = 0, mat_index = 31})
  end}
  settle(W)
  local i = W.K.census.i
  T.eq({i.gems, i.gems_cut, i.gems_rough, i.gems_glass}, {6, 2, 4, 1})
end)

T.test('BUG-573: 93 rough gems and a jeweler, a Fey mood misses cut gems: a CutGems order at once, no glass chain', function()
  local W = world{wants = {{cls = 'gems', n = 1, glass = 'cut', unit = 1}}, shops = {'Jewelers'}, furnaces = {'GlassFurnace'},
                  setup = function(W) for _ = 1, 93 do F.item(W, 'ROUGH', {mat_type = 0, mat_index = 31}) end end}
  days(W, 1)
  local c = orders(W, 'dfllm:cutgems')
  T.eq(#c, 1, 'one CutGems order')
  T.eq({c[1].job, c[1].amount_total}, {'CutGems', 5}, 'the mood\'s 1 + the reserve\'s 5, at most max_jobs')
  T.eq(c[1].item_conditions, {{condition = 'AtLeast', value = 1, item_type = 'ROUGH'}})
  T.eq(#orders(W, 'dfllm:glass') + #orders(W, 'dfllm:sand') + #orders(W, 'dfllm:cutglass'), 0, 'rough gems to cut: no glass')
  T.eq(W.find_acts('sand_zone'), {})
end)

T.test('BUG-573: the rough gems under glass.rough_keep stay uncut; cut gems at the target need no order; no jeweler: asked', function()
  local W = world{shops = {'Jewelers'}, setup = function(W) for _ = 1, 2 do F.item(W, 'ROUGH', {mat_type = 0, mat_index = 31}) end end}
  days(W, 1)
  T.eq(#orders(W, 'dfllm:cutgems'), 0, '2 rough gems = rough_keep: the rough-gem filters keep them')
  local W2 = world{shops = {'Jewelers'}, setup = function(W)
    for _ = 1, 9 do F.item(W, 'ROUGH', {mat_type = 0, mat_index = 31}) end
    for _ = 1, 5 do F.item(W, 'SMALLGEM', {mat_type = 0, mat_index = 31}) end
  end}
  days(W2, 1)
  T.eq(#orders(W2, 'dfllm:cutgems'), 0, '5 cut gems on the shelf: the standing stock is there')
  local W3 = world{setup = function(W) for _ = 1, 9 do F.item(W, 'ROUGH', {mat_type = 0, mat_index = 31}) end end}
  days(W3, 1)
  local req = W3.find_events('PROJECT_REQUEST')
  local n = 0
  for _, e in ipairs(req) do if e.d.why == 'glass' then n = n + 1 end end
  T.eq(n, 1, "no jeweler's: the workshops project is asked for once")
  T.eq(#orders(W3, 'dfllm:cutgems'), 0)
end)

T.test('BUG-573: care\'s held cut gems count as stock; the standing stock is made while the fort has cut gems under the target', function()
  local W, ctl = world{shops = {'Jewelers'}, setup = function(W, ctl)
    ctl.held = {gems = 5}
    for _ = 1, 9 do F.item(W, 'ROUGH', {mat_type = 0, mat_index = 31}) end
  end}
  days(W, 1)
  T.eq(#orders(W, 'dfllm:cutgems'), 0, '5 cut gems held by the reserve: nothing to cut')
  ctl.held = {gems = 2}
  days(W, 1)
  local c = orders(W, 'dfllm:cutgems')
  T.eq(#c, 1)
  T.eq(c[1].amount_total, 3, 'the 3 missing to the target of 5')
end)

local function silk_world(opts)
  opts = opts or {}
  return world{wants = {{cls = 'cloth', n = 1, sub = 'silk', unit = 1}}, shops = opts.shops or {'Loom'}, phase = 'P1',
               setup = function(W)
    for _ = 1, opts.cloth or 25 do F.item(W, 'CLOTH', {mat_type = 419, mat_index = 71}) end    -- plant cloth: over every target
    for _ = 1, opts.thread or 6 do F.item(W, 'THREAD', {mat_type = 419, mat_index = 71}) end
    for _ = 1, opts.webs or 40 do F.item(W, 'THREAD', {mat_type = 0, mat_index = 32, flags = {spider_web = true}}) end
    for _ = 1, opts.silk or 0 do F.item(W, 'THREAD', {mat_type = 0, mat_index = 32}) end
  end}
end

T.test('BUG-574: a silk mood, webs on the walk group, no silk thread, plenty of other cloth: a CollectWebs work order', function()
  local W = silk_world()
  days(W, 1)
  local w = orders(W, 'dfllm:webs')
  T.eq(#w, 1)
  T.eq({w[1].job, w[1].amount_total}, {'CollectWebs', 3}, '1 silk + 2 spare webs')
  T.eq(#orders(W, 'dfllm:cloth_silk'), 0, 'no silk thread yet: nothing to weave')
  T.eq(W.K.census.i.thread_silk, 0)
end)

T.test('BUG-574: silk thread at hand: the silk weave order comes first, whatever the other cloth; no second web order', function()
  local W = silk_world{silk = 3}
  days(W, 1)
  local s = orders(W, 'dfllm:cloth_silk')
  T.eq(#s, 1)
  T.eq({s[1].job, s[1].material_category, s[1].amount_total}, {'WeaveCloth', {'silk'}, 1})
  T.eq(s[1].item_conditions, {{condition = 'AtLeast', value = 1, item_type = 'THREAD', flags = {'collected', 'silk'}}})
  T.eq(#orders(W, 'dfllm:webs'), 0, 'silk thread is there')
end)

T.test('BUG-574: no Loom, or webs only off the walk group: no order, the reason is kept for the status', function()
  local W = silk_world{shops = {}}
  days(W, 1)
  T.eq(#orders(W, 'dfllm:webs'), 0)
  local W2 = silk_world{webs = 0}
  days(W2, 1)
  T.eq(#orders(W2, 'dfllm:webs'), 0)
end)

---------------------------------------------------------------- care: the reserve class, the rush, the early decision
local function filter(t, spec)
  local f = {_t = t, mat_type = -1, mat_index = -1, quantity = 1, flags1 = {}, flags2 = {}, flags3 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end

local function item(W, cat, id, mi, flags, pos)
  local it = F.item(W, cat, {id = id, mat_type = 0, mat_index = mi, flags = flags or {}, _pos = pos or {10, 10, 5}})
  it.getSubtype = function() return -1 end
  it.getMaterial = function(self) return self.mat_type end
  it.getMaterialIndex = function(self) return self.mat_index end
  return it
end

local function moody(W, id, kind, filters)
  local u = W.unit(id)
  for _, f in ipairs(filters) do f.item_type = f._t and df.item_type[f._t] or -1 end
  u.mood = df.mood_type[kind]
  u.job.current_job = CW.mood_job(W, 900 + id, F.workshop(W, 'Craftsdwarfs'), filters, {})
  return u
end

T.test('BUG-573: item_class: a rough gem is no reserve stock, a cut gem (glass too) is', function()
  local W = CW.world{}
  local function cls(cat, spec) return R.item_class(F.item(W, cat, spec or {})) end
  T.eq({cls('ROUGH', {mat_type = 0}), cls('ROUGH', {mat_type = 3}), cls('SMALLGEM'), cls('SMALLGEM', {mat_type = 3})},
       {nil, nil, 'gems', 'gems'})
end)

T.test('BUG-573: the gems class takes its total from the cut count; a rough gem held by an older run is let go', function()
  local W, Cm = CW.world{phase = 'P1', census_i = {gems = 12, gems_cut = 0}, setup = function(W)
    F.mat(W, 0, 7, {token = 'INORGANIC:AGATE'})
    local rough = {}
    for i = 1, 5 do rough[i] = item(W, 'ROUGH', 800 + i, 7, {forbid = true}) end
    CW.pile(W, '', rough)
  end}
  local p = W.K.persist.get('m.care')
  p.reserve = p.reserve or {}
  p.reserve.held = {gems = {801, 802, 803, 804, 805}}
  W.run(2)
  local freed = 0
  for _, a in ipairs(W.find_acts('item_flag')) do if a.args[2] == 'forbid' and a.args[3] == false then freed = freed + 1 end end
  T.eq(freed, 5, 'the five rough gems the old class held are unforbidden')
  T.eq(#(W.K.persist.get('m.care').reserve.held.gems or {}), 0)
  T.eq(CW.held(W).gems or {}, {}, 'and the class holds no new one: cut gems 0 in the census, rough ones do not count')
end)

T.test('BUG-575: a rough-gem slot gets an early DECISION_NEEDED mood_deadline with trade.want and an explore dig; once per set', function()
  local W = CW.world{census_i = {gems = 4, gems_cut = 0, rock = 0}, setup = function(W)
    moody(W, 1, 'Possessed', {filter('ROUGH', {mat_type = 0}), filter('SMALLGEM', {})})
    W.unit(1).counters2 = {thirst_timer = 1000, hunger_timer = 0}
    W.load({name = 'economy', every = {ticks = 1200}})
  end}
  W.run(6)
  local ds = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'mood_deadline' and e.d.early == 1 then ds[#ds + 1] = e end end
  T.eq(#ds, 1, 'one early decision, at the first report (not after 2 days of waiting)')
  local d = ds[1].d
  T.ok(d.q:find('gems(rough) x1', 1, true) and d.q:find('no work order', 1, true), d.q)
  local joined = table.concat(d.cmds, '\n')
  T.ok(joined:find('trade.want', 1, true) and joined:find('"gem"', 1, true), joined)
  T.ok(joined:find('"tpl":"explore"', 1, true), joined)
  T.ok(joined:find('inspect what=unit key=1', 1, true), joined)
  for _, c in ipairs(d.cmds) do T.ok(#c < 200, c) end
  W.run(6)
  local again = 0
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'mood_deadline' and e.d.early == 1 then again = again + 1 end end
  T.eq(again, 1, 'not repeated for the same set')
end)

T.test('BUG-575: a cut-gem slot with a jeweler and rough gems is no early decision (the chain makes it)', function()
  local W = CW.world{census_i = {gems = 4, gems_cut = 0}, setup = function(W)
    F.mat(W, 0, 7, {token = 'INORGANIC:AGATE'})
    moody(W, 1, 'Fey', {filter('SMALLGEM', {})})
    for i = 1, 4 do item(W, 'ROUGH', 600 + i, 7) end
    W.unit(1).counters2 = {thirst_timer = 1000, hunger_timer = 0}
    W.load({name = 'economy', every = {ticks = 1200}})
  end}
  W.run(6)
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do T.ok(not (e.d.id == 'mood_deadline' and e.d.early), 'no early decision') end
end)

T.test('BUG-575: a silk slot with no web and no silk thread: early decision (trade.want cloth:silk); with webs near: none', function()
  local function run(webs_near)
    local W = CW.world{census_i = {cloth = 0, thread = 0, webs_near = webs_near, thread_silk = 0}, setup = function(W)
      moody(W, 1, 'Secretive', {filter('CLOTH', {flags2 = {silk = true}})})
      W.unit(1).counters2 = {thirst_timer = 1000, hunger_timer = 0}
      W.load({name = 'economy', every = {ticks = 1200}})
    end}
    W.run(6)
    local ds = {}
    for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'mood_deadline' and e.d.early == 1 then ds[#ds + 1] = e end end
    return ds
  end
  local ds = run(0)
  T.eq(#ds, 1)
  T.ok(ds[1].d.q:find('no web within reach', 1, true), ds[1].d.q)
  T.ok(table.concat(ds[1].d.cmds, '\n'):find('cloth:silk', 1, true), table.concat(ds[1].d.cmds, '\n'))
  T.eq(#run(12), 0, 'webs on the walk group: the chain collects them')
end)

T.test('BUG-573: care tells economy a new mood want at once (economy.need, once per class and count)', function()
  local calls = {}
  local W = CW.world{census_i = {gems = 0, gems_cut = 0}, setup = function(W)
    F.mat(W, 0, 7, {token = 'INORGANIC:AGATE'})
    moody(W, 1, 'Fey', {filter('SMALLGEM', {})})
    W.unit(1).counters2 = {thirst_timer = 1000, hunger_timer = 0}
    W.load({name = 'economy', every = {ticks = 1200}, need = function(K, key, n, who, d)
      calls[#calls + 1] = {key, n, who, d}
      return true, ''
    end})
  end}
  W.run(6)
  T.eq(calls, {{'gems', 1, 'care', 2}})
end)

T.done()
