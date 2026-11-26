-- Neuausrichtung 15b, third review (BUG-907, the post-job gap): the reach rule (gate.reach_hold) cancels a pull only while its lever job is queued (the units
-- that WALK within reach_ticks / REACH_TPT tiles hold it; units that stand past the 24-tile census scan do not, else an idle fort would keep B1 down for
-- good). A unit that stands out there when the pull is queued and starts to walk right after the lever job has vanished can be on the footprint while the bridge still
-- moves (100 to 380 ticks, nothing stops it). It is NOT closed; these tests show it (the walker is crushed in the simulator) and pin that the kernel SAYS so
-- when it queues the pull (GATE state reach_resid + kern.log). The quiet PEACE raise looks at PEACE_R = 20 tiles only: a walker 21..40 tiles out is the same case.
-- When the rule is one day closed, these tests must be changed on purpose (the crush assertions are the residual).
local T = require('testlib')
local S = require('siege_world')
local B = require('b1_world')
local Z = S.Z

-- a unit standing `y0` rows north of the footprint row 40 (x 51) that starts to walk toward it the frame the lever job has gone and the bridge starts to move
local function late_walker(id, y0)
  return {id = id, kind = 'citizen', pos = {51, y0}, nopath = true,
          fn = function(W, rel, a)
            if not a.go and S.bstate(W, 'B1') == 'moving' then a.go, a.t = true, rel end
            if a.go then
              local y = math.min(y0 + (rel - a.t) // 9, 41)
              W.move(a.id, 51, y, Z)
            end
          end}
end
local function logged(W, s)
  for _, l in ipairs(W.logs) do if l.msg:find(s, 1, true) then return l.msg end end
end

T.test('(i) post-job gap, ALERT: a unit standing 30 tiles out starts to walk right after the lever job has vanished: B1 is pulled (he does not hold), he reaches the ' ..
       'footprint while it moves (the residual: crushed in the simulator), and the kernel says so (GATE reach_resid, kern.log)', function()
  local W = B.build{mode = 'ALERT', lock = 'lockdown', lat = 1000, move = 380, actors = {late_walker(900, 10)}, army = {S.inv(250, 51, 20, Z)}}
  B.run(W, 1500)
  local pulls = B.pulls(W, 'B1')
  T.eq(#pulls >= 1, true, 'B1 pulled: he stands, so he does not hold')
  local ev = B.events(W, 'GATE', 'reach_resid')
  T.eq(#ev >= 1, true, 'GATE reach_resid says what the rule could not see')
  T.ok(ev[1] and ev[1].d.bridge == 'B1' and ev[1].d.n >= 1 and ev[1].msg:find('starts to walk after the lever job', 1, true), ev[1] and ev[1].msg)
  T.ok(logged(W, 'the reach rule cannot see a walk before it starts'), 'kern.log says it too')
  T.eq(#W.crushed, 1, 'the residual: he walks onto the footprint (30 x 9 = 270 ticks) while it moves (380): ' .. table.concat(W.crushed, '; '))
end)

T.test('(i) post-job gap, ALERT: the same unit standing 12 tiles out holds the pull (inside the census scan: standing or not); nobody crushed, no pull', function()
  local W = B.build{mode = 'ALERT', lock = 'lockdown', lat = 1000, move = 380, actors = {late_walker(901, 28)}, army = {S.inv(250, 51, 20, Z)}}
  B.run(W, 1500)
  T.eq(#B.pulls(W, 'B1'), 0, 'no pull while a unit within the census scan can reach it')
  T.eq(#W.crushed, 0)
  T.eq(#B.events(W, 'GATE', 'reach_resid'), 0)
end)

T.test('(ii) post-job gap, quiet PEACE: the quiet raise looks at 20 tiles (PEACE_R); a unit standing 21..40 tiles out that starts to walk after the job is done is the same ' ..
       'residual: B1 is pulled, the kernel says so; a unit within 20 tiles still holds the raise', function()
  for _, y0 in ipairs({19, 15, 0}) do                          -- 21, 25 and 40 tiles from the footprint row 40
    local W = B.build{lat = 645, move = 380, actors = {late_walker(910 + y0, y0)}}
    B.run(W, 2600)
    local pulls = B.pulls(W, 'B1')
    T.eq(#pulls >= 1, true, y0 .. ': pulled with a unit ' .. (40 - y0) .. ' tiles out')
    local ev = B.events(W, 'GATE', 'reach_resid')
    T.eq(#ev >= 1, true, y0 .. ': GATE reach_resid')
    T.ok(ev[1] and ev[1].msg:find('quiet PEACE', 1, true), ev[1] and ev[1].msg)
    T.eq(#W.crushed, 1, y0 .. ': residual: ' .. table.concat(W.crushed, '; '))      -- 40 tiles = 360 ticks, inside the longest live movement (380)
  end
  local W = B.build{lat = 645, move = 380, actors = {late_walker(930, 22)}}      -- 18 tiles out: holds
  B.run(W, 2600)
  T.eq(#B.pulls(W, 'B1'), 0, 'a unit 18 tiles out holds the quiet raise')
  T.eq(#W.crushed, 0)
end)

T.done()
