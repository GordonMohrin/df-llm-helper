-- care + dfllm.curse (BUG-115, FR-83, FR-84): curses and transformations were invisible (Run 14 y707: a miner toppled a
-- statue in a tantrum, "has been cursed by Ok!", became a werecavy, 23 dwarves followed, pop 54 -> 10; no event, no wake).
-- Every test here fails on the commit before the package (32994bb).
local T = require('testlib')
local CW = require('care_world')
local kmock = require('dfllm.util.k_mock')

-- an announcement type the care module does not list: the text alone must route the report (the type's name is unknown offline)
local ANY = 'CARAVAN_ARRIVAL'

local RAWS = {[1] = {name = {[0] = 'dwarf'}, creature_id = 'DWARF'},
              [2] = {name = {[0] = 'werecavy'}, creature_id = 'WERECAVY'}}

local function world(opts)
  opts = opts or {}
  local W, care = CW.world{cit = opts.cit or 6, mode = opts.mode, units = opts.units}
  df.creature_raw = {find = function(id) return RAWS[id] end}
  for i = 1, opts.cit or 6 do
    local u = W.unit(i)
    u.race = 1
    u._m.name = ({'Oddom Letmoscog, Miner', 'Kel Becordastot, Manager', 'Urist McMiner, Doctor', 'Shem Kikrost, Cook',
                  'Mosus Avuz, Mason', 'Zon Ushat, Brewer'})[i] or ('Dwarf Number' .. i .. ', Laborer')
    u._m.stress = 3
  end
  return W, care
end

local function events(W, t) return W.find_events(t) end

local function cursed_report(W, who, god, typ)
  W.event('REPORT', {type = typ or ANY, text = who .. ' has been cursed by ' .. god .. '!'})
end

---------------------------------------------------------------- the texts
T.test('BUG-115: the curse and transformation texts of Run 14 are parsed', function()
  local CU = require('dfllm.curse')
  local r = CU.parse('Oddom Letmoscog, Miner has been cursed by \xC3\x93k!')
  T.eq({r.kind, r.who, r.god}, {'cursed', 'Oddom Letmoscog', '\xC3\x93k'})
  r = CU.parse('Oddom Letmoscog has transformed into a werecavy!')
  T.eq({r.kind, r.who, r.to, r.dir}, {'transform', 'Oddom Letmoscog', 'werecavy', 'beast'})
  r = CU.parse('Oddom Letmoscog, Werecavy has transformed into a dwarf!')
  T.eq({r.kind, r.to, r.dir}, {'transform', 'dwarf', 'back'})
  T.eq(CU.parse('Urist McMiner has been struck down.'), nil)
  T.eq(CU.parse('The merchants have arrived.'), nil)
  T.eq(CU.parse(nil), nil)
end)

T.test('BUG-115: the next full moon: 13 a year from the new year, calibrated by the first wave seen', function()
  local CU = require('dfllm.curse')
  local YEAR = 403200
  local day, mi = CU.moon(100 * 1200, 13)
  T.eq({day, mi}, {104, 4}, 'k x year / 13: the 4th full moon (103.4 d) after day 100')
  day, mi = CU.moon(155 * 1200 + 5, 13, 155 * 1200)
  T.eq(mi, 26, 'a wave seen at d155: the next one about 26 days later')
  T.eq(({CU.moon(YEAR - 100, 13)})[1], 1, 'the next moon falls on the new year: day 1')
end)

---------------------------------------------------------------- the report route
T.test('BUG-115: "X has been cursed by <god>!" of ANY announcement type is CURSED (A) with the unit, the god and the trigger', function()
  local W = world()
  local u = W.unit(1)
  W.event('REPORT', {type = 'CITIZEN_TANTRUM', text = 'Oddom Letmoscog, Miner is throwing a tantrum!'})
  W.event('REPORT', {type = 'BUILDING_DESTROYED_OR_TOPPLED', text = 'The Statue was toppled by Oddom Letmoscog.',
                     pos = {x = 5, y = 5, z = 5}})
  W.run(3)
  cursed_report(W, 'Oddom Letmoscog, Miner', '\xC3\x93k')
  W.run(3)
  local e = events(W, 'CURSED')
  T.eq(#e, 1)
  T.eq(e[1].cls, 'A')
  T.eq({e[1].d.unit, e[1].d.god, e[1].d.n, e[1].d.ann, e[1].d.kind}, {1, '\xC3\x93k', 1, ANY, '?'})
  T.ok(e[1].d.trig:find('toppled Statue', 1, true), tostring(e[1].d.trig))
  T.ok(e[1].msg:find('Oddom Letmoscog cursed by \xC3\x93k (toppled Statue in a tantrum)', 1, true), e[1].msg)
  T.ok(e[1].msg:find('full moon ~d', 1, true), e[1].msg)
  T.ok(e[1].d.mi >= 0 and e[1].d.moon >= 1)
  local s = W.state().curse
  T.eq({s.n, s.tf, s.ids}, {1, 0, {1}})
  T.ok(s.mo >= 1 and s.mi >= 0)
  T.eq(u.id, 1)
end)

T.test('BUG-115: the same curse again (the popup after the report, a repeated report) is no news', function()
  local W, care = world()
  cursed_report(W, 'Oddom Letmoscog, Miner', 'Ok')
  W.run(3)
  cursed_report(W, 'Oddom Letmoscog, Miner', 'Ok')
  W.run(3)
  W.K.call('care', 'curse_text', 'Oddom Letmoscog, Miner has been cursed by Ok!')
  W.run(3)
  CW.day(W, 2)
  T.eq(#events(W, 'CURSED'), 1)
  T.eq(W.state().curse.n, 1)
end)

T.test('BUG-115: a burst of 23 curses: the first goes out at once, the rest merge into one event, the lists stay bounded', function()
  local W = world{cit = 30}
  for i = 1, 23 do W.unit(i)._m.name = 'Dwarf Number' .. i .. ', Laborer' end
  cursed_report(W, 'Dwarf Number1, Laborer', 'Ok')
  W.run(3)
  T.eq(#events(W, 'CURSED'), 1)
  for i = 2, 23 do cursed_report(W, 'Dwarf Number' .. i .. ', Laborer', 'Ok') end
  W.run(3)
  T.eq(#events(W, 'CURSED'), 1, 'inside curse_every: queued, not announced one by one')
  CW.day(W, 2)
  local e = events(W, 'CURSED')
  T.eq(#e, 2, 'one merged event for the other 22')
  T.eq({e[2].d.n, e[2].d.more, #e[2].d.ids}, {23, 21, 8})
  T.ok(e[2].msg:find('22 cursed', 1, true), e[2].msg)
  local s = W.state().curse
  T.eq({s.n, #s.ids}, {23, 8})
  T.ok(#W.K.persist.get('m.care').cur.u == 0 and next(W.K.persist.get('m.care').cur.u) ~= nil)
end)

T.test('BUG-115: more cursed than curse_keep: the record is bounded', function()
  local W = world{cit = 6}
  local c = require('dfllm.care').conf(W.K)
  local keep = c.curse_keep
  for i = 1, keep + 15 do cursed_report(W, 'Stranger' .. i .. ', Visitor', 'Ok') end
  W.run(3)
  CW.day(W, 1)
  local n = 0
  for _ in pairs(W.K.persist.get('m.care').cur.u) do n = n + 1 end
  T.eq(n, keep)
end)

---------------------------------------------------------------- the transformation
T.test('BUG-115: a transformation is TRANSFORM (A) and asks the kill question once; the moon is calibrated by the wave', function()
  local W = world()
  cursed_report(W, 'Oddom Letmoscog, Miner', 'Ok')
  W.run(3)
  W.event('REPORT', {type = ANY, text = 'Oddom Letmoscog, Miner has transformed into a werecavy!'})
  W.run(3)
  local e = events(W, 'TRANSFORM')
  T.eq(#e, 1)
  T.eq({e[1].cls, e[1].d.dir, e[1].d.to, e[1].d.unit, e[1].d.n, e[1].d.cursed}, {'A', 'beast', 'werecavy', 1, 1, 1})
  local q = {}
  for _, x in ipairs(events(W, 'DECISION_NEEDED')) do if x.d.id == 'curse_kill' then q[#q + 1] = x end end
  T.eq(#q, 1, 'the kill order stays the player\'s decision')
  T.ok(q[1].d.q:find('A kill order only with your yes', 1, true), q[1].d.q)
  local s = W.state().curse
  T.eq({s.n, s.tf, s.ids}, {0, 1, {1}})
  local r = W.inbox('inspect', {what = 'curse'})
  T.ok(r.ok, r.msg)
  T.eq(r.data.calibrated, 1, 'the wave fixed the moon')
  T.eq(r.data.units[1].tf, 1)
  W.event('REPORT', {type = ANY, text = 'Oddom Letmoscog, Werecavy has transformed into a dwarf!'})
  W.run(3)
  CW.day(W, 1)
  e = events(W, 'TRANSFORM')
  T.eq({#e, e[2].d.dir}, {2, 'back'})
  T.eq({W.state().curse.n, W.state().curse.tf}, {1, 0})
  T.eq(#events(W, 'DECISION_NEEDED') > 0 and #q, 1)
end)

T.test('BUG-115: a bitten citizen no curse report named turns: TRANSFORM bite=1, listed among the cursed', function()
  local W = world()
  W.event('REPORT', {type = ANY, text = 'Kel Becordastot, Manager has transformed into a werecavy!'})
  W.run(3)
  local e = events(W, 'TRANSFORM')
  T.eq({#e, e[1].d.bite, e[1].d.unit}, {1, 1, 2})
  T.eq(W.state().curse.tf, 1)
end)

T.test('BUG-115: a cursed citizen who dies leaves the list (counted as dead)', function()
  local W = world()
  cursed_report(W, 'Oddom Letmoscog, Miner', 'Ok')
  W.run(3)
  W.kill(1)
  CW.day(W, 1)
  T.eq(W.state().curse, nil, 'nobody cursed is left')
  local r = W.inbox('inspect', {what = 'curse'})
  T.eq({r.data.cursed, r.data.dead}, {0, 1})
end)

---------------------------------------------------------------- the unit sheet
T.test('BUG-115: units cursed before the kernel booted are found on their sheets; a hidden curse stays hidden', function()
  local W = world()
  W.unit(3).curse = {name = 'werecavy', name_visible = true}
  W.unit(4).curse = {name = 'vampire', name_visible = false}      -- a vampire the sheet does not show
  CW.day(W, 1)
  local e = events(W, 'CURSED')
  T.eq(#e, 1)
  T.eq({e[1].d.unit, e[1].d.ann, e[1].d.kind}, {3, 'sheet', 'were'})
  T.eq(W.state().curse.ids, {3})
end)

T.test('BUG-115: the were-form race on the sheet is TRANSFORM (sheet), and the way back too; no event twice', function()
  local W = world()
  W.unit(2).curse = {name = 'werecavy', name_visible = true}
  CW.day(W, 1)
  W.unit(2).race = 2                                             -- the werecavy
  CW.day(W, 1)
  local t = events(W, 'TRANSFORM')
  T.eq(#t, 1)
  T.eq({t[1].d.dir, t[1].d.ann, t[1].d.to}, {'beast', 'sheet', 'werecavy'})
  CW.day(W, 2)
  T.eq(#events(W, 'TRANSFORM'), 1)
  W.unit(2).race = 1
  CW.day(W, 1)
  t = events(W, 'TRANSFORM')
  T.eq({#t, t[2].d.dir}, {2, 'back'})
  T.eq({W.state().curse.n, W.state().curse.tf}, {1, 0})
end)

T.test('BUG-115: a unit a report called cursed (kind unknown) turns werecavy on the sheet: TRANSFORM by sheet, kind were', function()
  local W = world()
  cursed_report(W, 'Oddom Letmoscog, Miner', 'Ok')
  W.run(3)
  CW.day(W, 1)
  T.eq(#events(W, 'TRANSFORM'), 0)
  W.unit(1).race = 2
  CW.day(W, 1)
  local t = events(W, 'TRANSFORM')
  T.eq({#t, t[1].d.ann, t[1].d.unit}, {1, 'sheet', 1})
  local r = W.inbox('inspect', {what = 'curse'})
  T.eq({r.data.units[1].kind, r.data.units[1].tf}, {'were', 1})
end)

T.test('BUG-115: a curse name that is not a string (a struct) is never read as a curse', function()
  local W = world()
  W.unit(3).curse = {name = setmetatable({}, {__tostring = function() return '<struct>' end}), name_visible = true}
  CW.day(W, 1)
  T.eq(#events(W, 'CURSED'), 0)
  T.eq(W.state().curse, nil)
  W.unit(4).curse = {name = 'werecavy', name_visible = true}          -- a string name is read
  CW.day(W, 1)
  T.eq({#events(W, 'CURSED'), W.state().curse.ids}, {1, {4}})
end)

T.test('BUG-115: a were-form record from a report is corrected by the sheet when the race says dwarf again', function()
  local W = world()
  W.event('REPORT', {type = ANY, text = 'Oddom Letmoscog, Miner has transformed into a werecavy!'})
  W.run(3)
  CW.day(W, 1)
  T.eq(W.state().curse.tf, 1, 'a sheet that never showed the were-form race does not clear a report\'s word')
  W.unit(1).race = 2
  CW.day(W, 1)
  W.unit(1).race = 1                                            -- the race shows the were-form for him, then a dwarf again
  CW.day(W, 1)
  T.eq({W.state().curse.n, W.state().curse.tf}, {1, 0}, 'no "back" text needed')
end)

T.test('BUG-115: a fort of 80 with 40 cursed on their sheets: one merged event, ids bounded, one care run', function()
  local W = world{cit = 80}
  for i = 1, 40 do W.unit(i).curse = {name = 'werecavy', name_visible = true} end
  CW.day(W, 2)
  local e = events(W, 'CURSED')
  T.ok(#e <= 2 and #e >= 1, 'merged: ' .. #e)
  T.eq(W.state().curse.n, 40)
  T.eq(#W.state().curse.ids, 8)
end)

---------------------------------------------------------------- CURSE_MOON
T.test('BUG-115: CURSE_MOON comes once when the full moon is near, again only for a new cursed unit', function()
  local W = world()
  cursed_report(W, 'Oddom Letmoscog, Miner', 'Ok')
  W.run(3)
  -- put the clock four days before the next full moon
  local CU = require('dfllm.curse')
  local now = W.K.now().tick
  local _, _, nxt = CU.moon(now, 13)
  local want = nxt - 3 * 1200
  df.global.cur_year_tick = want % 403200
  df.global.cur_year = want // 403200
  CW.day(W, 1)
  local m = events(W, 'CURSE_MOON')
  T.eq(#m, 1)
  T.eq({m[1].cls, m[1].d.n, m[1].d.ids}, {'A', 1, {1}})
  T.ok(m[1].msg:find('put them in one locked room now', 1, true), m[1].msg)
  CW.day(W, 1)
  T.eq(#events(W, 'CURSE_MOON'), 1, 'once per moon')
  cursed_report(W, 'Kel Becordastot, Manager', 'Ok')
  W.run(3)
  W.ms = W.ms + 700000                                          -- the wall clock of the cadence (util/cadence)
  CW.day(W, 3)
  T.eq(#events(W, 'CURSE_MOON'), 2, 'a new cursed unit is news')
end)

T.test('BUG-115: nobody cursed: no CURSE_MOON, no state key', function()
  local W = world()
  CW.day(W, 30)
  T.eq(#events(W, 'CURSE_MOON'), 0)
  T.eq(W.state().curse, nil)
  cursed_report(W, 'Oddom Letmoscog, Miner', 'Ok')
  W.run(3)
  T.eq(W.state().curse.n, 1, 'a curse after thirty quiet days is seen')
end)

---------------------------------------------------------------- the persisted list and old states
T.test('BUG-115: the list survives a reload; an old care state without it works', function()
  local W = world()
  cursed_report(W, 'Oddom Letmoscog, Miner', 'Ok')
  W.run(3)
  local p = W.K.persist.get('m.care')
  T.eq(p.cur.u['1'].g, 'Ok')
  p.cur = nil                                                   -- a state written before this package
  CW.day(W, 1)
  T.eq(W.state().curse, nil)
  cursed_report(W, 'Kel Becordastot, Manager', 'Ok')
  W.run(3)
  T.eq(W.state().curse.n, 1)
end)

T.test('BUG-115: curse = false switches the reading off', function()
  local W = world()
  W.K.cfg.baseline.care = W.K.cfg.baseline.care or {}
  W.K.cfg.baseline.care.curse = false
  cursed_report(W, 'Oddom Letmoscog, Miner', 'Ok')
  W.unit(3).curse = {name = 'werecavy', name_visible = true}
  CW.day(W, 1)
  T.eq(#events(W, 'CURSED'), 0)
  T.eq(W.state().curse, nil)
  W.K.cfg.baseline.care.curse = true
  cursed_report(W, 'Kel Becordastot, Manager', 'Ok')
  W.run(3)
  T.eq(#events(W, 'CURSED'), 1, 'on again: the report is read')
end)

---------------------------------------------------------------- inspect what=unit (FR-83)
T.test('FR-83: inspect what=unit reads the sheet: stress and its level, mood, thoughts, curse, wounds, job, place', function()
  local W = world()
  local u = W.unit(1)
  u._m.stress = 0
  u.status = {current_soul = {personality = {stress = 81234, emotions = kmock.vec{
    {thought = df.unit_thought_type and df.unit_thought_type.Death or 1}}}}}
  u.body = {wounds = kmock.vec{{bleeding = 3}, {bleeding = 0}}, blood_count = 4000, blood_max = 5000}
  u.job = {current_job = nil}
  u.curse = {name = 'werecavy', name_visible = true}
  W.event('REPORT', {type = ANY, text = 'Oddom Letmoscog, Miner has been cursed by Ok!'})
  W.run(3)
  local r = W.inbox('inspect', {what = 'unit', key = '1'})
  T.ok(r.ok, r.msg)
  local d = r.data
  T.eq({d.id, d.stress, d.cat, d.level}, {1, 81234, 0, 'desperate'})
  T.eq(d.wound, {n = 2, bleed = 1})
  T.eq(d.blood_pct, 80)
  T.eq({d.curse.god, d.curse.name, d.curse.tf}, {'Ok', 'werecavy', 0})
  T.eq(d.job, 'none')
  T.ok(d.pos ~= nil)
  T.ok(r.msg:find('stress desperate (0)', 1, true), r.msg)
  local byname = W.inbox('inspect', {what = 'unit', key = 'Oddom Letmoscog'})
  T.ok(byname.ok, byname.msg)
  T.eq(byname.data.id, 1)
  local none = W.inbox('inspect', {what = 'unit', key = 'Nobody Atall'})
  T.eq(none.ok, false)
  local nokey = W.inbox('inspect', {what = 'unit'})
  T.eq(nokey.ok, false)
end)

T.test('FR-83: the sheet of a unit that is no citizen or resident is not read (fair play: only the fort\'s own)', function()
  local W = world{units = {{id = 90, pos = {5, 5, 5}}}}
  W.unit(90).curse = {name = 'vampire', name_visible = true}
  local r = W.inbox('inspect', {what = 'unit', key = '90'})
  T.eq(r.ok, false)
  T.ok(r.msg:find('not a citizen or resident', 1, true), r.msg)
  T.eq(W.inbox('inspect', {what = 'unit', key = '1'}).ok, true)
end)

T.test('FR-83: two citizens of one name are not guessed', function()
  local W = world()
  W.unit(5)._m.name = 'Oddom Letmoscog, Mason'
  local r = W.inbox('inspect', {what = 'unit', key = 'Oddom Letmoscog'})
  T.eq(r.ok, false)
  T.ok(r.msg:find('share that name', 1, true), r.msg)
end)

---------------------------------------------------------------- FR-83: the desperate list
T.test('FR-83: care.s0 counts the citizens at stress category 0 and names the first ones', function()
  local W = world{cit = 20}
  for i = 1, 9 do W.unit(i)._m.stress = 0 end
  CW.day(W, 1)
  local s0 = W.state().care.s0
  T.eq({s0.n, #s0.ids, #s0.nm}, {9, 6, 6})
  T.eq(s0.nm[1], 'Oddom Letmoscog, Miner')
  for i = 1, 9 do W.unit(i)._m.stress = 3 end
  CW.day(W, 1)
  T.eq(W.state().care.s0, nil)
end)

T.done()
