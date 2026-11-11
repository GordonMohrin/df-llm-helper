-- Run 15 projects without progress (fix14-projects, BUG-328, BUG-329).
-- BUG-328: Inkintense y377 aqshaft c1a188b5f1ae45b201 'l0.dig 0 %', 'runner: no run ended for 176 d' (the watchdog after
-- 600 slices, 132 game days), the seal and the farm 'queued' behind it; seal y374s0b0 stuck 900-1399 days, holding a slot
-- ('queued behind y374s0b0'). BUG-329: farms c1a18745d4e25dac02 'build_lost at build, missing p' while its plot 17696
-- stood; FarmPlot 86,87,133, doors and hatches 'not suspended, no builder has taken it' with no reason named.
-- Every test fails on 9b6f614.
local T = require('testlib')
local H = require('runner_world')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')
local runner = require('dfllm.runner')
local AQ = require('dfllm.aqshaft')

local CFG0, AQ0 = {}, {}
for k, v in pairs(runner.CFG) do CFG0[k] = v end
for k, v in pairs(AQ.CFG) do AQ0[k] = v end
local AQWORK = AQ.work
local function fresh(opts)
  for k, v in pairs(CFG0) do runner.CFG[k] = v end
  for k, v in pairs(AQ0) do AQ.CFG[k] = v end
  AQ.work = AQWORK
  local W = H.world(opts)
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z)
    local id = W.bld_at[x .. ',' .. y .. ',' .. z]
    return id and W.buildings[id] or nil
  end
  W.load(runner)
  return W
end
local function logged(W, level, pat)
  for _, l in ipairs(W.logs) do if l.level == level and l.msg:find(pat) then return l end end
end
local function row(W, id) for _, r in ipairs(W.state().proj) do if r[1] == id then return r end end end

local function shaft_doc(x, y, top, depth)
  local stages = {}
  for i = 0, (depth or 3) - 1 do
    stages[#stages + 1] = {label = 'l' .. i .. '.dig', mode = 'dig', orders = 0, defense = 0,
                           chunks = {{pos = {x, y, top - i}, cells = {{0, 0, 0, i == 0 and 'j' or 'i'}}}}}
  end
  return {v = 2, tpl = 'aqshaft', site = 'S1', class = 'infra', anchor = {x, y, top}, rot = 0,
          params = {x = x, y = y, top = top, dry_levels = 2, depth = depth or 3, mode = 'auto'},
          stages = stages, manifest = {v = 2}, materials = {}}
end

---------------------------------------------------------------- BUG-328 aqshaft
T.test('BUG-328: an aqshaft whose top tile quickfort refuses ends its run (old: the same refused call every slice, ' ..
       'no run ended until the watchdog); three refusals stop it (apply_fail)', function()
  local W = fresh{tag = 'b328refuse'}
  H.place(W, 'aq', shaft_doc(0, 50, 100))            -- x 0: the map edge, quickfort never designates a mine key there
  H.place(W, 'bd', H.dig_doc(1, {tpl = 'bedrooms', class = 'living', x = 20}))
  H.runs(W, 1)                                         -- old code: 'runner did not settle' (a yield every slice)
  T.ok(logged(W, 'warn', 'quickfort designated nothing at 0,50,100 %(tile #, refused 1/3%)'), 'named')
  T.eq(W.tile(20, 10, 100).dig, 'd', 'the other project is designated in the same run')
  H.runs(W, 3)
  T.eq(H.proj(W, 'aq').blocked, 'apply_fail')
  local n = 0
  for _, c in ipairs(H.qf_calls(W, 'dig', 'run')) do if c.pos[1] == 0 then n = n + 1 end end
  T.eq(n, 3, 'one refused call a run, three in all')
  T.ok(not logged(W, 'warn', '^runner watchdog'), 'no watchdog needed')
end)

T.test('BUG-328: a top tile quickfort refuses because it is open already goes on as designated: the next level is ' ..
       'dug', function()
  local W = fresh{tag = 'b328open'}
  W.tile(50, 50, 100).c = '>'                          -- a down stair already: 'j' is refused, nothing left to dig
  H.place(W, 'aq', shaft_doc(50, 50, 100))
  H.runs(W, 4)
  T.ok(logged(W, 'info', 'aq: z100 50,50: open already %(tile >%): nothing more to designate'), 'named')
  T.eq(W.tile(50, 50, 99).dig, 'i', 'z99 designated')
  T.eq(H.proj(W, 'aq').blocked, '')
end)

