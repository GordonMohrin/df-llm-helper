-- BUG-834..838 (Neuausrichtung 3, 'fass'): forts die of thirst with full plant stocks. The live state of Run 17, rebuilt:
--   i1 Diedplank y380: 3 free empty barrels, 3472 plants, 32 brews open, order 414 bound to the first of two Stills, 'the manager gave no Still a job';
--   i2 Whirledrampart y485: 321 barrels, 7 'empty' that never change for 1800 days, 6978 plants, a MakeBarrel job nobody works, 'the labor this job needs is not known'.
-- BUG-834 the container verdict follows the brews open (not a constant 3), a free count that never moves is no container, and the plant stockpiles take no
--         new barrel while a brew has none (act.pile_barrels); BUG-835 the container labors are held and the Carpenter's sheet gets MakeBarrel tasks without the
--         manager; BUG-836 jobwhy names the labor of a container job, the unmet item condition and an unreliable scan; BUG-837 the manager's chores go off and
--         the query says what he does; BUG-838 an order bound to one Still while another idles.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local DAYT = 1200
local BREWER, CARPENTER = 6, 7

local function world(o)
  o = o or {}
  local units, ids = {}, {}
  for i = 1, o.n or 6 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}}; ids[i] = i end
  local base = F.cfg()
  if o.cures ~= false then base.economy.diag = {cx_cure = true, mgr_chores = true, still_pin = true, stall_line = true} end   -- NEU3: the cures are switches, default off
  local W = F.world{cfg = {baseline = base}, units = units}
  if df.job_type.Dig == nil then df.job_type.Dig = 990; df.job_type[990] = 'Dig' end
  df.unit_labor = {BREWER = BREWER, [BREWER] = 'BREWER', CARPENTER = CARPENTER, [CARPENTER] = 'CARPENTER'}
  df.job_skill = df.job_skill or {}
  dfhack.job.getWorker = function(j) return j._worker end
  for i = 1, o.n or 6 do
    local u = W.unit(i)
    u.job, u.mood = {current_job = nil}, -1
    u.status.labors = {}
    u.military = {squad_id = -1}
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  for _, id in ipairs(o.brewers or {1, 2}) do W.unit(id).status.labors[BREWER] = true end
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
  local b2
  if o.second then
    b2 = F.workshop(W, 'Still')
    b2.x1, b2.y1, b2.x2, b2.y2, b2.z = 30, 20, 32, 22, 100
    b2.getBuildStage = function() return 1 end
    b2.getMaxBuildStage = function() return 1 end
    b2.jobs = kmock.vec{}
    b2.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  end
  local ord = F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = o.left or 5, amount_total = o.left or 5,
                          mat_type = -1, mat_index = -1, workshop_id = o.pinned and b.id or -1, item_conditions = kmock.vec{}})
  return W, b, ord, b2
end

-- NEU4: DF's own reason: `n` cancels "Needs empty food storage item" at `tick` (the CANCEL_JOB announcement economy tallies)
local function feed(econ, K, n, tick, why)
  for _ = 1, n do
    econ.on.REPORT(K, {type = 'CANCEL_JOB', tick = tick, text = 'Urist McBrew cancels Brew drink from plant: ' .. (why or 'Needs empty food storage item') .. '.'})
  end
end

-- days of brew_watch; `inv` may be a function(day) -> inventory; `df` = DF cancels the brews 'Needs empty food storage item' (3 a day)
local function econ_run(W, ord, n, inv, drink_d, df)
  local econ = require('dfllm.economy')
  local p = W.K.persist.get('m.economy')
  p.orders = p.orders or {}
  p.orders['dfllm:drink'] = ord.id
  for i = 1, n do
    if df then feed(econ, W.K, 3, (100 + i) * DAYT) end
    local r = {day = true, now = (100 + i) * DAYT, p = p, inv = type(inv) == 'function' and inv(i) or inv, days = {drink_d = drink_d or 40}, cit = 6}
    econ.brew_watch(W.K, W.K.cfg.baseline.economy, r)
  end
  return econ, p
