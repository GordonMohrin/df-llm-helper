-- reflex (FR-36/49/51/52/53/58): the arrival lockdown and the interrupt channel on the siege world (k_mock, strict
-- contract checks). Run 9: an army walked in over lowered drawbridges the kernel did not know (no manifest); the
-- kernel woke the operator only at BREACH and its seal failed closed.
local T = require('testlib')
local S = require('siege_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')
local C = require('dfllm.util.contract')
local Z = S.Z

local function door(W, id, x, y, forbidden)
  local b = W.add_building{id = id, _kind = 'door', x1 = x, y1 = y, x2 = x, y2 = y, z = Z, centerx = x, centery = y,
                           door_flags = {forbidden = forbidden == true}}
  b.getType = function() return df.building_type.Door end
  df.global.world.buildings.other.DOOR:insert('#', b)
  return b
end

-- the siege world plus doors, open-sky tiles north of O1, a snapshot stand-in (real outside_near), the reflex module
-- and the arbiter. opts.manifest = false: the bridges and levers exist, the fort has no manifest (Run 9).
local function setup(opts)
  opts = opts or {}
  local dir = H.tmpdir(opts.tag or 'r')
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local W = S.world{manifest = opts.manifest, units = opts.units or S.fort_units(), dfpath = dir, cfg = opts.cfg,
                    ms_per_frame = opts.ms_per_frame, tiefe = opts.tiefe, kern = opts.kern, mode = opts.mode,
                    persist = opts.persist}
  W.dir = dir
  df.building_type.Door = 23
  df.global.world.status.popups = kmock.vec{}
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  package.loaded['plugins.overlay'] = nil
  W.act_result('door_forbid', function(id, on)
    local b = W.buildings[id]
    if not b or b._kind ~= 'door' then return false, 'not a door' end
    local old = b.door_flags.forbidden
    b.door_flags.forbidden = on and true or false
    return true, old
  end)
  W.act_result('dismiss_popup', function(kind)        -- act.lua: close the front popup
    local p = df.global.world.status.popups
    if #p == 0 then return false, 'no popup' end
    p:erase(0)
    return true, kind
  end)
  W.tiles = {}
  for x = 40, 70 do W.tiles[x .. ',7,' .. Z] = {des = {outside = true}} end
  W.doors = {entrance = door(W, 501, 51, 8), inner = door(W, 502, 60, 70), own = door(W, 503, 52, 8, true)}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far(K, x, y, z) return W.far_fn ~= nil and W.far_fn(x, y, z) or false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  for _, n in ipairs({'reflex', 'arbiter'}) do package.loaded['dfllm.' .. n] = nil end
  local mods = {S.military(), snap}
  if opts.reflex ~= false then mods[#mods + 1] = require('dfllm.reflex') end
  mods[#mods + 1] = require('dfllm.arbiter')
  for _, m in ipairs(opts.extra or {}) do mods[#mods + 1] = m end
  S.load(W, mods)
  return W
end

local function events(W, t)
  local r = {}
  for _, e in ipairs(W.events) do if e.type == t then r[#r + 1] = e end end
  return r
end
local function cap(W) return W.settings.fps_cap end
local function alarm_txt(W) return H.read(W.dir .. '/dfllm-runtime/mock/alarm.txt') end
local function popup(W, text) df.global.world.status.popups:insert('#', {text = text}) end

T.test('contract: reflex module, door_forbid, ack verb, interrupts are class A, SIEGE_START/INVASION wake', function()
  local names = {}
  for _, m in ipairs(C.MODULES) do names[#names + 1] = m.name end
  T.eq({names[4], names[5]}, {'gate', 'reflex'})
  T.eq(C.ACT.door_forbid, {'reflex'})
  T.eq(C.VERBS.ack.mod, 'reflex')
  for t in pairs(C.INTERRUPTS) do T.eq(C.EVENTS[t].cls, 'A', t) end
  T.eq({C.EVENTS.SIEGE_START.cls, C.EVENTS.INVASION.cls}, {'A', 'A'})
end)

T.test('fort without a manifest: the arrival popup locks down at once (gates, doors, alert, clock), then dismissed', function()
  local W = setup{tag = 'nomanifest', manifest = false}
  S.run(W, 200)
  T.eq(#S.pulls(W), 0, 'PEACE: nothing pulled')
  T.eq(cap(W), nil, 'PEACE: the FPS cap is left alone')
  popup(W, 'A vile force of darkness has arrived!')
  df.global.pause_state = false                      -- DF 53 halts on the popup with pause_state false
  S.run(W, 400)
  local arr = events(W, 'ARRIVAL')
  T.eq(#arr, 1)
  T.eq({arr[1].cls, arr[1].d.kind, arr[1].d.src}, {'A', 'siege', 'popup'})
  T.ok(arr[1].d.text:find('vile force', 1, true), arr[1].d.text)
  T.ok(arr[1].msg:find('gates: 0 of 3 up, 3 pulls pending', 1, true), arr[1].msg)
  T.eq({arr[1].d.raised, arr[1].d.up, arr[1].d.left, arr[1].d.blocked}, {3, 0, 3, 0})
  T.eq(#df.global.world.status.popups, 0, 'FR-36: dismissed after the reflexes')
  -- gates: every lever-linked bridge (O1, B1, B2 buildings exist, no manifest): one pull each, no double pull
  T.eq(#S.pulls(W), 3)
  T.eq(W.pending_violations, 0)
  -- doors: only the entrance next to the open sky; the player's forbidden one stays his
  T.eq({W.doors.entrance.door_flags.forbidden, W.doors.inner.door_flags.forbidden, W.doors.own.door_flags.forbidden},
       {true, false, true})
  T.eq(#S.acts(W, 'door_forbid'), 1)
  -- clock at once; the civ alert waits for the gates (live L3: it keeps civilians away from the levers)
  T.eq({cap(W), W.timestream_fps}, {30, -1})
  T.ok(arr[1].msg:find('alert: after the gates', 1, true), arr[1].msg)
  local st = W.state()
  T.eq({st.alarm.defcon, st.alarm.lock, st.alarm.unacked, st.alarm.why}, {2, 1, 1, 'arrival:siege'})
  T.eq({st.clock.cap, st.clock.held, st.clock.ts, st.owners.tempo}, {30, 1, -1, 'clock'})
  T.eq(C.check_state(st), {})
  local txt = alarm_txt(W)
  T.ok(txt and txt:find('^DEFCON 2 | mode PEACE | unacked 1'), txt)
  T.ok(txt:find('\tARRIVAL\tunacked\tsiege %(popup%)'), txt)
  -- the bridges rise; lever latency is measured from the queued pull to the raised bridge
  S.run(W, 300)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1'), S.bstate(W, 'B2')}, {'up', 'up', 'up'})
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 1, 'alert on once the gates are up')
  T.eq(W.alert_burrows, {'Kern+'})
  local on = S.acts(W, 'civ_alert', function(a) return a.args[1] == true end)[1]
  local last_up = 0
  for _, f in ipairs(W.flips) do if f.to == 'up' and f.tick > last_up then last_up = f.tick end end
  T.ok(on and on.tick >= last_up and on.tick > arr[1].tick, 'the alert came after the gates were pulled')
  st = W.state()
  T.eq({st.bridges.X1, st.bridges.X2, st.bridges.X3}, {'up', 'up', 'up'})
  T.ok(st.lever.lat_t >= 70 and st.lever.lat_t <= 140, tostring(st.lever.lat_t))
  T.eq(st.lever.pend, 0)
  -- quiet: ARM + 2 days; then doors open again, the bridges the lockdown raised come down (D-14 down), clock free
  W.inbox('ack', {})
  S.run(W, 5200)
  T.eq(#events(W, 'LOCKDOWN_END'), 1)
  T.eq(W.doors.entrance.door_flags.forbidden, false)
  T.eq(W.doors.own.door_flags.forbidden, true, 'never opens a door it did not forbid')
  S.run(W, 400)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1'), S.bstate(W, 'B2')}, {'down', 'down', 'down'})
  T.eq({cap(W), W.timestream_fps}, {250, 500})
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 0)
  st = W.state()
  T.eq({st.alarm.defcon, st.alarm.lock, st.clock.held}, {5, 0, 0})
  T.eq(st.bridges, nil, 'the unmanaged bridges are handed back')
  T.eq(W.pending_violations, 0)
end)

T.test('peace_gates up (D-14): the bridges a lockdown raised stay up afterwards', function()
  local W = setup{tag = 'd14up', manifest = false, cfg = {decisions = {['D-14'] = 'up'}}}
  W.event('INVASION', {id = 31})
  S.run(W, 400)
  local inv = events(W, 'INVASION')
  T.eq({#inv, inv[1].cls}, {1, 'A'})
  T.eq(events(W, 'ARRIVAL')[1].d.kind, 'invasion')
  W.inbox('ack', {})
  S.run(W, 7600)
  T.eq(#events(W, 'LOCKDOWN_END'), 1)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1'), S.bstate(W, 'B2')}, {'up', 'up', 'up'})
  T.eq(#S.pulls(W), 3, 'raised once, never lowered')
end)

T.test('manifest fort: the lockdown raises O1/B1 (not the core seal) in PEACE and refuses down while it holds', function()
  local W = setup{tag = 'manifest'}
  W.event('REPORT', {type = 'AMBUSH_SNATCHER', text = 'Snatcher! Protect the children!'})
  S.run(W, 30)
  local arr = events(W, 'ARRIVAL')
  T.eq({#arr, arr[1].d.kind, arr[1].d.src}, {1, 'snatcher', 'report'})
  T.eq(W.K.mode(), 'PEACE', 'an announcement alone does not start a siege')
  local ok, ok2, msg = W.K.call('gate', 'want', 'O1', 'down', 'trade')
  T.eq({ok, ok2, msg}, {true, false, 'down refused: lockdown'})
  S.run(W, 300)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1'), S.bstate(W, 'B2')}, {'up', 'up', 'down'})
  T.eq(W.state().bridges.X3, nil, 'manifest bridges are not handled twice')
  T.eq(#S.pulls(W), 2)
  W.inbox('ack', {})
  S.run(W, 5600)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {'down', 'down'}, 'D-14 down: back to the PEACE mode table')
end)

T.test('peace_gates up on a manifest fort: O1/B1 up in PEACE; a caravan or migrants open a window', function()
  local trade = {name = 'trade', every = {ticks = 100}, caravan = 0}
  function trade.state(K) return {trade = {caravan = trade.caravan, ratio = 0, done = 0}} end
  local W = setup{tag = 'peaceup', cfg = {decisions = {['D-14'] = 'up'}}, extra = {trade}}
  S.run(W, 700)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1'), S.bstate(W, 'B2')}, {'up', 'up', 'down'})
  trade.caravan = 1
  S.run(W, 1300)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {'down', 'down'}, 'caravan window')
  trade.caravan = 0
  S.run(W, 1300)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {'up', 'up'}, 'closed WIN_CLOSE after the caravan left')
  W.event('REPORT', {type = 'MIGRANT_ARRIVAL', text = 'Some migrants have arrived.'})
  S.run(W, 700)
  T.eq(S.bstate(W, 'O1'), 'down', 'migrant window')
  S.run(W, 3000)
  T.eq(S.bstate(W, 'O1'), 'up')
  T.eq(W.pending_violations, 0)
end)

T.test('the first armed hostile in sight locks down; INTRUDER on the citizens walkable group; ETA', function()
  local units = S.fort_units()
  units[#units + 1] = S.inv(300, 51, 0)              -- at the map edge north of O1
  local W = setup{tag = 'sighting', manifest = false, units = units}
  S.run(W, 120)
  local arr = events(W, 'ARRIVAL')
  T.eq({#arr, arr[1].d.kind, arr[1].d.src}, {1, 'invader', 'sighting'})
  local intr = events(W, 'INTRUDER')
  T.eq({#intr, intr[1].d.id, intr[1].d.k}, {1, 300, 'inv'})
  T.eq(W.state().alarm.eta, 8 * 6, 'Chebyshev 8 tiles to the nearest entrance door x 6 ticks')
  T.eq(W.state().alarm.defcon, 1, 'an unacked INTRUDER is DEFCON 1')
  S.run(W, 2000)
  T.eq(#events(W, 'INTRUDER'), 1, 'once per episode')
  W.far_fn = function() return true end              -- the bridges are up: the invader is cut off
  W.inbox('ack', {})
  T.eq(W.state().alarm.unacked, 0)
end)

T.test('PREDATOR: a wild danger on a roofed tile of the citizens group; none on the open surface', function()
  local units = S.fort_units()
  units[#units + 1] = S.danger(400, 45, 7)           -- outside (open sky row y=7)
  local W = setup{tag = 'predator', manifest = false, units = units}
  S.run(W, 200)
  T.eq(#events(W, 'PREDATOR'), 0)
  W.move(400, 62, 72, Z)                             -- inside the fort
  S.run(W, 200)
  local p = events(W, 'PREDATOR')
  T.eq({#p, p[1].d.id}, {1, 400})
  T.eq(#events(W, 'ARRIVAL'), 0, 'a wild animal is no army: no lockdown')
end)

T.test('Run 10: a roofed wild danger far from every citizen is PREDATOR_FAR (B), no lockdown; one near a citizen is PREDATOR', function()
  local units = S.fort_units()
  units[#units + 1] = S.danger(400, 150, 30)         -- the map edge, 70+ tiles from Kern+, no citizen outside Kern+
  local W = setup{tag = 'predfar', manifest = false, units = units}
  S.run(W, 200)
  T.eq(#events(W, 'PREDATOR'), 0, 'no class A interrupt')
  local f = events(W, 'PREDATOR_FAR')
  T.eq({#f, f[1].cls, f[1].d.id, f[1].d.dc}, {1, 'B', 400, -1})
  T.eq(#events(W, 'LOCKDOWN'), 0)
  T.eq(W.state().alarm.unacked, 0, 'nothing to ack, no clock hold')
  -- a woodcutter walks out to 12 tiles from it: now it is a danger to a citizen
  W.move(2, 138, 30, Z)
  S.run(W, 200)
  local p = events(W, 'PREDATOR')
  T.eq({#p, p[1].d.id}, {1, 400})
end)

T.test('Run 10: reflex.predator_near 0 keeps the old rule (any roofed wild danger on the citizens group)', function()
  local units = S.fort_units()
  units[#units + 1] = S.danger(400, 150, 30)
  local W = setup{tag = 'prednear0', manifest = false, units = units, cfg = {reflex = {v = 2, predator_near = 0}}}
  S.run(W, 200)
  T.eq(#events(W, 'PREDATOR'), 1)
  T.eq(#events(W, 'PREDATOR_FAR'), 0)
end)

T.test('ack timeout: an unacked DEATHS_3PLUS gets its default (clock) and LOCKDOWN says so; acked ones do not', function()
  local W = setup{tag = 'acktimeout', manifest = false, ms_per_frame = 500}
  W.K.emit('DEATHS_3PLUS', 'A', '3 citizens died today', {n = 3, ids = {1, 2, 3}})
  S.run(W, 20)
  T.ok(alarm_txt(W):find('\tDEATHS_3PLUS\tunacked\t3 citizens died today'), alarm_txt(W))
  T.eq(W.state().alarm.unacked, 1)
  S.run(W, 9 * 140)                                  -- 140 frames x 0.5 s = 70 s
  local l = events(W, 'LOCKDOWN')
  T.eq(#l, 1)
  T.eq({l[1].cls, l[1].d.why, l[1].d.type}, {'A', 'ack_timeout', 'DEATHS_3PLUS'})
  T.ok(l[1].msg:find('kernel applied its default: clock 30 t/s', 1, true), l[1].msg)
  T.eq({cap(W), W.timestream_fps}, {30, -1})
  T.eq(#S.pulls(W), 0, 'the clock-only default pulls no lever')
  T.eq(#S.acts(W, 'door_forbid'), 0)
  T.ok(alarm_txt(W):find('\tDEATHS_3PLUS\tdefault\t'), alarm_txt(W))
  local r = W.inbox('ack', {})
  T.eq(r.ok, true)
  T.ok(r.msg:find('^acked up to #'), r.msg)
  W.K.emit('DEATHS_3PLUS', 'A', '3 more', {n = 3})
  S.run(W, 9 * 10)
  W.inbox('ack', {})
  S.run(W, 9 * 140)
  T.eq(#events(W, 'LOCKDOWN'), 1, 'acked in time: no second default')
  T.eq(W.inbox('ack', {n = -1}).ok, false)
end)

T.test('NO_DEPOT: the merchants-need-a-depot report and popup are an interrupt, without a lockdown', function()
  local W = setup{tag = 'nodepot', manifest = false}
  W.event('REPORT', {type = 'MERCHANTS_NEED_DEPOT', text = 'The merchants need a trade depot to unload their goods.'})
  S.run(W, 30)
  T.eq(#events(W, 'NO_DEPOT'), 1)
  popup(W, 'The merchants need a trade depot to unload their goods.')
  S.run(W, 400)
  T.eq(#events(W, 'NO_DEPOT'), 1, 'once per day')
  T.eq(#df.global.world.status.popups, 0, 'the caravan notice is still dismissed')
  T.eq({W.state().alarm.lock, #S.pulls(W)}, {0, 0})
end)

T.test('BUG-008: one NO_DEPOT per caravan visit; a new caravan is told, the same one never again', function()
  local W = setup{tag = 'nodepot2', manifest = false}
  df.caravan_state = {T_trade_state = {[0] = 'None', [1] = 'Approaching', [2] = 'AtDepot', [3] = 'Leaving'}}
  df.global.plotinfo.caravans = kmock.vec{{entity = 77, trade_state = 1}}
  local function need() W.event('REPORT', {type = 'MERCHANTS_NEED_DEPOT', text = 'The merchants need a trade depot.'}) end
  need()
  S.run(W, 30)
  T.eq(#events(W, 'NO_DEPOT'), 1)
  for _ = 1, 4 do                                  -- DF repeats the notice while the merchants wait (days apart)
    S.run(W, 3000)
    W.ms = W.ms + 700000
    need()
  end
  S.run(W, 30)
  T.eq(#events(W, 'NO_DEPOT'), 1, 'the same visit: never again')
  df.global.plotinfo.caravans:insert('#', {entity = 88, trade_state = 1})
  need()
  S.run(W, 30)
  T.eq(#events(W, 'NO_DEPOT'), 2, 'a second caravan on the map')
  df.global.plotinfo.caravans = kmock.vec{}         -- both left
  S.run(W, 200)
  df.global.plotinfo.caravans = kmock.vec{{entity = 77, trade_state = 1}}
  need()
  S.run(W, 30)
  T.eq(#events(W, 'NO_DEPOT'), 3, 'the next visit of the first civ')
  T.eq(W.K.persist.get('m.reflex').depot.ents, {['77'] = 1})
  df.global.plotinfo.caravans, df.caravan_state = nil, nil
end)

T.test('BUG-008: without a readable caravan NO_DEPOT repeats only after max(7 game days, 10 min)', function()
  local W = setup{tag = 'nodepot3', manifest = false}
  local function need() W.event('REPORT', {type = 'MERCHANTS_NEED_DEPOT', text = 'The merchants need a trade depot.'}) end
  need()
  S.run(W, 30)
  S.run(W, 9000)
  need()
  S.run(W, 30)
  T.eq(#events(W, 'NO_DEPOT'), 1, '7 game days but seconds of wall clock')
  W.ms = W.ms + 600000
  need()
  S.run(W, 30)
  T.eq(#events(W, 'NO_DEPOT'), 2)
end)

T.test('fail-open: without the reflex module the arbiter holds the clock on a threat popup and says so', function()
  local W = setup{tag = 'noreflex', manifest = false, reflex = false}
  popup(W, 'Snatcher! Protect the children!')
  S.run(W, 400)
  local arr = events(W, 'ARRIVAL')
  T.eq(#arr, 1)
  T.ok(arr[1].msg:find('reflex module unavailable', 1, true), arr[1].msg)
  T.eq({cap(W), W.timestream_fps}, {30, -1})
  T.eq(#df.global.world.status.popups, 0)
  S.run(W, 5000)
  T.eq(cap(W), 250, 'the fallback clamp ends after FALLBACK_TICKS')
end)

T.test('alert without a Kern+ burrow: the lockdown reports it instead of failing silently', function()
  local W = setup{tag = 'noburrow', manifest = false, tiefe = false}
  for i = #df.global.plotinfo.burrows.list - 1, 0, -1 do df.global.plotinfo.burrows.list:erase(i) end
  dfhack.burrows.findByName = function() return nil end
  W.event('INVASION', {id = 2})
  S.run(W, 30)
  T.eq(#S.pulls(W), 3, 'the other reflexes still run')
  S.run(W, 300)
  local said
  for _, l in ipairs(W.logs) do if l.msg:find('civ alert: none (no burrow Kern+) (gates up)', 1, true) then said = true end end
  T.ok(said, 'kern.log names the missing burrow')
  T.ok(#S.acts(W, 'alert_burrows') <= 1, 'one try per RETRY window, no ACT_FAIL spam')
end)

T.test('BUG-013: the deferred alert waits for the pulls up to its deadline (900 ticks before a lever latency was ' ..
       'measured, else 2x it, 450..1500), and not at all for a citizen outside (Run 11: the recall) or a hostile near ' ..
       'one', function()
  local units = S.fort_units()                       -- everybody in Kern+ (the soldier does not count)
  local W = setup{tag = 'alertnear', manifest = false, units = units}
  W.lever_default = {}                               -- nobody takes the pulls: the gates never rise
  W.event('INVASION', {id = 3})
  S.run(W, 60)
  local t0 = events(W, 'ARRIVAL')[1].tick
  T.ok(events(W, 'ARRIVAL')[1].msg:find('alert: after the gates (<= 900 ticks)', 1, true), events(W, 'ARRIVAL')[1].msg)
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 0)
  S.run(W, 800)
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 0, 'T+860: the pulls are still pending')
  S.run(W, 100)
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 1, 'the deadline: the alert does not wait for ever')
  local on = S.acts(W, 'civ_alert', function(a) return a.args[1] == true end)[1]
  T.ok(on.tick - t0 >= 900 and on.tick - t0 <= 920, 'T+' .. (on.tick - t0))
  local said
  for _, l in ipairs(W.logs) do
    local want = 'civ alert: Kern+ (deadline 900 ticks, 3 pulls left); gates: 0 of 3 up, 3 pulls pending'
    if l.msg:find(want, 1, true) then said = true end
  end
  T.ok(said, 'kern.log names the deadline and the pulls left')
  local units2 = S.fort_units()
  units2[#units2 + 1] = S.cit(9, 45, 9)              -- a woodcutter outside Kern+
  local W2 = setup{tag = 'alertnear2', manifest = false, units = units2}
  W2.lever_default = {}
  S.run(W2, 30)                                      -- sense's first census
  W2.event('INVASION', {id = 4})
  S.run(W2, 20)
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 1, 'Run 11: a citizen outside: at once (the recall), pulls pending')
  local a2 = events(W2, 'ARRIVAL')[1]
  T.ok(a2.msg:find('alert: Kern+, recall: 1 outside Kern+', 1, true), a2.msg)
  W2.add_unit(S.inv(310, 46, 12))
  S.run(W2, 60)
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 1, 'a hostile 3 tiles from the woodcutter: still on')
  -- a lever latency measured before: 2 x 300 ticks
  local W3 = setup{tag = 'alertlat', manifest = false, units = units,
                   persist = {['m.gate'] = {v = 2, br = {}, kpi = {}, lat = {s = 10, t = 300}}}}
  W3.lever_default = {}
  W3.event('INVASION', {id = 5})
  S.run(W3, 60)
  local a3 = events(W3, 'ARRIVAL')[1]
  T.ok(a3.msg:find('alert: after the gates (<= 600 ticks)', 1, true), a3.msg)
  S.run(W3, 500)
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 0)
  S.run(W3, 100)
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 1, '2 x the measured latency')
end)

T.test('a reload mid-lockdown keeps it (persisted hold, doors, interrupts)', function()
  local W = setup{tag = 'reload', manifest = false}
  W.event('INVASION', {id = 5})
  S.run(W, 30)
  local p = json.decode(W.persist_raw['dfllm.m.reflex'])
  T.eq({p.hold.why, p.doors, #p.irq}, {'arrival:invasion', {501}, 1})
  local R = require('dfllm.reflex')
  R.init(W.K)
  T.eq(R.holding(W.K, 'gates'), 'arrival:invasion')
  T.eq(R.holding(W.K, 'nothing'), nil)
end)

T.test('a siege on a fort without a manifest: SIEGE_START is class A, the seal is counted (no more sealed 0 ticks)', function()
  local units = S.fort_units()
  for _, u in ipairs(S.army(8, 50, 0)) do units[#units + 1] = u end
  local W = setup{tag = 'siege', manifest = false, units = units}
  S.run(W, 120)
  local ss = events(W, 'SIEGE_START')
  T.eq({#ss, ss[1].cls, W.K.mode()}, {1, 'A', 'SIEGE'})
  T.eq(events(W, 'ARRIVAL')[1].d.kind, 'invader')
  T.eq({cap(W), W.timestream_fps}, {30, -1})
  S.run(W, 1500)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1'), S.bstate(W, 'B2')}, {'up', 'up', 'up'})
  for i = 201, 208 do W.kill(i) end
  W.inbox('ack', {})
  S.run(W, 12000)
  local se = events(W, 'SIEGE_END')
  T.eq(#se, 1)
  T.ok(se[1].d.sealed_ticks > 9000, se[1].msg)
  T.eq(W.K.mode(), 'PEACE')
  S.run(W, 600)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1'), S.bstate(W, 'B2')}, {'down', 'down', 'down'}, 'D-14 down, in PEACE')
  T.eq(cap(W), 250)
  T.eq(W.pending_violations, 0)
end)

T.test('snapshot.outside_near: revealed open-sky tiles within r on the same z; hidden ones never count', function()
  local W = kmock.new{}
  W.tiles = {['5,5,3'] = {des = {outside = true}}, ['9,9,3'] = {des = {outside = true, hidden = true}}}
  local f = require('dfllm.snapshot').outside_near
  T.eq(f(W.K, {{4, 4, 3}, {5, 5, 3}, {7, 7, 3}, {8, 8, 3}, {5, 5, 4}, {'x'}}, 1), {1, 1, 0, 0, 0, -1})
  T.eq(f(W.K, {{4, 4, 3}, {5, 5, 3}}, 0), {0, 1})
end)

---------------------------------------------------------------- Run 11: the lockdown expires far (site98 y439)
-- Live: ALERT and an arrival:ambush lockdown for 45 days (clock 30 t/s, 6 doors forbidden, idle 68 %, 9 t/s instead of
-- 400) for ONE invader, ELK_BIRD 28188 at 184,1,144 at the map edge (the citizens' walk group, 100+ tiles from
-- everybody): LOCKDOWN_END needed threat 0 for hold_quiet_days, which never came.
local ELK, GOB, GREM = 88, 89, 90
local function raws()
  local elk = {flags = {CAN_LEARN = false, CAN_SPEAK = false, MOUNT_EXOTIC = true}}
  local gob = {flags = {CAN_LEARN = true, CAN_SPEAK = true}}
  df.creature_raw = {find = function(r)
    if r == ELK then return {caste = {[0] = elk}} elseif r == GOB or r == GREM then return {caste = {[0] = gob}} end
  end}
end
local function add(W, spec, race)
  local u = W.add_unit(spec)
  u.race, u.caste = race, 0
  return u
end
local function logged(W, pat)
  for _, l in ipairs(W.logs) do if l.msg:find(pat, 1, true) then return l.msg end end
end

T.test('Run 11: an ELK_BIRD invader (a mount: no CAN_LEARN/CAN_SPEAK) 130 tiles away is no invader: no INTRUDER, no ' ..
       'ALERT, the ambush lockdown ends after hold_quiet_days naming it (cause far); near a citizen it is a PREDATOR', function()
  local W = setup{tag = 'elkbird', manifest = false}
  raws()
  add(W, S.inv(28188, 184, 1, Z, {race = 'ELK_BIRD'}), ELK)
  W.tiles['184,1,' .. Z] = {des = {outside = true}}     -- the open map edge, 132 tiles from the open-sky door 503 (52,8)
  W.event('REPORT', {type = 'AMBUSH_AMBUSHER', text = 'An ambush! Curse them!'})
  S.run(W, 60)
  local arr = events(W, 'ARRIVAL')
  T.eq({#arr, arr[1].d.kind}, {1, 'ambush'})
  local h = W.K.census.h
  T.eq({h.vis, h.inv, h.an, h.list[1].k, h.list[1].an}, {1, 0, 1, 'danger', 1}, 'a wild animal, not an invader')
  W.inbox('ack', {})
  S.run(W, 2400 + 2400 + 400)                           -- ARM, then hold_quiet_days (2) of quiet
  T.eq(#events(W, 'INTRUDER'), 0)
  T.eq(#events(W, 'ALERT_START'), 0, 'old code: ALERT for 45 days')
  T.eq(W.K.mode(), 'PEACE')
  local e = events(W, 'LOCKDOWN_END')
  T.eq(#e, 1, 'old code: the lockdown never ended')
  T.eq({e[1].d.why, e[1].d.cause, e[1].d.nfar}, {'arrival:ambush', 'far', 1})
  T.eq(e[1].d.far, {'animal 28188 ELK_BIRD at 184,1,10 (132 tiles)'})
  T.ok(e[1].msg:find('lockdown over (arrival:ambush): threat 0 for 2 days, 1 far: animal 28188 ELK_BIRD', 1, true),
       e[1].msg)
  T.eq(W.doors.entrance.door_flags.forbidden, false, 'its doors open again')
  T.eq({W.state().alarm.lock, cap(W), W.timestream_fps}, {0, 250, 500})
  T.eq(#events(W, 'ARRIVAL'), 1, 'never an arrival of its own')
  -- a woodcutter outside meets it on a roofed tile: the predator rules (PREDATOR, ALERT), still no arrival lockdown
  W.move(2, 100, 20, Z)
  W.move(28188, 110, 20, Z)
  S.run(W, 300)
  T.eq(#events(W, 'PREDATOR'), 1)
  T.eq(W.K.mode(), 'ALERT', 'threat counts it within predator_near of a citizen outside Kern+')
  T.eq(#events(W, 'ARRIVAL'), 1)
end)

T.test('Run 11: one goblin at the map edge (98 tiles): the lockdown expires after hold_quiet_days (cause far, named), ' ..
       'ALERT ends with it, no new arrival for it; it comes within lockdown_near (40) of an entrance: re-armed at once',
       function()
  local W = setup{tag = 'farinv', manifest = false}
  raws()
  add(W, S.inv(300, 150, 30, Z), GOB)
  S.run(W, 120)
  local arr = events(W, 'ARRIVAL')
  T.eq({#arr, arr[1].d.kind, arr[1].d.src}, {1, 'invader', 'sighting'})
  local intr = events(W, 'INTRUDER')
  T.eq({#intr, intr[1].d.id, intr[1].d.far, intr[1].d.dist}, {1, 300, 1, 98})
  T.ok(intr[1].msg:find('far: 98 tiles from the citizens and entrances', 1, true), intr[1].msg)
  T.eq(W.K.mode(), 'ALERT')
  W.inbox('ack', {})
  S.run(W, 2400 + 2400 + 400)
  local e = events(W, 'LOCKDOWN_END')
  T.eq(#e, 1, 'old code: never (an invader in sight)')
  T.eq({e[1].d.cause, e[1].d.nfar, e[1].d.far}, {'far', 1, {'inv 300 GOBLIN at 150,30,10 (98 tiles)'}})
  T.ok(e[1].msg:find('no invader within 40 tiles of a citizen or an entrance for 2 days, 1 far: inv 300', 1, true),
       e[1].msg)
  T.eq({W.state().alarm.lock, W.state().alarm.far}, {0, 1})
  S.run(W, 1500)
  T.eq(W.K.mode(), 'PEACE', 'ALERT ends: threat counts the expired-far invader for nothing')
  T.eq(#events(W, 'ALERT_END'), 1)
  S.run(W, 3000)
  T.eq({#events(W, 'ARRIVAL'), #events(W, 'INTRUDER'), #events(W, 'LOCKDOWN')}, {1, 1, 0}, 'no re-arm while it stays far')
  T.eq({W.doors.entrance.door_flags.forbidden, cap(W)}, {false, 250})
  -- the expired-far list survives a reload
  local p = json.decode(W.persist_raw['dfllm.m.reflex'])
  T.eq(p.far.ids, {300})
  -- it walks toward the fort: 18 tiles from the open-sky door 503 (52,8)
  W.move(300, 70, 20, Z)
  S.run(W, 60)
  arr = events(W, 'ARRIVAL')
  T.eq(#arr, 2, 're-armed')
  T.ok(arr[2].d.text:find('inv 300 came within 18 tiles of an entrance after its lockdown ended far', 1, true),
       arr[2].d.text)
  T.ok(logged(W, 'inv 300 at 70,20,10 came within 18 tiles of an entrance after its lockdown ended far'), 'kern.log')
  T.eq({W.state().alarm.lock, W.state().alarm.far, cap(W)}, {1, nil, 30})
  S.run(W, 60)
  T.eq(W.K.mode(), 'ALERT', 'it counts again')
end)

T.test('Run 11: an invader within lockdown_near keeps the lockdown; lockdown_near 0 keeps the old rule; in a siege the ' ..
       'far rule never ends it', function()
  local W = setup{tag = 'nearinv', manifest = false}
  raws()
  add(W, S.inv(300, 80, 20, Z), GOB)                     -- 28 tiles from the door 503
  S.run(W, 60)
  W.inbox('ack', {})
  S.run(W, 6000)
  T.eq(#events(W, 'LOCKDOWN_END'), 0)
  local W2 = setup{tag = 'farinv0', manifest = false, cfg = {reflex = {v = 2, lockdown_near = 0}}}
  raws()
  add(W2, S.inv(300, 150, 30, Z), GOB)
  S.run(W2, 60)
  W2.inbox('ack', {})
  S.run(W2, 6000)
  T.eq(#events(W2, 'LOCKDOWN_END'), 0, 'lockdown_near 0: threat 0 only')
  local units = S.fort_units()
  for _, u in ipairs(S.army(6, 150, 30)) do units[#units + 1] = u end
  local W3 = setup{tag = 'farsiege', manifest = false, units = units}
  S.run(W3, 60)
  T.eq(W3.K.mode(), 'SIEGE')
  W3.inbox('ack', {})
  S.run(W3, 6000)
  T.eq({#events(W3, 'LOCKDOWN_END'), W3.state().alarm.lock}, {0, 1}, 'six invaders in sight: a siege, not far')
end)

T.test('Run 11: the ack timeout applies no default for an INTRUDER whose unit is far (alarm.txt: far); one that ' ..
       'comes near raises a new INTRUDER at once and gets it', function()
  local W = setup{tag = 'farack', manifest = false, ms_per_frame = 500}
  raws()
  add(W, S.inv(300, 150, 30, Z), GOB)
  S.run(W, 30)
  local arr, intr = events(W, 'ARRIVAL'), events(W, 'INTRUDER')
  T.eq({#arr, #intr}, {1, 1})
  W.inbox('ack', {n = arr[1].n})                         -- the arrival seen, the INTRUDER not
  S.run(W, 9 * 140)                                      -- 70 s
  T.eq(#events(W, 'LOCKDOWN'), 0, 'old code: LOCKDOWN unacked:INTRUDER for a unit 98 tiles away')
  T.ok(alarm_txt(W):find('\tINTRUDER\tfar\t'), alarm_txt(W))
  T.ok(logged(W, 'unacked for 6'), 'kern.log')
  T.ok(logged(W, 'its unit 300 is far (98 tiles from the citizens and entrances, lockdown_near 40): no default'),
       'kern.log names why')
  T.eq(W.state().alarm.defcon, 2, 'a far INTRUDER is no DEFCON 1 (the arrival lockdown holds)')
  W.move(300, 70, 20, Z)
  S.run(W, 30)
  intr = events(W, 'INTRUDER')
  T.eq({#intr, intr[2].d.far, intr[2].d.dist}, {2, 0, 18}, 'near after a far-only INTRUDER: at once')
  S.run(W, 9 * 140)
  local l = events(W, 'LOCKDOWN')
  T.eq({#l, l[1].d.type, l[1].d.n}, {1, 'INTRUDER', intr[2].n})
end)

---------------------------------------------------------------- BUG-065 (Run 14): the endless confinement
-- Live: a gremlin in the caves (z91, the fort's walk group) kept the Kern+ lockdown on for months: every project outside
-- Kern+ stalled, no squad went, civ_alert cleared by hand came back within 15 s (the lockdown holds it, level-triggered),
-- the brief said "threat 0 vis". The lockdown had no clock of its own: a hostile near a citizen kept the quiet clock off
-- for ever, and every unacked INTRUDER default engaged it again.
local function gremlin(W, id, x, y, size)
  local u = add(W, S.inv(id, x, y, Z, {race = 'GREMLIN'}), GREM)
  u.body = {size_info = {size_cur = size or 4000}}
  return u
end
local function decisions(W, id)
  local r = {}
  for _, e in ipairs(events(W, 'DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end
local function with_sortie(f)                           -- the military stand-in names a squad to send
  local orig = S.military
  S.military = function() local m = orig(); m.sortie_squad = function() return 'A', 6 end; return m end
  local ok, err = pcall(f)
  S.military = orig
  assert(ok, err)
end
local CONFINE = {reflex = {v = 2, confine = {max_days = 3, offer_days = 1}}}

T.test('BUG-065: a lone small intruder near a citizen holds the lockdown only for confine.max_days: named, a sortie ' ..
       'offered, then the lockdown ends, civ_alert stays off, the clock is free and the cleared unit counts for nothing',
       function() with_sortie(function()
  local W = setup{tag = 'grem', manifest = false, cfg = CONFINE}
  raws()
  W.move(2, 100, 20, Z)                                  -- a woodcutter outside Kern+
  gremlin(W, 300, 110, 20)                               -- 10 tiles from him, in the fort's walk group
  S.run(W, 120)
  local arr = events(W, 'ARRIVAL')
  T.eq({#arr, arr[1].d.kind, arr[1].d.src}, {1, 'invader', 'sighting'}, 'a lone intruder still starts a lockdown')
  W.inbox('ack', {})
  local a = W.state().alarm
  T.eq(a.lock, 1)
  T.eq({a.by.id, a.by.race, a.by.k, a.by.pos, a.by.dc, a.by.hl, a.by.n}, {300, 'GREMLIN', 'inv', {110, 20, Z}, 10, 1, 1},
       'the state names the cause: unit, race, position, distance to the nearest citizen outside Kern+')
  T.ok(a.by.de >= 0, 'and to the nearest entrance')
  T.eq({a.lim, a.qw}, {3 * 1200, 'near'}, 'the limit, and why the quiet clock does not run')
  T.eq(C.check_state(W.state()), {})
  S.run(W, 1300)
  W.inbox('ack', {})
  local o = decisions(W, 'intruder_sortie')
  T.eq(#o, 1, 'a sortie is offered after offer_days, once')
  T.eq({o[1].cls, o[1].d.unit, o[1].d.squad, o[1].d.hl, o[1].d.pos}, {'A', 300, 'A', 1, {110, 20, Z}})
  T.ok(o[1].d.cmd:find('squad.sortie', 1, true) and o[1].d.cmd:find('"target":[110,20,10]', 1, true)
       and o[1].d.cmd:find('"squad":"A"', 1, true), o[1].d.cmd)           -- (J3: the command is d.cmd, d.q stays within 200 bytes)
  T.ok(#o[1].d.q <= 200, 'd.q is at most 200 bytes: ' .. #o[1].d.q)
  T.ok(o[1].d.q:find('GREMLIN', 1, true) and o[1].d.q:find('10 tiles', 1, true), o[1].d.q)
  S.run(W, 1300)
  W.inbox('ack', {})
  T.eq(#events(W, 'LOCKDOWN_END'), 0, 'inside the limit it holds')
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 1)
  df.global.plotinfo.alerts.civ_alert_idx = 0            -- cleared by hand: the lockdown sounds it again (level-triggered)
  S.run(W, 120)
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 1)
  S.run(W, 1300)
  W.inbox('ack', {})
  local e = events(W, 'LOCKDOWN_END')
  T.eq(#e, 1, 'old code: never')
  T.eq({e[1].d.cause, e[1].d.nfar, e[1].d.far}, {'limit', 1, {'inv 300 GREMLIN at 110,20,10 (10 tiles)'}})
  T.ok(e[1].msg:find('confinement limit of 3 days', 1, true) and e[1].msg:find('harmless', 1, true), e[1].msg)
  T.eq({W.state().alarm.lock, W.state().alarm.far}, {0, 1})
  T.eq(W.doors.entrance.door_flags.forbidden, false, 'its doors open again')
  S.run(W, 700)                                          -- ALERT's own 600-tick hold on the civ alert runs out
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 0, 'civ_alert off and not sounded again')
  S.run(W, 1700)
  T.eq(W.K.mode(), 'PEACE', 'ALERT ends with it')
  T.eq({cap(W), W.timestream_fps}, {250, 500}, 'the clock is back to the normal cap')
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 0)
  S.run(W, 4000)
  T.eq({#events(W, 'ARRIVAL'), #events(W, 'LOCKDOWN'), W.state().alarm.lock}, {1, 0, 0}, 'no re-arm while it stays')
  local p = json.decode(W.persist_raw['dfllm.m.reflex'])
  T.eq({p.far.ids, p.far.hl}, {{300}, {300}}, 'the cleared list survives a reload')
  -- another hostile in sight: the picture is not a lone harmless intruder any more, the cleared one counts again
  W.add_unit(S.inv(301, 150, 30, Z)).race = GOB
  S.run(W, 120)
  T.eq(#events(W, 'ARRIVAL'), 2, 'counted again')
  T.eq(W.state().alarm.lock, 1)
end) end)

T.test('BUG-065: the limit is config: max_days 0 keeps the old rule; a dangerous (big) hostile near keeps the lockdown ' ..
       'and the offer says so; three small ones are a group, not a lone intruder', function() with_sortie(function()
  local W = setup{tag = 'gremdanger', manifest = false, cfg = CONFINE}
  raws()
  W.move(2, 100, 20, Z)
  local g = gremlin(W, 300, 110, 20, 60000)              -- a goblin-sized thief
  S.run(W, 120)
  W.inbox('ack', {})
  T.eq(W.state().alarm.by.hl, 0)
  S.run(W, 3 * 1200 + 1300)
  W.inbox('ack', {})
  T.eq(#events(W, 'LOCKDOWN_END'), 0, 'a dangerous hostile within the near radius keeps it')
  local o = decisions(W, 'intruder_sortie')
  T.ok(#o >= 1 and o[#o].d.hl == 0, 'the offer for a dangerous one names the confinement')
  T.ok(o[1].d.q:find('lockdown', 1, true), o[1].d.q)
  local W2 = setup{tag = 'gremgroup', manifest = false, cfg = CONFINE}
  raws()
  W2.move(2, 100, 20, Z)
  for i = 0, 2 do gremlin(W2, 300 + i, 110 + i, 20) end
  S.run(W2, 120)
  W2.inbox('ack', {})
  S.run(W2, 3 * 1200 + 1300)
  T.eq(#events(W2, 'LOCKDOWN_END'), 0, 'more than confine.lone_max small ones: not harmless')
  local W3 = setup{tag = 'gremoff', manifest = false, cfg = {reflex = {v = 2, confine = {max_days = 0}}}}
  raws()
  W3.move(2, 100, 20, Z)
  gremlin(W3, 300, 110, 20)
  S.run(W3, 120)
  W3.inbox('ack', {})
  S.run(W3, 6 * 1200)
  T.eq(#events(W3, 'LOCKDOWN_END'), 0, 'max_days 0: the old rule')
  T.eq(W3.state().alarm.lim, 0)
end) end)

T.test('BUG-065: no hostile in sight: the state says why the lockdown still holds (quiet clock), nothing is guessed',
       function()
  local W = setup{tag = 'gremnone', manifest = false}
  W.event('REPORT', {type = 'AMBUSH_AMBUSHER', text = 'An ambush! Curse them!'})
  S.run(W, 60)
  local a = W.state().alarm
  T.eq({a.lock, a.by, a.qw}, {1, nil, 'recent'}, 'a trigger within the last 2,400 ticks')
  T.eq(a.lim, 10 * 1200, 'the default limit is 10 game days')
  S.run(W, 2600)
  T.eq(W.state().alarm.qw, 'run', 'the quiet clock runs')
  T.eq(C.check_state(W.state()), {})
end)

T.test('BUG-065: a mood dwarf or a patient dying of thirst inside the confinement is reported; with no dangerous ' ..
       'hostile near the lockdown ends for him, with one near it holds and says so', function()
  local W = setup{tag = 'gremneed', manifest = false}
  raws()
  W.move(2, 100, 20, Z)
  gremlin(W, 300, 110, 20)
  S.run(W, 120)
  W.inbox('ack', {})
  S.run(W, 2600)                                         -- the alert sounds, no trigger for 2,400 ticks
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 1)
  W.inbox('ack', {})
  local u = W.unit(3)
  u.mood, u.counters2 = 1, {thirst_timer = 63513, hunger_timer = 0}
  S.run(W, 700)
  local d = decisions(W, 'confined_need')
  T.eq(#d, 1, 'reported once')
  T.eq({d[1].cls, d[1].d.units, d[1].d.thirst, d[1].d.why}, {'A', {3}, 63513, 'mood'})
  T.ok(#d[1].d.q <= 200, 'J3: d.q is at most 200 bytes (schema.py): ' .. #d[1].d.q)
  local e = events(W, 'LOCKDOWN_END')
  T.eq(#e, 1, 'nothing dangerous near: the confinement ends for him')
  T.eq(e[1].d.cause, 'need')
  S.run(W, 700)
  T.eq(df.global.plotinfo.alerts.civ_alert_idx, 0)
  -- a dangerous hostile near: reported, the lockdown stays
  local W2 = setup{tag = 'gremneed2', manifest = false}
  raws()
  W2.move(2, 100, 20, Z)
  gremlin(W2, 300, 110, 20, 60000)
  S.run(W2, 120)
  W2.inbox('ack', {})
  S.run(W2, 2600)
  W2.inbox('ack', {})
  local p = W2.unit(3)
  p.counters2, p.health = {thirst_timer = 52000, hunger_timer = 0}, {flags = {needs_healthcare = true}}
  S.run(W2, 700)
  local d2 = decisions(W2, 'confined_need')
  T.eq(#d2, 1)
  T.eq({d2[1].d.why, d2[1].d.units}, {'patient', {3}})
  T.eq({#events(W2, 'LOCKDOWN_END'), W2.state().alarm.lock}, {0, 1})
end)


T.test('BUG-065: a great danger in reach, or an undead wave, keeps the lockdown at any distance (the limit is for a ' ..
       'lone harmless intruder, not for a siege)', function()
  local W = setup{tag = 'gremgreat', manifest = false, cfg = CONFINE}
  raws()
  W.move(2, 100, 20, Z)
  gremlin(W, 300, 110, 20)
  W.add_unit(S.inv(400, 150, 30, Z, {great = true, race = 'DRAGON'}))      -- a megabeast 98 tiles away, in reach
  S.run(W, 120)
  W.inbox('ack', {})
  S.run(W, 3 * 1200 + 1300)
  W.inbox('ack', {})
  T.eq(#events(W, 'LOCKDOWN_END'), 0, 'the great danger keeps it')
  T.eq({W.state().alarm.lock, W.K.mode(), W.state().alarm.lim}, {1, 'SIEGE', 3 * 1200}, 'a siege: no limit applies')
end)


T.test('review C1: an unchanged dangerous intruder past the limit is offered once, not once per game day', function()
  with_sortie(function()
    local W = setup{tag = 'gremonce', manifest = false, cfg = CONFINE}
    raws()
    W.move(2, 100, 20, Z)
    gremlin(W, 300, 110, 20, 60000)
    S.run(W, 120)
    W.inbox('ack', {})
    for _ = 1, 4 do S.run(W, 1900); W.ms = W.ms + 120000; W.inbox("ack", {}) end   -- 7,600 ticks: 6.3 days, 3.3 past the limit
    T.eq(#decisions(W, 'intruder_sortie'), 1, 'the same unit and cause: one offer (a repeat needs news)')
    gremlin(W, 301, 111, 20, 60000)                                -- another one: news
    for _ = 1, 3 do S.run(W, 1900); W.ms = W.ms + 120000; W.inbox("ack", {}) end
    T.ok(#decisions(W, 'intruder_sortie') <= 3, 'bounded')
  end)
end)

T.done()
