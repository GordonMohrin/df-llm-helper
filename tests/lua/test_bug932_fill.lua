-- NEU20a (holz-fass) BUG-932: Run 17 i3 region1-site97 y499-y505: ~750 barrels, almost all full, 4-6 empty; the player's own `MakeBarrel x20` lifted the drink from 14 to 241 days, the kernel
-- ordered ONE x10 batch and nothing after it. The standing fill: once the cure ran (p.rsv.t0) a wood barrel order is sized to the shortfall of free empties against creserve.fill_free (20),
-- independent of DF's cancel count, bounded (batch, season, barrels per citizen, total_cap a year), with one honest line a week when it cannot order or the order stands unworked.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200

local function world(o)
  o = o or {}
  local units, ids = {}, {}
  for i = 1, 8 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}}; ids[i] = i end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
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
    econ.on.REPORT(K, {type = 'CANCEL_JOB', tick = tick, text = 'Urist McBrew cancels Brew drink from plant: Needs empty food storage item.'})
  end
end
local function say(W, s) local n = 0; for _, l in ipairs(W.logs) do if tostring(l.msg):find(s, 1, true) then n = n + 1 end end; return n end

-- one plan run: o.inv census, o.live orders open by tag, o.xbarrel barrels others have on order, o.cit citizens
local function run(W, o)
  local econ = require('dfllm.economy')
  local c = econ.conf(W.K)
  local p = W.K.persist.get('m.economy')
  p.orders = p.orders or {}
  local r = {now = o.now, day = true, p = p, inv = o.inv, f = o.f or {['workshop:Carpenters'] = true, ['workshop:Craftsdwarfs'] = true, ['workshop:Still'] = true},
             s = {brew = {left = o.brews or 30}, live = o.live or {}, used = o.used or {}, xbarrel = o.xbarrel}, held = {}, cands = {}, planned = {}, days = {drink_d = 0}, cit = o.cit or 31}
  local acted = econ.plan_reserve(W.K, c, r)
  return acted, r, p, econ
end
-- i3 at y505: 750 barrels (31 citizens), 4 free empties, 88 usable logs, 30 brews open
local I3 = {wood = 88, boulders = 0, rock = 0, barrels = 750, barrels_empty = 6, cont_free = 4}
local RS = function(t0) return {t0 = t0, at = t0, mat = 'wood', n = 10, made = 10, open = nil, done = t0 + 3 * DAYT, wt = t0, wn = 10} end

