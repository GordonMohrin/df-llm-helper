-- care, package M1 (Run 14 notes 74 and 81): BUG-103 a unit that is no citizen (a resident, a merchant of a caravan) raises no
-- strange-mood report and no thirst or hunger decision; BUG-105 citizen bodies on tiles nobody can path to (tree crowns, tiles
-- without a walk group) are their own class (corpse_unreachable) apart from corpses_old and the GHOSTS wake.
-- Every test here fails on the commit before the package (32994bb).
local T = require('testlib')
local CW = require('care_world')
local F = CW.F
local kmock = require('dfllm.util.k_mock')

local function filter(spec)
  local f = {item_type = -1, mat_type = -1, mat_index = -1, quantity = 1, flags2 = {}}
  for k, v in pairs(spec or {}) do f[k] = v end
  return f
end

-- a strange mood: unit `id` claims a Craftsdwarfs workshop and wants a bone
local function moody(W, id, kind, thirst, hunger)
  local u = W.unit(id)
  u.mood = df.mood_type[kind]
  u.counters2 = {thirst_timer = thirst or 0, hunger_timer = hunger or 0}
  local shop = F.workshop(W, 'Craftsdwarfs')
  shop.x1, shop.y1, shop.x2, shop.y2, shop.z = 22, 22, 24, 24, 5
  u.job.current_job = CW.mood_job(W, 900 + id, shop, {filter({flags2 = {bone = true, body_part = true}})})
  return u
end

