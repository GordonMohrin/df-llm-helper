-- care's coffin provisioner (FR-61, Run 9: 25 unburied, 0 free coffins, soft stone): the trigger (free usable coffins
-- < bodies without a tomb + coffin_reserve), the space search (free roofed floor outside zones and buildings, the
-- citizens' walk group, away from the entrances), rows of coffins with aisles inside a free ring placed through the
-- real runner (runner.coffins: build + 1x1 tomb zones), ConstructCoffin orders in a material the fort can use, the
-- no-space and no-material alarms, and what state and inspect what=tombs show.
local T = require('testlib')
local CW = require('care_world')
local F = CW.F
local kmock = require('dfllm.util.k_mock')
local json = require('dfllm.util.json')

local function key(x, y, z) return x .. ',' .. y .. ',' .. z end

-- floor rectangles {x0, y0, x1, y1, z} in rock
local function floor_of(rects)
  local floor = {}
  for _, r in ipairs(rects) do
    for y = r[2], r[4] do for x = r[1], r[3] do floor[key(x, y, r[5])] = true end end
  end
  return floor
end

local function corpse(W, uid, pos)
  return F.item(W, 'ANY_CORPSE', {unit_id = uid, _pos = pos or {22, 22, 5}})
end

local function dead(W, id)
  W.kill(id)
  W.event('UNIT_DEATH', {unit = id})
end

-- the real workorder fills the material fields: 'INORGANIC' = any rock (mat_type 0), material_category wood
local function workorders(W)
  W.act_result('workorder', function(spec)
    local mo = df.global.world.manager_orders
    local id = mo.manager_order_next_id
    mo.manager_order_next_id = id + 1
    local o = {id = id, job_type = df.job_type[spec.job], amount_left = spec.amount_total,
               amount_total = spec.amount_total, mat_type = spec.material == 'INORGANIC' and 0 or -1, mat_index = -1}
    if spec.material_category then
      o.material_category = {}
      for _, m in ipairs(spec.material_category) do o.material_category[m] = true end
    end
    mo.all:insert('#', o)
    return true, id
  end)
end

-- quickfort as the game answers the runner's coffin project: build 'n' places an unbuilt coffin, zone 'T' a tomb zone
local function quickfort(W)
  W.qf = {}
  df.global.building_next_id = #df.global.world.buildings.all + 1
  W.act_result('quickfort', function(p)
    W.qf[#W.qf + 1] = {mode = p.mode, command = p.command or 'run', pos = p.pos, data = p.data}
    if (p.command or 'run') ~= 'run' then return true, {} end
    for dz, g in pairs(p.data) do
      for dy, row in pairs(g) do
        for dx, text in pairs(row) do
          local x, y, z = p.pos[1] + dx, p.pos[2] + dy, p.pos[3] + dz
          local k = text:match('^[^{(:/]*')
          if p.mode == 'build' and k == 'n' then
            local b = F.building(W, 'COFFIN', {x1 = x, y1 = y, x2 = x, y2 = y, z = z, _st = 0})
            b.relations = kmock.vec{}
            b.getBuildStage = function(self) return self._st end
            b.getMaxBuildStage = function() return 1 end
            b.getType = function() return df.building_type.Coffin end
            df.global.building_next_id = b.id + 1
          elseif p.mode == 'zone' and k == 'T' then
            CW.tomb(W, x, y, z, {coffin = false})
            W.civzones_at[key(x, y, z)] = {{type = df.civzone_type.Tomb}}
            for _, b in ipairs(df.global.world.buildings.other.COFFIN) do    -- DF links the coffin to its zone
              if b.x1 == x and b.y1 == y and b.z == z then b.relations = kmock.vec{{type = df.civzone_type.Tomb}} end
            end
            df.global.building_next_id = #df.global.world.buildings.all + 1
          end
        end
      end
    end
    return true, {}
  end)
end

-- o: floor (rects), outside / far (sets of 'x,y,z'), ents (seal entrances), runner (false: a fake with pending only),
--    pending, census_i, mode, cit, care (config overrides), setup(W)
local function world(o)
  o = o or {}
  local floor = floor_of(o.floor or {{20, 20, 29, 29, 5}})
  local W, Cm = CW.world{
    cit = o.cit or 6, mode = o.mode, census_i = o.census_i or {rock = 50, wood = 40},
    runner = o.runner ~= false, pending = o.runner == false and (o.pending or {}) or nil,
    tile = function(x, y, z)
      return {c = floor[key(x, y, z)] and '.' or '#', dig = '', bld = ''}
    end,
    snap = {
      outside_near = function(K, pts, r)
        local out = {}
        for i, p in ipairs(pts) do out[i] = (o.outside or {})[key(p[1], p[2], p[3])] and 1 or 0 end
        return out
      end,
      far = function(K, x, y, z) return (o.far or {})[key(x, y, z)] == true end,
    },
    setup = function(W)
      df.civzone_type.Bedroom, df.civzone_type[20] = 20, 'Bedroom'
      df.job_type.PlaceItemInTomb, df.job_type[90] = 90, 'PlaceItemInTomb'
      CW.tomb_acts(W)
      workorders(W)
      quickfort(W)
      if o.ents then W.load{name = 'seal', every = {ticks = 100000}, entrances = function() return o.ents, 25 end} end
      if o.masons ~= false then F.workshop(W, 'Masons') end
      if o.carpenters then F.workshop(W, 'Carpenters') end
      if o.setup then o.setup(W) end
      df.global.building_next_id = #df.global.world.buildings.all + 1
    end}
  W.K.cfg.baseline.care = o.care
  return W, Cm
end

local function done(W, id)
  for _, P in ipairs((W.K.persist.get('projects') or {}).list or {}) do if P.id == id then return P.done == 1 end end
end

local function project(W)
  for _, P in ipairs((W.K.persist.get('projects') or {}).list or {}) do
    if P.tpl == 'tombs' then return P, W.K.persist.get('bp.' .. P.id) end
  end
end

-- absolute {x, y, z, text} cells of one stage of a project document
local function cells(d, si)
  local out = {}
  for _, ch in ipairs(d.stages[si].chunks) do
    for _, c in ipairs(ch.cells) do out[#out + 1] = {ch.pos[1] + c[1], ch.pos[2] + c[2], ch.pos[3] + c[3], c[4]} end
  end
  table.sort(out, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
  return out
end

local function coffin_orders(W)
  local r = {}
  for _, a in ipairs(W.find_acts('workorder')) do
    local s = a.args[1]
    if s.job == 'ConstructCoffin' then
      r[#r + 1] = {s.amount_total, s.material or table.concat(s.material_category or {}, ','), s.tag}
    end
  end
  return r
end

local function events(W, t, id)
  local r = {}
  for _, e in ipairs(W.find_events(t)) do
    if id == nil or (e.d.id == id or e.d.tpl == id) then r[#r + 1] = e end
  end
  return r
end

---------------------------------------------------------------- capacity
T.test('capacity: an aisle every third line inside a free ring; the better orientation', function()
  local Cm = CW.fresh('care')
  T.eq({Cm.coffin_capacity(4, 4)}, {2, 'x'})
  T.eq({Cm.coffin_capacity(5, 5)}, {6, 'x'})
  T.eq({Cm.coffin_capacity(6, 7)}, {15, 'x'}, '4 inner columns: coffin, aisle, coffin, coffin')
  T.eq({Cm.coffin_capacity(4, 7)}, {6, 'y'})
  T.eq({Cm.coffin_capacity(3, 3)}, {1, 'x'})
  T.eq({Cm.coffin_capacity(2, 9)}, {0, 'x'})
end)

---------------------------------------------------------------- placement
T.test('FR-61: 3 unburied + reserve 10, 0 free: 13 coffins in the free hall (smallest fit, nearest corner), ring free', function()
  local W = world{setup = function(W)
    for _, id in ipairs({4, 5, 6}) do dead(W, id); corpse(W, id) end
  end}
  W.run(120)
  local P, d = project(W)
  T.ok(P, 'a tombs project')
  T.eq({P.tpl, P.class, P.prio, P.site, #d.stages, d.stages[1].mode, d.stages[1].orders, d.stages[2].mode},
       {'tombs', 'living', 3, 'care', 2, 'build', 0, 'zone'})
  local got = {}
  for _, c in ipairs(cells(d, 1)) do got[#got + 1] = key(c[1], c[2], c[3]) .. ' ' .. c[4] end
  -- core seed 25,25,5: the 10x10 hall 20..29 holds 13 in 6x7, placed nearest the seed (x 24..29, y 22..28); inner
  -- columns 25, 27, 28 (26 is the aisle), the ring x 24/29, y 22/28 stays free
  T.eq(got, {'25,23,5 n', '27,23,5 n', '28,23,5 n', '25,24,5 n', '27,24,5 n', '28,24,5 n', '25,25,5 n', '27,25,5 n',
             '28,25,5 n', '25,26,5 n', '27,26,5 n', '28,26,5 n', '25,27,5 n'})
  local zones = cells(d, 2)
  T.eq(#zones, 13)
  T.eq(zones[1][4], 'T(1x1)')
  T.eq(coffin_orders(W), {{13, 'INORGANIC', 'dfllm:coffin'}}, 'hard stone and a mason: rock')
  local tombs_req = 0
  for _, e in ipairs(W.find_events('PROJECT_REQUEST')) do if e.d.tpl == 'tombs' then tombs_req = tombs_req + 1 end end
  T.eq(tombs_req, 0, 'the provisioner owns the tombs request: nothing for follow')
  local s = W.state().care.coffins
  T.eq({s.want, s.short, s.stock, s.order, s.proj}, {13, 13, 0, 13, P.id})
  local r = W.inbox('inspect', {what = 'tombs'})
  T.ok(r.ok and r.msg:find('coffins want 13, short 13, stock 0, on order 13, project ' .. P.id, 1, true), r.msg)
  T.eq({r.data.prov.want, r.data.prov.bodies, r.data.prov.open, r.data.prov.found, r.data.prov.site},
       {13, 3, 3, 13, '6x7 at 24,22,5'})
  T.ok(#json.encode(r.data) < 8192)
  T.eq(W.bad_vectors, {})
end)

T.test('FR-61: the project builds and zones the coffins, the dead get them; no second project, no second order', function()
  local W = world{setup = function(W)
    for _, id in ipairs({4, 5, 6}) do dead(W, id); corpse(W, id) end
  end}
  W.run(120)
  local P = project(W)
  CW.day(W)
  T.eq(#W.find_acts('quickfort') > 0, true)
  local built = 0
  for _, b in ipairs(df.global.world.buildings.other.COFFIN) do if b._st == 0 then built = built + 1 end end
  T.eq(built, 13, 'the runner placed 13 planned coffins')
  T.eq(#coffin_orders(W), 1, 'the planned coffins are covered by the open order')
  local nproj = 0
  for _, Q in ipairs(W.K.persist.get('projects').list) do if Q.tpl == 'tombs' then nproj = nproj + 1 end end
  T.eq(nproj, 1)
  -- masons make and set the coffins; the order is done
  for _, b in ipairs(df.global.world.buildings.other.COFFIN) do b._st = 1 end
  df.global.world.manager_orders.all[0].amount_left = 0
  CW.day(W, 3)
  T.eq(done(W, P.id), true)
  local s = W.state()
  T.eq(s.care.tombs_free, 10, '13 tombs, three assigned to the dead')
  T.eq({s.care.coffins.want, s.care.coffins.short, s.care.coffins.order}, {10, 0, 0})
  T.eq(#coffin_orders(W), 1)
  nproj = 0
  for _, Q in ipairs(W.K.persist.get('projects').list) do if Q.tpl == 'tombs' then nproj = nproj + 1 end end
  T.eq(nproj, 1)
  local ent = {}
  for _, line in ipairs(F.runs(W)) do
    local u = line:match('^entomb %-%-unit (%d+)')
    if u then ent[u] = true end
  end
  T.eq(ent, {['4'] = true, ['5'] = true, ['6'] = true}, 'each dead citizen is entombed into a new coffin')
  T.eq(#CW.tacts(W, 'assign'), 3)
end)

T.test('FR-61: zones, stockpiles, furniture and open sky are no space; a second hall takes the rest', function()
  local W = world{floor = {{20, 20, 29, 29, 5}, {34, 20, 38, 24, 5}},
                  outside = {['29,20,5'] = true},
                  setup = function(W)
    for _, id in ipairs({4, 5, 6}) do dead(W, id); corpse(W, id) end
    local bed = F.building(W, 'ANY_ZONE', {x1 = 20, y1 = 20, x2 = 22, y2 = 29, z = 5, type = df.civzone_type.Bedroom})
    df.global.world.buildings.other.ZONE_BEDROOM:insert('#', bed)
    F.building(W, 'STOCKPILE', {x1 = 23, y1 = 26, x2 = 29, y2 = 29, z = 5})
    F.building(W, 'IN_PLAY', {x1 = 26, y1 = 20, x2 = 26, y2 = 20, z = 5})      -- a statue in the hall
  end, care = {coffin_reserve = 17}}
  W.run(200)
  local P, d = project(W)
  T.ok(P, 'a project')
  local main, other = 0, 0
  for _, c in ipairs(cells(d, 1)) do
    T.ok(c[1] >= 23 and c[3] == 5, 'never in the bedroom zone: ' .. key(c[1], c[2], c[3]))
    T.ok(not (c[1] >= 23 and c[1] <= 29 and c[2] >= 26), 'never on the stockpile: ' .. key(c[1], c[2], c[3]))
    if c[1] <= 29 then main = main + 1 else other = other + 1 end
  end
  -- the free part of the first hall: x 23..29 y 21..25 (row 20 has the statue and open sky); 7x5 holds 10 in two
  -- rows along x (aisle y 23)
  T.eq({main, other}, {10, 6}, 'the second hall (5x5) takes 6; 20 wanted, 16 fit, the rest is asked for')
  local req = events(W, 'PROJECT_REQUEST', 'tombs')
  T.eq(#req, 1)
  T.eq({req[1].d.n, req[1].d.why}, {4, 'no_space'})
  T.ok(req[1].msg:find('dig a tombs room', 1, true), req[1].msg)
end)

T.test('FR-61: a hall near an entrance or on another walk group is no space: PROJECT_REQUEST, later DECISION_NEEDED', function()
  local function scene(o)
    o.setup = function(W) for _, id in ipairs({4, 5, 6}) do dead(W, id); corpse(W, id) end end
    local W = world(o)
    W.run(300)
    return W
  end
  local W1 = scene{ents = {{27, 31, 5}}, care = {coffin_retry = 1200}}    -- within 10 of every hall tile
  T.eq(project(W1), nil)
  local r1 = events(W1, 'PROJECT_REQUEST', 'tombs')
  T.eq(#r1, 1)
  T.eq({r1[1].d.n, r1[1].d.why}, {13, 'no_space'})
  local far = {}
  for y = 20, 29 do for x = 20, 29 do far[key(x, y, 5)] = true end end
  local W2 = scene{far = far}
  T.eq(project(W2), nil, 'the hall lies on another walk group')
  T.eq(#events(W2, 'PROJECT_REQUEST', 'tombs'), 1)
  local W3 = scene{outside = far}
  T.eq(project(W3), nil, 'open sky: no hall')
  -- unresolved for coffin_wake: DECISION_NEEDED coffin_space (A), weekly
  W1.run(2500)
  local dn = events(W1, 'DECISION_NEEDED', 'coffin_space')
  T.eq(#dn, 1)
  T.eq(dn[1].cls, 'A')
  T.ok(dn[1].d.q:find('dig a tombs room', 1, true) and dn[1].d.q:find('13 short', 1, true), dn[1].d.q)
  W1.run(2400)
  T.eq(#events(W1, 'DECISION_NEEDED', 'coffin_space'), 1, 'weekly')
  T.eq(#events(W1, 'PROJECT_REQUEST', 'tombs'), 2, 'asked again after tomb_request_every')
  local v = W1.inbox('inspect', {what = 'tombs'})
  T.ok(v.msg:find('no space', 1, true), v.msg)
end)

T.test('FR-61: no rock at all near the seeds: the search ends, says where it looked, retries after coffin_retry', function()
  local W = world{floor = {}, care = {coffin_retry = 2400}, setup = function(W) dead(W, 4); corpse(W, 4) end}
  W.run(400)
  local req = events(W, 'PROJECT_REQUEST', 'tombs')
  T.eq(#req, 1)
  T.ok(req[1].msg:find('core 25,25,5', 1, true) and req[1].msg:find('citizens 5,5,5', 1, true), req[1].msg)
  local probes = W.inbox('inspect', {what = 'tombs'}).data.prov.probes
  T.eq(probes, 6 * 33 * 33, 'two seeds, three levels each')
  W.run(1000)
  T.eq(W.inbox('inspect', {what = 'tombs'}).data.prov.probes, nil, 'no search before coffin_retry')
  W.run(3000)
  T.eq(W.inbox('inspect', {what = 'tombs'}).data.prov.probes, 6 * 33 * 33, 'searched again')
end)

---------------------------------------------------------------- material
local function planned(W, n)
  for i = 1, n do
    local b = F.building(W, 'COFFIN', {x1 = 40 + i, y1 = 40, x2 = 40 + i, y2 = 40, z = 5})
    b.relations = kmock.vec{}
    b.getBuildStage = function() return 0 end
    b.getMaxBuildStage = function() return 1 end
  end
end

T.test('FR-61 material: hard stone with a mason -> rock; soft stone only -> wood beyond the keep; neither -> DECISION', function()
  local function scene(o)
    o.runner = false
    local setup = o.setup
    o.setup = function(W) planned(W, 5); if setup then setup(W) end end
    local W = world(o)
    W.run(60)
    return W
  end
  -- 5 planned coffins wait for items; want 10, free 0: 5 coffins to make
  local W1 = scene{census_i = {rock = 30}}
  T.eq(coffin_orders(W1), {{5, 'INORGANIC', 'dfllm:coffin'}})
  local W2 = scene{census_i = {rock = 30, rock_bad = 30, wood = 23}, carpenters = true}
  T.eq(coffin_orders(W2), {{3, 'wood', 'dfllm:coffin'}}, 'soft stone is refused; 23 logs - keep 20 = 3')
  CW.day(W2, 2)
  local dn = events(W2, 'DECISION_NEEDED', 'coffin_material')
  T.eq(#dn, 1, 'the other 2 have no material')
  T.ok(dn[1].d.q:find('hard stone 0', 1, true) and dn[1].d.q:find('logs 23', 1, true), dn[1].d.q)
  local W3 = scene{census_i = {rock = 30, rock_bad = 30, wood = 60}, masons = false}
  T.eq(coffin_orders(W3), {}, 'logs but no carpenter')
  local W4 = scene{census_i = {rock = 3, wood = 60}, carpenters = true}
  T.eq(coffin_orders(W4), {{3, 'INORGANIC', 'dfllm:coffin'}, {2, 'wood', 'dfllm:coffin'}}, 'stone first, then wood')
  T.eq(events(W4, 'DECISION_NEEDED', 'coffin_material'), {})
end)

T.test('FR-61 material: stock and open orders that can run count; a stuck rock order does not', function()
  local function scene(o)
    o.runner = false
    local setup = o.setup
    o.setup = function(W) planned(W, 5); if setup then setup(W) end end
    local W = world(o)
    W.run(60)
    return W
  end
  local W1 = scene{setup = function(W)
    F.item(W, 'COFFIN', {_pos = {30, 30, 5}})
    F.item(W, 'COFFIN', {_pos = {30, 30, 5}, flags = {in_job = true}})          -- on its way to a planned coffin
    F.item(W, 'COFFIN', {_pos = {30, 30, 5}, flags = {forbid = true}})
    F.item(W, 'COFFIN', {_pos = {30, 30, 5}, flags = {in_building = true}})
  end}
  T.eq(coffin_orders(W1), {{3, 'INORGANIC', 'dfllm:coffin'}}, '5 - 2 usable coffins in stock')
  CW.day(W1)
  T.eq(#coffin_orders(W1), 1, 'the open order covers them')
  local W2 = scene{census_i = {rock = 30, rock_bad = 30, wood = 60}, carpenters = true, setup = function(W)
    df.global.world.manager_orders.all:insert('#', {id = 900, job_type = df.job_type.ConstructCoffin, amount_left = 5,
                                                    mat_type = 0, mat_index = -1})
  end}
  T.eq(coffin_orders(W2), {{5, 'wood', 'dfllm:coffin'}}, 'a rock order on soft stone is stuck: wood')
  local v = W2.inbox('inspect', {what = 'tombs'}).data.prov
  T.eq({v.stuck, v.order, v.mat}, {5, 5, 'wood'})
end)

---------------------------------------------------------------- when not
T.test('FR-61: nothing while free usable coffins >= bodies without a tomb + reserve; nothing in SIEGE; config off', function()
  local W = world{setup = function(W) for i = 1, 10 do CW.tomb(W, 40 + i, 10, 5) end end}
  W.run(120)
  T.eq(project(W), nil)
  T.eq(coffin_orders(W), {})
  T.eq(W.state().care.coffins.short, 0)
  local W2 = world{mode = 'SIEGE', setup = function(W) dead(W, 4); corpse(W, 4); planned(W, 3) end}
  W2.run(120)
  T.eq({project(W2), coffin_orders(W2)}, {nil, {}})
  local W3 = world{care = {coffins = false}, setup = function(W) dead(W, 4); corpse(W, 4) end}
  W3.run(120)
  T.eq(project(W3), nil)
  T.eq(W3.state().care.coffins, nil)
  local req = events(W3, 'PROJECT_REQUEST', 'tombs')
  T.eq({#req, req[1].d.why, req[1].d.n}, {1, 'tombs_free', 7}, 'off: the old request (corpses + tomb_margin) for follow')
end)

T.test('FR-61: a pending tombs project waits; no core and nobody dead: nothing', function()
  local W = world{runner = false, pending = {tombs = 1}, setup = function(W) dead(W, 4); corpse(W, 4) end}
  W.run(120)
  T.eq(W.inbox('inspect', {what = 'tombs'}).data.prov.probes, nil)
  local W2 = world{setup = function(W) end}
  W2.K.persist.set('manifest', {v = 2})
  W2.run(120)
  T.eq(project(W2), nil)
end)

T.done()