T.test('BUG-328: the watchdog skips a task that yields for task_days game days, whatever its slice count (old: 600 ' ..
       'slices, 130 game days for a paced runner)', function()
  local W = fresh{tag = 'b328wd'}
  H.place(W, 'aq', shaft_doc(50, 50, 100))
  H.place(W, 'bd', H.dig_doc(1, {tpl = 'bedrooms', class = 'living', x = 20}))
  AQ.work = function() return 'yield' end            -- a task that never ends
  W.run(4 * 1200, {skip = 200})                        -- a slice every 200 ticks: 24 slices in 4 days
  AQ.work = AQWORK
  T.ok(logged(W, 'warn', '^runner watchdog: task %d/%d %(work aq%) yielded %d+ slices in a row %(3 days%): skipped ' ..
              'this run$'), 'skipped after 3 days')
  T.eq(W.tile(20, 10, 100).dig, 'd', 'the run went on: the bedrooms are designated')
end)

---------------------------------------------------------------- BUG-328 set aside
-- a bedrooms project whose two beds nobody builds (stalled)
T.test('BUG-328: a project without progress for idle_days is set aside: no slot, its row last, PROJECT_BLOCKED d.idle ' ..
       'with bp.resume / bp.cancel, state sched.ip; progress brings it back, bp.resume too', function()
  local W = fresh{tag = 'b328idle'}
  H.floor(W, 10, 10, 100, 14, 11)
  H.place(W, 'st', H.doc{x = 10})
  H.runs(W, 2)
  H.dig(W)
  for _ = 1, 4 do H.runs(W, 1) end                     -- dug: the beds are placed, nobody builds them
  T.ok(W.bld_at['10,10,100'], 'beds placed')
  for _ = 1, 2 * 25 do H.runs(W, 1) end                 -- 25 days: stalled, not yet set aside
  T.eq(H.proj(W, 'st').blocked, 'stalled')
  T.eq(W.state().sched, nil, 'not set aside before idle_days')
  for _ = 1, 2 * 8 do H.runs(W, 1) end
  local r = row(W, 'st')
  T.ok(r[4]:find('^set aside %d+ d: stalled %(bp.resume%)$'), T.show(r))
  local ip = W.state().sched.ip
  T.eq({ip.n, ip.by[1][1], ip.by[1][2]}, {1, 'st', 'bedrooms'})
  T.ok(ip.by[1][3] >= 30)
  local ev
  for _, e in ipairs(W.find_events('PROJECT_BLOCKED')) do if e.d.idle then ev = e end end
  T.ok(ev, 'PROJECT_BLOCKED d.idle')
  T.ok(ev.msg:find('set aside for want of progress, not of slots', 1, true) and ev.msg:find('bp.resume', 1, true)
       and ev.msg:find('bp.cancel', 1, true), ev.msg)
  T.eq(ev.d.why, 'stalled')
  -- the set-aside project is still measured now and then: its beds built -> back by itself
  H.build(W)
  for _ = 1, 8 do H.runs(W, 1) end
  T.ok(logged(W, 'info', '^st %(bedrooms%) moves again after %d+ days set aside'), 'back by itself on progress')
  T.ok(not (row(W, 'st') or {'', '', 0, ''})[4]:find('set aside', 1, true))
  -- bp.resume: refused when not set aside, else back with a fresh idle window
  local res = W.inbox('bp.resume', {proj = 'st'})
  T.ok(not res.ok, 'not set aside')
end)

T.test('BUG-328: bp.resume takes a set-aside project back at once (a fresh idle_days, config queue.idle_days); an ' ..
       'unknown project is refused', function()
  local W = fresh{tag = 'b328res', cfg = {baseline = {v = 2, runner = {queue = {idle_days = 5}}}}}
  H.floor(W, 10, 10, 100, 14, 11)
  H.place(W, 'st', H.doc{x = 10})
  H.runs(W, 2)
  H.dig(W)
  for _ = 1, 2 * 14 do H.runs(W, 1) end
  T.ok(row(W, 'st')[4]:find('^set aside'), T.show(row(W, 'st')))
  local res = W.inbox('bp.resume', {proj = 'st'})
  T.ok(res.ok, T.show(res))
  T.ok(tostring(res.msg):find('resumed st', 1, true), T.show(res))
  T.ok(not row(W, 'st')[4]:find('set aside', 1, true), T.show(row(W, 'st')))
  T.eq(W.state().sched and W.state().sched.ip, nil)
  T.ok(not W.inbox('bp.resume', {proj = 'zz'}).ok)
end)

