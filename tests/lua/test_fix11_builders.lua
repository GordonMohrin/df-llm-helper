-- Run 15 stuck builds (fix11-builders, BUG-313..315). BUG-313: the refuge hatches 55,82,133 (Earthboat), 89,72,137
-- (Drillchamber) and 86,53,126 (Inkintense) 'not suspended, no builder has taken it; 1 item attached' for hundreds of
-- days: each on an up/down stair inside a shaft walled in on all 8 sides of its level. BUG-314: `bp.cancel` of the
-- Earthboat seal left DF's job 8095; the seal placed again adopted it. BUG-315: Drillchamber's queue of 192-194 orders
-- (73-95 stuck, gear orders made again every 1-2 days) held the mood's bag and charcoal back for 30 days.
-- Every test fails on 9ef2ccb.
local T = require('testlib')
local H = require('runner_world')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
local runner = require('dfllm.runner')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat, 1, true) then return l end end
end
local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

---------------------------------------------------------------- BUG-313 economy.build_state
local X, Y, Z = 55, 82, 133
-- tiles: {['x,y,z'] = legend char} for the fake snapshot.tile (others: rock '#'); hidden = a set of hidden tiles
local function bs_world(tiles, hidden)
  local W = F.world{cfg = {baseline = F.cfg()}, units = {}}
  add_jobs({'ConstructBuilding'})
  package.loaded['plugins.suspendmanager'] = nil
  package.loaded['plugins.buildingplan'] = nil
  dfhack.job.getWorker = function(j) return j._worker end
  local j = {id = 8095, job_type = df.job_type.ConstructBuilding, flags = {suspend = false}, items = kmock.vec{{}},
             job_items = {elements = kmock.vec{}}}
  local b = {id = 900, x1 = X, y1 = Y, x2 = X, y2 = Y, z = Z, _st = 0, jobs = kmock.vec{j},
             getType = function() return df.building_type.Door end,
             getBuildStage = function(self) return self._st end, getMaxBuildStage = function() return 1 end}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z) if x == X and y == Y and z == Z then return b end end
  W.load({name = 'snapshot', every = {ticks = 100}, items_at = function() return {} end,
          tile = function(K, x, y, z)
            local k = x .. ',' .. y .. ',' .. z
            if (hidden or {})[k] then return nil end
            return {c = tiles[k] or '#'}
          end})
  W.set_census('i', {})
  W.load(fresh('economy'))
  return W
end

T.test('BUG-313: a hatch walled in on its level: build_state says so (boxed), a floor beside it or a hidden ' ..
       'neighbour says nothing more', function()
  local W = bs_world({['55,82,133'] = 'X'})
  local ok, r = W.K.call('economy', 'build_state', X, Y, Z)
  T.ok(ok, tostring(r))
  T.eq(r.boxed, true, 'old code: no boxed')
  T.eq(r.line, 'job 8095 not suspended, no builder has taken it: walled in on its level (no tile beside it to build from)')
  local W2 = bs_world({['55,82,133'] = 'X', ['54,83,133'] = '.'})
  local _, r2 = W2.K.call('economy', 'build_state', X, Y, Z)
  T.eq({r2.boxed, r2.line}, {nil, 'job 8095 not suspended, no builder has taken it'})
  local W3 = bs_world({['55,82,133'] = 'X'}, {['56,81,133'] = true})
  local _, r3 = W3.K.call('economy', 'build_state', X, Y, Z)
  T.eq(r3.boxed, nil, 'a hidden neighbour: unknown')
end)

