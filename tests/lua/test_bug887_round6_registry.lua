-- NEU13 BUG-887 round 6 / BUG-888 round 4 (13c): live on i2 (25.11. 20:30) three of three checked 'free' empty barrels were registered in the storage.container_item_id of the stockpile they
-- lie in (dfllm-mood max_barrels=1 x3); dfllm-stock (max 54) registers 47, dfllm-drink (max 12) one. DF keeps such a barrel as the pile's own container and gives it to no Still.
--   B  the census does not count a pile-registered empty barrel as usable ("N usable of M empty (R held by stockpiles as their containers)")
--   C  a mood pile is made with barrels=0 (runner.mooddrink) and existing ones are set to 0 once (act.pile_barrels zero_mood, economy.mood_piles_zero)
--   D  while DF's container reason is active the kernel's food piles that accept no drink and hold registered empties are lowered to their registered barrels with contents
--      (act.pile_barrels release); PILE_BARREL_RELEASE measures it 1 and 7 game days later; a registration that stayed stops further lowering
--   E  the standing cap no longer protects registered empties
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

---------------------------------------------------------------- B: the census
T.test('BUG-887 round 6 B: a barrel a stockpile keeps as its container is not usable; the text says how many', function()
  local units, ids = {}, {}
  for i = 1, 10 do units[i] = {id = i, citizen = true}; ids[i] = i end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  for i = 1, 10 do W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  local regd, loose = {}, {}
  for i = 1, 4 do regd[i] = F.item(W, 'BARREL', {pos = {x = 5, y = 5, z = 9}}).id end
  for i = 1, 3 do loose[i] = F.item(W, 'BARREL', {pos = {x = 8, y = 8, z = 9}}).id end
  F.item(W, 'BARREL', {pos = {x = 8, y = 9, z = 9}, flags = {in_job = true}})
  for _ = 1, 5 do F.item(W, 'BARREL', {_contents = {{id = 1}}, pos = {x = 5, y = 6, z = 9}}) end
  F.item(W, 'DRINK', {stack_size = 20000})
  df.global.world.buildings.other.STOCKPILE = kmock.vec{pile(7, 'dfllm-mood', 4, {max = 1, reg = {regd[1]}}), pile(8, 'dfllm-stock', 0, {max = 54, reg = {regd[2], regd[3], regd[4]}})}
  W.load(fresh('economy'))
  settle(W)
  local i = W.K.census.i
  T.eq({i.barrels, i.barrels_empty, i.cont_free, i.barrels_reg, i.barrels_busy}, {13, 8, 3, 4, 1}, 'the 4 registered empties are not usable')
  local econ = require('dfllm.economy')
  T.ok(econ.cont_text(i):find('3 usable of 8 empty barrels or pots', 1, true) and econ.cont_text(i):find('4 held by stockpiles as their containers', 1, true), econ.cont_text(i))
end)

