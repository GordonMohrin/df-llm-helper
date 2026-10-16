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

T.done()
