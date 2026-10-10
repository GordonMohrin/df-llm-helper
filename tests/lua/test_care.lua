-- care (WP8): moods, burial, corpses, captives, hospital water, barrel guard, stress and naked sampler.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end

local function shirt() return {mode = 2, item = {getType = function() return df.item_type.ARMOR end}} end

local MANIFEST = {v = 2, burrows = {['Kern+'] = {role = 'kern'}},
                  bridges = {O1 = {role = 'outer', fp = {20, 20, 10, 22, 20, 10}, levers = {{1, 1, 10}}}},
                  zones = {Z4 = {{0, 0, 5, 50, 50, 5}}}}

-- a job that counts reads of job_items (the showmood data care must never read)
local function job(W, id, holder)
  return setmetatable({id = id, items = kmock.vec{}, _holder = holder}, {__index = function(_, k)
    if k == 'job_items' then W.job_items_reads = (W.job_items_reads or 0) + 1 end
  end})
end

-- opts: cit, units, persist, manifest, mode, caged, kern (false: no Kern+ burrow), no_snapshot, setup
local function world(opts)
  opts = opts or {}
  local n = opts.cit or 4
  local units = {}
  for i = 1, n do units[i] = {id = i, citizen = true} end
  for _, u in ipairs(opts.units or {}) do units[#units + 1] = u end
  local persist = opts.persist or {}
  if opts.manifest ~= false then persist.manifest = persist.manifest or opts.manifest or MANIFEST end
  local W = F.world{cfg = {baseline = F.cfg(), decisions = opts.decisions}, units = units, mode = opts.mode,
                    persist = persist}
  local ids = {}
  for i = 1, n do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = job(W, 900 + i)}
    u.mood = -1
    u.inventory = kmock.vec{shirt()}
    u.status = {current_soul = {personality = {emotions = kmock.vec{}}}}
    u.counters = {death_cause = 1}
  end
  W.set_census('u', F.census_u(ids, {caged = opts.caged or {}}))
  if opts.kern ~= false then W.burrow('Kern+', {0, 0, 0, 50, 50, 9}) end
  W.hidden = {}
  if opts.setup then opts.setup(W) end
  if not opts.no_snapshot and not W.mods.snapshot then      -- revealed everywhere but W.hidden['x,y,z']
    W.load({name = 'snapshot', every = {ticks = 100}, tile = function(K, x, y, z)
      if W.hidden[x .. ',' .. y .. ',' .. z] then return nil end
      return {c = '.', dig = '', bld = ''}
    end})
  end
  local Cm = fresh('care')
  W.load(Cm)
  return W, Cm
end

