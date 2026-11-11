-- BUG-719 (Run 16c i3 Doorwings y372: depot1..25 on the aqshaft anchor 94,98,148, each 'done' in 5 s, no depot ever stood, the caravan could not
-- unload; Run 16d i4 Pagedsculpture y372: depot1..15 at 96,95,142 with a stair, a trap and a door in the 5x5): (1) a depot cell counts as built only
-- where a TRADE DEPOT stands, not any building or construction on its corner; (2) the surface fallback site is open floor on all 25 tiles and
-- keeps off the tiles of another open project; (3) a site whose project reported done without a depot is given up, the next one looks elsewhere,
-- and after depot_resite_max failed sites the keeper stops.
local T = require('testlib')
local H = require('runner_world')
local runner = require('dfllm.runner')

local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end

local function world(tag)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160}}
  W.real_bench = true
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load(runner)
  W.state()
  return W
end
local function depot_doc(x, y, z)
  return {v = 2, tpl = 'depot', site = 'S1', class = 'infra', params = {}, anchor = {x, y, z}, rot = 0,
          stages = {{label = 'build', mode = 'build', orders = 0, defense = 0,
                     chunks = {{pos = {x, y, z}, cells = {{0, 0, 0, 'D(5x5)'}}}}}},
          manifest = {v = 2, depot = {x + 2, y + 2, z}}, materials = {trade_depot = 1}}
end
local function citizens(W, pts)
  local ids, units = {}, {}
  for i, p in ipairs(pts) do ids[i] = i; units[i] = {id = i, pos = {x = p[1], y = p[2], z = p[3]}} end
  df.unit.find = function(id) return units[id] end
  dfhack.units.getPosition = function(u) return u.pos.x, u.pos.y, u.pos.z end
  W.K.census.u = {ids = ids}
end
local function flat(W, x0, y0, x1, y1, z)
  H.floor(W, x0, y0, z, x1, y1)
  for y = y0, y1 do for x = x0, x1 do local t = W.tile(x, y, z); t.g = t.c == '.' and 1 or 0 end end
end

