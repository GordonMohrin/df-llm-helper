-- NEU1 P9 Pflege (docs/v2/NEU1-pflege.md, decision E8): the hospital minimum (a 1x1 hospital zone over one free bed near accepted
-- water, the standing preconditions in state care.hosp), the standing caregivers of water, memorial slabs before the ghost
-- (mem_early), and the room of a failing strange mood locked instead of rescued (mood_contain). Coffins: test_care_coffins.lua.
local T = require('testlib')
local CW = require('care_world')
local F = CW.F

local DAY = 1200

-- a fake water module: near 30, accepted water at x = 40 (Chebyshev on x), buckets and carers as given
local function water_mod(W, o)
  o = o or {}
  W.load({name = 'water', every = {ticks = 1200},
          conf = function() return {near = 30} end,
          kpi = function() if o.kpi == false then return nil end
            return o.kpi or {buckets_free = 2, carers = 3, patients = 0} end,
          -- BUG-823: water's own verdict (served, the lockdown included) and its hold after a removal
          would_serve = function(_, x, y, z)
            if o.dry then return {ok = false, d = -1, near = 30} end
            local d = math.abs(x - 40)
            return {ok = d <= 30, d = d, near = 30}
          end,
          hosp_hold = function() return o.hold end})
end

local function hosp_world(o)
  o = o or {}
  return CW.world{cit = 4, setup = function(W)
    df.civzone_type.Bedroom, df.civzone_type[20] = 20, 'Bedroom'
    W.act_result('hospital_zone', function(spec)
      local zn = F.hospital(W, {spec.x, spec.y, spec.x, spec.y, spec.z})
      local k = spec.x .. ',' .. spec.y .. ',' .. spec.z
      W.civzones_at[k] = W.civzones_at[k] or {}
      table.insert(W.civzones_at[k], zn)
      return true, {ids = {zn.id}}
    end)
    if o.water ~= false then water_mod(W, o) end
    for _, b in ipairs(o.beds or {}) do
      local bed = F.building(W, 'BED', {x1 = b[1], y1 = b[2], x2 = b[1], y2 = b[2], z = b[3]})
      if b.owner then
        W.civzones_at[b[1] .. ',' .. b[2] .. ',' .. b[3]] = {{id = 900 + bed.id, type = 20, assigned_unit_id = b.owner}}
      end
    end
    if o.setup then o.setup(W) end
  end}
end