local function day(W, n) for _ = 1, n or 1 do W.run(1200, {skip = 100}) end end
local function acts(W, fn, flag)
  local r = {}
  for _, a in ipairs(W.find_acts(fn)) do
    if flag == nil or a.args[2] == flag then r[#r + 1] = {a.args[1], a.args[2], a.args[3]} end
  end
  return r
end
local function sorted(list)
  table.sort(list, function(a, b) return a[1] * 10 + #a[2] < b[1] * 10 + #b[2] end)
  return list
end

T.test('config/baseline.json mirrors care.DEFAULTS', function()
  T.eq(F.read_json('config/baseline.json').care, fresh('care').DEFAULTS)
end)

T.test('stress category and naked sampler', function()
  local W = world{cit = 5, setup = function(W)
    W.unit(1)._m.stress, W.unit(2)._m.stress = 0, 1
    W.unit(3).inventory = kmock.vec{}                           -- naked
    W.unit(4).inventory = kmock.vec{}
    W.unit(4)._m.baby = true                                    -- babies do not count as naked
    W.unit(5).inventory = kmock.vec{{mode = 1, item = {getType = function() return df.item_type.ARMOR end}}}
  end}
  W.run(1)
  local s = W.state()
  T.eq(s.care.stressed_pct, 40)
  T.eq(s.care.naked, 2)
  T.eq(s.stock.hosp_water, 0)
  T.eq(W.bad_vectors, {}, 'only real buildings_other / items_other vectors')
end)

T.test('moods: needs from the claimed workshop only (never job_items), MOOD_NEED, MOOD_END', function()
  local W = world{setup = function(W)
    W.unit(1).mood = df.mood_type.Fey                            -- Jeweler's: rough gems or cut gems
    W.unit(1).job.current_job._holder = F.workshop(W, 'Jewelers')
    W.unit(2).mood = df.mood_type.Secretive                      -- no workshop claimed yet
    W.unit(2).job.current_job = nil
    W.unit(2)._m.skills = {MINING = 12, WOODCRAFT = 5, CARPENTRY = 3}
    W.unit(3).mood = df.mood_type.Fell                           -- forge: metal bars, only a coal bar exists
    W.unit(3).job.current_job._holder = F.workshop(W, 'MetalsmithsForge')
    W.unit(4).mood = df.mood_type.Macabre                        -- craftsdwarf: bone already brought
    W.unit(4).job.current_job._holder = F.workshop(W, 'Craftsdwarfs')
    W.unit(4).job.current_job.items = kmock.vec{{item = {getType = function() return df.item_type.CORPSEPIECE end}}}
    F.item(W, 'ROUGH', {id = 1, flags = {forbid = true}, _pos = {10, 10, 5}})
    F.item(W, 'ROUGH', {id = 2, flags = {forbid = true}, _pos = {11, 10, 5}})   -- one is enough
    F.item(W, 'SMALLGEM', {id = 3, flags = {forbid = true}, _pos = {100, 100, 5}})   -- outside Kern+
    F.item(W, 'SMALLGEM', {id = 4, flags = {dump = true}, _pos = {12, 10, 5}})
    F.item(W, 'BAR', {id = 5, mat_type = 7, _pos = {10, 10, 5}})
    F.item(W, 'BOULDER', {id = 6, flags = {forbid = true}, _pos = {10, 10, 5}})   -- unit 4 is served
  end}
  W.run(1)
  T.eq(#W.find_events('MOOD_START'), 4)
  T.eq(sorted(acts(W, 'item_flag')), {{1, 'forbid', false}, {4, 'dump', false}})
  local need = W.find_events('MOOD_NEED')
  T.eq(#need, 1)
  T.eq({need[1].d.unit, need[1].d.need, need[1].d.kind, need[1].d.ws}, {3, 'bars', 'Fell', 'MetalsmithsForge'})
  day(W)
  T.eq(#W.find_events('MOOD_START'), 4, 'not repeated')
  need = W.find_events('MOOD_NEED')
  T.eq(#need, 2, 'bars not repeated; workshop once')
  T.eq({need[2].d.unit, need[2].d.need, need[2].d.skill}, {2, 'workshop', 'WOODCRAFT'})
  T.eq(W.state().care.moods, 4)
  W.unit(1).mood = -1
  W.unit(2).mood = df.mood_type.Berserk
  day(W)
  local fin = W.find_events('MOOD_END')
  table.sort(fin, function(a, b) return a.d.unit < b.d.unit end)
  T.eq({fin[1].d.unit, fin[1].d.ok, fin[2].d.unit, fin[2].d.ok}, {1, 1, 2, 0})
  T.eq(W.state().care.moods, 2)
  T.eq(W.job_items_reads, nil, 'job_items never read (showmood is armok)')
  for _, a in ipairs(W.acts) do
    T.ok(a.fn == 'item_flag' or a.fn == 'run' or a.fn == 'zone_assign', 'unexpected act ' .. a.fn)
  end
  T.eq(W.bad_vectors, {})
end)

T.test('moods: an unknown workshop gives no need; Craftsdwarfs with nothing at all -> one MOOD_NEED', function()
  local W = world{setup = function(W)
    W.unit(1).mood = df.mood_type.Fey
    W.unit(1).job.current_job._holder = F.workshop(W, 'Craftsdwarfs')
    W.unit(2).mood = df.mood_type.Fey
    W.unit(2).job.current_job._holder = F.workshop(W, 'Farmers')
  end}
  W.run(1)
  local need = W.find_events('MOOD_NEED')
  T.eq(#need, 1)
  T.eq({need[1].d.unit, need[1].d.need}, {1, 'bone/shell/rock/wood'})
end)

T.test('deaths: DEATH per citizen, DEATHS_3PLUS once per day, others ignored', function()
  local W = world{cit = 6, units = {{id = 99, invader = true}}}
  W.run(1)
  W.event('UNIT_DEATH', {unit = 99})
  W.event('UNIT_DEATH', {unit = 1}); W.event('UNIT_DEATH', {unit = 2})
  W.run(1)
  T.eq(#W.find_events('DEATH'), 2)
  T.eq(W.find_events('DEATH')[1].d.cause, 'HUNGER')
  T.eq(#W.find_events('DEATHS_3PLUS'), 0)
  W.event('UNIT_DEATH', {unit = 3}); W.event('UNIT_DEATH', {unit = 3}); W.event('UNIT_DEATH', {unit = 4})
  W.run(1)
  local a = W.find_events('DEATHS_3PLUS')
  T.eq(#a, 1)
  T.eq(a[1].cls, 'A')
  T.eq(a[1].d.ids, {1, 2, 3}, 'emitted at the third death')
  T.eq(#W.find_events('DEATH'), 4, 'unit 3 once')
end)

T.test('deaths: census already dropped the dead citizen; insane members count; animals do not', function()
  local W = world{cit = 4, units = {{id = 20, own_group = true}, {id = 21, own_group = true, animal = true},
                                    {id = 22, visitor = true}}}
  W.run(1)
  W.kill(3)
  W.set_census('u', F.census_u({1, 2, 4}))                     -- sense rescanned before the event
  W.event('UNIT_DEATH', {unit = 3})
  W.kill(20)                                                   -- berserk citizen, never in getCitizens
  W.event('UNIT_DEATH', {unit = 20})
  W.kill(21); W.event('UNIT_DEATH', {unit = 21})
  W.kill(22); W.event('UNIT_DEATH', {unit = 22})
  W.run(1)
  local d = W.find_events('DEATH')
  T.eq({#d, d[1].d.unit, d[2].d.unit}, {2, 3, 20})
  T.eq(W.K.persist.get('m.care').dead, {3, 20})
end)

T.test('a corpse scan before UNIT_DEATH does not swallow the DEATH event', function()
  local W = world{}
  W.kill(2)
  F.item(W, 'ANY_CORPSE', {unit_id = 2, flags = {forbid = true}, _pos = {5, 5, 5}})
  W.run(1)
  T.eq(W.K.persist.get('m.care').dead, {2}, 'tracked from the corpse')
  T.eq(#W.find_events('DEATH'), 0)
  W.event('UNIT_DEATH', {unit = 2})
  W.run(1)
  T.eq(#W.find_events('DEATH'), 1)
end)

T.test('tombs: PROJECT_REQUEST when free < open corpses + 6, rate-limited; corpses_old, ghosts', function()
  local W = world{setup = function(W)
    F.building(W, 'ZONE_TOMB', {assigned_unit_id = -1, spec_sub_flag = {active = true}})
    F.building(W, 'ZONE_TOMB', {assigned_unit_id = 7, spec_sub_flag = {active = true}})
    F.building(W, 'ZONE_TOMB', {assigned_unit_id = -1, spec_sub_flag = {active = false}})
  end}
  W.run(1)
  local req = W.find_events('PROJECT_REQUEST')
  T.eq(#req, 1, 'core exists: keep 6 spare tombs')
  T.eq({req[1].d.tpl, req[1].d.n}, {'tombs', 5})
  W.event('UNIT_DEATH', {unit = 3})
  W.run(1)
  W.kill(3)
  W.unit(3)._m.ghost = true
  F.item(W, 'ANY_CORPSE', {unit_id = 3, flags = {forbid = true}, _pos = {5, 5, 5}})
  F.item(W, 'ANY_CORPSE', {unit_id = 3, flags = {in_building = true}, _pos = {5, 5, 5}})
  day(W)
  local s = W.state()
  T.eq({s.care.tombs_free, s.care.corpses_old, s.care.ghosts}, {1, 0, 1})
  T.eq(acts(W, 'item_flag'), {{5001, 'forbid', false}}, 'citizen corpse unforbidden for burial, never dumped')
  T.eq(#W.find_events('PROJECT_REQUEST'), 1, 'rate-limited')
  day(W, 2)
  req = W.find_events('PROJECT_REQUEST')
  T.eq(#req, 2)
  T.eq(req[2].d.n, 6)
  day(W, 1)
  T.eq(W.state().care.corpses_old, 1)
end)

T.test('no core yet and nobody dead: no tomb request', function()
  local W = world{manifest = {v = 2}}
  day(W, 2)
  T.eq(W.find_events('PROJECT_REQUEST'), {})
end)

T.test('approach corpses: dumped in late RECOVERY, untouched in SIEGE, citizens never dumped', function()
  local function setup(W)
    F.item(W, 'ANY_CORPSE', {id = 61, unit_id = 500, flags = {forbid = true}, _pos = {25, 22, 10}})  -- near O1
    F.item(W, 'ANY_CORPSE', {id = 62, unit_id = 501, _pos = {25, 60, 10}})                           -- far
    F.item(W, 'ANY_CORPSE', {id = 63, unit_id = 2, flags = {forbid = true, dump = true}, _pos = {21, 21, 10}})
  end
  local W = world{mode = 'SIEGE', setup = setup, persist = {['m.care'] = {v = 2, dead = {2}}}}
  day(W, 2)
  T.eq(W.find_acts('item_flag'), {})
  local W2 = world{mode = 'PEACE', setup = setup, persist = {['m.care'] = {v = 2, dead = {2}}}}
  W2.run(1)
  T.eq(sorted(acts(W2, 'item_flag')), {{61, 'dump', true}, {61, 'forbid', false}, {63, 'dump', false}, {63, 'forbid', false}},
       'hostile corpse dumped, citizen corpse freed for burial')
  local W3 = world{mode = 'SIEGE', setup = setup, persist = {['m.care'] = {v = 2, dead = {2}}}}
  W3.set_mode('RECOVERY')
  W3.run(1)
  T.eq(acts(W3, 'item_flag', 'dump'), {}, 'RECOVERY < 1,200 ticks: not yet')
  day(W3, 1)
  T.eq(acts(W3, 'item_flag', 'dump'), {{61, 'dump', true}, {63, 'dump', false}})
end)

T.test('a missed death: the corpse of a dead fort member is freed for burial, never dumped', function()
  local W = world{setup = function(W)
    W.kill(2)
    F.item(W, 'ANY_CORPSE', {id = 64, unit_id = 2, flags = {forbid = true}, _pos = {21, 21, 10}})  -- near O1
  end}
  W.run(1)
  T.eq(acts(W, 'item_flag'), {{64, 'forbid', false}})
  W.unit(2)._m.ghost = true
  day(W)
  T.eq(W.state().care.ghosts, 1, 'the ghost is counted')
end)

T.test('no Kern+ burrow: nothing is unforbidden in SIEGE; in PEACE only on revealed tiles', function()
  local function setup(W)
    W.kill(2)
    F.item(W, 'ANY_CORPSE', {id = 65, unit_id = 2, flags = {forbid = true}, _pos = {5, 5, 5}})
    F.item(W, 'BARREL', {id = 75, flags = {forbid = true}, _contents = {{getType = function() return df.item_type.DRINK end}},
                         _pos = {6, 5, 5}})
    W.unit(1).mood = df.mood_type.Fey
    W.unit(1).job.current_job._holder = F.workshop(W, 'MetalsmithsForge')
    F.item(W, 'BAR', {id = 85, flags = {forbid = true}, _pos = {7, 5, 5}})
  end
  local m = {v = 2, zones = {Z4 = {{0, 0, 5, 50, 50, 5}}}}
  for _, mode in ipairs({'SIEGE', 'ALERT'}) do
    local W = world{mode = mode, kern = false, manifest = m, setup = setup}
    W.set_census('i', {tick = 0, drink = 0, drink_forb = 5, food_forb = 0})
    day(W, 2)
    T.eq(W.find_acts('item_flag'), {}, mode)
  end
  local W = world{mode = 'PEACE', kern = false, manifest = m, setup = function(W)
    setup(W)
    W.hidden['6,5,5'] = true                                     -- the barrel lies on an unrevealed tile
  end}
  W.set_census('i', {tick = 0, drink = 0, drink_forb = 5, food_forb = 0})
  W.run(1)
  T.eq(sorted(acts(W, 'item_flag')), {{65, 'forbid', false}, {85, 'forbid', false}})
  local W2 = world{mode = 'PEACE', no_snapshot = true, setup = setup}
  W2.set_census('i', {tick = 0, drink = 0, drink_forb = 5, food_forb = 0})
  W2.run(1)
  T.eq(W2.find_acts('item_flag'), {}, 'no tile reader: no item writes')
end)

T.test('captives: CAPTURE once, melt-safe in any mode, pit after the deadline in PEACE', function()
  local cage = {id = 777, flags = {melt = true}}
  local W = world{mode = 'SIEGE', caged = {50}, units = {{id = 50, invader = true, caged = true, race = 'GOBLIN'}},
                  setup = function(W) W.unit(50)._cage = cage end}
  W.run(1)
  T.eq(#W.find_events('CAPTURE'), 1)
  T.eq(W.find_events('CAPTURE')[1].d.race, 'GOBLIN')
  T.eq(acts(W, 'item_flag'), {{777, 'melt', false}})
  day(W, 2)
  T.eq(W.find_acts('zone_assign'), {}, 'no hauling during a siege')
  T.eq(#W.find_events('CAPTURE'), 1)
  local m = {v = 2, pit = {30, 30, 2}}
  local W2 = world{caged = {50}, manifest = m, units = {{id = 50, invader = true, caged = true}},
                   setup = function(W)
                     W.unit(50)._cage = {id = 778, flags = {}}
                     W.civzones_at['30,30,2'] = {{id = 88, type = df.civzone_type.Pond}}
                   end}
  W2.run(1)
  T.eq(W2.find_acts('zone_assign'), {}, 'deadline not reached')
  day(W2)
  T.eq(#W2.find_acts('zone_assign'), 1)
  T.eq({W2.find_acts('zone_assign')[1].args[1], W2.find_acts('zone_assign')[1].args[2]}, {88, 50})
  day(W2)
  T.eq(#W2.find_acts('zone_assign'), 1, 'once')
end)

T.test('captives without a pit: the trap cage is marked for dumping (leaves the trap tile)', function()
  local W = world{caged = {50}, units = {{id = 50, invader = true, caged = true}},
                  setup = function(W) W.unit(50)._cage = {id = 779, flags = {}, _holder = {_trap = true}} end}
  W.run(1)
  day(W)
  T.eq(acts(W, 'item_flag'), {{779, 'dump', true}})
  -- the captive left the census (pitted, freed or dead): forgotten
  W.set_census('u', F.census_u({1, 2, 3, 4}, {caged = {}}))
  day(W)
  T.eq(next(W.K.persist.get('m.care').captives), nil)
end)

T.test('captives: a refused cage write is retried at most 3 times', function()
  local W = world{caged = {50}, units = {{id = 50, invader = true, caged = true}},
                  setup = function(W)
                    W.unit(50)._cage = {id = 780, flags = {melt = true}}
                    W.act_result('item_flag', function() return false, 'no item' end)
                  end}
  day(W, 6)
  T.eq(#W.find_acts('item_flag'), 3)
end)

T.test('hospital water: a zone linked to a hospital location, a well in it, water below', function()
  local function setup(W)
    F.hospital(W, {10, 10, 14, 14, 5})
    F.building(W, 'WELL', {x1 = 12, y1 = 12, z = 5, bucket_z = 2})
  end
  local W = world{no_snapshot = true, setup = setup}
  W.run(1)
  T.eq(W.state().stock.hosp_water, 1, 'no tile reader: trust the well')
  T.eq(W.bad_vectors, {}, 'no ZONE_HOSPITAL vector read')
  for _, case in ipairs({{{'_', 'w'}, 1}, {{'_', '#'}, 0}, {{'_', '_', '_', '_'}, 0}}) do
    local col = case[1]
    local W2 = world{setup = function(W)
      setup(W)
      W.load({name = 'snapshot', every = {ticks = 100},
              tile = function(K, x, y, z) local c = col[5 - z]; return c and {c = c, dig = '', bld = ''} or nil end})
    end}
    W2.run(1)
    T.eq(W2.state().stock.hosp_water, case[2], table.concat(col, ''))
  end
  local W3 = world{no_snapshot = true, setup = function(W)
    F.hospital(W, {10, 10, 14, 14, 5})
    F.building(W, 'WELL', {x1 = 30, y1 = 12, z = 5})
  end}
  W3.run(1)
  T.eq(W3.state().stock.hosp_water, 0, 'well outside the hospital')
  local W4 = world{no_snapshot = true, setup = function(W)
    F.building(W, 'ANY_ZONE', {x1 = 10, y1 = 10, x2 = 14, y2 = 14, z = 5, location_id = -1})   -- not a hospital
    W.site.buildings:insert('#', {id = 3, getType = function() return df.abstract_building_type.TEMPLE end})
    F.building(W, 'ANY_ZONE', {x1 = 10, y1 = 10, x2 = 14, y2 = 14, z = 5, location_id = 3})    -- a temple
    F.building(W, 'WELL', {x1 = 12, y1 = 12, z = 5})
  end}
  W4.run(1)
  T.eq(W4.state().stock.hosp_water, 0, 'a well in a temple or plain zone does not count')
end)

T.test('forbidden-barrel guard: unforbid drink barrels inside Kern+ only, only when drinks are locked', function()
  local function drink() return {getType = function() return df.item_type.DRINK end} end
  local function setup(W)
    F.item(W, 'BARREL', {id = 71, flags = {forbid = true}, _contents = {drink()}, _pos = {5, 5, 5}})
    F.item(W, 'BARREL', {id = 72, flags = {forbid = true}, _contents = {drink()}, _pos = {80, 5, 5}})
    F.item(W, 'BARREL', {id = 73, flags = {forbid = true}, _contents = {}, _pos = {5, 6, 5}})
    F.item(W, 'BARREL', {id = 74, flags = {}, _contents = {drink()}, _pos = {5, 7, 5}})
  end
  local W = world{setup = setup}
  W.set_census('i', {tick = 0, drink = 10, drink_forb = 0, food_forb = 0})
  W.run(1)
  T.eq(W.find_acts('item_flag'), {}, 'nothing locked: barrels not scanned')
  local W2 = world{setup = setup}
  W2.set_census('i', {tick = 0, drink = 10, drink_forb = 5, food_forb = 0})
  W2.run(1)
  T.eq(acts(W2, 'item_flag'), {{71, 'forbid', false}})
end)

T.test('burial -c for unzoned built coffins only', function()
  local W = world{setup = function(W)
    local c1 = F.building(W, 'COFFIN', {})
    c1.relations = kmock.vec{{type = df.civzone_type.Tomb}}
  end}
  W.run(1)
  T.ok(not F.has(F.runs(W), 'burial -c'))
  local W2 = world{setup = function(W)
    local c2 = F.building(W, 'COFFIN', {})
    c2.relations = kmock.vec{}
  end}
  W2.run(1)
  T.ok(F.has(F.runs(W2), 'burial -c'))
  T.eq(F.bad_runs(W2), {})
end)

T.test('petitions: PETITION once per agreement', function()
  local W = world{setup = function(W) df.global.plotinfo.petitions:insert('#', 5) end}
  W.run(1)
  day(W, 2)
  local p = W.find_events('PETITION')
  T.eq(#p, 1)
  T.eq(p[1].d.id, 5)
end)

T.test('weekly top stressors persisted (thoughts of stressed citizens)', function()
  local W = world{setup = function(W)
    W.unit(1)._m.stress = 0
    W.unit(1).status.current_soul.personality.emotions = kmock.vec{{thought = 0}, {thought = 0}, {thought = 3}}
  end}
  for _ = 1, 8 do day(W) end
  local top = W.K.persist.get('m.care').stress.top
  T.eq(top, {{'SawDeadBody', 16}, {'AteNoTable', 8}}, 'eight daily samples in the first week')
end)

T.test('work is sliced: 1,000 corpses take several frames, state stays valid', function()
  local W = world{setup = function(W)
    for i = 1, 1000 do F.item(W, 'ANY_CORPSE', {unit_id = 1000 + i, _pos = {1, 1, 1}}) end
  end}
  W.run(1)
  T.eq(W.state().care, nil, 'first run not finished after one frame')
  W.run(6)
  T.ok(W.state().care, 'finished')
  T.ok(#require('dfllm.util.json').encode(W.state()) < 4096)
end)

T.done()
