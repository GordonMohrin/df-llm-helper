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

T.done()
