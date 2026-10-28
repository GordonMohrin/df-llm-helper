-- M2 / BUG-107 (Run 14 note 78: 37 dead in hours): the refuge choice counts the supplies. Kern+ with a well, food 1 and no
-- drink passed the drink-only WET level and, first in the chain, beat Innen+ with food and drink in plenty that failed
-- the area (56 tiles < 63). Now: a burrow with its food and drink beats one without (level FED), the best supplied one
-- is taken when none is fed (REFUGE_FAIL has the counts), a siege leaves a depleted burrow for a fed one.
-- k_mock (strict) + tests/lua/seal_world.lua.
local T = require('testlib')
local SW = require('seal_world')

local function evs(W, t) return W.find_events(t) end
local function inspect(W, what, key)
  local r = W.inbox('inspect', {what = what, key = key})
  T.ok(r.ok, r.msg)
  return r.data, r.msg
end

-- the hall x5-15 y5-15 on z9 behind a door at 19,10 (the corridor to the up stair 20,10): separated. Kern+ = x5-15 y5-12
-- (88 tiles), Innen+ = x5-9 y13-15 (15 tiles: under the 30 a fort of 30 needs, over the 9 of breach_tiles).
-- opts: kfood, kdrink (items in Kern+), well (a well in Kern+), ifood, idrink (items in Innen+), innen (false: no Innen+),
-- citizens (default 30), cfg (reflex.refuge)
local Z = 9
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
  SW.regroup(W)
  local cits = {}
  for i = 1, opts.citizens or 30 do cits[i] = {i, 8 + i % 6, 9 + i // 6 % 3, Z} end
  SW.citizens(W, cits)
  W.burrow('Kern+', {5, 5, Z, 15, 12, Z})
  if opts.innen ~= false then W.burrow('Innen+', {5, 13, Z, 9, 15, Z}) end
  if opts.tiefe then W.burrow('Tiefe+', {10, 13, Z, 15, 15, Z}) end         -- the refuge: 18 tiles, no stock
  if opts.kdrink then SW.item(W, 'DRINK', 10, 6, Z, opts.kdrink) end
  if opts.kfood then SW.item(W, 'PLANT', 10, 7, Z, opts.kfood) end
  if opts.idrink then SW.item(W, 'DRINK', 6, 14, Z, opts.idrink) end
  if opts.ifood then SW.item(W, 'PLANT', 7, 14, Z, opts.ifood) end
  if opts.well then SW.building(W, 'WELL', 'Well', 12, 8, Z, {}) end
  W.act_result('burrow_tiles', function() return true, 0 end)     -- seal paints no Innen+ over the fixture's small one
  W.K.cfg.reflex = {v = 2, refuge = opts.cfg or {bed_pct = 0}}
  package.loaded['dfllm.seal'] = nil
  local M = require('dfllm.seal')
  W.load(M)
  W.run(opts.settle or 2400, {skip = 9})
  return W, M
end

T.test('BUG-107 (note 78): Kern+ with a well, food 1 and no drink loses to Innen+ with food and drink that is too small: level FED, REFUGE_FAIL with the counts', function()
  local W = fort{kfood = 1, well = true, ifood = 40, idrink = 40}
  local d = inspect(W, 'refuge')
  local k, i = d.burrows['Kern+'], d.burrows['Innen+']
  T.eq({k.exists, k.fed, k.counts, i.fed, i.counts}, {1, 0, 0, 1, 0}, 'Kern+ has no food, Innen+ fails the area')
  T.eq({k.fneed, k.dneed, i.tiles < 30, i.tiles >= 9}, {30, 30, true, true})
  T.eq(d.choice.SIEGE, {want = 'Kern+', burrow = 'Innen+', level = 'FED'})
  T.eq(d.choice.ALERT, {want = 'Kern+', burrow = 'Innen+', level = 'FED'})
  local ok, pick, note, short = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  T.eq({ok, pick}, {true, 'Innen+'})
  T.ok(short:find('Innen+', 1, true), short)
  local f = evs(W, 'REFUGE_FAIL')
  T.eq(#f, 1)
  T.eq({f[1].d.burrow, f[1].d.fallback, f[1].d.level}, {'Kern+', 'Innen+', 'FED'})
  T.ok(f[1].d.sup:find('Innen+ food 40/30, drink 40/30', 1, true), f[1].d.sup)
  T.ok(f[1].d.sup:find('Kern+ food 1/30', 1, true), f[1].d.sup)
  T.ok(f[1].msg:find('Kern+: food 1<30', 1, true), f[1].msg)
  T.ok(f[1].msg:find('has the food and drink', 1, true), f[1].msg)
end)

T.test('BUG-107: when no burrow is fed the best supplied one is taken and REFUGE_FAIL says so with the counts', function()
  local W = fort{kfood = 1, well = true, ifood = 5, idrink = 40}
  local d = inspect(W, 'refuge')
  T.eq(d.choice.SIEGE, {want = 'Kern+', burrow = 'Innen+', level = 'WET'}, 'food 5/30 beats food 1/30')
  W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  local f = evs(W, 'REFUGE_FAIL')
  T.eq(#f, 1)
  T.ok(f[1].d.sup:find('Innen+ food 5/30', 1, true) and f[1].d.sup:find('Kern+ food 1/30', 1, true), f[1].d.sup)
  T.ok(f[1].msg:find('no burrow has its food and drink', 1, true), f[1].msg)
end)

T.test('BUG-107: the only candidate short of food is still chosen and still reported although it is the wanted one', function()
  local W = fort{kfood = 1, well = true, innen = false}
  local ok, pick = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  T.eq({ok, pick}, {true, 'Kern+'})
  local f = evs(W, 'REFUGE_FAIL')
  T.eq(#f, 1, 'a depleted pick that is the wanted burrow says so')
  T.eq({f[1].d.burrow, f[1].d.fallback}, {'Kern+', 'Kern+'})
  T.ok(f[1].msg:find('best supplied', 1, true), f[1].msg)
  local al = W.state().alert
  T.eq({al.burrow, al.ok}, {'Kern+', 0}, 'the state does not call a depleted pick ok')
  T.ok(al.why:find('food 1<30', 1, true), al.why)
  W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  T.eq(#evs(W, 'REFUGE_FAIL'), 1, 'cadence: not again at once')
end)

T.test('BUG-107: a fed Kern+ is still chosen first, silently (no REFUGE_FAIL), also with a fed Innen+', function()
  local W = fort{kfood = 40, kdrink = 40, ifood = 40, idrink = 40}
  local d = inspect(W, 'refuge')
  T.eq({d.burrows['Kern+'].fed, d.burrows['Kern+'].fneed, d.burrows['Kern+'].dneed}, {1, 30, 30}, 'the cover is in inspect')
  T.eq(d.choice.SIEGE, {want = 'Kern+', burrow = 'Kern+', level = 'SIEGE'})
  W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+')
  T.eq(#evs(W, 'REFUGE_FAIL'), 0)
  -- a fed Kern+ short of food in a fort whose Innen+ is not fed: Kern+ short stays the pick, Innen+ with drink only is worse
  local W2 = fort{kfood = 10, well = true, idrink = 40}
  T.eq(inspect(W2, 'refuge').choice.SIEGE, {want = 'Kern+', burrow = 'Kern+', level = 'WET'}, 'food 10/30 beats food 0/30')
end)

T.test('BUG-107: a siege holding the alert on a depleted Kern+ leaves it for the fed Innen+ (REFUGE_SWITCH supply); supply_switch 0 keeps it', function()
  local W = fort{kfood = 1, well = true, ifood = 40, idrink = 40}
  W.set_mode('SIEGE')
  local ok, pick = W.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+', false, 'Kern+')
  T.eq({ok, pick}, {true, 'Innen+'})
  local sw = evs(W, 'REFUGE_SWITCH')
  T.eq(#sw, 1)
  T.eq({sw[1].d.from, sw[1].d.to, sw[1].d.why}, {'Kern+', 'Innen+', 'supply'})
  local W2 = fort{kfood = 1, well = true, ifood = 40, idrink = 40, cfg = {bed_pct = 0, supply_switch = 0}}
  W2.set_mode('SIEGE')
  local _, pick2 = W2.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+', false, 'Kern+')
  T.eq(pick2, 'Kern+', 'the old rule: no switch without a reason')
  T.eq(#evs(W2, 'REFUGE_SWITCH'), 0)
  -- over half of the need (20 of 30 food): the siege stays where it is, a small shortfall is no reason to walk
  local W4 = fort{kfood = 20, well = true, ifood = 40, idrink = 40}
  W4.set_mode('SIEGE')
  local _, pick4 = W4.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+', false, 'Kern+')
  T.eq(pick4, 'Kern+', 'Kern+ holds 66% of its food: kept')
  T.eq(#evs(W4, 'REFUGE_SWITCH'), 0)
  local W5 = fort{kfood = 20, well = true, ifood = 40, idrink = 40, cfg = {bed_pct = 0, supply_switch = 80}}
  W5.set_mode('SIEGE')
  T.eq(select(2, W5.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+', false, 'Kern+')), 'Innen+', 'supply_switch 80: 66% is under it')
  -- the refuge is never left for its supplies: the deep defense has its own window (a hostile-free fed Kern+ is the pick)
  local W3 = fort{kfood = 40, kdrink = 40, tiefe = true}
  W3.set_mode('SIEGE')
  local _, pick3 = W3.K.call('seal', 'alert_burrow', 'SIEGE', 'Kern+', false, 'Tiefe+')
  T.eq(#evs(W3, 'REFUGE_SWITCH'), 0, 'no supply switch out of the refuge')
  T.eq(pick3, 'Tiefe+')
end)

---------------------------------------------------------------- the standing floor
T.test('BUG-107: Kern+ under its food/drink floor in PEACE: REFUGE_STOCK (A) with the stockroom command, once; stocked up and low again: a new episode', function()
  local W = fort{kfood = 1, innen = false}
  local e = evs(W, 'REFUGE_STOCK')
  T.eq(#e, 1)
  T.eq({e[1].cls, e[1].d.burrow, e[1].d.short, e[1].d.food, e[1].d.fneed, e[1].d.drink, e[1].d.dneed, e[1].d.pct, e[1].d.cit},
       {'A', 'Kern+', 'food+drink', 1, 30, 0, 30, 100, 30})
  T.ok(e[1].d.cmd:find('bp.place', 1, true) and e[1].d.cmd:find('"tpl":"stockroom"', 1, true) and
       not e[1].d.cmd:find('"burrow"', 1, true), e[1].d.cmd)       -- the stockroom template has no burrow param
  T.ok(e[1].msg:find('Kern+ holds food 1/30, drink 0/30, under 100%', 1, true), e[1].msg)
  W.run(9 * 1200 * 3, {skip = 9})                                     -- three game days more: no repeat of an unchanged condition
  T.eq(#evs(W, 'REFUGE_STOCK'), 1)
  SW.item(W, 'DRINK', 10, 6, Z, 40)
  SW.item(W, 'PLANT', 10, 7, Z, 40)
  inspect(W, 'refuge', 'refresh')
  T.eq(#evs(W, 'REFUGE_STOCK'), 1, 'fed: nothing to say')
end)

T.test('BUG-107: no floor event for a young fort, with floor_pct 0, in a fight; a wet well covers the drink; the refuge asks for refuge_drink', function()
  local W = fort{kfood = 40, kdrink = 0, well = true}
  T.eq(#evs(W, 'REFUGE_STOCK'), 0, 'food in plenty, a well for the drink')
  local W2 = fort{kfood = 1, citizens = 12}
  T.eq(#evs(W2, 'REFUGE_STOCK'), 0, 'a fort of 12 (under the default floor_pop 30) has no floor')
  W2 = fort{kfood = 1, citizens = 12, cfg = {bed_pct = 0, floor_pop = 12}}
  T.eq(#evs(W2, 'REFUGE_STOCK'), 1, 'control: floor_pop 12 and the same fort is short')
  local W3 = fort{kfood = 1, citizens = 12, cfg = {bed_pct = 0, floor_pop = 13}}
  T.eq(#evs(W3, 'REFUGE_STOCK'), 0, 'refuge.floor_pop 13: a fort of 12 has none')
  local W4 = fort{kfood = 1, cfg = {bed_pct = 0, floor_pct = 0}}
  T.eq(#evs(W4, 'REFUGE_STOCK'), 0, 'refuge.floor_pct 0: off')
  local W5 = fort{kfood = 1, mode = nil}
  W5.set_mode('SIEGE')
  W5.clear()
  inspect(W5, 'refuge', 'refresh')
  T.eq(#evs(W5, 'REFUGE_STOCK'), 0, 'not in a siege: REFUGE_FAIL has the counts there')
  local W6 = fort{kfood = 40, kdrink = 40, tiefe = true}                  -- Tiefe+ holds nothing
  local e = evs(W6, 'REFUGE_STOCK')
  T.eq(#e, 1)
  T.eq({e[1].d.burrow, e[1].d.short}, {'Tiefe+', 'food+drink'})
  T.eq(e[1].d.cmd, 'the refuge level has no food store template: stock it from the next plan (refuge_drink holds drink only)')
  local W7 = fort{kfood = 40, kdrink = 40, ifood = 40, idrink = 40, tiefe = true}
  T.eq(#evs(W7, 'REFUGE_STOCK'), 1)
end)

T.done()
