-- economy (Run 10, Handlelock): inspect workload counts only really unclaimed, reachable jobs (FR-40), loose spider
-- webs are no thread (BUG-024), and orders waiting for steel get the steel chain or a named missing input.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 60 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

-- metals 50.. and a flux stone 70 (reaction class FLUX)
local METALS = {[51] = 'IRON', [54] = 'STEEL', [55] = 'PIG_IRON'}

local function world(opts)
  opts = opts or {}
  local units = {}
  for i = 1, opts.cit or 6 do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = (opts.pos or {})[i] or {5, 5, 1}} end
  local W = F.world{cfg = {baseline = F.cfg()}, units = units}
  add_jobs({'PlantSeeds', 'GatherPlants', 'Dig', 'MakeWeapon', 'FellTree'})
  dfhack.job.getWorker = function(j) return j._worker end
  local ids = {}
  for i = 1, opts.cit or 6 do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = not (opts.idle or {})[i] and {id = 900 + i} or nil}
    u.status.labors, u.mood = {}, -1
  end
  W.set_census('u', F.census_u(ids))
  for i, name in pairs(METALS) do F.mat(W, 0, i, {token = 'INORGANIC:' .. name, flags = {IS_METAL = true}}) end
  F.mat(W, 0, 70, {token = 'INORGANIC:LIMESTONE', flags = {ITEMS_HARD = true}})
  F.mat(W, 419, 72, {token = 'CREATURE:SPIDER_CAVE:SILK', flags = {SILK = true}})
  local decode = dfhack.matinfo.decode
  dfhack.matinfo.decode = function(t, i)
    if type(t) == 'table' then t, i = t.mat_type, t.mat_index end
    local m = decode(t, i)
    if m and t == 0 then
      m.inorganic = {metal_ore = {mat_index = kmock.vec{}}}
      m.material.reaction_class = kmock.vec(i == 70 and {{value = 'FLUX'}} or {})
    end
    return m
  end
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 500})
  F.item(W, 'FOOD', {stack_size = 500, subtype = 1})
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = opts.phase or 'P3'} end})
  if opts.snapshot then W.load(opts.snapshot) end
  if opts.setup then opts.setup(W) end
  W.load(fresh('economy'))
  return W
end

