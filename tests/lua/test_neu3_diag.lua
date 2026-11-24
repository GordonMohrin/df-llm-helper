-- NEU3 diagnostics (docs/v2/NEU3-diagnose.md): the raw dumps (inspect what=raw: order / brew / job / items / manager), the stall line in kern.log, the
-- acting cures of the 'fass' round behind economy.diag switches that default OFF, J.labors for a MakeBarrel job. Offline, against the fake world.
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
  if o.diag then base.economy.diag = o.diag end
  local W = F.world{cfg = {baseline = base}, units = units}
  if df.job_type.Dig == nil then df.job_type.Dig = 990; df.job_type[990] = 'Dig' end
  if df.job_type.MakeBarrel == nil then df.job_type.MakeBarrel = 991; df.job_type[991] = 'MakeBarrel' end
  df.unit_labor = {BREWER = BREWER, [BREWER] = 'BREWER', CARPENTER = CARPENTER, [CARPENTER] = 'CARPENTER'}
  df.job_skill = df.job_skill or {}
  df.items_other_id = kmock.enum({'IN_PLAY', 'PLANT', 'PLANT_GROWTH', 'BARREL', 'FISH_RAW', 'FOOD_STORAGE', 'WOOD'})
  for _, v in ipairs({'PLANT', 'PLANT_GROWTH', 'BARREL', 'WOOD', 'FOOD_STORAGE'}) do rawset(df.global.world.items.other, v, rawget(df.global.world.items.other, v) or kmock.vec{}) end
  df.job_type.attrs = setmetatable({}, {__index = function() return {labor = -1, skill = -1} end})
  df.global.world.raws.reactions = {reactions = kmock.vec{
    {code = 'BREW_DRINK_FROM_PLANT', skill = 60, building = {type = kmock.vec{df.building_type.Workshop}, subtype = kmock.vec{df.workshop_type.Still}}}}}
  dfhack.job.getWorker = function(j) return j._worker end
  dfhack.job.isSuitableItem = function() return true end
  dfhack.job.isSuitableMaterial = function() return true end
  dfhack.units.isJobAvailable = function(u) return u._m.avail ~= false end
  dfhack.units.getNominalSkill = function() return 0 end
  dfhack.units.isChild = function() return false end
  dfhack.units.isBaby = function() return false end
  for i = 1, o.n or 6 do
    local u = W.unit(i)
    u.job, u.mood = {current_job = nil}, -1
    u.status.labors = {}
    u.military = {squad_id = -1}
    u.burrows = kmock.vec{}
    u.flags1 = {}
    u.counters2 = {thirst_timer = 0, hunger_timer = 0}
  end
  for _, id in ipairs(o.brewers or {1, 2}) do W.unit(id).status.labors[BREWER] = true end
  W.set_census('u', F.census_u(ids))
  F.item(W, 'DRINK', {stack_size = 20000})
  W.load({name = 'snapshot', every = {ticks = 100}, tile = function() return {c = '.'} end, plot_under = function() return true end,
          groups = function(_, pts) local g = {}; for i, p in ipairs(pts) do g[i] = p[1] >= 500 and 2 or 1 end; return g end,
          hidden = function(_, pts) local g = {}; for i, p in ipairs(pts) do g[i] = p[2] >= 900 end; return g end})
  W.load(fresh('economy'))
  local b = F.workshop(W, 'Still')
  b.x1, b.y1, b.x2, b.y2, b.z, b.centerx, b.centery = 20, 20, 22, 22, 100, 21, 21
  b.getBuildStage = function() return 1 end
  b.getMaxBuildStage = function() return 1 end
  b.jobs = kmock.vec{}
  b.flags = {}
  b.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  local ord = F.order(W, {job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', amount_left = o.left or 5, amount_total = o.left or 5,
                          mat_type = -1, mat_index = -1, workshop_id = o.pinned or -1, status = {validated = true, active = true}, frequency = 0,
                          item_conditions = kmock.vec{{compare_type = 'AtLeast', compare_val = 1, item_type = -1, flags1 = {empty = true}, flags3 = {food_storage = true}}}})
  return W, b, ord
end

local function raw(W, key)
  return W.inbox('inspect', {what = 'raw', key = key})
end
local function text(r) return table.concat((r.data and r.data.lines) or {}, '\n') end

