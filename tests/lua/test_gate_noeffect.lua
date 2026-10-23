-- BUG-068 (Run 12 Trussroads, a reclaimed fort): the kernel pulled lever 11808 of the old fort's bridge X11814 six times in
-- one second at timestream speed, each pull without effect. A pull whose job leaves the queue without the bridge moving
-- was only marked `bad` until the other levers were tried; with one lever (or all bad) the same lever was pulled again
-- SETTLE (50) ticks later, for ever. Here: the real sense, threat, siege and gate on the siege world without a fort
-- manifest (unmanaged bridges X1.. as in a reclaimed fort), a SIEGE that wants every bridge up, and levers whose jobs DF
-- drops at once (no worker will ever take them, the bridge never moves).
local T = require('testlib')
local S = require('siege_world')
local Z = S.Z

local function world(o)
  o = o or {}
  local units = S.fort_units()
  for _, u in ipairs(S.army(4, 150, 150)) do units[#units + 1] = u end        -- a far army: the invasion makes SIEGE
  local W = S.world{units = o.peace and S.fort_units() or units, manifest = o.peace and S.manifest() or false,
                    lever_default = o.lever_default}
  W.mil = S.military()
  S.load(W, {W.mil})
  if o.cfg then W.K.cfg.reflex = o.cfg end
  W.dropping = o.drop ~= false              -- DF drops every pull job of the bridge at once: no effect
  return W
end

-- the frame: the gate pass, then DF cancels the pull jobs of the dropped bridge's levers
local function run(W, ticks, at)
  S.run(W, ticks, {at = at, frame = function(dt)
    W.frame(dt)
    if W.dropping then
      for _, lv in ipairs(W.levers) do
        if lv.bridge == 'O1' then
          for i = #lv.jobs - 1, 0, -1 do if lv.jobs[i].job_type == df.job_type.PullLever then lv.jobs:erase(i) end end
        end
      end
    end
  end})
end

local function ne_events(W) return W.find_events('LEVER_NOEFFECT') end

T.test('BUG-068: a lever whose pulls never move the bridge is parked after noeffect_max pulls, doubled per further ' ..
       'parking; LEVER_NOEFFECT reports each lever once; old code: a pull every SETTLE ticks, for ever', function()
  local W = world()
  W.event('INVASION', {id = 1})
  run(W, 2400)
  T.eq(W.K.mode(), 'SIEGE')
  local n = #S.pulls(W, 'O1')
  T.ok(n >= 3, 'the pulls start: ' .. n)
  T.ok(n <= 24, 'at most 3 per lever and parking, 2 levers, waits 300/600/1200 in a fight (old code: ~48): ' .. n)
  local ev = ne_events(W)
  T.eq(#ev, 2, 'one report per lever, not per parking')
  T.eq({ev[1].cls, ev[1].d.bridge ~= nil, ev[1].d.pulls, ev[1].d.state, ev[1].d.wait, ev[1].d.worker},
       {'B', true, 3, 'down', 300, 0}, 'a quarter of the wait in a fight; no worker took any of the dropped jobs')
  T.ok(ev[1].msg:find('3 pulls without effect', 1, true), ev[1].msg)
  T.eq(S.bstate(W, 'O1'), 'down')
  -- levers that work are never parked and never reported
  local Wg = world{drop = false}
  Wg.event('INVASION', {id = 1})
  run(Wg, 1200)
  T.eq(S.bstate(Wg, 'O1'), 'up')
  T.eq(#ne_events(Wg), 0)
end)

T.test('BUG-068: the GATE_FAIL of a bridge with every lever parked says no_effect, not a timeout', function()
  local W = world()
  W.event('INVASION', {id = 1})
  run(W, 1500)
  local gf
  for _, e in ipairs(W.find_events('GATE_FAIL')) do if e.d.bridge == 'O1' or e.d.bridge:find('^X') then gf = gf or e end end
  T.ok(gf, 'GATE_FAIL at the deadline')
  T.eq(gf.d.why, 'no_effect')
end)

T.test('BUG-068: a parked lever is tried again after its wait, and a pull that moves the bridge clears the record', function()
  local W = world()
  W.event('INVASION', {id = 1})
  run(W, 600)
  local parked = #S.pulls(W, 'O1')
  T.ok(parked >= 3 and parked <= 12, 'parked after the first pulls: ' .. parked)
  W.dropping = false                       -- the jobs get workers again
  run(W, 1300)
  T.eq(S.bstate(W, 'O1'), 'up', 'raised after the wait')
  local after = #S.pulls(W, 'O1')
  T.ok(after > parked, 'tried again')
  run(W, 600)
  T.eq(#S.pulls(W, 'O1'), after, 'no pull once it is up')
  T.eq(#ne_events(W), 2, 'still one report per lever')
end)

T.test('BUG-068: config gate.noeffect_max / noeffect_wait set the bound; bad values fall back to 3 / 1200', function()
  local W = world{cfg = {gate = {noeffect_max = 1, noeffect_wait = 2000}}}
  W.event('INVASION', {id = 1})
  run(W, 400)
  local ev = ne_events(W)
  T.eq(#ev, 2)
  T.eq({ev[1].d.pulls, ev[1].d.wait}, {1, 500}, 'a quarter of 2000 in a fight')
  local W2 = world{cfg = {gate = {noeffect_max = 99, noeffect_wait = 5}}}
  W2.event('INVASION', {id = 1})
  run(W2, 600)
  local e2 = ne_events(W2)
  T.eq({e2[1].d.pulls, e2[1].d.wait}, {3, 300})
end)

T.test('BUG-068: in PEACE (the lever verb opens a bridge for a window) the first wait is the whole noeffect_wait', function()
  local W = world{peace = true}
  W.dropping = false
  W.drop_bridge = 'O1'
  local r = W.inbox('lever', {bridge = 'O1', want = 'up'})
  T.ok(r.ok, r.msg)
  W.dropping = true
  run(W, 600)
  T.eq(W.K.mode(), 'PEACE')
  local ev = ne_events(W)
  T.ok(#ev >= 1, 'the lever without effect is reported in PEACE too')
  T.eq({ev[1].d.pulls, ev[1].d.wait}, {3, 1200})
end)

T.done()
