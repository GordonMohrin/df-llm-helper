-- NEU17b BUG-918 rework (lead decisions D1-D5). Live facts (i4 Girderroots, run-17d, 26.11.): '115 of 121 empties are registered in the storage.container_item_id of a stockpile', cont_free 0,
-- dfllm-stock piles max_barrels 9 / 9 / 27 with 0-1 full barrels, one dfllm-drink pile, DF's brew cancels ON/OFF with its own cancel count; i3 Orangering: the cure was ON only while DF reported
-- >= 5 brew cancels in 7 d, the manager stopped making brew jobs (order condition 'at least N empty food storage' unmet) and the cancels fell to 0 although the shortage stayed.
--   D1 the gate (M.cx_reason / cx_gate) also holds while the brew order's own item condition is unmet by the kernel's cont_free, with a DF cancel seen since
--   D2 the release lowers every kernel food pile except dfllm-drink to its full-barrel count whether or not the pile's settings accept drink; unreadable piles are named
--   D3 PILE_BARREL_RELEASE at once and after 1 / 7 game days; nothing freed after 7 days: the event says so and the release rests
--   D4 an open reserve barrel order nobody takes: once a week the blocker from jobwhy
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200
local BREWER = 6
local function log_has(W, s)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(s, 1, true) then return l.msg end end
  return nil
end
local function api_new()
  local actlib = require('dfllm.act')
  return actlib.new{who = function() return 'economy' end, allowlist = function() return actlib.BUILTIN_ALLOWLIST end, log_cmd = function() end, fail = function() end}
end
local function pile(id, name, x1, o)
  o = o or {}
  return {id = id, name = name, x1 = x1, y1 = 0, x2 = x1 + 2, y2 = 2, z = 5, max_barrels = o.max or 40,
          storage = {container_item_id = kmock.vec(o.reg or {})},
          settings = {flags = {food = o.food ~= false}, food = {drink_plant = kmock.vec{o.drink == true}, drink_animal = kmock.vec{false}}}}
end

local function brew_world(cond_n)
  local units, ids = {}, {}
  for i = 1, 6 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}}; ids[i] = i end
  local base = F.cfg()
  base.economy.diag = {cx_cure = true, mgr_chores = true, still_pin = true, stall_line = true}
  local W = F.world{cfg = {baseline = base}, units = units}
  df.unit_labor = {BREWER = BREWER, [BREWER] = 'BREWER'}
  df.job_skill = df.job_skill or {}
  dfhack.job.getWorker = function(j) return j._worker end
  for i = 1, 6 do
    local u = W.unit(i)
    u.job, u.mood = {current_job = nil}, -1
    u.status.labors = {}
    u.military = {squad_id = -1}
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  W.unit(1).status.labors[BREWER] = true
  W.set_census('u', F.census_u(ids))
  F.item(W, 'DRINK', {stack_size = 20000})
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, plot_under = function() return true end})
  W.load(fresh('economy'))
  W.mods.economy.disabled = true                        -- only the calls below drive it
  local b = F.workshop(W, 'Still')
  b.x1, b.y1, b.x2, b.y2, b.z = 20, 20, 22, 22, 100
  b.getBuildStage = function() return 1 end
  b.getMaxBuildStage = function() return 1 end
  b.jobs = kmock.vec{}
  b.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  local conds = {}
  if cond_n then conds[1] = {compare_type = 0, compare_val = cond_n, flags1 = {empty = true}, flags3 = {food_storage = true}, item_type = -1} end
  local ord = F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = 20, amount_total = 20,
                          mat_type = -1, mat_index = -1, workshop_id = -1, item_conditions = kmock.vec(conds)})
  return W, b, ord
end
local function feed(econ, K, n, tick)
  for _ = 1, n do
    econ.on.REPORT(K, {type = 'CANCEL_JOB', tick = tick, text = 'Urist McBrew cancels Brew drink from plant: Needs empty food storage item.'})
  end
end