---------------------------------------------------------------- C: mood piles
T.test('BUG-887 round 6 C: act zero_mood sets existing mood piles to 0 (others untouched, a pile marked done is left alone)', function()
  local a, b, c = pile(1, 'dfllm-mood', 0, {max = 1}), pile(2, 'dfllm-mood', 10, {max = 0}), pile(3, 'dfllm-stock', 20, {max = 54})
  df.global.world.buildings.other.STOCKPILE = kmock.vec{a, b, c}
  local api = api_new()
  local ok, res = api.pile_barrels('zero_mood', {done = {}})
  T.ok(ok and #res == 1 and res[1].id == 1 and res[1].old == 1 and res[1].new == 0, T.show(res))
  T.eq({a.max_barrels, b.max_barrels, c.max_barrels}, {0, 0, 54})
  T.eq(#res.seen, 2, 'both mood piles looked at')
  a.max_barrels = 1                                              -- the player raises it again: a pile marked done is left alone
  ok, res = api.pile_barrels('zero_mood', {done = {['1'] = true, ['2'] = true}})
  T.eq({#res, a.max_barrels}, {0, 1})
end)

---------------------------------------------------------------- D / E: release, measurement, standing cap
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

T.test('BUG-887 round 6 C: economy.mood_piles_zero acts only with the container reason of DF, logs once and remembers the piles', function()
  local W = brew_world()
  local a = pile(1, 'dfllm-mood', 0, {max = 1})
  df.global.world.buildings.other.STOCKPILE = kmock.vec{a}
  local api = api_new()
  W.act_result('pile_barrels', function(mode, arg) return api.pile_barrels(mode, arg) end)
  local econ = require('dfllm.economy')
  local p = {}
  econ.mood_piles_zero(W.K, p, econ.conf(W.K))
  T.eq(a.max_barrels, 1, 'no DF reason: not touched')
  feed(econ, W.K, 12, W.K.now().tick)
  econ.mood_piles_zero(W.K, p, econ.conf(W.K))
  T.eq({a.max_barrels, p.moodz['1']}, {0, true})
  T.ok(log_has(W, 'mood pile 1: the barrel limit 1 -> 0'), 'logged')
  a.max_barrels = 1
  econ.mood_piles_zero(W.K, p, econ.conf(W.K))
  T.eq(a.max_barrels, 1, 'once')
end)

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

T.test('BUG-887 round 6 D: act.pile_barrels release lowers a kernel food pile with registered empties to its registered barrels with contents, nothing else', function()
  local W, ord, P, reg1, api = release_world()
  local ok, res = api.pile_barrels('release', {})
  T.ok(ok and #res == 1, T.show(res))
  T.eq({res[1].id, res[1].old, res[1].new, res[1].reg_empty, res[1].reg_full}, {41, 54, 2, 2, 2})
  T.eq({P[1].max_barrels, P[2].max_barrels, P[3].max_barrels, P[4].max_barrels}, {2, 12, 20, 20}, 'drink piles, mixed piles and a player pile are not changed')
  local why = {}
  for _, k in ipairs(res.kept or {}) do why[k.id] = k.why end
  T.eq(why[42], 'dedicated drink pile: not changed')
  T.eq(why[43], 'not a kernel food pile')
  T.eq(why[44], 'not a kernel food pile')
  T.eq(#P[1].storage.container_item_id, 4, 'the registry is never written')
  ok, res = api.pile_barrels('release', {})
  T.eq({#res, P[1].max_barrels}, {0, 2}, 'again: already low')
  -- registered empties only: the pile goes to 0 (floor 0)
  P[1].max_barrels = 54
  for _, it in ipairs(reg1) do it._contents = nil end
  ok, res = api.pile_barrels('release', {})
  T.eq(P[1].max_barrels, 0)
end)

T.test('BUG-888 round 4 (E): the standing cap counts the barrels a pile holds without its registered empties, plus the floor', function()
  local W, ord, P, reg1, api = release_world()
  api.pile_barrels('freeze', {floor = 2})
  -- pile 41 lies 4 barrels (2 registered empties + 2 full): the cap protects 2 (and the floor is 2), not 4
  T.eq(P[1].max_barrels, 2, 'registered empties are no barrels the cap protects')
  T.eq(P[4].max_barrels, 2, 'a food pile with one registered empty only: the floor')
  P[1].max_barrels = 54
  for _, it in ipairs(reg1) do it._contents = nil end
  api.pile_barrels('freeze', {floor = 2})
  T.eq(P[1].max_barrels, 2, 'all registered empties: the floor')
end)

T.test('BUG-887 round 6 D: economy lowers the piles on DF\'s reason, measures after 1 and 7 days, the old limit is kept for the standing cap exit', function()
  local W, ord, P, reg1 = release_world()
  local econ = require('dfllm.economy')
  local p = W.K.persist.get('m.economy')
  p.orders = {['dfllm:drink'] = ord.id}
  local inv = {brew_p = 6978, barrels = 20, barrels_empty = 4, cont_free = 0, barrels_reg = 4}
  local function watch(day, i2) econ.brew_watch(W.K, W.K.cfg.baseline.economy, {day = true, now = day * DAYT, p = p, inv = i2 or inv, days = {drink_d = 40}, cit = 6}) end
  watch(100)
  T.eq(P[1].max_barrels, 54, 'no DF reason: nothing acts')
  feed(econ, W.K, 12, 101 * DAYT)
  watch(101)
  T.eq(P[1].max_barrels, 2, 'lowered to the 2 registered barrels with contents (the standing cap and its floor of 2 agree)')
  T.eq({P[2].max_barrels, P[3].max_barrels}, {12, 20}, 'drink piles untouched')
  local ev = W.find_events('PILE_BARREL_RELEASE')
  T.eq(#ev, 1)
  T.eq({ev[1].d.pile, ev[1].d.phase, ev[1].d.reg0}, {41, 'lowered', 2})
  T.ok(p.relpiles and p.relpiles['41'] and p.relpiles['41'].old == 54, 'the old limit is kept in the hold (BUG-930)')
  T.ok(log_has(W, 'pile barrel release: stockpile 41'), 'logged')
  -- one game day later: the registration fell by one (DF let one empty go)
  P[1].storage.container_item_id = kmock.vec{reg1[2].id, reg1[3].id, reg1[4].id}
  watch(102)
  ev = W.find_events('PILE_BARREL_RELEASE')
  T.eq(#ev, 2)
  T.eq({ev[2].d.phase, ev[2].d.reg1}, {'d1', 1})
  -- seven days after: still 1 < 2: the registration fell, the cure keeps working
  watch(108)
  ev = W.find_events('PILE_BARREL_RELEASE')
  T.eq(#ev, 3)
  T.eq({ev[3].d.phase, ev[3].d.reg7, ev[3].d.before, ev[3].d.after}, {'d7', 1, 54, 2})
  -- NEU17b D3: cont_free stood at 0 (0 -> 0): the event says so and the release rests (the lowered limit stays until the cure ends)
  T.ok(ev[3].d.verdict:find('the registration fell; cont_free did not rise (0 -> 0)', 1, true), ev[3].d.verdict)
  T.ok(p.relnext ~= nil, 'the release rests')
  T.eq(p.relstop, nil)
end)

T.test('BUG-887 round 6 D: if the registered empties did not fall after 7 days the event says DF kept the registration and nothing is lowered further', function()
  local W, ord, P = release_world()
  local econ = require('dfllm.economy')
  local p = W.K.persist.get('m.economy')
  p.orders = {['dfllm:drink'] = ord.id}
  local inv = {brew_p = 6978, barrels = 20, barrels_empty = 4, cont_free = 0, barrels_reg = 4}
  W.K.cfg.baseline.economy.cancel.stand = false              -- the standing cap is its own cure with its own exit; it would lower the pile again in the same run
  local function watch(day) econ.brew_watch(W.K, W.K.cfg.baseline.economy, {day = true, now = day * DAYT, p = p, inv = inv, days = {drink_d = 40}, cit = 6}) end
  feed(econ, W.K, 12, 101 * DAYT)
  watch(101)
  watch(102)
  watch(108)
  local ev = W.find_events('PILE_BARREL_RELEASE')
  T.eq(#ev, 3)
  T.eq(ev[3].d.phase, 'd7')
  T.ok(ev[3].d.verdict:find('DF kept the registration', 1, true), ev[3].d.verdict)
  T.eq(p.relstop, nil)
  T.ok(ev[3].msg:find('DF kept the registration', 1, true), ev[3].text)
  -- NEU17c BUG-930: the d7 verdict no longer gives the limit back (the i4 live run: that and the 14-day bound undid the cure): it is held
  T.eq(P[1].max_barrels, 2, 'the limit stays lowered after the d7 kept verdict')
  T.ok(p.relpiles and p.relpiles['41'].old == 54, 'held with its old limit')
  T.ok(not log_has(W, 'pile barrel release over (DF kept the registration)'), 'no give-back line')
  feed(econ, W.K, 12, 109 * DAYT)
  watch(109)
  T.eq(P[1].max_barrels, 2, 'still held')
  T.eq(#W.find_events('PILE_BARREL_RELEASE'), 3)
end)

T.test('BUG-887 round 6 D: a release lowering is NOT given back after 14 game days (BUG-930: held), the release rests for new piles', function()
  local W, ord, P, reg1 = release_world()
  local econ = require('dfllm.economy')
  local p = W.K.persist.get('m.economy')
  p.orders = {['dfllm:drink'] = ord.id}
  W.K.cfg.baseline.economy.cancel.stand = false
  local inv = {brew_p = 6978, barrels = 20, barrels_empty = 4, cont_free = 0, barrels_reg = 4}
  local function watch(day) econ.brew_watch(W.K, W.K.cfg.baseline.economy, {day = true, now = day * DAYT, p = p, inv = inv, days = {drink_d = 40}, cit = 6}) end
  feed(econ, W.K, 12, 101 * DAYT)
  watch(101)
  T.eq(P[1].max_barrels, 2)
  P[1].storage.container_item_id = kmock.vec{reg1[2].id, reg1[3].id, reg1[4].id}      -- the registration fell: the cure works, the cancels go on
  watch(102)
  watch(108)
  T.eq(p.relstop, nil)
  T.eq(P[1].max_barrels, 2, 'still lowered on day 108')
  feed(econ, W.K, 12, 115 * DAYT)
  watch(115)
  T.eq(P[1].max_barrels, 2, 'no time bound: still held after 14 days')
  T.ok(p.relpiles and p.relpiles['41'], 'held')
  feed(econ, W.K, 12, 116 * DAYT)
  watch(116)
  T.eq(P[1].max_barrels, 2, 'still held')
end)

T.test('BUG-887 round 6 D: without a registered empty in the census, or with the switch off, nothing is lowered', function()
  local W, ord, P = release_world()
  local econ = require('dfllm.economy')
  local p = W.K.persist.get('m.economy')
  p.orders = {['dfllm:drink'] = ord.id}
  W.K.cfg.baseline.economy.cancel.stand = false
  feed(econ, W.K, 12, 101 * DAYT)
  local r = {day = true, now = 101 * DAYT, p = p, inv = {brew_p = 6978, barrels = 20, barrels_empty = 4, cont_free = 0, barrels_reg = 0}, days = {drink_d = 40}, cit = 6}
  econ.brew_watch(W.K, W.K.cfg.baseline.economy, r)
  T.eq(P[1].max_barrels, 54, 'census says no registered empty')
  r.inv.barrels_reg = 3
  W.K.cfg.baseline.economy.cancel.release = false
  econ.brew_watch(W.K, W.K.cfg.baseline.economy, r)
  T.eq(P[1].max_barrels, 54, 'cancel.release = false')
  W.K.cfg.baseline.economy.cancel.release = nil
  econ.brew_watch(W.K, W.K.cfg.baseline.economy, r)
  T.eq(P[1].max_barrels, 2, 'default on: lowered to the 2 registered full barrels')
end)

T.done()