---------------------------------------------------------------- BUG-313/314 runner
local CFG0 = {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
local SEAL = 'c1a1884b90c4405401'
local AT = X .. ',' .. Y .. ',' .. Z

local function rworld(tag, bs)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  local W = H.world{tag = tag, map_size = {16, 16, 160}}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  W.tile(X, Y, Z).c = 'X'                                   -- the up/down stair the hatch goes on
  W.bs = bs or {}
  W.load({name = 'economy', every = {ticks = 1200}, mat_for = function() return 'rock' end,
          build_state = function(K, x, y, z) return W.bs[x .. ',' .. y .. ',' .. z] end,
          state = function() return {stock = {food_d = 200, drink_d = 300, rock = 50, rock_need = 10}} end})
  W.load({name = 'seal', every = {ticks = 50}, opening_ways = function()
    return {known = true, routes = 1, here = true, here_closable = false, others = 0, age = 0}
  end})
  W.load(runner)
  W.state()
  return W
end

local function seal_doc()
  return {v = 2, tpl = 'seal', site = 'S1', class = 'defense', params = {at = AT .. ' stair_updown'},
          anchor = {X, Y, Z}, rot = 0,
          stages = {{label = 'seal.build', mode = 'build', orders = 1, defense = 1,
                     chunks = {{pos = {X, Y, Z}, cells = {{0, 0, 0, 'H'}}}}}},
          manifest = {v = 2}, materials = {hatch_cover = 1}}
end

T.test('BUG-313: a seal hatch nobody takes that is walled in on its level is SEAL_STUCK why "boxed" and is not ' ..
       'removed and placed again on the same tile (old: "no builder", a useless re-place)', function()
  local W = rworld('boxed', {[AT] = {id = 900, kind = 'Hatch', job = 8095, susp = false, work = false, items = 1, boxed = true,
                                    line = 'job 8095 not suspended, no builder has taken it: walled in on its level (no ' ..
                                           'tile beside it to build from)'}})
  H.place(W, SEAL, seal_doc())
  for _ = 1, 20 do H.runs(W, 1) end
  local ev = W.find_events('SEAL_STUCK')[1]
  T.ok(ev, 'stuck')
  T.eq(ev.d.why, 'boxed')
  T.ok(ev.d.wait:find('walled in on its level', 1, true) and ev.d.wait:find('1 item attached', 1, true), ev.d.wait)
  T.eq(#H.qf_calls(W, 'build', 'undo'), 0, 'old code: removed and placed again')
end)

T.test('BUG-314: bp.cancel removes the project\'s unbuilt pieces with their DF jobs (old: the hatch and its job 8095 ' ..
       'stayed, the next seal adopted it); a built piece stays', function()
  local W = rworld('cancel')
  H.place(W, SEAL, seal_doc())
  H.runs(W, 2)
  local id = W.bld_at[AT]
  T.ok(id and W.buildings[id] and W.buildings[id]._st == 0, 'the hatch is placed, not built')
  local r = W.inbox('bp.cancel', {proj = SEAL})
  T.ok(r.ok, r.msg)
  T.eq(r.msg, 'cancelling ' .. SEAL .. ' (1 unbuilt piece(s) removed first, their jobs with them)')
  H.runs(W, 1)
  local undo = H.qf_calls(W, 'build', 'undo')
  T.eq(#undo, 1, 'old code: nothing removed')
  T.eq(undo[1].pos, {X, Y, Z})
  T.eq(W.bld_at[AT], nil, 'the planned hatch is gone')
  T.eq(H.proj(W, SEAL), nil, 'the project is removed after it')
  T.ok(logged(W, 'info', SEAL .. ' (seal) cancelled: 1 unbuilt piece(s) removed with their construction jobs'))
  -- placed again: a fresh building (old: the stale one adopted)
  H.place(W, 'y383s0b0', seal_doc())
  H.runs(W, 2)
  T.ok(W.bld_at[AT] and W.bld_at[AT] ~= id, 'a fresh hatch and job')
  -- built: a cancel leaves it
  H.build(W)
  local built = W.bld_at[AT]
  local r2 = W.inbox('bp.cancel', {proj = 'y383s0b0'})
  T.eq(r2.msg, 'cancelled y383s0b0')
  H.runs(W, 1)
  T.eq(W.bld_at[AT], built)
  T.eq(#H.qf_calls(W, 'build', 'undo'), 1)
end)

---------------------------------------------------------------- BUG-313 seal.refuge_stair (the kernel's trust)
T.test('BUG-313: the kernel wants the refuge hatch where a builder can build it: a head walled in on its level moves up ' ..
       'the stair to the first level with a floor beside it; a hatch standing on the head still counts', function()
  local SW = require('seal_world')
  local ZZ = 9
  local W = SW.new{persist = {manifest = {v = 2, burrows = {['Kern+'] = {role = 'kern'}}}}}
  for z = ZZ - 4, ZZ do SW.fill(W, z, 0, 0, 40, 30, '#') end
  SW.fill(W, ZZ - 4, 5, 5, 8, 8, '.')
  SW.draw(W, ZZ - 4, {'<'}, 6, 6)
  for z = ZZ - 3, ZZ - 1 do SW.draw(W, z, {'X'}, 6, 6) end
  SW.fill(W, ZZ - 2, 7, 6, 9, 6, '.')                         -- a room beside the stair two levels up
  SW.draw(W, ZZ, {'>'}, 6, 6)
  SW.regroup(W)
  SW.citizens(W, {{1, 7, 6, ZZ - 2}})
  W.burrow('Kern+', {5, 5, ZZ - 2, 15, 15, ZZ - 2})
  W.K.persist.set('manifest', {v = 2, burrows = {['Kern+'] = {role = 'kern'}, ['Tiefe+'] = {role = 'refuge'}},
                               refuge = {anchor = {5, 5, ZZ - 4}, burrow = 'Tiefe+'}, stairs = {civ = {{6, 6, ZZ - 4, ZZ}}}})
  package.loaded['dfllm.seal'] = nil
  local M = require('dfllm.seal')
  W.load(M)
  W.run(2400, {skip = 9})
  local _, rs = W.K.call('seal', 'refuge_stair')
  T.eq({rs.state, rs.pos, rs.man, rs.why}, {'moved', {6, 6, ZZ - 2}, {6, 6, ZZ - 3}, 'boxed'}, 'old code: ok at 6,6,6')
  T.eq(M.boxed(6, 6, ZZ - 3), true)
  T.eq(M.boxed(6, 6, ZZ - 2), false)
  -- a hatch that already stands on the old head counts there
  local hatch = SW.building(W, 'DOOR', 'Hatch', 6, 6, ZZ - 3)
  W.dyn[SW.key(6, 6, ZZ - 3)] = hatch
  W.tiles[SW.key(6, 6, ZZ - 3)].occ.building = df.tile_building_occ.Dynamic
  _, rs = W.K.call('seal', 'refuge_stair')
  T.eq({rs.state, rs.pos}, {'ok', {6, 6, ZZ - 3}})
end)

---------------------------------------------------------------- BUG-315 the order queue
local ONE = 0
local function ow()
  local W = F.world{cfg = {baseline = F.cfg()}, units = {}}
  add_jobs({'MakeGloves', 'MakeAmmo', 'ConstructDoor', 'MakeBag'})
  df.workquota_frequency_type = {OneTime = ONE, Daily = 1, [0] = 'OneTime', [1] = 'Daily'}
  W.act_result('order_remove', function(id)
    local all = df.global.world.manager_orders.all
    for i = #all - 1, 0, -1 do if all[i].id == id then all:erase(i); return true, 'removed' end end
    return false, 'no order'
  end)
  local E = fresh('economy')
  W.load(E)
  return W, E
end
local function order(job, why, since, extra)
  local o = {job_type = df.job_type[job], mat_type = 0, mat_index = 7, item_subtype = 3, amount_left = 1,
             frequency = ONE, status = {validated = true}}
  for k, v in pairs(extra or {}) do o[k] = v end
  return o, why, since
end
local function ids()
  local r = {}
  for _, o in ipairs(df.global.world.manager_orders.all) do r[#r + 1] = o.id end
  return r
end

T.test('BUG-315: stuck duplicates go (the tagged one stays), piece and mood orders stay, above the cap the longest ' ..
       'stuck past prune_days go, at most prune_per_day a day', function()
  local W, E = ow()
  local DAY = 1200
  local now = 400 * DAY
  local p = {orders = {['dfllm:gear_gloves'] = 3, ['dfllm:bag'] = 9}, ostuck = {}}
  local why = 'no bars:INORGANIC:BISMUTH_BRONZE'
  for i = 1, 5 do                                            -- 5 x the same gloves, stuck 10 days; 3 is the tagged one
    local o = F.order(W, order('MakeGloves'))
    p.ostuck[tostring(o.id)] = {since = now - 10 * DAY, why = why}
  end
  local d = F.order(W, order('ConstructDoor'))               -- 6, 7: doors a seal waits for (never pruned)
  p.ostuck[tostring(d.id)] = {since = now - 10 * DAY, why = 'no rock'}
  local d2 = F.order(W, order('ConstructDoor'))
  p.ostuck[tostring(d2.id)] = {since = now - 10 * DAY, why = 'no rock'}
  local a = F.order(W, order('MakeAmmo'))                    -- 8: stuck 1 day only
  p.ostuck[tostring(a.id)] = {since = now - DAY, why = why}
  local b = F.order(W, order('MakeBag'))                     -- 9: the mood's bag
  p.ostuck[tostring(b.id)] = {since = now - 40 * DAY, why = 'no cloth'}
  local c = {orders = {stuck_days = 3, backoff_days = 10, cap = 120, prune_days = 30, prune_per_day = 30}}
  local ok, n = W.K.call('economy', 'order_prune', c, p, now)
  T.ok(ok, tostring(n))
  T.eq(n, 4, 'old code: no prune')
  T.eq(ids(), {3, 6, 7, 8, 9})
  T.eq(p.orders['dfllm:gear_gloves'], 3, 'the tagged one stays')
  local ev = W.find_events('ORDER_STUCK')
  T.eq({#ev, ev[1].d.kind, ev[1].d.n, ev[1].d.dropped}, {1, 'prune', 4, 1})
  T.ok(logged(W, 'warn', 'order queue: 4 of 9 open orders removed (stuck duplicates, above the cap of 120): 1 MakeGloves ' ..
              '(duplicate), 2 MakeGloves (duplicate), 4 MakeGloves (duplicate), 5 MakeGloves (duplicate)'))
  -- the cap: 3 open orders above it; the oldest stuck one past prune_days goes, not the bag, not a door
  for i = 1, 3 do
    local o = F.order(W, order('MakeAmmo', nil, nil, {mat_index = 100 + i}))
    p.ostuck[tostring(o.id)] = {since = now - (50 + i) * DAY, why = 'no bars:' .. i}
  end
  c.orders.cap = 6
  local _, n2 = W.K.call('economy', 'order_prune', c, p, now)
  T.eq(n2, 2)
  T.eq(ids(), {3, 6, 7, 8, 9, 10}, 'the two longest stuck (12, 11) go: 8 open -> 6')
  -- prune_per_day: 30 already spent today
  p.prune_n = 30
  c.orders.cap = 1
  local _, n3 = W.K.call('economy', 'order_prune', c, p, now)
  T.eq(n3, 0)
end)

T.test('BUG-315: while a mood wants a material, the orders of its chains (bag, sand, charcoal, ...) go first in the ' ..
       'work orders; other orders and a fort without a mood keep the queue order', function()
  local _, E = ow()
  T.eq(E.mood_top({needs = {gems = {care = {n = 1, untl = 9e9}}}}, 'dfllm:bag'), true, 'old code: no mood_top')
  T.eq(E.mood_top({needs = {}}, 'dfllm:bag'), false)
  T.eq(E.mood_top({needs = {gems = {care = {n = 1}}}}, 'dfllm:gear_gloves'), false)
end)

T.done()
