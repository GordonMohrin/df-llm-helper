-- Run 15 (fix6-water): hospital water in 4 of 4 forts. BUG-262 an aquifer well (the recipe, the cistern basin kept rough);
-- BUG-263 a well fed only by its own pond is no accepted source, a dropped source is named; BUG-264 a well waiting for its
-- chain or rope gets a route; BUG-265 water with no bank: a deeper dig (ws_dig 16) and a piped cistern; BUG-266 the dry
-- fortcore well and its fill source in HOSPITAL_DRY. Every test fails on 2b9c009 but the Water Source zone guard.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
local C = require('dfllm.util.contract')
local AQ = require('dfllm.aqshaft')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'

local DEPTH = {['~'] = 7, w = 2}

local function owners()
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'pond_remove'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn] or {}) do if o ~= 'water' then keep[#keep + 1] = o end end
    keep[#keep + 1] = 'water'
    C.ACT[fn] = keep
  end
end

-- opts: tiles {['x,y,z'] = c} (default '#', '?' hidden), unreach, manifest, pending {tpl = n}, census_i, setup(W)
local function world(opts)
  opts = opts or {}
  owners()
  local units = {}
  for i = 1, 4 do units[i] = {id = i, citizen = true, pos = {12, 12, 5}} end
  local man = opts.manifest or {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {{0, 0, 0, 99, 99, 20}}}}
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, persist = {manifest = man},
                    census = {i = opts.census_i}}
  df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
  df.civzone_type.Pond, df.civzone_type[11] = 11, 'Pond'
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  df.job_type.MakeChain, df.job_type[78] = 78, 'MakeChain'
  df.item_type.CHAIN, df.item_type[90] = 90, 'CHAIN'
  local ids = {}
  for i = 1, 4 do
    ids[i] = i
    W.unit(i).counters2 = {thirst_timer = 1000}
    W.unit(i).job = {current_job = nil}
  end
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 0, 0, 99, 99, 20})
  W.cmap, W.unreach = opts.tiles or {}, opts.unreach or {}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile(K, x, y, z)
    local c = W.cmap[x .. ',' .. y .. ',' .. z] or '#'
    if c == '?' then return nil end
    return {c = c, dig = '', bld = '', flow = DEPTH[c] or 0}
  end
  function snap.liquids(K, x0, y0, x1, y1, z, min)
    local out = {}
    for y = y0, y1 do
      for x = x0, x1 do
        local f = DEPTH[W.cmap[x .. ',' .. y .. ',' .. z] or ''] or 0
        if f >= (min or 1) then out[#out + 1] = {x, y, f, 0} end
      end
    end
    return out
  end
  function snap.reach(K, a, b) return not W.unreach[b.x .. ',' .. b.y .. ',' .. b.z] end
  W.load(snap)
  W.pending = opts.pending or {}
  W.load({name = 'runner', every = {ticks = 600}, pending = function(K, tpl) return W.pending[tpl] or 0 end,
          kept_in = function() return nil end, bp_params = function() return {} end})
  W.act_result('pond_remove', function(id)
    for _, b in ipairs(df.global.world.buildings.other.ANY_ZONE) do if b.id == id then b.type = 0 end end
    return true, 1
  end)
  if opts.setup then opts.setup(W) end
  package.loaded['dfllm.water'] = nil
  local M = require('dfllm.water')
  W.load(M)
  return W, M
end

local function day(W, n) for _ = 1, n or 1 do W.run(1200, {skip = 10}) end end
local function well(W, x, y, z, spec)
  spec = spec or {}
  spec.x1, spec.y1, spec.x2, spec.y2, spec.z = x, y, x, y, z
  return F.building(W, 'WELL', spec)
end
local function pond(W, id, x, y, z)
  return F.building(W, 'ANY_ZONE', {id = id, type = df.civzone_type.Pond, x1 = x, y1 = y, x2 = x, y2 = y, z = z})
end
local function hospital(W) return F.hospital(W, {10, 10, 14, 14, 5}) end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l end end
end
local WET = {['20,12,4'] = '_', ['20,12,3'] = '~'}       -- a well at 20,12,5 over water two levels down

---------------------------------------------------------------- BUG-263
T.test('BUG-263 (Run 15 Drillchamber y373: well 17813 accepted, its pond 17822 removed as a loop, HOSPITAL_DRY 13 days ' ..
       'later): a wet well with its own pond beside it is no accepted source; the hospital beside it is dry and says why',
       function()
  local wid
  local W, M = world{tiles = WET, setup = function(W)
    hospital(W)
    wid = well(W, 20, 12, 5).id
    pond(W, 80, 21, 12, 5)
  end}
  day(W)
  local w = W.state().water
  T.eq(w.src, {}, 'old code: src {{20,12,5}} (bp sites hospital ranked by it)')
  T.eq(w.hosp_ok, 0)
  T.ok(logged(W, 'water: pond zone 80 removed'), 'pond_loops as before')
  local hd = W.find_events('HOSPITAL_DRY')
  T.eq(#hd, 1, 'old code: no gate (the loop well served the hospital)')
  local want = string.format('well %d at 20,12,5 is fed only by its own pond 80 (a loop, no outside supply)', wid)
  T.ok(hd[1].d.why:find(want, 1, true), hd[1].d.why)
  T.ok(hd[1].msg:find('(' .. want, 1, true), hd[1].msg)
  T.eq({M.wet_wells(W.K, 'Kern+')}, {1, 1}, 'the stored water still counts as drink for a burrow (siege, refuge)')
  -- the pond is gone, the well still holds its store: still no source
  day(W)
  T.eq(W.state().water.src, {})
  -- dry: forgotten; wet again without a pond (a pipe, the aquifer): accepted
  W.cmap['20,12,3'] = '.'
  day(W)
  W.cmap['20,12,3'] = '~'
  day(W)
  T.eq(W.state().water.src, {{20, 12, 5}})
  T.eq(W.state().water.hosp_ok, 1)
end)

T.test('BUG-263: a wet Water Source zone is the real supply: the well beside a pond is accepted (no loop)', function()
  local W = world{tiles = {['20,12,4'] = '_', ['20,12,3'] = '~', ['30,12,5'] = '~'}, setup = function(W)
    hospital(W)
    well(W, 20, 12, 5)
    pond(W, 80, 21, 12, 5)
    F.building(W, 'ZONE_WATER_SOURCE', {id = 82, type = df.civzone_type.WaterSource, x1 = 30, y1 = 12, x2 = 30, y2 = 12,
                                        z = 5, spec_sub_flag = {active = true}})
  end}
  day(W)
  local src = W.state().water.src
  T.eq(#src, 2, 'the well and the zone')
  T.eq(W.find_events('HOSPITAL_DRY'), {})
end)

T.test('BUG-263: the source a planned hospital was placed by drops out (its pond appears): HOSPITAL_DRY names it and ' ..
       'why', function()
  local wid
  local W = world{tiles = WET, pending = {hospital = 1}, setup = function(W) wid = well(W, 20, 12, 5).id end}
  day(W)
  T.eq(W.state().water.src, {{20, 12, 5}})
  T.eq(W.find_events('HOSPITAL_DRY'), {}, 'accepted water: no gate')
  pond(W, 81, 20, 13, 5)
  day(W)
  local hd = W.find_events('HOSPITAL_DRY')
  T.eq(#hd, 1)
  local want = string.format('the accepted well %d at 20,12,5 dropped out (fed only by its own pond 81: a loop)', wid)
  T.ok(hd[1].d.why:find('no accepted water on the map: ' .. want, 1, true), hd[1].d.why)
  T.ok(hd[1].msg:find('planned hospital without accepted water, 0 patient(s) (' .. want, 1, true), hd[1].msg)
  T.ok(#hd[1].msg <= 200 and #hd[1].d.why <= 200)
end)

---------------------------------------------------------------- BUG-266
T.test('BUG-266 (Run 15 Drillchamber y372: fortcore well 17718 dry, Kern+ refused): HOSPITAL_DRY names the dry well, ' ..
       'that only buckets fill its sump, and the fill source the scan found', function()
  local wid
  local W = world{tiles = {['20,12,4'] = '_', ['20,12,3'] = '.', ['26,20,5'] = '~', ['27,20,5'] = '~', ['25,20,5'] = '.'},
                  setup = function(W)
                    hospital(W)
                    wid = well(W, 20, 12, 5).id
                    pond(W, 80, 21, 12, 5)
                  end}
  day(W)
  local hd = W.find_events('HOSPITAL_DRY')
  T.eq(#hd, 1)
  local want = string.format('dry well %d at 20,12,5 (0/7): only buckets fill its sump; fill source: the water at ' ..
                             '26,20,5 (bank 25,20,5)', wid)
  T.ok(hd[1].d.why:find(want, 1, true), 'the alarm waited for the scan: ' .. hd[1].d.why)
  T.ok(hd[1].msg:find('(' .. want:sub(1, 30), 1, true), hd[1].msg)
  -- without water a carrier reaches
  local W2 = world{tiles = {['20,12,4'] = '_', ['20,12,3'] = '.'}, setup = function(W) hospital(W); well(W, 20, 12, 5) end}
  day(W2)
  T.ok(W2.find_events('HOSPITAL_DRY')[1].d.why:find('only buckets fill its sump; no water a carrier reaches to fill it',
                                                    1, true))
end)

---------------------------------------------------------------- BUG-264
local function chain_well(W)
  local w = well(W, 49, 90, 5, {getBuildStage = function() return 0 end, getMaxBuildStage = function() return 1 end})
  w.jobs = kmock.vec{{items = kmock.vec{}, job_items = {elements = kmock.vec{{item_type = df.item_type.BLOCKS, quantity = 1},
                                                                            {item_type = df.item_type.CHAIN, quantity = 1}}}}}
  return w
end
local function chains(W)
  local out = {}
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == 'dfllm:chain' then out[#out + 1] = a end end
  return out
end
local function requests(W, why)
  local out = {}
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.why == why then out[#out + 1] = e end end
  return out
end

T.test('BUG-264 (Run 15 Earthboat: the hospital well waited a year for "chain x1", 0 bars, 0 cloth, 244 thread): thread ' ..
       'without cloth: the Loom and the Clothier\'s shop are requested, again only after 14 days; HOSPITAL_DRY names it',
       function()
  local W, M = world{census_i = {thread = 244, cloth = 0}, setup = function(W)
    hospital(W)
    chain_well(W)
  end}
  day(W)
  local rq = requests(W, 'well')
  T.eq(#rq, 1, 'old code: nothing asked for the rope')
  T.eq({rq[1].d.tpl, rq[1].d.types}, {'workshops', {'Loom', 'Clothiers'}})
  local _, _, data = M.inspect(W.K, 'water_sources')
  T.eq({data.chain.route, data.chain.need}, {'thread', {'Loom', 'Clothiers'}})
  local hd = W.find_events('HOSPITAL_DRY')
  T.ok(hd[1].d.why:find('waits for a chain: a rope: thread 244, no cloth: Loom+Clothiers', 1, true), hd[1].d.why)
  day(W, 10)
  T.eq(#requests(W, 'well'), 1)
  day(W, 5)
  T.eq(#requests(W, 'well'), 2, 'after 14 days')
  W.pending.workshops = 1
  day(W, 15)
  T.eq(#requests(W, 'well'), 2, 'never while a workshops project is pending')
end)

T.test('BUG-264: hard-metal bars and a forge: a MakeChain order of that metal, never doubled; cloth and a Clothier\'s: a ' ..
       'cloth rope; nothing at all: buy rope or a chain', function()
  local W = world{census_i = {thread = 0, cloth = 0}, setup = function(W)
    chain_well(W)
    F.mat(W, 0, 5, {token = 'INORGANIC:IRON', flags = {IS_METAL = true, ITEMS_HARD = true}})
    F.mat(W, 0, 6, {token = 'INORGANIC:GOLD', flags = {IS_METAL = true}})
    F.item(W, 'BAR', {mat_type = 0, mat_index = 5})
    for _ = 1, 3 do F.item(W, 'BAR', {mat_type = 0, mat_index = 6}) end      -- gold makes no chain
    F.workshop(W, 'MetalsmithsForge')
  end}
  day(W)
  local o = chains(W)
  T.eq(#o, 1)
  T.eq({o[1].args[1].job, o[1].args[1].material, o[1].args[1].tag, o[1].args[1].amount_total},
       {'MakeChain', 'INORGANIC:IRON', 'dfllm:chain', 1})
  day(W, 20)
  T.eq(#chains(W), 1, 'the live order is not doubled')
  -- cloth, a Clothier's shop and a live rope order of somebody else's: no new order
  local W2 = world{census_i = {cloth = 3}, setup = function(W)
    chain_well(W)
    F.workshop(W, 'Clothiers')
    F.order(W, {job_type = df.job_type.MakeChain, amount_left = 1})
  end}
  day(W2)
  T.eq(#chains(W2), 0)
  local W3 = world{census_i = {cloth = 3}, setup = function(W) chain_well(W); F.workshop(W, 'Clothiers') end}
  day(W3)
  T.eq(chains(W3)[1].args[1].material_category, {'cloth'})
  local W4 = world{census_i = {}, setup = function(W) hospital(W); chain_well(W) end}
  day(W4)
  T.eq(#chains(W4), 0)
  T.eq(#requests(W4, 'well'), 0)
  T.ok(W4.find_events('HOSPITAL_DRY')[1].d.why:find('no metal, cloth or thread: buy rope or a chain', 1, true))
end)

---------------------------------------------------------------- BUG-265 / BUG-262 recipes
T.test('BUG-265: deep water 9 walls from a reachable floor is dug to (ws_dig 16; old 8: "a cistern")', function()
  local tiles = {['40,40,5'] = '~', ['50,40,5'] = '.'}
  for x = 38, 52 do
    for _, y in ipairs({39, 41}) do tiles[x .. ',' .. y .. ',5'] = '?' end
  end
  for _, y in ipairs({39, 40, 41}) do tiles['39,' .. y .. ',5'] = '?'; tiles['51,' .. y .. ',5'] = '?' end
  local W = world{tiles = tiles, setup = function(W) F.hospital(W, {30, 30, 34, 34, 5}) end}
  day(W)
  local hd = W.find_events('HOSPITAL_DRY')
  T.ok(hd[1].d.recipe:find('dig 9 wall tile(s) from 50,40,5', 1, true), hd[1].d.recipe)
end)

T.test('BUG-265: water with no bank and no dig: a cistern piped to it (bp.sites cistern --near); BUG-262: an aquifer ' ..
       'level known and no water at all: the aquifer well', function()
  local tiles = {['40,40,5'] = '~'}
  for _, o in ipairs({{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}) do
    tiles[(40 + o[1]) .. ',' .. (40 + o[2]) .. ',5'] = '?'
  end
  local W = world{tiles = tiles, setup = function(W) F.hospital(W, {30, 30, 34, 34, 5}) end}
  day(W)
  local r = W.find_events('HOSPITAL_DRY')[1].d.recipe
  T.ok(r:find('the water at 40,40,5 (7/7, 6 tiles) has no bank and no dig within 16 walls: a cistern piped to it ' ..
              '(python -m dfpilot.bp.sites cistern --near 40,40,5)', 1, true), r)
  local man = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {{0, 0, 0, 99, 99, 20}}},
               aquifer_levels = {3, 4}}
  local W2 = world{manifest = man, setup = hospital}
  day(W2)
  r = W2.find_events('HOSPITAL_DRY')[1].d.recipe
  T.ok(r:find('no reachable water >= 4/7 within 30 tiles: an aquifer well (dfllm bp sites cistern water=aquifer: its ' ..
              'basin on aquifer level z4)', 1, true), r)
end)

---------------------------------------------------------------- BUG-262: the cistern basin keeps its aquifer walls
local function host(own)
  local X = {rt = {aq = {}}, ev = {}, qf_calls = {}, t = 5000, logs = {}}
  X.now = function() return X.t end
  X.dirty, X.level = function() end, function() end
  X.log = function(_, f, ...) X.logs[#X.logs + 1] = string.format(f, ...) end
  local tiles = {}
  X.tiles = tiles
  X.tile = function(x, y, z) return tiles[x .. ',' .. y .. ',' .. z] end
  X.emit = function(t, c, m, d) X.ev[#X.ev + 1] = {type = t, cls = c, msg = m, d = d} end
  X.own = function() return own end
  X.live = function() return true end
  X.qf = function(o) X.qf_calls[#X.qf_calls + 1] = o; return true end
  return X
end

T.test('BUG-262: damp stone in a cistern basin (an own tile under an own tile) keeps its rough walls and its rising ' ..
       'water is no heavy stop; a pipe tile and any other project are sealed as before', function()
  local own = {['20,20,89'] = true, ['20,20,90'] = true, ['30,20,89'] = true}     -- basin under the room; a pipe tile
  local X = host(own)
  for _, k in ipairs({'20,20,89', '30,20,89'}) do X.tiles[k] = {c = '.', dig = ''} end
  for _, k in ipairs({'21,20,89', '19,20,89', '20,21,89', '20,19,89', '31,20,89', '29,20,89', '30,21,89', '30,19,89'}) do
    X.tiles[k] = {c = '#', dig = ''}
  end
  local P = {id = 'cis1', tpl = 'cistern'}
  T.ok(AQ.observe(X, P, {20, 20, 89}, 'report'))
  AQ.observe(X, P, {30, 20, 89}, 'report')
  local r = X.rt.aq.cis1
  T.eq({r.pts[1][4], r.pts[2][4]}, {'keep', 'new'}, 'old code: both new (both sealed)')
  AQ.tick(X)
  T.eq(#X.qf_calls, 1, 'only the pipe tile is smoothed around')
  T.eq(X.qf_calls[1].pos, {30, 20, 89})
  T.ok(X.logs[1]:find('in the cistern basin: its walls stay rough', 1, true), X.logs[1])
  local heavy = false
  for f = 1, 3 do heavy = AQ.wet(X, P, {20, 20, 89, 'd'}, f) or heavy end
  T.eq(heavy, false, 'water rising in the basin is the point')
  local Pf = {id = 'f1', tpl = 'fortcore'}
  AQ.observe(X, Pf, {20, 20, 89}, 'report')
  T.eq(X.rt.aq.f1.pts[1][4], 'new', 'not a cistern: sealed')
  local hv = false
  for f = 1, 3 do hv = AQ.wet(X, Pf, {22, 22, 89, 'd'}, f) or hv end
  T.eq(hv, true, 'another project: rising water stops it')
end)

T.done()