-- 1. order / brew dump --------------------------------------------------------------------------------------------------------------
T.test('NEU3 raw order: flags, pinned shop, condition fields, shop profile, jobs, holders by status', function()
  local W, b, ord = world{pinned = 99}
  local j = {id = 777, job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', flags = {suspend = false}, order_id = ord.id,
             completion_timer = 3, _holder = b, mat_type = -1, mat_index = -1, items = kmock.vec{}, job_items = {elements = kmock.vec{}}}
  b.jobs:insert('#', j)
  W.unit(2).burrows = kmock.vec{5}                                -- brewer 2 is held to burrow 5
  dfhack.burrows = dfhack.burrows or {}
  df.global.plotinfo.burrows = {list = kmock.vec{{id = 5, flags = {}}}}
  dfhack.burrows.isAssignedTile = function() return false end
  local r = raw(W, 'order:' .. ord.id)
  T.ok(r.ok, T.show(r))
  local t = text(r)
  T.ok(t:find('order ' .. ord.id, 1, true) and t:find('amount_left=5 amount_total=5', 1, true), t)
  T.ok(t:find('status=[active,validated]', 1, true), 'status flags by name: ' .. t)
  T.ok(t:find('workshop_id=99', 1, true) and t:find('pinned to workshop 99', 1, true), 'the pinned shop')
  T.ok(t:find('pinned workshop 99 does not exist', 1, true), 'a pin on nothing is said')
  T.ok(t:find('cond 1: compare=AtLeast value=1', 1, true) and t:find('flags1=[empty]', 1, true) and t:find('flags3=[food_storage]', 1, true), 'the condition fields: ' .. t)
  T.ok(t:find('ws ' .. b.id .. ' workshop:Still', 1, true) and t:find('max_general_orders=10', 1, true), 'the Still and its profile: ' .. t)
  T.ok(t:find('job 777 ', 1, true) and t:find('order=' .. ord.id, 1, true) and t:find('worker=none', 1, true), 'the job: ' .. t)
  T.ok(t:find('labor BREWER: 2 holder(s)', 1, true), 'holders: ' .. t)
  T.ok(t:find('burrow_own=1', 1, true), 'one holder is kept out by his burrow: ' .. t)
  T.ok(#t < 12000, 'bounded')
  b.profile = {max_general_orders = 10, permitted_workers = kmock.vec{1}, min_level = 0, max_level = 3000}      -- H4: only unit 1 is permitted
  t = text(raw(W, 'order:' .. ord.id))
  T.ok(t:find('status=profile (not on the permitted list)', 1, true), t)
end)

T.test('NEU3 raw brew: every brew order and every Still, an unknown order is refused, a bad key too', function()
  local W = world{}
  local r = raw(W, 'brew')
  T.ok(r.ok and text(r):find('brew: 1 order(s)', 1, true) and text(r):find('stills: 1', 1, true), text(r))
  r = raw(W, 'order:424242')
  T.ok(not r.ok and tostring(r.msg):find('no manager order 424242', 1, true), T.show(r))
  r = raw(W, 'nonsense')
  T.ok(not r.ok, T.show(r))
end)

T.test('NEU3 raw: a world whose fields all raise or are missing never raises and prints ?', function()
  local W, b, ord = world{}
  local evil = setmetatable({}, {__index = function(_, k) error('no field ' .. tostring(k)) end})
  b.profile, b.flags = evil, evil
  b.getBuildStage = function() error('x') end
  ord.status, ord.item_conditions = evil, evil
  b.jobs:insert('#', setmetatable({id = 5, order_id = ord.id}, {__index = function(_, k) error('no field ' .. tostring(k)) end}))
  for _, key in ipairs({'order:' .. ord.id, 'brew', 'job:5', 'manager', 'items:plants', 'items:logs', 'items:barrels', 'items:BOOK', 'ws:' .. b.id}) do
    local r = raw(W, key)
    T.ok(r ~= nil and (r.ok == true or r.ok == false), key .. ': ' .. T.show(r))
    if r.ok then
      local t = text(r)
      T.ok(#t > 0, key)
    end
  end
  local t = text(raw(W, 'order:' .. ord.id))
  T.ok(t:find('stage ?/1', 1, true) and t:find('max_general_orders=?', 1, true), 'unreadable fields print ?: ' .. t)
end)

-- 2. job dump -----------------------------------------------------------------------------------------------------------------------
T.test('NEU3 raw job: MakeBarrel at the Carpenters: derived labor CARPENTER, job items with flags, holder rows with burrow / walk group / squad', function()
  local W = world{}
  local c = F.workshop(W, 'Carpenters')
  c.x1, c.y1, c.x2, c.y2, c.z, c.centerx, c.centery = 600, 20, 602, 22, 100, 601, 21
  c.jobs, c.flags = kmock.vec{}, {}
  c.getBuildStage, c.getMaxBuildStage = function() return 3 end, function() return 3 end
  c.profile = {max_general_orders = 10, permitted_workers = kmock.vec{}, min_level = 0, max_level = 3000}
  local j = {id = 1430329, job_type = df.job_type.MakeBarrel, reaction_name = '', mat_type = -1, mat_index = -1, flags = {suspend = false}, _holder = c, order_id = 31,
             pos = {x = 601, y = 21, z = 100}, material_category = {wood = true},
             job_items = {elements = kmock.vec{{item_type = df.item_type.WOOD, item_subtype = -1, mat_type = -1, mat_index = -1, quantity = 1, vector_id = -1, min_dimension = 0,
                                                flags1 = {unrotten = true}, flags2 = {}, flags3 = {}}}}, items = kmock.vec{}}
  c.jobs:insert('#', j)
  dfhack.job.getHolder = function(x) return x._holder end
  W.unit(3).status.labors[CARPENTER] = true
  W.unit(4).status.labors[CARPENTER] = true
  W.unit(4).military.squad_id = 2
  W.unit(4).flags1 = {caged = true}
  W.set_census('u', F.census_u({1, 2, 3, 4, 5, 6}, {soldier_ids = {4}}))
  local r = raw(W, 'job:' .. j.id)
  T.ok(r.ok, T.show(r))
  local t = text(r)
  T.ok(t:find('derived labor: CARPENTER', 1, true), 'was nil for MakeBarrel: ' .. t)
  T.ok(t:find('item[0] item_type=', 1, true), t)
  T.ok(t:find('flags1=[unrotten]', 1, true) and t:find('quantity=1', 1, true), 'job item flags: ' .. t)
  T.ok(t:find('holder 3 ', 1, true) and t:find('holder 4 ', 1, true), 'both holders listed: ' .. t)
  T.ok(t:find('squad=2 soldier=true', 1, true) and t:find('flags=[caged]', 1, true), 'squad and caged flag of holder 4: ' .. t)
  T.ok(t:find('walk_group=1 same_as_shop=false', 1, true), 'the shop lies on walk group 2, the unit on 1: ' .. t)
  T.ok(t:find('status=far', 1, true) and t:find('status=soldier', 1, true), t)
  local JW = fresh('jobwhy')
  local labors = JW.labors(df.job_type.MakeBarrel, '', -1, -1, nil)
  T.eq(labors and labors[1], CARPENTER, 'J.labors(MakeBarrel) without a shop key')
end)

-- 3. items --------------------------------------------------------------------------------------------------------------------------
T.test('NEU3 raw items: 183 logs by exclusion reason (forbid, in_job, claimed container, other walk group, hidden tile, civ burrow), census beside', function()
  local W = world{}
  W.set_census('i', {wood = 183})
  local function log(spec) spec._pos = spec._pos or {12, 12, 100}; return F.item(W, 'WOOD', spec) end
  for _ = 1, 100 do log{} end
  for _ = 1, 20 do log{flags = {forbid = true}} end
  for _ = 1, 15 do log{flags = {in_job = true}} end
  for _ = 1, 10 do log{flags = {dump = true, forbid = true}} end          -- dump first, forbid also
  for _ = 1, 8 do log{_pos = {700, 12, 100}} end                            -- the other walk group
  for _ = 1, 5 do log{_pos = {12, 950, 100}} end                            -- an unrevealed tile
  for _ = 1, 25 do log{flags = {}, _cont = {flags = {in_job = true}}} end   -- inside a claimed container
  local r = raw(W, 'items:logs')
  T.ok(r.ok, T.show(r))
  local t = text(r)
  T.ok(t:find('items logs (vector WOOD): 183 records, 183 looked at', 1, true), t)
  T.ok(t:find('no exclusion (free as DF sees it): 100', 1, true), t)
  T.ok(t:find('forbid=30 in_job=15', 1, true) and t:find('dump=10', 1, true), 'forbid 20 + 10 dumped-and-forbidden, dump hit 10: ' .. t)
  T.ok(t:find('in_job=15', 1, true), t)
  T.ok(t:find('in_claimed_container=25', 1, true), t)
  T.ok(t:find('other_walk_group=8', 1, true) and t:find('hidden_tile=5', 1, true), t)
  T.ok(t:find('census says: wood=183', 1, true), t)
  df.global.plotinfo.alerts = {civ_alert_idx = 1, list = kmock.vec{{burrows = kmock.vec{9}}, {burrows = kmock.vec{9}}}}
  df.global.plotinfo.burrows = {list = kmock.vec{{id = 9, flags = {}}}}
  dfhack.burrows = dfhack.burrows or {}
  dfhack.burrows.isAssignedTile = function(_, p) return p.x < 100 end
  t = text(raw(W, 'items:logs'))
  T.ok(t:find('outside_civ_burrow=', 1, true), 'burrow reason: ' .. t)
end)

T.test('NEU3 raw items: brewable plants only (DRINK_MAT), the empty barrels only; a flag the game does not have is counted unreadable, not 0', function()
  local W = world{}
  F.mat(W, 419, 1, {products = {'DRINK_MAT'}})
  dfhack.matinfo.decode = function(t, i)
    if t == 419 then return {material = {reaction_product = {id = kmock.vec{'DRINK_MAT'}}}} end
    return {material = {reaction_product = {id = kmock.vec{}}}}
  end
  for _ = 1, 6 do F.item(W, 'PLANT', {mat_type = 419, mat_index = 1, _pos = {12, 12, 100}}) end
  for _ = 1, 4 do F.item(W, 'PLANT', {mat_type = 1, mat_index = 1, _pos = {12, 12, 100}}) end
  for _ = 1, 3 do F.item(W, 'BARREL', {_pos = {12, 12, 100}}) end
  F.item(W, 'BARREL', {_pos = {12, 12, 100}, _contents = {{id = 1}}})
  local t = text(raw(W, 'items:plants'))
  T.ok(t:find('10 records, 6 looked at', 1, true) and t:find('skipped as not a candidate (no DRINK_MAT): 4', 1, true), t)
  local t2 = text(raw(W, 'items:barrels'))
  T.ok(t2:find('no exclusion (free as DF sees it): 3', 1, true), t2)
  local W2 = world{}
  local strictfl = setmetatable({}, {__index = function(_, k) if k == 'forbid' then return false end error('no flag ' .. k) end})
  F.item(W2, 'WOOD', {flags = strictfl, _pos = {12, 12, 100}})
  local t3 = text(raw(W2, 'items:logs'))
  T.ok(t3:find('fields not readable on this DF', 1, true) and t3:find('in_job=1', 1, true), t3)
end)

-- 4. manager ------------------------------------------------------------------------------------------------------------------------
T.test('NEU3 raw manager: his job, labors on, orders unvalidated, the office, the DF timer is honest about being unread', function()
  local W, _, ord = world{}
  ord.status = {validated = false}
  W.unit(2).status.labors[BREWER] = true
  df.global.plotinfo.main = {fortress_entity = {positions = {own = kmock.vec{{id = 3, code = 'MANAGER', flags = {ACTIVE = true}}},
                             assignments = kmock.vec{{id = 1, position_id = 3, histfig = 5769, histfig2 = 5769}}}}}
  W.unit(2).hist_figure_id = 5769
  W.unit(2)._m.name = 'Domas, Manager'
  local r = raw(W, 'manager')
  T.ok(r.ok, T.show(r))
  local t = text(r)
  T.ok(t:find('manager unit=2', 1, true) and t:find('labors on: BREWER', 1, true), t)
  T.ok(t:find('orders: 1, unvalidated 1', 1, true), t)
  T.ok(t:find('DF manager timer: ? (no such field found)', 1, true), t)
end)

-- 5. the stall line -----------------------------------------------------------------------------------------------------------------
local function econ_days(W, ord, n, inv, from)
  local econ = require('dfllm.economy')
  local p = W.K.persist.get('m.economy')
  p.orders = p.orders or {}
  p.orders['dfllm:drink'] = ord.id
  for i = 1, n do
    local r = {day = true, now = ((from or 100) + i) * DAYT, p = p, inv = inv, days = {drink_d = 40}, cit = 6}
    W.K.census.i = inv
    econ.brew_watch(W.K, W.K.cfg.baseline.economy, r)
  end
  return econ, p
end
local function stall_logs(W)
  local out = {}
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('raw stall brew:', 1, true) then out[#out + 1] = l.msg end end
  return out
end
local I2 = {brew_p = 6978, barrels = 321, barrels_empty = 7, cont_free = 7, pots = 243, pots_empty = 5}

T.test('NEU3 stall line: a brew stall logs ONE raw line per game week with the discriminators; a later week logs again; stall_line=false logs none', function()
  local W, b, ord = world{left = 6}
  b.jobs:insert('#', {id = 9, job_type = df.job_type.CustomReaction, reaction_name = 'BREW_DRINK_FROM_PLANT', flags = {suspend = true}, order_id = ord.id, items = kmock.vec{},
                      job_items = {elements = kmock.vec{}}})
  econ_days(W, ord, 10, I2)
  local l = stall_logs(W)
  T.eq(#l, 1, 'one line in the first game week: ' .. T.show(l))
  T.ok(l[1]:find('orders=1 valid=1 active=1 left=6 pinned=[]', 1, true), l[1])
  T.ok(l[1]:find('jobs=1 susp=1 work=0', 1, true), 'still jobs: ' .. l[1])
  T.ok(l[1]:find('brewers=2 [free=2]', 1, true), 'holders: ' .. l[1])
  T.ok(l[1]:find('census[barrels=321 barrels_empty=7 cont_free=7]', 1, true), 'items part: ' .. l[1])
  local econ = require('dfllm.economy')
  T.eq(econ.stall_log(W.K, 'brew', 'brew'), nil, 'the same game week: no second line')
  df.global.cur_year_tick = df.global.cur_year_tick + 7 * DAYT + 5
  W.run(1)
  T.ok(econ.stall_log(W.K, 'brew', 'brew') ~= nil, 'a game week later: again')
  T.eq(#stall_logs(W), 2)
  local W2, _, ord2 = world{left = 6, diag = {cx_cure = false, mgr_chores = false, still_pin = false, stall_line = false}}
  econ_days(W2, ord2, 10, I2)
  T.eq(#stall_logs(W2), 0)
end)

T.test('NEU3 stall line: an order stall and a build stall carry their raw discriminators; a missing order says nothing', function()
  local W, _, ord = world{left = 6}
  local econ = require('dfllm.economy')
  local l = econ.stall_log(W.K, 'order', ord.id, ord.id)
  T.ok(l and l:find('raw stall order: DF: no cancel reason seen | DF cancel lines seen in window: 0 (source report', 1, true) and l:find(' | order ' .. ord.id, 1, true) and l:find('shop 1 stage 1/1 jobs=0 maxgen=10', 1, true) and l:find('holders=2 [free=2]', 1, true), tostring(l))
  T.eq(econ.stall_log(W.K, 'order', 4242, 4242), nil, 'no such order: no line')
  local b = econ.stall_log(W.K, 'build', '17', {at = '12,12,100', pos = {12, 12, 100}, labor = 'CARPENTER'})
  T.ok(b and b:find('raw stall build: DF: no cancel reason seen | DF cancel lines seen in window: 0', 1, true) and b:find(' | site 12,12,100', 1, true) and b:find('builders=0 []', 1, true), tostring(b))
end)

-- 6. the cures are switches, default off ----------------------------------------------------------------------------------------------
T.test('NEU3/NEU4 default: with no DF reason the container cures stay OFF (no pile freeze, no labor holds, no MakeBarrel tasks, constant reserve), the barrels order of BUG-779 stays', function()
  local W, _, ord = world{left = 32}
  W.act_result('pile_barrels', function() return true, {{id = 41, old = -1, new = 9, name = 'x'}} end)
  F.workshop(W, 'Carpenters')
  for _ = 1, 40 do F.item(W, 'WOOD', {}) end
  W.act_result('labor_set', function() return true, 'enabled' end)
  local I1 = {brew_p = 3472, barrels = 55, barrels_empty = 4, cont_free = 2}
  local _, p = econ_days(W, ord, 8, I1)
  T.eq(#W.find_acts('pile_barrels'), 0, 'no stockpile limit touched')
  T.eq(#W.find_acts('labor_set'), 0, 'no labor switched')
  T.ok(p.contx and p.contx.res == 3, 'BUG-779 reserve 3: ' .. T.show(p.contx))
  p.contx.since = 0
  for _ = 1, 3 do W.run(1200, {skip = 100}); for _ = 1, 40 do W.run(1) end end
  local tasks = 0
  for _, a in ipairs(W.find_acts('ws_task')) do if a.args[2] == 'MakeBarrel' then tasks = tasks + 1 end end
  T.eq(tasks, 0, 'no direct MakeBarrel task')
  local W2, _, ord2 = world{left = 6}
  local _, p2 = econ_days(W2, ord2, 45, I2)
  T.eq(p2.contx, nil, 'no phantom verdict')
end)

T.test('NEU3 switches: economy.diag defaults and a partial section', function()
  local W = world{}
  local econ = require('dfllm.economy')
  T.eq(econ.diag_on(W.K, 'mgr_chores'), false)
  T.eq(econ.diag_on(W.K, 'cx_cure'), true, 'NEU4: on by default, gated by DF reason')
  T.eq(econ.diag_on(W.K, 'still_pin'), false)
  T.eq(econ.diag_on(W.K, 'stall_line'), true)
  local W2 = world{diag = {cx_cure = false}}
  T.eq(require('dfllm.economy').diag_on(W2.K, 'cx_cure'), false)
  T.eq(require('dfllm.economy').diag_on(W2.K, 'mgr_chores'), false)
end)

T.done()
