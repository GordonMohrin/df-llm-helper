-- BUG-342 (Run 15 sieges: i3 Earthboat y387 GATE_FAIL B2 'no_worker' x2 and BREACH 'O1 not up at T+900', i4 Drillchamber
-- GATE_FAIL O1/B2 'no_worker'): every one of those GATE_FAILs came 5-50 ticks after a fresh pull (the LEVER events), the
-- pulls before it were cancelled one after the other for units walking toward the bridge ('B2 up pull cancelled: citizen
-- 26729 2 tiles from it and walking toward it', 90 B2 pulls in 1,100 ticks); gate read the fresh pull's missing worker as
-- the reason. And fortcore's B2 landing room 'dfllm-levers-b2' lies 1-3 tiles from B2's footprint: a lever puller waiting
-- there held his own bridge ('B2 up waits for citizen 27079 next to it', 27079 a puller of dfllm-levers-b2).
-- Fixture: the siege world (k_mock, the lever simulator) with a lever room beside O1 and act.burrow_units.
local T = require('testlib')
local S = require('siege_world')
local C = require('dfllm.util.contract')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local LEVER = {53, 11, Z}                  -- one tile beside O1's footprint (50-52, 10)
local ROOM = {53, 11, Z, 54, 12, Z}        -- 'dfllm-levers': the lever and three tiles around it

local function world(o)
  o = o or {}
  C.ACT.burrow_units = {'gate'}
  local m = S.manifest()
  m.bridges.O1.levers = {LEVER}
  if o.room ~= false then m.burrows['dfllm-levers'] = {role = 'other'} end
  local units = S.fort_units()
  units[#units + 1] = S.cit(6, o.x6 or LEVER[1], o.y6 or LEVER[2])   -- a puller, waiting at the lever
  units[#units + 1] = S.cit(7, 50, 15)                                -- a passer-by, 5 tiles from O1
  for _, u in ipairs(S.army(4, 150, 150)) do units[#units + 1] = u end
  local W = S.world{units = units, manifest = m, lever_default = {worker = o.worker or 30, pull = 40}}
  if o.room ~= false then W.burrow('dfllm-levers', ROOM) end
  W.act_result('burrow_units', function(name, ids)
    local b = dfhack.burrows.findByName(name)
    if not b then return false, 'no burrow ' .. tostring(name) end
    b.units = kmock.vec(ids)
    return true, #ids
  end)
  W.mil = S.military()
  S.load(W, {W.mil})
  return W
end

-- the pull's worker is citizen 6 (he stands at the lever); o.passer: citizen 7 walks toward O1 one tile per frame while a
-- worker holds a pull (5 tiles from it down to 2) and goes back to 5 tiles when none does
local function run(W, ticks, o)
  o = o or {}
  local y7 = 15
  S.run(W, ticks, {frame = function(dt)
    W.frame(dt)
    local working = false
    for _, lv in ipairs(W.levers) do
      for _, j in ipairs(lv.jobs) do
        if j._worker then
          working = true
          if j._worker.id == 9999 then j._worker = W.unit(6) end
        end
      end
    end
    if o.passer then
      y7 = working and math.max(12, y7 - 1) or 15
      W.move(7, 50, y7, Z)
    end
  end})
end

local function fails(W, b)
  local r = {}
  for _, e in ipairs(W.find_events('GATE_FAIL')) do if e.d.bridge == b then r[#r + 1] = e end end
  return r
end

T.test('BUG-342: a lever puller waiting in his room beside the footprint does not hold the raise: O1 rises', function()
  local W = world()
  W.event('INVASION', {id = 1})
  run(W, 1500)
  local ok, pul = W.K.call('gate', 'puller_of')
  T.eq(ok and pul[6], 'dfllm-levers', 'citizen 6 is a puller of the room')
  T.eq(S.bstate(W, 'O1'), 'up', 'old code: "O1 up waits for citizen 6 next to it", no pull queued')
  T.eq(#fails(W, 'O1'), 0)
end)

T.test('BUG-342: the same citizen beside the footprint who is no puller (no room) still holds it', function()
  local W = world{room = false}
  W.event('INVASION', {id = 1})
  run(W, 1500)
  T.ok(S.bstate(W, 'O1') ~= 'up', 'a citizen beside the bridge outside any lever room holds the raise')
  T.eq(#S.pulls(W, 'O1'), 0, 'no pull queued while he stands there')
end)

T.test('BUG-342: a puller ON the footprint holds the raise like anybody', function()
  local W = world{x6 = 51, y6 = 10}
  W.burrow('dfllm-levers', {51, 10, Z, 54, 12, Z})      -- a room reaching onto the footprint
  W.event('INVASION', {id = 1})
  run(W, 1500)
  T.ok(S.bstate(W, 'O1') ~= 'up', 'never raised onto him')
end)

T.test('BUG-342: pulls cancelled for a unit walking toward the bridge fail as cancelled (not no_worker), naming him',
       function()
  local W = world{x6 = 60, y6 = 80}
  W.event('INVASION', {id = 1})
  run(W, 3600, {passer = true})
  local f = fails(W, 'O1')
  T.eq(#f >= 1, true, 'a GATE_FAIL at the deadline (after the AP_CREDIT cancels the deadline runs again)')
  T.eq(f[1].d.why, 'cancelled', 'old code: no_worker (the fresh pull after the last cancel had no worker yet)')
  T.ok(f[1].d.pulls >= 2, 'pulls ' .. tostring(f[1].d.pulls))
  T.eq(f[1].d.units, {7})
  T.ok(f[1].msg:find('pulls cancelled for units walking toward it, the last citizen 7 3 tiles from it', 1, true), f[1].msg)
  -- BUG-335/342 review: the first AP_CREDIT cancels do not eat the deadline; at that count DECISION_NEEDED gate_traffic
  -- asks once, then the deadline runs again (old: GATE_FAIL at T+900 with the time gone to the cancels, no question)
  local dn = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'gate_traffic' then dn[#dn + 1] = e end end
  T.eq(#dn, 1, 'asked once')
  T.eq({dn[1].d.bridge, dn[1].d.n, dn[1].d.opts}, {'O1', 8, {'hold_civilians', 'reroute', 'lever'}})
  T.ok(f[1].tick > dn[1].tick, 'GATE_FAIL only after the question')
  T.ok(f[1].d.pulls > 8, 'pulls ' .. tostring(f[1].d.pulls))
  T.eq(require('dfllm.util.contract').check_state(W.state()), {})
end)

T.test('BUG-342: a queued pull without a worker yet reads "queued" in not_up, not no_worker', function()
  local W = world{x6 = 60, y6 = 80, worker = 100000}
  W.event('INVASION', {id = 1})
  run(W, 700)
  local ok, list = W.K.call('gate', 'not_up')
  local why
  for _, x in ipairs(ok and list or {}) do if x.bridge == 'O1' then why = x.why end end
  T.eq(why, 'a pull is queued, no worker yet')
end)

T.test('BUG-342: a pull nobody takes is still no_worker; the message counts them and names the lever pullers', function()
  local W = world{x6 = 60, y6 = 80, worker = 100000}
  W.event('INVASION', {id = 1})
  run(W, 1800)
  local f = fails(W, 'O1')
  T.eq(#f >= 1, true, 'a GATE_FAIL at the deadline')
  T.eq(f[1].d.why, 'no_worker')
  T.ok(f[1].msg:find('not taken in 200 ticks; lever pullers: dfllm-levers 0 of ', 1, true), f[1].msg)
end)

T.test('BUG-342 review: a puller in his room beside the footprint still holds a LOWERING (old: drop_own for both ' ..
       'directions, the intake down of O1 pulled at once with him one tile from it)', function()
  local W = world()
  W.event('INVASION', {id = 1})
  run(W, 1500)
  T.eq(S.bstate(W, 'O1'), 'up')
  local ok, pul = W.K.call('gate', 'puller_of')
  T.eq(ok and pul[6], 'dfllm-levers')
  local n0 = #S.pulls(W, 'O1')
  local okw, res = W.K.call('gate', 'want', 'O1', 'down', 'intake')
  T.ok(okw and res == true, 'wanted down')
  T.eq(#S.pulls(W, 'O1'), n0, 'no lowering pull with the puller one tile from the footprint')
  local b
  for _, e in ipairs(W.find_events('GATE')) do if e.d.state == 'blocked' and e.d.bridge == 'O1' then b = e end end
  T.ok(b and b.msg:find('O1 down waits: citizen 6 next to it', 1, true), b and b.msg)
end)

T.test('BUG-342 review: a puller in his room whose walk path crosses the footprint holds the raise (drop_own keeps ' ..
       'the crossers of BUG-335)', function()
  local W = world()
  local vec = kmock.vec
  W.unit(6).path = {path = {x = vec{52, 51}, y = vec{11, 10}, z = vec{Z, Z}}}
  W.event('INVASION', {id = 1})
  local pul, n = nil, 0
  repeat
    run(W, 50)
    n = n + 50
    pul = select(2, W.K.call('gate', 'puller_of'))
  until (pul and pul[6]) or n >= 1500
  T.eq(pul and pul[6], 'dfllm-levers', 'citizen 6 a puller in his room')
  run(W, 700)         -- BUG-511: he is chosen at once now (standing in the room), the timer raise (T+450) comes after him
  T.ok(S.bstate(W, 'O1') ~= 'up', 'old code: dropped as a puller in his room, raised onto his path')
  local ok, nu = W.K.call('gate', 'not_up')
  local why
  for _, x in ipairs(ok and nu or {}) do if x.bridge == 'O1' then why = x.why end end
  T.ok(why and why:find('citizen 6 walking onto it in 2 steps', 1, true), tostring(why))
end)

T.done()
