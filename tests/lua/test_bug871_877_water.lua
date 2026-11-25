-- Neuausrichtung 10 (wasser), Run 17 i1 Diedplank / i4 Girderroots: NO CITIZEN HAS TO LEAVE THE FORT TO DRINK.
-- BUG-871 the pond of a cistern room is never taken by the stall ladder; BUG-873 no accepted source inside = a PROJECT_REQUEST cistern
-- why=inside_water + state water.inw / wout; BUG-874 a source inside a Z4 box is inside (no burrow of its own); BUG-875 the kernel's own
-- Water Source zone outside goes once water stands inside; BUG-876 seal.job_stray runs with no group holding drink;
-- BUG-877 a vanished citizen's death record carries position, thirst and hazard.
local T = require('testlib')
local F = require('wp8_world')
local C = require('dfllm.util.contract')

F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'

local function owners()
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'pond_remove', 'water_zone_remove'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn] or {}) do if o ~= 'water' then keep[#keep + 1] = o end end
    keep[#keep + 1] = 'water'
    C.ACT[fn] = keep
  end
end

local TYPES = {GiveWater = 78, FillPond = 79}
local function jobs(list)
  for name, v in pairs(TYPES) do df.job_type[name], df.job_type[v] = v, name end
  local head
  for i = #list, 1, -1 do
    head = {item = {job_type = TYPES[list[i].type or 'GiveWater'], id = list[i].id, _worker = list[i].worker}, next = head}
  end
  df.global.world.jobs = {list = {next = head}}
  dfhack.job = dfhack.job or {}
  dfhack.job.getWorker = function(j) return j._worker end
end

-- opts: rooms (manifest rooms), kern {x0,y0,z0,x1,y1,z1} (Kern+ burrow and Z4 box), tiles {['x,y,z'] = '~'}, outside (census outside),
--       jobs, thirst {[id] = n}, setup(W), pending
local function world(opts)
  opts = opts or {}
  owners()
  local units = {}
  for i = 1, 6 do units[i] = {id = i, citizen = true, pos = {50, 50, 10}} end
  local kb = opts.kern or {0, 0, 0, 99, 99, 20}
  local persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}, zones = {Z4 = {kb}}, rooms = opts.rooms or {}}}
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, persist = persist}
  df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
  df.civzone_type.Pond, df.civzone_type[11] = 11, 'Pond'
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  local ids = {}
  for i = 1, 6 do
    ids[i] = i
    local u = W.unit(i)
    u.counters2 = {thirst_timer = (opts.thirst or {})[i] or 1000, hunger_timer = 1000}
    u.job = {current_job = nil}
  end
  W.set_census('u', F.census_u(ids, {outside = opts.outside or 0}))
  W.burrow('Kern+', kb)
  W.load({name = 'snapshot', every = {ticks = 100},
          far = function(K, x, y, z) return opts.far ~= nil and opts.far(x, y, z) == true end,   -- the citizens' main walk group (BUG-875)
          tile = function(K, x, y, z)
            local c = (opts.tiles or {})[x .. ',' .. y .. ',' .. z] or '#'
            return {c = c, dig = '', bld = '', flow = c == '~' and 7 or 0}
          end})
  W.pending = opts.pending or {}
  W.load({name = 'runner', every = {ticks = 600}, pending = function(K, tpl) return W.pending[tpl] or 0 end,
          kept_in = function() return nil end, bp_params = function() return {} end})
  if opts.hospital ~= false then F.hospital(W, {10, 10, 14, 14, 5}) end
  jobs(opts.jobs or {})
  W.removed = {}
  W.act_result('pond_remove', function(id) W.removed[#W.removed + 1] = id; return true, 1 end)
  W.act_result('water_zone_remove', function(id)
    W.removed[#W.removed + 1] = 'z' .. id
    for _, b in ipairs(df.global.world.buildings.other.ZONE_WATER_SOURCE) do if b.id == id then b.spec_sub_flag.active = false end end
    return true, 1
  end)
  if opts.setup then opts.setup(W) end
  package.loaded['dfllm.water'] = nil
  local M = require('dfllm.water')
  W.load(M)
  return W, M
end

local function day(W, n) for _ = 1, n or 1 do W.ms = W.ms + 600000; W.run(1200, {skip = 100}) end end
local function zone(W, id, x, y, z, name)
  return F.building(W, 'ZONE_WATER_SOURCE', {id = id, type = df.civzone_type.WaterSource, x1 = x, y1 = y, x2 = x, y2 = y, z = z,
                                              name = name or 'dfllm-water', spec_sub_flag = {active = true}})
end
local function requests(W, why)
  local out = {}
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.why == why then out[#out + 1] = e end end
  return out
end

---------------------------------------------------------------- BUG-871
T.test('BUG-871 (i1: three pond-fed cisterns lost their pond to the stall ladder): the pond zone beside the well of a cistern room ' ..
       'stays when its FillPond worker stalls; a pond beside no cistern still goes', function()
  local room = {tpl = 'cistern', id = 'c1', bbox = {49, 49, 10, 53, 53, 10}}
  local W = world{rooms = {room}, jobs = {{id = 601, type = 'FillPond', worker = 3}}, thirst = {[3] = 53360}, setup = function(W)
    F.building(W, 'WELL', {x1 = 50, y1 = 50, x2 = 50, y2 = 50, z = 10})
    F.building(W, 'ANY_ZONE', {id = 77, type = df.civzone_type.Pond, x1 = 51, y1 = 50, x2 = 52, y2 = 51, z = 10})
  end}
  day(W, 5)
  T.eq(W.removed, {}, 'old code: {77} (the cistern lost its only fill)')
  local W2 = world{jobs = {{id = 601, type = 'FillPond', worker = 3}}, thirst = {[3] = 53360}, setup = function(W)
    F.building(W, 'WELL', {x1 = 50, y1 = 50, x2 = 50, y2 = 50, z = 10})
    F.building(W, 'ANY_ZONE', {id = 77, type = df.civzone_type.Pond, x1 = 51, y1 = 50, x2 = 52, y2 = 51, z = 10})
  end}
  day(W2, 5)
  T.eq(W2.removed[1], 77, 'a pond beside a well of no cistern room: as before')
end)

---------------------------------------------------------------- BUG-873 / 874
T.test('BUG-873 (i1: the only accepted water outside for years): no accepted source inside asks PROJECT_REQUEST cistern why=inside_water, ' ..
       'state water.inw 0 and the citizens outside; once per inside_every; nothing while a cistern project is pending', function()
  local W = world{kern = {0, 0, 0, 60, 60, 20}, outside = 4, tiles = {['80,80,10'] = '~'}, setup = function(W)
    zone(W, 90, 80, 80, 10)
  end}
  day(W, 2)
  local w = W.state().water
  T.eq({w.inw, w.wout, #w.src}, {0, 4, 1}, 'the zone is accepted, but outside: old code had no inw')
  local rq = requests(W, 'inside_water')
  T.eq(#rq, 1, 'one request')
  T.eq(rq[1].d.tpl, 'cistern')
  day(W, 3)
  T.eq(#requests(W, 'inside_water'), 1, 'not again within inside_every (7 days)')
  day(W, 6)
  T.eq(#requests(W, 'inside_water'), 2, 'again after a week')
  local W2 = world{kern = {0, 0, 0, 60, 60, 20}, outside = 4, tiles = {['80,80,10'] = '~'}, pending = {cistern = 1}, setup = function(W)
    zone(W, 90, 80, 80, 10)
  end}
  day(W2, 3)
  T.eq(#requests(W2, 'inside_water'), 0, 'a cistern project is pending: no second ask')
end)

T.test('BUG-874 (i1: zone 18189 inside the Tiefe+ box was labelled outside): a source inside a manifest Z4 box is inside without a ' ..
       'burrow of its own; no inside_water ask then', function()
  local W = world{kern = {0, 0, 0, 99, 99, 20}, tiles = {['70,70,10'] = '~'}, setup = function(W)
    zone(W, 91, 70, 70, 10)
  end}
  W.K.manifest().zones.Z4 = {{60, 60, 0, 80, 80, 20}}
  W.burrow('Kern+', {0, 0, 0, 10, 10, 20})              -- the zone lies on no burrow
  day(W, 2)
  local w = W.state().water
  T.eq(w.inw, 1, 'old code: the burrow test alone called it outside')
  T.eq(#requests(W, 'inside_water'), 0)
  T.ok(w.src_l[1] and w.src_l[1]:find('in fort', 1, true), tostring(w.src_l[1]))
end)

---------------------------------------------------------------- BUG-874 on the live i1 manifest
T.test('BUG-874 (verifier round 2): zone 18189 at 63,104,141 lies in NO Z4 box of the live i1 manifest (z137-142 boxes, none holds ' ..
       '63,104,141): it stays outside, inw is 0 and the inside_water ask goes out', function()
  local W = world{kern = {0, 0, 0, 10, 10, 20}, outside = 5, tiles = {['63,104,141'] = '~'}, setup = function(W)
    zone(W, 18189, 63, 104, 141)
  end}
  W.K.manifest().zones.Z4 = {{56, 103, 142, 60, 105, 142}, {58, 104, 137, 58, 104, 141}, {45, 93, 139, 77, 107, 139},
                             {61, 103, 142, 64, 105, 142}, {63, 112, 142, 67, 116, 142}, {67, 103, 142, 74, 111, 142}}
  T.ok(not require('dfllm.water').in_fort_box(W.K, 63, 104, 141), 'the box test says outside')
  day(W, 2)
  local w = W.state().water
  T.eq({w.inw, w.wout}, {0, 5}, 'no inside source on i1: the ask below goes out')
  T.eq(#requests(W, 'inside_water'), 1)
end)

---------------------------------------------------------------- BUG-875
T.test('BUG-875 (i1: Drink jobs went to the river zone, 7 drowned): only after a strong inside source stood retire_days (28) in a ' ..
       'row the kernel-painted Water Source zone outside goes (WATER_OUTSIDE_RETIRED); the players own zone, a fort without an ' ..
       'inside source and one whose inside source the citizens cannot reach keep theirs', function()
  local W = world{kern = {0, 0, 0, 60, 60, 20}, tiles = {['80,80,10'] = '~', ['30,30,10'] = '~'}, setup = function(W)
    zone(W, 90, 80, 80, 10)
    zone(W, 92, 30, 30, 10, 'dfllm-water')
  end}
  day(W, 20)
  T.eq(W.removed, {}, 'three days were the old rule; 20 days of an inside source are not enough')
  day(W, 12)
  T.eq(W.removed, {'z90'}, 'after 28+ days the outside zone of the kernel went, the inside one stays')
  T.eq(#W.find_events('WATER_OUTSIDE_RETIRED'), 1)
  local W2 = world{kern = {0, 0, 0, 60, 60, 20}, tiles = {['80,80,10'] = '~', ['30,30,10'] = '~'}, setup = function(W)
    zone(W, 90, 80, 80, 10, 'River')
    zone(W, 92, 30, 30, 10, 'dfllm-water')
  end}
  day(W2, 34)
  T.eq(W2.removed, {}, "a zone of the player's own name is never removed")
  local W3 = world{kern = {0, 0, 0, 60, 60, 20}, tiles = {['80,80,10'] = '~'}, setup = function(W) zone(W, 90, 80, 80, 10) end}
  day(W3, 34)
  T.eq(W3.removed, {}, 'no source inside: the outside zone stays (the last water of the fort)')
  local W4 = world{kern = {0, 0, 0, 60, 60, 20}, tiles = {['80,80,10'] = '~', ['30,30,10'] = '~'},
                   far = function(x, y, z) return x == 30 end, setup = function(W)
    zone(W, 90, 80, 80, 10)
    zone(W, 92, 30, 30, 10, 'dfllm-water')
  end}
  day(W4, 34)
  T.eq(W4.removed, {}, 'the inside source is off the citizens main walk group: the outside zone stays')
end)

T.test('BUG-875 (verifier round 2, both directions): an inside source that dries before retire_days restarts the clock; once the zone ' ..
       'was retired and the inside water goes dry or out of reach, it is painted again', function()
  local tiles = {['80,80,10'] = '~', ['30,30,10'] = '~'}
  local reach = true
  local W = world{kern = {0, 0, 0, 60, 60, 20}, tiles = tiles, far = function() return not reach end, setup = function(W)
    zone(W, 90, 80, 80, 10)
    zone(W, 92, 30, 30, 10, 'dfllm-water')
  end}
  W.painted = {}
  W.act_result('water_zone', function(pos, up) W.painted[#W.painted + 1] = pos; return true, 1 end)
  day(W, 20)
  tiles['30,30,10'] = nil                                -- the inside source runs dry for a few days (a shallow spell)
  day(W, 3)
  tiles['30,30,10'] = '~'
  day(W, 20)
  T.eq(W.removed, {}, '43 days since the start, but only 20 in a row since the dry spell: nothing removed')
  day(W, 12)
  T.eq(W.removed, {'z90'}, 'now 32 days in a row: retired')
  T.eq(W.painted, {}, 'while the inside water stands, nothing is painted')
  reach = false                                          -- the citizens can no longer reach the inside source
  day(W, 1)
  T.eq(W.painted, {}, 'one day: not yet (restore_days 2)')
  day(W, 3)
  T.eq(#W.painted, 1, 'unreachable for 2+ days: the outside zone is painted again')
  T.eq({W.painted[1][1], W.painted[1][2], W.painted[1][3]}, {80, 80, 10}, 'on the same tile')
  T.eq(#W.find_events('WATER_OUTSIDE_RESTORED'), 1)
  day(W, 3)
  T.eq(#W.painted, 1, 'once')
end)

---------------------------------------------------------------- BUG-877
T.test('BUG-877: a citizen missing from the unit list gets position, thirst, hunger and the water at the position into the death ' ..
       'record (the cause stays open)', function()
  local DT = require('dfllm.deaths')
  local u = {id = 5, pos = {x = 118, y = 82, z = 143}, counters2 = {thirst_timer = 26000, hunger_timer = 3000}, job = {current_job = nil}}
  local prev = DT.incident
  DT.incident = function() return {found = false} end
  local ok, r = pcall(DT.classify, u, {})
  DT.incident = prev
  T.ok(ok, tostring(r))
  T.eq({r.found, r.cause}, {false, 'unknown'})
  T.eq(r.pos, {118, 82, 143}, 'old code: no position')
  T.eq(r.thirst, 26000)
  T.ok(table.concat(r.why, ';'):find('thirst 26000', 1, true))
end)

T.done()
