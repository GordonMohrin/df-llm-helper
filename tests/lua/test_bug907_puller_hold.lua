-- Neuausrichtung 15b, BUG-907 (verifier round): the lever puller is no exemption from the reach rule. Under the reach rule (ALERT / RECOVERY / PEACE / DRILL, gate.reach on) only the puller who
-- stands AT the lever (next to it, same level) while the pull job of the bridge is live is exempt (drop_own, the worker exemption, the quiet-PEACE skip). An idle puller standing in the lever
-- room, that starts to walk onto the footprint after the job has vanished, is a unit like any other: he holds the pull and nobody is crushed. Fixture: the B1 world (reach ON, the shipped
-- switches) with the lever room 'dfllm-levers' around B1's levers (54-55, 46) and citizen 6 its only puller, a 5-tile walk (45 ticks) from B1's footprint (50-52, 40).
local T = require('testlib')
local S = require('siege_world')
local B = require('b1_world')
local C = require('dfllm.util.contract')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local ROOM = {53, 45, Z, 56, 47, Z}

-- puller 6 idles in the room (55, 47: not next to a lever of B1? (55,46) is adjacent: so he waits at (53, 47) / room corner) and starts to walk onto the footprint after +go
local function puller(go)
  return {id = 6, kind = 'citizen', pos = {53, 47}, nopath = true,
          fn = function(W, rel, a)
            -- the job's worker is the puller: the lever simulator's anonymous worker 9999 becomes citizen 6 (he stands at his room, not at the lever)
            for _, lv in ipairs(W.levers) do
              for _, j in ipairs(lv.jobs) do if j._worker and j._worker.id == 9999 then j._worker = W.unit(6) end end
            end
            if go and not a.go and (S.bstate(W, 'B1') == 'moving' or rel >= go) then a.go, a.t = true, rel end
            if a.go then
              local y = math.max(41, 47 - (rel - a.t) // 9)
              W.move(6, 51, y, Z)
            end
          end}
end

local function world(o)
  C.ACT.burrow_units = {'gate'}
  local m = S.manifest()
  m.burrows = m.burrows or {}
  m.burrows['dfllm-levers'] = {role = 'other'}
  o.manifest = m
  o.deep = true
  local W = B.build(o)
  W.burrow('dfllm-levers', ROOM)
  W.act_result('burrow_units', function(name, ids)
    local b = dfhack.burrows.findByName(name)
    if not b then return false, 'no burrow ' .. tostring(name) end
    b.units = kmock.vec(ids)
    return true, #ids
  end)
  return W
end

T.test('puller idle in his lever room, starts to walk onto B1 after the job would be done: ALERT, latency 1000 -> nobody crushed', function()
  local W = world{mode = 'ALERT', lock = 'lockdown', lat = 1000, move = 380, actors = {puller(150)}, army = {S.inv(250, 51, 20, Z)}}
  B.run(W, 2400)
  T.eq(#W.crushed, 0, 'nobody crushed: ' .. table.concat(W.crushed, '; '))
  T.eq(#B.pulls(W, 'B1'), 0, 'the idle puller is a reach unit: no pull')
  T.eq(S.bstate(W, 'B1'), 'down', 'B1 stays down')
end)

T.test('puller idle in his lever room: quiet PEACE -> nobody crushed', function()
  local W = world{lat = 645, move = 380, actors = {puller(150)}}
  B.run(W, 3000)
  T.eq(#W.crushed, 0, 'nobody crushed: ' .. table.concat(W.crushed, '; '))
  T.eq(#B.pulls(W, 'B1'), 0, 'no pull')
  T.eq(S.bstate(W, 'B1'), 'down')
end)

T.test('control: the same fort with a puller who stays in his room and nobody else: he still holds (a 5-tile walk), B1 stays down, no crush', function()
  local W = world{mode = 'ALERT', lock = 'lockdown', lat = 1000, move = 380, actors = {puller(nil)}, army = {S.inv(250, 51, 20, Z)}}
  B.run(W, 1500)
  T.eq(#W.crushed, 0)
  T.eq(S.bstate(W, 'B1'), 'down')
end)

T.test('the exemption stays narrow and exact: only AT a live job\'s lever (same level, next to the tile)', function()
  local G = package.loaded['dfllm.gate'] or require('dfllm.gate')
  local W = world{mode = 'ALERT', lock = 'lockdown', lat = 1000, actors = {puller(nil)}}
  B.run(W, 20)
  T.eq(G.at_lever('B1', 54, 47, Z), false, 'no live job: nobody is at the lever')
  T.eq(G.at_lever('B1', nil, nil, nil), false, 'a unit without a map position is never at the lever')
end)

T.done()
