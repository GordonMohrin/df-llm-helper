-- The arrival lockdown on a fort without a manifest, with the real sense, threat, siege, gate, reflex and seal on one
-- k_mock world (tests/lua/seal_world.lua: DF-like walk groups, revealed tiles, burrows painted by seal).
-- BUG-011 (Run 9 forced arrival: act.civ_alert true, 12 ticks later false, every batch; civ_alert 0 for the whole
-- lockdown while LOCKDOWN said "alert on Kern+"): siege owns the alert, seal picks the burrow, nothing writes false
-- while the lockdown holds, and the text says what holds. BUG-012 ("0 entrances": a door one tile behind the east
-- stair, three openings listed with "no door"): the doors come from seal's entrance routes, the openings without one
-- are named, and the undo after quiet opens exactly the doors the lockdown forbade. BUG-018 (the first real siege, 50 ->
-- 1): the shaft opening has no door and leads into the hall, so no burrow is separated and the lockdown does not confine
-- (the citizens flee); with a door behind the shaft (opts.shaft_door) BUG-011's interior burrow holds.
local T = require('testlib')
local SW = require('seal_world')
local S = require('siege_world')

local Z = 5                                    -- the fort level; the surface is Z + 1

-- surface z 6: an open field x0-40 y0-24 (outside, reaches the map edge) with a down stair at 20,10 and the top of a
-- shaft (up/down stair) at 30,13. Fort z 5: hall x2-12 y4-16 (beds, the citizens, Kern+), corridor A y10 x13-18
-- to a door at 19,10 and the up stair at 20,10 (the opening: the door is one tile behind it), corridor B y13 x13-29
-- to the shaft at 30,13 (an opening without a door; opts.shaft_door: a door at 29,13 behind it), a bedroom x2-4 y18-20
-- behind its door at 3,17. No drink and no food anywhere: Kern+ and the interior burrow fail their audits (Run 9 behind
-- BUG-001: "drink 0<45, food 2<45").
local function fort(opts)
  opts = opts or {}
  local W = SW.new{persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}}}}
  W.ms_per_frame = 100
  SW.fill(W, Z + 1, 0, 0, 40, 24, ',')
  SW.draw(W, Z + 1, {'>'}, 20, 10, {outside = true})
  SW.draw(W, Z + 1, {'X'}, 30, 13, {outside = true})
  SW.fill(W, Z, 0, 0, 40, 24, '#')
  SW.fill(W, Z, 2, 4, 12, 16, '.')
  SW.fill(W, Z, 13, 10, 18, 10, '.')
  SW.draw(W, Z, {'+<'}, 19, 10)
  SW.fill(W, Z, 13, 13, 29, 13, '.')
  SW.draw(W, Z, {'X'}, 30, 13)
  if opts.shaft_door then SW.draw(W, Z, {'+'}, 29, 13) end
  SW.draw(W, Z, {'+'}, 3, 17)
  SW.fill(W, Z, 2, 18, 4, 20, '.')
  SW.draw(W, Z, {'bb'}, 3, 5)
  SW.regroup(W)
  W.stair_door = W.dyn[SW.key(19, 10, Z)]
  W.room_door = W.dyn[SW.key(3, 17, Z)]
  for _, c in ipairs({{1, 5, 8}, {2, 6, 9}, {3, 7, 10}, {4, 8, 11}}) do
    W.add_unit{id = c[1], pos = {c[2], c[3], Z}, citizen = true, adult = true}
  end
  for _, u in ipairs(opts.units or {}) do W.add_unit(u) end
  W.burrow('Kern+', {2, 4, Z, 12, 16, Z})
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
  W.paint_fn = W.act_results.burrow_tiles      -- seal_world's burrows screen (add + paint)
  if opts.no_paint then W.act_result('burrow_tiles', function() return false, 'test: paint refused' end) end
  local snap = {name = 'snapshot', every = {ticks = 100}}
  snap.outside_near = require('dfllm.snapshot').outside_near
  function snap.far() return false end
  for _, n in ipairs({'reflex', 'seal'}) do package.loaded['dfllm.' .. n] = nil end
  S.load(W, {S.military(), snap, require('dfllm.reflex'), require('dfllm.seal')})
  W.run(3000, {skip = 9})                      -- the first audit, the interior burrow painted, the entrance check
  return W
end

