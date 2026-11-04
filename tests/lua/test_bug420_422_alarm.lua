-- BUG-421 (Run 16d i4 Mazelanterns y386: a wild platybelodon, no LARGE_PREDATOR flag, struck down two citizens inside the
-- fort; no PREDATOR, threat 0): a wild unit that killed a citizen is a large predator for sense from then on.
-- BUG-422 (the same fort, autumn: a citizen died of thirst with 766 days of drink, no THIRSTY wake): economy's
-- DECISION_NEEDED thirst_unit for ONE citizen over SOLO_THIRST / SOLO_HUNGER.
-- (BUG-420's station fallback is tested in test_stations.lua.)
local T = require('testlib')
local S = require('siege_world')
local F = require('wp8_world')
local SW = require('seal_world')

T.test('BUG-421 sense: a wild grazer is no hostile until it killed a citizen (mark_killer); then k danger, pr 1, kl 1, ' ..
       'ALERT; a citizen or a tame unit is never marked', function()
  local function world(mark)
    local W = S.world{units = {S.cit(1, 60, 70), {id = 300, pos = {60, 25, S.Z}, animal = true},
                               {id = 301, pos = {61, 25, S.Z}, animal = true, tame = true}}}
    df.creature_raw = {find = function() return {caste = {[0] = {flags = {}}}} end}      -- no LARGE_PREDATOR
    W.unit(300).race, W.unit(300).caste = 1, 0
    W.unit(301).race, W.unit(301).caste = 1, 0
    dfhack.maps.getWalkableGroup = function() return 7 end
    S.load(W, {S.military(), SW.fake('seal', {entrances = function() return {{51, 10, S.Z}}, 25 end})})
    S.run(W, 300)
    if mark then
      T.eq({W.K.call('sense', 'mark_killer', 300)}, {true, true})
      T.eq({W.K.call('sense', 'mark_killer', 1)}, {true, false}, 'a citizen is never a killer to hunt')
      T.eq({W.K.call('sense', 'mark_killer', 301)}, {true, false}, 'a tame unit neither')
      S.run(W, 300)
    end
    return W
  end
  local W = world(false)
  T.eq({W.K.mode(), W.K.census.h.vis}, {'PEACE', 0}, 'old behaviour: a grazer is wildlife')
  local W2 = world(true)
  T.eq({W2.K.mode(), W2.K.census.h.vis}, {'ALERT', 1}, 'it killed: a wild danger within reach of the fort')
  local e = W2.K.census.h.list[1]
  T.eq({e.id, e.k, e.pr, e.kl}, {300, 'danger', 1, 1})
end)

T.test('BUG-422 economy: ONE citizen over SOLO_THIRST is a DECISION_NEEDED thirst_unit with the drink stock and why; ' ..
       'again after SOLO_EVERY; none for a citizen below the mark', function()
  local units = {}
  for i = 1, 10 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  local ids = {}
  for i = 1, 10 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  for _ = 1, 3 do F.item(W, 'DRINK', {stack_size = 400}) end
  local E = require('dfllm.economy')
  package.loaded['dfllm.economy'] = nil
  E = require('dfllm.economy')
  W.load(E)
  local function wakes()
    local r = {}
    for _, ev in ipairs(W.find_events('DECISION_NEEDED')) do if ev.d.id == 'thirst_unit' then r[#r + 1] = ev end end
    return r
  end
  local function day(n) for _ = 1, n do W.run(1200, {skip = 100}); for _ = 1, 40 do W.run(1) end end end
  W.unit(4).counters2 = {thirst_timer = 49000, hunger_timer = 0}
  day(1)
  T.eq(#wakes(), 0, 'thirst 49000: below the mark')
  W.unit(4).counters2 = {thirst_timer = 62000, hunger_timer = 87000}
  day(1)
  local w = wakes()
  T.eq(#w, 1, 'one citizen is enough (alarm.units is 2)')
  T.eq({w[1].cls, w[1].d.units}, {'A', {4}})
  T.ok(w[1].d.q:find('4 (thirst 62000, hunger 87000', 1, true), w[1].d.q)
  T.ok(w[1].d.q:find('job ', 1, true) or w[1].d.q:find('no job', 1, true), 'why: his job')
  T.eq(w[1].d.cmds[1], 'dfllm cmd inspect what=unit key=4')
  day(1)
  T.eq(#wakes(), 1, 'not again within SOLO_EVERY')
  day(3)
  T.eq(#wakes(), 2, 'again after three days while he stays over the mark')
  W.unit(4).counters2 = {thirst_timer = 0, hunger_timer = 0}
  day(4)
  T.eq(#wakes(), 2, 'he drank: quiet')
end)

T.test('BUG-421 care: a citizen killed by a wild unit (death incident criminal) is passed to sense.mark_killer; a death ' ..
       'without a killer is not', function()
  local CW = require('care_world')
  local incidents, marked = {}, {}
  local W = CW.world{cit = 3, units = {{id = 77, animal = true}}, setup = function(W)
    df.incident = {find = function(id) return incidents[id] end}
    for i = 1, 3 do
      local u = W.unit(i)
      u.counters = {death_cause = -1, death_id = -1}
      u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
      u.name = {first_name = 'dwarf' .. i, nickname = ''}
    end
    W.load({name = 'sense', every = {ticks = 1200}, mark_killer = function(K, id) marked[#marked + 1] = id; return true end})
  end}
  W.run(1)
  local function die(id, killer)
    W.kill(id)
    W.unit(id).counters.death_id = 500 + id
    incidents[500 + id] = {death_cause = df.death_type.STRUCK_DOWN, criminal = killer or -1, flags = {discovered = true}}
    W.event('UNIT_DEATH', {unit = id})
  end
  die(1, 77)
  die(2)
  W.run(1)
  T.eq(marked, {77})
end)

T.done()
