-- NEU17 BUG-918 (Run 17 i4 Girderroots y491: 115 of 121 empty barrels registered in stockpiles' container lists, 'Needs empty food storage item' beside 91 free empties, the container reason ON
-- since tick 198106769 and no PILE_BARREL_RELEASE event on any fort): the existing release (BUG-887 round 6 D) is kept; (1) it also runs from the kernel's guaranteed look at the REAL tick (not
-- only in the daily run whose census can lie hundreds of game days back), (2) a call that lowers no pile says so once per game week (phase none: registered / free empties, piles kept by
-- reason, failed writes, cancels), (3) the lowering / d1 / d7 events carry the free empties before / after beside the registered ones and the cancels.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 60 do W.run(1) end end
local DAYT = 1200
local BREWER = 6
local function log_has(W, s)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(s, 1, true) then return l.msg end end
  return nil
end

local function pile(id, name, x1, o)
  o = o or {}
  return {id = id, name = name, x1 = x1, y1 = 0, x2 = x1 + 2, y2 = 2, z = 5, max_barrels = o.max or 40,
          storage = {container_item_id = kmock.vec(o.reg or {})},
          settings = {flags = {food = o.food ~= false}, food = {drink_plant = kmock.vec{o.drink == true}, drink_animal = kmock.vec{false}}}}
end
local function api_new()
  local actlib = require('dfllm.act')
  return actlib.new{who = function() return 'economy' end, allowlist = function() return actlib.BUILTIN_ALLOWLIST end, log_cmd = function() end, fail = function() end}
end

local function brew_world()
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
  local b = F.workshop(W, 'Still')
  b.x1, b.y1, b.x2, b.y2, b.z = 20, 20, 22, 22, 100
  b.getBuildStage = function() return 1 end
  b.getMaxBuildStage = function() return 1 end
  b.jobs = kmock.vec{}
  b.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  local ord = F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = 20, amount_total = 20,
                          mat_type = -1, mat_index = -1, workshop_id = -1, item_conditions = kmock.vec{}})
  return W, b, ord
end
local function feed(econ, K, n, tick)
  for _ = 1, n do
    econ.on.REPORT(K, {type = 'CANCEL_JOB', tick = tick, text = 'Urist McBrew cancels Brew drink from plant: Needs empty food storage item.'})
  end
end