local function evs(W, t) return W.find_events(t) end
local function idx() return df.global.plotinfo.alerts.civ_alert_idx end
local function holding(W) return select(2, W.K.call('reflex', 'holding', 'alert')) end
local function acts_since(W, fn, tick, val)
  local r = {}
  for _, a in ipairs(W.find_acts(fn)) do
    if a.tick >= tick and (val == nil or a.args[1] == val) then r[#r + 1] = a end
  end
  return r
end

T.test('the fort: Kern+ and the interior burrow fail their audits; the entrance check knows both openings', function()
  local W = fort()
  local r = W.inbox('inspect', {what = 'refuge'})
  T.ok(r.ok, r.msg)
  T.eq({r.data.burrows['Kern+'].ok, r.data.burrows['Innen+'].ok, r.data.burrows['Innen+'].exists}, {0, 0, 1})
  T.ok(r.data.burrows['Kern+'].why:find('drink 0<4', 1, true), r.data.burrows['Kern+'].why)
  -- BUG-018: the shaft (no door) leads into the hall; the interior burrow was painted without the tiles it reaches
  T.eq({r.data.burrows['Kern+'].sep, r.data.burrows['Kern+'].open}, {0, {'30,13,5 stair_updown'}})
  T.eq({r.data.burrows['Innen+'].sep, r.data.burrows['Innen+'].tiles}, {1, 12})
  T.eq(r.data.choice.ALERT.burrow, '', 'no burrow passes: no confinement outside a lockdown (FR-37)')
  T.eq(r.data.choice.LOCKDOWN, {want = 'Kern+', burrow = '', flee = 1},
       'BUG-018: the interior behind the doors is too small to keep, no dead end: no confinement')
  local e = W.inbox('inspect', {what = 'entrances'})
  T.eq({e.data.sealed, e.data.routes}, {false, 2})
  T.ok(e.msg:find('1 entrance door, 1 opening without one', 1, true), e.msg)
  T.eq(W.hidden_wg, 0)
  -- a door behind the shaft too: Kern+ is separated (it still lacks drink and food), the lockdown keeps Innen+
  local W2 = fort{shaft_door = true}
  r = W2.inbox('inspect', {what = 'refuge'})
  T.eq({r.data.burrows['Kern+'].sep, r.data.burrows['Kern+'].ok, r.data.burrows['Innen+'].sep}, {1, 0, 1})
  T.eq(r.data.choice.LOCKDOWN, {want = 'Kern+', burrow = 'Innen+', level = 'HOLD'}, 'a lockdown keeps the interior burrow')
end)

T.test('BUG-011: the lockdown holds the civ alert on the interior burrow for many frame batches, never false, ' ..
       'and the text says so', function()
  local W = fort{shaft_door = true}
  local t0 = W.K.now().tick
  T.eq(#acts_since(W, 'civ_alert', 0), 0, 'PEACE: no alert before the arrival')
  W.event('INVASION', {id = 1})
  W.run(30, {skip = 9})
  local arr = evs(W, 'ARRIVAL')
  T.eq(#arr, 1)
  W.inbox('ack', {})                           -- else its default re-applies the lockdown after 60 s (LOCKDOWN)
  -- no gate (no lever-linked bridge): the alert at once; seal refused Kern+, the lockdown kept Innen+
  T.ok(arr[1].msg:find('alert: Innen+ (REFUGE_FAIL Kern+, lockdown fallback)', 1, true), arr[1].msg)
  T.ok(arr[1].d.alert:find('^Innen%+ %(REFUGE_FAIL Kern%+: drink 0<4, food 0<4; Innen%+ kept for the lockdown'),
       arr[1].d.alert)
  T.eq({idx(), W.alert_burrows}, {1, {'Innen+'}}, 'the state is what the text says')
  local f = evs(W, 'REFUGE_FAIL')
  T.ok(#f >= 1 and f[#f].d.fallback == 'Innen+' and f[#f].msg:find('Innen+ kept for the lockdown although', 1, true),
       f[#f] and f[#f].msg)
  local st = W.state().alert
  T.eq({st.want, st.burrow, st.ok}, {'Kern+', 'Innen+', 0}, 'status shows the lockdown burrow')
  -- many frame batches (siege steps, seal audits, reflex re-checks): on and on Innen+ throughout, never false
  local batches = 0
  while holding(W) and batches < 60 do
    W.run(100, {skip = 9})
    batches = batches + 1
    if holding(W) then
      T.eq({idx(), W.alert_burrows}, {1, {'Innen+'}}, 'batch ' .. batches)
      T.eq(#acts_since(W, 'civ_alert', t0, false), 0, 'no civ_alert(false) while the lockdown holds')
    end
  end
  T.ok(batches >= 30, 'the lockdown held for ' .. batches .. ' batches')
  T.eq(#acts_since(W, 'civ_alert', t0, true), 1, 'sounded once')
  -- threat 0 for 2 days: the lockdown ends and only then the alert goes off (PEACE)
  W.run(600, {skip = 9})
  local endt = evs(W, 'LOCKDOWN_END')
  T.eq(#endt, 1)
  T.eq(idx(), 0)
  local off = acts_since(W, 'civ_alert', t0, false)
  T.ok(#off == 1 and off[1].tick >= endt[1].tick, 'the one civ_alert(false) came with the end of the lockdown')
end)

T.test('BUG-011: no usable burrow at all: "alert: none (REFUGE_FAIL ...)", the alert stays off, the interior burrow ' ..
       'is painted at once and the alert follows without a flip', function()
  local W = fort{no_paint = true, shaft_door = true}
  T.eq(W.inbox('inspect', {what = 'refuge'}).data.burrows['Innen+'].exists, 0, 'painting refused: no Innen+')
  local t0 = W.K.now().tick
  W.event('INVASION', {id = 2})
  W.run(30, {skip = 9})
  W.inbox('ack', {})
  local arr = evs(W, 'ARRIVAL')[1]
  T.ok(arr.msg:find('alert: none (REFUGE_FAIL Kern+, Innen+ missing)', 1, true), arr.msg)
  T.ok(arr.d.alert:find('^none %(REFUGE_FAIL Kern%+: drink 0<4, food 0<4; Innen%+ missing, paint queued%)$'),
       arr.d.alert)
  T.eq(idx(), 0, 'not sounded: the text says none')
  local f = evs(W, 'REFUGE_FAIL')
  T.ok(#f >= 1 and f[#f].msg:find('no confinement, the whole fort; Innen+ missing', 1, true), f[#f] and f[#f].msg)
  for _ = 1, 10 do
    W.run(100, {skip = 9})
    T.eq(#acts_since(W, 'civ_alert', t0), 0, 'neither on nor off while no burrow is usable')
  end
  W.act_result('burrow_tiles', W.paint_fn)     -- the burrows screen works again; the next daily ask paints Innen+
  local n = 0
  while idx() == 0 and holding(W) and n < 40 do W.run(100, {skip = 9}); n = n + 1 end
  T.eq({idx(), W.alert_burrows}, {1, {'Innen+'}}, 'confined once the interior burrow exists')
  T.eq(#acts_since(W, 'civ_alert', t0, false), 0)
end)

T.test('BUG-018: an arrival with an open entrance into the hall: "alert: none (REFUGE_FAIL Kern+, citizens flee)"; a ' ..
       'door lost during the lockdown turns the sounding alert off although the lockdown holds it', function()
  local W = fort()
  local t0 = W.K.now().tick
  W.event('INVASION', {id = 6})
  W.run(30, {skip = 9})
  W.inbox('ack', {})
  local arr = evs(W, 'ARRIVAL')[1]
  T.ok(arr.msg:find('alert: none (REFUGE_FAIL Kern+, citizens flee)', 1, true), arr.msg)
  T.ok(arr.d.alert:find('open to 1 entrance 30,13,5 stair_updown', 1, true), arr.d.alert)
  T.eq(idx(), 0)
  local f = evs(W, 'REFUGE_FAIL')
  T.ok(#f >= 1 and f[#f].d.flee == 1 and f[#f].d.fallback == '', f[#f] and f[#f].msg)
  for _ = 1, 10 do
    W.run(100, {skip = 9})
    T.eq(#acts_since(W, 'civ_alert', t0, true), 0, 'never sounded')
  end
  -- the shaft has a door, the lockdown confines to Innen+; the door is destroyed: an opening reaches Innen+ now
  local W2 = fort{shaft_door = true}
  W2.event('INVASION', {id = 7})
  W2.run(30, {skip = 9})
  W2.inbox('ack', {})
  T.eq({idx(), W2.alert_burrows}, {1, {'Innen+'}})
  local t1 = W2.K.now().tick
  W2.dyn[SW.key(29, 13, Z)] = nil
  SW.draw(W2, Z, {'.'}, 29, 13)
  SW.regroup(W2)
  W2.inbox('inspect', {what = 'entrances', key = 'refresh'})
  W2.run(100, {skip = 9})
  T.ok(holding(W2), 'the lockdown still holds the alert')
  T.eq(idx(), 0, 'switched off: confined, the citizens would wait in the attackers\' path')
  T.eq(#acts_since(W2, 'civ_alert', t1, false), 1)
  local f2 = evs(W2, 'REFUGE_FAIL')
  T.ok(#f2 >= 1 and f2[#f2].d.flee == 1 and f2[#f2].d.open[1] == '30,13,5 stair_updown', f2[#f2] and f2[#f2].msg)
end)

T.test('BUG-012: the door one tile behind the stair opening is forbidden, the shaft is named, the undo opens ' ..
       'exactly that door', function()
  local W = fort()
  local ok, x = W.K.call('seal', 'entrance_doors')
  T.ok(ok and x, 'seal exposes the entrance doors')
  T.eq(#x.doors, 1)
  T.eq({x.doors[1].id, x.doors[1].pos}, {W.stair_door.id, {19, 10, Z}})
  T.eq(x.open, {{pos = {30, 13, Z}, kind = 'stair_updown'}})
  W.event('INVASION', {id = 3})
  W.run(30, {skip = 9})
  W.inbox('ack', {})
  local arr = evs(W, 'ARRIVAL')[1]
  T.ok(arr.msg:find('doors 1 forbidden, partial lockdown: stair_updown 30,13,5 has no door', 1, true), arr.msg)
  T.eq(arr.d.doors, 1)
  T.eq({W.stair_door.door_flags.forbidden, W.room_door.door_flags.forbidden}, {true, false})
  -- the player locks the bedroom during the lockdown; the fresh entrance check (asked for by the lockdown) and
  -- later checks never add it and never forbid the stair door twice
  W.room_door.door_flags.forbidden = true
  W.run(1200, {skip = 9})
  T.eq(#W.find_acts('door_forbid'), 1)
  local n = 0
  while holding(W) and n < 80 do W.run(100, {skip = 9}); n = n + 1 end
  W.run(300, {skip = 9})
  local e = evs(W, 'LOCKDOWN_END')
  T.eq(#e, 1)
  T.ok(e[1].msg:find('; 1 doors opened', 1, true), e[1].msg)
  T.eq({W.stair_door.door_flags.forbidden, W.room_door.door_flags.forbidden}, {false, true},
       'the undo opens the door it forbade, never the player\'s')
  local opened = {}
  for _, a in ipairs(W.find_acts('door_forbid')) do if a.args[2] == false then opened[#opened + 1] = a.args[1] end end
  T.eq(opened, {W.stair_door.id})
end)

-- the follow-up of BUG-012 (citizens shut out): a woodcutter on the field at 24,9 when the arrival comes
local function woodcutter() return {id = 9, pos = {24, 9, Z + 1}, citizen = true, adult = true} end

T.test('BUG-012 safety: the door waits while a citizen is outside it, and is forbidden once he came in', function()
  local W = fort{units = {woodcutter()}}
  local ok, per, n = W.K.call('seal', 'door_outside', {W.stair_door.id})
  T.eq({ok, per[W.stair_door.id], n}, {true, 1, 1}, 'the woodcutter is on the open sky of the door\'s walk group')
  W.event('INVASION', {id = 4})
  W.run(30, {skip = 9})
  W.inbox('ack', {})
  local arr = evs(W, 'ARRIVAL')[1]
  T.ok(arr.msg:find('doors 0 forbidden, 1 waiting for 1 citizen outside, partial lockdown: stair_updown 30,13,5', 1,
       true), arr.msg)
  T.eq(W.stair_door.door_flags.forbidden, false, 'not locked out')
  local a = W.state().alarm
  T.eq({a.doors, a.dwait, a.dout}, {0, 1, 1}, 'status: 1 door waiting for 1 citizen outside')
  T.eq(idx(), 0, 'BUG-018: the shaft without a door leads into the hall, no separated burrow: no confinement')
  W.move(9, 20, 10, Z)                         -- on the stair: inside, but still on the porch outside the door
  W.run(100, {skip = 9})
  T.eq(W.stair_door.door_flags.forbidden, false, 'the porch is still outside the door')
  W.move(9, 9, 12, Z)                          -- in the hall, behind the door
  W.run(40, {skip = 9})
  T.eq(W.stair_door.door_flags.forbidden, true, 'forbidden once nobody is left outside')
  local t = W.find_acts('door_forbid')[1].tick
  T.ok(t - arr.tick < 450, 'before the deadline: ' .. (t - arr.tick))
  a = W.state().alarm
  T.eq({a.doors, a.dwait, a.dout}, {1, nil, nil})
end)

T.test('BUG-012 safety: a hostile near the door forbids it at once; a citizen who stays out does not hold it past ' ..
       'ALERT_AFTER', function()
  -- a goblin at 24,13 on the field, 5 tiles from the door, comes into sight: the first armed hostile in sight starts
  -- the lockdown
  local W = fort{units = {woodcutter(), S.inv(300, 24, 13, Z + 1, {hidden = true})}}
  W.unit(300)._m.hidden = false
  W.run(60, {skip = 9})
  local arr = evs(W, 'ARRIVAL')
  T.eq({#arr, arr[1] and arr[1].d.kind}, {1, 'invader'})
  T.eq(W.stair_door.door_flags.forbidden, true, 'a hostile within 15 tiles: at once, the woodcutter notwithstanding')
  T.ok(arr[1].msg:find('doors 1 forbidden', 1, true), arr[1].msg)
  -- the woodcutter alone, nobody near: the deadline
  local W2 = fort{units = {woodcutter()}}
  W2.event('INVASION', {id = 5})
  W2.run(30, {skip = 9})
  W2.inbox('ack', {})
  local t0 = evs(W2, 'ARRIVAL')[1].tick
  W2.run(300, {skip = 9})
  T.eq(W2.stair_door.door_flags.forbidden, false, 'still waiting for him')
  W2.run(200, {skip = 9})
  T.eq(W2.stair_door.door_flags.forbidden, true, 'ALERT_AFTER after the trigger')
  local t = W2.find_acts('door_forbid')[1].tick
  T.ok(t - t0 >= 450 and t - t0 <= 480, tostring(t - t0))
end)

T.test('BUG-012: a ramp opening with a door two tiles behind it on the level below; a bridge on a route is a gate; ' ..
       'revealed tiles only', function()
  -- surface z 6 field with the tops of ramps at 10,20 and 14,20; fort z 5: ramp 10,20, corridor 10,21, door 10,22,
  -- hall beyond; a side passage behind a hidden tile (11,21) leads to a door at 12,21 that must not be read; ramp
  -- 14,20 with a lowered drawbridge at 14,21 on its way to the hall (closed by the gates, not "no door")
  local W = SW.new{persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}}}}
  W.ms_per_frame = 100
  SW.fill(W, Z + 1, 0, 0, 30, 30, ',')
  SW.draw(W, Z + 1, {'^'}, 10, 20, {outside = true})
  SW.draw(W, Z + 1, {'^'}, 14, 20, {outside = true})
  SW.fill(W, Z, 0, 0, 30, 30, '#')
  SW.draw(W, Z, {'r'}, 10, 20)
  SW.draw(W, Z, {'.?+'}, 10, 21)
  SW.draw(W, Z, {'+'}, 10, 22)
  SW.draw(W, Z, {'r'}, 14, 20)
  SW.draw(W, Z, {'='}, 14, 21)
  SW.draw(W, Z, {'.'}, 14, 22)
  SW.fill(W, Z, 5, 23, 15, 28, '.')
  SW.regroup(W)
  SW.citizens(W, {{1, 8, 25, Z}, {2, 9, 26, Z}})
  package.loaded['dfllm.seal'] = nil
  W.load(require('dfllm.seal'))
  W.run(600, {skip = 9})
  local r = W.inbox('inspect', {what = 'entrances'})
  local d = r.data
  T.eq({d.sealed, d.routes}, {false, 2}, r.msg)
  local by = {}
  for _, o in ipairs(d.openings) do by[o.pos[1]] = o end
  T.eq({by[10].pos, #by[10].doors, by[10].gate}, {{10, 20, Z}, 1, 0})
  T.eq({by[14].pos, #by[14].doors, by[14].gate}, {{14, 20, Z}, 0, 1})
  local ok, x = W.K.call('seal', 'entrance_doors')
  T.ok(ok and x)
  local door = W.dyn[SW.key(10, 22, Z)]
  T.eq(#x.doors, 1, 'the door behind the hidden tile is never found')
  T.eq({x.doors[1].id, x.doors[1].pos, #x.open}, {door.id, {10, 22, Z}, 0})
  T.eq(W.hidden_wg, 0, 'no walk group of a hidden tile was read')
end)

T.done()
