-- BUG-027 (Run 10 Handlelock, y417 autumn and y418 summer): siege and the arrival lockdown raised bridge 17880 (B1,
-- footprint 128,127..129,122, on the corridor between the core and the workshops) with four goblins far away; a
-- recruit and later a miner died on its footprint (no combat report, one "missing" in the unit list). The gate's old
-- SIEGE/BREACH rule queued a raise without the margin check, never cancelled a pending raise when somebody stepped on
-- and raised after 300 ticks onto whoever stood there. Here: the real sense, threat, siege and gate on the siege world
-- without a fort manifest, so the bridges are unmanaged (X1 = O1's building, X2 = B1's, X3 = B2's) as in a fort
-- without fortcore, plus the manifest variant of the Run 10 corridor.
local T = require('testlib')
local S = require('siege_world')
local Z = S.Z

local B1FP = {50, 40, Z, 52, 40, Z}
local function on_fp(p, fp, m)
  m = m or 0
  return p.z >= fp[3] and p.z <= fp[6] and p.x >= fp[1] - m and p.x <= fp[4] + m and p.y >= fp[2] - m and p.y <= fp[5] + m
end

-- a world whose frames record every unit that stands on or next to a bridge's footprint when it starts to move
local function world(o)
  o = o or {}
  local W = S.world{units = o.units, manifest = o.manifest, lever_default = o.lever_default, lever_cfg = o.lever_cfg}
  W.mil = S.military()
  S.load(W, {W.mil})
  if o.cfg then W.K.cfg.reflex = o.cfg end
  W.crushed = {}
  local n = 0
  W.watch = function()
    for i = n + 1, #W.flips do
      local f = W.flips[i]
      local b = W.bridges[f.bridge]
      local fp = {b.x1, b.y1, b.z, b.x2, b.y2, b.z}
      for _, u in ipairs(df.global.world.units.active) do
        if not u._m.dead and not u._m.invader and on_fp(u.pos, fp, 1) then
          W.crushed[#W.crushed + 1] = {tick = f.tick, bridge = f.bridge, unit = u.id}
        end
      end
    end
    n = #W.flips
  end
  return W
end

local function run(W, ticks, at)
  S.run(W, ticks, {at = at, frame = function(dt) W.frame(dt); W.watch() end})
end

local function rel(W, t) return t - W.t_start end
local function far_army() return S.army(4, 150, 150) end   -- Run 10: snatcher + 3, far from the gate

local function cast(extra)
  local r = S.fort_units()
  for _, u in ipairs(far_army()) do r[#r + 1] = u end
  for _, u in ipairs(extra or {}) do r[#r + 1] = u end
  return r
end

T.test('BUG-027 Run 10, unmanaged bridges: in a SIEGE (invasion, 4 goblins far away) the raise of X2 waits for the ' ..
       'recruit on it and the miner who steps on while the pull is pending; GATE_FAIL names them; nobody is crushed',
       function()
  local W = world{manifest = false, units = cast({S.cit(26535, 51, 40, Z, {squad = 3})}),
                  lever_cfg = {[21] = {worker = 150}, [22] = {worker = 150}}}
  W.event('INVASION', {id = 1})
  run(W, 60)
  T.eq(W.K.mode(), 'SIEGE')
  T.eq(#S.pulls(W, 'O1'), 1, 'X1 raised at once (nobody on it)')
  T.eq(#S.pulls(W, 'B1'), 0, 'X2 waits for the recruit')
  -- the recruit steps off, the pull is queued, a miner walks onto the footprint before the lever is pulled
  W.move(26535, 51, 44, Z)
  run(W, 40)
  local p = S.pulls(W, 'B1')
  T.eq(#p, 1, 'queued once the footprint and its margin were clear')
  W.add_unit(S.cit(26099, 52, 40))
  run(W, 30)
  local c = S.acts(W, 'cancel_own_lever_job')
  T.eq(#c, 1, 'the pending raise is cancelled (UI cancel)')
  T.eq(c[1].args[1], p[1].job)
  run(W, 1000)
  T.eq(#W.find_events('GATE_FORCED'), 0)
  local gf
  for _, e in ipairs(W.find_events('GATE_FAIL')) do if e.d.bridge == 'X2' then gf = e end end
  T.ok(gf, 'GATE_FAIL for X2 at its deadline')
  T.eq({gf.d.why, gf.d.units}, {'blocked', {26099}})
  T.ok(gf.msg:find('blocked: citizen 26099 on the footprint, never raised onto them', 1, true), gf.msg)
  W.move(26099, 60, 70, Z)
  run(W, 300)
  T.eq(S.bstate(W, 'B1'), 'up', 'raised once both were gone')
  T.eq(W.crushed, {}, 'no unit on or next to a footprint when a bridge started to move')
end)

T.test('BUG-027 Run 10, the corridor bridge B1 (manifest): a stream of passers-by never sees B1 move under them',
       function()
  -- miners cross B1 (y 40) on the corridor x 51 from y 36 to y 44 one tile per 9-tick frame, one every 30 ticks
  local W = world{units = cast(), lever_cfg = {[21] = {worker = 120}, [22] = {worker = 120}}}
  local walkers, next_id, t = {}, 700, 0
  local frame = function(dt)
    W.frame(dt)
    t = t + dt
    if t % 30 < dt and next_id < 712 then
      next_id = next_id + 1
      W.add_unit(S.cit(next_id, 51, 36))
      walkers[next_id] = 36
    end
    for id, y in pairs(walkers) do
      if y < 44 then walkers[id] = y + 1; W.move(id, 51, y + 1, Z) end
    end
    W.watch()
  end
  W.event('INVASION', {id = 2})
  S.run(W, 2400, {frame = frame})
  T.eq(W.crushed, {}, 'nobody on or next to B1 when it started to move')
  T.eq(S.bstate(W, 'B1'), 'up', 'B1 rose once the stream ended')
  T.ok(#S.acts(W, 'cancel_own_lever_job') >= 1, 'pending raises were cancelled for the passers-by')
end)

T.test('BUG-027: the lowering after the siege (and a lockdown end) waits for a recruit on the footprint like the ' ..
       'raise', function()
  local W = world{units = cast()}
  W.event('INVASION', {id = 3})
  run(W, 600)
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(W.K.call('gate', 'want', 'B1', 'down', 'test'), true)   -- refused in SIEGE: never lowered now
  W.move(5, 51, 40, Z)                                          -- the soldier stands on the raised B1
  T.eq(on_fp(W.unit(5).pos, B1FP), true)
  for _, id in ipairs({201, 202, 203, 204}) do W.kill(id); W.event('UNIT_DEATH', {unit = id}) end
  local n = 0
  while W.K.mode() ~= 'PEACE' and n < 200 do run(W, 100); n = n + 1 end
  T.eq(W.K.mode(), 'PEACE')
  run(W, 600)
  T.eq(S.bstate(W, 'B1'), 'up', 'not lowered onto him')
  W.move(5, 51, 44, Z)
  run(W, 300)
  T.eq(S.bstate(W, 'B1'), 'down')
  T.eq(W.crushed, {})
end)

T.test('BUG-027 Run 10 (baby 27608): a baby in its mother\'s arms counts where the mother stands ' ..
       '(dfhack.units.getPosition), not at its own stale pos field', function()
  local W = world{units = cast({S.cit(27000, 60, 75), S.cit(27608, 60, 75, Z, {adult = false, baby = true})})}
  local getPos = dfhack.units.getPosition
  dfhack.units.getPosition = function(u)
    if u.id == 27608 then return getPos(W.unit(27000)) end           -- carried: the carrier's position
    return getPos(u)
  end
  W.move(27000, 51, 41, Z)                                           -- the mother next to B1, the baby's pos stays
  W.event('INVASION', {id = 5})
  run(W, 300)
  T.eq(#S.pulls(W, 'B1'), 0, 'held for the mother and the baby')
  local g
  for _, e in ipairs(W.find_events('GATE')) do if e.d.bridge == 'B1' and e.d.state == 'blocked' then g = e end end
  T.eq(g.d.units, {27000, 27608})
  W.move(27000, 60, 75, Z)
  run(W, 300)
  T.eq(S.bstate(W, 'B1'), 'up')
  dfhack.units.getPosition = getPos
end)

T.test('BUG-027 order at an arrival: a unit next to a bridge the lockdown wants up sounds the civ alert at once (call ' ..
       'them in first), the bridge rises once he is inside; the other pulls do not hold the alert back', function()
  local kmock = require('dfllm.util.k_mock')
  -- no fort manifest (unmanaged X1..X3); the X1/X3 pulls are slow, so the deferred alert would wait for them
  local W = S.world{manifest = false, units = cast({S.cit(26099, 51, 39)}),
                    lever_cfg = {[11] = {worker = 400}, [12] = {worker = 400}, [31] = {worker = 400}, [32] = {worker = 400}}}
  df.global.world.status.popups = kmock.vec{}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  package.loaded['dfllm.reflex'] = nil
  S.load(W, {S.military(), snap, require('dfllm.reflex')})
  for i = 201, 204 do W.unit(i)._m.hidden = true end      -- the raiders are not in sight yet: a PEACE lockdown
  W.event('INVASION', {id = 7})
  S.run(W, 30)
  W.inbox('ack', {})
  T.eq(W.K.mode(), 'PEACE')
  local on = S.acts(W, 'civ_alert', function(a) return a.args[1] == true end)
  local t0 = W.find_events('ARRIVAL')[1].tick
  T.ok(#on == 1 and on[1].tick - t0 <= 20, 'the alert at once: ' .. (on[1] and on[1].tick - t0 or -1))
  local said
  for _, l in ipairs(W.logs) do if l.msg:find('(units on a bridge)', 1, true) then said = true end end
  T.ok(said, 'kern.log says why the alert did not wait')
  T.eq(#S.pulls(W, 'B1'), 0, 'X2 waits for him')
  W.move(26099, 51, 44, Z)                                   -- the alert called him in
  S.run(W, 200)
  T.eq(S.bstate(W, 'B1'), 'up')
end)

T.test('BUG-027 BRIDGE_CRUSH: in a siege a foreign pull (the player\'s, or one from before a reload) moves B1 with a ' ..
       'miner on it; he dies "missing": BRIDGE_CRUSH (A) names bridge, unit and how; once; none far from a move',
       function()
  local W = world{units = cast({S.cit(26099, 51, 40)}), lever_cfg = {[21] = {worker = 100, pull = 40}}}
  S.foreign_job(W, 21)                                         -- gate never pulls next to it (single pending pull)
  W.event('INVASION', {id = 9})
  run(W, 300)
  T.eq(W.K.mode(), 'SIEGE')
  T.eq(S.bstate(W, 'B1'), 'up')
  T.eq(#S.pulls(W, 'B1'), 0, 'not our pull')
  T.eq(#W.crushed, 1, 'the sim saw him on the moving bridge')
  local ok, moves = W.K.call('gate', 'moves')
  T.ok(ok and #moves >= 1)
  local m = moves[#moves]
  T.eq({m.b, m.bid, m.to, m.pull}, {'B1', 2, 'up', -1})
  T.eq({m.seen[1].id, m.seen[1].d, m.seen[1].k}, {26099, 0, 'citizen'})
  local g
  for _, e in ipairs(W.find_events('GATE')) do if e.d.bridge == 'B1' and e.d.state == 'moving' then g = e end end
  T.eq(g.d.units, {26099}, 'GATE moving names him')
  local u = W.unit(26099)
  W.kill(26099)
  u.counters = {death_id = 9001}
  df.incident = {find = function(id) if id == 9001 then return {death_cause = -1, criminal = -1,
                                                                 flags = {discovered = false}} end end}
  W.event('UNIT_DEATH', {unit = 26099})
  run(W, 20)
  local bc = W.find_events('BRIDGE_CRUSH')
  T.eq(#bc, 1)
  T.eq({bc[1].cls, bc[1].d.bridge, bc[1].d.unit, bc[1].d.how, bc[1].d.pull, bc[1].d.to, bc[1].d.pos},
       {'A', 'B1', 26099, 'seen', -1, 'up', {51, 40, Z}})
  T.ok(bc[1].msg:find('citizen 26099 crushed: bridge B1 2 up, last seen on it at 51,40,' .. Z, 1, true), bc[1].msg)
  W.event('UNIT_DEATH', {unit = 26099})
  run(W, 20)
  T.eq(#W.find_events('BRIDGE_CRUSH'), 1, 'once per unit')
  W.kill(1)                                                   -- inside Kern+, never near a bridge
  W.event('UNIT_DEATH', {unit = 1})
  run(W, 20)
  T.eq(#W.find_events('BRIDGE_CRUSH'), 1)
end)

T.test('BUG-310 (Earthboat y379 #3757: BRIDGE_CRUSH for a citizen last seen 1 tile from B2 whose incident said BLEED): ' ..
       'a death with another incident cause is no bridge death next to the footprint (old: BRIDGE_CRUSH), on it it is',
       function()
  local W = world{units = cast({S.cit(26424, 51, 41), S.cit(26425, 51, 40)}), lever_cfg = {[21] = {worker = 100, pull = 40}}}
  S.foreign_job(W, 21)
  W.event('INVASION', {id = 11})
  run(W, 300)
  T.eq(S.bstate(W, 'B1'), 'up')
  local m = select(2, W.K.call('gate', 'moves'))
  m = m[#m]
  local seen = {}
  for _, e in ipairs(m.seen) do seen[e.id] = e.d end
  T.eq({seen[26424], seen[26425]}, {1, 0})
  local dt0, inc0 = df.death_type, df.incident
  df.death_type = {[5] = 'BLEED', BLEED = 5}
  df.incident = {find = function(id) if id >= 9100 then return {death_cause = 5, criminal = -1,
                                                                 flags = {discovered = true}} end end}
  for i, id in ipairs({26424, 26425}) do
    local u = W.unit(id)
    W.move(id, 51, 46, Z)
    W.kill(id)
    u.counters = {death_id = 9100 + i}
    W.event('UNIT_DEATH', {unit = id})
  end
  run(W, 20)
  local bc = W.find_events('BRIDGE_CRUSH')
  T.eq(#bc, 1, 'only the one seen on it (old: both)')
  T.eq(bc[1].d.unit, 26425)
  df.death_type, df.incident = dt0, inc0
end)

T.test('BUG-027: a merchant (and his pack animal) on B1 hold the SIEGE raise (census.h.friends via gate.watch); a ' ..
       'wild animal does not', function()
  local W = world{units = cast({{id = 900, pos = {51, 40, Z}, merchant = true},
                                {id = 901, pos = {50, 41, Z}, tame = true, animal = true},
                                {id = 902, pos = {52, 41, Z}, animal = true}})}
  W.event('INVASION', {id = 11})
  run(W, 200)
  T.eq(#S.pulls(W, 'B1'), 0, 'held for the merchant')
  local f = {}
  for _, e in ipairs(W.K.census.h.friends or {}) do f[e.id] = e.k end
  T.eq(f, {[900] = 'merchant', [901] = 'animal'}, 'sense lists the friends near the watched footprint, no wild animal')
  local said                                   -- the first GATE line named the animal (census.a); the merchant came
  for _, l in ipairs(W.logs) do                -- with sense's next scan of the watch box: the kern.log line
    if tostring(l.msg):find('B1 up still waits for merchant 900 on the footprint, animal 901 next to it', 1, true) then
      said = true
    end
  end
  T.ok(said, 'kern.log names the merchant')
  W.move(900, 70, 70, Z)
  W.move(901, 70, 71, Z)
  run(W, 200)
  T.eq(S.bstate(W, 'B1'), 'up', 'the wild animal 902 next to it does not hold the raise')
  T.eq(W.K.call('gate', 'watch'), true)
  T.eq(select(2, W.K.call('gate', 'watch')), nil, 'nothing to watch once B1 is up')
end)

---------------------------------------------------------------- lever burrow check (BUG-027, Run 10 y419)
-- live: BREACH 'O1 not up at T+900' (enemy far), then GATE_FAIL "B1 not up ... no worker: its levers lie outside the
-- alert burrow" although every lever lay in Kern+: in BREACH the alert holds the civilians in Tiefe+.
-- A DF-like lever sim: a civilian takes a pull only on a lever inside one of the alert's burrows (or with no alert),
-- and only once somebody is free (W.free_at); a fake seal paints Hebel+ (the bbox of the lever tiles).
local function in_box(p, b) return p.x >= b[1] and p.x <= b[4] and p.y >= b[2] and p.y <= b[5] and p.z >= b[3] and p.z <= b[6] end
local function breach_world(units, free_after, manifest)
  local W = S.world{units = units, manifest = manifest}
  W.mil = S.military()
  local seal = {name = 'seal', every = {ticks = 600}}
  function seal.lever_burrow(K, tiles)
    if #tiles == 0 then return nil end
    local b = {1e9, 1e9, 1e9, -1e9, -1e9, -1e9}
    for _, t in ipairs(tiles) do
      b = {math.min(b[1], t[1]), math.min(b[2], t[2]), math.min(b[3], t[3]),
           math.max(b[4], t[1]), math.max(b[5], t[2]), math.max(b[6], t[3])}
    end
    W.burrow('Hebel+', b)
    return 'Hebel+'
  end
  S.load(W, {W.mil, seal})
  W.free_at = S.abs_now() + free_after
  W.lever_cfg = setmetatable({}, {__index = function(_, id)
    local lv = W.buildings[id]
    if S.abs_now() < W.free_at then return {} end
    if df.global.plotinfo.alerts.civ_alert_idx == 0 then return nil end
    for _, n in ipairs(W.alert_burrows or {}) do
      local bb = dfhack.burrows.findByName(n)
      if bb and in_box({x = lv.x1, y = lv.y1, z = lv.z}, bb._bbox) then return nil end
    end
    return {}                                                  -- outside every alert burrow: nobody may take it
  end})
  return W
end

T.test('BUG-027 lever burrow check: BREACH by a gate fail with the enemy far: the alert (Tiefe+) lists Hebel+ for the ' ..
       'Kern+ levers, the civilians pull O1/B1/B2; no GATE_FAIL outside_alert', function()
  local W = breach_world(cast(), 1000)                         -- nobody is free for the levers until T+1000
  W.event('INVASION', {id = 21})
  S.run(W, 950)
  T.eq(S.modes(W), {'PEACE>SIEGE', 'SIEGE>BREACH'})
  T.eq(W.find_events('BREACH')[1].d.why, 'gate_fail')
  T.eq(W.alert_burrows, {'Tiefe+', 'Hebel+'}, 'the lever tiles are in the alert while the pulls are pending')
  S.run(W, 600)
  for _, b in ipairs({'O1', 'B1', 'B2'}) do T.eq(S.bstate(W, b), 'up', b) end
  T.eq(W.alert_burrows, {'Tiefe+'}, 'the pulls are done: Hebel+ left the list')
  for _, e in ipairs(W.find_events('GATE_FAIL')) do T.ok(e.d.why ~= 'outside_alert', e.msg) end
end)

T.test('BUG-027 lever burrow check: BREACH with a hostile inside Kern+: no Hebel+ (attacker-side levers); the ' ..
       'GATE_FAIL names the alert burrow', function()
  local W = breach_world(cast({S.inv(299, 60, 50)}), 0)
  S.run(W, 1000)
  T.eq(W.K.mode(), 'BREACH')
  T.eq(W.find_events('BREACH')[1].d.why, 'inside')
  T.eq(W.alert_burrows, {'Tiefe+'})
  local gf
  for _, e in ipairs(W.find_events('GATE_FAIL')) do if e.d.bridge == 'O1' then gf = e end end
  T.ok(gf, 'O1 GATE_FAIL')
  T.eq(gf.d.why, 'outside_alert')
  T.ok(gf.msg:find('no worker: its levers lie outside the alert burrow Tiefe+', 1, true), gf.msg)
end)

---------------------------------------------------------------- the deep defense: civilians in the refuge (Run 11 y432)
-- live y432 winter d64: GATE_FAIL O1 'no_worker', the kernel pulled lever 18664 again and again, `lever pull --id 18664
-- --priority` by hand was taken at once; the civilians stood confined in Tiefe+ (deep defense SIEGE_DEEP, BUG-030).
-- An army of 30 > 3 x 8 soldiers (the fake military) sends the siege deep: the alert confines to Tiefe+.
local function deep_cast(extra)
  local r = cast(extra)
  for _, u in ipairs(S.army(26, 150, 160, 400)) do r[#r + 1] = u end   -- 30 in sight
  return r
end
local function lever_id(W, p)
  for _, lv in ipairs(W.levers) do if lv.x1 == p[1] and lv.y1 == p[2] and lv.z == p[3] then return lv.id end end
end
local function gfails(W, why)
  local r = {}
  for _, e in ipairs(W.find_events('GATE_FAIL')) do if why == nil or e.d.why == why then r[#r + 1] = e end end
  return r
end

T.test('Run 11 deep defense: O1 and B1 raised with every civilian confined to Tiefe+ and their levers in Kern+ -> the ' ..
       'alert lists Hebel+ while the pulls are pending (no hostile in Kern+ or near the levers), a confined civilian ' ..
       'pulls; no GATE_FAIL', function()
  local W = breach_world(deep_cast(), 0)
  W.event('INVASION', {id = 31})
  S.run(W, 60)
  T.eq(W.K.mode(), 'SIEGE')
  T.ok(#W.find_events('SIEGE_DEEP') == 1, 'the deep defense')
  T.eq(W.alert_burrows, {'Tiefe+', 'Hebel+'}, 'the refuge and the lever tiles while the pulls are pending')
  S.run(W, 400)
  T.eq({S.bstate(W, 'O1'), S.bstate(W, 'B1')}, {'up', 'up'})
  T.eq(W.alert_burrows, {'Tiefe+'}, 'the pulls are done: Hebel+ left the list')
  T.eq(#gfails(W), 0)
end)

T.test('Run 11 deep defense: O1 and B1 each with a lever inside Tiefe+ (fortcore stage 3) -> the pull goes to it at ' ..
       'once, not to a Kern+ lever nobody confined may take (the old order waited 200 ticks per Kern+ lever)', function()
  local m = S.manifest()
  local ref = {O1 = {70, 70, Z - 6}, B1 = {71, 70, Z - 6}}
  for b, p in pairs(ref) do table.insert(m.bridges[b].levers, p) end
  local W = breach_world(deep_cast(), 0, m)
  W.event('INVASION', {id = 32})
  S.run(W, 60)
  T.eq(W.alert_burrows, {'Tiefe+'}, 'a usable lever inside the refuge: no Hebel+')
  S.run(W, 240)
  for b, p in pairs(ref) do
    T.eq(S.bstate(W, b), 'up', b .. ' up within 300 ticks')
    local pl = S.pulls(W, b)
    T.eq(pl[#pl].lever, lever_id(W, p), b .. ': the refuge lever did it')
  end
  T.eq(#gfails(W), 0)
  local n = 0
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('lies outside the alert burrows, a lever inside them', 1, true) then n = n + 1 end end
  T.ok(n <= 2, 'at most one switch per bridge (the pull queued before the alert sounded): ' .. n)
  for _, l in ipairs(W.logs) do T.ok(not tostring(l.msg):find('no worker', 1, true), l.msg) end
end)

T.test('Run 11 deep defense with a hostile 15 tiles from the Kern+ levers: no Hebel+ (the BREACH rule: no civilian is ' ..
       'drawn out of the refuge toward it); GATE_FAIL outside_alert names Tiefe+', function()
  local W = breach_world(deep_cast({S.inv(450, 51, 30)}), 0)
  W.event('INVASION', {id = 33})
  S.run(W, 1000)
  T.ok(#W.find_events('SIEGE_DEEP') >= 1)
  T.eq(W.alert_burrows, {'Tiefe+'})
  local gf = gfails(W, 'outside_alert')
  T.ok(#gf >= 1 and gf[1].msg:find('outside the alert burrow Tiefe+', 1, true), gf[1] and gf[1].msg or 'no GATE_FAIL')
end)

T.test('BUG-027: a popup pause (no ticks, the real clock runs) never turns a pending pull into no_worker or a GATE_FAIL',
       function()
  local W = world{units = cast(), lever_cfg = {[11] = {worker = 100}, [12] = {worker = 100}}}
  W.event('INVASION', {id = 22})
  run(W, 50)
  T.eq(#S.pulls(W, 'O1'), 1)
  df.global.pause_state = true                                 -- a popup: DF pauses, the kernel frames go on
  for _ = 1, 2000 do W.frame(9); W.watch() end                 -- 32 s of real time
  df.global.pause_state = false
  T.eq(#S.acts(W, 'cancel_own_lever_job'), 0)
  T.eq(#W.find_events('GATE_FAIL'), 0)
  run(W, 300)
  T.eq(S.bstate(W, 'O1'), 'up')
  T.eq(#S.pulls(W, 'O1'), 1, 'the same pull did it')
end)

T.done()
