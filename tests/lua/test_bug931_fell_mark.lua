-- NEU20a (holz-fass) BUG-931: Run 17 i1 Diedplank y435: WOOD_UNMARK took 7 unreachable fell designations down three times, autochop marked the same trees again, 'stopped for this episode',
-- >1000 reachable trees stood, 6 dwarves died for want of drink. After the removal has done its part the kernel marks a bounded number of REACHABLE trees itself: nearest a built Carpenter's
-- workshop, on the citizens' walk group, >= 3 tiles from water and from a drop of 2+ levels, PEACE / RECOVERY only, measured after 7 game days, stops when nothing is felled.
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

-- trees: {x, marked}; the Carpenter's workshop stands at 9..11 / 9..11 on level 1; x >= 500 = group 2 (off the walk group), x == 700 unknown (-1), else group 1.
-- water: tiles {x, y} with flow 3; drops: tiles {x, y} that are open air over open air
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
  local water, drop = {}, {}
  for _, t in ipairs(opts.water or {}) do water[t[1] .. ',' .. t[2]] = true end
  for _, t in ipairs(opts.drops or {}) do drop[t[1] .. ',' .. t[2]] = true end
  W.reads = 0
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P3'} end})
  W.load({name = 'snapshot', every = {ticks = 100},
          tile = function(K, x, y, z)
            W.reads = W.reads + 1
            if x >= 0 and x <= 800 and y >= 0 and y <= 60 and z >= 0 and z <= 1 then
              local k = x .. ',' .. y
              if opts.hidden and opts.hidden[x .. ',' .. y .. ',' .. z] then return nil end
              if z == 1 and drop[k] then return {c = ' ', dig = '', bld = '', shape = 'EMPTY', flow = 0} end
              if z == 0 and drop[k] then return {c = ' ', dig = '', bld = '', shape = 'EMPTY', flow = 0} end
              return {c = '.', dig = '', bld = '', shape = 'FLOOR', flow = (z == 1 and water[k]) and 3 or 0}
            end
          end,
          far = function(K, x, y, z, strict) if x >= 500 then return strict == true, strict == true and 'nowalk' or nil end return false end,
          groups = function(K, pts)
            if opts.nogroups then return nil end
            local g = {}
            for i = 1, #pts do local x = pts[i][1]; g[i] = x == 700 and -1 or (x >= 500 and 2 or 1) end
            return g
          end})
  for _ = 1, 8 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 2000})
  F.item(W, 'FOOD', {stack_size = 2000, subtype = 1})
  if opts.shop ~= false then
    local b = F.workshop(W, 'Carpenters')
    b.x1, b.y1, b.x2, b.y2, b.z = 9, 9, 11, 11, 1
  end
  local trees = {}
  for i, t in ipairs(opts.trees or {}) do trees[i] = {pos = {x = t[1], y = t[3] or 10, z = 1}, _marked = t[2] ~= false} end
  df.global.world.plants = {tree_dry = kmock.vec(trees), tree_wet = kmock.vec{}, shrub_dry = kmock.vec{}, shrub_wet = kmock.vec{}}
  W.unmarked, W.marked = {}, {}
  dfhack.designations = {isPlantMarked = function(p) return p._marked == true end,
                         unmarkPlant = function(p) p._marked = false; W.unmarked[#W.unmarked + 1] = p.pos.x; return true end,
                         markPlant = function(p) p._marked = true; W.marked[#W.marked + 1] = p.pos.x; return true end}
  W.act_result('tree_unmark', function(list)
    local n = 0
    for _, pos in ipairs(list) do
      for _, t in ipairs(trees) do
        if t.pos.x == pos[1] and t._marked then dfhack.designations.unmarkPlant(t); n = n + 1 end
      end
    end
    return true, n
  end)
  W.act_result('tree_mark', function(list)             -- the act itself is tested in test_act_supply.lua
    local n = 0
    for _, pos in ipairs(list) do
      for _, t in ipairs(trees) do
        if t.pos.x == pos[1] and t.pos.y == pos[2] and not t._marked then dfhack.designations.markPlant(t); n = n + 1 end
      end
    end
    return true, n
  end)
  local jobs = {}
  for _, x in ipairs(opts.fells or {600, 610}) do jobs[#jobs + 1] = {'FellTree', {x = x, y = 10, z = 1}} end
  job_list(jobs)
  if opts.setup then opts.setup(W) end
  W.load(fresh('economy'))
  return W, trees
end

-- the marked unreachable trees of i1 (x 600, 610) plus reachable ones near the shop
local function base(extra)
  local t = {{600}, {610}}
  for _, e in ipairs(extra) do t[#t + 1] = e end
  return t
end
local function fell_events(W, ph)
  local out = {}
  for _, e in ipairs(W.find_events('WOOD_FELL_MARK')) do if ph == nil or e.d.ph == ph then out[#out + 1] = e end end
  return out
end
-- the days until the first marking (WOOD_UNMARK first, then WOOD_FELL_MARK)
local function until_mark(W, max)
  for _ = 1, max or 14 do if #W.marked > 0 then return end; days(W, 1) end
end

T.test('BUG-931: after WOOD_UNMARK ran, the kernel marks reachable trees: nearest the shop first, on the walk group, none near water or a 2-level drop, none beyond near_d', function()
  local W, trees = world{trees = base{{12, false}, {13, false}, {30, false}, {35, false}, {120, false}, {700, false}, {550, false}},
                         water = {{33, 10}}, drops = {{35, 13}}}
  until_mark(W)
  local ev = fell_events(W, 'did')
  T.eq(#ev, 1, 'one marking pass')
  T.eq(W.marked, {12, 13}, 'the two safe trees: x 30 has water 3 tiles away, x 35 a drop, x 120 lies beyond near_d, x 550 is off the walk group, x 700 has an unknown group')
  T.eq(ev[1].d.n, 2)
  T.eq(ev[1].d.shop, '9,9,1')
  T.ok(ev[1].d.sample:find('12,10,1', 1, true), ev[1].d.sample)
  T.ok(#W.unmarked >= 2, 'the removal ran first: ' .. T.show(W.unmarked))
  T.ok(trees[1]._marked == false and trees[2]._marked == false, 'unreachable trees stay unmarked: the kernel never marks them')
  T.ok(ev[1].msg:find('reachable trees marked for felling', 1, true), ev[1].msg)
  T.eq(F.bad_runs(W), {})
end)

T.test('BUG-931: at most fell_n (6) a pass, a pass every fell_days (3), nearest first; the season cap fell_season stops it (event stop, why cap)', function()
  local ts = {}
  for x = 12, 40 do ts[#ts + 1] = {x, false} end
  local W = world{trees = base(ts)}
  W.K.cfg.baseline.economy = {wood = {fell_season = 10}}
  until_mark(W)
  T.eq(#W.marked, 6, 'six in the first pass')
  T.eq(W.marked, {12, 13, 14, 15, 16, 17}, 'the six nearest the shop')
  days(W, 2)
  T.eq(#W.marked, 6, 'not again within fell_days / before the measurement')
  days(W, 12)
  local stops = fell_events(W, 'stop')
  T.ok(#W.marked <= 10, 'never more than the season cap: ' .. #W.marked)
  T.ok(#stops >= 1 and stops[1].d.why, 'the cap or the measurement stopped it: ' .. T.show(stops))
end)

T.test('BUG-931: nothing before WOOD_UNMARK has run; PEACE / RECOVERY only; fell = false switches it off; no workshop, no marking', function()
  local W = world{trees = base{{12, false}}, mode = 'SIEGE'}
  days(W, 12)
  T.eq(W.marked, {}, 'SIEGE: nothing')
  local W2 = world{trees = base{{12, false}}}
  W2.K.cfg.baseline.economy = {wood = {fell = false}}
  days(W2, 12)
  T.eq(W2.marked, {}, 'switched off')
  local W3 = world{trees = base{{12, false}}, shop = false}
  days(W3, 12)
  T.eq(W3.marked, {}, 'no Carpenter workshop')
  local W4 = world{trees = base{{12, false}}}
  W4.K.cfg.baseline.economy = {wood = {unmark = false}}
  until_mark(W4)
  T.eq(W4.marked, {12}, 'with the removal switched off the marking may start at once')
end)

T.test('BUG-931: unreadable groups or an unreadable tree tile: nothing is marked on a guess', function()
  local W = world{trees = base{{12, false}, {13, false}}, hidden = {['12,10,1'] = true}}
  until_mark(W, 12)
  T.eq(W.marked, {13}, 'the tree whose own tile cannot be read is skipped (fails closed)')
  local W2 = world{trees = base{{12, false}}, nogroups = true}
  days(W2, 12)
  T.eq(W2.marked, {}, 'no group answer, no marking')
end)

T.test('BUG-931: the measurement after 7 game days (felled trees, new logs) and the stop when nothing was felled', function()
  local W, trees = world{trees = base{{12, false}, {13, false}}}
  until_mark(W)
  T.eq(#W.marked, 2)
  -- the dwarves fell both trees: the vector no longer holds them
  df.global.world.plants.tree_dry = kmock.vec{trees[1], trees[2]}
  days(W, 8)
  local res = fell_events(W, 'result')
  T.eq(#res, 1, 'one measurement')
  T.eq({res[1].d.n, res[1].d.trees, res[1].d.still}, {2, 2, 0})
  T.eq(#fell_events(W, 'stop'), 0, 'felled: no stop')
  local W2, trees2 = world{trees = base{{12, false}, {13, false}}}
  until_mark(W2)
  days(W2, 8)
  local res2 = fell_events(W2, 'result')
  T.eq(#res2, 1)
  T.eq({res2[1].d.trees, res2[1].d.still}, {0, 2}, 'both still stand')
  local stop = fell_events(W2, 'stop')
  T.eq(#stop, 1)
  T.eq(stop[1].d.why, 'not_felled')
  T.ok(stop[1].msg:find('none of the 2 marked trees was felled', 1, true), stop[1].msg)
  local n = #W2.marked
  days(W2, 12)
  T.eq(#W2.marked, n, 'stopped for the episode: no further marking')
end)

T.test('BUG-931: the tile read budget per pass bounds the work (fell_reads)', function()
  local ts = {}
  for x = 12, 40 do ts[#ts + 1] = {x, false} end
  local W = world{trees = base(ts)}
  W.K.cfg.baseline.economy = {wood = {fell_reads = 60}}
  until_mark(W, 14)
  T.eq(#W.marked, 1, 'a tree costs 49 tile reads, the 60 of the pass buy one')
end)

T.test('BUG-931: a logs-only episode (no open FellTree job, nothing marked to take down) does not wait for a removal that cannot run: the kernel marks reachable trees', function()
  local W = world{trees = {{12, false}, {13, false}}, fells = {}, setup = function(W) for _ = 1, 30 do F.item(W, 'WOOD', {_pos = {600, 10, 1}}) end end}
  until_mark(W, 14)
  T.eq(W.marked, {12, 13}, 'logs-only stuck: marked although WOOD_UNMARK never ran')
  T.eq(#W.unmarked, 0, 'no removal was needed')
  T.eq(#fell_events(W, 'did'), 1)
end)

T.test('BUG-931: documented limit: a HIDDEN neighbour tile is skipped (only revealed water / drops exclude a tree); the tree tile and the tile below an open-air tile fail closed', function()
  local W = world{trees = base{{12, false}}, hidden = {['13,10,1'] = true, ['11,11,1'] = true}}
  until_mark(W, 12)
  T.eq(W.marked, {12}, 'hidden neighbours do not exclude the tree')
  local W2 = world{trees = base{{12, false}}, drops = {{13, 10}}, hidden = {['13,10,0'] = true}}
  days(W2, 12)
  T.eq(W2.marked, {}, 'open air over an unreadable tile below: excluded')
end)
T.done()
