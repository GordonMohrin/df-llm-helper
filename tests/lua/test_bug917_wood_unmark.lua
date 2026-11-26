-- NEU16c (holz) BUG-917: Run 17 i4 Girderroots / i1 Diedplank 26.11.: autochop 'designated trees 6-7, expected logs 220 / 246' above the max, every open FellTree job off the
-- citizens' walk group, harvested trees unchanged for years. While WOOD_STUCK holds with all open FellTree jobs off the walk group the kernel takes down exactly the fell
-- designations of the trees off the walk group (PEACE / RECOVERY only, once per 7 days, bounded), says so once (WOOD_UNMARK did), measures after the next readings (result), and
-- stops when the logs felled afterwards again lie unwalkable (stop). Also the BUG-916 text worded by cause.
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

-- two old logs on tiles with no walk group: the census marks the logs of its previous reading, so later logs count as new (BUG-916)
local OLD = {trees = {{600}, {610}, {620}, {10}, {700}, {630, false}}, fells = {600, 610, 620, 640},
             setup = function(W) for _ = 1, 2 do F.item(W, 'WOOD', {_pos = {600, 10, 1}}) end end}

-- game days until the first removal happened (the logs of a test arrive right after it, before the measurement)
local function until_unmark(W)
  for _ = 1, 8 do if #W.unmarked > 0 then return end; days(W, 1) end
end

local STUCK = {trees = {{600}, {610}, {620}, {10}, {700}, {630, false}}, fells = {600, 610, 620, 640}}

T.test('BUG-917: WOOD_STUCK with every open FellTree job off the walk group: the marked trees off the walk group are unmarked, once, reachable / unknown / unmarked ones stay', function()
  local W, trees = world(STUCK)
  days(W, 2)
  T.eq(#W.find_events('WOOD_UNMARK'), 0, 'not before WOOD_STUCK holds (3 game days)')
  days(W, 3)
  local ev = W.find_events('WOOD_UNMARK')
  T.eq(#ev, 1, 'once')
  T.eq(ev[1].d.ph, 'did')
  T.eq(ev[1].d.n, 3)
  T.eq(ev[1].d.des, 5, 'five marked trees were read')
  T.eq(ev[1].d.off, 3)
  T.eq(W.unmarked, {600, 610, 620}, 'the reachable tree (x 10), the unknown group (x 700) and the unmarked tree stay')
  T.ok(trees[4]._marked and trees[5]._marked, 'reachable and unknown stay marked')
  T.ok(ev[1].d.sample:find('600,10,1', 1, true), ev[1].d.sample)
  T.ok(ev[1].msg:find('taken down', 1, true), ev[1].msg)
  T.eq(#W.find_events('WOOD_STUCK'), 1)
  days(W, 4)
  local did = 0
  for _, e in ipairs(W.find_events('WOOD_UNMARK')) do if e.d.ph == 'did' then did = did + 1 end end
  T.eq(did, 1, 'not again within 7 game days')
  T.eq(#W.unmarked, 3, 'idempotent: nothing unmarked twice')
  T.eq(F.bad_runs(W), {})
end)

T.test('BUG-917: WOOD_STUCK text is worded by cause: no "felling brings none"', function()
  local W = world(STUCK)
  days(W, 5)
  local ev = W.find_events('WOOD_STUCK')
  T.eq(#ev, 1)
  T.ok(ev[1].msg:find("open FellTree jobs lie off the citizens' walk group", 1, true), ev[1].msg)
  T.ok(not ev[1].msg:find('felling brings none', 1, true), ev[1].msg)
  T.ok(not ev[1].msg:find('new logs', 1, true), 'no new logs seen: no claim about them')
end)

T.test('BUG-917: only in PEACE / RECOVERY, and economy.wood.unmark=false switches it off', function()
  local W = world({trees = STUCK.trees, fells = STUCK.fells, mode = 'SIEGE'})
  days(W, 6)
  T.eq(#W.find_events('WOOD_UNMARK'), 0, 'SIEGE: nothing is taken down')
  T.eq(W.unmarked, {})
  local W2 = world(STUCK)
  W2.K.cfg.baseline.economy = {wood = {unmark = false}}
  days(W2, 6)
  T.eq(#W2.find_events('WOOD_UNMARK'), 0, 'switched off')
end)

T.test('BUG-917: a marked tree that is reachable (every group readable) is never unmarked, no event', function()
  local W = world({trees = {{10}, {11}}, fells = {600, 610}})
  days(W, 6)
  T.eq(W.unmarked, {})
  T.eq(#W.find_events('WOOD_UNMARK'), 0)
end)

T.test('BUG-917: measurement after the next readings: usable new logs, the removal ends with the episode', function()
  local W = world(OLD)
  until_unmark(W)
  T.eq(#W.unmarked, 3)
  for _ = 1, 4 do F.item(W, 'WOOD', {_pos = {12, 10, 1}}) end
  days(W, 3)
  local res
  for _, e in ipairs(W.find_events('WOOD_UNMARK')) do if e.d.ph == 'result' then res = e end end
  T.ok(res, 'a result line')
  T.eq({res.d.new, res.d.newnw, res.d.n}, {4, 0, 3})
  T.ok(res.msg:find('4 (4 usable, 0 on tiles with no walk group)', 1, true), res.msg)
  for _, e in ipairs(W.find_events('WOOD_UNMARK')) do T.ok(e.d.ph ~= 'stop', 'walkable logs: no stop') end
end)

T.test('BUG-917: the new logs again unwalkable: result, then stop (once), no further removal', function()
  local W, trees = world(OLD)
  until_unmark(W)
  T.eq(#W.unmarked, 3)
  for _ = 1, 6 do F.item(W, 'WOOD', {_pos = {600, 10, 1}}) end
  days(W, 3)
  local ph = {}
  for _, e in ipairs(W.find_events('WOOD_UNMARK')) do ph[#ph + 1] = e.d.ph end
  T.eq(ph, {'did', 'result', 'stop'})
  local stop = W.find_events('WOOD_UNMARK')[3]
  T.eq({stop.d.new, stop.d.newnw, stop.d.why}, {6, 6, 'unwalkable'})
  for _, t in ipairs(trees) do if t.pos.x >= 600 and t.pos.x < 700 then t._marked = true end end   -- the plugin marks them again
  days(W, 15)
  T.eq(#W.unmarked, 3, 'stopped: nothing taken down again')
  T.eq(#W.find_events('WOOD_UNMARK'), 3)
end)

T.test('BUG-917: no result of use after unmark_runs removals: stop with why runs', function()
  local W, trees = world(OLD)
  W.K.cfg.baseline.economy = {wood = {unmark_runs = 1}}
  days(W, 5)
  T.eq(#W.unmarked, 3)
  for _, t in ipairs(trees) do t._marked = t.pos.x ~= 630 end    -- re-marked
  days(W, 12)
  local last = W.find_events('WOOD_UNMARK')
  T.eq(last[#last].d.ph, 'stop')
  T.eq(last[#last].d.why, 'runs')
end)

T.done()
