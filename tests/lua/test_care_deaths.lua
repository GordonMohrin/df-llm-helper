-- care (FR-64): the cause of every citizen death (dfllm.deaths), DEATH with the evidence, deaths found later
-- (fair play: "missing" waits), DEATH_CLUSTER (B) / DEATHS_PREVENTABLE (A) with util/cadence, the season tally.
-- Run 9 (STATUS 0h): `citizen 25889 died (NONE) [cause=NONE]` x3 in 15 minutes, two of them dehydrated.
local T = require('testlib')
local CW = require('care_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local DT = require('dfllm.deaths')

local NAMES = {'urist', 'asob', 'momuz', 'libash', 'nil', 'sodel', 'atir', 'bomrek', 'kadol', 'zon', 'ingish', 'olin'}
local incidents

-- opts as care_world, plus stock = {drink_d, food_d} (a fake economy publishes it); every citizen has a name, no
-- death incident yet, low timers
local function world(opts)
  opts = opts or {}
  incidents = {}
  local setup = opts.setup
  opts.setup = function(W)
    df.incident = {find = function(id) return incidents[id] end}
    for i = 1, opts.cit or 6 do
      local u = W.unit(i)
      u.counters = {death_cause = -1, death_id = -1}
      u.counters2 = {thirst_timer = 1000, hunger_timer = 1000}
      u.name = {first_name = NAMES[i] or ('dwarf' .. i), nickname = ''}
    end
    if opts.stock then
      W.load({name = 'economy', every = {ticks = 1200}, state = function() return {stock = opts.stock} end})
    end
    if setup then setup(W) end
  end
  return CW.world(opts)
end

-- a citizen dies: an incident with the df.death_type name (nil = NONE), o = {killer, found = false, thirst, hunger,
-- patient, job, mood (df.mood_type name kept by the dead unit)}
local function die(W, id, cause, o)
  o = o or {}
  local u = W.unit(id)
  W.kill(id)
  u.counters.death_id = 500 + id
  incidents[500 + id] = {death_cause = cause and df.death_type[cause] or -1, criminal = o.killer or -1,
                         flags = {discovered = o.found ~= false}}
  if o.thirst then u.counters2.thirst_timer = o.thirst end
  if o.hunger then u.counters2.hunger_timer = o.hunger end
  if o.patient then u.health = {flags = {needs_healthcare = true}} end
  if o.job then u.job.current_job = {id = 900 + id, job_type = df.job_type[o.job]} end
  if o.mood then u.mood = df.mood_type[o.mood] end
  W.event('UNIT_DEATH', {unit = id})
end

local function deaths(W)
  local by = {}
  for _, e in ipairs(W.find_events('DEATH')) do by[e.d.unit] = e end
  return by
end

local function report(W, text, o)
  o = o or {}
  local reps = df.global.world.status.reports
  reps:insert('#', {id = 9000 + #reps, type = 0, text = text, flags = {continuation = o.cont == true},
                    year = o.year, time = o.time, pos = {x = -30000, y = -30000, z = -30000}})
end

---------------------------------------------------------------- the library
T.test('parse: the victim is the subject of a passive death phrase, as a whole word', function()
  local keys = {'urist'}
  local h = DT.parse('Urist Lokumzasit, Miner has been found dead, dehydrated.', keys)
  T.eq({h.cat, h.text}, {'dehydrated', 'has been found dead, dehydrated.'})
  T.eq(DT.parse('Urist Lokumzasit, Thresher has been found, starved to death.', keys).cat, 'starved')
  T.eq(DT.parse('Urist has died of thirst.', keys).cat, 'dehydrated')
  T.eq(DT.parse('Urist has bled to death.', keys).cat, 'bled')
  T.eq(DT.parse('Urist has been crushed by a drawbridge!', keys).cat, 'crushed')
  h = DT.parse('Urist, Ghostly Tanner has been murdered by Libash Rakust!', keys)
  T.eq({h.cat, h.by}, {'killed', 'Libash Rakust'})
  T.eq(DT.parse('Urist has been found dead.', keys).cat, nil, 'found: no category in the text')
  T.eq(DT.parse('Urist has slain the goblin lasher!', keys), nil, 'the killer, not the victim')
  T.eq(DT.parse('Libash has been struck down by Urist.', keys), nil, 'named after the phrase only')
  T.eq(DT.parse('Uristen has been found dead, dehydrated.', keys), nil, 'whole words only')
  T.eq(DT.parse('Urist has been taken by a fey mood!', keys), nil, 'no death')
  T.eq(DT.parse('\142sob Zuglar has drowned.', {'\142sob'}).cat, 'drowned', 'CP437 capital initial (translateName key)')
end)

T.test('window: same-cause groups need death_same; pending and unknown never form one', function()
  local list = {{t = 100, u = 1, c = 'dehydrated'}, {t = 200, u = 2, c = 'dehydrated'}, {t = 300, u = 3, c = 'unknown'},
                {t = 400, u = 4, c = 'unknown'}, {t = 500, u = 5, c = 'unknown', pend = 1}, {t = 5, u = 6, c = 'killed'}}
  local win, groups = DT.window(list, 600, 550, 2)
  T.eq(#win, 5, 'unit 6 is outside the window')
  T.eq(#groups, 1)
  T.eq({groups[1].cause, #groups[1].list}, {'dehydrated', 2})
  T.eq((DT.tally(win)), 'unknown 3, dehydrated 2')
end)

---------------------------------------------------------------- DEATH causes
T.test('the death incident decides: category, killer race and id, evidence (thirst, patient, job, position)', function()
  local W = world{cit = 12, units = {{id = 77, invader = true, race = 'GOBLIN'}}}
  W.run(1)
  W.move(1, 7, 8, 5)
  die(W, 1, 'THIRST', {thirst = 18879, patient = true, job = 'ConstructBed'})
  die(W, 2, 'STRUCK_DOWN', {killer = 77})
  die(W, 3, 'DROWN')
  die(W, 4, 'DRAWBRIDGE')
  die(W, 5, 'OLD_AGE')
  die(W, 6, 'MAGMA')
  die(W, 7, 'INFECTION')
  die(W, 8, 'BLEED')
  die(W, 9, 'SUFFOCATE')
  die(W, 10, 'COLD')
  die(W, 11, 'TRAP')
  die(W, 12, 'HUNGER', {hunger = 80000})
  W.run(1)
  local d = deaths(W)
  local e = d[1]
  T.eq({e.d.cause, e.d.src, e.d.dtype, e.d.thirst, e.d.patient, e.d.job, e.d.pos, e.d.found},
       {'dehydrated', 'incident', 'THIRST', 18879, 1, 'ConstructBed', {7, 8, 5}, 1})
  T.eq(e.msg, 'citizen 1 died: dehydrated (incident THIRST; thirst 18879; patient)')
  T.eq(e.d.why, 'incident THIRST; thirst 18879; patient')
  T.eq({d[2].d.cause, d[2].d.by, d[2].d.killer}, {'killed', 'goblin', 77})
  T.eq(d[2].msg, 'citizen 2 died: killed by goblin 77 (incident STRUCK_DOWN)')
  local want = {[3] = 'drowned', [4] = 'crushed', [5] = 'old_age', [6] = 'burned', [7] = 'infection', [8] = 'bled',
                [9] = 'suffocated', [10] = 'unknown', [11] = 'killed', [12] = 'starved'}
  for id, cause in pairs(want) do T.eq(d[id].d.cause, cause, 'unit ' .. id) end
  T.eq({d[10].d.dtype, d[10].d.src}, {'COLD', 'incident'}, 'no category: the type is the evidence')
  T.eq(d[11].d.by, 'trap')
  T.ok(d[12].d.why:find('hunger 80000', 1, true), d[12].d.why)
  for _, ev in pairs(d) do T.eq(ev.cls, 'B'); T.ok(#ev.msg <= 200 and #json.encode(ev.d) < 1024) end
end)

T.test('a strange mood: thirst in the mood -> mood; an accident in the mood stays the accident; insane -> mood', function()
  local W = world{cit = 6}
  W.unit(3).mood = df.mood_type.Fey                           -- care sees the mood, then it fails (Berserk)
  W.run(1)
  T.eq(#W.find_events('MOOD_START'), 1)
  W.unit(3).mood = df.mood_type.Berserk
  CW.day(W)
  local me = W.find_events('MOOD_END')
  T.eq({#me, me[1].d.ok}, {1, 0})
  die(W, 1, 'THIRST', {thirst = 75004, mood = 'Fey'})          -- Run 9: the fey-mood dwarf at thirst 75004
  die(W, 2, 'CAVEIN', {mood = 'Possessed'})
  W.unit(3).mood = -1                                          -- care's MOOD_END record alone
  die(W, 3, 'STRUCK_DOWN', {killer = 4})
  W.run(1)
  local d = deaths(W)
  T.eq({d[1].d.cause, d[1].d.src, d[1].d.mood, d[1].d.dtype}, {'mood', 'mood', 'Fey', 'THIRST'})
  T.eq(d[1].msg, 'citizen 1 died: mood (in a Fey mood; incident THIRST; thirst 75004)')
  T.eq({d[2].d.cause, d[2].d.mood}, {'crushed', nil})
  T.ok(d[2].d.why:find('in a Possessed mood', 1, true), d[2].d.why)
  T.eq({d[3].d.cause, d[3].d.mood, d[3].d.killer}, {'mood', 'Fey', 4})
  T.ok(d[3].d.why:find('insane after a failed mood (Fey)', 1, true) and d[3].d.why:find('by dwarf 4', 1, true),
       d[3].d.why)
end)

T.test('fair play: a death the unit list shows as missing has no cause until found; then DEATH revised', function()
  local W = world{cit = 4}
  W.run(1)
  die(W, 2, 'THIRST', {found = false, thirst = 18879})
  W.run(1)
  local d = W.find_events('DEATH')
  T.eq(#d, 1)
  T.eq({d[1].d.cause, d[1].d.found, d[1].d.src, d[1].d.dtype, d[1].d.thirst}, {'unknown', 0, 'none', nil, nil},
       'nothing of the incident or the timers leaks')
  T.eq(d[1].msg, 'citizen 2 died: unknown (not found yet, missing in the unit list)')
  CW.day(W, 2)
  T.eq(#W.find_events('DEATH'), 1, 'still missing: asked again, nothing new')
  T.eq(W.state().care.died, {unknown = 1})
  incidents[502].flags.discovered = true                       -- a dwarf found the body
  CW.day(W)
  d = W.find_events('DEATH')
  T.eq(#d, 2)
  T.eq({d[2].d.cause, d[2].d.found, d[2].d.revised, d[2].d.unit}, {'dehydrated', 1, 1, 2})
  T.eq(d[2].msg, 'citizen 2 found dead: dehydrated (incident THIRST; thirst 18879)')
  T.eq(W.state().care.died, {dehydrated = 1})
  CW.day(W, 2)
  T.eq(#W.find_events('DEATH'), 2, 'once')
end)

T.test('a missing death found through the announcement naming the unit; never found -> unknown for good', function()
  local W = world{cit = 4}
  W.run(1)
  die(W, 1, 'THIRST', {found = false})
  die(W, 3, nil, {found = false})
  W.run(1)
  report(W, 'Urist Lokumzasit, Miner has been found dead,')
  report(W, 'dehydrated.', {cont = true})
  CW.day(W)
  local d = deaths(W)
  T.eq({d[1].d.cause, d[1].d.revised, d[1].d.src}, {'dehydrated', 1, 'incident'}, 'the report made it visible')
  T.eq(d[3].d.found, 0)
  local p = W.K.persist.get('m.care')
  T.eq(p.died[2].pend, 1)
  for _ = 1, 85 do CW.day(W) end                              -- death_recheck: a season
  local gave_up = false
  for _, l in ipairs(W.logs) do
    if tostring(l.msg):find('death of citizen 3: not found after 84 days, cause unknown', 1, true) then gave_up = true end
  end
  T.ok(gave_up, 'given up: unknown for good')
  T.eq(#W.find_events('DEATH'), 3)
end)

T.test('DF 53.16: incident cause NONE -> the announcement log (joined lines; old ones and other dwarves ignored)', function()
  local W = world{cit = 6}
  CW.day(W, 2)
  local y, now = df.global.cur_year, df.global.cur_year_tick
  report(W, 'Libash Bomrek has slain the goblin lasher!')
  report(W, 'Nil Zursul has drowned.', {year = y, time = now - 2000})          -- before the death
  report(W, 'Urist Lokumzasit, Miner has been found dead,', {year = y, time = now})
  report(W, 'dehydrated.', {cont = true})
  report(W, 'Asob Zuglar, Thresher has been found, starved to death.')
  report(W, 'Momuz Ral, Ghostly Tanner has been murdered by Libash Rakust!')
  for _, id in ipairs({1, 2, 3, 4, 5}) do die(W, id, nil) end
  W.run(1)
  local d = deaths(W)
  T.eq({d[1].d.cause, d[1].d.src}, {'dehydrated', 'report'})
  T.eq(d[1].d.why, 'report "has been found dead, dehydrated."; thirst 1000', 'the timer rides along, low or not')
  T.eq(d[2].d.cause, 'starved')
  T.eq({d[3].d.cause, d[3].d.by}, {'killed', 'Libash Rakust'})
  T.eq({d[4].d.cause, d[4].d.why}, {'unknown', 'no incident, report or timer'}, 'the killer, not the victim')
  T.eq(d[5].d.cause, 'unknown', 'a report older than the death')
end)

T.test('timers decide when nothing else does: past Dehydrated / Starving on the unit sheet', function()
  local W = world{cit = 4}
  W.run(1)
  die(W, 1, nil, {thirst = 60000})
  die(W, 2, nil, {hunger = 80000})
  die(W, 3, nil, {thirst = 30000})
  W.run(1)
  local d = deaths(W)
  T.eq({d[1].d.cause, d[1].d.src, d[1].d.why}, {'dehydrated', 'timer', 'thirst 60000'})
  T.eq({d[2].d.cause, d[2].d.src}, {'starved', 'timer'})
  T.eq({d[3].d.cause, d[3].d.why}, {'unknown', 'thirst 30000'}, 'thirsty is evidence, not a cause')
end)

T.test('unreadable DF fields: no incident API, no timers, no report vector -> unknown, no fault', function()
  local W = world{cit = 3}
  W.run(1)
  W.kill(1)
  df.incident = nil
  W.unit(1).counters, W.unit(1).counters2 = nil, nil
  df.global.world.status.reports = nil
  W.event('UNIT_DEATH', {unit = 1})
  W.run(1)
  local d = W.find_events('DEATH')
  T.eq({#d, d[1].d.cause, d[1].d.found}, {1, 'unknown', 1})
  T.eq(W.faults, {})
  df.global.world.status.reports = kmock.vec{}
end)

---------------------------------------------------------------- clusters
T.test('DEATH_CLUSTER + DEATHS_PREVENTABLE for 2 dehydration deaths; no repeat without news; a 3rd after both clocks', function()
  local W = world{cit = 6, stock = {drink_d = 1115, food_d = 300}}
  W.run(1)
  W.move(2, 9, 9, 5)
  die(W, 1, 'THIRST', {thirst = 18879, patient = true})
  W.run(1)
  T.eq(W.find_events('DEATH_CLUSTER'), {}, 'one death is no cluster')
  CW.day(W, 3)
  die(W, 2, 'THIRST', {thirst = 20130, job = 'ConstructBed'})
  W.run(1)
  local cl, pv = W.find_events('DEATH_CLUSTER'), W.find_events('DEATHS_PREVENTABLE')
  T.eq({#cl, #pv, cl[1].cls, pv[1].cls}, {1, 1, 'B', 'A'})
  local d = pv[1].d
  T.eq({d.cause, d.n, d.units, d.total, d.days, d.patients, d.stock, d.pos, d.job},
       {'dehydrated', 2, {1, 2}, 2, 28, 1, 1115, {9, 9, 5}, 'ConstructBed'})
  T.eq(d.causes, {'1:dehydrated', '2:dehydrated'})
  T.eq(pv[1].msg, '2 citizens died of dehydration within 28 d; drink 1115 d: forbidden or unreachable? inspect reach, '
                  .. 'inspect refuge; patients: hospital water (inspect water_sources); units 1, 2 (1 patient)')
  T.eq(cl[1].msg, pv[1].msg)
  CW.day(W, 3)
  T.eq(#W.find_events('DEATHS_PREVENTABLE'), 1, 'the same cluster: not again')
  die(W, 3, 'THIRST')
  CW.day(W)
  T.eq(#W.find_events('DEATHS_PREVENTABLE'), 1, 'a new death, but within 10 wall minutes')
  W.ms = W.ms + 600000
  CW.day(W)
  pv = W.find_events('DEATHS_PREVENTABLE')
  T.eq(#pv, 2, 'grew and both clocks passed')
  T.eq({pv[2].d.n, pv[2].d.units}, {3, {1, 2, 3}})
  T.eq(#W.find_events('DEATH_CLUSTER'), 2, 'one cause for the whole window: no mixed line')
  local p = W.K.persist.get('m.care')
  T.eq(p.clus.dehydrated.ids, {1, 2, 3})
end)

T.test('starvation cluster: DEATHS_PREVENTABLE with the food hint', function()
  local W = world{cit = 4, stock = {drink_d = 400, food_d = 12}}
  W.run(1)
  die(W, 1, 'HUNGER')
  die(W, 2, 'HUNGER', {patient = true})
  W.run(1)
  local pv = W.find_events('DEATHS_PREVENTABLE')
  T.eq(#pv, 1)
  T.eq(pv[1].d.hint, 'food 12 d: forbidden or unreachable? inspect reach, inspect refuge; patients: fed by caregivers?')
  T.eq(#W.find_events('DEATHS_3PLUS'), 0)
end)

T.test('mixed cluster: 3 deaths of 3 causes within a month (B only); a killed pair names the attackers', function()
  local W = world{cit = 6, units = {{id = 77, invader = true, race = 'GOBLIN'}}}
  W.run(1)
  die(W, 1, 'DROWN')
  CW.day(W, 5)
  die(W, 2, 'STRUCK_DOWN', {killer = 77})
  CW.day(W, 5)
  die(W, 3, 'OLD_AGE')
  W.run(1)
  local cl = W.find_events('DEATH_CLUSTER')
  T.eq(#cl, 1)
  T.eq({cl[1].d.cause, cl[1].d.n, cl[1].d.total}, {'mixed', 3, 3})
  T.eq(cl[1].msg, '3 citizens died within 28 d: drowned 1, killed 1, old_age 1; units 1, 2, 3')
  T.eq(W.find_events('DEATHS_PREVENTABLE'), {})
  T.eq(W.find_events('DEATHS_3PLUS'), {}, 'spread over days')
  W.ms = W.ms + 600000
  CW.day(W)
  die(W, 4, 'STRUCK_DOWN', {killer = 77})
  W.run(1)
  cl = W.find_events('DEATH_CLUSTER')
  T.eq(#cl, 2, 'the killed pair; the mixed line is covered by it')
  T.eq({cl[2].d.cause, cl[2].d.n, cl[2].d.total, cl[2].d.causes}, {'killed', 2, 4, {'2:killed by goblin', '4:killed by goblin'}})
  T.eq(cl[2].msg, '2 citizens were killed within 28 d (4 deaths in all); units 2, 4')
  W.ms = W.ms + 600000
  CW.day(W, 2)
  T.eq(#W.find_events('DEATH_CLUSTER'), 2, 'no news: no repeat')
end)

T.test('outside the window no cluster; the season tally in the state; DEATHS_3PLUS names the causes', function()
  local W = world{cit = 8}
  W.run(1)
  die(W, 1, 'THIRST')
  CW.day(W, 30)                                                -- > 28 days
  die(W, 2, 'THIRST')
  W.run(1)
  T.eq(W.find_events('DEATH_CLUSTER'), {})
  T.eq(W.state().care.died, {dehydrated = 2})
  die(W, 3, 'DROWN'); die(W, 4, 'DROWN'); die(W, 5, 'BLEED')
  W.run(1)
  local a = W.find_events('DEATHS_3PLUS')
  T.eq(#a, 1)
  T.eq(a[1].d.causes, {'2:dehydrated', '3:drowned', '4:drowned'})
  T.eq(a[1].msg, '3 citizens died within a day: drowned 2, dehydrated 1')
  T.eq(W.state().care.died, {dehydrated = 2, drowned = 2, bled = 1})
  local cl = W.find_events('DEATH_CLUSTER')
  T.eq(#cl, 1, 'the drowned pair names the total; the bled death joins the mixed set within the cadence')
  T.eq({cl[1].d.cause, cl[1].d.total}, {'drowned', 3})
  T.eq(cl[1].msg, '2 citizens drowned within 28 d (3 deaths in all); units 3, 4')
  for _ = 1, 85 do CW.day(W) end
  T.eq(W.state().care.died, nil, 'a season later: no deaths to show')
end)

---------------------------------------------------------------- BUG-027: crushed by a bridge
-- Run 10: seven citizens died on the B1/O1 footprints, every DEATH said "unknown (not found yet, missing in the unit
-- list)". gate.moves (here a stand-in) holds the move of B1 with the units gate saw near its footprint.
local B1 = {128, 127, 122, 128, 129, 122}
local function gate_stub(W, moves)
  W.load({name = 'gate', every = {ticks = 600}, moves = function() return W.moves end})
  W.moves = moves
end
local function b1_move(t, seen) return {{t = t, t1 = t + 100, b = 'B1', bid = 17880, fp = B1, to = 'up', pull = t - 200,
                                         lever = 17584, seen = seen}} end

T.test('library: a death matches a bridge move by sighting (also missing), by the body on or next to the footprint, ' ..
       'by an incident DRAWBRIDGE; never outside the window', function()
  local mv = b1_move(1000, {{id = 7, k = 'soldier', d = 0, x = 128, y = 127, z = 122}, {id = 8, k = 'citizen', d = 3,
                             x = 131, y = 127, z = 122}})
  local m = DT.bridge(7, 1050, mv)
  T.eq({m.b, m.bid, m.to, m.pull, m.how, m.d, m.pos, m.k}, {'B1', 17880, 'up', 800, 'seen', 0, {128, 127, 122}, 'soldier'})
  T.eq(DT.bridge_why(m), 'bridge B1 17880 up (pulled at 800), last seen on it at 128,127,122')
  T.eq(DT.bridge(8, 1050, mv), nil, 'seen 3 tiles off: no match by sighting')
  T.eq(DT.bridge(8, 1050, mv, {128, 130, 122}).how, 'pos', 'the body next to the footprint')
  T.eq(DT.bridge(8, 1050, mv, {128, 131, 122}), nil, 'two tiles off')
  T.eq(DT.bridge(9, 1050, mv, nil, 'DRAWBRIDGE').how, 'incident')
  T.eq(DT.bridge(7, 1000 + 100 + 201, mv), nil, 'after the window')
  T.eq(DT.bridge(7, 1000 - 101, mv), nil, 'before the window')
  T.eq(DT.bridge(7, 1000 - 100, mv).how, 'seen')
end)

T.test('BUG-027 Run 10: a citizen gate saw on B1 dies "missing": DEATH crushed (src bridge) with the bridge, at once',
       function()
  local W = world{cit = 4, setup = function(W) gate_stub(W, {}) end}
  W.run(1)
  W.moves = b1_move(W.K.now().tick, {{id = 2, k = 'citizen', d = 0, x = 128, y = 129, z = 122}})
  die(W, 2, nil, {found = false})
  W.run(1)
  local d = W.find_events('DEATH')
  T.eq(#d, 1)
  T.eq({d[1].d.cause, d[1].d.src, d[1].d.bridge, d[1].d.found}, {'crushed', 'bridge', 'B1', 1})
  T.ok(d[1].msg:find('citizen 2 died: crushed (bridge B1 17880 up (pulled at ', 1, true), d[1].msg)
  T.ok(d[1].msg:find('last seen on it at 128,129,122; missing in the unit list)', 1, true), d[1].msg)
  T.eq(W.state().care.died, {crushed = 1})
end)

T.test('BUG-027: a found death on the footprint and an incident DRAWBRIDGE name the bridge; combat stays killed; ' ..
       'a citizen far away stays unknown', function()
  local W = world{cit = 6, units = {{id = 77, invader = true, race = 'GOBLIN'}},
                  setup = function(W) gate_stub(W, {}) end}
  W.run(1)
  W.moves = b1_move(W.K.now().tick, {{id = 3, k = 'soldier', d = 0, x = 128, y = 128, z = 122}})
  W.move(1, 128, 127, 122)
  die(W, 1, nil)                                                -- found, no cause: the body on the footprint
  die(W, 2, 'DRAWBRIDGE')
  die(W, 3, 'STRUCK_DOWN', {killer = 77})                       -- seen on the bridge, but killed by the goblin
  W.move(4, 10, 10, 5)
  die(W, 4, nil, {found = false})
  W.run(1)
  local d = deaths(W)
  T.eq({d[1].d.cause, d[1].d.src, d[1].d.bridge}, {'crushed', 'bridge', 'B1'})
  T.ok(d[1].d.why:find('died on it at 128,127,122', 1, true), d[1].d.why)
  T.eq({d[2].d.cause, d[2].d.src, d[2].d.dtype, d[2].d.bridge}, {'crushed', 'incident', 'DRAWBRIDGE', 'B1'})
  T.eq({d[3].d.cause, d[3].d.bridge}, {'killed', nil})
  T.eq({d[4].d.cause, d[4].d.found}, {'unknown', 0})
end)

T.done()
