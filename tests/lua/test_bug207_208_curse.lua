-- Live test round 3 of the curse package (fresh fort and i-instances, kernel bd27973): BUG-207 (inspect what=unit by the
-- nickname the sheet shows; the bare last name no longer a key), BUG-208 (a set of were-forms that grew inside the
-- 2400-tick kill gate got no curse_kill). Four tests fail on bd27973; two are guards (a report naming the unit as the sheet
-- does still resolves; an unchanged set is asked once).
local T = require('testlib')
local CW = require('care_world')

local ANY = 'CARAVAN_ARRIVAL'
local RAWS = {[1] = {name = {[0] = 'dwarf'}, creature_id = 'DWARF'},
              [2] = {name = {[0] = 'werecavy'}, creature_id = 'NIGHT_CREATURE_36'}}
local NAMES = {'Olon Gatizbomrek "Fondlewhipped", Axe Lord', 'Urvad Kubukarban "Lancedcradles", Planter',
               'Lorbam Ekastreg "Savedglove", Miner', 'Shem Kikrost "Bellowedears", Cook', 'Mosus Avuz "Oakenfist", Mason',
               'Zon Ushat "Gravelbell", Brewer'}

local function world()
  local W, care = CW.world{cit = 6}
  df.creature_raw = {find = function(id) return RAWS[id] end}
  for i = 1, 6 do
    local u = W.unit(i)
    u.race = 1
    u._m.name = NAMES[i]
    u._m.stress = 3
  end
  return W, care
end
local function kills(W)
  local q = {}
  for _, x in ipairs(W.find_events('DECISION_NEEDED')) do if x.d.id == 'curse_kill' then q[#q + 1] = x end end
  return q
end

-- the reports of one wave stand in the report list with the same year and time before kern delivers them (BUG-175)
local function wave(W, list)
  local y, t = df.global.cur_year, df.global.cur_year_tick
  for _, x in ipairs(list) do
    df.global.world.status.reports:insert('#', {id = x[1], type = df.announcement_type[ANY], text = x[2], year = y, time = t})
  end
  for _, x in ipairs(list) do W.event('REPORT', {id = x[1], type = ANY, text = x[2]}) end
end

local function blinky(W)
  dfhack.translation = {translateName = function(n, eng, only_last)
    return only_last and n._last or (n.first_name .. ' ' .. n._last)
  end}
  local u = W.unit(3)
  u._m.name = "`Blinky' Imeshakrul \"Sprinkletin\", Peasant"
  u.name = {first_name = 'Astesh', nickname = 'Blinky', _last = 'Imeshakrul'}
  local r = W.unit(4)                                       -- his brother, no nickname
  r._m.name = 'Ber Imeshakrul "Sprinkletin", Cook'
  r.name = {first_name = 'Ber', nickname = '', _last = 'Imeshakrul'}
end

---------------------------------------------------------------- BUG-207
T.test('BUG-207: inspect what=unit finds a nicknamed unit by nickname + last name and by the nickname alone', function()
  local W = world()
  blinky(W)
  for _, key in ipairs({'Blinky Imeshakrul', 'Blinky', "`Blinky' Imeshakrul", 'Astesh Imeshakrul', 'Astesh', '3'}) do
    local r = W.inbox('inspect', {what = 'unit', key = key})
    T.ok(r.ok, key .. ': ' .. tostring(r.msg))
    T.eq(r.data and r.data.id, 3, key .. ' (live: "Blinky" and "Blinky Imeshakrul" -> no such citizen)')
  end
  T.eq(W.inbox('inspect', {what = 'unit', key = 'Ber Imeshakrul'}).data.id, 4)
end)

T.test('BUG-207: the bare last name is no key of a nicknamed unit (his relatives share it)', function()
  local W = world()
  blinky(W)
  local CU = require('dfllm.curse')
  local keys = CU.unit_keys(W.unit(3), W.mods.care.M.curse_env(), true)
  T.eq(keys, {'astesh imeshakrul', 'blinky imeshakrul', 'blinky'}, 'live: the keys were imeshakrul and astesh imeshakrul')
  T.ok(not W.inbox('inspect', {what = 'unit', key = 'Imeshakrul'}).ok, 'the family name names no single citizen')
end)

T.test('BUG-207: a report naming the unit by nickname + last name resolves to him', function()
  local W = world()
  blinky(W)
  W.event('REPORT', {type = ANY, text = 'Blinky Imeshakrul, Peasant has been cursed by Risen!'})
  W.run(3)
  T.eq(W.find_events('CURSED')[1].d.unit, 3)
end)

T.test('BUG-207 review: a report naming the unit as the sheet does ("`Blinky\' Imeshakrul") still resolves to him', function()
  local W = world()
  blinky(W)
  W.event('REPORT', {type = ANY, text = "`Blinky' Imeshakrul, Peasant has been cursed by Risen!"})
  W.run(3)
  local ev = W.find_events('CURSED')[1]
  T.eq(ev and ev.d.unit, 3, 'the report index keeps the sheet key (a shared one maps to false, no guess)')
end)

---------------------------------------------------------------- BUG-208
T.test('BUG-208: a third were-form 830 ticks after the curse_kill for two is asked about once the gate opens', function()
  local W = world()
  wave(W, {{901, 'Olon Gatizbomrek, Axe Lord has transformed into a werecavy!'},
           {902, 'Lorbam Ekastreg, Miner has transformed into a werecavy!'}})
  W.run(3)
  local t0 = W.K.now().tick
  T.eq(#kills(W), 1)
  T.eq(kills(W)[1].d.n, 2)
  W.run(137)
  W.event('REPORT', {type = ANY, text = 'Shem Kikrost, Cook has transformed into a werecavy!'})
  for _ = 1, 40 do
    if #W.find_events('TRANSFORM') >= 2 then break end
    W.run(50)
  end
  T.eq(#W.find_events('TRANSFORM'), 2, 'the second TRANSFORM went out')
  T.ok(W.K.now().tick - t0 < 2400, 'inside the kill gate: ' .. (W.K.now().tick - t0))
  T.eq(#kills(W), 1, 'the gate holds the question inside 2400 ticks')
  CW.day(W, 3)
  local q = kills(W)
  T.eq(#q, 2, 'live: no curse_kill through four moons')
  T.eq(q[2].d.n, 3)
  CW.day(W, 5)
  T.eq(#kills(W), 2, 'one question per set')
end)

T.test('BUG-208: an unchanged set is not asked about again at the daily pass', function()
  local W = world()
  W.event('REPORT', {type = ANY, text = 'Olon Gatizbomrek, Axe Lord has transformed into a werecavy!'})
  W.run(3)
  CW.day(W, 6)
  T.eq(#kills(W), 1)
end)

T.done()
