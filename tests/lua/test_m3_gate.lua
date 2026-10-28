-- M3 (BUG-114, Run 14 y707 note 97): unmanaged bridge X25718 stayed down and the kernel pulled lever 25729 every few
-- seconds with new jobs for weeks. BUG-068's parking slows the pulls (8x at most) but never ends them, and no wake said
-- why. Fixture of test_gate_noeffect: a SIEGE that wants every bridge up, levers whose jobs DF drops at once.
local T = require('testlib')
local S = require('siege_world')
local Z = S.Z

local function world(o)
  o = o or {}
  local units = S.fort_units()
  for _, u in ipairs(S.army(4, 150, 150)) do units[#units + 1] = u end
  local W = S.world{units = units, manifest = false}
  W.mil = S.military()
  S.load(W, {W.mil})
  if o.cfg then W.K.cfg.reflex = o.cfg end
  W.dropping = true
  return W
end
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
local function fails(W)
  local r = {}
  for _, e in ipairs(W.find_events('GATE_FAIL')) do if e.d.pulls then r[#r + 1] = e end end
  return r
end

T.test('BUG-114: after gate.pull_cap pulls without effect the bridge gets no pull for giveup_wait ticks and a GATE_FAIL ' ..
       'says why; old code: a pull every few hundred ticks for ever', function()
  local W = world()
  W.event('INVASION', {id = 1})
  run(W, 3000)
  local n1 = #S.pulls(W, 'O1')
  T.ok(n1 >= 15 and n1 <= 18, 'the cap of 15: ' .. n1)
  local f = fails(W)
  T.eq(#f, 1, 'one give-up GATE_FAIL')
  T.eq({f[1].cls, f[1].d.why, f[1].d.pulls, f[1].d.wait, f[1].d.want}, {'A', 'no_effect', 15, 7200, 'up'})
  T.ok(f[1].msg:find('15 pulls without effect', 1, true) and f[1].msg:find('no pull for 7200 ticks', 1, true)
       and f[1].msg:find('no worker took one', 1, true), f[1].msg)
  run(W, 3500)
  T.eq(#S.pulls(W, 'O1'), n1, 'no pull during the wait (old code: ~15 more)')
  run(W, 4500)                                          -- the wait (7200) is over: one test pull
  local n2 = #S.pulls(W, 'O1')
  T.ok(n2 > n1 and n2 <= n1 + 2, 'one test pull: ' .. n1 .. ' -> ' .. n2)
  f = fails(W)
  T.eq(#f, 2, 'the failed test pull gives up again')
  T.eq(f[2].d.wait, 14400, 'doubled')
  T.eq(require('dfllm.util.contract').check_state(W.state()), {})
end)

T.test('BUG-114: the give-up names who stands on the footprint; gate.not_up says why a bridge is not up', function()
  local W = world()
  W.event('INVASION', {id = 1})
  run(W, 300)
  local na = W.K.call('gate', 'not_up')
  local ok, list = W.K.call('gate', 'not_up')
  T.ok(ok and #list >= 1, 'bridges wanted up that are not')
  T.ok(type(list[1].bridge) == 'string' and #list[1].why > 0)
  run(W, 3000)
  ok, list = W.K.call('gate', 'not_up')
  local why
  for _, x in ipairs(list) do if x.why:find('no effect', 1, true) then why = x.why end end
  T.ok(why and why:find('15 pulls', 1, true), tostring(why))
end)

T.test('BUG-114: a working lever is never given up on; a test pull that moves the bridge clears the record', function()
  local W = world()
  W.event('INVASION', {id = 1})
  run(W, 600)
  W.dropping = false
  run(W, 1500)
  T.eq(S.bstate(W, 'O1'), 'up')
  T.eq(#fails(W), 0)
end)

T.test('BUG-114: config gate.pull_cap and giveup_wait set the bound; a bad value is the default', function()
  local W = world{cfg = {gate = {pull_cap = 4, giveup_wait = 1000}}}
  W.event('INVASION', {id = 1})
  run(W, 2000)
  local f = fails(W)
  T.ok(#f >= 1 and f[1].d.pulls == 4 and f[1].d.wait == 1000, f[1] and f[1].msg)
  local W2 = world{cfg = {gate = {pull_cap = 1, giveup_wait = 5}}}
  W2.event('INVASION', {id = 1})
  run(W2, 3000)
  f = fails(W2)
  T.eq({f[1].d.pulls, f[1].d.wait}, {15, 7200})
end)

T.done()
