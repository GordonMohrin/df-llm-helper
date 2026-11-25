-- NEU7 BUG-854: the standing container reserve. Live states: i4 Girderroots (wood 0 usable of 361, DF cancels 'Needs empty food storage item', the players' own
-- `order.add MakeBarrel mat=rock` lifted drink), i2 Whirledrampart (the first two cycles of the one-shot cure: plan_pots called a later local `stone_free`, a nil global:
-- 'economy task plan: economy.lua:1929: attempt to call a nil value (global stone_free)' aborted the plan run). Offline, against the fake world.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200
local BREWWHY = 'Needs empty food storage item'

local function world(o)
  o = o or {}
  local units, ids = {}, {}
  for i = 1, 8 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}}; ids[i] = i end
  local base = F.cfg()
  local W = F.world{cfg = {baseline = base}, units = units}
  df.unit_labor = {BREWER = 6, [6] = 'BREWER', CARPENTER = 7, [7] = 'CARPENTER', STONE_CRAFT = 8, [8] = 'STONE_CRAFT'}
  df.job_skill = df.job_skill or {}
  dfhack.units.isChild = function() return false end
  dfhack.units.isBaby = function() return false end
  for i = 1, 8 do
    local u = W.unit(i)
    u.job, u.mood = {current_job = nil}, -1
    u.status.labors = {}
    u.military = {squad_id = -1}
  end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, plot_under = function() return true end})
  W.load(fresh('economy'))
  return W
end

local function feed(econ, K, n, tick)
  for _ = 1, n do
    econ.on.REPORT(K, {type = 'CANCEL_JOB', tick = tick, text = 'Urist McBrew cancels Brew drink from plant: ' .. BREWWHY .. '.'})
  end
end

-- a plan run's r: orders open by tag in `live`, the census `inv`, workshops built `f`
local function run(W, o)
  local econ = require('dfllm.economy')
  local c = econ.conf(W.K)
  local p = W.K.persist.get('m.economy')
  p.orders = p.orders or {}
  local r = {now = o.now, day = true, p = p, inv = o.inv, f = o.f or {['workshop:Carpenters'] = true, ['workshop:Craftsdwarfs'] = true, ['workshop:Still'] = true},
             s = {brew = {left = o.brews or 30}, live = o.live or {}, used = {}}, held = {}, cands = {}, planned = {}, days = {drink_d = 0}, cit = 8}
  local acted = econ.plan_reserve(W.K, c, r)
  return acted, r, p, econ
end
local I4 = {wood = 0, wood_far = 336, boulders = 90, rock = 90, barrels = 140, barrels_empty = 34, cont_free = 5, brew_p = 3000}

