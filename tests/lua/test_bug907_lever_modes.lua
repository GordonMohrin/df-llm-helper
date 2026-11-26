-- Neuausrichtung 15b (BUG-907): the player's lever up of an inner bridge is allowed in ALERT and SIEGE while reflex.json gate.player_lever is true (shipped: true; the code's
-- default without the key is the list of main: PEACE only). contract.lua C.VERB_CFG_MODES; kern.lua and util/k_mock.lua apply it; gate's verb refuses the rest.
-- The old tests (test_k_mock 'inbox routing', test_kern_io 'inbox rejections', test_neu1_acts 'the open exit') keep their assertions for the list of main; these are the
-- new expectations with the switch on, and the switch off.
local T = require('testlib')
local H = require('kern_world')
local kmock = require('dfllm.util.k_mock')
local C = require('dfllm.util.contract')
local kern = require('dfllm.kern')

T.test('contract: lever modes stay PEACE; C.VERB_CFG_MODES lists ALERT and SIEGE under gate.player_lever', function()
  T.eq(C.VERBS.lever.modes, {PEACE = true})
  T.eq(C.VERB_CFG_MODES.lever, {key = 'player_lever', modes = {ALERT = true, SIEGE = true}})
end)

T.test('k_mock: lever is allowed in ALERT and SIEGE with gate.player_lever (KMOCK_NEU15B / cfg), refused in them without, refused in DRILL either way', function()
  local function gate()
    local g = {name = 'gate', every = {ticks = 25}, verbs = {}}
    g.verbs.lever = function(K, args) return true, 'queued ' .. args.bridge, {job = 1} end
    return g
  end
  local W = kmock.new{}
  W.load(gate())
  W.set_mode('SIEGE')
  T.eq(W.inbox('lever', {bridge = 'O1', want = 'up'}).ok, false, 'switch off: the list of main')
  T.eq(W.inbox('lever', {bridge = 'O1', want = 'up'}).msg, 'lever not allowed in SIEGE')
  KMOCK_NEU15B = true
  local W2 = kmock.new{}
  KMOCK_NEU15B = nil
  W2.load(gate())
  for _, m in ipairs({'SIEGE', 'ALERT'}) do
    W2.set_mode(m)
    T.eq(W2.inbox('lever', {bridge = 'O1', want = 'up'}).ok, true, m .. ': allowed with the switch')
  end
  W2.set_mode('DRILL')
  T.eq(W2.inbox('lever', {bridge = 'O1', want = 'up'}).msg, 'lever not allowed in DRILL')
  W2.set_mode('SIEGE')
  T.eq(W2.inbox('drill', {}).ok, false)
end)

T.test('kern: lever in SIEGE with gate.player_lever goes to the verb of gate, without it is refused; trade.retry (PEACE only) is refused in SIEGE either way', function()
  local W = H.world{tag = 'rej15b'}
  local g = {name = 'gate', every = {ticks = 25}, verbs = {}}
  g.verbs.lever = function(K, args) return true, 'ok' end
  H.boot(W, {modules = {g}, strict = false})
  local K = kern.K()
  K.set_mode('SIEGE', 'test')
  H.inbox(W, 'm1', 'lever', {bridge = 'O1', want = 'up'})
  H.inbox(W, 'm2', 'trade.retry', {})
  H.run(W, 40)
  T.eq(H.outbox(W, 'm1').msg, 'lever not allowed in SIEGE')
  T.eq(H.outbox(W, 'm2').msg, 'trade.retry not allowed in SIEGE')
  K.cfg.reflex = {v = 2, gate = {player_lever = true}}
  H.inbox(W, 'm3', 'lever', {bridge = 'O1', want = 'up'})
  H.inbox(W, 'm4', 'trade.retry', {})
  H.run(W, 40)
  T.eq(H.outbox(W, 'm3').msg, 'ok')
  T.eq(H.outbox(W, 'm4').msg, 'trade.retry not allowed in SIEGE')
  kern.stop()
end)

T.test('kern: the open exit lifts the mode list of the VERB_EMG verbs only (lever in DRILL), a closed or missing one does not; with gate.player_lever the lever in SIEGE needs no exit', function()
  local W = H.world{tag = 'kernemg15b', ms_per_frame = 100}
  local gate = {name = 'gate', every = {ticks = 25}, verbs = {}}
  gate.verbs.lever = function(K, args) return true, 'queued ' .. args.bridge end
  local pl = {name = 'player', every = {ticks = 1200}, is = false}
  function pl.open() return pl.is end
  local ok, msg = H.boot(W, {modules = {gate, pl}})
  T.ok(ok, msg)
  local K = require('dfllm.kern').K()
  K.set_mode('DRILL', 'test')
  H.inbox(W, 'l1', 'lever', {bridge = 'O1', want = 'up'})
  H.run(W, 100, {skip = 10})
  T.eq(H.outbox(W, 'l1').msg, 'lever not allowed in DRILL')
  pl.is = true
  H.inbox(W, 'l2', 'lever', {bridge = 'O1', want = 'up'})
  H.inbox(W, 'd1', 'drill', {})
  H.run(W, 100, {skip = 10})
  T.eq(H.outbox(W, 'l2').msg, 'queued O1')
  T.eq(H.outbox(W, 'd1').msg, 'drill not allowed in DRILL', 'a verb outside VERB_EMG keeps its modes')
  pl.is = false
  K.set_mode('SIEGE', 'test')
  K.cfg.reflex = {v = 2, gate = {player_lever = true}}
  H.inbox(W, 'l3', 'lever', {bridge = 'O1', want = 'up'})
  H.inbox(W, 'd2', 'drill', {})
  H.run(W, 100, {skip = 10})
  T.eq(H.outbox(W, 'l3').msg, 'queued O1')
  T.eq(H.outbox(W, 'd2').msg, 'drill not allowed in SIEGE')
  require('dfllm.kern').stop()
end)

T.done()
