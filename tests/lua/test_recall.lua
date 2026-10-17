-- BUG-035 (Run 11, Kilrudrabed site98, siege 9 = invasion 13 and the ambush after it, y445): ARRIVAL said
-- 'recall: 5 outside Kern+', then 'recall: 9 of 5 still outside after 1246 t' (the count grew past the start count) and
-- 'recall: 8 of 5'; in the ambush 'recall (arrival:ambush): 2 of 2 citizens still outside Kern+ after 2407 ticks' with
-- the alert on Tiefe+, still 2 of 2 at the lockdown's end after 4807 ticks, the doors '8 waiting for 1 citizen
-- outside'. The two (28346, 28350) were the same in both, adults, idle, unhurt, on the citizens' only walk group.
-- The real sense, threat, siege, gate, reflex and seal on one k_mock world (tests/lua/seal_world.lua: DF-like walk
-- groups that ignore a forbidden door, burrows by bbox). No lever-linked bridge: the lockdown's alert sounds at once.
-- Checked, each failing on 784399f:
--   * the recall follows the citizens it called: citizens who step out of Kern+ into a corridor after the alert are
--     counted apart ('+4 more out since'), never as '7 of 3 still outside';
--   * the alert's burrow moves Kern+ -> Tiefe+ (deep defense): the recall measures arrival in Tiefe+, says so, the
--     texts name Tiefe+; an alert on Tiefe+ from the start (the ambush) is measured there too, never 'outside Kern+';
--   * a citizen behind a door the lockdown forbade (a roofed gatehouse is no 'outside side' of the door): seal's path
--     check finds that his only way crosses it, the door opens again for him and is forbidden once he is in;
--   * citizens who cannot come (lying on the field, gate's lever puller, another walk group) hold no door: RECALL
--     stuck once, with a reason per citizen; a puller does not keep the recall open;
--   * kern.log names every citizen out at the alert with where he stands and why he is not in.
local T = require('testlib')
local SW = require('seal_world')
local S = require('siege_world')

local Z = 5                                    -- the fort level; the surface is Z + 1, the refuge level Z - 1

-- surface z 6: an open field x0-40 y0-24 with a down stair at 20,10 and a walled-off patch (a ring of constructed
-- walls) around 35,20. Fort z 5: hall x2-12 y4-16 (beds, drink, food, Kern+), corridor y10 x13-18 (no burrow) to the
-- door at 19,10 and the up stair at 20,10, a roofed gatehouse x21-27 y8-12 beside the stair (outside the door: seal's
-- porch of the stair opening) and off it, behind its own door at 26,13 (6 steps from the stair: no entrance door), a
-- store room x24-28 y14-17 (no burrow, no open sky, no porch: the porch walk stops at a door). Refuge z 4: a stair
-- down from the hall at 4,14, a passage x5-7 y14 (no burrow), the room x8-12 y12-16 (Tiefe+).
local function fort(opts)
  opts = opts or {}
  local persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}}}}
  local W = SW.new{persist = persist}
  W.ms_per_frame = 100
  SW.fill(W, Z + 1, 0, 0, 40, 24, ',')
  SW.draw(W, Z + 1, {'>'}, 20, 10, {outside = true})
  SW.draw(W, Z + 1, {'CCCCC', 'C,,,C', 'C,,,C', 'C,,,C', 'CCCCC'}, 33, 18)
  SW.fill(W, Z, 0, 0, 40, 24, '#')
  SW.fill(W, Z, 2, 4, 12, 16, '.')
  SW.fill(W, Z, 13, 10, 18, 10, '.')
  SW.draw(W, Z, {'+<'}, 19, 10)
  SW.fill(W, Z, 21, 8, 27, 12, '.')
  SW.draw(W, Z, {'+'}, 26, 13)
  SW.fill(W, Z, 24, 14, 28, 17, '.')
  SW.draw(W, Z, {'bb'}, 3, 5)
  SW.draw(W, Z, {'>'}, 4, 14)
  SW.fill(W, Z - 1, 0, 0, 40, 24, '#')
  SW.draw(W, Z - 1, {'<...'}, 4, 14)
  SW.fill(W, Z - 1, 8, 12, 12, 16, '.')
  SW.regroup(W)
  SW.item(W, 'DRINK', 5, 6, Z, 20)
  SW.item(W, 'FOOD', 6, 6, Z, 20)
  for _, c in ipairs({{1, 5, 8}, {2, 6, 9}, {3, 7, 10}, {4, 8, 11}}) do
    W.add_unit{id = c[1], pos = {c[2], c[3], Z}, citizen = true, adult = true}
  end
  for _, u in ipairs(opts.units or {}) do W.add_unit(u) end
  W.burrow('Kern+', {2, 4, Z, 12, 16, Z})
  W.burrow('Tiefe+', {8, 12, Z - 1, 12, 16, Z - 1})
  W.act_result('alert_burrows', function(names)
    for _, n in ipairs(names) do if not dfhack.burrows.findByName(n) then return false, 'no burrow ' .. n end end
    W.alert_burrows = names
    return true, #names
  end)
  W.act_result('door_forbid', function(id, on)
    local b = W.buildings[id]
    if not b or not b.door_flags then return false, 'not a door' end
    local old = b.door_flags.forbidden
    b.door_flags.forbidden = on and true or false
    return true, old
  end)
  df.job_type.Rest, df.job_type.Sleep = 300, 301
  dfhack.job = {getWorker = function(j) return j._worker end}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  snap.outside_near = require('dfllm.snapshot').outside_near
  function snap.far() return false end
  for _, n in ipairs({'reflex', 'seal'}) do package.loaded['dfllm.' .. n] = nil end
  S.load(W, {S.military(), snap, require('dfllm.reflex'), require('dfllm.seal')})
  return W