---------------------------------------------------------------- BUG-329 farm plot detection
T.test('BUG-329: a finished farm plot findAtTile misses (no building occupancy) counts as the farm\'s p: the farms ' ..
       'project completes (old: build_lost, missing p, eight retries on the plot that stood)', function()
  local W = fresh{tag = 'b329farm'}
  H.floor(W, 10, 10, 100, 16, 14)
  -- the plot stands (built by the stage before a retry, or by the player); quickfort counts its cell occupied
  local plot = W.add_building{id = 17696, x1 = 10, y1 = 10, x2 = 16, y2 = 14, z = 100, _st = 1, room = {},
                              getType = function() return 99 end,
                              getBuildStage = function(self) return self._st end, getMaxBuildStage = function() return 1 end}
  df.global.world.buildings.other = df.global.world.buildings.other or {}
  df.global.world.buildings.other.FARM_PLOT = {plot}
  W.unsuitable['10,10,100'] = true
  local d = {v = 2, tpl = 'farms', site = 'S1', class = 'infra', params = {plots = 1}, anchor = {10, 10, 100}, rot = 0,
             stages = {{label = 'build', mode = 'build', orders = 0, defense = 0,
                        chunks = {{pos = {10, 10, 100}, cells = {{0, 0, 0, 'p(7x5)'}}}}}},
             manifest = {v = 2}, materials = {}}
  local res = H.place(W, 'fm', d)
  T.ok(res.ok, T.show(res))
  for _ = 1, 30 do H.runs(W, 1) end
  T.eq(#W.find_events('PROJECT_DONE'), 1, 'old code: ' .. T.show(H.proj(W, 'fm')))
  T.eq(#W.find_events('PROJECT_BLOCKED'), 0)
  df.global.world.buildings.other.FARM_PLOT = nil
end)

T.test('BUG-329: a farm plot with extents holds only its extent tiles', function()
  local W = fresh{tag = 'b329ext'}
  local ext = {[0] = 1, [1] = 0, [2] = 1, [3] = 1}      -- 2x2, the tile 11,10 left out
  local plot = W.add_building{id = 5, x1 = 10, y1 = 10, x2 = 11, y2 = 11, z = 100, _st = 1,
                              room = {extents = ext, x = 10, y = 10, width = 2, height = 2},
                              getType = function() return 99 end,
                              getBuildStage = function(self) return self._st end, getMaxBuildStage = function() return 1 end}
  df.global.world.buildings.other = df.global.world.buildings.other or {}
  df.global.world.buildings.other.FARM_PLOT = {plot}
  T.eq(runner.bld_at(10, 10, 100), plot)
  T.eq(runner.bld_at(11, 10, 100), nil)
  T.eq(runner.bld_at(11, 11, 100), plot)
  T.eq(runner.bld_at(10, 10, 101), nil)
  df.global.world.buildings.other.FARM_PLOT = nil
end)

---------------------------------------------------------------- BUG-329 economy: why nobody builds it
local BX, BY, BZ = 86, 87, 133
local function fresh_mod(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end
-- kind: building type name; labor: the citizens with it on ({[unit id] = true}); items: the job's attached items
local function bs_world(kind, labor, items, far)
  local W = F.world{cfg = {baseline = F.cfg()}, units = {{id = 1, citizen = true, pos = {1, 1, 1}},
                                                       {id = 2, citizen = true, pos = {2, 1, 1}},
                                                       {id = 3, citizen = true, pos = {3, 1, 1}}}}
  add_jobs({'ConstructBuilding'})
  df.unit_labor = {PLANT = 40, HAUL_FURNITURE = 41, MECHANIC = 42}
  for id = 1, 3 do W.unit(id).status.labors = {[df.unit_labor[kind == 'FarmPlot' and 'PLANT' or 'HAUL_FURNITURE']] =
                                                (labor or {})[id] == true} end
  package.loaded['plugins.suspendmanager'] = nil
  package.loaded['plugins.buildingplan'] = nil
  dfhack.job.getWorker = function(j) return j._worker end
  local refs = {}
  for _, it in ipairs(items or {}) do refs[#refs + 1] = {item = it} end
  local j = {id = 152960, job_type = df.job_type.ConstructBuilding, flags = {suspend = false}, items = kmock.vec(refs),
             job_items = {elements = kmock.vec{}}}
  local b = {id = 900, x1 = BX, y1 = BY, x2 = BX, y2 = BY, z = BZ, _st = 0, jobs = kmock.vec{j},
             getType = function() return df.building_type[kind] end,
             getBuildStage = function(self) return self._st end, getMaxBuildStage = function() return 1 end}
  dfhack.buildings = dfhack.buildings or {}
  dfhack.buildings.findAtTile = function(x, y, z) if x == BX and y == BY and z == BZ then return b end end
  W.load({name = 'snapshot', every = {ticks = 100}, items_at = function() return {} end,
          tile = function() return {c = '.'} end,
          far = function(K, x, y, z) return (far or {})[x .. ',' .. y .. ',' .. z] == true end})
  dfhack.items = dfhack.items or {}
  dfhack.items.getPosition = function(it) return it.pos.x, it.pos.y, it.pos.z end
  W.set_census('i', {})
  W.set_census('u', {ids = {1, 2, 3}, soldier_ids = {3}, cit = 3})
  W.load(fresh_mod('economy'))
  return W, b, j
end

T.test('BUG-329: a job nobody takes names the labor no free adult has on (old: only "no builder has taken it"); ' ..
       'runner calls that cause "no labor"', function()
  if not df.building_type.FarmPlot then
    local n = 0
    for _, v in pairs(df.building_type) do if type(v) == 'number' and v > n then n = v end end
    df.building_type.FarmPlot, df.building_type[n + 1] = n + 1, 'FarmPlot'
  end
  local W = bs_world('FarmPlot', {[3] = true})          -- only the soldier has Farming on
  local ok, r = W.K.call('economy', 'build_state', BX, BY, BZ)
  T.ok(ok, tostring(r))
  T.eq(r.line, 'job 152960 not suspended, no builder has taken it: no free adult citizen has the labor Farming ' ..
               '(fields) on (0 of 2; a work detail grants it)')
  T.eq({r.nolabor, r.labor}, {true, {'PLANT', 0, 2}})
  T.eq(runner.cls_of(r), 'no labor')
  local W2 = bs_world('FarmPlot', {[1] = true})
  local _, r2 = W2.K.call('economy', 'build_state', BX, BY, BZ)
  -- BUG-747: the idle holder who reaches the site is counted (one adult of the labor, no job, no walk group data = reachable)
  T.eq({r2.line, r2.nolabor}, {'job 152960 not suspended, no builder has taken it; 1 idle holder reaches it, DF did not assign it', nil})
end)

T.test('BUG-329: an attached item that is forbidden or off the citizens\' walk group is named', function()
  local function item(id, x, y, z, forbid)
    return {id = id, pos = {x = x, y = y, z = z}, flags = {forbid = forbid == true},
            getType = function() return df.item_type.HATCH_COVER or 0 end}
  end
  local W = bs_world('Hatch', {[1] = true}, {item(7, 40, 40, 120, true)})
  local _, r = W.K.call('economy', 'build_state', BX, BY, BZ)
  T.ok(r.line:find('is forbidden', 1, true) and r.line:find('at 40,40,120', 1, true), r.line)
  T.eq(r.item_bad, true)
  local W2 = bs_world('Hatch', {[1] = true}, {item(8, 41, 40, 120)}, {['41,40,120'] = true})
  local _, r2 = W2.K.call('economy', 'build_state', BX, BY, BZ)
  T.ok(r2.line:find('at 41,40,120 lies off the citizens\' walk group', 1, true), r2.line)
end)

T.test('BUG-329: a job DF suspended names the citizen standing on its site (old: "no cause readable")', function()
  local W, _, j = bs_world('Hatch', {[1] = true})
  j.flags.suspend = true
  W.move(2, BX, BY, BZ)                                -- a citizen on the refuge stair the hatch goes on
  local _, r = W.K.call('economy', 'build_state', BX, BY, BZ)
  T.eq(r.line, 'job 152960 suspended by DF (not buildingplan, not suspendmanager): 1 citizen on the site now (a ' ..
               'walked tile: DF suspends it)')
  W.move(2, 2, 1, 1)
  local _, r2 = W.K.call('economy', 'build_state', BX, BY, BZ)
  T.ok(r2.line:find('no cause readable', 1, true), r2.line)
end)

T.done()
