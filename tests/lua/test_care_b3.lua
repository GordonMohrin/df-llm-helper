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

T.done()