T.test('BUG-854 i4: wood 0 usable, DF cancels: a ROCK batch of MakeBarrel material INORGANIC, sized by the brews (30 brews -> 10), on the standing tag', function()
  local W = world()
  local econ = require('dfllm.economy')
  local t0 = 200 * DAYT
  feed(econ, W.K, 40, t0)
  local acted, r = run(W, {now = t0 + DAYT, inv = I4, brews = 30})
  T.ok(acted, 'the reserve owns the barrel planning')
  T.eq(#r.cands, 1)
  local cd = r.cands[1]
  T.eq(cd.tag, 'dfllm:barrelx')
  T.eq(cd.spec.job, 'MakeBarrel')
  T.eq(cd.spec.material, 'INORGANIC', 'the players\' working command: mat=rock')
  T.eq(cd.spec.material_category, nil)
  T.eq(cd.n, 10, 'min batch 10 for 30 brews / 5 = 6')
  T.eq(cd.uses.rock, 1)
  local l = r.s.brew.left
  local acted2, r2 = run(W, {now = t0 + 2 * DAYT, inv = I4, brews = 200, live = {}})
  T.ok(r2.cands[1] == nil, 'a plan run two days later (the order not yet made, repeat gap 3 days) adds nothing again')
  T.ok(acted2, 'and the reserve still owns the barrel planning (no old x15 batch or pots behind it)')
  T.eq(l, 30)
end)

T.test('BUG-854: the batch grows with the brews open (200 brews -> 30, the cap), wood when it carries the batch and boulders are few', function()
  local W = world()
  local econ = require('dfllm.economy')
  local t0 = 200 * DAYT
  feed(econ, W.K, 40, t0)
  local inv = {wood = 80, boulders = 5, rock = 5, barrels = 140, barrels_empty = 3, cont_free = 1}
  local _, r = run(W, {now = t0 + DAYT, inv = inv, brews = 200})
  T.eq(#r.cands, 1)
  T.eq(r.cands[1].n, 30)
  T.eq(r.cands[1].spec.material, nil)
  T.ok(r.cands[1].spec.material_category and r.cands[1].spec.material_category[1] == 'wood', T.show(r.cands[1].spec))
  T.eq(r.cands[1].uses.wood, 1)
  local W2 = world()
  feed(require('dfllm.economy'), W2.K, 40, t0)
  local inv2 = {wood = 80, boulders = 90, rock = 90, barrels = 140, barrels_empty = 3, cont_free = 1}
  local _, r2 = run(W2, {now = t0 + DAYT, inv = inv2, brews = 30})
  T.eq(r2.cands[1].spec.material, 'INORGANIC', 'boulders plentiful (>= batch + 20): rock although wood would do')
end)

T.test('BUG-854: no cancels, no cure ever ran, no brews open: nothing; neither wood nor boulders: no order, one warn a day, the old planning goes on', function()
  local W = world()
  local acted, r = run(W, {now = 200 * DAYT, inv = I4, brews = 30})
  T.ok(not acted and #r.cands == 0, 'no DF reason, no reserve')
  local econ = require('dfllm.economy')
  feed(econ, W.K, 40, 200 * DAYT)
  local acted2, r2 = run(W, {now = 201 * DAYT, inv = I4, brews = 0})
  T.ok(not acted2 and #r2.cands == 0, 'no brew order open')
  local W3 = world()
  feed(require('dfllm.economy'), W3.K, 40, 200 * DAYT)
  local acted3, r3 = run(W3, {now = 201 * DAYT, inv = {wood = 0, boulders = 0, rock = 0, barrels = 9}, brews = 30})
  T.ok(not acted3 and #r3.cands == 0)
  local n = 0
  for _, l in ipairs(W3.logs) do if tostring(l.msg):find('nothing to make them of', 1, true) then n = n + 1 end end
  T.eq(n, 1)
  run(W3, {now = 201 * DAYT + 100, inv = {wood = 0, boulders = 0, rock = 0, barrels = 9}, brews = 30})
  n = 0
  for _, l in ipairs(W3.logs) do if tostring(l.msg):find('nothing to make them of', 1, true) then n = n + 1 end end
  T.eq(n, 1, 'once a game day')
end)

T.test('BUG-854: repeat until the cancels stop: a new batch only after a cancel NEWER than the last batch\'s end plus grace; then a trickle, not a batch', function()
  local W = world()
  local econ = require('dfllm.economy')
  local t = 200 * DAYT
  feed(econ, W.K, 40, t)
  local _, r1, p = run(W, {now = t + DAYT, inv = I4})
  T.eq(#r1.cands, 1)
  -- the batch is open: the reserve keeps the planning, adds nothing
  local acted2, r2 = run(W, {now = t + 2 * DAYT, inv = I4, live = {['dfllm:barrelx'] = {}}})
  T.ok(acted2 and #r2.cands == 0)
  -- the batch ended at day 205; cancels of day 200 still stand in the window: no new batch (they predate the batch)
  local _, r3 = run(W, {now = t + 5 * DAYT, inv = I4})
  T.ok(p.rsv.done ~= nil and #r3.cands == 0, 'cancels older than the batch do not order again: ' .. T.show(p.rsv))
  -- DF cancels again two game days after the batch ended: the second batch
  feed(econ, W.K, 6, t + 8 * DAYT)
  local _, r4 = run(W, {now = t + 8 * DAYT + 100, inv = I4})
  T.eq(#r4.cands, 1, 'DF still cancels after the batch: again')
  T.eq(p.rsv.made, 20)
  T.eq(p.rsv.rep, 1)
  -- the cancels stop (window empty 10 days later): no batch; the trickle comes after trickle_days
  run(W, {now = t + 9 * DAYT, inv = I4, live = {['dfllm:barrelx'] = {}}})
  run(W, {now = t + 10 * DAYT, inv = I4})
  local _, r5 = run(W, {now = t + 25 * DAYT, inv = I4})
  T.eq(#r5.cands, 0, 'the window is empty and the trickle is not due yet: ' .. T.show(p.rsv))
  local _, r6 = run(W, {now = t + 31 * DAYT, inv = I4})
  T.eq(#r6.cands, 1)
  T.eq(r6.cands[1].n, 1, 'a trickle of one container')
  T.eq(p.rsv.made, 21)
  T.eq(p.rsv.rep, 0, 'the repeat count started over')
  local _, r7 = run(W, {now = t + 40 * DAYT, inv = {wood = 0, boulders = 90, rock = 90, cont_free = 40}})
  T.eq(#r7.cands, 0, 'plenty free (>= trickle_free): no trickle')
end)

T.test('BUG-854: the reserve is bounded by total_cap and the repeats slow down after max_repeats batches in a row', function()
  local W = world()
  local econ = require('dfllm.economy')
  local c = econ.conf(W.K)
  c.creserve.total_cap = 25
  local t = 200 * DAYT
  local p = W.K.persist.get('m.economy')
  feed(econ, W.K, 40, t)
  local _, r1 = run(W, {now = t + DAYT, inv = I4})
  T.eq(r1.cands[1].n, 10)
  p.rsv.rep = 4
  p.rsv.done = t + 2 * DAYT
  p.rsv.at = t + 2 * DAYT
  feed(econ, W.K, 6, t + 6 * DAYT)
  local _, r2 = run(W, {now = t + 7 * DAYT, inv = I4})
  T.eq(#r2.cands, 0, 'after 4 batches in a row the gap is 14 days')
  local _, r3 = run(W, {now = t + 17 * DAYT, inv = I4})
  feed(econ, W.K, 6, t + 17 * DAYT)
  local _, r4 = run(W, {now = t + 17 * DAYT + 10, inv = I4})
  T.eq(#r4.cands, 1, '14 days later it orders again')
  T.eq(p.rsv.made, 20)
  p.rsv.made, p.rsv.wn = 25, 25                 -- NEU13 BUG-889: the cap counts the containers ordered in the current game year (rs.wn)
  p.rsv.at = 0
  local _, r5 = run(W, {now = t + 40 * DAYT, inv = I4})
  T.eq(#r5.cands, 0, 'total_cap reached')
end)

T.test('BUG-854 labor: the batch asks for the labor of its material (rock: Stone crafting; wood: Carpentry), at most once a game day', function()
  local W = world()
  local econ = require('dfllm.economy')
  local sets = {}
  W.act_result('labor_set', function(id, which, on) sets[#sets + 1] = which; W.unit(id).status.labors[which == 'stonecraft' and 8 or 7] = true; return true, 'enabled' end)
  feed(econ, W.K, 40, 200 * DAYT)
  run(W, {now = 201 * DAYT, inv = I4})
  T.ok(#sets >= 1 and sets[1] == 'stonecraft', 'rock batch: Stone crafting: ' .. T.show(sets))
  local before = #sets
  run(W, {now = 201 * DAYT + 50, inv = I4, live = {['dfllm:barrelx'] = {}}})
  T.ok(#sets <= before + 3, 'the holders are topped up daily, not per run')
end)

T.test('BUG-854 i2: plan_pots no longer calls a nil global (the plan run survives the rock-pot path)', function()
  local W = world()
  local econ = require('dfllm.economy')
  T.ok(type(econ.stone_free) == 'function')
  local c = econ.conf(W.K)
  local r = {now = 200 * DAYT, inv = {boulders = 50, rock = 50}, f = {['workshop:Craftsdwarfs'] = true}, s = {live = {}, used = {}}, held = {}, cands = {}, planned = {},
             p = W.K.persist.get('m.economy')}
  local ok, err = pcall(econ.plan_pots, W.K, c, r, 4)
  T.ok(ok, tostring(err))
  T.eq(#r.cands, 1)
  T.ok(r.cands[1].n >= 1)
end)

T.test('BUG-867: the cure gate has a hysteresis: ON at 5 cancels in the window, a count of 4 or 3 keeps it, OFF only after 14 game days under 2; the way-out line comes once a week', function()
  local W = world()
  local econ = require('dfllm.economy')
  local c = econ.conf(W.K)
  local t0 = 200 * DAYT
  feed(econ, W.K, 6, t0)
  T.ok(econ.cx_gate(W.K, c, t0 + 10), 'ON at 6 (>= 5)')
  local t1 = t0 + 7 * DAYT + 100                                   -- the 6 left the 7-day window; 4 new ones
  feed(econ, W.K, 4, t1)
  T.ok(econ.cx_gate(W.K, c, t1 + 10), 'a count of 4 (< 5) keeps the cure ON: no flap')
  feed(econ, W.K, 1, t1 + DAYT)
  local t2 = t1 + 8 * DAYT                                          -- all quiet now (0 in the window)
  T.ok(econ.cx_gate(W.K, c, t2), 'quiet for the first day: still ON')
  T.ok(econ.cx_gate(W.K, c, t2 + 10 * DAYT), '10 quiet days: still ON')
  T.ok(not econ.cx_gate(W.K, c, t2 + 15 * DAYT), '14 quiet days under 2: OFF')
  feed(econ, W.K, 5, t2 + 16 * DAYT)
  T.ok(econ.cx_gate(W.K, c, t2 + 16 * DAYT + 10), 'ON again at 5')
  -- the way out, once a week
  local W3 = world()
  feed(require('dfllm.economy'), W3.K, 40, 200 * DAYT)
  local inv = {wood = 0, boulders = 0, rock = 0, barrels = 9, picks = 4}
  run(W3, {now = 201 * DAYT, inv = inv, brews = 30})
  run(W3, {now = 203 * DAYT, inv = inv, brews = 30})
  feed(require('dfllm.economy'), W3.K, 40, 208 * DAYT)
  run(W3, {now = 209 * DAYT, inv = inv, brews = 30})
  local n, way = 0, nil
  for _, l in ipairs(W3.logs) do if tostring(l.msg):find('nothing to make them of', 1, true) then n = n + 1; way = l.msg end end
  T.eq(n, 2, 'day 201 and day 209, not day 203')
  T.ok(way:find('way out: dig for stone (4 picks', 1, true) and way:find('trade.want wood', 1, true), way)
end)

T.done()
