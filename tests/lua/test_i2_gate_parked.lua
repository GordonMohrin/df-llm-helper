-- Integration audit I2 (BUG-082): C2's parked lever (BUG-068) against the reflex lockdown's deferred civ alert (BUG-013).
-- gate.pulls() counted a bridge whose every linked lever was parked for no effect (r.stuck 'no_effect') as a pull still
-- to do (needs_pull: NO_PULL had blocked, no_lever, guard and manual only), so the lockdown's civ alert waited for a pull
-- that was not going to be made, up to reflex.ALERT_MAX (1500) ticks, and the gates text said "1 pull pending".
local T = require('testlib')
local S = require('siege_world')

local function world()
  local units = S.fort_units()
  for _, u in ipairs(S.army(4, 150, 150)) do units[#units + 1] = u end
  local W = S.world{units = units, manifest = false}
  W.mil = S.military()
  S.load(W, {W.mil})
  W.dropping = true
  return W
end

local function run(W, ticks)
  S.run(W, ticks, {frame = function(dt)
    W.frame(dt)
    if W.dropping then
      for _, lv in ipairs(W.levers) do
        for i = #lv.jobs - 1, 0, -1 do if lv.jobs[i].job_type == df.job_type.PullLever then lv.jobs:erase(i) end end
      end
    end
  end})
end

T.test('BUG-082: a bridge whose levers are all parked for no effect is no pull to wait for (gate.pulls().left)', function()
  local W = world()
  W.event('INVASION', {id = 1})
  run(W, 500)
  local parked = false
  for _, e in ipairs(W.find_events('LEVER_NOEFFECT')) do parked = true end
  T.ok(parked, 'the levers are parked after noeffect_max pulls')
  local ok, p = W.K.call('gate', 'pulls')
  T.ok(ok and p.want > 0, 'a bridge is wanted up')
  T.eq(p.up, 0)
  T.eq(p.left, 0, 'a parked lever is no pull pending: the alert must not wait for it')
  T.eq(p.parked, p.want, 'the parked bridges are counted apart')
  run(W, 300)                                -- the park (300 ticks in a fight) is over: a real pull is pending again
  local _, p2 = W.K.call('gate', 'pulls')
  T.eq({p2.left, p2.parked}, {p2.want, nil}, 'a lever tried again is a pull to wait for')
end)

T.done()
