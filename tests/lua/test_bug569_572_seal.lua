-- BUG-569 (Run 16b i2 Brotherarrow y406: SIEGE_DEEP held 95 citizens in a Tiefe+ with drink (the refuge_drink store) but food 1 and 23 beds
-- while Kern+ held 4987 food): seal.refuge_fit says whether the refuge can be the civilians' burrow of a deep defense that is no BREACH (food,
-- drink and beds at refuge.deep_pct = 90 % of the SIEGE need), and alert_burrow takes a release REASON from siege (a text, not only the
-- eased siege's true) that leaves a held refuge for the free pick. The fort is test_bug462_464_retreat's (Kern+ hall with a door, the dead end
-- Tiefe+ behind a stair); the siege-level behaviour is test_bug569_570_starve_traffic.lua.
local T = require('testlib')
local SW = require('seal_world')

local Z = 9
local function evs(W, t) return W.find_events(t) end
local function inspect(W, what, key)
  local r = W.inbox('inspect', {what = what, key = key})
  T.ok(r.ok, r.msg)
  return r.data, r.msg
end

local function fort(opts)
  opts = opts or {}
  local W = SW.new{persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}}}}
  SW.fill(W, Z + 1, 0, 0, 40, 30, ',')
  SW.draw(W, Z + 1, {'>'}, 20, 10, {outside = true})
  SW.fill(W, Z, 0, 0, 40, 30, '#')
  SW.fill(W, Z, 5, 5, 15, 15, '.')
  SW.fill(W, Z, 16, 10, 19, 10, '.')
  SW.draw(W, Z, {'<'}, 20, 10)
  SW.draw(W, Z, {'+'}, 19, 10)
  SW.draw(W, Z, {'bb'}, 12, 12)
  SW.draw(W, Z, {'>'}, 6, 6)
  for z = Z - 3, Z - 1 do
    SW.fill(W, z, 0, 0, 40, 30, '#')
    SW.draw(W, z, {'X'}, 6, 6)
  end
  SW.fill(W, Z - 4, 0, 0, 40, 30, '#')
  SW.fill(W, Z - 4, 5, 5, 8, 8, '.')
  SW.draw(W, Z - 4, {'<'}, 6, 6)
  SW.regroup(W)
  local cits = {}
  for i = 1, 3 do cits[i] = {i, 8 + i % 6, 9 + i // 6, Z} end
  SW.citizens(W, cits)
  SW.item(W, 'DRINK', 9, 13, Z, 20)
  SW.item(W, 'PLANT', 9, 14, Z, 20)
  W.burrow('Kern+', {5, 5, Z, 15, 15, Z})
  if opts.cfg then W.K.cfg.reflex = {v = 2, refuge = opts.cfg} end
  SW.item(W, 'DRINK', 6, 7, Z - 4, 5)                          -- Tiefe+ has its drink (the refuge_drink store) ...
  if opts.food then SW.item(W, 'PLANT', 7, 7, Z - 4, opts.food) end    -- ... and the food only when the test says so
  package.loaded['dfllm.seal'] = nil
  local M = require('dfllm.seal')
  W.load(M)
  W.run(2400, {skip = 9})
  inspect(W, 'refuge', 'refresh')
  W.run(1200, {skip = 9})
  return W, M
end

T.test('BUG-569: refuge_fit names the shortfall of a refuge with drink and no food (old code: no such verdict, the WET level took it)', function()
  local W = fort()
  local ok, fit, why, d = W.K.call('seal', 'refuge_fit')
  T.ok(ok, tostring(fit))
  T.eq(fit, false, 'Tiefe+ holds drink only')
  T.ok(tostring(why):find('food 0<3', 1, true), tostring(why))
  T.eq(d.fneed, 3)
  T.eq(d.pct, 90)
end)

T.test('BUG-569: with food at 90 % of the need (and no bed count) refuge_fit is true; deep_pct 0 turns the check off, 100 wants the whole need', function()
  local W = fort{food = 3, cfg = {bed_pct = 0}}
  local ok, fit, why = W.K.call('seal', 'refuge_fit')
  T.eq({ok, fit, why}, {true, true, ''}, T.show({W.K.call('seal', 'refuge_fit')}))
  local W2 = fort{food = 2, cfg = {bed_pct = 0}}                       -- 2 of 3 = 67 % < 90 %
  local _, fit2, why2 = W2.K.call('seal', 'refuge_fit')
  T.eq(fit2, false)
  T.ok(tostring(why2):find('food 2<3', 1, true), tostring(why2))
  local W3 = fort{food = 2, cfg = {bed_pct = 0, deep_pct = 60}}
  T.eq(select(2, W3.K.call('seal', 'refuge_fit')), true, '67 % >= 60 %')
  local W4 = fort{cfg = {deep_pct = 0}}
  T.eq(select(2, W4.K.call('seal', 'refuge_fit')), true, 'deep_pct 0: no check')
  local W5 = fort{food = 3, cfg = {bed_pct = 0, deep_pct = 100}}
  T.eq(select(2, W5.K.call('seal', 'refuge_fit')), true)
end)

T.test('BUG-569: a refuge of an unfit audit: the beds count too (food and drink fine, no bed: not fit)', function()
  local W = fort{food = 3}
  local _, fit, why = W.K.call('seal', 'refuge_fit')
  T.eq(fit, false)
  T.ok(tostring(why):find('beds 0<1', 1, true), tostring(why))
end)

T.test('BUG-569 / BUG-570: alert_burrow SIEGE with the alert held in Tiefe+: KEPT without a reason (the old rule: nothing walks them ' ..
       'through the danger), LEFT for Kern+ with siege\'s release reason, which REFUGE_SWITCH carries', function()
  local W = fort()
  W.set_mode('SIEGE')
  W.set_census('h', {tick = W.K.now().tick, vis = 0, armed = 0, inside = 0, list = {}})
  local ok, pick = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+', false, 'Tiefe+')
  T.eq({ok, pick}, {true, 'Tiefe+'}, 'no reason: the held refuge is kept')
  T.eq(#evs(W, 'REFUGE_SWITCH'), 0)
  local why = 'Tiefe+ cannot hold the civilians (food 0<3)'
  local _, pick2 = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+', false, 'Tiefe+', why)
  T.eq(pick2, 'Kern+', 'old code: release is a boolean, a text is ignored and the refuge kept')
  local sw = evs(W, 'REFUGE_SWITCH')
  T.eq(#sw, 1)
  T.eq({sw[1].d.from, sw[1].d.to, sw[1].d.why}, {'Tiefe+', 'Kern+', 'released'})
  T.ok(sw[1].msg:find('food 0<3', 1, true), sw[1].msg)
  -- release = true keeps its old text
  local W2 = fort()
  W2.set_mode('SIEGE')
  W2.set_census('h', {tick = W2.K.now().tick, vis = 0, armed = 0, inside = 0, list = {}})
  local _, pick3 = W2.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+', false, 'Tiefe+', true)
  T.eq(pick3, 'Kern+')
  T.ok(evs(W2, 'REFUGE_SWITCH')[1].msg:find('the eased siege lifted the deep defense', 1, true), evs(W2, 'REFUGE_SWITCH')[1].msg)
end)

T.test('BUG-569/572: the state\'s alert.ref carries the refuge\'s food and the food wanted (fd, fn) for plan check / propose', function()
  local W = fort{food = 1}
  W.run(300, {skip = 9})
  local ref = W.state().alert and W.state().alert.ref
  T.ok(ref, 'alert.ref')
  T.eq({ref.fd, ref.fn}, {1, 3})
end)

T.done()