local function acts(W, fn)
  local r = {}
  for _, a in ipairs(W.find_acts(fn)) do r[#r + 1] = a.args end
  return r
end

T.test('hosp_min: no hospital zone, a free bed 15 tiles from accepted water: a 1x1 hospital zone over it, once; care.hosp ok', function()
  local W, Cm = hosp_world{beds = {{55, 10, 5}, {25, 10, 5}}}            -- 15 tiles each: the lower id wins the tie
  CW.day(W, 1)
  local a = acts(W, 'hospital_zone')
  T.eq(#a, 1)
  T.eq({a[1][1].x, a[1][1].y, a[1][1].z}, {55, 10, 5})
  local ev = W.find_events('HOSPITAL_MIN')
  T.eq(ev[1].d.op, 'zone')
  T.eq({ev[1].d.d, ev[1].d.ok, ev[1].d.pos}, {15, 1, {55, 10, 5}})
  local s = Cm.state(W.K).care.hosp
  T.eq({s.ok, s.gaps}, {1, nil})
  T.ok(s.zone and s.bed, 'zone and bed named')
  CW.day(W, 2)
  T.eq(#acts(W, 'hospital_zone'), 1, 'a bed in a hospital zone: nothing more')
end)

T.test('hosp_min fails closed: water does not answer -> no zone, gaps no_zone + held_by_water + unknown; a bed 60 tiles out or owned is no candidate', function()
  local W, Cm = hosp_world{water = false, beds = {{55, 10, 5}}}
  CW.day(W, 1)
  T.eq(#acts(W, 'hospital_zone'), 0)
  T.eq(Cm.state(W.K).care.hosp.gaps, {'no_zone', 'held_by_water', 'unknown'}, 'BUG-823: no answer from water is a hold')
  local W2, Cm2 = hosp_world{beds = {{100, 10, 5}, {45, 10, 5, owner = 3}}}
  CW.day(W2, 1)
  T.eq(#acts(W2, 'hospital_zone'), 0)
  local ev = W2.find_events('HOSPITAL_MIN')
  T.eq(ev[1].d.op, 'gaps')
  T.ok(ev[1].msg:find('no free bed within 30 tiles of accepted water', 1, true), ev[1].msg)
  T.eq(Cm2.state(W2.K).care.hosp.gaps, {'no_zone'})
  local W3, Cm3 = hosp_world{dry = true, beds = {{45, 10, 5}}}
  CW.day(W3, 1)
  T.eq(#acts(W3, 'hospital_zone'), 0, 'no accepted water in the fort')
  T.ok(W3.find_events('HOSPITAL_MIN')[1].msg:find('no accepted water', 1, true))
end)

T.test('hosp_min: no bucket, no caregiver are named gaps of a standing zone; the switch off: nothing', function()
  local W, Cm = hosp_world{beds = {{45, 10, 5}}, kpi = {buckets_free = 0, carers = 0, patients = 1}}
  CW.day(W, 1)
  T.eq(#acts(W, 'hospital_zone'), 1)
  T.eq(Cm.state(W.K).care.hosp.gaps, {'no_bucket', 'no_carer'})
  local W2, Cm2 = hosp_world{beds = {{45, 10, 5}}}
  W2.K.cfg.baseline.care = {hosp_min = false}
  CW.day(W2, 1)
  T.eq(#acts(W2, 'hospital_zone'), 0)
  T.eq(Cm2.state(W2.K).care.hosp, nil)
end)

T.test('water.carers_standing: carers_min caregivers wanted while a hospital zone stands, no patient needed; off: 0', function()
  local W = F.world{units = {{id = 11, citizen = true, pos = {1, 1, 1}}, {id = 12, citizen = true, pos = {1, 1, 1}}}}
  local Wm = CW.fresh('water')
  W.load(Wm)
  local c = Wm.conf(W.K)
  local r = {patients = {}, carers = {}, carers_idle = 0, pool = {}, hosp = {{id = 1, x1 = 1, y1 = 1, x2 = 1, y2 = 1, z = 1}}}
  T.eq(Wm.carers(W.K, c, r, {}, 0, false, false).want, c.carers_min)
  r.hosp = {}
  T.eq(Wm.carers(W.K, c, r, {}, 0, false, false).want, 0, 'no hospital, no patient: none')
  r.hosp = {{id = 1, x1 = 1, y1 = 1, x2 = 1, y2 = 1, z = 1}}
  c.carers_standing = false
  T.eq(Wm.carers(W.K, c, r, {}, 0, false, false).want, 0, 'switch off: the old rule')
  c.carers_standing = true
  W.act_result('work_detail', function() return true, 'removed' end)
  local p = {cw = {['11'] = 0, ['12'] = 0}, cw_t = 0}
  r.carers = {{id = 1}, {id = 11}, {id = 12}}
  local out = Wm.carers(W.K, c, r, p, c.carers_hold_days * DAY, false, false)
  T.eq({out.want, out.dropped}, {c.carers_min, {11}}, 'standing: more than carers_min after the hold: one leaves')
  r.carers = {{id = 1}, {id = 12}}
  T.eq(Wm.carers(W.K, c, r, p, c.carers_hold_days * DAY + DAY, false, false).dropped, {}, 'carers_min stay')
end)

-- memorial slabs before the ghost
local function dead(W, id, hf)
  W.unit(id).hist_figure_id = hf
  W.kill(id)
  W.event('UNIT_DEATH', {unit = id})
end

T.test('mem_early: a dead citizen with no body gets a memorial slab after mem_wait_days (before the ghost); not before; off: never', function()
  local units = {{id = 6200, citizen = true, pos = {5, 5, 5}}, {id = 6201, citizen = true, pos = {5, 5, 5}}}
  local W, Cm = CW.world{cit = 4, units = units, setup = function(W) dead(W, 6200, 800); dead(W, 6201, -1) end}
  CW.day(W, 3)
  T.eq(Cm.unreach_ids(W.K), {}, 'three days: not yet')
  CW.day(W, 6)
  T.eq(Cm.unreach_ids(W.K), {6200}, 'no body after 7 days: a slab (6201 has no figure)')
  local W2, Cm2 = CW.world{cit = 4, units = {{id = 6200, citizen = true, pos = {5, 5, 5}}}, setup = function(W) dead(W, 6200, 800) end}
  W2.K.cfg.baseline.care = {mem_early = false}
  CW.day(W2, 9)
  T.eq(Cm2.unreach_ids(W2.K), {})
end)

T.test('mem_early: a body that lies mem_wait_days without a coffin gets its slab too', function()
  local units = {{id = 6300, citizen = true, pos = {5, 5, 5}}}
  local W, Cm = CW.world{cit = 4, units = units, setup = function(W)
    dead(W, 6300, 801)
    F.item(W, 'ANY_CORPSE', {unit_id = 6300, _pos = {8, 8, 5}})
  end}
  CW.day(W, 3)
  T.eq(Cm.unreach_ids(W.K), {})
  CW.day(W, 7)
  T.eq(Cm.unreach_ids(W.K), {6300})
end)

-- the room of a failing mood: x 2..8, y 2..8 on z 5, walls round it, a door at 9,5; over(x, y) replaces a tile
local function room_tiles(over)
  return function(x, y, z)
    if over then
      local t = over(x, y)
      if t then return t end
    end
    if x == 9 and y == 5 then return {c = '+', dig = '', bld = 'Door'} end
    if x >= 2 and x <= 8 and y >= 2 and y <= 8 then return {c = '.', dig = '', bld = ''} end
    return {c = '#', dig = '', bld = ''}
  end
end

local function filter(t)
  return {item_type = df.item_type[t], mat_type = 0, mat_index = -1, quantity = 1, flags2 = {non_economic = true}}
end

local function mood_world(o)
  o = o or {}
  return CW.world{cit = 4, tile = room_tiles(o.over), setup = function(W)
    local u = W.unit(1)
    u.mood = df.mood_type.Fell
    u.counters2 = {thirst_timer = 1000, hunger_timer = 500}
    u.job.mood_timeout = (o.days or 2) * DAY
    local shop = F.workshop(W, 'Craftsdwarfs')
    shop.x1, shop.y1, shop.x2, shop.y2, shop.z = 4, 4, 6, 6, 5
    u.job.current_job = CW.mood_job(W, 901, shop, {filter('BOULDER')})
    for id = 2, 4 do W.move(id, 30, 30, 5) end
    if o.inside then W.move(2, 3, 3, 5) end
    local door = F.building(W, 'DOOR', {id = 777, x1 = 9, y1 = 5, z = 5})
    local door2 = o.door2 and F.building(W, 'DOOR', {id = 778, x1 = 1, y1 = 5, z = 5}) or nil
    W.door = door
    dfhack.buildings.findAtTile = function(x, y, z)
      if x == 9 and y == 5 and z == 5 then return door end
      if door2 and x == 1 and y == 5 and z == 5 then return door2 end
    end
    W.act_result('door_forbid', function(id, on, close) return true, false end)
  end}
end

local function contain(W)
  local r = {}
  for _, e in ipairs(W.find_events('MOOD_CONTAIN')) do r[#r + 1] = e.d.op end
  return r
end

T.test('mood_contain: material missing, 2 days to insanity, a closed room: its door is locked; the dwarf dead: unlocked again', function()
  local W = mood_world()
  CW.day(W, 1)
  T.eq(contain(W), {'locked'})
  local a = acts(W, 'door_forbid')
  T.eq(a[1], {777, true, true, n = 3})
  T.eq(W.find_events('MOOD_CONTAIN')[1].d.doors, {777})
  CW.day(W, 1)
  T.eq(#acts(W, 'door_forbid'), 1, 'once')
  W.kill(1)
  CW.day(W, 1)
  T.eq(contain(W), {'locked', 'released'})
  T.eq(acts(W, 'door_forbid')[2], {777, false, n = 2})
end)

T.test('mood_contain: 10 days left: not yet; a citizen inside: busy, no lock; a stair in the room: open, no lock', function()
  local W = mood_world{days = 10}
  CW.day(W, 1)
  T.eq(contain(W), {})
  local W2 = mood_world{inside = true}
  CW.day(W2, 1)
  T.eq(contain(W2), {'busy'})
  T.eq(#acts(W2, 'door_forbid'), 0)
  T.ok(W2.find_events('MOOD_CONTAIN')[1].d.why:find('citizen 2 is inside', 1, true))
  local W3 = mood_world{over = function(x, y) if x == 7 and y == 7 then return {c = '>', dig = '', bld = ''} end end}
  CW.day(W3, 1)
  T.eq(contain(W3), {'open'})
  T.ok(W3.find_events('MOOD_CONTAIN')[1].d.why:find('stair at 7,7,5', 1, true))
  T.eq(#acts(W3, 'door_forbid'), 0)
end)

-- BUG-824: a second door at 1,5; ring = the outer ring x/y 0 or 10 is floor (the ways beyond both doors join), else only the tile
-- beyond each door is floor (a corridor piece: locking would split the fort)
local function two_doors(ring)
  return function(x, y)
    if x == 1 and y == 5 then return {c = '+', dig = '', bld = 'Door'} end
    if ring and x >= 0 and x <= 10 and y >= 0 and y <= 10 and (x == 0 or x == 10 or y == 0 or y == 10) then
      return {c = '.', dig = '', bld = ''}
    end
    if not ring and y == 5 and (x == 0 or x == 10) then return {c = '.', dig = '', bld = ''} end
  end
end

T.test('BUG-824: two doors whose outsides join only through the room: not locked (op open, split); joined round it: locked', function()
  local W = mood_world{door2 = true, over = two_doors(false)}
  CW.day(W, 1)
  T.eq(contain(W), {'open'})
  T.ok(W.find_events('MOOD_CONTAIN')[1].d.why:find('split', 1, true), W.find_events('MOOD_CONTAIN')[1].d.why)
  T.eq(#acts(W, 'door_forbid'), 0)
  local W2 = mood_world{door2 = true, over = two_doors(true)}
  CW.day(W2, 1)
  T.eq(contain(W2), {'locked'})
  local ds = W2.find_events('MOOD_CONTAIN')[1].d.doors
  table.sort(ds)
  T.eq(ds, {777, 778})
end)

T.test('BUG-824: the mood ends berserk with a citizen in the room: busy, tried again later; locked once he is out', function()
  local W = mood_world{days = 10}
  CW.day(W, 1)
  T.eq(contain(W), {})
  W.unit(1).mood = df.mood_type.Berserk
  W.move(2, 3, 3, 5)
  CW.day(W, 1)
  T.eq(contain(W), {'busy'})
  W.move(2, 30, 30, 5)
  CW.day(W, 1)
  T.eq(contain(W)[#contain(W)], 'locked', 'tried again while he stays berserk')
end)

T.test('BUG-824: contained: a door someone else unforbade is locked again; mood_deadline no longer asks for deliveries', function()
  local W = mood_world()
  CW.day(W, 1)
  T.eq(contain(W), {'locked'})
  W.door.door_flags = {forbidden = false}
  CW.day(W, 1)
  local a = acts(W, 'door_forbid')
  T.eq(a[#a], {777, true, true, n = 3}, 'held')
  local dl
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'mood_deadline' then dl = e end end
  T.ok(dl and dl.d.q:find('locked', 1, true) and not dl.d.q:find('send these', 1, true), dl and dl.d.q)
  T.eq(dl.d.cmds, nil)
end)

T.done()
