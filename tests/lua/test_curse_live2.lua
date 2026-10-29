-- The live test round 2 of the curse package (i2, DF 53.16 / DFHack 53.16-r3, E:/DF-test2, y721): BUG-172 (no `curse` in
-- the state after a reload until care's first full run), BUG-173 (inspect what=unit: the real name with a nickname set,
-- empty ANYTHING emotion slots, blood_pct of the dead), BUG-174 (CURSE_MOON and curse_kill held by the 600 s wall gate),
-- BUG-175 (a wave of one tick split in two, dead units named, bite of a syndrome-found unit), BUG-176 (a 40-byte name cut
-- inside an epithet: the record never matched), BUG-178 (cur.ev persisted as a json array). Every test here fails on the
-- commit before the package (b805745).
local T = require('testlib')
local CW = require('care_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

local ANY = 'CARAVAN_ARRIVAL'
local RAWS = {[1] = {name = {[0] = 'dwarf'}, creature_id = 'DWARF'},
              [2] = {name = {[0] = 'werecavy'}, creature_id = 'NIGHT_CREATURE_36'}}
local NAMES = {'Olon Gatizbomrek "Fondlewhipped", Axe Lord', 'Urvad Kubukarban "Lancedcradles", Planter',
               'Lorbam Ekastreg "Savedglove", Miner', 'Shem Kikrost "Bellowedears", Cook', 'Mosus Avuz "Oakenfist", Mason',
               'Zon Ushat "Gravelbell", Brewer'}

local function world(opts)
  opts = opts or {}
  local W, care = CW.world{cit = opts.cit or 6}
  df.creature_raw = {find = function(id) return RAWS[id] end}
  for i = 1, opts.cit or 6 do
    local u = W.unit(i)
    u.race = 1
    u._m.name = NAMES[i] or ('Dwarf Number' .. i .. ' "Nick' .. i .. '", Laborer')
    u._m.stress = 3
  end
  return W, care
end

local function events(W, t) return W.find_events(t) end
local function kills(W)
  local q = {}
  for _, x in ipairs(events(W, 'DECISION_NEEDED')) do if x.d.id == 'curse_kill' then q[#q + 1] = x end end
  return q
end
local function ytime() return df.global.cur_year, df.global.cur_year_tick end

---------------------------------------------------------------- BUG-172
T.test('BUG-172: after a reload the state carries `curse` at once, before care\'s first full run', function()
  local W = world()
  W.event('REPORT', {type = ANY, text = 'Olon Gatizbomrek, Axe Lord has been cursed by Risen!'})
  W.run(3)
  CW.day(W, 1)
  T.eq(W.state().curse.n, 1)
  W.mods.care.M.init(W.K)                                   -- a reload: care's run and the curse library start empty
  local s = W.state()
  T.ok(type(s.curse) == 'table', 'live: no `curse` and no CURSED line for 27 game days')
  T.eq({s.curse.n, s.curse.ids}, {1, {1}})
  T.eq(s.care, nil, 'care\'s own values still wait for its run')
end)

---------------------------------------------------------------- BUG-173
T.test('BUG-173: inspect what=unit finds a unit whose nickname replaced the first name by the real first and last name; '
       .. 'a report naming the real name resolves to him', function()
  local W = world()
  local u = W.unit(3)
  u._m.name = "`Blinky' Savotdumat, Miner"
  u.name = {first_name = 'Rig\xC3\xB2th', nickname = 'Blinky', _last = 'Savotdumat'}
  dfhack.translation = {translateName = function(n, eng, only_last)
    return only_last and n._last or (n.first_name .. ' ' .. n._last)
  end}
  local r = W.inbox('inspect', {what = 'unit', key = 'Rig\xC3\xB2th Savotdumat'})
  T.ok(r.ok, r.msg)
  T.eq(r.data.id, 3, 'live: no such citizen')
  T.eq(W.inbox('inspect', {what = 'unit', key = 'Rig\xC3\xB2th'}).data.id, 3, 'the real first name of one citizen')
  W.event('REPORT', {type = ANY, text = 'Rig\xC3\xB2th Savotdumat, Miner has been cursed by Risen!'})
  W.run(3)
  T.eq(events(W, 'CURSED')[1].d.unit, 3)
end)

T.test('BUG-173: thoughts skip the empty ANYTHING slots and come newest first by year and tick; no blood_pct for the '
       .. 'dead or without a blood count', function()
  local W = world()
  local u = W.unit(2)
  df.unit_thought_type = {[5] = 'Conflict', [6] = 'SawDeadBody', [7] = 'Rain'}
  df.emotion_type = {[-1] = 'ANYTHING', [2] = 'ANGER', [3] = 'GRIEF'}
  local em = {{thought = 6, type = 3, strength = 20, year = 721, year_tick = 500},      -- the newest
              {thought = 7, type = 2, strength = 5, year = 719, year_tick = 9000},
              {thought = 5, type = 2, strength = 10, year = 720, year_tick = 100}}
  for _ = 1, 5 do em[#em + 1] = {thought = -1, type = -1, strength = 0, year = 717, year_tick = 0} end   -- empty slots
  em[#em + 1] = {thought = -1, type = 2, strength = 0, year = 722, year_tick = 1}       -- no thought, no strength
  u.status = {current_soul = {personality = {stress = 0, emotions = kmock.vec(em)}}}
  u.body = {wounds = kmock.vec{}, blood_count = 50, blood_max = 0}
  local r = W.inbox('inspect', {what = 'unit', key = '2'})
  T.eq(r.data.thoughts, {'SawDeadBody', 'Conflict', 'Rain'}, 'live: every list began with ANYTHING')
  T.eq(r.data.blood_pct, nil, 'no blood_max')
  u.body.blood_count, u.body.blood_max = -1, 100
  W.kill(2)
  r = W.inbox('inspect', {what = 'unit', key = '2'})
  T.eq(r.data.blood_pct, nil, 'live: a dead unit read blood_pct -1')
end)

---------------------------------------------------------------- BUG-174
T.test('BUG-174: CURSE_MOON before every full moon and curse_kill for every new set of were-forms, within ten real '
       .. 'minutes (timestream speed)', function()
  local W = world()
  local CU = require('dfllm.curse')
  W.event('REPORT', {type = ANY, text = 'Olon Gatizbomrek, Axe Lord has been cursed by Risen!'})
  W.run(3)
  local wall0 = W.K.now().wall
  for moon = 1, 2 do
    local _, _, nxt = CU.moon(W.K.now().tick, 13)
    local want = nxt - 3 * 1200
    df.global.cur_year_tick = want % 403200
    df.global.cur_year = want // 403200
    CW.day(W, 1)
    T.eq(#events(W, 'CURSE_MOON'), moon, 'live: moons 2, 3 and 5 had no CURSE_MOON')
    CW.day(W, 4)
  end
  W.event('REPORT', {type = ANY, text = 'Olon Gatizbomrek, Axe Lord has transformed into a werecavy!'})
  W.run(3)
  T.eq(#kills(W), 1)
  W.event('REPORT', {type = ANY, text = 'Olon Gatizbomrek, Axe Lord has transformed into a dwarf!'})
  CW.day(W, 3)
  W.event('REPORT', {type = ANY, text = 'Lorbam Ekastreg, Miner has transformed into a werecavy!'})
  W.run(3)
  T.eq(#kills(W), 2, 'live: no curse_kill for the d77, d155 and d181 waves')
  T.ok(W.K.now().wall - wall0 < 600, 'all within the old wall gate')
end)

---------------------------------------------------------------- BUG-175
-- the reports of one wave: in DF they all stand in the report list (with the same year and time) before kern delivers them
local function wave(W, list)
  local y, t = ytime()
  for _, x in ipairs(list) do
    df.global.world.status.reports:insert('#', {id = x[1], type = df.announcement_type[ANY], text = x[2], year = y, time = t})
  end
  for _, x in ipairs(list) do W.event('REPORT', {id = x[1], type = ANY, text = x[2]}) end
end

T.test('BUG-175: the reports of one tick go out as one TRANSFORM and one curse_kill naming the whole wave', function()
  local W = world()
  wave(W, {{901, 'Olon Gatizbomrek, Axe Lord has transformed into a werecavy!'},
           {902, 'Lorbam Ekastreg, Miner has transformed into a werecavy!'},
           {903, 'Shem Kikrost, Cook has transformed into a werecavy!'}})
  W.run(3)
  CW.day(W, 1)
  local t = events(W, 'TRANSFORM')
  T.eq(#t, 1, 'live: the first unit alone, the rest 1199 ticks later')
  T.eq({t[1].d.n, t[1].d.ids, t[1].d.more}, {3, {1, 3, 4}, 2})
  local q = kills(W)
  T.eq(#q, 1)
  T.eq(q[1].d.n, 3, 'live: the question named the first unit only')
end)

T.test('BUG-175: a queued transformation of a unit that died before it went out is not named, nor counted', function()
  local W = world()
  W.event('REPORT', {type = ANY, text = 'Olon Gatizbomrek, Axe Lord has transformed into a werecavy!'})
  W.run(5)
  T.eq(#events(W, 'TRANSFORM'), 1)
  wave(W, {{911, 'Lorbam Ekastreg, Miner has transformed into a werecavy!'},
           {912, 'Shem Kikrost, Cook has transformed into a werecavy!'}})
  W.run(3)                                                  -- within curse_every: queued
  T.eq(#events(W, 'TRANSFORM'), 1)
  W.kill(3)
  CW.day(W, 1)
  local t = events(W, 'TRANSFORM')
  T.eq(#t, 2)
  T.eq({t[2].d.unit, t[2].d.ids, t[2].d.n}, {4, {4}, 2}, 'live: 5 of the 7 named units were dead, "4 were-form"')
  T.ok(t[2].msg:find('1 more died first', 1, true), t[2].msg)
end)

T.test('BUG-175: a unit found by the bite\'s syndrome (src syndrome) carries bite=1 when he transforms', function()
  local W = world()
  df.creature_interaction_effect_type = {BODY_TRANSFORMATION = 3}
  df.syndrome = {find = function(id) return id == 9 and {ce = kmock.vec{{getType = function() return 3 end}}} or nil end}
  W.unit(5).curse_year, W.unit(5).syndromes = 721, {active = kmock.vec{{type = 9}}}
  CW.day(W, 1)
  T.eq(#events(W, 'CURSED'), 1)
  W.event('REPORT', {type = ANY, text = 'Mosus Avuz, Mason has transformed into a werecavy!'})
  W.run(3)
  local t = events(W, 'TRANSFORM')
  T.eq({#t, t[1].d.unit, t[1].d.bite}, {1, 5, 1}, 'live: bite only when no record matched')
end)

---------------------------------------------------------------- BUG-176
T.test('BUG-176: a name longer than 40 bytes (an epithet in quotes) still matches its report; his death leaves no phantom '
       .. 'were-form', function()
  local W = world()
  W.unit(4)._m.name = 'Kumil Akrul\xC3\xB4nam Dalkamennol Kad\xC3\xB4l "Tinshimmer the Lean Reputation of Gems", '
                      .. 'Werecavy Planter'
  W.event('REPORT', {type = ANY, text = 'Kumil Akrul\xC3\xB4nam Dalkamennol Kad\xC3\xB4l, Planter has transformed into a werecavy!'})
  W.run(3)
  local t = events(W, 'TRANSFORM')
  T.eq(t[1].d.unit, 4, 'live: "1 by name only (no unit matched)"')
  T.eq(W.inbox('inspect', {what = 'curse'}).data.unresolved, nil)
  W.kill(4)
  CW.day(W, 1)
  T.eq(W.state().curse, nil, 'live: a dead unit stayed "1 in were-form"')
end)

---------------------------------------------------------------- BUG-178
T.test('BUG-178: cur.ev read back as an empty json array keeps the moon and kill records when saved', function()
  local CU = require('dfllm.curse')
  local p = {cur = json.decode('{"u":{},"ev":[],"dead":0}')}
  local c = CU.cur(p)
  c.ev.moon = {t = 5, w = 6, ids = {1}, toks = {'m26'}}
  local back = json.decode(json.encode(p.cur))
  T.eq(back.ev.moon.t, 5, 'live: "ev":[] although CURSE_MOON had marked it')
end)

T.test('BUG-178: after a reload the moon is not announced again for the same day (the cadence record survived)', function()
  local W = world()
  local CU = require('dfllm.curse')
  W.K.persist.get('m.care').cur = json.decode('{"u":{},"ev":[],"dead":0}')     -- an earlier boot saved no record yet
  W.event('REPORT', {type = ANY, text = 'Olon Gatizbomrek, Axe Lord has been cursed by Risen!'})
  W.run(3)
  local _, _, nxt = CU.moon(W.K.now().tick, 13)
  local want = nxt - 3 * 1200
  df.global.cur_year_tick = want % 403200
  df.global.cur_year = want // 403200
  CW.day(W, 1)
  T.eq(#events(W, 'CURSE_MOON'), 1)
  local raw = json.encode(W.K.persist.get('m.care'))
  W.K.persist.get('m.care').cur = json.decode(raw).cur     -- what a load reads back
  W.mods.care.M.init(W.K)
  CW.day(W, 1)
  T.eq(#events(W, 'CURSE_MOON'), 1, 'live: CURSE_MOON and curse_kill came again as "first" after every load')
end)

T.done()
