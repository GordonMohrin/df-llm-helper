-- BUG-708 siege traffic test (the lockdown / refuge behaviour of water.lua changed: a source outside the walls is no hospital water in a
-- SIEGE lockdown). The world of test_bug564_568_siege_traffic.lua (real sense / threat / siege / gate / military / readiness, walkers on
-- and around the bridges, a raised bridge cannot be walked, a unit ON a moving bridge is crushed, an army outside) with the water module
-- added: a hospital with a patient at thirst 40,000, a dry well in Kern+ and the only wet Water Source zone far outside the walls.
-- The fort must close exactly as without the water module (O1 and B1 up, B2 down, nobody crushed or left on a footprint), the water
-- module must not touch a bridge, lever, door or burrow (it removes the hospital zone and asks siege_no_water, nothing else). The recall
-- after the siege is not touched by the change (water reads the lockdown, never sets it) and stays covered by the other traffic tests.
local T = require('testlib')
local S = require('siege_world')
local X = require('wp6_world')
local F = require('wp8_world')
local C = require('dfllm.util.contract')
local kmock = require('dfllm.util.k_mock')
local Z = S.Z

local FPY = {O1 = 10, B1 = 40, B2 = 60}
local function on_fp(name, x, y) return y == FPY[name] and x >= 50 and x <= 52 end
local function route(x, y0, y1)
  local r, step = {}, y1 >= y0 and 1 or -1
  for y = y0, y1, step do r[#r + 1] = {x, y} end
  return r
end

local function owners()
  for _, fn in ipairs({'hospital_remove', 'hospital_restore', 'work_detail', 'item_flag', 'workorder', 'burrow_tiles'}) do
    local keep = {}
    for _, o in ipairs(C.ACT[fn] or {}) do if o ~= 'water' then keep[#keep + 1] = o end end
    keep[#keep + 1] = 'water'
    C.ACT[fn] = keep
  end
end

local function build()
  owners()
  local units = X.citizens(40, 1, {skills = {AXE = 6, SHIELD = 3, ARMOR = 2, DODGING = 2}})
  local walkers = {}
  for k = 0, 3 do
    local rt = route(51, 0, 70)
    units[#units + 1] = S.cit(900 + k, rt[1][1], rt[1][2], Z, k % 2 == 1 and {squad = 1} or nil)
    walkers[#walkers + 1] = {id = 900 + k, route = rt, start = 300 * k, i = 1, kind = k % 2 == 1 and 'soldier' or 'citizen'}
  end
  for _, u in ipairs(S.army(6, 50, 150)) do units[#units + 1] = u end
  local W = X.world{units = units, persist = {}, mode = 'SIEGE'}
  local runner = X.runner('P5')
  function runner.emit(K, etype, d) return K.emit(etype, nil, etype, d) end
  W.seal = {name = 'seal', every = {ticks = 600}, x = {tick = 1, sealed = 0, routes = 0, doors = {}, open = {}}, rep = {}}
  function W.seal.entrance_doors(K) return W.seal.x end
  function W.seal.replaced(K) return W.seal.rep end
  W.econ, W.snap = X.economy(), X.snapshot()
  X.load(W, {'military', 'readiness'}, {W.econ, W.snap, runner, W.seal})
  X.mod('readiness').CAPS = {[0] = 55, [1] = 55, [2] = 75, [3] = 250}
  W.walkers, W.crushed, W.t0 = walkers, {}, nil
  return W
end

local function water(W)
  -- the water world's fakes beside the siege world's (F.install would replace its dfhack.buildings / dfhack.items)
  local other = df.global.world.buildings.other
  for _, n in ipairs({'WELL', 'ANY_ZONE', 'ZONE_WATER_SOURCE'}) do other[n] = other[n] or kmock.vec{} end
  local items = df.global.world.items.other
  items.BUCKET = items.BUCKET or kmock.vec{}
  W.item_seq, W.items_by_id = 0, {}
  W.site = {buildings = kmock.vec{}}
  dfhack.world = dfhack.world or {}
  dfhack.world.getCurrentSite = function() return W.site end
  dfhack.items.getPosition = function(it) local p = it._pos; if p then return p[1], p[2], p[3] end end
  dfhack.items.getContainedItems = function(it) return it._contents or {} end
  dfhack.buildings.findCivzonesAt = function(p) return {} end
  df.item_type = df.item_type or {BUCKET = 1}
  df.civzone_type = {WaterSource = 10, [10] = 'WaterSource', Pond = 11, [11] = 'Pond'}
  df.abstract_building_type = df.abstract_building_type or {HOSPITAL = 3}
  df.unit_labor = df.unit_labor or {FEED_WATER_CIVILIANS = 40, MINE = 41, CUTWOOD = 42, HUNT = 43}
  df.job_type.Rest, df.job_type[77] = 77, 'Rest'
  df.job_type.GiveWater, df.job_type[78] = 78, 'GiveWater'
  W.hosp = F.building(W, 'ANY_ZONE', {id = 9001, x1 = 45, y1 = 72, x2 = 49, y2 = 76, z = Z, location_id = 9100})
  W.site.buildings:insert('#', {id = 9100, getType = function() return df.abstract_building_type.HOSPITAL end})
  W.well = F.building(W, 'WELL', {id = 9002, x1 = 55, y1 = 72, x2 = 55, y2 = 72, z = Z})
  F.building(W, 'ZONE_WATER_SOURCE', {id = 9003, type = df.civzone_type.WaterSource, x1 = 52, y1 = 2, x2 = 52, y2 = 2, z = Z,
                                      spec_sub_flag = {active = true}})
  for i = 1, 4 do F.item(W, 'BUCKET', {_pos = {55, 73 + i, Z}}) end
  local pu = W.unit(5)
  pu.counters2 = {thirst_timer = 40000, hunger_timer = 1000}
  pu.health = {flags = {needs_healthcare = true}}
  W.removed = {}
  W.act_result('hospital_remove', function(id)
    W.removed[#W.removed + 1] = id
    local az = df.global.world.buildings.other.ANY_ZONE            -- the zone is gone from the game
    for i = 0, #az - 1 do if az[i].id == id then az:erase(i); break end end
    return true, 1
  end)
  W.act_result('hospital_restore', function(loc) W.restored = (W.restored or 0) + 1; return true, 'present' end)
  W.act_result('work_detail', function(name, id, on) return true, 'added' end)
  local prev = W.snap.tile
  W.snap.tile = function(K, x, y, z)
    if x == 52 and y == 2 and z == Z then return {c = '~', dig = '', bld = ''} end
    return prev and prev(K, x, y, z) or {c = '.', dig = '', bld = ''}
  end
  package.loaded['dfllm.water'] = nil
  W.load(require('dfllm.water'))
end

local function step(W, t)
  W.t0 = W.t0 or t
  local rel = t - W.t0
  for _, w in ipairs(W.walkers) do
    if not w.dead and rel >= w.start and w.i < #w.route then
      local nx = w.route[w.i + 1]
      local blocked = false
      for name in pairs(FPY) do
        if on_fp(name, nx[1], nx[2]) and S.bstate(W, name) == 'up' then blocked = true end
      end
      if not blocked then
        w.i = w.i + 1
        W.move(w.id, w.route[w.i][1], w.route[w.i][2], Z)
      end
    end
  end
  for _, w in ipairs(W.walkers) do
    if not w.dead then
      local u = W.unit(w.id)
      for name in pairs(FPY) do
        if S.bstate(W, name) == 'moving' and on_fp(name, u._m.x, u._m.y) then
          w.dead = true
          W.crushed[#W.crushed + 1] = string.format('%s %d on %s at +%d', w.kind, w.id, name, rel)
        end
      end
    end
  end
end

local function run(W, ticks)
  local at = {}
  for t = 0, ticks, 9 do at[#at + 1] = {t, step} end
  S.run(W, ticks, {at = at})
end

local DEFENSE = {'lever', 'bridge', 'door', 'burrow', 'alert'}
local function defense_acts(W, who)
  local n = {}
  for _, a in ipairs(W.acts) do
    local fn = tostring(a.fn or a.name or a[1])
    for _, k in ipairs(DEFENSE) do
      if fn:find(k, 1, true) and (a.by == who or a.module == who) then n[#n + 1] = fn end
    end
  end
  return n
end

T.test('BUG-708 traffic: SIEGE with an army outside, a dry hospital well in Kern+ and the only water outside: the fort closes (O1, B1 up, ' ..
       'B2 down), nobody is crushed or left on a footprint, the water module touches no bridge / lever / door / burrow', function()
  local W = build()
  water(W)
  run(W, 3600)
  T.eq(#W.crushed, 0, 'crushed: ' .. table.concat(W.crushed, '; '))
  for _, b in ipairs({'O1', 'B1'}) do T.eq(S.bstate(W, b), 'up', b .. ' up (the fort closes)') end
  T.eq(S.bstate(W, 'B2'), 'down', 'the core seal B2 is the BREACH bridge, not the SIEGE one')
  for _, w in ipairs(W.walkers) do
    local u = W.unit(w.id)
    for name in pairs(FPY) do T.ok(not on_fp(name, u._m.x, u._m.y), w.id .. ' stands on ' .. name) end
  end
  T.eq(defense_acts(W, 'water'), {}, 'water.lua moved no defense piece')
  T.eq(W.K.mode(), 'SIEGE', 'the lockdown stands')
  T.eq(W.state().water.hosp_ok, 0, 'the water outside the walls is no hospital water in the lockdown')
  T.eq(W.removed, {W.hosp.id}, 'the dry hospital zone is removed: the patient drinks from the stock')
  local d = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'siege_no_water' then d[#d + 1] = e end end
  T.eq(#d, 1, 'one siege_no_water decision')
end)

T.done()
