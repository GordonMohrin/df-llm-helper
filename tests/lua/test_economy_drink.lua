-- economy BUG-042 (Run 11, Kilrudrabed site98, y471 summer d24 - winter d42, kernel b873eb6/0038b55): drink fell from 93
-- to 32 days beside 15 idle stills, 275 plants and 3079 plant growths. The manager's Office zone 18631 (127-129,73-75
-- z141) held no chair and no table, so he validated nothing: 112 of 446 orders waited, the brew orders among them
-- (the kernel's dfllm:drink x10, the game session's x30 + x30), while the 334 older ones were validated and the ratio
-- watch (< 10 % validated) stayed silent. A table and a chair built in the office let him take ManageWorkOrders at
-- once (live confirmed). Now: the office's chair and table are checked and placed, unvalidated orders are watched by
-- age with the reason, the drink line names why nothing brews, fruit is brewed too, and the brews waiting for empty
-- barrels order barrels.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 60 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local OFFICE = {id = 18631, x1 = 127, y1 = 73, x2 = 129, y2 = 75, z = 141}
local BREWER = 3

-- opts: cit (12), drinks (20 = 31 drink days for 12 citizens), plants (plump helmets), fruit (brewable strawberries),
-- leaves (unbrewable growths), office (false: none), chair/table ({x, y} built in the office), barrels {total, empty},
-- still (false: none), orders (extra manager orders), validated (the workorder fake's status), setup
local function world(opts)
  opts = opts or {}
  local ctl = {repairs = {}}
  local cit = opts.cit or 12
  local units = {}
  for i = 1, cit do units[i] = {id = i, citizen = true, name = 'Urist ' .. i} end
  local cfg = F.cfg()
  cfg.economy.standing = false                   -- FR-73's standing orders would be unvalidated orders of their own here
  local W = F.world{cfg = {baseline = cfg}, units = units}
  df.unit_labor = {BREWER = BREWER, [BREWER] = 'BREWER'}
  local ids = {}
  for i = 1, cit do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors = {[BREWER] = opts.brewer ~= false}
    u.mood = -1
  end
  W.set_census('u', F.census_u(ids))
  df.global.plotinfo.main = {fortress_entity = {positions = {
    own = kmock.vec{{id = 3, code = 'MANAGER', flags = {ACTIVE = true}}},
    assignments = kmock.vec{{id = 1, position_id = 3, histfig = 5769, histfig2 = 5769}}}}}
  local mg = W.unit(2)
  mg.hist_figure_id = 5769
  mg._m.name = 'Astesh Shorastthum, Manager'
  F.mat(W, 419, 50, {token = 'PLANT:MUSHROOM_HELMET_PLUMP:STRUCTURAL', flags = {EDIBLE_RAW = true},
                     products = {'DRINK_MAT', 'SEED_MAT'}})
  F.mat(W, 419, 70, {token = 'PLANT:STRAWBERRY:FRUIT', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true},
                     products = {'DRINK_MAT'}})
  F.mat(W, 419, 71, {token = 'PLANT:OAK:LEAF', flags = {}})
  if opts.office ~= false then
    ctl.office = F.building(W, 'ACTIVITY_ZONE', {id = OFFICE.id, type = df.civzone_type.Office, x1 = OFFICE.x1,
                                                 y1 = OFFICE.y1, x2 = OFFICE.x2, y2 = OFFICE.y2, z = OFFICE.z,
                                                 assigned_unit_id = 2})
  end
  -- his bedroom (19235 live) is no office
  F.building(W, 'ACTIVITY_ZONE', {id = 19235, type = df.civzone_type.Bedroom, x1 = 136, y1 = 68, x2 = 138, y2 = 70,
                                  z = 137, assigned_unit_id = 2})
  ctl.at = {}
  function ctl.furniture(kind, x, y, planned)
    local b
    b = F.building(W, kind == 'chair' and 'CHAIR' or 'TABLE', {x1 = x, y1 = y, x2 = x, y2 = y, z = OFFICE.z,
      _planned = planned == true, getMaxBuildStage = function() return 1 end})
    b.getBuildStage = function(self) return self._planned and 0 or 1 end
    ctl.at[x .. ',' .. y .. ',' .. OFFICE.z] = b
    return b
  end
  if opts.chair then ctl.furniture('chair', opts.chair[1], opts.chair[2]) end
  if opts.table then ctl.furniture('table', opts.table[1], opts.table[2]) end
  dfhack.buildings.findAtTile = function(x, y, z)
    if type(x) == 'table' then x, y, z = x.x, x.y, x.z end
    return ctl.at[x .. ',' .. y .. ',' .. z]
  end
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z)
            if x == 127 and y == 73 then return {c = '#', bld = '', dig = ''} end      -- a wall corner of the room
            return {c = '.', bld = '', dig = ''}
          end})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end, pending = function() return 0 end,
          state = function() return {phase = 'P5'} end,
          -- runner.repair: quickfort places the planned buildings, buildingplan waits for the items
          repair = function(K, cells, why)
            ctl.repairs[#ctl.repairs + 1] = {cells = cells, why = why}
            if not opts.no_plan then
              for _, q in ipairs(cells) do ctl.furniture(q[4] == 'c' and 'chair' or 'table', q[1], q[2], true) end
            end
            return true, 'rp' .. #ctl.repairs
          end})
  if opts.still ~= false then for _ = 1, opts.stills or 1 do F.workshop(W, 'Still') end end
  F.workshop(W, 'Carpenters')
  for _ = 1, opts.wood or 0 do F.item(W, 'WOOD', {}) end
  local bt = opts.barrels or {4, 4}
  for i = 1, bt[1] do F.item(W, 'BARREL', i <= bt[2] and {} or {_contents = {{id = 1}}}) end
  ctl.drink = F.item(W, 'DRINK', {stack_size = opts.drinks or 20})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  if (opts.plants or 0) > 0 then F.item(W, 'PLANT', {mat_type = 419, mat_index = 50, stack_size = opts.plants}) end
  if (opts.fruit or 0) > 0 then F.item(W, 'PLANT_GROWTH', {mat_type = 419, mat_index = 70, stack_size = opts.fruit}) end
  if (opts.leaves or 0) > 0 then F.item(W, 'PLANT_GROWTH', {mat_type = 419, mat_index = 71, stack_size = opts.leaves}) end
  for _, o in ipairs(opts.orders or {}) do F.order(W, o) end
  W.act_result('workorder', function(spec)
    local mo = df.global.world.manager_orders
    local id = mo.manager_order_next_id
    mo.manager_order_next_id = id + 1
    mo.all:insert('#', {id = id, job_type = df.job_type[spec.job], reaction_name = spec.reaction or '',
                        amount_left = spec.amount_total, amount_total = spec.amount_total, _spec = spec,
                        item_subtype = -1, mat_type = -1, mat_index = -1,
                        status = {validated = opts.validated == true}})
    return true, id
  end)
  if opts.setup then opts.setup(W, ctl) end
  W.load(fresh('economy'))
  return W, ctl