T.test('BUG-932 i3: the cure ran, DF cancels 0, 4 free empties of 20 wanted: a standing wood order of 16 (the shortfall), no DF cancel needed', function()
  local W = world()
  local t0 = 200 * DAYT
  local p = W.K.persist.get('m.economy')
  p.rsv = RS(t0)
  local acted, r = run(W, {now = t0 + 30 * DAYT, inv = I3})
  T.ok(acted, 'the reserve owns the barrel planning')
  T.eq(#r.cands, 1)
  local cd = r.cands[1]
  T.eq(cd.tag, 'dfllm:barrelx')
  T.eq(cd.spec.job, 'MakeBarrel')
  T.eq(cd.n, 16, '20 - 4')
  T.eq(cd.spec.item_conditions, nil, 'no item condition (the live order 2877 with one stood 420 d unworked)')
  T.eq(cd.spec.material, nil, 'wood, not rock')
  T.ok(cd.spec.material_category and cd.spec.material_category[1] == 'wood', T.show(cd.spec))
  T.eq(cd.uses.wood, 1)
  T.ok(cd.why:find('standing fill', 1, true), cd.why)
  T.eq(p.rsv.fsn, 16)
  T.eq(p.rsv.rep or 0, 0, 'no DF-cancel repeat is counted for a fill batch')
  local _, r2 = run(W, {now = t0 + 30 * DAYT + DAYT, inv = I3})
  T.eq(#r2.cands, 0, 'the gap of 3 days: not again at once')
end)

T.test('BUG-932: the player\'s own MakeBarrel x20 is counted as ordered: the fill orders only what is still missing; a full target orders nothing', function()
  local W = world()
  local t0 = 200 * DAYT
  W.K.persist.get('m.economy').rsv = RS(t0)
  local _, r = run(W, {now = t0 + 30 * DAYT, inv = I3, xbarrel = 20})
  T.eq(#r.cands, 0, '4 free + 20 on order >= 20')
  local _, r2 = run(W, {now = t0 + 30 * DAYT, inv = I3, xbarrel = 10})
  T.eq(#r2.cands, 1)
  T.eq(r2.cands[1].n, 6, '20 - 4 - 10')
  local inv = {wood = 88, barrels = 750, cont_free = 25}
  local _, r3 = run(W, {now = t0 + 40 * DAYT, inv = inv})
  T.eq(#r3.cands, 0, 'free empties at the target')
end)

T.test('BUG-932: bounded: batch 20, season 60 in 84 days, barrels per citizen, logs; each stop is one line a game week', function()
  local W = world()
  local t0 = 200 * DAYT
  local p = W.K.persist.get('m.economy')
  p.rsv = RS(t0)
  local inv = {wood = 88, barrels = 100, cont_free = 0}
  local _, r = run(W, {now = t0 + 30 * DAYT, inv = inv, cit = 8})
  T.eq(r.cands[1].n, 20, 'batch cap 20 of a shortfall of 20')
  local W1 = world()
  W1.K.cfg.baseline.economy = {creserve = {fill_batch = 7, fill_season = 10}}
  W1.K.persist.get('m.economy').rsv = RS(t0)
  W, p = W1, W1.K.persist.get('m.economy')
  local _, r1 = run(W, {now = t0 + 40 * DAYT, inv = inv, cit = 8})
  T.eq(r1.cands[1].n, 7, 'fill_batch')
  local _, r2 = run(W, {now = t0 + 50 * DAYT, inv = inv, cit = 8})
  T.eq(r2.cands[1].n, 3, 'the season cap leaves 3 of 10 (7 + ... ordered; fsn ' .. tostring(p.rsv.fsn) .. ')')
  local _, r3 = run(W, {now = t0 + 60 * DAYT, inv = inv, cit = 8})
  T.eq(#r3.cands, 0, 'season cap reached')
  T.eq(say(W, 'barrels ordered in this season'), 1)
  run(W, {now = t0 + 62 * DAYT, inv = inv, cit = 8})
  T.eq(say(W, 'barrels ordered in this season'), 1, 'once a week')
  run(W, {now = t0 + 70 * DAYT, inv = inv, cit = 8})
  T.eq(say(W, 'barrels ordered in this season'), 2, 'the next week again')
  -- the pop cap
  local W2 = world()
  W2.K.persist.get('m.economy').rsv = RS(t0)
  local _, rp = run(W2, {now = t0 + 30 * DAYT, inv = {wood = 88, barrels = 240, cont_free = 0}, cit = 8})
  T.eq(#rp.cands, 0, '240 barrels for 8 citizens = 30 a citizen')
  T.eq(say(W2, 'barrels already stand for 8 citizens'), 1)
  -- no log
  local W3 = world()
  W3.K.persist.get('m.economy').rsv = RS(t0)
  local _, rw = run(W3, {now = t0 + 30 * DAYT, inv = {wood = 0, wood_dist = 12, boulders = 90, rock = 90, barrels = 100, cont_free = 0}, cit = 8})
  T.eq(#rw.cands, 1, 'no usable log: no fill order; the old trickle (one, of rock: boulders 90) stays the fallback')
  T.eq({rw.cands[1].n, rw.cands[1].spec.material}, {1, 'INORGANIC'})
  T.eq(say(W3, 'no usable log'), 1)
end)

T.test('BUG-932: the old paths stay: fill = false gives the 20-day trickle of one; a fort whose cure never ran and DF never cancelled is left alone', function()
  local W = world()
  W.K.cfg.baseline.economy = {creserve = {fill = false}}
  local t0 = 200 * DAYT
  W.K.persist.get('m.economy').rsv = RS(t0)
  local _, r = run(W, {now = t0 + 30 * DAYT, inv = I3})
  T.eq(#r.cands, 1)
  T.eq(r.cands[1].n, 1, 'the old trickle')
  local W2 = world()
  local acted, r2 = run(W2, {now = t0, inv = I3})
  T.ok(not acted and #r2.cands == 0, 'never cancelled, never cured: nothing')
end)

T.test('BUG-932: an open order nobody works is explained once a week although the container gate is OFF (cancels 0), by the real blocker', function()
  local W = world()
  local econ = require('dfllm.economy')
  local c = W.K.cfg.baseline.economy
  local bo = F.order(W, {job_type = df.job_type.MakeBarrel, amount_left = 16, amount_total = 16, mat_type = -1, mat_index = -1, workshop_id = -1, item_conditions = kmock.vec{},
                         material_category = {wood = true}})
  local t0 = 200 * DAYT
  local p = W.K.persist.get('m.economy')
  p.orders = {['dfllm:barrelx'] = bo.id}
  p.rsv = {at = t0 - 6 * DAYT, mat = 'wood', n = 16, made = 16, open = true, wt = t0 - 6 * DAYT, wn = 16, t0 = t0 - 20 * DAYT}
  W.K.census.i = {cont_free = 3, wood = 40}
  local function runo(now)
    local r = {now = now, day = true, p = p, inv = W.K.census.i, f = {['workshop:Carpenters'] = true, ['workshop:Still'] = true},
               s = {brew = {left = 30}, live = {['dfllm:barrelx'] = bo.id}, used = {}}, held = {}, cands = {}, planned = {}, days = {drink_d = 0}, cit = 6}
    return econ.plan_reserve(W.K, c, r)
  end
  T.ok(runo(t0), 'the order stands: the reserve waits')
  T.eq(say(W, 'container reserve: barrel order'), 1, 'open 6 d, 0 of 16 made, free 3 < 20: one blocker line')
  runo(t0 + 3 * DAYT)
  T.eq(say(W, 'container reserve: barrel order'), 1, 'once a week')
  runo(t0 + 8 * DAYT)
  T.eq(say(W, 'container reserve: barrel order'), 2, 'the next week again')
  W.K.census.i.cont_free = 30
  runo(t0 + 16 * DAYT)
  T.eq(say(W, 'container reserve: barrel order'), 2, 'free empties above the target: silent')
end)
T.test('BUG-932: scan_orders counts the barrels other owners still owe (a MakeBarrel x20 by hand, not the kernel own tag)', function()
  local W = world()
  local econ = require('dfllm.economy')
  if df.job_type.MakeBarrel == nil then
    local n = 0
    for _, v in pairs(df.job_type) do if type(v) == 'number' and v > n then n = v end end
    df.job_type.MakeBarrel = n + 1; df.job_type[n + 1] = 'MakeBarrel'
  end
  F.order(W, {job_type = df.job_type.MakeBarrel, amount_left = 20, amount_total = 20, mat_type = -1, mat_index = -1, workshop_id = -1, item_conditions = kmock.vec{}, material_category = {wood = true}})
  local own = F.order(W, {job_type = df.job_type.MakeBarrel, amount_left = 7, amount_total = 7, mat_type = -1, mat_index = -1, workshop_id = -1, item_conditions = kmock.vec{}, material_category = {wood = true}})
  local p = W.K.persist.get('m.economy')
  p.orders, p.meta = {['dfllm:barrelx'] = own.id}, {}
  local s = econ.scan_orders(p)
  T.eq(s.xbarrel, 20, 'the kernel own order is not counted twice')
  T.eq(s.live['dfllm:barrelx'], 7)
end)

T.test('BUG-932 i3 (order 2877): a conditioned wood batch open 28 d with 0 made is taken back once, the next wood order has no item condition; a condition-free one is never taken back', function()
  local W = world()
  local econ = require('dfllm.economy')
  W.removed = {}
  W.act_result('order_remove', function(id) W.removed[#W.removed + 1] = id; return true, 'removed' end)
  local c = econ.conf(W.K)
  local bo = F.order(W, {job_type = df.job_type.MakeBarrel, amount_left = 10, amount_total = 10, mat_type = -1, mat_index = -1, workshop_id = -1, item_conditions = kmock.vec{{item_type = 0}},
                         material_category = {wood = true}})
  local t0 = 200 * DAYT
  local p = W.K.persist.get('m.economy')
  p.orders = {['dfllm:barrelx'] = bo.id}
  p.rsv = {at = t0, mat = 'wood', n = 10, made = 10, open = true, wt = t0, wn = 10, t0 = t0 - 20 * DAYT}
  local inv = {cont_free = 3, wood = 1044, barrels = 700}
  local function runo(now)
    local r = {now = now, day = true, p = p, inv = inv, f = {['workshop:Carpenters'] = true, ['workshop:Still'] = true},
               s = {brew = {left = 30}, live = {['dfllm:barrelx'] = 10}, used = {}}, held = {}, cands = {}, planned = {}, days = {drink_d = 0}, cit = 31}
    return econ.plan_reserve(W.K, c, r), r
  end
  local _, r1 = runo(t0 + 20 * DAYT)
  T.eq(W.removed, {}, 'open 20 d: waited')
  local _, r2 = runo(t0 + 29 * DAYT)
  T.eq(W.removed, {bo.id}, 'open 29 d, 0 of 10 made, 1044 logs: taken back')
  T.eq(#r2.cands, 1, 'and the fill orders at once')
  T.eq(r2.cands[1].spec.item_conditions, nil, 'no item condition')
  T.eq(r2.cands[1].n, 17, '20 - 3')
  T.ok(p.rsv.nocond, 'every wood order after it is condition-free')
  p.rsv.at = t0 + 29 * DAYT
  p.rsv.open = true
  local r3 = {now = t0 + 70 * DAYT, day = true, p = p, inv = inv, f = {['workshop:Carpenters'] = true, ['workshop:Still'] = true},
              s = {brew = {left = 30}, live = {['dfllm:barrelx'] = 16}, used = {}}, held = {}, cands = {}, planned = {}, days = {drink_d = 0}, cit = 31}
  p.orders = {['dfllm:barrelx'] = bo.id}
  econ.plan_reserve(W.K, c, r3)
  T.eq(W.removed, {bo.id}, 'a condition-free order is not taken back again (the blocker is another: said by the weekly line)')
  inv = {cont_free = 3, wood = 0, barrels = 700}
  p.rsv = {at = t0, mat = 'wood', n = 10, made = 10, open = true, wt = t0, wn = 10, t0 = t0 - 20 * DAYT}
  runo(t0 + 40 * DAYT)
  T.eq(W.removed, {bo.id}, 'no logs: not the item condition, nothing is taken back')
end)

T.done()