-- i4 numbers: 115 registered empties (stock piles 9 / 9 / 9 / 27 with 0-1 full barrels, one dfllm-drink pile, one player pile), cont_free 0
local function i4_world(drink)
  local W, still, ord = brew_world()
  local function barrels(x, empties, fulls)
    local ids = {}
    for _ = 1, empties do ids[#ids + 1] = F.item(W, 'BARREL', {pos = {x = x, y = 1, z = 5}}).id end
    for _ = 1, fulls do ids[#ids + 1] = F.item(W, 'BARREL', {pos = {x = x, y = 1, z = 5}, _contents = {{id = 1}}}).id end
    return ids
  end
  local all = {
    pile(61, 'dfllm-stock', 0, {max = 9, drink = drink, reg = barrels(0, 28, 0)}),
    pile(62, 'dfllm-stock', 10, {max = 9, drink = drink, reg = barrels(10, 28, 0)}),
    pile(63, 'dfllm-stock', 20, {max = 9, drink = drink, reg = barrels(20, 29, 0)}),
    pile(64, 'dfllm-stock', 30, {max = 27, drink = drink, reg = barrels(30, 27, 1)}),
    pile(65, 'dfllm-drink', 40, {max = 3, drink = true, reg = barrels(40, 1, 2)}),
    pile(66, 'my stocks', 50, {max = 15, drink = drink, reg = barrels(50, 1, 0)}),
  }
  df.global.world.buildings.other.STOCKPILE = kmock.vec(all)
  df.building.find = function(id) for _, sp in ipairs(all) do if sp.id == id then return sp end end end
  local api = api_new()
  W.act_result('pile_barrels', function(mode, arg) return api.pile_barrels(mode, arg) end)
  W.K.census.i = {brew_p = 6978, barrels = 121, barrels_empty = 121, cont_free = 0, barrels_reg = 115, wood = 0}
  return W, ord, all, W.K.cfg.baseline.economy
end
local function limits(P) local o = {}; for i, sp in ipairs(P) do o[i] = sp.max_barrels end; return o end
local function ev_of(W, phase)
  local o = {}
  for _, e in ipairs(W.find_events('PILE_BARREL_RELEASE')) do if e.d.phase == phase then o[#o + 1] = e end end
  return o
end
local function day(W, econ, c, n, feedn)
  for _ = 1, n do
    W.run(DAYT, {skip = 100})
    if feedn then feed(econ, W.K, feedn, W.K.now().tick) end
    econ.release_watch(W.K, c)
  end
end

for _, drink in ipairs({true, false}) do
  local label = drink and 'the stock piles ACCEPT drink' or 'the stock piles do NOT accept drink'

  T.test('BUG-918b D2/D3 (i4 numbers, ' .. label .. '): every dfllm-stock pile is lowered to its full-barrel count, dfllm-drink and the player pile are not touched; events at d0 / d1 / d7', function()
    local W, ord, P, c = i4_world(drink)
    local econ = require('dfllm.economy')
    c.cancel.stand = false
    feed(econ, W.K, 12, W.K.now().tick)
    econ.release_watch(W.K, c)
    T.eq(limits(P), {0, 0, 0, 1, 3, 15}, 'stock 9/9/9 -> 0 (no full barrel), stock 27 -> 1 full barrel; drink pile 3 and the player pile 15 untouched')
    local lo = ev_of(W, 'lowered')
    T.eq(#lo, 4)
    for _, e in ipairs(lo) do T.eq({e.d.free0, e.d.drink}, {0, drink and 1 or 0}) end
    T.eq(ev_of(W, 'none')[1], nil, 'something was lowered: no phase none')
    day(W, econ, c, 1, 12)
    T.eq(#ev_of(W, 'd1'), 4, 'one game day later')
    T.ok(ev_of(W, 'd1')[1].d.cx1 ~= nil and ev_of(W, 'd1')[1].d.free1 ~= nil and ev_of(W, 'd1')[1].d.reg1 ~= nil, 'registered / free empties and cancels after 1 d')
    day(W, econ, c, 6, 12)
    local d7 = ev_of(W, 'd7')
    T.eq(#d7, 4, 'seven game days later')
    T.ok(d7[1].d.reg7 ~= nil and d7[1].d.free7 ~= nil and d7[1].d.cx7 ~= nil)
  end)

  T.test('BUG-918b D3 (i4 numbers, ' .. label .. '): nothing is freed after 7 days (registration kept, cont_free 0): the event says so, the old limits go back, the release rests', function()
    local W, ord, P, c = i4_world(drink)
    local econ = require('dfllm.economy')
    c.cancel.stand = false
    local p = W.K.persist.get('m.economy')
    feed(econ, W.K, 12, W.K.now().tick)
    econ.release_watch(W.K, c)
    T.eq(limits(P), {0, 0, 0, 1, 3, 15})
    day(W, econ, c, 7, 12)
    local d7 = ev_of(W, 'd7')
    T.eq(#d7, 4)
    T.ok(d7[1].d.verdict:find('DF kept the registration', 1, true) and d7[1].d.verdict:find('cont_free did not rise (0 -> 0)', 1, true), d7[1].d.verdict)
    T.eq(limits(P), {9, 9, 9, 27, 3, 15}, 'the old limits are back')
    T.eq(p.relstop, true)
    local n = #W.find_events('PILE_BARREL_RELEASE')
    day(W, econ, c, 20, 12)
    T.eq(#W.find_events('PILE_BARREL_RELEASE'), n, 'no loop: nothing is lowered again')
    T.eq(limits(P), {9, 9, 9, 27, 3, 15})
  end)

  T.test('BUG-918b D2/D3 (i4 numbers, ' .. label .. '): the registration falls and cont_free rises: the verdict says so, the limits stay until the cure ends, then they go back', function()
    local W, ord, P, c = i4_world(drink)
    local econ = require('dfllm.economy')
    c.cancel.stand = false
    local p = W.K.persist.get('m.economy')
    feed(econ, W.K, 12, W.K.now().tick)
    econ.release_watch(W.K, c)
    day(W, econ, c, 1, 12)
    for i = 1, 4 do P[i].storage.container_item_id = kmock.vec{} end                  -- DF gave the registered empties back
    W.K.census.i.cont_free, W.K.census.i.barrels_reg = 110, 2
    day(W, econ, c, 6, 12)
    local d7 = ev_of(W, 'd7')
    T.eq(#d7, 4)
    T.eq(d7[1].d.verdict, 'the registration fell')
    T.eq(d7[1].d.free7, 110)
    T.eq(limits(P), {0, 0, 0, 1, 3, 15}, 'still lowered')
    -- the cure ends (containers back, no cancels for the hysteresis days): the brew_watch exit gives them back
    local pst = W.K.persist.get('m.economy')
    T.ok(pst.pilecap ~= nil, 'the old limits are remembered')
    econ.cx_end(W.K, pst, true)
    T.eq(limits(P), {9, 9, 9, 27, 3, 15}, 'restored at the cure end')
  end)
end

T.test('BUG-918b D2: a kernel pile whose limit field cannot be read is named with its reason in the act result; nothing is dropped silently', function()
  local W, ord, P, c = i4_world(true)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  P[2].max_barrels = nil                         -- no field to read on this pile
  local api = api_new()
  local ok, res = api.pile_barrels('release', {})
  T.ok(ok)
  local why
  for _, k in ipairs(res.kept or {}) do if k.id == 62 then why = k.why end end
  T.ok(why and why:find('limit field unreadable', 1, true), tostring(why))
  T.eq(#res, 3, 'the three readable stock piles are lowered')
end)

T.test('BUG-918b: no DF reason at all (no cancel, no brew order condition): nothing is lowered', function()
  local W, ord, P, c = i4_world(true)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  -- an unmet order condition alone (cont_free 0 < 5, no DF cancel was ever seen) is no reason either
  ord.item_conditions = kmock.vec{{compare_type = 0, compare_val = 5, flags1 = {empty = true}, flags3 = {food_storage = true}, item_type = -1}}
  econ.release_watch(W.K, c)
  T.eq(limits(P), {9, 9, 9, 27, 3, 15})
  T.eq(#W.find_events('PILE_BARREL_RELEASE'), 0)
  T.eq(econ.cx_gate(W.K, c, W.K.now().tick), false)
end)

-- D1: i3 loop. The order's own condition 'at least 5 empty food storage items' is unmet (cont_free < 5): DF's cancels fall to 0 (the manager makes no brew job), the gate stays on
T.test('BUG-918b D1 (i3 loop): the cancels fall to 0 because the order condition is unmet: the gate stays ON; it goes OFF after cont_free >= N for the hysteresis days', function()
  local W, still, ord = brew_world(5)
  local econ = require('dfllm.economy')
  local c = W.K.cfg.baseline.economy
  W.K.census.i = {cont_free = 0, barrels_reg = 8, brew_p = 100}
  local function gate(d) return econ.cx_gate(W.K, c, d * DAYT) end
  T.eq(gate(100), false, 'no DF cancel yet: unmet condition alone is no reason (BUG-844)')
  feed(econ, W.K, 10, 101 * DAYT)
  T.ok(gate(101), 'DF cancels 10x: ON')
  for d = 102, 160 do T.ok(gate(d), 'day ' .. d .. ': 0 cancels in the window, the order condition is unmet: still ON') end
  local x = econ.cx_reason(W.K, c, 160 * DAYT)
  T.eq(x.n, 0)
  T.ok(x.text:find('order condition unmet', 1, true), x.text)
  W.K.census.i.cont_free = 12                    -- the containers are back: N met
  for d = 161, 173 do T.ok(gate(d), 'day ' .. d .. ': hysteresis (14 d) running') end
  T.eq(gate(175), false, 'cont_free >= N for the hysteresis days: OFF')
  W.K.census.i.cont_free = 0
  T.eq(gate(176), false, 'OFF stays OFF without a fresh DF cancel')
end)

-- NEU17c verifier: the hold of reason (b) is persisted (p.cxb), not a session latch
T.test('BUG-918b D1 (reload): ON, economy re-required, 40+ days with 0 cancels and cont_free < N: the gate is still ON and cx_expire does not give the limits back', function()
  local W, ord, P, c = i4_world(false)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  ord.item_conditions = kmock.vec{{compare_type = 0, compare_val = 5, flags1 = {empty = true}, flags3 = {food_storage = true}, item_type = -1}}
  feed(econ, W.K, 12, W.K.now().tick)
  econ.release_watch(W.K, c)
  T.eq(limits(P), {0, 0, 0, 1, 3, 15})
  W.run(DAYT * 9, {skip = 100})
  T.ok(econ.cx_gate(W.K, c, W.K.now().tick), 'held on the order condition')
  local p = W.K.persist.get('m.economy')
  T.ok(type(p.cxb) == 'table', 'the hold is in the persisted state')
  local econ2 = fresh('economy')                 -- reload: the session tables (st.cxh) are gone, the persisted state stays
  local now = W.K.now().tick
  for d = 1, 45 do
    T.ok(econ2.cx_gate(W.K, c, now + d * DAYT), 'day +' .. d .. ': 0 cancels, cont_free < N: still ON')
    if d == 3 then
      econ2.cx_expire(W.K, c, p, now + d * DAYT)     -- inside the freeze's own 14-day bound: only the gate could end it
      T.eq(limits(P), {0, 0, 0, 1, 3, 15}, 'cx_expire after the reload: limits NOT given back (gate held by p.cxb)')
      T.ok(type(p.pilecap) == 'table')
    end
  end
  T.eq(econ2.df_count(W.K, econ2.BREW_KINDS, econ2.CX_REASON, c, now + 45 * DAYT), 0)
  W.K.census.i.cont_free = 40
  econ2.cx_gate(W.K, c, now + 46 * DAYT)
  T.ok(p.cxb == nil, 'cont_free >= N clears the persisted hold')
end)

T.test('BUG-918b D1: with the gate held by the order condition the release lowers, and the cure end restores the limits', function()
  local W, ord, P, c = i4_world(false)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  ord.item_conditions = kmock.vec{{compare_type = 0, compare_val = 5, flags1 = {empty = true}, flags3 = {food_storage = true}, item_type = -1}}
  feed(econ, W.K, 12, W.K.now().tick)
  econ.release_watch(W.K, c)
  T.eq(limits(P), {0, 0, 0, 1, 3, 15})
  W.run(DAYT * 9, {skip = 100})                  -- 9 days later: no cancel in the 7-day window
  T.eq(econ.df_count(W.K, econ.BREW_KINDS, econ.CX_REASON, c, W.K.now().tick), 0)
  T.ok(econ.cx_gate(W.K, c, W.K.now().tick), 'the gate holds on the order condition')
  W.K.census.i.cont_free = 40                    -- containers back
  local p = W.K.persist.get('m.economy')
  local now = W.K.now().tick
  for d = 1, 15 do econ.cx_gate(W.K, c, now + d * DAYT) end
  econ.cx_expire(W.K, c, p, now + 16 * DAYT)
  T.eq(limits(P), {9, 9, 9, 27, 3, 15}, 'cx_expire -> cx_end: restored')
end)

-- D4: the reserve's barrel order is open, nothing made: the blocker from jobwhy, once a week
T.test('BUG-918b D4: a reserve barrel order open for more than blocker_days with 0 made names the blocker once a week', function()
  local W, still, ord = brew_world()
  local econ = require('dfllm.economy')
  local c = W.K.cfg.baseline.economy
  local bo = F.order(W, {job_type = df.job_type.MakeBarrel, amount_left = 10, amount_total = 10, mat_type = -1, mat_index = -1, workshop_id = -1, item_conditions = kmock.vec{},
                         material_category = {wood = true}})
  local t0 = 200 * DAYT
  feed(econ, W.K, 12, t0)
  W.K.census.i = {cont_free = 0, wood = 40}
  local p = W.K.persist.get('m.economy')
  p.orders = {['dfllm:barrelx'] = bo.id}
  p.rsv = {at = t0 - 6 * DAYT, mat = 'wood', n = 10, made = 10, open = true, wt = t0 - 6 * DAYT, wn = 10, t0 = t0 - 6 * DAYT}
  local function run(now)
    local r = {now = now, day = true, p = p, inv = W.K.census.i, f = {['workshop:Carpenters'] = true, ['workshop:Still'] = true},
               s = {brew = {left = 30}, live = {['dfllm:barrelx'] = bo.id}, used = {}}, held = {}, cands = {}, planned = {}, days = {drink_d = 0}, cit = 6}
    return econ.plan_reserve(W.K, c, r)
  end
  local function blockers() local k = 0; for _, l in ipairs(W.logs) do if tostring(l.msg):find('container reserve: barrel order', 1, true) then k = k + 1 end end; return k end
  T.ok(run(t0))
  T.eq(blockers(), 1, 'open 6 d (> 5), 0 made: the blocker line')
  feed(econ, W.K, 12, t0 + 3 * DAYT)
  run(t0 + 3 * DAYT)
  T.eq(blockers(), 1, 'once a week')
  feed(econ, W.K, 12, t0 + 8 * DAYT)
  run(t0 + 8 * DAYT)
  T.eq(blockers(), 2, 'the next week again')
  bo.amount_left = 4                              -- some were made
  feed(econ, W.K, 12, t0 + 16 * DAYT)
  run(t0 + 16 * DAYT)
  T.eq(blockers(), 2, 'made: no blocker line')
end)

T.done()
