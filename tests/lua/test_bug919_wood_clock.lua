-- NEU17 BUG-919 (Run 17 i4 Girderroots y484-y491): the WOOD_STUCK / WOOD_UNMARK clocks ran on the tick the run's CENSUS started at (r.now), which lay up to ~350 game days behind the real tick when a
-- long run reached its chop task: the first removal came 377 game days after the reload, the result said '552 game days' for 199, WOOD_STUCK's `d` was not monotonic. Now: the real tick, also from the end
-- of the census; a silent miss does not burn the unmark_days window; a loaded older save re-dates a pending measurement; the highest log id of the last reading is persisted.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end
local function job_list(jobs)
  local head = {}
  local cur = head
  for i, j in ipairs(jobs) do
    local node = {item = {id = 7000 + i, job_type = df.job_type[j[1]], flags = {}, pos = j[2]}}
    cur.next = node
    cur = node
  end
  df.global.world.jobs = {list = head}
end

-- trees: list of {x, marked}; fells: x of each open FellTree job. groups: x >= 500 -> group 2 (off), x == 700 -> -1 (unknown), else 1
local function world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, 10 do units[i] = {id = i, citizen = true} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units, mode = opts.mode}
  add_jobs({'Dig', 'FellTree', 'GatherPlants'})
  df.work_detail_mode = {Default = 0, EverybodyDoesThis = 1, NobodyDoesThis = 2, OnlySelectedDoesThis = 3}
  df.unit_labor = {MINE = 1, CUTWOOD = 2}
  dfhack.job.getWorker = function() return nil end
  df.global.plotinfo.labor_info = {work_details = kmock.vec{}}
  local ids = {}
  for i = 1, 10 do ids[i] = i; W.unit(i).job = {current_job = {id = 900 + i}} end
  W.set_census('u', F.census_u(ids))
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P3'} end})
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z) if z == 1 and x >= 0 and x <= 60 and y >= 0 and y <= 60 then return {c = '.', dig = '', bld = ''} end end,
          far = function(K, x, y, z, strict) if x >= 500 then return strict == true, strict == true and 'nowalk' or nil end return false end,
          groups = function(K, pts)
            local g = {}
            for i = 1, #pts do local x = pts[i][1]; g[i] = x == 700 and -1 or (x >= 500 and 2 or 1) end
            return g
          end})
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  local trees = {}
  for i, t in ipairs(opts.trees or {}) do trees[i] = {pos = {x = t[1], y = 10, z = 1}, _marked = t[2] ~= false} end
  df.global.world.plants = {tree_dry = kmock.vec(trees), tree_wet = kmock.vec{}, shrub_dry = kmock.vec{}, shrub_wet = kmock.vec{}}
  W.unmarked = {}
  dfhack.designations = {isPlantMarked = function(p) return p._marked == true end,
                         unmarkPlant = function(p) p._marked = false; W.unmarked[#W.unmarked + 1] = p.pos.x; return true end}
  W.act_result('tree_unmark', function(list)           -- the act is tested in test_act_supply.lua: here it unmarks the marked trees at the positions
    local n = 0
    for _, pos in ipairs(list) do
      for _, t in ipairs(trees) do
        if t.pos.x == pos[1] and t._marked then dfhack.designations.unmarkPlant(t); n = n + 1 end
      end
    end
    return true, n
  end)
  local jobs = {}
  for _, x in ipairs(opts.fells or {}) do jobs[#jobs + 1] = {'FellTree', {x = x, y = 10, z = 1}} end
  job_list(jobs)
  if opts.setup then opts.setup(W) end
  W.load(fresh('economy'))
  return W, trees
end


local STUCK = {trees = {{600}, {610}, {620}, {10}, {700}, {630, false}}, fells = {600, 610, 620, 640}}

T.test('BUG-919: the result counts the REAL game days since the removal (not the run start of the census)', function()
  local W = world(STUCK)
  local econ = require('dfllm.economy')
  for _ = 1, 8 do if #W.unmarked > 0 then break end; days(W, 1) end
  T.eq(#W.unmarked, 3)
  local pend = W.K.persist.get('m.economy').wunmark.pend
  T.ok(pend, 'pending')
  local now = W.K.now().tick
  pend.t = now - 5 * 1200                                      -- removed 5 real game days ago
  econ.wood_watch(W.K, W.K.cfg.baseline.economy, W.K.census.i)
  local res
  for _, e in ipairs(W.find_events('WOOD_UNMARK')) do if e.d.ph == 'result' then res = e end end
  T.ok(res, 'result')
  T.eq(res.d.days, 5)
  T.ok(res.msg:find('5 game days after', 1, true), res.msg)
end)

T.test('BUG-919: a save from before the removal was loaded: the pending measurement is dated again, no result with negative days', function()
  local W = world(STUCK)
  local econ = require('dfllm.economy')
  for _ = 1, 8 do if #W.unmarked > 0 then break end; days(W, 1) end
  local pend = W.K.persist.get('m.economy').wunmark.pend
  pend.t = W.K.now().tick + 50 * 1200
  econ.wood_watch(W.K, W.K.cfg.baseline.economy, W.K.census.i)
  for _, e in ipairs(W.find_events('WOOD_UNMARK')) do T.ok(e.d.ph ~= 'result', 'no result yet') end
  T.eq(W.K.persist.get('m.economy').wunmark.pend.t, W.K.now().tick)
end)

T.test('BUG-919: a look that finds no marked tree does not burn the 7-day window: the removal follows the day the tree is marked', function()
  local W, trees = world({trees = {{600, false}, {610, false}}, fells = {600, 610}})
  days(W, 5)
  T.eq(#W.unmarked, 0)
  T.eq(#W.find_events('WOOD_UNMARK'), 0)
  trees[1]._marked, trees[2]._marked = true, true
  days(W, 2)
  T.eq(#W.unmarked, 2, 'taken down within 2 game days, not after a week of silent misses')
end)

T.test('BUG-919: the highest log id of a reading is persisted (a reload counts the logs felled before the first reading)', function()
  local W = world(STUCK)
  F.item(W, 'WOOD', {_pos = {600, 10, 1}})
  days(W, 2)
  local p = W.K.persist.get('m.economy')
  T.ok(math.tointeger(p.wood_mark) and p.wood_mark > 0, 'wood_mark persisted: ' .. tostring(p.wood_mark))
end)

T.done()