-- jobs: {{type, pos, posted (true/false/nil = no job board entry), worker}}
local function jobs(list)
  local head, cur, posts = {}, nil, {}
  cur = head
  for i, e in ipairs(list) do
    local j = {id = 7000 + i, job_type = df.job_type[e[1]], flags = {}, pos = e[2] and {x = e[2][1], y = e[2][2], z = e[2][3]},
               _worker = e[4]}
    cur.next = {item = j}
    cur = cur.next
    if e[3] ~= nil then posts[#posts + 1] = {job = j, flags = {dead = e[3] == false}} end
  end
  df.global.world.jobs = {list = head, postings = kmock.vec(posts)}
end

-- walk groups: x < 10 the fort (1), x 40.. outside the wall (2), x 50.. a lone cave (3); walls (y 9) have none
local SNAP = {name = 'snapshot', every = {ticks = 100},
  groups = function(K, pts, near)
    local r = {}
    for i, p in ipairs(pts) do
      local g = -1
      if type(p) == 'table' then
        local x, y = p[1], p[2]
        if y == 9 then g = near and 1 or 0
        elseif x < 10 then g = 1 elseif x < 50 then g = 2 else g = 3 end
      end
      r[i] = g
    end
    return r
  end,
  far = function(K, x, y, z) return z == 37 end,
  tile = function() return {c = '.'} end, reach = function() return true end}

T.test('Run 10 (FR-40): unclaimed = no worker, on the job board, on a citizen\'s walk group; idle without reachable work',
  function()
  local W = world{cit = 4, idle = {[3] = true, [4] = true}, pos = {[3] = {55, 5, 1}}, snapshot = SNAP, setup = function(W)
    W.unit(1).status.labors = {PLANT = true, HERBALIST = true}            -- FR-72: the labors of these jobs are held
    jobs({{'PlantSeeds', {6, 5, 1}, true}, {'PlantSeeds', {6, 6, 1}, true}, {'PlantSeeds', {6, 7, 1}, false},
          {'GatherPlants', {40, 40, 1}, true}, {'GatherPlants', {41, 40, 1}, true}, {'GatherPlants', {42, 40, 1}, true},
          {'Dig', {7, 9, 1}, true}, {'PlantSeeds', {6, 8, 1}, nil, {id = 1}}})
  end}
  days(W, 1)
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq(r.ok, true, r.msg)
  T.eq(r.data.unclaimed, {{job = 'PlantSeeds', n = 2}, {job = 'Dig', n = 1}}, 'the wall a dig job cuts counts by its side')
  T.eq(r.data.unreachable, {{job = 'GatherPlants', n = 3}}, 'outside the wall: nobody can reach them')
  T.eq(r.data.waiting, 1, 'no worker, not on the job board: taken between workers or waiting')
  T.eq({r.data.idle, r.data.idle_noreach}, {2, 1}, 'the dwarf in the lone cave has no reachable work')
  -- FR-77: the clause adds up; the lone-cave dwarf is "no reachable work", the other idle one has reachable work waiting
  T.ok(r.msg:find('2 of 4 adults without a job (no reachable work 1, free 1), 3 unclaimed jobs, 3 unreachable', 1, true), r.msg)
end)

T.test('BUG-024: spider webs are no thread: "no collected thread", the webs\' reach, no weave order', function()
  local W = world{cit = 4, phase = 'P1', snapshot = SNAP, setup = function(W)
    F.workshop(W, 'Loom')
    for _ = 1, 5 do
      F.item(W, 'THREAD', {mat_type = 419, mat_index = 72, flags = {spider_web = true, on_ground = true}, _pos = {12, 28, 37}})
    end
    F.order(W, {job_type = df.job_type.WeaveCloth, mat_type = -1, mat_index = -1, amount_left = 40,
                material_category = {silk = true}, _name = 'Weave silk cloth'})
    jobs({})
  end}
  days(W, 4)
  local i = W.K.census.i
  T.eq({i.thread, i.thread_silk, i.webs, i.webs_near}, {0, 0, 5, 0})
  local ev = W.find_events('ORDER_STUCK')
  T.eq(#ev, 1)
  T.ok(ev[1].d.why:find('no collected thread (5 webs, none on the walk group)', 1, true), ev[1].d.why)
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq(r.data.cloth.why, 'no collected thread: the webs lie off the citizens\' walk group')
  local weave = false                          -- FR-73's standing weave orders only take collected thread
  for _, a in ipairs(W.find_acts('workorder')) do
    if a.args[1].job == 'WeaveCloth' and a.args[1].tag:sub(1, 12) ~= 'dfllm:stand_' then weave = true end
  end
  T.eq(weave, false, 'no weave order from webs')
  -- webs the citizens can walk to: the hint names them
  local W2 = world{cit = 4, phase = 'P1', snapshot = SNAP, setup = function(W)
    F.workshop(W, 'Loom')
    for _ = 1, 3 do F.item(W, 'THREAD', {mat_type = 419, mat_index = 72, flags = {spider_web = true}, _pos = {8, 8, 2}}) end
    jobs({})
  end}
  days(W2, 2)
  T.eq({W2.K.census.i.webs, W2.K.census.i.webs_near}, {3, 3})
  local r2 = W2.inbox('inspect', {what = 'workload'})
  T.eq(r2.data.cloth.why, 'no collected thread: 3 webs on the walk group (weavers collect them)')
  local hint = false
  for _, l in ipairs(W2.logs) do if tostring(l.msg):find('3 spider webs on the citizens\' walk group', 1, true) then hint = true end end
  T.ok(hint, 'cloth short: a CollectWebs hint in the log')
end)

local function steel_world(opts)
  return world{cit = 6, phase = 'P3', setup = function(W)
    F.workshop(W, 'Smelter', true)
    F.workshop(W, 'MetalsmithsForge')
    for _ = 1, opts.iron or 4 do F.item(W, 'BAR', {mat_type = 0, mat_index = 51}) end
    for _ = 1, opts.flux or 4 do F.item(W, 'BOULDER', {mat_type = 0, mat_index = 70}) end
    for _ = 1, opts.fuel or 4 do F.item(W, 'BAR', {mat_type = 7}) end
    for _, id in ipairs({262, 263}) do
      F.order(W, {id = id, job_type = df.job_type.MakeWeapon, mat_type = 0, mat_index = 54, amount_left = 2, item_subtype = 0,
                  material_category = {}, _name = 'Forge steel spear'})
    end
    jobs({})
  end}
end
local function wo(W, tag)
  local r
  for _, a in ipairs(W.find_acts('workorder')) do if a.args[1].tag == tag then r = a.args[1] end end
  return r
end

T.test('Run 10: orders waiting for steel bars get the steel chain (pig iron, then steel)', function()
  local W = steel_world{}
  days(W, 1)
  local pig = wo(W, 'dfllm:pig_iron')
  T.ok(pig, 'pig iron for the steel orders')
  T.eq({pig.job, pig.reaction, pig.amount_total}, {'CustomReaction', 'PIG_IRON_MAKING', 2}, 'two irons per later steel job')
  T.eq(pig.item_conditions[2], {condition = 'AtLeast', value = 1, item_type = 'BOULDER', reaction_class = 'FLUX'})
  T.eq(wo(W, 'dfllm:steel'), nil, 'no pig iron yet')
  for _ = 1, 2 do F.item(W, 'BAR', {mat_type = 0, mat_index = 55}) end      -- the pig iron came out
  days(W, 1)
  local stl = wo(W, 'dfllm:steel')
  T.ok(stl, 'steel from pig iron + iron + flux')
  T.eq({stl.reaction, stl.amount_total}, {'STEEL_MAKING', 2})
  local dec = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do dec[#dec + 1] = e.d.id end
  T.eq(dec, {'metal'}, 'no steel decision (4 iron bars, no ore: only the yearly ore question, Run 10)')
end)

T.test('Run 10: without flux the steel orders name the missing input once (DECISION_NEEDED steel, cadence)', function()
  local W = steel_world{flux = 0}
  days(W, 1)
  local dec = {}
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'steel' then dec[#dec + 1] = e end end
  T.eq(#dec, 1)
  T.ok(dec[1].msg:find('2 orders (262,263) wait for steel bars; missing flux', 1, true), dec[1].msg)
  T.ok(dec[1].d.q:find('limestone', 1, true), dec[1].d.q)
  T.eq(wo(W, 'dfllm:pig_iron'), nil)
  days(W, 10)
  local n = 0
  for _, e in ipairs(W.find_events('DECISION_NEEDED')) do if e.d.id == 'steel' then n = n + 1 end end
  T.eq(n, 1, 'unchanged: not repeated')
end)

T.done()