end

local function orders_of(W, tag)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == tag then r[#r + 1] = a.args[1] end end
  return r
end
local function decisions(W, id)
  local r = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == id then r[#r + 1] = e end end
  return r
end
local function log_has(W, s)
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(s, 1, true) then return true end end
  return false
end

T.test('BUG-042 live replay: an office without chair and table gets them placed; unvalidated orders by age name it; '
       .. 'the drink line says why nothing brews; quiet once they stand', function()
  local W, ctl = world{plants = 40, fruit = 60, leaves = 500, barrels = {16, 12}}
  days(W, 1)
  -- the office: no chair, no table -> both placed on free floor tiles of the zone (127,73 is a wall), side by side
  T.eq(#ctl.repairs, 1)
  local cells = ctl.repairs[1].cells
  T.eq(#cells, 2)
  T.eq({cells[1][4], cells[2][4]}, {'c', 't'})
  T.eq({cells[1][1], cells[1][2], cells[1][3]}, {128, 73, 141}, 'the first free tile of the zone')
  T.ok(math.abs(cells[2][1] - cells[1][1]) <= 1 and math.abs(cells[2][2] - cells[1][2]) <= 1, 'the table beside it')
  T.eq(ctl.repairs[1].why, 'manager office 18631 has no chair, no table')
  local mo = W.find_events('MANAGER_OFFICE')
  T.eq(#mo, 1)
  T.eq({mo[1].d.zone, mo[1].d.chair, mo[1].d.table, mo[1].d.proj}, {18631, 0, 0, 'rp1'})
  T.ok(mo[1].msg:find('manager office 18631 has no chair, no table: chair at 128,73,141, table at', 1, true), mo[1].msg)
  T.ok(log_has(W, 'manager office 18631 has no chair, no table: chair at 128,73,141'), 'one kern.log line')
  -- the brew orders come (plump helmets and fruit), and wait for the manager
  T.eq(#orders_of(W, 'dfllm:drink'), 1, 'plants')
  T.eq(#orders_of(W, 'dfllm:drink_fruit'), 1, 'fruit')
  -- orders.unval_days after they were first seen unvalidated (day 2): DECISION_NEEDED manager_office with the reason
  -- and what was placed
  days(W, 2)
  T.eq(#decisions(W, 'manager_office'), 0, 'one day old')
  days(W, 1)
  local dn = decisions(W, 'manager_office')
  T.eq(#dn, 1)
  T.ok(dn[1].msg:find('manager orders not validated for 2 days', 1, true), dn[1].msg)
  T.ok(dn[1].msg:find('brews among them', 1, true) and dn[1].msg:find('manager office 18631 has no chair, no table', 1,
       true), dn[1].msg)
  T.ok(dn[1].d.q:find('chair at 128,73,141', 1, true) and dn[1].d.q:find('placed', 1, true), dn[1].d.q)
  T.ok(dn[1].d.q:find('not built: no free chair, no table; the kernel adds it as a workshop task', 1, true), dn[1].d.q)
  local s = W.state()
  T.eq(s.orders.mgr, 'manager office 18631 has no chair, no table')
  T.ok(s.orders.unval >= 2 and s.orders.uval_d >= 2, s.orders.unval)
  T.ok(s.stock.dwhy and s.stock.dwhy:find('brews wait for validation: manager office 18631 has no chair', 1, true),
       tostring(s.stock.dwhy))
  -- the orders' reason (inspect orders / ORDER_STUCK) is the office, not their plants or barrels
  local r = W.inbox('inspect', {what = 'orders'})
  T.eq(r.ok, true, r.msg)
  local seen = false
  for _, o in ipairs(r.data.list or {}) do
    if o.why == 'unvalidated: manager office 18631 has no chair, no table' then seen = true end
  end
  T.ok(seen, 'inspect orders names the office')
  -- the drink line: DECISION_NEEDED drink_low (31 days < 60) with the cause and what the kernel did
  local dl = decisions(W, 'drink_low')
  T.ok(#dl >= 1, 'drink_low')
  T.eq(dl[1].d.drink, s.stock.drink_d)
  T.ok(dl[1].msg:find('drink low: ', 1, true), dl[1].msg)
  T.ok(#dl[1].d.q <= 200 and dl[1].d.q:find('auto: ', 1, true), dl[1].d.q)
  W.ms = W.ms + 600 * 1000                                  -- util/cadence: max(7 game days, 10 min)
  days(W, 8)
  dl = decisions(W, 'drink_low')
  local last = dl[#dl]
  T.ok(F.has(last.d.block, 'unvalidated'), 'the unvalidated brews are the blocker')
  T.ok(last.d.q:find('brews wait for validation: manager office 18631', 1, true), last.d.q)
  T.ok(F.has(last.d.auto, 'office') and F.has(last.d.auto, 'brew'), 'office chair placed, brews ordered')
  -- within retry_days nothing is placed again (the repair project waits for a chair and a table)
  T.eq(#ctl.repairs, 1, 'once per retry_days')
  T.eq(#decisions(W, 'manager_office'), 1, 'once per reason')
  T.eq(W.state().orders.mgr, 'manager office 18631 has no chair, no table', 'placed, not built: the same reason')
  -- the chair and the table are built and the manager validates: the check stays quiet
  for _, q in ipairs(cells) do ctl.at[q[1] .. ',' .. q[2] .. ',' .. q[3]]._planned = false end
  for _, o in ipairs(df.global.world.manager_orders.all) do o.status = {validated = true} end
  days(W, 10)
  T.eq(#ctl.repairs, 1, 'nothing placed once they stand')
  T.eq(#W.find_events('MANAGER_OFFICE'), 1)
  T.eq(#decisions(W, 'manager_office'), 1)
  T.ok(log_has(W, 'manager office 18631: chair and table stand'), 'the end is logged')
  s = W.state()
  T.eq({s.orders.mgr, s.orders.unval}, {nil, nil})
  T.ok(not (s.stock.dwhy or ''):find('validation', 1, true), tostring(s.stock.dwhy))
end)

T.test('BUG-042: an office with a chair and a table is left alone; a planned chair waits; no office zone is named',
       function()
  local W, ctl = world{chair = {128, 74}, table = {127, 74}, plants = 40}
  days(W, 5)
  T.eq(#ctl.repairs, 0)
  T.eq(#W.find_events('MANAGER_OFFICE'), 0)
  -- unvalidated orders with a complete office: the manager by name
  local dn = decisions(W, 'manager_office')
  T.eq(#dn, 1)
  T.ok(dn[1].msg:find('manager Astesh validates nothing (his office has a chair and a table)', 1, true), dn[1].msg)
  local W2, ctl2 = world{plants = 40, setup = function(_, c2) c2.furniture('chair', 128, 74, true) end}
  days(W2, 3)
  T.eq(#ctl2.repairs, 1, 'only the table')
  T.eq(ctl2.repairs[1].cells[1][4], 't')
  T.eq(ctl2.repairs[1].why, 'manager office 18631 has no chair, no table', 'the chair is only planned')
  local W3, ctl3 = world{office = false, plants = 40}
  days(W3, 4)
  T.eq(#ctl3.repairs, 0)
  local d3 = decisions(W3, 'manager_office')
  T.eq(#d3, 1)
  T.ok(d3[1].msg:find('no office (chair+table needed)', 1, true), d3[1].msg)          -- BUG-233: was 'no office zone'
  T.ok(d3[1].d.q:find('an Office zone with a chair and a table for him', 1, true), d3[1].d.q)
end)

T.test('BUG-042: validated orders older than the unvalidated ones keep nobody quiet (the ratio rule is gone)', function()
  local old = {}
  for k = 1, 30 do
    old[k] = {id = k, job_type = df and 0 or 0, amount_left = 5, status = {validated = true}}
  end
  local W = world{chair = {128, 74}, table = {127, 74}, plants = 40, orders = old, drinks = 2000}
  days(W, 3)
  T.eq(#decisions(W, 'manager_office'), 0, 'nothing unvalidated: quiet')
  F.order(W, {job_type = df.job_type.ConstructTable, amount_left = 2, status = {validated = false}})
  days(W, 1)
  T.eq(#decisions(W, 'manager_office'), 0, 'one day old')
  days(W, 2)
  T.eq(#decisions(W, 'manager_office'), 1, '1 of 31 unvalidated for 2 days: asked (0038b55: 30 of 31 validated, silent)')
end)

T.test('BUG-042: fruit is brewed (BREW_DRINK_FROM_PLANT_GROWTH); the deficit is split by stock; a removed order comes '
       .. 'back', function()
  local W = world{fruit = 200, leaves = 500, validated = true, chair = {128, 74}, table = {127, 74}}
  days(W, 1)
  T.eq(#orders_of(W, 'dfllm:drink'), 0, 'no brewable plant: no plant order')
  local fr = orders_of(W, 'dfllm:drink_fruit')
  T.eq(#fr, 1)
  T.eq({fr[1].job, fr[1].reaction, fr[1].frequency}, {'CustomReaction', 'BREW_DRINK_FROM_PLANT_GROWTH', 'OneTime'})
  T.eq(fr[1].item_conditions[1], {condition = 'AtLeast', flags = {'unrotten'}, item_type = 'PLANT_GROWTH',
                                  reaction_product = 'DRINK_MAT', value = 2})
  T.eq(fr[1].item_conditions[2], {condition = 'AtLeast', flags = {'empty', 'food_storage'}, value = 1})
  T.eq(W.K.census.i.brew_g, 200, 'the leaves are no brew input')
  -- DF removes a finished one-time order: the next run orders again
  local all = df.global.world.manager_orders.all
  for i = #all - 1, 0, -1 do all:erase(i) end
  days(W, 1)
  T.eq(#orders_of(W, 'dfllm:drink_fruit'), 2, 'ordered again')
  T.ok(log_has(W, 'order dfllm:drink_fruit x'), 'kern.log line per order')
  -- plump helmets (always brewable) and fruit: the jobs split by their stock
  local W2 = world{plants = 30, fruit = 90, validated = true, chair = {128, 74}, table = {127, 74}}
  days(W2, 1)
  local p2, f2 = orders_of(W2, 'dfllm:drink')[1], orders_of(W2, 'dfllm:drink_fruit')[1]
  T.ok(p2 and f2, 'both')
  T.ok(f2.amount_total >= 2 * p2.amount_total, string.format('%d plant, %d fruit jobs', p2.amount_total,
                                                             f2.amount_total))
  T.eq(p2.reaction, 'BREW_DRINK_FROM_PLANT')
  T.eq({W2.K.census.i.brew_p, W2.K.census.i.brew_g}, {30, 90})
end)

T.test('BUG-042: brews waiting for empty barrels order barrels past grow_total (60 brews, 12 of 85 empty)', function()
  local brews = {{reaction_name = 'BREW_DRINK_FROM_PLANT', job_type = 0, amount_left = 30, status = {validated = true}},
                 {reaction_name = 'BREW_DRINK_FROM_PLANT_GROWTH', job_type = 0, amount_left = 30,
                  status = {validated = true}}}
  local W = world{plants = 300, fruit = 3000, barrels = {85, 12}, wood = 300, orders = brews, validated = true,
                  chair = {128, 74}, table = {127, 74}}
  days(W, 1)
  local b = orders_of(W, 'dfllm:barrel')
  T.eq(#b, 1, 'barrels for the waiting brews (0038b55: 12 empty >= min_empty 4, 85 > grow_total 80: none)')
  T.eq({b[1].job, b[1].amount_total}, {'MakeBarrel', 4}, 'max_jobs a run')
  T.ok(log_has(W, 'brews wait, 12 of 85 barrels empty'), 'logged')
  -- drink above the target: no barrels for brews
  local W2 = world{plants = 300, barrels = {85, 12}, wood = 300, orders = brews, validated = true, drinks = 4000,
                   chair = {128, 74}, table = {127, 74}}
  days(W2, 1)
  T.eq(#orders_of(W2, 'dfllm:barrel'), 0)
end)

T.test('BUG-042: drink_low below 60 days names the blockers once per episode (no still, no plants, nobody brews)',
       function()
  local W, ctl = world{still = false, brewer = false, barrels = {4, 0}, chair = {128, 74}, table = {127, 74},
                       validated = true}
  days(W, 1)
  local dl = decisions(W, 'drink_low')
  T.eq(#dl, 1)
  T.eq(dl[1].d.block, {'still', 'brew', 'plants', 'barrels', 'brewer'}, 'the first run: no brew order yet either')
  T.ok(dl[1].msg:find('drink low: 31 drink days (thirst alarm below 10): no still', 1, true), dl[1].msg)
  T.eq(W.state().stock.dwhy, 'no still')
  days(W, 3)
  T.eq(#decisions(W, 'drink_low'), 1, 'no news: once')
  ctl.drink.stack_size = 4000
  days(W, 1)
  T.ok(log_has(W, 'drink pre-alarm over'), 'over')
  T.eq(W.state().stock.dwhy, nil)
end)

T.test('BUG-204 (live Earthboat): no free Office zone is a state said in kern.log once per 7 days and 10 min, not a ' ..
       'daily act that fails (ACT_FAIL x39); a free zone is assigned by the act as before', function()
  local function mk(office)
    return world{office = office, setup = function(W)
      dfhack.units.getUnitByNobleRole = function(role) if role == 'manager' then return W.unit(2) end end
      if office == 'free' then
        F.building(W, 'ACTIVITY_ZONE', {id = 18632, type = df.civzone_type.Office, x1 = 1, y1 = 1, x2 = 3, y2 = 3,
                                        z = 141, assigned_unit_id = -1})
      end
    end}
  end
  local W = mk(false)
  days(W, 20)
  T.eq(#W.find_acts('manager_office'), 0, 'live: tried daily, ACT_FAIL every 4-10 game days')
  local n = 0
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('manager office: no free office zone', 1, true) then n = n + 1 end end
  T.eq(n, 1, 'once while the wall clock holds')
  W.ms = W.ms + 700 * 1000
  days(W, 8)
  n = 0
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('manager office: no free office zone', 1, true) then n = n + 1 end end
  T.eq(n, 2, 'again after 7 days and 10 min')
  local W2 = mk('free')
  days(W2, 2)
  T.ok(#W2.find_acts('manager_office') >= 1, 'a free zone: the act assigns it')
  dfhack.units.getUnitByNobleRole = nil
end)

T.test('BUG-206 (live Earthboat spr d43): no still but a pending fortcore stage 1 builds one: drink_low above the ' ..
       'thirst alarm is a kern.log note, no DECISION_NEEDED; without the project the question as before', function()
  local W = world{still = false, barrels = {4, 0}, chair = {128, 74}, table = {127, 74}, validated = true,
                  setup = function(W)
    W.K.persist.set('projects', {v = 2, list = {{id = 'fc1', tpl = 'fortcore', stage = 1, pct = 34, blocked = '',
                                                 done = 0}}})
    W.K.persist.set('bp.fc1', {v = 2, tpl = 'fortcore', params = {stage = 1},
                               manifest = {v = 2, workshops = {{type = 'Still', pos = {6, 46, 100}}}}})
  end}
  days(W, 2)
  T.eq(#decisions(W, 'drink_low'), 0, 'live: DECISION_NEEDED drink_low "no still; auto: brew" (A)')
  T.ok(log_has(W, 'no still yet: project fc1 builds one'), 'the note')
  T.eq(W.state().stock.dwhy, 'no still', 'status still says why')
  -- review: the note does not use up the episode's question; the project gone (cancelled), the question comes at once
  W.K.persist.set('projects', {v = 2, list = {}})
  days(W, 1)
  T.eq(#decisions(W, 'drink_low'), 1, 'no project builds the Still any more: the question as before')
end)

T.done()