T.test('BUG-719: a construction on the depot corner is no depot: the stage is not done, a trade depot there is', function()
  local W = world('b719a')
  H.floor(W, 20, 20, 50, 24, 24)
  local id = df.global.building_next_id
  df.global.building_next_id = id + 1
  W.add_building{id = id, _t = df.building_type.Construction, _st = 0, _pos = {20, 20, 50}, _key = 'Cw',
                 getType = function(self) return self._t end, getBuildStage = function() return 1 end, getMaxBuildStage = function() return 1 end}
  W.bld_at['20,20,50'] = id
  H.place(W, 'dp', depot_doc(20, 20, 50))
  H.runs(W, 12)
  local P = H.proj(W, 'dp')
  T.ok(P.done ~= 1, 'not done: a wall stands on the corner, no depot')
  T.eq(P.blocked, 'build_lost', 'lost, with the reason (lost_why), not adopted as the depot')
  T.eq(#W.find_events('PROJECT_DONE'), 0)
  -- the same on clear floor: the depot is built and the project is done
  local W2 = world('b719b')
  H.floor(W2, 20, 20, 50, 24, 24)
  H.place(W2, 'dp', depot_doc(20, 20, 50))
  H.runs(W2, 12)
  local b2 = W2.buildings[W2.bld_at['20,20,50']]
  T.ok(b2 and b2._t == df.building_type.TradeDepot, 'quickfort placed the trade depot')
  T.ok(H.proj(W2, 'dp').blocked ~= 'build_lost', T.show(H.proj(W2, 'dp')))
end)

T.test('BUG-719: the fallback site is open floor on all 25 tiles and keeps off the tiles of another open project', function()
  local W = world('b719c')
  flat(W, 30, 30, 80, 80, 100)
  W.tile(55, 52, 100).c = '>'; W.tile(55, 52, 100).g = 1            -- a stair beside the citizens (walkable, same group)
  W.tile(47, 50, 100).bld = nil
  citizens(W, {{50, 50, 100}, {51, 51, 100}, {52, 52, 100}})
  -- an open aqshaft project whose stage covers the floor around 46..49
  local aq = {v = 2, tpl = 'aqshaft', site = 'S1', class = 'infra', params = {}, anchor = {46, 46, 100}, rot = 0,
              stages = {{label = 'dig', mode = 'dig', orders = 0, defense = 0, chunks = {{pos = {46, 46, 100}, cells = {{0, 0, 0, 'd(6x6)'}}}}}},
              manifest = {v = 2}, materials = {}}
  H.place(W, 'aqx', aq)
  local ok, id = runner.depot_keep(W.K, 'caravan')
  T.ok(ok and id == 'depot1', tostring(id))
  local at = W.K.persist.get('m.runner').depot
  T.ok(type(at) == 'table', T.show(at))
  for y = at[2] - 2, at[2] + 2 do
    for x = at[1] - 2, at[1] + 2 do
      T.eq(W.tile(x, y, 100).c, '.', string.format('%d,%d is open floor', x, y))
      T.ok(not (x >= 46 and x <= 51 and y >= 46 and y <= 51), string.format('%d,%d lies in the aqshaft project', x, y))
    end
  end
end)

T.test('BUG-719: a site whose project reported done without a depot is given up; after depot_resite_max sites the keeper stops', function()
  local W = world('b719d')
  flat(W, 30, 30, 90, 90, 100)
  citizens(W, {{60, 60, 100}, {61, 61, 100}})
  W.K.persist.get('m.runner')
  local sites = {}
  local stopped
  for i = 1, 8 do
    local ok, id = runner.depot_keep(W.K, 'caravan')
    if not ok then stopped = id; break end
    local P = H.proj(W, id)
    T.ok(P and P.tpl == 'depot', tostring(id))
    local at = W.K.persist.get('m.runner').depot
    for _, s in ipairs(sites) do T.ok(s[1] ~= at[1] or s[2] ~= at[2], 'a new site, not the failed one again') end
    sites[#sites + 1] = {at[1], at[2]}
    P.done = 1                                   -- reported done, no depot stands
  end
  T.eq(stopped, 'no depot site stood the build')
  T.eq(#sites, runner.CFG.depot_resite_max, 'one project per site, then stop')
  local said
  for _, l in ipairs(W.logs) do if tostring(l.msg):find('sites failed', 1, true) then said = l.msg end end
  T.ok(said, 'the stop is logged')
end)

T.test('BUG-719: a depot project build_lost twice (a foreign building in the 5x5) is cancelled and the next site is another one', function()
  local W = world('b719e')
  flat(W, 30, 30, 90, 90, 100)
  citizens(W, {{60, 60, 100}, {61, 61, 100}})
  local ok, id = runner.depot_keep(W.K, 'caravan')
  T.ok(ok and id == 'depot1', tostring(id))
  local at1 = W.K.persist.get('m.runner').depot
  local bid = df.global.building_next_id
  df.global.building_next_id = bid + 1
  W.add_building{id = bid, _t = df.building_type.Door, _st = 1, _pos = {at1[1] - 2, at1[2] - 2, 100}, _key = 'd',
                 getType = function(self) return self._t end, getBuildStage = function() return 1 end, getMaxBuildStage = function() return 1 end}
  W.bld_at[(at1[1] - 2) .. ',' .. (at1[2] - 2) .. ',100'] = bid     -- a door on the footprint's corner (the fake quickfort reads the corner)
  H.runs(W, 8)
  T.eq(H.proj(W, 'depot1').blocked, 'build_lost', T.show(H.proj(W, 'depot1')))
  W.K.persist.get('m.runner').rty.depot1.n = 2
  local ok2, id2 = runner.depot_keep(W.K, 'caravan')
  T.ok(ok2 and id2 == 'depot2', tostring(id2))
  local at2 = W.K.persist.get('m.runner').depot
  T.ok(at2[1] ~= at1[1] or at2[2] ~= at1[2], 'another site')
  T.ok(W.K.persist.get('m.runner').depot_bad[at1[1] .. ',' .. at1[2] .. ',100'], 'the first site is remembered as bad')
end)

T.done()
