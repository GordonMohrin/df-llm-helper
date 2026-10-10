-- WP5 siege reflex: table-driven scenarios over sense+threat+siege+gate on k_mock (strict), with
-- 9-tick timestream skips and a simulated lever/bridge world (tests/lua/siege_world.lua).
-- Every scenario also checks the invariants: never two pending pulls on one bridge, 0 double toggles.
local T = require('testlib')
local S = require('siege_world')
local Z = S.Z

---------------------------------------------------------------- helpers
local function rel(W, tick) return tick and (tick - W.t_start) or nil end
local function evs(W, t) return W.find_events(t) end
local function ev1(W, t) return W.find_events(t)[1] end
local function hide(id) return function(W) W.unit(id)._m.hidden = true end end
local function show(id) return function(W) W.unit(id)._m.hidden = false end end
local function units(...)
  local r = S.fort_units()
  for _, x in ipairs({...}) do
    if x.id then r[#r + 1] = x else for _, u in ipairs(x) do r[#r + 1] = u end end
  end
  return r
end
local function alert_acts(W, on)
  return S.acts(W, 'civ_alert', function(a) return a.args[1] == on end)
end
local function burrow_acts(W, name)
  return S.acts(W, 'alert_burrows', function(a) return a.args[1][1] == name end)
end
local function postures(W)     -- posture changes (periodic re-asserts collapsed)
  local r = {}
  for _, p in ipairs(W.mil.postures) do if r[#r] ~= p.P then r[#r + 1] = p.P end end
  return r
end
local function posture_tick(W, P)
  for _, p in ipairs(W.mil.postures) do if p.P == P then return p.tick end end
end
local function between(v, lo, hi, what)
  T.ok(v ~= nil and v >= lo and v <= hi, string.format('%s = %s not in [%d, %d]', what, tostring(v), lo, hi))
end
local function kill_all(ids)
  return function(W)
    for _, id in ipairs(ids) do W.kill(id); W.event('UNIT_DEATH', {unit = id}) end
  end
end
local function army_ids(n, first) local r = {}; for i = 1, n do r[i] = (first or 200) + i end; return r end
local function cens(W) return W.K.census end

local function setup(sc)
  local W = S.world{units = sc.units and sc.units() or S.fort_units(), lever_cfg = sc.lever_cfg,
                    lever_default = sc.lever_default, tiefe = sc.tiefe, persist = sc.persist}
  W.mil, W.drill = S.military(), S.drill()
  local extra = {W.mil, W.drill}
  if sc.snapshot then extra[#extra + 1] = S.snapshot(sc.snapshot) end
  S.load(W, extra)
  if sc.setup then sc.setup(W) end
  S.run(W, sc.run or 3000, {at = sc.at, skip = sc.skip})
  return W
end

---------------------------------------------------------------- scenarios
local SC = {}
local function add(sc) SC[#SC + 1] = sc end

add{name = 'quiet peace: no mode change, no pulls, alert off, gate idles at 600 ticks',
  run = 3000, modes = {},
  check = function(W)
    T.eq(#S.pulls(W), 0)
    T.eq(#alert_acts(W, true), 0)
    T.eq(postures(W), {'TRAIN'})
    T.eq(W.state().bridges, {O1 = 'down', B1 = 'down', B2 = 'down'})
    T.eq(package.loaded['dfllm.gate'].every.ticks, 600)
    T.eq(W.state().threat, {vis = 0, armed = 0})
  end}

add{name = 'one wild danger in reach (68 tiles from B2): ALERT, PEACE after 1,200 calm ticks',
  units = function() return units(S.danger(300, 120, 100)) end,
  at = {{600, hide(300)}}, run = 2600, modes = {'PEACE>ALERT', 'ALERT>PEACE'},
  check = function(W)
    between(rel(W, S.mode_tick(W, 'PEACE>ALERT')), 0, 50, 'ALERT latency')
    between(rel(W, S.mode_tick(W, 'ALERT>PEACE')), 1800, 1900, 'ALERT end')
    T.eq(#evs(W, 'ALERT_START'), 1)
    T.eq(ev1(W, 'ALERT_START').d.vis, 1)
    T.eq(#evs(W, 'ALERT_END'), 1)
    T.eq(#S.pulls(W), 0)
    T.eq(#alert_acts(W, true), 0, 'nobody outside: no civ alert')
    T.eq(postures(W), {'STATION_B1', 'TRAIN'})
  end}

add{name = 'no flapping: a hostile blinking in and out of view keeps one ALERT',
  units = function() return units(S.danger(300, 120, 100)) end,
  at = {{400, hide(300)}, {800, show(300)}, {1200, hide(300)}, {1600, show(300)}, {2000, hide(300)}},
  run = 3000, modes = {'PEACE>ALERT'},
  check = function(W)
    T.eq(#evs(W, 'ALERT_START'), 1)
    T.eq(#evs(W, 'ALERT_END'), 0)
  end}

add{name = 'ALERT civ alert: on near an outside citizen, off 600 ticks after the hostile moved away',
  units = function() return units(S.cit(6, 100, 100), S.danger(300, 120, 100)) end,
  at = {{900, function(W) W.move(300, 150, 150, Z) end}}, run = 2400, modes = {'PEACE>ALERT'},
  check = function(W)
    local on = alert_acts(W, true)
    T.eq(#on, 1)
    between(rel(W, on[1].tick), 0, 60, 'alert on')
    T.eq(#burrow_acts(W, 'Kern+'), 1)
    local off = alert_acts(W, false)
    T.eq(#off, 1)
    between(rel(W, off[1].tick), 1500, 1570, 'alert off (hysteresis)')
  end}

add{name = 'ALERT: a hostile within 30 tiles of O1 raises only O1; PEACE lowers it again',
  units = function() return units(S.danger(300, 51, 0)) end,
  at = {{800, hide(300)}}, run = 2600, modes = {'PEACE>ALERT', 'ALERT>PEACE'},
  check = function(W)
    T.eq(#S.pulls(W, 'O1'), 2, 'O1 up, then down in PEACE')
    T.eq(#S.pulls(W, 'B1') + #S.pulls(W, 'B2'), 0)
    T.eq(#S.flips(W, 'O1'), 2)
    T.eq(S.flips(W, 'O1')[1].to, 'up')
    T.eq(S.bstate(W, 'O1'), 'down')
    T.ok(S.pulls(W, 'O1')[2].tick >= S.mode_tick(W, 'ALERT>PEACE'))
  end}

add{name = 'six visible invaders: SIEGE and every T0 action in the detecting step',
  units = function() return units(S.army(6, 51, 0)) end, run = 1500, modes = {'PEACE>SIEGE'},
  check = function(W)
    local t0 = S.mode_tick(W, 'PEACE>SIEGE')
    between(rel(W, t0), 0, 50, 'SIEGE latency')
    T.eq(alert_acts(W, true)[1].tick, t0, 'civ alert in the same step')
    T.eq(burrow_acts(W, 'Kern+')[1].tick, t0, 'alert burrow Kern+ in the same step')
    T.eq(posture_tick(W, 'READY_STATION'), t0, 'READY_STATION in the same step')
    local ss = ev1(W, 'SIEGE_START')
    T.eq({ss.tick, ss.d.vis, ss.d.inv, ss.d.why}, {t0, 6, 6, 'invaders'})
    T.eq(ev1(W, 'WEALTH').d, {created = 12000, exported = 300, imported = 900})
    T.eq(S.pulls(W, 'O1')[1].tick, t0, 'nobody outside: O1 pulled at T0')
    T.eq(S.pulls(W, 'B1')[1].tick, t0, 'nobody outside: B1 pulled at T0')
    T.eq(#S.pulls(W, 'O1') + #S.pulls(W, 'B1'), 2)
    T.eq(#S.pulls(W, 'B2'), 0, 'B2 stays down in SIEGE')
    T.ok(S.flips(W, 'B1')[1].tick < t0 + 900)
    T.eq(W.state().bridges, {O1 = 'up', B1 = 'up', B2 = 'down'})
    T.eq(#evs(W, 'BREACH') + #evs(W, 'GATE_FAIL'), 0)
    T.eq(package.loaded['dfllm.gate'].every.ticks, 25)
  end}

add{name = 'INVASION arms the fast scan: one visible invader becomes a SIEGE within 50 ticks',
  units = function() return units(S.inv(201, 150, 150, Z, {hidden = true})) end,
  at = {{0, function(W) W.event('INVASION', {id = 7}) end},
        {200, function(W) W.armed200 = cens(W).h.armed end}, {300, show(201)}},
  run = 900, modes = {'PEACE>SIEGE'},
  check = function(W)
    T.eq(W.armed200, 1)
    T.eq(#evs(W, 'INVASION'), 1)
    T.eq(ev1(W, 'INVASION').d.id, 7)
    between(rel(W, S.mode_tick(W, 'PEACE>SIEGE')), 300, 330, 'armed latency (<= 25 ticks + one 9-tick frame)')
    T.eq(ev1(W, 'SIEGE_START').d.why, 'invasion')
  end}

add{name = 'INVASION with a hidden army: armed for 2,400 ticks, never a mode change',
  units = function()
    local a = S.army(8, 150, 150)
    for _, u in ipairs(a) do u.hidden = true end
    return units(a)
  end,
  at = {{0, function(W) W.event('INVASION', {id = 9}) end},
        {1000, function(W) W.a1 = cens(W).h.armed end}, {2700, function(W) W.a2 = cens(W).h.armed end}},
  run = 3000, modes = {},
  check = function(W)
    T.eq({W.a1, W.a2}, {1, 0})
    T.eq(#evs(W, 'INVASION'), 1)
    T.eq(cens(W).h.vis, 0)
  end}

add{name = 'hidden (sneaking) and not-visible units never count',
  units = function()
    local r = {}
    for i = 1, 5 do r[#r + 1] = S.inv(200 + i, 51, i, Z, {hidden = true}) end
    for i = 6, 10 do r[#r + 1] = S.inv(200 + i, 51, i, Z, {visible = false}) end
    return units(r)
  end,
  run = 1500, modes = {},
  check = function(W)
    local h = cens(W).h
    T.eq({h.vis, h.inv, #h.list, h.near_o1}, {0, 0, 0, -1})
    T.eq(#S.pulls(W), 0)
  end}

add{name = 'caged invaders never count but are listed as captives',
  units = function()
    local a = S.army(8, 51, 0)
    for _, u in ipairs(a) do u.caged = true end
    return units(a)
  end,
  run = 600, modes = {},
  check = function(W)
    T.eq(cens(W).h.vis, 0)
    T.eq(cens(W).u.caged, army_ids(8))
  end}

for _, kind in ipairs({'megabeast', 'fb', 'titan', 'demon', 'great'}) do
  add{name = 'a single visible great danger (' .. kind .. ') is a SIEGE',
    units = function() return units(S.danger(300, 120, 100, Z, {[kind] = true})) end,
    run = 300, modes = {'PEACE>SIEGE'},
    check = function(W)
      T.eq(ev1(W, 'SIEGE_START').d.why, 'great')
      T.eq(ev1(W, 'SIEGE_START').d.great, 1)
      T.eq(cens(W).h.list[1].k, 'great')
    end}
end

add{name = 'UNDEAD_ATTACK report plus a visible undead: SIEGE',
  units = function() return units({id = 300, pos = {120, 100, Z}, undead = true}) end,
  at = {{0, function(W) W.event('REPORT', {type = 'UNDEAD_ATTACK', text = 'The dead walk.'}) end}},
  run = 300, modes = {'PEACE>SIEGE'},
  check = function(W)
    T.eq(ev1(W, 'SIEGE_START').d.why, 'undead')
    T.eq(cens(W).h.undead, 1)
  end}

add{name = 'a visible undead without the report is only an ALERT',
  units = function() return units({id = 300, pos = {120, 100, Z}, undead = true}) end,
  run = 300, modes = {'PEACE>ALERT'}}

add{name = 'citizens outside Kern+ delay the raise until T+600; bridges still up by T+900',
  units = function() return units(S.cit(6, 100, 100), S.army(6, 150, 150)) end,
  run = 1500, modes = {'PEACE>SIEGE'},
  check = function(W)
    local t0 = S.mode_tick(W, 'PEACE>SIEGE')
    T.eq(cens(W).u.outside, 1)
    between(S.pulls(W, 'O1')[1].tick - t0, 600, 640, 'O1 raise')
    between(S.pulls(W, 'B1')[1].tick - t0, 600, 640, 'B1 raise')
    T.ok(S.flips(W, 'O1')[1].tick < t0 + 900)
    T.eq(#evs(W, 'BREACH'), 0)
  end}

add{name = 'a hostile within 10 tiles of B1 raises B1 at once; O1 still waits for T+600',
  units = function() return units(S.cit(6, 100, 100), S.army(6, 51, 32)) end,
  run = 1500, modes = {'PEACE>SIEGE'},
  check = function(W)
    local t0 = S.mode_tick(W, 'PEACE>SIEGE')
    between(S.pulls(W, 'B1')[1].tick - t0, 0, 30, 'B1 raise')
    between(S.pulls(W, 'O1')[1].tick - t0, 600, 640, 'O1 raise')
  end}

add{name = 'a soldier on the B1 footprint delays its raise by 300 ticks in a SIEGE',
  units = function()
    local r = units(S.army(6, 150, 150))
    r[5].pos = {51, 40, Z}
    return r
  end,
  run = 1500, modes = {'PEACE>SIEGE'},
  check = function(W)
    local t0 = S.mode_tick(W, 'PEACE>SIEGE')
    T.eq(S.pulls(W, 'O1')[1].tick, t0)
    between(S.pulls(W, 'B1')[1].tick - t0, 300, 330, 'B1 raise after the footprint wait')
    T.eq(cens(W).u.on_bridge.B1, 1)
  end}

add{name = 'DRILL: a soldier on the footprint blocks the raise until he steps off (no forced raise)',
  units = function()
    local r = S.fort_units()
    r[5].pos = {51, 40, Z}
    return r
  end,
  at = {{100, function(W) W.K.call('drill', 'start') end}, {1100, function(W) W.move(5, 51, 44, Z) end}},
  run = 2000, modes = {'PEACE>DRILL', 'DRILL>PEACE'},
  check = function(W)
    local b1 = S.pulls(W, 'B1')
    between(rel(W, b1[1].tick), 1100, 1130, 'B1 pull after the soldier left')
    T.ok(b1[1].tick < S.mode_tick(W, 'DRILL>PEACE'), 'still in the drill')
    T.eq(#evs(W, 'GATE_FAIL') + #evs(W, 'BREACH'), 0, 'a drill raises no A events')
    T.eq(W.drill.kpi.fails, {'B1:blocked'})
  end}

add{name = 'no worker on O1: cancel after 200 ticks, backup lever, BREACH and GATE_FAIL at T+900',
  lever_cfg = {[11] = {}, [12] = {}},
  units = function() return units(S.army(6, 150, 150)) end,
  run = 1500, modes = {'PEACE>SIEGE', 'SIEGE>BREACH'},
  check = function(W)
    local t0 = S.mode_tick(W, 'PEACE>SIEGE')
    local p = S.pulls(W, 'O1')
    T.ok(#p >= 4, 'repeated attempts')
    for i = 2, #p do
      T.ok(p[i].lever ~= p[i - 1].lever, 'alternates to the backup lever')
      T.ok(p[i].tick - p[i - 1].tick >= 200, 'one pull per 200 ticks at most')
    end
    T.ok(#S.acts(W, 'cancel_own_lever_job') >= 3)
    local tb = S.mode_tick(W, 'SIEGE>BREACH')
    between(tb - t0, 900, 930, 'BREACH at T+900')
    T.eq(ev1(W, 'BREACH').d, {why = 'gate_fail', bridge = 'O1'})
    local gf = ev1(W, 'GATE_FAIL')
    T.eq({gf.tick, gf.cls, gf.d.bridge, gf.d.want, gf.d.why}, {tb, 'A', 'O1', 'up', 'no_worker'})
    T.eq(burrow_acts(W, 'Tiefe+')[1].tick, tb, 'alert burrow Tiefe+ in the BREACH step')
    T.eq(posture_tick(W, 'B2_HOLD'), tb)
    T.eq(S.pulls(W, 'B2')[1].tick, tb, 'B2 seal pulled in the BREACH step')
    T.eq(S.bstate(W, 'B1'), 'up')
    T.eq(S.bstate(W, 'B2'), 'up')
  end}

add{name = 'backup lever: lever 11 never gets a worker, lever 12 does; exactly one toggle',
  lever_cfg = {[11] = {}},
  units = function() return units(S.army(6, 150, 150)) end,
  run = 1500, modes = {'PEACE>SIEGE'},
  check = function(W)
    local p = S.pulls(W, 'O1')
    T.eq(#p, 2)
    T.eq({p[1].lever, p[2].lever}, {11, 12})
    between(p[2].tick - p[1].tick, 200, 230, 'backup after the no-worker cancel')
    local c = S.acts(W, 'cancel_own_lever_job')
    T.eq(#c, 1)
    T.eq(c[1].args[1], p[1].job)
    T.eq(#S.flips(W, 'O1'), 1)
    T.eq(S.bstate(W, 'O1'), 'up')
  end}

add{name = 'single-pending invariant: a foreign pending pull blocks queueing; GATE_FAIL and BREACH',
  lever_cfg = {[21] = {}},
  setup = function(W) S.foreign_job(W, 21) end,
  units = function() return units(S.army(6, 150, 150)) end,
  run = 1200, modes = {'PEACE>SIEGE', 'SIEGE>BREACH'},
  check = function(W)
    T.eq(#S.pulls(W, 'B1'), 0, 'never a second pull next to a pending one')
    T.eq(ev1(W, 'GATE_FAIL').d, {bridge = 'B1', want = 'up', why = 'no_worker'})
    T.eq(ev1(W, 'BREACH').d.bridge, 'B1')
    T.eq(#S.acts(W, 'cancel_own_lever_job'), 0, 'a foreign job is never cancelled')
  end}

add{name = 'raised bridges with a camping army: never RECOVERY (visibility, not paths)',
  units = function() return units(S.army(6, 51, 0)) end,
  run = 12000, modes = {'PEACE>SIEGE'},
  check = function(W)
    T.ok(#evs(W, 'SIEGE_STATUS') >= 19)
    T.eq(ev1(W, 'SIEGE_STATUS').d, {vis = 6, worn = 95, on_station = 7, deaths = 0, captures = 0})
    T.eq(W.state().bridges, {O1 = 'up', B1 = 'up', B2 = 'down'})
  end}

add{name = 'RECOVERY: 2,400 quiet ticks; B1 down at +1,200, O1 at +2,400; PEACE + SIEGE_END at +8,400',
  units = function() return units(S.army(6, 51, 0)) end,
  at = {{1000, kill_all(army_ids(6))}}, run = 12200,
  modes = {'PEACE>SIEGE', 'SIEGE>RECOVERY', 'RECOVERY>PEACE'},
  check = function(W)
    local tr = S.mode_tick(W, 'SIEGE>RECOVERY')
    between(rel(W, tr), 3400, 3460, 'RECOVERY after 2,400 quiet ticks')
    local b1, o1 = S.pulls(W, 'B1'), S.pulls(W, 'O1')
    T.eq({#b1, #o1}, {2, 2})
    between(b1[2].tick - tr, 1200, 1240, 'B1 lowered')
    between(o1[2].tick - tr, 2400, 2440, 'O1 lowered')
    T.eq(#S.pulls(W, 'B2'), 0)
    local off = alert_acts(W, false)
    T.eq(#off, 1)
    T.ok(off[1].tick >= S.flips(W, 'B1')[2].tick + W.move_ticks, 'alert off only after B1 is down')
    between(S.mode_tick(W, 'RECOVERY>PEACE') - tr, 8400, 8440, 'PEACE')
    local se = ev1(W, 'SIEGE_END')
    T.eq(se.cls, 'A')
    T.eq({se.d.hostiles, se.d.killed, se.d.lost, se.d.captures}, {6, 6, 0, 0})
    T.ok(se.d.sealed_ticks > 3000, 'sealed time counted')
    T.eq(W.state().bridges, {O1 = 'down', B1 = 'down', B2 = 'down'})
    T.eq(postures(W), {'READY_STATION', 'STATION_B1', 'TRAIN'})
  end}

add{name = 'RECOVERY re-entry: a new visible invader sends the FSM straight back to SIEGE and re-raises',
  units = function() return units(S.army(6, 51, 0)) end,
  at = {{1000, kill_all(army_ids(6))}, {5200, function(W) W.add_unit(S.inv(250, 51, 2)) end}}, run = 6000,
  modes = {'PEACE>SIEGE', 'SIEGE>RECOVERY', 'RECOVERY>SIEGE'},
  check = function(W)
    between(rel(W, S.mode_tick(W, 'RECOVERY>SIEGE')), 5200, 5250, 're-entry latency')
    local b1 = S.flips(W, 'B1')
    T.eq({#b1, b1[1].to, b1[2].to, b1[3].to}, {3, 'up', 'down', 'up'})
    T.eq(#S.flips(W, 'O1'), 1, 'O1 was never lowered')
    T.eq(#evs(W, 'SIEGE_START'), 2)
    T.eq(evs(W, 'SIEGE_START')[2].d.why, 'reentry')
    T.eq(#evs(W, 'SIEGE_END'), 0)
  end}

add{name = 'a visible hostile inside Kern+ is a BREACH: Tiefe+ alert, B2 up, B2_HOLD',
  units = function() return units(S.army(6, 150, 150)) end,
  at = {{300, function(W) W.move(201, 60, 75, Z) end}}, run = 1000,
  modes = {'PEACE>SIEGE', 'SIEGE>BREACH'},
  check = function(W)
    local tb = S.mode_tick(W, 'SIEGE>BREACH')
    between(rel(W, tb), 300, 350, 'BREACH latency')
    T.eq(ev1(W, 'BREACH').d, {why = 'inside'})
    T.eq(cens(W).h.inside, 1)
    T.eq(burrow_acts(W, 'Tiefe+')[1].tick, tb)
    T.eq(S.pulls(W, 'B2')[1].tick, tb)
    T.eq(posture_tick(W, 'B2_HOLD'), tb)
    T.eq(#evs(W, 'GATE_FAIL'), 0)
  end}

add{name = 'BREACH without a Tiefe+ burrow falls back to Kern+ and retries slowly',
  tiefe = false,
  units = function() return units(S.army(6, 150, 150)) end,
  at = {{300, function(W) W.move(201, 60, 75, Z) end}}, run = 2000,
  modes = {'PEACE>SIEGE', 'SIEGE>BREACH'},
  check = function(W)
    local fails = S.acts(W, 'alert_burrows', function(a) return a.args[1][1] == 'Tiefe+' end)
    T.ok(#fails >= 1 and #fails <= 4, 'Tiefe+ retried every 600 ticks: ' .. #fails)
    T.eq(fails[1].ok, false)
    T.eq(df.global.plotinfo.alerts.civ_alert_idx, 1, 'alert stays on with Kern+')
  end}

add{name = 'DRILL: real pulls, KPIs at T+1,200, then lowered in PEACE; no siege events',
  at = {{100, function(W) W.K.call('drill', 'start') end}}, run = 2500,
  modes = {'PEACE>DRILL', 'DRILL>PEACE'},
  check = function(W)
    local t0 = S.mode_tick(W, 'PEACE>DRILL')
    T.eq(alert_acts(W, true)[1].tick, t0)
    T.eq(burrow_acts(W, 'Kern+')[1].tick, t0)
    T.eq(posture_tick(W, 'READY_STATION'), t0)
    T.eq(S.pulls(W, 'O1')[1].tick, t0)
    T.eq(S.pulls(W, 'B1')[1].tick, t0)
    local k = W.drill.kpi
    T.ok(k.last_raise_ticks.O1 <= 900 and k.last_raise_ticks.B1 <= 900, 'raised by T+900')
    T.eq(k.double_toggles, 0)
    T.eq(k.fails, {})
    T.eq({#S.flips(W, 'O1'), #S.flips(W, 'B1')}, {2, 2})
    T.eq(S.bstate(W, 'O1'), 'down')
    T.ok(alert_acts(W, false)[1].tick >= S.mode_tick(W, 'DRILL>PEACE'))
    T.eq(postures(W), {'TRAIN', 'READY_STATION', 'TRAIN'})
    T.eq(#evs(W, 'SIEGE_START') + #evs(W, 'BREACH') + #evs(W, 'GATE_FAIL'), 0)
  end}

add{name = 'DRILL with dead levers: no BREACH, no GATE_FAIL; the failures are in gate.kpi',
  lever_default = {},
  at = {{100, function(W) W.K.call('drill', 'start') end}}, run = 1500,
  modes = {'PEACE>DRILL', 'DRILL>PEACE'},
  check = function(W)
    T.eq(#evs(W, 'BREACH') + #evs(W, 'GATE_FAIL'), 0)
    T.eq(W.drill.kpi.fails, {'B1:no_worker', 'O1:no_worker'})
    T.eq(W.drill.kpi.last_raise_ticks.O1, nil)
    T.eq(#S.flips(W, 'O1') + #S.flips(W, 'B1'), 0)
  end}

add{name = 'a wild danger lingering within 40 tiles of O1 holds RECOVERY back',
  units = function() return units(S.army(6, 150, 150), S.danger(300, 51, 0, Z, {hidden = true})) end,
  at = {{500, kill_all(army_ids(6))}, {500, show(300)}, {4000, hide(300)}}, run = 6600,
  modes = {'PEACE>SIEGE', 'SIEGE>RECOVERY'},
  check = function(W)
    between(rel(W, S.mode_tick(W, 'SIEGE>RECOVERY')), 6400, 6480, 'RECOVERY only after the danger left')
  end}


add{name = 'kill orders: only targets inside the kill box, never on a stair or shaft tile',
  snapshot = {['53,30,' .. Z] = '_'},
  units = function()
    return units(S.army(6, 150, 150), S.inv(301, 50, 28), S.inv(302, 49, 26), S.inv(303, 53, 30), S.inv(304, 51, 2))
  end,
  run = 300, modes = {'PEACE>SIEGE'},
  check = function(W)
    T.ok(#W.mil.kills >= 1)
    T.eq(W.mil.kills[1].ids, {301})
    for _, k in ipairs(W.mil.kills) do T.eq(k.ids, {301}) end
  end}

add{name = 'lever verb in PEACE: one pull, a repeat is a no-op, refused outside PEACE',
  run = 100,
  check = function(W)
    local r1 = W.inbox('lever', {bridge = 'O1', want = 'up'})
    T.eq({r1.ok, r1.data and r1.data.job ~= nil}, {true, true})
    local r2 = W.inbox('lever', {bridge = 'O1', want = 'up'})
    T.eq(r2.ok, true)
    T.eq(#S.pulls(W, 'O1'), 1, 'no second pull while one is pending')
    S.run(W, 300)
    T.eq(S.bstate(W, 'O1'), 'up')
    T.eq(W.inbox('lever', {bridge = 'O1', want = 'up'}).msg, 'O1 already up')
    T.eq(W.inbox('lever', {bridge = 'X9', want = 'up'}).ok, false)
    S.run(W, 600)
    T.eq(S.bstate(W, 'O1'), 'up', 'the verb holds O1 up in PEACE')
    for _, u in ipairs(S.army(6, 150, 150)) do W.add_unit(u) end
    S.run(W, 100)
    T.eq(W.K.mode(), 'SIEGE')
    T.eq(W.inbox('lever', {bridge = 'O1', want = 'down'}).ok, false, 'lever is PEACE only')
  end}

add{name = 'gate.want: down refused in SIEGE and near a hostile; unknown bridge refused',
  units = function() return units(S.danger(300, 51, 0)) end, run = 200,
  check = function(W)
    local ok, ok2, msg = W.K.call('gate', 'want', 'O1', 'down', 'test')
    T.eq({ok, ok2}, {true, false})
    T.ok(msg:find('hostile within 30'), msg)
    T.eq(select(2, W.K.call('gate', 'want', 'X9', 'up', 'test')), false)
    for _, u in ipairs(S.army(6, 150, 150)) do W.add_unit(u) end
    S.run(W, 100)
    T.eq(W.K.mode(), 'SIEGE')
    S.run(W, 200)
    ok, ok2, msg = W.K.call('gate', 'want', 'B2', 'down', 'test')
    T.eq(ok2, false)
    T.ok(msg:find('SIEGE'), msg)
    T.eq({W.K.call('gate', 'state', 'B1')}, {true, 'up'})
  end}

add{name = 'a moving bridge is never pulled; exactly one pull after it settled',
  units = function() return units(S.army(6, 150, 150)) end,
  setup = function(W)
    local b = W.bridges.O1
    b.gate_flags.closed, b.gate_flags.opening = true, true
    b._move_end = S.abs_now() + 200
  end,
  run = 800, modes = {'PEACE>SIEGE'},
  check = function(W)
    local p = S.pulls(W, 'O1')
    T.eq(#p, 1)
    T.ok(rel(W, p[1].tick) >= 200, 'pulled only after the motion ended')
    T.eq(S.bstate(W, 'O1'), 'up')
  end}

add{name = 'the bridge moved without us while our pull was pending: ours is cancelled, no re-toggle',
  lever_cfg = {[11] = {worker = 150}},
  units = function() return units(S.army(6, 150, 150)) end,
  at = {{60, function(W, now) S.move_bridge(W, 'O1', now, true) end}}, run = 800, modes = {'PEACE>SIEGE'},
  check = function(W)
    local c = S.acts(W, 'cancel_own_lever_job')
    T.eq(#c, 1)
    T.eq(c[1].args[1], S.pulls(W, 'O1')[1].job)
    T.eq(#S.pulls(W, 'O1'), 1)
    T.eq(#S.flips(W, 'O1'), 1)
    T.eq(S.bstate(W, 'O1'), 'up')
  end}

add{name = 're-entry while our B1 lowering pull is pending: the pull is cancelled, B1 never drops',
  lever_cfg = {[21] = {worker = 150}, [22] = {worker = 150}},
  units = function() return units(S.army(6, 51, 0)) end,
  at = {{1000, kill_all(army_ids(6))}, {1000 + 2430 + 1260, function(W) W.add_unit(S.inv(250, 51, 2)) end}},
  run = 5500, modes = {'PEACE>SIEGE', 'SIEGE>RECOVERY', 'RECOVERY>SIEGE'},
  check = function(W)
    local b1 = S.pulls(W, 'B1')
    T.eq(#b1, 2, 'up, then the lowering pull')
    local c = S.acts(W, 'cancel_own_lever_job')
    T.eq(#c, 1)
    T.eq(c[1].args[1], b1[2].job)
    T.eq(c[1].mode, 'SIEGE', 'cancelled in the re-entry step')
    T.eq(#S.flips(W, 'B1'), 1, 'B1 went up once and stayed up')
    T.eq(S.bstate(W, 'B1'), 'up')
  end}

add{name = 'a wild danger revealed inside Kern+ in PEACE: ALERT and BREACH in the same step',
  units = function() return units(S.danger(300, 65, 80)) end, run = 300,
  modes = {'PEACE>ALERT', 'ALERT>BREACH'},
  check = function(W)
    T.eq(S.mode_tick(W, 'PEACE>ALERT'), S.mode_tick(W, 'ALERT>BREACH'))
    T.eq(ev1(W, 'BREACH').d, {why = 'inside'})
    T.eq(burrow_acts(W, 'Tiefe+')[1].tick, S.mode_tick(W, 'ALERT>BREACH'))
  end}

add{name = 'a real army during a drill turns the drill into a SIEGE without re-toggling',
  units = function()
    local a = S.army(6, 150, 150)
    for _, u in ipairs(a) do u.hidden = true end
    return units(a)
  end,
  at = {{100, function(W) W.K.call('drill', 'start') end},
        {400, function(W) for _, id in ipairs(army_ids(6)) do W.unit(id)._m.hidden = false end end}},
  run = 2500, modes = {'PEACE>DRILL', 'DRILL>SIEGE'},
  check = function(W)
    between(rel(W, S.mode_tick(W, 'DRILL>SIEGE')), 400, 450, 'SIEGE latency')
    T.eq(#evs(W, 'SIEGE_START'), 1)
    T.eq({#S.flips(W, 'O1'), #S.flips(W, 'B1')}, {1, 1})
    T.eq(W.state().bridges, {O1 = 'up', B1 = 'up', B2 = 'down'})
    T.eq(W.K.mode(), 'SIEGE', 'the drill stand-in does not end a real siege')
  end}

add{name = 'a drill nobody ends returns to PEACE after 3,600 ticks (bridges lowered again)',
  setup = function(W) W.drill.step = nil end,
  at = {{100, function(W) W.K.call('drill', 'start') end}}, run = 4200,
  modes = {'PEACE>DRILL', 'DRILL>PEACE'},
  check = function(W)
    between(S.mode_tick(W, 'DRILL>PEACE') - S.mode_tick(W, 'PEACE>DRILL'), 3600, 3630, 'drill timeout')
    T.eq(S.bstate(W, 'O1'), 'down')
  end}

add{name = 'raised bridges unseen by findAtTile: a long siege never loses them (no false BREACH)',
  setup = function(W) W.hide_raised = true end,
  units = function() return units(S.army(6, 51, 0)) end, run = 14000, modes = {'PEACE>SIEGE'},
  check = function(W)
    T.eq(W.state().bridges, {O1 = 'up', B1 = 'up', B2 = 'down'})
    T.eq(#S.pulls(W), 2)
  end}

---------------------------------------------------------------- review findings (WP5 rev 1)
local function unlink(W, ids)
  W.saved_links = W.saved_links or {}
  for _, id in ipairs(ids) do
    local lv = W.buildings[id]
    W.saved_links[id] = lv.linked_mechanisms
    lv.linked_mechanisms = require('dfllm.util.k_mock').vec{}
  end
end
local function relink(W) for id, v in pairs(W.saved_links) do W.buildings[id].linked_mechanisms = v end end
local function gate_blocked(W, b)
  local r = {}
  for _, e in ipairs(evs(W, 'GATE')) do if e.d.bridge == b and e.d.state == 'blocked' then r[#r + 1] = e end end
  return r
end
local function mv(id, x, y) return function(W) W.move(id, x, y, Z) end end

add{name = 'levers linked after the first resolve: used at once; both bridges up by T+900',
  setup = function(W) unlink(W, {11, 12, 21, 22}) end,
  at = {{700, relink}, {1000, function(W) for _, u in ipairs(S.army(6, 150, 150)) do W.add_unit(u) end end}},
  run = 2200, modes = {'PEACE>SIEGE'},
  check = function(W)
    local t0 = S.mode_tick(W, 'PEACE>SIEGE')
    for _, b in ipairs({'O1', 'B1'}) do
      T.eq(#S.pulls(W, b), 1, b .. ' pulled once')
      T.ok(S.flips(W, b)[1].tick < t0 + 900, b .. ' up by T+900')
    end
    T.eq(#evs(W, 'GATE_FAIL') + #evs(W, 'BREACH'), 0)
  end}

add{name = 'a lever unlinked after the last resolve is skipped: the pull goes to the linked backup',
  units = function() return units(S.army(6, 150, 150)) end,
  at = {{0, function(W) unlink(W, {11}) end}}, run = 900, modes = {'PEACE>SIEGE'},
  check = function(W)
    local p = S.pulls(W, 'O1')
    T.eq(#p, 1)
    T.eq(p[1].lever, 12)
    T.eq(S.bstate(W, 'O1'), 'up')
  end}

add{name = 'footprint after a DRILL: B1 is not lowered while a citizen stands on it (no forcing)',
  at = {{100, function(W) W.K.call('drill', 'start') end}, {500, mv(1, 51, 40)}, {2000, mv(1, 60, 70)}},
  run = 2600, modes = {'PEACE>DRILL', 'DRILL>PEACE'},
  check = function(W)
    local tp = S.mode_tick(W, 'DRILL>PEACE')
    local b1 = S.pulls(W, 'B1')
    T.eq(#b1, 2, 'up in the drill, down only after the citizen left')
    between(rel(W, b1[2].tick), 2000, 2045, 'B1 lowering pull (one gate pass)')
    T.ok(S.pulls(W, 'O1')[2].tick < tp + 50, 'O1 (nobody on it) lowered at once')
    T.eq(#gate_blocked(W, 'B1'), 1, 'one GATE blocked event')
    T.eq(S.flips(W, 'B1')[2].to, 'down')
    T.ok(S.flips(W, 'B1')[2].tick >= W.t_start + 2000)
    T.eq(S.bstate(W, 'B1'), 'down')
  end}

add{name = 'footprint: our pending lowering pull is cancelled when a citizen steps on; re-queued later',
  lever_cfg = {[21] = {worker = 150}, [22] = {worker = 150}},
  at = {{100, function(W) W.K.call('drill', 'start') end}, {1350, mv(1, 51, 40)}, {1800, mv(1, 60, 70)}},
  run = 2400, modes = {'PEACE>DRILL', 'DRILL>PEACE'},
  check = function(W)
    local b1 = S.pulls(W, 'B1')
    T.eq(#b1, 3, 'up, down (cancelled), down')
    local c = S.acts(W, 'cancel_own_lever_job')
    T.eq(#c, 1)
    T.eq(c[1].args[1], b1[2].job)
    between(rel(W, c[1].tick), 1350, 1380, 'cancelled within one gate pass')
    T.ok(rel(W, b1[3].tick) >= 1800, 'new pull after the citizen left')
    T.eq(#S.flips(W, 'B1'), 2)
    T.eq(S.bstate(W, 'B1'), 'down')
  end}

add{name = 'footprint in RECOVERY: B1 stays up while a citizen stands on it; alert off only after',
  units = function() return units(S.army(6, 51, 0)) end,
  at = {{1000, kill_all(army_ids(6))}, {1000, mv(2, 51, 40)}, {6000, mv(2, 61, 70)}}, run = 12500,
  modes = {'PEACE>SIEGE', 'SIEGE>RECOVERY', 'RECOVERY>PEACE'},
  check = function(W)
    local b1 = S.pulls(W, 'B1')
    T.eq(#b1, 2)
    between(rel(W, b1[2].tick), 6000, 6030, 'B1 lowered after the citizen left')
    T.ok(alert_acts(W, false)[1].tick >= b1[2].tick, 'alert held until B1 is down')
    T.eq(W.state().bridges, {O1 = 'down', B1 = 'down', B2 = 'down'})
  end}

add{name = 'footprint in PEACE after an ALERT: O1 is not lowered onto a citizen',
  units = function() return units(S.danger(300, 51, 0)) end,
  at = {{500, mv(1, 51, 10)}, {800, hide(300)}, {2600, mv(1, 60, 70)}}, run = 3200,
  modes = {'PEACE>ALERT', 'ALERT>PEACE'},
  check = function(W)
    local o1 = S.pulls(W, 'O1')
    T.eq(#o1, 2)
    T.ok(S.mode_tick(W, 'ALERT>PEACE') < W.t_start + 2600, 'PEACE came while the citizen was on O1')
    between(rel(W, o1[2].tick), 2600, 2630, 'O1 lowered after the citizen left')
  end}

add{name = 'an insane citizen (berserk) inside Kern+ is no hostile: no ALERT, no BREACH',
  units = function() return units(S.cit(7, 62, 72, Z, {insane = true, danger = true})) end,
  run = 600, modes = {},
  check = function(W)
    local h, u = cens(W).h, cens(W).u
    T.eq({h.vis, h.inside, h.crazed, #h.list}, {0, 0, 1, 0})
    T.eq({u.cit, u.insane_ids}, {5, {7}})
    T.eq(#S.acts(W, 'alert_burrows'), 0)
  end}

add{name = 'an insane citizen on a raised footprint blocks the lowering (lever verb in PEACE)',
  units = function() return units(S.cit(7, 62, 72, Z, {insane = true})) end, run = 50,
  check = function(W)
    T.eq(W.inbox('lever', {bridge = 'B1', want = 'up'}).ok, true)
    S.run(W, 300)
    T.eq(S.bstate(W, 'B1'), 'up')
    W.move(7, 51, 40, Z)
    S.run(W, 150)
    T.eq(cens(W).u.on_bridge.B1, 1, 'on_bridge counts insane citizens')
    T.eq(W.inbox('lever', {bridge = 'B1', want = 'down'}).ok, true)
    S.run(W, 600)
    T.eq({S.bstate(W, 'B1'), #S.pulls(W, 'B1')}, {'up', 1})
    W.move(7, 62, 72, Z)
    S.run(W, 300)
    T.eq({S.bstate(W, 'B1'), #S.pulls(W, 'B1')}, {'down', 2})
  end}

add{name = 'kill orders follow the kill box: replaced when a target leaves, withdrawn when none is left',
  units = function() return units(S.army(6, 150, 150), S.inv(301, 50, 28), S.inv(302, 51, 29)) end,
  at = {{400, mv(301, 51, 2)}, {800, mv(302, 51, 3)}}, run = 1200, modes = {'PEACE>SIEGE'},
  check = function(W)
    local k = W.mil.kills
    T.eq(k[1].ids, {301, 302})
    T.eq(k[#k].ids, {302})
    between(rel(W, k[#k].tick), 400, 450, 'order replaced at once')
    T.eq(#W.mil.withdrawn, 1)
    between(rel(W, W.mil.withdrawn[1]), 800, 900, 'withdrawn within 100 ticks')
  end}

add{name = 'a citizen killed in a SIEGE with UNIT_DEATH 60 ticks later counts as lost',
  units = function() return units(S.army(6, 51, 0)) end,
  at = {{500, function(W) W.kill(3) end}, {560, function(W) W.event('UNIT_DEATH', {unit = 3}) end},
        {1000, kill_all(army_ids(6))}},
  run = 12200, modes = {'PEACE>SIEGE', 'SIEGE>RECOVERY', 'RECOVERY>PEACE'},
  check = function(W)
    local ss = evs(W, 'SIEGE_STATUS')
    T.eq(ss[#ss].d.deaths, 1)
    local se = ev1(W, 'SIEGE_END')
    T.eq({se.d.lost, se.d.killed}, {1, 6})
  end}

add{name = 'a titan at the far map edge: no SIEGE, no ALERT; DECISION_NEEDED (A) once',
  units = function() return units(S.danger(300, 180, 180, Z, {titan = true})) end,
  run = 3000, modes = {},
  check = function(W)
    T.eq(cens(W).h.great, 1)
    local d = evs(W, 'DECISION_NEEDED')
    T.eq(#d, 1)
    T.eq({d[1].cls, d[1].d.id, d[1].d.unit}, {'A', 'great_far', 300})
  end}

add{name = 'a forgotten beast and wildlife in a revealed cavern below the fortcore: no SIEGE, no ALERT',
  units = function() return units(S.danger(300, 55, 30, 0, {fb = true}), S.danger(301, 60, 70, 0)) end,
  run = 3000, modes = {},
  check = function(W)
    T.eq({cens(W).h.vis, cens(W).h.great}, {2, 1})
    T.eq(#evs(W, 'DECISION_NEEDED'), 1)
  end}

add{name = 'a far titan stays visible during a siege: RECOVERY and PEACE still come',
  units = function() return units(S.army(6, 51, 0), S.danger(300, 180, 180, Z, {titan = true})) end,
  at = {{1000, kill_all(army_ids(6))}}, run = 12200,
  modes = {'PEACE>SIEGE', 'SIEGE>RECOVERY', 'RECOVERY>PEACE'}}

add{name = 'a titan entering reach is a SIEGE; it must leave 120 tiles (hysteresis) for RECOVERY',
  units = function() return units(S.danger(300, 180, 180, Z, {titan = true})) end,
  at = {{300, mv(300, 120, 100)}, {1500, mv(300, 162, 150)}, {4500, mv(300, 180, 180)}}, run = 15600,
  modes = {'PEACE>SIEGE', 'SIEGE>RECOVERY', 'RECOVERY>PEACE'},
  check = function(W)
    between(rel(W, S.mode_tick(W, 'PEACE>SIEGE')), 300, 350, 'SIEGE when in reach')
    T.eq(ev1(W, 'SIEGE_START').d.why, 'great')
    between(rel(W, S.mode_tick(W, 'SIEGE>RECOVERY')), 6900, 6960, 'quiet only beyond 120 tiles')
    T.eq(#evs(W, 'DECISION_NEEDED'), 1, 'reported once per unit')
  end}

---------------------------------------------------------------- run
for _, sc in ipairs(SC) do
  T.test(sc.name, function()
    local W = setup(sc)
    if sc.modes then T.eq(S.modes(W), sc.modes, 'mode transitions') end
    T.eq(W.pending_violations, 0, 'two pending pulls on one bridge')
    T.ok(W.max_pending <= 1, 'max pending ' .. W.max_pending)
    T.eq(S.kpi(W).double_toggles, sc.dbl or 0, 'double toggles')
    if sc.check then sc.check(W) end
  end)
end

-- a reload mid-siege: mode and T0 come from persist, so BREACH still fires at the original T+900
T.test('reload mid-siege keeps T0: BREACH at the original T+900', function()
  local W1 = S.world{units = units(S.army(6, 150, 150)), lever_cfg = {[11] = {}, [12] = {}}}
  W1.mil = S.military()
  S.load(W1, {W1.mil})
  S.run(W1, 500)
  local t0 = S.mode_tick(W1, 'PEACE>SIEGE')
  T.ok(t0 ~= nil)
  local persist = {}
  for dk, raw in pairs(W1.persist_raw) do
    local key = dk == 'dfllm' and 'marker' or dk:gsub('^dfllm%.', '')
    persist[key] = S.json.decode(raw)
  end
  local ytick = df.global.cur_year_tick
  local W2 = S.world{units = units(S.army(6, 150, 150)), lever_cfg = {[11] = {}, [12] = {}}, persist = persist,
                     mode = 'SIEGE', ytick = ytick}
  W2.mil = S.military()
  S.load(W2, {W2.mil})
  S.run(W2, 800)
  T.eq(S.modes(W2), {'SIEGE>BREACH'})
  between(S.mode_tick(W2, 'SIEGE>BREACH') - t0, 900, 930, 'BREACH relative to the original T0')
end)

T.test('detection latency over all frame phases (9-tick skips): <= 25 ticks armed, <= 50 otherwise', function()
  local function latency(armed, offset)
    local list = S.fort_units()
    local army = S.army(armed and 1 or 6, 150, 150)
    for _, u in ipairs(army) do u.hidden = true; list[#list + 1] = u end
    local W = S.world{units = list}
    S.load(W, {S.military()})
    local shown
    local at = {{offset, function(W, now)
      shown = now
      for _, u in ipairs(army) do W.unit(u.id)._m.hidden = false end
    end}}
    if armed then table.insert(at, 1, {0, function(W) W.event('INVASION', {id = 1}) end}) end
    S.run(W, offset + 120, {at = at})
    return S.mode_tick(W, 'PEACE>SIEGE') - shown
  end
  for k = 0, 9 do
    local off = 300 + 9 * k
    T.ok(latency(true, off) <= 25, 'armed latency at offset ' .. off)
    T.ok(latency(false, off) <= 50, 'latency at offset ' .. off)
  end
end)

T.test('T0 raise uses a census from the detecting step: a citizen who left < 100 ticks earlier counts', function()
  for _, off in ipairs({0, 9, 27, 63}) do
    local army = S.army(6, 150, 150)
    for _, u in ipairs(army) do u.hidden = true end
    local W = S.world{units = units(army)}
    S.load(W, {S.military()})
    S.run(W, 200)
    local t = W.K.census.u.tick
    while W.K.census.u.tick == t do S.run(W, 9) end       -- right after a PEACE citizen scan
    W.move(1, 51, 20, Z)                                   -- citizen 1 walks out into the bailey
    S.run(W, 800, {at = {{off, function(W) for _, u in ipairs(army) do W.unit(u.id)._m.hidden = false end end}}})
    local t0 = S.mode_tick(W, 'PEACE>SIEGE')
    T.ok(t0 ~= nil, 'siege at offset ' .. off)
    for _, b in ipairs({'O1', 'B1'}) do
      between(S.pulls(W, b)[1].tick - t0, 600, 640, b .. ' raise at offset ' .. off)
    end
  end
end)

T.test('ALERT civ alert with citizens who obey it: on once, held while the danger lingers, off once', function()
  local W = S.world{units = units(S.cit(6, 100, 100), S.danger(300, 120, 100))}
  W.mil = S.military()
  S.load(W, {W.mil})
  local function frame(dt)
    W.frame(dt)
    if df.global.plotinfo.alerts.civ_alert_idx ~= 0 then W.move(6, 60, 70, Z) else W.move(6, 100, 100, Z) end
  end
  S.run(W, 6000, {frame = frame, at = {{3000, mv(300, 141, 100)}}})
  local on, off = alert_acts(W, true), alert_acts(W, false)
  T.eq({#on, #off}, {1, 1})
  between(rel(W, off[1].tick), 3600, 3670, 'off 600 ticks after the danger left the anchors')
  T.eq(W.K.mode(), 'ALERT', 'the danger is still in reach (89 tiles)')
  T.eq(S.modes(W), {'PEACE>ALERT'})
end)

T.test('reload mid-siege with raised bridges unseen by findAtTile: found by extents, no pull, no BREACH', function()
  local W1 = S.world{units = units(S.army(6, 51, 0))}
  W1.mil = S.military()
  S.load(W1, {W1.mil})
  S.run(W1, 600)
  T.eq(W1.state().bridges, {O1 = 'up', B1 = 'up', B2 = 'down'})
  local persist = {}
  for dk, raw in pairs(W1.persist_raw) do
    persist[dk == 'dfllm' and 'marker' or dk:gsub('^dfllm%.', '')] = S.json.decode(raw)
  end
  local W2 = S.world{units = units(S.army(6, 51, 0)), persist = persist, mode = 'SIEGE', ytick = df.global.cur_year_tick}
  W2.bridges.O1.gate_flags.closed, W2.bridges.B1.gate_flags.closed = true, true
  W2.hide_raised = true
  W2.mil = S.military()
  S.load(W2, {W2.mil})
  S.run(W2, 1500)
  T.eq(S.modes(W2), {})
  T.eq(#S.pulls(W2), 0, 'already up: nothing to pull')
  T.eq(W2.state().bridges, {O1 = 'up', B1 = 'up', B2 = 'down'})
end)

T.done()