-- units that live in the fort without being citizens (sense.lua counts isCitizen or isResident): the census holds them
local function outsiders(W, ids, extra)
  for _, id in ipairs(ids) do
    local u = W.unit(id)
    u.job, u.mood = {current_job = nil}, -1
    u.inventory = kmock.vec{{mode = 2, item = {getType = function() return df.item_type.ARMOR end}}}
    u.status = {current_soul = {personality = {emotions = kmock.vec{}}}}
    u.counters = {death_cause = 1}
  end
  local all = {}
  for _, id in ipairs(extra) do all[#all + 1] = id end
  for _, id in ipairs(ids) do all[#all + 1] = id end
  W.set_census('u', F.census_u(all))
end

local function about(W, name, unit)
  local r = {}
  for _, e in ipairs(W.find_events(name)) do
    if unit == nil or e.d.unit == unit then r[#r + 1] = e end
  end
  return r
end

---------------------------------------------------------------- BUG-103
T.test('BUG-103: a resident (no citizen) in a strange mood at thirst 76,000 raises nothing; a citizen at 55,000 does', function()
  local W = CW.world{cit = 4, units = {{id = 40, resident = true, pos = {190, 23, 133}},
                                         {id = 41, resident = true, merchant = true, pos = {190, 24, 133}}}}
  outsiders(W, {40, 41}, {1, 2, 3, 4})
  moody(W, 40, 'Fey', 76000, 70000)
  moody(W, 41, 'Possessed', 52000, 0)
  moody(W, 2, 'Fey', 55000, 0)
  W.run(1)
  for _, name in ipairs({'MOOD_START', 'MOOD_RISK', 'MOOD_CRITICAL', 'MOOD_NEED'}) do
    T.eq(#about(W, name, 40), 0, name .. ' for a resident')
    T.eq(#about(W, name, 41), 0, name .. ' for a merchant')
  end
  T.eq(#about(W, 'MOOD_START', 2), 1, 'the citizen is still reported')
  T.ok(#about(W, 'MOOD_RISK', 2) >= 1)
  T.eq(#about(W, 'MOOD_CRITICAL', 2), 1)
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do
    T.ok(not (e.msg or ''):find('unit 40', 1, true) and not (e.msg or ''):find('unit 41', 1, true), e.msg)
    T.ok(e.d.unit ~= 40 and e.d.unit ~= 41)
  end
  T.eq(W.state().care.moods, 1, 'only the citizen\'s mood counts')
end)

T.test('BUG-103: a record of an older kernel for a unit that is no citizen is dropped silently (no MOOD_END), a citizen\'s ' ..
       'record stays; the mood check of the fast cadence ignores them too', function()
  local W = CW.world{cit = 4, units = {{id = 40, citizen = true, pos = {5, 5, 5}}}}
  outsiders(W, {40}, {1, 2, 3, 4})
  moody(W, 40, 'Fey', 52000, 0)
  moody(W, 2, 'Fey', 52000, 0)
  W.run(1)
  local risks = #about(W, 'MOOD_RISK', 40)
  T.ok(risks >= 1, 'a citizen at first')
  local p = W.K.persist.get('m.care')
  T.ok(p.moods['40'] and p.moods['2'])
  W.unit(40)._m.citizen, W.unit(40)._m.resident = false, true       -- the same unit is a resident now (a reload, a new roster)
  CW.day(W, 2)
  p = W.K.persist.get('m.care')
  T.eq(p.moods['40'], nil, 'dropped')
  T.ok(p.moods['2'], 'the citizen\'s record stays')
  T.eq(#about(W, 'MOOD_END', 40), 0, 'no MOOD_END for a unit nobody serves')
  T.eq(#about(W, 'MOOD_RISK', 40), risks, 'and no further MOOD_RISK')
  T.eq(W.state().care.moods, 1)
end)

T.test('BUG-103: the mood of an outsider asks for no material (mood_wants), no workshop request and no stock', function()
  local W, Cm = CW.world{cit = 3, units = {{id = 40, resident = true, pos = {5, 5, 5}}}}
  outsiders(W, {40}, {1, 2, 3})
  local u = W.unit(40)
  u.mood = df.mood_type.Fey
  u.counters2 = {thirst_timer = 80000, hunger_timer = 0}
  u.job.current_job = nil                                         -- no workshop claimed: MOOD_NEED / mood_workshop for a citizen
  W.run(1)
  CW.day(W, 3)
  T.eq(#about(W, 'MOOD_NEED', 40), 0)
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do T.ok(e.d.id ~= 'mood_workshop', e.msg) end
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do T.ok(e.d.why ~= 'mood', e.msg) end
  T.eq(Cm.mood_wants(W.K), {})
end)

---------------------------------------------------------------- BUG-105
local function corpse(W, uid, pos, extra)
  local spec = {unit_id = uid, _pos = pos or {5, 5, 5}}
  for k, v in pairs(extra or {}) do spec[k] = v end
  return F.item(W, 'ANY_CORPSE', spec)
end

local function dead(W, id, ghost)
  W.kill(id)
  if ghost then W.unit(id)._m.ghost = true end
  W.event('UNIT_DEATH', {unit = id})
end

local function crown_world(opts)
  opts = opts or {}
  local units = {}
  for i = 0, 5 do units[#units + 1] = {id = 6100 + i, citizen = true, pos = {5, 5, 5}} end
  local W, Cm = CW.world{cit = 6, units = units,
    reach = function(a, b) return not (a.x >= 100 or b.x >= 100) end,
    tile = function(x, y, z)
      if x >= 120 then return {c = '.', dig = '', bld = '', shape = 'BRANCH'} end
      return {c = '.', dig = '', bld = '', shape = 'FLOOR'}
    end,
    snap = {groups = function(K, pts)
      local r = {}
      for i, p in ipairs(pts) do r[i] = (p.x >= 130) and 0 or ((p.x >= 100) and 859 or 9) end
      return r
    end},
    setup = function(W)
      if opts.setup then opts.setup(W) end
    end}
  return W, Cm
end

T.test('BUG-105: five bodies in tree crowns are corpse_unreachable, not corpses_old: the Z7 number and GHOSTS ignore them',
       function()
  local W = crown_world{setup = function(W)
    for i = 0, 4 do
      dead(W, 6100 + i)
      corpse(W, 6100 + i, {120 + i, 64, 133})                       -- BRANCH tiles
    end
  end}
  CW.day(W, 4)
  local c = W.state().care
  T.eq(c.corpses_old, 0, 'nothing a citizen can bury is old')
  T.eq(c.corpses_unreach, 5, 'the five are a class of their own')
  T.eq(#W.find_events('GHOSTS'), 0, 'no class-A wake for bodies no dwarf can reach')
  local ins = W.inbox('inspect', {what = 'tombs'})
  T.ok(ins.ok, ins.msg)
  for _, e in ipairs(ins.data.unburied) do T.eq(e.why, 'corpse_unreachable') end
  T.eq(ins.data.far_n, 5)
  T.eq(ins.data.unreach_n, 5)
  T.ok(ins.msg:find('5 unreachable', 1, true), ins.msg)
end)

T.test('BUG-105: a tile without a walk group is unreachable too; a body in another walk group stays corpse_far and counts as ' ..
       'old; a body in the fort counts as before', function()
  local W = crown_world{setup = function(W)
    dead(W, 6100); corpse(W, 6100, {135, 64, 133})                  -- group 0: nothing walks there
    dead(W, 6101); corpse(W, 6101, {110, 64, 133})                  -- group 859 on a floor: an old battlefield
    dead(W, 6102); corpse(W, 6102, {5, 5, 5})                       -- in the fort
  end}
  CW.day(W, 4)
  local c = W.state().care
  T.eq({c.corpses_old, c.corpses_unreach}, {2, 1}, 'far and fort bodies are old, group 0 is unreachable')
  local ins = W.inbox('inspect', {what = 'tombs'})
  local why = {}
  for _, e in ipairs(ins.data.unburied) do why[e.u] = e.why end
  T.eq(why[6100], 'corpse_unreachable')
  T.eq(why[6101], 'corpse_far')
  local g = W.find_events('GHOSTS')
  T.eq(#g, 1)
  T.eq(g[1].d.old, 2)
end)

T.test('BUG-105: a ghost whose body lies in a crown is named corpse_unreachable (a slab lays it to rest)', function()
  local W = crown_world{setup = function(W)
    dead(W, 6100, true); corpse(W, 6100, {121, 64, 133})
  end}
  CW.day(W, 2)
  local g = W.find_events('GHOSTS')
  T.eq(#g, 1)
  T.eq(g[1].d.causes, {'6100:corpse_unreachable'})
  T.eq({g[1].d.ghosts, g[1].d.old}, {1, 0})
  T.ok(g[1].msg:find('slab for corpse_unreachable', 1, true), g[1].msg)
  T.ok(#g[1].msg <= 200)
end)

T.test('BUG-105: without the walk-group hooks nothing is unreachable (no guess), and the reach hook alone keeps corpse_far', function()
  local units = {}
  for i = 0, 3 do units[#units + 1] = {id = 6100 + i, citizen = true, pos = {5, 5, 5}} end
  local W = CW.world{cit = 4, units = units, reach = function(a, b) return not (a.x >= 100 or b.x >= 100) end,
    setup = function(W) dead(W, 6100); corpse(W, 6100, {121, 64, 133}) end}
  CW.day(W, 4)
  local c = W.state().care
  T.eq({c.corpses_old, c.corpses_unreach}, {1, nil}, 'groups and tile unknown: the old BUG-062 answer, corpse_far')
  local ins = W.inbox('inspect', {what = 'tombs'})
  T.eq(ins.data.unburied[1].why, 'corpse_far')
  T.eq({ins.data.far_n, ins.data.unreach_n}, {1, 0}, 'the document says there are none')
end)
T.done()
