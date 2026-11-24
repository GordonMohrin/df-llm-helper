-- NEU1 P9 verification (BUG-823): care's hospital minimum against the REAL water module. Water removes a hospital zone when a patient
-- is near death from thirst (remove_dry BUG-034, stall_hospital BUG-541; remembered in p.hrm, drawn again only by hospital.restore),
-- and in a lockdown a source outside Kern+ is no hospital water (BUG-708, water.served's outer filter). care must neither redraw a
-- zone water just removed nor draw one water would judge dry: water.hosp_hold / water.would_serve, fail closed (gap held_by_water).
-- The world is test_bug708_siege_thirst's: Kern+ y 25..60, the hospital 10..14 x 30..34 z 5, a dry well inside, the only wet water
-- a Water Source zone at 30,12 outside Kern+ (18-21 tiles from the hospital beds, inside water's near 30).
local T = require('testlib')
local C = require('dfllm.util.contract')
local F = require('wp8_world')
F.BUILDINGS_OTHER[#F.BUILDINGS_OTHER + 1] = 'ZONE_WATER_SOURCE'
local FEED = 40
local DAY = 1200

local function owners()
  for _, fn in ipairs({'item_flag', 'workorder', 'hospital_remove', 'hospital_restore', 'work_detail', 'burrow_tiles'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn] or {}) do if o ~= 'water' then keep[#keep + 1] = o end end
    keep[#keep + 1] = 'water'
    C.ACT[fn] = keep
  end
end

-- o.mode, o.alert (civ alert sounds), o.thirst (the patient, unit 5 at 12,32,5), o.zone (false: no hospital zone at the start),
-- o.bed (a bed {x, y}: default 13,33)
local function world(o)
  o = o or {}
  owners()
  local units = {}
  for i = 1, 8 do units[i] = {id = i, citizen = true, pos = {12, 32, 5}} end
  local persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
                               zones = {Z4 = {{0, 0, 0, 99, 99, 20}}}}}
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, persist = persist}
  df.civzone_type.WaterSource, df.civzone_type[10] = 10, 'WaterSource'
  df.civzone_type.Bedroom, df.civzone_type[20] = 20, 'Bedroom'
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  df.job_type.GiveWater, df.job_type[78] = 78, 'GiveWater'
  df.unit_labor = {FEED_WATER_CIVILIANS = FEED, MINE = 41, CUTWOOD = 42, HUNT = 43}
  local ids = {}
  for i = 1, 8 do
    ids[i] = i
    local u = W.unit(i)
    u.counters2 = {thirst_timer = 1000}
    u.job = {current_job = nil}
    u.status = {labors = {[FEED] = i <= 4, [41] = false, [42] = false, [43] = false}}
  end
  for i = 1, 8 do if i ~= 5 then W.move(i, 40, 40 + i, 5) end end
  local pu = W.unit(5)
  pu.counters2.thirst_timer = o.thirst or 40000
  pu.health = {flags = {needs_healthcare = true}}
  W.set_census('u', F.census_u(ids))
  W.burrow('Kern+', {0, 25, 0, 60, 60, 20})
  W.burrow('Tiefe+', {40, 40, 2, 60, 60, 2})
  W.set_mode(o.mode or 'SIEGE')
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z)
            return {c = (y == 12 and x == 30 and z == 5) and '~' or '#', dig = '', bld = ''}
          end})
  df.global.plotinfo.alerts.civ_alert_idx = o.alert == false and 0 or 1
  W.load({name = 'siege', every = {ticks = 1000}, alert_names = function() return {'Tiefe+'} end})
  W.hosp = F.hospital(W, {10, 30, 14, 34, 5})
  if o.zone == false then W.hosp.location_id = -1 end
  F.building(W, 'WELL', {x1 = 20, y1 = 30, x2 = 20, y2 = 30, z = 5})
  F.building(W, 'ZONE_WATER_SOURCE', {id = 82, type = df.civzone_type.WaterSource, x1 = 30, y1 = 12, x2 = 30, y2 = 12, z = 5,
                                      spec_sub_flag = {active = true}})
  for i = 1, 4 do F.item(W, 'BUCKET', {_pos = {20, 31 + i, 5}}) end
  local bx = o.bed or {13, 33}
  W.bed = F.building(W, 'BED', {x1 = bx[1], y1 = bx[2], x2 = bx[1], y2 = bx[2], z = 5})
  W.removed, W.drawn = {}, {}
  -- the removal is real: the zone leaves the hospital location (care and water read hospital zones by their location)
  W.act_result('hospital_remove', function(id)
    W.removed[#W.removed + 1] = id
    if id == W.hosp.id then W.hosp.location_id = -1 end
    return true, 1
  end)
  W.act_result('hospital_zone', function(spec)
    W.drawn[#W.drawn + 1] = {spec.x, spec.y, spec.z}
    local zn = F.hospital(W, {spec.x, spec.y, spec.x, spec.y, spec.z})
    W.civzones_at[spec.x .. ',' .. spec.y .. ',' .. spec.z] = {zn}
    return true, {ids = {zn.id}}
  end)
  W.act_result('work_detail', function(name, id, on) W.unit(id).status.labors[FEED] = on; return true, 'added' end)
  df.global.world.jobs = {list = {next = {item = {job_type = 78, id = 501}}}}
  dfhack.job = dfhack.job or {}
  dfhack.job.getWorker = function(j) return nil end
  package.loaded['dfllm.water'] = nil
  local Wm = require('dfllm.water')
  W.load(Wm)
  package.loaded['dfllm.care'] = nil
  local Cm = require('dfllm.care')
  W.load(Cm)
  return W, Wm, Cm
end

local function day(W, n) for _ = 1, (n or 1) * 12 do W.run(100, {skip = 100}) end end

local function last_gaps(W)
  local ev = W.find_events('HOSPITAL_MIN')
  return ev[#ev] and ev[#ev].d.gaps or nil
end

local function has(list, x)
  for _, v in ipairs(list or {}) do if v == x then return true end end
  return false
end

T.test('BUG-823 (a): water removes the dry hospital zone for the thirsty patient (p.hrm); care does not redraw it within hrm_expire ' ..
       'although a free bed stands 21 tiles from the zone water (held_by_water)', function()
  local W, Wm = world{}
  day(W)
  T.eq(W.removed, {W.hosp.id}, 'water removed the zone (BUG-708: the water outside is no hospital water in the siege)')
  T.ok(Wm.hosp_hold(W.K), 'water holds the hospital back')
  day(W, 5)
  T.eq(W.drawn, {}, 'no hospital zone drawn while water holds it back')
  T.ok(has(last_gaps(W), 'held_by_water'), 'gap held_by_water named')
end)

T.test('BUG-823 (a2): the patient drinks (thirst under patient_thirst) but the removal is younger than hrm_expire: still held; ' ..
       'after hrm_expire in PEACE: drawn', function()
  local W, Wm = world{}
  day(W)
  T.eq(W.removed, {W.hosp.id})
  W.unit(5).counters2.thirst_timer = 1000
  W.set_mode('PEACE')
  df.global.plotinfo.alerts.civ_alert_idx = 0
  day(W, 3)
  T.eq(W.drawn, {}, 'a fresh removal holds')
  local c = Wm.conf(W.K)
  day(W, c.hrm_expire // DAY + 1)
  T.eq(Wm.hosp_hold(W.K), nil, 'the memory expired')
  T.eq(#W.drawn, 1, 'then care draws its 1x1 zone over the bed')
end)

T.test('BUG-823 (b): a lockdown whose only accepted water lies outside Kern+: no zone is drawn (water.would_serve says dry); ' ..
       'the same fort in PEACE: drawn', function()
  local W, Wm = world{zone = false, thirst = 1000}
  day(W, 2)
  T.eq(W.removed, {})
  T.eq(Wm.hosp_hold(W.K), nil, 'nothing held: no removal, no thirsty patient')
  local ws = Wm.would_serve(W.K, 13, 33, 5)
  T.eq({ws.ok, ws.d}, {false, -1}, 'the outer zone is no hospital water in the lockdown')
  T.eq(W.drawn, {})
  local W2, Wm2 = world{zone = false, thirst = 1000, mode = 'PEACE', alert = false}
  day(W2, 2)
  T.eq(Wm2.would_serve(W2.K, 13, 33, 5).ok, true)
  T.eq(W2.drawn, {{13, 33, 5}})
end)

T.test('BUG-823: a bed a unit lies in is no candidate (the patient\'s own bed)', function()
  local W = world{zone = false, thirst = 1000, mode = 'PEACE', alert = false, bed = {12, 32}}
  day(W, 2)
  T.eq(W.drawn, {}, 'unit 5 lies on the only bed')
end)

T.done()
