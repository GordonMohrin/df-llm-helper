-- NEU20a (holz-fass) BUG-935 (17c verifier nits): held piles whose pile no longer exists or whose give-back write fails leave `p.relpiles` (else the hold never ends), a hold that lasted
-- longer than cancel.hold_warn_d (672 = 2 game years) with cont_free still under the target is said once a game week (nothing is given back by it), and the status text does not claim
-- more than is known about the registered empties.
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


local HELD = {0, 0, 0, 1, 3, 15}          -- dfllm-stock 9/9/9/27 lowered to their full-barrel count (0/0/0/1), dfllm-drink 3 and the player pile 15 untouched
local OLD = {9, 9, 9, 27, 3, 15}

-- gate-off day of the world: feed cancels once, then none; the cure's hysteresis (7 d window + 14 d) ends it
local function lower_and_wait(W, econ, c, P)
  feed(econ, W.K, 12, W.K.now().tick)
  econ.release_watch(W.K, c)
  T.eq(limits(P), HELD, 'lowered')
end
local function ev_count(W, phase) return #ev_of(W, phase) end


local function steps(W, econ, c, n)
  for _ = 1, n do
    W.run(DAYT, {skip = 100})
    econ.release_watch(W.K, c)
  end
end
local function count_log(W, s) local n = 0; for _, l in ipairs(W.logs) do if tostring(l.msg):find(s, 1, true) then n = n + 1 end end; return n end

T.test('BUG-935: a held pile that is gone leaves the hold (said once); the others are given back in steps and the hold ends', function()
  local W, ord, P, c = i4_world(true)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  local p = W.K.persist.get('m.economy')
  lower_and_wait(W, econ, c, P)
  -- pile 62 is deconstructed: gone from the building list and from df.building.find
  local keep = {}
  for _, sp in ipairs(P) do if sp.id ~= 62 then keep[#keep + 1] = sp end end
  df.global.world.buildings.other.STOCKPILE = kmock.vec(keep)
  local find = df.building.find
  df.building.find = function(id) if id == 62 then return nil end return find(id) end
  W.K.census.i.cont_free = 25
  steps(W, econ, c, 140)
  T.eq(p.relpiles, nil, 'the hold ended: the gone pile did not keep it alive: ' .. T.show(p.relpiles))
  T.eq(p.hold, nil)
  T.eq(count_log(W, '(pile gone)'), 1, 'said once')
  T.ok(log_has(W, '1 held piles leave the hold'), 'the line names the count')
  T.eq({P[1].max_barrels, P[3].max_barrels, P[4].max_barrels}, {9, 9, 27}, 'the others are back at their old limits')
end)

T.test('BUG-935: a pile whose give-back write fails three steps in a row leaves the hold (a single failure does not)', function()
  local W, ord, P, c = i4_world(true)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  local p = W.K.persist.get('m.economy')
  lower_and_wait(W, econ, c, P)
  local PL = require('dfllm.pilelib')
  local set = PL.set
  local fails = 0
  PL.set = function(sp, v) if sp.id == 63 then fails = fails + 1; return false end return set(sp, v) end
  W.K.census.i.cont_free = 25
  steps(W, econ, c, 140)
  PL.set = set
  T.ok(fails >= 3, 'the write was tried: ' .. fails)
  T.eq(p.relpiles, nil, 'the hold ended after the third failed step: ' .. T.show(p.relpiles))
  T.eq(count_log(W, 'write failed 3 steps in a row'), 1)
  T.eq(P[3].max_barrels, 0, 'the unwritable pile keeps its lowered limit (said, not hidden)')
  T.eq({P[1].max_barrels, P[2].max_barrels, P[4].max_barrels}, {9, 9, 27})
end)

T.test('BUG-935: a hold older than hold_warn_d with cont_free under the target: one line a game week, nothing given back', function()
  local W, ord, P, c = i4_world(true)
  local econ = require('dfllm.economy')
  c.cancel.stand = false
  local p = W.K.persist.get('m.economy')
  lower_and_wait(W, econ, c, P)
  p.hold.t = W.K.now().tick - 700 * DAYT                       -- the hold is 700 game days old
  W.K.census.i.cont_free = 5
  steps(W, econ, c, 3)
  T.eq(count_log(W, 'have held their barrel limit lowered'), 1, 'the first line')
  steps(W, econ, c, 3)
  T.eq(count_log(W, 'have held their barrel limit lowered'), 1, 'once a week')
  steps(W, econ, c, 6)
  T.eq(count_log(W, 'have held their barrel limit lowered'), 2, 'the next week')
  T.ok(log_has(W, 'NOT given back by this'), 'honest: no automatic give-back')
  T.eq(limits(P), HELD, 'the limits stand')
  W.K.census.i.cont_free = 25
  local before = count_log(W, 'have held their barrel limit lowered')
  steps(W, econ, c, 10)
  T.eq(count_log(W, 'have held their barrel limit lowered'), before, 'no line while the empties are at the target')
end)

T.test('BUG-935: the container text does not claim DF skips the registered empties (not proven)', function()
  local econ = require('dfllm.economy')
  local txt = econ.cont_text({barrels_empty = 8, barrels_reg = 4, cont_free = 3})
  T.ok(txt:find('4 held by stockpiles as their containers', 1, true) and txt:find("DF's own use of them is not proven", 1, true), txt)
end)

T.done()
