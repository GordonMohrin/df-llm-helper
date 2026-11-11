-- BUG-729 (Run 16c i3 Wallfree y373: a smilodon struck citizen 26523 down while its PREDATOR waited for the ack; the 60 s default came
-- after the kill): a PREDATOR whose unit stands inside Kern+ / past B1 or within reflex.PRED_NEAR tiles of a citizen gets its lockdown
-- default after PRED_NEAR_S real seconds; a farther one (within predator_near) keeps the ack_timeout_s wait.
local T = require('testlib')
local S = require('siege_world')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local function setup(tag, units, bridges)
  local dir = H.tmpdir(tag)
  luahost.mkdir_recursive(dir .. '/dfllm-runtime/mock')
  local W = S.world{manifest = (not bridges) and false or nil, units = units, dfpath = dir, ms_per_frame = 500}
  W.dir = dir
  df.global.world.status.popups = kmock.vec{}
  package.loaded['plugins.timestream'] = {timestream_getFps = function() return W.timestream_fps end}
  W.tiles = {}
  local snap = {name = 'snapshot', every = {ticks = 100}}
  function snap.tile() return {c = '.', dig = '', bld = ''} end
  function snap.far() return false end
  snap.outside_near = require('dfllm.snapshot').outside_near
  for _, n in ipairs({'reflex', 'arbiter'}) do package.loaded['dfllm.' .. n] = nil end
  S.load(W, {S.military(), snap, require('dfllm.reflex'), require('dfllm.arbiter')})
  return W
end
local function events(W, t)
  local r = {}
  for _, e in ipairs(W.events) do if e.type == t then r[#r + 1] = e end end
  return r
end

T.test('BUG-729: a predator inside the fort gets the lockdown default after PRED_NEAR_S (10 s), not 60 s', function()
  local units = S.fort_units()
  units[#units + 1] = S.danger(400, 62, 72)
  local W = setup('pq1', units)
  S.run(W, 36)                                           -- 4 frames of 500 ms
  T.eq(#events(W, 'PREDATOR'), 1)
  T.eq(#events(W, 'LOCKDOWN'), 0, 'not yet: under 10 s')
  S.run(W, 300)                                          -- ~15 s of frames
  local l = events(W, 'LOCKDOWN')
  T.ok(#l >= 1 and l[1].d.why == 'ack_timeout' and l[1].d.type == 'PREDATOR', 'the default came: ' .. #l)
end)

T.test('BUG-729: a predator 30 tiles from a woodcutter (not near) keeps the 60 s wait', function()
  local units = S.fort_units()
  units[#units + 1] = S.danger(400, 150, 30)
  local W = setup('pq2', units)
  W.move(2, 120, 30, Z)
  S.run(W, 36)
  T.eq(#events(W, 'PREDATOR'), 1, 'within predator_near: a PREDATOR')
  S.run(W, 360)                                          -- ~25 s
  T.eq(#events(W, 'LOCKDOWN'), 0, 'no default after 25 s')
  S.run(W, 900)                                          -- past 60 s
  T.ok(#events(W, 'LOCKDOWN') >= 1, 'the 60 s default still applies')
end)

-- siege traffic test: an army at O1 and a predator beside a woodcutter at the same time: the quick PREDATOR default (lockdown, clock, civ
-- alert) and the siege must not fight over the bridges: SIEGE at once, O1 and B1 up and held, no BREACH, no double pull
T.test('BUG-729 siege traffic: an army at O1 plus a predator beside a woodcutter: SIEGE, bridges up and held, the default comes once', function()
  local units = S.fort_units()
  for _, u in ipairs(S.army(6, 51, 0)) do units[#units + 1] = u end
  units[#units + 1] = S.danger(400, 150, 30)
  local W = setup('pq3', units, true)
  W.move(2, 140, 30, Z)
  S.run(W, 600)
  T.eq(W.K.mode(), 'SIEGE')
  T.eq(#events(W, 'SIEGE_START'), 1)
  T.eq(W.state().bridges.O1, 'up', 'O1 raised')
  T.eq(W.state().bridges.B1, 'up', 'B1 raised')
  local l = events(W, 'LOCKDOWN')
  T.ok(#l >= 1, 'the quick default fired')
  S.run(W, 600)
  T.eq(W.K.mode(), 'SIEGE')
  T.eq(W.state().bridges.O1, 'up')
  T.eq(#events(W, 'BREACH') + #events(W, 'GATE_FAIL'), 0)
  T.eq(W.pending_violations, 0, 'two pending pulls on one bridge')
  T.eq(S.kpi(W).double_toggles, 0)
end)

T.done()
