-- NEU19 BUG-928 (Run 17 i3 Orangering: B1 'not up after 3900 / 40825 / 799475 ticks' and GATE_FAIL 'blocked: soldier ... can reach it in N ticks' in an ALERT started by a lone plant eater
-- 19-20 tiles from a citizen, while the kernel itself keeps the bridge down under the reach rule of round 15b): outside SIEGE / BREACH a bridge held down ON PURPOSE is no failure. The hold is
-- said in ONE GATE `reach_hold` line per FAIL_REPEAT (class C), the ONE DECISION_NEEDED gate_reach_traffic comes from the reach rule as before, and GATE_FAIL stays for what is a failure: a unit ON
-- the footprint, SIEGE / BREACH, no worker. EVENT WORDING ONLY: when a bridge is raised or lowered is unchanged (the 15b traffic tests pin that; nobody is crushed here either).
-- (SIEGE TRAFFIC test: b1_world, a real hostile, soldiers pacing at the station, the real gate / siege / sense.)
local T = require('testlib')
local S = require('siege_world')
local B = require('b1_world')
local Z = S.Z

local PACE3 = {{0, -1}, {0, 0}, {1, -1}, {1, 0}}
local function soldiers(ids, pace)
  local r = {}
  for _, id in ipairs(ids) do r[#r + 1] = {id = id, kind = 'soldier', pos = {51, 44}, pace = pace, nopath = true} end
  return r
end
local function alert_world(o)
  return B.build{mode = o and o.mode or 'ALERT', lock = 'lockdown', real_mil = true, hidden = o and o.hidden,
                 actors = soldiers({5, 101, 102, 103}, PACE3), army = {S.inv(250, 51, 15, Z)}}
end
local function b1_fails(W)
  local r = {}
  for _, e in ipairs(W.find_events('GATE_FAIL')) do if e.d.bridge == 'B1' then r[#r + 1] = e end end
  return r
end

T.test('BUG-928: ALERT, soldiers pacing 3-4 tiles from B1 hold the raise under the reach rule: no GATE_FAIL (class A) for B1, ONE GATE reach_hold line names who can reach it, at most one gate_reach_traffic, B1 stays down, nobody crushed', function()
  local W = alert_world()
  B.run(W, 4800)
  T.eq(W.K.mode(), 'ALERT')
  T.eq(S.bstate(W, 'B1'), 'down', 'behaviour unchanged: the soldiers at their station can reach it, not raised')
  T.eq(#B.pulls(W, 'B1'), 0, 'no pull')
  T.eq(#W.crushed, 0)
  T.eq(#b1_fails(W), 0, 'no GATE_FAIL for a deliberate hold: ' .. tostring(b1_fails(W)[1] and b1_fails(W)[1].msg))
  local rh = B.events(W, 'GATE', 'reach_hold')
  T.ok(#rh >= 1, 'the hold is said')
  T.eq(rh[1].cls, 'C')
  T.ok(rh[1].msg:find('held down by the reach rule on purpose', 1, true) and rh[1].msg:find('can reach it in', 1, true) and rh[1].msg:find('soldier', 1, true), rh[1].msg)
  T.ok(rh[1].d.ticks >= 900 and type(rh[1].d.units) == 'table' and #rh[1].d.units >= 1, 'ticks and units')
  local dn = 0
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'gate_reach_traffic' then dn = dn + 1 end end
  T.ok(dn <= 1, 'at most one DECISION_NEEDED gate_reach_traffic per want: ' .. dn)
end)

T.test('BUG-928: SIEGE (not the reach rule): a soldier ON the footprint still ends as GATE_FAIL naming him; the reach_hold line is for ALERT / RECOVERY / PEACE only', function()
  local W2 = B.build{mode = 'SIEGE', lock = 'lockdown', real_mil = true, hidden = true,
                     actors = {{id = 110, kind = 'soldier', pos = {51, 40}, still = true, nopath = true}}, army = {S.inv(250, 51, 15, Z)}}
  B.run(W2, 2400)
  T.eq(S.bstate(W2, 'B1'), 'down')
  local f = b1_fails(W2)
  T.ok(#f >= 1 and f[1].msg:find('soldier 110 on the footprint', 1, true), f[1] and f[1].msg)
  T.eq(#B.events(W2, 'GATE', 'reach_hold'), 0, 'no reach_hold in SIEGE')
  T.eq(#W2.crushed, 0)
end)

T.test('BUG-928: a leftover quiet want (peace_gates) in an ALERT without lockdown carries the age of the PEACE it came from: no GATE_FAIL (the age is not an alert failure)', function()
  local G = package.loaded['dfllm.gate']
  T.ok(G.reach_held ~= nil, 'M.reach_held is public')
  local K = {neu_cfg = nil}
  local r = {block = {{id = 1, d = 5, k = 'soldier', reach = 90}, {id = 2, d = 7, k = 'citizen', reach = 63}}}
  local W = alert_world()
  T.eq(G.reach_held(W.K, r, 'ALERT'), true)
  T.eq(G.reach_held(W.K, r, 'RECOVERY'), true)
  T.eq(G.reach_held(W.K, r, 'PEACE'), true)
  T.eq(G.reach_held(W.K, r, 'SIEGE'), false)
  T.eq(G.reach_held(W.K, r, 'BREACH'), false)
  T.eq(G.reach_held(W.K, r, 'DRILL'), false, 'a drill reports through drill.kpi')
  T.eq(G.reach_held(W.K, {block = {{id = 1, d = 0, k = 'soldier'}, {id = 2, d = 7, k = 'citizen', reach = 63}}}, 'ALERT'), false, 'a unit ON the footprint is no reach hold')
  T.eq(G.reach_held(W.K, {block = {}}, 'ALERT'), false)
  T.eq(G.reach_held(W.K, {}, 'ALERT'), false)
end)

T.test('BUG-928 (verifier): the reach_hold return still marks the bridge failed (no GATE_FAIL) so the ALERT -> SIEGE switch with a reach-held bridge behaves as before: B1 stays down, nobody is crushed, not_up reports failed', function()
  local W = alert_world()
  B.run(W, 4800)
  T.eq(#b1_fails(W), 0, 'no GATE_FAIL in the ALERT')
  local G = package.loaded['dfllm.gate']
  local nb
  for _, x in ipairs(G.not_up(W.K) or {}) do if x.bridge == 'B1' then nb = x end end
  T.ok(nb ~= nil and nb.failed == true, 'failed as before: siege failed_bridge / breach_stuck read it: ' .. T.show(nb))
  W.K.set_mode('SIEGE', 'test: the plant eater turned out to be a siege')
  B.run(W, 2400)
  T.ok(W.K.mode() == 'SIEGE' or W.K.mode() == 'BREACH', 'mode ' .. tostring(W.K.mode()))
  -- measured identical on 0f4f08a4 (before BUG-928), the first BUG-928 commit and this one: the SIEGE raises B1 with one pull, nobody is crushed
  T.eq(S.bstate(W, 'B1'), 'up', 'SIEGE raises it as before')
  T.eq(#B.pulls(W, 'B1'), 1, 'one pull, as before')
  T.eq(#W.crushed, 0)
  T.eq(#b1_fails(W), 0, 'no GATE_FAIL for it')
end)

-- BUG-928 verifier round 2 (SIEGE TRAFFIC): what gate.not_up / gate.kpi.fails / GATE_FAIL / pulls say, measured with these fixtures on main 0f4f08a4's gate.lua (temporary swap, restored)
-- and on this one; the expected strings ARE the measured main values except gf (main emitted the class A GATE_FAIL of the reach hold: gf=1 in (b) and (c); here the GATE reach_hold line: gf=0).
local function measure(W)
  local G = package.loaded['dfllm.gate']
  local nb
  for _, x in ipairs(G.not_up(W.K) or {}) do if x.bridge == 'B1' then nb = x end end
  local fl = {}
  for _, f in ipairs(G.kpi(W.K).fails or {}) do if f:sub(1, 3) == 'B1:' then fl[#fl + 1] = f end end
  return {nu = nb ~= nil, failed = nb ~= nil and nb.failed == true, kfails = #fl, kwhy = fl[1] or '-', gf = #b1_fails(W),
          st = S.bstate(W, 'B1'), pulls = #B.pulls(W, 'B1'), crushed = #W.crushed}
end
local function show(m) return string.format('nu=%s failed=%s kfails=%d kwhy=%s gf=%d st=%s pulls=%d crushed=%d', tostring(m.nu), tostring(m.failed), m.kfails, m.kwhy, m.gf, m.st, m.pulls, m.crushed) end
local MEASURE_ONLY = os.getenv('DF_MEASURE_928')
local function expect(label, m, want)
  if MEASURE_ONLY then print('MEASURED ' .. label .. ' ' .. show(m)) return end
  T.eq(show(m), want, label)
end

T.test('BUG-928 (verifier 2): (a) a bridge already up in an ALERT (the PEACE peace_gates want carried over): not in not_up, not failed, no kpi fail, no GATE_FAIL; (b) reach-held B1 in ALERT; (c) after set_mode(SIEGE): identical to main 0f4f08a4', function()
  local up = B.build{mode = 'PEACE', lock = nil, base = false, closed = {B1 = true}, cfg = {decisions = {['D-14'] = 'up'}, reflex = {v = 2, gate = {peace_clear = 0, peace_clear_r = 2}}}, actors = {}, army = {}}
  B.run(up, 1500)
  expect('a0 PEACE up', measure(up), 'nu=false failed=false kfails=0 kwhy=- gf=0 st=up pulls=0 crushed=0')
  up.K.set_mode('ALERT', 'test: a lone plant eater')
  B.run(up, 4800)
  expect('a ALERT already up', measure(up), 'nu=false failed=false kfails=0 kwhy=- gf=0 st=up pulls=0 crushed=0')
  up.K.set_mode('SIEGE', 'test: siege')
  B.run(up, 2400)
  expect('a2 SIEGE', measure(up), 'nu=false failed=false kfails=0 kwhy=- gf=0 st=up pulls=0 crushed=0')
  local W = alert_world()
  B.run(W, 4800)
  expect('b ALERT reach-held', measure(W), 'nu=true failed=true kfails=1 kwhy=B1:blocked gf=0 st=down pulls=0 crushed=0')
  W.K.set_mode('SIEGE', 'test: the plant eater turned out to be a siege')
  B.run(W, 2400)
  expect('c SIEGE after reach-held', measure(W), 'nu=false failed=false kfails=1 kwhy=B1:blocked gf=0 st=up pulls=1 crushed=0')
end)

T.done()
