-- The live test i2 of the curse package (DF 53.16 / DFHack 53.16-r3, E:/DF-test2, y717): BUG-134 (nicknames: every record
-- stayed 'n:<name>', no ids, no curse_kill, the dead never forgotten; a popup naming nobody stayed for good), BUG-135
-- (`unit.curse` does not exist in 53.16), BUG-136 (the curse logic starved by care's paced full run: no CURSE_MOON, a frozen
-- moon in the state, a missed wave), BUG-137 (inspect what=unit: thoughts and wounds never read, mood None, names),
-- BUG-138 (ann POPUP, a TRANSFORM with the curse's type). Every test here fails on the commit before the package (dec5132).
local T = require('testlib')
local CW = require('care_world')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local ANY = 'CARAVAN_ARRIVAL'
local RAWS = {[1] = {name = {[0] = 'dwarf'}, creature_id = 'DWARF'},
              [2] = {name = {[0] = 'werecavy'}, creature_id = 'NIGHT_CREATURE_36'}}

-- the live names: every citizen has a nickname (51 of 51 on i2)
local NAMES = {'Olon Gatizbomrek "Fondlewhipped", Axe Lord', 'Urvad K\xC3\xBBbukarban "Lancedcradles", Planter',
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
local function records(W)
  local n = 0
  for _ in pairs(W.K.persist.get('m.care').cur.u) do n = n + 1 end
  return n
end

---------------------------------------------------------------- BUG-134: names
T.test('BUG-134: the game names a nicknamed citizen without the nickname: CURSED and TRANSFORM carry his id, curse_kill '
       .. 'is asked, the sheet adds no second record, his death clears the list', function()
  local W = world()
  W.event('REPORT', {type = ANY, text = 'Olon Gatizbomrek, Axe Lord has been cursed by R\xC3\xAEsen!'})
  W.run(3)
  local e = events(W, 'CURSED')
  T.eq(#e, 1)
  T.eq({e[1].d.unit, e[1].d.ids}, {1, {1}}, 'live: no d.unit and no d.ids')
  T.eq(W.state().curse.ids, {1})
  W.event('REPORT', {type = ANY, text = 'Olon Gatizbomrek, Axe Lord has transformed into a werecavy!'})
  W.run(3)
  local t = events(W, 'TRANSFORM')
  T.eq({#t, t[1].d.unit}, {1, 1})
  T.eq(#kills(W), 1, 'live: no DECISION_NEEDED curse_kill after two beast waves')
  T.ok(kills(W)[1].d.q:find('(1)', 1, true), kills(W)[1].d.q)
  W.unit(1).race = 2                                       -- the sheet shows the were-form: the same record
  CW.day(W, 1)
  T.eq({records(W), #events(W, 'CURSED')}, {1, 1})
  W.kill(1)
  CW.day(W, 1)
  T.eq(W.state().curse, nil, 'live: the dead werecavy counted as "1 in were-form" for months')
  local r = W.inbox('inspect', {what = 'curse'})
  T.eq({r.data.cursed, r.data.transformed, r.data.dead}, {0, 0, 1})
end)

T.test('BUG-134: a name in CP437 (not converted) matches the citizen\'s UTF-8 name', function()
  local W = world()
  local orig = dfhack.df2utf
  dfhack.df2utf = function(s) return (tostring(s):gsub('\x96', '\xC3\xBB')) end      -- CP437 0x96 = u circumflex
  W.K.call('care', 'curse_text', 'Urvad K\x96bukarban, Planter has been cursed by Risen!')
  W.run(3)
  dfhack.df2utf = orig
  local e = events(W, 'CURSED')
  T.eq(#e, 1)
  T.eq(e[1].d.unit, 2)
  T.eq(e[1].d.name, 'Urvad K\xC3\xBBbukarban')
end)

T.test('BUG-134 (i1): a curse popup naming no unit is listed by name only and expires after one moon cycle', function()
  local W = world()
  W.K.call('care', 'curse_text', 'Urist McTest has been cursed to prowl the night!')
  W.run(3)
  T.eq(#events(W, 'CURSED'), 1)
  T.eq(W.state().curse.n, 1)
  local r = W.inbox('inspect', {what = 'curse'})
  T.eq(r.data.unresolved, {'Urist McTest'})
  T.ok(r.msg:find('by name only', 1, true), r.msg)
  CW.day(W, 28)
  T.eq(W.state().curse, nil, 'i1: CURSED 1 stood for good and `next` kept offering the brief')
  r = W.inbox('inspect', {what = 'curse'})
  T.eq({r.data.cursed, r.data.dead, r.data.unresolved}, {0, 0, nil}, 'not counted as dead either')
end)

---------------------------------------------------------------- BUG-135: the sheet of 53.16
T.test('BUG-135: the sheet is read from the fields DF 53.16 has: uwss_* for a shown curse, curse_year with a '
       .. 'body-transformation syndrome for a were-curse before its first moon; unit.curse is never read', function()
  local W = world()
  df.creature_interaction_effect_type = {BODY_TRANSFORMATION = 3}
  local SYN = {[7] = {ce = kmock.vec{{getType = function() return 3 end}}},          -- DEITY_CURSE_WEREBEAST_cavy_1
               [8] = {ce = kmock.vec{{getType = function() return 1 end}}}}          -- a curse without a transformation
  df.syndrome = {find = function(id) return SYN[id] end}
  W.unit(1).curse = {name = 'werecavy', name_visible = true}       -- the old struct: 'Cannot read field unit.curse' live
  W.unit(2).uwss_use_display_name, W.unit(2).uwss_display_name_sing = true, 'vampire'
  W.unit(3).uwss_use_display_name, W.unit(3).uwss_display_name_sing = false, 'vampire'     -- hidden: stays hidden
  W.unit(4).curse_year, W.unit(4).syndromes = 717, {active = kmock.vec{{type = 7}}}
  W.unit(5).curse_year, W.unit(5).syndromes = 700, {active = kmock.vec{{type = 8}}}      -- not a were-curse
  CW.day(W, 2)
  local e = events(W, 'CURSED')
  local got = {}
  for _, x in ipairs(e) do
    for _, id in ipairs(x.d.ids or {x.d.unit}) do got[#got + 1] = id end
  end
  table.sort(got)
  T.eq(got, {2, 4})
  local r = W.inbox('inspect', {what = 'curse'})
  local by = {}
  for _, x in ipairs(r.data.units) do by[x.id] = x end
  T.eq({by[2].kind, by[2].src, by[4].kind, by[4].src}, {'vampire', 'sheet', 'were', 'syndrome'})
  local u4 = W.inbox('inspect', {what = 'unit', key = '4'})
  T.eq({u4.data.curse.were, u4.data.curse.tf}, {1, 0})
end)

---------------------------------------------------------------- BUG-136: not starved by pacing
T.test('BUG-136: care demoted so far that its full run never comes: the daily watch still sees the wave, asks '
       .. 'CURSE_MOON in time and publishes the moon of today', function()
  local W = world()
  W.event('REPORT', {type = ANY, text = 'Olon Gatizbomrek, Axe Lord has been cursed by Risen!'})
  W.run(3)
  CW.day(W, 1)
  W.mods.care.factor = 512                                -- live: 'care demoted x8', runs 10-31 game days apart
  CW.day(W, 1)
  local CU = require('dfllm.curse')
  local _, _, nxt = CU.moon(W.K.now().tick, 13)
  local want = nxt - 6 * 1200
  df.global.cur_year_tick = want % 403200
  df.global.cur_year = want // 403200
  CW.day(W, 1)
  local s = W.state().curse
  T.eq(s.mi, ({CU.moon(W.K.now().tick, 13)})[2], 'live: status showed a moon 20 days past')
  T.eq(#events(W, 'CURSE_MOON'), 0, 'not yet: 5 days')
  CW.day(W, 2)
  T.eq(#events(W, 'CURSE_MOON'), 1, 'live: no CURSE_MOON over three moons')
  W.unit(1).race = 2
  CW.day(W, 1)
  local t = events(W, 'TRANSFORM')
  T.eq({#t, t[1].d.unit, t[1].d.ann}, {1, 1, 'sheet'}, 'live: the d77 wave went unseen')
end)

T.test('BUG-136: a citizen bitten (curse_year, were syndrome) is found by the daily watch before his first moon', function()
  local W = world()
  df.creature_interaction_effect_type = {BODY_TRANSFORMATION = 3}
  df.syndrome = {find = function(id) return id == 9 and {ce = kmock.vec{{getType = function() return 3 end}}} or nil end}
  CW.day(W, 1)
  W.mods.care.factor = 512
  CW.day(W, 1)
  W.unit(6).curse_year, W.unit(6).syndromes = 717, {active = kmock.vec{{type = 9}}}
  CW.day(W, 1)
  local e = events(W, 'CURSED')
  T.eq(#e, 1)
  T.eq({e[1].d.unit, e[1].d.ann, e[1].d.kind}, {6, 'syndrome', 'were'})
end)

---------------------------------------------------------------- BUG-138: the announcement type
T.test('BUG-138: a curse popup carries the type of its report, else DEITY_CURSE; a TRANSFORM carries its own type', function()
  local W = world()
  local text = 'Olon Gatizbomrek, Axe Lord has been cursed by Risen!'
  df.global.world.status.reports:insert('#', {id = 990, type = df.announcement_type[ANY], text = text})
  W.K.call('care', 'curse_text', text)
  W.run(3)
  T.eq(events(W, 'CURSED')[1].d.ann, ANY, 'live: ann=POPUP')
  W.K.call('care', 'curse_text', 'Lorbam Ekastreg, Miner has been cursed by Risen!')
  CW.day(W, 1)
  T.eq(events(W, 'CURSED')[2].d.ann, 'DEITY_CURSE', 'the type DF 53.16 uses for the curse (no report yet)')
  W.event('REPORT', {type = 'BODY_TRANSFORMATION', text = 'Lorbam Ekastreg, Miner has transformed into a werecavy!'})
  W.run(3)
  T.eq(events(W, 'TRANSFORM')[1].d.ann, 'BODY_TRANSFORMATION', 'live: the curse\'s DEITY_CURSE')
end)

---------------------------------------------------------------- BUG-137: inspect what=unit
T.test('BUG-137: inspect what=unit reads the thoughts (0-based emotions), the bleeding wound parts, no mood -1, '
       .. 'a late spouse, DEAD, and finds the unit by name without the nickname or by the first name', function()
  local W = world()
  local u = W.unit(3)
  df.unit_thought_type = {[5] = 'Conflict'}
  df.emotion_type = {[2] = 'ANGER'}
  df.mood_type[-1] = 'None'
  u.status = {current_soul = {personality = {stress = 100, emotions = kmock.vec{{thought = -1, type = 2}, {thought = 5, type = 1}}}}}
  u.body = {wounds = kmock.vec{{parts = kmock.vec{{bleeding = 0}, {bleeding = 2}}}, {parts = kmock.vec{{bleeding = 0}}}},
            blood_count = 50, blood_max = 100}
  u.mood = -1
  u.hist_figure_id = 77
  df.histfig_hf_link_type = {[9] = 'DECEASED_SPOUSE'}
  df.historical_figure = {find = function(id)
    if id == 77 then return {histfig_links = kmock.vec{{getType = function() return 9 end, target_hf = 78}}} end
  end}
  local r = W.inbox('inspect', {what = 'unit', key = 'Lorbam Ekastreg'})
  T.ok(r.ok, r.msg)
  local d = r.data
  T.eq(d.id, 3)
  T.eq(d.thoughts, {'Conflict', 'ANGER'}, 'newest first; live: unread thoughts')
  T.eq(d.wound, {n = 2, bleed = 1}, 'live: unread wounds')
  T.eq(d.mood, nil, 'mood -1 is no mood')
  for _, m in ipairs(d.unread or {}) do T.ok(m ~= 'thoughts' and m ~= 'wounds' and m ~= 'relatives', m) end
  T.eq(d.rel, {{role = 'late spouse', hf = 78}})
  T.eq(W.inbox('inspect', {what = 'unit', key = 'Lorbam Ekastreg "Savedglove"'}).data.id, 3)
  T.eq(W.inbox('inspect', {what = 'unit', key = 'Lorbam'}).data.id, 3, 'the first name of one citizen')
  W.kill(3)
  r = W.inbox('inspect', {what = 'unit', key = '3'})
  T.ok(r.msg:find('Miner, DEAD:', 1, true), r.msg)
end)

T.test('BUG-137: a name is found before the first census (paused after a load): sense.own_ids', function()
  local W = world()
  local SE = require('dfllm.sense')
  W.load({name = 'sense', every = {ticks = 10000000}, own_ids = SE.own_ids})     -- the real reader, no census scan
  W.set_census('u', F.census_u({}))
  local r = W.inbox('inspect', {what = 'unit', key = 'Shem Kikrost'})
  T.ok(r.ok, r.msg)
  T.eq(r.data.id, 4)
end)

T.done()