end
local function stuck(W)
  local out = {}
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do
    if tostring(e.msg):find('brewing stalled', 1, true) then
      out[#out + 1] = e
      for _, l in ipairs(W.logs) do if tostring(l.msg):sub(1, 60) == tostring(e.msg):sub(1, 60) then e.full = l.msg end end
      e.full = e.full or e.msg
    end
  end
  return out
end

-- the Run 17 i1 census: 55 barrels, 4 empty, 3 free, 3472 plants
local I1 = {brew_p = 3472, barrels = 55, barrels_empty = 4, cont_free = 3, pots = 0, pots_empty = 0}
-- the Run 17 i2 census: 321 barrels, 7 empty and free by the census, never changing
local I2 = {brew_p = 6978, barrels = 321, barrels_empty = 7, cont_free = 7, pots = 243, pots_empty = 5}

T.test('BUG-834 i1 Diedplank: 3 free containers beside 32 brews open is a container stall; the plant piles are frozen, barrels wanted', function()
  local W, _, ord = world{left = 32}
  W.act_result('pile_barrels', function(mode, arg)
    if mode == 'freeze' then return true, {{id = 41, old = -1, new = 9, name = 'dfllm-stock'}} end
    return true, {}
  end)
  local _, p = econ_run(W, ord, 8, I1, nil, true)
  local ev = stuck(W)
  T.eq(#ev, 1, 'told once')
  T.ok(ev[1].full:find('no empty barrel or pot for a brew', 1, true), 'the container verdict, not "the manager gave no Still a job": ' .. ev[1].full)
  T.ok(p.contx and p.contx.res == 8, 'reserve = a quarter of 32 brews: ' .. T.show(p.contx))
  local fr = W.find_acts('pile_barrels')
  T.ok(#fr >= 1 and fr[1].args[1] == 'freeze', 'the plant piles take no new barrel')
  T.eq(fr[1].args[2].mixed, false, 'drink 40 days: piles that hold drink are left alone')
  T.eq(p.pilecap and p.pilecap['41'], -1, 'the old limit is kept for the restore')
end)

T.test('BUG-834: 3 free beside 5 brews stays no stall (reserve 3); a drink emergency freezes the mixed piles too', function()
  local W, _, ord = world{left = 5}
  local _, p = econ_run(W, ord, 8, {brew_p = 50, barrels = 20, barrels_empty = 6, cont_free = 3})
  T.eq(p.contx, nil)
  T.eq(#W.find_acts('pile_barrels'), 0)
  local W2, _, ord2 = world{left = 32}
  econ_run(W2, ord2, 8, I1, 3, true)
  T.eq(W2.find_acts('pile_barrels')[1].args[2].mixed, true, 'drink 3 days: emergency')
end)

T.test('BUG-834 i2 Whirledrampart: 7 "free" barrels that never change for 12 days beside stalled brews are no free containers (phantom)', function()
  local W, _, ord = world{left = 6}
  local _, p = econ_run(W, ord, 10, I2)
  T.eq(p.contx, nil, '10 days: not yet proof')
  local W2, _, ord2 = world{left = 6}
  W2.act_result('pile_barrels', function(mode) return true, {} end)
  W2.K.persist.get('m.economy').brewx = {relax = 1, n = 1}          -- the first cure (the orders made again) has run
  local _, p2 = econ_run(W2, ord2, 45, I2, nil, true)
  local ev = stuck(W2)
  T.ok(#ev >= 2 and ev[2].full:find('DF takes none of them', 1, true) and ev[2].full:find('DF cancelled Brew', 1, true), ev[2] and ev[2].full or 'no 2nd report')
  T.ok(p2.contx and p2.contx.ph == true, 'wanted: ' .. T.show(p2.contx))
  -- a moving count is no phantom
  local W3, _, ord3 = world{left = 6}
  local _, p3 = econ_run(W3, ord3, 20, function(i) local x = {}; for k, v in pairs(I2) do x[k] = v end; x.cont_free = 7 + (i % 2); return x end)
  T.eq(p3.contx, nil)
end)

T.test('BUG-834: the stall is over (the brews moved): the stockpile limits come back, contx is cleared', function()
  local W, _, ord = world{left = 32}
  local back
  W.act_result('pile_barrels', function(mode, arg)
    if mode == 'freeze' then return true, {{id = 41, old = 12, new = 9, name = 'dfllm-stock'}} end
    back = arg
    return true, {{id = 41, new = 12}}
  end)
  local _, p = econ_run(W, ord, 8, I1, nil, true)
  T.ok(p.pilecap and p.pilecap['41'] == 12)
  ord.amount_left = 20                                             -- the brewers work: the order fell
  local econ = require('dfllm.economy')
  local r = {day = true, now = 120 * DAYT, p = p, inv = {brew_p = 3000, barrels = 55, barrels_empty = 20, cont_free = 19}, days = {drink_d = 40}, cit = 6}
  econ.brew_watch(W.K, W.K.cfg.baseline.economy, r)
  r.now = 121 * DAYT
  econ.brew_watch(W.K, W.K.cfg.baseline.economy, r)
  T.eq(back and back['41'], 12, 'restore with the old limit')
  T.eq(p.pilecap, nil)
end)

T.test('BUG-834: act.pile_barrels freezes the plant piles at the barrels they hold, leaves drink piles and the drink store alone, restores', function()
  local W = world{}
  local sp = function(id, name, x1, food, drink, max)
    return {id = id, name = name, x1 = x1, y1 = 0, x2 = x1 + 2, y2 = 2, z = 5, max_barrels = max,
            settings = {flags = {food = food}, food = {drink_plant = kmock.vec{drink}, drink_animal = kmock.vec{false}}}}
  end
  local plants, mixed, store = sp(41, 'plants', 0, true, false, -1), sp(42, 'mixed', 10, true, true, -1), sp(43, 'dfllm-drink', 20, true, true, -1)
  local rows = kmock.vec{plants, mixed, store}
  df.global.world.buildings.other.STOCKPILE = rows
  df.building.find = function(id) for _, s in ipairs({plants, mixed, store}) do if s.id == id then return s end end end
  rawset(df.global.world.items.other, 'BARREL', kmock.vec{{pos = {x = 1, y = 1, z = 5}}, {pos = {x = 2, y = 2, z = 5}}, {pos = {x = 11, y = 1, z = 5}}, {pos = {x = 50, y = 1, z = 5}}})
  local actlib = require('dfllm.act')
  local api = actlib.new{who = function() return 'economy' end, allowlist = function() return actlib.BUILTIN_ALLOWLIST end,
                         log_cmd = function() end, fail = function() end}
  local ok, res = api.pile_barrels('freeze', {})
  T.ok(ok and #res == 1 and res[1].id == 41 and res[1].new == 2, T.show(res))
  T.eq({plants.max_barrels, mixed.max_barrels, store.max_barrels}, {2, -1, -1})
  ok, res = api.pile_barrels('freeze', {mixed = true})
  T.eq({mixed.max_barrels, store.max_barrels, plants.max_barrels}, {1, -1, 2}, 'the emergency takes the mixed pile, never the drink store')
  api.pile_barrels('restore', {['41'] = -1, ['42'] = -1})
  T.eq({plants.max_barrels, mixed.max_barrels}, {-1, -1})
end)

T.test('BUG-835: a container stall puts the Carpentry labor on citizens (3 holders) and MakeBarrel tasks on the Carpenter sheet without the manager', function()
  local W, _, ord = world{left = 32, n = 8}
  F.workshop(W, 'Carpenters')
  for _ = 1, 40 do F.item(W, 'WOOD', {}) end
  local sets = {}
  W.act_result('labor_set', function(id, which, on) sets[#sets + 1] = {id, which, on}; W.unit(id).status.labors[CARPENTER] = true; return true, 'enabled' end)
  local p = W.K.persist.get('m.economy')
  p.contx = {untl = 1e12, want = 15, res = 8, since = 0}           -- the stall is 2+ days old
  feed(require('dfllm.economy'), W.K, 8, W.K.now().tick)           -- NEU4: and DF says so
  for _ = 1, 3 do W.run(1200, {skip = 100}); for _ = 1, 40 do W.run(1) end end
  local carp = 0
  for _, s in ipairs(sets) do if s[2] == 'carpenter' and s[3] == true then carp = carp + 1 end end
  T.ok(carp >= 2, 'Carpentry on for citizens: ' .. T.show(sets))
  local tasks = {}
  for _, a in ipairs(W.find_acts('ws_task')) do if a.args[2] == 'MakeBarrel' then tasks[#tasks + 1] = a end end
  T.ok(#tasks >= 3 and #tasks % 3 == 0, 'MakeBarrel tasks at the Carpenters (3 a day, CX_DIRECT): ' .. #tasks)
end)

T.test('BUG-835: act.ws_task accepts MakeBarrel in wood only', function()
  local A = require('dfllm.act')
  T.ok(A.WS_TASK.MakeBarrel and A.WS_TASK.MakeBarrel.wood and not A.WS_TASK.MakeBarrel.rock)
  T.ok(A.LABOR_SETS.carpenter.name == 'CARPENTER' and A.LABOR_SETS.carpenter.on == true)
  T.ok(A.LABOR_SETS.stonecraft.name == 'STONE_CRAFT')
end)

-- jobwhy -------------------------------------------------------------------------------------------------------------------------------
local function jw_world()
  local W = world{}
  df.items_other_id = kmock.enum({'IN_PLAY', 'PLANT', 'BARREL', 'FISH_RAW', 'FOOD_STORAGE', 'WOOD'})
  rawset(df.global.world.items.other, 'FOOD_STORAGE', kmock.vec{})
  if df.job_type.MakeBarrel == nil then df.job_type.MakeBarrel = 991; df.job_type[991] = 'MakeBarrel' end
  df.job_type.attrs = setmetatable({}, {__index = function() return {labor = -1, skill = -1} end})
  df.global.world.raws.reactions = {reactions = kmock.vec{
    {code = 'BREW_DRINK_FROM_PLANT', skill = 60,
     building = {type = kmock.vec{df.building_type.Workshop}, subtype = kmock.vec{df.workshop_type.Still}}}}}
  dfhack.job.isSuitableItem = function() return true end
  dfhack.job.isSuitableMaterial = function() return true end
  dfhack.units.isJobAvailable = function(u) return u._m.avail ~= false end
  dfhack.units.getNominalSkill = function() return 0 end
  for i = 1, 6 do W.unit(i).burrows = kmock.vec{} end
  return W
end

T.test('BUG-836 i2: a MakeBarrel job nobody works names the Carpentry labor and its missing holders (was "the labor this job needs is not known")', function()
  local W = jw_world()
  local b = F.workshop(W, 'Carpenters')
  b.x1, b.y1, b.x2, b.y2, b.z, b.centerx, b.centery = 20, 20, 22, 22, 100, 21, 21
  b.jobs = kmock.vec{}
  b.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  local o = F.order(W, {job_type = df.job_type.MakeBarrel, amount_left = 40, amount_total = 40, mat_type = -1, mat_index = -1, workshop_id = -1,
                        material_category = {wood = true}, item_conditions = kmock.vec{}})
  local j = {id = 1430329, job_type = df.job_type.MakeBarrel, reaction_name = '', mat_type = -1, mat_index = -1, flags = {}, _holder = b, order_id = o.id,
             job_items = {elements = kmock.vec{{item_type = df.item_type.WOOD, item_subtype = -1, mat_type = -1, mat_index = -1, quantity = 1, vector_id = -1,
                                                flags1 = {}}}}, items = kmock.vec{}}
  b.jobs:insert('#', j)
  F.item(W, 'WOOD', {_pos = {12, 12, 100}})
  local JW = fresh('jobwhy')
  local r = JW.find(W.K, 'order:' .. o.id, {})
  T.eq(r.cause, 'no_labor', r.text)
  T.ok(r.text:find('nobody holds the CARPENTER labor', 1, true), r.text)
  W.unit(3).status.labors[CARPENTER] = true
  r = JW.find(W.K, 'order:' .. o.id, {})
  T.ok(r.cause ~= 'no_labor' and r.sub and r.sub.workers and r.sub.workers.n == 1, 'with a holder the labor is read: ' .. r.text)
end)

T.test('BUG-836: an order with an item condition that is not met names it with the count (was "DF checks itself, not read here")', function()
  local W = jw_world()
  local b = F.workshop(W, 'Still')
  b.x1, b.y1, b.x2, b.y2, b.z, b.centerx, b.centery = 20, 20, 22, 22, 100, 21, 21
  b.jobs = kmock.vec{}
  b.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  W.unit(1).status.labors[BREWER] = true
  local o = F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = 5, amount_total = 5, mat_type = -1,
                        mat_index = -1, workshop_id = -1,
                        item_conditions = kmock.vec{{compare_type = 'AtLeast', compare_val = 10, item_type = df.item_type.PLANT, flags1 = {}}}})
  for _ = 1, 3 do F.item(W, 'PLANT', {_pos = {12, 12, 100}, getSubtype = function() return -1 end, getMaterial = function() return 419 end,
                                      getMaterialIndex = function() return 1 end}) end
  local JW = fresh('jobwhy')
  local r = JW.find(W.K, 'order:' .. o.id, {})
  T.eq(r.cause, 'cond_unmet', r.text)
  T.ok(r.text:find('AtLeast 10 plant: 3 found', 1, true), r.text)
  T.ok(JW.proven(r), 'a named blocker')
end)

T.test('BUG-836 i2: a scan that finds 0 plants where the census holds 6932 says the scan is unreliable, not "none"', function()
  local W = jw_world()
  local b = F.workshop(W, 'Still')
  b.x1, b.y1, b.x2, b.y2, b.z, b.centerx, b.centery = 20, 20, 22, 22, 100, 21, 21
  b.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  W.unit(1).status.labors[BREWER] = true
  local j = {id = 1443589, job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', mat_type = -1, mat_index = -1, flags = {},
             _holder = b, order_id = -1, items = kmock.vec{},
             job_items = {elements = kmock.vec{{item_type = df.item_type.PLANT, item_subtype = -1, mat_type = -1, mat_index = -1, quantity = 1, vector_id = -1,
                                                flags1 = {unrotten = true}, has_material_reaction_product = 'DRINK_MAT'}}}}
  b.jobs = kmock.vec{j}
  local JW = fresh('jobwhy')
  local r = JW.find(W.K, 'job:' .. j.id, {inv = I2})
  T.eq(r.cause, 'scan_unreliable', r.text)
  T.ok(r.text:find('census holds 6978', 1, true), r.text)
  T.ok(not JW.proven(r), 'not claimed as the cause')
  r = JW.find(W.K, 'job:' .. j.id, {})
  T.eq(r.cause, 'no_input', 'without a census the old answer')
end)

T.test('BUG-836 retry: a condition counted 0 by the scan while the census holds 6978 is not proven; empty food_storage is read against the census', function()
  local W = jw_world()
  local b = F.workshop(W, 'Still')
  b.x1, b.y1, b.x2, b.y2, b.z, b.centerx, b.centery = 20, 20, 22, 22, 100, 21, 21
  b.jobs = kmock.vec{}
  b.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  W.unit(1).status.labors[BREWER] = true
  local o = F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = 5, amount_total = 5, mat_type = -1,
                        mat_index = -1, workshop_id = -1,
                        item_conditions = kmock.vec{{compare_type = 'AtLeast', compare_val = 2, item_type = df.item_type.PLANT, flags1 = {unrotten = true},
                                                     has_material_reaction_product = 'DRINK_MAT'},
                                                    {compare_type = 'AtLeast', compare_val = 1, item_type = -1, flags1 = {empty = true}, flags3 = {food_storage = true}}}})
  local JW = fresh('jobwhy')
  local r = JW.find(W.K, 'order:' .. o.id, {inv = I2})
  T.ok(r.cause ~= 'cond_unmet', 'the scan found 0, the census 6978: ' .. r.text)
  T.ok(not JW.proven(r), 'not a proven cause: ' .. r.text)
  T.ok(r.text:find('census holds 6978', 1, true), r.text)
  T.ok(r.text:find('empty by the census', 1, true), 'the empty storage condition is read: ' .. r.text)
  r = JW.find(W.K, 'order:' .. o.id, {})
  T.eq(r.cause, 'cond_unmet', 'without a census the scan counts: ' .. r.text)
end)

T.test('BUG-837: an unvalidated order names what the manager does (a carer), whatever his chore', function()
  local W = jw_world()
  local b = F.workshop(W, 'Still')
  b.x1, b.y1, b.x2, b.y2, b.z = 20, 20, 22, 22, 100
  b.jobs = kmock.vec{}
  local o = F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = 5, amount_total = 5, mat_type = -1,
                        mat_index = -1, workshop_id = -1, status = {validated = false}, item_conditions = kmock.vec{}})
  local JW = fresh('jobwhy')
  local r = JW.find(W.K, 'order:' .. o.id, {manager = function() return {unit = 5, causes = {}, job = 'GiveWater'} end})
  T.eq(r.cause, 'not_validated')
  T.ok(r.text:find('works as GiveWater', 1, true), r.text)
end)

T.test('BUG-838 i1: an order bound to one Still while a second Still stands idle is named and relaxed', function()
  local W, b, ord, b2 = world{left = 5, pinned = true, second = true}
  local _, p = econ_run(W, ord, 8, {brew_p = 3472, barrels = 55, barrels_empty = 20, cont_free = 19})
  local ev = stuck(W)
  T.ok(#ev == 1 and ev[1].full:find('bound to Still', 1, true), ev[1] and ev[1].full)
  T.ok(p.brewx and p.brewx.relax, 'the order is made again with no pin')
end)

T.done()