end

local function run(W, ticks, each)
  local done = 0
  while done < ticks do
    W.frame(9)
    if each then each(W) end
    done = done + 9
  end
end

local function acts(W, fn, val, on)
  local r = {}
  for _, a in ipairs(W.acts) do
    if a.fn == fn and (val == nil or a.args[1] == val) and (on == nil or a.args[2] == on) then r[#r + 1] = a end
  end
  return r
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then return l end end
end
local function has(list, x) for _, v in ipairs(list or {}) do if v == x then return true end end return false end
local function find_tok(list, prefix)
  for _, v in ipairs(list or {}) do if tostring(v):sub(1, #prefix) == prefix then return v end end
end

-- the lockdown: an invasion report; returns the ARRIVAL event and the alert's tick
local function lockdown(W, id)
  W.event('INVASION', {id = id or 5})
  run(W, 30)
  W.inbox('ack', {})
  local arr = W.find_events('ARRIVAL')[1]
  local on = acts(W, 'civ_alert', true)[1]
  return arr, on and on.tick or -1
end

local function settle(W) run(W, 1800) end
local function door_of(W) return W.dyn[SW.key(19, 10, Z)] end

T.test('the fort: Kern+ and Tiefe+ exist, the gatehouse and the corridor lie in neither, one walk group for all ' ..
       'but the walled patch', function()
  local W = fort()
  settle(W)
  local kern, tiefe = dfhack.burrows.findByName('Kern+'), dfhack.burrows.findByName('Tiefe+')
  for _, p in ipairs({{15, 10, Z}, {24, 10, Z}, {6, 14, Z - 1}}) do
    T.eq(dfhack.burrows.isAssignedTile(kern, {x = p[1], y = p[2], z = p[3]}), false)
    T.eq(dfhack.burrows.isAssignedTile(tiefe, {x = p[1], y = p[2], z = p[3]}), false)
  end
  local g = function(x, y, z) return dfhack.maps.getWalkableGroup({x = x, y = y, z = z}) end
  T.eq(g(24, 10, Z), g(5, 8, Z), 'the gatehouse joins the hall (the door is no barrier to the walk group)')
  T.eq(g(10, 14, Z - 1), g(5, 8, Z), 'Tiefe+ too')
  T.ok(g(35, 20, Z + 1) ~= g(24, 9, Z + 1), 'the walled patch is its own group')
  T.eq(W.inbox('inspect', {what = 'refuge'}).data.burrows['Kern+'].ok, 1)
end)

T.test('BUG-035 (Run 11 siege 9: "recall: 9 of 5 still outside"): citizens who step out of Kern+ into the corridor ' ..
       'after the alert are counted apart; the recall follows the 3 it called and is done when they are in', function()
  local W = fort{units = {{id = 9, pos = {24, 9, Z + 1}, citizen = true, adult = true},
                          {id = 10, pos = {26, 9, Z + 1}, citizen = true, adult = true},
                          {id = 11, pos = {28, 9, Z + 1}, citizen = true, adult = true}}}
  settle(W)
  local arr, t_on = lockdown(W, 5)
  T.ok(arr.msg:find('recall: 3 outside Kern+', 1, true), arr.msg)
  -- four of the hall citizens walk into the corridor (no burrow); the three outside stay out for now
  for i = 1, 4 do W.move(i, 13 + i, 10, Z) end
  run(W, 200)
  W.event('REPORT', {type = 'AMBUSH_AMBUSHER', text = ''})   -- a second arrival: its text says how the recall stands
  run(W, 20)
  local a2 = W.find_events('ARRIVAL')
  local last = a2[#a2].msg
  T.ok(not last:find('7 of 3', 1, true), 'old: the live total against the start count: ' .. last)
  T.ok(last:find('recall: 3 of 3 still outside Kern+ after', 1, true), last)
  T.ok(last:find('+4 more out since', 1, true), last)
  T.ok(logged(W, 'reflex: recall: out at the alert: 9:idle@24,9,6 10:idle@26,9,6 11:idle@28,9,6'),
       'kern.log named each one at the start with where he stands and why he is not in')
  T.eq(a2[#a2].d.rc_left, 3)
  T.eq(a2[#a2].d.rc_new, 4)
  T.ok(logged(W, 'reflex: recall: 4 more citizens out of Kern+ since the alert'), 'kern.log names them once')
  T.ok(logged(W, '1:idle@14,10,5'), 'with where they stand')
  local al = W.state().alarm
  T.eq({al.rn, al.rleft, al.rnew, al.rstuck, al.rto}, {3, 3, 4, 0, 'Kern+'})
  -- the three come in: done, although the four still stand in the corridor
  for _, id in ipairs({9, 10, 11}) do W.move(id, 6, 12, Z) end
  run(W, 100)
  local rc = W.find_events('RECALL')
  T.eq(#rc, 1)
  T.eq({rc[1].d.why, rc[1].d.n, rc[1].d.left, rc[1].d.nnew}, {'done', 3, 0, 4})
  T.eq(rc[1].d.newu, {1, 2, 3, 4})
  T.ok(rc[1].msg:find('recall (arrival:invasion): all 3 citizens outside Kern+ at the alert came in within', 1, true),
       rc[1].msg)
  T.ok(rc[1].msg:find('+4 more out of Kern+ since', 1, true), rc[1].msg)
  T.ok(rc[1].tick - t_on < 2400, 'done before the recall window ended')
end)

T.test('BUG-035: the alert moves from Kern+ to Tiefe+ (the deep defense): the recall measures arrival in Tiefe+ from ' ..
       'then on, says so, and the citizens walking down through the passage are no "still outside Kern+"', function()
  local W = fort{units = {{id = 9, pos = {24, 9, Z + 1}, citizen = true, adult = true}}}
  settle(W)
  local arr = lockdown(W, 5)
  T.ok(arr.msg:find('recall: 1 outside Kern+', 1, true), arr.msg)
  W.move(9, 6, 12, Z)                           -- he is in Kern+
  local siege = W.mods.siege.M
  siege.alert_names = function() return {'Tiefe+'} end     -- siege switched the alert (REFUGE_SWITCH deeper)
  for i = 1, 2 do W.move(i, 4 + i, 14, Z - 1) end           -- two walk down, in the passage (no burrow)
  run(W, 60)
  T.ok(logged(W, 'reflex: recall: the civ alert moved from Kern+ to Tiefe+'), 'kern.log says the recall follows it')
  W.event('REPORT', {type = 'AMBUSH_AMBUSHER', text = ''})
  run(W, 20)
  local a = W.find_events('ARRIVAL')
  local last = a[#a].msg
  T.ok(last:find('recall: 1 of 1 still outside Tiefe+', 1, true), last)
  T.ok(not last:find('of 1 still outside Kern+', 1, true), last)
  T.eq(W.state().alarm.rto, 'Tiefe+')
  -- everybody reaches Tiefe+: done, named Tiefe+
  for _, id in ipairs({1, 2, 3, 4, 9}) do W.move(id, 9 + id % 3, 13 + id % 3, Z - 1) end
  run(W, 100)
  local rc = W.find_events('RECALL')
  T.eq(#rc, 1)
  T.eq({rc[1].d.why, rc[1].d.burrow, rc[1].d.left}, {'done', 'Tiefe+', 0})
  T.ok(rc[1].msg:find('outside Tiefe+ at the alert came in', 1, true), rc[1].msg)
end)

T.test('BUG-035 (the ambush after siege 9: alert on Tiefe+, texts "outside Kern+"): an alert that confines to Tiefe+ ' ..
       'from the start measures arrival there and names it; the lever burrow in the list is no destination', function()
  local W = fort{units = {{id = 9, pos = {24, 9, Z + 1}, citizen = true, adult = true}}}
  settle(W)
  W.mods.siege.M.alert_names = function() return {'Tiefe+', 'Hebel+'} end
  local arr = lockdown(W, 5)
  T.ok(arr.msg:find('recall: 5 outside Tiefe+', 1, true), arr.msg)   -- the four in Kern+ are not in Tiefe+ yet
  T.ok(logged(W, 'reflex: recall: 5 citizens outside Tiefe+ at the alert (arrival:invasion)'), 'kern.log')
  T.ok(logged(W, 'called into Tiefe+'), 'kern.log')
  W.mods.siege.M.alert_names = function() return {'Kern+', 'Tiefe+'} end
  run(W, 60)
  T.ok(logged(W, 'the civ alert moved from Tiefe+ to Kern+/Tiefe+'), 'both listed: either one counts')
  W.move(9, 6, 12, Z)
  run(W, 60)
  local rc = W.find_events('RECALL')
  T.eq(#rc, 1)
  T.eq({rc[1].d.why, rc[1].d.burrow}, {'done', 'Kern+/Tiefe+'})
end)

T.test('BUG-035 hypothesis (i): the gatehouse is the stair opening\'s porch, a citizen there holds the door (as ' ..
       'before); one in the store room off it (behind its own door) is on no "outside side" of the entrance door: the ' ..
       'lockdown forbids it at once although his only way in crosses it; the path check finds that, the door opens ' ..
       'again for him and is forbidden once he is in (old: locked out, RECALL late at 2400)', function()
  local W = fort{units = {{id = 9, pos = {26, 16, Z}, citizen = true, adult = true},
                          {id = 10, pos = {23, 10, Z}, citizen = true, adult = true}}}
  settle(W)
  local door = door_of(W)
  local arr, t_on = lockdown(W, 5)
  T.ok(arr.msg:find('recall: 2 outside Kern+', 1, true), arr.msg)
  T.eq(door.door_flags.forbidden, false, 'the gatehouse citizen holds it (the porch)')
  W.move(10, 6, 12, Z)                          -- he comes in
  run(W, 60)
  T.eq(door.door_flags.forbidden, true, 'then nobody on its outside side by seal.door_outside: forbidden')
  T.eq(W.unit(9).pos.x, 26, 'the store room citizen is still out')
  run(W, 900)
  local reo = acts(W, 'door_forbid', door.id, false)
  T.eq(#reo, 1, 'opened again once')
  T.ok(reo[1].tick - t_on >= 600 and reo[1].tick - t_on < 900, 'after RECALL_PATH: T+' .. (reo[1].tick - t_on))
  T.eq(door.door_flags.forbidden, false, 'it waits for him')
  T.ok(logged(W, string.format('reflex: recall: door %d (19,10,5) opened again: citizen 9 at 26,16,5 has no way into ' ..
       'Kern+ without it', door.id)), 'kern.log')
  local sd = W.dyn[SW.key(26, 13, Z)]
  T.eq(sd.door_flags.forbidden, false, 'the store room door is no entrance door: never forbidden')
  T.eq(#W.find_events('RECALL'), 0)
  W.move(9, 6, 12, Z)
  run(W, 100)
  local rc = W.find_events('RECALL')
  T.eq(#rc, 1)
  T.eq(rc[1].d.why, 'done')
  T.eq(door.door_flags.forbidden, true, 'forbidden again once he is in')
  T.ok(rc[1].tick - t_on < 2400)
end)

T.test('BUG-035: a door the recall opened again is forbidden at once when a hostile comes within DOOR_NEAR of it, ' ..
       'and the citizen it was opened for is then reported as locked out', function()
  local W = fort{units = {{id = 9, pos = {26, 16, Z}, citizen = true, adult = true}}}
  settle(W)
  local door = door_of(W)
  local _, t_on = lockdown(W, 5)
  run(W, 700)
  T.eq(door.door_flags.forbidden, false, 'opened again for him')
  W.add_unit(S.inv(300, 22, 12, Z + 1))           -- a goblin 3 tiles from the door
  run(W, 100)
  T.eq(door.door_flags.forbidden, true, 'forbidden at once')
  local st = W.find_events('RECALL')
  T.eq(#st, 1, 'stuck once')
  T.eq(st[1].d.why, 'stuck')
  -- the store room door lies on seal's route from the stair to him (the nearest citizen): an entrance door as well,
  -- forbidden with him behind it; both were opened again for him, the first one on his way out is named
  local tok = find_tok(st[1].d.reasons, '9:locked:')
  T.ok(tok and tok:find('@26,16,5', 1, true), table.concat(st[1].d.reasons or {}, ' '))
  T.ok(st[1].tick - t_on < 2400)
end)

T.test('BUG-035 safety: a citizen lying on the field holds no door (old: the door waited RECALL_MAX for him); RECALL ' ..
       'stuck once, with the reason; still named at late', function()
  local W = fort{units = {{id = 9, pos = {24, 9, Z + 1}, citizen = true, adult = true, lying = true}}}
  settle(W)
  local door = door_of(W)
  local _, t_on = lockdown(W, 5)
  run(W, 120)
  local f = acts(W, 'door_forbid', door.id, true)[1]
  T.ok(f and f.tick - t_on <= 120, 'forbidden soon after the alert: T+' .. (f and f.tick - t_on or -1))
  local st = W.find_events('RECALL')
  T.eq(#st, 1)
  T.eq({st[1].d.why, st[1].d.stuck, st[1].d.units}, {'stuck', 1, {9}})
  T.ok(has(st[1].d.reasons, '9:down@24,9,6'), table.concat(st[1].d.reasons or {}, ' '))
  T.ok(st[1].msg:find('recall (arrival:invasion): 1 of 1 citizens outside Kern+ cannot come, the doors do not wait ' ..
       'for them (9:down@24,9,6)', 1, true), st[1].msg)
  run(W, 2400)
  local rc = W.find_events('RECALL')
  T.eq(#rc, 2, 'stuck once per lockdown, then late')
  T.eq({rc[2].d.why, rc[2].d.left, rc[2].d.stuck}, {'late', 1, 1})
  T.ok(has(rc[2].d.reasons, '9:down@24,9,6'))
end)

T.test('BUG-035: gate\'s lever puller stays by his levers on purpose: no door waits for him, the recall does not ' ..
       'wait for him either and says so', function()
  local W = fort{units = {{id = 9, pos = {24, 9, Z + 1}, citizen = true, adult = true},
                          {id = 10, pos = {26, 9, Z + 1}, citizen = true, adult = true}}}
  settle(W)
  W.mods.gate.M.puller_of = function() return {[10] = 'dfllm-levers'} end
  local door = door_of(W)
  local _, t_on = lockdown(W, 5)
  W.move(9, 6, 12, Z)
  run(W, 120)
  T.eq(door.door_flags.forbidden, true, 'nobody else outside: the puller holds no door')
  T.ok(logged(W, '10:puller:dfllm-levers@26,9,6'), 'kern.log at the start')
  local rc = W.find_events('RECALL')
  T.eq(#rc, 1, 'no stuck event for a puller')
  T.eq({rc[1].d.why, rc[1].d.left, rc[1].d.pull}, {'done', 0, 1})
  T.ok(rc[1].msg:find('recall (arrival:invasion): 1 of 2 citizens outside Kern+ at the alert came in within', 1, true),
       rc[1].msg)
  T.ok(rc[1].msg:find('the other 1 lever puller at the levers', 1, true), rc[1].msg)
  T.ok(rc[1].tick - t_on < 300)
end)

T.test('BUG-035: a citizen on another walk group (the walled patch) is diagnosed by the path check (group) and named ' ..
       'at the lockdown\'s end', function()
  local W = fort{units = {{id = 9, pos = {35, 20, Z + 1}, citizen = true, adult = true}}}
  settle(W)
  lockdown(W, 5)
  run(W, 800)
  local st = W.find_events('RECALL')
  T.eq(#st, 1)
  T.eq(st[1].d.why, 'stuck')
  T.ok(find_tok(st[1].d.reasons, '9:group@35,20,6'), table.concat(st[1].d.reasons or {}, ' '))
  T.eq(W.state().alarm.rstuck, 1)
end)

T.test('BUG-035: a reload keeps the recall\'s burrows and its stuck report (sense counts against them again, no second ' ..
       'RECALL stuck)', function()
  local W = fort{units = {{id = 9, pos = {24, 9, Z + 1}, citizen = true, adult = true, lying = true}}}
  settle(W)
  W.mods.siege.M.alert_names = function() return {'Tiefe+'} end
  lockdown(W, 5)
  run(W, 120)
  T.eq(#W.find_events('RECALL'), 1)
  local p = require('dfllm.util.json').decode(W.persist_raw['dfllm.m.reflex'])
  T.eq({p.hold.rc.to, p.hold.rc.burrow, p.hold.rc.stuck}, {{'Tiefe+'}, 'Tiefe+', 1})
  W.mods.sense.M.init(W.K)                        -- a reload: both modules start from their persisted state
  W.mods.reflex.M.init(W.K)
  run(W, 300)
  T.eq(#W.find_events('RECALL'), 1, 'stuck once per lockdown, across the reload')
  T.eq(W.K.census.u.away_to, {'Tiefe+'}, 'sense counts against Tiefe+ again')
  local al = W.state().alarm
  T.eq({al.rto, al.rstuck, al.rn}, {'Tiefe+', 1, 5})
end)

T.done()
