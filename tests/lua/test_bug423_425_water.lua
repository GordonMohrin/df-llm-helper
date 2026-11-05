-- Run 16a i1 Manorsubtle (13 of 15 dead of thirst): BUG-423 the water scan reported one body of 1229 tiles with `at` 10,0,158 (its first
-- tile in y order, at the map edge) although the brook ran in a gully 8 tiles from the start room; now `at` is the water tile NEAREST
-- to the fort or a citizen and the bank search starts there. BUG-424 the no_water decision names that tile, asks the cistern with its
-- pipe (PROJECT_REQUEST cistern why=no_water, drink below economy.drink.access_d days). BUG-425 a built well over 2/7 is a slow
-- emergency drink source when nothing else exists. Every test fails on 03f4c1a.
local T = require('testlib')
local F = require('wp8_world')
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DEPTH = {['~'] = 7, w = 2}

local function owners()
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'pond_remove'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn] or {}) do if o ~= 'water' then keep[#keep + 1] = o end end
    keep[#keep + 1] = 'water'
    C.ACT[fn] = keep
  end
end

-- tiles {['x,y,z'] = c} (default '#'), pos (unit positions), setup(W)
local function world(opts)
  opts = opts or {}
  owners()
  local units = {}
  for i = 1, 4 do units[i] = {id = i, citizen = true, pos = (opts.pos or {})[i] or {12, 12, 5}} end
  local man = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {{0, 0, 0, 199, 199, 20}}}}
  local cfg = F.cfg()
  cfg.water = opts.water
  local W = F.world{cfg = {baseline = cfg}, units = units, persist = {manifest = man}}
  df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
  df.civzone_type.Pond, df.civzone_type[11] = 11, 'Pond'
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  local ids = {}
  for i = 1, 4 do
    ids[i] = i
    W.unit(i).counters2 = {thirst_timer = 1000}
    W.unit(i).job = {current_job = nil}
  end
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 0, 0, 199, 199, 20})
  W.cmap = opts.tiles or {}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile(K, x, y, z)
    local k = x .. ',' .. y .. ',' .. z
    local c = W.cmap[k] or '#'
    if c == '?' then return nil end
    return {c = c, dig = '', bld = '', flow = (opts.flow or {})[k] or DEPTH[c] or 0, aq = false}
  end
  function snap.liquids(K, x0, y0, x1, y1, z, min, ice, lat)
    local out = {}
    local area = (x1 - x0 + 1) * (y1 - y0 + 1)
    if (lat and (area + lat - 1) // lat or area) > 4096 then return nil, 'rect too large' end
    for y = y0, y1 do
      for x = x0, x1 do
        if not lat or (x + 2 * y) % lat == 0 then
          local k = x .. ',' .. y .. ',' .. z
          local f = (opts.flow or {})[k] or DEPTH[W.cmap[k] or ''] or 0
          if f >= (min or 1) then out[#out + 1] = {x, y, f, 0} end
        end
      end
    end
    return out
  end
  function snap.reach(K, a, b) return not (opts.unreach or {})[b.x .. ',' .. b.y .. ',' .. b.z] end
  W.load(snap)
  W.load({name = 'runner', every = {ticks = 600}, pending = function() return 0 end,
          kept_in = function() return nil end, bp_params = function() return {} end,
          aq_seen = function() return true end})
  if opts.setup then opts.setup(W) end
  package.loaded['dfllm.water'] = nil
  local M = require('dfllm.water')
  W.load(M)
  return W, M
end

local function day(W, n) for _ = 1, n or 1 do W.run(1200, {skip = 10}) end end
local function sources(W, M)
  local ok, msg, d = M.inspect(W.K, 'water_sources')
  T.ok(ok, msg)
  return d
end

---------------------------------------------------------------- BUG-423
-- a brook along y = 40 from x = 0 to 60 (7/7), its bank row y = 39; the citizens and the hospital stand at x 10-14, y 10-14: the
-- first tile in y/x order is 0,40 (old `at`), the tile nearest to the fort is 10,40 (26 tiles)
local function brook()
  local t = {}
  for x = 0, 60 do t[x .. ',40,5'] = '~'; t[x .. ',39,5'] = '.' end
  return t
end

T.test('BUG-423: a long brook is one body whose `at` is the water tile nearest to the fort (old: its first tile in y order, ' ..
       'the map edge), with its distance `nd` and extent `ext`; the bank found is the one beside that tile', function()
  local W, M = world{tiles = brook(), setup = function(W) F.hospital(W, {10, 10, 14, 14, 5}) end}
  day(W, 30)
  local d = sources(W, M)
  T.eq(#d.bodies, 1)
  local b = d.bodies[1]
  T.eq(b.n, 45, 'the scan box: the hospital +- near')
  T.ok(b.at[1] >= 10 and b.at[1] <= 14 and b.at[2] == 40 and b.at[3] == 5, 'at ' .. json.encode(b.at) .. ' (old 0,40,5)')
  T.eq(b.nd, 26)
  T.eq(b.d, 26)
  T.eq(b.ext, {0, 40, 44, 40})
  T.ok(b.bank and b.bank[1] >= 9 and b.bank[1] <= 15 and b.bank[2] == 39, 'bank ' .. json.encode(b.bank or {}))
end)

T.test('BUG-423: a citizen standing at the far end of the water makes the tile beside him the nearest', function()
  local W, M = world{tiles = brook(), pos = {{12, 12, 5}, {55, 38, 5}}, setup = function(W) F.hospital(W, {10, 10, 14, 14, 5}) end}
  day(W, 30)
  local b = sources(W, M).bodies[1]
  T.eq(b.nd, 2, 'a citizen at 55,38: the water 2 tiles from him')
  T.ok(b.at[1] >= 54 and b.at[1] <= 56 and b.at[2] == 40, json.encode(b.at))
end)

T.test('BUG-423: drink_access gives the nearest water tile of a body without a bank, and the recipe names it', function()
  local W, M = world{tiles = {['30,20,5'] = '~', ['31,20,5'] = '~', ['30,60,5'] = '~', ['31,60,5'] = '~'},
                     setup = function(W) F.hospital(W, {10, 10, 14, 14, 5}) end}
  day(W, 30)
  local a = M.drink_access(W.K)
  T.eq(a.known, true)
  T.eq(a.ok, false)
  T.eq(a.near, {30, 20, 5})
  T.eq(a.nd, 16)
  local txt = M.drink_fix(W.K)
  T.ok(txt:find('cistern --near 30,20,5', 1, true) or txt:find('the water at 30,20,5', 1, true), txt)
end)

---------------------------------------------------------------- BUG-425
T.test('BUG-425: emerg_wells: nothing else accepted and no bank: a built well over 2/7 is accepted as a slow source; any real source, ' ..
       'a bank, an unknown scan, 1/7 or well_emerg 0 keep it out', function()
  local M = fresh('water')
  local function src() return {{kind = 'well', id = 7, x = 1, y = 1, z = 5, built = true, wet = false, below = {why = 'shallow', flow = 2}},
                               {kind = 'well', id = 8, x = 2, y = 2, z = 5, built = true, wet = false, below = {why = 'shallow', flow = 1}}} end
  local c = {well_emerg = 2}
  local s = src()
  T.eq(#M.emerg_wells(c, s, {bodies = {}}), 1)
  T.eq({s[1].wet, s[1].emerg, s[2].wet}, {true, true, false}, '2/7 yes, 1/7 no')
  s = src()
  T.eq(#M.emerg_wells(c, s, nil), 0, 'no scan yet: nothing on a guess')
  T.eq(#M.emerg_wells(c, s, {bodies = {{bank = {1, 2, 3}}}}), 0, 'a body with a bank the citizens reach: they drink there')
  T.eq(#M.emerg_wells(c, s, {bodies = {{cavern = 1, bank = {1, 2, 3}}}}), 1, 'cavern water is none')
  s = src()
  s[2].wet = true
  T.eq(#M.emerg_wells(c, s, {bodies = {}}), 0, 'a real source stands')
  T.eq(#M.emerg_wells({well_emerg = 0}, src(), {bodies = {}}), 0, 'off')
  T.eq(M.DEFAULTS.well_emerg, 2)
  s = src()                                                -- a citizen over well_thirst beside it: the trickle does not reach him
  T.eq(#M.emerg_wells(c, s, {bodies = {}}, {{id = 3, thirst = 61000, x = 2, y = 1, z = 5}}), 0, 'proof against well 7')
  T.eq({s[1].wet, s[1].emerg_no}, {false, 61000})
end)

T.test('BUG-425: in a run, a 2/7 well with no other water is an emergency source: a kern.log warning, no hospital water, not in ' ..
       'water.src, drink_access counts it apart and the thirst text says EMERGENCY', function()
  local W, M = world{tiles = {['20,12,4'] = 'w'}, setup = function(W)
    F.building(W, 'WELL', {id = 79, x1 = 20, y1 = 12, x2 = 20, y2 = 12, z = 5})
  end}
  day(W, 30)
  local a = M.drink_access(W.K)
  T.eq({a.known, a.acc, a.emerg, a.ok}, {true, 0, 1, false}, json.encode(a))
  local found = false
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('EMERGENCY: no other drink source, well 79', 1, true) then found = true end end
  T.ok(found, 'kern.log')
  local txt = M.drink_fix(W.K)
  T.ok(txt:find('EMERGENCY: well 79 at 20,12,5 over only 2/7 is accepted as a slow drink source', 1, true), txt)
  T.eq(#(W.state().water.src or {}), 0, 'plan keeps asking for real water')
  local W2, M2 = world{tiles = {['20,12,4'] = 'w'}, water = {well_emerg = 0}, setup = function(W)
    F.building(W, 'WELL', {id = 79, x1 = 20, y1 = 12, x2 = 20, y2 = 12, z = 5})
  end}
  day(W2, 30)
  T.eq(M2.drink_access(W2.K).emerg, 0, 'well_emerg 0: as before')
end)

---------------------------------------------------------------- BUG-424 (economy)
local SEASONS = {SPRING = true, SUMMER = true, AUTUMN = true, WINTER = true}
local function days(W, n)
  for _ = 1, n do
    W.run(1200, {skip = 100})
    for _ = 1, 60 do W.run(1) end
  end
end
local function events(W, typ, id)
  local r = {}
  for _, e in ipairs(W.find_events(typ)) do if not id or e.d.id == id then r[#r + 1] = e end end
  return r
end

local function econ_world(opts)
  local cit = 7
  local units = {}
  for i = 1, cit do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}} end
  local cfg = F.cfg()
  cfg.economy.standing = false
  if opts.access_d then cfg.economy.drink = {low_d = 60, access_d = opts.access_d} end
  local W = F.world{cfg = {baseline = cfg}, units = units}
  local ids = {}
  for i = 1, cit do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors, u.mood = {}, -1
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  W.set_census('u', F.census_u(ids))
  df.global.world.raws.plants.all = require('dfllm.util.k_mock').vec{{id = 'MUSHROOM_HELMET_PLUMP', flags = {SEED = true, SPRING = true, SUMMER = true,
                                                                                         AUTUMN = true, WINTER = true},
                                                underground_depth_min = 1, growths = require('dfllm.util.k_mock').vec{}}}
  F.mat(W, 419, 60, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:SEED'})
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = opts.drinks or 70})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  W.load({name = 'water', every = {ticks = 100000}, drink_access = function() return opts.access end,
          drink_fix = function() return 'no accepted water; a cistern piped to the water at 102,72,158',
                                        {'dfllm cmd inspect what=water_sources', 'dfllm bp sites cistern'} end})
  F.workshop(W, 'Still')
  F.workshop(W, 'Kitchen')
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.', bld = '', dig = ''} end,
          plot_under = function() return true end})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, pending = function() return 0 end,
          state = function() return {phase = 'P1'} end})
  package.loaded['dfllm.economy'] = nil
  W.load(require('dfllm.economy'))
  return W
end

local NEAR = {known = true, ok = false, acc = 0, bank = 0, bodies = 1, partial = 0, emerg = 0, near = {102, 72, 158}, nd = 8}

T.test('BUG-423/424: no_water names the water tile nearest to the fort (d.near, d.nd, the cistern command with it) and, with ' ..
       'drink below access_d days, asks PROJECT_REQUEST cistern why=no_water with that tile', function()
  local W = econ_world{access = NEAR, drinks = 40}      -- ~107 drink days: below access_d 400
  days(W, 1)
  local d = events(W, 'DECISION_NEEDED', 'no_water')
  T.eq(#d, 1)
  T.eq(d[1].d.near, {102, 72, 158})
  T.eq(d[1].d.nd, 8)
  local joined = table.concat(d[1].d.cmds, '\n')
  T.ok(joined:find('python -m dfpilot.bp.sites cistern --near 102,72,158 --radius 20', 1, true), joined)
  local r = events(W, 'PROJECT_REQUEST')
  T.eq(#r, 1, 'old code: no request')
  T.eq({r[1].d.tpl, r[1].d.why, r[1].d.at, r[1].d.n}, {'cistern', 'no_water', {102, 72, 158}, 8})
end)

T.test('BUG-424: plenty of drink (>= access_d days) or access_d 0: the decision comes, no cistern request yet', function()
  local W = econ_world{access = NEAR, drinks = 400}
  days(W, 1)
  T.eq(#events(W, 'DECISION_NEEDED', 'no_water'), 1)
  T.eq(#events(W, 'PROJECT_REQUEST'), 0)
  local W2 = econ_world{access = NEAR, drinks = 40, access_d = 0}
  days(W2, 1)
  T.eq(#events(W2, 'PROJECT_REQUEST'), 0, 'access_d 0 = never')
end)

T.test('BUG-425: an emergency well in drink_access: the decision says so in d.auto', function()
  local acc = {known = true, ok = false, acc = 0, bank = 0, bodies = 1, partial = 0, emerg = 1, near = {102, 72, 158}, nd = 8}
  local W = econ_world{access = acc}
  days(W, 1)
  local d = events(W, 'DECISION_NEEDED', 'no_water')
  T.eq(#d, 1)
  T.ok(table.concat(d[1].d.auto, ' '):find('EMERGENCY well', 1, true), table.concat(d[1].d.auto, ' '))
end)

T.done()
