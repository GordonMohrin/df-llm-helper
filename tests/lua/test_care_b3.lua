-- care, package B3 (Run 14, 2026): the tomb zone lock and the ghosts (BUG-062).
-- Every test here fails on the commit before the package (f17e2b3).
local T = require('testlib')
local CW = require('care_world')
local F = CW.F
local json = require('dfllm.util.json')

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

local function closed_zones()
  local n = 0
  for _, z in ipairs(df.global.world.buildings.other.ZONE_TOMB) do
    if z.zone_settings.tomb.flags.no_citizens then n = n + 1 end
  end
  return n
end

---------------------------------------------------------------- BUG-062: the zone lock
T.test('BUG-062: every closed free tomb zone is opened in one run, not 20 acts at a time', function()
  local W = world{cit = 6, setup = function(W)
    for i = 0, 59 do CW.tomb(W, 30 + i, 10, 5, {closed = true}) end
    dead(W, 3)
    corpse(W, 3)
  end}
  W.run(2)
  T.eq(closed_zones(), 1, 'the 60 closed zones are open but the one assigned to the dead (entomb closes it)')
  T.eq(#CW.tacts(W, 'assign'), 1)
  T.eq(#CW.tacts(W, 'open'), 59)
  T.eq(W.state().care.tombs_free, 59)
  T.eq(W.state().care.tombs_locked, nil, 'nothing is left closed')
end)

T.test('BUG-062: a zone that stays closed (the open failed) is no free tomb; the body says zone_locked', function()
  local W = world{cit = 6, setup = function(W)
    for i = 0, 3 do CW.tomb(W, 30 + i, 10, 5, {closed = true}) end
    dead(W, 3)
    corpse(W, 3, {5, 5, 5}, {flags = {forbid = false}})
  end}
  local orig = W.act_results.tomb_zone
  W.act_result('tomb_zone', function(op, id, uid)
    if op == 'open' or op == 'assign' then return false, 'refused' end
    return orig(op, id, uid)
  end)
  W.run(2)
  local d = inspect(W)
  T.eq(why_of(d, 3), 'zone_locked', 'free tombs exist but none DF can use: the lock, not a missing coffin')
  T.eq(d.free, 0, 'four closed zones are no free tombs')
  T.eq(d.locked, 4)
  T.eq(W.state().care.tombs_free, 0)
  T.eq(W.state().care.tombs_locked, 4)
  local ev = W.find_events('TOMBS_LOCKED')
  T.eq(#ev, 1)
  T.eq(ev[1].cls, 'B')
  T.eq({ev[1].d.closed, ev[1].d.free, ev[1].d.usable, ev[1].d.opened, ev[1].d.left, ev[1].d.unburied}, {4, 4, 4, 0, 4, 1})
end)

T.test('BUG-062: zones care opened and found closed again are counted by owner, entomb apart (TOMBS_LOCKED)', function()
  local W = world{cit = 6, setup = function(W)
    for i = 0, 3 do CW.tomb(W, 30 + i, 10, 5, {closed = true}) end     -- zones 2, 4, 6, 8: all closed, nobody dead yet
  end}
  W.run(2)
  local ev = W.find_events('TOMBS_LOCKED')
  T.eq(#ev, 1)
  T.eq({ev[1].d.closed, ev[1].d.usable, ev[1].d.opened, ev[1].d.left, ev[1].d.again_free, ev[1].d.again_owned}, {4, 4, 4, 0, 0, 0})
  T.eq(closed_zones(), 0)
  local by_id = {}
  for _, z in ipairs(df.global.world.buildings.other.ZONE_TOMB) do by_id[z.id] = z end
  W.ms = W.ms + 600000
  dead(W, 3)
  corpse(W, 3)
  CW.day(W)
  T.eq(CW.tacts(W, 'assign'), {{'assign', 2, 3}}, 'the lowest free zone goes to unit 3, entomb follows')
  -- what happens next, as the live fort showed: entomb closes the zone it assigned, a closed zone nobody owns, and a
  -- zone DF handed to a dead citizen (unit 5 has no body here) that is closed with its owner
  by_id[2].zone_settings.tomb.flags.no_citizens = true
  by_id[6].zone_settings.tomb.flags.no_citizens = true
  by_id[4].zone_settings.tomb.flags.no_citizens = true
  by_id[4].assigned_unit_id = 5
  dead(W, 5)
  W.ms = W.ms + 600000
  CW.day(W, 8)
  ev = W.find_events('TOMBS_LOCKED')
  T.eq(#ev, 2, 'news: zones closed again')
  T.eq({ev[2].d.again_free, ev[2].d.again_owned, ev[2].d.by_entomb}, {1, 2, 1})
  T.ok(ev[2].msg:find('closed again since: 1 unassigned, 2 assigned (1 by entomb)', 1, true), ev[2].msg)
  local d = inspect(W)
  T.eq(d.again, {free = 1, owned = 2, by_entomb = 1})
  T.eq(by_id[6].zone_settings.tomb.flags.no_citizens, false, 'the unassigned one is opened again')
  T.eq(by_id[2].zone_settings.tomb.flags.no_citizens, true, 'an assigned zone belongs to its dead: left alone')
  T.eq(by_id[4].assigned_unit_id, -1, 'the bodiless dead\'s zone is freed (FR-41) and open')
  T.eq(by_id[4].zone_settings.tomb.flags.no_citizens, false)
end)

T.test('BUG-062: inspect names why coffins are no free tombs', function()
  local W = world{cit = 6, setup = function(W)
    CW.tomb(W, 30, 10, 5, {built = false})                      -- unbuilt coffin
    CW.tomb(W, 31, 10, 5)                                       -- usable
    CW.tomb(W, 32, 10, 5)
    F.building(W, 'ZONE_BEDROOM', {x1 = 32, y1 = 9, x2 = 34, y2 = 11, z = 5})   -- bedroom coffin
  end}
  W.run(2)
  local d = inspect(W)
  T.eq(d.unusable, {unbuilt = 1, bedroom = 1, other_zone = 0, occupied = 0, zones = 0})
  T.eq(d.free, 1)
end)

---------------------------------------------------------------- BUG-062: bodies nobody can walk to
T.test('BUG-062: a body in another walk group is corpse_far, not no_coffin; no zone, no coffin request for it', function()
  local W = world{cit = 6, reach = function(a, b) return not (a.x == 99 or b.x == 99) end, setup = function(W)
    CW.tomb(W, 30, 10, 5)                                       -- a free usable tomb
    dead(W, 3, true)
    corpse(W, 3, {99, 99, 5})                                   -- an old battlefield (walk group 859 against the fort's 9)
    dead(W, 4)
    corpse(W, 4)                                                -- a body in the fort
  end}
  W.run(2)
  local d = inspect(W)
  T.eq(why_of(d, 3), 'corpse_far')
  T.eq(why_of(d, 4), 'no_zone', 'the cause before the repair: the body in the fort gets the free tomb')
  T.eq(CW.tacts(W, 'assign'), {{'assign', 2, 4}}, 'the free zone is not wasted on the far body')
  T.eq(d.far_n, 1)
  T.eq(d.prov.far, 1)
  T.eq(d.prov.open, 0, 'no coffin is provisioned for a body nobody can fetch')
  CW.day(W, 4)
  local g = W.find_events('GHOSTS')
  T.eq(#g, 1)
  T.eq({g[1].d.ghosts, g[1].d.far}, {1, 1})
  T.eq(g[1].d.causes, {'3:corpse_far'})
  T.ok(g[1].msg:find('corpse_far', 1, true) and g[1].msg:find('another walk group', 1, true), g[1].msg)
end)

T.test('BUG-062: without the reach hook nothing is far (no guess)', function()
  local W = world{cit = 6, setup = function(W)
    CW.tomb(W, 30, 10, 5)
    dead(W, 3)
    corpse(W, 3, {99, 99, 5})
  end}
  W.run(2)
  local d = inspect(W)
  T.eq({d.far_n, d.prov.far}, {0, 0})
  T.eq(why_of(d, 3), 'no_zone', 'no reach hook: the body is assigned a tomb as before')
  T.eq(CW.tacts(W, 'assign'), {{'assign', 2, 3}})
end)

---------------------------------------------------------------- BUG-062: the ghost number
T.test('BUG-062: the ghost number is the ghostly units (census.g), not only the deaths care saw', function()
  local units = {}
  for i = 0, 11 do units[#units + 1] = {id = 200 + i, citizen = true, pos = {5, 5, 5}} end   -- deaths care sees
  local W = world{cit = 6, units = units}
  local ids = {}
  for i = 0, 17 do ids[#ids + 1] = 100 + i end                  -- ghosts of an earlier run, never recorded
  for i = 0, 11 do ids[#ids + 1] = 200 + i end
  W.K.census.g = {tick = W.K.now().tick, n = #ids, ids = ids}            -- what sense meets in the unit list
  for i = 0, 11 do dead(W, 200 + i, true) end
  W.run(2)
  T.eq(W.state().care.ghosts, 30, '12 recorded deaths + 18 ghostly citizens nobody recorded')
  local g = W.find_events('GHOSTS')
  T.eq(g[1].d.ghosts, 30)
  local logs = {}
  for _, l in ipairs(W.logs) do if l.msg:find('not in the death record', 1, true) then logs[#logs + 1] = l.msg end end
  T.eq(#logs, 1)
  T.ok(logs[1]:find('18 ghostly citizen', 1, true), logs[1])
  -- sense stopped: a census.g older than two days is not trusted, only the ghostly units of the death record count
  W.K.census.g.tick = W.K.now().tick - 200000
  CW.day(W)
  T.eq(W.state().care.ghosts, 12)
end)

---------------------------------------------------------------- BUG-063: moods
local function filter(t, spec)
  local f = {item_type = t and df.item_type[t] or -1, mat_type = -1, mat_index = -1, quantity = 1, flags2 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end

-- a strange mood: unit `id` claims a Craftsdwarfs workshop at 22..24,22..24 z5 and needs one bone (available)
local function moody(W, id, kind, thirst, hunger, shop)
  local u = W.unit(id)
  u.mood = df.mood_type[kind]
  u.counters2 = {thirst_timer = thirst or 0, hunger_timer = hunger or 0}
  shop = shop or F.workshop(W, 'Craftsdwarfs')
  shop.x1, shop.y1, shop.x2, shop.y2, shop.z = 22, 22, 24, 24, 5
  u.job.current_job = CW.mood_job(W, 900 + id, shop, {filter(nil, {quantity = 1, flags2 = {bone = true, body_part = true}})})
  return u, shop
end

local function risks(W, why)
  local r = {}
  for _, e in ipairs(W.find_events('MOOD_RISK')) do if why == nil or e.d.why == why then r[#r + 1] = e end end
  return r
end

T.test('BUG-063: the game announcing a strange mood starts the check at once, not at the next care run', function()
  local W = world{cit = 6}
  W.run(1)
  T.eq(W.find_events('MOOD_START'), {})
  moody(W, 2, 'Fey', 0, 0)
  W.event('REPORT', {type = 'STRANGE_MOOD', text = 'Urist has been taken by a fey mood!'})
  W.run(3)
  local s = W.find_events('MOOD_START')
  T.eq(#s, 1, 'noticed within a few ticks of the report (care runs every 1,200)')
  T.eq(s[1].d.unit, 2)
end)

T.test('BUG-063: while a mood is open the thirst and hunger are read every mood_fast ticks, not every care run', function()
  local W = world{cit = 6}
  moody(W, 2, 'Fey', 1000, 0)
  W.run(1)
  T.eq(#W.find_events('MOOD_START'), 1)
  W.unit(2).counters2.thirst_timer = 31000
  W.run(450, {skip = 50})
  T.eq(#risks(W, 'thirst'), 1, 'MOOD_RISK within 450 ticks of the thirst passing the line (the full run is 1,200 apart)')
  T.eq(W.K.persist.get('m.care') ~= nil, true)
  -- the quiet fort keeps its cadence
  local W2 = world{cit = 6}
  W2.run(1)
  W2.unit(1).counters2 = {thirst_timer = 0, hunger_timer = 0}
  W2.run(450, {skip = 50})
  T.eq(W2.find_events('MOOD_START'), {})
end)

T.test('BUG-063: hunger above 40,000 is a MOOD_RISK too; the line names thirst, hunger and the workshop', function()
  local W = world{cit = 6}
  moody(W, 2, 'Possessed', 12000, 41000)
  W.run(1)
  local r = risks(W, 'hunger')
  T.eq(#r, 1)
  T.eq({r[1].d.thirst, r[1].d.hunger, r[1].d.ws}, {12000, 41000, 'Craftsdwarfs'})
  T.ok(r[1].msg:find('thirst 12000 hunger 41000', 1, true) and r[1].msg:find('Craftsdwarfs', 1, true), r[1].msg)
  T.ok(#r[1].msg <= 200)
end)

T.test('BUG-063: thirst past 50,000 is MOOD_CRITICAL (A): the dwarf and the workshop named, once per cadence', function()
  local W = world{cit = 6}
  moody(W, 2, 'Fey', 20000, 0)
  W.run(1)
  T.eq(W.find_events('MOOD_CRITICAL'), {})
  W.unit(2).counters2.thirst_timer = 50500
  W.run(450, {skip = 50})
  local c = W.find_events('MOOD_CRITICAL')
  T.eq(#c, 1)
  T.eq(c[1].cls, 'A')
  T.eq({c[1].d.unit, c[1].d.why, c[1].d.kind, c[1].d.ws, c[1].d.thirst, c[1].d.pos}, {2, 'thirst', 'Fey', 'Craftsdwarfs', 50500, {22, 22, 5}})
  T.ok(c[1].msg:find('Unit 2', 1, true) and c[1].msg:find('workshop Craftsdwarfs at 22,22,5', 1, true), c[1].msg)
  W.run(900, {skip = 100})
  T.eq(#W.find_events('MOOD_CRITICAL'), 1, 'the same cause is not repeated within the cadence')
end)

local function nook_world(o)
  o = o or {}
  local floor = {}
  for y = 18, 28 do for x = 18, 28 do floor[x .. ',' .. y .. ',5'] = true end end
  local W, Cm = CW.world{cit = 6, runner = true, mode = o.mode, tile = function(x, y, z)
    return {c = floor[x .. ',' .. y .. ',' .. z] and '.' or '#', dig = '', bld = ''}
  end, setup = function(W)
    df.global.building_next_id = 1000
    W.qf = {}
    W.act_result('quickfort', function(p)
      W.qf[#W.qf + 1] = {mode = p.mode, pos = p.pos, data = p.data}
      return true, {}
    end)
  end}
  return W, Cm
end

T.test('BUG-063: from 40,000 a one-barrel drink stockpile is queued beside the claimed workshop (never a job for the dwarf)', function()
  local W = nook_world()
  moody(W, 2, 'Fey', 41000, 0)
  W.run(1)
  local r = risks(W, 'thirst')
  T.eq(#r, 1)
  T.ok(r[1].msg:find('drink nook queued at 22,21,5', 1, true), r[1].msg)
  local P
  for _, x in ipairs((W.K.persist.get('projects') or {}).list or {}) do if x.tpl == 'mood_drink' then P = x end end
  T.ok(P, 'a mood_drink project')
  local d = W.K.persist.get('bp.' .. P.id)
  T.eq(d.stages[1].mode, 'place')
  local c = d.stages[1].chunks[1]
  T.eq({c.pos, c.cells[1][4]}, {{22, 21, 5}, 'f{name=dfllm-mood barrels=1 take_from=dfllm-stock}:=booze(1x1)'})
  T.ok(#c.cells[1][4] <= 64)
  -- once per mood: not again, whatever the thirst does
  W.unit(2).counters2.thirst_timer = 52000
  W.run(900, {skip = 100})
  local n = 0
  for _, x in ipairs((W.K.persist.get('projects') or {}).list or {}) do if x.tpl == 'mood_drink' then n = n + 1 end end
  T.eq(n, 1)
  T.ok(W.find_events('MOOD_CRITICAL')[1].msg:find('drink nook queued at 22,21,5', 1, true))
  for _, a in ipairs(W.acts) do
    T.ok(a.fn ~= 'job' and a.fn ~= 'item_flag', 'no act on the dwarf or his items: ' .. a.fn)
  end
end)

T.test('BUG-063: no nook in a fight; a nook only beside a claimed workshop; no free floor is said', function()
  local W = nook_world{mode = 'SIEGE'}
  moody(W, 2, 'Fey', 41000, 0)
  W.run(1)
  T.eq(#risks(W, 'thirst'), 1)
  T.ok(not risks(W, 'thirst')[1].msg:find('nook', 1, true))
  local W2 = world{cit = 6}                    -- no runner module: no nook, no fault
  moody(W2, 2, 'Fey', 41000, 0)
  W2.run(1)
  T.ok(risks(W2, 'thirst')[1].msg:find('dies at 75000', 1, true))
  local W3, _ = CW.world{cit = 6, runner = true, tile = function() return {c = '#', dig = '', bld = ''} end}
  moody(W3, 2, 'Fey', 41000, 0)
  W3.run(1)
  T.ok(risks(W3, 'thirst')[1].msg:find('no free floor within 3 tiles', 1, true), risks(W3, 'thirst')[1].msg)
end)

---------------------------------------------------------------- BUG-064: toppled by
local function toppled(W) return W.find_events('BUILDING_TOPPLED') end

T.test('BUG-064: "X toppled by <dwarf>" names the culprit, his stress and a tantrum before it', function()
  local W = world{cit = 6}
  local u = W.unit(3)
  u._m.name, u._m.stress = 'Kel Becordastot, Manager', 0
  u.status.current_soul.personality.stress = 61234
  W.event('REPORT', {type = 'CITIZEN_TANTRUM', text = 'Kel Becordastot, Manager is throwing a tantrum!'})
  W.event('REPORT', {type = 'BUILDING_DESTROYED_OR_TOPPLED', text = "The Mason's Workshop was toppled by Kel Becordastot.",
                     pos = {x = 30, y = 40, z = 5}})
  W.run(3)
  local e = toppled(W)
  T.eq(#e, 1)
  T.eq(e[1].cls, 'B')
  T.eq({e[1].d.what, e[1].d.by, e[1].d.unit, e[1].d.ghost, e[1].d.stress, e[1].d.cat, e[1].d.pos},
       {"Mason's Workshop", 'Kel Becordastot', 3, 0, 61234, 0, {30, 40, 5}})
  T.ok(e[1].msg:find("Mason's Workshop toppled by Kel Becordastot, stress 61234", 1, true), e[1].msg)
end)

T.test('BUG-064: a ghost that toppled a lever (one ghost in the census: its id), two buildings by one dwarf in a day: one event', function()
  local W = world{cit = 6, units = {{id = 50, citizen = true, pos = {5, 5, 5}}}}
  W.kill(50)
  W.unit(50)._m.ghost = true
  W.K.census.g = {tick = W.K.now().tick, n = 1, ids = {50}}
  W.event('REPORT', {type = 'BUILDING_TOPPLED_BY_GHOST', text = 'A lever was toppled by a ghost!', pos = {x = 10, y = 10, z = 5}})
  W.run(3)
  local e = toppled(W)
  T.eq(#e, 1)
  T.eq({e[1].d.what, e[1].d.by, e[1].d.unit, e[1].d.ghost}, {'lever', 'a ghost', 50, 1})
  for i = 1, 3 do
    W.event('REPORT', {type = 'BUILDING_TOPPLED_BY_GHOST', text = 'A table was toppled by a ghost!', pos = {x = 10 + i, y = 10, z = 5}})
  end
  W.run(3)
  T.eq(#toppled(W), 1, 'the same culprit within topple_every ticks: counted, not announced again')
  CW.day(W, 3)
  W.event('REPORT', {type = 'BUILDING_TOPPLED_BY_GHOST', text = 'A door was toppled by a ghost!', pos = {x = 20, y = 10, z = 5}})
  W.run(3)
  e = toppled(W)
  T.eq(#e, 2)
  T.eq(e[2].d.n, 3, 'three buildings since the last event')
end)

T.test('BUG-064: care.toppled finds the record near a position within topple_win ticks; two dwarves of one name are not guessed', function()
  local W, care = world{cit = 6}
  W.unit(3)._m.name = 'Urist McSame'
  W.unit(4)._m.name = 'Urist McSame'
  W.event('REPORT', {type = 'BUILDING_DESTROYED_OR_TOPPLED', text = 'A Bridge was toppled by Urist McSame.',
                     pos = {x = 20, y = 25, z = 9}})
  W.event('REPORT', {type = 'BUILDING_DESTROYED_OR_TOPPLED', text = 'A Statue was toppled by Somebody Else.',
                     pos = {x = 50, y = 50, z = 9}})
  W.run(3)
  local ok, r = W.K.call('care', 'toppled', 22, 25, 9)
  T.ok(ok and type(r) == 'table')
  T.eq({r.by, r.what, r.unit}, {'Urist McSame', 'Bridge', -1})
  T.eq(({W.K.call('care', 'toppled', 22, 25, 12)})[2], nil, 'another level')
  T.eq(({W.K.call('care', 'toppled', 40, 25, 9)})[2], nil, 'too far')
  CW.day(W, 5)
  T.eq(({W.K.call('care', 'toppled', 22, 25, 9)})[2], nil, 'older than topple_win')
end)

---------------------------------------------------------------- FR-74: stress sources, population
local kmock = require('dfllm.util.k_mock')

local function stressed(W, id, thoughts, cat)
  local u = W.unit(id)
  u._m.stress = cat or 0
  u.status.current_soul.personality.emotions = kmock.vec(thoughts)
end

T.test('FR-74: the stress sources are the thoughts of the stressed citizens, once per citizen and source', function()
  local W = world{cit = 8, setup = function(W)
    df.unit_thought_type = {[10] = 'GhostHaunt', [11] = 'WitnessDeath', [12] = 'LackBedroom', [13] = 'Rain',
                            [14] = 'Thirsty', [15] = 'GhostNightmare'}
  end}
  stressed(W, 1, {{thought = 10}, {thought = 15}, {thought = 11}})           -- ghosts (twice, counted once), deaths
  stressed(W, 2, {{thought = 10}, {thought = 12}})
  stressed(W, 3, {{thought = 11}, {thought = 13}})
  stressed(W, 4, {{thought = 14}}, 1)                                           -- category 1 still counts
  stressed(W, 5, {{thought = 10}, {thought = 12}, {thought = 11}}, 3)           -- not stressed: not counted
  W.run(2)
  local c = W.state().care
  T.eq(c.src, {ghosts = 2, deaths = 2, beds = 1, drink = 1})
  T.eq(c.stressed_pct, 50, '4 of 8')
end)

T.test('FR-74: STRESS_HIGH (B) after stress_days over stress_high, with the sources; calm forts say nothing', function()
  local W = world{cit = 4, setup = function(W)
    df.unit_thought_type = {[10] = 'GhostHaunt', [11] = 'WitnessDeath'}
  end}
  for i = 1, 3 do stressed(W, i, {{thought = 10}, {thought = 11}}) end
  W.run(2)
  CW.day(W, 10)
  T.eq(W.find_events('STRESS_HIGH'), {}, 'ten days: not yet')
  W.ms = W.ms + 600000
  CW.day(W, 6)
  local e = W.find_events('STRESS_HIGH')
  T.eq(#e, 1)
  T.eq(e[1].cls, 'B')
  T.eq({e[1].d.pct, e[1].d.src, e[1].d.cit}, {75, {'ghosts 3', 'deaths 3'}, 4})
  T.ok(e[1].d.days >= 14 and e[1].msg:find('plan propose drafts a temple and a tavern', 1, true), e[1].msg)
  CW.day(W, 3)
  T.eq(#W.find_events('STRESS_HIGH'), 1, 'the same set: not again')
  local W2 = world{cit = 4}
  CW.day(W2, 20)
  T.eq(W2.find_events('STRESS_HIGH'), {})
end)

T.test('FR-74: the population diagnosis: children and residents apart, the peak, the deaths of the year, the migrant waves', function()
  local units = {}
  for i = 1, 4 do units[#units + 1] = {id = 10 + i, citizen = true, pos = {5, 5, 5}, adult = false} end   -- children
  units[#units + 1] = {id = 20, resident = true, pos = {5, 5, 5}}                                          -- a resident
  local W, care = world{cit = 6, units = units}
  local ids = {}
  for i = 1, 6 do ids[#ids + 1] = i end
  for i = 1, 4 do ids[#ids + 1] = 10 + i end
  ids[#ids + 1] = 20
  W.set_census('u', F.census_u(ids))
  W.K.census.u.cit = 50
  W.run(2)
  local p = W.state().care.pop
  T.eq({p.kids, p.res, p.peak, p.dy, p.waves, p.mig, p.lastw}, {4, 1, 50, 0, 0, 0, -1})
  W.K.census.u.cit = 33                                     -- the fort shrank in peace
  dead(W, 2)
  dead(W, 3)
  care.on['EV:MIGRANTS'](W.K, {d = {n = 7}, tick = W.K.now().tick})
  CW.day(W, 3)
  p = W.state().care.pop
  T.eq({p.peak, p.dy, p.waves, p.mig, p.lastw}, {50, 2, 1, 7, 3}, 'peak stays, 2 deaths, 1 wave of 7, seen 3 days ago')
  T.eq(next(W.state().care.died_y) ~= nil, true)
  local n = 0
  for _, v in pairs(W.state().care.died_y) do n = n + v end
  T.eq(n, 2)
  -- a year later the deaths and the wave are out of the window
  W.ms = W.ms + 600000
  CW.day(W, 340)
  p = W.state().care.pop
  T.eq({p.dy, p.waves, p.mig}, {0, 0, 0})
  T.ok(p.lastw >= 340)
end)

T.done()
