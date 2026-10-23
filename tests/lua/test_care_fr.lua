-- care (Run 9 FRs): tomb hygiene and repair (FR-27/41/42), entomb burial jobs (FR-45), GHOSTS with the causes
-- per body (FR-04/26), inspect what=tombs and the tombs.repair verb, doctors and hospital posts (FR-48), mood
-- survival (FR-44), and the three new act functions (tomb_zone, medic, hospital_post).
local T = require('testlib')
local CW = require('care_world')
local F = CW.F
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local actlib = require('dfllm.act')

local function corpse(W, uid, pos, extra)
  local spec = {unit_id = uid, _pos = pos or {5, 5, 5}}
  for k, v in pairs(extra or {}) do spec[k] = v end
  return F.item(W, 'ANY_CORPSE', spec)
end

-- a dead citizen (UNIT_DEATH delivered next frame); ghost = its ghost walks
local function dead(W, id, ghost)
  W.kill(id)
  if ghost then W.unit(id)._m.ghost = true end
  W.event('UNIT_DEATH', {unit = id})
end

local function world(opts)
  opts = opts or {}
  local setup = opts.setup
  opts.setup = function(W)
    df.civzone_type.Bedroom, df.civzone_type[20] = 20, 'Bedroom'
    df.job_type.PlaceItemInTomb, df.job_type[90] = 90, 'PlaceItemInTomb'
    CW.tomb_acts(W)
    if setup then setup(W) end
  end
  return CW.world(opts)
end

local function inspect(W)
  local r = W.inbox('inspect', {what = 'tombs'})
  T.ok(r.ok, r.msg)
  return r.data, r.msg
end

local function why_of(d, uid)
  for _, e in ipairs(d.unburied) do if e.u == uid then return e.why end end
end

