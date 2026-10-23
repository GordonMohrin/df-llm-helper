-- economy BUG-057 / FR-72 (Run 12-14, Wheelsblows and Kilrudrabed): PlantSeeds 122-421 and GatherPlants 250-565 stayed
-- unclaimed for years with 30-70 % of the adults idle; the work details Planters, Plant gatherers and Fisherdwarves stood
-- at 0 members (the only code that staffed Planters was FR-25's starvation); nobody held HERBALIST and the idle line said
-- "0 without reachable work". The details follow the unclaimed reachable jobs (farmers and gatherers kept apart), never
-- shrink while jobs wait, name members that vanished without the kernel, and GatherPlants designations nobody works on
-- (or off the walk group) are withdrawn.
local T = require('testlib')
local F = require('wp8_world')
local kmock = require('dfllm.util.k_mock')

local function fresh(mod) package.loaded['dfllm.' .. mod] = nil; return require('dfllm.' .. mod) end
local function settle(W) for _ = 1, 40 do W.run(1) end end
local function days(W, n) for _ = 1, n do W.run(1200, {skip = 100}); settle(W) end end

local MINE, FISH, HERB, PLANT, COOK, DIAG = 1, 4, 20, 21, 7, 30

local function add_jobs(names)
  local jt, n = df.job_type, 0
  for _, v in pairs(jt) do if type(v) == 'number' and v > n then n = v end end
  for _, nm in ipairs(names) do
    if jt[nm] == nil then n = n + 1; jt[nm] = n; jt[n] = nm end
  end
end

-- jobs: list of {type, x, y, z, worker?}
local function job_list(list)
  local head, cur = {}, nil
  cur = head
  for i, e in ipairs(list) do
    local node = {item = {id = 7000 + i, job_type = df.job_type[e[1]], flags = {}, _worker = e[5],
                          pos = {x = e[2], y = e[3], z = e[4]}}}
    cur.next = node
    cur = node
  end
  df.global.world.jobs = {list = head}
end
local function many(tp, n, x0, worker)
  local r = {}
  for i = 1, n do r[i] = {tp, (x0 or 30) + i, 30, 100, worker and {} or nil} end
  return r
end
local function cat(...)
  local r = {}
  for _, l in ipairs({...}) do for _, e in ipairs(l) do r[#r + 1] = e end end
  return r
end

-- opts: cit (14), food (stack, 2000 = 66 days), mode, cover (config patch), jobs (job_list), members ({detail = {ids}}),
-- modes ({detail = mode}), zone, fish_raw, labors ({[id] = {LABOR = true}}), idle ({ids}), setup(W, ctl)
local function world(opts)
  opts = opts or {}
  local ctl = {calls = {}, ungather = {}}
  local cit = opts.cit or 14
  local units = {}
  for i = 1, cit do units[i] = {id = i, citizen = true, name = 'Urist ' .. i, pos = {10 + i, 10, 100}} end
  local bc = F.cfg()
  bc.economy.cover = bc.economy.cover or {}                      -- (the key is new with BUG-057)
  for k, v in pairs(opts.cover or {}) do bc.economy.cover[k] = v end
  local W = F.world{cfg = {baseline = bc}, units = units, mode = opts.mode}
  add_jobs({'Dig', 'FellTree', 'GatherPlants', 'PlantSeeds', 'HarvestPlants', 'Fish'})
  df.work_detail_mode = {Default = 0, EverybodyDoesThis = 1, NobodyDoesThis = 2, OnlySelectedDoesThis = 3,
                         [0] = 'Default', [1] = 'EverybodyDoesThis', [2] = 'NobodyDoesThis', [3] = 'OnlySelectedDoesThis'}
  df.unit_labor = {MINE = MINE, FISH = FISH, HERBALIST = HERB, PLANT = PLANT, COOK = COOK, DIAGNOSE = DIAG,
                   [MINE] = 'MINE', [FISH] = 'FISH', [HERB] = 'HERBALIST', [PLANT] = 'PLANT', [COOK] = 'COOK',
                   [DIAG] = 'DIAGNOSE'}
  df.job_skill.HERBALISM, df.job_skill[77] = 77, 'HERBALISM'
  df.job_skill.PLANT, df.job_skill[78] = 78, 'PLANT'
  df.job_skill.FISH, df.job_skill[79] = 79, 'FISH'
  df.civzone_type.FishingArea, df.civzone_type[85] = 85, 'FishingArea'
  dfhack.job.getWorker = function(j) return j._worker end
  local function lab_vec(t) return setmetatable(t, {__len = function() return 40 end}) end
  local function wd(name, labor, ids, mode)
    return {name = name, assigned_units = kmock.vec(ids or {}), allowed_labors = lab_vec{[labor] = true},
            flags = {mode = mode or 3}}
  end
  local m, md = opts.members or {}, opts.modes or {}
  ctl.wds = {Miners = wd('Miners', MINE, m.Miners or {5}, md.Miners),
             Planters = wd('Planters', PLANT, m.Planters, md.Planters),
             ['Plant gatherers'] = wd('Plant gatherers', HERB, m['Plant gatherers'], md['Plant gatherers']),
             Fisherdwarves = wd('Fisherdwarves', FISH, m.Fisherdwarves, md.Fisherdwarves)}
  df.global.plotinfo.labor_info = {work_details = kmock.vec{ctl.wds.Miners, ctl.wds.Planters,
                                                              ctl.wds['Plant gatherers'], ctl.wds.Fisherdwarves}}
  ctl.runner = {lost = 0}
  W.load({name = 'runner', every = {ticks = 600}, dig_backlog = function() return 0 end,
          state = function() return {phase = 'P0'} end,
          pending = function() return ctl.runner.pending or 0 end,
          lost = function() return ctl.runner.lost, ctl.runner.lost > 0 and 'c1a1farms' or nil end})
  -- walk groups: x < 100 the fort (1), x >= 100 outside the wall (2)
  W.load({name = 'snapshot', every = {ticks = 100},
          groups = function(K, pts, near)
            local r = {}
            for i, p in ipairs(pts) do r[i] = type(p) == 'table' and (p[1] >= 100 and 2 or 1) or -1 end
            return r
          end,
          tile = function() return {c = '.'} end, far = function() return false end, reach = function() return true end})
  W.act_result('run', function(cmd, a1)
    if cmd == 'labormanager' and a1 == 'mode' then return true, 'Mode: monitor (labormanager)' end
    return true, ''
  end)
  W.act_result('work_detail', function(name, id, on, o)
    ctl.calls[#ctl.calls + 1] = {name = name, id = id, on = on, opts = o}
    local w = ctl.wds[name]
    if not w then return false, 'no work detail ' .. name end
    if on and o and o.select and w.flags.mode == 2 then w.flags.mode = 3 end
    local v = w.assigned_units
    for i = 0, #v - 1 do if v[i] == id then if not on then v:erase(i) end; return true end end
    if on then v:insert('#', id) end
    return true
  end)
  pcall(W.act_result, 'plant_ungather', function(list)          -- (pcall: the act is new with BUG-057)
    ctl.ungather[#ctl.ungather + 1] = list
    return true, #list
  end)
  for _ = 1, 4 do F.item(W, 'BARREL', {}) end
  F.item(W, 'DRINK', {stack_size = 4000})
  ctl.food = F.item(W, 'FOOD', {stack_size = opts.food or 2000, subtype = 1})
  if opts.fish_raw then F.item(W, 'FISH_RAW', {stack_size = opts.fish_raw}) end
  if opts.zone then F.building(W, 'ANY_ZONE', {type = 85, x1 = 0, y1 = 0, x2 = 2, y2 = 2, z = 100}) end
  job_list(opts.jobs or {})
  local ids = {}
  for i = 1, cit do
    ids[i] = i
    local u = W.unit(i)
    u.job = {current_job = {id = 900 + i}}
    u.status.labors = (opts.labors or {})[i] or {}
    u.mood = -1
    u._m.skills = {}
  end
  for _, i in ipairs(opts.idle or {9, 10, 11, 12, 13, 14}) do if i <= cit then W.unit(i).job = {current_job = nil} end end
  W.unit(2).status.labors = {DIAGNOSE = true}               -- the doctor
  W.unit(3).status.labors = {COOK = true}                   -- the only cook
  W.unit(5).status.labors = {MINE = true}                   -- a miner (Miners)
  W.unit(4).military.squad_id = 1                           -- a soldier
  W.set_census('u', F.census_u(ids, {soldiers = 1, soldier_ids = {4}}))
  if opts.setup then opts.setup(W, ctl) end
  W.load(fresh('economy'))
  return W, ctl
end

local function members(ctl, name)
  local r = {}
  for _, id in ipairs(ctl.wds[name].assigned_units) do r[#r + 1] = id end
  table.sort(r)
  return r
end
local function has(list, id) for _, x in ipairs(list) do if x == id then return true end end return false end
local function logs(W, pat)
  local r = {}
  for _, l in ipairs(W.logs) do if tostring(l.msg):find(pat, 1, true) then r[#r + 1] = l.msg end end
  return r
end

T.test('BUG-057: PlantSeeds unclaimed above 20 -> farmers join Planters (food fine); never a soldier, doctor, sole cook or miner',
       function()
  local W, ctl = world{jobs = many('PlantSeeds', 40)}
  days(W, 1)
  local pl = members(ctl, 'Planters')
  T.eq(#pl, 4, '40 jobs / 10 per farmer = 4')
  for _, id in ipairs({2, 3, 4, 5}) do T.ok(not has(pl, id), 'unit ' .. id .. ' must not be a farmer') end
  T.eq(members(ctl, 'Plant gatherers'), {}, 'no GatherPlants jobs: no gatherers')
  local ev = W.find_events('WORK_DETAIL')
  T.eq(#ev, 4)
  T.eq({ev[1].d.detail, ev[1].d.on, ev[1].d.n, ev[1].d.why}, {'Planters', 1, 4, 'cover'})
  T.ok(#logs(W, 'details: Planters +4') == 1, 'one kern.log line for the change')
  -- a further day: nothing changes (the target is met)
  days(W, 1)
  T.eq(#W.find_events('WORK_DETAIL'), 4)
end)

T.test('BUG-057: GatherPlants unclaimed -> gatherers join Plant gatherers at any food level; farmers and gatherers stay apart',
       function()
  local W, ctl = world{jobs = cat(many('PlantSeeds', 40), many('GatherPlants', 60, 20)),
                       labors = {[9] = {PLANT = true}, [10] = {PLANT = true}, [11] = {PLANT = true}, [12] = {PLANT = true}}}
  days(W, 1)
  local pl, ga = members(ctl, 'Planters'), members(ctl, 'Plant gatherers')
  T.eq(#pl, 4)
  T.eq(pl, {9, 10, 11, 12}, 'the PLANT holders plant')
  T.eq(#ga, 3, '60 jobs / 25 = 3 gatherers')
  for _, id in ipairs(ga) do T.ok(not has(pl, id) and id ~= 9, 'gatherer ' .. id .. ' is no farmer') end
  for _, c in ipairs(ctl.calls) do
    if c.name == 'Plant gatherers' then T.eq(c.opts, {select = true}) end
  end
end)

T.test('BUG-057: a detail on "nobody does this" is set to only selected; everybody-does-this is left alone; SIEGE changes nothing',
       function()
  local W, ctl = world{jobs = many('PlantSeeds', 40), modes = {Planters = 2}}
  days(W, 1)
  T.eq(ctl.wds.Planters.flags.mode, 3)
  T.eq(#members(ctl, 'Planters'), 4)
  local W2, ctl2 = world{jobs = many('PlantSeeds', 40), modes = {Planters = 1}}
  days(W2, 1)
  T.eq(#members(ctl2, 'Planters'), 0, 'everybody does this: the jobs wait for another reason')
  local W3, ctl3 = world{jobs = many('PlantSeeds', 40), mode = 'SIEGE'}
  days(W3, 2)
  T.eq(#members(ctl3, 'Planters'), 0)
end)

T.test('BUG-057: no shrinking while unclaimed jobs exist; the kernel\'s members leave after idle_days without any; the player\'s stay',
       function()
  local W, ctl = world{jobs = many('PlantSeeds', 40), members = {Planters = {13}}}
  days(W, 1)
  T.eq(#members(ctl, 'Planters'), 4, 'the player\'s member counts toward the target of 4: 3 added')
  job_list(many('PlantSeeds', 5))                              -- 5 unclaimed: below the line, above zero
  days(W, 12)
  T.eq(#members(ctl, 'Planters'), 4, 'jobs still wait: nobody leaves')
  job_list({})
  days(W, 6)
  T.eq(#members(ctl, 'Planters'), 4, 'six passes without jobs: still there')
  days(W, 2)
  local pl = members(ctl, 'Planters')
  T.ok(has(pl, 13), 'the player\'s member stays')
  T.eq(#pl, 2, 'down to farm_min')
end)

T.test('BUG-057: unreachable jobs (off the citizens\' walk group) call for no farmers', function()
  local W, ctl = world{jobs = cat(many('PlantSeeds', 30, 20), many('PlantSeeds', 40, 100))}   -- x >= 100: outside the wall
  days(W, 1)
  T.eq(#members(ctl, 'Planters'), 3, '30 reachable jobs / 10 = 3 (70 unclaimed would be 7)')
  local W2, ctl2 = world{jobs = cat(many('PlantSeeds', 15, 20), many('PlantSeeds', 40, 100))}
  days(W2, 1)
  T.eq(#members(ctl2, 'Planters'), 0, '15 reachable jobs: below the line')
end)

T.test('BUG-057: Fisherdwarves wants fishers beside a fishing zone with raw fish or Fish jobs, whatever the food stock says',
       function()
  local W, ctl = world{cit = 20, zone = true, fish_raw = 30}
  days(W, 1)
  T.eq(#members(ctl, 'Fisherdwarves'), 3, '20 citizens / 6 = 3')
  local W2, ctl2 = world{cit = 20, zone = true}
  days(W2, 2)
  T.eq(#members(ctl2, 'Fisherdwarves'), 0, 'no raw fish, no Fish job, plenty of food')
  local W3, ctl3 = world{cit = 20, zone = true, jobs = many('Fish', 3)}
  days(W3, 2)
  T.eq(#members(ctl3, 'Fisherdwarves'), 3, 'Fish jobs open: fishers')
  local W4, ctl4 = world{cit = 8, zone = true, fish_raw = 5}
  days(W4, 1)
  T.eq(#members(ctl4, 'Fisherdwarves'), 1, 'a fort of 8: one fisher')
  local W5, ctl5 = world{cit = 20, fish_raw = 30}
  days(W5, 1)
  T.eq(#members(ctl5, 'Fisherdwarves'), 0, 'no fishing zone: nobody fishes')
end)

T.test('BUG-057: members that vanish without the kernel are named (who resets the details?); the kernel\'s own removals are not',
       function()
  local W, ctl = world{jobs = many('PlantSeeds', 40)}
  days(W, 1)
  local pl = members(ctl, 'Planters')
  T.eq(#pl, 4)
  local v = ctl.wds.Planters.assigned_units
  v:erase(0); v:erase(0)                                       -- somebody else took two off
  days(W, 1)
  local l = logs(W, 'details: Planters lost 2 members the kernel did not take off')
  T.eq(#l, 1, table.concat(logs(W, 'Planters'), ' | '))
  T.ok(l[1]:find('0 of them still hold PLANT', 1, true), l[1])
  local r = W.inbox('inspect', {what = 'workload', key = 'details'})
  T.eq(r.ok, true, r.msg)
  local row
  for _, d in ipairs(r.data.details) do if d.detail == 'Planters' then row = d end end
  T.ok(row, 'Planters in the detail list')
  T.eq({row.lost, row.mode}, {2, 'OnlySelectedDoesThis'})
  T.ok(r.msg:find('Planters', 1, true) and r.msg:find('vanished without it', 1, true), r.msg)
  -- after the demand is gone the kernel takes its own off: no 'lost' line for those
  job_list({})
  days(W, 9)
  T.eq(#logs(W, 'details: Planters lost'), 1, 'only the first loss')
end)

T.test('FR-72: a job type nobody holds the labor for is named in the idle line ("no labor holder"), not counted as 0 without reachable work',
       function()
  local W = world{jobs = many('GatherPlants', 60, 20), cover = {on = false}}
  days(W, 1)
  local r = W.inbox('inspect', {what = 'workload'})
  T.eq(r.ok, true, r.msg)
  T.eq(r.data.nolabor, {{job = 'GatherPlants', n = 60, labor = 'HERBALIST'}})
  T.eq(r.data.idle_nolabor, 6)
  T.ok(r.msg:find('6 with no labor holder for the open jobs: GatherPlants 60 need HERBALIST', 1, true), r.msg)
  T.ok(not r.msg:find('0 without reachable work', 1, true), r.msg)
  -- one citizen holds the labor: the old wording
  local W2 = world{jobs = many('GatherPlants', 60, 20), cover = {on = false}, labors = {[1] = {HERBALIST = true}}}
  days(W2, 1)
  local r2 = W2.inbox('inspect', {what = 'workload'})
  T.ok(r2.msg:find('(0 without reachable work), 60 unclaimed jobs', 1, true), r2.msg)
end)

T.test('FR-72: another job type of cover.labors with more than min_jobs unclaimed jobs and no holder gets idle citizens ' ..
       'through a detail that grants the labor', function()
  local W, ctl = world{cover = {labors = {GatherPlants = 'HERBALIST', PlantSeeds = 'PLANT', HarvestPlants = 'PLANT',
                                          Dig = 'MINE', ConstructBed = 'CARPENTER'}},
                       setup = function(W, ctl)
    add_jobs({'ConstructBed'})
    df.unit_labor.CARPENTER, df.unit_labor[40] = 40, 'CARPENTER'
    ctl.wds.Carpenters = {name = 'Carpenters', assigned_units = kmock.vec{}, allowed_labors = {[40] = true},
                          flags = {mode = 3}}
    df.global.plotinfo.labor_info.work_details:insert('#', ctl.wds.Carpenters)
    job_list(many('ConstructBed', 25))
  end}
  days(W, 1)
  T.eq(#members(ctl, 'Carpenters'), 2, '25 jobs / 20 per = 2 (other_max 3)')
end)

T.test('FR-72: GatherPlants designations off the walk group (two passes) and unworked for stale_days are withdrawn; ' ..
       'not in SIEGE, not while food is low', function()
  local jobs = cat(many('GatherPlants', 8, 100), many('GatherPlants', 12, 40))
  local W, ctl = world{jobs = jobs, cover = {on = true}}
  days(W, 1)
  T.eq(#ctl.ungather, 0, 'seen off the walk group once: not yet')
  days(W, 1)
  T.eq(#ctl.ungather, 1)
  T.eq(#ctl.ungather[1], 8, 'only the 8 outside the wall')
  for _, pt in ipairs(ctl.ungather[1]) do T.ok(pt[1] >= 100, 'x ' .. pt[1]) end
  -- the reachable ones: nobody works on them for 30 days -> withdrawn too; gatherers were staffed but no job is taken
  days(W, 29)
  local n = 0
  for _, l in ipairs(ctl.ungather) do n = n + #l end
  T.ok(n >= 12 + 8, 'the 12 reachable ones went after stale_days: ' .. n)
  -- a taken job: nothing is stale
  local W2, ctl2 = world{jobs = cat(many('GatherPlants', 12, 40), many('GatherPlants', 2, 50, true))}
  days(W2, 34)
  T.eq(#ctl2.ungather, 0, 'somebody works on GatherPlants: nothing withdrawn')
  -- food low: the gatherers are wanted, the jobs stay
  local W3, ctl3 = world{jobs = many('GatherPlants', 12, 40), food = 5}
  days(W3, 34)
  T.ok((W3.K.view().stock.food_d or 99) < 30, 'food is below the pre-alarm line')
  T.eq(#ctl3.ungather, 0, 'food below the pre-alarm line: nothing withdrawn')
  local W4, ctl4 = world{jobs = many('GatherPlants', 12, 40), mode = 'SIEGE'}
  days(W4, 34)
  T.eq(#ctl4.ungather, 0, 'SIEGE: nothing withdrawn')
end)

T.test('FR-72: a gate bridge that is not down splits the walk groups: nothing off the walk group is withdrawn then',
       function()
  local jobs = cat(many('GatherPlants', 8, 100), many('GatherPlants', 12, 40, true))      -- 12 taken: no stale either
  local W, ctl = world{jobs = jobs, setup = function(W)
    W.load({name = 'gate', every = {ticks = 600}, state = function() return {bridges = {B1 = 'up'}} end})
  end}
  days(W, 4)
  T.eq(#ctl.ungather, 0, 'B1 is up')
  local W2, ctl2 = world{jobs = jobs, setup = function(W)
    W.load({name = 'gate', every = {ticks = 600}, state = function() return {bridges = {B1 = 'down'}} end})
  end}
  days(W2, 2)
  T.eq(#ctl2.ungather, 1, 'B1 is down: the 8 outside the wall go')
end)

T.test('BUG-057: the cover state survives a save/load round trip (an old state, a reload): no churn, no false "lost"',
       function()
  local json = require('dfllm.util.json')
  local W, ctl = world{jobs = many('PlantSeeds', 40)}
  days(W, 1)
  T.eq(#members(ctl, 'Planters'), 4)
  local p = W.K.persist.get('m.economy')
  T.eq(#p.cover.mine.Planters, 4)
  W.K.persist.set('m.economy', json.decode(json.encode(p)))          -- as after a save and a load
  days(W, 3)
  T.eq(#members(ctl, 'Planters'), 4, 'nothing added or removed')
  T.eq(#logs(W, 'lost'), 0, 'and nobody named lost')
  T.eq(#W.find_events('WORK_DETAIL'), 4)
  -- a state from before BUG-057 (no cover key at all): the first pass starts clean
  local W2, ctl2 = world{jobs = many('PlantSeeds', 40)}
  W2.K.persist.set('m.economy', {v = 2, hist = {drink = {}, food = {}}, prev = json.object{}, idle_days = 0, migrants = 0,
                                 cit = 0})
  days(W2, 1)
  T.eq(#members(ctl2, 'Planters'), 4)
end)

-- review of BUG-057 (note 35 for the food_low path): gather_low took the PLANT holders as gatherers while farm jobs waited
T.test('BUG-057 review: at food_low the gatherers are not the PLANT holders nor the Planters while PlantSeeds wait; without a backlog they may be',
       function()
  local lab = {[9] = {PLANT = true}, [10] = {PLANT = true}}
  local W, ctl = world{cover = {on = false}, food = 8, jobs = cat(many("PlantSeeds", 40), many("GatherPlants", 60, 20)),
                       labors = lab, members = {Planters = {11}}}
  days(W, 2)
  local ga = members(ctl, 'Plant gatherers')
  T.ok(#ga >= 1, 'gatherers join at food_low')
  for _, id in ipairs({9, 10, 11}) do T.ok(not has(ga, id), 'unit ' .. id .. ' plants, it does not gather') end
  local W2, ctl2 = world{cover = {on = false}, food = 8, jobs = many("GatherPlants", 60, 20), labors = lab}
  days(W2, 2)
  T.ok(has(members(ctl2, 'Plant gatherers'), 9), 'no farm backlog: an idle PLANT holder may gather')
end)

-- review: the marks of the kernel's own removals are spent after one audit and the kernel's list stays bounded
T.test('BUG-057 review: a member the kernel took off and added again and the game then drops is named lost; the mine list holds no duplicates',
       function()
  local W, ctl = world{jobs = many('PlantSeeds', 40)}
  days(W, 1)
  local before = members(ctl, 'Planters')
  T.eq(#before, 4)
  job_list({}); days(W, 9)                                       -- the demand is gone: the kernel takes its own off
  T.eq(#members(ctl, 'Planters'), 2, 'down to farm_min')
  job_list(many('PlantSeeds', 40)); days(W, 2)                   -- back: the kernel adds again
  T.eq(#members(ctl, 'Planters'), 4)
  local v = ctl.wds.Planters.assigned_units
  v:erase(0)                                                     -- the game drops one now
  days(W, 1)
  T.eq(#logs(W, 'details: Planters lost 1 members'), 1, 'a removal the kernel did long ago must not hide this one')
  local p = W.K.persist.get('m.economy')
  local seen = {}
  for _, id in ipairs(p.cover.mine.Planters) do T.ok(not seen[id], 'duplicate ' .. id); seen[id] = true end
  T.ok(#p.cover.mine.Planters <= 4, 'the list holds the members that are there')
end)

T.done()
