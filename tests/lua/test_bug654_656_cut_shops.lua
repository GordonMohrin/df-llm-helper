-- BUG-654 (Run 16a i1 Basementflew y459-y466: meals 0 beside 3,323 food days, `inspect workload` 'unreachable PrepareMeal x1'; the fort's only Kitchen,
-- Carpenters, Masons and Mechanics stood in the flooded level z117, on a walk group no citizen is on): a workshop type whose every shop stands off the
-- citizens' walk groups for 3 days in PEACE is counted as missing (f['cut:<Type>']), told (ORDER_STUCK kind workshop) and asked for again
-- (PROJECT_REQUEST workshops why=cut); a shop of the type on the citizens' walk group ends it.
-- BUG-655 (the hospital's 'missing b x4'): economy.piece_supply names what the supply of a missing piece lacks; the runner calls a 'b' cell a bed.
local T = require('testlib')
local F = require('wp8_world')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

-- walk groups by x: 0..60 the fort (group 7), 100+ a flooded level (group 9), the rest no walkable tile
local function group_at(x) return x <= 60 and 7 or (x >= 100 and 9 or 0) end
local SNAP = {name = 'snapshot', every = {ticks = 1200},
              groups = function(_K, pts)
                local out = {}
                for i, p in ipairs(pts) do out[i] = group_at(p.x or p[1]) end
                return out
              end,
              home_set = function(_K, ids)
                local set = {}
                for _, g in ipairs(ids) do if g > 0 then set[g] = true end end
                return set
              end}

local function shop(W, name, x, y, z)
  local sub = df.workshop_type[name]
  return F.building(W, 'WORKSHOP_ANY', {type = sub, getType = function() return df.building_type.Workshop end,
                                        getSubtype = function() return sub end,
                                        x1 = x - 1, x2 = x + 1, y1 = y - 1, y2 = y + 1, z = z or 5})
end

local function world(o)
  o = o or {}
  local cit = o.cit or 12
  local units, ids = {}, {}
  for i = 1, cit do units[i] = {id = i, citizen = true, pos = {10 + i, 20, 5}}; ids[i] = i end
  local cfg = F.cfg()
  cfg.economy.orders_per_day = 20
  local W = F.world{cfg = {baseline = cfg}, units = units}
  for i = 1, cit do W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  df.unit_labor = {COOK = 5, [5] = 'COOK', PLANT = 1, [1] = 'PLANT'}
  df.job_skill = df.job_skill or {}
  F.mat(W, 419, 53, {token = 'PLANT:PEACH:FRUIT', flags = {EDIBLE_RAW = true, EDIBLE_COOKED = true}})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P3'} end})
  if o.snapshot ~= false then W.load(SNAP) end
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  if (o.growth or 0) > 0 then F.item(W, 'PLANT_GROWTH', {stack_size = o.growth, mat_type = 419, mat_index = 53}) end
  for i = 1, cit do
    W.unit(i).counters2 = {thirst_timer = 0, hunger_timer = i <= (o.hungry or 0) and 60000 or 1000}
  end
  return W
end
local function econ(W)
  local E = fresh('economy')
  W.load(E)
  return E
end
local function requests(W, why)
  local n, last = 0, nil
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.why == why then n, last = n + 1, e end end
  return n, last
end
local function cut_events(W)
  local out = {}
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do
    if e.d.kind == 'workshop' and tostring(e.msg):find('no way for the citizens', 1, true) then out[#out + 1] = e end
  end
  return out
end
local function setup(o)
  local W = world(o)
  for i = 1, (o.cit or 12) do
    local u = W.unit(i)
    u.status.labors, u.mood, u.military = {}, -1, {squad_id = -1}
  end
  return W
end

T.test('BUG-654 Basementflew: the only Kitchen on a walk group no citizen is on: after 3 days it is cut off, told once and a new one is asked for (why=cut)', function()
  local W = setup{growth = 200, hungry = 2}
  shop(W, 'Kitchen', 120, 20)
  econ(W)
  days(W, 2)
  T.eq(#cut_events(W), 0, 'two days: not yet (a flooded corner may dry)')
  days(W, 4)
  local ev = cut_events(W)
  T.eq(#ev, 1, 'told once')
  T.eq({ev[1].d.job, ev[1].d.kind, ev[1].d.n}, {'Kitchen', 'workshop', 1})
  T.ok(ev[1].msg:find('Kitchen at 120,20,5 (walk group 9, the citizens on 7)', 1, true), ev[1].msg)
  local n, req = requests(W, 'cut')
  T.ok(n >= 1, 'PROJECT_REQUEST why=cut')
  T.eq({req.d.tpl, req.d.types}, {'workshops', {'Kitchen'}})
  local p = W.K.persist.get('m.economy')
  T.ok(p.cutws and p.cutws.Kitchen and p.cutws.Kitchen.grp == 9, 'persisted for the facts')
end)

T.test('BUG-654: the food decision names the cut-off kitchen, not "no kitchen" or "raw food is not cooked"; meal orders are not remade at a kitchen nobody reaches', function()
  local W = setup{growth = 400, hungry = 4}
  shop(W, 'Kitchen', 120, 20)
  econ(W)
  days(W, 10)
  local said
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do
    if (e.d.id == 'famine' or e.d.id == 'food_low') and tostring(e.msg):find('Kitchen', 1, true) then said = e end
  end
  for _, g in ipairs(W.logs) do if tostring(g.msg):find('kitchen cut off', 1, true) or tostring(g.msg):find('cut off (Kitchen', 1, true) then said = said or g end end
  T.ok(said, 'a decision or a kern.log line names the cut-off kitchen')
  for _, e in ipairs(W.find_events('ORDER_STUCK')) do
    T.ok(not tostring(e.msg):find('cooking stalled', 1, true), 'no stall watch for a shop that does not count: ' .. tostring(e.msg))
  end
end)

T.test('BUG-654: a Kitchen on the citizens\' walk group is no cut; a second one there ends the cut of the first', function()
  local W = setup{growth = 200}
  shop(W, 'Kitchen', 20, 20)
  econ(W)
  days(W, 6)
  T.eq(#cut_events(W), 0)
  T.eq(requests(W, 'cut'), 0)
  local W2 = setup{growth = 200}
  shop(W2, 'Kitchen', 120, 20)
  econ(W2)
  days(W2, 6)
  T.eq(#cut_events(W2), 1)
  shop(W2, 'Kitchen', 30, 20)
  days(W2, 3)
  local p = W2.K.persist.get('m.economy')
  T.eq(p.cutws, nil, 'a Kitchen on the citizens\' group again: nothing is cut off')
  local before = requests(W2, 'cut')
  days(W2, 20)
  T.eq(requests(W2, 'cut'), before, 'no more requests')
end)

T.test('BUG-654: a shop with no walkable tile read round it (a walled-in one) is unknown, not cut; no walk-group module: nothing judged', function()
  local W = setup{growth = 200}
  shop(W, 'Kitchen', 80, 20)                 -- x 79..81 and its ring: group 0 (no walkable tile)
  econ(W)
  days(W, 8)
  T.eq(#cut_events(W), 0)
  local W2 = setup{growth = 200, snapshot = false}
  shop(W2, 'Kitchen', 120, 20)
  econ(W2)
  days(W2, 8)
  T.eq(#cut_events(W2), 0, 'without the snapshot module the groups cannot be read')
end)

T.test('BUG-654: Carpenters, Masons and Mechanics cut off with the Kitchen: one request lists the types the template places; inspect workload names them', function()
  local W = setup{growth = 200}
  for i, n in ipairs({'Kitchen', 'Carpenters', 'Masons', 'Mechanics'}) do shop(W, n, 120 + 4 * i, 20) end
  shop(W, 'Still', 20, 20)
  local E = econ(W)
  days(W, 6)
  local _, req = requests(W, 'cut')
  T.ok(req, 'asked')
  T.eq(req.d.types, {'Carpenters', 'Kitchen', 'Masons', 'Mechanics'})
  local r = W.inbox('inspect', {what = 'workload'})
  local okv, msg, data = r.ok, r.msg, r.data
  T.ok(okv, tostring(msg))
  T.ok(tostring(msg):find('workshops cut off: ', 1, true), msg)
  T.eq(#data.shops_cut, 4)
  T.eq(data.shops_cut[1].grp, 9)
end)

T.test('BUG-655 Basementflew: economy.piece_supply says what lacks for 4 missing beds: no order, no Carpenters, cut off, no logs', function()
  local W = setup{growth = 10}
  shop(W, 'Carpenters', 20, 20)
  local E = econ(W)
  for _ = 1, 30 do F.item(W, 'WOOD', {stack_size = 10}) end
  days(W, 2)
  local txt, cmd, code = E.piece_supply(W.K, 'bed', 4)
  T.eq(code, 'no_order', tostring(txt))
  T.ok(txt:find('bed x4: ConstructBed x0 open, Carpenters stands', 1, true), txt)
  T.eq(cmd, [[dfllm cmd order.add '{"job":"ConstructBed","amount":4}']])
  F.order(W, {job_type = df.job_type.ConstructBed, amount_left = 4, amount_total = 4})
  local txt2, cmd2, code2 = E.piece_supply(W.K, 'bed', 4)
  T.eq({code2, cmd2}, {'ordered', nil}, tostring(txt2))
  local few = setup{growth = 10}
  shop(few, 'Carpenters', 20, 20)
  local Ef = econ(few)
  F.item(few, 'WOOD', {stack_size = 2})
  days(few, 2)
  local _, cmd3, code3 = Ef.piece_supply(few.K, 'bed', 4)
  T.eq(code3, 'no_logs')
  T.eq(cmd3, [[dfllm cmd trade.want '{"add":["wood"]}']])
  -- the Carpenters stands where no citizen goes
  local W2 = setup{growth = 10}
  shop(W2, 'Carpenters', 120, 20)
  local E2 = econ(W2)
  for _ = 1, 30 do F.item(W2, 'WOOD', {stack_size = 10}) end
  days(W2, 6)
  local t4, c4, code4 = E2.piece_supply(W2.K, 'bed', 4)
  T.eq(code4, 'cut', tostring(t4))
  T.ok(t4:find('Carpenters cut off (Carpenters at 120,20,5', 1, true), t4)
  T.eq(c4, [[dfllm cmd bp.place '{"tpl":"workshops","site":"S1","p":{"only":"Carpenters"}}']])
  local W3 = setup{growth = 10}
  local E3 = econ(W3)
  days(W3, 1)
  local _, c5, code5 = E3.piece_supply(W3.K, 'bed', 2)
  T.eq(code5, 'no_shop')
  T.eq(c5, [[dfllm cmd bp.place '{"tpl":"workshops","site":"S1","p":{"only":"Carpenters"}}']])
end)

T.done()