local function entombs(W)
  local r = {}
  for _, line in ipairs(F.runs(W)) do if line:find('^entomb ') then r[#r + 1] = line end end
  return r
end

---------------------------------------------------------------- GHOSTS (FR-04/26)
T.test('GHOSTS (A) as soon as a citizen ghost exists; BUG-008: again only for news, after max(7 days, 10 min)', function()
  local W = world{cit = 6}
  dead(W, 2, true)                                            -- no body anywhere: a memorial slab is the way
  W.run(2)
  local g = W.find_events('GHOSTS')
  T.eq(#g, 1)
  T.eq(g[1].cls, 'A')
  T.eq({g[1].d.ghosts, g[1].d.old, g[1].d.units, g[1].d.causes}, {1, 0, {2}, {'2:no_body'}})
  T.ok(g[1].msg:find('slab for no_body', 1, true) and g[1].msg:find('inspect tombs', 1, true), g[1].msg)
  CW.day(W)
  T.eq(#W.find_events('GHOSTS'), 1, 'the same set: not again')
  dead(W, 3, true)
  corpse(W, 3)
  CW.day(W, 8)
  T.eq(#W.find_events('GHOSTS'), 1, 'a new ghost after 8 game days but 2 wall seconds: waits for the wall clock')
  W.ms = W.ms + 600000                                        -- 10 real minutes later (timestream speed)
  CW.day(W)
  g = W.find_events('GHOSTS')
  T.eq(#g, 2, 'the set grew and both clocks passed')
  T.eq({g[2].d.ghosts, g[2].d.corpses, g[2].d.units}, {2, 1, {2, 3}})
  T.eq(g[2].d.causes[2], '3:no_coffin')
  CW.day(W, 8)
  W.ms = W.ms + 600000
  CW.day(W)
  T.eq(#W.find_events('GHOSTS'), 2, 'an unchanged set is never repeated (Run 9: x9..x31 of the same text)')
  T.ok(#json.encode(g[2].d) < 1024)
end)

T.test('BUG-008: a new episode after the set emptied waits for the cadence of the last announcement', function()
  local W = world{cit = 6}
  dead(W, 2, true)
  W.run(2)
  T.eq(#W.find_events('GHOSTS'), 1)
  W.unit(2)._m.ghost = false                                  -- laid to rest (a slab)
  CW.day(W)
  dead(W, 4, true)
  CW.day(W)
  T.eq(#W.find_events('GHOSTS'), 1, 'within the cadence')
  CW.day(W, 7)
  W.ms = W.ms + 600000
  CW.day(W)
  local g = W.find_events('GHOSTS')
  T.eq(#g, 2)
  T.eq(g[2].d.units, {4})
end)

T.test('GHOSTS for a citizen body unburied longer than corpse_old (3 days), no ghost needed', function()
  local W = world{cit = 4}
  dead(W, 3)
  corpse(W, 3)
  CW.day(W, 2)
  T.eq(W.find_events('GHOSTS'), {}, 'two days: not yet')
  CW.day(W, 2)
  local g = W.find_events('GHOSTS')
  T.eq(#g, 1)
  T.eq({g[1].d.ghosts, g[1].d.old, g[1].d.units, g[1].d.causes}, {0, 1, {3}, {'3:no_coffin'}})
  T.ok(g[1].msg:find('1 citizen(s) unburied > 3 d', 1, true), g[1].msg)
end)

---------------------------------------------------------------- causes per body (FR-26)
T.test('causes: coffin_taken, zone_shared, bedroom, zone_owner, unflagged, in_stockpile, undiscovered, unreachable', function()
  local incidents = {}
  -- BUG-062: 'unreachable' = the body walks to the citizens but not to its coffin (36,10); a body nobody walks to is corpse_far
  local W = world{cit = 12, reach = function(a, b) return not (a.x == 9 and a.y == 9 and b.x == 36) end, mode = 'SIEGE',
                  setup = function(W)
    df.incident = {find = function(id) return incidents[id] end}
    local cofA = CW.tomb(W, 30, 10, 5, {unit = 3})              -- coffin A holds unit 11's body
    corpse(W, 11, {30, 10, 5}, {flags = {in_building = true}, _holder = cofA})
    CW.tomb(W, 31, 10, 5, {unit = 4})                           -- coffin B: two zones
    F.building(W, 'ZONE_TOMB', {x1 = 31, y1 = 10, x2 = 31, y2 = 10, z = 5, type = df.civzone_type.Tomb,
                                assigned_unit_id = 5, spec_sub_flag = {active = true},
                                zone_settings = {tomb = {flags = {no_citizens = false}}}})
    CW.tomb(W, 32, 10, 5, {unit = 6})                           -- coffin C inside a bedroom (FR-42)
    F.building(W, 'ZONE_BEDROOM', {x1 = 32, y1 = 9, x2 = 34, y2 = 11, z = 5})
    CW.tomb(W, 35, 10, 5, {unit = 7})                           -- usable, but DF does not give 7 the body
    CW.tomb(W, 36, 10, 5, {unit = 8})                           -- usable, body unreachable
    F.building(W, 'STOCKPILE', {x1 = 20, y1 = 20, x2 = 22, y2 = 22, z = 5})
    CW.tomb(W, 37, 10, 5)                                       -- a free usable tomb
    for _, id in ipairs({3, 4, 5, 6, 7, 8, 9, 11}) do W.kill(id) end
    corpse(W, 3); corpse(W, 4); corpse(W, 5); corpse(W, 6)
    local c7 = corpse(W, 7)
    W.unit(7).corpse_parts = kmock.vec{c7.id + 1000}            -- some other item: 7 does not own this body
    corpse(W, 8, {9, 9, 5}, {flags = {dead_dwarf = false}})
    corpse(W, 9, {21, 21, 5})                                   -- in a stockpile, death not discovered
    W.unit(9).counters.death_id = 77
    incidents[77] = {flags = {discovered = false}}
  end}
  for _, id in ipairs({3, 4, 5, 6, 7, 8, 9, 11}) do W.event('UNIT_DEATH', {unit = id}) end
  W.run(2)
  local d = inspect(W)
  T.eq(why_of(d, 3), 'coffin_taken')
  T.eq(why_of(d, 4), 'zone_shared')
  T.eq(why_of(d, 5), 'zone_shared')
  T.eq(why_of(d, 6), 'bedroom')
  T.eq(why_of(d, 7), 'zone_owner')
  T.eq(why_of(d, 8), 'unreachable+unflagged')
  T.eq(why_of(d, 9), 'no_zone+in_stockpile+undiscovered', 'free tombs exist: DF never gave it one')
  T.eq(why_of(d, 11), nil, 'buried')
  T.eq(CW.tacts(W), {}, 'SIEGE: no repair')
  T.eq(entombs(W), {})
  T.eq(W.bad_vectors, {})
  df.incident = nil
end)

---------------------------------------------------------------- hygiene and repair (FR-27/41/42)
T.test('one zone per coffin: stacked zones removed (the body\'s zone kept), the dropped body gets a free coffin', function()
  local W = world{cit = 6, setup = function(W)
    CW.tomb(W, 30, 10, 5)                                       -- coffin 1, zone 2: unassigned
    F.building(W, 'ZONE_TOMB', {id = 3, x1 = 30, y1 = 10, x2 = 30, y2 = 10, z = 5, type = df.civzone_type.Tomb,
                                assigned_unit_id = 4, spec_sub_flag = {active = true},
                                zone_settings = {tomb = {flags = {no_citizens = true}}}})
    F.building(W, 'ZONE_TOMB', {id = 4, x1 = 30, y1 = 10, x2 = 30, y2 = 10, z = 5, type = df.civzone_type.Tomb,
                                assigned_unit_id = 5, spec_sub_flag = {active = true},
                                zone_settings = {tomb = {flags = {no_citizens = true}}}})
    CW.tomb(W, 31, 10, 5)                                       -- coffin 5, zone 6: free
    dead(W, 4); dead(W, 5)
    corpse(W, 4); corpse(W, 5)
  end}
  W.run(2)
  T.eq(CW.tacts(W, 'remove'), {{'remove', 2}, {'remove', 4}}, 'the unassigned and unit 5\'s zone go; 4 keeps its own')
  T.eq(CW.tacts(W, 'assign'), {{'assign', 6, 5}})
  T.eq(entombs(W), {'entomb --unit 4 --haul-now', 'entomb --unit 5 --haul-now'})
  T.eq(F.bad_runs(W), {}, 'entomb through config/allowlist.json')
  local d = inspect(W)
  T.eq({d.acts.removed, d.acts.assigned, d.acts.entombed, d.repaired}, {2, 1, 2, 1})
  CW.day(W)
  T.eq(#CW.tacts(W, 'remove'), 2, 'one zone per coffin now: nothing more to do')
  T.eq(#entombs(W), 2, 'entomb waits entomb_retry before a second try')
end)

T.test('zones without a coffin are removed (not while a tombs project is pending), FR-41 stale zones are freed', function()
  local function scene(pending)
    return world{cit = 6, pending = pending, setup = function(W)
      CW.tomb(W, 40, 10, 5, {coffin = false})                   -- zone 1: no coffin, unassigned
      CW.tomb(W, 41, 10, 5, {coffin = false, unit = 2})         -- zone 2: a living citizen's
      CW.tomb(W, 42, 10, 5, {unit = 3})                         -- coffin 3, zone 4: unit 3 died without a body
      CW.tomb(W, 43, 10, 5, {unit = 6, closed = true})          -- coffin 5, zone 6: 6 is buried in coffin 7
      local cof = CW.tomb(W, 44, 10, 5, {unit = 6})
      corpse(W, 6, {44, 10, 5}, {flags = {in_building = true}, _holder = cof})
      dead(W, 3); dead(W, 6)
      dead(W, 4)
      corpse(W, 4)                                              -- unburied: takes the first freed coffin
    end}
  end
  local W = scene({tombs = 0})
  W.run(2)
  T.eq(CW.tacts(W, 'remove'), {{'remove', 1}})
  T.eq(CW.tacts(W, 'free'), {{'free', 4}, {'free', 6}}, 'the bodiless dead\'s zone and the zone of 6, buried elsewhere')
  T.eq(CW.tacts(W, 'assign'), {{'assign', 4, 4}})
  T.eq(CW.tacts(W, 'open'), {}, 'zone 6 was opened by the free')
  T.eq(W.state().care.tombs_free, 1, 'zone 6 is free and usable now')
  local W2 = scene({tombs = 1})
  W2.run(2)
  T.eq(CW.tacts(W2, 'remove'), {}, 'a tombs project is being built: its zones may wait for their coffins')
end)

T.test('FR-42: a coffin inside a Bedroom zone is no tomb: its unburied owner is freed and reassigned', function()
  local W = world{cit = 6, setup = function(W)
    CW.tomb(W, 32, 10, 5, {unit = 3})                           -- coffin 1, zone 2 in the bedroom
    F.building(W, 'ZONE_BEDROOM', {x1 = 32, y1 = 9, x2 = 34, y2 = 11, z = 5})
    CW.tomb(W, 33, 12, 5, {closed = true})                       -- coffin 4, zone 5: outside it, closed
    CW.tomb(W, 36, 12, 5, {closed = true})                       -- coffin 6, zone 7: spare, closed
    dead(W, 3)
    corpse(W, 3)
  end}
  W.run(2)
  T.eq(CW.tacts(W), {{'free', 2}, {'assign', 5, 3}, {'open', 7}})
  local d = inspect(W)
  T.eq(d.list[1].bed, 1)
  T.eq(why_of(d, 3), 'bedroom', 'the cause before the repair')
  T.eq(d.free, 1, 'the bedroom coffin is not counted')
end)

T.test('repair modes: none in SIEGE or with tomb_repair off; tombs.repair forces it and restarts entomb', function()
  local function scene(o)
    o.cit = 6
    o.setup = function(W)
      CW.tomb(W, 30, 10, 5, {coffin = false})
      CW.tomb(W, 31, 10, 5)
      dead(W, 3)
      corpse(W, 3)
    end
    return world(o)
  end
  local W = scene{mode = 'SIEGE'}
  CW.day(W)
  T.eq(CW.tacts(W), {})
  local r = W.inbox('tombs.repair', {})
  T.ok(r.ok and r.msg:find('queued', 1, true), r.msg)
  CW.day(W)
  T.eq(CW.tacts(W), {{'remove', 1}, {'assign', 3, 3}}, 'forced in SIEGE')
  T.eq(entombs(W), {'entomb --unit 3 --haul-now'}, 'the body lies inside Kern+')
  CW.day(W)
  T.eq(#CW.tacts(W), 2, 'the force is spent after one run')
  local W2 = scene{reserve = {}}
  W2.K.cfg.baseline.care = {tomb_repair = false}
  CW.day(W2, 2)
  T.eq(CW.tacts(W2), {})
  W2.inbox('tombs.repair', {})
  CW.day(W2)
  T.eq(#CW.tacts(W2), 2)
end)

---------------------------------------------------------------- burial jobs (FR-45)
T.test('entomb: once per body with a usable zone and no job, inside Kern+; retried every 2 days, 3 tries; no_job', function()
  local W = world{cit = 6, setup = function(W)
    CW.tomb(W, 30, 10, 5, {unit = 3})
    CW.tomb(W, 31, 10, 5, {unit = 4})
    CW.tomb(W, 32, 10, 5, {unit = 5})
    dead(W, 3); dead(W, 4); dead(W, 5)
    corpse(W, 3)
    corpse(W, 4, {5, 5, 5}, {flags = {in_job = true}})          -- already hauled
    corpse(W, 5, {80, 80, 5})                                   -- outside Kern+, PEACE: clean-up time
    W.hidden['5,6,5'] = true
  end}
  W.run(2)
  T.eq(entombs(W), {'entomb --unit 3 --haul-now', 'entomb --unit 5 --haul-now'})
  local link = {item = {job_type = df.job_type.PlaceItemInTomb}, next = {item = {job_type = 1}, next = nil}}
  df.global.world.jobs = {list = {next = link}}
  CW.day(W, 2)
  T.eq(#entombs(W), 4, 'no job after entomb_retry: a second try each')
  local d = inspect(W)
  T.eq(d.jobs, 1, 'PlaceItemInTomb jobs counted')
  T.eq(why_of(d, 3), 'no_job')
  T.eq(why_of(d, 4), '', 'being hauled')
  CW.day(W, 6)
  T.eq(#entombs(W), 6, 'three tries, then it waits for tombs.repair')
  W.inbox('tombs.repair', {})
  CW.day(W)
  T.eq(#entombs(W), 8)
  df.global.world.jobs = nil
end)

T.test('entomb in SIEGE only for bodies inside Kern+ and on revealed tiles', function()
  local W = world{cit = 6, mode = 'SIEGE', setup = function(W)
    CW.tomb(W, 30, 10, 5, {unit = 3}); CW.tomb(W, 31, 10, 5, {unit = 4}); CW.tomb(W, 32, 10, 5, {unit = 5})
    dead(W, 3); dead(W, 4); dead(W, 5)
    corpse(W, 3, {5, 5, 5}); corpse(W, 4, {80, 80, 5}); corpse(W, 5, {6, 6, 5})
    W.hidden['6,6,5'] = true
  end}
  W.inbox('tombs.repair', {})
  W.run(2)
  T.eq(entombs(W), {'entomb --unit 3 --haul-now'})
end)

---------------------------------------------------------------- inspect what=tombs
T.test('inspect what=tombs: before the first run, then the lists; <= 8 KB with 200 coffins', function()
  local W = world{cit = 4, setup = function(W)
    for i = 1, 200 do CW.tomb(W, 10 + i % 40, 10 + i // 40, 5) end
    CW.tomb(W, 90, 90, 5, {coffin = false, unit = 2})
  end}
  local r = W.inbox('inspect', {what = 'tombs'})
  T.ok(r.ok and r.msg:find('no care run', 1, true), r.msg)
  W.run(2)
  local d, msg = inspect(W)
  T.ok(msg:find('200 coffins, 200 free', 1, true), msg)
  T.eq({d.coffins, d.zones, d.free}, {200, 201, 200})
  T.ok(d.listed > 20 and d.listed < 200, d.listed)
  T.ok(#json.encode(d) <= 7300, #json.encode(d))
  T.eq(d.loose, {{201 * 2 - 1, 90, 90, 5, 2}})
  T.ok(d.legend:find('no_coffin', 1, true))
  local bad = W.inbox('inspect', {what = 'nonsense'})
  T.eq(bad.ok, false)
end)

---------------------------------------------------------------- BUG-003: inspect tombs after burials
T.test('BUG-003: a body with remains in a coffin is buried; inspect keeps the acts of the entomb run', function()
  local cof
  local W = world{cit = 6, setup = function(W)
    cof = CW.tomb(W, 30, 10, 5)                                 -- a free usable tomb
    W.kill(3)
  end}
  W.event('UNIT_DEATH', {unit = 3})
  local body = corpse(W, 3, {5, 5, 5})
  local part = corpse(W, 3, {6, 5, 5})                          -- a severed part of the same body
  W.run(2)
  T.eq(entombs(W), {'entomb --unit 3 --haul-now'})
  CW.day(W)                                                     -- the next run has nothing to do
  local d, msg = inspect(W)
  T.eq(d.acts.entombed, 0, 'this run')
  T.eq({d.last.assigned, d.last.entombed}, {1, 1}, 'the acts of the entomb run stay visible')
  T.ok(msg:find('entomb 1', 1, true), msg)
  T.eq(d.unburied_n, 1)
  body.flags.in_building, body._holder = true, cof              -- the burial job laid the corpse in the coffin
  CW.day(W)
  d, msg = inspect(W)
  T.eq({d.unburied_n, d.buried_loose}, {0, 1}, 'the loose part keeps nobody unburied')
  T.ok(msg:find('0 unburied', 1, true), msg)
  T.eq(part.flags.forbid, nil)
end)

T.test('BUG-003: inspect rebuilds an index older than one care period (read-only)', function()
  local W, Cm = world{cit = 6, setup = function(W) CW.tomb(W, 30, 10, 5, {unit = 3}) end}
  local body
  W.run(2)
  local d = inspect(W)
  T.eq({d.unburied_n, d.fresh}, {0, nil})
  Cm.every = {ticks = 10 ^ 7}                                   -- care stops running (demoted, faulting, ...)
  W.kill(3)
  body = corpse(W, 3, {5, 5, 5})
  W.run(1300, {skip = 100})
  local acts = #W.acts
  d = inspect(W)
  T.eq({d.unburied_n, d.fresh}, {1, 1}, 'rebuilt: the new body is listed')
  T.eq(#W.acts, acts, 'the rebuild writes nothing')
  body.flags.in_building, body._holder = true, W.buildings[1]
  d = inspect(W)
  T.eq(d.unburied_n, 0, 'buried in the coffin')
end)

---------------------------------------------------------------- doctors and hospital posts (FR-48)
local function medic_world(extra)
  return world{cit = 10, setup = function(W)
    df.unit_labor = {DIAGNOSE = 10, SURGERY = 11, BONE_SETTING = 12}
    df.occupation_type = kmock.enum{'TAVERN_KEEPER', 'DOCTOR', 'DIAGNOSTICIAN', 'SURGEON', 'BONE_DOCTOR'}
    for i = 1, 10 do W.unit(i).status.labors = {[10] = false, [11] = false, [12] = false} end
    W.unit(1).status.labors = {[10] = true, [11] = true, [12] = true}      -- a doctor
    W.unit(2).status.labors[10] = true                                     -- a partial doctor
    W.unit(3).military.squad_id = 1                                        -- a soldier
    W.unit(4).mood = df.mood_type.Fey                                      -- in a mood
    W.unit(5)._m.adult = false                                             -- a child
    W.unit(6).health = {flags = {needs_healthcare = true}}                 -- a patient
    W.unit(7)._m.skills = {SURGERY = 5}
    W.act_result('medic', function(id, on)
      for _, l in ipairs({10, 11, 12}) do W.unit(id).status.labors[l] = on end
      return true, 'enabled'
    end)
    if extra then extra(W) end
  end}
end

T.test('doctors: at least 4 adults with DIAGNOSE/SURGERY/BONE_SETTING; partial doctors, then skill; never soldiers, moody, children, patients', function()
  local W, Cm = medic_world()
  W.run(2)
  local m = {}
  for _, a in ipairs(W.find_acts('medic')) do m[#m + 1] = {a.args[1], a.args[2]} end
  T.eq(m, {{2, true}, {7, true}, {8, true}})
  T.eq(Cm.kpi(W.K).doctors.have, 4)
  CW.day(W, 2)
  T.eq(#W.find_acts('medic'), 3, 'enough doctors: nothing more')
  W.kill(1)                                                    -- a doctor died
  W.set_census('u', F.census_u({2, 3, 4, 5, 6, 7, 8, 9, 10}))
  CW.day(W)
  T.eq(#W.find_acts('medic'), 4)
  T.eq(W.find_acts('medic')[4].args[1], 9)
end)

T.test('hospital posts: vacant or held by the dead are filled with doctors who hold no post; never soldiers', function()
  local W = medic_world(function(W)
    local hosp = {id = 600, getType = function() return df.abstract_building_type.HOSPITAL end}
    local tav = {id = 601, getType = function() return df.abstract_building_type.INN_TAVERN end}
    W.site.buildings:insert('#', hosp); W.site.buildings:insert('#', tav)
    F.building(W, 'ANY_ZONE', {x1 = 10, y1 = 10, x2 = 14, y2 = 14, z = 5, location_id = 600})   -- BUG-056: a zone makes it a hospital
    W.unit(3).status.labors = {[10] = true, [11] = true, [12] = true}      -- a soldier doctor: no post
    W.add_unit{id = 99, dead = true}
    df.global.world.occupations = {all = kmock.vec{
      {id = 1, type = df.occupation_type.DOCTOR, location_id = 600, unit_id = -1},
      {id = 2, type = df.occupation_type.SURGEON, location_id = 600, unit_id = 99},
      {id = 3, type = df.occupation_type.DIAGNOSTICIAN, location_id = 600, unit_id = 1},
      {id = 4, type = df.occupation_type.DOCTOR, location_id = 601, unit_id = -1},
      {id = 5, type = df.occupation_type.TAVERN_KEEPER, location_id = 601, unit_id = 7},
    }}
  end)
  W.run(2)
  local p = {}
  for _, a in ipairs(W.find_acts('hospital_post')) do p[#p + 1] = {a.args[1], a.args[2]} end
  T.eq(p, {{1, 2}, {2, 8}}, 'unit 1 and 7 hold posts; the soldier doctor 3 neither counts nor gets a post')
  df.global.world.occupations = nil
end)

T.test('BUG-056 (Run 11: 8 hospital locations stayed after their zones were deleted): the posts of a location without ' ..
       'a zone are left alone, so the doctors fill the live hospital\'s posts (old: the stale locations\' older ids came first)',
       function()
  local W, Cm = medic_world(function(W)
    for id = 600, 603 do
      W.site.buildings:insert('#', {id = id, getType = function() return df.abstract_building_type.HOSPITAL end})
    end
    F.building(W, 'ANY_ZONE', {x1 = 10, y1 = 10, x2 = 14, y2 = 14, z = 5, location_id = 603})   -- only 603 has a zone
    df.global.world.occupations = {all = kmock.vec{
      {id = 1, type = df.occupation_type.DOCTOR, location_id = 600, unit_id = -1},
      {id = 2, type = df.occupation_type.SURGEON, location_id = 601, unit_id = -1},
      {id = 3, type = df.occupation_type.DIAGNOSTICIAN, location_id = 602, unit_id = -1},
      {id = 4, type = df.occupation_type.DOCTOR, location_id = 603, unit_id = -1},
      {id = 5, type = df.occupation_type.SURGEON, location_id = 603, unit_id = -1},
    }}
  end)
  W.run(2)
  local p = {}
  for _, a in ipairs(W.find_acts('hospital_post')) do p[#p + 1] = {a.args[1], a.args[2]} end
  T.eq(p, {{4, 1}, {5, 2}}, 'posts 4 and 5 of the live location; 1-3 belong to locations without a zone')
  T.eq(Cm.kpi(W.K).doctors.stale, 3)
  df.global.world.occupations = nil
end)

---------------------------------------------------------------- mood survival (FR-44)
local function filter(t, spec)
  local f = {item_type = t and df.item_type[t] or -1, mat_type = -1, mat_index = -1, quantity = 1, flags2 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end

T.test('FR-44: a mood that starts without its materials raises MOOD_RISK (A) with the missing classes, once', function()
  local W = CW.world{setup = function(W)
    local u = W.unit(1)
    u.mood = df.mood_type.Fey
    u.job.current_job = CW.mood_job(W, 901, F.workshop(W, 'Craftsdwarfs'), {filter('BAR', {quantity = 150})})
    local u2 = W.unit(2)                                          -- everything present: no risk
    u2.mood = df.mood_type.Secretive
    u2.job.current_job = CW.mood_job(W, 902, F.workshop(W, 'Masons'), {filter('BOULDER')})
    F.item(W, 'BOULDER', {id = 50, _pos = {10, 10, 5}})
  end}
  W.run(1)
  local r = W.find_events('MOOD_RISK')
  T.eq(#r, 1)
  T.eq(r[1].cls, 'A')
  T.eq({r[1].d.unit, r[1].d.why, r[1].d.kind, r[1].d.missing}, {1, 'missing', 'Fey', {'bars'}})
  T.ok(r[1].msg:find('starts without', 1, true), r[1].msg)
  CW.day(W, 2)
  T.eq(#W.find_events('MOOD_RISK'), 1, 'the start check runs once per mood')
end)

T.test('FR-44: a moody dwarf past the thirst or hunger line: MOOD_RISK at once, again only for the other cause after max(2 days, 10 min)', function()
  local W = CW.world{setup = function(W)
    local u = W.unit(1)
    u.mood = df.mood_type.Possessed
    u.counters2 = {thirst_timer = 10000, hunger_timer = 0}
    u.job.current_job = CW.mood_job(W, 901, F.workshop(W, 'Craftsdwarfs'),
                                    {filter(nil, {quantity = 2, flags2 = {bone = true, body_part = true}})})
  end}
  W.run(1)
  T.eq(#W.find_events('MOOD_RISK'), 1, 'the start check')
  W.unit(1).counters2.thirst_timer = 31000
  CW.day(W)
  local r = W.find_events('MOOD_RISK')
  T.eq(#r, 2)
  T.eq({r[2].d.why, r[2].d.thirst, r[2].d.missing}, {'thirst', 31000, {'bone'}})
  T.ok(r[2].msg:find('cannot be cancelled', 1, true) and r[2].msg:find('missing bone', 1, true), r[2].msg)
  CW.day(W, 3)
  W.ms = W.ms + 600000
  CW.day(W)
  T.eq(#W.find_events('MOOD_RISK'), 2, 'the same cause: no repeat (BUG-008)')
  W.unit(1).counters2 = {thirst_timer = 1000, hunger_timer = 52000}
  CW.day(W)
  r = W.find_events('MOOD_RISK')
  T.eq(#r, 3, 'another cause and both clocks passed')
  T.eq(r[#r].d.why, 'hunger')
  W.unit(1).counters2 = {thirst_timer = 32000, hunger_timer = 1000}
  CW.day(W, 3)
  T.eq(#W.find_events('MOOD_RISK'), 3, 'back to thirst within 10 wall minutes: waits')
  for _, a in ipairs(W.acts) do
    T.ok(a.fn == 'item_flag' or a.fn == 'run', 'unexpected act ' .. a.fn)
  end
end)

---------------------------------------------------------------- act functions
local function mk()
  local env = {who_v = 'care', fails = {}}
  env.api = actlib.new{
    who = function() return env.who_v end,
    allowlist = function() return actlib.BUILTIN_ALLOWLIST end,
    log_cmd = function() end,
    fail = function(fn, err, module) env.fails[#env.fails + 1] = {fn, err, module} end,
  }
  return env
end

T.test('act.tomb_zone: remove, free, open, assign through setOwner/deconstruct; tomb zones only', function()
  local W = H.world{tag = 'tomb', units = {{id = 7, dead = true}, {id = 8, citizen = true}}}
  df.civzone_type = {Tomb = 1, Bedroom = 2}
  local owners, gone = {}, {}
  dfhack.buildings = {
    setOwner = function(z, u) z.assigned_unit_id = u and u.id or -1; owners[#owners + 1] = u and u.id or -1; return true end,
    deconstruct = function(z) gone[#gone + 1] = z.id; return true end,
  }
  local function zone(id, t, unit, closed)
    return W.add_building{id = id, type = t, assigned_unit_id = unit,
                          zone_settings = {tomb = {flags = {no_citizens = closed}}}}
  end
  local z1, z2, z3 = zone(11, 1, -1, true), zone(12, 1, 7, false), zone(13, 2, -1, false)
  local env = mk()
  T.eq({env.api.tomb_zone('assign', 11, 8)}, {false, 'not a dead unit'})
  T.eq({env.api.tomb_zone('assign', 11, 7)}, {true, 'assigned'})
  T.eq({env.api.tomb_zone('assign', 11, 7)}, {true, 'already'})
  T.eq({env.api.tomb_zone('free', 11)}, {true, 'freed'})
  T.eq({z1.assigned_unit_id, z1.zone_settings.tomb.flags.no_citizens}, {-1, false})
  z1.zone_settings.tomb.flags.no_citizens = true
  T.eq({env.api.tomb_zone('open', 11)}, {true, 'opened'})
  T.eq({env.api.tomb_zone('open', 11)}, {true, 'already'})
  T.eq({env.api.tomb_zone('remove', 12)}, {true, 'removed'})
  T.eq({owners, gone}, {{7, -1, -1}, {12}}, 'the owner link is dropped before the zone')
  T.eq({env.api.tomb_zone('remove', 13)}, {false, 'not a tomb zone'})
  T.eq({env.api.tomb_zone('burn', 11)}, {false, 'op must be remove, free, open or assign'})
  env.who_v = 'economy'
  T.eq({env.api.tomb_zone('free', 11)}, {false, 'not owner'})
end)

T.test('act.medic: the three doctor labors of an adult living citizen; act.hospital_post: hospital posts only', function()
  local W = H.world{tag = 'medic', units = {{id = 7, citizen = true}, {id = 8, citizen = true, adult = false},
                                             {id = 9, dead = true}, {id = 10, citizen = true}}}
  df.unit_labor = {DIAGNOSE = 1, SURGERY = 2, BONE_SETTING = 3}
  for _, id in ipairs({7, 8, 9, 10}) do W.unit(id).status.labors = {[1] = false, [2] = true, [3] = false} end
  local env = mk()
  T.eq({env.api.medic(7, true)}, {true, 'enabled'})
  T.eq(W.unit(7).status.labors, {[1] = true, [2] = true, [3] = true})
  T.eq({env.api.medic(7, true)}, {true, 'already'})
  T.eq({env.api.medic(8, true)}, {false, 'not an adult living citizen'})
  T.eq({env.api.medic(7, false)}, {true, 'disabled'})
  df.occupation_type = kmock.enum{'TAVERN_KEEPER', 'DOCTOR', 'DIAGNOSTICIAN', 'SURGEON', 'BONE_DOCTOR'}
  df.abstract_building_type = {HOSPITAL = 13, INN_TAVERN = 8}
  local site = {buildings = kmock.vec{{id = 600, getType = function() return 13 end},
                                      {id = 601, getType = function() return 8 end}}}
  dfhack.world = dfhack.world or {}
  dfhack.world.getCurrentSite = function() return site end
  W.unit(9).occupations = kmock.vec{}
  W.unit(10).occupations = kmock.vec{}
  W.unit(7).occupations = kmock.vec{}
  local o1 = {id = 1, type = df.occupation_type.SURGEON, location_id = 600, unit_id = 9, histfig_id = 90}
  W.unit(9).occupations:insert('#', o1)
  local o2 = {id = 2, type = df.occupation_type.DOCTOR, location_id = 600, unit_id = 10}
  local o3 = {id = 3, type = df.occupation_type.TAVERN_KEEPER, location_id = 601, unit_id = -1}
  df.global.world.occupations = {all = kmock.vec{o1, o2, o3}}
  W.unit(7).hist_figure_id = 70
  T.eq({env.api.hospital_post(1, 7)}, {true, 'filled'})
  T.eq({o1.unit_id, o1.histfig_id, #W.unit(9).occupations, W.unit(7).occupations[0].id}, {7, 70, 0, 1})
  T.eq({env.api.hospital_post(1, 7)}, {true, 'already'})
  T.eq({env.api.hospital_post(2, 7)}, {false, 'post held by a living unit'})
  T.eq({env.api.hospital_post(3, 7)}, {false, 'not a hospital post'})
  T.eq({env.api.hospital_post(1, 8)}, {false, 'not an adult living citizen'})
  df.global.world.occupations = nil
end)

T.done()
