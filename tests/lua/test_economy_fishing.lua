-- economy (Run 11, Kilrudrabed site98, y432 winter, pop 54): food 24 days and falling, no meat or fish, no farm soil,
-- both kitchens idle with ORDER_STUCK PrepareMeal 'no cook', nobody fished (no fishing zone; the kernel only read zones),
-- and in y433 883-4532 raw fish lay uncleaned because no fishery stood (food fell to 5 days). The census' cook
-- ingredients and the real 'no cook' cause, ORDER_STUCK PrepareRawFish 'no Fishery', the fishery request, the fishing
-- zone on safe revealed water (never cavern water or ice, a bank on the citizens' walk group, roofed first, never on
-- the attack path), the food_low decision with its blockers and options (util/cadence), hunters in the pre-alarm.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end
local function key(x, y, z) return x .. ',' .. y .. ',' .. z end

-- opts: cit, food (meals), pos (the citizens' tile), water ({{x, y, z, flow, cav, ice}}), tiles ({'x,y,z' = tile}),
-- far, sky ({'x,y,z' = true}), manifest, mode, zone (a fishing zone stands), setup(W, ctl)
local function world(opts)
  opts = opts or {}
  local cit = opts.cit or 20
  local ctl = {water = opts.water or {}, tiles = opts.tiles or {}, far = opts.far or {}, sky = opts.sky or {},
               zones = {}, liq = 0}
  local units = {}
  for i = 1, cit do units[i] = {id = i, citizen = true, pos = opts.pos or {50, 50, 100}} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, mode = opts.mode,
                    persist = opts.manifest and {manifest = opts.manifest} or nil}
  local ids = {}
  for i = 1, cit do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  df.civzone_type.FishingArea, df.civzone_type[85] = 85, 'FishingArea'
  df.unit_labor = {COOK = 7, [7] = 'COOK'}
  F.mat(W, 419, 50, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  F.mat(W, 419, 60, {token = 'PLANT:OAK:LEAF', flags = {}})
  F.mat(W, 419, 61, {token = 'PLANT:STRAWBERRY:FRUIT', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 4000})
  F.item(W, 'FOOD', {stack_size = opts.food or 10, subtype = 1})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          pending = function() return ctl.pending or 0 end})
  W.load({name = 'snapshot', every = {ticks = 100},
          liquids = function(K, x0, y0, x1, y1, z, min, ice)
            ctl.liq = ctl.liq + 1
            local out = {}
            for _, t in ipairs(ctl.water) do
              if t[3] == z and t[1] >= x0 and t[1] <= x1 and t[2] >= y0 and t[2] <= y1 then
                if t[6] then
                  if ice then out[#out + 1] = {t[1], t[2], t[4], t[5] and 1 or 0, 1} end
                elseif t[4] >= min then out[#out + 1] = {t[1], t[2], t[4], t[5] and 1 or 0, ice and 0 or nil} end
              end
            end
            return out
          end,
          tile = function(K, x, y, z)
            local t = ctl.tiles[key(x, y, z)]
            if t then return t end
            for _, w in ipairs(ctl.water) do
              if w[1] == x and w[2] == y and w[3] == z then
                return {c = w[6] and '#' or (w[4] >= 4 and '~' or 'w'), flow = w[4], cav = w[5] == true, ice = w[6] == true}
              end
            end
            return {c = '#', dig = '', bld = ''}
          end,
          far = function(K, x, y, z) return ctl.far[key(x, y, z)] == true end,
          outside_near = function(K, pts, r)
            local out = {}
            for i, q in ipairs(pts) do out[i] = ctl.sky[key(q[1], q[2], q[3])] and 1 or 0 end
            return out
          end})
  W.act_result('run', function(cmd, a1)
    if cmd == 'labormanager' and a1 == 'mode' then return true, 'Mode: monitor (labormanager)' end
    return true, ''
  end)
  W.act_result('fish_zone', function(pos, side, up)
    ctl.zones[#ctl.zones + 1] = {pos = {pos[1], pos[2], pos[3]}, side = side, up = up}
    F.building(W, 'ANY_ZONE', {type = 85, x1 = pos[1] - 1, y1 = pos[2] - 1, x2 = pos[1] + 1, y2 = pos[2] + 1, z = pos[3]})
    return true, up and 2 or 1
  end)
  if opts.zone then F.building(W, 'ANY_ZONE', {type = 85, x1 = 0, y1 = 0, x2 = 2, y2 = 2, z = 100}) end
  if opts.setup then opts.setup(W, ctl) end
  W.load(fresh('economy'))
  for i = 1, cit do
    local u = W.unit(i)
    u.status.labors, u.mood = {}, -1
  end
  return W, ctl
end

local function decisions(W, id)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end
local function stuck(W, job)
  local r = {}
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do if e.d.job == job then r[#r + 1] = e end end
  return r
end
local function requests(W, why)
  local r = {}
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.tpl == 'workshops' and e.d.why == why then r[#r + 1] = e end end
  return r
end

T.test('census (Run 11): cook ingredients are EDIBLE_COOKED and not on the Cook ban; inedible growths and cut-off food', function()
  local W = world{setup = function(W)
    F.item(W, 'PLANT_GROWTH', {stack_size = 1566, mat_type = 419, mat_index = 60})       -- oak leaves: no food
    F.item(W, 'PLANT', {stack_size = 11, mat_type = 419, mat_index = 50})               -- plump helmets: never cooked
    F.item(W, 'PLANT_GROWTH', {stack_size = 30, mat_type = 419, mat_index = 61})         -- strawberries: cookable
    F.item(W, 'PLANT_GROWTH', {stack_size = 9, mat_type = 419, mat_index = 61, subtype = 2, _pos = {1, 2, 3}})
    W.kitchen[#W.kitchen + 1] = {what = 'Cook', it = df.item_type.PLANT_GROWTH, t = 419, i = 61, _sub = 2}
  end}
  settle(W)
  local i = W.K.census.i
  T.eq({i.food_inedible, i.cook_in, i.cook_ban, i.cook_ban_g, i.food_nocook}, {1566, 0, 50, 39, 11},
       'the kitchen exclusion of the strawberries bans all 39 (fake: no subtype), the helmets by Gordon\'s rule')
  for k = #W.kitchen, 1, -1 do if W.kitchen[k].i == 61 then table.remove(W.kitchen, k) end end
  days(W, 1)
  T.eq({W.K.census.i.cook_in, W.K.census.i.cook_ban}, {39, 11})
end)

T.test("Run 11: ORDER_STUCK PrepareMeal names the real cause, not 'no cook'; PrepareRawFish says no Fishery", function()
  local W = world{setup = function(W)
    F.workshop(W, 'Kitchen')
    F.item(W, 'PLANT_GROWTH', {stack_size = 1566, mat_type = 419, mat_index = 60})
    F.item(W, 'PLANT', {stack_size = 11, mat_type = 419, mat_index = 50})
    for _ = 1, 3 do F.item(W, 'FISH_RAW', {stack_size = 300}) end
    F.order(W, {id = 41, job_type = df.job_type.PrepareMeal, amount_left = 5, mat_type = -1, mat_index = -1})
    df.job_type.PrepareRawFish, df.job_type[90] = 90, 'PrepareRawFish'
    F.order(W, {id = 42, job_type = 90, amount_left = 5, mat_type = -1, mat_index = -1})
  end}
  W.unit(1).status.labors = {[7] = true}
  days(W, 4)
  local m = stuck(W, 'PrepareMeal')
  T.eq(#m, 1)
  T.ok(m[1].d.why:find('no cook ingredient (900 raw fish need a fishery, 1566 inedible (OAK:LEAF), 11 cook-banned)', 1, true),
       m[1].d.why)
  T.ok(not m[1].d.why:find('no worker', 1, true), 'a cook holds the COOK labor')
  local f = stuck(W, 'PrepareRawFish')
  T.eq(#f, 1)
  T.ok(f[1].d.why:find('no Fishery', 1, true), f[1].d.why)
end)

T.test('Run 11: raw fish and no fishery -> PROJECT_REQUEST workshops why=fishery every 14 days; none with a fishery', function()
  local W = world{food = 2000, setup = function(W) for _ = 1, 10 do F.item(W, 'FISH_RAW', {}) end end}
  days(W, 1)
  local r = requests(W, 'fishery')
  T.eq(#r, 1)
  T.eq({r[1].d.n, r[1].cls}, {1, 'B'})
  T.ok(r[1].msg:find('a fishery for 10 raw fish', 1, true), r[1].msg)
  days(W, 10)
  T.eq(#requests(W, 'fishery'), 1, 'not again within request_days')
  days(W, 5)
  T.eq(#requests(W, 'fishery'), 2)
  local W2 = world{food = 2000, setup = function(W)
    for _ = 1, 10 do F.item(W, 'FISH_RAW', {}) end
    F.workshop(W, 'Fishery')
  end}
  days(W2, 2)
  T.eq(requests(W2, 'fishery'), {}, 'a fishery stands')
end)

-- BUG-038 (Run 11, y451, pop 26): the fishery was destroyed in the sieges, 138 raw fish lay there, food fell from 51 to
-- 22 days and no fishery came. A fishery that was seen restarts no request clock; 'queued' holds only while a pending
-- workshops project builds a fishery and moves (runner's project list and its doc, read-only)
local function gone(W, b)
  local v = df.global.world.buildings.other.WORKSHOP_ANY
  for i = #v - 1, 0, -1 do if v[i] == b then v:erase(i) end end
end
local function fish_logs(W)
  local r = {}
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('fishery: none built', 1, true) then r[#r + 1] = l.msg end end
  return r
end
-- a runner project (persist 'projects' + its doc 'bp.<id>'); fishery: its manifest lists a Fishery
local function project(W, id, fishery, o)
  o = o or {}
  local pd = W.K.persist.get('projects') or {v = 2, list = {}}
  local P = {id = id, tpl = o.tpl or 'workshops', site = 'S1', class = 'infra', prio = 1, stage = 0, chunk = 0,
             pct = o.pct or 0, blocked = o.blocked or '', since = 0, created = 0, done = o.done or 0}
  pd.list[#pd.list + 1] = P
  W.K.persist.set('projects', pd)
  W.K.persist.set('bp.' .. id, {v = 2, tpl = P.tpl, manifest = {v = 2, workshops = {
    {type = fishery and 'Fishery' or 'Craftsdwarfs', pos = {10, 10, 100}}}}})
  return P
end

T.test('BUG-038: a fishery seen for a while restarts no request clock; one destroyed long after its request is asked at once', function()
  local W = world{food = 2000, setup = function(W) for _ = 1, 10 do F.item(W, 'FISH_RAW', {}) end end}
  days(W, 1)
  T.eq(#requests(W, 'fishery'), 1)
  local b = F.workshop(W, 'Fishery')
  days(W, 2)
  gone(W, b)                                       -- built from the request, destroyed in the next siege
  days(W, 3)
  T.eq(#requests(W, 'fishery'), 1, 'within request_days of the last request: no second one (d782dfa: asked at once)')
  days(W, 10)
  T.eq(#requests(W, 'fishery'), 2, 'the period is over')
  b = F.workshop(W, 'Fishery')
  days(W, 30)
  T.eq(#requests(W, 'fishery'), 2, 'a fishery stands')
  gone(W, b)
  days(W, 1)
  T.eq(#requests(W, 'fishery'), 3, 'destroyed a month after the last request: asked at once')
  local l = fish_logs(W)
  T.eq(#l, 3, 'one kern.log line per request')
  T.ok(l[1]:find('(first request)', 1, true), l[1])
  T.ok((math.tointeger(tonumber(l[3]:match('%((%d+) days since the last request%)'))) or 0) >= 30, l[3])
end)

T.test('BUG-038: queued only while a pending workshops project builds a fishery and moves; else asked again', function()
  local W, ctl = world{food = 2000, setup = function(W) for _ = 1, 10 do F.item(W, 'FISH_RAW', {}) end end}
  days(W, 1)
  T.eq(#requests(W, 'fishery'), 1)
  project(W, 'w1', false)                          -- the moodable shops: no fishery in it
  ctl.pending = 1
  days(W, 15)
  T.eq(#requests(W, 'fishery'), 2, 'a workshops project without a fishery holds nothing (d782dfa: queued 56 days)')
  local P = project(W, 'w2', true)                 -- follow placed the fishery
  ctl.pending = 2
  for _ = 1, 20 do P.pct = P.pct + 1; days(W, 1) end
  T.eq(#requests(W, 'fishery'), 2, 'the fishery project moves: queued')
  days(W, 13)
  T.eq(#requests(W, 'fishery'), 2, 'still within request_days of its last move')
  days(W, 2)
  T.eq(#requests(W, 'fishery'), 3, 'the project has not moved for request_days (BUG-037: a queue that never starts it)')
  local l = fish_logs(W)
  T.ok((math.tointeger(tonumber(l[2]:match('%((%d+) days since the last request%)'))) or 0) >= 14, l[2])
  T.ok(l[3]:find('project w2 has not moved for 14 days', 1, true), l[3])
  P.blocked, P.pct = 'build_lost', P.pct + 1
  days(W, 15)
  T.eq(#requests(W, 'fishery'), 4, 'a halted project holds nothing')
  T.ok(fish_logs(W)[4]:find('project w2 build_lost', 1, true), fish_logs(W)[4])
  local W2 = world{food = 2000, setup = function(W2) for _ = 1, 10 do F.item(W2, 'FISH_RAW', {}) end end}
  local P2 = project(W2, 'w9', true)               -- the player placed one before any request
  for _ = 1, 30 do P2.pct = P2.pct + 1; days(W2, 1) end
  T.eq(requests(W2, 'fishery'), {}, 'a moving fishery project of the player: no request')
end)

T.test('BUG-206 (live Earthboat): a pending fortcore stage 1 builds the fishery: no request while it moves; a later ' ..
       'fortcore stage (its doc lists the workshops of stage 1 too) holds nothing', function()
  local function run(stage)
    local W = world{food = 2000, setup = function(W) for _ = 1, 10 do F.item(W, 'FISH_RAW', {}) end end}
    local P = project(W, 'fc' .. stage, true, {tpl = 'fortcore'})
    local d = W.K.persist.get('bp.fc' .. stage)
    d.params = {stage = stage}
    W.K.persist.set('bp.fc' .. stage, d)
    for _ = 1, 10 do P.pct = P.pct + 1; days(W, 1) end
    return W
  end
  T.eq(requests(run(1), 'fishery'), {}, 'live: "fishery: none built ... request (first request)" beside the core')
  T.eq(#requests(run(3), 'fishery'), 1, 'stage 3: its Fishery is the one of stage 1, built or lost long ago')
end)

-- the citizens stand at 50,50,100. Nearest water: a cavern lake, ice, a river whose bank lies on another walk group,
-- then an open-sky river with a bank; farther a roofed pool one level down under open space
local function waters()
  return {{52, 50, 100, 7, true}, {53, 50, 100, 7, false, true}, {55, 50, 100, 7}, {60, 50, 100, 7},
          {80, 50, 99, 5}}
end
local function banks()
  return {[key(56, 50, 100)] = {c = '.'}, [key(61, 50, 100)] = {c = '.'}, [key(53, 51, 100)] = {c = '.'},
          [key(80, 50, 100)] = {c = '_'}, [key(81, 50, 100)] = {c = '.'}, [key(51, 50, 100)] = {c = '.'}}
end

T.test('Run 11: fishing zone on safe water: no cavern water, no ice, a bank on the walk group, roofed first', function()
  local W, ctl = world{food = 26, water = waters(), tiles = banks(), far = {[key(56, 50, 100)] = true},
                       sky = {[key(61, 50, 100)] = true}}
  days(W, 1)
  T.eq(#ctl.zones, 1)
  T.eq(ctl.zones[1], {pos = {80, 50, 99}, side = 3, up = true},
       'the roofed pool (bank one level up over open space) beats the nearer open-sky river')
  T.ok(ctl.liq > 0, 'read through snapshot.liquids')
  local z = W.K.persist.get('m.economy').fishz
  T.eq({z.why, z.inside, z.bank}, {'painted', 1, {81, 50, 100}})
  local n = ctl.liq
  days(W, 8)
  T.eq(#ctl.zones, 1, 'a fishing zone stands: no second one, no search')
  T.eq(ctl.liq, n)
  -- without the pool: the open-sky river (its bank is not on the attack path)
  local wl = waters()
  wl[5] = nil
  local W2, ctl2 = world{food = 26, water = wl, tiles = banks(), far = {[key(56, 50, 100)] = true},
                         sky = {[key(61, 50, 100)] = true}}
  days(W2, 1)
  T.eq(ctl2.zones[1], {pos = {60, 50, 100}, side = 3, up = false})
  -- the same river bank inside the bailey (manifest Z1): never there
  local W3, ctl3 = world{food = 26, water = wl, tiles = banks(), far = {[key(56, 50, 100)] = true},
                         manifest = {v = 2, zones = {Z1 = {{58, 45, 100, 65, 55, 100}}}}}
  days(W3, 1)
  T.eq(ctl3.zones, {}, 'the attack path is no fishing spot')
end)

T.test('Run 11: no safe fishing water (frozen, cavern) -> no zone; food_low names it with the numbers and options', function()
  local W, ctl = world{cit = 20, food = 10, water = {{52, 50, 100, 7, true}, {53, 50, 100, 7, false, true},
                                                     {54, 50, 100, 7, false, true}}, tiles = banks()}
  days(W, 1)
  T.eq(ctl.zones, {})
  local z = W.K.persist.get('m.economy').fishz
  T.eq(z.why, 'no safe fishing water (2 frozen, 1 cavern)')
  local d = decisions(W, 'food_low')
  T.eq(#d, 1, '20 food days: the pre-alarm')
  T.eq(d[1].cls, 'A')
  local q = d[1].d.q
  T.ok(#q <= 200, q)
  T.ok(q:find('food 20 d (20 cit, 10 meals)', 1, true), q)
  T.ok(q:find('no safe fishing water (2 frozen, 1 cavern)', 1, true), q)
  T.ok(q:find('. Also: trade.want food, butcher.mark, gather, popcap.lower', 1, true), q)
  -- BUG-258: no crossbow is the blocker 'xbow' (option crossbow), not bolts; frozen water still names the fishing zone
  T.eq(d[1].d.opts, {'kitchen', 'fishing zone', 'crossbow', 'trade.want food', 'butcher.mark', 'gather', 'popcap.lower'})
  T.eq(d[1].d.food, 20)
  T.eq(d[1].d.block, {'kitchen', 'fish_zone', 'xbow', 'farms'}, 'no animals: no butcher blocker')
  -- the same blockers: never again (BUG-008 cadence); a new blocker after 7 days and 10 minutes: again
  days(W, 8)
  T.eq(#decisions(W, 'food_low'), 1)
  for _ = 1, 10 do F.item(W, 'FISH_RAW', {}) end
  W.ms = W.ms + 600 * 1000
  days(W, 1)
  T.eq(#decisions(W, 'food_low'), 1, 'BUG-038: raw fish and no fishery is asked by itself (PROJECT_REQUEST): no news')
  T.eq(#requests(W, 'fishery'), 1)
  W.set_census('a', {n = 3})                                 -- tame animals and no butcher's shop: a new blocker
  days(W, 1)
  d = decisions(W, 'food_low')
  T.eq(#d, 2)
  T.eq(d[2].d.auto, {'fishery'})
  T.ok(not F.has(d[2].d.block, 'fishery') and F.has(d[2].d.block, 'butcher'), table.concat(d[2].d.block, ','))
  T.ok(not F.has(d[2].d.opts, 'fishery'), table.concat(d[2].d.opts, ','))
  T.ok(d[2].d.q:find('; auto: fishery asked (10 raw fish). Also: ', 1, true), d[2].d.q)
  T.ok(d[2].msg:find('food low: 20 food days (famine below 10): no kitchen; auto: fishery', 1, true), d[2].msg)
  -- the winter ends: the next search (scan_days) finds the river thawed
  ctl.water = {{60, 50, 100, 7}}
  days(W, 7)
  T.eq(#ctl.zones, 1)
end)

-- BUG-258 (Run 15 Inkintense y373: food_low block [cook, fish_zone, hunt, farms] in a fort without a brook, 175 bolts and
-- no crossbow): no water at all is no fishing option; no crossbow names the crossbow and its workshop, not bolts
T.test('BUG-258: a scan that met no water drops the fishing zone from food_low; no crossbow is xbow with the bolts', function()
  local W = world{cit = 20, food = 10, setup = function(W)
    W.subdefs[4] = {id = 'ITEM_AMMO_BOLTS'}
    F.item(W, 'AMMO', {subtype = 4, stack_size = 175})
  end}
  days(W, 1)
  local z = W.K.persist.get('m.economy').fishz
  T.eq(z.seen, 0, 'the scan met no water tile')
  local d = decisions(W, 'food_low')
  T.eq(#d, 1)
  T.ok(not F.has(d[1].d.block, 'fish_zone') and not F.has(d[1].d.opts, 'fishing zone'), table.concat(d[1].d.block, ','))
  T.ok(F.has(d[1].d.block, 'xbow') and not F.has(d[1].d.block, 'hunt'), table.concat(d[1].d.block, ','))
  T.ok(F.has(d[1].d.opts, 'crossbow') and not F.has(d[1].d.opts, 'bolts'), table.concat(d[1].d.opts, ','))
  T.ok(d[1].d.q:find("hunt: no crossbow, no Bowyer's workshop (175 bolts)", 1, true), d[1].d.q)
  local W2 = world{cit = 20, food = 10, setup = function(W2)
    W2.subdefs[4] = {id = 'ITEM_AMMO_BOLTS'}
    F.item(W2, 'AMMO', {subtype = 4, stack_size = 175})
    F.workshop(W2, 'Bowyers')
  end}
  days(W2, 1)
  T.ok(decisions(W2, 'food_low')[1].d.q:find('hunt: no crossbow (175 bolts)', 1, true), decisions(W2, 'food_low')[1].d.q)
end)

T.test('Run 11: no fishing search outside PEACE/RECOVERY, with a zone standing, or with food enough', function()
  local W, ctl = world{food = 26, mode = 'ALERT', water = waters(), tiles = banks()}
  days(W, 2)
  T.eq({ctl.zones, ctl.liq}, {{}, 0})
  local W2, ctl2 = world{food = 26, zone = true, water = waters(), tiles = banks()}
  days(W2, 2)
  T.eq({ctl2.zones, ctl2.liq}, {{}, 0})
  local W3, ctl3 = world{food = 2000, water = waters(), tiles = banks()}
  days(W3, 2)
  T.eq({ctl3.zones, ctl3.liq}, {{}, 0}, '4166 food days')
end)

T.test('Run 11: cookable growths on the kitchen ban are let go once in the food_low pre-alarm (helmets stay)', function()
  local W = world{food = 4, setup = function(W)                                  -- 4 meals + 5 berries: 18 food days
    F.item(W, 'PLANT_GROWTH', {stack_size = 5, mat_type = 419, mat_index = 61})
    W.kitchen[#W.kitchen + 1] = {what = 'Cook', it = df.item_type.PLANT_GROWTH, t = 419, i = 61}
  end}
  days(W, 1)
  local un = {}
  for _, line in ipairs(F.runs(W)) do if line:find('^ban%-cooking fruit') then un[#un + 1] = line end end
  T.eq(un, {'ban-cooking fruit --unban'})
  T.eq(F.bad_runs(W), {})
  days(W, 3)
  local n = 0
  for _, line in ipairs(F.runs(W)) do if line:find('^ban%-cooking fruit') then n = n + 1 end end
  T.eq(n, 1, 'once per episode')
end)

T.done()