-- barrels lie in each pile; some are registered in the pile's storage.container_item_id
local function release_world()
  local W, still, ord = brew_world()
  local function barrel(x, full)
    return F.item(W, 'BARREL', {pos = {x = x, y = 1, z = 5}, _contents = full and {{id = 1}} or nil})
  end
  local reg1 = {barrel(1, false), barrel(1, false), barrel(1, true), barrel(1, true)}       -- pile 41 'dfllm-stock': 2 registered empties, 2 registered full
  local reg2 = {barrel(11, false)}                                                           -- pile 42 'dfllm-drink' pure drink pile: a registered empty, not changed
  local reg3 = {barrel(21, false), barrel(21, true)}                                         -- pile 43 player pile that accepts drink: not changed (a kernel pile that accepts drink IS lowered since NEU17b D2)
  local reg4 = {barrel(31, false)}                                                           -- pile 44 player pile: not a kernel pile
  local ids = function(t) local o = {}; for _, it in ipairs(t) do o[#o + 1] = it.id end; return o end
  local p41, p42, p43, p44 = pile(41, 'dfllm-stock', 0, {max = 54, reg = ids(reg1)}), pile(42, 'dfllm-drink', 10, {max = 12, drink = true, reg = ids(reg2)}),
                             pile(43, 'mixed', 20, {max = 20, drink = true, reg = ids(reg3)}), pile(44, 'plants', 30, {max = 20, reg = ids(reg4)})
  local all = {p41, p42, p43, p44}
  df.global.world.buildings.other.STOCKPILE = kmock.vec(all)
  df.building.find = function(id) for _, s in ipairs(all) do if s.id == id then return s end end end
  local api = api_new()
  W.act_result('pile_barrels', function(mode, arg) return api.pile_barrels(mode, arg) end)
  return W, ord, all, reg1, api
end


local function econ_p(W, ord)
  local p = W.K.persist.get('m.economy')
  p.orders = {['dfllm:drink'] = ord.id}
  return p
end

T.test('BUG-918: the measurement events carry the free empties before / after', function()
  local W, ord, P, reg1 = release_world()
  local econ = require('dfllm.economy')
  local p = econ_p(W, ord)
  W.K.cfg.baseline.economy.cancel.stand = false
  local inv = {brew_p = 6978, barrels = 20, barrels_empty = 4, cont_free = 3, barrels_reg = 4}
  local function watch(day, i2) econ.brew_watch(W.K, W.K.cfg.baseline.economy, {day = true, now = day * DAYT, p = p, inv = i2 or inv, days = {drink_d = 40}, cit = 6}) end
  feed(econ, W.K, 12, 101 * DAYT)
  watch(101)
  local ev = W.find_events('PILE_BARREL_RELEASE')
  T.eq({ev[1].d.phase, ev[1].d.free0}, {'lowered', 3})
  W.K.census.i = {cont_free = 9}
  P[1].storage.container_item_id = kmock.vec{reg1[2].id, reg1[3].id, reg1[4].id}
  watch(102)
  ev = W.find_events('PILE_BARREL_RELEASE')
  T.eq({ev[2].d.phase, ev[2].d.free0, ev[2].d.free1}, {'d1', 3, 9})
  T.ok(ev[2].msg:find('free empties 3 -> 9', 1, true), ev[2].msg)
end)

T.test('BUG-918: a release that lowers no pile says so once per game week, with the reasons; nothing is lowered or written', function()
  local W, ord, P = release_world()
  local econ = require('dfllm.economy')
  local p = econ_p(W, ord)
  W.K.cfg.baseline.economy.cancel.stand = false                -- the standing cap is its own cure
  P[1].max_barrels = 2                                         -- the kernel pile is low already: nothing to lower
  local inv = {brew_p = 6978, barrels = 20, barrels_empty = 4, cont_free = 5, barrels_reg = 4}
  local function watch(day) econ.brew_watch(W.K, W.K.cfg.baseline.economy, {day = true, now = day * DAYT, p = p, inv = inv, days = {drink_d = 40}, cit = 6}) end
  feed(econ, W.K, 12, 101 * DAYT)
  watch(101)
  local ev = W.find_events('PILE_BARREL_RELEASE')
  T.eq(#ev, 1)
  T.eq({ev[1].d.phase, ev[1].d.pile, ev[1].d.reg0, ev[1].d.free0}, {'none', 0, 4, 5})
  T.ok(ev[1].d.kept >= 3, 'the piles looked at')
  T.ok(ev[1].msg:find('no pile lowered', 1, true) and ev[1].msg:find('limit already low', 1, true), ev[1].msg)
  watch(103)
  T.eq(#W.find_events('PILE_BARREL_RELEASE'), 1, 'once per game week')
  watch(109)
  T.eq(#W.find_events('PILE_BARREL_RELEASE'), 2)
  T.eq(P[1].max_barrels, 2)
  T.eq(P[4].max_barrels, 20, 'a player pile is never touched')
end)

T.test('BUG-918: a lowering in progress is not reported as "none" again', function()
  local W, ord, P = release_world()
  local econ = require('dfllm.economy')
  local p = econ_p(W, ord)
  W.K.cfg.baseline.economy.cancel.stand = false
  local inv = {brew_p = 6978, barrels = 20, barrels_empty = 4, cont_free = 0, barrels_reg = 4}
  local function watch(day) econ.brew_watch(W.K, W.K.cfg.baseline.economy, {day = true, now = day * DAYT, p = p, inv = inv, days = {drink_d = 40}, cit = 6}) end
  feed(econ, W.K, 12, 101 * DAYT)
  watch(101)
  watch(102)
  for _, e in ipairs(W.find_events('PILE_BARREL_RELEASE')) do T.ok(e.d.phase ~= 'none', 'phase ' .. e.d.phase) end
end)

T.test('BUG-918: the release runs from the kernel look (M.release_watch) at the real tick, once a game day, without the daily run', function()
  local W, ord, P = release_world()
  local econ = require('dfllm.economy')
  local p = econ_p(W, ord)
  W.K.cfg.baseline.economy.cancel.stand = false
  W.K.census.i = {brew_p = 6978, barrels = 20, barrels_empty = 4, cont_free = 0, barrels_reg = 4}
  feed(econ, W.K, 12, W.K.now().tick)
  econ.release_watch(W.K, W.K.cfg.baseline.economy)
  T.eq(P[1].max_barrels, 2, 'lowered by the look')
  T.eq(#W.find_events('PILE_BARREL_RELEASE'), 1)
  P[1].max_barrels = 54
  econ.release_watch(W.K, W.K.cfg.baseline.economy)
  T.eq(P[1].max_barrels, 54, 'once per game day')
end)

-- i4 Girderroots y491: every pile that holds a registered empty is a kernel `dfllm-stock` pile that ALSO accepts drink (115 of 121 empties registered, cont_free 0, DF's reason on)
local function i4_world(o)
  local W, still, ord = brew_world()
  local ids, all = {}, {}
  for n = 1, 3 do
    local reg = {}
    for k = 1, (n == 3 and 39 or 38) do reg[#reg + 1] = F.item(W, 'BARREL', {pos = {x = n * 10, y = 1, z = 5}, _contents = nil}).id end
    all[n] = pile(50 + n, 'dfllm-stock', n * 10, {max = o and o.max or 9, drink = true, reg = reg})
  end
  df.global.world.buildings.other.STOCKPILE = kmock.vec(all)
  df.building.find = function(id) for _, sp in ipairs(all) do if sp.id == id then return sp end end end
  local api = api_new()
  local calls = {n = 0, modes = {}}
  W.act_result('pile_barrels', function(mode, arg) if mode == 'release' then calls.n = calls.n + 1 end; calls.modes[#calls.modes + 1] = mode; return api.pile_barrels(mode, arg) end)
  return W, ord, all, calls
end

-- NEU17b D2: a kernel pile that accepts drink IS lowered now (test_bug918b_fass_release.lua); what is left to say 'none' is a pile whose limit is already at its full-barrel count
T.test('BUG-918 (i4 shape, limits already low): dfllm-stock piles hold 115 registered empties: nothing is written, the event and the kern.log say why per pile, the registry scan is not repeated daily', function()
  local W, ord, P, calls = i4_world({max = 0})
  local econ = require('dfllm.economy')
  W.mods.economy.disabled = true                        -- only the calls below drive it
  local p = econ_p(W, ord)
  W.K.cfg.baseline.economy.cancel.stand = false
  W.K.census.i = {brew_p = 6978, barrels = 121, barrels_empty = 121, cont_free = 0, barrels_reg = 115}
  local c = W.K.cfg.baseline.economy
  feed(econ, W.K, 12, W.K.now().tick)
  econ.release_watch(W.K, c)
  local ev = W.find_events('PILE_BARREL_RELEASE')
  T.eq(#ev, 1)
  T.eq({ev[1].d.phase, ev[1].d.reg0, ev[1].d.free0, ev[1].d.kept, ev[1].d.pile}, {'none', 115, 0, 3, 0})
  T.ok(ev[1].msg:find('3 limit already low (115 empties)', 1, true), ev[1].msg)
  for _, sp in ipairs(P) do T.eq(sp.max_barrels, 0, 'no limit written on pile ' .. sp.id) end
  local seen = 0
  for _, l in ipairs(W.logs) do
    if tostring(l.msg):find('pile barrel release kept', 1, true) then
      for _, sp in ipairs(P) do if l.msg:find(tostring(sp.id) .. ' dfllm-stock limit 0 empties', 1, true) then seen = seen + 1 end end
    end
  end
  T.eq(seen, 3, 'every pile is named with its own reason')
  local n0 = calls.n
  for _ = 1, 5 do W.run(DAYT, {skip = 100}); feed(econ, W.K, 12, W.K.now().tick); econ.release_watch(W.K, c) end
  T.eq(calls.n, n0, 'no registry scan (act.pile_barrels release) on the five following days')
  T.eq(#W.find_events('PILE_BARREL_RELEASE'), 1)
  for _ = 1, 3 do W.run(DAYT, {skip = 100}); feed(econ, W.K, 12, W.K.now().tick); econ.release_watch(W.K, c) end
  T.eq(calls.n, n0 + 1, 'again after the idle week')
  T.eq(#W.find_events('PILE_BARREL_RELEASE'), 2)
end)

T.test('BUG-918: release_watch beside brew_watch cx_end (no brew order): no lowered / restored cycle every game day', function()
  local W, ord, P, reg1 = release_world()
  local econ = require('dfllm.economy')
  W.mods.economy.disabled = true                        -- only the calls below drive it
  local p = econ_p(W, ord)
  local c = W.K.cfg.baseline.economy
  c.cancel.stand = false
  W.K.census.i = {brew_p = 0, barrels = 20, barrels_empty = 4, cont_free = 0, barrels_reg = 4}
  local lowered = 0
  for _ = 1, 9 do
    W.run(DAYT, {skip = 100})
    local now = W.K.now().tick
    feed(econ, W.K, 12, now)
    econ.release_watch(W.K, c)
    econ.brew_watch(W.K, c, {day = true, now = now, p = p, inv = W.K.census.i, days = {drink_d = 40}, cit = 6})
  end
  for _, e in ipairs(W.find_events('PILE_BARREL_RELEASE')) do if e.d.phase == 'lowered' then lowered = lowered + 1 end end
  print('BUG-918 cycle: lowered events in 9 days: ' .. lowered)
  T.eq(lowered, 1, 'lowered once, not every game day')
  T.eq(P[1].max_barrels, 54, 'the old limit is back and stays')
  T.eq(p.relpiles, nil)
end)

T.test('BUG-918: cx_end (containers back) gives the released limits back and forgets them: no lowering for the rest week, none measured', function()
  local W, ord, P = release_world()
  local econ = require('dfllm.economy')
  W.mods.economy.disabled = true
  local p = econ_p(W, ord)
  local c = W.K.cfg.baseline.economy
  c.cancel.stand = false
  W.K.census.i = {brew_p = 6978, barrels = 20, barrels_empty = 4, cont_free = 0, barrels_reg = 4}
  feed(econ, W.K, 12, W.K.now().tick)
  econ.release_watch(W.K, c)
  T.eq(P[1].max_barrels, 2)
  T.ok(p.relpiles and p.relmeas, 'a lowering is measured')
  econ.cx_end(W.K, p)
  T.eq(P[1].max_barrels, 54, 'restored')
  T.eq({p.relpiles, p.relmeas}, {nil, nil})
  for _ = 1, 5 do W.run(DAYT, {skip = 100}); feed(econ, W.K, 12, W.K.now().tick); econ.release_watch(W.K, c) end
  T.eq(P[1].max_barrels, 54, 'not lowered again inside the week')
  for _, e in ipairs(W.find_events('PILE_BARREL_RELEASE')) do T.ok(e.d.phase ~= 'd1' and e.d.phase ~= 'd7', 'no verdict on a restored pile') end
end)

T.done()
