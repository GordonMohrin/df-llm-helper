-- M3 (BUG-114, Run 14 y707 note 97): BREACH never ended while a bridge stayed down although nobody was inside and the
-- enemy stood far away; the status did not say what it waited for. Fixtures of test_siege.lua (no worker on O1: BREACH at
-- T+900, GATE_FAIL no_worker) with the army far away.
local T = require('testlib')
local S = require('siege_world')
local Z = S.Z

local function setup(o)
  o = o or {}
  local units = S.fort_units()
  for _, u in ipairs(o.army or S.army(6, 150, 150)) do units[#units + 1] = u end
  local W = S.world{units = units, lever_cfg = {[11] = {}, [12] = {}}, cfg = o.cfg}
  W.mil = S.military()
  if o.on_station then W.mil.kpi = function() return {squads = 3, soldiers = 8, worn = 95, cv = 13, metal_pct = 0, on_station = o.on_station,
                                                     off = o.off, in_kern = o.in_kern} end end
  S.load(W, {W.mil})
  if o.cfg then W.K.cfg.reflex = o.cfg.reflex end
  return W
end

T.test('BUG-114: a BREACH whose failed bridge stays down, nobody inside and the enemy far, falls back to SIEGE after ' ..
       'breach.stuck_ticks; no BREACH again for the same bridge; old code: BREACH for ever', function()
  local W = setup()
  S.run(W, 1500)
  T.eq(W.K.mode(), 'BREACH')
  S.run(W, 1500)
  T.eq(W.K.mode(), 'BREACH', 'not before stuck_ticks')
  S.run(W, 2500)
  T.eq(W.K.mode(), 'SIEGE', 'old code: BREACH')
  local st = W.find_events('SIEGE_START')
  local last = st[#st]
  T.eq(last.d.why, 'bridge_stuck')
  T.ok(last.msg:find('stay down', 1, true) and last.msg:find('O1', 1, true), last.msg)
  S.run(W, 6000)
  T.eq(W.K.mode(), 'SIEGE', 'no flapping back into BREACH')
  T.eq(#W.find_events('BREACH'), 1)
end)

T.test('BUG-114: the status line of a BREACH names what it waits for: the bridge and why, the quiet clock', function()
  local W = setup()
  S.run(W, 1500)
  local w = W.state().wave
  T.ok(w.ba >= 500 and w.ba <= 700, tostring(w.ba))
  T.ok(w.bw:find('waiting for O1 up:', 1, true) and w.bw:find('quiet clock: 6 invaders in sight', 1, true), w.bw)
  T.eq(require('dfllm.util.contract').check_state(W.state()), {})
end)

T.test('BUG-114: no fallback with a hostile inside, one near the bridge, soldiers off their stations or stuck_ticks 0', function()
  local W = setup{army = S.army(6, 52, 20)}                     -- 10 tiles from O1
  S.run(W, 6000)
  T.eq(W.K.mode(), 'BREACH')
  local W2 = setup{on_station = 2}
  S.run(W2, 6000)
  T.eq(W2.K.mode(), 'BREACH', 'the soldiers stand elsewhere')
  local W3 = setup{cfg = {reflex = {v = 2, breach = {stuck_ticks = 0}}}}
  S.run(W3, 6000)
  T.eq(W3.K.mode(), 'BREACH')
  local W4 = setup{cfg = {reflex = {v = 2, breach = {stuck_ticks = 600}}}}
  S.run(W4, 3000)
  T.eq(W4.K.mode(), 'SIEGE', 'config shortens it')
end)

T.test('BUG-215 (live t4: on_station 0 of 8, off nost 8): no station order for the soldiers and the soldiers in ' ..
       'Kern+: the stuck-bridge fallback comes; outside Kern+ it does not', function()
  local W = setup{on_station = 0, off = {nost = 8}, in_kern = 8}
  S.run(W, 6000)
  T.eq(W.K.mode(), 'SIEGE', 'old code: BREACH (0 of 8 at their stations)')
  local W2 = setup{on_station = 0, off = {nost = 8}, in_kern = 1}
  S.run(W2, 6000)
  T.eq(W2.K.mode(), 'BREACH')
end)

T.test('BUG-114: the stuck mark ends with a hostile near the bridge: BREACH again at once', function()
  local W = setup()
  S.run(W, 4400)
  T.eq(W.K.mode(), 'SIEGE')
  W.unit(201)._m.x, W.unit(201)._m.y = 51, 20                    -- one comes within 30 tiles of O1
  S.run(W, 200)
  T.eq(W.K.mode(), 'BREACH')
end)

T.test('BUG-114 (note 97 d): with no enemy in sight a BREACH over a bridge that stays down ends after the 2,400 quiet ' ..
       'ticks: RECOVERY (the clock is free there); the proof the fixture gives for the part of the note that is not a bug', function()
  local W = setup()
  S.run(W, 1500)
  T.eq(W.K.mode(), 'BREACH')
  for i = 201, 206 do W.unit(i)._m.hidden = true end
  S.run(W, 2200)
  T.eq(W.K.mode(), 'BREACH', 'inside the quiet window')
  S.run(W, 600)
  T.eq(W.K.mode(), 'RECOVERY')
  T.ok(W.state().wave == nil or W.state().wave.bw == nil, 'no BREACH line any more')
end)

T.done()
